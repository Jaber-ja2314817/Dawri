"""One-transaction moves between stages, and the sample floor on wait estimates."""

from __future__ import annotations

import inspect
import json

import pytest

from backend import db
from backend import events as channels
from backend import timeutil
from backend.adapters.queue_base import (
    InvalidTransition,
    QueueAdapter,
    TicketNotFound,
    VisitNotEligible,
)
from backend.queue_engine import MIN_SAMPLE_SEC, ROLLING_WINDOW, SqliteQueueEngine
from backend.tests.conftest import make_visit

T1 = "C-WAKRA-T1"
D3 = "C-WAKRA-D3"
D4 = "C-WAKRA-D4"
P1 = "C-WAKRA-P1"
RAYYAN_D = "C-RAYYAN-D1"


def _counter_with(conn, centre_id, stage):
    return conn.execute(
        "SELECT id FROM counter WHERE centre_id = ? AND stage = ? ORDER BY id",
        (centre_id, stage),
    ).fetchone()["id"]


def _at_counter(engine, conn, counter_id=T1, patient_id="P001", serving=False):
    """A real ticket at the counter, in state called or serving."""
    ticket = engine.issue_active(make_visit(conn, patient_id), counter_id)
    assert engine.call_next(counter_id).called.id == ticket.id
    if serving:
        engine.serve(ticket.id)
    return ticket


def _visit(conn, visit_id):
    return conn.execute("SELECT * FROM visit WHERE id = ?", (visit_id,)).fetchone()


def _ticket(conn, ticket_id):
    return conn.execute("SELECT * FROM ticket WHERE id = ?", (ticket_id,)).fetchone()


def _event_types(conn, visit_id):
    rows = conn.execute(
        "SELECT type FROM event WHERE visit_id = ? ORDER BY id", (visit_id,)
    ).fetchall()
    return [row["type"] for row in rows]


def _snapshot(conn):
    return {
        table: [tuple(row) for row in conn.execute(f"SELECT * FROM {table}").fetchall()]
        for table in ("ticket", "visit", "event", "number_sequence")
    }


def _types(events, channel):
    return [event["type"] for event in events.on(channel)]


# advance


def test_advance_from_serving_finishes_and_queues_the_next_stage(engine, seeded, events):
    ticket = _at_counter(engine, seeded, serving=True)
    events.clear()

    next_ticket = engine.advance(ticket.id, D4)

    assert _ticket(seeded, ticket.id)["state"] == "done"
    assert next_ticket.state == "active"
    assert next_ticket.counter_id == D4
    assert next_ticket.visit_id == ticket.visit_id
    assert next_ticket.number == "D-GP-001"
    assert next_ticket.activated_at is not None
    assert _visit(seeded, ticket.visit_id)["status"] == "in_doctor"
    assert _event_types(seeded, ticket.visit_id)[-2:] == ["ticket.done", "ticket.activated"]
    activated = seeded.execute(
        "SELECT payload FROM event WHERE type = 'ticket.activated' ORDER BY id DESC"
    ).fetchone()
    assert json.loads(activated["payload"])["method"] == "direct"


def test_advance_from_called_passes_through_serving(engine, seeded):
    ticket = _at_counter(engine, seeded)
    engine.advance(ticket.id, D4)
    assert _event_types(seeded, ticket.visit_id)[-3:] == [
        "ticket.serving",
        "ticket.done",
        "ticket.activated",
    ]


def test_advance_to_pharmacy_sets_the_pharmacy_status(engine, seeded):
    ticket = _at_counter(engine, seeded)
    doctor = engine.advance(ticket.id, D4)
    engine.call_next(D4)
    pharmacy = engine.advance(doctor.id, P1)
    assert pharmacy.number == "P-001"
    assert _visit(seeded, ticket.visit_id)["status"] == "in_pharmacy"


def test_advance_keeps_the_first_arrival_stamp(engine, seeded, clock):
    ticket = _at_counter(engine, seeded)
    arrived_at = _visit(seeded, ticket.visit_id)["arrived_at"]
    clock.advance(minutes=5)
    engine.advance(ticket.id, D4)
    assert _visit(seeded, ticket.visit_id)["arrived_at"] == arrived_at


