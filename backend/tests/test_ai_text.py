from __future__ import annotations

from itertools import product
from pathlib import Path

import pytest

from backend.ai import simulated
from backend.ai.filters import gate_reply
from backend.ai.text import (
    has_arabic,
    is_negated,
    normalise,
    split_sentences,
    tokenise,
)


def cue_index(tokens, word):
    return [token.text for token in tokens].index(word)


def cue_position(tokens):
    words = [token.text for token in tokens]
    return words.index("pain") if "pain" in words else words.index("الم")


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("أَلَم", "الم"),
        ("ألـــم", "الم"),
        ("أإآٱ", "اااا"),
        ("على", "علي"),
        ("حرارة", "حراره"),
        ("٣٨ ۳۸", "38 38"),
        ("CHEST Pain", "chest pain"),
        ("can’t", "can't"),
        ("can‘t", "can't"),
        ("canʼt", "can't"),
        ("chest   pain", "chest pain"),
        ("a b", "a b"),
        ("  a \n b  ", "a\nb"),
        ("a\r\nb", "a\nb"),
        ("chest​ pain‮", "chest pain"),
        ("﻿أ⁦لم⁩", "الم"),
        ("well, yes!", "well, yes!"),
    ],
)
def test_normalise(raw, expected):
    assert normalise(raw) == expected


def test_misspelled_and_correct_fainting_become_the_same_string():
    assert normalise("أغمى علي") == normalise("أغمي علي")


def test_hamza_carriers_stay_distinct():
    assert normalise("ؤ ئ") == "ؤ ئ"


def test_nfkc_runs_first_so_presentation_forms_are_unified():
    assert normalise("ﺃﻟﻢ") == "الم"


@pytest.mark.parametrize("raw", ["أَلَم، في الصّدر\nCHEST  ٣٨", "can’t  breathe.", ""])
def test_normalise_is_idempotent(raw):
    assert normalise(normalise(raw)) == normalise(raw)


def test_contractions_stay_one_token():
    assert [t.text for t in tokenise("I can't, don't")] == ["i", "can't", "don't"]


def test_tokenise_accepts_raw_text():
    assert [t.text for t in tokenise("أَلَم CHEST")] == ["الم", "chest"]


def test_empty_text_has_no_tokens():
    assert tokenise("  ") == []


@pytest.mark.parametrize("mark", [",", ".", "،", ";", "؛", ":", "?", "؟", "!", "\n"])
def test_punctuation_starts_a_clause(mark):
    tokens = tokenise(f"one{mark} two")
    assert tokens[0].starts_clause
    assert tokens[1].starts_clause


def test_decimal_point_is_not_a_boundary():
    tokens = tokenise("38.5 degrees")
    assert [t.text for t in tokens] == ["38", "5", "degrees"]
    assert not tokens[1].starts_clause


def test_full_stop_after_a_number_is_a_boundary():
    assert tokenise("about 38. then")[2].starts_clause


@pytest.mark.parametrize(
    "word",
    ["but", "however", "though", "although", "and", "لكن", "ولكن", "بس", "وبس", "و"],
)
def test_clause_words_start_a_clause(word):
    assert tokenise(f"one {word} two")[1].starts_clause


def test_plain_words_do_not_start_a_clause():
    assert not any(t.starts_clause for t in tokenise("one two three")[1:])


@pytest.mark.parametrize(
    ("text", "cue", "expected"),
    [
        ("no pain", "pain", True),
        ("no history of pain", "pain", True),
        ("no real history of any pain", "pain", False),
        ("i don't have pain", "pain", True),
        ("i don’t have any pain", "pain", True),
        ("no, pain", "pain", False),
        ("no fever but pain", "pain", False),
        ("no fever and pain", "pain", False),
        ("know pain", "pain", False),
        ("notable pain", "pain", False),
        ("nothing pain", "pain", False),
        ("cannot pain", "pain", False),
        ("not pain", "pain", True),
        ("without pain", "pain", True),
        ("denies pain", "pain", True),
        ("have pain", "pain", False),
        ("don't pain", "pain", False),
        ("ما عندي الم", "الم", True),
        ("عندي الم", "الم", False),
        ("ما الم", "الم", False),
        ("ما في الم", "الم", True),
        ("لا يوجد الم", "الم", True),
        ("يوجد الم", "الم", False),
        ("موجود الم", "الم", False),
        ("مو الم", "الم", True),
        ("مافي الم", "الم", True),
        ("بدون الم", "الم", True),
        ("ليس الم", "الم", True),
        ("ما، عندي الم", "الم", False),
    ],
)
def test_is_negated(text, cue, expected):
    tokens = tokenise(text)
    assert is_negated(tokens, cue_index(tokens, cue)) is expected


