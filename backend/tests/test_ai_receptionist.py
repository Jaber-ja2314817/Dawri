from __future__ import annotations

import json

import pytest

from backend.ai import intake, simulated
from backend.ai.llm import Llm
from backend.ai.receptionist import rule_emergency, run_turn
from backend.tests.ai_fakes import FakeChatClient

FATIMA = {
    "age": 34, "sex": "F", "preferred_lang": "ar", "allergies": ["penicillin"],
    "chronic": [], "active_meds": [],
}
AHMED = {
    "age": 67, "sex": "M", "preferred_lang": "ar", "allergies": [],
    "chronic": ["hypertension"], "active_meds": ["amlodipine 5 mg once daily"],
}


def intake_dict(**changes):
    base = {
        "emergency": False,
        "language": "en",
        "chief_complaint": "fever and cough",
        "chief_complaint_patient_words": "the model's version of the words",
        "duration": "3 days",
        "severity_0_10": 6,
        "associated": ["cough"],
        "self_medication": [],
        "service": "gp",
        "service_confidence": 0.9,
        "summary_for_nurse": "34F, 3 days fever and cough, severity 6/10.",
        "refill_request": None,
        "questions_asked": 2,
    }
    return json.dumps({**base, **changes}, ensure_ascii=False)


def real(*replies):
    client = FakeChatClient(list(replies))
    return Llm(mode="real", model_id="test", client=client), client


SIM = Llm(mode="simulated", model_id="simulated")


def history_of(*questions):
    """An opening followed by these model questions, each answered."""
    history = [{"role": "assistant", "content": simulated.OPENING["en"], "slot": "complaint"}]
    for question in questions:
        history += [
            {"role": "user", "content": "I have a cough", "slot": None},
            {"role": "assistant", "content": question, "slot": None},
        ]
    return history


def types(result):
    return [event.type for event in result.events]


def payload(result, event_type):
    return next(e.payload for e in result.events if e.type == event_type)


def test_rule_hit_is_an_emergency_with_no_model_call():
    llm, client = real()
    result = run_turn(llm, "Chest pain going to my left arm.", [], FATIMA)
    assert result.emergency
    assert result.source == "rules"
    assert result.emergency_category == "chest_pain"
    assert result.intake is None
    assert client.calls == []
    assert "999" in result.reply
    hit = payload(result, "redflag.hit")
    assert hit["category"] == "chest_pain"
    assert hit["label"] == "chest pain"


def test_the_model_cannot_clear_a_rule_hit():
    llm, client = real(intake_dict(emergency=False))
    result = run_turn(llm, "I can't breathe", [], FATIMA)
    assert result.emergency
    assert client.calls == []


def test_self_harm_rule_sets_the_flag():
    llm, _ = real()
    result = run_turn(llm, "I want to end my life", [], FATIMA)
    assert result.emergency
    assert result.self_harm
    assert result.emergency_category == "self_harm"
    assert result.reply == simulated.emergency_reply("en", True)


def test_arabic_emergency_gets_an_arabic_reply():
    result = run_turn(SIM, "عندي ألم في الصدر ينتشر إلى ذراعي", [], FATIMA, lang="en")
    assert result.emergency
    assert result.language == "ar"
    assert result.reply == simulated.emergency_reply("ar", False)


def test_rules_run_before_refill():
    result = run_turn(SIM, "I need my usual blood pressure pills and I have chest pain", [], AHMED)
    assert result.emergency
    assert result.refill is None


def test_denied_labels_accumulate_and_do_not_stop_the_patient():
    result = run_turn(SIM, "no chest pain, I have a cough", [], FATIMA, denied=["choking"])
    assert not result.emergency
    assert result.denied == ["choking", "chest pain"]
    assert payload(result, "redflag.denied") == {"labels": ["chest pain"]}


def test_a_denial_beside_a_hit_is_kept():
    result = run_turn(SIM, "no chest pain, short of breath", [], FATIMA)
    assert result.emergency
    assert result.emergency_category == "breathing"
    assert result.denied == ["chest pain"]


def test_no_denied_event_without_a_denial():
    assert "redflag.denied" not in types(run_turn(SIM, "I have a cough", [], FATIMA))


