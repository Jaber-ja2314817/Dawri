from __future__ import annotations

import json
from datetime import date

import pytest

from backend import bootstrap, db
from backend.ai import handoff
from backend.ai.handoff import HandoffError, draft, draft_for_visit, template
from backend.ai.llm import Llm
from backend.ai.llm import build as build_llm
from backend.ai.runtime import AiRuntime
from backend.tests.ai_fakes import FakeChatClient
from backend.tests.conftest import make_visit

ON = date(2026, 11, 6)
FATIMA = {
    "qid_demo": "DEMO-10001",
    "full_name_en": "Fatima Al-Demo",
    "full_name_ar": "فاطمة التجريبية",
    "age": 34,
    "sex": "F",
    "preferred_lang": "ar",
    "allergies": ["penicillin"],
    "chronic": [],
    "active_meds": [],
}
AHMED = {
    **FATIMA,
    "qid_demo": "DEMO-10002",
    "full_name_en": "Ahmed Al-Demo",
    "age": 67,
    "sex": "M",
    "allergies": [],
    "chronic": ["hypertension"],
    "active_meds": ["amlodipine 5 mg once daily"],
}
INTAKE = {
    "language": "ar-gulf",
    "chief_complaint": "fever and cough",
    "chief_complaint_patient_words": "عندي حرارة وكحة من ثلاث أيام",
    "duration": "3 days",
    "severity_0_10": 6,
    "associated": ["fever"],
    "self_medication": ["paracetamol"],
    "service": "gp",
    "service_confidence": 0.86,
    "summary_for_nurse": "34F, 3 days fever and cough, severity 6/10.",
    "refill_request": None,
    "questions_asked": 5,
    "denied_red_flags": [],
    "patient_concerns": None,
}
DENIED = {**INTAKE, "denied_red_flags": ["chest pain"]}
VITALS = {
    "bp_sys": 120,
    "bp_dia": 80,
    "hr": 88,
    "temp_c": 38.2,
    "spo2": 98,
    "weight_kg": 62.0,
    "urgency": "routine",
}
GOOD = (
    "Fatima Al-Demo, 34F.\n"
    "Fever and cough for 3 days, severity 6/10.\n"
    "No chronic conditions. Allergy: penicillin. Took paracetamol.\n"
    "BP 120/80, HR 88, Temp 38.2 C, SpO2 98%, Weight 62 kg."
)
LINE_PREFIXES = ("Fatima Al-Demo", "Complaint:", "History:", "Vitals:", "Concerns:")
ORIGINAL_COMPLAINT = "fever and cough"
EDITED_COMPLAINT = "wheeze since this morning"


def simulated() -> Llm:
    return Llm(mode="simulated", model_id="simulated")


def real(*replies) -> tuple[Llm, FakeChatClient]:
    client = FakeChatClient(list(replies))
    return build_llm(client), client


def event_types(result):
    return [event.type for event in result.events]


def fallback_payload(result):
    return next(e.payload for e in result.events if e.type == "ai.fallback")


def add_intake(conn, visit_id, stored=INTAKE, edited=None):
    conn.execute(
        "INSERT INTO intake (visit_id, json, edited_json) VALUES (?, ?, ?)",
        (visit_id, db.dumps(stored), None if edited is None else db.dumps(edited)),
    )


def add_vitals(conn, visit_id):
    conn.execute(
        "INSERT INTO vitals (visit_id, bp_sys, bp_dia, hr, temp_c, spo2, weight_kg, urgency) "
        "VALUES (:visit_id, :bp_sys, :bp_dia, :hr, :temp_c, :spo2, :weight_kg, :urgency)",
        {"visit_id": visit_id, **VITALS},
    )


@pytest.fixture
def visit(seeded):
    visit_id = make_visit(seeded, "P001")
    seeded.execute(
        "UPDATE visit SET centre_id = 'C-WAKRA', service = 'gp', status = 'in_triage' "
        "WHERE id = ?",
        (visit_id,),
    )
    return visit_id


