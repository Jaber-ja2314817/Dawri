from __future__ import annotations

import inspect

import pytest

from backend.ai import filters, intake, prompts, simulated
from backend.ai.simulated import OPENING, next_turn, question_count

FATIMA = {"age": 34, "sex": "F"}
AHMED = {"age": 67, "sex": "M"}
AHMED_MED = "amlodipine 5 mg once daily"


def assistant(content, slot=None):
    return {"role": "assistant", "content": content, "slot": slot}


def user(content):
    return {"role": "user", "content": content, "slot": None}


def play(answers, lang="ar", patient=FATIMA, denied=()):
    """Answer each question in turn, returning the history and the final turn."""
    history = [assistant(OPENING[lang], "complaint")]
    turn = None
    for answer in answers:
        history.append(user(answer))
        turn = next_turn(history, patient, list(denied), lang)
        lang = turn.language
        if turn.intake is not None:
            return history, turn
        history.append(assistant(turn.reply, turn.slot))
    return history, turn


def asked_slots(history):
    return [m["slot"] for m in history if m["role"] == "assistant"]


def test_fatima_arabic_run_is_the_three_question_demo():
    history, turn = play(["عندي حرارة وكحة من ثلاث أيام", "٦", "بنادول", "لا"])
    assert asked_slots(history) == ["complaint", "severity", "medicine", "other"]
    result = intake.validate_intake(turn.intake)
    assert result.questions_asked == 4
    assert result.language == "ar-gulf"
    assert result.chief_complaint == "fever and cough"
    assert result.chief_complaint_patient_words == "عندي حرارة وكحة من ثلاث أيام"
    assert result.duration == "3 days"
    assert result.severity_0_10 == 6
    assert result.associated == ["cough"]
    assert result.self_medication == ["paracetamol"]
    assert result.service == "gp"
    assert result.service_confidence == 0.85
    assert result.patient_concerns is None
    assert result.summary_for_nurse == (
        "34F, 3 days fever and cough, severity 6/10, took paracetamol."
    )


def test_english_run_switches_from_an_arabic_preference():
    history, turn = play(
        ["I have had a fever and cough for three days", "6/10", "no", "no thanks"], lang="ar"
    )
    assert turn.language == "en"
    assert turn.intake["language"] == "en"
    assert turn.intake["duration"] == "3 days"
    assert turn.intake["self_medication"] == []
    assert turn.reply.endswith("Is this right?")


def test_the_six_questions_in_vault_order():
    history, turn = play(["I have a cough", "from yesterday", "7", "no", "no", "my son is sick"], "en")
    assert [m["content"] for m in history if m["role"] == "assistant"] == [
        "What brings you in today?",
        "Since when?",
        "How bad is it from 0 to 10?",
        "Do you have a fever?",
        "Did you take any medicine for it?",
        "Anything else the nurse should know?",
    ]
    assert turn.intake["questions_asked"] == 6
    assert turn.intake["patient_concerns"] == "my son is sick"


def test_the_arabic_wording_comes_from_the_vault():
    history, _ = play(["عندي كحة", "من يومين", "٧", "لا", "لا", "لا"])
    assert [m["content"] for m in history if m["role"] == "assistant"] == [
        "شو اللي يتعبك اليوم؟",
        "من متى؟",
        "كم شدته من 0 إلى 10؟",
        "عندك حرارة؟",
        "أخذت أي دوا له؟",
        "في شي ثاني تبي الممرضة تعرفه؟",
    ]


@pytest.mark.parametrize(
    "complaint, expected",
    [
        ("I have a stomach pain for 2 days", "Any vomiting?"),
        ("I have pain for 2 days", "Where is the pain?"),
        ("I have a cough for 2 days", "Do you have a fever?"),
        ("عندي مغص من يومين", "في ترجيع؟"),
        ("عندي ألم من يومين", "وين الألم بالضبط؟"),
    ],
)
def test_follow_up_depends_on_the_complaint(complaint, expected):
    lang = "ar" if "عندي" in complaint else "en"
    history = [assistant(OPENING[lang], "complaint"), user(complaint)]
    first = next_turn(history, FATIMA, [], lang)
    assert first.slot == "severity"
    history += [assistant(first.reply, first.slot), user("5")]
    assert next_turn(history, FATIMA, [], lang).reply == expected


