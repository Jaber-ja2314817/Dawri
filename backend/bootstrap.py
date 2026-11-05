"""Brings the database to a usable state at startup or on a demo reset."""

from __future__ import annotations

import sqlite3
from contextlib import closing

from backend import config, db, seeding, simulate
from backend.queue_engine import SqliteQueueEngine


def _seed(conn: sqlite3.Connection, simulate_load: bool | None) -> None:
    load = config.simulate_load() if simulate_load is None else simulate_load
    seeding.seed_static(conn)
    simulate.seed_queue_state(SqliteQueueEngine(), conn, load)


def startup(simulate_load: bool | None = None) -> None:
    """Create and seed the database once. A restart keeps what is there."""
    with closing(db.connect()) as conn:
        db.init_schema(conn)
        if not seeding.is_seeded(conn):
            _seed(conn, simulate_load)


def reset_demo(simulate_load: bool | None = None) -> None:
    """Back to a fresh demo. Session rows survive, so staff stay logged in."""
    with closing(db.connect()) as conn:
        db.init_schema(conn)  # A reset can be the first thing to touch a new file.
        db.reset_all(conn)
        _seed(conn, simulate_load)
