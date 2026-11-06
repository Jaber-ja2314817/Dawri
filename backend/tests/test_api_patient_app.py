"""What the patient app added to the visit routes: refill, list names and the rating."""

from __future__ import annotations

import inspect
import json

import pytest

from backend.routers import visits
from backend.tests.api_helpers import (
    AHMED_QID,
    AHMED_TEXT,
    DOCTOR2,
    FATIMA_QID,
    NURSE,
    PHARMACIST,
    RAVI_QID,
    RAVI_TEXT,
)
from backend.tests.test_api_e2e import (
    arrived_visit,
    confirmed_visit,
    dispense,
    hand_off,
    open_visit,
    patient,
    reserved_visit,
    see_doctor,
    staff,
    tell,
    to_counter,
)
from backend.tests.test_api_staff import event_types, rows, table_dump

STATS = "/api/stats/C-WAKRA"
STAFF_ONLY_KEYS = {
    "summary_for_nurse",
    "chief_complaint",
    "duration",
    "associated",
    "patient_concerns",
    "turns",
    "patient_words",
}
ROW_KEYS = {
    "visit_id",
    "patient_id",
    "status",
    "stage",
    "service",
    "centre_id",
    "centre",
    "created_at",
    "completed_at",
    "active",
}
WAKRA = {"id": "C-WAKRA", "name_en": "Al Wakra Health Centre", "name_ar": "مركز الوكرة الصحي"}
AMLODIPINE = "amlodipine 5 mg once daily"


def rating_path(visit_id: str) -> str:
    return f"/api/visits/{visit_id}/rating"


def visit_view(person, visit_id: str) -> dict:
    response = person.get(f"/api/visits/{visit_id}")
    assert response.status_code == 200, response.text
    return response.json()


def completed_visit(api, fatima) -> str:
    nurse = staff(api, NURSE)
    doctor = staff(api, DOCTOR2)
    pharmacist = staff(api, PHARMACIST)
    visit_id = arrived_visit(fatima)
    to_counter(nurse, visit_id)
    hand_off(nurse, visit_id)
    see_doctor(doctor, visit_id)
    dispense(pharmacist, visit_id)
    return visit_id


def keys_in(value) -> set[str]:
    if isinstance(value, dict):
        return set(value) | {key for item in value.values() for key in keys_in(item)}
    if isinstance(value, list):
        return {key for item in value for key in keys_in(item)}
    return set()


# Refill


def test_a_deflected_visit_names_the_medicine(api):
    ahmed = patient(api, AHMED_QID)
    visit_id = open_visit(ahmed)
    tell(ahmed, visit_id, AHMED_TEXT)
    view = visit_view(ahmed, visit_id)
    assert view["status"] == "deflected_refill"
    assert view["refill"] == {"medicine": AMLODIPINE}


def test_the_medicine_survives_a_re_read(api):
    ahmed = patient(api, AHMED_QID)
    visit_id = open_visit(ahmed)
    tell(ahmed, visit_id, AHMED_TEXT)
    assert visit_view(ahmed, visit_id)["refill"] == visit_view(ahmed, visit_id)["refill"]
    fresh_session = patient(api, AHMED_QID)
    assert visit_view(fresh_session, visit_id)["refill"] == {"medicine": AMLODIPINE}


def test_refill_is_null_on_a_visit_in_intake(api):
    fatima = patient(api, FATIMA_QID)
    assert visit_view(fatima, open_visit(fatima))["refill"] is None


def test_refill_is_null_on_a_reserved_visit(api):
    fatima = patient(api, FATIMA_QID)
    assert visit_view(fatima, reserved_visit(fatima))["refill"] is None


def test_refill_is_null_once_the_patient_still_wants_a_visit(api):
    ahmed = patient(api, AHMED_QID)
    visit_id = open_visit(ahmed)
    tell(ahmed, visit_id, AHMED_TEXT)
    ahmed.ok(f"/api/visits/{visit_id}/refill/continue")
    view = visit_view(ahmed, visit_id)
    assert view["status"] == "intake"
    assert view["refill"] is None


