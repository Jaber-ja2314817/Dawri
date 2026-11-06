"""The speech-to-text adapter. It never invents a transcript or keeps audio."""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

from backend import config

logger = logging.getLogger(__name__)

ASR_UNAVAILABLE_EN = "Voice is not available right now. Please type your message."
ASR_UNAVAILABLE_AR = "الصوت غير متاح الآن. الرجاء كتابة رسالتك."

_HF_INFERENCE = "hf-inference"


class AsrUnavailable(Exception):
    """Simulated mode. The route maps this to 503."""


class AsrBadAudio(Exception):
    """Empty, or not a RIFF/WAVE file. The route maps this to 400."""


class AsrFailed(Exception):
    """The real model failed or returned blank text."""


def _is_wav(audio: bytes) -> bool:
    return bool(audio) and audio[:4] == b"RIFF" and audio[8:12] == b"WAVE"


@dataclass(frozen=True)
class Asr:
    """Frozen, because plain def routes share it across threadpool threads."""

    mode: str
    model_id: str
    client: Any = field(default=None, repr=False)

    def transcribe(self, wav: bytes) -> str:
        if self.mode != "real":
            raise AsrUnavailable(ASR_UNAVAILABLE_EN)
        if not _is_wav(wav):
            raise AsrBadAudio("Audio must be a WAV file.")
        try:
            # Plain bytes: hf-inference refuses BytesIO, and any parameter forces base64 JSON.
            text = self.client.automatic_speech_recognition(wav).text
        except AssertionError:
            # A broken test expectation must not pass for a model failure.
            raise
        except Exception as exc:
            logger.warning("asr call failed: type=%s", type(exc).__name__)
            # from None: the chained text can quote the provider's response.
            raise AsrFailed("Transcription failed.") from None
        text = text.strip() if isinstance(text, str) else ""
        if not text:
            raise AsrFailed("Transcription was blank.")
        return text


def _real_client() -> Any:
    from huggingface_hub import InferenceClient

    provider = config.asr_provider()
    # Raw bytes carry no mime type, and only hf-inference takes them as the body.
    extra = {"headers": {"Content-Type": "audio/wav"}} if provider == _HF_INFERENCE else {}
    return InferenceClient(
        model=config.asr_model_id(),
        provider=provider,
        token=config.hf_token(),
        timeout=config.llm_timeout_sec(),
        **extra,
    )


def build(client: Any = None) -> Asr:
    """An injected client is always real. That is how tests reach the real path."""
    if client is None:
        if config.ai_mode() == "simulated":
            return Asr(mode="simulated", model_id="simulated")
        client = _real_client()
    return Asr(mode="real", model_id=config.asr_model_id(), client=client)
