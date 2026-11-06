"""Doctor suggestion by rule score. The nurse confirms, and the reason is a template."""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass

from backend import db


@dataclass(frozen=True)
class Suggestion:
    doctor_id: str
    name: str
    counter_id: str
    counter_label: str
    clinic: str
    waiting: int
    speaks_language: bool
    gender_ok: bool
    score: float
    clinic_fallback: bool
    reason_en: str
    reason_ar: str


# A doctor counter is what "on shift" means in this demo.
_CANDIDATES = """
SELECT s.id, s.name, s.clinic, s.languages, s.gender,
       c.id AS counter_id, c.label AS counter_label,
       (SELECT COUNT(*) FROM ticket t
        WHERE t.counter_id = c.id AND t.state IN ('active', 'called', 'serving')) AS waiting
FROM staff s
JOIN counter c ON c.staff_id = s.id AND c.centre_id = s.centre_id AND c.stage = 'doctor'
WHERE s.role = 'doctor' AND s.centre_id = ? AND s.clinic = ?
"""

_CLINIC_EN = {"gp": "GP", "dental": "Dental", "womens_health": "Women's Health"}
_CLINIC_AR = {"gp": "طب عام", "dental": "طب الأسنان", "womens_health": "صحة المرأة"}
_LANGUAGE_EN = {"ar": "Arabic", "en": "English"}
_LANGUAGE_AR = {"ar": "العربية", "en": "الإنجليزية"}
_SPEAKS_AR = {"F": "تتحدث"}
_DEFAULT_SPEAKS_AR = "يتحدث"

# The service as it reads in "No ... clinic here". 'other' has no name of its own.
_MISSING_CLINIC_EN = {
    "dental": "dental",
    "womens_health": "women's health",
    "refill": "refill",
    "vaccination": "vaccination",
    "lab_only": "lab",
    "mental_health": "mental health",
}
_MISSING_CLINIC_AR = {
    "dental": "الأسنان",
    "womens_health": "صحة المرأة",
    "refill": "صرف الأدوية",
    "vaccination": "التطعيم",
    "lab_only": "المختبر",
    "mental_health": "الصحة النفسية",
}


def _reason_en(
    row: sqlite3.Row, lang: str, speaks: bool, gender_ok: bool, missing_service: str | None
) -> str:
    speech = "speaks" if speaks else "does not speak"
    clinic = _CLINIC_EN.get(row["clinic"], row["clinic"])
    reason = f"{row['name']} — {clinic}, {row['waiting']} waiting, "
    reason += f"{speech} {_LANGUAGE_EN.get(lang, lang)}"
    if not gender_ok:
        reason += ", does not match the gender preference"
    if missing_service is not None:
        label = _MISSING_CLINIC_EN.get(missing_service, "matching")
        reason += f". No {label} clinic here, a GP is suggested"
    return reason


def _reason_ar(
    row: sqlite3.Row, lang: str, speaks: bool, gender_ok: bool, missing_service: str | None
) -> str:
    verb = _SPEAKS_AR.get(row["gender"], _DEFAULT_SPEAKS_AR)
    speech = verb if speaks else f"لا {verb}"
    clinic = _CLINIC_AR.get(row["clinic"], row["clinic"])
    reason = f"{row['name']} — {clinic}، {row['waiting']} في الانتظار، "
    reason += f"{speech} {_LANGUAGE_AR.get(lang, lang)}"
    if not gender_ok:
        reason += "، لا يطابق تفضيل الجنس"
    if missing_service is not None:
        label = _MISSING_CLINIC_AR.get(missing_service, "مناسبة")
        reason += f". لا توجد عيادة {label} هنا، نقترح طبيباً عاماً"
    return reason


def _suggestion(
    row: sqlite3.Row, patient_lang: str, gender_pref: str | None, missing_service: str | None
) -> Suggestion:
    speaks = patient_lang in db.loads_list(row["languages"])
    gender_ok = gender_pref is None or row["gender"] == gender_pref
    score = row["waiting"] * 1.0 + (0 if speaks else 2) + (0 if gender_ok else 5)
    return Suggestion(
        doctor_id=row["id"],
        name=row["name"],
        counter_id=row["counter_id"],
        counter_label=row["counter_label"],
        clinic=row["clinic"],
        waiting=row["waiting"],
        speaks_language=speaks,
        gender_ok=gender_ok,
        score=score,
        clinic_fallback=missing_service is not None,
        reason_en=_reason_en(row, patient_lang, speaks, gender_ok, missing_service),
        reason_ar=_reason_ar(row, patient_lang, speaks, gender_ok, missing_service),
    )


def suggest(
    conn: sqlite3.Connection,
    centre_id: str,
    service: str,
    patient_lang: str,
    gender_pref: str | None = None,
    limit: int = 3,
) -> list[Suggestion]:
    """Lowest score first. With no doctor in that clinic, the centre's GPs instead."""
    rows = conn.execute(_CANDIDATES, (centre_id, service)).fetchall()
    missing_service = None
    if not rows:
        rows = conn.execute(_CANDIDATES, (centre_id, "gp")).fetchall()
        missing_service = service

    ranked = sorted(
        (_suggestion(row, patient_lang, gender_pref, missing_service) for row in rows),
        key=lambda s: (s.score, s.waiting, s.doctor_id, s.counter_id),
    )
    # One line per doctor: a doctor with two counters shows the better one.
    best = {}
    for suggestion in ranked:
        best.setdefault(suggestion.doctor_id, suggestion)
    return list(best.values())[:limit]
