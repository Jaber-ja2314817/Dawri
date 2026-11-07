"""The nurse-to-doctor handoff: a model draft checked hard, or a fixed template.

The draft is free text and sits under a 6 s budget, so there is no retry. Any
doubt serves the template, which holds only what is stored and says 'not
recorded' for the rest. The nurse confirms either one in Phase 3.
"""

from __future__ import annotations

import hashlib
import re
import sqlite3
from collections.abc import Sequence
from dataclasses import asdict, dataclass, field
from datetime import date, datetime
from typing import Any

from backend import db, mock_health
from backend.ai import audit, doctors, filters, redflags
from backend.ai import intake as intake_store
from backend.ai.audit import AiEvent
from backend.ai.llm import Llm, LlmError
from backend.ai.runtime import AiRuntime
from backend.ai.text import (
    Token,
    has_arabic,
    is_negated,
    normalise,
    phrase_starts,
    phrase_tokens,
    tokenise,
)

MIN_LINES = 3
MAX_LINES = 5

_NUMBER = re.compile(r"\d+(?:[.٫]\d+)?")
_OXYGEN_LABEL = re.compile(r"\b(?:spo2|o2)\b")  # A name, not a reading of 2.
_SEVERITY_SCALE = re.compile(r"(\d+)\s*(?:/|out of|من)\s*10(?!\d|[.٫]\d)")

SYSTEM_PROMPT = """You write the nurse-to-doctor handoff at a Qatar primary health centre.

The user message is JSON with the confirmed intake, the vitals and the patient record.
Write a 3-5 line English summary, one item per line, in this fixed order:
1. who (name, age, sex)
2. complaint and duration
3. relevant history and allergies
4. vitals
5. patient concerns

Rules:
- Use only the facts in the JSON. Never invent a value. A missing vital is "not recorded".
- List every allergy in the record by name.
- If denied_red_flags is not empty, write "Patient denied:" and the items on the last line.
- No differential diagnosis. Do not name a likely condition.
- No treatment advice, no doses other than those on the record, no queue numbers.
- Output only the summary lines."""

# summary_for_nurse and the patient's words are left out: a nurse edit to the
# complaint does not rewrite them, and the doctor must see the edit alone.
_INTAKE_FIELDS = (
    "chief_complaint",
    "duration",
    "severity_0_10",
    "associated",
    "self_medication",
    "patient_concerns",
    "denied_red_flags",
)
_VITAL_FIELDS = ("bp_sys", "bp_dia", "hr", "temp_c", "spo2", "weight_kg", "urgency")

_WORDS = {
    "en": {
        "comma": ", ",
        "complaint": "Complaint",
        "not_recorded": "not recorded",
        "duration_missing": "duration not recorded",
        "severity": "severity",
        "severity_missing": "severity not recorded",
        "history": "History",
        "none_on_record": "none on record",
        "active_meds": "Active meds",
        "allergies": "Allergies",
        "took": "Took",
        "none_reported": "none reported",
        "vitals": "Vitals",
        "bp": "BP",
        "hr": "HR",
        "temp": "Temp",
        "temp_unit": " C",
        "temp_missing": "not recorded",
        "spo2": "SpO2",
        "weight": "Weight",
        "weight_unit": " kg",
        "urgency": "Urgency",
        "concerns": "Concerns",
        "none_stated": "none stated",
    },
    "ar": {
        "comma": "، ",
        "complaint": "الشكوى",
        "not_recorded": "غير مسجل",
        "duration_missing": "المدة غير مسجلة",
        "severity": "الشدة",
        "severity_missing": "الشدة غير مسجلة",
        "history": "السوابق",
        "none_on_record": "لا يوجد في السجل",
        "active_meds": "الأدوية الحالية",
        "allergies": "الحساسية",
        "took": "تناول",
        "none_reported": "لم يذكر شيئاً",
        "vitals": "العلامات الحيوية",
        "bp": "الضغط",
        "hr": "النبض",
        "temp": "الحرارة",
        "temp_unit": " م",
        "temp_missing": "غير مسجلة",
        "spo2": "الأكسجين",
        "weight": "الوزن",
        "weight_unit": " كغ",
        "urgency": "درجة الاستعجال",
        "concerns": "المخاوف",
        "none_stated": "لم يذكر شيئاً",
    },
}
_URGENCY_AR = {"routine": "روتيني", "soon": "قريباً", "urgent": "عاجل"}
_SEX_AR = {"F": "أنثى", "M": "ذكر"}


