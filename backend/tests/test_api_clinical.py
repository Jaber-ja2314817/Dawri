"""The nurse, doctor and pharmacy steps, and the safety rules that sit on them."""

from __future__ import annotations

import pytest

from backend.adapters.queue_base import VisitNotEligible
from backend.ai import handoff
from backend.tests.api_helpers import (
    AHMED_TEXT,
    DOCTOR2,
    FATIMA_ANSWERS,
    FATIMA_QID,
    bearer,
    patient_token,
)
from backend.tests.test_api_staff import (
    D4,
    FATIMA,
    LAYLA,
    OTHER_DOCTOR,
    P1,
    T1,
    arrived,
    at_doctor,
    at_vitals,
    chat,
    doctor,  # noqa: F401
    event_types,
    execute,
    new_visit,
    nurse,  # noqa: F401
    pharmacist,  # noqa: F401
    reserved,
    rows,
    table_dump,
)

GENEROUS = {"bp_sys": 118, "bp_dia": 76, "hr": 70, "temp_c": 37.2, "spo2": 99, "weight_kg": 61.5}
DENIED_COMPLAINT = "ما عندي ألم في الصدر بس عندي حرارة وكحة من ثلاث أيام"
DENIED_ANSWERS = (DENIED_COMPLAINT, *FATIMA_ANSWERS[1:])


def visit_row(visit_id):
    return rows("SELECT * FROM visit WHERE id = ?", visit_id)[0]


def detail(staff, visit_id):
    response = staff.get(f"/api/staff/visits/{visit_id}")
    assert response.status_code == 200, response.text
    return response.json()


def draft(nurse, visit_id):
    return nurse.ok(f"/api/visits/{visit_id}/handoff/draft")


def confirm(nurse, visit_id, text="Confirmed handoff.", doctor_id=DOCTOR2):
    return nurse.post(
        f"/api/visits/{visit_id}/handoff/confirm", {"final_text": text, "doctor_id": doctor_id}
    )


def drug_table(staff, visit_id):
    return {drug["id"]: drug for drug in staff.get(f"/api/staff/visits/{visit_id}/drugs").json()}


def to_pharmacy(nurse, doctor, api, **kwargs):
    visit_id = at_doctor(nurse, api, **kwargs)
    doctor.ok(f"/api/counters/{D4}/call-next")
    body = {"prescription": [{"drug_id": "DR-PARA"}]}
    assert doctor.ok(f"/api/visits/{visit_id}/consult/done", body)["status"] == "in_pharmacy"
    return visit_id


# The nurse backstop


def test_exact_words_sit_beside_the_summary(api, nurse):
    visit_id = arrived(api)
    body = detail(nurse, visit_id)
    assert body["patient_words"] == list(FATIMA_ANSWERS)
    spoken = [turn["text"] for turn in body["turns"] if turn["role"] == "patient"]
    assert spoken == list(FATIMA_ANSWERS)
    assert body["intake"]["summary_for_nurse"]
    assert body["status"] == "in_triage"
    assert body["ticket"]["number"] == "T-014"
    assert body["service"] == "gp"
    assert body["ai_mode"] == "simulated"
    assert body["vitals"] is None and body["handoff"] is None
    assert body["prescription"] == []
    assert body["medicines"] == {"en": [], "ar": []}
    assert body["red_flags_checked"] == "none detected"


def test_penicillin_allergy_shows_in_the_staff_view(api, nurse):
    patient = detail(nurse, arrived(api))["patient"]
    assert patient["allergies"] == ["penicillin"]
    assert patient["name"] == "Fatima Al-Demo"
    assert patient["sex"] == "F"
    assert patient["chronic"] == [] and patient["active_meds"] == []
    assert patient["age"] >= 34


