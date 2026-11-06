"""Queues, calling, and who may do what. The helpers here serve the other staff test files.

Visits are built through session and the engine, the same calls the patient routes make,
so these files test the staff routes alone.
"""

from __future__ import annotations

from datetime import timedelta

import pytest

from backend import db, timeutil
from backend.ai import session
from backend.tests.api_helpers import (
    DESK,
    DOCTOR2,
    FATIMA_ANSWERS,
    FATIMA_QID,
    NURSE,
    PHARMACIST,
    bearer,
    patient_token,
    staff_token,
)

T1 = "C-WAKRA-T1"
D3 = "C-WAKRA-D3"
D4 = "C-WAKRA-D4"
P1 = "C-WAKRA-P1"
DOCTOR1 = "S-WAK-DOC1"
OTHER_NURSE = "S-RAY-NURSE1"
OTHER_DOCTOR = "S-RAY-DOC1"
OTHER_DESK = "S-RAY-DESK1"
FATIMA = "P001"
LAYLA = "P004"
MARIAM = "P005"
SALEM = "P006"
SALEM_ANSWERS = ("I have a sore knee since last week", "4", "nothing", "no", "no")


class Staff:
    """Logged-in calls for one staff member."""

    def __init__(self, api, staff_id):
        self.api = api
        self.headers = bearer(staff_token(api, staff_id))

    def get(self, path):
        return self.api.get(path, headers=self.headers)

    def post(self, path, json=None):
        return self.api.post(path, json=json, headers=self.headers)

    def put(self, path, json=None):
        return self.api.put(path, json=json, headers=self.headers)

    def ok(self, path, json=None):
        response = self.post(path, json)
        assert response.status_code == 200, response.text
        return response.json()


def rows(sql, *params):
    conn = db.connect()
    try:
        return [dict(row) for row in conn.execute(sql, params)]
    finally:
        conn.close()


def execute(sql, *params):
    conn = db.connect()
    try:
        conn.execute(sql, params)
    finally:
        conn.close()


def table_dump(*tables):
    return {table: rows(f"SELECT * FROM {table} ORDER BY rowid") for table in tables}


def event_types(visit_id):
    return [row["type"] for row in rows("SELECT type FROM event WHERE visit_id = ?", visit_id)]


def new_visit(patient_id, booked_by=None):
    visit_id = db.new_id("V")
    execute(
        "INSERT INTO visit (id, patient_id, status, created_at, booked_by) "
        "VALUES (?, ?, 'intake', ?, ?)",
        visit_id,
        patient_id,
        timeutil.iso(timeutil.utcnow()),
        booked_by,
    )
    return visit_id


def chat(api, visit_id, *texts):
    conn = db.connect()
    try:
        return [session.handle_message(conn, api.app.state.ai, visit_id, t) for t in texts][-1]
    finally:
        conn.close()


def reserved(api, patient_id=FATIMA, answers=FATIMA_ANSWERS, centre_id="C-WAKRA", booked_by=None):
    """A visit past intake with a reserved ticket. Returns (visit_id, ticket)."""
    visit_id = new_visit(patient_id, booked_by)
    assert chat(api, visit_id, *answers).done
    engine = api.app.state.engine
    return visit_id, engine.issue_ticket(visit_id, engine.triage_counter(centre_id))


def arrived(api, patient_id=FATIMA, answers=FATIMA_ANSWERS, centre_id="C-WAKRA", booked_by=None):
    visit_id, ticket = reserved(api, patient_id, answers, centre_id, booked_by)
    api.app.state.engine.activate(ticket.id)
    return visit_id


def at_vitals(nurse, api, **kwargs):
    """Called to triage and with routine vitals taken, ready for a draft."""
    visit_id = arrived(api, **kwargs)
    assert nurse.ok(f"/api/counters/{T1}/call-next")["called"]["visit_id"] == visit_id
    body = {"bp_sys": 120, "bp_dia": 80, "hr": 72, "temp_c": 38.1, "spo2": 98, "urgency": "routine"}
    nurse.ok(f"/api/visits/{visit_id}/vitals", body)
    return visit_id


