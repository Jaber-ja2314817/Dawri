"""Writes AI decisions to the event table, the audit trail judges can inspect."""

from __future__ import annotations

import sqlite3
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import datetime

from backend import db, timeutil


@dataclass(frozen=True)
class AiEvent:
    type: str
    payload: dict


def record(
    conn: sqlite3.Connection,
    visit_id: str,
    events: Iterable[AiEvent],
    at: datetime | None = None,
) -> None:
    """No transaction of its own, so the rows join the caller's."""
    stamp = timeutil.iso(at or timeutil.utcnow())
    conn.executemany(
        "INSERT INTO event (visit_id, type, payload, at) VALUES (?, ?, ?, ?)",
        [(visit_id, event.type, db.dumps(event.payload), stamp) for event in events],
    )
