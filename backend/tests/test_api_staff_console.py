"""What the staff consoles read: the session route, raised flags and the Arabic draft."""

from __future__ import annotations

import pytest

from backend.tests.api_helpers import (
    DESK,
    DOCTOR2,
    FATIMA_QID,
    NURSE,
    PHARMACIST,
    bearer,
    patient_token,
    staff_token,
)
from backend.tests.test_api_clinical import DENIED_ANSWERS, detail, draft
from backend.tests.test_api_staff import (
    FATIMA,
    OTHER_NURSE,
    P1,
    T1,
    Staff,
    arrived,
    at_vitals,
    chat,
    execute,
    new_visit,
    nurse,  # noqa: F401
)

ME = "/api/staff/me"


def me(api, staff_id):
    response = api.get(ME, headers=bearer(staff_token(api, staff_id)))
    assert response.status_code == 200, response.text
    return response.json()


def test_me_returns_exactly_the_shape_the_session_reads(api):
    body = me(api, NURSE)
    assert set(body) == {"staff", "centre", "counters", "centre_counters"}
    assert body["staff"] == {
        "id": NURSE,
        "name": "Amal Al-Demo",
        "role": "nurse",
        "clinic": None,
        "centre_id": "C-WAKRA",
    }
    assert body["centre"] == {
        "id": "C-WAKRA",
        "name_en": "Al Wakra Health Centre",
        "name_ar": "مركز الوكرة الصحي",
    }
    assert body["counters"] == [
        {"id": T1, "label": "Triage 1", "label_ar": "الفرز 1", "stage": "triage", "prefix": "T"}
    ]


def test_me_lists_every_counter_of_the_centre_and_only_that_centre(api):
    centre = me(api, NURSE)["centre_counters"]
    assert [counter["id"] for counter in centre] == [
        "C-WAKRA-D3",
        "C-WAKRA-D4",
        "C-WAKRA-DEN1",
        "C-WAKRA-P1",
        "C-WAKRA-T1",
        "C-WAKRA-WH1",
    ]
    assert all(set(counter) == {"id", "label", "label_ar", "stage"} for counter in centre)

    other = me(api, OTHER_NURSE)
    assert other["centre"]["id"] == "C-RAYYAN"
    assert all(counter["id"].startswith("C-RAYYAN") for counter in other["centre_counters"])


@pytest.mark.parametrize(
    ("staff_id", "own"),
    [(DOCTOR2, ["C-WAKRA-D4"]), (PHARMACIST, [P1]), (DESK, [])],
)
def test_me_lists_own_counters_for_every_role(api, staff_id, own):
    assert [counter["id"] for counter in me(api, staff_id)["counters"]] == own


def test_me_needs_a_session(api):
    response = api.get(ME)
    assert response.status_code == 401
    assert response.json()["error"] == "unauthorized"


def test_me_refuses_a_patient(api):
    response = api.get(ME, headers=bearer(patient_token(api, FATIMA_QID)))
    assert response.status_code == 403


def test_the_staff_visit_lists_raised_flags_as_labels(api, nurse):  # noqa: F811
    visit_id = new_visit(FATIMA)
    chat(api, visit_id, "Chest pain going to my left arm.")
    execute("UPDATE visit SET centre_id = 'C-WAKRA' WHERE id = ?", visit_id)

    body = detail(nurse, visit_id)

    assert body["red_flags_raised"]
    assert all(isinstance(label, str) for label in body["red_flags_raised"])
    assert body["red_flags_checked"] == "Red flag raised: " + ", ".join(body["red_flags_raised"])


def test_the_staff_visit_has_an_empty_list_when_nothing_was_raised(api, nurse):  # noqa: F811
    body = detail(nurse, arrived(api))
    assert body["red_flags_raised"] == []
    assert body["red_flags_checked"] == "none detected"


def test_a_denied_cue_is_not_a_raised_flag(api, nurse):  # noqa: F811
    body = detail(nurse, arrived(api, answers=DENIED_ANSWERS))
    assert body["red_flags_raised"] == []
    assert body["red_flags_checked"] == "Patient denied: chest pain"


def test_the_staff_visit_says_when_the_patient_arrived(api, nurse):  # noqa: F811
    assert detail(nurse, arrived(api))["arrived_at"] is not None


def test_the_staff_visit_refuses_another_centre(api):
    visit_id = arrived(api)
    other = bearer(staff_token(api, OTHER_NURSE))
    response = api.get(f"/api/staff/visits/{visit_id}", headers=other)
    assert response.status_code == 403
    assert response.json()["error"] == "wrong_centre"


def test_the_staff_visit_needs_a_session_and_refuses_a_patient(api):
    path = f"/api/staff/visits/{arrived(api)}"
    assert api.get(path).status_code == 401
    assert api.get(path, headers=bearer(patient_token(api, FATIMA_QID))).status_code == 403


def test_the_draft_offers_the_arabic_template_beside_the_english(api, nurse):  # noqa: F811
    visit_id = at_vitals(nurse, api)

    body = draft(nurse, visit_id)

    assert set(body) == {"text", "text_ar", "source", "suggestions", "denied_text"}
    assert body["source"] == "simulated"
    assert body["text_ar"] != body["text"]
    assert any("؀" <= letter <= "ۿ" for letter in body["text_ar"])
    assert len(body["text_ar"].splitlines()) == len(body["text"].splitlines())


def test_the_arabic_draft_is_never_stored(api, nurse):  # noqa: F811
    visit_id = at_vitals(nurse, api)

    body = draft(nurse, visit_id)

    stored = detail(nurse, visit_id)["handoff"]
    assert stored["ai_draft"] == body["text"]
    assert stored["final_text"] is None


def test_the_draft_keeps_its_guards(api):
    path = f"/api/visits/{at_vitals(Staff(api, NURSE), api)}/handoff/draft"
    assert api.post(path).status_code == 401
    assert api.post(path, headers=bearer(patient_token(api, FATIMA_QID))).status_code == 403
    pharmacist = bearer(staff_token(api, PHARMACIST))
    assert api.post(path, headers=pharmacist).status_code == 403
    other = bearer(staff_token(api, OTHER_NURSE))
    response = api.post(path, headers=other)
    assert (response.status_code, response.json()["error"]) == (403, "wrong_centre")