def test_advance_joins_the_end_of_the_next_queue(engine, seeded):
    waiting = engine.issue_active(make_visit(seeded, "P002"), D4)
    ticket = _at_counter(engine, seeded)
    next_ticket = engine.advance(ticket.id, D4)
    assert engine.position(next_ticket.id).people_ahead == 1
    assert engine.queue_snapshot(D4)[0]["ticket_id"] == waiting.id


def test_advance_takes_priority_from_the_centre_rule(engine, seeded):
    ticket = _at_counter(engine, seeded, patient_id="P002")  # Born 1959, so 65+.
    assert engine.advance(ticket.id, D4).priority == 1


def test_advance_takes_no_priority_or_position_argument():
    for name in ("advance", "finish_visit", "escalate", "complete_simulated"):
        parameters = inspect.signature(getattr(QueueAdapter, name)).parameters
        assert not {"priority", "position"} & set(parameters), name


@pytest.mark.parametrize(
    "bad_counter", [RAYYAN_D, "C-NOPE"], ids=["other centre", "unknown counter"]
)
def test_advance_refuses_a_bad_counter_and_changes_nothing(
    engine, seeded, events, bad_counter
):
    ticket = _at_counter(engine, seeded)
    events.clear()
    before = _snapshot(seeded)
    with pytest.raises(InvalidTransition):
        engine.advance(ticket.id, bad_counter)
    assert _snapshot(seeded) == before
    assert events == []


@pytest.mark.parametrize("state", ["active", "done", "released", "reserved"])
def test_advance_needs_a_called_or_serving_ticket(engine, seeded, state):
    visit_id = make_visit(seeded, "P001")
    if state == "reserved":
        ticket = engine.issue_ticket(visit_id, T1)
    else:
        ticket = engine.issue_active(visit_id, T1)
    if state == "done":
        engine.call_next(T1)
        engine.complete(ticket.id)
    if state == "released":
        engine.release(ticket.id, "test")
    before = _snapshot(seeded)
    with pytest.raises(InvalidTransition):
        engine.advance(ticket.id, D4)
    assert _snapshot(seeded) == before


def test_advance_unknown_ticket(engine):
    with pytest.raises(TicketNotFound):
        engine.advance("tkt_nope", D4)


@pytest.mark.parametrize("status", ["redirected_emergency", "deflected_refill", "cancelled"])
def test_advance_refuses_a_closed_visit_and_rolls_back(engine, seeded, events, status):
    ticket = _at_counter(engine, seeded)
    seeded.execute("UPDATE visit SET status = ? WHERE id = ?", (status, ticket.visit_id))
    events.clear()
    before = _snapshot(seeded)
    with pytest.raises(VisitNotEligible):
        engine.advance(ticket.id, D4)
    # The first half was undone too: the triage ticket is still at the counter.
    assert _snapshot(seeded) == before
    assert _ticket(seeded, ticket.id)["state"] == "called"
    assert events == []


def test_advance_a_failure_late_in_the_unit_rolls_back_the_finish(engine, seeded, monkeypatch):
    """The next stage's insert blows up after the first ticket went to done."""
    ticket = _at_counter(engine, seeded)
    before = _snapshot(seeded)

    def boom(*args, **kwargs):
        raise RuntimeError("disk full")

    monkeypatch.setattr("backend.queue_engine._numbered", boom)
    with pytest.raises(RuntimeError):
        engine.advance(ticket.id, D4)
    assert _snapshot(seeded) == before


def test_advance_publishes_each_event_once_after_commit(engine, seeded, events):
    other = engine.issue_active(make_visit(seeded, "P003"), T1)
    ticket = engine.issue_active(make_visit(seeded, "P001"), T1)
    engine.call_next(T1)  # Calls `other`.
    engine.complete(other.id)
    engine.call_next(T1)
    events.clear()

    engine.advance(ticket.id, D4)

    channel = channels.visit_channel(ticket.visit_id)
    assert _types(events, channel) == ["ticket.serving", "ticket.done", "ticket.activated"]
    assert _types(events, channels.counter_channel(T1)) == ["ticket.serving", "ticket.done"]
    assert _types(events, channels.counter_channel(D4)) == ["ticket.activated"]


