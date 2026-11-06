"""The front desk: a patient without a phone joins by arrival stamp, and red flags still stop."""

from __future__ import annotations

import json
import threading
from concurrent.futures import ThreadPoolExecutor

import pytest

from backend import db, timeutil
from backend.ai import intake, session
from backend.tests.api_helpers import (
    AHMED_TEXT,
    DESK,
    FATIMA_ANSWERS,
    FATIMA_QID,
    RAVI_QID,
    RAVI_TEXT,
    bearer,
    patient_token,
    say,
    staff_token,
    start_visit,
)
from backend.tests.test_api_staff import (
    FATIMA,
    OTHER_DESK,
    SALEM,
    SALEM_ANSWERS,
    T1,
    Staff,
    arrived,
    chat,
    desk,  # noqa: F401
    event_types,
    new_visit,
    nurse,  # noqa: F401
    reserved,
    rows,
    execute,
)

SALEM_QID = "DEMO-10006"
MARIAM_QID = "DEMO-10005"
AHMED_QID = "DEMO-10002"
COMPLAINT = "Sore throat and a mild cough"


def walk_in(desk, qid=SALEM_QID, complaint=COMPLAINT):
    return desk.post("/api/desk/walk-in", {"qid": qid, "complaint": complaint})


def visit_of(visit_id):
    return rows("SELECT * FROM visit WHERE id = ?", visit_id)[0]


def queue_ids(staff):
    tickets = staff.get(f"/api/counters/{T1}/queue").json()["tickets"]
    return [row["visit_id"] for row in tickets if not row["simulated"]]


def test_a_walk_in_gets_an_active_triage_ticket_now(api, desk):
    response = walk_in(desk)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["emergency"] is False
    ticket = body["ticket"]
    assert ticket["number"] == "T-014"
    assert ticket["state"] == "active"
    assert ticket["counter_id"] == T1
    assert ticket["people_ahead"] == 3
    assert ticket["est_wait_min"] == 12
    visit = visit_of(body["visit_id"])
    assert visit["status"] == "in_triage"
    assert visit["booked_by"] is None
    assert visit["centre_id"] == "C-WAKRA"
    assert visit["service"] == "gp"
    assert visit["arrived_at"]
    assert "walk_in.registered" in event_types(body["visit_id"])


def test_the_nurse_sees_a_valid_intake_and_the_complaint_in_turns(api, desk, nurse):
    visit_id = walk_in(desk).json()["visit_id"]
    body = nurse.get(f"/api/staff/visits/{visit_id}").json()
    assert body["turns"] == [{"role": "patient", "text": COMPLAINT}]
    assert body["patient_words"] == [COMPLAINT]
    parsed = intake.validate_intake(body["intake"])
    assert parsed.chief_complaint == COMPLAINT
    assert parsed.chief_complaint_patient_words == COMPLAINT
    assert parsed.service == "gp"
    assert parsed.service_confidence == 0.0
    assert parsed.summary_for_nurse == f"Walk-in at the front desk: {COMPLAINT}"
    assert parsed.questions_asked == 0
    assert parsed.language == "ar-gulf"  # Salem's record says Arabic.
    assert body["confirmed_by_patient"] is True
    assert body["red_flags_checked"] == "none detected"
    assert body["service"] == "gp"
    tickets = nurse.get(f"/api/counters/{T1}/queue").json()["tickets"]
    assert tickets[-1]["complaint"] == COMPLAINT
    assert tickets[-1]["patient"]["name_en"] == "Salem Al-Demo"


def test_an_english_record_gives_an_english_intake(api, desk):
    visit_id = walk_in(desk, qid=RAVI_QID).json()["visit_id"]
    stored = rows("SELECT json FROM intake WHERE visit_id = ?", visit_id)[0]["json"]
    assert json.loads(stored)["language"] == "en"


