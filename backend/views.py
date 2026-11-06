"""Response shapes shared by the patient and staff routes."""

from __future__ import annotations

import sqlite3

from backend.adapters.queue_base import Ticket
from backend.queue_engine import SqliteQueueEngine


def ticket_view(engine: SqliteQueueEngine, conn: sqlite3.Connection, ticket: Ticket) -> dict:
    """The ticket as it stands now. A reserved ticket has no number and no place."""
    position = engine.position(ticket.id)
    counter = conn.execute(
        "SELECT label, label_ar FROM counter WHERE id = ?", (ticket.counter_id,)
    ).fetchone()
    return {
        "id": ticket.id,
        "visit_id": ticket.visit_id,
        "number": position.number,
        "state": position.state,
        "centre_id": ticket.centre_id,
        "counter_id": ticket.counter_id,
        "counter": counter["label"],
        "counter_ar": counter["label_ar"],
        "people_ahead": position.people_ahead,
        "est_wait_min": position.est_wait_min,
        "expires_at": position.expires_at,
    }
