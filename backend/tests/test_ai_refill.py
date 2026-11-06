from __future__ import annotations

import pytest

from backend.ai.refill import RefillMatch, detect

AHMED = ["amlodipine 5 mg once daily"]
RAVI = ["metformin 500 mg twice daily"]
FATIMA: list[str] = []


@pytest.mark.parametrize(
    "text",
    [
        "I need my usual blood pressure pills",
        "I need my usual blood pressure tablets.",
        "أبي حبوب الضغط المعتادة",
        "أحتاج دواء الضغط المعتاد",
        "دواء الضغط خلص",
        "refill my amlodipine",
        "I ran out of my BP meds",
        "I need more blood pressure medicine",
        "تجديد أملوديبين",
        "حبوب الضغط المعتادة",
        "دواء الضغط المعتاد لو سمحت",
        "can i have my usual blood pressure pills",
        "can i get my regular bp meds",
        "I want my usual amlodipine",
        "بدي حبوب الضغط المعتادة",
        "ممكن دواء الضغط المعتاد",
    ],
)
def test_ahmed_matches(text):
    match = detect(text, AHMED)
    assert match is not None
    assert match.medicine == "amlodipine 5 mg once daily"
    assert match.cue


def test_ravi_arabic_sugar_medicine_matches():
    match = detect("دواء السكر خلص", RAVI)
    assert match == RefillMatch("metformin 500 mg twice daily", "خلص")


def test_fatima_has_no_medicines_to_refill():
    assert detect("دواء السكر خلص", FATIMA) is None
    assert detect("I need my usual blood pressure pills", FATIMA) is None
    assert detect("I need a refill", FATIMA) is None


@pytest.mark.parametrize(
    "text",
    [
        "I need my usual diabetes pills",
        "my blood pressure is high",
        "I want a blood pressure check",
        "I don't need a refill",
        "I do not need a refill",
        "no refill please",
        "my usual blood pressure pills make me dizzy",
        "دواء الضغط ما خلص",
        "ما أبي تجديد",
        "my usual blood pressure pills gave me a rash",
        "side effect from my usual blood pressure pills",
        "حبوب الضغط المعتادة تعبتني",
        "حبوب الضغط المعتادة تسبب دوخة",
        "I took too many of my usual blood pressure pills",
        "بلعت حبوب الضغط المعتادة كلها",
        "My usual blood pressure tablets aren't working",
        "My usual blood pressure tablets aren’t working",
        "my usual blood pressure pills are not helping",
        "Can I double my usual blood pressure pills?",
        "I stopped my usual blood pressure pills",
        "حبوب الضغط المعتادة ما تنفع",
    ],
)
def test_ahmed_gets_no_match(text):
    assert detect(text, AHMED) is None


@pytest.mark.parametrize(
    "text",
    [
        "I take my usual blood pressure pills",
        "my regular hypertension prescription",
        "my usual blood pressure pills are expensive",
        "pills for blood pressure usual",
        "usual blood pressure pills",
        "حبوب الضغط المعتادة غالية",
        "أخذت حبوب الضغط المعتادة",
        "amlodipine is my usual blood pressure medicine",
    ],
)
def test_usual_without_a_request_word_is_no_intent(text):
    assert detect(text, AHMED) is None


@pytest.mark.parametrize(
    "text",
    [
        "I don't want my usual blood pressure pills",
        "I didn't get my usual blood pressure pills",
        "I can't get my usual blood pressure pills",
        "ما أبي حبوب الضغط المعتادة",
    ],
)
def test_a_negated_request_word_is_no_request(text):
    assert detect(text, AHMED) is None