def test_denied_text_comes_in_both_languages(api, nurse):
    visit_id = arrived(api, answers=DENIED_ANSWERS)
    body = detail(nurse, visit_id)
    assert body["denied"] == ["chest pain"]
    assert body["denied_text_en"] == "Patient denied: chest pain"
    assert body["denied_text_ar"].startswith("المريض نفى: ")
    assert body["red_flags_checked"] == "Patient denied: chest pain"


def test_a_fired_rule_is_never_reported_as_none_detected(api, nurse):
    visit_id, _ = reserved(api)
    assert chat(api, visit_id, "I have chest pain now").emergency
    body = detail(nurse, visit_id)
    assert body["status"] == "redirected_emergency"
    assert body["red_flags_checked"].startswith("Red flag raised: ")
    assert body["ticket"] is None or body["ticket"]["state"] == "reserved"


def test_a_nurse_edit_leaves_the_transcript_alone(api, nurse):
    visit_id = arrived(api)
    before = rows("SELECT json, transcript FROM intake WHERE visit_id = ?", visit_id)
    response = nurse.put(
        f"/api/visits/{visit_id}/intake", {"json": {"chief_complaint": "Cough and fever, 3 days"}}
    )
    assert response.status_code == 200
    body = response.json()
    assert body["edited"] is True and body["draft_cleared"] is False
    assert body["intake"]["chief_complaint"] == "Cough and fever, 3 days"

    assert rows("SELECT json, transcript FROM intake WHERE visit_id = ?", visit_id) == before
    stored = rows("SELECT edited_by_staff_id FROM intake WHERE visit_id = ?", visit_id)
    assert stored == [{"edited_by_staff_id": "S-WAK-NURSE1"}]
    seen = detail(nurse, visit_id)
    assert seen["edited"] is True
    assert seen["intake"]["chief_complaint"] == "Cough and fever, 3 days"
    assert seen["patient_words"] == list(FATIMA_ANSWERS)
    assert "intake.edited" in event_types(visit_id)


def test_the_nurse_cannot_rewrite_what_the_patient_said(api, nurse):
    visit_id = arrived(api, answers=DENIED_ANSWERS)
    stored = detail(nurse, visit_id)["intake"]
    response = nurse.put(
        f"/api/visits/{visit_id}/intake",
        {
            "json": {
                "denied_red_flags": [],
                "emergency": True,
                "chief_complaint_patient_words": "something else",
                "duration": "2 days",
                "not_a_field": "dropped",
            }
        },
    )
    assert response.status_code == 200
    edited = response.json()["intake"]
    assert edited["denied_red_flags"] == stored["denied_red_flags"] == ["chest pain"]
    assert edited["emergency"] is False
    assert edited["chief_complaint_patient_words"] == stored["chief_complaint_patient_words"]
    assert edited["duration"] == "2 days"
    assert "not_a_field" not in edited


@pytest.mark.parametrize(
    "fields",
    [
        {"chief_complaint": ""},
        {"severity_0_10": 11},
        {"service": "astrology"},
        {"service_confidence": 2},
    ],
)
def test_a_bad_edit_is_refused_and_stores_nothing(api, nurse, fields):
    visit_id = arrived(api)
    response = nurse.put(f"/api/visits/{visit_id}/intake", {"json": fields})
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_intake"
    assert rows("SELECT edited_json FROM intake WHERE visit_id = ?", visit_id) == [
        {"edited_json": None}
    ]


def test_edit_only_at_triage(api, nurse):
    visit_id = at_doctor(nurse, api)
    response = nurse.put(f"/api/visits/{visit_id}/intake", {"json": {"duration": "1 day"}})
    assert response.status_code == 409
    assert response.json()["error"] == "visit_not_in_triage"


def test_a_nan_in_an_edit_is_refused(api, nurse):
    visit_id = arrived(api)
    response = nurse.api.put(
        f"/api/visits/{visit_id}/intake",
        content='{"json": {"service_confidence": NaN}}',
        headers={**nurse.headers, "Content-Type": "application/json"},
    )
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_intake"


# Vitals


