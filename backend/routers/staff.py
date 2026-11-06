"""Staff routes: the queues, the nurse, doctor and pharmacy steps, the desk and the stats.

Every route is plain def, because several call the model and SSE must not stall.
The AI never decides order, ticket, medicine or doctor: a staff member does, here.
"""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timedelta
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field, StringConstraints, field_validator

from backend import db, mock_health, timeutil, visit_flow
from backend.adapters.queue_base import Ticket, TicketNotFound
from backend.ai import audit, handoff, intake, medicines, redflags, session
from backend.ai.audit import AiEvent
from backend.ai.intake import Complaint, IntakeParseError
from backend.ai.runtime import AiRuntime
from backend.deps import (
    ApiError,
    centre_counter,
    get_ai,
    get_conn,
    get_engine,
    own_counter,
    require_role,
    staff_member,
    staff_visit,
)
from backend.queue_engine import SqliteQueueEngine
from backend.views import ticket_view

router = APIRouter(prefix="/api")

_COLLEAGUE_NOTE = "handled by a colleague on shift"
_NONE_DETECTED = "none detected"
# The patient's own statements and what the rules saw. A nurse edit never changes them.
_LOCKED_INTAKE_FIELDS = ("denied_red_flags", "emergency", "chief_complaint_patient_words")
# A visit in the queue, or heading for it. Chat that stalled does not stop a patient who
# has since walked to the desk, and the desk has no other way to help them.
_QUEUED_STATUSES = ("reserved", "in_triage", "in_doctor", "in_pharmacy")


class IntakeEdit(BaseModel):
    fields: dict[str, Any] = Field(alias="json")


class Vitals(BaseModel):
    bp_sys: int | None = Field(default=None, ge=40, le=300)
    bp_dia: int | None = Field(default=None, ge=20, le=200)
    hr: int | None = Field(default=None, ge=20, le=300)
    temp_c: float | None = Field(default=None, ge=25, le=45, allow_inf_nan=False)
    spo2: int | None = Field(default=None, ge=40, le=100)
    weight_kg: float | None = Field(default=None, ge=0.5, le=400, allow_inf_nan=False)
    urgency: Literal["routine", "soon", "urgent"]


class HandoffConfirm(BaseModel):
    final_text: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=4000)
    ]
    doctor_id: str


class PrescriptionLine(BaseModel):
    drug_id: str
    dose: str | None = Field(default=None, max_length=100)
    frequency: str | None = Field(default=None, max_length=100)
    days: int | None = Field(default=None, ge=1, le=365)
    notes: str | None = Field(default=None, max_length=500)


class ConsultDone(BaseModel):
    prescription: list[PrescriptionLine] = Field(max_length=20)
    acknowledge_allergy: bool = False


class WalkIn(BaseModel):
    qid: str
    complaint: Complaint

    @field_validator("complaint")
    @classmethod
    def _single_line(cls, value: str) -> str:
        if len(value.splitlines()) != 1:
            raise ValueError("the complaint must be a single line")
        return value


# Shared checks


def _visit_status(conn: sqlite3.Connection, visit_id: str) -> str:
    return conn.execute("SELECT status FROM visit WHERE id = ?", (visit_id,)).fetchone()["status"]


def _require_triage(conn: sqlite3.Connection, visit_id: str) -> None:
    if _visit_status(conn, visit_id) != "in_triage":
        raise ApiError(409, "visit_not_in_triage", "This visit is not at triage.")


def _clear_draft(conn: sqlite3.Connection, visit_id: str) -> bool:
    """A draft written before a change must not reach the doctor."""
    deleted = conn.execute(
        "DELETE FROM handoff WHERE visit_id = ? AND confirmed_by IS NULL", (visit_id,)
    )
    return deleted.rowcount > 0