def test_order_is_by_arrival_stamp_for_everyone(api, desk, nurse):
    earlier = arrived(api)
    _, late_reservation = reserved(api, patient_id=SALEM, answers=SALEM_ANSWERS)
    walked_in = walk_in(desk, qid=RAVI_QID).json()["visit_id"]
    assert queue_ids(nurse) == [earlier, walked_in]

    # The one who reserved before the walk-in arrived after them.
    api.app.state.engine.activate(late_reservation.id)
    assert queue_ids(nurse) == [earlier, walked_in, late_reservation.visit_id]
    numbers = [
        row["number"]
        for row in nurse.get(f"/api/counters/{T1}/queue").json()["tickets"]
        if not row["simulated"]
    ]
    assert numbers == ["T-014", "T-015", "T-016"]


def test_a_65_plus_walk_in_gets_the_centre_priority(api, desk, nurse):
    younger = arrived(api)
    older = walk_in(desk, qid=MARIAM_QID)
    assert older.status_code == 200
    body = older.json()
    assert body["ticket"]["people_ahead"] == 0
    assert queue_ids(nurse) == [body["visit_id"], younger]
    assert rows("SELECT priority FROM ticket WHERE visit_id = ?", body["visit_id"]) == [
        {"priority": 1}
    ]


@pytest.mark.parametrize(
    ("qid", "complaint"),
    [
        (SALEM_QID, "Chest pain going to my left arm"),
        (SALEM_QID, "عندي ألم في الصدر"),
        (RAVI_QID, RAVI_TEXT),
        (SALEM_QID, "ما أقدر أتنفس"),
    ],
)
def test_a_red_flag_complaint_gets_no_ticket(api, desk, nurse, qid, complaint):
    response = walk_in(desk, qid=qid, complaint=complaint)
    assert response.status_code == 200
    body = response.json()
    assert body["emergency"] is True
    assert body["ticket"] is None
    assert body["reply"]
    visit_id = body["visit_id"]
    assert visit_of(visit_id)["status"] == "redirected_emergency"
    assert rows("SELECT * FROM ticket WHERE visit_id = ?", visit_id) == []
    assert queue_ids(nurse) == []
    types = event_types(visit_id)
    assert "redflag.hit" in types and "walk_in.registered" in types
    seen = nurse.get(f"/api/staff/visits/{visit_id}").json()
    assert seen["red_flags_checked"].startswith("Red flag raised: ")
    assert seen["patient_words"] == [complaint]
    assert seen["turns"][0] == {"role": "patient", "text": complaint}


def test_no_second_ticket_after_a_red_flag(api, desk):
    first = walk_in(desk, complaint="Chest pain now").json()
    response = walk_in(desk, complaint="Actually it is just a cough")
    assert response.status_code == 409
    assert response.json()["error"] == "active_visit"
    assert response.json()["visit_id"] == first["visit_id"]
    assert rows("SELECT * FROM ticket WHERE visit_id IS NOT NULL") == []


def test_a_phone_emergency_is_not_washed_out_at_the_desk(api, desk):
    visit_id = new_visit("P003")
    assert chat(api, visit_id, RAVI_TEXT).emergency
    response = walk_in(desk, qid=RAVI_QID, complaint="It is only a cough")
    assert response.status_code == 409
    assert response.json()["visit_id"] == visit_id
    assert rows("SELECT * FROM ticket WHERE visit_id IS NOT NULL") == []


def test_an_urgent_nurse_decision_is_not_washed_out_at_the_desk(api, desk, nurse):
    visit_id = arrived(api)
    nurse.ok(f"/api/counters/{T1}/call-next")
    nurse.ok(f"/api/visits/{visit_id}/vitals", {"urgency": "urgent"})
    response = walk_in(desk, qid=FATIMA_QID)
    assert response.status_code == 409
    assert response.json()["error"] == "active_visit"


def test_a_denied_flag_reaches_the_nurse(api, desk, nurse):
    body = walk_in(desk, complaint="Cough, no chest pain").json()
    assert body["emergency"] is False
    seen = nurse.get(f"/api/staff/visits/{body['visit_id']}").json()
    assert seen["denied"] == ["chest pain"]
    assert seen["intake"]["denied_red_flags"] == ["chest pain"]
    assert seen["denied_text_en"] == "Patient denied: chest pain"
    assert seen["red_flags_checked"] == "Patient denied: chest pain"