def test_vitals_serve_a_called_ticket_and_are_stored(api, nurse):
    visit_id = arrived(api)
    ticket = nurse.ok(f"/api/counters/{T1}/call-next")["called"]
    body = nurse.ok(f"/api/visits/{visit_id}/vitals", {**GENEROUS, "urgency": "soon"})
    assert body["status"] == "in_triage" and body["stage"] == "triage"
    assert body["escalated"] is False
    assert body["ticket"]["id"] == ticket["id"] and body["ticket"]["state"] == "serving"
    stored = detail(nurse, visit_id)["vitals"]
    assert stored["urgency"] == "soon" and stored["nurse_id"] == "S-WAK-NURSE1"
    assert stored["temp_c"] == 37.2 and stored["at"]
    assert "vitals.recorded" in event_types(visit_id)


def test_vitals_on_a_served_ticket_upsert(api, nurse):
    visit_id = arrived(api)
    ticket = nurse.ok(f"/api/counters/{T1}/call-next")["called"]
    nurse.ok(f"/api/tickets/{ticket['id']}/serve")
    nurse.ok(f"/api/visits/{visit_id}/vitals", {"hr": 80, "urgency": "routine"})
    nurse.ok(f"/api/visits/{visit_id}/vitals", {"hr": 90, "urgency": "soon"})
    assert rows("SELECT hr, urgency FROM vitals WHERE visit_id = ?", visit_id) == [
        {"hr": 90, "urgency": "soon"}
    ]


def test_vitals_need_a_called_ticket(api, nurse):
    visit_id = arrived(api)
    response = nurse.post(f"/api/visits/{visit_id}/vitals", {"urgency": "urgent"})
    assert response.status_code == 409
    assert response.json()["error"] == "not_called"
    assert visit_row(visit_id)["status"] == "in_triage"
    assert rows("SELECT * FROM vitals WHERE visit_id = ?", visit_id) == []


@pytest.mark.parametrize(
    "fields",
    [
        {"spo2": 101},
        {"hr": 5},
        {"bp_sys": 900},
        {"temp_c": 60},
        {"weight_kg": -1},
        {"urgency": "someday"},
    ],
)
def test_vitals_ranges(api, nurse, fields):
    visit_id = arrived(api)
    nurse.ok(f"/api/counters/{T1}/call-next")
    response = nurse.post(f"/api/visits/{visit_id}/vitals", {"urgency": "routine", **fields})
    assert response.status_code == 422
    assert rows("SELECT state FROM ticket WHERE visit_id = ?", visit_id) == [{"state": "called"}]


def test_vitals_refuse_nan(api, nurse):
    visit_id = arrived(api)
    nurse.ok(f"/api/counters/{T1}/call-next")
    response = nurse.api.post(
        f"/api/visits/{visit_id}/vitals",
        content='{"temp_c": NaN, "urgency": "routine"}',
        headers={**nurse.headers, "Content-Type": "application/json"},
    )
    assert response.status_code == 422


# Urgent to the ED


def test_urgent_ends_the_queue_for_this_visit(api, nurse, doctor):
    visit_id = arrived(api)
    ticket = nurse.ok(f"/api/counters/{T1}/call-next")["called"]
    body = nurse.ok(f"/api/visits/{visit_id}/vitals", {"urgency": "urgent"})
    assert body["status"] == "redirected_emergency"
    assert body["stage"] == "emergency"
    assert body["escalated"] is True
    assert body["ticket"]["id"] == ticket["id"]
    assert body["ticket"]["state"] == "released"

    assert visit_row(visit_id)["status"] == "redirected_emergency"
    assert rows(
        "SELECT state FROM ticket WHERE visit_id = ? AND state NOT IN ('released', 'done')",
        visit_id,
    ) == []
    engine = api.app.state.engine
    assert engine.live_ticket(visit_id) is None

    refused = {
        nurse.post(f"/api/visits/{visit_id}/handoff/draft"): "visit_not_in_triage",
        confirm(nurse, visit_id): "visit_not_in_triage",
        nurse.post(f"/api/visits/{visit_id}/vitals", {"urgency": "routine"}): "visit_not_in_triage",
        nurse.post(f"/api/demo/fast-forward/{visit_id}"): "visit_not_ready",
    }
    for response, code in refused.items():
        assert response.status_code == 409
        assert response.json()["error"] == code
    response = doctor.post(f"/api/visits/{visit_id}/consult/done", {"prescription": []})
    assert response.status_code == 409 and response.json()["error"] == "visit_not_in_doctor"
    with pytest.raises(VisitNotEligible):
        engine.issue_active(visit_id, T1)
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, T1)


