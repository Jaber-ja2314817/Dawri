"""The demo reset and the fast-forward button."""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from backend import config, db, simulate
from backend.main import app
from backend.tests.api_helpers import (
    FATIMA_QID,
    NURSE,
    bearer,
    open_stream,
    patient_token,
    staff_token,
)
from backend.tests.test_api_staff import (
    D3,
    D4,
    DOCTOR1,
    FATIMA,
    OTHER_NURSE,
    P1,
    SALEM,
    SALEM_ANSWERS,
    T1,
    Staff,
    arrived,
    at_doctor,
    at_vitals,
    doctor,  # noqa: F401
    event_types,
    execute,
    nurse,  # noqa: F401
    pharmacist,  # noqa: F401
    rows,
    table_dump,
)

MARIAM = "P005"
TABLES = ("visit", "ticket", "event", "prescription_item", "number_sequence", "handoff")


def forward(staff, visit_id):
    return staff.post(f"/api/demo/fast-forward/{visit_id}")


def refused_unchanged(staff, visit_id, code="not_next_in_queue"):
    before = table_dump(*TABLES)
    response = forward(staff, visit_id)
    assert response.status_code == 409
    assert response.json()["error"] == code
    assert table_dump(*TABLES) == before


def to_pharmacy(nurse, doctor, api, **kwargs):
    visit_id = at_doctor(nurse, api, **kwargs)
    doctor.ok(f"/api/counters/{D4}/call-next")
    doctor.ok(
        f"/api/visits/{visit_id}/consult/done", {"prescription": [{"drug_id": "DR-PARA"}]}
    )
    return visit_id


# Fast-forward


def test_fast_forward_completes_through_the_normal_engine(api, nurse):
    visit_id = at_doctor(nurse, api)
    response = forward(nurse, visit_id)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["status"] == "completed"

    tickets = rows(
        "SELECT number, counter_id, state FROM ticket WHERE visit_id = ? ORDER BY rowid", visit_id
    )
    assert tickets == [
        {"number": "T-014", "counter_id": T1, "state": "done"},
        {"number": "D-GP-023", "counter_id": D4, "state": "done"},
        {"number": "P-031", "counter_id": P1, "state": "done"},
    ]
    assert [step["step"] for step in body["steps"]] == [
        "called",
        "consult_done",
        "called",
        "dispensed",
    ]
    assert body["steps"][0]["number"] == "D-GP-023"
    assert body["steps"][2]["number"] == "P-031"

    assert rows("SELECT status FROM visit WHERE id = ?", visit_id) == [{"status": "completed"}]
    names = [line["name"] for line in body["medicines"]["ar"]]
    assert sorted(names) == sorted(["باراسيتامول", "ديكستروميثورفان"])
    assert "take" not in body["medicines"]["ar"][0]["line"]
    assert body["medicines"]["en"][0]["line"].startswith(("Paracetamol", "Dextromethorphan"))

    types = event_types(visit_id)
    for expected in ("consult.done", "dispensed", "demo.fast_forward"):
        assert types.count(expected) == 1
    assert types.count("ticket.called") == 3
    assert types.count("ticket.done") == 3
    assert types.count("ticket.activated") >= 2


def test_the_default_prescription_is_the_demo_drugs(api, nurse):
    visit_id = at_doctor(nurse, api)
    forward(nurse, visit_id)
    drugs = rows("SELECT drug FROM prescription_item WHERE visit_id = ? ORDER BY drug", visit_id)
    assert [row["drug"] for row in drugs] == ["DR-DEXT", "DR-PARA"]


def test_the_default_prescription_skips_a_conflict_for_this_patient(api, nurse):
    execute("UPDATE patient SET allergies = '[\"paracetamol\"]' WHERE id = ?", FATIMA)
    visit_id = at_doctor(nurse, api)
    assert forward(nurse, visit_id).status_code == 200
    drugs = rows("SELECT drug FROM prescription_item WHERE visit_id = ?", visit_id)
    assert drugs == [{"drug": "DR-DEXT"}]
    assert "prescription.allergy_override" not in event_types(visit_id)


def test_no_safe_default_ends_the_visit_at_the_doctor(api, nurse):
    execute("UPDATE drug SET allergy_tags = '[\"penicillin\"]' WHERE demo_default = 1")
    visit_id = at_doctor(nurse, api)
    body = forward(nurse, visit_id).json()
    assert body["status"] == "completed"
    assert body["medicines"] == {"en": [], "ar": []}
    assert rows("SELECT * FROM ticket WHERE visit_id = ? AND counter_id = ?", visit_id, P1) == []