def at_doctor(nurse, api, doctor_id=DOCTOR2, **kwargs):
    """Handed off to the doctor: the state the fast-forward button starts from."""
    visit_id = at_vitals(nurse, api, **kwargs)
    text = nurse.ok(f"/api/visits/{visit_id}/handoff/draft")["text"]
    nurse.ok(
        f"/api/visits/{visit_id}/handoff/confirm", {"final_text": text, "doctor_id": doctor_id}
    )
    return visit_id


@pytest.fixture
def nurse(api):
    return Staff(api, NURSE)


@pytest.fixture
def doctor(api):
    return Staff(api, DOCTOR2)


@pytest.fixture
def pharmacist(api):
    return Staff(api, PHARMACIST)


@pytest.fixture
def desk(api):
    return Staff(api, DESK)


def test_demo_staff_needs_no_login_and_lists_counters(api):
    response = api.get("/api/staff/demo-staff")
    assert response.status_code == 200
    staff = response.json()
    assert [(s["centre_id"], s["role"]) for s in staff] == sorted(
        (s["centre_id"], s["role"]) for s in staff
    )
    by_id = {s["id"]: s for s in staff}
    assert by_id[NURSE]["centre_name_en"] == "Al Wakra Health Centre"
    assert by_id[NURSE]["centre_name_ar"]
    assert by_id[NURSE]["counters"] == [
        {"id": T1, "label": "Triage 1", "label_ar": "الفرز 1", "stage": "triage"}
    ]
    assert by_id[DESK]["counters"] == []
    assert set(by_id[DOCTOR2]) == {
        "id",
        "name",
        "role",
        "clinic",
        "centre_id",
        "centre_name_en",
        "centre_name_ar",
        "counters",
    }


def test_queue_shape_with_a_real_ticket_and_greyed_simulated_ones(api, nurse):
    visit_id = arrived(api)
    body = nurse.get(f"/api/counters/{T1}/queue").json()
    assert body["counter"] == {
        "id": T1,
        "label": "Triage 1",
        "label_ar": "الفرز 1",
        "stage": "triage",
        "prefix": "T",
    }
    assert body["wait"] == {"people_ahead": 4, "wait_min": 16}

    *simulated, real = body["tickets"]
    assert len(simulated) == 3
    for row in simulated:
        assert row["simulated"] is True and row["label"] == "Simulated"
        assert "patient" not in row and "complaint" not in row
        assert row["visit_id"] is None
        assert row["waiting_min"] == 0

    assert real["simulated"] is False and real["label"] is None
    assert real["number"] == "T-014"
    assert real["visit_id"] == visit_id
    assert real["patient"] == {
        "name_en": "Fatima Al-Demo",
        "name_ar": "فاطمة التجريبية",
        "age": real["patient"]["age"],
        "sex": "F",
    }
    assert real["patient"]["age"] >= 34
    assert real["complaint"]
    assert real["priority"] == 0


def test_waiting_minutes_follow_the_engine_clock(api, nurse, monkeypatch):
    arrived(api)
    engine = api.app.state.engine
    later = timeutil.utcnow().replace(microsecond=0)
    monkeypatch.setattr(engine, "clock", lambda: later + timedelta(minutes=7, seconds=30))
    rows_now = nurse.get(f"/api/counters/{T1}/queue").json()["tickets"]
    assert [row["waiting_min"] for row in rows_now] == [7, 7, 7, 7]


def test_queue_complaint_is_the_nurses_edit(api, nurse):
    visit_id = arrived(api)
    assert nurse.put(
        f"/api/visits/{visit_id}/intake", {"json": {"chief_complaint": "cough, edited"}}
    ).status_code == 200
    tickets = nurse.get(f"/api/counters/{T1}/queue").json()["tickets"]
    assert tickets[-1]["complaint"] == "cough, edited"


def test_call_next_skips_simulated_and_calls_the_real_patient(api, nurse):
    visit_id = arrived(api)
    body = nurse.ok(f"/api/counters/{T1}/call-next")
    assert body["called"]["number"] == "T-014"
    assert body["called"]["visit_id"] == visit_id
    assert body["called"]["state"] == "called"
    assert body["auto_completed"] == ["T-011", "T-012", "T-013"]
    assert body["note"] == "handled by a colleague on shift"


def test_call_next_with_only_simulated_left_calls_nobody(api, nurse):
    body = nurse.ok(f"/api/counters/{T1}/call-next")
    assert body == {
        "called": None,
        "auto_completed": ["T-011"],
        "note": "handled by a colleague on shift",
    }