def _ticket_on_own_counter(
    conn: sqlite3.Connection, engine: SqliteQueueEngine, visit_id: str, staff: dict
) -> Ticket:
    """The visit's live ticket, which must stand on a counter the caller owns."""
    ticket = engine.live_ticket(visit_id)
    owner = None
    if ticket is not None:
        owner = conn.execute(
            "SELECT staff_id FROM counter WHERE id = ?", (ticket.counter_id,)
        ).fetchone()["staff_id"]
    if owner != staff["id"]:
        raise ApiError(403, "not_your_counter", "This patient is at a colleague's counter.")
    return ticket


def _medicines(conn: sqlite3.Connection, visit_id: str) -> dict:
    return {
        "en": medicines.for_visit(conn, visit_id, "en"),
        "ar": medicines.for_visit(conn, visit_id, "ar"),
    }


def _patient_or_404(conn: sqlite3.Connection, patient_id: str) -> dict:
    patient = mock_health.get_patient(conn, patient_id)
    if patient is None:
        raise ApiError(404, "patient_not_found", "This visit has no patient record.")
    return patient


# The login picker and the queues


@router.get("/staff/demo-staff")
def demo_staff(conn: sqlite3.Connection = Depends(get_conn)) -> list[dict]:
    rows = conn.execute(
        "SELECT staff.id, staff.name, staff.role, staff.clinic, staff.centre_id, "
        "centre.name_en AS centre_name_en, centre.name_ar AS centre_name_ar "
        "FROM staff JOIN centre ON centre.id = staff.centre_id "
        "ORDER BY staff.centre_id, staff.role, staff.id"
    ).fetchall()
    return [
        {
            **dict(row),
            "counters": [
                dict(counter)
                for counter in conn.execute(
                    "SELECT id, label, label_ar, stage FROM counter "
                    "WHERE staff_id = ? ORDER BY id",
                    (row["id"],),
                )
            ],
        }
        for row in rows
    ]


@router.get("/staff/me")
def staff_me(
    staff: dict = Depends(staff_member),
    conn: sqlite3.Connection = Depends(get_conn),
) -> dict:
    """What a console needs after a reload: the session token alone names none of this."""
    centre = conn.execute(
        "SELECT id, name_en, name_ar FROM centre WHERE id = ?", (staff["centre_id"],)
    ).fetchone()
    own = conn.execute(
        "SELECT id, label, label_ar, stage, prefix FROM counter WHERE staff_id = ? ORDER BY id",
        (staff["id"],),
    ).fetchall()
    everyone = conn.execute(
        "SELECT id, label, label_ar, stage FROM counter WHERE centre_id = ? ORDER BY id",
        (staff["centre_id"],),
    ).fetchall()
    return {
        "staff": staff,
        "centre": dict(centre),
        "counters": [dict(counter) for counter in own],
        "centre_counters": [dict(counter) for counter in everyone],
    }


