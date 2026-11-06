"""FastAPI dependencies and the error type routes raise."""

from __future__ import annotations

import sqlite3
from collections.abc import Callable, Iterator
from contextlib import closing
from typing import Any

from fastapi import Depends, Query, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from backend import auth, db
from backend.ai.runtime import AiRuntime
from backend.queue_engine import SqliteQueueEngine

_bearer = HTTPBearer(auto_error=False)


class ApiError(Exception):
    """Rendered as {error, message, **extra} by the handler in main.py."""

    def __init__(self, status_code: int, code: str, message: str, **extra: Any) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.extra = extra


def get_conn() -> Iterator[sqlite3.Connection]:
    with closing(db.connect()) as conn:
        yield conn


def get_engine(request: Request) -> SqliteQueueEngine:
    return request.app.state.engine


def get_ai(request: Request) -> AiRuntime:
    return request.app.state.ai


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


def stream_session(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    token: str | None = Query(default=None),
) -> sqlite3.Row:
    """stream_staff for any kind of session. The same connection rule applies."""
    with closing(db.connect()) as conn:
        return _valid_session(conn, credentials.credentials if credentials else token)


def staff_member(
    session: sqlite3.Row = Depends(require_staff),
    conn: sqlite3.Connection = Depends(get_conn),
) -> dict:
    staff = conn.execute(
        "SELECT id, name, role, clinic, centre_id FROM staff WHERE id = ?",
        (session["subject_id"],),
    ).fetchone()
    if staff is None:
        raise ApiError(401, "unauthorized", "A valid session token is required.")
    return dict(staff)


def require_role(*roles: str) -> Callable[..., dict]:
    def dependency(staff: dict = Depends(staff_member)) -> dict:
        if staff["role"] not in roles:
            raise ApiError(403, "wrong_role", "This action is for a different staff role.")
        return staff

    return dependency


def load_visit(conn: sqlite3.Connection, visit_id: str) -> sqlite3.Row:
    visit = conn.execute("SELECT * FROM visit WHERE id = ?", (visit_id,)).fetchone()
    if visit is None:
        raise ApiError(404, "visit_not_found", "No visit has this ID.")
    return visit


def patient_may_see_visit(conn: sqlite3.Connection, subject: str, visit: sqlite3.Row) -> bool:
    """The patient, their guardian, or whoever booked the visit."""
    return auth.can_access_patient(conn, subject, visit["patient_id"]) or (
        visit["booked_by"] == subject
    )


def patient_visit(
    visit_id: str,
    session: sqlite3.Row = Depends(require_patient),
    conn: sqlite3.Connection = Depends(get_conn),
) -> sqlite3.Row:
    visit = load_visit(conn, visit_id)
    if not patient_may_see_visit(conn, session["subject_id"], visit):
        raise ApiError(403, "forbidden", "This visit belongs to someone else.")
    return visit


def staff_visit(
    visit_id: str,
    staff: dict = Depends(staff_member),
    conn: sqlite3.Connection = Depends(get_conn),
) -> sqlite3.Row:
    visit = load_visit(conn, visit_id)
    if visit["centre_id"] != staff["centre_id"]:
        raise ApiError(403, "wrong_centre", "This visit belongs to another centre.")
    return visit


def load_counter(conn: sqlite3.Connection, counter_id: str) -> sqlite3.Row:
    counter = conn.execute("SELECT * FROM counter WHERE id = ?", (counter_id,)).fetchone()
    if counter is None:
        raise ApiError(404, "unknown_counter", "No counter has this ID.")
    return counter


def centre_counter(
    counter_id: str,
    staff: dict = Depends(staff_member),
    conn: sqlite3.Connection = Depends(get_conn),
) -> sqlite3.Row:
    """For reads: any counter at the staff member's centre."""
    counter = load_counter(conn, counter_id)
    if counter["centre_id"] != staff["centre_id"]:
        raise ApiError(403, "wrong_centre", "This counter belongs to another centre.")
    return counter


def own_counter(
    counter_id: str,
    staff: dict = Depends(staff_member),
    conn: sqlite3.Connection = Depends(get_conn),
) -> sqlite3.Row:
    """For actions: only the staff member's own counter."""
    counter = load_counter(conn, counter_id)
    if counter["staff_id"] != staff["id"]:
        raise ApiError(403, "not_your_counter", "This counter belongs to a colleague.")
    return counter
