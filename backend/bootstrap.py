"""Brings the database to a usable state at startup or on a demo reset."""

from __future__ import annotations

import sqlite3
from contextlib import closing
from functools import partial
from pathlib import Path
from tempfile import TemporaryDirectory

from backend import config, db, seeding, simulate, timeutil
from backend.queue_engine import SqliteQueueEngine


def _seed(path: Path, simulate_load: bool | None) -> None:
    load = config.simulate_load() if simulate_load is None else simulate_load
    engine = SqliteQueueEngine(partial(db.connect, path), clock=timeutil.utcnow)
    with closing(db.connect(path)) as conn:
        db.init_schema(conn)
        seeding.seed_static(conn)
        simulate.seed_queue_state(engine, conn, load)


def _stale(conn: sqlite3.Connection) -> bool:
    """True unless today is the only day on record: a server left past midnight adds a day."""
    today = timeutil.doha_day(timeutil.utcnow())
    days = {row["day"] for row in conn.execute("SELECT DISTINCT day FROM number_sequence")}
    return days != {today}


def startup(simulate_load: bool | None = None) -> None:
    """Create and seed once. A same-day restart keeps everything; a new day resets."""
    with closing(db.connect()) as conn:
        db.init_schema(conn)
        if not seeding.is_seeded(conn):
            _seed(config.db_path(), simulate_load)
        stale = _stale(conn)
    if stale:
        reset_demo(simulate_load)


def reset_demo(simulate_load: bool | None = None) -> None:
    """Back to a fresh demo. Session rows survive, so staff stay logged in.

    Requests are running while this happens, and the seed takes many commits because the
    engine opens its own connections. So the new demo is built in a scratch file beside the
    live one and swapped in with one commit: a request never meets a missing staff member or
    counter, a queue half refilled, or a number sequence that has not been set yet.
    """
    path = config.db_path()
    with closing(db.connect(path)) as conn:
        db.init_schema(conn)  # A reset can be the first thing to touch a new file.
        with TemporaryDirectory(dir=path.parent, prefix=".dawri-reset-") as scratch:
            fresh = Path(scratch) / "fresh.db"
            _seed(fresh, simulate_load)
            db.reset_all(conn, fresh)