def test_phrase_whose_first_word_is_outside_the_window_still_counts():
    tokens = tokenise("ما عندي حرارة ولا الم")
    assert is_negated(tokens, cue_index(tokens, "الم"))


def test_window_is_adjustable():
    tokens = tokenise("no a b c pain")
    assert not is_negated(tokens, 4)
    assert is_negated(tokens, 4, window=4)


def test_cue_at_the_start_is_not_negated():
    assert not is_negated(tokenise("pain no"), 0)


def test_extra_negators_apply_only_when_passed():
    tokens = tokenise("i don't need a refill")
    index = cue_index(tokens, "refill")
    assert not is_negated(tokens, index)
    assert is_negated(tokens, index, extra=[("don't", "need")])


NEGATION_EXCEPTIONS = (
    "only",
    "just",
    "sure",
    "certain",
    "doubt",
    "idea",
    "relief",
    "improvement",
    "better",
    "helping",
    "helps",
    "for",
    "from",
    "reason",
    "الا",
    "إلا",
    "غير",
    "فقط",
    "سوي",
    "سوى",
    "سبب",
    "دوا",
    "دواء",
    "علاج",
    "حل",
)


NEGATORS = ("no", "not", "without", "denies", "don't have", "ما عندي", "مو", "مافي",
            "ما في", "بدون", "لا يوجد", "ليس")


@pytest.mark.parametrize("word", NEGATION_EXCEPTIONS)
@pytest.mark.parametrize("negator", NEGATORS)
def test_exception_word_cancels_every_negator(negator, word):
    tokens = tokenise(f"{negator} {word} pain")
    assert not is_negated(tokens, cue_index(tokens, "pain"))


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("not only a pain", False),
        ("no reason at pain", False),
        ("ما عندي إلّا الم", False),
        ("ما عندي غـــير الم", False),
        ("مَا عِنْدِي سِوَى الم", False),
        ("ما عندي الدوا الم", False),
        ("ما عندي علاجا الم", True),
        ("ما عندي حرارة بسبب الم", False),
        ("بدون بالعلاج الم", False),
        ("only no pain", True),
        ("just no pain", True),
        ("no pain only", True),
        ("no pain for days", True),
        ("no history of pain", True),
        ("no more pain", True),
        ("ما عندي حرارة ولا الم", True),
    ],
)
def test_exception_word_counts_only_between_the_negator_and_the_cue(text, expected):
    tokens = tokenise(text)
    assert is_negated(tokens, cue_position(tokens)) is expected


def test_exception_words_do_not_apply_to_a_caller_with_its_own_negators():
    tokens = tokenise("no need for refill")
    index = cue_index(tokens, "refill")
    assert not is_negated(tokens, index)
    assert is_negated(tokens, index, extra=[("don't", "need")])


ENGLISH_AFFIRMATIONS = ("i", "i'm", "im", "i've", "my", "it", "it's", "he", "she",
                        "we", "they")
ARABIC_AFFIRMATIONS = ("عندي", "فيني", "معي", "احس", "أحس", "أشعر", "حاس")
ARABIC_MARKED = ("عِنْدِي", "عـــندي", "فِينِي", "مَعِي", "أَحِسّ", "إحس", "أَشْعُر", "حَاس")
ARABIC_FORMS = (*ARABIC_AFFIRMATIONS, *ARABIC_MARKED)


@pytest.mark.parametrize("word", ENGLISH_AFFIRMATIONS)
@pytest.mark.parametrize("negator", NEGATORS)
def test_english_affirmation_cancels_every_negator(negator, word):
    tokens = tokenise(f"{negator} {word} pain")
    assert not is_negated(tokens, cue_index(tokens, "pain"))


@pytest.mark.parametrize("word", ARABIC_FORMS)
@pytest.mark.parametrize("negator", NEGATORS)
def test_arabic_affirmation_after_another_word_cancels_every_negator(negator, word):
    tokens = tokenise(f"{negator} حرارة {word} الم")
    assert not is_negated(tokens, cue_index(tokens, "الم"))


@pytest.mark.parametrize("word", ARABIC_FORMS)
@pytest.mark.parametrize("negator", NEGATORS)
def test_arabic_affirmation_with_a_proclitic_counts(negator, word):
    tokens = tokenise(f"{negator} حرارة و{word} الم")
    assert not is_negated(tokens, cue_index(tokens, "الم"))


