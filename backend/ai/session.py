"""Chat persistence: what the patient routes call.

State lives in the intake row. `transcript` holds {messages, denied, language,
last_turn}, and `json` stays '{}' until an intake is ready. The turn itself runs
outside any transaction, because a model call can take seconds and BEGIN
IMMEDIATE would block every other writer for that time.
"""

from __future__ import annotations

import json
import sqlite3
from datetime import date, datetime

from backend import db, mock_health
from backend.ai import audit, intake, receptionist, redflags, simulated
from backend.ai.audit import AiEvent
from backend.ai.receptionist import TurnResult
from backend.ai.runtime import AiRuntime

_MAX_TEXT = 2000
_RULES_ONLY = ("redirected_emergency", "deflected_refill", "reserved", "expired")
_TAKES_RULES = ("intake", *_RULES_ONLY)
# No staff member is with the patient yet, so a refused message may be half a cue.
_KEEPS_REFUSED = ("deflected_refill", "reserved", "expired")
_STAFF_ROLES = {"user": "patient", "assistant": "receptionist"}


class SessionError(Exception):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def _visit(conn: sqlite3.Connection, visit_id: str) -> sqlite3.Row:
    row = conn.execute(
        "SELECT id, patient_id, status FROM visit WHERE id = ?", (visit_id,)
    ).fetchone()
    if row is None:
        raise SessionError("visit_not_found")
    return row


def _new_state(patient: dict) -> dict:
    language = "ar" if (patient.get("preferred_lang") or "ar").startswith("ar") else "en"
    opening = {"role": "assistant", "content": simulated.OPENING[language], "slot": "complaint"}
    return {"messages": [opening], "denied": [], "language": language, "last_turn": None}


def _load_state(conn: sqlite3.Connection, visit_id: str, patient: dict) -> dict:
    row = conn.execute("SELECT transcript FROM intake WHERE visit_id = ?", (visit_id,)).fetchone()
    if row is None or not row["transcript"]:
        return _new_state(patient)
    return json.loads(row["transcript"])


def _store_state(
    conn: sqlite3.Connection, visit_id: str, state: dict, intake_json: dict | None = None
) -> None:
    """Always in the caller's transaction, so a demo reset cannot land after this check."""
    _visit(conn, visit_id)
    conn.execute(
        "INSERT INTO intake (visit_id, json, transcript) VALUES (?, '{}', ?) "
        "ON CONFLICT(visit_id) DO UPDATE SET transcript = excluded.transcript",
        (visit_id, db.dumps(state)),
    )
    if intake_json is not None:
        conn.execute(
            "UPDATE intake SET json = ?, confirmed_by_patient = 0 WHERE visit_id = ?",
            (db.dumps(intake_json), visit_id),
        )


def _sticky_emergency(state: dict) -> TurnResult:
    """An emergency never clears, so this replays it with no model and no write."""
    last = state["last_turn"] or {}
    if not last.get("emergency"):
        last = {}
    self_harm = bool(last.get("self_harm"))
    return TurnResult(
        reply=last.get("reply") or simulated.emergency_reply(state["language"], self_harm),
        done=False,
        emergency=True,
        intake=None,
        refill=None,
        denied=state["denied"],
        source=last.get("ai_source") or "rules",
        emergency_category=last.get("emergency_category"),
        self_harm=self_harm,
        language=state["language"],
        slot=None,
        events=[],
    )


def _stored_slot(result: TurnResult) -> str | None:
    ended = result.done or result.emergency or result.refill
    return simulated.NOT_A_QUESTION if ended else result.slot


def _apply_outcome(conn: sqlite3.Connection, visit_id: str, result: TurnResult) -> None:
    # The guarded UPDATE is what makes the queue refuse a ticket, so it shares a
    # transaction with the redflag event. 'reserved' is in the guard because a
    # patient with a ticket can still report a red flag, and can reserve while the
    # model is thinking. The engine then refuses to activate that ticket, and expiry
    # leaves the emergency in place. 'expired' is in it because a patient whose
    # reservation lapsed is at home with no staff present and the engine lets them
    # reserve again, so only this status stops that. A reservation can also lapse
    # while the model is thinking.
    if result.emergency:
        conn.execute(
            "UPDATE visit SET status = 'redirected_emergency' "
            "WHERE id = ? AND status IN ('intake', 'deflected_refill', 'reserved', 'expired')",
            (visit_id,),
        )
    elif result.refill:
        conn.execute(
            "UPDATE visit SET status = 'deflected_refill', service = 'refill' "
            "WHERE id = ? AND status = 'intake'",
            (visit_id,),
        )
    elif result.done:
        conn.execute(
            "UPDATE visit SET service = ? WHERE id = ? AND status = 'intake'",
            (result.intake["service"], visit_id),
        )