def runtime(llm: Llm) -> AiRuntime:
    return AiRuntime(llm=llm, asr=None)


# Template


def test_template_matches_the_agreed_example():
    assert template(DENIED, VITALS, FATIMA).splitlines() == [
        "Fatima Al-Demo, 34F.",
        "Complaint: fever and cough, 3 days, severity 6/10.",
        "History: none on record. Allergies: penicillin. Took: paracetamol.",
        "Vitals: BP 120/80, HR 88, Temp 38.2 C, SpO2 98%, Weight 62 kg. Urgency: routine.",
        "Concerns: none stated. Patient denied: chest pain.",
    ]


@pytest.mark.parametrize(
    "vitals",
    [
        VITALS,
        {**VITALS, "hr": None, "temp_c": None},
        {key: None for key in VITALS},
        {},
        None,
    ],
)
def test_template_keeps_order_and_length(vitals):
    lines = template(INTAKE, vitals, FATIMA).splitlines()
    assert handoff.MIN_LINES <= len(lines) <= handoff.MAX_LINES
    for line, prefix in zip(lines, LINE_PREFIXES, strict=True):
        assert line.startswith(prefix)


def test_a_missing_vital_says_not_recorded():
    line = template(INTAKE, {**VITALS, "hr": None, "bp_dia": None}, FATIMA).splitlines()[3]
    assert "HR not recorded" in line
    assert "BP 120/not recorded" in line
    assert "Temp 38.2 C" in line


def test_no_vitals_at_all_has_no_invented_value():
    assert template(INTAKE, None, FATIMA).splitlines()[3] == "Vitals: not recorded."
    blank = template(INTAKE, {key: None for key in VITALS}, FATIMA).splitlines()[3]
    assert not any(ch.isdigit() for ch in blank.replace("SpO2", ""))
    assert blank.count("not recorded") == 6


def test_a_sparse_intake_says_not_recorded_rather_than_guess():
    lines = template({"chief_complaint": "headache"}, None, FATIMA).splitlines()
    assert lines[1] == "Complaint: headache, duration not recorded, severity not recorded."
    assert lines[2].endswith("Took: none reported.")


def test_severity_zero_is_a_value():
    assert "severity 0/10" in template({**INTAKE, "severity_0_10": 0}, None, FATIMA)


def test_history_line_carries_chronic_conditions_and_active_meds():
    line = template(INTAKE, None, AHMED).splitlines()[2]
    assert line == (
        "History: hypertension. Active meds: amlodipine 5 mg once daily. "
        "Allergies: none on record. Took: paracetamol."
    )


def test_patient_concerns_reach_the_last_line():
    intake = {**INTAKE, "patient_concerns": "worried about the cough"}
    assert template(intake, None, FATIMA).splitlines()[4] == (
        "Concerns: worried about the cough."
    )


def test_a_newline_in_free_text_cannot_change_the_line_count():
    intake = {**INTAKE, "chief_complaint": "fever\nand\n\ncough", "patient_concerns": "a\nb"}
    assert len(template(intake, VITALS, FATIMA).splitlines()) == 5


def test_arabic_template_keeps_the_order_and_the_free_text():
    lines = template(DENIED, VITALS, FATIMA, lang="ar").splitlines()
    assert lines == [
        "فاطمة التجريبية، 34 سنة، أنثى.",
        "الشكوى: عندي حرارة وكحة من ثلاث أيام، 3 أيام، الشدة 6/10.",
        "السوابق: لا يوجد في السجل. الحساسية: البنسلين. تناول: paracetamol.",
        "العلامات الحيوية: الضغط 120/80، النبض 88، الحرارة 38.2 م، الأكسجين 98%، "
        "الوزن 62 كغ. درجة الاستعجال: روتيني.",
        "المخاوف: لم يذكر شيئاً. المريض نفى: ألم في الصدر.",
    ]


def test_arabic_template_with_no_vitals():
    assert template(INTAKE, None, FATIMA, "ar").splitlines()[3] == (
        "العلامات الحيوية: غير مسجل."
    )