class HandoffError(Exception):
    """A handoff that cannot start. str(e) is a short code for the route to map."""

    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


@dataclass
class HandoffDraft:
    text: str
    source: str  # 'model' or 'simulated'
    events: list[AiEvent] = field(default_factory=list)


def _clean(value: Any) -> str:
    """One line with no end stop, because a stray newline would break the line count."""
    return "" if value is None else " ".join(str(value).split()).rstrip(" .")


def _items(value: Any) -> list[str]:
    values = value if isinstance(value, (list, tuple)) else [value]
    return [text for text in (_clean(item) for item in values) if text]


def _number(value: Any) -> str:
    return f"{value:g}" if isinstance(value, (int, float)) else str(value)


def _who_line(patient: dict, ar: bool) -> str:
    age, sex = patient.get("age"), patient.get("sex")
    if ar:
        name = patient.get("full_name_ar") or patient.get("full_name_en")
        years = None if age is None else f"{age} سنة"
        return "، ".join(part for part in (name, years, _SEX_AR.get(sex)) if part) + "."
    who = f"{'' if age is None else age}{sex or ''}"
    return ", ".join(part for part in (patient.get("full_name_en"), who) if part) + "."


# The seed's record terms, so an Arabic card does not break into English mid-line.
_RECORD_AR = {
    "hypertension": "ارتفاع ضغط الدم",
    "type 2 diabetes": "السكري من النوع الثاني",
    "penicillin": "البنسلين",
    "amlodipine 5 mg once daily": "أملوديبين 5 ملغ مرة يوميا",
    "metformin 500 mg twice daily": "ميتفورمين 500 ملغ مرتين يوميا",
}
_DURATION_AR = {
    "since yesterday": "من أمس",
    "since today": "من اليوم",
    "since this morning": "من الصباح",
}
# Singular, then the plural Arabic uses for 3 to 10.
_DURATION_UNITS_AR = {
    "hour": ("ساعة", "ساعات"), "hours": ("ساعة", "ساعات"),
    "day": ("يوم", "أيام"), "days": ("يوم", "أيام"),
    "week": ("أسبوع", "أسابيع"), "weeks": ("أسبوع", "أسابيع"),
    "month": ("شهر", "أشهر"), "months": ("شهر", "أشهر"),
}


def _duration_ar(duration: str) -> str:
    """A form we know reads in Arabic. Anything else stays as stored."""
    text = duration.strip().lower()
    if text in _DURATION_AR:
        return _DURATION_AR[text]
    parts = text.split()
    if len(parts) == 2 and parts[0].isdigit() and parts[1] in _DURATION_UNITS_AR:
        singular, plural = _DURATION_UNITS_AR[parts[1]]
        return f"{parts[0]} {plural if 3 <= int(parts[0]) <= 10 else singular}"
    return duration


def _complaint_line(intake: dict, w: dict, ar: bool = False) -> str:
    value = intake.get("severity_0_10")
    severity = w["severity_missing"] if value is None else f"{w['severity']} {value}/10"
    complaint = _clean(intake.get("chief_complaint"))
    duration = _clean(intake.get("duration"))
    if ar:
        words = _clean(intake.get("chief_complaint_patient_words"))
        if words and has_arabic(words):
            complaint = words
        duration = _duration_ar(duration) if duration else duration
    parts = [
        complaint or w["not_recorded"],
        duration or w["duration_missing"],
        severity,
    ]
    return f"{w['complaint']}: {w['comma'].join(parts)}."


def _history_line(intake: dict, patient: dict, w: dict, ar: bool = False) -> str:
    comma = w["comma"]

    def record(key: str) -> list[str]:
        items = _items(patient.get(key))
        return [_RECORD_AR.get(item, item) for item in items] if ar else items

    chronic = record("chronic")
    meds = record("active_meds")
    allergies = record("allergies")
    took = _items(intake.get("self_medication"))
    sentences = [f"{w['history']}: {comma.join(chronic) or w['none_on_record']}."]
    if meds:
        sentences.append(f"{w['active_meds']}: {comma.join(meds)}.")
    sentences.append(f"{w['allergies']}: {comma.join(allergies) or w['none_on_record']}.")
    sentences.append(f"{w['took']}: {comma.join(took) or w['none_reported']}.")
    return " ".join(sentences)


