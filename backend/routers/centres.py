"""Centre map route: which centres can see this patient, and how long they would wait."""

from __future__ import annotations

import sqlite3

from fastapi import APIRouter, Depends, Query

from backend import centres
from backend.ai import intake
from backend.deps import (
    ApiError,
    get_conn,
    get_engine,
    load_visit,
    patient_may_see_visit,
    require_patient,
)
from backend.queue_engine import SqliteQueueEngine

router = APIRouter(prefix="/api")

_EMERGENCY = "emergency"


def _patient_for(conn: sqlite3.Connection, subject: str, visit_id: str | None) -> str:
    """The visit's patient, so a dependent's map starts at the dependent's centre."""
    if visit_id is None:
        return subject
    visit = load_visit(conn, visit_id)
    if not patient_may_see_visit(conn, subject, visit):
        raise ApiError(403, "forbidden", "This visit belongs to someone else.")
    return visit["patient_id"]


@router.get("/centres")
def list_centres(
    service: str = "gp",
    lat: float | None = Query(default=None, ge=-90, le=90),
    lng: float | None = Query(default=None, ge=-180, le=180),
    visit_id: str | None = None,
    account: sqlite3.Row = Depends(require_patient),
    conn: sqlite3.Connection = Depends(get_conn),
    engine: SqliteQueueEngine = Depends(get_engine),
) -> dict:
    if service != _EMERGENCY and service not in intake.SERVICES:
        raise ApiError(422, "unknown_service", "We do not know this service.")
    home = centres.registered_centre(conn, _patient_for(conn, account["subject_id"], visit_id))
    home_point = None if home is None else (home["lat"], home["lng"])
    located_at = None if lat is None or lng is None else (lat, lng)
    reference = located_at or home_point

    if service == _EMERGENCY:
        effective = _EMERGENCY
        listed = centres.emergency_list(conn, reference)
        suggestion = None
    else:
        effective = centres.routed_service(service)
        registered_id = None if home is None else home["id"]
        listed = centres.rank(
            (
                centres.entry(
                    row, engine.centre_wait(row["id"], effective), located_at, registered_id
                )
                for row in centres.offering(conn, effective)
            ),
            located_at,
        )
        suggestion = centres.suggest(listed, reference)

    # A registered centre without this service is no default: reserving there is refused.
    default = next((item["id"] for item in listed if item["registered"]), None)
    return {
        "service": service,
        "effective_service": effective,
        "service_fallback": effective != service,
        "default_centre_id": default,
        "centres": listed,
        "suggestion": suggestion,
    }
