"""The files a Space build reads: the card, the env example, the image and the pins."""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from backend import config

ROOT = Path(__file__).resolve().parents[2]

README = ROOT / "README.md"
ENV_EXAMPLE = ROOT / ".env.example"
DOCKERFILE = ROOT / "Dockerfile"
DOCKERIGNORE = ROOT / ".dockerignore"
REQUIREMENTS = ROOT / "requirements.txt"
REQUIREMENTS_DEV = ROOT / "requirements-dev.txt"
PACKAGE_LOCK = ROOT / "frontend" / "package-lock.json"

ENV_KEYS = {
    "HF_TOKEN",
    "LLM_MODEL_ID",
    "LLM_PROVIDER",
    "ASR_MODEL_ID",
    "ASR_PROVIDER",
    "LLM_TIMEOUT_SEC",
    "SIMULATE_LOAD",
    "DAWRI_DB",
    "DAWRI_STATIC_DIR",
    "DEMO_PASSCODE",
}
BANNED_PHRASES = ("place held", "no-show", "nobody skips")
SECRET_SHAPES = (
    r"hf_[A-Za-z0-9]{6,}",
    r"sk-[A-Za-z0-9]{16,}",
    r"gh[pousr]_[A-Za-z0-9]{16,}",
    r"AKIA[0-9A-Z]{12,}",
    r"Bearer\s+[A-Za-z0-9._-]{16,}",
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
)
PIN = re.compile(r"^[A-Za-z0-9_.-]+(\[[a-z0-9,]+\])?==[0-9][A-Za-z0-9.]*$")


def _text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _front_matter(text: str) -> dict[str, str]:
    lines = text.splitlines()
    assert lines[0] == "---", "the card must be the very first thing in the README"
    end = lines.index("---", 1)
    fields = {}
    for line in lines[1:end]:
        key, separator, value = line.partition(":")
        assert separator, f"not a key and value: {line!r}"
        fields[key.strip()] = value.strip().strip("\"'")
    return fields


def _env_lines() -> dict[str, str]:
    pairs = {}
    for line in _text(ENV_EXAMPLE).splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        assert separator, f"not a key and value: {line!r}"
        assert key not in pairs, f"{key} appears twice"
        pairs[key] = value
    return pairs


def _dockerfile_stages() -> list[str]:
    return re.split(r"^(?=FROM )", _text(DOCKERFILE), flags=re.MULTILINE)[1:]


def _requirement_lines(path: Path) -> list[str]:
    lines = (line.strip() for line in _text(path).splitlines())
    return [line for line in lines if line and not line.startswith("#")]


def _version(text: str) -> tuple[int, ...]:
    parts = [int(part) for part in text.split(".")]
    return tuple(parts + [0] * (3 - len(parts)))


def _readme_node_minimum() -> tuple[int, ...]:
    found = re.findall(r"\bNode (\d+\.\d+\.\d+) or later\b", _text(README))
    assert len(found) == 1, f"the README must state one exact Node minimum, found {found}"
    return _version(found[0])


def _node_range_allows(version: tuple[int, ...], spec: str) -> bool:
    """The range shapes the lockfile uses. A new shape fails loudly rather than passing."""
    for alternative in spec.split("||"):
        shape = re.fullmatch(r"\s*(>=|\^)?\s*v?(\d+(?:\.\d+)*)\s*", alternative)
        assert shape, f"unknown engines range: {spec!r}"
        operator, floor = shape.group(1), _version(shape.group(2))
        if version < floor:
            continue
        if operator == ">=" or version[0] == floor[0]:
            return True
    return False


# README


def test_readme_card_is_a_docker_space_on_7860():
    card = _front_matter(_text(README))
    assert card["sdk"] == "docker"
    assert card["app_port"] == "7860"
    assert card["title"] == "Dawri"
    assert card["colorFrom"] == card["colorTo"] == "gray"
    assert card["pinned"] == "false"
    assert "emoji" not in card
    assert "license" not in card


