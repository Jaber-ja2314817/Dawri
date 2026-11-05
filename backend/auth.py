"""Demo login: session tokens, the fixed OTP and who may see which patient."""

from __future__ import annotations

import secrets
import sqlite3

from backend import timeutil

DEMO_OTP = "0000"


def create_session(conn: sqlite3.Connection, kind: str, subject_id: str) -> str:
    token = secrets.token_urlsafe(32)
    conn.execute(
        "INSERT INTO session (token, kind, subject_id, created_at) VALUES (?, ?, ?, ?)",
        (token, kind, subject_id, timeutil.iso(timeutil.utcnow())),
    )
    return token


def lookup_session(conn: sqlite3.Connection, token: str) -> sqlite3.Row | None:
    return conn.execute("SELECT * FROM session WHERE token = ?", (token,)).fetchone()


def verify_otp(otp: str) -> bool:
    return otp == DEMO_OTP


def can_access_patient(
    conn: sqlite3.Connection, patient_session_subject: str, patient_id: str
) -> bool:
    """A patient may act for themselves and for their linked dependents."""
    if patient_session_subject == patient_id:
        return True
    link = conn.execute(
        "SELECT 1 FROM dependent_link WHERE guardian_id = ? AND dependent_id = ?",
        (patient_session_subject, patient_id),
    ).fetchone()
    return link is not None