def test_unknown_qid_is_404(api, desk):
    response = walk_in(desk, qid="DEMO-99999")
    assert response.status_code == 404
    assert response.json()["error"] == "unknown_qid"
    assert rows("SELECT * FROM visit") == []


def test_a_live_visit_is_409_with_its_id(api, desk):
    visit_id = arrived(api)
    response = walk_in(desk, qid=FATIMA_QID)
    assert response.status_code == 409
    body = response.json()
    assert body["error"] == "active_visit" and body["visit_id"] == visit_id
    assert len(rows("SELECT * FROM visit")) == 1


def test_a_finished_lapsed_or_stalled_visit_does_not_block_the_desk(api, desk):
    for status in ("completed", "cancelled", "expired", "deflected_refill", "intake"):
        visit_id = new_visit(FATIMA)
        execute("UPDATE visit SET status = ? WHERE id = ?", status, visit_id)
    assert walk_in(desk, qid=FATIMA_QID).status_code == 200


def test_yesterdays_emergency_does_not_block_the_desk(api, desk):
    visit_id = new_visit(FATIMA)
    execute(
        "UPDATE visit SET status = 'redirected_emergency', "
        "created_at = '2020-01-01T06:00:00.000000+00:00' WHERE id = ?",
        visit_id,
    )
    assert walk_in(desk, qid=FATIMA_QID).status_code == 200


def test_a_reserved_visit_blocks_the_desk(api, desk):
    visit_id, _ = reserved(api)
    response = walk_in(desk, qid=FATIMA_QID)
    assert response.status_code == 409
    assert response.json()["visit_id"] == visit_id


@pytest.mark.parametrize(
    "complaint",
    ["", "   ", "x" * 201, "two\nlines", "two\r\nlines", "two lines"],
)
def test_the_complaint_is_one_line_of_at_most_200_characters(api, desk, complaint):
    response = walk_in(desk, complaint=complaint)
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_request"
    assert rows("SELECT * FROM visit") == []


def test_exactly_200_characters_is_fine(api, desk):
    assert walk_in(desk, complaint="x" * 200).status_code == 200


def test_a_nurse_may_register_too(api, nurse):
    assert walk_in(nurse).json()["ticket"]["number"] == "T-014"


def test_the_ticket_is_at_the_desks_own_centre(api):
    desk = Staff(api, OTHER_DESK)
    body = walk_in(desk, qid=SALEM_QID).json()  # Registered at Al Wakra, standing at Al Rayyan.
    assert body["ticket"]["centre_id"] == "C-RAYYAN"
    assert visit_of(body["visit_id"])["centre_id"] == "C-RAYYAN"


def test_a_refill_sentence_at_the_desk_still_reaches_a_nurse(api, desk):
    body = walk_in(desk, qid=AHMED_QID, complaint=AHMED_TEXT).json()
    assert body["emergency"] is False
    assert body["ticket"]["state"] == "active"


def test_start_walk_in_refuses_empty_text(api):
    visit_id = new_visit(SALEM)
    conn = db.connect()
    with pytest.raises(session.SessionError):
        session.start_walk_in(conn, visit_id, "   ")
    with pytest.raises(session.SessionError):
        session.start_walk_in(conn, "V_missing", "cough")
    conn.close()


# One queue place per patient


LIVE = "('reserved', 'active', 'called', 'serving')"
PATIENT_IDS = {SALEM_QID: SALEM, FATIMA_QID: FATIMA, MARIAM_QID: "P005"}


def live_tickets_of(patient_id):
    return rows(
        "SELECT ticket.* FROM ticket JOIN visit ON visit.id = ticket.visit_id "
        f"WHERE visit.patient_id = ? AND ticket.state IN {LIVE}",
        patient_id,
    )