@pytest.mark.parametrize("word", ARABIC_FORMS)
@pytest.mark.parametrize("negator", NEGATORS)
def test_arabic_affirmation_right_after_a_negator_is_negated_itself(negator, word):
    tokens = tokenise(f"{negator} {word} الم")
    assert is_negated(tokens, cue_index(tokens, "الم"))


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("i don't have pain", True),
        ("i don’t have any pain", True),
        ("i do not have pain", True),
        ("i have no pain", True),
        ("my no pain", True),
        ("it's not pain", True),
        ("it is not pain", True),
        ("no pain i have", True),
        ("عندي ما في الم", True),
        ("عندي لا يوجد الم", True),
        ("ما عندي الم", True),
        ("ما عندي حرارة ولا الم", True),
        ("ليس عندي الم", True),
        ("لا يوجد عندي الم", True),
        ("no i have pain", False),
        ("no i have any pain", False),
        ("ما عندي حرارة عندي الم", False),
        ("ما عندي حرارة وعندي الم", False),
        ("لا يوجد حرارة عندي الم", False),
        ("ليس حرارة عندي الم", False),
    ],
)
def test_negator_is_tested_before_the_affirmation_at_each_position(text, expected):
    tokens = tokenise(text)
    assert is_negated(tokens, cue_position(tokens)) is expected


@pytest.mark.parametrize("cue", ["i am pain", "my pain", "it pain"])
def test_a_cue_opening_on_an_affirmation_is_not_denied(cue):
    tokens = tokenise(f"no {cue}")
    assert not is_negated(tokens, 1)


def test_a_cue_opening_on_a_negated_arabic_affirmation_is_denied():
    tokens = tokenise("ليس عندي الم")
    assert is_negated(tokens, 1)


def test_window_still_stops_at_three_words():
    assert is_negated(tokenise("no a b pain"), 3)
    assert not is_negated(tokenise("no a b c pain"), 4)


def test_clause_rules_are_unchanged_by_affirmations():
    assert not is_negated(tokenise("no, i pain"), 2)
    assert is_negated(tokenise("i. no pain"), 2)


@pytest.mark.parametrize("word", (*ENGLISH_AFFIRMATIONS, *ARABIC_AFFIRMATIONS))
def test_affirmation_words_do_not_apply_to_a_caller_with_its_own_negators(word):
    tokens = tokenise(f"no حرارة {word} refill")
    index = cue_index(tokens, "refill")
    assert is_negated(tokens, index, extra=[("don't", "need")])
    assert not is_negated(tokens, index)


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("hello", False),
        ("123", False),
        ("", False),
        ("مرحبا", True),
        ("hello مرحبا", True),
        ("١٢٣", False),
    ],
)
def test_has_arabic(text, expected):
    assert has_arabic(text) is expected


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("One. Two? Three!", ["One.", "Two?", "Three!"]),
        ("هل عندك حرارة؟ خذ بنادول", ["هل عندك حرارة؟", "خذ بنادول"]),
        ("line one\nline two", ["line one", "line two"]),
        ("Temp 38.5 today. Fine", ["Temp 38.5 today.", "Fine"]),
        ("Really?! Yes", ["Really?!", "Yes"]),
        ("", []),
    ],
)
def test_split_sentences(text, expected):
    assert split_sentences(text) == expected


# The model text gate is filters.gate_reply. These words appear nowhere in backend/ai,
# and nothing here may add them: the gate has to refuse them unseen.
INVENTED = ("zorblax", "quinthera", "Velmoxin", "flurbitis", "زوربلاكس", "كويناثيرا")
AI_SOURCE = Path(__file__).resolve().parents[1] / "ai"


@pytest.mark.parametrize("word", INVENTED)
def test_invented_word_is_on_no_list(word):
    sources = sorted(AI_SOURCE.glob("*.py"))
    assert sources
    for source in sources:
        code = normalise(source.read_text(encoding="utf-8"))
        assert normalise(word) not in code, source.name