def test_urgent_clears_a_waiting_draft(api, nurse):
    visit_id = at_vitals(nurse, api)
    draft(nurse, visit_id)
    nurse.ok(f"/api/visits/{visit_id}/vitals", {"urgency": "urgent"})
    assert rows("SELECT * FROM handoff WHERE visit_id = ?", visit_id) == []


# The handoff


def test_the_edit_reaches_the_draft_and_the_final_text(api, nurse, doctor):
    visit_id = at_vitals(nurse, api)
    edit = "Persistent wheeze since Tuesday"
    assert nurse.put(
        f"/api/visits/{visit_id}/intake", {"json": {"chief_complaint": edit}}
    ).status_code == 200

    drafted = draft(nurse, visit_id)
    assert edit in drafted["text"]
    assert drafted["source"] == "simulated"
    assert drafted["denied_text"] == ""
    assert drafted["suggestions"][0]["doctor_id"] == DOCTOR2

    body = confirm(nurse, visit_id, text=drafted["text"]).json()
    assert body["doctor"] == {"id": DOCTOR2, "name": "Dr. Noor Al-Demo"}
    assert body["ticket"]["counter_id"] == D4
    assert body["ticket"]["number"] == "D-GP-023"

    seen = detail(doctor, visit_id)
    assert seen["status"] == "in_doctor"
    assert seen["intake"]["chief_complaint"] == edit
    assert edit in seen["handoff"]["final_text"]
    assert seen["handoff"]["chosen_doctor_id"] == DOCTOR2
    assert seen["handoff"]["confirmed_by"] == "S-WAK-NURSE1"
    assert seen["handoff"]["at"]
    assert seen["patient_words"] == list(FATIMA_ANSWERS)
    assert seen["ticket"]["number"] == "D-GP-023"
    assert "handoff.confirmed" in event_types(visit_id)


def test_a_later_edit_clears_the_draft(api, nurse):
    visit_id = at_vitals(nurse, api)
    draft(nurse, visit_id)
    body = nurse.put(f"/api/visits/{visit_id}/intake", {"json": {"duration": "1 day"}}).json()
    assert body["draft_cleared"] is True
    assert rows("SELECT * FROM handoff WHERE visit_id = ?", visit_id) == []
    response = confirm(nurse, visit_id)
    assert response.status_code == 409
    assert response.json()["error"] == "draft_required"
    assert visit_row(visit_id)["status"] == "in_triage"


def test_later_vitals_clear_the_draft(api, nurse):
    visit_id = at_vitals(nurse, api)
    draft(nurse, visit_id)
    nurse.ok(f"/api/visits/{visit_id}/vitals", {"hr": 120, "urgency": "soon"})
    response = confirm(nurse, visit_id)
    assert response.status_code == 409
    assert response.json()["error"] == "draft_required"
    assert "120" in draft(nurse, visit_id)["text"]


