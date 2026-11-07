#!/usr/bin/env python3
"""Harvests real inputs into harvested-inputs.json, so export-goldens.py needs no pytest.

Run it once, from the repo root, the same way as the exporters:

    HF_TOKEN= HF_HUB_OFFLINE=1 SIMULATE_LOAD=1 DAWRI_DB=<temp file outside the repo> \
        PYTHONDONTWRITEBYTECODE=1 .venv/bin/python ios/Tools/export/harvest_plugin.py

It has three parts, all of which end up in the one file:

1. As a pytest plugin it wraps the functions the Swift port must reproduce and keeps each
   distinct argument set. Only the files in ALLOWLIST run, with every outgoing connection
   blocked and load_dotenv replaced. test_ai_llm, test_ai_runtime, test_ai_asr, test_api_*
   and anything that sets HF_TOKEN are never run.
2. The string constants of every backend/tests/*.py, by parsing and never by running.
3. The table cells and quoted sentences of three vault notes.

A test that fails here because sockets are blocked is dropped by name and listed under
`failed_tests`. No test is ever edited. A string that names a host or a route this app must
never reach is left out, so a search of ios/ for them stays empty, and `left_out` counts them.

Schema of harvested-inputs.json:

    {"schema":1,
     "allowlist":[...], "failed_tests":[...], "passed_tests":N, "left_out":N,
     "calls":{"<module>.<function>":[<args as JSON>, ...]},
     "strings":[...], "vault":[...]}

A list under `calls` is sorted and holds each argument set once. Tokens are [text, flags] as
in common.tokens_of. The `session.handle_message` row is [text, on, status, patient_id, state],
where state is the transcript the visit held when the call came in, or null.
"""

from __future__ import annotations

import ast
import json
import re
import sys
from datetime import date, datetime
from functools import wraps
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]

ALLOWLIST = (
    "test_ai_redflags",
    "test_ai_crossturn",
    "test_ai_acceptance",
    "test_ai_refill",
    "test_ai_text",
    "test_ai_simulated",
    "test_ai_receptionist",
    "test_ai_session",
    "test_ai_medicines",
    "test_ai_doctors",
    "test_queue_expiry",
    "test_queue_flow",
    "test_queue_lifecycle",
    "test_queue_numbering",
    "test_queue_ordering",
    "test_queue_position_race",
    "test_queue_simulated",
    "test_queue_wait",
    "test_simulate_tick",
)
FORBIDDEN = ("test_ai_llm", "test_ai_runtime", "test_ai_asr", "test_api_")
VAULT_NOTES = (
    "Dawri-Vault/04 AI/Safety Guardrails.md",
    "Dawri-Vault/04 AI/AI Receptionist Design.md",
    "Dawri-Vault/03 Product/Patient Journey.md",
)

NEVER_NAMED = re.compile(r"URLSession|hf\.space|huggingface|/api/asr")

CALLS: dict[str, dict[str, list]] = {}
FAILED: list[str] = []
PASSED = [0]


def plain(value):
    """Anything a wrapped function was given, as JSON. A Token is [text, flags]."""
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, (list, tuple)):
        return [plain(item) for item in value]
    if isinstance(value, (set, frozenset)):
        return sorted(plain(item) for item in value)
    if isinstance(value, dict):
        return {str(key): plain(item) for key, item in value.items()}
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if hasattr(value, "starts_clause"):
        return [
            value.text,
            (1 if value.starts_clause else 0) | (2 if value.after_punctuation else 0),
        ]
    raise TypeError(f"cannot harvest a {type(value).__name__}")


def line(value) -> str:
    """One JSON value. A lone surrogate stays as an escape, or the file would not be UTF-8."""
    text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    try:
        text.encode("utf-8")
    except UnicodeEncodeError:
        return json.dumps(value, ensure_ascii=True, separators=(",", ":"))
    return text


def keep(name: str, args: list) -> None:
    table = CALLS.setdefault(name, {})
    table.setdefault(line(args), args)


def wrapped(name: str, original, describe):
    @wraps(original)
    def wrapper(*args, **kwargs):
        described = describe(*args, **kwargs)
        if described is not None:
            try:
                keep(name, plain(described))
            except TypeError:  # Bytes given on purpose, to test a refusal: not a text input.
                pass
        return original(*args, **kwargs)

    return wrapper


def install(module, attribute: str, describe) -> None:
    """Swaps the function everywhere backend already imported it by name."""
    original = getattr(module, attribute)
    replacement = wrapped(f"{module.__name__.rsplit('.', 1)[-1]}.{attribute}", original, describe)
    for loaded in list(sys.modules.values()):
        if (getattr(loaded, "__name__", "") or "").startswith("backend.") and (
            getattr(loaded, attribute, None) is original
        ):
            setattr(loaded, attribute, replacement)


def _handle_message(conn, ai, visit_id, text, on=None):
    row = conn.execute(
        "SELECT visit.status, visit.patient_id, intake.transcript FROM visit "
        "LEFT JOIN intake ON intake.visit_id = visit.id WHERE visit.id = ?",
        (visit_id,),
    ).fetchone()
    if row is None:
        return None
    state = json.loads(row["transcript"]) if row["transcript"] else None
    return [text, on, row["status"], row["patient_id"], state]


