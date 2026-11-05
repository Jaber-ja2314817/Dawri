"""FastAPI dependencies and the error type routes raise."""

from __future__ import annotations

import sqlite3
from collections.abc import Iterator
from contextlib import closing

from fastapi import Depends, Query, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from backend import auth, db
from backend.queue_engine import SqliteQueueEngine

_bearer = HTTPBearer(auto_error=False)


class ApiError(Exception):
    """Rendered as {error, message} by the handler in main.py."""

    def __init__(self, status_code: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message


def get_conn() -> Iterator[sqlite3.Connection]:
    with closing(db.connect()) as conn:
        yield conn


def get_engine(request: Request) -> SqliteQueueEngine:
    return request.app.state.engine


def _valid_session(conn: sqlite3.Connection, token: str | None) -> sqlite3.Row:
    session = auth.lookup_session(conn, token) if token else None
    if session is None:
        raise ApiError(401, "unauthorized", "A valid session token is required.")
    return session


def _require_kind(session: sqlite3.Row, kind: str) -> sqlite3.Row:
    if session["kind"] != kind:
        raise ApiError(403, "forbidden", f"This route needs a {kind} session.")
    return session


def current_session(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    conn: sqlite3.Connection = Depends(get_conn),
) -> sqlite3.Row:
    return _valid_session(conn, credentials.credentials if credentials else None)


def require_patient(session: sqlite3.Row = Depends(current_session)) -> sqlite3.Row:
    return _require_kind(session, "patient")


def require_staff(session: sqlite3.Row = Depends(current_session)) -> sqlite3.Row:
    return _require_kind(session, "staff")


def stream_staff(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    token: str | None = Query(default=None),
) -> sqlite3.Row:
    """require_staff for stream routes only, because EventSource cannot send headers.

    The connection is opened here rather than through get_conn: a yield
    dependency stays open until the response ends, and a stream never ends.
    """
    with closing(db.connect()) as conn:
        session = _valid_session(conn, credentials.credentials if credentials else token)
    return _require_kind(session, "staff")