def test_an_edit_during_the_model_call_cannot_leave_a_stale_draft(api, nurse, monkeypatch):
    visit_id = at_vitals(nurse, api)
    real_draft = handoff.draft_for_visit

    def edited_while_thinking(*args, **kwargs):
        drafted = real_draft(*args, **kwargs)
        execute(
            "UPDATE intake SET edited_json = "
            "json_set(json, '$.chief_complaint', 'edit landed') WHERE visit_id = ?",
            visit_id,
        )
        return drafted

    monkeypatch.setattr(handoff, "draft_for_visit", edited_while_thinking)
    response = nurse.post(f"/api/visits/{visit_id}/handoff/draft")
    assert response.status_code == 409
    assert response.json()["error"] == "draft_stale"
    assert rows("SELECT * FROM handoff WHERE visit_id = ?", visit_id) == []


def test_a_draft_needs_vitals_and_triage(api, nurse):
    visit_id = arrived(api)
    response = nurse.post(f"/api/visits/{visit_id}/handoff/draft")
    assert response.status_code == 409
    assert response.json()["error"] == "vitals_required"


def test_draft_shows_what_was_denied(api, nurse):
    visit_id = at_vitals(nurse, api, answers=DENIED_ANSWERS)
    drafted = draft(nurse, visit_id)
    assert drafted["denied_text"] == "Patient denied: chest pain"
    assert "Patient denied: chest pain" in drafted["text"]


def test_confirm_needs_a_draft(api, nurse):
    visit_id = at_vitals(nurse, api)
    response = confirm(nurse, visit_id)
    assert response.status_code == 409
    assert response.json()["error"] == "draft_required"


@pytest.mark.parametrize("doctor_id", ["S-WAK-NURSE1", OTHER_DOCTOR, "nobody"])
def test_confirm_needs_a_doctor_at_this_centre(api, nurse, doctor_id):
    visit_id = at_vitals(nurse, api)
    draft(nurse, visit_id)
    response = confirm(nurse, visit_id, doctor_id=doctor_id)
    assert response.status_code == 422
    assert response.json()["error"] == "unknown_doctor"
    assert visit_row(visit_id)["status"] == "in_triage"
    assert rows("SELECT confirmed_by FROM handoff WHERE visit_id = ?", visit_id) == [
        {"confirmed_by": None}
    ]


@pytest.mark.parametrize("text", ["", "   \n ", "x" * 4001])
def test_confirm_needs_a_final_text(api, nurse, text):
    visit_id = at_vitals(nurse, api)
    draft(nurse, visit_id)
    assert confirm(nurse, visit_id, text=text).status_code == 422


def test_confirm_needs_the_patient_at_the_counter(api, nurse):
    visit_id = at_vitals(nurse, api)
    draft(nurse, visit_id)
    execute("UPDATE ticket SET state = 'active' WHERE visit_id = ?", visit_id)
    response = confirm(nurse, visit_id)
    assert response.status_code == 409
    assert response.json()["error"] == "not_called"
    assert rows("SELECT confirmed_by FROM handoff WHERE visit_id = ?", visit_id) == [
        {"confirmed_by": None}
    ]


def test_the_doctor_ticket_joins_the_end_of_that_queue(api, nurse, doctor):
    first = at_doctor(nurse, api)
    second = at_doctor(nurse, api, patient_id="P006", answers=DENIED_ANSWERS)
    tickets = doctor.get(f"/api/counters/{D4}/queue").json()["tickets"]
    assert [row["visit_id"] for row in tickets] == [first, second]
    assert tickets[1]["number"] == "D-GP-024"
    assert tickets[1]["position"] == 2


def test_the_doctor_can_be_someone_other_than_the_suggestion(api, nurse):
    visit_id = at_vitals(nurse, api)
    draft(nurse, visit_id)
    assert confirm(nurse, visit_id, doctor_id="S-WAK-DEN1").json()["ticket"]["counter_id"] == (
        "C-WAKRA-DEN1"
    )


# The drug table


