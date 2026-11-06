from __future__ import annotations

import inspect
import io
import logging
import struct

import httpx2
import pytest
from huggingface_hub import InferenceClient

from backend import config
from backend.ai import asr
from backend.tests.ai_fakes import WAV_BYTES, FakeAsrClient, mock_transport

DUMMY_TOKEN = "dummy-not-a-real-token"
NOT_WAV = [
    b"",
    b"RIFF",
    b"RIFF\x00\x00\x00\x00",
    b"RIFF\x00\x00\x00\x00WAVX",
    b"OggS\x00\x00\x00\x00WAVE",
    b"\x1aE\xdf\xa3 webm data here",
    b"not audio at all, just some text",
]


@pytest.fixture(autouse=True)
def isolated_env(monkeypatch):
    for name in ("HF_TOKEN", "ASR_MODEL_ID", "ASR_PROVIDER", "LLM_TIMEOUT_SEC"):
        monkeypatch.delenv(name, raising=False)


@pytest.fixture
def recorder(monkeypatch):
    built = []

    class Recorder:
        def __init__(self, **kwargs):
            built.append(kwargs)

    monkeypatch.setattr("huggingface_hub.InferenceClient", Recorder)
    return built


def test_the_fake_wav_is_a_riff_wave_file():
    assert asr._is_wav(WAV_BYTES)
    assert struct.unpack("<I", WAV_BYTES[24:28])[0] == 16000


def test_messages_tell_the_patient_to_type():
    assert asr.ASR_UNAVAILABLE_EN == "Voice is not available right now. Please type your message."
    assert asr.ASR_UNAVAILABLE_AR == "الصوت غير متاح الآن. الرجاء كتابة رسالتك."


def test_the_real_path_returns_the_text():
    client = FakeAsrClient(text="  عندي حرارة \n")
    adapter = asr.build(client=client)

    assert adapter.mode == "real"
    assert adapter.transcribe(WAV_BYTES) == "عندي حرارة"
    assert client.calls == [WAV_BYTES]


def test_the_call_carries_no_extra_arguments():
    client = FakeAsrClient(text="hello")
    asr.build(client=client).transcribe(WAV_BYTES)
    assert client.kwargs == [{}]
    assert type(client.calls[0]) is bytes


def test_the_real_client_accepts_the_exact_call():
    inspect.signature(InferenceClient.automatic_speech_recognition).bind(None, WAV_BYTES)


def test_the_real_client_constructor_accepts_the_exact_arguments():
    inspect.signature(InferenceClient.__init__).bind(
        None, model="m", provider="hf-inference", token="t", timeout=1.0, headers={}
    )


@pytest.mark.parametrize("text", ["", "   \n", None])
def test_blank_text_is_a_failure(text):
    with pytest.raises(asr.AsrFailed):
        asr.build(client=FakeAsrClient(text=text)).transcribe(WAV_BYTES)


@pytest.mark.parametrize("error", [TimeoutError("slow"), ValueError("odd")])
def test_a_client_error_is_a_failure(error):
    with pytest.raises(asr.AsrFailed) as caught:
        asr.build(client=FakeAsrClient(error=error)).transcribe(WAV_BYTES)
    assert caught.value.__suppress_context__
    assert caught.value.__cause__ is None


@pytest.mark.parametrize("audio", NOT_WAV)
def test_anything_but_a_wav_is_bad_audio(audio):
    client = FakeAsrClient(text="must not be returned")
    with pytest.raises(asr.AsrBadAudio):
        asr.build(client=client).transcribe(audio)
    assert client.calls == []


def test_the_factory_builds_from_config_with_the_wav_header(monkeypatch, recorder):
    monkeypatch.setenv("HF_TOKEN", DUMMY_TOKEN)
    monkeypatch.setenv("LLM_TIMEOUT_SEC", "4")

    adapter = asr.build()

    assert adapter.mode == "real"
    assert adapter.model_id == "openai/whisper-large-v3-turbo"
    assert recorder == [
        {
            "model": "openai/whisper-large-v3-turbo",
            "provider": "hf-inference",
            "token": DUMMY_TOKEN,
            "timeout": 4.0,
            "headers": {"Content-Type": "audio/wav"},
        }
    ]