def _save_turn(
    conn: sqlite3.Connection, visit_id: str, patient: dict, text: str, result: TurnResult
) -> TurnResult:
    with db.transaction(conn):
        status = _visit(conn, visit_id)["status"]
        # Re-read inside the transaction: another message may have landed while
        # the model was thinking, and it may have been an emergency.
        state = _load_state(conn, visit_id, patient)
        if not result.emergency:
            # What landed meanwhile can complete a cue this turn never saw.
            result = receptionist.rule_emergency(
                text, state["messages"], patient, state["denied"], result.language
            ) or result
        if status == "redirected_emergency" and not result.self_harm:
            return _sticky_emergency(state)
        if status != "intake" and not result.emergency:
            raise SessionError("visit_not_in_intake")
        state["messages"] += [
            {"role": "user", "content": text, "slot": None},
            {"role": "assistant", "content": result.reply, "slot": _stored_slot(result)},
        ]
        merged = dict.fromkeys([*state["denied"], *result.denied])
        state["denied"] = [label for label in merged if label not in result.fired]
        state["language"] = result.language
        state["last_turn"] = {**result.to_api(), "emergency_category": result.emergency_category}
        _store_state(conn, visit_id, state, result.intake if result.done else None)
        audit.record(conn, visit_id, result.events)
        _apply_outcome(conn, visit_id, result)
    return result


def _note_refused(conn: sqlite3.Connection, visit_id: str, patient: dict, text: str) -> None:
    """Keep a refused message, so "pain" here can still pair with "chest" next time."""
    with db.transaction(conn):
        state = _load_state(conn, visit_id, patient)
        state["messages"].append({"role": "user", "content": text, "slot": None})
        _store_state(conn, visit_id, state)


def _turn_past_intake(status: str, text: str, state: dict, patient: dict) -> TurnResult | None:
    """Rules still run once intake has ended, and the model never does.

    On a closed emergency only self-harm adds anything, the supportive line. On a
    refill deflection, a reserved ticket or a lapsed reservation any hit makes the
    visit an emergency, and the engine then refuses to activate that ticket or to
    issue another. A lapsed reservation counts because that patient is at home with
    no staff present and can reserve again. None means nothing new was said, so the
    visit keeps what it had. Only _RULES_ONLY statuses come here: once the patient is
    in the centre, or the visit is over, a message is simply refused.
    """
    hit = receptionist.rule_emergency(
        text, state["messages"], patient, state["denied"], state["language"]
    )
    if hit is None or (status == "redirected_emergency" and not hit.self_harm):
        return None
    return hit


def _over_long_turn(
    conn: sqlite3.Connection, visit_id: str, message: str, state: dict, patient: dict
) -> TurnResult:
    """Too long to keep or to send to the model, but the rules read all of it.

    A cue can sit past the cut, so the cut only applies to what is stored. A hit takes
    the normal path, where _save_turn applies the closed emergency rule, and with no
    hit the message is refused as before.
    """
    hit = receptionist.rule_emergency(
        message, state["messages"], patient, state["denied"], state["language"]
    )
    if hit is None:
        raise SessionError("invalid_text")
    return _save_turn(conn, visit_id, patient, message[:_MAX_TEXT], hit)