def test_call_next_on_an_empty_queue(api, nurse):
    for _ in range(3):
        nurse.ok(f"/api/counters/{T1}/call-next")
    assert nurse.ok(f"/api/counters/{T1}/call-next") == {
        "called": None,
        "auto_completed": [],
        "note": None,
    }


def test_a_real_ticket_needs_no_note(api, nurse):
    for _ in range(3):
        nurse.ok(f"/api/counters/{T1}/call-next")
    arrived(api)
    body = nurse.ok(f"/api/counters/{T1}/call-next")
    assert body["auto_completed"] == [] and body["note"] is None
    assert body["called"]["number"] == "T-014"


def test_counter_busy_is_409(api, nurse):
    arrived(api)
    nurse.ok(f"/api/counters/{T1}/call-next")
    response = nurse.post(f"/api/counters/{T1}/call-next")
    assert response.status_code == 409
    assert response.json()["error"] == "counter_busy"


def test_serve_moves_a_called_ticket(api, nurse):
    arrived(api)
    ticket = nurse.ok(f"/api/counters/{T1}/call-next")["called"]
    served = nurse.ok(f"/api/tickets/{ticket['id']}/serve")
    assert served["state"] == "serving" and served["number"] == "T-014"
    response = nurse.post(f"/api/tickets/{ticket['id']}/serve")
    assert response.status_code == 409
    assert response.json()["error"] == "invalid_transition"


def test_no_show_goes_back_and_the_third_call_moves_to_the_back(api, nurse):
    first = arrived(api)
    second = arrived(api, patient_id="P006", answers=SALEM_ANSWERS)
    for call in (1, 2, 3):
        called = nurse.ok(f"/api/counters/{T1}/call-next")["called"]
        assert called["visit_id"] == first, f"call {call}"
        back = nurse.ok(f"/api/tickets/{called['id']}/no-show")
        assert back["state"] == "active"
    assert nurse.ok(f"/api/counters/{T1}/call-next")["called"]["visit_id"] == second
    tickets = nurse.get(f"/api/counters/{T1}/queue").json()["tickets"]
    assert [row["visit_id"] for row in tickets] == [second, first]


def test_unknown_ticket_and_counter_are_404(api, nurse):
    for path in ("/api/tickets/nope/serve", "/api/tickets/nope/no-show"):
        response = nurse.post(path)
        assert response.status_code == 404
        assert response.json()["error"] == "ticket_not_found"
    assert nurse.post("/api/counters/nope/call-next").json()["error"] == "unknown_counter"
    assert nurse.get("/api/counters/nope/queue").json()["error"] == "unknown_counter"


def test_a_colleagues_ticket_is_refused(api, nurse, doctor):
    arrived(api)
    ticket = nurse.ok(f"/api/counters/{T1}/call-next")["called"]
    for action in ("serve", "no-show"):
        response = doctor.post(f"/api/tickets/{ticket['id']}/{action}")
        assert response.status_code == 403
        assert response.json()["error"] == "not_your_counter"
    assert rows("SELECT state FROM ticket WHERE id = ?", ticket["id"]) == [{"state": "called"}]


def test_another_centres_nurse_is_stopped_everywhere(api, nurse):
    visit_id = arrived(api)
    ticket = nurse.ok(f"/api/counters/{T1}/call-next")["called"]
    stranger = Staff(api, OTHER_NURSE)

    for response in (
        stranger.get(f"/api/counters/{T1}/queue"),
        stranger.get(f"/api/staff/visits/{visit_id}"),
        stranger.put(f"/api/visits/{visit_id}/intake", {"json": {"chief_complaint": "x"}}),
        stranger.post(f"/api/visits/{visit_id}/vitals", {"urgency": "urgent"}),
        stranger.post(f"/api/visits/{visit_id}/handoff/draft"),
        stranger.post(
            f"/api/visits/{visit_id}/handoff/confirm",
            {"final_text": "x", "doctor_id": OTHER_DOCTOR},
        ),
        stranger.post(f"/api/demo/fast-forward/{visit_id}"),
        stranger.get("/api/stats/C-WAKRA"),
    ):
        assert response.status_code == 403
        assert response.json()["error"] == "wrong_centre"

    for response in (
        stranger.post(f"/api/counters/{T1}/call-next"),
        stranger.post(f"/api/tickets/{ticket['id']}/serve"),
        stranger.post(f"/api/tickets/{ticket['id']}/no-show"),
    ):
        assert response.status_code == 403
        assert response.json()["error"] == "not_your_counter"

    assert rows("SELECT state FROM ticket WHERE id = ?", ticket["id"]) == [{"state": "called"}]