def test_another_provider_gets_no_content_type_header(monkeypatch, recorder):
    monkeypatch.setenv("HF_TOKEN", DUMMY_TOKEN)
    monkeypatch.setenv("ASR_PROVIDER", "deepinfra")
    monkeypatch.setenv("ASR_MODEL_ID", "org/other-asr")

    asr.build()

    assert recorder[0]["provider"] == "deepinfra"
    assert recorder[0]["model"] == "org/other-asr"
    assert "headers" not in recorder[0]


@pytest.mark.parametrize("audio", [WAV_BYTES, *NOT_WAV])
def test_simulated_always_raises_unavailable_first(audio, recorder):
    adapter = asr.build()
    assert adapter.mode == "simulated"
    with pytest.raises(asr.AsrUnavailable):
        adapter.transcribe(audio)
    assert recorder == []


def test_simulated_mode_never_reaches_a_client():
    client = FakeAsrClient(text="fabricated")
    adapter = asr.Asr(mode="simulated", model_id="simulated", client=client)
    with pytest.raises(asr.AsrUnavailable):
        adapter.transcribe(WAV_BYTES)
    assert client.calls == []


def test_simulated_mode_does_not_claim_a_model():
    assert "whisper" not in asr.build().model_id


def test_nothing_private_reaches_the_log(caplog):
    caplog.set_level(logging.DEBUG)
    error = ValueError(f"{DUMMY_TOKEN} {WAV_BYTES!r}")
    with pytest.raises(asr.AsrFailed):
        asr.build(client=FakeAsrClient(error=error)).transcribe(WAV_BYTES)
    assert DUMMY_TOKEN not in caplog.text
    assert "RIFF" not in caplog.text
    assert "ValueError" in caplog.text


def test_audio_is_never_opened_as_a_file(monkeypatch):
    def refuse(*args, **kwargs):
        raise AssertionError("audio touched the disk")

    monkeypatch.setattr("builtins.open", refuse)
    monkeypatch.setattr(io, "open", refuse)
    assert asr.build(client=FakeAsrClient(text="ok")).transcribe(WAV_BYTES) == "ok"


def test_the_real_client_sends_raw_wav_with_the_content_type(monkeypatch):
    monkeypatch.setenv("HF_TOKEN", DUMMY_TOKEN)
    # A URL as the model keeps the library from looking the model up on the Hub.
    monkeypatch.setenv("ASR_MODEL_ID", "http://asr.invalid/whisper")
    requests = []

    def handle(request):
        if request.method == "GET":
            return httpx2.Response(200, json=[])
        requests.append(request)
        return httpx2.Response(200, json={"text": " hello "})

    with mock_transport(handle):
        assert asr.build().transcribe(WAV_BYTES) == "hello"

    assert requests[0].headers["content-type"] == "audio/wav"
    assert requests[0].content == WAV_BYTES


def test_a_real_client_timeout_is_a_failure(monkeypatch):
    monkeypatch.setenv("HF_TOKEN", DUMMY_TOKEN)
    monkeypatch.setenv("ASR_MODEL_ID", "http://asr.invalid/whisper")

    def handle(request):
        if request.method == "GET":
            return httpx2.Response(200, json=[])
        raise httpx2.ReadTimeout("slow", request=request)

    with mock_transport(handle):
        with pytest.raises(asr.AsrFailed):
            asr.build().transcribe(WAV_BYTES)


def test_asr_provider_setting(monkeypatch):
    assert config.asr_provider() == "hf-inference"
    monkeypatch.setenv("ASR_PROVIDER", "deepinfra")
    assert config.asr_provider() == "deepinfra"