def test_a_yes_to_the_follow_up_adds_the_complaint():
    _, turn = play(["I have a cough since yesterday", "5", "yes", "no", "no"], "en")
    assert turn.intake["chief_complaint"] == "cough and fever"
    assert turn.intake["associated"] == ["fever"]


def test_a_no_to_the_follow_up_adds_nothing():
    _, turn = play(["I have a cough since yesterday", "5", "no", "no", "no"], "en")
    assert turn.intake["chief_complaint"] == "cough"


def test_the_pain_location_is_kept_in_the_complaint():
    _, turn = play(["I hurt", "for 2 days", "5", "in my side", "no", "no"], "en")
    assert turn.intake["chief_complaint"] == "I hurt, in my side"


@pytest.mark.parametrize(
    "text, expected",
    [
        ("6", 6), ("٦", 6), ("6/10", 6), ("six", 6), ("ستة", 6), ("سته", 6), ("0", 0),
        ("10", 10), ("7 out of 10", 7), ("7 من 10", 7), ("۸", 8),
        ("11", None), ("-1", None), ("12/10", None), ("6.5", None), ("لا", None),
        ("bad", None), ("", None),
    ],
)
def test_parse_severity(text, expected):
    assert simulated.parse_severity(text) == expected


def test_severity_inside_a_sentence_needs_the_tag():
    assert simulated.parse_severity("about a 6 I think") is None
    assert simulated.parse_severity("about a 6 I think", loose=True) == 6
    assert simulated.parse_severity("تقريبا ستة", loose=True) == 6


@pytest.mark.parametrize(
    "text, expected",
    [
        ("from three days", "3 days"),
        ("for 3 days", "3 days"),
        ("من ثلاث أيام", "3 days"),
        ("من ثلاثة أيام", "3 days"),
        ("٣ أيام", "3 days"),
        ("من يومين", "2 days"),
        ("من أمس", "since yesterday"),
        ("since yesterday", "since yesterday"),
        ("for a week", "1 week"),
        ("من اسبوع", "1 week"),
        ("من أسبوع", "1 week"),
        ("2 weeks", "2 weeks"),
        ("a month ago", "1 month"),
        ("اسبوعين", "2 weeks"),
        ("twice a day", None),
        ("3 tablets", None),
        ("a while", None),
        ("0 days", None),
    ],
)
def test_parse_duration(text, expected):
    assert simulated.parse_duration(text) == expected


def test_a_tagged_answer_reads_a_bare_unit():
    assert simulated.parse_duration("اسبوع", tagged=True) == "1 week"
    assert simulated.parse_duration("today", tagged=True) == "since today"
    assert simulated.parse_duration("اليوم", tagged=True) == "since today"


def test_duration_is_never_invented_from_a_bare_number():
    _, turn = play(["I have a rash", "3", "5", "no", "no", "no"], "en")
    assert turn.intake["duration"] is None
    assert turn.intake["severity_0_10"] == 5
    assert turn.intake["summary_for_nurse"] == "34F, rash, severity 5/10."


@pytest.mark.parametrize(
    "text, expected",
    [
        ("I have fever and cough", ["fever", "cough"]),
        ("cough and fever", ["cough", "fever"]),
        ("عندي سخونة وسعال", ["fever", "cough"]),
        ("صداع", ["headache"]),
        ("no fever, I have a cough", ["cough"]),
        ("ما عندي حرارة لكن عندي كحة", ["cough"]),
        ("sore throat and earache", ["sore throat", "ear pain"]),
        ("ما عندي شي", []),
    ],
)
def test_find_complaints(text, expected):
    assert simulated.find_complaints(text) == expected


@pytest.mark.parametrize(
    "text, expected",
    [
        ("paracetamol", ["paracetamol"]),
        ("بنادول", ["paracetamol"]),
        ("باراسيتامول", ["paracetamol"]),
        ("panadol 500 mg twice", ["paracetamol"]),
        ("ibuprofen", ["ibuprofen"]),
        ("بروفين", ["ibuprofen"]),
        ("no", []),
        ("لا", []),
        ("ما أخذت بنادول", []),
        ("I did not take panadol", []),
        ("I am allergic to ibuprofen", []),
    ],
)
def test_parse_medicines(text, expected):
    assert simulated.parse_medicines(text) == expected