# Draft, simulated


def test_simulated_draft_is_the_template_and_says_so():
    result = draft(simulated(), DENIED, VITALS, FATIMA)
    assert result.text == template(DENIED, VITALS, FATIMA)
    assert result.source == "simulated"
    assert [(e.type, e.payload) for e in result.events] == [
        ("handoff.drafted", {"source": "simulated"})
    ]


# Draft, real


def test_good_model_draft_is_used_and_labelled_model():
    llm, client = real(GOOD)
    result = draft(llm, INTAKE, VITALS, FATIMA)
    assert (result.text, result.source) == (GOOD, "model")
    assert [(e.type, e.payload) for e in result.events] == [
        ("handoff.drafted", {"source": "model"})
    ]
    assert len(client.calls) == 1


def test_model_gets_the_handoff_rules_and_a_minimal_record():
    llm, client = real(GOOD)
    draft(llm, DENIED, VITALS, FATIMA)
    system, user = client.calls[0]["messages"]
    assert (system["role"], user["role"]) == ("system", "user")
    for phrase in ("3-5 line", "English", "No differential diagnosis", "not recorded"):
        assert phrase in system["content"]

    payload = json.loads(user["content"])
    assert set(payload) == {"intake", "vitals", "record"}
    assert payload["intake"]["chief_complaint"] == "fever and cough"
    assert payload["intake"]["denied_red_flags"] == ["chest pain"]
    assert payload["vitals"]["bp_sys"] == 120
    assert payload["record"]["allergies"] == ["penicillin"]
    assert "DEMO-10001" not in user["content"]
    assert "qid" not in user["content"].lower()


@pytest.mark.parametrize("intake", [INTAKE, DENIED])
@pytest.mark.parametrize("patient", [FATIMA, AHMED])
def test_a_model_writing_in_the_template_format_passes_every_check(intake, patient):
    echoed = template(intake, VITALS, patient)
    llm, _ = real(echoed)
    result = draft(llm, intake, VITALS, patient)
    assert (result.text, result.source) == (echoed, "model")


def test_self_medication_on_the_intake_lets_a_draft_name_it():
    llm, client = real(GOOD)
    assert draft(llm, INTAKE, VITALS, FATIMA).source == "model"
    assert "paracetamol" in client.calls[0]["messages"][1]["content"]


def test_a_drug_the_patient_never_mentioned_is_rejected():
    llm, _ = real(GOOD)
    result = draft(llm, {**INTAKE, "self_medication": []}, VITALS, FATIMA)
    assert result.source == "simulated"
    assert fallback_payload(result)["reason"] == "banned_output"


def test_an_intake_with_no_self_medication_field_still_drafts():
    sparse = {key: value for key, value in INTAKE.items() if key != "self_medication"}
    llm, _ = real(template(sparse, VITALS, FATIMA))
    assert draft(llm, sparse, VITALS, FATIMA).source == "model"


def test_a_dose_on_self_medication_does_not_reach_a_draft():
    intake = {**INTAKE, "self_medication": ["paracetamol 500 mg"]}
    llm, _ = real(GOOD.replace("Took paracetamol", "Took paracetamol 500 mg"))
    result = draft(llm, intake, VITALS, FATIMA)
    assert fallback_payload(result)["reason"] == "banned_output"


def test_blank_lines_between_model_lines_do_not_count():
    llm, _ = real(GOOD.replace("\n", "\n\n"))
    result = draft(llm, INTAKE, VITALS, FATIMA)
    assert (result.text, result.source) == (GOOD, "model")