def test_refill_is_null_on_an_emergency(api):
    ravi = patient(api, RAVI_QID)
    visit_id = open_visit(ravi)
    tell(ravi, visit_id, RAVI_TEXT)
    assert visit_view(ravi, visit_id)["refill"] is None


# The list


def test_list_rows_carry_the_centre_name(api):
    fatima = patient(api, FATIMA_QID)
    visit_id = reserved_visit(fatima)
    response = fatima.get("/api/visits")
    assert response.status_code == 200
    row = next(item for item in response.json() if item["visit_id"] == visit_id)
    assert row["centre"] == WAKRA
    assert row["centre_id"] == "C-WAKRA"
    assert row["completed_at"] is None


def test_a_row_with_no_centre_yet_has_a_null_centre(api):
    fatima = patient(api, FATIMA_QID)
    visit_id = open_visit(fatima)
    row = next(item for item in fatima.get("/api/visits").json() if item["visit_id"] == visit_id)
    assert row["centre"] is None
    assert row["centre_id"] is None


def test_a_completed_row_carries_completed_at(api):
    fatima = patient(api, FATIMA_QID)
    visit_id = completed_visit(api, fatima)
    row = next(item for item in fatima.get("/api/visits").json() if item["visit_id"] == visit_id)
    assert row["completed_at"] == visit_view(fatima, visit_id)["completed_at"]
    assert row["completed_at"] is not None


def test_list_rows_stay_free_of_staff_keys(api):
    fatima = patient(api, FATIMA_QID)
    confirmed_visit(fatima)
    listed = fatima.get("/api/visits").json()
    assert listed
    assert not keys_in(listed) & STAFF_ONLY_KEYS
    assert set(listed[0]) == ROW_KEYS


# The rating


def test_a_completed_visit_can_be_rated_and_shows_it(api):
    fatima = patient(api, FATIMA_QID)
    visit_id = completed_visit(api, fatima)
    assert visit_view(fatima, visit_id)["rating"] is None
    response = fatima.post(rating_path(visit_id), {"stars": 4})
    assert response.status_code == 200, response.text
    assert response.json() == {"rating": 4}
    assert visit_view(fatima, visit_id)["rating"] == 4


@pytest.mark.parametrize("stars", [1, 2, 3, 4, 5])
def test_every_star_value_is_accepted(api, stars):
    fatima = patient(api, FATIMA_QID)
    visit_id = completed_visit(api, fatima)
    assert fatima.post(rating_path(visit_id), {"stars": stars}).json() == {"rating": stars}


def test_rating_is_one_event_row_with_the_stars(api):
    fatima = patient(api, FATIMA_QID)
    visit_id = completed_visit(api, fatima)
    fatima.ok(rating_path(visit_id), {"stars": 5})
    assert event_types(visit_id).count("visit.rated") == 1
    stored = rows("SELECT payload FROM event WHERE visit_id = ? AND type = 'visit.rated'", visit_id)
    assert json.loads(stored[0]["payload"]) == {"stars": 5}


def test_rating_is_refused_before_completion(api):
    fatima = patient(api, FATIMA_QID)
    visit_id = arrived_visit(fatima)
    response = fatima.post(rating_path(visit_id), {"stars": 5})
    assert response.status_code == 409
    assert response.json()["error"] == "visit_not_completed"
    assert "visit.rated" not in event_types(visit_id)
    assert visit_view(fatima, visit_id)["rating"] is None


def test_rating_is_refused_in_intake(api):
    fatima = patient(api, FATIMA_QID)
    visit_id = open_visit(fatima)
    response = fatima.post(rating_path(visit_id), {"stars": 3})
    assert response.status_code == 409
    assert response.json()["error"] == "visit_not_completed"