def test_simulated_tickets_ahead_are_fine(api, nurse):
    visit_id = at_doctor(nurse, api, doctor_id=DOCTOR1)  # Room 3 has a simulated ticket.
    body = forward(nurse, visit_id).json()
    assert body["status"] == "completed"
    assert body["steps"][0]["counter_id"] == D3
    assert len(body["steps"][0]["auto_completed"]) == 1


def test_from_the_pharmacy_stage(api, nurse, doctor):
    visit_id = to_pharmacy(nurse, doctor, api)
    body = forward(nurse, visit_id).json()
    assert body["status"] == "completed"
    assert [step["step"] for step in body["steps"]] == ["called", "dispensed"]
    assert rows("SELECT drug FROM prescription_item WHERE visit_id = ?", visit_id) == [
        {"drug": "DR-PARA"}
    ]


def test_a_patient_the_doctor_already_called_can_finish(api, nurse, doctor):
    visit_id = at_doctor(nurse, api)
    doctor.ok(f"/api/counters/{D4}/call-next")
    body = forward(nurse, visit_id).json()
    assert body["status"] == "completed"
    assert [step["step"] for step in body["steps"]] == ["consult_done", "called", "dispensed"]


def test_any_staff_of_the_centre_may_press_it(api, nurse, doctor):
    visit_id = at_doctor(nurse, api)
    assert forward(doctor, visit_id).status_code == 200


def test_refused_with_a_real_patient_ahead_at_the_doctor(api, nurse):
    first = at_doctor(nurse, api)
    second = at_doctor(nurse, api, patient_id=SALEM, answers=SALEM_ANSWERS)
    refused_unchanged(nurse, second)
    assert forward(nurse, first).status_code == 200
    assert forward(nurse, second).status_code == 200


def test_refused_with_a_real_patient_ahead_at_the_pharmacy(api, nurse, doctor):
    to_pharmacy(nurse, doctor, api)
    second = at_doctor(nurse, api, patient_id=SALEM, answers=SALEM_ANSWERS)
    refused_unchanged(nurse, second)


def test_refused_when_the_doctor_is_with_someone_else(api, nurse, doctor):
    first = at_doctor(nurse, api)
    doctor.ok(f"/api/counters/{D4}/call-next")
    second = at_doctor(nurse, api, patient_id=SALEM, answers=SALEM_ANSWERS)
    refused_unchanged(nurse, second)
    assert rows("SELECT status FROM visit WHERE id = ?", first) == [{"status": "in_doctor"}]


def test_refused_when_the_pharmacy_is_busy(api, nurse, doctor, pharmacist):
    to_pharmacy(nurse, doctor, api)
    pharmacist.ok(f"/api/counters/{P1}/call-next")
    second = at_doctor(nurse, api, patient_id=SALEM, answers=SALEM_ANSWERS)
    refused_unchanged(nurse, second)


def test_a_priority_patient_is_not_held_behind_a_lower_priority_one(api, nurse, doctor):
    to_pharmacy(nurse, doctor, api)
    older = at_doctor(nurse, api, patient_id=MARIAM, booked_by=FATIMA)
    assert rows("SELECT priority FROM ticket WHERE visit_id = ? LIMIT 1", older)[0]["priority"] == 1
    assert forward(nurse, older).status_code == 200


def test_a_same_priority_patient_ahead_blocks_a_priority_patient(api, nurse):
    first = at_doctor(nurse, api, patient_id=MARIAM, booked_by=FATIMA)
    execute("UPDATE ticket SET priority = 1 WHERE visit_id = ?", first)
    second = at_doctor(nurse, api, patient_id=SALEM, answers=SALEM_ANSWERS)
    execute("UPDATE ticket SET priority = 1 WHERE visit_id = ?", second)
    refused_unchanged(nurse, second)


@pytest.mark.parametrize("stage", ["triage", "vitals", "completed"])
def test_only_a_visit_past_triage_can_skip(api, nurse, stage):
    if stage == "triage":
        visit_id = arrived(api)
    elif stage == "vitals":
        visit_id = at_vitals(nurse, api)
    else:
        visit_id = at_doctor(nurse, api)
        forward(nurse, visit_id)
    refused_unchanged(nurse, visit_id, "visit_not_ready")


