"""The dashboard: simple numbers from real rows, for today in Doha."""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from backend.routers.staff import _doha_window
from backend.tests.api_helpers import AHMED_TEXT, RAVI_TEXT
from backend.tests.test_api_staff import (
    D3,
    D4,
    NURSE,
    OTHER_NURSE,
    P1,
    SALEM,
    SALEM_ANSWERS,
    T1,
    Staff,
    arrived,
    at_doctor,
    chat,
    desk,  # noqa: F401
    doctor,  # noqa: F401
    execute,
    new_visit,
    nurse,  # noqa: F401
    rows,
)

STATS = "/api/stats/C-WAKRA"
ZERO = {
    "waiting": {"triage": 0, "doctor": 0, "pharmacy": 0},
    "avg_wait_min": None,
    "completed_today": 0,
    "refills_deflected": 0,
    "emergencies_redirected": 0,
    "walk_ins": 0,
    "ai_mode": "simulated",
}


def test_fresh_numbers_exclude_the_simulated_load(api, nurse):
    assert rows("SELECT COUNT(*) AS n FROM ticket WHERE simulated = 1")[0]["n"] > 0
    assert nurse.get(STATS).json() == ZERO


def test_there_is_no_no_show_claim(api, nurse):
    assert "show" not in nurse.get(STATS).text


def test_stats_are_for_the_centres_own_staff(api):
    response = Staff(api, OTHER_NURSE).get(STATS)
    assert response.status_code == 403
    assert response.json()["error"] == "wrong_centre"
    assert Staff(api, NURSE).get("/api/stats/C-NOPE").status_code == 403


def test_waiting_counts_real_active_tickets_per_stage(api, nurse):
    at_doctor(nurse, api)
    arrived(api, patient_id=SALEM, answers=SALEM_ANSWERS)
    assert nurse.get(STATS).json()["waiting"] == {"triage": 1, "doctor": 1, "pharmacy": 0}


def test_avg_wait_is_real_tickets_only(api, nurse):
    first = arrived(api)
    second = arrived(api, patient_id=SALEM, answers=SALEM_ANSWERS)
    execute(
        "UPDATE ticket SET activated_at = '2026-11-06T06:00:00.000000+00:00', "
        "called_at = '2026-11-06T06:04:00.000000+00:00', state = 'done' WHERE visit_id = ?",
        first,
    )
    execute(
        "UPDATE ticket SET activated_at = '2026-11-06T06:00:00.000000+00:00', "
        "called_at = '2026-11-06T06:07:00.000000+00:00', state = 'serving' WHERE visit_id = ?",
        second,
    )
    # A simulated ticket with a huge span must not move the mean.
    execute(
        "UPDATE ticket SET activated_at = '2026-11-06T01:00:00.000000+00:00', "
        "called_at = '2026-11-06T06:00:00.000000+00:00', state = 'done' WHERE simulated = 1"
    )
    assert nurse.get(STATS).json()["avg_wait_min"] == 5.5


def test_a_moved_to_back_no_show_does_not_give_a_negative_wait(api, nurse):
    visit_id = arrived(api)
    for _ in range(3):
        called = nurse.ok(f"/api/counters/{T1}/call-next")["called"]
        nurse.ok(f"/api/tickets/{called['id']}/no-show")
    row = rows("SELECT activated_at, called_at FROM ticket WHERE visit_id = ?", visit_id)[0]
    assert row["activated_at"] > row["called_at"]
    assert nurse.get(STATS).json()["avg_wait_min"] is None


def test_refill_and_emergency_count_at_the_registered_centre(api, nurse):
    refill = new_visit("P005")  # Mariam, registered at Al Wakra, with amlodipine on record.
    assert chat(api, refill, "I need my usual amlodipine").refill
    emergency = new_visit(SALEM)
    assert chat(api, emergency, RAVI_TEXT).emergency
    elsewhere = new_visit("P002")  # Ahmed is registered at Al Rayyan.
    assert chat(api, elsewhere, AHMED_TEXT).refill
    assert rows("SELECT centre_id FROM visit WHERE id = ?", refill) == [{"centre_id": None}]

    body = nurse.get(STATS).json()
    assert body["refills_deflected"] == 1
    assert body["emergencies_redirected"] == 1
    assert Staff(api, OTHER_NURSE).get("/api/stats/C-RAYYAN").json()["refills_deflected"] == 1


