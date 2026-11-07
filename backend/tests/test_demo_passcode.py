"""Reset demo asks for the passcode once DEMO_PASSCODE is set, and the Arabic handoff reads Arabic."""

from __future__ import annotations

from backend.ai import handoff
from backend.tests.api_helpers import bearer, staff_token

NURSE = "S-RAY-NURSE1"


def test_reset_stays_open_when_no_passcode_is_set(api, monkeypatch):
    monkeypatch.delenv("DEMO_PASSCODE", raising=False)
    response = api.post("/api/demo/reset", headers=bearer(staff_token(api, NURSE)))
    assert response.status_code == 200


def test_reset_refuses_without_the_passcode(api, monkeypatch):
    monkeypatch.setenv("DEMO_PASSCODE", "4821")
    headers = bearer(staff_token(api, NURSE))
    for body in (None, {}, {"passcode": ""}, {"passcode": "0000"}):
        response = api.post("/api/demo/reset", headers=headers, json=body)
        assert response.status_code == 403
        assert response.json()["error"] == "passcode_required"


def test_reset_works_with_the_passcode(api, monkeypatch):
    monkeypatch.setenv("DEMO_PASSCODE", "4821")
    headers = bearer(staff_token(api, NURSE))
    response = api.post("/api/demo/reset", headers=headers, json={"passcode": " 4821 "})
    assert response.status_code == 200


def test_reset_still_needs_staff(api, monkeypatch):
    monkeypatch.setenv("DEMO_PASSCODE", "4821")
    assert api.post("/api/demo/reset", json={"passcode": "4821"}).status_code == 401


PATIENT = {
    "full_name_en": "Ahmed Al-Demo",
    "full_name_ar": "أحمد التجريبي",
    "age": 67,
    "sex": "M",
    "allergies": ["penicillin"],
    "chronic": ["hypertension"],
    "active_meds": ["amlodipine 5 mg once daily"],
}


def _intake(words: str) -> dict:
    return {
        "chief_complaint": "fever and cough",
        "chief_complaint_patient_words": words,
        "duration": "since yesterday",
        "severity_0_10": 8,
    }


def test_the_arabic_handoff_uses_the_patients_arabic_words():
    text = handoff.template(_intake("عندي حرارة وكحة"), None, PATIENT, "ar")
    assert "عندي حرارة وكحة" in text
    assert "من أمس" in text
    assert "ارتفاع ضغط الدم" in text
    assert "أملوديبين" in text
    assert "البنسلين" in text
    assert "fever" not in text


def test_the_arabic_handoff_keeps_english_words_it_cannot_translate():
    assert "fever and cough" in handoff.template(_intake("I have a fever"), None, PATIENT, "ar")


def test_the_english_handoff_is_unchanged():
    text = handoff.template(_intake("عندي حرارة وكحة"), None, PATIENT, "en")
    assert "fever and cough" in text
    assert "since yesterday" in text
    assert "hypertension" in text
