"""The patient's visit, from consent to the live ticket.

Every route is plain def, because the AI layer can take seconds and must run in the
threadpool. Patient responses only ever carry receptionist.patient_intake output.
"""

from __future__ import annotations

import json
import sqlite3
import threading
from dataclasses import dataclass
from typing import Any

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field, StrictInt
from starlette.datastructures import UploadFile
from starlette.formparsers import MultiPartException, MultiPartParser

from backend import auth, centres, db, geo, timeutil, views, visit_flow
from backend.adapters.queue_base import Ticket
from backend.ai import audit, intake, medicines, receptionist, session, simulated
from backend.ai.audit import AiEvent
from backend.ai.runtime import AiRuntime
from backend.deps import (
    ApiError,
    get_ai,
    get_conn,
    get_engine,
    load_visit,
    patient_visit,
    require_patient,
)
from backend.queue_engine import RESERVATION_MINUTES, SqliteQueueEngine

router = APIRouter(prefix="/api")

GEOFENCE_M = 150
MAX_AUDIO_BYTES = 10 * 1024 * 1024
_MAX_BODY_BYTES = MAX_AUDIO_BYTES + 64 * 1024  # Room for the multipart framing.

_AT_THE_CENTRE = ("in_triage", "in_doctor", "in_pharmacy")
ACTIVE_STATUSES = ("reserved", *_AT_THE_CENTRE)
STAGES = {
    "intake": "intake",
    "redirected_emergency": "emergency",
    "deflected_refill": "refill",
    "reserved": "reserved",
    "expired": "expired",
    "in_triage": "triage",
    "in_doctor": "doctor",
    "in_pharmacy": "pharmacy",
    "completed": "completed",
    "cancelled": "cancelled",
}
_AT_A_COUNTER = ("active", "called", "serving")

STAFF_ROUTE_EN = "Speak to a member of staff at the centre, or call 999"
STAFF_ROUTE_AR = "تحدث إلى أحد الموظفين في المركز، أو اتصل بـ 999"
CHECK_IN_EN = "Check-in valid for 45 minutes"
CHECK_IN_AR = "تسجيل الوصول صالح لمدة 45 دقيقة"

# The engine keeps its own transaction, so a check beside it cannot share one. One process
# serves the app, as the event bus already assumes, so this keeps the check and the issue
# together for two sibling visits reserving at once.
_RESERVING = threading.Lock()


class VisitCreate(BaseModel):
    patient_id: str | None = None
    consent: Any = False


class IntakeConfirm(BaseModel):
    answers: dict[str, Any] | None = Field(default=None, alias="json")


class Reserve(BaseModel):
    centre_id: str


class Arrive(BaseModel):
    lat: float | None = Field(default=None, ge=-90, le=90)
    lng: float | None = Field(default=None, ge=-180, le=180)
    qr_code: str | None = None
    button: bool | None = None


class Rating(BaseModel):
    stars: StrictInt = Field(ge=1, le=5)  # Strict: "3" and true are not a rating.


# Reading uploads


class _InMemoryParser(MultiPartParser):
    """Audio is never stored, so an upload must not spill into a temp file."""

    spool_max_size = _MAX_BODY_BYTES


def _too_large() -> ApiError:
    return ApiError(413, "audio_too_large", "Audio can be at most 10 MB.")


def _invalid_text() -> ApiError:
    return ApiError(422, "invalid_text", "The message is empty or not valid text.")


def _is_multipart(request: Request) -> bool:
    return request.headers.get("content-type", "").lower().startswith("multipart/form-data")


async def _read_capped(request: Request) -> bytes | None:
    """The body, or None past the limit. Nothing beyond it is ever buffered."""
    body = bytearray()
    async for chunk in request.stream():
        body += chunk
        if len(body) > _MAX_BODY_BYTES:
            return None
    return bytes(body)


async def _audio_field(request: Request, body: bytes) -> bytes | None:
    """The `audio` file in a multipart body, or None if there is no such file."""

    async def chunks():
        yield body

    try:
        form = await _InMemoryParser(request.headers, chunks(), max_files=1, max_fields=8).parse()
    except MultiPartException:
        return None
    try:
        upload = form.get("audio")
        if not isinstance(upload, UploadFile):
            return None
        audio = await upload.read(MAX_AUDIO_BYTES + 1)
    finally:
        await form.close()
    if len(audio) > MAX_AUDIO_BYTES:
        raise _too_large()
    return audio


