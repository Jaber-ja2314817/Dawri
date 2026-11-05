"""SQLite queue engine. Deterministic: arrival stamps and centre rules only."""

from __future__ import annotations

import math
import sqlite3
from collections.abc import Callable, Iterator
from contextlib import closing, contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any

from backend import db, events, timeutil
from backend.adapters.queue_base import (
    CallResult,
    CounterBusy,
    InvalidTransition,
    Position,
    QueueAdapter,
    Ticket,
    TicketExpired,
    TicketNotFound,
    VisitHasLiveTicket,
    VisitNotEligible,
)

RESERVATION_MINUTES = 45
NO_SHOW_LIMIT = 3
ROLLING_WINDOW = 20
MIN_ROLLING_SAMPLES = 5

RESERVABLE_STATUSES = ("intake", "expired")
NO_TICKET_STATUSES = (
    "redirected_emergency",
    "deflected_refill",
    "completed",
    "cancelled",
    "expired",
)

_RESERVATION_WINDOW = timedelta(minutes=RESERVATION_MINUTES)
_ORDER = "priority DESC, activated_at ASC, seq ASC"
_LIVE_STATES = ("reserved", "active", "called", "serving")
_VISIT_STATUS_BY_STAGE = {
    "triage": "in_triage",
    "doctor": "in_doctor",
    "pharmacy": "in_pharmacy",
}
_SIMULATED_NOTE = "handled by a colleague on shift"


@dataclass
class _Unit:
    """One transaction's connection, plus the events to publish after COMMIT."""

    conn: sqlite3.Connection
    messages: list[tuple[str, dict]] = field(default_factory=list)
    # counter id to the tickets whose own event already went out from it
    subjects: dict[str, set[str]] = field(default_factory=dict)


def _to_ticket(row: sqlite3.Row) -> Ticket:
    return Ticket(
        id=row["id"],
        visit_id=row["visit_id"],
        counter_id=row["counter_id"],
        centre_id=row["centre_id"],
        number=row["number"],
        seq=row["seq"],
        priority=row["priority"],
        state=row["state"],
        simulated=bool(row["simulated"]),
        call_count=row["call_count"],
        reserved_at=row["reserved_at"],
        activated_at=row["activated_at"],
        called_at=row["called_at"],
        done_at=row["done_at"],
        released_at=row["released_at"],
    )


def _load(conn: sqlite3.Connection, ticket_id: str) -> sqlite3.Row:
    row = conn.execute("SELECT * FROM ticket WHERE id = ?", (ticket_id,)).fetchone()
    if row is None:
        raise TicketNotFound(f"no ticket {ticket_id}")
    return row


def _counter(conn: sqlite3.Connection, counter_id: str) -> sqlite3.Row:
    row = conn.execute("SELECT * FROM counter WHERE id = ?", (counter_id,)).fetchone()
    if row is None:
        raise InvalidTransition(f"no counter {counter_id}")
    return row


def _set(conn: sqlite3.Connection, ticket_id: str, **columns: Any) -> None:
    assignments = ", ".join(f"{name} = ?" for name in columns)
    conn.execute(
        f"UPDATE ticket SET {assignments} WHERE id = ?",
        (*columns.values(), ticket_id),
    )


def _active(conn: sqlite3.Connection, counter_id: str) -> list[sqlite3.Row]:
    return conn.execute(
        f"SELECT * FROM ticket WHERE counter_id = ? AND state = 'active' ORDER BY {_ORDER}",
        (counter_id,),
    ).fetchall()


def _called_count(conn: sqlite3.Connection, counter_id: str) -> int:
    return conn.execute(
        "SELECT COUNT(*) FROM ticket WHERE counter_id = ? AND state = 'called'",
        (counter_id,),
    ).fetchone()[0]


def _people_ahead(conn: sqlite3.Connection, row: sqlite3.Row) -> int | None:
    if row["state"] in ("called", "serving"):
        return 0
    if row["state"] != "active":
        return None
    order = [ticket["id"] for ticket in _active(conn, row["counter_id"])]
    return _called_count(conn, row["counter_id"]) + order.index(row["id"])