def install_all() -> None:
    from backend.ai import filters, receptionist, redflags, refill, session, simulated, text

    install(redflags, "check", lambda text: [text])
    install(redflags, "check_conversation", lambda text, history=(): [text, history])
    install(refill, "detect", lambda text, active_meds: [text, active_meds])
    install(
        simulated,
        "next_turn",
        lambda history, patient, denied, lang: [history, patient, denied, lang],
    )
    install(simulated, "parse_duration", lambda text, tagged=False: [text, tagged])
    install(simulated, "parse_severity", lambda text, loose=False: [text, loose])
    install(simulated, "parse_medicines", lambda text: [text])
    install(simulated, "find_complaints", lambda text: [text])
    install(simulated, "detect_lang", lambda text, current: [text, current])
    install(
        filters,
        "check_reply",
        lambda text, *, allowed_meds=(), read_back=False: (
            [text, allowed_meds] if read_back else None
        ),
    )
    install(
        receptionist,
        "run_turn",
        lambda llm, text, history, patient, denied=None, lang=None: [
            text, history, patient, denied, lang,
        ],
    )
    install(
        receptionist,
        "rule_emergency",
        lambda text, history, patient, denied=None, lang=None: [
            text, history, patient, denied, lang,
        ],
    )
    install(session, "handle_message", _handle_message)
    install(
        text,
        "is_negated",
        lambda tokens, cue_start_index, window=3, *, extra=(): [
            tokens, cue_start_index, window, extra,
        ],
    )


# Pytest hooks


def pytest_configure(config) -> None:
    from backend import main as backend_main

    backend_main.load_dotenv = lambda: None
    install_all()


def pytest_runtest_logreport(report) -> None:
    if report.when == "call" and report.passed:
        PASSED[0] += 1
    if report.failed and report.nodeid not in FAILED:
        FAILED.append(report.nodeid)


# The parts that run nothing


def test_strings() -> tuple[list[str], int]:
    found: set[str] = set()
    for path in sorted((REPO / "backend" / "tests").glob("*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                found.add(node.value)
    kept = sorted(item for item in found if not NEVER_NAMED.search(item))
    return kept, len(found) - len(kept)


_QUOTED = re.compile(r'"([^"\n]+)"|“([^”\n]+)”|\*([^*\n]+)\*|`([^`\n]+)`')


def vault_sentences() -> list[str]:
    found: set[str] = set()
    for note in VAULT_NOTES:
        for raw in (REPO / note).read_text(encoding="utf-8").splitlines():
            row = raw.strip()
            if row.startswith("|") and not set(row) <= set("|-: "):
                for cell in row.strip("|").split("|"):
                    cell = cell.strip()
                    if not cell:
                        continue
                    found.add(cell)
                    found.update(part.strip() for part in re.split("[،,]", cell) if part.strip())
            for match in _QUOTED.finditer(row):
                found.add(next(group for group in match.groups() if group).strip())
    return sorted(found)


def write(path: Path, document: dict) -> None:
    lines = ["{"]
    for key in ("schema", "allowlist", "failed_tests", "passed_tests", "left_out"):
        lines.append(f"{json.dumps(key)}:{line(document[key])},")
    lines.append('"calls":{')
    names = sorted(document["calls"])
    for index, name in enumerate(names):
        rows = document["calls"][name]
        body = ",\n".join(line(row) for row in rows)
        comma = "," if index < len(names) - 1 else ""
        lines.append(f"{json.dumps(name)}:[\n{body}\n]{comma}")
    lines.append("},")
    for key, closing in (("strings", ","), ("vault", "")):
        body = ",\n".join(line(item) for item in document[key])
        lines.append(f'"{key}":[\n{body}\n]{closing}')
    lines.append("}\n")
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(HERE.parent))
    from export import common

    common.check_environment("harvest")
    common.forbid_network("harvest")
    sys.path.insert(0, str(REPO))
    sys.path.insert(0, str(HERE))

    import pytest

    files = [f"backend/tests/{name}.py" for name in ALLOWLIST]
    assert not any(name.startswith(FORBIDDEN) for name in ALLOWLIST)
    status = pytest.main(
        ["-q", "--no-header", "-p", "no:cacheprovider",
         "-p", "harvest_plugin", *files],
        plugins=[sys.modules[__name__]],
    )
    print(f"harvest: pytest finished with {status}, {PASSED[0]} passed, {len(FAILED)} failed")
    for node in FAILED:
        print(f"harvest: dropped {node}")

    strings, left_out = test_strings()
    document = {
        "schema": 1,
        "allowlist": list(ALLOWLIST),
        "failed_tests": sorted(FAILED),
        "passed_tests": PASSED[0],
        "left_out": left_out,
        "calls": {
            name: [table[key] for key in sorted(table)] for name, table in CALLS.items()
        },
        "strings": strings,
        "vault": vault_sentences(),
    }
    write(HERE / "harvested-inputs.json", document)
    sizes = {name: len(rows) for name, rows in document["calls"].items()}
    print(f"harvest: {sizes}, {len(document['strings'])} strings, {len(document['vault'])} vault")


if __name__ == "__main__":
    main()
