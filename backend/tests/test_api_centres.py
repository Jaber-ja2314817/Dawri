"""The centre map: services, the order of the list, and the suggestion rule."""

from __future__ import annotations

from pathlib import Path

import pytest

from backend import centres, db, geo
from backend.ai import intake
from backend.tests.api_helpers import (
    AHMED_QID,
    FATIMA_QID,
    NURSE,
    RAVI_QID,
    bearer,
    patient_token,
    staff_token,
    start_visit,
)

WAKRA_T1 = "C-WAKRA-T1"
HOSPITALS = {"H-HGH", "H-WAKRA"}
GP_CENTRES = {"C-WAKRA", "C-RAYYAN", "C-MESAIMEER", "C-AIRPORT", "C-WESTBAY"}
AIRPORT = (25.25580, 51.55778)
WEST_BAY = (25.33767, 51.50388)


@pytest.fixture
def conn(api):
    connection = db.connect()
    yield connection
    connection.close()


@pytest.fixture
def fatima(api):
    return patient_token(api, FATIMA_QID)


def _map(api, token, **params):
    response = api.get("/api/centres", params=params, headers=bearer(token))
    assert response.status_code == 200, response.text
    return response.json()


def _ids(body):
    return [item["id"] for item in body["centres"]]


def _by_id(body):
    return {item["id"]: item for item in body["centres"]}


def _fill_wakra(api, tickets):
    for _ in range(tickets):
        api.app.state.engine.issue_simulated(WAKRA_T1)


# Fatima's map


def test_fatimas_map_starts_at_her_centre(api, fatima):
    body = _map(api, fatima)
    assert body["service"] == body["effective_service"] == "gp"
    assert body["service_fallback"] is False
    assert body["default_centre_id"] == "C-WAKRA"
    first = body["centres"][0]
    assert first["id"] == "C-WAKRA"
    assert first["registered"] is True
    assert (first["wait_min"], first["people_ahead"]) == (12, 3)
    assert 30 <= _by_id(body)["C-AIRPORT"]["wait_min"] <= 40


def test_entry_shape(api, fatima):
    first = _map(api, fatima)["centres"][0]
    assert set(first) == {
        "id",
        "name_en",
        "name_ar",
        "operator",
        "lat",
        "lng",
        "wait_min",
        "people_ahead",
        "distance_km",
        "registered",
    }
    assert first["operator"] == "PHCC"
    assert first["name_ar"] == "مركز الوكرة الصحي"


def test_only_one_centre_is_marked_registered(api, fatima):
    assert [item["id"] for item in _map(api, fatima)["centres"] if item["registered"]] == [
        "C-WAKRA"
    ]


def test_with_no_location_the_rest_are_ordered_by_wait(api, fatima):
    body = _map(api, fatima)
    waits = [item["wait_min"] for item in body["centres"][1:]]
    assert waits == sorted(waits)
    assert all(item["distance_km"] is None for item in body["centres"])


def test_with_a_location_the_rest_are_ordered_by_distance(api, fatima):
    body = _map(api, fatima, lat=WEST_BAY[0], lng=WEST_BAY[1])
    assert body["centres"][0]["id"] == "C-WAKRA"  # Registered first, even though furthest.
    rest = [item["distance_km"] for item in body["centres"][1:]]
    assert rest == sorted(rest)
    assert body["centres"][1]["id"] == "C-WESTBAY"
    assert body["centres"][1]["distance_km"] == 0.0


def test_half_a_location_is_no_location(api, fatima):
    assert all(item["distance_km"] is None for item in _map(api, fatima, lat=25.2)["centres"])


# Services


@pytest.mark.parametrize("service", ["dental", "womens_health"])
def test_a_service_only_al_wakra_offers(api, fatima, service):
    body = _map(api, fatima, service=service)
    assert _ids(body) == ["C-WAKRA"]
    assert body["service_fallback"] is False
    assert body["effective_service"] == service


@pytest.mark.parametrize("service", ["mental_health", "other", "refill"])
def test_services_seen_by_a_gp_fall_back_and_say_so(api, fatima, service):
    body = _map(api, fatima, service=service)
    assert body["service"] == service
    assert body["effective_service"] == "gp"
    assert body["service_fallback"] is True
    assert set(_ids(body)) == GP_CENTRES


