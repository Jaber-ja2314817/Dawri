"""The chat model adapter. Real when HF_TOKEN is set, otherwise simulated."""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

from backend import config

logger = logging.getLogger(__name__)


class LlmError(Exception):
    """A failed model call. str(e) is only the kind, so it is safe to store."""

    kind = "other"

    def __init__(self, kind: str | None = None) -> None:
        if kind is not None:
            self.kind = kind
        super().__init__(self.kind)


class LlmUnavailable(LlmError):
    """Simulated mode has no model. The scripted receptionist lives elsewhere."""

    kind = "unavailable"


def _kind(exc: Exception) -> str:
    # Imported here so simulated mode never loads huggingface_hub.
    import httpx
    import httpx2
    from huggingface_hub.errors import HfHubHTTPError, InferenceTimeoutError

    # The provider lookup runs outside the client's own timeout wrapper, so the
    # raw transport errors can reach this point too. Timeouts come first because
    # InferenceTimeoutError is also an HTTP error.
    if isinstance(
        exc, (TimeoutError, InferenceTimeoutError, httpx2.TimeoutException, httpx.TimeoutException)
    ):
        return "timeout"
    if isinstance(exc, (HfHubHTTPError, httpx2.HTTPError, httpx.HTTPError)):
        return "http"
    return "other"


@dataclass(frozen=True)
class Llm:
    """Frozen, because plain def routes share it across threadpool threads."""

    mode: str
    model_id: str
    client: Any = field(default=None, repr=False)

    def chat(self, messages: list[dict], max_tokens: int = 400, temperature: float = 0.2) -> str:
        if self.mode != "real":
            raise LlmUnavailable()
        try:
            resp = self.client.chat_completion(
                messages=[{"role": m["role"], "content": m["content"]} for m in messages],
                max_tokens=max_tokens,
                temperature=temperature,
            )
            content = resp.choices[0].message.content
        except AssertionError:
            # A broken test expectation, such as a fake with no replies left,
            # must not pass for a model failure and fall back quietly.
            raise
        except Exception as exc:
            kind = _kind(exc)
            logger.warning("llm call failed: kind=%s type=%s", kind, type(exc).__name__)
            # from None: the chained text can quote the prompt or the provider.
            raise LlmError(kind) from None
        text = content.strip() if isinstance(content, str) else ""
        if not text:
            logger.warning("llm call failed: kind=empty")
            raise LlmError("empty")
        return text


def _real_client() -> Any:
    from huggingface_hub import InferenceClient

    return InferenceClient(
        model=config.llm_model_id(),
        provider=config.llm_provider(),
        token=config.hf_token(),
        timeout=config.llm_timeout_sec(),
    )


def build(client: Any = None) -> Llm:
    """An injected client is always real. That is how tests reach the real path."""
    if client is None:
        if config.ai_mode() == "simulated":
            return Llm(mode="simulated", model_id="simulated")
        client = _real_client()
    return Llm(mode="real", model_id=config.llm_model_id(), client=client)
