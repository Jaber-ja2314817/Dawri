"""Dawri in real mode with no model behind it, for the browser tests only.

An injected client is what makes a mode real (see backend/ai/llm.py build), so this
replaces runtime.build_runtime with one that injects the two stand-ins below. HF_TOKEN
stays blank and nothing here opens a socket to anyone, so no network call is possible.
What the tests prove on this server is the app's real path. They say nothing about the
live model. Not collected by pytest, and left out of the image by .dockerignore.

A patient message holding MODEL_DOWN makes the stand-in fail that one turn, so a browser
test can reach the scripted fallback. Nothing else fails, so A1 stays on the model.

    DAWRI_DB=... SIMULATE_LOAD=1 .venv/bin/python -m backend.tests.standin_server --port 8152
"""

from __future__ import annotations

import argparse
import io
import json
import os
import re
import wave
from types import SimpleNamespace

import uvicorn

from backend.main import app
from backend.ai import handoff, runtime

TRANSCRIPT = "عندي حرارة وكحة من ثلاث أيام"
MODEL_DOWN = "standin-model-down"

# Worded apart from the scripted receptionist, so a screen can tell who asked.
_QUESTIONS = (
    ("كم شدتها من 0 إلى 10؟", "From 0 to 10, how bad is it?"),
    ("هل أخذت أي دواء؟", "Have you taken any medicine?"),
    ("هل عندك شي ثاني؟", "Is there anything else?"),
)
_ARABIC = re.compile(r"[؀-ۿ]")
_NUMBER = re.compile(r"\d+")
_FORCE_INTAKE = "Output ONLY the intake JSON now."


def _reply(text: str) -> SimpleNamespace:
    return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=text))])


def _severity(answers: list[str]) -> int | None:
    for answer in answers:
        found = _NUMBER.search(answer)
        if found and int(found[0]) <= 10:
            return int(found[0])
    return None


def _intake(said: list[str], arabic: bool) -> str:
    severity = _severity(said[1:])
    return json.dumps(
        {
            "emergency": False,
            "language": "ar-gulf" if arabic else "en",
            "chief_complaint": "fever and cough",
            "chief_complaint_patient_words": said[0],
            "duration": "3 days",
            "severity_0_10": severity,
            "associated": ["cough"],
            "self_medication": [],
            "service": "gp",
            "service_confidence": 0.9,
            "summary_for_nurse": "Stand-in model summary: fever and cough for 3 days.",
            "patient_concerns": None,
            "refill_request": None,
            "questions_asked": min(len(said) - 1, 6),
        },
        ensure_ascii=False,
    )


def _receptionist(messages: list[dict]) -> str:
    """One question per patient message, then the intake, however long the chat runs."""
    said = [m["content"] for m in messages if m["role"] == "user"]
    forced = _FORCE_INTAKE in said[-1] or _FORCE_INTAKE in messages[0]["content"]
    if forced:
        said = said[:-1] if _FORCE_INTAKE in said[-1] else said
    arabic = bool(_ARABIC.search(said[0]))
    if forced or len(said) > len(_QUESTIONS):
        return _intake(said, arabic)
    question_ar, question_en = _QUESTIONS[len(said) - 1]
    return question_ar if arabic else question_en


def _reading(value: object) -> str:
    return "not recorded" if value is None else f"{value:g}"


def _handoff(body: str) -> str:
    """Only the facts in the payload, line for line, as the system prompt asks."""
    facts = json.loads(body)
    intake, vitals, record = facts["intake"], facts["vitals"] or {}, facts["record"]
    severity = intake["severity_0_10"]
    return "\n".join(
        (
            f"{record['name']}, {record['age']}{record['sex']}.",
            f"Complaint: {intake['chief_complaint']}, {intake['duration']}, "
            f"severity {'not recorded' if severity is None else f'{severity}/10'}.",
            f"History: {', '.join(record['chronic']) or 'none on record'}. "
            f"Allergies: {', '.join(record['allergies']) or 'none on record'}.",
            f"Vitals: BP {_reading(vitals.get('bp_sys'))}/{_reading(vitals.get('bp_dia'))}, "
            f"HR {_reading(vitals.get('hr'))}, Temp {_reading(vitals.get('temp_c'))} C, "
            f"SpO2 {_reading(vitals.get('spo2'))}%, Weight {_reading(vitals.get('weight_kg'))} kg.",
            "Concerns: none stated.",
        )
    )


class StandInChat:
    """Stateful by message count alone, so it cannot run out of replies."""

    def chat_completion(self, messages, *, max_tokens=None, temperature=None) -> SimpleNamespace:
        if messages[0]["content"] == handoff.SYSTEM_PROMPT:
            return _reply(_handoff(messages[-1]["content"]))
        if MODEL_DOWN in messages[-1]["content"]:
            raise TimeoutError("stand-in model down")
        return _reply(_receptionist(messages))


class StandInAsr:
    """Hears one sentence, and only from audio in the format the browser promises.

    A failed assertion is not caught by the adapter, so bad audio fails the test rather
    than passing for a model failure.
    """

    def automatic_speech_recognition(self, audio: bytes) -> SimpleNamespace:
        assert audio[:4] == b"RIFF" and audio[8:12] == b"WAVE", "not RIFF/WAVE"
        with wave.open(io.BytesIO(audio), "rb") as wav:
            assert wav.getframerate() == 16000, f"rate {wav.getframerate()}"
            assert wav.getnchannels() == 1, f"channels {wav.getnchannels()}"
            assert wav.getsampwidth() == 2, f"sample width {wav.getsampwidth()}"
            assert wav.getnframes() > 0, "no samples"
        return SimpleNamespace(text=TRANSCRIPT)


def main() -> None:
    if os.environ.get("HF_TOKEN", "").strip():
        raise SystemExit("standin_server runs with HF_TOKEN blank, always.")
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    port = parser.parse_args().port

    build = runtime.build_runtime
    runtime.build_runtime = lambda: build(StandInChat(), StandInAsr())
    uvicorn.run(
        app, host="127.0.0.1", port=port, timeout_graceful_shutdown=1, log_level="warning"
    )


if __name__ == "__main__":
    main()