def _has_live_ticket(conn: sqlite3.Connection, visit_id: str) -> bool:
    marks = ", ".join("?" for _ in _LIVE_STATES)
    found = conn.execute(
        f"SELECT 1 FROM ticket WHERE visit_id = ? AND state IN ({marks})",
        (visit_id, *_LIVE_STATES),
    ).fetchone()
    return found is not None


def _visit_status(conn: sqlite3.Connection, visit_id: str) -> str | None:
    row = conn.execute("SELECT status FROM visit WHERE id = ?", (visit_id,)).fetchone()
    return None if row is None else row["status"]


def _next_seq(
    conn: sqlite3.Connection, centre_id: str, prefix: str, now: datetime
) -> tuple[int, str]:
    day = timeutil.doha_day(now)
    seq = conn.execute(
        "INSERT INTO number_sequence (centre_id, prefix, day, last_value) "
        "VALUES (?, ?, ?, 1) "
        "ON CONFLICT (centre_id, prefix, day) "
        "DO UPDATE SET last_value = last_value + 1 RETURNING last_value",
        (centre_id, prefix, day),
    ).fetchone()[0]
    return seq, day


def _numbered(conn: sqlite3.Connection, counter: sqlite3.Row, now: datetime) -> dict:
    seq, day = _next_seq(conn, counter["centre_id"], counter["prefix"], now)
    return {"number": f"{counter['prefix']}-{seq:03d}", "seq": seq, "day": day}


def _priority(conn: sqlite3.Connection, visit_id: str, centre_id: str, now: datetime) -> int:
    """The centre's age rule, on the visit's patient: the dependent, not the guardian."""
    row = conn.execute(
        "SELECT patient.dob, centre.priority_age_min FROM visit "
        "JOIN patient ON patient.id = visit.patient_id "
        "JOIN centre ON centre.id = ? "
        "WHERE visit.id = ?",
        (centre_id, visit_id),
    ).fetchone()
    return 1 if timeutil.age_on(row["dob"], now) >= row["priority_age_min"] else 0


def _avg_service_sec(conn: sqlite3.Connection, counter: sqlite3.Row) -> float:
    rows = conn.execute(
        "SELECT called_at, done_at FROM ticket "
        "WHERE counter_id = ? AND state = 'done' AND simulated = 0 "
        "AND called_at IS NOT NULL "
        "ORDER BY done_at DESC, rowid DESC LIMIT ?",
        (counter["id"], ROLLING_WINDOW),
    ).fetchall()
    if len(rows) < MIN_ROLLING_SAMPLES:
        return float(counter["avg_service_sec"])
    spans = [
        (timeutil.parse(row["done_at"]) - timeutil.parse(row["called_at"])).total_seconds()
        for row in rows
    ]
    return sum(spans) / len(spans)


def _wait_min(people_ahead: int, avg_service_sec: float) -> int:
    return math.ceil(people_ahead * avg_service_sec / 60)


def _counter_wait(conn: sqlite3.Connection, counter: sqlite3.Row) -> dict:
    ahead = _called_count(conn, counter["id"]) + len(_active(conn, counter["id"]))
    return {
        "people_ahead": ahead,
        "wait_min": _wait_min(ahead, _avg_service_sec(conn, counter)),
    }


def _triage_counter(conn: sqlite3.Connection, centre_id: str) -> sqlite3.Row | None:
    return conn.execute(
        "SELECT * FROM counter WHERE centre_id = ? AND stage = 'triage' ORDER BY id LIMIT 1",
        (centre_id,),
    ).fetchone()


