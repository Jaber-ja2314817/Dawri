"""Plain-language medicine lines. Every number comes from the prescription fields."""

from __future__ import annotations

import re
import sqlite3
from typing import Any

_FREQUENCY_EN = {
    "once daily": "once a day",
    "twice daily": "twice a day",
    "three times daily": "three times a day",
    "every 6 hours as needed": "every 6 hours when needed",
    "every 8 hours as needed": "every 8 hours when needed",
}
_FREQUENCY_AR = {
    "once daily": "مرة واحدة يومياً",
    "twice daily": "مرتين يومياً",
    "three times daily": "ثلاث مرات يومياً",
    "every 6 hours as needed": "كل 6 ساعات عند الحاجة",
    "every 8 hours as needed": "كل 8 ساعات عند الحاجة",
}
_FORM_AR = {"tablet": "أقراص", "capsule": "كبسولات", "syrup": "شراب"}
_UNIT_AR = {"mg": "ملغ", "ml": "مل"}
_DOSE_UNIT = re.compile(r"(\d)\s*(mg|ml)(?![a-z])", re.IGNORECASE)


def _text(value: Any) -> str:
    return "" if value is None else str(value).strip()


def _frequency(value: str, table: dict[str, str]) -> str:
    """A string outside the table is copied as written, never rewritten."""
    return table.get(value.lower(), value)


def _dose_ar(dose: str) -> str:
    return _DOSE_UNIT.sub(lambda m: f"{m[1]} {_UNIT_AR[m[2].lower()]}", dose)


def _days_en(days: Any) -> str:
    return "for 1 day" if days == 1 else f"for {days} days"


def _days_ar(days: Any) -> str:
    if days == 1:
        return "لمدة يوم واحد"
    if days == 2:
        return "لمدة يومين"
    if isinstance(days, int) and days >= 11:
        return f"لمدة {days} يوماً"
    return f"لمدة {days} أيام"


def _label(name: str, form: str) -> str:
    """The name with its form in brackets, unless the name already says it."""
    if not form or form.lower() in name.lower():
        return name
    return f"{name} ({form})"


def _name_en(item: dict, drug: dict | None) -> str:
    name = _text(drug.get("name_en")) if drug else ""
    if not name:
        return _text(item.get("drug"))
    return name[0].upper() + name[1:]


def _name_ar(item: dict, drug: dict | None) -> str:
    return (_text(drug.get("name_ar")) if drug else "") or _text(item.get("drug"))


def _display_name(item: dict, lang: str, drug: dict | None) -> str:
    return _name_ar(item, drug) if lang.startswith("ar") else _name_en(item, drug)


def _line(label: str, parts: list[str], joiner: str, notes: str) -> str:
    line = f"{label}: {joiner.join(parts)}." if parts else f"{label}."
    return f"{line} {notes}" if notes else line


def plain_line(item: dict, lang: str, drug: dict | None = None) -> str:
    form = _text(drug.get("form")) if drug else ""
    dose = _text(item.get("dose"))
    frequency = _text(item.get("frequency"))
    days = item.get("days")
    notes = _text(item.get("notes"))
    name = _display_name(item, lang, drug)

    if lang.startswith("ar"):
        parts = [
            *([f"الجرعة {_dose_ar(dose)}"] if dose else []),
            *([_frequency(frequency, _FREQUENCY_AR)] if frequency else []),
            *([_days_ar(days)] if days is not None else []),
        ]
        return _line(_label(name, _FORM_AR.get(form.lower(), form)), parts, "، ", notes)

    parts = [
        *([f"take {dose}"] if dose else []),
        *([_frequency(frequency, _FREQUENCY_EN)] if frequency else []),
        *([_days_en(days)] if days is not None else []),
    ]
    return _line(_label(name, form), parts, ", ", notes)


def _find_drug(conn: sqlite3.Connection, value: str) -> dict | None:
    """Phase 3 may store the drug id or its English name."""
    row = conn.execute(
        "SELECT * FROM drug WHERE id = ? OR lower(name_en) = lower(?) LIMIT 1",
        (value, value),
    ).fetchone()
    return dict(row) if row is not None else None


def for_visit(conn: sqlite3.Connection, visit_id: str, lang: str) -> list[dict]:
    rows = conn.execute(
        "SELECT drug, dose, frequency, days, notes FROM prescription_item "
        "WHERE visit_id = ? ORDER BY id",
        (visit_id,),
    ).fetchall()
    lines = []
    for row in rows:
        item = dict(row)
        drug = _find_drug(conn, _text(item["drug"]))
        lines.append(
            {
                "drug": item["drug"],
                "name": _display_name(item, lang, drug),
                "line": plain_line(item, lang, drug),
            }
        )
    return lines
