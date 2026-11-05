"""Loads the static seed files. Queue state is seeded elsewhere."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any

from backend import db

SEED_DIR = Path(__file__).resolve().parent / "seed"

_SEEDED_TABLES = ("centre", "patient", "staff", "counter", "drug")


def _load(name: str) -> list[dict[str, Any]]:
    with (SEED_DIR / name).open(encoding="utf-8") as f:
        return json.load(f)


def _insert(
    conn: sqlite3.Connection,
    table: str,
    rows: list[dict[str, Any]],
    columns: tuple[str, ...],
    json_columns: tuple[str, ...] = (),
) -> None:
    placeholders = ", ".join("?" for _ in columns)
    sql = f"INSERT OR IGNORE INTO {table} ({', '.join(columns)}) VALUES ({placeholders})"
    for row in rows:
        values = [
            db.dumps(row[col]) if col in json_columns else row[col] for col in columns
        ]
        conn.execute(sql, values)


def seed_static(conn: sqlite3.Connection) -> None:
    staff_columns = ("id", "centre_id", "name", "role", "clinic", "languages", "gender")
    with db.transaction(conn):
        _insert(
            conn,
            "centre",
            _load("centres.json"),
            (
                "id",
                "name_en",
                "name_ar",
                "operator",
                "lat",
                "lng",
                "services",
                "has_emergency",
                "priority_age_min",
            ),
            ("services",),
        )
        _insert(
            conn,
            "patient",
            _load("patients.json"),
            (
                "id",
                "qid_demo",
                "full_name_en",
                "full_name_ar",
                "dob",
                "sex",
                "preferred_lang",
                "registered_centre_id",
                "allergies",
                "chronic",
                "active_meds",
            ),
            ("allergies", "chronic", "active_meds"),
        )
        _insert(
            conn,
            "dependent_link",
            _load("dependents.json"),
            ("guardian_id", "dependent_id"),
        )
        _insert(conn, "staff", _load("doctors.json"), staff_columns, ("languages",))
        _insert(conn, "staff", _load("staff.json"), staff_columns, ("languages",))
        _insert(
            conn,
            "counter",
            _load("counters.json"),
            (
                "id",
                "centre_id",
                "stage",
                "label",
                "label_ar",
                "staff_id",
                "prefix",
                "avg_service_sec",
            ),
        )
        _insert(
            conn,
            "drug",
            _load("drugs.json"),
            (
                "id",
                "name_en",
                "name_ar",
                "form",
                "default_dose",
                "default_frequency",
                "default_days",
                "allergy_tags",
                "demo_default",
            ),
            ("allergy_tags",),
        )


def is_seeded(conn: sqlite3.Connection) -> bool:
    return all(
        conn.execute(f"SELECT 1 FROM {table} LIMIT 1").fetchone() is not None
        for table in _SEEDED_TABLES
    )