def test_readme_short_description_fits_the_hub_limit():
    description = _front_matter(_text(README))["short_description"]
    assert 0 < len(description) <= 60


@pytest.mark.parametrize("phrase", BANNED_PHRASES)
def test_readme_has_no_banned_phrase(phrase):
    assert phrase not in _text(README).lower()


@pytest.mark.parametrize(
    "needle",
    [
        "google/gemma-4-26B-A4B-it",
        "novita",
        "openai/whisper-large-v3-turbo",
        "hf-inference",
    ],
)
def test_readme_names_the_models_and_providers(needle):
    assert needle in _text(README)


def test_readme_names_both_design_exceptions():
    design = _text(README).split("## Design", 1)[1].split("\n## ", 1)[0]
    assert "S10" in design and "T08" in design and "48 px" in design
    assert "S06" in design and "full red field" in design


def test_readme_says_what_was_not_tested_or_reviewed():
    text = _text(README).lower()
    assert "untested" in text
    assert "clinician" in text


def test_readme_covers_every_env_key():
    text = _text(README)
    for key in ENV_KEYS:
        assert f"`{key}`" in text


def test_readme_keeps_the_timed_run_line():
    assert "Timed run of the Demo Script" in _text(README)
    assert "frontend/e2e/demo-timed.spec.ts" in _text(README)


@pytest.mark.parametrize(
    ("version", "spec", "allowed"),
    [
        ((22, 22, 2), "^22.22.2 || ^24.15.0 || >=26.0.0", True),
        ((22, 19, 0), "^22.22.2 || ^24.15.0 || >=26.0.0", False),
        ((25, 0, 0), "^22.22.2 || ^24.15.0 || >=26.0.0", False),
        ((20, 19, 0), ">=22.19.0", False),
        ((22, 23, 4), "20 || >=22", True),
        ((22, 23, 4), ">= 20", True),
    ],
)
def test_node_range_reader(version, spec, allowed):
    assert _node_range_allows(version, spec) is allowed


def test_readme_node_minimum_meets_every_locked_package():
    minimum = _readme_node_minimum()
    packages = json.loads(_text(PACKAGE_LOCK))["packages"]
    ranges = {
        name: entry["engines"]["node"]
        for name, entry in packages.items()
        if "node" in entry.get("engines", {})
    }
    assert ranges
    refused = {name: spec for name, spec in ranges.items() if not _node_range_allows(minimum, spec)}
    assert not refused, f"README minimum {minimum} is below: {refused}"


def test_image_node_is_not_below_the_readme_minimum():
    image = re.match(r"FROM node:(\d+\.\d+\.\d+)-", _dockerfile_stages()[0])
    assert image
    assert _version(image.group(1)) >= _readme_node_minimum()


# .env.example


def test_env_example_keys_are_the_config_keys():
    assert set(_env_lines()) == ENV_KEYS


def test_every_env_key_is_read_by_config():
    source = _text(ROOT / "backend" / "config.py")
    for key in ENV_KEYS:
        assert f'"{key}"' in source


def test_env_example_token_is_blank():
    assert _env_lines()["HF_TOKEN"] == ""


def test_env_example_has_one_comment_per_key():
    lines = _text(ENV_EXAMPLE).splitlines()
    for index, line in enumerate(lines):
        if line and not line.startswith("#"):
            assert lines[index - 1].startswith("# "), f"no comment above {line!r}"


def test_env_example_model_defaults_match_config(monkeypatch):
    for key in ENV_KEYS:
        monkeypatch.delenv(key, raising=False)
    example = _env_lines()
    assert example["LLM_MODEL_ID"] == config.llm_model_id()
    assert example["LLM_PROVIDER"] == config.llm_provider()
    assert example["ASR_MODEL_ID"] == config.asr_model_id()
    assert example["ASR_PROVIDER"] == config.asr_provider()
    assert float(example["LLM_TIMEOUT_SEC"]) == config.llm_timeout_sec()


# Secrets


