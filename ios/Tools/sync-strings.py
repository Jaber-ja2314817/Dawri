#!/usr/bin/env python3
"""Generates the app's strings from the website's, so the two cannot drift.

Reads the patient dictionaries in the order frontend/src/i18n/index.tsx merges them, later
files winning, and leaves out every staff.* file. Adds the phone-only keys from
ios/Tools/strings/, refusing one that collides with a web key. Writes the sorted result to
ios/DawriCore/Sources/DawriCore/Resources/, with the Arabic record terms from record.ts.

    python3 ios/Tools/sync-strings.py            write the resources
    python3 ios/Tools/sync-strings.py --check    print what differs, write nothing, exit 1 if any
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
I18N = REPO / "frontend" / "src" / "i18n"
PHONE_ONLY = REPO / "ios" / "Tools" / "strings"
RESOURCES = REPO / "ios" / "DawriCore" / "Sources" / "DawriCore" / "Resources"
LANGS = ("en", "ar")
PLACEHOLDER = re.compile(r"\{(\w+)\}")


def die(message: str) -> None:
    print(f"sync-strings: {message}", file=sys.stderr)
    raise SystemExit(1)


def load(path: Path) -> dict[str, str]:
    return json.loads(path.read_text(encoding="utf-8"))


def patient_files(lang: str) -> list[Path]:
    """The files index.tsx spreads into this language's dictionary, in its order."""
    source = (I18N / "index.tsx").read_text(encoding="utf-8")
    imports = dict(re.findall(r"^import (\w+) from '\./([\w.]+\.json)'", source, re.M))
    block = re.search(rf"^\s*{lang}: \{{\n(.*?)^\s*\}},", source, re.M | re.S)
    if block is None:
        die(f"no dictionary for {lang} in index.tsx")
    files = [imports[name] for name in re.findall(r"\.\.\.(\w+)", block.group(1))]
    patient = [name for name in files if not name.startswith("staff.")]
    if not patient:
        die(f"no patient files for {lang} in index.tsx")
    return [I18N / name for name in patient]


def web_dictionary(lang: str) -> dict[str, str]:
    merged: dict[str, str] = {}
    for path in patient_files(lang):
        merged.update(load(path))
    return merged


def bundled_dictionary(lang: str) -> dict[str, str]:
    web = web_dictionary(lang)
    phone = load(PHONE_ONLY / f"ios.{lang}.json")
    collisions = sorted(set(web) & set(phone))
    if collisions:
        die(f"phone-only keys collide with web keys in {lang}: {', '.join(collisions)}")
    return {**web, **phone}


def validate(dictionaries: dict[str, dict[str, str]]) -> None:
    english, arabic = dictionaries["en"], dictionaries["ar"]
    only_one = sorted(set(english) ^ set(arabic))
    if only_one:
        die(f"keys in one language only: {', '.join(only_one)}")
    staff = sorted(key for key in english if key.startswith("staff."))
    if staff:
        die(f"staff keys in the patient strings: {', '.join(staff)}")
    uneven = sorted(
        key
        for key in english
        if set(PLACEHOLDER.findall(english[key])) != set(PLACEHOLDER.findall(arabic[key]))
    )
    if uneven:
        die(f"placeholders differ between languages: {', '.join(uneven)}")


def record_terms() -> dict[str, str]:
    """The ARABIC table of record.ts. A line this cannot read stops the run."""
    source = (I18N / "record.ts").read_text(encoding="utf-8")
    table = re.search(r"^const ARABIC[^=]*= \{\n(.*?)^\}", source, re.M | re.S)
    if table is None:
        die("no ARABIC table in record.ts")
    terms: dict[str, str] = {}
    for line in table.group(1).splitlines():
        entry = re.fullmatch(r"\s*(?:'([^']+)'|(\w+)): '([^']*)',", line)
        if entry is None:
            die(f"cannot read this line of record.ts: {line.strip()}")
        terms[entry.group(1) or entry.group(2)] = entry.group(3)
    return terms


def rendered(table: dict[str, str]) -> str:
    return json.dumps(table, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def tables() -> dict[str, dict[str, str]]:
    dictionaries = {lang: bundled_dictionary(lang) for lang in LANGS}
    validate(dictionaries)
    return {
        **{f"strings.{lang}.json": table for lang, table in dictionaries.items()},
        "record.ar.json": record_terms(),
    }


def differences(path: Path, wanted: dict[str, str]) -> list[str]:
    if not path.exists():
        return [f"{path.name}: missing"]
    if path.read_text(encoding="utf-8") == rendered(wanted):
        return []
    try:
        current = load(path)
    except json.JSONDecodeError as error:
        return [f"{path.name}: not valid JSON ({error})"]
    keys = sorted(key for key in set(current) | set(wanted) if current.get(key) != wanted.get(key))
    return [f"{path.name}: {key}" for key in keys] or [f"{path.name}: layout differs"]


def main() -> None:
    args = sys.argv[1:]
    if args not in ([], ["--check"]):
        die("usage: sync-strings.py [--check]")
    wanted = tables()
    if args:
        found = [line for name, table in wanted.items() for line in differences(RESOURCES / name, table)]
        if found:
            print("sync-strings: out of date. Differing keys:", file=sys.stderr)
            for line in found:
                print(f"  {line}", file=sys.stderr)
            raise SystemExit(1)
        print("sync-strings: up to date")
        return
    RESOURCES.mkdir(parents=True, exist_ok=True)
    for name, table in wanted.items():
        (RESOURCES / name).write_text(rendered(table), encoding="utf-8")
    print(f"sync-strings: wrote {', '.join(wanted)}")


if __name__ == "__main__":
    main()
