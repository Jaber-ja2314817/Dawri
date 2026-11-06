"""Demo routes: reset the demo, and skip a confirmed visit through to the end."""

from __future__ import annotations

import sqlite3

from fastapi import APIRouter, Depends

from backend import bootstrap, config, events, mock_health, timeutil, visit_flow
from backend.adapters.queue_base import Ticket
from backend.ai import audit, medicines
from backend.ai.audit import AiEvent
from backend.deps import ApiError, get_conn, get_engine, staff_member, staff_visit
from backend.queue_engine import SqliteQueueEngine

router = APIRouter(prefix="/api")

_AT_COUNTER = ("called", "serving")


def _ids(conn: sqlite3.Connection, table: str) -> list[str]:
    return [row["id"] for row in conn.execute(f"SELECT id FROM {table}")]


@router.post("/demo/reset")
def reset(
    staff: dict = Depends(staff_member),
    conn: sqlite3.Connection = Depends(get_conn),
) -> dict:
    """Sessions survive, and open consoles refetch on the event sent after the reset."""
    visit_ids = _ids(conn, "visit")
    bootstrap.reset_demo()
    now = timeutil.utcnow()
    audit.record(conn, None, [AiEvent("demo.reset", {"staff_id": staff["id"]})], at=now)
    channels = [
        *(events.counter_channel(counter_id) for counter_id in _ids(conn, "counter")),
        *(events.display_channel(centre_id) for centre_id in _ids(conn, "centre")),
        *(events.visit_channel(visit_id) for visit_id in visit_ids),
    ]
    for channel in channels:
        events.bus.publish(channel, {"type": "demo.reset"})
    return {"ok": True, "simulate_load": config.simulate_load(), "reset_at": timeutil.iso(now)}


def _blocked_here(rows: list[dict], visit_id: str) -> bool:
    """Someone real stands before this visit on its own counter. Simulated rows do not count."""
    for row in rows:
        if row["visit_id"] == visit_id:
            return False
        if row["state"] in _AT_COUNTER or not row["simulated"]:
            return True
    return False


def _blocked_on_joining(rows: list[dict], priority: int) -> bool:
    """A newcomer goes behind every real ticket of its own priority or above."""
    return any(
        row["state"] in _AT_COUNTER or (not row["simulated"] and row["priority"] >= priority)
        for row in rows
    )


def _to_counter(engine: SqliteQueueEngine, ticket: Ticket, steps: list[dict]) -> Ticket:
    """Call this ticket through the normal engine, unless staff already have."""
    if ticket.state in _AT_COUNTER:
        return ticket
    result = engine.call_next(ticket.counter_id)
    called = result.called
    if called is None or called.visit_id != ticket.visit_id:  # Someone moved first.
        raise ApiError(409, "not_next_in_queue", "Another patient is next at this counter.")
    steps.append(
        {
            "step": "called",
            "number": called.number,
            "counter_id": called.counter_id,
            "auto_completed": [done.number for done in result.auto_completed],
        }
    )
    return called


@router.post("/demo/fast-forward/{visit_id}")
def fast_forward(
    staff: dict = Depends(staff_member),
    visit: sqlite3.Row = Depends(staff_visit),
    conn: sqlite3.Connection = Depends(get_conn),
    engine: SqliteQueueEngine = Depends(get_engine),
) -> dict:
    """Walks doctor and pharmacy through the normal engine. It never skips a real patient."""
    visit_id = visit["id"]
    at_doctor = visit["status"] == "in_doctor"
    ticket = engine.live_ticket(visit_id)
    if visit["status"] not in ("in_doctor", "in_pharmacy") or ticket is None:
        raise ApiError(409, "visit_not_ready", "This visit has no doctor or pharmacy step left.")
    patient = mock_health.get_patient(conn, visit["patient_id"])
    items = visit_flow.default_items(conn, patient) if at_doctor else []

    # Every check comes before the first change.
    blocked = _blocked_here(engine.queue_snapshot(ticket.counter_id), visit_id)
    if items:
        pharmacy = visit_flow.pharmacy_counter(conn, visit["centre_id"])
        blocked = blocked or _blocked_on_joining(engine.queue_snapshot(pharmacy), ticket.priority)
    if blocked:
        raise ApiError(409, "not_next_in_queue", "Another patient is next at this counter.")

    actor = f"demo:{staff['id']}"
    steps: list[dict] = []
    if at_doctor:
        ticket = _to_counter(engine, ticket, steps)
        steps.append({"step": "consult_done", "number": ticket.number, "items": len(items)})
        ticket = visit_flow.complete_consult(conn, engine, visit_id, ticket, items, actor)
    if ticket.state != "done":
        ticket = _to_counter(engine, ticket, steps)
        visit_flow.dispense(conn, engine, visit_id, ticket, actor)
        steps.append({"step": "dispensed", "number": ticket.number})
    audit.record(
        conn,
        visit_id,
        [AiEvent("demo.fast_forward", {"staff_id": staff["id"], "steps": steps})],
        at=engine.clock(),
    )
    return {
        "status": "completed",
        "steps": steps,
        "medicines": {
            "en": medicines.for_visit(conn, visit_id, "en"),
            "ar": medicines.for_visit(conn, visit_id, "ar"),
        },
    }
