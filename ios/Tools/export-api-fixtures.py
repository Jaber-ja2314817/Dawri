#!/usr/bin/env python3
"""Writes real API responses to ios/DawriCore/Tests/DawriCoreTests/Fixtures/.

The Swift models are tested against what the backend really returns, not guessed JSON.
This runs the FastAPI app in process through TestClient. It starts no server and makes no
model call: the whole walk is the simulated path.

Run it only like this, from the repo root:

    HF_TOKEN= SIMULATE_LOAD=1 DAWRI_DB=<temp file> .venv/bin/python ios/Tools/export-api-fixtures.py

The checks in check_environment() run before anything from backend is imported, because
backend/main.py calls load_dotenv() and a run without the blank variable would be a real one.
That call is also replaced below, so this script never opens .env.

Two fixtures are forced, the way backend/tests force them: visit_expired moves the engine's
clock on 46 minutes, and visit_cancelled writes the status straight to the temp database,
because no route cancels a visit.
"""

from __future__ import annotations

import json
import os
import socket
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "ios" / "DawriCore" / "Tests" / "DawriCoreTests" / "Fixtures"
FAKE_TOKEN = "fixture-token-not-real"

# Doha midday, so a run cannot cross the midnight that turns ticket numbers over.
START = datetime(2026, 11, 7, 9, 0, tzinfo=timezone.utc)

T1 = "C-WAKRA-T1"
D4 = "C-WAKRA-D4"
P1 = "C-WAKRA-P1"
PRESCRIPTION = {"prescription": [{"drug_id": "DR-PARA"}, {"drug_id": "DR-DEXT"}]}
VITALS = {"bp_sys": 120, "bp_dia": 80, "hr": 72, "temp_c": 38.1, "spo2": 98, "urgency": "routine"}


def refuse(message: str) -> None:
    print(f"export-api-fixtures: {message}", file=sys.stderr)
    raise SystemExit(2)


def check_environment() -> None:
    """Everything here must pass before backend can be imported."""
    if os.environ.get("HF_TOKEN") != "":
        refuse("refusing to run: HF_TOKEN must be present and blank (HF_TOKEN= on the command line)")
    if os.environ.get("SIMULATE_LOAD") != "1":
        refuse("refusing to run: SIMULATE_LOAD must be 1")
    db_file = os.environ.get("DAWRI_DB", "").strip()
    if not db_file:
        refuse("refusing to run: DAWRI_DB must name a temp file")
    if REPO in Path(db_file).resolve().parents:
        refuse("refusing to run: DAWRI_DB must be outside the repo")


def forbid_network() -> None:
    """TestClient stays in process, so any outgoing connection here is a bug."""

    def blocked(self, address):
        raise RuntimeError(f"export-api-fixtures: blocked a connection to {address!r}")

    socket.socket.connect = blocked
    socket.socket.connect_ex = blocked


def scrubbed(value, tokens: set[str]):
    """The same JSON with every token replaced by the fixed fake."""
    if isinstance(value, dict):
        clean = {}
        for key, item in value.items():
            if key == "token" and isinstance(item, str):
                tokens.add(item)
                clean[key] = FAKE_TOKEN
            else:
                clean[key] = scrubbed(item, tokens)
        return clean
    if isinstance(value, list):
        return [scrubbed(item, tokens) for item in value]
    return value


class Walk:
    """The calls the three demo patients make, keeping each body under a fixture name."""

    def __init__(self, api, bearer) -> None:
        self.api = api
        self.bearer = bearer
        self.saved: dict[str, object] = {}

    def keep(self, name: str, body: object) -> None:
        assert name not in self.saved, name
        self.saved[name] = body

    def get(self, path: str, token: str, name: str | None = None):
        response = self.api.get(path, headers=self.bearer(token))
        assert response.status_code == 200, f"{path}: {response.text}"
        body = response.json()
        if name is not None:
            self.keep(name, body)
        return body

    def post(self, path: str, token: str, body: object = None, name: str | None = None):
        response = self.api.post(path, json=body, headers=self.bearer(token))
        assert response.status_code == 200 or response.status_code == 201, (
            f"{path}: {response.text}"
        )
        payload = response.json()
        if name is not None:
            self.keep(name, payload)
        return payload

    def refused(self, path: str, token: str, status: int, name: str, body: object = None) -> None:
        response = self.api.post(path, json=body, headers=self.bearer(token))
        assert response.status_code == status, f"{path}: {response.text}"
        self.keep(name, response.json())

    def visit(self, visit_id: str, token: str, name: str):
        return self.get(f"/api/visits/{visit_id}", token, name)

    def call_next(self, counter: str, token: str, visit_id: str) -> None:
        called = self.post(f"/api/counters/{counter}/call-next", token)["called"]
        assert called["visit_id"] == visit_id, called