async def audio_input(request: Request) -> bytes:
    """The upload for /asr. As a dependency it runs after the session check.

    Starlette's own form parsing would read the whole body first, whoever sent it,
    and would spool anything past 1 MB to disk.
    """
    body = await _read_capped(request)
    if body is None:
        raise _too_large()
    audio = await _audio_field(request, body) if _is_multipart(request) else None
    if audio is None:
        raise ApiError(422, "invalid_request", "Send the recording as a multipart field `audio`.")
    return audio


@dataclass(frozen=True)
class ChatInput:
    text: str | None = None
    audio: bytes | None = None


async def chat_input(request: Request) -> ChatInput:
    """JSON {text} or multipart `audio`. Only reads: transcribing happens in the route."""
    body = await _read_capped(request)
    if _is_multipart(request):
        if body is None:
            raise _too_large()
        audio = await _audio_field(request, body)
        if audio is None:
            raise _invalid_text()
        return ChatInput(audio=audio)
    if body is None:
        raise _invalid_text()
    try:
        payload = json.loads(body)
        text = payload.get("text") if isinstance(payload, dict) else None
        if not isinstance(text, str):
            raise _invalid_text()
        text.encode("utf-8")  # A lone surrogate from a JSON escape cannot be stored.
    except (ValueError, RecursionError):
        raise _invalid_text() from None
    return ChatInput(text=text)


# Shared checks


def _refuse_after_emergency(
    conn: sqlite3.Connection, patient_id: str, other_than: str | None = None
) -> None:
    """The no-ticket red line belongs to the patient, not to one visit.

    A fresh chat would walk around it, and so would an older visit kept open.
    """
    visit_id = visit_flow.emergency_today(conn, patient_id, timeutil.utcnow(), other_than)
    if visit_id is not None:
        raise ApiError(
            409,
            "emergency_today",
            STAFF_ROUTE_EN,
            message_ar=STAFF_ROUTE_AR,
            visit_id=visit_id,
        )


def _refuse_active_visit(
    conn: sqlite3.Connection, patient_id: str, other_than: str | None = None
) -> None:
    """One queue place per patient, whichever visit holds it. A dependent has their own."""
    marks = ", ".join("?" for _ in ACTIVE_STATUSES)
    row = conn.execute(
        f"SELECT id FROM visit WHERE patient_id = ? AND status IN ({marks}) AND id IS NOT ? "
        "ORDER BY created_at DESC LIMIT 1",
        (patient_id, *ACTIVE_STATUSES, other_than),
    ).fetchone()
    if row is not None:
        raise ApiError(
            409,
            "active_visit",
            "This patient already has a visit in progress.",
            visit_id=row["id"],
        )


def _confirm_intake(
    conn: sqlite3.Connection, visit_id: str, answers: dict[str, Any] | None = None
) -> dict:
    """In one transaction, so a chat turn cannot turn the visit into an emergency between
    the status check and the write. Only `service` is honoured from the answers."""
    answers = answers or {}
    with db.transaction(conn):
        visit = load_visit(conn, visit_id)
        if visit["status"] != "intake":
            raise ApiError(409, "visit_not_in_intake", "This visit is past the chat stage.")
        effective = intake.load_effective(conn, visit_id)
        if effective is None:
            raise ApiError(409, "no_intake", "This visit has no intake yet.")
        service = visit["service"] or effective.get("service")
        if "service" in answers:
            service = answers["service"]
        if service not in intake.SERVICES:
            raise ApiError(422, "unknown_service", "We do not know this service.")
        conn.execute("UPDATE intake SET confirmed_by_patient = 1 WHERE visit_id = ?", (visit_id,))
        conn.execute("UPDATE visit SET service = ? WHERE id = ?", (service, visit_id))
        audit.record(conn, visit_id, [AiEvent("intake.confirmed", {"service": service})])
    return {
        "status": visit["status"],
        "service": service,
        "intake": receptionist.patient_intake(effective),
    }


def _confirmed(conn: sqlite3.Connection, visit_id: str) -> bool:
    row = conn.execute(
        "SELECT confirmed_by_patient FROM intake WHERE visit_id = ?", (visit_id,)
    ).fetchone()
    return row is not None and bool(row["confirmed_by_patient"])


# Starting a visit