@pytest.mark.parametrize(
    "text",
    [
        "I want amoxicillin",
        "she wants amoxicillin",
        "I would like ibuprofen",
        "I need ibuprofen",
        "can I get amoxicillin",
        "can I have amoxicillin",
        "can I take ibuprofen",
        "should I take panadol?",
        "should I panadol",
        "my friend said try ibuprofen",
        "ابي اموكسيسيلين",
        "أبغى بنادول",
        "أريد بنادول",
        "أحتاج بنادول",
        "هل ينفع بنادول",
        "I am allergic to ibuprofen",
        "didn't take panadol",
    ],
)
def test_a_drug_wanted_or_asked_about_is_not_a_drug_taken(text):
    assert simulated.parse_medicines(text) == []


@pytest.mark.parametrize("text", ["I took panadol", "أخذت بنادول", "panadol", "بنادول"])
def test_a_drug_taken_still_reads_as_taken(text):
    assert simulated.parse_medicines(text) == ["paracetamol"]


@pytest.mark.parametrize(
    ("wanted", "lang"), [("I want amoxicillin", "en"), ("ابي اموكسيسيلين", "ar")]
)
def test_a_wanted_drug_never_reaches_the_intake(wanted, lang):
    answers = (
        [wanted, "for 2 days", "5", "no", "no", "no"]
        if lang == "en"
        else [wanted, "من يومين", "٥", "لا", "لا", "لا"]
    )
    _, turn = play(answers, lang)
    assert turn.intake["self_medication"] == []
    assert "took" not in turn.reply
    assert "أخذت" not in turn.reply


def test_a_dose_never_reaches_the_intake():
    _, turn = play(["I have fever for 2 days", "5", "panadol 500 mg", "no"], "en")
    assert turn.intake["self_medication"] == ["paracetamol"]
    assert "500" not in str(turn.intake)


def test_medicine_named_early_skips_the_question():
    history, _ = play(["I have a fever for 2 days and took panadol", "5", "no"], "en")
    assert "medicine" not in asked_slots(history)


@pytest.mark.parametrize("answer", ["no", "لا", "ما أخذت", "I didn't take anything"])
def test_a_no_medicine_answer_gives_an_empty_list(answer):
    _, turn = play(["I have a fever for 2 days", "5", answer, "no"], "en")
    assert turn.intake["self_medication"] == []


@pytest.mark.parametrize(
    "text, service, confidence",
    [
        ("I have a fever", "gp", 0.85),
        ("I feel strange", "gp", 0.6),
        ("my tooth hurts", "dental", 0.85),
        ("عندي ألم في الضرس", "dental", 0.85),
        ("ضرسي يوجعني", "dental", 0.85),
        ("I need a vaccine", "vaccination", 0.85),
        ("أبي تطعيم", "vaccination", 0.85),
        ("I need a blood test", "lab_only", 0.85),
        ("أبي تحليل", "lab_only", 0.85),
        ("I am pregnant", "womens_health", 0.85),
        ("الدورة متأخرة", "womens_health", 0.85),
        ("I have anxiety", "mental_health", 0.85),
        ("عندي قلق", "mental_health", 0.85),
        ("I need a sick note", "other", 0.85),
        ("أبي شهادة", "other", 0.85),
    ],
)
def test_service_keywords(text, service, confidence):
    _, turn = play([text, "for 2 days", "5", "no", "no", "no"], "en")
    assert turn.intake["service"] == service
    assert turn.intake["service_confidence"] == confidence


@pytest.mark.parametrize(
    "first, expected",
    [
        ("عندي صداع", "ar-gulf"),
        ("ابغى اشوف دكتور", "ar-gulf"),
        ("صداع وايد", "ar-gulf"),
        ("أشعر بصداع شديد", "ar-msa"),
        ("I have a headache", "en"),
    ],
)
def test_intake_language(first, expected):
    lang = "en" if expected == "en" else "ar"
    no, none = ("no", "no") if lang == "en" else ("لا", "لا")
    _, turn = play([first, "5 days" if lang == "en" else "٥ أيام", "5", no, no, none], lang)
    assert turn.intake["language"] == expected


@pytest.mark.parametrize(
    "text, current, expected",
    [
        ("عندي حرارة", "en", "ar"),
        ("I have a fever", "ar", "en"),
        ("6", "ar", "ar"),
        ("6", "en", "en"),
        ("لا", "en", "en"),
        ("paracetamol", "ar", "ar"),
        ("6 / 10", "en", "en"),
        ("٦ / ١٠", "ar", "ar"),
    ],
)
def test_detect_lang(text, current, expected):
    assert simulated.detect_lang(text, current) == expected