def test_refill_needs_a_record_match_and_never_calls_the_model():
    llm, client = real()
    result = run_turn(llm, "I need my usual blood pressure pills", [], AHMED)
    assert result.refill == {"medicine": "amlodipine 5 mg once daily"}
    assert result.source == "rules"
    assert not result.done
    assert client.calls == []
    assert payload(result, "refill.detected") == {"medicine": "amlodipine 5 mg once daily"}
    assert "amlodipine 5 mg once daily" in result.reply


def test_refill_sentence_without_the_medicine_goes_on():
    result = run_turn(SIM, "I need my usual blood pressure pills", [], FATIMA)
    assert result.refill is None
    assert result.source == "simulated"


def test_a_side_effect_is_not_a_refill():
    result = run_turn(SIM, "my usual blood pressure pills make me dizzy", [], AHMED)
    assert result.refill is None


def test_simulated_mode_is_labelled_simulated():
    result = run_turn(SIM, "عندي حرارة وكحة من ثلاث أيام", [], FATIMA)
    assert result.source == "simulated"
    assert result.slot == "severity"
    assert result.reply == simulated.QUESTIONS["severity"]["ar"]
    assert payload(result, "ai.turn") == {"source": "simulated", "questions_asked": 2, "done": False}


def test_an_empty_history_means_the_opening_was_asked():
    llm, client = real("Since when?")
    run_turn(llm, "I have a cough", [], FATIMA)
    messages = client.calls[0]["messages"]
    assert [m["role"] for m in messages] == ["system", "assistant", "user"]
    assert messages[1]["content"] == simulated.OPENING["en"]
    assert messages[2]["content"] == "I have a cough"


def test_model_question_is_returned_and_labelled():
    llm, client = real("Since when?")
    result = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert result.source == "model"
    assert result.reply == "Since when?"
    assert result.slot is None
    assert len(client.calls) == 1
    assert "ai.fallback" not in types(result)
    assert client.calls[0]["max_tokens"] >= 700


def test_the_system_message_is_minimal_and_carries_the_denial():
    patient = {**FATIMA, "full_name_en": "Fatima Al-Demo", "qid_demo": "DEMO-10001"}
    llm, client = real("Since when?")
    run_turn(llm, "no chest pain, I have a cough", history_of(), patient)
    system = client.calls[0]["messages"][0]
    assert system["role"] == "system"
    assert "You are NOT a doctor or nurse." in system["content"]
    assert "Patient denied: chest pain" in system["content"]
    assert "penicillin" in system["content"]
    assert "Fatima" not in system["content"]
    assert "DEMO-10001" not in system["content"]


def test_valid_intake_gets_the_server_overrides():
    llm, _ = real(intake_dict(questions_asked=5, denied_red_flags=["made up"]))
    history = history_of("Since when?")
    result = run_turn(llm, "no chest pain", history, FATIMA, denied=["choking"])
    assert result.done
    assert result.source == "model"
    assert result.intake["emergency"] is False
    assert result.intake["questions_asked"] == 2
    assert result.intake["denied_red_flags"] == ["choking", "chest pain"]
    assert result.intake["chief_complaint_patient_words"] == "I have a cough"
    assert result.intake["summary_for_nurse"].endswith("Patient denied: choking, chest pain.")
    # The model wrote "fever and cough", and the patient only ever said cough.
    assert result.intake["chief_complaint"] == "fever and cough"
    assert "nurse: cough, 3 days, severity 6/10." in result.reply
    assert "fever" not in result.reply
    assert payload(result, "ai.intake_ready") == {"service": "gp", "source": "model"}
    assert intake.validate_intake(result.intake)


def test_a_denial_already_in_the_summary_is_not_doubled():
    summary = "34F, cough. Patient denied: chest pain."
    llm, _ = real(intake_dict(summary_for_nurse=summary))
    result = run_turn(llm, "ok", history_of("Since when?"), FATIMA, denied=["chest pain"])
    assert result.intake["summary_for_nurse"] == summary


def test_first_message_as_the_final_one_is_the_patient_words():
    llm, _ = real(intake_dict())
    result = run_turn(llm, "I have fever and cough for 3 days", history_of(), FATIMA)
    assert result.intake["chief_complaint_patient_words"] == "I have fever and cough for 3 days"


