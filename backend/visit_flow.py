"""Steps shared between routers: leaving the queue on a red flag, the consult and dispensing.

Only deterministic rules here. The allergy check is a table lookup, and a doctor decides
every medicine. The demo default list is a fixed seed flag, never a model output.
"""

from __future__ import annotations

import sqlite3
from collections.abc import Iterable, Sequence
from datetime import datetime

from backend import db, timeutil
from backend.adapters.queue_base import InvalidTransition, Ticket, TicketNotFound
from backend.ai import audit
from backend.ai.audit import AiEvent
from backend.deps import ApiError
from backend.queue_engine import SqliteQueueEngine

# What stops a visit: the rules, the model, or a release by a nurse or a sibling's red flag.
# Other rows, such as consent or a later override, say nothing about when that happened.
_EMERGENCY_EVENTS = ("redflag.hit", "ai.emergency", "ticket.released")
# Arabic for the allergens the seed holds, as in frontend/src/i18n/record.ts.
_ALLERGEN_AR = {"penicillin": "البنسلين"}


def emergency_today(
    conn: sqlite3.Connection,
    patient_id: str,
    now: datetime,
    other_than: str | None = None,
) -> str | None:
    """This patient's emergency visit of the Doha day of `now`, the newest visit first.

    The day is the one the emergency happened on, as a visit opened before midnight can be
    flagged after it. created_at stands in only for a visit with none of those events. The
    look is keyed on the patient, so a guardian stays free when a dependent is stopped.
    """
    marks = ", ".join("?" for _ in _EMERGENCY_EVENTS)
    rows = conn.execute(
        "SELECT visit.id, COALESCE(MAX(event.at), visit.created_at) AS happened_at "
        f"FROM visit LEFT JOIN event ON event.visit_id = visit.id AND event.type IN ({marks}) "
        "WHERE visit.patient_id = ? AND visit.status = 'redirected_emergency' "
        "AND visit.id IS NOT ? "
        "GROUP BY visit.id ORDER BY visit.created_at DESC",
        (*_EMERGENCY_EVENTS, patient_id, other_than),
    ).fetchall()
    today = timeutil.doha_day(now)
    for row in rows:
        if timeutil.doha_day(timeutil.parse(row["happened_at"])) == today:
            return row["id"]
    return None


def leave_the_queue(engine: SqliteQueueEngine, patient_id: str, visit_id: str) -> None:
    """A red flag takes every live ticket of this patient out of the queue, in any stage.

    The no-ticket line belongs to the patient, so a ticket on a second visit goes too, and
    so does a reservation: arrival refuses one only until the Doha day ends, and its 45
    minutes can run past midnight. A dependent's visit is someone else's: the look is keyed
    on the patient. escalate rather than release, so a patient who reserved and arrived
    while the model was thinking is not left with an open visit and no ticket.

    It looks again until nothing new turns up: a ticket that moved to the next stage
    between the look and the escalate has left a new ticket behind it.
    """
    seen: set[str] = set()
    while True:
        due = [
            ticket
            for ticket in engine.live_tickets_of_patient(patient_id)
            if ticket.id not in seen
        ]
        if not due:
            return
        for ticket in due:
            seen.add(ticket.id)
            try:
                engine.escalate(ticket.id, "emergency")
            except InvalidTransition:
                pass  # It lapsed or moved a moment ago, and the next look finds where.


def _allergy_tags(drug: dict) -> list[str]:
    tags = drug.get("allergy_tags")
    return db.loads_list(tags) if isinstance(tags, str) or tags is None else list(tags)


def _allergen_ar(allergy: str) -> str:
    """An unknown term stays as stored: a clinical word is never guessed."""
    return _ALLERGEN_AR.get(allergy.strip().lower(), allergy)


def allergy_conflict(patient: dict, drug: dict) -> dict | None:
    """The first allergy on the record that this drug hits, or None."""
    tags = {tag.strip().lower() for tag in _allergy_tags(drug)}
    name = (drug.get("name_en") or "").lower()
    for allergy in patient.get("allergies") or []:
        key = allergy.strip().lower()
        if key and (key in tags or key in name):
            return {
                "allergen": allergy,
                "text_en": f"Allergy on record: {allergy}. Check before prescribing "
                f"{drug['name_en']}.",
                "text_ar": f"حساسية مسجلة: {_allergen_ar(allergy)}. "
                f"راجع قبل وصف {drug['name_ar']}.",
            }
    return None