@pytest.mark.parametrize(
    "reply, reason",
    [
        (RuntimeError("provider said DEMO-10001"), "model_error"),
        (TimeoutError("timed out"), "model_error"),
        (None, "model_error"),
        ("Fatima, 34F.\nFever. Allergy: penicillin.", "line_count"),
        ("\n".join(["Allergy: penicillin."] * 7), "line_count"),
        (GOOD + "\nLikely viral infection", "banned_output"),
        (GOOD + "\nTake paracetamol 500 mg", "banned_output"),
        (GOOD + "\nTicket T-014", "banned_output"),
        (GOOD + "\nTreat with amoxicillin", "banned_output"),
        (GOOD + "\nGive paracetamol", "banned_output"),
        (GOOD + "\nConsider antibiotics", "banned_output"),
        (GOOD + "\nAssessment: viral URTI", "banned_output"),
        (GOOD + "\nViral illness", "banned_output"),
        (GOOD + "\nURTI", "banned_output"),
        (GOOD + "\nAssessment: bacterial", "banned_output"),
        (GOOD + "\nRule out sepsis", "banned_output"),
        (GOOD.replace("Allergy: penicillin. ", ""), "missing_allergy"),
        (GOOD.replace("Allergy: penicillin.", "No penicillin allergy."), "missing_allergy"),
        (GOOD.replace("Allergy: penicillin.", "Not allergic to penicillin."), "missing_allergy"),
    ],
)
def test_a_rejected_draft_falls_back_with_an_event_and_no_retry(reply, reason):
    llm, client = real(reply)
    result = draft(llm, INTAKE, VITALS, FATIMA)
    assert result.text == template(INTAKE, VITALS, FATIMA)
    assert result.source == "simulated"
    assert fallback_payload(result) == {
        "surface": "handoff",
        "reason": reason,
        "mode": "real",
        "served_by": "simulated",
    }
    assert event_types(result) == ["ai.fallback", "handoff.drafted"]
    assert result.events[-1].payload == {"source": "simulated"}
    assert len(client.calls) == 1


def test_fallback_event_holds_no_exception_text():
    llm, _ = real(RuntimeError("provider said DEMO-10001"))
    assert "DEMO-10001" not in str(draft(llm, INTAKE, VITALS, FATIMA).events)


def test_allergy_check_ignores_case():
    llm, _ = real(GOOD.replace("penicillin", "PENICILLIN"))
    assert draft(llm, INTAKE, VITALS, FATIMA).source == "model"


def test_every_allergy_must_appear():
    patient = {**FATIMA, "allergies": ["penicillin", "latex"]}
    llm, _ = real(GOOD)
    result = draft(llm, INTAKE, VITALS, patient)
    assert fallback_payload(result)["reason"] == "missing_allergy"


def test_recorded_condition_and_dose_are_allowed():
    reply = (
        "Ahmed Al-Demo, 67M.\n"
        "Fever and cough for 3 days.\n"
        "History: hypertension, on amlodipine 5 mg once daily. No allergies on record.\n"
        "BP 120/80."
    )
    llm, _ = real(reply)
    assert draft(llm, INTAKE, VITALS, AHMED).source == "model"


def test_a_condition_off_the_record_is_rejected():
    llm, _ = real(GOOD + "\nHistory of diabetes.")
    assert fallback_payload(draft(llm, INTAKE, VITALS, FATIMA))["reason"] == "banned_output"


def test_a_dose_outside_the_active_meds_is_rejected_and_allowed_meds_extends_the_list():
    reply = GOOD + "\nOn cetirizine 10 mg."
    llm, _ = real(reply)
    assert draft(llm, INTAKE, VITALS, FATIMA).source == "simulated"
    llm, _ = real(reply)
    allowed = ["cetirizine 10 mg once daily"]
    assert draft(llm, INTAKE, VITALS, FATIMA, allowed_meds=allowed).source == "model"


def test_patient_denied_wording_reaches_a_model_draft_that_left_it_out():
    llm, _ = real(GOOD)
    result = draft(llm, DENIED, VITALS, FATIMA)
    assert result.source == "model"
    lines = result.text.splitlines()
    assert len(lines) == 4
    assert lines[-1].endswith("Weight 62 kg. Patient denied: chest pain.")


def test_patient_denied_wording_is_not_doubled():
    reply = GOOD + "\nPatient denied: chest pain."
    llm, _ = real(reply)
    result = draft(llm, DENIED, VITALS, FATIMA)
    assert result.text == reply