def test_a_client_refetching_on_an_advance_event_sees_the_new_state(seeded, db_path, clock):
    """A stale read here would show a patient a finished stage with no next ticket."""
    seen = []

    def refetch(channel, event):
        conn = db.connect(db_path)
        visit = conn.execute("SELECT status FROM visit WHERE id = ?", (visit_id,)).fetchone()
        live = conn.execute(
            "SELECT number FROM ticket WHERE visit_id = ? AND state = 'active'", (visit_id,)
        ).fetchone()
        conn.close()
        seen.append((event["type"], visit["status"], None if live is None else live["number"]))

    engine = SqliteQueueEngine(lambda: db.connect(db_path), clock, refetch)
    visit_id = make_visit(seeded, "P001")
    ticket = engine.issue_active(visit_id, T1)
    engine.call_next(T1)
    seen.clear()

    engine.advance(ticket.id, D4)

    assert seen
    assert {status for _, status, _ in seen} == {"in_doctor"}
    assert {number for _, _, number in seen} == {"D-GP-001"}


# finish_visit


def test_finish_visit_finishes_the_ticket_and_completes_the_visit(engine, seeded, clock):
    ticket = _at_counter(engine, seeded, P1, serving=True)
    finished = engine.finish_visit(ticket.id)
    assert finished.state == "done"
    visit = _visit(seeded, ticket.visit_id)
    assert visit["status"] == "completed"
    assert visit["completed_at"] == timeutil.iso(clock.now)
    assert _event_types(seeded, ticket.visit_id)[-1] == "ticket.done"


def test_finish_visit_from_called_passes_through_serving(engine, seeded):
    ticket = _at_counter(engine, seeded, P1)
    engine.finish_visit(ticket.id)
    assert _event_types(seeded, ticket.visit_id)[-2:] == ["ticket.serving", "ticket.done"]


def test_a_client_refetching_on_ticket_done_sees_completed(seeded, db_path, clock):
    seen = []

    def refetch(channel, event):
        if event["type"] == "ticket.done":
            conn = db.connect(db_path)
            seen.append(_visit(conn, visit_id)["status"])
            conn.close()

    engine = SqliteQueueEngine(lambda: db.connect(db_path), clock, refetch)
    visit_id = make_visit(seeded, "P001")
    ticket = engine.issue_active(visit_id, P1)
    engine.call_next(P1)
    engine.finish_visit(ticket.id)
    assert seen and set(seen) == {"completed"}


def test_finish_visit_publishes_once(engine, seeded, events):
    ticket = _at_counter(engine, seeded, P1, serving=True)
    events.clear()
    engine.finish_visit(ticket.id)
    assert _types(events, channels.visit_channel(ticket.visit_id)) == ["ticket.done"]


@pytest.mark.parametrize("state", ["active", "done"])
def test_finish_visit_needs_a_called_or_serving_ticket(engine, seeded, state):
    ticket = engine.issue_active(make_visit(seeded, "P001"), P1)
    if state == "done":
        engine.call_next(P1)
        engine.complete(ticket.id)
    before = _snapshot(seeded)
    with pytest.raises(InvalidTransition):
        engine.finish_visit(ticket.id)
    assert _snapshot(seeded) == before


def test_finish_visit_never_overwrites_an_emergency(engine, seeded, events):
    ticket = _at_counter(engine, seeded, P1)
    seeded.execute(
        "UPDATE visit SET status = 'redirected_emergency' WHERE id = ?", (ticket.visit_id,)
    )
    events.clear()
    before = _snapshot(seeded)
    with pytest.raises(VisitNotEligible):
        engine.finish_visit(ticket.id)
    assert _snapshot(seeded) == before
    assert events == []