def handle_message(
    conn: sqlite3.Connection,
    ai: AiRuntime,
    visit_id: str,
    text: str,
    on: datetime | date | None = None,
) -> TurnResult:
    visit = _visit(conn, visit_id)
    if not isinstance(text, str) or not text.strip():
        raise SessionError("invalid_text")
    over_long = len(text) > _MAX_TEXT
    if over_long and visit["status"] not in _TAKES_RULES:
        raise SessionError("invalid_text")
    patient = mock_health.get_patient(conn, visit["patient_id"], on)
    if patient is None:
        raise SessionError("visit_not_found")
    state = _load_state(conn, visit_id, patient)
    message = text.strip()
    if over_long:
        return _over_long_turn(conn, visit_id, message, state, patient)
    if visit["status"] in _RULES_ONLY:
        result = _turn_past_intake(visit["status"], message, state, patient)
        if result is not None:
            return _save_turn(conn, visit_id, patient, message, result)
    if visit["status"] == "redirected_emergency":
        return _sticky_emergency(state)
    if visit["status"] in _KEEPS_REFUSED:
        _note_refused(conn, visit_id, patient, message)
    if visit["status"] != "intake":
        raise SessionError("visit_not_in_intake")

    result = receptionist.run_turn(
        ai.llm, message, state["messages"], patient, state["denied"], state["language"]
    )
    return _save_turn(conn, visit_id, patient, message, result)


def continue_after_refill(
    conn: sqlite3.Connection, visit_id: str, on: datetime | date | None = None
) -> dict:
    """ "I still want a visit": the patient goes on as GP, with a scripted intake."""
    visit = _visit(conn, visit_id)
    if visit["status"] != "deflected_refill":
        raise SessionError("visit_not_deflected")
    patient = mock_health.get_patient(conn, visit["patient_id"], on)
    state = _load_state(conn, visit_id, patient)
    deflected = (state["last_turn"] or {}).get("refill") or {}
    medicine = deflected.get("medicine") or next(iter(patient["active_meds"]), "")
    gp_intake = simulated.gp_intake_after_refill(
        state["messages"], patient, medicine, state["denied"], state["language"]
    )
    with db.transaction(conn):
        changed = conn.execute(
            "UPDATE visit SET status = 'intake', service = 'gp' "
            "WHERE id = ? AND status = 'deflected_refill'",
            (visit_id,),
        ).rowcount
        if not changed:
            raise SessionError("visit_not_deflected")
        _store_state(conn, visit_id, state, gp_intake)
        audit.record(conn, visit_id, [AiEvent("refill.declined", {"medicine": medicine})])
    return gp_intake


def start_walk_in(
    conn: sqlite3.Connection,
    visit_id: str,
    complaint: str,
    on: datetime | date | None = None,
) -> TurnResult | None:
    """The front desk's one line stands in for the chat: the emergency turn on a hit, else None.

    Layer 1 runs on this message like any other. No opening line is stored, because the
    patient never saw one. With no hit the intake is built from the complaint alone, and
    the patient has confirmed it by saying it to the desk.
    """
    visit = _visit(conn, visit_id)
    patient = mock_health.get_patient(conn, visit["patient_id"], on)
    if patient is None:
        raise SessionError("visit_not_found")
    text = complaint.strip() if isinstance(complaint, str) else ""
    if not text:
        raise SessionError("invalid_text")
    language = _new_state(patient)["language"]
    state = {"messages": [], "denied": [], "language": language, "last_turn": None}

    result = receptionist.rule_emergency(text, [], patient, [], language)
    if result is not None:
        with db.transaction(conn):
            _store_state(conn, visit_id, state)
        return _save_turn(conn, visit_id, patient, text, result)

    denied = [hit.label_en for hit in redflags.check(text).denied]
    walk_in = intake.validate_intake(
        {
            "language": "ar-gulf" if language == "ar" else "en",
            "chief_complaint": text,
            "chief_complaint_patient_words": text,
            "service": "gp",
            "service_confidence": 0.0,
            "summary_for_nurse": f"Walk-in at the front desk: {text}",
            "questions_asked": 0,
            "denied_red_flags": denied,
        }
    )
    state["messages"].append({"role": "user", "content": text, "slot": None})
    state["denied"] = denied
    with db.transaction(conn):
        _store_state(conn, visit_id, state, walk_in.model_dump())
        conn.execute("UPDATE intake SET confirmed_by_patient = 1 WHERE visit_id = ?", (visit_id,))
        conn.execute(
            "UPDATE visit SET service = 'gp' WHERE id = ? AND status = 'intake'", (visit_id,)
        )
        if denied:
            audit.record(conn, visit_id, [AiEvent("redflag.denied", {"labels": denied})])
    return None