def test_fallback_template_also_carries_patient_denied():
    llm, _ = real(RuntimeError("down"))
    assert "Patient denied: chest pain" in draft(llm, DENIED, VITALS, FATIMA).text


# draft_for_visit


def stored(conn, visit_id):
    return conn.execute("SELECT * FROM handoff WHERE visit_id = ?", (visit_id,)).fetchone()


def audit_rows(conn, visit_id):
    rows = conn.execute(
        "SELECT type, payload FROM event WHERE visit_id = ? ORDER BY id", (visit_id,)
    ).fetchall()
    return [(row["type"], json.loads(row["payload"])) for row in rows]


def test_draft_for_visit_stores_the_draft_and_leaves_the_nurse_fields_alone(seeded, visit):
    add_intake(seeded, visit)
    add_vitals(seeded, visit)
    result = draft_for_visit(seeded, runtime(simulated()), visit, on=ON)

    assert result["source"] == "simulated"
    assert result["text"].startswith("Fatima Al-Demo, 34F.")
    assert "BP 120/80" in result["text"]
    row = stored(seeded, visit)
    assert row["ai_draft"] == result["text"]
    assert row["final_text"] is None
    assert row["chosen_doctor_id"] is None
    assert row["confirmed_by"] is None
    assert audit_rows(seeded, visit) == [("handoff.drafted", {"source": "simulated"})]


def test_draft_for_visit_without_vitals_says_not_recorded(seeded, visit):
    add_intake(seeded, visit)
    result = draft_for_visit(seeded, runtime(simulated()), visit, on=ON)
    assert "Vitals: not recorded." in result["text"]


def test_redraft_updates_the_draft_and_keeps_what_the_nurse_decided(seeded, visit):
    add_intake(seeded, visit)
    draft_for_visit(seeded, runtime(simulated()), visit, on=ON)
    seeded.execute(
        "UPDATE handoff SET final_text = 'nurse text', chosen_doctor_id = 'S-WAK-DOC1', "
        "confirmed_by = 'S-WAK-NURSE1' WHERE visit_id = ?",
        (visit,),
    )
    add_vitals(seeded, visit)
    result = draft_for_visit(seeded, runtime(simulated()), visit, on=ON)

    row = stored(seeded, visit)
    assert row["ai_draft"] == result["text"]
    assert "BP 120/80" in row["ai_draft"]
    assert row["final_text"] == "nurse text"
    assert row["chosen_doctor_id"] == "S-WAK-DOC1"
    assert row["confirmed_by"] == "S-WAK-NURSE1"


def test_nurse_edit_reaches_the_simulated_draft(seeded, visit):
    edited = {**INTAKE, "chief_complaint": EDITED_COMPLAINT}
    add_intake(seeded, visit, edited=edited)
    text = draft_for_visit(seeded, runtime(simulated()), visit, on=ON)["text"]
    assert EDITED_COMPLAINT in text
    assert ORIGINAL_COMPLAINT not in text


def test_nurse_edit_reaches_the_model_and_the_original_does_not(seeded, visit):
    edited = {**INTAKE, "chief_complaint": EDITED_COMPLAINT}
    add_intake(seeded, visit, edited=edited)
    add_vitals(seeded, visit)
    llm, client = real(GOOD)
    result = draft_for_visit(seeded, runtime(llm), visit, on=ON)

    assert result["source"] == "model"
    user = client.calls[0]["messages"][1]["content"]
    assert EDITED_COMPLAINT in user
    assert ORIGINAL_COMPLAINT not in user
    assert INTAKE["chief_complaint_patient_words"] not in user


def test_model_fallback_is_audited(seeded, visit):
    add_intake(seeded, visit)
    llm, _ = real(RuntimeError("down"))
    result = draft_for_visit(seeded, runtime(llm), visit, on=ON)
    assert result["source"] == "simulated"
    assert audit_rows(seeded, visit) == [
        (
            "ai.fallback",
            {
                "surface": "handoff",
                "reason": "model_error",
                "mode": "real",
                "served_by": "simulated",
            },
        ),
        ("handoff.drafted", {"source": "simulated"}),
    ]