@pytest.mark.parametrize(
    "output",
    [
        '{"emergency": true}',
        intake_dict(emergency=True),
        '{"emergency": true, "language": "klingon"',
        '```json\n{"emergency": "true", broken',
    ],
)
def test_a_model_emergency_escalates_even_when_broken(output):
    llm, client = real(output)
    result = run_turn(llm, "I feel strange", history_of(), FATIMA)
    assert result.emergency
    assert result.source == "model"
    assert result.intake is None
    assert "999" in result.reply
    assert payload(result, "ai.emergency") == {"source": "model"}
    assert len(client.calls) == 1


def test_a_retry_that_says_emergency_escalates():
    llm, client = real('{"language": "en"}', '{"emergency": true}')
    result = run_turn(llm, "I feel strange", history_of(), FATIMA)
    assert result.emergency
    assert result.source == "model"
    assert len(client.calls) == 2


PROSE_AR = "هذه حالة طارئة، اتصل على 999 الآن."
PROSE_EN = "This is an emergency, please call an ambulance."


def assert_model_emergency(result, reply):
    assert result.emergency
    assert result.source == "model"
    assert result.reply == reply
    assert result.intake is None
    assert payload(result, "ai.emergency") == {"source": "model"}


@pytest.mark.parametrize(
    ("output", "said", "language"),
    [(PROSE_AR, "أحس إني تعبان جدا", "ar"), (PROSE_EN, "I feel very strange", "en")],
)
def test_prose_at_the_first_reply_escalates(output, said, language):
    llm, client = real(output)
    result = run_turn(llm, said, history_of(), FATIMA)
    assert_model_emergency(result, simulated.emergency_reply(language, False))
    assert len(client.calls) == 1


@pytest.mark.parametrize("output", [PROSE_AR, PROSE_EN])
def test_prose_at_the_retry_after_invalid_json_escalates(output):
    llm, client = real('{"language": "en"}', output)
    result = run_turn(llm, "I feel very strange", history_of(), FATIMA)
    assert_model_emergency(result, simulated.emergency_reply("en", False))
    assert len(client.calls) == 2


def test_prose_at_the_retry_after_the_question_cap_escalates():
    llm, client = real("One more question?", PROSE_EN)
    result = run_turn(llm, "I have a cough", history_of(*["Next?"] * 6), FATIMA)
    assert_model_emergency(result, simulated.emergency_reply("en", False))
    assert len(client.calls) == 2


def test_a_reply_saying_not_an_emergency_is_no_escalation_and_never_shown():
    llm, _ = real("This is not an emergency. How long have you had it?")
    result = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert not result.emergency
    assert result.source == "simulated"
    assert "not an emergency" not in result.reply
    assert payload(result, "ai.fallback")["reason"] == "bad_shape"


@pytest.mark.parametrize(
    "broken",
    ['{"emergency": false, broken', '{"emergency": false, "note": "call 999'],
)
def test_broken_json_saying_false_is_a_failed_parse(broken):
    llm, client = real(broken, broken)
    result = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert not result.emergency
    assert result.source == "simulated"
    assert payload(result, "ai.fallback")["reason"] == "invalid_json"
    assert len(client.calls) == 2


def test_rule_emergency_on_a_hit_builds_the_rule_turn():
    result = rule_emergency("no chest pain, I can't breathe", [], FATIMA, ["seizure"], "en")
    assert result.emergency
    assert result.source == "rules"
    assert result.emergency_category == "breathing"
    assert result.denied == ["seizure", "chest pain"]
    assert "redflag.hit" in types(result)


def test_rule_emergency_is_none_when_clear():
    assert rule_emergency("hello there", [], FATIMA) is None
    assert rule_emergency("no chest pain", [], FATIMA) is None


def test_invalid_json_retries_once_with_the_error():
    llm, client = real(intake_dict(service="nonsense"), intake_dict())
    result = run_turn(llm, "ok", history_of(), FATIMA)
    assert result.done
    assert result.source == "model"
    assert "ai.fallback" not in types(result)
    second = client.calls[1]["messages"]
    assert second[-2]["role"] == "assistant"
    assert second[-1]["role"] == "user"
    assert "service" in second[-1]["content"]
    assert second[-1]["content"].startswith("Invalid intake")