def test_summary_form_omits_missing_parts():
    _, turn = play(["I have a rash", "dunno", "dunno", "dunno", "no", "no"], "en")
    assert turn.intake["duration"] is None
    assert turn.intake["severity_0_10"] is None
    assert turn.intake["summary_for_nurse"] == "34F, rash."


def test_denied_labels_reach_the_intake_and_summary():
    _, turn = play(
        ["I have fever and cough for 3 days", "5", "no", "no"], "en", denied=["chest pain"]
    )
    assert turn.intake["denied_red_flags"] == ["chest pain"]
    assert turn.intake["summary_for_nurse"].endswith(" Patient denied: chest pain.")


def test_a_long_complaint_never_loses_the_denial():
    words = "strange feeling " * 40
    _, turn = play([words, "for 2 days", "5", "no", "no", "no"], "en", denied=["chest pain"])
    summary = turn.intake["summary_for_nurse"]
    assert len(summary) <= 400
    assert summary.endswith("Patient denied: chest pain.")


def test_the_first_message_is_kept_verbatim_up_to_the_schema_limit():
    long_text = "x" * 1500
    _, turn = play([long_text, "for 2 days", "5", "no", "no", "no"], "en")
    assert turn.intake["chief_complaint_patient_words"] == "x" * 1000
    assert len(turn.intake["chief_complaint"]) == 200


def test_an_unparseable_severity_is_asked_once_more_then_left_empty():
    history, turn = play(
        ["I have fever for 2 days", "dunno", "dunno", "no", "no", "no"], "en"
    )
    assert asked_slots(history).count("severity") == 2
    assert turn.intake["severity_0_10"] is None


def test_a_second_severity_answer_is_used():
    _, turn = play(["I have fever for 2 days", "dunno", "4", "no", "no", "no"], "en")
    assert turn.intake["severity_0_10"] == 4


def test_never_a_seventh_question():
    history, turn = play(
        ["I feel strange", "dunno", "dunno", "dunno", "dunno", "dunno", "dunno"], "en"
    )
    assert question_count(history) == 6
    assert turn.intake["questions_asked"] == 6


def test_budget_runs_out_before_slots_do():
    history = [assistant(OPENING["en"], "complaint")]
    for number in range(5):
        history += [user("I feel strange"), assistant(f"Model question {number}?")]
    history.append(user("still strange"))
    turn = next_turn(history, FATIMA, [], "en")
    assert turn.intake is not None
    assert turn.intake["questions_asked"] == 6


def test_takeover_reads_model_questions_without_tags():
    history = [
        assistant(OPENING["en"], "complaint"),
        user("I have a cough"),
        assistant("How long have you had it?"),
        user("3 days"),
        assistant("How bad is it, 0 to 10?"),
        user("6"),
        assistant("Do you have a fever?"),
        user("no"),
    ]
    turn = next_turn(history, FATIMA, [], "en")
    assert turn.slot == "medicine"


def test_takeover_understands_a_bare_no_to_a_model_medicine_question():
    history = [
        assistant(OPENING["ar"], "complaint"),
        user("عندي كحة من يومين"),
        assistant("كم شدته؟"),
        user("٦"),
        assistant("عندك حرارة؟"),
        user("لا"),
        assistant("هل أخذت أي دوا؟"),
        user("لا"),
    ]
    turn = next_turn(history, FATIMA, [], "ar")
    assert turn.slot == "other"
    assert turn.reply == "في شي ثاني تبي الممرضة تعرفه؟"


def test_a_bare_number_after_a_duration_question_is_not_severity():
    history = [
        assistant(OPENING["en"], "complaint"),
        user("I have a cough"),
        assistant("Since when?", "duration"),
        user("3"),
    ]
    turn = next_turn(history, FATIMA, [], "en")
    assert turn.slot == "severity"


def test_a_number_in_the_first_message_is_not_severity():
    history = [assistant(OPENING["en"], "complaint"), user("6")]
    assert next_turn(history, FATIMA, [], "en").slot == "duration"


def test_next_turn_is_pure():
    history = [assistant(OPENING["ar"], "complaint"), user("عندي حرارة وكحة من ثلاث أيام")]
    frozen = [dict(message) for message in history]
    first = next_turn(history, FATIMA, [], "ar")
    second = next_turn(history, FATIMA, [], "ar")
    assert first == second
    assert history == frozen