def test_model_draft_is_stored_with_a_model_label(seeded, visit):
    add_intake(seeded, visit)
    add_vitals(seeded, visit)
    llm, _ = real(GOOD)
    result = draft_for_visit(seeded, runtime(llm), visit, on=ON)
    assert stored(seeded, visit)["ai_draft"] == GOOD
    assert result["source"] == "model"
    assert audit_rows(seeded, visit) == [("handoff.drafted", {"source": "model"})]


def test_the_stored_qid_never_reaches_the_model(seeded, visit):
    add_intake(seeded, visit)
    add_vitals(seeded, visit)
    llm, client = real(GOOD)
    draft_for_visit(seeded, runtime(llm), visit, on=ON)
    assert "DEMO-10001" not in json.dumps(client.calls[0]["messages"], ensure_ascii=False)


class WritesDuringCall(FakeChatClient):
    """Stands in for another request hitting the database during the model call."""

    def __init__(self, conn, db_path, replies):
        super().__init__(replies)
        self.conn = conn
        self.db_path = db_path
        self.saw_transaction = None
        self.write_error = None

    def chat_completion(self, messages, **kw):
        self.saw_transaction = self.conn.in_transaction
        other = db.connect(self.db_path)
        try:
            other.execute("PRAGMA busy_timeout=0")
            other.execute("INSERT INTO event (visit_id, type) VALUES (NULL, 'probe')")
        except Exception as exc:  # noqa: BLE001 - recorded and asserted on below
            self.write_error = exc
        finally:
            other.close()
        return super().chat_completion(messages, **kw)


def test_no_transaction_is_open_during_the_model_call(seeded, visit, db_path):
    add_intake(seeded, visit)
    add_vitals(seeded, visit)
    client = WritesDuringCall(seeded, db_path, [GOOD])
    result = draft_for_visit(seeded, runtime(build_llm(client)), visit, on=ON)

    assert client.saw_transaction is False
    assert client.write_error is None
    assert result["source"] == "model"
    assert not seeded.in_transaction
    assert seeded.execute("SELECT COUNT(*) FROM event WHERE type = 'probe'").fetchone()[0] == 1


def test_no_intake_raises(seeded, visit):
    with pytest.raises(HandoffError) as caught:
        draft_for_visit(seeded, runtime(simulated()), visit, on=ON)
    assert caught.value.code == "no_intake"
    assert str(caught.value) == "no_intake"
    assert stored(seeded, visit) is None


def test_unknown_visit_raises_no_intake(seeded):
    with pytest.raises(HandoffError) as caught:
        draft_for_visit(seeded, runtime(simulated()), "V_missing", on=ON)
    assert caught.value.code == "no_intake"


def test_suggestions_come_from_the_rules_and_the_top_one_is_stored(seeded, visit):
    add_intake(seeded, visit)
    result = draft_for_visit(seeded, runtime(simulated()), visit, on=ON)
    ids = [s["doctor_id"] for s in result["suggestions"]]
    assert ids == ["S-WAK-DOC1", "S-WAK-DOC2"]
    top = result["suggestions"][0]
    assert top["counter_label"] == "Room 3"
    row = stored(seeded, visit)
    assert row["suggested_doctor_id"] == "S-WAK-DOC1"
    assert row["reason"] == top["reason_en"]


def test_gender_preference_is_passed_through(seeded, visit):
    add_intake(seeded, visit)
    result = draft_for_visit(seeded, runtime(simulated()), visit, on=ON, gender_pref="F")
    assert result["suggestions"][0]["doctor_id"] == "S-WAK-DOC2"


def test_a_visit_with_no_centre_has_no_suggestions(seeded):
    visit_id = make_visit(seeded, "P001")
    add_intake(seeded, visit_id)
    result = draft_for_visit(seeded, runtime(simulated()), visit_id, on=ON)
    assert result["suggestions"] == []
    row = stored(seeded, visit_id)
    assert row["ai_draft"] == result["text"]
    assert row["suggested_doctor_id"] is None
    assert row["reason"] is None


