"""Plumbing shared by the two exporters. Nothing here imports backend at module level.

check_environment() must pass before any backend import, because backend/main.py calls
load_dotenv() and a run without the blank variable would be a real one. enter() is the only
way in: it refuses, blocks every outgoing connection, freezes the clock and replaces
load_dotenv, in that order, so a section can import backend freely afterwards.

Output is byte-deterministic. Goldens hold one case per line, so a diff shows the cases that
moved. Every golden file has this shape, and each section's docstring gives the columns:

    {"schema":1,"name":"<file stem>","family":"<corpus family>","columns":[...],<extra header
    keys>,"cases":[
    [...],
    [...]
    ]}

A folder's manifest.json is:

    {"schema":1,"unidata_version":"16.0.0","sources":{"backend/...":"<sha256>"},
     "families":{"<family>":{"count":N,"minimum":M}},
     "files":{"<file>.json":{"family":"<family>","count":N,"sha256":"<hex>","bytes":N}},
     "excluded":[{"file":"<file>.json","input":"<start of the input>","reason":"..."}],
     "notes":{...}}

`count` is the number of rows in `cases`, and `sha256` is of the file's bytes.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
import socket
import sys
import unicodedata
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable

REPO = Path(__file__).resolve().parents[3]
RESOURCES = REPO / "ios" / "DawriCore" / "Sources" / "DawriCore" / "Resources"
GOLDENS = REPO / "ios" / "DawriCore" / "Tests" / "DawriCoreTests" / "Fixtures" / "goldens"
HARVEST = Path(__file__).resolve().parent / "harvested-inputs.json"

SCHEMA = 1
MAX_FILE_BYTES = 25 * 1024 * 1024
MAX_GOLDEN_BYTES = 40 * 1024 * 1024

# Doha midday, so nothing crosses the midnight that turns ticket numbers over by accident.
START = datetime(2026, 11, 7, 9, 0, tzinfo=timezone.utc)

MINIMUMS = {
    "rules": {
        "text": 5000,
        "regex": 2000,
        "redflags_single": 60000,
        "redflags_conversation": 5000,
        "refill": 8000,
        "parsers": 5000,
        "readback": 3000,
        "next_turn": 5000,
    },
    "clinic": {
        "queue_traces": 200,
        "medicines": 1000,
        "doctors": 500,
        "centres": 500,
        "geo": 200,
        "time": 200,
        "allergy": 100,
        "mock_health": 1,
    },
    "journeys": {"sessions": 2000, "api": 1, "refusals": 30},
}


def refuse(tool: str, message: str) -> None:
    print(f"{tool}: {message}", file=sys.stderr)
    raise SystemExit(2)


def check_environment(tool: str) -> None:
    """Everything here must pass before backend can be imported."""
    if os.environ.get("HF_TOKEN") != "":
        refuse(tool, "refusing to run: HF_TOKEN must be present and blank (HF_TOKEN= on the command line)")
    if os.environ.get("SIMULATE_LOAD") != "1":
        refuse(tool, "refusing to run: SIMULATE_LOAD must be 1")
    db_file = os.environ.get("DAWRI_DB", "").strip()
    if not db_file:
        refuse(tool, "refusing to run: DAWRI_DB must name a temp file")
    if REPO in Path(db_file).resolve().parents:
        refuse(tool, "refusing to run: DAWRI_DB must be outside the repo")


def forbid_network(tool: str) -> None:
    """Everything stays in process, so any outgoing connection here is a bug."""

    def blocked(self, address):
        raise RuntimeError(f"{tool}: blocked a connection to {address!r}")

    socket.socket.connect = blocked
    socket.socket.connect_ex = blocked


class Clock:
    """Stands in for timeutil.utcnow. It moves only when a caller moves it."""

    def __init__(self, now: datetime = START) -> None:
        self.now = now

    def __call__(self) -> datetime:
        return self.now

    def set(self, now: datetime) -> None:
        self.now = now

    def advance(self, **delta: float) -> None:
        self.now += timedelta(**delta)


CLOCK = Clock()


def enter(tool: str) -> None:
    """The one way in. Nothing from backend may be imported before this returns."""
    check_environment(tool)
    os.environ["HF_HUB_OFFLINE"] = "1"
    sys.dont_write_bytecode = True
    forbid_network(tool)
    if str(REPO) not in sys.path:
        sys.path.insert(0, str(REPO))

    # Before queue_engine is imported: it takes utcnow as a default argument.
    from backend import timeutil

    timeutil.utcnow = CLOCK

    from backend import main as backend_main

    backend_main.load_dotenv = lambda: None  # Nothing here opens .env.

    from backend import config

    if config.ai_mode() != "simulated":
        refuse(tool, "aborting: backend says ai_mode is not simulated")


def arguments(description: str) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--check", action="store_true", help="compare with the files on disk")
    parser.add_argument(
        "--only", choices=("rules", "clinic", "journeys"), help="only this section"
    )
    return parser.parse_args()


# JSON


def text_of(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def encodable(value: Any) -> bool:
    """False for a lone surrogate, which neither UTF-8 nor a Swift String can hold."""
    try:
        text_of(value).encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def resource_bytes(document: dict) -> bytes:
    """A data resource: each top-level key on its line, and each row of a table on its own."""
    lines = []
    keys = list(document)
    for index, key in enumerate(keys):
        value = document[key]
        comma = "," if index < len(keys) - 1 else ""
        if isinstance(value, list) and value and isinstance(value[0], (list, dict)):
            rows = ",\n".join(text_of(row) for row in value)
            lines.append(f"{text_of(key)}:[\n{rows}\n]{comma}")
        else:
            lines.append(f"{text_of(key)}:{text_of(value)}{comma}")
    return ("{\n" + "\n".join(lines) + "\n}\n").encode("utf-8")


def golden_bytes(name: str, family: str, columns: list, header: dict, rows: Iterable[list]) -> bytes:
    head = {"schema": SCHEMA, "name": name, "family": family, "columns": columns, **header}
    body = ",\n".join(text_of(row) for row in rows)
    return (text_of(head)[:-1] + ',"cases":[\n' + body + "\n]}\n").encode("utf-8")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sources(paths: Iterable[str]) -> dict[str, str]:
    return {path: sha256((REPO / path).read_bytes()) for path in sorted(set(paths))}


def manifest_bytes(document: dict) -> bytes:
    return (json.dumps(document, ensure_ascii=False, indent=1) + "\n").encode("utf-8")


class Folder:
    """One goldens folder, built up in memory. Nothing touches the disk until sync()."""

    def __init__(self, name: str, source_paths: Iterable[str]) -> None:
        self.name = name
        self.source_paths = list(source_paths)
        self.files: dict[str, bytes] = {}
        self.entries: dict[str, dict] = {}
        self.excluded: list[dict] = []
        self.notes: dict[str, Any] = {}

    def add(
        self, name: str, family: str, columns: list, header: dict, rows: list[list]
    ) -> None:
        data = golden_bytes(name, family, columns, header, rows)
        file = f"{name}.json"
        self.files[file] = data
        self.entries[file] = {
            "family": family,
            "count": len(rows),
            "sha256": sha256(data),
            "bytes": len(data),
        }
        print(f"  {self.name}/{file}: {len(rows)} cases, {len(data) / 1e6:.2f} MB", flush=True)

    def exclude(self, file: str, value: Any, reason: str) -> None:
        shown = value if isinstance(value, str) else repr(value)
        if len(shown) > 160:
            shown = f"{shown[:120]}... ({len(shown)} code points)"
        shown = shown.encode("utf-8", "backslashreplace").decode("utf-8")
        entry = {"file": f"{file}.json", "input": shown, "reason": reason}
        if entry not in self.excluded:
            self.excluded.append(entry)

    def finish(self) -> dict[str, bytes]:
        families: dict[str, dict] = {}
        for entry in self.entries.values():
            family = families.setdefault(
                entry["family"], {"count": 0, "minimum": MINIMUMS[self.name].get(entry["family"], 0)}
            )
            family["count"] += entry["count"]
        document = {
            "schema": SCHEMA,
            "unidata_version": unicodedata.unidata_version,
            "sources": sources(self.source_paths),
            "families": dict(sorted(families.items())),
            "files": dict(sorted(self.entries.items())),
            "excluded": self.excluded,
            "notes": self.notes,
        }
        return {**self.files, "manifest.json": manifest_bytes(document)}


def sync(folder: Path, files: dict[str, bytes], *, check: bool, tool: str, keep_glob: str = "*.json") -> bool:
    """Write the files, or with check compare them. Anything stale is removed or reported."""
    on_disk = {path.name for path in folder.glob(keep_glob)} if folder.exists() else set()
    problems = [f"{name} is stale" for name in sorted(on_disk - set(files))]
    if check:
        for name, data in sorted(files.items()):
            path = folder / name
            if not path.exists():
                problems.append(f"{name} is missing")
            elif path.read_bytes() != data:
                problems.append(f"{name} differs from a fresh export")
        for problem in problems:
            print(f"{tool}: {problem}", file=sys.stderr)
        return not problems
    folder.mkdir(parents=True, exist_ok=True)
    for name in sorted(on_disk - set(files)):
        (folder / name).unlink()
    for name, data in sorted(files.items()):
        (folder / name).write_bytes(data)
    return True


# Reading the Python source, so a literal in code is checked against the code, not retyped


def function_constants(path: str, function: str) -> list[str]:
    tree = ast.parse((REPO / path).read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == function:
            return [
                item.value
                for item in ast.walk(node)
                if isinstance(item, ast.Constant) and isinstance(item.value, str)
            ]
    raise SystemExit(f"{path} has no function {function}")


def literal(path: str, function: str, value: str) -> str:
    """A literal that a function hard-codes. Fails loudly once the source stops saying it."""
    if value not in function_constants(path, function):
        raise SystemExit(f"{path}:{function} no longer holds the literal {value!r}")
    return value


# Common shapes


def ranges(code_points: Iterable[int]) -> list[list[int]]:
    """Sorted, inclusive [first, last] pairs."""
    result: list[list[int]] = []
    for point in sorted(code_points):
        if result and result[-1][1] == point - 1:
            result[-1][1] = point
        else:
            result.append([point, point])
    return result


def pairs(table: dict, value=lambda item: item) -> list[list]:
    """A dict as [key, value] rows in source order. Where order matters, a dict would lose it."""
    return [[key, value(item)] for key, item in table.items()]


def tuples(phrases: Iterable[Iterable[str]]) -> list[list[str]]:
    return [list(phrase) for phrase in phrases]


def tokens_of(tokens: Iterable[Any]) -> list[list]:
    """Tokens as [text, flags]: bit 0 is starts_clause, bit 1 is after_punctuation."""
    return [
        [token.text, (1 if token.starts_clause else 0) | (2 if token.after_punctuation else 0)]
        for token in tokens
    ]


def dedupe(items: Iterable[tuple]) -> list[tuple]:
    """Keeps the first of each key, where the key is everything after the first field."""
    seen: dict[str, tuple] = {}
    for item in items:
        key = text_of(item[1:]) if encodable(item[1:]) else repr(item[1:])
        seen.setdefault(key, item)
    return list(seen.values())


class Index:
    """A header table that rows refer to by position, so a long value is stored once."""

    def __init__(self) -> None:
        self.rows: list = []
        self._seen: dict[str, int] = {}

    def __call__(self, value: Any) -> int:
        key = text_of(value)
        if key not in self._seen:
            self._seen[key] = len(self.rows)
            self.rows.append(value)
        return self._seen[key]


def load_harvest() -> dict:
    if not HARVEST.exists():
        raise SystemExit(f"{HARVEST} is missing: run ios/Tools/export/harvest_plugin.py once")
    return json.loads(HARVEST.read_text(encoding="utf-8"))