@router.post("/visits")
def create_visit(
    body: VisitCreate | None = None,
    account: sqlite3.Row = Depends(require_patient),
    conn: sqlite3.Connection = Depends(get_conn),
) -> dict:
    body = body or VisitCreate()
    if body.consent is not True:
        raise ApiError(422, "consent_required", "Consent is needed before the chat starts.")
    subject = account["subject_id"]
    patient_id = body.patient_id or subject
    if not auth.can_access_patient(conn, subject, patient_id):
        raise ApiError(403, "forbidden", "You cannot start a visit for this patient.")
    visit_id = db.new_id("V")
    now = timeutil.utcnow()
    with db.transaction(conn):
        _refuse_active_visit(conn, patient_id)
        _refuse_after_emergency(conn, patient_id)
        conn.execute(
            "INSERT INTO visit (id, patient_id, status, created_at, booked_by) "
            "VALUES (?, ?, 'intake', ?, ?)",
            (visit_id, patient_id, timeutil.iso(now), subject),
        )
        event = AiEvent("consent.given", {"patient_id": patient_id, "booked_by": subject})
        audit.record(conn, visit_id, [event], at=now)
    chat = session.history(conn, visit_id)
    return {
        "visit_id": visit_id,
        "status": chat["status"],
        "language": chat["language"],
        "opening": chat["messages"][0]["content"],
    }


@router.get("/visits")
def list_visits(
    account: sqlite3.Row = Depends(require_patient),
    conn: sqlite3.Connection = Depends(get_conn),
) -> list[dict]:
    subject = account["subject_id"]
    rows = conn.execute(
        "SELECT * FROM visit WHERE patient_id = ? OR patient_id IN "
        "(SELECT dependent_id FROM dependent_link WHERE guardian_id = ?) "
        "ORDER BY created_at DESC, rowid DESC",
        (subject, subject),
    ).fetchall()
    return [
        {
            "visit_id": row["id"],
            "patient_id": row["patient_id"],
            "status": row["status"],
            "stage": STAGES[row["status"]],
            "service": row["service"],
            "centre_id": row["centre_id"],
            "centre": _centre_name(conn, row["centre_id"]),
            "created_at": row["created_at"],
            "completed_at": row["completed_at"],
            "active": row["status"] in ACTIVE_STATUSES,
        }
        for row in rows
    ]


# Full state


def _shown_ticket(engine: SqliteQueueEngine, visit: sqlite3.Row) -> Ticket | None:
    if visit["status"] in ("redirected_emergency", "expired"):
        return None
    ticket = engine.live_ticket(visit["id"])
    if ticket is None and visit["status"] == "completed":
        latest = engine.latest_ticket(visit["id"])
        ticket = latest if latest is not None and latest.state == "done" else None
    return ticket


def _centre_name(conn: sqlite3.Connection, centre_id: str | None) -> dict | None:
    row = conn.execute(
        "SELECT id, name_en, name_ar FROM centre WHERE id = ?", (centre_id,)
    ).fetchone()
    return None if row is None else dict(row)


def _go_to(ticket: dict | None) -> dict | None:
    if ticket is None or ticket["state"] not in _AT_A_COUNTER:
        return None
    return {"counter": ticket["counter"], "counter_ar": ticket["counter_ar"]}


def _emergency_card(conn: sqlite3.Connection, visit: sqlite3.Row, chat: dict) -> dict | None:
    if visit["status"] != "redirected_emergency":
        return None
    last = chat["last_turn"] or {}
    if not last.get("emergency"):  # A nurse sent them to emergency, not the chat.
        last = {}
    self_harm = bool(last.get("self_harm"))
    return {
        "reply": last.get("reply") or simulated.emergency_reply(chat["language"], self_harm),
        "reply_en": simulated.emergency_reply("en", self_harm),
        "reply_ar": simulated.emergency_reply("ar", self_harm),
        "self_harm": self_harm,
        "nearest_ed": centres.nearest_ed(conn, visit["patient_id"]),
    }


def _refill_card(visit: sqlite3.Row, chat: dict) -> dict | None:
    if visit["status"] != "deflected_refill":
        return None
    refill = (chat["last_turn"] or {}).get("refill")
    return None if refill is None else {"medicine": refill["medicine"]}


def _rating(conn: sqlite3.Connection, visit_id: str) -> int | None:
    row = conn.execute(
        "SELECT payload FROM event WHERE visit_id = ? AND type = 'visit.rated' "
        "ORDER BY id LIMIT 1",
        (visit_id,),
    ).fetchone()
    return None if row is None else json.loads(row["payload"])["stars"]