def test_fast_forward_needs_staff_of_that_centre(api, nurse):
    visit_id = at_doctor(nurse, api)
    assert api.post(f"/api/demo/fast-forward/{visit_id}").status_code == 401
    token = patient_token(api, FATIMA_QID)
    response = api.post(f"/api/demo/fast-forward/{visit_id}", headers=bearer(token))
    assert response.status_code == 403
    assert forward(Staff(api, OTHER_NURSE), visit_id).status_code == 403
    assert nurse.post("/api/demo/fast-forward/V_missing").status_code == 404


def test_estimates_do_not_move_after_ten_fast_forwards(api, nurse):
    engine = api.app.state.engine
    before = {counter: engine.avg_service_sec(counter) for counter in (D4, P1)}
    for _ in range(10):
        assert forward(nurse, at_doctor(nurse, api)).status_code == 200
    assert {counter: engine.avg_service_sec(counter) for counter in (D4, P1)} == before
    assert engine.counter_wait(D4) == {"people_ahead": 0, "wait_min": 0}
    done = rows("SELECT COUNT(*) AS n FROM ticket WHERE counter_id = ? AND state = 'done'", D4)
    assert done == [{"n": 10}]


# Reset


def test_reset_restores_t_014_and_keeps_tokens(api, nurse):
    first = at_doctor(nurse, api)
    forward(nurse, first)
    patient = patient_token(api, FATIMA_QID)

    response = nurse.post("/api/demo/reset")
    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is True
    assert body["simulate_load"] is True
    assert body["reset_at"]

    assert rows("SELECT * FROM visit") == []
    assert rows("SELECT type FROM event WHERE type = 'demo.reset'") == [{"type": "demo.reset"}]
    assert api.get("/api/me", headers=bearer(patient)).status_code == 200
    assert nurse.get(f"/api/counters/{T1}/queue").status_code == 200
    assert arrived(api) and rows(
        "SELECT number FROM ticket WHERE simulated = 0"
    ) == [{"number": "T-014"}]


def test_reset_is_for_staff(api):
    assert api.post("/api/demo/reset").status_code == 401
    token = patient_token(api, FATIMA_QID)
    assert api.post("/api/demo/reset", headers=bearer(token)).status_code == 403


def test_reset_reports_a_run_without_load(api, nurse, monkeypatch):
    monkeypatch.setenv("SIMULATE_LOAD", "0")
    assert nurse.ok("/api/demo/reset")["simulate_load"] is False
    assert config.simulate_load() is False
    assert rows("SELECT * FROM ticket") == []
    assert arrived(api) and rows("SELECT number FROM ticket") == [{"number": "T-014"}]


def test_reset_publishes_on_every_channel(api, nurse, monkeypatch):
    visit_id = arrived(api)
    sent = []
    monkeypatch.setattr("backend.events.bus.publish", lambda ch, event: sent.append((ch, event)))
    nurse.ok("/api/demo/reset")
    assert all(event == {"type": "demo.reset"} for _, event in sent)
    channels = {channel for channel, _ in sent}
    counters = {f"counter:{row['id']}" for row in rows("SELECT id FROM counter")}
    centres = {f"display:{row['id']}" for row in rows("SELECT id FROM centre")}
    assert channels == counters | centres | {f"visit:{visit_id}"}
    assert len(sent) == len(channels)


def test_open_streams_hear_the_reset(live_api):
    client = SimpleNamespace(app=app)
    visit_id = arrived(client)
    token = staff_token(live_api.http, NURSE)
    paths = (
        f"/api/counters/{T1}/stream",
        "/api/display/C-WAKRA/stream",
        f"/api/visits/{visit_id}/stream",
    )
    with (
        open_stream(live_api, paths[0], token) as counter,
        open_stream(live_api, paths[1], token) as display,
        open_stream(live_api, paths[2], token) as visit,
    ):
        for stream in (counter, display, visit):
            stream.until(": connected")
        response = live_api.http.post("/api/demo/reset", headers=bearer(token))
        assert response.status_code == 200
        for stream in (counter, display, visit):
            assert '"type":"demo.reset"' in stream.until("demo.reset")[-1]


def test_seed_counts_come_back_after_a_reset(api, nurse):
    arrived(api)
    nurse.ok(f"/api/counters/{T1}/call-next")
    nurse.ok("/api/demo/reset")
    conn = db.connect()
    try:
        for counter_id, count in simulate.SIMULATED_TICKETS.items():
            found = conn.execute(
                "SELECT COUNT(*) FROM ticket WHERE counter_id = ? AND state = 'active'",
                (counter_id,),
            ).fetchone()[0]
            assert found == count
    finally:
        conn.close()
