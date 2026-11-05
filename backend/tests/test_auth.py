from __future__ import annotations

import pytest
from fastapi import Depends
from fastapi.testclient import TestClient

from backend import auth, db, deps
from backend.main import app


@pytest.fixture
def client(db_path, monkeypatch):
    monkeypatch.setattr("backend.main.load_dotenv", lambda: None)
    monkeypatch.delenv("SIMULATE_LOAD", raising=False)
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture
def add_route():
    saved = list(app.router.routes)
    yield app.add_api_route
    app.router.routes[:] = saved


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


def patient_token(client, qid="DEMO-10001"):
    assert client.post("/api/auth/start", json={"qid": qid}).json() == {"otp_sent": True}
    response = client.post("/api/auth/verify", json={"qid": qid, "otp": "0000"})
    assert response.status_code == 200
    return response.json()["token"]


def staff_token(client, staff_id="S-WAK-NURSE1"):
    return client.post("/api/staff/login", json={"staff_id": staff_id}).json()["token"]


def test_full_login(client):
    start = client.post("/api/auth/start", json={"qid": "DEMO-10001"})
    assert start.status_code == 200
    verify = client.post("/api/auth/verify", json={"qid": "DEMO-10001", "otp": "0000"})
    assert verify.status_code == 200
    body = verify.json()
    assert body["patient"]["id"] == "P001"
    assert body["patient"]["allergies"] == ["penicillin"]
    me = client.get("/api/me", headers=bearer(body["token"]))
    assert me.status_code == 200
    assert me.json()["patient"]["id"] == "P001"


def test_each_login_gets_its_own_token(client):
    assert patient_token(client) != patient_token(client)


def test_wrong_otp(client):
    response = client.post("/api/auth/verify", json={"qid": "DEMO-10001", "otp": "1234"})
    assert response.status_code == 401
    assert response.json()["error"] == "invalid_otp"


def test_wrong_otp_creates_no_session(client):
    client.post("/api/auth/verify", json={"qid": "DEMO-10001", "otp": "1234"})
    conn = db.connect()
    assert conn.execute("SELECT COUNT(*) FROM session").fetchone()[0] == 0
    conn.close()


@pytest.mark.parametrize(
    ("path", "body"),
    [
        ("/api/auth/start", {"qid": "DEMO-99999"}),
        ("/api/auth/verify", {"qid": "DEMO-99999", "otp": "0000"}),
    ],
)
def test_unknown_qid(client, path, body):
    response = client.post(path, json=body)
    assert response.status_code == 404
    assert response.json()["error"] == "unknown_qid"
    assert response.json()["message"]


def test_malformed_body_is_rejected(client):
    assert client.post("/api/auth/start", json={}).status_code == 422


def test_me_without_a_token(client):
    assert client.get("/api/me").status_code == 401


def test_me_with_an_unknown_token(client):
    assert client.get("/api/me", headers=bearer("nope")).status_code == 401


def test_me_with_a_non_bearer_scheme(client):
    token = patient_token(client)
    response = client.get("/api/me", headers={"Authorization": f"Basic {token}"})
    assert response.status_code == 401


def test_me_with_a_staff_token(client):
    assert client.get("/api/me", headers=bearer(staff_token(client))).status_code == 403


def test_query_string_token_is_rejected_on_me(client):
    token = patient_token(client)
    assert client.get("/api/me", params={"token": token}).status_code == 401


def test_me_shows_dependents_and_record(client):
    body = client.get("/api/me", headers=bearer(patient_token(client))).json()
    assert [dependent["id"] for dependent in body["dependents"]] == ["P004", "P005"]
    assert body["record"]["resourceType"] == "Bundle"
    assert body["record"]["demo"] is True


def test_demo_patients_have_the_vault_three_and_no_dependents(client):
    body = client.get("/api/auth/demo-patients").json()
    by_id = {patient["id"]: patient["qid_demo"] for patient in body}
    assert by_id["P001"] == "DEMO-10001"
    assert by_id["P002"] == "DEMO-10002"
    assert by_id["P003"] == "DEMO-10003"
    assert not {"P004", "P005"} & set(by_id)


def test_staff_login(client):
    response = client.post("/api/staff/login", json={"staff_id": "S-WAK-NURSE1"})
    assert response.status_code == 200
    body = response.json()
    assert body["staff"] == {
        "id": "S-WAK-NURSE1",
        "name": "Amal Al-Demo",
        "role": "nurse",
        "clinic": None,
        "centre_id": "C-WAKRA",
    }
    assert [counter["id"] for counter in body["counters"]] == ["C-WAKRA-T1"]
    assert body["token"]


def test_unknown_staff(client):
    response = client.post("/api/staff/login", json={"staff_id": "S-NOBODY"})
    assert response.status_code == 404
    assert response.json()["error"] == "unknown_staff"


def test_can_access_patient(seeded):
    assert auth.can_access_patient(seeded, "P001", "P001")
    assert auth.can_access_patient(seeded, "P001", "P004")
    assert auth.can_access_patient(seeded, "P001", "P005")
    assert not auth.can_access_patient(seeded, "P002", "P001")
    assert not auth.can_access_patient(seeded, "P002", "P004")
    assert not auth.can_access_patient(seeded, "P004", "P001")


def test_session_round_trip(seeded):
    token = auth.create_session(seeded, "staff", "S-WAK-NURSE1")
    row = auth.lookup_session(seeded, token)
    assert (row["kind"], row["subject_id"]) == ("staff", "S-WAK-NURSE1")
    assert auth.lookup_session(seeded, "nope") is None


def test_verify_otp():
    assert auth.verify_otp("0000")
    assert not auth.verify_otp("0001")
    assert not auth.verify_otp("")


def test_require_staff(client, add_route):
    def staff_only(session=Depends(deps.require_staff)):
        return {"subject": session["subject_id"]}

    add_route("/api/test-staff-only", staff_only)
    staff = staff_token(client)
    allowed = client.get("/api/test-staff-only", headers=bearer(staff))
    assert allowed.json() == {"subject": "S-WAK-NURSE1"}
    patient = patient_token(client)
    assert client.get("/api/test-staff-only", headers=bearer(patient)).status_code == 403
    assert client.get("/api/test-staff-only").status_code == 401
    query = client.get("/api/test-staff-only", params={"token": staff})
    assert query.status_code == 401