def test_two_invalid_jsons_fall_back():
    llm, client = real("{not json", "{still not json")
    result = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert result.source == "simulated"
    assert payload(result, "ai.fallback") == {
        "surface": "chat", "reason": "invalid_json", "mode": "real", "served_by": "simulated",
    }
    assert len(client.calls) == 2
    assert "{" not in result.reply


def test_a_timeout_on_the_retry_falls_back_as_invalid_json():
    llm, _ = real("{not json", TimeoutError("secret provider text"))
    result = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert payload(result, "ai.fallback")["reason"] == "invalid_json"
    assert "secret" not in str(result.events)


def test_a_plain_retry_is_still_invalid():
    llm, _ = real("{not json", "How are you?")
    result = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert payload(result, "ai.fallback")["reason"] == "invalid_json"
    assert result.reply != "How are you?"


def test_model_error_falls_back_with_no_retry():
    llm, client = real(TimeoutError("supersecret provider text"))
    result = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert result.source == "simulated"
    assert payload(result, "ai.fallback")["reason"] == "model_error"
    assert len(client.calls) == 1
    assert "supersecret" not in str(result.events)


def test_an_empty_model_reply_is_a_model_error():
    llm, _ = real(None)
    result = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert payload(result, "ai.fallback")["reason"] == "model_error"


@pytest.mark.parametrize(
    "banned",
    ["You have the flu", "Take paracetamol 500 mg", "Your number is T-014", "عندك انفلونزا"],
)
def test_banned_model_reply_never_reaches_the_patient(banned):
    llm, _ = real(banned)
    result = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert result.reply != banned
    assert banned not in str(result.to_api())
    assert result.source == "simulated"
    assert payload(result, "ai.fallback")["reason"] == "banned_output"


SEVEN_QUESTIONS = (
    "When did it start? How bad is it? Any fever? Any vomiting? "
    "Did you take anything? Any allergies? Anything else?"
)


def test_several_questions_in_one_reply_are_not_shown():
    llm, client = real(SEVEN_QUESTIONS, "Since when?")
    first = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert first.source == "simulated"
    assert "fever?" not in first.reply
    assert SEVEN_QUESTIONS not in str(first.to_api())
    assert payload(first, "ai.fallback")["reason"] == "multiple_questions"
    assert len(client.calls) == 1

    second = run_turn(llm, "two days", history_of("q2?"), FATIMA)
    assert second.source == "model"
    assert second.reply == "Since when?"
    assert len(client.calls) == 2


@pytest.mark.parametrize(
    "reply",
    ["منذ متى؟ وهل عندك حرارة؟", "Since when? ولا حرارة؟", "Since when？ Any fever？"],
)
def test_arabic_and_wide_question_marks_count(reply):
    llm, _ = real(reply)
    result = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert payload(result, "ai.fallback")["reason"] == "multiple_questions"


def test_one_question_mark_is_shown():
    llm, _ = real("Thanks. How long have you had it?")
    result = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert result.source == "model"
    assert "ai.fallback" not in types(result)


def test_a_banned_reply_with_two_questions_reports_the_ban():
    llm, _ = real("You have the flu. Since when? Any fever?")
    result = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert payload(result, "ai.fallback")["reason"] == "banned_output"


def test_a_recorded_dose_is_allowed_in_a_model_question():
    llm, _ = real("Are you still on amlodipine 5 mg once daily?")
    result = run_turn(llm, "I have a cough", history_of(), AHMED)
    assert result.source == "model"


def test_a_diagnosis_in_the_summary_is_invalid():
    llm, client = real(
        intake_dict(summary_for_nurse="34F, likely viral infection."), intake_dict()
    )
    result = run_turn(llm, "ok", history_of(), FATIMA)
    assert len(client.calls) == 2
    assert result.source == "model"
    assert "safety rule" in client.calls[1]["messages"][-1]["content"]
    assert "viral" not in client.calls[1]["messages"][-1]["content"]


def test_a_diagnosis_in_the_chief_complaint_is_invalid():
    bad = intake_dict(chief_complaint="pneumonia")
    llm, _ = real(bad, bad)
    result = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert result.source == "simulated"
    assert payload(result, "ai.fallback")["reason"] == "invalid_json"