@pytest.mark.parametrize("service", intake.SERVICES)
def test_hospitals_never_appear_for_a_normal_service(api, fatima, service):
    assert not HOSPITALS & set(_ids(_map(api, fatima, service=service)))


def test_a_hospital_stays_out_even_if_it_offers_the_service(api, fatima, conn):
    conn.execute("""UPDATE centre SET services = '["gp", "emergency"]' WHERE id = 'H-HGH'""")
    assert set(_ids(_map(api, fatima))) == GP_CENTRES


def test_a_registered_centre_without_the_service_is_not_the_default(api):
    token = patient_token(api, AHMED_QID)  # Registered at Al Rayyan, which has no dental.
    body = _map(api, token, service="dental")
    assert _ids(body) == ["C-WAKRA"]
    assert body["default_centre_id"] is None
    assert body["centres"][0]["registered"] is False
    assert body["suggestion"] is None


def test_unknown_service(api, fatima):
    response = api.get("/api/centres", params={"service": "icu"}, headers=bearer(fatima))
    assert response.status_code == 422
    assert response.json()["error"] == "unknown_service"


@pytest.mark.parametrize(
    "params",
    [{"lat": "nan", "lng": 51}, {"lat": 91, "lng": 51}, {"lat": 25, "lng": -181}, {"lat": "x"}],
    ids=["nan", "lat range", "lng range", "not a number"],
)
def test_bad_coordinates(api, fatima, params):
    response = api.get("/api/centres", params=params, headers=bearer(fatima))
    assert response.status_code == 422


# Emergency


def test_the_emergency_list_is_hospitals_by_distance_from_home(api, fatima):
    body = _map(api, fatima, service="emergency")
    assert _ids(body) == ["H-WAKRA", "H-HGH"]
    assert body["suggestion"] is None
    assert body["service_fallback"] is False
    assert body["effective_service"] == "emergency"
    for item in body["centres"]:
        assert item["wait_min"] is None
        assert item["people_ahead"] is None
        assert item["distance_km"] > 0
        assert item["operator"] == "HMC"
    assert body["centres"][0]["distance_km"] < body["centres"][1]["distance_km"]


def test_the_emergency_list_uses_the_location_when_it_has_one(api, fatima):
    body = _map(api, fatima, service="emergency", lat=WEST_BAY[0], lng=WEST_BAY[1])
    assert _ids(body) == ["H-HGH", "H-WAKRA"]


def test_nearest_emergency(conn, api):
    nearest = centres.nearest_emergency(conn, 25.17302, 51.59575)
    assert set(nearest) == {"id", "name_en", "name_ar", "lat", "lng", "distance_km"}
    assert nearest["id"] == "H-WAKRA"
    assert nearest["distance_km"] == pytest.approx(1.0, abs=0.2)
    assert centres.nearest_emergency(conn, *WEST_BAY)["id"] == "H-HGH"


# Access


def test_needs_a_patient_session(api):
    assert api.get("/api/centres").status_code == 401
    response = api.get("/api/centres", headers=bearer(staff_token(api, NURSE)))
    assert response.status_code == 403


def test_a_dependents_map_starts_at_the_dependents_centre(api, fatima, conn):
    conn.execute("UPDATE patient SET registered_centre_id = 'C-AIRPORT' WHERE id = 'P004'")
    visit_id = start_visit(api, fatima, "P004")
    assert _map(api, fatima, visit_id=visit_id)["default_centre_id"] == "C-AIRPORT"
    assert _map(api, fatima)["default_centre_id"] == "C-WAKRA"


def test_a_strangers_visit_is_refused(api, fatima):
    visit_id = start_visit(api, fatima)
    token = patient_token(api, RAVI_QID)
    response = api.get("/api/centres", params={"visit_id": visit_id}, headers=bearer(token))
    assert response.status_code == 403
    assert response.json()["error"] == "forbidden"


def test_an_unknown_visit_is_a_404(api, fatima):
    response = api.get("/api/centres", params={"visit_id": "V-NOPE"}, headers=bearer(fatima))
    assert response.status_code == 404


# Suggestion


def test_no_suggestion_for_fatima_on_a_fresh_reset(api, fatima):
    assert _map(api, fatima)["suggestion"] is None