def test_finish_visit_failure_rolls_back_the_ticket(engine, seeded, monkeypatch):
    ticket = _at_counter(engine, seeded, P1)
    before = _snapshot(seeded)
    real = engine._record

    def boom(unit, ticket_id, event_type, now, **detail):
        if event_type == "ticket.done":
            raise RuntimeError("disk full")
        return real(unit, ticket_id, event_type, now, **detail)

    monkeypatch.setattr(engine, "_record", boom)
    with pytest.raises(RuntimeError):
        engine.finish_visit(ticket.id)
    assert _snapshot(seeded) == before


# escalate


@pytest.mark.parametrize("state", ["reserved", "active", "called", "serving"])
def test_escalate_releases_a_live_ticket_and_redirects(engine, seeded, events, state):
    visit_id = make_visit(seeded, "P001")
    if state == "reserved":
        ticket = engine.issue_ticket(visit_id, T1)
    else:
        ticket = engine.issue_active(visit_id, T1)
    if state in ("called", "serving"):
        engine.call_next(T1)
    if state == "serving":
        engine.serve(ticket.id)
    events.clear()

    released = engine.escalate(ticket.id, "nurse_urgent_ed")

    assert released.state == "released"
    assert _visit(seeded, visit_id)["status"] == "redirected_emergency"
    assert engine.live_ticket(visit_id) is None
    event = seeded.execute(
        "SELECT payload FROM event WHERE type = 'ticket.released' AND visit_id = ?",
        (visit_id,),
    ).fetchone()
    assert json.loads(event["payload"])["reason"] == "nurse_urgent_ed"
    assert _types(events, channels.visit_channel(visit_id)) == ["ticket.released"]


def test_escalate_refuses_a_finished_ticket_and_changes_nothing(engine, seeded):
    ticket = _at_counter(engine, seeded)
    engine.complete(ticket.id)
    before = _snapshot(seeded)
    with pytest.raises(InvalidTransition):
        engine.escalate(ticket.id, "too late")
    assert _snapshot(seeded) == before


def test_an_escalated_visit_can_get_no_new_ticket(engine, seeded):
    ticket = _at_counter(engine, seeded)
    engine.escalate(ticket.id, "nurse_urgent_ed")
    with pytest.raises(VisitNotEligible):
        engine.issue_active(ticket.visit_id, D4)
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(ticket.visit_id, T1)


def test_a_client_refetching_on_release_sees_the_redirect(seeded, db_path, clock):
    seen = []

    def refetch(channel, event):
        if event["type"] == "ticket.released":
            conn = db.connect(db_path)
            seen.append(_visit(conn, visit_id)["status"])
            conn.close()

    engine = SqliteQueueEngine(lambda: db.connect(db_path), clock, refetch)
    visit_id = make_visit(seeded, "P001")
    ticket = engine.issue_active(visit_id, T1)
    engine.escalate(ticket.id, "nurse_urgent_ed")
    assert seen and set(seen) == {"redirected_emergency"}


# complete_simulated


def test_complete_simulated_takes_the_first_in_queue_order(engine, seeded, events):
    first = engine.issue_simulated(T1)
    second = engine.issue_simulated(T1)
    events.clear()

    done = engine.complete_simulated(T1)

    assert done.id == first.id
    assert done.state == "done" and done.done_at is not None
    assert done.called_at is None and done.call_count == 0
    assert engine.position(second.id).state == "active"
    assert _types(events, channels.counter_channel(T1)) == ["ticket.simulated_done"]
    row = seeded.execute(
        "SELECT payload FROM event WHERE type = 'ticket.simulated_done'"
    ).fetchone()
    assert json.loads(row["payload"])["note"] == "handled by a colleague on shift"


def test_complete_simulated_never_touches_a_real_ticket(engine, seeded):
    real = engine.issue_active(make_visit(seeded, "P001"), T1)
    before = tuple(_ticket(seeded, real.id))
    assert engine.complete_simulated(T1) is None
    assert tuple(_ticket(seeded, real.id)) == before


