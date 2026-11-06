"""The receptionist's system prompt, built fresh for every model call."""

from __future__ import annotations

import json
from collections.abc import Sequence

from backend.ai import intake, redflags

MAX_QUESTIONS = 6

# The vault's prompt from AI Receptionist Design, word for word.
SYSTEM_PROMPT = """\
You are the reception assistant at a Qatar primary health centre. You help
patients check in before they arrive. You are NOT a doctor or nurse.

Rules:
- Never diagnose, name a likely condition, suggest treatment or doses.
- Ask one short question at a time, max 6 questions in total.
- Reply in the patient's language and dialect (Gulf Arabic, MSA or English).
- If anything suggests an emergency (chest pain, trouble breathing, stroke
  signs, severe bleeding, fainting, severe allergic reaction, thoughts of
  harming themselves, a very sick baby) output {"emergency": true} and stop.
- When you have enough information, output ONLY the intake JSON.
- Use the patient record you are given for allergies and chronic
  conditions; don't ask for what the record already has.

Patient record: {{record_json}}"""

INTAKE_KEYS = (
    "emergency (false)",
    f"language ({' | '.join(intake.LANGUAGES)})",
    "chief_complaint",
    "chief_complaint_patient_words",
    "duration (null if not given)",
    "severity_0_10 (integer, null if not given)",
    "associated (list)",
    "self_medication (list of names, no doses)",
    f"service ({' | '.join(intake.SERVICES)})",
    "service_confidence (0 to 1)",
    "summary_for_nurse",
    "refill_request (null unless asking for a usual medicine)",
    "questions_asked",
)

_RECORD_FIELDS = ("age", "sex", "allergies", "chronic", "active_meds")


def build_system(
    record: dict, denied: Sequence[str], questions_asked: int, force_intake: bool
) -> str:
    # Copies named fields only, so a full patient row cannot leak a name or QID.
    minimal = {name: record.get(name) for name in _RECORD_FIELDS}
    record_json = json.dumps(minimal, ensure_ascii=False)
    lines = [SYSTEM_PROMPT.replace("{{record_json}}", record_json)]
    denied_line = redflags.denied_text(denied)
    if denied_line:
        lines.append(denied_line)
    lines.append("Intake JSON keys: " + "; ".join(INTAKE_KEYS))
    if force_intake:
        lines.append(f"You have asked {MAX_QUESTIONS} questions. Output ONLY the intake JSON now.")
    else:
        lines.append(f"Questions asked so far: {questions_asked} of {MAX_QUESTIONS}.")
    return "\n".join(lines)