@pytest.mark.parametrize(
    "bad",
    [
        {"duration": "3 days, likely influenza"},
        {"self_medication": ["paracetamol 1000 mg"]},
        {"patient_concerns": "you have pneumonia"},
        {"associated": ["influenza"]},
        {"associated": ["cough", "أنفلونزا"]},
        {"chief_complaint": "fever", "duration": "ثلاثة أيام، التهاب"},
    ],
)
def test_every_free_text_field_is_filtered(bad):
    output = intake_dict(**bad)
    llm, client = real(output, output)
    result = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert result.source == "simulated"
    assert payload(result, "ai.fallback")["reason"] == "invalid_json"
    assert len(client.calls) == 2
    assert "safety rule" in client.calls[1]["messages"][-1]["content"]
    for words in ("influenza", "pneumonia", "1000"):
        assert words not in client.calls[1]["messages"][-1]["content"]


def test_a_bad_field_can_be_fixed_by_the_retry():
    llm, client = real(intake_dict(duration="likely influenza"), intake_dict())
    result = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert result.source == "model"
    assert result.intake["duration"] == "3 days"
    assert len(client.calls) == 2


def test_the_patients_own_medicine_stays_valid():
    llm, client = real(
        intake_dict(
            self_medication=["paracetamol"],
            summary_for_nurse="34F, cough, took paracetamol.",
        )
    )
    result = run_turn(llm, "I have a cough and I took paracetamol", history_of(), FATIMA)
    assert result.done
    assert result.source == "model"
    assert result.intake["self_medication"] == ["paracetamol"]
    assert len(client.calls) == 1


def test_a_medicine_only_in_the_summary_is_still_refused():
    output = intake_dict(self_medication=[], summary_for_nurse="34F, cough, took paracetamol.")
    llm, _ = real(output, output)
    result = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert result.source == "simulated"


def test_a_dropped_refill_request_is_not_filtered():
    llm, client = real(
        intake_dict(service="refill", refill_request="you have pneumonia, more ibuprofen 400 mg")
    )
    result = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert result.source == "model"
    assert result.intake["service"] == "gp"
    assert result.intake["refill_request"] is None
    assert len(client.calls) == 1


def test_a_gp_intake_never_keeps_the_models_refill_text():
    llm, client = real(
        intake_dict(service="gp", refill_request="You have the flu, take paracetamol 500 mg")
    )
    result = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert result.done
    assert result.source == "model"
    assert result.intake["service"] == "gp"
    assert result.intake["refill_request"] is None
    assert "flu" not in str(result.to_api())
    assert len(client.calls) == 1


@pytest.mark.parametrize(
    "changes",
    [
        {"summary_for_nurse": "Patient has eczema."},
        {"summary_for_nurse": "34F has a bad cold"},
        {"summary_for_nurse": "Take rest and drink water."},
        {"chief_complaint": "eczema flare"},
    ],
    ids=["eczema", "bad-cold", "advice", "complaint"],
)
def test_a_banned_free_text_field_retries_then_falls_back(changes):
    llm, client = real(intake_dict(**changes), intake_dict(**changes))
    result = run_turn(llm, "I have a cough", history_of(), FATIMA)
    assert len(client.calls) == 2
    assert result.source == "simulated"
    assert not result.done
    assert result.intake is None
    assert payload(result, "ai.fallback")["reason"] == "invalid_json"
    banned = next(iter(changes.values()))
    assert banned not in str(result.to_api())
    assert banned not in result.reply


def test_a_condition_on_the_record_may_be_named_in_the_summary():
    llm, _ = real(intake_dict(summary_for_nurse="67M with hypertension, 3 days of cough."))
    result = run_turn(llm, "I have a cough", history_of(), AHMED)
    assert result.source == "model"


def test_a_seventh_question_gets_one_forced_retry_then_the_intake():
    history = history_of("q2?", "q3?", "q4?", "q5?", "q6?")
    assert simulated.question_count(history) == 6
    llm, client = real("One more thing?", intake_dict())
    result = run_turn(llm, "fine", history, FATIMA)
    assert result.done
    assert result.source == "model"
    assert result.intake["questions_asked"] == 6
    forced = client.calls[1]["messages"]
    assert "You have asked 6 questions. Output ONLY the intake JSON now." in forced[0]["content"]
    assert forced[-1]["content"] == "Output ONLY the intake JSON now."


