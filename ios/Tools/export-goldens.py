#!/usr/bin/env python3
"""Writes the golden corpus by running the real backend functions, with no model and no network.

    HF_TOKEN= HF_HUB_OFFLINE=1 SIMULATE_LOAD=1 DAWRI_DB=<temp file outside the repo> \
        PYTHONDONTWRITEBYTECODE=1 .venv/bin/python ios/Tools/export-goldens.py [--check]

--check rebuilds in memory and exits 1 if anything differs. --only rules, clinic or journeys runs
one folder. Goldens are never edited by hand. The inputs come from export/variants.py and
export/harvested-inputs.json, so this needs no pytest. The columns of each file are in the
docstring of ios/Tools/export/rules.py, clinic.py and journeys.py.
"""

from __future__ import annotations

import json
import sys

sys.dont_write_bytecode = True  # Nothing goes in ios/, however this is started.

from export import common  # noqa: E402

TOOL = "export-goldens"


def table(name: str, files: dict[str, bytes]) -> bool:
    """Prints count against minimum for a folder. False if any minimum or size limit fails."""
    manifest = json.loads(files["manifest.json"])
    ok = True
    print(f"{name}:")
    for family, entry in manifest["families"].items():
        met = entry["count"] >= entry["minimum"]
        ok = ok and met
        print(f"  {family:<24}{entry['count']:>8}  minimum {entry['minimum']:>6}  {'met' if met else 'NOT MET'}")
    for file, entry in manifest["files"].items():
        if entry["bytes"] > common.MAX_FILE_BYTES:
            print(f"  {file} is over the 25 MB limit", file=sys.stderr)
            ok = False
    if manifest["excluded"]:
        print(f"  excluded: {len(manifest['excluded'])}")
    return ok


def main() -> None:
    args = common.arguments(__doc__)
    common.enter(TOOL)

    from export import clinic, journeys, rules

    ok = True
    total = 0
    for name, section in (("rules", rules), ("clinic", clinic), ("journeys", journeys)):
        if args.only not in (None, name):
            continue
        files = section.goldens()
        ok = table(name, files) and ok
        total += sum(len(body) for body in files.values())
        ok = common.sync(common.GOLDENS / name, files, check=args.check, tool=TOOL) and ok
    if args.only is None:
        print(f"{TOOL}: {total / 1e6:.2f} MB in all")
        if total > common.MAX_GOLDEN_BYTES:
            print(f"{TOOL}: over the 40 MB limit", file=sys.stderr)
            ok = False
    if not ok:
        raise SystemExit(1)


if __name__ == "__main__":
    sys.exit(main())