def test_amoxicillin_warns_for_fatima(api, nurse, doctor):
    visit_id = at_doctor(nurse, api)
    response = doctor.get(f"/api/staff/visits/{visit_id}/drugs")
    assert response.status_code == 200
    drugs = {drug["id"]: drug for drug in response.json()}
    warning = drugs["DR-AMOX"]["allergy_warning"]
    assert warning["allergen"] == "penicillin"
    assert "penicillin" in warning["text_en"] and "أموكسيسيلين" in warning["text_ar"]
    assert drugs["DR-AUGM"]["allergy_warning"]["allergen"] == "penicillin"
    assert drugs["DR-PARA"]["allergy_warning"] is None
    assert set(drugs["DR-PARA"]) == {
        "id",
        "name_en",
        "name_ar",
        "form",
        "default_dose",
        "default_frequency",
        "default_days",
        "demo_default",
        "allergy_warning",
    }


def test_a_dependent_is_judged_on_their_own_record(api, nurse, doctor):
    visit_id = at_doctor(nurse, api, patient_id=LAYLA, booked_by=FATIMA)
    assert drug_table(doctor, visit_id)["DR-AMOX"]["allergy_warning"] is None
    doctor.ok(f"/api/counters/{D4}/call-next")
    body = {"prescription": [{"drug_id": "DR-AMOX"}]}
    assert doctor.ok(f"/api/visits/{visit_id}/consult/done", body)["status"] == "in_pharmacy"
    assert "prescription.allergy_override" not in event_types(visit_id)


def test_the_pharmacist_sees_the_same_warning(api, nurse, pharmacist):
    visit_id = at_doctor(nurse, api)
    assert drug_table(pharmacist, visit_id)["DR-AMOX"]["allergy_warning"] is not None


# The consult


def test_an_allergy_conflict_stops_until_acknowledged(api, nurse, doctor):
    visit_id = at_doctor(nurse, api)
    doctor.ok(f"/api/counters/{D4}/call-next")
    lines = [{"drug_id": "DR-PARA"}, {"drug_id": "DR-AMOX", "days": 7}]
    response = doctor.post(f"/api/visits/{visit_id}/consult/done", {"prescription": lines})
    assert response.status_code == 409
    body = response.json()
    assert body["error"] == "allergy_conflict"
    assert [conflict["drug_id"] for conflict in body["conflicts"]] == ["DR-AMOX"]
    assert body["conflicts"][0]["allergen"] == "penicillin"
    assert rows("SELECT * FROM prescription_item WHERE visit_id = ?", visit_id) == []
    assert visit_row(visit_id)["status"] == "in_doctor"
    assert "consult.done" not in event_types(visit_id)

    body = doctor.ok(
        f"/api/visits/{visit_id}/consult/done",
        {"prescription": lines, "acknowledge_allergy": True},
    )
    assert body["status"] == "in_pharmacy"
    assert body["ticket"]["number"] == "P-031"
    assert body["ticket"]["counter_id"] == P1
    stored = rows("SELECT * FROM prescription_item WHERE visit_id = ? ORDER BY id", visit_id)
    assert [row["drug"] for row in stored] == ["DR-PARA", "DR-AMOX"]
    assert stored[1]["days"] == 7
    assert stored[1]["dose"] == "500 mg"
    assert stored[1]["frequency"] == "three times daily"
    assert stored[0]["days"] == 3
    types = event_types(visit_id)
    assert types.count("prescription.allergy_override") == 1
    assert types.count("consult.done") == 1


def test_acknowledging_with_no_conflict_logs_nothing(api, nurse, doctor):
    visit_id = at_doctor(nurse, api)
    doctor.ok(f"/api/counters/{D4}/call-next")
    doctor.ok(
        f"/api/visits/{visit_id}/consult/done",
        {"prescription": [{"drug_id": "DR-PARA"}], "acknowledge_allergy": True},
    )
    assert "prescription.allergy_override" not in event_types(visit_id)