@pytest.mark.parametrize(
    "cancel",
    [
        "too many", "too much", "overdose", "double", "extra", "stopped", "stop taking",
        "not working", "aren't working", "isn't working", "don't work", "doesn't work",
        "not helping", "wrong", "missed",
        "زيادة", "جرعة", "بلعت", "كلها", "وقفت", "ما تنفع", "ما ينفع", "ما يفيد", "غلط", "نسيت",
        "stop", "change", "switch", "ask", "know", "safe",
        "أوقف", "اوقف", "أغير", "اغير", "أبدل", "أسأل", "اسأل", "أعرف",
    ],
)
def test_every_cancel_phrase_stops_a_strong_refill(cancel):
    assert detect("refill my amlodipine", AHMED) is not None
    assert detect(f"refill my amlodipine {cancel}", AHMED) is None


@pytest.mark.parametrize(
    "text",
    [
        "I want to stop my usual blood pressure pills",
        "need to change my usual blood pressure pills",
        "can I switch my usual blood pressure pills",
        "I need to ask about my usual blood pressure pills",
        "I need to know if my usual blood pressure pills are safe",
        "are my usual blood pressure pills safe, I need them",
        "أبي أوقف حبوب الضغط المعتادة",
        "ابي اوقف حبوب الضغط المعتادة",
        "أبي أغير حبوب الضغط المعتادة",
        "أبي أبدل حبوب الضغط المعتادة",
        "أبي أسأل عن حبوب الضغط المعتادة",
        "أبي اسأل عن حبوب الضغط المعتادة",
        "أبي أعرف عن حبوب الضغط المعتادة",
    ],
)
def test_a_question_or_a_change_is_not_a_refill(text):
    assert detect(text, AHMED) is None


@pytest.mark.parametrize(
    "text",
    [
        "I need my usual blood pressure pills",
        "I need my usual blood pressure tablets.",
        "أبي حبوب الضغط المعتادة",
        "I ran out of my blood pressure pills",
    ],
)
def test_the_new_cancel_words_leave_a_plain_refill_alone(text):
    assert detect(text, AHMED).medicine == AHMED[0]


def test_intent_alone_is_not_enough():
    assert detect("my usual", AHMED) is None


def test_medicine_noun_without_a_class_or_name_is_not_enough():
    assert detect("I need my usual tablets", AHMED) is None


def test_class_word_without_a_medicine_noun_is_not_enough():
    assert detect("usual blood pressure", AHMED) is None


def test_drug_name_without_intent_is_not_enough():
    assert detect("I take amlodipine", AHMED) is None


@pytest.mark.parametrize(
    "text",
    ["refill", "I need a refill", "refill please", "تجديد", "تجديد الدواء", "refill my meds"],
)
def test_bare_refill_with_one_medicine(text):
    assert detect(text, AHMED).medicine == AHMED[0]


def test_bare_refill_with_two_medicines_is_ambiguous():
    assert detect("I need a refill", [*AHMED, *RAVI]) is None


@pytest.mark.parametrize(
    "text",
    [
        "refill my insulin",
        "I need a refill of my cholesterol pills",
        "refill my diabetes pills",
    ],
)
def test_bare_refill_rule_does_not_swallow_another_medicine(text):
    assert detect(text, AHMED) is None


def test_second_medicine_on_the_record_is_found():
    match = detect("I ran out of my diabetes tablets", [*AHMED, *RAVI])
    assert match.medicine == RAVI[0]


def test_drug_lookup_ignores_case_and_keeps_the_exact_entry():
    entry = "Amlodipine 5 MG once daily"
    assert detect("refill my AMLODIPINE", [entry]).medicine == entry


def test_drug_outside_the_class_map_matches_by_name():
    entry = "atorvastatin 20 mg nightly"
    assert detect("I ran out of atorvastatin", [entry]).medicine == entry


def test_arabic_entry_on_the_record_matches_class_words():
    entry = "أملوديبين 5 ملغ"
    assert detect("دواء الضغط خلص", [entry]).medicine == entry


def test_blank_entries_are_ignored():
    assert detect("I need a refill", ["", *AHMED]).medicine == AHMED[0]


def test_empty_text():
    assert detect("", AHMED) is None
