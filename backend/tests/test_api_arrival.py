"""Reserving and arriving: no number before arrival, and every way to arrive."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from backend import db, timeutil
from backend.routers import visits
from backend.tests.api_helpers import (
    FATIMA_ANSWERS,
    FATIMA_QID,
    NURSE,
    RAVI_QID,
    bearer,
    patient_token,
    say,
    staff_token,
    start_visit,
)
from backend.tests.conftest import FakeClock, make_visit

WAKRA = (25.17302, 51.59575)
METRES_PER_DEGREE = 111_195
CHEST_PAIN = "Chest pain going to my left arm."
SALEM_QID = "DEMO-10006"


@pytest.fixture
def conn(api):
    connection = db.connect()
    yield connection
    connection.close()


@pytest.fixture
def fatima(api):
    return patient_token(api, FATIMA_QID)


@pytest.fixture
def clock(api):
    fake = FakeClock(timeutil.utcnow())
    api.app.state.engine.clock = fake
    return fake


def _north_of_wakra(metres):
    return {"lat": WAKRA[0] + metres / METRES_PER_DEGREE, "lng": WAKRA[1]}


def _confirmed_visit(api, token, patient_id=None):
    visit_id = start_visit(api, token, patient_id)
    say(api, token, visit_id, *FATIMA_ANSWERS)
    response = api.post(f"/api/visits/{visit_id}/intake/confirm", headers=bearer(token))
    assert response.status_code == 200, response.text
    return visit_id


def _reserve(api, token, visit_id, centre_id="C-WAKRA"):
    return api.post(
        f"/api/visits/{visit_id}/reserve", json={"centre_id": centre_id}, headers=bearer(token)
    )


def _reserved_visit(api, token, patient_id=None, centre_id="C-WAKRA"):
    visit_id = _confirmed_visit(api, token, patient_id)
    response = _reserve(api, token, visit_id, centre_id)
    assert response.status_code == 200, response.text
    return visit_id


def _arrive(api, token, visit_id, **body):
    return api.post(f"/api/visits/{visit_id}/arrive", json=body, headers=bearer(token))


def _status(api, token, visit_id):
    return api.get(f"/api/visits/{visit_id}", headers=bearer(token)).json()["status"]


def _ticket_rows(conn, visit_id):
    return conn.execute(
        "SELECT * FROM ticket WHERE visit_id = ? ORDER BY rowid", (visit_id,)
    ).fetchall()


# Reserving


def test_a_reserved_ticket_has_no_number_and_no_place(api, fatima):
    visit_id = _confirmed_visit(api, fatima)
    response = _reserve(api, fatima, visit_id)
    assert response.status_code == 200
    body = response.json()
    ticket = body["ticket"]
    assert ticket["state"] == "reserved"
    assert ticket["number"] is None
    assert ticket["people_ahead"] is None
    assert ticket["est_wait_min"] is None
    assert body["expires_at"] == ticket["expires_at"]
    assert body["check_in_valid_min"] == 45
    assert body["message"] == "Check-in valid for 45 minutes"
    assert body["message_ar"] == "تسجيل الوصول صالح لمدة 45 دقيقة"


def test_the_full_state_shows_a_reserved_ticket_the_same_way(api, fatima):
    visit_id = _reserved_visit(api, fatima)
    state = api.get(f"/api/visits/{visit_id}", headers=bearer(fatima)).json()
    assert state["stage"] == "reserved"
    assert state["ticket"]["number"] is None
    assert state["ticket"]["people_ahead"] is None
    assert state["centre"]["id"] == "C-WAKRA"
    assert state["go_to"] is None


def test_the_expiry_is_45_minutes_after_reserving(api, fatima, clock):
    visit_id = _confirmed_visit(api, fatima)
    body = _reserve(api, fatima, visit_id).json()
    expires = timeutil.parse(body["expires_at"])
    assert (expires - clock.now).total_seconds() == 45 * 60


def test_the_wording_never_promises_a_place():
    source = Path(visits.__file__).read_text(encoding="utf-8").lower()
    for phrase in ("place held", "held for 45", "nobody skips"):
        assert phrase not in source


def test_reserving_uses_up_no_number(api, fatima, conn):
    before = conn.execute("SELECT * FROM number_sequence").fetchall()
    _reserved_visit(api, fatima)
    after = conn.execute("SELECT * FROM number_sequence").fetchall()
    assert [tuple(row) for row in before] == [tuple(row) for row in after]


def test_reserving_twice_is_refused(api, fatima, conn):
    visit_id = _reserved_visit(api, fatima)
    response = _reserve(api, fatima, visit_id)
    assert response.status_code == 409
    assert len(_ticket_rows(conn, visit_id)) == 1


def test_an_unknown_centre(api, fatima):
    visit_id = _confirmed_visit(api, fatima)
    response = _reserve(api, fatima, visit_id, "C-NOPE")
    assert response.status_code == 404
    assert response.json()["error"] == "unknown_centre"


def test_a_centre_without_the_service(api, fatima, conn):
    visit_id = _confirmed_visit(api, fatima)
    conn.execute("UPDATE visit SET service = 'dental' WHERE id = ?", (visit_id,))
    response = _reserve(api, fatima, visit_id, "C-AIRPORT")
    assert response.status_code == 409
    assert response.json()["error"] == "service_not_offered"


def test_a_hospital_takes_no_reservation(api, fatima, conn):
    visit_id = _confirmed_visit(api, fatima)
    response = _reserve(api, fatima, visit_id, "H-HGH")
    assert response.status_code == 409
    assert response.json()["error"] == "service_not_offered"
    assert _ticket_rows(conn, visit_id) == []


@pytest.mark.parametrize("service", ["mental_health", "other"])
def test_a_routed_service_reserves_at_a_gp_centre(api, fatima, conn, service):
    visit_id = _confirmed_visit(api, fatima)
    conn.execute("UPDATE visit SET service = ? WHERE id = ?", (service, visit_id))
    assert _reserve(api, fatima, visit_id, "C-AIRPORT").status_code == 200


def test_reserving_needs_confirmed_answers(api, fatima, conn):
    visit_id = start_visit(api, fatima)
    say(api, fatima, visit_id, *FATIMA_ANSWERS)
    response = _reserve(api, fatima, visit_id)
    assert response.status_code == 409
    assert response.json()["error"] == "intake_not_confirmed"
    assert _ticket_rows(conn, visit_id) == []


def test_a_stranger_cannot_reserve(api, fatima):
    visit_id = _confirmed_visit(api, fatima)
    assert _reserve(api, patient_token(api, RAVI_QID), visit_id).status_code == 403


def test_the_engine_refuses_a_visit_past_reserving(api, fatima, conn):
    visit_id = _confirmed_visit(api, fatima)
    conn.execute("UPDATE visit SET status = 'completed' WHERE id = ?", (visit_id,))
    response = _reserve(api, fatima, visit_id)
    assert response.status_code == 409
    assert response.json()["error"] == "visit_not_eligible"


# Arriving


def test_fatima_gets_t014(api, fatima):
    visit_id = _reserved_visit(api, fatima)
    response = _arrive(api, fatima, visit_id, button=True)
    assert response.status_code == 200
    body = response.json()
    ticket = body["ticket"]
    assert ticket["number"] == "T-014"
    assert ticket["state"] == "active"
    assert ticket["people_ahead"] == 3
    assert ticket["est_wait_min"] == 12
    assert ticket["expires_at"] is None
    assert body["go_to"] == {"counter": "Triage 1", "counter_ar": "الفرز 1"}


def test_the_full_state_after_arriving(api, fatima):
    visit_id = _reserved_visit(api, fatima)
    _arrive(api, fatima, visit_id, button=True)
    state = api.get(f"/api/visits/{visit_id}", headers=bearer(fatima)).json()
    assert state["status"] == "in_triage"
    assert state["stage"] == "triage"
    assert state["arrived_at"] is not None
    assert state["ticket"]["number"] == "T-014"
    assert state["ticket"]["people_ahead"] == 3
    assert state["go_to"]["counter"] == "Triage 1"


@pytest.mark.parametrize(
    ("body", "method"),
    [
        ({"button": True}, "button"),
        ({"qr_code": "DOOR-C-WAKRA"}, "qr"),
        ({"lat": WAKRA[0], "lng": WAKRA[1]}, "geofence"),
        (_north_of_wakra(140), "geofence"),
    ],
    ids=["button", "door code", "at the centre", "140 m out"],
)
def test_every_way_to_arrive(api, fatima, conn, body, method):
    visit_id = _reserved_visit(api, fatima)
    response = _arrive(api, fatima, visit_id, **body)
    assert response.status_code == 200, response.text
    event = conn.execute(
        "SELECT payload FROM event WHERE visit_id = ? AND type = 'ticket.activated'",
        (visit_id,),
    ).fetchone()
    assert json.loads(event["payload"])["method"] == method


def test_the_geofence_edge(api, fatima):
    visit_id = _reserved_visit(api, fatima)
    assert _arrive(api, fatima, visit_id, **_north_of_wakra(151)).status_code == 409
    assert _arrive(api, fatima, visit_id, **_north_of_wakra(149)).status_code == 200


def test_too_far_says_how_far(api, fatima):
    visit_id = _reserved_visit(api, fatima)
    response = _arrive(api, fatima, visit_id, **_north_of_wakra(200))
    assert response.status_code == 409
    body = response.json()
    assert body["error"] == "too_far"
    assert body["distance_m"] == pytest.approx(200, abs=2)
    assert _status(api, fatima, visit_id) == "reserved"


def test_the_geofence_is_the_reserved_centre_and_not_another(api, fatima):
    visit_id = _reserved_visit(api, fatima, centre_id="C-AIRPORT")
    response = _arrive(api, fatima, visit_id, lat=WAKRA[0], lng=WAKRA[1])
    assert response.status_code == 409
    assert response.json()["error"] == "too_far"


@pytest.mark.parametrize("code", ["DOOR-C-AIRPORT", "door-c-wakra", "", "C-WAKRA"])
def test_a_wrong_door_code(api, fatima, code):
    visit_id = _reserved_visit(api, fatima)
    response = _arrive(api, fatima, visit_id, qr_code=code)
    assert response.status_code == 409
    assert response.json()["error"] == "wrong_door"


@pytest.mark.parametrize(
    "body",
    [
        {},
        {"button": False},
        {"lat": WAKRA[0]},
        {"lng": WAKRA[1]},
        {"lat": WAKRA[0], "button": True},
        {"lat": WAKRA[0], "lng": WAKRA[1], "button": True},
        {"qr_code": "DOOR-C-WAKRA", "button": True},
        {"qr_code": "DOOR-C-WAKRA", "lat": WAKRA[0], "lng": WAKRA[1]},
    ],
    ids=[
        "nothing",
        "button false",
        "lat only",
        "lng only",
        "half a location and the button",
        "location and button",
        "door and button",
        "door and location",
    ],
)
def test_exactly_one_method(api, fatima, body):
    visit_id = _reserved_visit(api, fatima)
    response = _arrive(api, fatima, visit_id, **body)
    assert response.status_code == 422
    assert response.json()["error"] == "arrival_method_required"
    assert _status(api, fatima, visit_id) == "reserved"


def test_an_empty_body_is_no_method(api, fatima):
    visit_id = _reserved_visit(api, fatima)
    response = api.post(f"/api/visits/{visit_id}/arrive", headers=bearer(fatima))
    assert response.status_code == 422
    assert response.json()["error"] == "arrival_method_required"


@pytest.mark.parametrize(
    "raw",
    [
        '{"lat":NaN}',
        '{"lat":NaN,"lng":51.59}',
        '{"lat":25.17,"lng":Infinity}',
        '{"lat":91,"lng":51.59}',
        '{"lat":25.17,"lng":181}',
        '{"lat":-91,"lng":51.59}',
        '{"lat":"north","lng":51.59}',
    ],
)
def test_impossible_coordinates_are_a_422(api, fatima, raw):
    visit_id = _reserved_visit(api, fatima)
    response = api.post(
        f"/api/visits/{visit_id}/arrive",
        content=raw,
        headers={**bearer(fatima), "Content-Type": "application/json"},
    )
    assert response.status_code == 422


def test_a_visit_with_no_reservation(api, fatima):
    visit_id = _confirmed_visit(api, fatima)
    response = _arrive(api, fatima, visit_id, button=True)
    assert response.status_code == 409
    assert response.json()["error"] == "no_reservation"


def test_arriving_twice_is_refused(api, fatima, conn):
    visit_id = _reserved_visit(api, fatima)
    assert _arrive(api, fatima, visit_id, button=True).status_code == 200
    response = _arrive(api, fatima, visit_id, button=True)
    assert response.status_code == 409
    assert len(_ticket_rows(conn, visit_id)) == 1


def test_a_stranger_cannot_arrive(api, fatima):
    visit_id = _reserved_visit(api, fatima)
    assert _arrive(api, patient_token(api, RAVI_QID), visit_id, button=True).status_code == 403


def test_a_staff_token_cannot_arrive(api, fatima):
    visit_id = _reserved_visit(api, fatima)
    assert _arrive(api, staff_token(api, NURSE), visit_id, button=True).status_code == 403


def test_needs_a_token(api, fatima):
    visit_id = _reserved_visit(api, fatima)
    assert api.post(f"/api/visits/{visit_id}/arrive", json={"button": True}).status_code == 401


def test_an_unknown_visit(api, fatima):
    assert _arrive(api, fatima, "V-NOPE", button=True).status_code == 404


# The queue


def test_arrival_order_beats_reservation_order(api, fatima):
    first_to_reserve = _reserved_visit(api, fatima)
    salem = patient_token(api, SALEM_QID)
    second_to_reserve = _reserved_visit(api, salem)

    salem_ticket = _arrive(api, salem, second_to_reserve, button=True).json()["ticket"]
    fatima_ticket = _arrive(api, fatima, first_to_reserve, button=True).json()["ticket"]

    assert (salem_ticket["number"], salem_ticket["people_ahead"]) == ("T-014", 3)
    assert (fatima_ticket["number"], fatima_ticket["people_ahead"]) == ("T-015", 4)


def test_only_the_centre_rule_gives_priority(api, fatima, conn):
    _arrive(api, fatima, _reserved_visit(api, fatima), button=True)
    mother = _reserved_visit(api, fatima, "P005")  # 65+, booked by her daughter.
    ticket = _arrive(api, fatima, mother, button=True).json()["ticket"]
    assert ticket["people_ahead"] == 0
    rows = conn.execute(
        "SELECT priority FROM ticket WHERE visit_id = ?", (mother,)
    ).fetchall()
    assert [row["priority"] for row in rows] == [1]


def test_a_dependent_child_gets_no_priority_from_the_guardian(api, fatima):
    child = _reserved_visit(api, fatima, "P004")
    assert _arrive(api, fatima, child, button=True).json()["ticket"]["people_ahead"] == 3


# Expiry


def test_arriving_just_in_time(api, fatima, clock):
    visit_id = _reserved_visit(api, fatima)
    clock.advance(minutes=44, seconds=59)
    assert _arrive(api, fatima, visit_id, button=True).status_code == 200


def test_arriving_late_is_a_410_and_the_visit_expires(api, fatima, clock):
    visit_id = _reserved_visit(api, fatima)
    clock.advance(minutes=45)
    response = _arrive(api, fatima, visit_id, button=True)
    assert response.status_code == 410
    assert response.json()["error"] == "ticket_expired"
    assert _status(api, fatima, visit_id) == "expired"


def test_a_lapsed_ticket_is_a_410_from_anywhere(api, fatima, clock):
    visit_id = _reserved_visit(api, fatima)
    clock.advance(minutes=45)
    assert _arrive(api, fatima, visit_id, **_north_of_wakra(5000)).status_code == 410


def test_the_full_state_sees_the_expiry_without_an_arrival(api, fatima, clock):
    visit_id = _reserved_visit(api, fatima)
    clock.advance(minutes=45)
    state = api.get(f"/api/visits/{visit_id}", headers=bearer(fatima)).json()
    assert state["status"] == "expired"
    assert state["stage"] == "expired"
    assert state["ticket"] is None
    assert state["go_to"] is None


def test_reserving_again_after_expiry(api, fatima, clock, conn):
    visit_id = _reserved_visit(api, fatima)
    clock.advance(minutes=45)
    _arrive(api, fatima, visit_id, button=True)

    again = _reserve(api, fatima, visit_id)
    assert again.status_code == 200
    assert again.json()["ticket"]["number"] is None
    response = _arrive(api, fatima, visit_id, button=True)
    assert response.status_code == 200
    assert response.json()["ticket"]["number"] == "T-014"
    assert [row["state"] for row in _ticket_rows(conn, visit_id)] == ["released", "active"]


def test_a_new_reservation_can_be_at_another_centre(api, fatima, clock):
    visit_id = _reserved_visit(api, fatima)
    clock.advance(minutes=45)
    api.get(f"/api/visits/{visit_id}", headers=bearer(fatima))
    assert _reserve(api, fatima, visit_id, "C-AIRPORT").status_code == 200
    response = _arrive(api, fatima, visit_id, qr_code="DOOR-C-AIRPORT")
    assert response.status_code == 200
    assert response.json()["ticket"]["centre_id"] == "C-AIRPORT"


def test_a_red_flag_after_the_reservation_lapsed_blocks_a_new_one(api, fatima, clock, conn):
    visit_id = _reserved_visit(api, fatima)
    clock.advance(minutes=45)
    assert _status(api, fatima, visit_id) == "expired"
    say(api, fatima, visit_id, CHEST_PAIN)
    assert _status(api, fatima, visit_id) == "redirected_emergency"
    assert _reserve(api, fatima, visit_id).status_code == 409
    assert [row["state"] for row in _ticket_rows(conn, visit_id)] == ["released"]


def test_arrive_on_a_seeded_visit_with_no_centre(api, fatima, conn):
    visit_id = make_visit(conn, "P001")
    response = _arrive(api, fatima, visit_id, lat=WAKRA[0], lng=WAKRA[1])
    assert response.status_code == 409
    assert response.json()["error"] == "no_reservation"