@pytest.mark.parametrize("drug_id", ["amoxicillin", "Amoxil", "DR-NOPE", ""])
def test_a_typed_drug_is_refused(api, nurse, doctor, drug_id):
    visit_id = at_doctor(nurse, api)
    doctor.ok(f"/api/counters/{D4}/call-next")
    body = {"prescription": [{"drug_id": "DR-PARA"}, {"drug_id": drug_id}]}
    response = doctor.post(f"/api/visits/{visit_id}/consult/done", body)
    assert response.status_code == 422
    assert response.json()["error"] == "unknown_drug"
    assert rows("SELECT * FROM prescription_item WHERE visit_id = ?", visit_id) == []


def test_blank_lines_take_the_defaults_and_typed_ones_win(api, nurse, doctor):
    visit_id = at_doctor(nurse, api)
    doctor.ok(f"/api/counters/{D4}/call-next")
    doctor.ok(
        f"/api/visits/{visit_id}/consult/done",
        {
            "prescription": [
                {"drug_id": "DR-CETI", "dose": "  ", "frequency": ""},
                {"drug_id": "DR-AZIT", "dose": "250 mg", "notes": "after food"},
            ]
        },
    )
    stored = rows(
        "SELECT dose, frequency, days, notes FROM prescription_item WHERE visit_id = ? ORDER BY id",
        visit_id,
    )
    assert stored == [
        {"dose": "10 mg", "frequency": "once daily", "days": 5, "notes": None},
        {"dose": "250 mg", "frequency": "once daily", "days": 3, "notes": "after food"},
    ]


def test_an_empty_prescription_ends_the_visit_without_a_pharmacy_ticket(api, nurse, doctor):
    visit_id = at_doctor(nurse, api)
    doctor.ok(f"/api/counters/{D4}/call-next")
    body = doctor.ok(f"/api/visits/{visit_id}/consult/done", {"prescription": []})
    assert body["status"] == "completed"
    assert body["ticket"]["state"] == "done"
    assert rows(
        "SELECT * FROM ticket WHERE visit_id = ? AND counter_id = ?", visit_id, P1
    ) == []
    assert visit_row(visit_id)["completed_at"]
    assert "consult.done" in event_types(visit_id)


def test_consult_needs_the_patient_called(api, nurse, doctor):
    visit_id = at_doctor(nurse, api)
    response = doctor.post(
        f"/api/visits/{visit_id}/consult/done", {"prescription": [{"drug_id": "DR-PARA"}]}
    )
    assert response.status_code == 409
    assert response.json()["error"] == "invalid_transition"
    assert rows("SELECT * FROM prescription_item WHERE visit_id = ?", visit_id) == []
    assert "consult.done" not in event_types(visit_id)


def test_consult_only_at_the_doctor_stage(api, nurse, doctor):
    visit_id = arrived(api)
    response = doctor.post(f"/api/visits/{visit_id}/consult/done", {"prescription": []})
    assert response.status_code == 409
    assert response.json()["error"] == "visit_not_in_doctor"


# The pharmacy


def test_dispensing_completes_with_medicines_in_both_languages(api, nurse, doctor, pharmacist):
    visit_id = to_pharmacy(nurse, doctor, api)
    called = pharmacist.ok(f"/api/counters/{P1}/call-next")["called"]
    assert called["number"] == "P-031"
    body = pharmacist.ok(f"/api/visits/{visit_id}/dispensed")
    assert body["status"] == "completed"
    assert "paracetamol".capitalize() in body["medicines"]["en"][0]["line"]
    assert "باراسيتامول" in body["medicines"]["ar"][0]["line"]
    assert visit_row(visit_id)["status"] == "completed"
    assert "dispensed" in event_types(visit_id)
    seen = detail(pharmacist, visit_id)
    assert seen["prescription"][0]["drug"] == "DR-PARA"
    assert seen["medicines"]["ar"] == body["medicines"]["ar"]
    assert seen["ticket"] is None