def desk_opened_visit(patient_id):
    """What the desk has written after opening a visit and before the ticket exists."""
    visit_id = db.new_id("V")
    execute(
        "INSERT INTO visit (id, patient_id, centre_id, status, created_at, booked_by) "
        "VALUES (?, ?, 'C-WAKRA', 'intake', ?, NULL)",
        visit_id,
        patient_id,
        timeutil.iso(timeutil.utcnow()),
    )
    return visit_id


def walk_ins_at_once(live, qid, complaint, count=6):
    token = staff_token(live.http, DESK)
    start = threading.Barrier(count)

    def attempt(_):
        start.wait(timeout=5)
        return live.http.post(
            "/api/desk/walk-in",
            json={"qid": qid, "complaint": complaint},
            headers=bearer(token),
        )

    with ThreadPoolExecutor(count) as pool:
        return list(pool.map(attempt, range(count)))


def test_a_walk_in_ticket_blocks_a_reservation_on_a_phone_visit(api, desk):
    token = patient_token(api, FATIMA_QID)
    phone = start_visit(api, token)
    say(api, token, phone, *FATIMA_ANSWERS)
    headers = bearer(token)
    assert api.post(f"/api/visits/{phone}/intake/confirm", headers=headers).status_code == 200

    body = walk_in(desk, qid=FATIMA_QID).json()
    assert body["ticket"]["state"] == "active"

    refused = api.post(
        f"/api/visits/{phone}/reserve", json={"centre_id": "C-WAKRA"}, headers=headers
    )
    assert refused.status_code == 409
    assert refused.json()["error"] == "active_visit"
    assert refused.json()["visit_id"] == body["visit_id"]
    assert [row["visit_id"] for row in live_tickets_of(FATIMA)] == [body["visit_id"]]


def test_a_visit_the_desk_is_still_opening_blocks_the_desk(api, desk):
    visit_id = desk_opened_visit(SALEM)
    response = walk_in(desk)
    assert response.status_code == 409
    assert response.json()["error"] == "active_visit"
    assert response.json()["visit_id"] == visit_id
    assert len(rows("SELECT * FROM visit WHERE patient_id = ?", SALEM)) == 1


def test_a_red_flag_at_the_desk_is_heard_while_another_call_opens_the_visit(api, desk):
    visit_id = desk_opened_visit(SALEM)
    body = walk_in(desk, complaint="Chest pain since morning").json()
    assert body["emergency"] is True
    assert body["visit_id"] == visit_id
    assert visit_of(visit_id)["status"] == "redirected_emergency"
    assert live_tickets_of(SALEM) == []
    assert "redflag.hit" in event_types(visit_id)


def test_a_phone_visit_in_intake_does_not_block_the_desk(api, desk):
    new_visit(SALEM, booked_by=SALEM)
    assert walk_in(desk).status_code == 200


@pytest.mark.parametrize("qid", list(PATIENT_IDS))
def test_six_walk_ins_at_once_give_one_live_ticket(live_api, qid):
    answers = walk_ins_at_once(live_api, qid, COMPLAINT)
    assert sorted(answer.status_code for answer in answers) == [200, 409, 409, 409, 409, 409]
    assert {a.json()["error"] for a in answers if a.status_code == 409} == {"active_visit"}
    assert len(live_tickets_of(PATIENT_IDS[qid])) == 1
    assert len(rows("SELECT * FROM visit WHERE patient_id = ?", PATIENT_IDS[qid])) == 1


def test_six_chest_pains_at_once_give_no_ticket(live_api):
    answers = walk_ins_at_once(live_api, SALEM_QID, "Chest pain since morning")
    assert all(answer.status_code in (200, 409) for answer in answers), [
        answer.text for answer in answers
    ]
    assert any(answer.status_code == 200 for answer in answers)
    assert live_tickets_of(SALEM) == []
    assert [row["status"] for row in rows("SELECT * FROM visit WHERE patient_id = ?", SALEM)] == [
        "redirected_emergency"
    ]