ENGLISH_SHAPES = (
    "You have {w}.",
    "You have {w}",
    "{w} is best.",
    "{w} is best",
    "{w}.",
    "{w}",
    "It is {w}.",
    "It's probably {w}.",
    "This looks like {w}.",
    "Your problem is {w}.",
    "Take {w}.",
    "Try {w} twice a day.",
    "Use {w} tonight!",
    "{w} will help.",
    "{w} is the cause. Any fever?",
    "{w} is best. Do you have a fever?",
    "You have {w}. When did it start?",
    "You have {w}, when did it start?",
    "You have {w}: when did it start?",
    "You have {w}; when did it start?",
    "Thanks, you have {w}. When did it start?",
    "Thanks. {w}. When did it start?",
    "Thanks {w}. When did it start?",
    "Sorry about the {w}. When did it start?",
    "When did it start? {w} is best.",
    "When did it start? You have {w}",
    "When did it start?\n{w} is best",
    "Do you have a fever? Take {w}.",
    "Do you have a fever, {w} is best?",
    "Do you have a fever (it is {w})?",
    "Do you have a fever - {w} is best?",
    "Do you have a fever \u2014 {w} is best?",
    "Do you have a fever / {w}?",
    "**You have {w}?**",
    "You have {w}?",
    "{w}?",
    "{w} is best?",
    "{w} is best, okay?",
    "{w} is best, right?",
    "Is it {w}?",
    "Is this {w}?",
    "Is that {w}?",
    "It is {w}?",
    "Could it be {w}?",
    "Could this be {w}?",
    "Might it be {w}?",
    "Maybe {w}?",
    "Probably {w}?",
    "Take {w}?",
    "Try {w}?",
    "Should you take {w}?",
    "Would {w} help?",
    "Will {w} help?",
    "Does {w} help?",
    "Is {w} best?",
    "Is your problem {w}?",
    "Is the cause {w}?",
    "Do you think it is {w}?",
    "Do you think you have {w}?",
    "Do you believe it's {w}?",
    "Did you know you have {w}?",
    "Did you know {w} is best?",
    "Are you aware you have {w}?",
    "What about {w}?",
    "How about {w}?",
    "Any chance this is {w}?",
    "Have you tried {w}?",
    "Do you want to try {w}?",
    "Do you need {w}?",
    "Which {w} is best?",
)
ARABIC_SHAPES = (
    "عندك {w}.",
    "عندك {w}",
    "{w} أفضل.",
    "{w} أفضل",
    "{w}.",
    "{w}",
    "شكلك مصاب ب{w}",
    "مصاب ب{w}.",
    "خذ {w}.",
    "خذ {w}",
    "جرب {w}!",
    "{w} يساعدك.",
    "عندك {w}. من متى؟",
    "عندك {w}، من متى؟",
    "{w} أفضل. عندك حرارة؟",
    "سلامتك، عندك {w}. من متى؟",
    "سلامتك {w}. من متى؟",
    "من متى؟ عندك {w}.",
    "من متى؟\nخذ {w}",
    "عندك حرارة، {w} أفضل؟",
    "{w}؟",
    "{w} أفضل؟",
    "{w} أفضل، صح؟",
    "هل {w} أفضل؟",
    "هل هذا {w}؟",
    "هل هذه {w}؟",
    "هذا {w}؟",
    "شكلك مصاب؟",
    "مصاب ب{w}؟",
    "يمكن {w}؟",
    "خذ {w}؟",
    "جرب {w}؟",
    "عندك {w} يمكن؟",
    "في {w} أفضل؟",
    "عندك {w} لأنك تعبان؟",
)
REJECTED_SHAPES = sorted(
    {
        shape.format(w=word)
        for shape, word in (
            *product(ENGLISH_SHAPES, INVENTED),
            *product(ARABIC_SHAPES, INVENTED),
        )
    }
)


def test_rejected_shapes_cover_every_template_and_word():
    assert len(ENGLISH_SHAPES) + len(ARABIC_SHAPES) > 100
    assert len(REJECTED_SHAPES) > 600


@pytest.mark.parametrize("reply", REJECTED_SHAPES)
def test_gate_rejects_an_invented_word_by_shape(reply):
    assert not gate_reply(reply)


@pytest.mark.parametrize(
    "reply",
    [
        "عِنْدَك زوربلاكس.",
        "زوربلـــاكس أَفْضَل.",
        "You\u200b have zorblax.",
        "zorblax\ufeff is best\u200f.",
    ],
)
def test_gate_rejects_an_invented_word_behind_marks(reply):
    assert not gate_reply(reply)


@pytest.mark.parametrize(
    "reply",
    ["Do you have zorblax?", "Did you take zorblax?", "عندك زوربلاكس؟", "هل تناولت زوربلاكس؟"],
)
def test_gate_rejects_an_invented_word_inside_a_real_question(reply):
    assert not gate_reply(reply)


@pytest.mark.parametrize(
    "reply",
    ["Do you have zorblax?", "Did you take zorblax?", "عندك زوربلاكس؟"],
)
def test_gate_lets_a_question_repeat_what_the_patient_said(reply):
    assert gate_reply(reply, known=["zorblax", "زوربلاكس"])