def export(api, helpers, db, clock_ahead) -> dict[str, object]:
    bearer = helpers.bearer
    walk = Walk(api, bearer)

    health = api.get("/api/health").json()
    if health.get("ai_mode") != "simulated":
        refuse(f"aborting: /api/health says ai_mode is {health.get('ai_mode')!r}, not simulated")
    walk.keep("health", health)

    nurse = helpers.staff_token(api, helpers.NURSE)
    doctor = helpers.staff_token(api, helpers.DOCTOR2)
    pharmacist = helpers.staff_token(api, helpers.PHARMACIST)
    walk.post("/api/demo/reset", nurse)

    response = api.get("/api/auth/demo-patients")
    assert response.status_code == 200, response.text
    walk.keep("demo_patients", response.json())

    # Fatima, the whole visit.
    walk.keep("auth_start", api.post("/api/auth/start", json={"qid": helpers.FATIMA_QID}).json())
    response = api.post("/api/auth/verify", json={"qid": helpers.FATIMA_QID, "otp": "0000"})
    assert response.status_code == 200, response.text
    walk.keep("auth_verify", response.json())
    fatima = response.json()["token"]

    response = api.post("/api/auth/verify", json={"qid": helpers.FATIMA_QID, "otp": "1234"})
    assert response.status_code == 401, response.text
    walk.keep("api_error", response.json())

    me = walk.get("/api/me", fatima, "me_with_dependents")
    assert me["dependents"], "Fatima should have dependents"

    created = walk.post("/api/visits", fatima, {"consent": True}, "create_visit")
    visit_id = created["visit_id"]
    walk.visit(visit_id, fatima, "visit_intake")

    answers = list(helpers.FATIMA_ANSWERS)
    first = walk.post(f"/api/visits/{visit_id}/chat", fatima, {"text": answers[0]}, "chat_turn")
    assert not first["done"], first
    helpers.say(api, fatima, visit_id, *answers[1:-1])
    last = walk.post(
        f"/api/visits/{visit_id}/chat", fatima, {"text": answers[-1]}, "chat_intake_done"
    )
    assert last["done"], last
    walk.visit(visit_id, fatima, "visit_intake_done")

    walk.post(f"/api/visits/{visit_id}/intake/confirm", fatima, {}, "confirm")
    walk.visit(visit_id, fatima, "visit_intake_confirmed")

    walk.get(
        f"/api/centres?service=gp&visit_id={visit_id}&lat=25.2&lng=51.5", fatima, "centre_list"
    )
    walk.get(f"/api/centres?service=other&visit_id={visit_id}", fatima, "centre_list_fallback")

    walk.post(f"/api/visits/{visit_id}/reserve", fatima, {"centre_id": "C-WAKRA"}, "reserve")
    walk.visit(visit_id, fatima, "visit_reserved")
    walk.post(f"/api/visits/{visit_id}/arrive", fatima, {"button": True}, "arrive")
    walk.visit(visit_id, fatima, "visit_triage")

    walk.call_next(T1, nurse, visit_id)
    walk.visit(visit_id, fatima, "visit_triage_called")
    walk.post(f"/api/visits/{visit_id}/vitals", nurse, VITALS)
    text = walk.post(f"/api/visits/{visit_id}/handoff/draft", nurse)["text"]
    walk.post(
        f"/api/visits/{visit_id}/handoff/confirm",
        nurse,
        {"final_text": text, "doctor_id": helpers.DOCTOR2},
    )
    walk.visit(visit_id, fatima, "visit_doctor")

    walk.call_next(D4, doctor, visit_id)
    walk.post(f"/api/visits/{visit_id}/consult/done", doctor, PRESCRIPTION)
    walk.visit(visit_id, fatima, "visit_pharmacy")

    walk.call_next(P1, pharmacist, visit_id)
    walk.post(f"/api/visits/{visit_id}/dispensed", pharmacist)
    walk.visit(visit_id, fatima, "visit_completed")
    walk.post(f"/api/visits/{visit_id}/rating", fatima, {"stars": 5}, "rating")
    walk.visit(visit_id, fatima, "visit_completed_rated")

    # Ravi, the emergency. The rules stop him, and the override gives no ticket.
    ravi = helpers.patient_token(api, helpers.RAVI_QID)
    walk.get("/api/me", ravi, "me_no_dependents")
    emergency = walk.post("/api/visits", ravi, {"consent": True})["visit_id"]
    reply = walk.post(
        f"/api/visits/{emergency}/chat", ravi, {"text": helpers.RAVI_TEXT}, "chat_emergency"
    )
    assert reply["emergency"], reply
    walk.visit(emergency, ravi, "visit_emergency")
    walk.post(f"/api/visits/{emergency}/emergency/override", ravi, None, "override")
    walk.refused("/api/visits", ravi, 409, "api_error_ar", {"consent": True})

    # Ahmed, the refill route, then still wanting a visit.
    ahmed = helpers.patient_token(api, helpers.AHMED_QID)
    refill = walk.post("/api/visits", ahmed, {"consent": True})["visit_id"]
    reply = walk.post(
        f"/api/visits/{refill}/chat", ahmed, {"text": helpers.AHMED_TEXT}, "chat_refill"
    )
    assert reply["refill"] is not None, reply
    walk.visit(refill, ahmed, "visit_refill")
    walk.post(f"/api/visits/{refill}/refill/continue", ahmed, None, "confirm_refill_continue")
    walk.visit(refill, ahmed, "visit_refill_continued")

    # Fatima booking for a dependent, so booked_by is someone else.
    child = walk.post("/api/visits", fatima, {"consent": True, "patient_id": "P004"})["visit_id"]
    walk.visit(child, fatima, "visit_dependent")

    # A reservation left to lapse.
    lapsed = walk.post("/api/visits", fatima, {"consent": True})["visit_id"]
    helpers.say(api, fatima, lapsed, *helpers.FATIMA_ANSWERS)
    walk.post(f"/api/visits/{lapsed}/intake/confirm", fatima, {})
    walk.post(f"/api/visits/{lapsed}/reserve", fatima, {"centre_id": "C-WAKRA"})
    with clock_ahead(api.app.state.engine, minutes=46):
        expired = walk.visit(lapsed, fatima, "visit_expired")
    assert expired["stage"] == "expired", expired

    # A long queue at Al Wakra, so the map has a suggestion to make.
    for _ in range(40):
        body = walk.get(f"/api/centres?service=gp&visit_id={lapsed}", fatima)
        if body["suggestion"] is not None:
            walk.keep("centre_list_suggestion", body)
            break
        api.app.state.engine.issue_simulated(T1)
    assert "centre_list_suggestion" in walk.saved

    # No route cancels a visit, so this one is forced in the temp database.
    cancelled = walk.post("/api/visits", fatima, {"consent": True, "patient_id": "P005"})[
        "visit_id"
    ]
    conn = db.connect()
    try:
        conn.execute("UPDATE visit SET status = 'cancelled' WHERE id = ?", (cancelled,))
    finally:
        conn.close()
    walk.visit(cancelled, fatima, "visit_cancelled")

    walk.get("/api/visits", fatima, "visit_rows")
    return walk.saved


