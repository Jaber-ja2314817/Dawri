"""SQLite connection, schema setup, transactions and small row helpers."""

from __future__ import annotations

import json
import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any
from uuid import uuid4

from backend import config
from backend.models import SCHEMA

# Children before parents. session is left out on purpose: it survives a reset.
_RESET_ORDER = (
    "event",
    "prescription_item",
    "handoff",
    "vitals",
    "intake",
    "ticket",
    "number_sequence",
    "visit",
    "dependent_link",
    "counter",
    "staff",
    "patient",
    "centre",
    "drug",
)


def connect(path: str | Path | None = None) -> sqlite3.Connection:
    db_file = Path(path) if path is not None else config.db_path()
    if str(db_file) == ":memory:":
        raise ValueError("a file path is required")
    db_file.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_file, isolation_level=None, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)


@contextmanager
def transaction(conn: sqlite3.Connection) -> Iterator[sqlite3.Connection]:
    conn.execute("BEGIN IMMEDIATE")
    try:
        yield conn
        conn.execute("COMMIT")
    except BaseException:
        # SQLite may already have rolled back, and a second ROLLBACK would
        # raise and hide the original error.
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise


@contextmanager
def read_snapshot(conn: sqlite3.Connection) -> Iterator[sqlite3.Connection]:
    """Several reads that see one moment. A deferred BEGIN takes no write lock.

    Under WAL the first SELECT pins a snapshot and a writer can still commit beside it, so
    this never queues behind `transaction` the way BEGIN IMMEDIATE would.
    """
    conn.execute("BEGIN")
    try:
        yield conn
    finally:
        if conn.in_transaction:
            conn.execute("COMMIT")


def reset_all(conn: sqlite3.Connection) -> None:
    with transaction(conn):
        for table in _RESET_ORDER:
            conn.execute(f"DELETE FROM {table}")
        conn.execute("DELETE FROM sqlite_sequence")


def new_id(prefix: str) -> str:
    return f"{prefix}_{uuid4().hex[:12]}"


def dumps(obj: Any) -> str:
    return json.dumps(obj, ensure_ascii=False)


def loads_list(s: str | None) -> list:
    return [] if s is None else json.loads(s)