def _waiting_min(row: dict, now: datetime) -> int:
    waited = now - timeutil.parse(row["activated_at"])
    return max(int(waited.total_seconds() // 60), 0)


def _queue_row(conn: sqlite3.Connection, row: dict, now: datetime) -> dict:
    shown = {**row, "waiting_min": _waiting_min(row, now)}
    if row["simulated"]:
        return shown
    visit = conn.execute(
        "SELECT patient_id FROM visit WHERE id = ?", (row["visit_id"],)
    ).fetchone()
    patient = _patient_or_404(conn, visit["patient_id"])
    effective = intake.load_effective(conn, row["visit_id"]) or {}
    return {
        **shown,
        "patient": {
            "name_en": patient["full_name_en"],
            "name_ar": patient["full_name_ar"],
            "age": patient["age"],
            "sex": patient["sex"],
        },
        "complaint": effective.get("chief_complaint"),
    }


@router.get("/counters/{counter_id}/queue")
def counter_queue(
    counter: sqlite3.Row = Depends(centre_counter),
    conn: sqlite3.Connection = Depends(get_conn),
    engine: SqliteQueueEngine = Depends(get_engine),
) -> dict:
    now = engine.clock()
    rows = engine.queue_snapshot(counter["id"])
    return {
        "counter": {key: counter[key] for key in ("id", "label", "label_ar", "stage", "prefix")},
        "wait": engine.counter_wait(counter["id"]),
        "tickets": [_queue_row(conn, row, now) for row in rows],
    }


@router.post("/counters/{counter_id}/call-next")
def call_next(
    counter: sqlite3.Row = Depends(own_counter),
    conn: sqlite3.Connection = Depends(get_conn),
    engine: SqliteQueueEngine = Depends(get_engine),
) -> dict:
    result = engine.call_next(counter["id"])
    return {
        "called": None if result.called is None else ticket_view(engine, conn, result.called),
        "auto_completed": [ticket.number for ticket in result.auto_completed],
        "note": _COLLEAGUE_NOTE if result.auto_completed else None,
    }


def _own_ticket(
    ticket_id: str,
    staff: dict = Depends(staff_member),
    conn: sqlite3.Connection = Depends(get_conn),
) -> str:
    row = conn.execute(
        "SELECT counter.staff_id FROM ticket JOIN counter ON counter.id = ticket.counter_id "
        "WHERE ticket.id = ?",
        (ticket_id,),
    ).fetchone()
    if row is None:
        raise TicketNotFound(f"no ticket {ticket_id}")
    if row["staff_id"] != staff["id"]:
        raise ApiError(403, "not_your_counter", "This ticket is at a colleague's counter.")
    return ticket_id


@router.post("/tickets/{ticket_id}/serve")
def serve_ticket(
    ticket_id: str = Depends(_own_ticket),
    conn: sqlite3.Connection = Depends(get_conn),
    engine: SqliteQueueEngine = Depends(get_engine),
) -> dict:
    return ticket_view(engine, conn, engine.serve(ticket_id))


@router.post("/tickets/{ticket_id}/no-show")
def no_show_ticket(
    ticket_id: str = Depends(_own_ticket),
    conn: sqlite3.Connection = Depends(get_conn),
    engine: SqliteQueueEngine = Depends(get_engine),
) -> dict:
    return ticket_view(engine, conn, engine.no_show(ticket_id))


# The visit as staff see it


def _raised_flags(conn: sqlite3.Connection, visit_id: str) -> list[str]:
    rows = conn.execute(
        "SELECT payload FROM event WHERE visit_id = ? AND type = 'redflag.hit' ORDER BY id",
        (visit_id,),
    ).fetchall()
    return list(dict.fromkeys(json.loads(row["payload"])["label"] for row in rows))


def _red_flags_checked(conn: sqlite3.Connection, visit_id: str, denied_text: str) -> str:
    """A rule that fired outranks the rest: "none detected" would be false on that visit."""
    raised = _raised_flags(conn, visit_id)
    if raised:
        return "Red flag raised: " + ", ".join(raised)
    return denied_text or _NONE_DETECTED


def _row_or_none(conn: sqlite3.Connection, table: str, visit_id: str) -> dict | None:
    row = conn.execute(f"SELECT * FROM {table} WHERE visit_id = ?", (visit_id,)).fetchone()
    return None if row is None else dict(row)


def _shown_service(visit: sqlite3.Row, view: dict) -> str | None:
    """The nurse's edit wins, as it does for the doctor suggestion."""
    effective = view["intake"] or {}
    if view["edited"] and effective.get("service"):
        return effective["service"]
    return visit["service"] or effective.get("service")


@router.get("/staff/visits/{visit_id}")
def staff_visit_detail(
    visit: sqlite3.Row = Depends(staff_visit),
    conn: sqlite3.Connection = Depends(get_conn),
    engine: SqliteQueueEngine = Depends(get_engine),
    ai: AiRuntime = Depends(get_ai),
) -> dict:
    """The nurse backstop, and the only route that returns session.staff_view.

    The patient's exact words sit beside the summary because a summary can drop a detail.
    """
    visit_id = visit["id"]
    view = session.staff_view(conn, visit_id)
    patient = _patient_or_404(conn, visit["patient_id"])
    prescription = conn.execute(
        "SELECT * FROM prescription_item WHERE visit_id = ? ORDER BY id", (visit_id,)
    ).fetchall()
    ticket = engine.live_ticket(visit_id)
    return {
        **view,
        "denied_text_en": redflags.denied_text(view["denied"], "en"),
        "denied_text_ar": redflags.denied_text(view["denied"], "ar"),
        "red_flags_checked": _red_flags_checked(conn, visit_id, view["denied_text"]),
        "red_flags_raised": _raised_flags(conn, visit_id),
        "arrived_at": visit["arrived_at"],
        "patient": {
            "id": patient["id"],
            "name": patient["full_name_en"],
            "name_en": patient["full_name_en"],
            "name_ar": patient["full_name_ar"],
            "age": patient["age"],
            "sex": patient["sex"],
            "allergies": patient["allergies"],
            "chronic": patient["chronic"],
            "active_meds": patient["active_meds"],
        },
        "vitals": _row_or_none(conn, "vitals", visit_id),
        "handoff": _row_or_none(conn, "handoff", visit_id),
        "prescription": [dict(row) for row in prescription],
        "medicines": _medicines(conn, visit_id),
        "ticket": None if ticket is None else ticket_view(engine, conn, ticket),
        "service": _shown_service(visit, view),
        "ai_mode": ai.mode,
    }


# The nurse


@router.put("/visits/{visit_id}/intake")
def edit_intake(
    body: IntakeEdit,
    staff: dict = Depends(require_role("nurse")),
    visit: sqlite3.Row = Depends(staff_visit),
    conn: sqlite3.Connection = Depends(get_conn),
    engine: SqliteQueueEngine = Depends(get_engine),
) -> dict:
    """The edit lands in edited_json. The transcript is never touched."""
    visit_id = visit["id"]
    with db.transaction(conn):
        _require_triage(conn, visit_id)
        stored = intake.load_effective(conn, visit_id)
        if stored is None:
            raise ApiError(409, "no_intake", "This visit has no intake yet.")
        sent = {
            key: value for key, value in body.fields.items() if key not in _LOCKED_INTAKE_FIELDS
        }
        try:
            edited = intake.validate_intake({**stored, **sent}).model_dump()
        except IntakeParseError as exc:
            raise ApiError(422, "invalid_intake", str(exc)) from None
        conn.execute(
            "UPDATE intake SET edited_json = ?, edited_by_staff_id = ? WHERE visit_id = ?",
            (db.dumps(edited), staff["id"], visit_id),
        )
        cleared = _clear_draft(conn, visit_id)
        changed = sorted(key for key, value in edited.items() if stored.get(key) != value)
        audit.record(
            conn,
            visit_id,
            [AiEvent("intake.edited", {"staff_id": staff["id"], "fields": changed})],
            at=engine.clock(),
        )
    return {"intake": edited, "edited": True, "draft_cleared": cleared}


def _store_vitals(
    conn: sqlite3.Connection,
    engine: SqliteQueueEngine,
    visit_id: str,
    body: Vitals,
    staff: dict,
) -> None:
    now = engine.clock()
    values = body.model_dump()
    columns = list(values)
    assignments = ", ".join(f"{name} = excluded.{name}" for name in (*columns, "nurse_id", "at"))
    with db.transaction(conn):
        _require_triage(conn, visit_id)
        conn.execute(
            f"INSERT INTO vitals (visit_id, {', '.join(columns)}, nurse_id, at) "
            f"VALUES (?, {', '.join('?' for _ in columns)}, ?, ?) "
            f"ON CONFLICT (visit_id) DO UPDATE SET {assignments}",
            (visit_id, *values.values(), staff["id"], timeutil.iso(now)),
        )
        _clear_draft(conn, visit_id)
        audit.record(
            conn,
            visit_id,
            [AiEvent("vitals.recorded", {"staff_id": staff["id"], "urgency": body.urgency})],
            at=now,
        )


@router.post("/visits/{visit_id}/vitals")
def record_vitals(
    body: Vitals,
    staff: dict = Depends(require_role("nurse")),
    visit: sqlite3.Row = Depends(staff_visit),
    conn: sqlite3.Connection = Depends(get_conn),
    engine: SqliteQueueEngine = Depends(get_engine),
) -> dict:
    """Submitting vitals serves a called ticket. Urgent ends the queue here: the nurse decides."""
    visit_id = visit["id"]
    _require_triage(conn, visit_id)
    ticket = engine.live_ticket(visit_id)
    if ticket is None or ticket.state not in ("called", "serving"):
        raise ApiError(409, "not_called", "Call this patient to the counter first.")
    if ticket.state == "called":
        ticket = engine.serve(ticket.id)
    _store_vitals(conn, engine, visit_id, body, staff)
    escalated = body.urgency == "urgent"
    if escalated:
        ticket = engine.escalate(ticket.id, "urgent_ed")
        visit_flow.leave_the_queue(engine, visit["patient_id"], visit_id)
    return {
        "status": _visit_status(conn, visit_id),
        "stage": "emergency" if escalated else "triage",
        "escalated": escalated,
        "ticket": ticket_view(engine, conn, ticket),
    }


def _draft_basis(conn: sqlite3.Connection, visit_id: str) -> tuple:
    return intake.load_effective(conn, visit_id), _row_or_none(conn, "vitals", visit_id)


@router.post("/visits/{visit_id}/handoff/draft")
def draft_handoff(
    staff: dict = Depends(require_role("nurse")),
    visit: sqlite3.Row = Depends(staff_visit),
    conn: sqlite3.Connection = Depends(get_conn),
    ai: AiRuntime = Depends(get_ai),
) -> dict:
    visit_id = visit["id"]
    _require_triage(conn, visit_id)
    basis = _draft_basis(conn, visit_id)
    if basis[1] is None:
        raise ApiError(409, "vitals_required", "Record the vitals before drafting the handoff.")
    drafted = handoff.draft_for_visit(conn, ai, visit_id)
    # The model call ran with no lock, so an edit can have landed while it was thinking.
    with db.transaction(conn):
        stale = _draft_basis(conn, visit_id) != basis
        if stale:
            _clear_draft(conn, visit_id)
    if stale:
        raise ApiError(409, "draft_stale", "The intake changed. Draft the handoff again.")
    denied = (basis[0] or {}).get("denied_red_flags") or []
    patient = _patient_or_404(conn, visit["patient_id"])
    return {
        **drafted,
        "denied_text": redflags.denied_text(denied),
        # The fixed template, for reading only. The doctor gets final_text.
        "text_ar": handoff.template(basis[0], basis[1], patient, "ar"),
    }


def _doctor_counter(conn: sqlite3.Connection, doctor_id: str, centre_id: str) -> sqlite3.Row:
    row = conn.execute(
        "SELECT staff.id, staff.name, counter.id AS counter_id FROM staff "
        "JOIN counter ON counter.staff_id = staff.id AND counter.centre_id = staff.centre_id "
        "WHERE staff.id = ? AND staff.role = 'doctor' AND staff.centre_id = ? "
        "AND counter.stage = 'doctor' ORDER BY counter.id LIMIT 1",
        (doctor_id, centre_id),
    ).fetchone()
    if row is None:
        raise ApiError(422, "unknown_doctor", "Pick a doctor on shift at this centre.")
    return row


@router.post("/visits/{visit_id}/handoff/confirm")
def confirm_handoff(
    body: HandoffConfirm,
    staff: dict = Depends(require_role("nurse")),
    visit: sqlite3.Row = Depends(staff_visit),
    conn: sqlite3.Connection = Depends(get_conn),
    engine: SqliteQueueEngine = Depends(get_engine),
) -> dict:
    """Nothing reaches the doctor without this step. The nurse picks the doctor."""
    visit_id = visit["id"]
    now = engine.clock()
    with db.transaction(conn):
        _require_triage(conn, visit_id)
        draft = _row_or_none(conn, "handoff", visit_id)
        if draft is None or not draft["ai_draft"]:
            raise ApiError(409, "draft_required", "Draft the handoff again before confirming.")
        doctor = _doctor_counter(conn, body.doctor_id, visit["centre_id"])
        ticket = engine.live_ticket(visit_id)
        if ticket is None or ticket.state != "serving":
            raise ApiError(409, "not_called", "This patient is not at the counter.")
        conn.execute(
            "UPDATE handoff SET final_text = ?, chosen_doctor_id = ?, confirmed_by = ?, at = ? "
            "WHERE visit_id = ?",
            (body.final_text, doctor["id"], staff["id"], timeutil.iso(now), visit_id),
        )
        audit.record(
            conn,
            visit_id,
            [
                AiEvent(
                    "handoff.confirmed",
                    {
                        "staff_id": staff["id"],
                        "doctor_id": doctor["id"],
                        "suggested_doctor_id": draft["suggested_doctor_id"],
                    },
                )
            ],
            at=now,
        )
    moved = engine.advance(ticket.id, doctor["counter_id"])
    return {
        "ticket": ticket_view(engine, conn, moved),
        "doctor": {"id": doctor["id"], "name": doctor["name"]},
    }


# The doctor and the pharmacist


@router.get("/staff/visits/{visit_id}/drugs")
def visit_drugs(
    staff: dict = Depends(require_role("doctor", "pharmacist")),
    visit: sqlite3.Row = Depends(staff_visit),
    conn: sqlite3.Connection = Depends(get_conn),
) -> list[dict]:
    """Judged on the visit patient's own record: a dependent's, not the guardian's."""
    patient = _patient_or_404(conn, visit["patient_id"])
    drugs = conn.execute("SELECT * FROM drug ORDER BY name_en").fetchall()
    return [
        {
            "id": drug["id"],
            "name_en": drug["name_en"],
            "name_ar": drug["name_ar"],
            "form": drug["form"],
            "default_dose": drug["default_dose"],
            "default_frequency": drug["default_frequency"],
            "default_days": drug["default_days"],
            "demo_default": drug["demo_default"],
            "allergy_warning": visit_flow.allergy_conflict(patient, dict(drug)),
        }
        for drug in drugs
    ]


@router.post("/visits/{visit_id}/consult/done")
def consult_done(
    body: ConsultDone,
    staff: dict = Depends(require_role("doctor")),
    visit: sqlite3.Row = Depends(staff_visit),
    conn: sqlite3.Connection = Depends(get_conn),
    engine: SqliteQueueEngine = Depends(get_engine),
) -> dict:
    visit_id = visit["id"]
    if visit["status"] != "in_doctor":
        raise ApiError(409, "visit_not_in_doctor", "This visit is not with a doctor.")
    ticket = _ticket_on_own_counter(conn, engine, visit_id, staff)
    items = visit_flow.resolve_items(conn, [line.model_dump() for line in body.prescription])
    patient = _patient_or_404(conn, visit["patient_id"])
    conflicts = visit_flow.allergy_conflicts(patient, items)
    if conflicts and not body.acknowledge_allergy:
        raise ApiError(
            409,
            "allergy_conflict",
            "This prescription conflicts with an allergy on record.",
            conflicts=conflicts,
        )
    moved = visit_flow.complete_consult(
        conn, engine, visit_id, ticket, items, staff["id"], overrides=conflicts
    )
    return {
        "status": _visit_status(conn, visit_id),
        "ticket": ticket_view(engine, conn, moved),
    }


@router.post("/visits/{visit_id}/dispensed")
def dispensed(
    staff: dict = Depends(require_role("pharmacist")),
    visit: sqlite3.Row = Depends(staff_visit),
    conn: sqlite3.Connection = Depends(get_conn),
    engine: SqliteQueueEngine = Depends(get_engine),
) -> dict:
    visit_id = visit["id"]
    if visit["status"] != "in_pharmacy":
        raise ApiError(409, "visit_not_in_pharmacy", "This visit is not at the pharmacy.")
    ticket = _ticket_on_own_counter(conn, engine, visit_id, staff)
    visit_flow.dispense(conn, engine, visit_id, ticket, staff["id"])
    return {"status": "completed", "medicines": _medicines(conn, visit_id)}


# The front desk


def _open_walk_in(
    conn: sqlite3.Connection, engine: SqliteQueueEngine, patient_id: str, centre_id: str
) -> str:
    """One visit at a time. Checked and inserted together, so a double click opens one.

    Today's emergency counts as live: the desk must not hand a ticket to someone the rules
    or a nurse sent to the ED. So does a visit the desk opened that has no ticket yet, as
    the ticket comes in later transactions. A phone visit in intake holds no place.
    """
    marks = ", ".join("?" for _ in _QUEUED_STATUSES)
    with db.transaction(conn):
        emergency = visit_flow.emergency_today(conn, patient_id, engine.clock())
        live = conn.execute(
            f"SELECT id FROM visit WHERE patient_id = ? AND (status IN ({marks}) "
            "OR id = ? "
            "OR (status = 'intake' AND booked_by IS NULL AND centre_id IS NOT NULL)) "
            "ORDER BY created_at DESC LIMIT 1",
            (patient_id, *_QUEUED_STATUSES, emergency),
        ).fetchone()
        if live is not None:
            raise ApiError(
                409,
                "active_visit",
                "This patient already has a visit open.",
                visit_id=live["id"],
            )
        visit_id = db.new_id("V")
        conn.execute(
            "INSERT INTO visit (id, patient_id, centre_id, status, created_at, booked_by) "
            "VALUES (?, ?, ?, 'intake', ?, NULL)",
            (visit_id, patient_id, centre_id, timeutil.iso(engine.clock())),
        )
    return visit_id


def _stop_open_visit(
    conn: sqlite3.Connection,
    engine: SqliteQueueEngine,
    visit_id: str,
    complaint: str,
    staff: dict,
) -> dict | None:
    """A patient with a visit open is still heard: the desk's one line goes to the rules.

    A hit takes them out of the queue, as one in the chat does. None leaves the desk's
    refusal standing, which is also the answer for a visit already sent to emergency.
    A refusal only names an intake visit when another desk call is still opening it, and
    that call read different words.
    """
    if _visit_status(conn, visit_id) not in (*_QUEUED_STATUSES, "intake"):
        return None
    hit = session.desk_red_flag(conn, visit_id, complaint)
    if hit is None:
        return None
    patient_id = conn.execute(
        "SELECT patient_id FROM visit WHERE id = ?", (visit_id,)
    ).fetchone()["patient_id"]
    visit_flow.leave_the_queue(engine, patient_id, visit_id)
    audit.record(
        conn, visit_id, [AiEvent("desk.red_flag", {"staff_id": staff["id"]})], at=engine.clock()
    )
    return {"emergency": True, "reply": hit.reply, "ticket": None, "visit_id": visit_id}


@router.post("/desk/walk-in")
def walk_in(
    body: WalkIn,
    staff: dict = Depends(require_role("desk", "nurse")),
    conn: sqlite3.Connection = Depends(get_conn),
    engine: SqliteQueueEngine = Depends(get_engine),
) -> dict:
    """A patient without a phone. The rules read the complaint before any ticket exists."""
    patient = mock_health.find_by_qid(conn, body.qid)
    if patient is None:
        raise ApiError(404, "unknown_qid", "No demo patient has this QID.")
    centre_id = staff["centre_id"]
    try:
        visit_id = _open_walk_in(conn, engine, patient["id"], centre_id)
    except ApiError as refused:
        stopped = _stop_open_visit(conn, engine, refused.extra["visit_id"], body.complaint, staff)
        if stopped is None:
            raise
        return stopped
    hit = session.start_walk_in(conn, visit_id, body.complaint)
    audit.record(
        conn,
        visit_id,
        [AiEvent("walk_in.registered", {"staff_id": staff["id"], "emergency": hit is not None})],
        at=engine.clock(),
    )
    if hit is not None:
        return {"emergency": True, "reply": hit.reply, "ticket": None, "visit_id": visit_id}
    ticket = engine.issue_active(visit_id, engine.triage_counter(centre_id))
    return {
        "emergency": False,
        "visit_id": visit_id,
        "ticket": ticket_view(engine, conn, ticket),
    }


# The dashboard


def _doha_window(now: datetime) -> tuple[str, str]:
    """Today as UTC stamps. Stored stamps are fixed width, so strings compare as times."""
    day = datetime.fromisoformat(timeutil.doha_day(now)).replace(tzinfo=timeutil.DOHA)
    return timeutil.iso(day), timeutil.iso(day + timedelta(days=1))


def _avg_wait_min(conn: sqlite3.Connection, centre_id: str, day: str) -> float | None:
    # An active ticket with a called_at is a no-show waiting to be called again, and its
    # called_at is older than a moved-to-back activated_at.
    rows = conn.execute(
        "SELECT activated_at, called_at FROM ticket WHERE centre_id = ? AND day = ? "
        "AND simulated = 0 AND called_at IS NOT NULL AND state <> 'active'",
        (centre_id, day),
    ).fetchall()
    if not rows:
        return None
    spans = [
        (timeutil.parse(row["called_at"]) - timeutil.parse(row["activated_at"])).total_seconds()
        for row in rows
    ]
    return round(sum(spans) / len(spans) / 60, 1)


def _visit_count(conn: sqlite3.Connection, centre_id: str, condition: str, *params: str) -> int:
    # A refill or emergency visit never picks a centre, so it counts at the registered one.
    return conn.execute(
        "SELECT COUNT(*) FROM visit JOIN patient ON patient.id = visit.patient_id "
        f"WHERE COALESCE(visit.centre_id, patient.registered_centre_id) = ? AND {condition}",
        (centre_id, *params),
    ).fetchone()[0]


def _waiting_by_stage(conn: sqlite3.Connection, centre_id: str, day: str) -> dict:
    rows = conn.execute(
        "SELECT counter.stage, COUNT(*) AS waiting FROM ticket "
        "JOIN counter ON counter.id = ticket.counter_id "
        "WHERE ticket.centre_id = ? AND ticket.day = ? AND ticket.simulated = 0 "
        "AND ticket.state = 'active' GROUP BY counter.stage",
        (centre_id, day),
    ).fetchall()
    counts = {row["stage"]: row["waiting"] for row in rows}
    return {stage: counts.get(stage, 0) for stage in ("triage", "doctor", "pharmacy")}


@router.get("/stats/{centre_id}")
def centre_stats(
    centre_id: str,
    staff: dict = Depends(staff_member),
    conn: sqlite3.Connection = Depends(get_conn),
    engine: SqliteQueueEngine = Depends(get_engine),
    ai: AiRuntime = Depends(get_ai),
) -> dict:
    """Plain counts of real rows for today in Doha. Simulated tickets never count."""
    if staff["centre_id"] != centre_id:
        raise ApiError(403, "wrong_centre", "These numbers belong to another centre.")
    now = engine.clock()
    day = timeutil.doha_day(now)
    start, end = _doha_window(now)
    created_today = "visit.created_at >= ? AND visit.created_at < ?"
    walk_ins = conn.execute(
        "SELECT COUNT(*) FROM event JOIN visit ON visit.id = event.visit_id "
        "JOIN patient ON patient.id = visit.patient_id "
        "WHERE event.type = 'walk_in.registered' AND event.at >= ? AND event.at < ? "
        "AND COALESCE(visit.centre_id, patient.registered_centre_id) = ?",
        (start, end, centre_id),
    ).fetchone()[0]
    return {
        "waiting": _waiting_by_stage(conn, centre_id, day),
        "avg_wait_min": _avg_wait_min(conn, centre_id, day),
        "completed_today": _visit_count(
            conn,
            centre_id,
            "visit.status = 'completed' AND visit.completed_at >= ? AND visit.completed_at < ?",
            start,
            end,
        ),
        "refills_deflected": _visit_count(
            conn, centre_id, f"visit.status = 'deflected_refill' AND {created_today}", start, end
        ),
        "emergencies_redirected": _visit_count(
            conn,
            centre_id,
            f"visit.status = 'redirected_emergency' AND {created_today}",
            start,
            end,
        ),
        "walk_ins": walk_ins,
        "ai_mode": ai.mode,
    }
