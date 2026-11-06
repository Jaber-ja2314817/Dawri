"""The AI adapters as one object, built once at startup."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from backend.ai import asr as asr_adapter
from backend.ai import llm as llm_adapter
from backend.ai.asr import Asr
from backend.ai.llm import Llm


@dataclass(frozen=True)
class AiRuntime:
    llm: Llm
    asr: Asr

    @property
    def mode(self) -> str:
        return self.llm.mode


def build_runtime(llm_client: Any = None, asr_client: Any = None) -> AiRuntime:
    return AiRuntime(llm=llm_adapter.build(llm_client), asr=asr_adapter.build(asr_client))