def test_no_user_message_gives_the_opening():
    assert next_turn([], FATIMA, [], "ar").reply == OPENING["ar"]
    assert next_turn([], FATIMA, [], "en").slot == "complaint"


def test_correcting_after_the_summary_rebuilds_the_intake():
    history, turn = play(["I have a rash for 2 days", "5", "no", "no", "no"], "en")
    history += [assistant(turn.reply, simulated.NOT_A_QUESTION), user("8")]
    corrected = next_turn(history, FATIMA, [], "en")
    assert corrected.intake["severity_0_10"] == 8
    assert corrected.intake["questions_asked"] == turn.intake["questions_asked"]


def corrected_at_summary(answers, lang, correction):
    history, turn = play(answers, lang)
    history += [assistant(turn.reply, simulated.NOT_A_QUESTION), user(correction)]
    return turn, next_turn(history, FATIMA, [], turn.language)


ENGLISH_RUN = ["I have a rash for 2 days", "5", "no", "no", "no"]
ARABIC_RUN = ["عندي كحة من يومين", "٥", "لا", "لا", "لا"]


@pytest.mark.parametrize(
    "words",
    [
        "actually it is 8",
        "actually it's eight",
        "it is 8",
        "it's an 8",
        "no, 8",
        "no it was more like 8",
        "my pain is 8",
        "sorry, I meant 8",
        "make it 8",
        "change it to 8",
        "8, not 5",
        "not 5, 8",
    ],
)
def test_a_severity_correction_in_a_sentence_changes_the_read_back(words):
    first, corrected = corrected_at_summary(ENGLISH_RUN, "en", words)
    assert "severity 5/10" in first.reply
    assert corrected.intake["severity_0_10"] == 8
    assert "severity 8/10" in corrected.reply
    assert "severity 8/10" in corrected.intake["summary_for_nurse"]
    assert corrected.intake["duration"] == first.intake["duration"]
    assert corrected.intake["questions_asked"] == first.intake["questions_asked"]


@pytest.mark.parametrize(
    "words",
    [
        "لا، ثمانية",
        "لا ثمانية",
        "لا، ٨",
        "لأ 8",
        "قصدي ثمانية",
        "الشدة ثمانية",
        "لا هي ثمانية",
        "خلها ثمانية",
        "ثمانية مو خمسة",
    ],
)
def test_an_arabic_severity_correction_changes_the_read_back(words):
    first, corrected = corrected_at_summary(ARABIC_RUN, "ar", words)
    assert "الشدة 5 من 10" in first.reply
    assert corrected.intake["severity_0_10"] == 8
    assert "الشدة 8 من 10" in corrected.reply
    assert corrected.intake["duration"] == first.intake["duration"]


@pytest.mark.parametrize(
    "words",
    [
        "I took 2 tablets",
        "I had 2 panadol",
        "it is not 8",
        "not 8",
        "no",
        "yes that is right",
        "actually it is 12",
        "it is 7.5",
        "between 7 and 8",
        "actually it is 8 or 9",
        "there are 3 of us",
    ],
)
def test_a_sentence_that_is_no_correction_leaves_the_severity_alone(words):
    _, corrected = corrected_at_summary(ENGLISH_RUN, "en", words)
    assert corrected.intake["severity_0_10"] == 5


@pytest.mark.parametrize("words", ["أخذت 2 حبة", "مو ثمانية", "لا، مو ثمانية", "عندي 3 عيال"])
def test_an_arabic_sentence_that_is_no_correction_leaves_the_severity_alone(words):
    _, corrected = corrected_at_summary(ARABIC_RUN, "ar", words)
    assert corrected.intake["severity_0_10"] == 5


def test_a_number_mid_chat_is_not_taken_for_a_correction():
    history, turn = play(["I have a rash", "2 days"], "en")
    assert turn.slot == "severity"
    history += [assistant(turn.reply, turn.slot), user("5")]
    turn = next_turn(history, FATIMA, [], "en")
    history += [assistant(turn.reply, turn.slot), user("actually it is 8")]
    assert simulated._read(history).severity == 5


def test_a_duration_correction_is_not_read_as_a_severity():
    first, corrected = corrected_at_summary(ENGLISH_RUN, "en", "actually it is 8 days")
    assert corrected.intake["duration"] == "8 days"
    assert corrected.intake["severity_0_10"] == first.intake["severity_0_10"]


