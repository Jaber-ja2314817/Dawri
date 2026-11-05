"""Server-sent event streams."""

from __future__ import annotations

import sqlite3
from contextlib import closing

from fastapi import APIRouter, Depends
from fastapi.responses import StreamingResponse

from backend import db, events
from backend.deps import ApiError, stream_staff

router = APIRouter(prefix="/api")

_STREAM_HEADERS = {"Cache-Control": "no-cache", "X-Accel-Buffering": "no"}


def _staff_of_counter(counter_id: str, session: sqlite3.Row = Depends(stream_staff)) -> None:
    """Plain def, so it runs in the threadpool. The connection closes before streaming."""
    with closing(db.connect()) as conn:
        counter = conn.execute(
            "SELECT centre_id FROM counter WHERE id = ?", (counter_id,)
        ).fetchone()
        staff = conn.execute(
            "SELECT centre_id FROM staff WHERE id = ?", (session["subject_id"],)
        ).fetchone()
    if counter is None:
        raise ApiError(404, "unknown_counter", "No counter has this ID.")
    if staff is None or staff["centre_id"] != counter["centre_id"]:
        raise ApiError(403, "wrong_centre", "This counter belongs to another centre.")


@router.get("/counters/{counter_id}/stream", dependencies=[Depends(_staff_of_counter)])
async def counter_stream(counter_id: str) -> StreamingResponse:
    return StreamingResponse(
        events.sse_stream(events.bus.subscribe(events.counter_channel(counter_id))),
        media_type="text/event-stream",
        headers=_STREAM_HEADERS,
    )