def test_on_the_demo_load_the_empty_room_is_suggested(conn):
    bootstrap.reset_demo(simulate_load=True)
    visit_id = make_visit(conn, "P001")
    conn.execute(
        "UPDATE visit SET centre_id = 'C-WAKRA', service = 'gp' WHERE id = ?", (visit_id,)
    )
    add_intake(conn, visit_id)
    result = draft_for_visit(conn, runtime(simulated()), visit_id, on=ON)
    assert [(s["doctor_id"], s["waiting"]) for s in result["suggestions"]] == [
        ("S-WAK-DOC2", 0),
        ("S-WAK-DOC1", 1),
    ]
    assert result["suggestions"][0]["counter_label"] == "Room 4"
    assert stored(conn, visit_id)["suggested_doctor_id"] == "S-WAK-DOC2"


def test_edited_service_wins_over_the_visit(seeded, visit):
    add_intake(seeded, visit, edited={**INTAKE, "service": "dental"})
    result = draft_for_visit(seeded, runtime(simulated()), visit, on=ON)
    assert [s["doctor_id"] for s in result["suggestions"]] == ["S-WAK-DEN1"]


def test_unedited_intake_service_does_not_beat_the_visit(seeded, visit):
    seeded.execute("UPDATE visit SET service = 'dental' WHERE id = ?", (visit,))
    add_intake(seeded, visit, stored={**INTAKE, "service": "gp"})
    result = draft_for_visit(seeded, runtime(simulated()), visit, on=ON)
    assert [s["doctor_id"] for s in result["suggestions"]] == ["S-WAK-DEN1"]


def test_a_visit_with_no_service_uses_the_intake(seeded, visit):
    seeded.execute("UPDATE visit SET service = NULL WHERE id = ?", (visit,))
    add_intake(seeded, visit, stored={**INTAKE, "service": "dental"})
    result = draft_for_visit(seeded, runtime(simulated()), visit, on=ON)
    assert [s["doctor_id"] for s in result["suggestions"]] == ["S-WAK-DEN1"]


def test_edited_service_with_no_clinic_gets_a_gp_fallback(seeded, visit):
    add_intake(seeded, visit, edited={**INTAKE, "service": "mental_health"})
    result = draft_for_visit(seeded, runtime(simulated()), visit, on=ON)
    assert result["suggestions"][0]["clinic"] == "gp"
    assert result["suggestions"][0]["clinic_fallback"] is True


def test_the_returned_dict_has_exactly_the_agreed_keys(seeded, visit):
    add_intake(seeded, visit)
    result = draft_for_visit(seeded, runtime(simulated()), visit, on=ON)
    assert set(result) == {"text", "source", "suggestions"}
    json.dumps(result)


def test_vitals_with_no_record_are_an_invented_number():
    recorded = "BP 120/80, HR 88, Temp 38.2 C, SpO2 98%, Weight 62 kg"
    llm, _ = real(GOOD.replace(recorded, "BP 150/90, SpO2 88%"))
    result = draft(llm, INTAKE, None, FATIMA)
    assert result.source == "simulated"
    assert result.text == template(INTAKE, None, FATIMA)
    assert "150" not in result.text
    assert fallback_payload(result)["reason"] == "invented_number"


def test_a_changed_reading_is_an_invented_number():
    recorded = {**VITALS, "temp_c": 38.5}
    llm, _ = real(GOOD.replace("Temp 38.2 C", "Temp 39.2 C"))
    result = draft(llm, INTAKE, recorded, FATIMA)
    assert result.source == "simulated"
    assert fallback_payload(result)["reason"] == "invented_number"
    assert "ai.fallback" in event_types(result)