@pytest.mark.parametrize(
    "reply",
    [
        "You have zorblax.",
        "zorblax is best.",
        "Take zorblax.",
        "You have zorblax?",
        "Is it zorblax?",
        "zorblax is best, okay?",
        "زوربلاكس أفضل.",
        "خذ زوربلاكس.",
        "زوربلاكس؟",
    ],
)
def test_a_patients_own_word_does_not_excuse_the_shape(reply):
    assert not gate_reply(reply, known=["zorblax", "زوربلاكس"])


@pytest.mark.parametrize(
    "reply",
    [
        "You have the flu",
        "عندك انفلونزا",
        "شكلك مصاب بالتهاب",
        "Take paracetamol 500 mg",
        "خذ بنادول",
        "Your number is T-014",
        "رقمك 14",
        "عِنْدَك إِنْفْلُونْزَا",
        "خُذْ بَنَادُول",
    ],
)
def test_gate_rejects_the_banned_output_acceptance_strings(reply):
    assert not gate_reply(reply)


@pytest.mark.parametrize(
    "reply",
    [
        "",
        "   ",
        "?",
        "؟",
        "Thanks.",
        "Thanks?",
        "شكرا",
        "شكرا؟",
        "Do you have a fever",
        "عندك حرارة",
        "Do you have a fever.",
        "Do you have a fever??",
        "Do you have a fever? Any cough?",
        "Since when? Any fever?",
        "عندك حرارة؟ عندك كحة؟",
        "Do you have a fever؟ Any cough?",
        "Do you have a fever? Thanks.",
        "Thanks. Okay. When did it start?",
        "Thanks! Thanks! When did it start?",
        "Thanks. Okay, when did it start?",
        "شكرا. طيب، من متى؟",
        "Sorry to hear that. Thanks. When did it start?",
        "3 thanks. When did it start?",
        "Thanks 3. When did it start?",
        "Thanks ٣. When did it start?",
        "شكرا ٣. من متى؟",
        "This is not an emergency. How long have you had it?",
        "I hope you feel better soon my friend. When did it start?",
        "Is there anything else?",
    ],
)
def test_gate_rejects_any_other_shape(reply):
    assert not gate_reply(reply)


@pytest.mark.parametrize(
    "reply",
    [
        "Do you have a fever?",
        "عندك حرارة؟",
        "Did you take any medicine for it?",
        "How long have you had it?",
        "How long have you had the cough?",
        "How long?",
        "Since when?",
        "When did it start?",
        "Where does it hurt?",
        "Is the pain sharp?",
        "How bad is it from 0 to 10?",
        "كم شدته؟",
        "أخذت أي دوا؟",
        "من متى عندك الحرارة؟",
        "هل عندك حرارة؟",
        "هل الألم شديد؟",
        "وين الألم؟",
        "Thanks. How long have you had it?",
        "Thanks, how long have you had it?",
        "Thanks! How long have you had it?",
        "Sorry to hear that. When did it start?",
        "Okay, thanks. Do you have a fever?",
        "سلامتك! من متى؟",
        "سلامتك، من متى؟",
        "شكرا. عندك حرارة؟",
    ],
)
def test_gate_accepts_one_short_question_with_one_acknowledgement_at_most(reply):
    assert gate_reply(reply)


@pytest.mark.parametrize(
    "reply",
    [
        "هَل عِنْدَك حَرَارَة؟",
        "عِنْدَك حَرَارَة؟",
        "أَخَذْت أَي دَوَاء؟",
        "مِن مَتَى؟",
        "سَلَامَتَك، مِن مَتَى؟",
        "شُكْرًا. كـــم شدته؟",
        "مـــن مـــتى؟",
    ],
)
def test_gate_reads_normalised_text(reply):
    assert gate_reply(reply)


def test_gate_accepts_the_questions_the_simulated_receptionist_asks():
    asked = [
        *simulated.OPENING.values(),
        *(
            question
            for group in (*simulated.QUESTIONS.values(), *simulated.FOLLOW_UPS.values())
            for question in group.values()
        ),
    ]
    assert len(asked) >= 16
    for question in asked:
        assert gate_reply(question), question


def test_gate_caps_the_question_at_fifteen_words():
    fifteen = "Do you have " + "a " * 11 + "fever?"
    assert len(fifteen.split()) == 15
    assert gate_reply(fifteen)
    assert not gate_reply("Do you have " + "a " * 12 + "fever?")


def test_gate_caps_the_acknowledgement_at_six_words():
    question = "When did it start?"
    assert gate_reply(f"{'thanks ' * 6}. {question}")
    assert not gate_reply(f"{'thanks ' * 7}. {question}")