def _vitals_line(vitals: dict | None, ar: bool, w: dict) -> str:
    missing = w["not_recorded"]
    if vitals is None:
        return f"{w['vitals']}: {missing}."

    def reading(key: str, column: str, unit: str = "", absent: str = missing) -> str:
        value = vitals.get(column)
        return f"{w[key]} {absent if value is None else _number(value) + unit}"

    pressure = [vitals.get("bp_sys"), vitals.get("bp_dia")]
    shown = missing
    if any(value is not None for value in pressure):
        shown = "/".join(missing if value is None else _number(value) for value in pressure)
    readings = [
        f"{w['bp']} {shown}",
        reading("hr", "hr"),
        reading("temp", "temp_c", w["temp_unit"], w["temp_missing"]),
        reading("spo2", "spo2", "%"),
        reading("weight", "weight_kg", w["weight_unit"]),
    ]
    urgency = _clean(vitals.get("urgency")) or missing
    urgency = _URGENCY_AR.get(urgency, urgency) if ar else urgency
    return f"{w['vitals']}: {w['comma'].join(readings)}. {w['urgency']}: {urgency}."


def _concerns_line(intake: dict, lang: str, w: dict) -> str:
    concerns = _clean(intake.get("patient_concerns")) or w["none_stated"]
    line = f"{w['concerns']}: {concerns}."
    denied = redflags.denied_text(_items(intake.get("denied_red_flags")), lang)
    return f"{line} {denied}." if denied else line


def template(intake: dict, vitals: dict | None, patient: dict, lang: str = "en") -> str:
    """Five lines in the vault's order. Free text stays as stored in either language."""
    ar = lang.startswith("ar")
    w = _WORDS["ar" if ar else "en"]
    return "\n".join(
        (
            _who_line(patient, ar),
            _complaint_line(intake, w, ar),
            _history_line(intake, patient, w, ar),
            _vitals_line(vitals, ar, w),
            _concerns_line(intake, lang, w),
        )
    )


def _payload(intake: dict, vitals: dict | None, patient: dict) -> dict:
    return {
        "intake": {key: intake.get(key) for key in _INTAKE_FIELDS},
        "vitals": None if vitals is None else {key: vitals.get(key) for key in _VITAL_FIELDS},
        "record": {
            "name": patient.get("full_name_en"),
            "age": patient.get("age"),
            "sex": patient.get("sex"),
            "allergies": _items(patient.get("allergies")),
            "chronic": _items(patient.get("chronic")),
            "active_meds": _items(patient.get("active_meds")),
        },
    }


def _messages(payload: dict) -> list[dict]:
    return [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": db.dumps(payload)},
    ]


def _states_allergy(tokens: Sequence[Token], allergy: str) -> bool:
    """Named and not negated. "No penicillin allergy" is worse than leaving it out."""
    starts = phrase_starts(tokens, phrase_tokens(allergy))
    return any(not is_negated(tokens, start) for start in starts)


def _numbers_in(text: str) -> set[float]:
    return {float(number.replace("٫", ".")) for number in _NUMBER.findall(text)}


def _payload_numbers(value: Any) -> set[float]:
    """Every number in the values. Keys hold no facts, severity_0_10 least of all."""
    if isinstance(value, dict):
        value = list(value.values())
    if isinstance(value, list):
        return {number for item in value for number in _payload_numbers(item)}
    if value is None or isinstance(value, bool):
        return set()
    return _numbers_in(normalise(str(value)))


def _draft_numbers(lines: list[str], severity: Any) -> set[float]:
    """The numbers the draft states. Its list markers and the 10 of '6/10' are not facts.

    The prompt numbers the lines, so a model may too. A marker counts only on its
    own line, and the 10 only beside the recorded severity.
    """
    unmarked = [
        re.sub(rf"^{position}[.)]\s+", "", normalise(line))
        for position, line in enumerate(lines, start=1)
    ]
    text = _OXYGEN_LABEL.sub(" ", "\n".join(unmarked))
    text = _SEVERITY_SCALE.sub(
        lambda found: found[1] if found[1] == str(severity) else found[0], text
    )
    return _numbers_in(text)


def _rejection(
    lines: list[str], intake: dict, patient: dict, allowed_meds: Sequence[str], payload: dict
) -> str | None:
    if not MIN_LINES <= len(lines) <= MAX_LINES:
        return "line_count"
    text = "\n".join(lines)
    allergies = _items(patient.get("allergies"))
    verdict = filters.check_handoff(
        text,
        chronic=_items(patient.get("chronic")),
        allergies=allergies,
        allowed_meds=(*_items(patient.get("active_meds")), *allowed_meds),
        self_medication=_items(intake.get("self_medication")),
    )
    if not verdict.ok:
        return "banned_output"
    tokens = tokenise(text)
    if not all(_states_allergy(tokens, allergy) for allergy in allergies):
        return "missing_allergy"
    known = _payload_numbers([payload, *allowed_meds])
    if _draft_numbers(lines, intake.get("severity_0_10")) - known:
        return "invented_number"
    return None