def main() -> None:
    check_environment()
    forbid_network()
    sys.path.insert(0, str(REPO))

    # Before queue_engine is imported: it takes utcnow as a default argument.
    from backend import timeutil

    wall_clock = timeutil.utcnow
    offset = START - wall_clock()
    timeutil.utcnow = lambda: wall_clock() + offset

    from contextlib import contextmanager

    from fastapi.testclient import TestClient

    from backend import db
    from backend import main as backend_main
    from backend.tests import api_helpers

    backend_main.load_dotenv = lambda: None  # Nothing here opens .env.

    @contextmanager
    def clock_ahead(engine, minutes):
        before = engine.clock
        engine.clock = lambda: before() + timedelta(minutes=minutes)
        try:
            yield
        finally:
            engine.clock = before

    with TestClient(backend_main.app) as api:
        saved = export(api, api_helpers, db, clock_ahead)

    tokens: set[str] = set()
    files = {
        f"{name}.json": json.dumps(scrubbed(body, tokens), ensure_ascii=False, indent=2, sort_keys=True)
        + "\n"
        for name, body in saved.items()
    }
    assert tokens, "the login fixture should have held a token"
    for name, text in files.items():
        assert not any(token in text for token in tokens), f"{name} still holds a token"

    OUT.mkdir(parents=True, exist_ok=True)
    for stale in OUT.glob("*.json"):
        stale.unlink()
    for name, text in sorted(files.items()):
        (OUT / name).write_text(text, encoding="utf-8")
    print(f"export-api-fixtures: ai_mode simulated, wrote {len(files)} fixtures to {OUT}")


if __name__ == "__main__":
    main()