@pytest.mark.parametrize(
    ("staff_id", "method", "path"),
    [
        (DOCTOR2, "put", "/api/visits/{v}/intake"),
        (PHARMACIST, "put", "/api/visits/{v}/intake"),
        (DESK, "put", "/api/visits/{v}/intake"),
        (DOCTOR2, "post", "/api/visits/{v}/vitals"),
        (DESK, "post", "/api/visits/{v}/vitals"),
        (DOCTOR2, "post", "/api/visits/{v}/handoff/draft"),
        (PHARMACIST, "post", "/api/visits/{v}/handoff/confirm"),
        (NURSE, "post", "/api/visits/{v}/consult/done"),
        (PHARMACIST, "post", "/api/visits/{v}/consult/done"),
        (NURSE, "post", "/api/visits/{v}/dispensed"),
        (DOCTOR2, "post", "/api/visits/{v}/dispensed"),
        (NURSE, "get", "/api/staff/visits/{v}/drugs"),
        (DESK, "get", "/api/staff/visits/{v}/drugs"),
        (DOCTOR2, "post", "/api/desk/walk-in"),
        (PHARMACIST, "post", "/api/desk/walk-in"),
    ],
)
def test_role_matrix(api, staff_id, method, path):
    visit_id = arrived(api)
    bodies = {
        "/api/visits/{v}/intake": {"json": {}},
        "/api/visits/{v}/vitals": {"urgency": "routine"},
        "/api/visits/{v}/handoff/confirm": {"final_text": "x", "doctor_id": DOCTOR2},
        "/api/visits/{v}/consult/done": {"prescription": []},
        "/api/desk/walk-in": {"qid": FATIMA_QID, "complaint": "cough"},
    }
    kwargs = {"json": bodies[path]} if path in bodies else {}
    staff = Staff(api, staff_id)
    response = getattr(staff, method)(path.replace("{v}", visit_id), **kwargs)
    assert response.status_code == 403
    assert response.json()["error"] == "wrong_role"


def test_a_doctor_cannot_finish_another_doctors_patient(api, nurse):
    visit_id = at_doctor(nurse, api, doctor_id=DOCTOR2)
    other = Staff(api, DOCTOR1)
    response = other.post(f"/api/visits/{visit_id}/consult/done", {"prescription": []})
    assert response.status_code == 403
    assert response.json()["error"] == "not_your_counter"
    response = other.post(f"/api/counters/{D4}/call-next")
    assert response.status_code == 403
    assert response.json()["error"] == "not_your_counter"
    assert rows("SELECT status FROM visit WHERE id = ?", visit_id) == [{"status": "in_doctor"}]


def test_visit_detail_refuses_a_patient_token_and_no_token(api, nurse):
    visit_id = arrived(api)
    response = api.get(f"/api/staff/visits/{visit_id}")
    assert response.status_code == 401
    token = patient_token(api, FATIMA_QID)
    for path in (f"/api/staff/visits/{visit_id}", f"/api/staff/visits/{visit_id}/drugs"):
        response = api.get(path, headers=bearer(token))
        assert response.status_code == 403
        assert "summary_for_nurse" not in response.text
        assert "turns" not in response.text


@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("get", f"/api/counters/{T1}/queue"),
        ("post", f"/api/counters/{T1}/call-next"),
        ("post", "/api/tickets/x/serve"),
        ("post", "/api/tickets/x/no-show"),
        ("get", "/api/stats/C-WAKRA"),
        ("post", "/api/demo/reset"),
        ("post", "/api/demo/fast-forward/x"),
        ("post", "/api/desk/walk-in"),
    ],
)
def test_every_staff_route_needs_a_staff_session(api, method, path):
    assert getattr(api, method)(path).status_code == 401
    response = getattr(api, method)(path, headers=bearer(patient_token(api, FATIMA_QID)))
    assert response.status_code == 403
    assert response.json()["error"] == "forbidden"