@pytest.mark.parametrize(
    "history, expected",
    [
        ([], 1),
        ([user("hi")], 1),
        ([assistant("q1", "complaint")], 1),
        ([assistant("q1"), user("a"), assistant("q2")], 2),
        ([user("a"), assistant("q2")], 2),
        ([assistant("q1"), user("a"), assistant("done", simulated.NOT_A_QUESTION)], 1),
    ],
)
def test_question_count(history, expected):
    assert question_count(history) == expected


def every_script_string():
    for lang in ("en", "ar"):
        yield OPENING[lang]
        yield from (wording[lang] for wording in simulated.QUESTIONS.values())
        yield from (wording[lang] for wording in simulated.FOLLOW_UPS.values())
        yield simulated.emergency_reply(lang, False)
        yield simulated.emergency_reply(lang, True)
        yield simulated.refill_reply("the usual medicine", lang)


@pytest.mark.parametrize("line", list(every_script_string()))
def test_every_script_string_passes_the_banned_filter(line):
    assert filters.check_reply(line).ok
    assert "place held" not in line.lower()


@pytest.mark.parametrize("lang", ["en", "ar"])
def test_refill_reply_names_the_recorded_medicine_and_passes_with_it_allowed(lang):
    reply = simulated.refill_reply(AHMED_MED, lang)
    assert AHMED_MED in reply
    assert filters.check_reply(reply, allowed_meds=[AHMED_MED]).ok


@pytest.mark.parametrize("lang", ["en", "ar"])
def test_summary_replies_pass_the_read_back_filter(lang):
    _, turn = play(["عندي حرارة وكحة من ثلاث أيام", "٦", "بنادول", "لا"], denied=["chest pain"])
    reply = simulated.summary_reply(turn.intake, lang)
    check = filters.check_reply(
        reply, allowed_meds=turn.intake["self_medication"], read_back=True
    )
    assert check.ok
    assert reply != simulated._SUMMARY_PLAIN[lang]


def test_arabic_summary_is_in_arabic():
    _, turn = play(["عندي حرارة وكحة من ثلاث أيام", "٦", "بنادول", "لا"], denied=["chest pain"])
    reply = simulated.summary_reply(turn.intake, "ar")
    assert "حرارة وكحة" in reply
    assert "3 أيام" in reply
    assert "باراسيتامول" in reply
    assert "المريض نفى: ألم في الصدر" in reply
    assert "severity" not in reply


def test_fatima_hears_her_complaint_and_medicine_back_in_arabic():
    _, turn = play(["عندي حرارة وكحة من ثلاث أيام", "٦", "بنادول", "لا"])
    assert turn.intake["self_medication"] == ["paracetamol"]
    assert "حرارة وكحة" in turn.reply
    assert "أخذت باراسيتامول" in turn.reply
    assert "paracetamol" not in turn.reply
    assert turn.reply.endswith(simulated._SUMMARY_CHECK["ar"])


def test_an_english_patient_hears_the_complaint_and_medicine_back():
    _, turn = play(["I have a fever and cough for three days", "6", "paracetamol", "no"], "en")
    assert turn.intake["self_medication"] == ["paracetamol"]
    assert "fever" in turn.reply
    assert "took paracetamol" in turn.reply
    assert turn.reply.endswith(simulated._SUMMARY_CHECK["en"])


def test_two_medicines_are_both_read_back():
    _, turn = play(["I have a fever for 2 days", "5", "panadol and brufen", "no"], "en")
    assert turn.intake["self_medication"] == ["paracetamol", "ibuprofen"]
    assert "took paracetamol and ibuprofen" in turn.reply


@pytest.mark.parametrize("drug", list(filters.DRUG_NAMES))
@pytest.mark.parametrize("lang", ["en", "ar"])
def test_every_listed_medicine_can_be_read_back(lang, drug):
    _, turn = play(["I have a rash for 2 days", "5", "no", "no", "no"], "en")
    took = {
        **turn.intake,
        "self_medication": [drug],
        "summary_for_nurse": f"34F, 2 days rash, severity 5/10, took {drug}.",
    }
    assert simulated.summary_reply(took, lang) != simulated._SUMMARY_PLAIN[lang]


@pytest.mark.parametrize("lang", ["en", "ar"])
def test_only_the_medicines_the_patient_took_are_allowed(lang):
    """The same words read back or not, depending only on self_medication."""
    _, turn = play(["I tried brufen last night", "for 2 days", "5", "panadol", "no", "no"], "en")
    assert turn.intake["self_medication"] == ["ibuprofen", "paracetamol"]
    plain = simulated._SUMMARY_PLAIN[lang]
    assert simulated.summary_reply(turn.intake, lang) != plain
    unlisted = {**turn.intake, "self_medication": ["paracetamol"]}
    assert simulated.summary_reply(unlisted, lang) == plain