def _with_denied(lines: list[str], intake: dict) -> str:
    """The denied line is a fact the doctor gets whether or not the model wrote it."""
    denied = redflags.denied_text(_items(intake.get("denied_red_flags")))
    text = "\n".join(lines)
    if not denied or normalise(denied) in normalise(text):
        return text
    return "\n".join((*lines[:-1], f"{lines[-1].rstrip(' .')}. {denied}."))


def _served(text: str, source: str, reason: str | None = None) -> HandoffDraft:
    events = []
    if reason is not None:
        events.append(
            AiEvent(
                "ai.fallback",
                {"surface": "handoff", "reason": reason, "mode": "real", "served_by": "simulated"},
            )
        )
    events.append(AiEvent("handoff.drafted", {"source": source}))
    return HandoffDraft(text=text, source=source, events=events)


def draft(
    llm: Llm,
    intake: dict,
    vitals: dict | None,
    patient: dict,
    allowed_meds: Sequence[str] = (),
) -> HandoffDraft:
    fixed = template(intake, vitals, patient)
    if llm.mode != "real":
        return _served(fixed, "simulated")
    payload = _payload(intake, vitals, patient)
    try:
        reply = llm.chat(_messages(payload))
    except LlmError:
        return _served(fixed, "simulated", "model_error")

    lines = [line.strip() for line in reply.splitlines() if line.strip()]
    reason = _rejection(lines, intake, patient, allowed_meds, payload)
    if reason is not None:
        return _served(fixed, "simulated", reason)
    return _served(_with_denied(lines, intake), "model")


def _service(conn: sqlite3.Connection, visit: sqlite3.Row, visit_id: str, intake: dict) -> str:
    """The nurse's edit wins. Unedited, the visit's service beats the intake's guess."""
    row = conn.execute("SELECT edited_json FROM intake WHERE visit_id = ?", (visit_id,)).fetchone()
    if row is None:  # A demo reset removed it after draft_for_visit read the intake.
        raise HandoffError("no_intake")
    edited = bool(row["edited_json"] and row["edited_json"].strip())
    if edited and intake.get("service"):
        return intake["service"]
    return visit["service"] or intake.get("service") or "other"


def draft_id(text: str) -> str:
    """Names one stored draft, so a nurse can only confirm the draft they read."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def draft_for_visit(
    conn: sqlite3.Connection,
    ai: AiRuntime,
    visit_id: str,
    on: datetime | date | None = None,
    gender_pref: str | None = None,
) -> dict:
    visit = conn.execute(
        "SELECT patient_id, centre_id, service FROM visit WHERE id = ?", (visit_id,)
    ).fetchone()
    intake = intake_store.load_effective(conn, visit_id)
    if visit is None or intake is None:
        raise HandoffError("no_intake")
    patient = mock_health.get_patient(conn, visit["patient_id"], on)
    if patient is None:
        raise HandoffError("no_patient")
    row = conn.execute("SELECT * FROM vitals WHERE visit_id = ?", (visit_id,)).fetchone()
    vitals = dict(row) if row is not None else None

    # No transaction here: the model call can take seconds and must not hold
    # the write lock.
    drafted = draft(ai.llm, intake, vitals, patient)

    suggestions: list[doctors.Suggestion] = []
    if visit["centre_id"] is not None:
        suggestions = doctors.suggest(
            conn,
            visit["centre_id"],
            _service(conn, visit, visit_id, intake),
            patient["preferred_lang"],
            gender_pref,
        )
    top = suggestions[0] if suggestions else None

    with db.transaction(conn):
        conn.execute(
            "INSERT INTO handoff (visit_id, ai_draft, suggested_doctor_id, reason) "
            "VALUES (?, ?, ?, ?) "
            "ON CONFLICT (visit_id) DO UPDATE SET ai_draft = excluded.ai_draft, "
            "suggested_doctor_id = excluded.suggested_doctor_id, reason = excluded.reason",
            (
                visit_id,
                drafted.text,
                top.doctor_id if top else None,
                top.reason_en if top else None,
            ),
        )
        audit.record(conn, visit_id, drafted.events)

    return {
        "text": drafted.text,
        "source": drafted.source,
        "suggestions": [asdict(suggestion) for suggestion in suggestions],
    }