@pytest.mark.parametrize(
    "second", ["And another?", "{broken", TimeoutError("boom")], ids=["plain", "json", "error"]
)
def test_the_question_cap_falls_back_to_an_intake(second):
    history = history_of("q2?", "q3?", "q4?", "q5?", "q6?")
    llm, client = real("One more thing?", second)
    result = run_turn(llm, "fine", history, FATIMA)
    assert len(client.calls) == 2
    assert result.source == "simulated"
    assert payload(result, "ai.fallback")["reason"] == "question_cap"
    assert result.done
    assert result.intake["questions_asked"] == 6


def test_a_model_refill_with_no_match_becomes_gp():
    llm, _ = real(intake_dict(service="refill", refill_request="something"))
    result = run_turn(llm, "I need my usual blood pressure pills", history_of(), FATIMA)
    assert result.done
    assert result.refill is None
    assert result.intake["service"] == "gp"
    assert result.intake["refill_request"] is None
    assert "refill.unmatched" in types(result)


def test_a_model_refill_naming_the_record_is_a_refill():
    llm, _ = real(intake_dict(service="refill", refill_request="amlodipine"))
    result = run_turn(llm, "can I get some more of that", history_of(), AHMED)
    assert result.refill == {"medicine": "amlodipine 5 mg once daily"}
    assert result.source == "model"
    assert not result.done
    assert result.intake is None


def test_a_model_refill_naming_the_arabic_drug_name_counts():
    llm, _ = real(intake_dict(service="refill", refill_request="أملوديبين"))
    result = run_turn(llm, "ابي شوي منه", history_of(), AHMED)
    assert result.refill == {"medicine": "amlodipine 5 mg once daily"}


def test_a_model_refill_stands_on_an_earlier_message():
    history = [
        {"role": "assistant", "content": simulated.OPENING["en"], "slot": "complaint"},
        {"role": "user", "content": "I need a refill of amlodipine", "slot": None},
        {"role": "assistant", "content": "Anything else?", "slot": None},
    ]
    llm, _ = real(intake_dict(service="refill"))
    result = run_turn(llm, "no", history, AHMED)
    assert result.refill == {"medicine": "amlodipine 5 mg once daily"}


def test_the_model_cannot_deflect_a_patient_with_a_symptom():
    llm, _ = real(intake_dict(service="refill", refill_request="amlodipine"))
    result = run_turn(llm, "my amlodipine makes me dizzy", history_of(), AHMED)
    assert result.refill is None
    assert result.intake["service"] == "gp"
    assert "refill.unmatched" in types(result)


@pytest.mark.parametrize(
    "said",
    [
        "I took too many of my usual blood pressure pills",
        "بلعت حبوب الضغط المعتادة كلها",
        "My usual blood pressure tablets aren't working",
        "my usual blood pressure pills are not helping",
        "Can I double my usual blood pressure pills?",
        "I stopped my usual blood pressure pills",
        "حبوب الضغط المعتادة ما تنفع",
    ],
)
def test_the_model_cannot_deflect_a_problem_with_a_medicine(said):
    llm, client = real(intake_dict(service="refill", refill_request="amlodipine"))
    result = run_turn(llm, said, history_of(), AHMED)
    assert len(client.calls) == 1  # The rules did not deflect it either.
    assert result.refill is None
    assert result.intake["service"] == "gp"
    assert result.intake["refill_request"] is None
    assert "refill.unmatched" in types(result)


def test_an_earlier_problem_still_stops_a_model_refill():
    history = [
        {"role": "assistant", "content": simulated.OPENING["en"], "slot": "complaint"},
        {"role": "user", "content": "I stopped my amlodipine", "slot": None},
        {"role": "assistant", "content": "Anything else?", "slot": None},
    ]
    llm, _ = real(intake_dict(service="refill", refill_request="amlodipine"))
    result = run_turn(llm, "no", history, AHMED)
    assert result.refill is None
    assert result.intake["service"] == "gp"


REFILL_AFTER_A_SYMPTOM = "I need a refill of my blood pressure tablets"


