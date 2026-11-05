"""Mock national health record: synthetic patients served in a FHIR-like shape.

get_patient and get_record return None for an unknown patient, as find_by_qid does.
"""

from __future__ import annotations

import sqlite3
from datetime import date, datetime
from typing import Any

from backend import db, timeutil

_PATIENT_SELECT = """
SELECT p.*, c.id AS centre_key, c.name_en AS centre_name_en, c.name_ar AS centre_name_ar
FROM patient p
LEFT JOIN centre c ON c.id = p.registered_centre_id
"""


def _patient_dict(row: sqlite3.Row, on: datetime | date | None) -> dict[str, Any]:
    return {
        "id": row["id"],
        "qid_demo": row["qid_demo"],
        "full_name_en": row["full_name_en"],
        "full_name_ar": row["full_name_ar"],
        "dob": row["dob"],
        "age": timeutil.age_on(row["dob"], on if on is not None else timeutil.utcnow()),
        "sex": row["sex"],
        "preferred_lang": row["preferred_lang"],
        "allergies": db.loads_list(row["allergies"]),
        "chronic": db.loads_list(row["chronic"]),
        "active_meds": db.loads_list(row["active_meds"]),
        "registered_centre": {
            "id": row["centre_key"],
            "name_en": row["centre_name_en"],
            "name_ar": row["centre_name_ar"],
        },
        "demo": True,
    }


def find_by_qid(conn: sqlite3.Connection, qid: str) -> dict[str, Any] | None:
    row = conn.execute(_PATIENT_SELECT + "WHERE p.qid_demo = ?", (qid,)).fetchone()
    return _patient_dict(row, None) if row is not None else None


def get_patient(
    conn: sqlite3.Connection, patient_id: str, on: datetime | date | None = None
) -> dict[str, Any] | None:
    row = conn.execute(_PATIENT_SELECT + "WHERE p.id = ?", (patient_id,)).fetchone()
    return _patient_dict(row, on) if row is not None else None


def get_dependents(
    conn: sqlite3.Connection, guardian_id: str, on: datetime | date | None = None
) -> list[dict[str, Any]]:
    rows = conn.execute(
        _PATIENT_SELECT
        + """
        JOIN dependent_link d ON d.dependent_id = p.id
        WHERE d.guardian_id = ?
        ORDER BY p.id
        """,
        (guardian_id,),
    ).fetchall()
    return [_patient_dict(row, on) for row in rows]


def list_demo_patients(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    rows = conn.execute(
        """
        SELECT id, qid_demo, full_name_en, full_name_ar
        FROM patient
        WHERE id NOT IN (SELECT dependent_id FROM dependent_link)
        ORDER BY id
        """
    ).fetchall()
    return [dict(row) for row in rows]


def get_record(conn: sqlite3.Connection, patient_id: str) -> dict[str, Any] | None:
    row = conn.execute("SELECT * FROM patient WHERE id = ?", (patient_id,)).fetchone()
    if row is None:
        return None
    reference = {"reference": f"Patient/{row['id']}"}
    resources: list[dict[str, Any]] = [
        {
            "resourceType": "Patient",
            "id": row["id"],
            "identifier": [{"system": "urn:dawri:demo-qid", "value": row["qid_demo"]}],
            "name": [
                {"text": row["full_name_en"], "language": "en"},
                {"text": row["full_name_ar"], "language": "ar"},
            ],
            "gender": {"F": "female", "M": "male"}[row["sex"]],
            "birthDate": row["dob"],
        }
    ]
    resources += [
        {
            "resourceType": "AllergyIntolerance",
            "patient": reference,
            "code": {"text": allergy},
        }
        for allergy in db.loads_list(row["allergies"])
    ]
    resources += [
        {"resourceType": "Condition", "subject": reference, "code": {"text": condition}}
        for condition in db.loads_list(row["chronic"])
    ]
    resources += [
        {
            "resourceType": "MedicationStatement",
            "status": "active",
            "subject": reference,
            "medicationCodeableConcept": {"text": med},
        }
        for med in db.loads_list(row["active_meds"])
    ]
    return {
        "resourceType": "Bundle",
        "type": "collection",
        "demo": True,
        "entry": [{"resource": resource} for resource in resources],
    }