def desk_red_flag(
    conn: sqlite3.Connection,
    visit_id: str,
    complaint: str,
    on: datetime | date | None = None,
) -> TurnResult | None:
    """Layer 1 on what the desk heard about a visit already open: the emergency turn, or None.

    The desk is a way in after the chat has closed, so its one line is read like any other
    message. A hit is stored as a turn, so the nurse sees the words. With no hit nothing is
    stored, and the caller's refusal stands. The model is never involved.
    """
    visit = _visit(conn, visit_id)
    patient = mock_health.get_patient(conn, visit["patient_id"], on)
    if patient is None:
        raise SessionError("visit_not_found")
    state = _load_state(conn, visit_id, patient)
    text = complaint.strip()
    hit = receptionist.rule_emergency(
        text, state["messages"], patient, state["denied"], state["language"]
    )
    return None if hit is None else _save_turn(conn, visit_id, patient, text, hit)


def red_flag_past_arrival(
    conn: sqlite3.Connection,
    visit_id: str,
    message: str | None,
    on: datetime | date | None = None,
) -> TurnResult:
    """Layer 1 on a message from a patient already in the centre: the emergency turn, or a
    refusal. The chat has closed, so the model is never involved, whatever the outcome.

    The rules read all of it and the cut applies only to what is stored, as in
    _over_long_turn. Taking the visit out of the queue is the caller's step, because
    nothing under backend/ai touches the queue.
    """
    visit = _visit(conn, visit_id)
    if not isinstance(message, str) or not message.strip():
        raise SessionError("invalid_text")
    patient = mock_health.get_patient(conn, visit["patient_id"], on)
    if patient is None:
        raise SessionError("visit_not_found")
    state = _load_state(conn, visit_id, patient)
    text = message.strip()
    hit = receptionist.rule_emergency(
        text, state["messages"], patient, state["denied"], state["language"]
    )
    if hit is None:
        raise SessionError("visit_not_in_intake")
    return _save_turn(conn, visit_id, patient, text[:_MAX_TEXT], hit)


def history(conn: sqlite3.Connection, visit_id: str) -> dict:
    """Read-only, and the patient's view: model prose stays out, as it does in last_turn.

    A visit with no message yet shows the opening without creating a row. Staff read
    the visit with staff_view.
    """
    visit = _visit(conn, visit_id)
    patient = mock_health.get_patient(conn, visit["patient_id"])
    if patient is None:
        raise SessionError("visit_not_found")
    state = _load_state(conn, visit_id, patient)
    shown = receptionist.patient_intake(intake.load_effective(conn, visit_id))
    return {**state, "status": visit["status"], "intake": shown}


def staff_view(conn: sqlite3.Connection, visit_id: str, on: datetime | date | None = None) -> dict:
    """Read-only, and for staff only: the patient's exact words beside the full intake.

    A summary can drop a detail such as "with blood", and the nurse is the last safety
    layer, so turns come straight from the transcript and no summary touches them. The
    nurse's edit changes intake and never turns. Never return this to a patient route.
    """
    visit = _visit(conn, visit_id)
    patient = mock_health.get_patient(conn, visit["patient_id"], on)
    if patient is None:
        raise SessionError("visit_not_found")
    state = _load_state(conn, visit_id, patient)
    row = conn.execute(
        "SELECT confirmed_by_patient, edited_json FROM intake WHERE visit_id = ?", (visit_id,)
    ).fetchone()
    edited = row["edited_json"] if row is not None else None
    turns = [
        {"role": _STAFF_ROLES[message["role"]], "text": message["content"]}
        for message in state["messages"]
    ]
    return {
        "status": visit["status"],
        "language": state["language"],
        "turns": turns,
        "patient_words": [turn["text"] for turn in turns if turn["role"] == "patient"],
        "denied": state["denied"],
        "denied_text": redflags.denied_text(state["denied"]),
        "intake": intake.load_effective(conn, visit_id),
        "confirmed_by_patient": row is not None and bool(row["confirmed_by_patient"]),
        "edited": bool(edited and edited.strip()),
    }