def test_an_earlier_symptom_stops_a_rule_refill_on_the_model_path():
    llm, client = real("How long have you had the cough?")
    result = run_turn(llm, REFILL_AFTER_A_SYMPTOM, history_of("Since when?"), AHMED)
    assert result.refill is None
    assert result.source == "model"
    assert len(client.calls) == 1
    assert "refill.detected" not in types(result)


def test_an_earlier_symptom_stops_a_rule_refill_in_simulated_mode():
    result = run_turn(SIM, REFILL_AFTER_A_SYMPTOM, history_of("Since when?"), AHMED)
    assert result.refill is None
    assert result.source == "simulated"
    assert "refill.detected" not in types(result)


def test_an_earlier_medicine_problem_stops_a_rule_refill():
    history = [
        {"role": "assistant", "content": simulated.OPENING["en"], "slot": "complaint"},
        {"role": "user", "content": "I want to stop my usual tablets", "slot": None},
        {"role": "assistant", "content": "Since when?", "slot": None},
    ]
    result = run_turn(SIM, REFILL_AFTER_A_SYMPTOM, history, AHMED)
    assert result.refill is None


def test_earlier_chat_with_no_problem_keeps_the_rule_refill():
    history = [
        {"role": "assistant", "content": simulated.OPENING["en"], "slot": "complaint"},
        {"role": "user", "content": "hello there", "slot": None},
        {"role": "assistant", "content": "How can I help?", "slot": None},
    ]
    llm, client = real()
    result = run_turn(llm, REFILL_AFTER_A_SYMPTOM, history, AHMED)
    assert result.refill == {"medicine": "amlodipine 5 mg once daily"}
    assert result.source == "rules"
    assert client.calls == []


def test_usual_alone_goes_to_the_model_rather_than_the_refill_line():
    llm, client = real("How long have you had them?")
    result = run_turn(llm, "I take my usual blood pressure pills", history_of(), AHMED)
    assert result.refill is None
    assert result.source == "model"
    assert len(client.calls) == 1


def test_fallback_serves_the_scripted_intake_when_slots_are_full():
    history = [
        {"role": "assistant", "content": simulated.OPENING["en"], "slot": "complaint"},
        {"role": "user", "content": "I have fever and cough for 3 days", "slot": None},
        {"role": "assistant", "content": "How bad, 0 to 10?", "slot": None},
        {"role": "user", "content": "6", "slot": None},
        {"role": "assistant", "content": "Did you take any medicine?", "slot": None},
        {"role": "user", "content": "panadol", "slot": None},
        {"role": "assistant", "content": "Anything else the nurse should know?", "slot": None},
    ]
    llm, _ = real(TimeoutError("down"))
    result = run_turn(llm, "no", history, FATIMA)
    assert result.done
    assert result.source == "simulated"
    assert result.intake["duration"] == "3 days"
    assert result.intake["severity_0_10"] == 6
    assert result.intake["self_medication"] == ["paracetamol"]
    assert payload(result, "ai.intake_ready") == {"service": "gp", "source": "simulated"}


def test_every_turn_logs_ai_turn():
    llm, _ = real("Since when?")
    for result in (
        run_turn(SIM, "I have a cough", [], FATIMA),
        run_turn(SIM, "I can't breathe", [], FATIMA),
        run_turn(SIM, "I need my usual blood pressure pills", [], AHMED),
        run_turn(llm, "I have a cough", [], FATIMA),
    ):
        assert "ai.turn" in types(result)


def test_events_hold_no_patient_sentence():
    sentence = "my very private sentence about a cough"
    outputs = (
        run_turn(SIM, sentence, [], FATIMA),
        run_turn(real(TimeoutError("x"))[0], sentence, [], FATIMA),
        run_turn(real("You have the flu")[0], sentence, [], FATIMA),
        run_turn(real(intake_dict())[0], sentence, [], FATIMA),
    )
    for result in outputs:
        assert "private" not in str(result.events)


def test_to_api_shape():
    data = run_turn(SIM, "I have a cough", [], FATIMA).to_api()
    assert set(data) == {
        "reply", "done", "emergency", "intake", "refill", "denied", "ai_source", "self_harm",
    }
    assert data["ai_source"] == "simulated"


def test_run_turn_does_not_touch_the_history_it_gets():
    history = history_of("Since when?")
    copy = [dict(message) for message in history]
    run_turn(SIM, "3 days", history, FATIMA)
    assert history == copy