def test_dispensing_needs_the_patient_called(api, nurse, doctor, pharmacist):
    visit_id = to_pharmacy(nurse, doctor, api)
    response = pharmacist.post(f"/api/visits/{visit_id}/dispensed")
    assert response.status_code == 409
    assert response.json()["error"] == "invalid_transition"
    assert visit_row(visit_id)["status"] == "in_pharmacy"
    assert "dispensed" not in event_types(visit_id)


def test_dispensing_only_at_the_pharmacy_stage(api, nurse, pharmacist):
    visit_id = at_doctor(nurse, api)
    response = pharmacist.post(f"/api/visits/{visit_id}/dispensed")
    assert response.status_code == 409
    assert response.json()["error"] == "visit_not_in_pharmacy"


# Only the staff route carries the backstop


def test_a_refill_visit_has_no_centre_so_no_staff_view(api, nurse):
    visit_id = new_visit("P002")
    assert chat(api, visit_id, AHMED_TEXT).refill
    response = nurse.get(f"/api/staff/visits/{visit_id}")
    assert response.status_code == 403
    assert response.json()["error"] == "wrong_centre"


def test_the_drug_route_refuses_a_patient(api, nurse):
    visit_id = at_doctor(nurse, api)
    response = api.get(
        f"/api/staff/visits/{visit_id}/drugs", headers=bearer(patient_token(api, FATIMA_QID))
    )
    assert response.status_code == 403


def test_a_read_changes_nothing(api, nurse, doctor):
    visit_id = at_doctor(nurse, api)
    before = table_dump("visit", "ticket", "event", "intake", "handoff", "vitals")
    detail(nurse, visit_id)
    doctor.get(f"/api/staff/visits/{visit_id}/drugs")
    doctor.get(f"/api/counters/{D4}/queue")
    assert table_dump("visit", "ticket", "event", "intake", "handoff", "vitals") == before


# Urgent reaches every visit of the patient


def _sibling_ticket(api, patient_id=FATIMA):
    """A second place in the queue, set up by the engine because reserve now refuses one."""
    engine = api.app.state.engine
    visit_id = new_visit(patient_id)
    engine.issue_active(visit_id, T1)
    return visit_id


def _live(patient_id):
    return rows(
        "SELECT ticket.* FROM ticket JOIN visit ON visit.id = ticket.visit_id "
        "WHERE visit.patient_id = ? "
        "AND ticket.state IN ('reserved', 'active', 'called', 'serving')",
        patient_id,
    )


def test_urgent_leaves_no_sibling_ticket_callable(api, nurse):
    visit_id = arrived(api)
    sibling = _sibling_ticket(api)
    assert nurse.ok(f"/api/counters/{T1}/call-next")["called"]["visit_id"] == visit_id

    body = nurse.ok(f"/api/visits/{visit_id}/vitals", {"urgency": "urgent"})

    assert set(body) == {"status", "stage", "escalated", "ticket"}
    assert body["status"] == "redirected_emergency"
    assert body["ticket"]["state"] == "released"
    assert _live(FATIMA) == []
    assert visit_row(sibling)["status"] == "redirected_emergency"
    assert nurse.ok(f"/api/counters/{T1}/call-next")["called"] is None


def test_urgent_leaves_a_dependents_ticket_alone(api, nurse):
    visit_id = arrived(api)
    child = _sibling_ticket(api, LAYLA)
    assert nurse.ok(f"/api/counters/{T1}/call-next")["called"]["visit_id"] == visit_id
    nurse.ok(f"/api/visits/{visit_id}/vitals", {"urgency": "urgent"})
    assert [row["visit_id"] for row in _live(LAYLA)] == [child]


def test_routine_vitals_touch_no_other_ticket(api, nurse):
    visit_id = arrived(api)
    sibling = _sibling_ticket(api)
    assert nurse.ok(f"/api/counters/{T1}/call-next")["called"]["visit_id"] == visit_id
    nurse.ok(f"/api/visits/{visit_id}/vitals", {"urgency": "routine"})
    assert sibling in {row["visit_id"] for row in _live(FATIMA)}