@pytest.mark.parametrize(
    "answers, lang",
    [
        (["I am allergic to ibuprofen", "for 2 days", "5", "panadol", "no", "no"], "en"),
        (["حساسية من بروفين", "من يومين", "٥", "بنادول", "لا", "لا"], "ar"),
    ],
)
def test_a_drug_the_patient_did_not_take_gives_the_plain_line(answers, lang):
    _, turn = play(answers, lang)
    assert turn.language == lang
    assert turn.intake["self_medication"] == ["paracetamol"]
    assert turn.reply == simulated._SUMMARY_PLAIN[lang]


@pytest.mark.parametrize(
    "prose",
    ["34F, 2 days rash, took ibuprofen.", "You have the flu.", "zorblax twice daily."],
)
@pytest.mark.parametrize("lang", ["en", "ar"])
def test_the_nurse_summary_is_never_read_back(lang, prose):
    """Only the fields the server rendered reach the patient, whatever this one says."""
    _, turn = play(["I have a rash for 2 days", "5", "panadol", "no", "no"], "en")
    assert turn.intake["self_medication"] == ["paracetamol"]
    swapped = {**turn.intake, "summary_for_nurse": prose}
    reply = simulated.summary_reply(swapped, lang)
    assert reply == simulated.summary_reply(turn.intake, lang)
    assert reply != simulated._SUMMARY_PLAIN[lang]
    for word in ("ibuprofen", "flu", "zorblax", "34F"):
        assert word not in reply


@pytest.mark.parametrize(
    ("duration", "expected"),
    [
        ("3 days", "3 days"),
        ("three days", "3 days"),
        ("since yesterday", "since yesterday"),
        ("a zorblax flare", None),
        ("twice daily", None),
        (None, None),
    ],
)
def test_only_a_valid_duration_is_read_back(duration, expected):
    _, turn = play(["I have a rash for 2 days", "5", "no", "no", "no"], "en")
    reply = simulated.summary_reply({**turn.intake, "duration": duration}, "en")
    summary = reply.removeprefix(simulated._SUMMARY_INTRO["en"])
    assert summary.strip().startswith("rash")
    if expected:
        assert f"rash, {expected}, severity 5/10." in summary
    else:
        assert "rash, severity 5/10." in summary
    assert "zorblax" not in reply
    assert "twice" not in reply


@pytest.mark.parametrize("lang", ["en", "ar"])
def test_a_complaint_outside_our_words_reads_back_the_patients_own_words(lang):
    _, turn = play(["my knee feels odd for 2 days", "5", "no", "no", "no"], "en")
    model_said = {**turn.intake, "chief_complaint": "zorblax flare"}
    reply = simulated.summary_reply(model_said, lang)
    assert "my knee feels odd for 2 days" in reply
    assert "zorblax" not in reply


def test_a_patient_may_hear_their_own_disease_word_back():
    _, turn = play(["my asthma is playing up", "for 2 days", "5", "no", "no", "no"], "en")
    assert "my asthma is playing up" in turn.reply


def test_a_drug_with_no_took_word_gives_the_plain_line_even_when_it_is_allowed():
    _, turn = play(["panadol did nothing", "for 2 days", "5", "no", "no", "no"], "en")
    assert turn.intake["self_medication"] == ["paracetamol"]
    assert turn.reply == simulated._SUMMARY_PLAIN["en"]


def test_the_denial_reads_back_in_english_too():
    _, turn = play(["I have a rash for 2 days", "5", "no", "no", "no"], "en", denied=["chest pain"])
    assert "Patient denied: chest pain." in turn.reply


