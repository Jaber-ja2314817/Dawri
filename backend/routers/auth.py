"""Demo login for patients and staff."""

from __future__ import annotations

import sqlite3
from typing import Any

from fastapi import APIRouter, Depends
from pydantic import BaseModel

from backend import auth, mock_health
from backend.deps import ApiError, get_conn, require_patient

router = APIRouter(prefix="/api")


class AuthStart(BaseModel):
    qid: str


class AuthVerify(BaseModel):
    qid: str
    otp: str


class StaffLogin(BaseModel):
    staff_id: str


def _patient_by_qid(conn: sqlite3.Connection, qid: str) -> dict[str, Any]:
    patient = mock_health.find_by_qid(conn, qid)
    if patient is None:
        raise ApiError(404, "unknown_qid", "No demo patient has this QID.")
    return patient


@router.post("/auth/start")
def auth_start(body: AuthStart, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    _patient_by_qid(conn, body.qid)
    return {"otp_sent": True}


@router.post("/auth/verify")
def auth_verify(body: AuthVerify, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    patient_id = _patient_by_qid(conn, body.qid)["id"]
    if not auth.verify_otp(body.otp):
        raise ApiError(401, "invalid_otp", "That code is not correct.")
    token = auth.create_session(conn, "patient", patient_id)
    return {"token": token, "patient": mock_health.get_patient(conn, patient_id)}


@router.get("/me")
def me(
    session: sqlite3.Row = Depends(require_patient),
    conn: sqlite3.Connection = Depends(get_conn),
) -> dict:
    patient_id = session["subject_id"]
    return {
        "patient": mock_health.get_patient(conn, patient_id),
        "dependents": mock_health.get_dependents(conn, patient_id),
        "record": mock_health.get_record(conn, patient_id),
    }


@router.get("/auth/demo-patients")
def demo_patients(conn: sqlite3.Connection = Depends(get_conn)) -> list[dict]:
    return mock_health.list_demo_patients(conn)


@router.post("/staff/login")
def staff_login(body: StaffLogin, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
    staff = conn.execute(
        "SELECT id, name, role, clinic, centre_id FROM staff WHERE id = ?",
        (body.staff_id,),
    ).fetchone()
    if staff is None:
        raise ApiError(404, "unknown_staff", "No demo staff member has this ID.")
    counters = conn.execute(
        "SELECT * FROM counter WHERE staff_id = ? ORDER BY id", (body.staff_id,)
    ).fetchall()
    return {
        "token": auth.create_session(conn, "staff", staff["id"]),
        "staff": dict(staff),
        "counters": [dict(counter) for counter in counters],
    }