@router.get("/visits/{visit_id}")
def get_visit(
    visit: sqlite3.Row = Depends(patient_visit),
    conn: sqlite3.Connection = Depends(get_conn),
    engine: SqliteQueueEngine = Depends(get_engine),
) -> dict:
    engine.expire_due()
    visit = load_visit(conn, visit["id"])  # A lapsed reservation just changed its status.
    visit_id = visit["id"]
    chat = session.history(conn, visit_id)
    ticket = _shown_ticket(engine, visit)
    shown = None if ticket is None else views.ticket_view(engine, conn, ticket)
    return {
        "visit_id": visit_id,
        "patient_id": visit["patient_id"],
        "booked_by": visit["booked_by"],
        "status": visit["status"],
        "stage": STAGES[visit["status"]],
        "service": visit["service"],
        "created_at": visit["created_at"],
        "arrived_at": visit["arrived_at"],
        "completed_at": visit["completed_at"],
        "centre": _centre_name(conn, visit["centre_id"]),
        "ticket": shown,
        "intake": chat["intake"],
        "confirmed_by_patient": _confirmed(conn, visit_id),
        "chat": {"messages": chat["messages"], "language": chat["language"]},
        "medicines": {
            "en": medicines.for_visit(conn, visit_id, "en"),
            "ar": medicines.for_visit(conn, visit_id, "ar"),
        },
        "emergency": _emergency_card(conn, visit, chat),
        "go_to": _go_to(shown),
        "refill": _refill_card(visit, chat),
        "rating": _rating(conn, visit_id),
    }


# Chat and voice


@router.post("/visits/{visit_id}/chat")
def send_message(
    visit: sqlite3.Row = Depends(patient_visit),
    message: ChatInput = Depends(chat_input),
    conn: sqlite3.Connection = Depends(get_conn),
    engine: SqliteQueueEngine = Depends(get_engine),
    ai: AiRuntime = Depends(get_ai),
) -> dict:
    visit_id = visit["id"]
    transcript = None if message.audio is None else ai.asr.transcribe(message.audio)
    text = transcript or message.text
    # Read after the transcription, which takes seconds. Past arrival the rules still run,
    # and never the model: a patient in the waiting room can get worse.
    if load_visit(conn, visit_id)["status"] in _AT_THE_CENTRE:
        result = session.red_flag_past_arrival(conn, visit_id, text)
    else:
        result = session.handle_message(conn, ai, visit_id, text)
    if result.emergency:
        visit_flow.leave_the_queue(engine, visit["patient_id"], visit_id)
    return {
        **result.to_api(),
        "status": load_visit(conn, visit_id)["status"],
        "transcript": transcript,
        "nearest_ed": (
            centres.nearest_ed(conn, visit["patient_id"]) if result.emergency else None
        ),
    }


@router.post("/asr", dependencies=[Depends(require_patient)])
def asr(audio: bytes = Depends(audio_input), ai: AiRuntime = Depends(get_ai)) -> dict:
    return {"text": ai.asr.transcribe(audio)}


# After the chat


@router.post("/visits/{visit_id}/intake/confirm")
def confirm_intake(
    body: IntakeConfirm | None = None,
    visit: sqlite3.Row = Depends(patient_visit),
    conn: sqlite3.Connection = Depends(get_conn),
) -> dict:
    return _confirm_intake(conn, visit["id"], body.answers if body else None)


@router.post("/visits/{visit_id}/refill/continue")
def continue_refill(
    visit: sqlite3.Row = Depends(patient_visit),
    conn: sqlite3.Connection = Depends(get_conn),
) -> dict:
    session.continue_after_refill(conn, visit["id"])
    return _confirm_intake(conn, visit["id"], {"service": "gp"})


@router.post("/visits/{visit_id}/emergency/override")
def emergency_override(
    visit: sqlite3.Row = Depends(patient_visit),
    conn: sqlite3.Connection = Depends(get_conn),
) -> dict:
    with db.transaction(conn):
        if load_visit(conn, visit["id"])["status"] != "redirected_emergency":
            raise ApiError(409, "not_emergency", "This visit is not an emergency.")
        audit.record(conn, visit["id"], [AiEvent("emergency.override", {})])
    return {
        "status": "redirected_emergency",
        "ticket": None,
        "message": STAFF_ROUTE_EN,
        "message_ar": STAFF_ROUTE_AR,
    }


