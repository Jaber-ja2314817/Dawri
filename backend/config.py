"""Runtime configuration. Every value is read from os.environ at call time."""

from __future__ import annotations

import os
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent

_DEFAULT_LLM_MODEL_ID = "QCRI/Fanar-1-9B-Instruct"
_DEFAULT_LLM_PROVIDER = "featherless-ai"
_DEFAULT_ASR_MODEL_ID = "openai/whisper-large-v3-turbo"


def _env(name: str, default: str) -> str:
    """Return the variable stripped, or the default when unset or blank."""
    return os.environ.get(name, "").strip() or default


def db_path() -> Path:
    return Path(_env("DAWRI_DB", str(_REPO_ROOT / "backend" / "data" / "dawri.db")))


def ai_mode() -> str:
    return "real" if os.environ.get("HF_TOKEN", "").strip() else "simulated"


def simulate_load() -> bool:
    return os.environ.get("SIMULATE_LOAD") == "1"


def llm_model_id() -> str:
    return _env("LLM_MODEL_ID", _DEFAULT_LLM_MODEL_ID)


def llm_provider() -> str:
    return _env("LLM_PROVIDER", _DEFAULT_LLM_PROVIDER)


def asr_model_id() -> str:
    return _env("ASR_MODEL_ID", _DEFAULT_ASR_MODEL_ID)
