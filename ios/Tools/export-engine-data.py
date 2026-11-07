#!/usr/bin/env python3
"""Writes the engine's data resources from the Python source, so nothing is retyped.

    HF_TOKEN= HF_HUB_OFFLINE=1 SIMULATE_LOAD=1 DAWRI_DB=<temp file outside the repo> \
        PYTHONDONTWRITEBYTECODE=1 .venv/bin/python ios/Tools/export-engine-data.py [--check]

--check rebuilds in memory and exits 1 if a resource differs from a fresh export. --only rules,
clinic or journeys runs one section, and journeys has no data. What each file holds is in the
docstring of ios/Tools/export/rules.py and clinic.py.
"""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # Nothing goes in ios/, however this is started.

from export import common  # noqa: E402

TOOL = "export-engine-data"


def main() -> None:
    args = common.arguments(__doc__)
    common.enter(TOOL)

    from export import clinic, rules

    ok = True
    sections = {"rules": (rules.data, "engine.rules.*.json"), "clinic": (clinic.data, "engine.clinic.*.json")}
    for name, (build, pattern) in sections.items():
        if args.only not in (None, name):
            continue
        files = build()
        ok = common.sync(common.RESOURCES, files, check=args.check, tool=TOOL, keep_glob=pattern) and ok
        total = sum(len(body) for body in files.values())
        print(f"{TOOL}: ai_mode simulated, {name}: {len(files)} files, {total / 1e6:.2f} MB")
    if not ok:
        raise SystemExit(1)


if __name__ == "__main__":
    sys.exit(main())