def test_a_walk_in_counts_where_it_walked_in(api, desk, nurse):
    body = desk.post("/api/desk/walk-in", {"qid": "DEMO-10002", "complaint": "cough"}).json()
    assert body["ticket"]["centre_id"] == "C-WAKRA"
    desk.post("/api/desk/walk-in", {"qid": "DEMO-10003", "complaint": "Chest pain now"})
    numbers = nurse.get(STATS).json()
    assert numbers["walk_ins"] == 2
    assert numbers["emergencies_redirected"] == 1
    assert numbers["waiting"]["triage"] == 1
    assert Staff(api, OTHER_NURSE).get("/api/stats/C-RAYYAN").json()["walk_ins"] == 0


def test_a_nurse_urgent_decision_counts_at_the_centre(api, nurse):
    visit_id = arrived(api)
    nurse.ok(f"/api/counters/{T1}/call-next")
    nurse.ok(f"/api/visits/{visit_id}/vitals", {"urgency": "urgent"})
    assert nurse.get(STATS).json()["emergencies_redirected"] == 1


def test_completed_today_follows_the_real_visit(api, nurse, doctor):
    visit_id = at_doctor(nurse, api)
    doctor.ok(f"/api/counters/{D4}/call-next")
    doctor.ok(f"/api/visits/{visit_id}/consult/done", {"prescription": []})
    assert doctor.get(STATS).json()["completed_today"] == 1


@pytest.mark.parametrize(
    ("now", "start", "end"),
    [
        (
            datetime(2026, 11, 6, 20, 59, tzinfo=timezone.utc),
            "2026-11-05T21:00:00.000000+00:00",
            "2026-11-06T21:00:00.000000+00:00",
        ),
        (
            datetime(2026, 11, 6, 21, 0, tzinfo=timezone.utc),
            "2026-11-06T21:00:00.000000+00:00",
            "2026-11-07T21:00:00.000000+00:00",
        ),
    ],
)
def test_the_day_is_dohas_not_utcs(now, start, end):
    assert _doha_window(now) == (start, end)


def test_yesterday_in_doha_does_not_count(api, nurse, monkeypatch):
    now = datetime(2026, 11, 6, 22, 0, tzinfo=timezone.utc)  # 01:00 on the 7th in Doha.
    monkeypatch.setattr(api.app.state.engine, "clock", lambda: now)
    visit = new_visit(SALEM)
    stamp = "2026-11-06T20:30:00.000000+00:00"  # Late on the 6th in Doha, the same UTC date.
    execute(
        "UPDATE visit SET status = 'completed', centre_id = 'C-WAKRA', created_at = ?, "
        "completed_at = ? WHERE id = ?",
        stamp,
        stamp,
        visit,
    )
    assert nurse.get(STATS).json()["completed_today"] == 0
    later = "2026-11-06T21:30:00.000000+00:00"
    execute("UPDATE visit SET completed_at = ? WHERE id = ?", later, visit)
    assert nurse.get(STATS).json()["completed_today"] == 1


def test_counters_keep_their_real_tickets_apart(api, nurse):
    """A simulated doctor ticket sits on Room 3 and stays out of the doctor number."""
    assert rows(
        "SELECT COUNT(*) AS n FROM ticket WHERE counter_id = ? AND simulated = 1", D3
    ) == [{"n": 1}]
    assert nurse.get(STATS).json()["waiting"]["doctor"] == 0
    assert rows("SELECT COUNT(*) AS n FROM ticket WHERE counter_id = ?", P1) == [{"n": 0}]
