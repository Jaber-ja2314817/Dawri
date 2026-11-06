"""The intake schema and the parsing of model replies into it."""

from __future__ import annotations

import json
import re
import sqlite3
from typing import Annotated, Any, Literal, get_args

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    StringConstraints,
    TypeAdapter,
    ValidationError,
)

from backend.ai.text import is_negated, phrase_starts, phrase_tokens, tokenise

Service = Literal[
    "gp", "dental", "refill", "vaccination", "lab_only", "womens_health", "mental_health", "other"
]
Language = Literal["ar-gulf", "ar-msa", "en"]

SERVICES = get_args(Service)
LANGUAGES = get_args(Language)

_MAX_ERRORS_SHOWN = 3
_MAX_ERROR_CHARS = 300
# Bounds the work on hostile nesting, which is quadratic without a limit.
_MAX_JSON_STARTS = 64

_DECODER = json.JSONDecoder()
_BOOL = TypeAdapter(bool)
# Loose on purpose: broken JSON is what this has to catch, and the model can only
# escalate. The key may be unquoted or carry a prefix or suffix (search finds a
# prefix by itself). A backslash before the closing quote stops the match, so a
# summary that quotes the key inside valid JSON does not escalate.
_EMERGENCY_TRUE = re.compile(
    r"""emergency[\w-]*["']?\s*[:=]\s*["']?(?:true|yes|1)\b""", re.IGNORECASE
)
# JSON that lost its opening brace. The key alone is not the model saying emergency.
_EMERGENCY_FALSE = re.compile(r"""["']?emergency["']?\s*:\s*["']?false\b""", re.IGNORECASE)
_PROSE_EMERGENCY = tuple(
    phrase_tokens(word)
    for word in ("999", "emergency", "ambulance", "طوارئ", "طارئ", "طارئة", "إسعاف")
)
# Two more ways to write "not an emergency". The shared negators stay as the
# vault lists them, so this reaches only the model's prose.
_PROSE_NEGATORS = tuple(phrase_tokens(word) for word in ("isn't", "ليست"))


Complaint = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]
PatientWords = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=1000)
]
NurseSummary = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=400)
]


class Intake(BaseModel):
    """The vault's schema. duration and severity stay None rather than be invented."""

    model_config = ConfigDict(extra="ignore")

    emergency: bool = False
    language: Language
    chief_complaint: Complaint
    chief_complaint_patient_words: PatientWords
    duration: str | None = None
    severity_0_10: Annotated[int, Field(strict=True, ge=0, le=10)] | None = None
    associated: list[str] = Field(default_factory=list)
    self_medication: list[str] = Field(default_factory=list)
    service: Service
    service_confidence: float = Field(strict=True, ge=0, le=1)
    summary_for_nurse: NurseSummary
    refill_request: str | None = None
    questions_asked: int = Field(strict=True, ge=0, le=6)
    denied_red_flags: list[str] = Field(default_factory=list)  # Set by the server, not the model.
    patient_concerns: str | None = None


class IntakeParseError(ValueError):
    """str(e) is short and holds no patient text, so it can go back to the model."""


def extract_json(text: str) -> dict | None:
    """The first JSON object in text, past any fences, prose or stray braces."""
    start = text.find("{")
    for _ in range(_MAX_JSON_STARTS):
        if start == -1:
            break
        try:
            value, _end = _DECODER.raw_decode(text, start)
        except (ValueError, RecursionError):
            value = None
        if isinstance(value, dict):
            return value
        start = text.find("{", start + 1)
    return None


def _means_true(value: Any) -> bool:
    """True for anything the schema itself would read as true."""
    try:
        return _BOOL.validate_python(value.strip() if isinstance(value, str) else value)
    except ValidationError:
        return False


def _prose_says_emergency(text: str) -> bool:
    if "{" in text:  # JSON says it through its key, and a summary may quote the word.
        return False
    tokens = tokenise(_EMERGENCY_FALSE.sub(" ", text))
    return any(
        not is_negated(tokens, start, extra=_PROSE_NEGATORS)
        for phrase in _PROSE_EMERGENCY
        for start in phrase_starts(tokens, phrase)
    )


def says_emergency(text: str) -> bool:
    """The model can only escalate, so a malformed emergency still counts.

    The pattern runs even when an object parsed: broken JSON can leave a nested
    object as the first one that parses, with the emergency key outside it. A
    reply with no JSON at all can still escalate in plain words.
    """
    data = extract_json(text)
    if data is not None and _means_true(data.get("emergency")):
        return True
    return _EMERGENCY_TRUE.search(text) is not None or _prose_says_emergency(text)


def _describe(exc: ValidationError) -> str:
    # include_input=False keeps the patient's words out of the retry prompt.
    errors = exc.errors(include_url=False, include_context=False, include_input=False)
    parts = [
        f"{'.'.join(str(step) for step in error['loc']) or 'intake'}: {error['msg']}"
        for error in errors[:_MAX_ERRORS_SHOWN]
    ]
    return f"Invalid intake: {'; '.join(parts)}"[:_MAX_ERROR_CHARS]


def validate_intake(data: dict) -> Intake:
    try:
        return Intake.model_validate(data)
    except ValidationError as exc:
        raise IntakeParseError(_describe(exc)) from None


def parse_intake(text: str) -> Intake:
    data = extract_json(text)
    if data is None:
        raise IntakeParseError("The reply did not contain a JSON object.")
    return validate_intake(data)


def load_effective(conn: sqlite3.Connection, visit_id: str) -> dict | None:
    """The intake everyone downstream sees: the nurse's edit when there is one."""
    row = conn.execute(
        "SELECT edited_json, json FROM intake WHERE visit_id = ?", (visit_id,)
    ).fetchone()
    if row is None:
        return None
    edited, stored = row
    return json.loads(edited if edited and edited.strip() else stored) or None
