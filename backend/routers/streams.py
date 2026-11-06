"""Server-sent event streams and the waiting-room display snapshot."""

from __future__ import annotations

import sqlite3
from contextlib import closing

from fastapi import APIRouter, Depends
from fastapi.responses import StreamingResponse

from backend import db, events
from backend.deps import (
    ApiError,
    get_conn,
    load_visit,
    patient_may_see_visit,
    stream_session,
    stream_staff,
)

router = APIRouter(prefix="/api")

HEARTBEAT_SEC = 15.0

_STREAM_HEADERS = {"Cache-Control": "no-cache", "X-Accel-Buffering": "no"}


def _staff_centre(conn: sqlite3.Connection, staff_id: str) -> str | None:
    staff = conn.execute("SELECT centre_id FROM staff WHERE id = ?", (staff_id,)).fetchone()
    return None if staff is None else staff["centre_id"]


def _staff_of_counter(counter_id: str, session: sqlite3.Row = Depends(stream_staff)) -> None:
    """Plain def, so it runs in the threadpool. The connection closes before streaming."""
    with closing(db.connect()) as conn:
        counter = conn.execute(
            "SELECT centre_id FROM counter WHERE id = ?", (counter_id,)
        ).fetchone()
        staff_centre = _staff_centre(conn, session["subject_id"])
    if counter is None:
        raise ApiError(404, "unknown_counter", "No counter has this ID.")
    if staff_centre != counter["centre_id"]:
        raise ApiError(403, "wrong_centre", "This counter belongs to another centre.")


def _watcher_of_visit(visit_id: str, session: sqlite3.Row = Depends(stream_session)) -> None:
    """The patient side of the visit, or staff of its centre. Plain def, as above."""
    with closing(db.connect()) as conn:
        visit = load_visit(conn, visit_id)
        if session["kind"] == "patient":
            allowed = patient_may_see_visit(conn, session["subject_id"], visit)
        else:
            allowed = _staff_centre(conn, session["subject_id"]) == visit["centre_id"]
    if not allowed:
        raise ApiError(403, "forbidden", "This visit belongs to someone else.")


def _staff_of_centre(centre_id: str, session: sqlite3.Row = Depends(stream_staff)) -> None:
    """Plain def, as above."""
    with closing(db.connect()) as conn:
        centre = conn.execute("SELECT 1 FROM centre WHERE id = ?", (centre_id,)).fetchone()
        staff_centre = _staff_centre(conn, session["subject_id"])
    if centre is None:
        raise ApiError(404, "unknown_centre", "No centre has this ID.")
    if staff_centre != centre_id:
        raise ApiError(403, "wrong_centre", "This display belongs to another centre.")


def _event_stream(channel: str) -> StreamingResponse:
    """Call this from an async def route: subscribe must run on the loop thread."""
    return StreamingResponse(
        events.sse_stream(events.bus.subscribe(channel), HEARTBEAT_SEC),
        media_type="text/event-stream",
        headers=_STREAM_HEADERS,
    )


@router.get("/counters/{counter_id}/stream", dependencies=[Depends(_staff_of_counter)])
async def counter_stream(counter_id: str) -> StreamingResponse:
    return _event_stream(events.counter_channel(counter_id))


@router.get("/visits/{visit_id}/stream", dependencies=[Depends(_watcher_of_visit)])
async def visit_stream(visit_id: str) -> StreamingResponse:
    return _event_stream(events.visit_channel(visit_id))


@router.get("/display/{centre_id}/stream", dependencies=[Depends(_staff_of_centre)])
async def display_stream(centre_id: str) -> StreamingResponse:
    return _event_stream(events.display_channel(centre_id))


def _display_counter(conn: sqlite3.Connection, counter: sqlite3.Row) -> dict:
    at_counter = conn.execute(
        "SELECT number FROM ticket WHERE counter_id = ? AND state IN ('called', 'serving') "
        "ORDER BY called_at DESC LIMIT 1",
        (counter["id"],),
    ).fetchone()
    waiting = conn.execute(
        "SELECT COUNT(*) FROM ticket WHERE counter_id = ? AND state = 'active'",
        (counter["id"],),
    ).fetchone()[0]
    return {
        "id": counter["id"],
        "label": counter["label"],
        "label_ar": counter["label_ar"],
        "stage": counter["stage"],
        "now_serving": None if at_counter is None else at_counter["number"],
        "waiting": waiting,
    }


@router.get("/display/{centre_id}", dependencies=[Depends(_staff_of_centre)])
def display_snapshot(centre_id: str, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    """What the waiting-room TV shows. Numbers only, never a patient link."""
    centre = conn.execute(
        "SELECT id, name_en, name_ar FROM centre WHERE id = ?", (centre_id,)
    ).fetchone()
    counters = conn.execute(
        "SELECT id, label, label_ar, stage FROM counter WHERE centre_id = ? ORDER BY id",
        (centre_id,),
    ).fetchall()
    return {
        "centre": dict(centre),
        "counters": [_display_counter(conn, counter) for counter in counters],
    }
