"""The stand-ins behind the browser tests' real mode must stay honest about their input."""

from __future__ import annotations

import io
import wave

import pytest

from backend.ai import handoff, simulated
from backend.ai.llm import Llm
from backend.ai.receptionist import run_turn
from backend.tests import standin_server
from backend.tests.ai_fakes import WAV_BYTES

FATIMA = {
    "age": 34, "sex": "F", "preferred_lang": "ar", "allergies": ["penicillin"],
    "chronic": [], "active_meds": [],
}
RECORD = {**FATIMA, "full_name_en": "Fatima Al-Demo"}
VITALS = {
    "bp_sys": 118, "bp_dia": 76, "hr": 88, "temp_c": 38.2, "spo2": 98, "weight_kg": 62,
    "urgency": "routine",
}
LLM = Llm(mode="real", model_id="stand-in", client=standin_server.StandInChat())


def chat(*said):
    history = [{"role": "assistant", "content": simulated.OPENING["ar"], "slot": "complaint"}]
    results = []
    for text in said:
        result = run_turn(LLM, text, history, FATIMA)
        results.append(result)
        slot = simulated.NOT_A_QUESTION if result.done else None
        history += [
            {"role": "user", "content": text, "slot": None},
            {"role": "assistant", "content": result.reply, "slot": slot},
        ]
    return results


def wav(rate=16000, channels=1, width=2):
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as out:
        out.setnchannels(channels)
        out.setsampwidth(width)
        out.setframerate(rate)
        out.writeframes(b"\x00" * width * channels * 160)
    return buffer.getvalue()


def test_the_whole_intake_passes_the_real_path_with_no_fallback():
    results = chat(standin_server.TRANSCRIPT, "5", "لا", "لا")
    assert [result.source for result in results] == ["model"] * 4
    assert [result.done for result in results] == [False, False, False, True]
    assert not any(e.type == "ai.fallback" for result in results for e in result.events)
    assert results[-1].intake["service"] == "gp"
    assert results[-1].intake["severity_0_10"] == 5


def test_it_cannot_run_out_of_replies():
    results = chat(standin_server.TRANSCRIPT, "5", "لا", "لا", *["لا"] * 8)
    assert all(result.source == "model" and result.done for result in results[3:])


def test_the_handoff_draft_passes_the_real_checks():
    intake = chat(standin_server.TRANSCRIPT, "5", "لا", "لا")[-1].intake
    drafted = handoff.draft(LLM, intake, VITALS, RECORD)
    assert drafted.source == "model"
    assert "Allergies: penicillin." in drafted.text
    assert [event.type for event in drafted.events] == ["handoff.drafted"]


def test_asr_hears_its_sentence_from_the_promised_format():
    heard = standin_server.StandInAsr().automatic_speech_recognition(WAV_BYTES)
    assert heard.text == "عندي حرارة وكحة من ثلاث أيام"


@pytest.mark.parametrize(
    "audio",
    [
        wav(rate=44100),
        wav(channels=2),
        wav(width=1),
        b"OggS not a wave file at all",
    ],
)
def test_asr_refuses_anything_else(audio):
    with pytest.raises(AssertionError):
        standin_server.StandInAsr().automatic_speech_recognition(audio)