def test_complete_simulated_passes_over_a_real_ticket_ahead(engine, seeded):
    real = engine.issue_active(make_visit(seeded, "P001"), T1)
    sim = engine.issue_simulated(T1)
    assert engine.complete_simulated(T1).id == sim.id
    assert engine.position(real.id).state == "active"


def test_complete_simulated_with_none_waiting(engine):
    assert engine.complete_simulated(T1) is None


def test_complete_simulated_tells_real_patients_to_refetch(engine, seeded, events):
    engine.issue_simulated(T1)
    real = engine.issue_active(make_visit(seeded, "P001"), T1)
    events.clear()
    engine.complete_simulated(T1)
    assert _types(events, channels.visit_channel(real.visit_id)) == ["queue.changed"]
    assert engine.position(real.id).people_ahead == 0


# live_ticket and latest_ticket


def test_live_and_latest_with_no_tickets(engine, seeded):
    visit_id = make_visit(seeded, "P001")
    assert engine.live_ticket(visit_id) is None
    assert engine.latest_ticket(visit_id) is None


def test_live_and_latest_follow_the_stages(engine, seeded):
    ticket = _at_counter(engine, seeded)
    assert engine.live_ticket(ticket.visit_id).id == ticket.id
    assert engine.latest_ticket(ticket.visit_id).id == ticket.id
    next_ticket = engine.advance(ticket.id, D4)
    assert engine.live_ticket(ticket.visit_id).id == next_ticket.id
    assert engine.latest_ticket(ticket.visit_id).id == next_ticket.id


def test_finished_visit_has_a_latest_but_no_live_ticket(engine, seeded):
    ticket = _at_counter(engine, seeded, P1)
    engine.finish_visit(ticket.id)
    assert engine.live_ticket(ticket.visit_id) is None
    assert engine.latest_ticket(ticket.visit_id).state == "done"


def test_a_past_due_reservation_still_reaches_activate(engine, seeded, clock):
    """arrive finds the ticket through live_ticket, and must answer 'expired'."""
    visit_id = make_visit(seeded, "P001")
    engine.issue_ticket(visit_id, T1)
    clock.advance(minutes=45)
    assert engine.live_ticket(visit_id).state == "reserved"
    assert engine.latest_ticket(visit_id).state == "reserved"


# The sample floor on wait estimates


def _serve_one(engine, conn, clock, seconds, counter_id=T1):
    ticket = engine.issue_active(make_visit(conn, "P003"), counter_id)
    engine.call_next(counter_id)
    clock.advance(seconds=seconds)
    engine.complete(ticket.id)


def test_instant_clicks_do_not_collapse_the_estimate(engine, seeded, clock):
    for _ in range(10):
        _serve_one(engine, seeded, clock, 0)
    assert engine.avg_service_sec(T1) == 240


def test_spans_below_the_floor_are_ignored_in_the_mean(engine, seeded, clock):
    for seconds in (100, 200, 300, 400, 500):
        _serve_one(engine, seeded, clock, seconds)
    _serve_one(engine, seeded, clock, 1)
    _serve_one(engine, seeded, clock, MIN_SAMPLE_SEC - 1)
    assert engine.avg_service_sec(T1) == 300


def test_a_span_on_the_floor_counts(engine, seeded, clock):
    for _ in range(5):
        _serve_one(engine, seeded, clock, MIN_SAMPLE_SEC)
    assert engine.avg_service_sec(T1) == MIN_SAMPLE_SEC


def test_too_few_spans_left_above_the_floor_use_the_seed(engine, seeded, clock):
    for seconds in (100, 100, 100, 100, 5, 5):
        _serve_one(engine, seeded, clock, seconds)
    assert engine.avg_service_sec(T1) == 240


def test_the_floor_applies_after_the_window_is_taken(engine, seeded, clock):
    """A window of instant clicks hides older real spans, so the seed value is used."""
    for _ in range(5):
        _serve_one(engine, seeded, clock, 100)
    for _ in range(ROLLING_WINDOW):
        _serve_one(engine, seeded, clock, 1)
    assert engine.avg_service_sec(T1) == 240