def test_suggestion_fires_on_a_long_queue(api, fatima):
    _fill_wakra(api, 10)  # 13 tickets at 4 min is 52, against Airport's 36.
    body = _map(api, fatima)
    suggestion = body["suggestion"]
    assert suggestion["centre_id"] == "C-AIRPORT"
    assert set(suggestion) == {"centre_id", "reason_en", "reason_ar"}
    assert "36" in suggestion["reason_en"] and "52" in suggestion["reason_en"]
    assert "36" in suggestion["reason_ar"] and "52" in suggestion["reason_ar"]


def test_a_suggestion_never_moves_the_default(api, fatima):
    _fill_wakra(api, 10)
    body = _map(api, fatima)
    assert body["suggestion"] is not None
    assert body["default_centre_id"] == "C-WAKRA"
    assert body["centres"][0]["id"] == "C-WAKRA"


def test_no_suggestion_short_of_the_margin(api, fatima):
    _fill_wakra(api, 9)  # 48 against 36: only 12 minutes shorter.
    assert _map(api, fatima)["suggestion"] is None


def test_no_suggestion_for_a_service_nobody_else_offers(api, fatima):
    _fill_wakra(api, 10)
    assert _map(api, fatima, service="dental")["suggestion"] is None


def test_a_far_location_rules_out_the_near_centre(api, fatima):
    _fill_wakra(api, 10)
    # From the far west nothing short enough is within 12 km.
    assert _map(api, fatima, lat=25.28, lng=51.2)["suggestion"] is None


def _entry(centre_id, wait, point=AIRPORT, registered=False):
    return {
        "id": centre_id,
        "name_en": centre_id,
        "name_ar": centre_id,
        "lat": point[0],
        "lng": point[1],
        "wait_min": wait,
        "registered": registered,
    }


def _north_of(point, km):
    return (point[0] + km / 111.195, point[1])


def test_exactly_the_margin_is_enough():
    entries = [_entry("HOME", 40, registered=True), _entry("A", 25)]
    assert centres.suggest(entries, AIRPORT)["centre_id"] == "A"
    entries[1]["wait_min"] = 26
    assert centres.suggest(entries, AIRPORT) is None


def test_exactly_the_distance_is_near_enough():
    entries = [
        _entry("HOME", 60, registered=True),
        _entry("A", 10, _north_of(AIRPORT, 11.99)),
    ]
    assert centres.suggest(entries, AIRPORT)["centre_id"] == "A"
    entries[1].update(zip(("lat", "lng"), _north_of(AIRPORT, 12.01)))
    assert centres.suggest(entries, AIRPORT) is None


def test_lowest_wait_wins_then_nearest():
    home = _entry("HOME", 60, registered=True)
    near = _entry("NEAR", 20, _north_of(AIRPORT, 2))
    far = _entry("FAR", 20, _north_of(AIRPORT, 8))
    shortest = _entry("SHORTEST", 10, _north_of(AIRPORT, 9))
    assert centres.suggest([home, far, near], AIRPORT)["centre_id"] == "NEAR"
    assert centres.suggest([home, far, near, shortest], AIRPORT)["centre_id"] == "SHORTEST"


def test_no_registered_entry_or_no_reference_means_no_suggestion():
    assert centres.suggest([_entry("A", 1)], AIRPORT) is None
    assert centres.suggest([_entry("HOME", 60, registered=True), _entry("A", 1)], None) is None


# The rule itself


@pytest.mark.parametrize(
    ("service", "routed"),
    [
        ("mental_health", "gp"),
        ("other", "gp"),
        ("refill", "gp"),
        ("gp", "gp"),
        ("dental", "dental"),
        ("vaccination", "vaccination"),
        ("lab_only", "lab_only"),
        ("womens_health", "womens_health"),
    ],
)
def test_routed_service(service, routed):
    assert centres.routed_service(service) == routed


def test_the_rule_needs_no_model():
    source = Path(centres.__file__).read_text(encoding="utf-8")
    assert "backend.ai" not in source
    assert "llm" not in source


def test_the_distances_the_rule_depends_on():
    wakra = (25.17302, 51.59575)
    assert geo.distance_m(*wakra, *AIRPORT) / 1000 < 12
