"""Stand-ins for the Hugging Face client, shared by the AI tests."""

from __future__ import annotations

import copy
import io
import wave
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from types import SimpleNamespace

import httpx2
import huggingface_hub
from huggingface_hub.utils._http import default_client_factory


def _make_wav() -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(b"\x00\x00" * 160)
    return buffer.getvalue()


WAV_BYTES = _make_wav()


class FakeChatClient:
    """Plays replies in order: a str or None as content, an Exception to raise.

    Running out raises AssertionError, so an unexpected extra call fails the test.
    """

    def __init__(self, replies: list) -> None:
        self._replies = list(replies)
        self.calls: list[dict] = []

    def chat_completion(self, messages, *, max_tokens=None, temperature=None, **kw) -> object:
        self.calls.append(
            {
                "messages": copy.deepcopy(messages),
                "max_tokens": max_tokens,
                "temperature": temperature,
                **kw,
            }
        )
        if not self._replies:
            raise AssertionError(f"unexpected model call {len(self.calls)}: no replies left")
        reply = self._replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        message = SimpleNamespace(content=reply)
        return SimpleNamespace(choices=[SimpleNamespace(message=message)])


class FakeAsrClient:
    def __init__(self, text: str = "", error: Exception | None = None) -> None:
        self._text = text
        self._error = error
        self.calls: list[bytes] = []
        self.kwargs: list[dict] = []

    def automatic_speech_recognition(self, audio, **kw) -> object:
        self.calls.append(audio)
        self.kwargs.append(kw)
        if self._error is not None:
            raise self._error
        return SimpleNamespace(text=self._text)


@contextmanager
def mock_transport(handler: Callable[[httpx2.Request], httpx2.Response]) -> Iterator[None]:
    """Sends every request the real client makes to handler instead of the network."""
    huggingface_hub.set_client_factory(
        lambda: httpx2.Client(transport=httpx2.MockTransport(handler))
    )
    huggingface_hub.close_session()
    try:
        yield
    finally:
        huggingface_hub.set_client_factory(default_client_factory)
        huggingface_hub.close_session()