def test_a_deflected_visit_cannot_be_rated(api):
    ahmed = patient(api, AHMED_QID)
    visit_id = open_visit(ahmed)
    tell(ahmed, visit_id, AHMED_TEXT)
    assert ahmed.post(rating_path(visit_id), {"stars": 3}).status_code == 409


@pytest.mark.parametrize(
    "body",
    [
        {"stars": 0},
        {"stars": 6},
        {"stars": -1},
        {"stars": "3"},
        {"stars": "five"},
        {"stars": None},
        {"stars": 3.5},
        {"stars": True},
        {},
    ],
    ids=repr,
)
def test_a_bad_rating_is_422_and_stores_nothing(api, body):
    fatima = patient(api, FATIMA_QID)
    visit_id = completed_visit(api, fatima)
    assert fatima.post(rating_path(visit_id), body).status_code == 422
    assert "visit.rated" not in event_types(visit_id)
    assert visit_view(fatima, visit_id)["rating"] is None


def test_a_second_rating_is_refused_and_keeps_the_first(api):
    fatima = patient(api, FATIMA_QID)
    visit_id = completed_visit(api, fatima)
    fatima.ok(rating_path(visit_id), {"stars": 5})
    response = fatima.post(rating_path(visit_id), {"stars": 1})
    assert response.status_code == 409
    assert response.json()["error"] == "already_rated"
    assert event_types(visit_id).count("visit.rated") == 1
    assert visit_view(fatima, visit_id)["rating"] == 5


def test_a_guardian_rates_a_dependents_visit(api):
    fatima = patient(api, FATIMA_QID)
    nurse = staff(api, NURSE)
    doctor = staff(api, DOCTOR2)
    pharmacist = staff(api, PHARMACIST)
    visit_id = arrived_visit(fatima, patient_id="P004")
    to_counter(nurse, visit_id)
    hand_off(nurse, visit_id)
    see_doctor(doctor, visit_id)
    dispense(pharmacist, visit_id)
    assert fatima.post(rating_path(visit_id), {"stars": 2}).json() == {"rating": 2}


def test_another_patient_gets_403(api):
    fatima = patient(api, FATIMA_QID)
    ravi = patient(api, RAVI_QID)
    visit_id = completed_visit(api, fatima)
    response = ravi.post(rating_path(visit_id), {"stars": 1})
    assert response.status_code == 403
    assert "visit.rated" not in event_types(visit_id)


def test_no_token_gets_401(api):
    fatima = patient(api, FATIMA_QID)
    visit_id = completed_visit(api, fatima)
    assert api.post(rating_path(visit_id), json={"stars": 1}).status_code == 401
    assert "visit.rated" not in event_types(visit_id)


def test_a_staff_token_gets_403(api):
    fatima = patient(api, FATIMA_QID)
    visit_id = completed_visit(api, fatima)
    response = staff(api, NURSE).post(rating_path(visit_id), {"stars": 1})
    assert response.status_code == 403


def test_an_unknown_visit_gets_404(api):
    fatima = patient(api, FATIMA_QID)
    assert fatima.post(rating_path("V_nope"), {"stars": 1}).status_code == 404


def test_rating_changes_no_visit_ticket_or_stats(api):
    fatima = patient(api, FATIMA_QID)
    nurse = staff(api, NURSE)
    visit_id = completed_visit(api, fatima)
    before = visit_view(fatima, visit_id)
    stats = nurse.get(STATS).json()
    tables = table_dump("visit", "ticket")
    fatima.ok(rating_path(visit_id), {"stars": 3})
    assert {**visit_view(fatima, visit_id), "rating": None} == before
    assert nurse.get(STATS).json() == stats
    assert table_dump("visit", "ticket") == tables


def test_the_route_is_plain_def():
    assert not inspect.iscoroutinefunction(visits.rate_visit)