class SqliteQueueEngine(QueueAdapter):
    def __init__(
        self,
        conn_factory: Callable[[], sqlite3.Connection] = db.connect,
        clock: Callable[[], datetime] = timeutil.utcnow,
        publish: Callable[[str, dict], None] | None = None,
    ) -> None:
        self._conn_factory = conn_factory
        self.clock = clock
        self._publish = publish or (lambda channel, event: None)

    # Transaction plumbing

    @contextmanager
    def _unit(self) -> Iterator[_Unit]:
        conn = self._conn_factory()
        unit = _Unit(conn)
        try:
            with db.transaction(conn):
                yield unit
                self._queue_changed(unit)
        finally:
            conn.close()
        for channel, event in unit.messages:
            self._publish(channel, event)

    def _record(
        self, unit: _Unit, ticket_id: str, event_type: str, now: datetime, **detail: Any
    ) -> sqlite3.Row:
        """Write the event row and line up the SSE messages for this transition."""
        conn = unit.conn
        row = _load(conn, ticket_id)
        payload = {
            "ticket_id": row["id"],
            "number": row["number"],
            "counter_id": row["counter_id"],
            **detail,
        }
        conn.execute(
            "INSERT INTO event (visit_id, type, payload, at) VALUES (?, ?, ?, ?)",
            (row["visit_id"], event_type, db.dumps(payload), timeutil.iso(now)),
        )
        message = {
            "type": event_type,
            "visit_id": row["visit_id"],
            "ticket": row["number"],
            "counter": _counter(conn, row["counter_id"])["label"],
            "people_ahead": _people_ahead(conn, row),
        }
        unit.messages.append((events.counter_channel(row["counter_id"]), message))
        if row["visit_id"] is not None:
            unit.messages.append((events.visit_channel(row["visit_id"]), message))
        # The TV in the waiting room gets numbers only, never a patient link.
        display = {key: value for key, value in message.items() if key != "visit_id"}
        unit.messages.append((events.display_channel(row["centre_id"]), display))
        unit.subjects.setdefault(row["counter_id"], set()).add(row["id"])
        return row

    def _queue_changed(self, unit: _Unit) -> None:
        """Tell every other waiting patient on the touched counters to refetch."""
        for counter_id, subjects in unit.subjects.items():
            message = {
                "type": "queue.changed",
                "counter": _counter(unit.conn, counter_id)["label"],
            }
            waiting = unit.conn.execute(
                "SELECT id, visit_id FROM ticket WHERE counter_id = ? "
                "AND state IN ('active', 'called') AND simulated = 0",
                (counter_id,),
            ).fetchall()
            for row in waiting:
                if row["id"] not in subjects:
                    unit.messages.append((events.visit_channel(row["visit_id"]), message))

    # Reserving and arriving

    def issue_ticket(self, visit_id: str, counter_id: str) -> Ticket:
        now = self.clock()
        self._expire(now)
        with self._unit() as unit:
            conn = unit.conn
            counter = _counter(conn, counter_id)
            if counter["stage"] != "triage":
                raise InvalidTransition("reservations are for triage counters only")
            status = _visit_status(conn, visit_id)
            if status is None:
                raise VisitNotEligible(f"no visit {visit_id}")
            if _has_live_ticket(conn, visit_id):
                raise VisitHasLiveTicket(f"visit {visit_id} already has a live ticket")
            if status not in RESERVABLE_STATUSES:
                raise VisitNotEligible(f"visit {visit_id} is {status}")
            ticket_id = db.new_id("tkt")
            conn.execute(
                "INSERT INTO ticket (id, visit_id, centre_id, counter_id, state, reserved_at) "
                "VALUES (?, ?, ?, ?, 'reserved', ?)",
                (ticket_id, visit_id, counter["centre_id"], counter_id, timeutil.iso(now)),
            )
            conn.execute(
                "UPDATE visit SET status = 'reserved', centre_id = ? WHERE id = ?",
                (counter["centre_id"], visit_id),
            )
            row = self._record(unit, ticket_id, "ticket.reserved", now)
        return _to_ticket(row)

    def activate(self, ticket_id: str, method: str = "button") -> Ticket:
        now = self.clock()
        self._expire(now)  # Commits on its own, so the release below survives the raise.
        with self._unit() as unit:
            conn = unit.conn
            row = _load(conn, ticket_id)
            if self._was_expired(row):
                raise TicketExpired(f"ticket {ticket_id} passed its check-in window")
            if row["state"] != "reserved":
                raise InvalidTransition(f"cannot activate a {row['state']} ticket")
            status = _visit_status(conn, row["visit_id"])
            if status != "reserved":
                raise VisitNotEligible(f"visit {row['visit_id']} is {status}")
            stamp = timeutil.iso(now)
            _set(
                conn,
                ticket_id,
                state="active",
                activated_at=stamp,
                priority=_priority(conn, row["visit_id"], row["centre_id"], now),
                **_numbered(conn, _counter(conn, row["counter_id"]), now),
            )
            conn.execute(
                "UPDATE visit SET status = 'in_triage', arrived_at = ? WHERE id = ?",
                (stamp, row["visit_id"]),
            )
            row = self._record(unit, ticket_id, "ticket.activated", now, method=method)
        return _to_ticket(row)

    @staticmethod
    def _was_expired(row: sqlite3.Row) -> bool:
        """True for a ticket the window released, false for one cancelled in time."""
        if row["state"] != "released" or row["activated_at"] is not None:
            return False
        deadline = timeutil.parse(row["reserved_at"]) + _RESERVATION_WINDOW
        return timeutil.parse(row["released_at"]) >= deadline

    def issue_active(self, visit_id: str, counter_id: str) -> Ticket:
        now = self.clock()
        self._expire(now)
        with self._unit() as unit:
            conn = unit.conn
            counter = _counter(conn, counter_id)
            status = _visit_status(conn, visit_id)
            if status is None:
                raise VisitNotEligible(f"no visit {visit_id}")
            if _has_live_ticket(conn, visit_id):
                raise VisitHasLiveTicket(f"visit {visit_id} already has a live ticket")
            if status in NO_TICKET_STATUSES:
                raise VisitNotEligible(f"visit {visit_id} is {status}")
            ticket_id = db.new_id("tkt")
            stamp = timeutil.iso(now)
            number = _numbered(conn, counter, now)
            conn.execute(
                "INSERT INTO ticket (id, visit_id, centre_id, counter_id, state, number, seq, "
                "day, priority, activated_at) VALUES (?, ?, ?, ?, 'active', ?, ?, ?, ?, ?)",
                (
                    ticket_id,
                    visit_id,
                    counter["centre_id"],
                    counter_id,
                    number["number"],
                    number["seq"],
                    number["day"],
                    _priority(conn, visit_id, counter["centre_id"], now),
                    stamp,
                ),
            )
            conn.execute(
                "UPDATE visit SET status = ?, centre_id = ?, "
                "arrived_at = COALESCE(arrived_at, ?) WHERE id = ?",
                (
                    _VISIT_STATUS_BY_STAGE[counter["stage"]],
                    counter["centre_id"],
                    stamp,
                    visit_id,
                ),
            )
            row = self._record(unit, ticket_id, "ticket.activated", now, method="direct")
        return _to_ticket(row)

    def issue_simulated(self, counter_id: str) -> Ticket:
        """A waiting ticket with no patient behind it, for SIMULATE_LOAD."""
        now = self.clock()
        with self._unit() as unit:
            conn = unit.conn
            counter = _counter(conn, counter_id)
            number = _numbered(conn, counter, now)
            ticket_id = db.new_id("tkt")
            conn.execute(
                "INSERT INTO ticket (id, centre_id, counter_id, state, number, seq, day, "
                "priority, simulated, activated_at) "
                "VALUES (?, ?, ?, 'active', ?, ?, ?, 0, 1, ?)",
                (
                    ticket_id,
                    counter["centre_id"],
                    counter_id,
                    number["number"],
                    number["seq"],
                    number["day"],
                    timeutil.iso(now),
                ),
            )
            row = self._record(unit, ticket_id, "ticket.activated", now, method="simulated")
        return _to_ticket(row)

    # At the counter

    def call_next(self, counter_id: str) -> CallResult:
        now = self.clock()
        self._expire(now)
        with self._unit() as unit:
            conn = unit.conn
            _counter(conn, counter_id)
            busy = conn.execute(
                "SELECT 1 FROM ticket WHERE counter_id = ? AND state IN ('called', 'serving')",
                (counter_id,),
            ).fetchone()
            if busy is not None:
                raise CounterBusy(f"counter {counter_id} already has a patient")
            queue = _active(conn, counter_id)
            first_real = next(
                (index for index, row in enumerate(queue) if not row["simulated"]), None
            )
            # Only simulated tickets left: one moves on, and nobody is called.
            ahead = queue[:1] if first_real is None else queue[:first_real]
            auto_completed = []
            for row in ahead:
                _set(conn, row["id"], state="done", done_at=timeutil.iso(now))
                auto_completed.append(
                    self._record(
                        unit, row["id"], "ticket.simulated_done", now, note=_SIMULATED_NOTE
                    )
                )
            called = None
            if first_real is not None:
                ticket = queue[first_real]
                _set(
                    conn,
                    ticket["id"],
                    state="called",
                    called_at=timeutil.iso(now),
                    call_count=ticket["call_count"] + 1,
                )
                called = self._record(unit, ticket["id"], "ticket.called", now)
        return CallResult(
            called=None if called is None else _to_ticket(called),
            auto_completed=[_to_ticket(row) for row in auto_completed],
        )

    def serve(self, ticket_id: str) -> Ticket:
        now = self.clock()
        with self._unit() as unit:
            row = _load(unit.conn, ticket_id)
            if row["state"] != "called":
                raise InvalidTransition(f"cannot serve a {row['state']} ticket")
            row = self._serve(unit, ticket_id, now)
        return _to_ticket(row)

    def _serve(self, unit: _Unit, ticket_id: str, now: datetime) -> sqlite3.Row:
        _set(unit.conn, ticket_id, state="serving")
        return self._record(unit, ticket_id, "ticket.serving", now)

    def no_show(self, ticket_id: str) -> Ticket:
        now = self.clock()
        with self._unit() as unit:
            conn = unit.conn
            row = _load(conn, ticket_id)
            if row["state"] != "called":
                raise InvalidTransition(f"cannot mark a {row['state']} ticket as no-show")
            moved_to_back = row["call_count"] >= NO_SHOW_LIMIT
            if moved_to_back:
                counter = _counter(conn, row["counter_id"])
                seq, _ = _next_seq(conn, row["centre_id"], counter["prefix"], now)
                _set(conn, ticket_id, state="active", activated_at=timeutil.iso(now), seq=seq)
            else:
                _set(conn, ticket_id, state="active")
            row = self._record(
                unit, ticket_id, "ticket.no_show", now, moved_to_back=moved_to_back
            )
        return _to_ticket(row)

    def complete(self, ticket_id: str) -> Ticket:
        now = self.clock()
        with self._unit() as unit:
            row = _load(unit.conn, ticket_id)
            if row["state"] not in ("called", "serving"):
                raise InvalidTransition(f"cannot complete a {row['state']} ticket")
            if row["state"] == "called":
                self._serve(unit, ticket_id, now)
            _set(unit.conn, ticket_id, state="done", done_at=timeutil.iso(now))
            row = self._record(unit, ticket_id, "ticket.done", now)
        return _to_ticket(row)

    def release(self, ticket_id: str, reason: str) -> Ticket:
        now = self.clock()
        with self._unit() as unit:
            row = _load(unit.conn, ticket_id)
            if row["state"] not in _LIVE_STATES:
                raise InvalidTransition(f"cannot release a {row['state']} ticket")
            _set(unit.conn, ticket_id, state="released", released_at=timeutil.iso(now))
            row = self._record(unit, ticket_id, "ticket.released", now, reason=reason)
        return _to_ticket(row)

    def expire_due(self) -> list[Ticket]:
        return self._expire(self.clock())

    def _expire(self, now: datetime) -> list[Ticket]:
        # A ticket is expired when now >= reserved_at + the window. Stored
        # stamps are fixed width UTC, so this string compare is a time compare.
        cutoff = timeutil.iso(now - _RESERVATION_WINDOW)
        expired = []
        with self._unit() as unit:
            conn = unit.conn
            due = conn.execute(
                "SELECT id FROM ticket WHERE state = 'reserved' AND reserved_at <= ?",
                (cutoff,),
            ).fetchall()
            for row in due:
                _set(conn, row["id"], state="released", released_at=timeutil.iso(now))
                released = self._record(
                    unit, row["id"], "ticket.released", now, reason="expired"
                )
                # A visit that moved on, such as to emergency, must not reopen.
                conn.execute(
                    "UPDATE visit SET status = 'expired' WHERE id = ? AND status = 'reserved'",
                    (released["visit_id"],),
                )
                expired.append(_to_ticket(released))
        return expired

    # Reading the queue

    def position(self, ticket_id: str) -> Position:
        self._expire(self.clock())
        with closing(self._conn_factory()) as conn:
            row = _load(conn, ticket_id)
            people_ahead = _people_ahead(conn, row)
            est_wait_min = None
            if people_ahead is not None:
                counter = _counter(conn, row["counter_id"])
                est_wait_min = _wait_min(people_ahead, _avg_service_sec(conn, counter))
        expires_at = None
        if row["state"] == "reserved":
            expires_at = timeutil.iso(
                timeutil.parse(row["reserved_at"]) + _RESERVATION_WINDOW
            )
        return Position(
            ticket_id=row["id"],
            state=row["state"],
            number=row["number"],
            people_ahead=people_ahead,
            est_wait_min=est_wait_min,
            expires_at=expires_at,
        )

    def queue_snapshot(self, counter_id: str) -> list[dict]:
        self._expire(self.clock())
        with closing(self._conn_factory()) as conn:
            at_counter = conn.execute(
                "SELECT * FROM ticket WHERE counter_id = ? "
                "AND state IN ('called', 'serving') ORDER BY called_at ASC",
                (counter_id,),
            ).fetchall()
            waiting = _active(conn, counter_id)
        rows = [(row, None) for row in at_counter]
        rows += [(row, index) for index, row in enumerate(waiting, start=1)]
        return [
            {
                "ticket_id": row["id"],
                "number": row["number"],
                "state": row["state"],
                "priority": row["priority"],
                "simulated": bool(row["simulated"]),
                "visit_id": row["visit_id"],
                "activated_at": row["activated_at"],
                "called_at": row["called_at"],
                "call_count": row["call_count"],
                "label": "Simulated" if row["simulated"] else None,
                "position": position,
            }
            for row, position in rows
        ]

    def avg_service_sec(self, counter_id: str) -> float:
        with closing(self._conn_factory()) as conn:
            return _avg_service_sec(conn, _counter(conn, counter_id))

    def counter_wait(self, counter_id: str) -> dict:
        """What a newcomer to this counter would face."""
        with closing(self._conn_factory()) as conn:
            return _counter_wait(conn, _counter(conn, counter_id))

    def centre_wait(self, centre_id: str, service: str) -> dict:
        """Triage wait plus the shortest doctor wait for the service."""
        with closing(self._conn_factory()) as conn:
            triage = _triage_counter(conn, centre_id)
            wait = {"people_ahead": 0, "wait_min": 0}
            if triage is not None:
                wait = _counter_wait(conn, triage)
            doctors = conn.execute(
                "SELECT counter.* FROM counter JOIN staff ON staff.id = counter.staff_id "
                "WHERE counter.centre_id = ? AND counter.stage = 'doctor' AND staff.clinic = ?",
                (centre_id, service),
            ).fetchall()
            doctor_min = min(
                (_counter_wait(conn, doctor)["wait_min"] for doctor in doctors), default=0
            )
        return {
            "people_ahead": wait["people_ahead"],
            "wait_min": wait["wait_min"] + doctor_min,
        }

    def triage_counter(self, centre_id: str) -> str:
        with closing(self._conn_factory()) as conn:
            counter = _triage_counter(conn, centre_id)
        if counter is None:
            raise InvalidTransition(f"centre {centre_id} has no triage counter")
        return counter["id"]