@router.post("/visits/{visit_id}/reserve")
def reserve(
    body: Reserve,
    visit: sqlite3.Row = Depends(patient_visit),
    conn: sqlite3.Connection = Depends(get_conn),
    engine: SqliteQueueEngine = Depends(get_engine),
) -> dict:
    centre = conn.execute("SELECT * FROM centre WHERE id = ?", (body.centre_id,)).fetchone()
    if centre is None:
        raise ApiError(404, "unknown_centre", "No centre has this ID.")
    if not _confirmed(conn, visit["id"]):
        raise ApiError(409, "intake_not_confirmed", "Confirm your answers first.")
    service = centres.routed_service(visit["service"])
    if service not in db.loads_list(centre["services"]):
        raise ApiError(409, "service_not_offered", "This centre does not offer this service.")
    _refuse_after_emergency(conn, visit["patient_id"], other_than=visit["id"])
    with _RESERVING:
        _refuse_active_visit(conn, visit["patient_id"], other_than=visit["id"])
        ticket = engine.issue_ticket(visit["id"], engine.triage_counter(centre["id"]))
    shown = views.ticket_view(engine, conn, ticket)
    return {
        "ticket": shown,
        "expires_at": shown["expires_at"],
        "check_in_valid_min": RESERVATION_MINUTES,
        "message": CHECK_IN_EN,
        "message_ar": CHECK_IN_AR,
    }


@router.post("/visits/{visit_id}/rating")
def rate_visit(
    body: Rating,
    visit: sqlite3.Row = Depends(patient_visit),
    conn: sqlite3.Connection = Depends(get_conn),
) -> dict:
    """An event row only: the visit, its tickets and the stats stay as they are."""
    with db.transaction(conn):
        if load_visit(conn, visit["id"])["status"] != "completed":
            raise ApiError(409, "visit_not_completed", "Only a completed visit can be rated.")
        if _rating(conn, visit["id"]) is not None:
            raise ApiError(409, "already_rated", "This visit has already been rated.")
        audit.record(conn, visit["id"], [AiEvent("visit.rated", {"stars": body.stars})])
    return {"rating": body.stars}


# Arriving


def _arrival_method(body: Arrive) -> str:
    if (body.lat is None) != (body.lng is None):
        raise ApiError(422, "arrival_method_required", "Send both lat and lng.")
    methods = [
        method
        for method, used in (
            ("geofence", body.lat is not None),
            ("qr", body.qr_code is not None),
            ("button", body.button is True),
        )
        if used
    ]
    if len(methods) != 1:
        raise ApiError(
            422,
            "arrival_method_required",
            "Send exactly one of a location, a door code or the button.",
        )
    return methods[0]


def _check_at_centre(
    conn: sqlite3.Connection, body: Arrive, method: str, centre_id: str
) -> None:
    if method == "geofence":
        centre = conn.execute("SELECT lat, lng FROM centre WHERE id = ?", (centre_id,)).fetchone()
        distance = geo.distance_m(body.lat, body.lng, centre["lat"], centre["lng"])
        if distance > GEOFENCE_M:
            raise ApiError(
                409, "too_far", "You are not at the centre yet.", distance_m=round(distance)
            )
    elif method == "qr" and body.qr_code != f"DOOR-{centre_id}":
        raise ApiError(409, "wrong_door", "This door code belongs to another centre.")


@router.post("/visits/{visit_id}/arrive")
def arrive(
    body: Arrive | None = None,
    visit: sqlite3.Row = Depends(patient_visit),
    conn: sqlite3.Connection = Depends(get_conn),
    engine: SqliteQueueEngine = Depends(get_engine),
) -> dict:
    body = body or Arrive()
    method = _arrival_method(body)
    engine.expire_due()
    ticket = engine.live_ticket(visit["id"]) or engine.latest_ticket(visit["id"])
    if ticket is None:
        raise ApiError(409, "no_reservation", "This visit has no reservation.")
    _refuse_after_emergency(conn, visit["patient_id"], other_than=visit["id"])
    if ticket.state == "reserved":  # Any other ticket: the engine gives the real reason.
        _check_at_centre(conn, body, method, ticket.centre_id)
    activated = engine.activate(ticket.id, method)
    shown = views.ticket_view(engine, conn, activated)
    return {"ticket": shown, "go_to": _go_to(shown)}