@pytest.mark.parametrize("path", [README, ENV_EXAMPLE, DOCKERFILE], ids=lambda path: path.name)
def test_no_secret_shaped_text(path):
    text = _text(path)
    for shape in SECRET_SHAPES:
        assert re.search(shape, text) is None, shape


# Dockerfile


def test_dockerfile_runs_as_uid_1000_on_port_7860():
    text = _text(DOCKERFILE)
    assert re.search(r"^USER 1000$", text, flags=re.MULTILINE)
    assert re.search(r"^EXPOSE 7860$", text, flags=re.MULTILINE)
    assert "--uid 1000" in text


def test_dockerfile_keeps_all_writes_in_tmp():
    text = _text(DOCKERFILE)
    assert "DAWRI_DB=/tmp/dawri.db" in text
    assert "HOME=/tmp" in text
    assert "HF_HOME=/tmp/hf" in text
    assert "SIMULATE_LOAD=1" in text


def test_dockerfile_never_names_the_token():
    assert "HF_TOKEN" not in _text(DOCKERFILE)


def test_dockerfile_builds_on_exact_node_22_and_python_3_12():
    stages = _dockerfile_stages()
    assert len(stages) == 2
    assert re.match(r"FROM node:22\.\d+\.\d+-[a-z-]*slim AS frontend\n", stages[0])
    assert re.match(r"FROM python:3\.12\.\d+-slim-trixie\n", stages[1])


def test_dockerfile_sets_no_platform():
    assert "--platform" not in _text(DOCKERFILE)


def test_dockerfile_starts_one_process_with_the_shipping_flags():
    cmd = _text(DOCKERFILE).rsplit("CMD ", 1)[1]
    assert cmd.startswith('["uvicorn", "backend.main:app"')
    assert '"--no-access-log"' in cmd
    assert '"--timeout-graceful-shutdown", "3"' in cmd
    assert "--workers" not in cmd


def test_dockerfile_checks_health_without_curl():
    text = _text(DOCKERFILE)
    assert "HEALTHCHECK" in text
    assert "urllib" in text
    assert "http://127.0.0.1:7860/api/health" in text


@pytest.mark.parametrize(
    "pattern",
    [
        ".git",
        ".venv",
        "Dawri-Vault",
        "backend/tests",
        "frontend/node_modules",
        "frontend/e2e",
        ".env",
        ".env.*",
        "**/*.db",
    ],
)
def test_dockerignore_keeps_this_out_of_the_build(pattern):
    assert pattern in _text(DOCKERIGNORE).splitlines()


@pytest.mark.parametrize(
    "needed",
    [
        "frontend/src",
        "frontend/public",
        "frontend/index.html",
        "frontend/package.json",
        "frontend/package-lock.json",
        "frontend/vite.config.ts",
        "frontend/tsconfig.json",
    ],
)
def test_dockerignore_leaves_the_frontend_build_inputs(needed):
    assert needed not in _text(DOCKERIGNORE).splitlines()


# Requirements


def test_runtime_requirements_have_no_test_tools():
    names = [line.split("==")[0] for line in _requirement_lines(REQUIREMENTS)]
    assert "pytest" not in names
    assert "httpx" in names


def test_dev_requirements_start_from_the_runtime_ones():
    lines = _requirement_lines(REQUIREMENTS_DEV)
    assert lines[0] == "-r requirements.txt"
    assert any(line.startswith("pytest==") for line in lines)


@pytest.mark.parametrize("path", [REQUIREMENTS, REQUIREMENTS_DEV], ids=lambda path: path.name)
def test_every_requirement_is_pinned(path):
    for line in _requirement_lines(path):
        if line == "-r requirements.txt":
            continue
        assert PIN.match(line), f"not an exact pin: {line!r}"


def test_nothing_at_runtime_imports_pytest():
    backend = ROOT / "backend"
    for path in backend.rglob("*.py"):
        if backend / "tests" in path.parents:
            continue
        assert re.search(r"^\s*(import|from)\s+pytest\b", _text(path), re.M) is None, path