@pytest.mark.parametrize(
    "answers",
    [
        ["Take paracetamol 500 mg", "for 2 days", "5", "panadol", "no", "no"],
        ["paracetamol 500 mg", "for 2 days", "5", "panadol", "no", "no"],
        ["Take paracetamol", "for 2 days", "5", "panadol", "no", "no"],
        ["خذ بنادول 500 ملغ", "من يومين", "٥", "بنادول", "لا", "لا"],
        ["بنادول 500 ملغ", "من يومين", "٥", "بنادول", "لا", "لا"],
        ["خذ بنادول", "من يومين", "٥", "بنادول", "لا", "لا"],
    ],
)
@pytest.mark.parametrize("lang", ["en", "ar"])
def test_a_dose_or_an_order_in_the_complaint_still_gives_the_plain_line(lang, answers):
    """Allowing paracetamol by name must not let a dose or an order about it through."""
    _, turn = play(answers, "en" if answers[1] == "for 2 days" else "ar")
    assert turn.intake["self_medication"] == ["paracetamol"]
    assert simulated.summary_reply(turn.intake, lang) == simulated._SUMMARY_PLAIN[lang]


def test_a_patient_sentence_that_fails_the_filter_is_replaced():
    _, turn = play(["my knee feels odd", "for 2 days", "5", "no", "no", "no"], "en")
    bad = {**turn.intake, "chief_complaint_patient_words": "You have the flu."}
    reply = simulated.summary_reply(bad, "en")
    assert reply == simulated._SUMMARY_PLAIN["en"]
    assert filters.check_reply(reply).ok


@pytest.mark.parametrize("lang", ["en", "ar"])
def test_emergency_reply_says_999_and_nearest_department(lang):
    reply = simulated.emergency_reply(lang, False)
    assert "999" in reply
    assert ("emergency department" in reply) if lang == "en" else ("طوارئ" in reply)


@pytest.mark.parametrize("lang", ["en", "ar"])
def test_self_harm_reply_adds_the_supportive_line(lang):
    plain = simulated.emergency_reply(lang, False)
    supportive = simulated.emergency_reply(lang, True)
    assert supportive.startswith(plain)
    assert len(supportive) > len(plain)


def test_gp_intake_after_refill_is_valid_and_passes_the_handoff_filter():
    history = [
        assistant(OPENING["en"], "complaint"),
        user("I need my usual blood pressure pills"),
        assistant("Handled without a visit", simulated.NOT_A_QUESTION),
    ]
    result = simulated.gp_intake_after_refill(history, AHMED, AHMED_MED, ["chest pain"], "en")
    assert intake.validate_intake(result).service == "gp"
    assert result["questions_asked"] == 1
    assert result["refill_request"] == AHMED_MED
    assert result["chief_complaint"] == "amlodipine refill"
    assert result["chief_complaint_patient_words"] == "I need my usual blood pressure pills"
    assert result["summary_for_nurse"].startswith("67M, amlodipine refill")
    assert result["summary_for_nurse"].endswith("Patient denied: chest pain.")
    assert "5 mg" not in result["summary_for_nurse"]
    assert filters.check_handoff(
        result["summary_for_nurse"], chronic=["hypertension"], allowed_meds=[AHMED_MED]
    ).ok


def test_no_randomness_or_clock():
    source = inspect.getsource(simulated)
    for forbidden in ("import random", "import time", "import datetime", "utcnow", "Fanar"):
        assert forbidden not in source


def test_system_prompt_holds_the_vault_rules():
    system = prompts.build_system({"age": 34, "sex": "F"}, [], 1, False)
    assert "You are NOT a doctor or nurse." in system
    assert "Never diagnose, name a likely condition, suggest treatment or doses." in system
    assert '{"emergency": true}' in system
    assert "{{record_json}}" not in system


def test_system_prompt_takes_only_the_minimal_record():
    full = {
        "age": 34, "sex": "F", "allergies": ["penicillin"], "chronic": [], "active_meds": [],
        "full_name_en": "Fatima Al-Demo", "qid_demo": "DEMO-10001", "id": "P001",
    }
    system = prompts.build_system(full, [], 1, False)
    assert '"age": 34' in system
    assert "penicillin" in system
    for private in ("Fatima", "DEMO-10001", "P001", "full_name"):
        assert private not in system


def test_system_prompt_context_lines():
    record = {"age": 34, "sex": "F", "allergies": [], "chronic": [], "active_meds": []}
    clear = prompts.build_system(record, [], 2, False)
    assert "Patient denied" not in clear
    assert "Output ONLY the intake JSON now" not in clear
    assert "Patient denied: chest pain" in prompts.build_system(record, ["chest pain"], 2, False)
    forced = prompts.build_system(record, [], 6, True)
    assert "You have asked 6 questions. Output ONLY the intake JSON now." in forced
    for key in intake.Intake.model_fields:
        if key not in ("denied_red_flags", "patient_concerns"):
            assert key in clear