def _filled(value: str | None, default: str | None) -> str | None:
    return (value or "").strip() or default


def resolve_items(conn: sqlite3.Connection, items: Iterable[dict]) -> list[dict]:
    """Each line against the drug table, blanks taking the drug's defaults.

    An id is required because a typed name would never meet the allergy check.
    """
    resolved = []
    for item in items:
        row = conn.execute("SELECT * FROM drug WHERE id = ?", (item.get("drug_id"),)).fetchone()
        if row is None:
            raise ApiError(422, "unknown_drug", "Pick the medicine from the drug list.")
        days = item.get("days")
        resolved.append(
            {
                "drug": dict(row),
                "dose": _filled(item.get("dose"), row["default_dose"]),
                "frequency": _filled(item.get("frequency"), row["default_frequency"]),
                "days": row["default_days"] if days is None else days,
                "notes": _filled(item.get("notes"), None),
            }
        )
    return resolved


def allergy_conflicts(patient: dict, items: Iterable[dict]) -> list[dict]:
    conflicts = []
    for item in items:
        drug = item["drug"]
        conflict = allergy_conflict(patient, drug)
        if conflict is not None:
            conflicts.append({"drug_id": drug["id"], "name_en": drug["name_en"], **conflict})
    return conflicts


def default_items(conn: sqlite3.Connection, patient: dict) -> list[dict]:
    """The demo prescription, without anything that conflicts with this patient's record."""
    rows = conn.execute("SELECT id FROM drug WHERE demo_default = 1 ORDER BY id").fetchall()
    items = resolve_items(conn, [{"drug_id": row["id"]} for row in rows])
    return [item for item in items if allergy_conflict(patient, item["drug"]) is None]


def pharmacy_counter(conn: sqlite3.Connection, centre_id: str) -> str:
    row = conn.execute(
        "SELECT id FROM counter WHERE centre_id = ? AND stage = 'pharmacy' ORDER BY id LIMIT 1",
        (centre_id,),
    ).fetchone()
    if row is None:
        raise InvalidTransition(f"centre {centre_id} has no pharmacy counter")
    return row["id"]


def _check_at_counter(conn: sqlite3.Connection, ticket: Ticket) -> None:
    row = conn.execute("SELECT state FROM ticket WHERE id = ?", (ticket.id,)).fetchone()
    if row is None:
        raise TicketNotFound(f"no ticket {ticket.id}")
    if row["state"] not in ("called", "serving"):
        raise InvalidTransition("this patient has not been called to the counter")


def complete_consult(
    conn: sqlite3.Connection,
    engine: SqliteQueueEngine,
    visit_id: str,
    ticket: Ticket,
    items: Sequence[dict],
    actor: str,
    overrides: Sequence[dict] = (),
) -> Ticket:
    """Store the prescription, then move on: to pharmacy, or out when nothing was prescribed.

    `overrides` are the allergy conflicts the doctor acknowledged, logged with the rows.
    """
    centre_id = ticket.centre_id
    pharmacy = pharmacy_counter(conn, centre_id) if items else None
    events = [AiEvent("consult.done", {"staff_id": actor, "items": len(items)})]
    if overrides:
        events.append(
            AiEvent(
                "prescription.allergy_override",
                {"staff_id": actor, "conflicts": list(overrides)},
            )
        )
    with db.transaction(conn):
        _check_at_counter(conn, ticket)
        conn.execute("DELETE FROM prescription_item WHERE visit_id = ?", (visit_id,))
        conn.executemany(
            "INSERT INTO prescription_item (visit_id, drug, dose, frequency, days, notes) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            [
                (
                    visit_id,
                    item["drug"]["id"],
                    item["dose"],
                    item["frequency"],
                    item["days"],
                    item["notes"],
                )
                for item in items
            ],
        )
        audit.record(conn, visit_id, events, at=engine.clock())
    if pharmacy is None:
        return engine.finish_visit(ticket.id)
    return engine.advance(ticket.id, pharmacy)


def dispense(
    conn: sqlite3.Connection,
    engine: SqliteQueueEngine,
    visit_id: str,
    ticket: Ticket,
    actor: str,
) -> Ticket:
    finished = engine.finish_visit(ticket.id)
    audit.record(conn, visit_id, [AiEvent("dispensed", {"staff_id": actor})], at=engine.clock())
    return finished