@pytest.mark.parametrize(
    "line",
    [
        "Fever and cough for 5 days, severity 6/10.",  # duration
        "Fever and cough for 3 days, severity 7/10.",  # severity
        "Fever and cough for 3 days, severity 7 out of 10.",
        "Fever and cough for 3 days, severity 6/9.",  # a scale nobody asked for
        "Fever and cough for 3 days, severity 3/10.",  # a recorded number, not the severity
        "Fever and cough for 3 days, 10 episodes, severity 6/10.",  # a loose 10
    ],
)
def test_other_invented_numbers_are_caught(line):
    llm, _ = real(GOOD.replace("Fever and cough for 3 days, severity 6/10.", line))
    result = draft(llm, INTAKE, VITALS, FATIMA)
    assert fallback_payload(result)["reason"] == "invented_number"


def test_the_10_of_a_scale_needs_a_recorded_severity():
    no_severity = {**INTAKE, "severity_0_10": None}
    llm, _ = real(GOOD)
    result = draft(llm, no_severity, VITALS, FATIMA)
    assert fallback_payload(result)["reason"] == "invented_number"


@pytest.mark.parametrize(
    "line",
    [
        "Fever and cough for 3 days, severity 6/10.",
        "Fever and cough for 3 days, severity 6 / 10",
        "Fever and cough for 3 days, severity 6 out of 10.",
        "Fever and cough for ٣ days, severity ٦/١٠.",
    ],
)
def test_recorded_numbers_age_and_the_scale_stay_model(line):
    reply = GOOD.replace("Fever and cough for 3 days, severity 6/10.", line)
    llm, _ = real(reply)
    result = draft(llm, INTAKE, VITALS, FATIMA)
    assert (result.source, result.text) == ("model", reply)


def test_arabic_digits_and_decimal_mark_match_the_record():
    llm, _ = real(GOOD.replace("Temp 38.2 C", "Temp ٣٨٫٢ C").replace("HR 88", "HR ٨٨"))
    assert draft(llm, INTAKE, VITALS, FATIMA).source == "model"


def test_a_whole_number_matches_its_decimal_record():
    llm, _ = real(GOOD)  # Says 62 kg, and the record holds 62.0.
    assert draft(llm, INTAKE, VITALS, FATIMA).source == "model"


def test_numbers_in_record_text_count():
    reply = GOOD.replace("No chronic conditions.", "On amlodipine 5 mg once daily, hypertension.")
    patient = {**AHMED, "allergies": ["penicillin"]}
    llm, _ = real(reply.replace("Fatima Al-Demo, 34F", "Ahmed Al-Demo, 67M"))
    assert draft(llm, INTAKE, VITALS, patient).source == "model"


def test_field_names_are_not_numbers_the_model_may_use():
    # severity_0_10 and spo2 are keys. Neither may excuse a draft's 0, 10 or 2.
    for invented in ("Temp 0 C", "Temp 10 C", "Temp 2 C"):
        llm, _ = real(GOOD.replace("Temp 38.2 C", invented))
        result = draft(llm, INTAKE, VITALS, FATIMA)
        assert fallback_payload(result)["reason"] == "invented_number"


def test_line_numbers_are_not_invented_numbers():
    numbered = "\n".join(f"{i}. {line}" for i, line in enumerate(GOOD.split("\n"), start=1))
    llm, _ = real(numbered)
    assert draft(llm, INTAKE, VITALS, FATIMA).source == "model"


def test_a_line_number_out_of_place_is_a_number():
    llm, _ = real(GOOD.replace("Fever and cough", "7. Fever and cough"))
    result = draft(llm, INTAKE, VITALS, FATIMA)
    assert fallback_payload(result)["reason"] == "invented_number"


def test_an_invented_number_is_audited_and_not_stored(seeded, visit):
    add_intake(seeded, visit)
    llm, _ = real(GOOD)  # No vitals row, so every reading here is invented.
    result = draft_for_visit(seeded, runtime(llm), visit, on=ON)
    assert result["source"] == "simulated"
    assert "120/80" not in stored(seeded, visit)["ai_draft"]
    assert audit_rows(seeded, visit)[0][1]["reason"] == "invented_number"
