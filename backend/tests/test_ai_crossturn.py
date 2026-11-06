"""Red flags across a whole conversation, a yes to a cue question, and the text gate.

The red line is that no ticket goes out with a listed red flag present. So every
firing case here ends at engine.issue_ticket, not at the rule's own return value.
"""

from __future__ import annotations

import ast
import inspect
import json
from itertools import permutations, product
from pathlib import Path

import pytest

from backend import db
from backend.adapters.queue_base import VisitNotEligible
from backend.ai import filters, receptionist, redflags, session, simulated
from backend.ai.asr import Asr
from backend.ai.llm import Llm
from backend.ai.runtime import AiRuntime
from backend.ai.text import has_arabic, phrase_tokens, tokenise
from backend.tests.ai_fakes import FakeChatClient
from backend.tests.conftest import make_visit

ASR = Asr(mode="simulated", model_id="simulated")
SIM = AiRuntime(llm=Llm(mode="simulated", model_id="simulated"), asr=ASR)
TRIAGE = "C-WAKRA-T1"
ENGLISH = "P003"
ARABIC = "P001"
AHMED = "P002"
RECORD = {"allergies": [], "chronic": [], "active_meds": [], "preferred_lang": "en"}


def real(client):
    return AiRuntime(llm=Llm(mode="real", model_id="test", client=client), asr=ASR)


def say(conn, ai, visit_id, *messages):
    result = None
    for message in messages:
        result = session.handle_message(conn, ai, visit_id, message)
    return result


def visit_status(conn, visit_id):
    return conn.execute("SELECT status FROM visit WHERE id = ?", (visit_id,)).fetchone()[0]


def ticket_count(conn):
    return conn.execute("SELECT COUNT(*) FROM ticket").fetchone()[0]


def event_rows(conn, visit_id):
    rows = conn.execute(
        "SELECT type, payload FROM event WHERE visit_id = ? ORDER BY id", (visit_id,)
    ).fetchall()
    return [(row["type"], json.loads(row["payload"])) for row in rows]


def event_types(conn, visit_id):
    return [name for name, _ in event_rows(conn, visit_id)]


def refused_a_ticket(conn, engine, visit_id):
    before = ticket_count(conn)
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, TRIAGE)
    return ticket_count(conn) == before


def model_questions(count, lang="en"):
    """A model that only asks plain questions, one per message before the last."""
    return FakeChatClient([simulated.QUESTIONS["duration"][lang]] * count)


def assert_stopped(conn, engine, visit_id, result, category):
    assert result.emergency
    assert result.source == "rules"
    assert result.emergency_category == category
    assert "999" in result.reply
    assert not result.done
    assert result.intake is None
    assert visit_status(conn, visit_id) == "redirected_emergency"
    assert "redflag.hit" in event_types(conn, visit_id)
    assert refused_a_ticket(conn, engine, visit_id)


CHEST_SITES_EN = ("chest", "my chest", "in my chest", "left chest and arm", "the chest")
CHEST_SITES_AR = ("صدري", "في الصدر", "الصدر", "بصدري", "في صدري", "بالصدر")
PAIN_EN = ("I have pain", "it hurts", "I hurt", "an ache", "it feels tight", "pressure")
PAIN_AR = ("عندي ألم", "عندي وجع", "يوجع", "يعور", "يوجعني")

# The listed cues our own questions split: (messages, category, label).
ROW_SPLITS_EN = [
    (("I vomited", "there was blood"), "bleeding", "vomiting blood"),
    (("there was blood", "I vomited"), "bleeding", "vomiting blood"),
    (("I have been vomiting", "with blood"), "bleeding", "vomiting blood"),
    (("I was throwing up", "blood"), "bleeding", "vomiting blood"),
    (("I threw up", "blood"), "bleeding", "vomiting blood"),
    (("I need a blood test", "I vomited", "there was blood too"), "bleeding", "vomiting blood"),
    (("I have pain", "to my left arm"), "chest_pain", "pain spreading to arm or jaw"),
    (("to my left arm", "I have pain"), "chest_pain", "pain spreading to arm or jaw"),
    (("I have pain", "to left arm"), "chest_pain", "pain spreading to arm or jaw"),
    (("I have pain", "to my arm"), "chest_pain", "pain spreading to arm or jaw"),
    (("I have pain", "to the arm"), "chest_pain", "pain spreading to arm or jaw"),
    (("it hurts", "down my arm"), "chest_pain", "pain spreading to arm or jaw"),
    (("it hurts", "down my left arm"), "chest_pain", "pain spreading to arm or jaw"),
    (("it hurts", "into my arm"), "chest_pain", "pain spreading to arm or jaw"),
    (("an ache", "to my jaw"), "chest_pain", "pain spreading to arm or jaw"),
    (("an ache", "to jaw"), "chest_pain", "pain spreading to arm or jaw"),
    (("an ache", "to my left jaw"), "chest_pain", "pain spreading to arm or jaw"),
    (("an ache", "into my jaw"), "chest_pain", "pain spreading to arm or jaw"),
    (("I have swelling", "my throat"), "allergy", "throat swelling"),
    (("my throat", "I have swelling"), "allergy", "throat swelling"),
    (("it is swollen", "my tongue"), "allergy", "throat swelling"),
    (("my tongue", "it swelled"), "allergy", "throat swelling"),
    (("I have swelling", "my lips"), "allergy", "lip swelling"),
    (("my lip", "it is swollen"), "allergy", "lip swelling"),
    (("my face", "it is drooping"), "stroke", "facial drooping"),
    (("drooping", "my face"), "stroke", "facial drooping"),
    (("my face", "it drooped"), "stroke", "facial drooping"),
    (("my speech", "slurred"), "stroke", "slurred speech"),
    (("slurred", "my speech"), "stroke", "slurred speech"),
    (("slurring", "my words"), "stroke", "slurred speech"),
    (("I can't move", "my arm"), "stroke", "unable to move arm"),
    (("I can’t move", "my arm"), "stroke", "unable to move arm"),
    (("I can't move my", "arm"), "stroke", "unable to move arm"),
    (("my arm", "I can't move it"), "stroke", "unable to move arm"),
    (("my left leg", "I cannot move it"), "stroke", "unable to move arm"),
    (("I can not move", "not my arm", "my leg"), "stroke", "unable to move arm"),
    (("no can't move", "my arm"), "stroke", "unable to move arm"),  # "no" denies nothing here
]
ROW_SPLITS_AR = [
    (("أستفرغ", "فيه دم"), "bleeding", "vomiting blood"),
    (("فيه دم", "أستفرغ"), "bleeding", "vomiting blood"),
    (("عندي ترجيع", "مع دم"), "bleeding", "vomiting blood"),
    (("استفراغ", "بالدم"), "bleeding", "vomiting blood"),
    (("أرجع", "طلع دم"), "bleeding", "vomiting blood"),
    (("عندي قيء", "فيه الدم"), "bleeding", "vomiting blood"),
    (("تقيؤ", "ودم"), "bleeding", "vomiting blood"),
    (("لما أرجع فيه دم",), "bleeding", "vomiting blood"),  # لما is "when", not a negator
    (("عندي ألم", "يمتد ذراعي"), "chest_pain", "pain spreading to arm or jaw"),
    (("عندي ألم", "ينتشر يدي"), "chest_pain", "pain spreading to arm or jaw"),
    (("عندي ألم", "ينزل فكي"), "chest_pain", "pain spreading to arm or jaw"),
    (("عندي وجع", "لذراعي"), "chest_pain", "pain spreading to arm or jaw"),
    (("عندي وجع", "ليدي"), "chest_pain", "pain spreading to arm or jaw"),
    (("عندي وجع", "لفكي"), "chest_pain", "pain spreading to arm or jaw"),
    (("يوجعني", "إلى ذراعي"), "chest_pain", "pain spreading to arm or jaw"),
    (("يوجعني", "إلى يدي"), "chest_pain", "pain spreading to arm or jaw"),
    (("يوجعني", "إلى فكي"), "chest_pain", "pain spreading to arm or jaw"),
    (("لذراعي", "عندي ألم"), "chest_pain", "pain spreading to arm or jaw"),
    (("عندي انتفاخ", "حلقي"), "allergy", "throat swelling"),
    (("حلقي", "متورم"), "allergy", "throat swelling"),
    (("لساني", "منتفخ"), "allergy", "throat swelling"),
    (("عندي تورم", "في الحلق"), "allergy", "throat swelling"),
    (("عندي تورم", "شفايفي"), "allergy", "lip swelling"),
    (("شفايفي", "منتفخة"), "allergy", "lip swelling"),
    (("الشفاه", "متورمة"), "allergy", "lip swelling"),
    (("وجهي", "مايل"), "stroke", "facial drooping"),
    (("مائل", "وجهي"), "stroke", "facial drooping"),
    (("كلامي", "ثقيل"), "stroke", "slurred speech"),
    (("ثقيل", "كلامي"), "stroke", "slurred speech"),
    (("ما أقدر أحرك", "يدي"), "stroke", "unable to move arm"),
    (("يدي", "ما أقدر أحركها"), "stroke", "unable to move arm"),
    (("رجلي", "ما أقدر أحركه"), "stroke", "unable to move arm"),
    (("مو قادر أحرك", "ذراعي"), "stroke", "unable to move arm"),
    (("يدي", "ما أحركها"), "stroke", "unable to move arm"),
    (("لا أقدر أحرك", "إيدي"), "stroke", "unable to move arm"),
    (("لا أستطيع تحريك", "رجلي"), "stroke", "unable to move arm"),
    (("عندي ضيق", "في التنفس"), "breathing", "shortness of breath"),
    (("عندي ضيق", "تنفس"), "breathing", "shortness of breath"),
    (("ضيق", "بالتنفس من أمس"), "breathing", "shortness of breath"),
    (("في التنفس", "عندي ضيق"), "breathing", "shortness of breath"),
    (("عندي ضيقة", "لما أتنفس"), "breathing", "shortness of breath"),
]


def without_label(rows):
    return [(messages, category) for messages, category, _ in rows]


SPLIT_EN = [
    *without_label(ROW_SPLITS_EN),
    *(((pain, site), "chest_pain") for pain in PAIN_EN for site in CHEST_SITES_EN),
    (("chest", "I have pain"), "chest_pain"),
    (("I have pain", "yesterday", "8", "chest"), "chest_pain"),
    (("I have pain", "for 2 days", "5", "in my chest"), "chest_pain"),
    (("I have pain", "no it is my chest"), "chest_pain"),
    (("I have pain", "no my chest"), "chest_pain"),
    (("I am bleeding", "I am pregnant"), "pregnancy"),
    (("I am pregnant", "I am bleeding"), "pregnancy"),
    (("I am pregnant", "bleeding"), "pregnancy"),
    (("severe pain", "I am pregnant"), "pregnancy"),
    (("I am pregnant", "severe pain"), "pregnancy"),
    (("I have pain", "it is severe", "I am pregnant"), "pregnancy"),
    (("I am bleeding", "heavy"), "bleeding"),
    (("I am bleeding", "heavily"), "bleeding"),
    (("I am bleeding", "a lot"), "bleeding"),
    (("heavy", "I am bleeding"), "bleeding"),
    (("my baby", "not feeding"), "infant"),
    (("my baby", "no not feeding"), "infant"),
    (("not feeding", "my baby"), "infant"),
    (("my baby", "very sleepy"), "infant"),
    (("my baby", "high fever"), "infant"),
    (("my baby has a fever", "it is very high"), "infant"),
    (("the infant", "won't wake"), "infant"),
    (("my son", "not breastfeeding"), "infant"),
]
SPLIT_AR = [
    *without_label(ROW_SPLITS_AR),
    *(((pain, site), "chest_pain") for pain in PAIN_AR for site in CHEST_SITES_AR),
    (("صدري", "عندي ألم"), "chest_pain"),
    (("ينزف", "أنا حامل"), "pregnancy"),
    (("أنا حامل", "تنزف"), "pregnancy"),
    (("عندي ألم شديد", "أنا حامل"), "pregnancy"),
    (("أنا حامل", "وجع شديد"), "pregnancy"),
    (("عندي ألم", "شديد", "أنا حامل"), "pregnancy"),
    (("ينزف", "غزير"), "bleeding"),
    (("تنزف", "وايد"), "bleeding"),
    (("طفلي", "ما يرضع"), "infant"),
    (("الرضيع", "ما يرضع"), "infant"),
    (("ولدي", "ما يرضع"), "infant"),
    (("بنتي", "ما ترضع"), "infant"),
    (("البيبي", "نعسان جدا"), "infant"),
    (("طفلتي", "ما تصحى"), "infant"),
    (("طفلي", "حرارة عالية"), "infant"),
    (("رضيعي عنده حرارة", "مرتفعة"), "infant"),
]
SAME_MESSAGE_EN = [
    ("severe pain and i am pregnant", "pregnancy"),
    ("i have severe pain and i am pregnant", "pregnancy"),
    ("the pain is severe and i am pregnant", "pregnancy"),
    ("I am bleeding and i think i am pregnant", "pregnancy"),
    ("my chest, it has pain", "chest_pain"),
    ("I have been bleeding, it is heavy", "bleeding"),
    ("my baby has stopped feeding", "infant"),
    ("there is blood in my vomit", "bleeding"),
    ("I vomited and there was blood", "bleeding"),
    ("blood came up when I threw up", "bleeding"),
    ("it hurts, and it goes down my left arm", "chest_pain"),
    ("it goes into my jaw and it hurts", "chest_pain"),
    ("my throat has swelling", "allergy"),
    ("swelling on my lips", "allergy"),
    ("my face started drooping", "stroke"),
    ("my speech sounds slurred", "stroke"),
    ("I can not move arm", "stroke"),
    ("I can not move left arm", "stroke"),
    ("I can not move right arm", "stroke"),
    ("I can not move leg", "stroke"),
    ("I can not move left leg", "stroke"),
    ("I can not move right leg", "stroke"),
    ("I cannot move, it is my leg", "stroke"),
]
SAME_MESSAGE_AR = [
    ("عندي ألم شديد وحامل", "pregnancy"),
    ("أنا حامل وعندي وجع قوي", "pregnancy"),
    ("ينزف وأنا حامل", "pregnancy"),
    ("طفلتي حرارتها مرتفعة", "infant"),
    ("فيه دم مع الترجيع", "bleeding"),
    ("استفرغت وطلع دم", "bleeding"),
    ("عندي ألم ينزل إلى يدي", "chest_pain"),
    ("حلقي فيه انتفاخ", "allergy"),
    ("شفايفي فيها تورم", "allergy"),
    ("وجهي صار مايل", "stroke"),
    ("كلامي صار ثقيل", "stroke"),
    ("مو قادر أحرك يدي", "stroke"),
    ("مو قادر أحرك إيدي", "stroke"),
    ("مو قادر أحرك ذراعي", "stroke"),
    ("مو قادر أحرك رجلي", "stroke"),
    ("لا أقدر أحرك رجلي", "stroke"),
    ("لا أستطيع تحريك إيدي", "stroke"),
    ("عندي ضيق وصعب أتنفس", "breathing"),
]


def ids(cases):
    return [" / ".join(case[0]) if isinstance(case[0], tuple) else case[0] for case in cases]


@pytest.mark.parametrize(("messages", "category"), SPLIT_EN, ids=ids(SPLIT_EN))
def test_a_split_cue_fires_in_simulated_english(seeded, engine, messages, category):
    visit_id = make_visit(seeded, ENGLISH)
    assert_stopped(seeded, engine, visit_id, say(seeded, SIM, visit_id, *messages), category)


@pytest.mark.parametrize(("messages", "category"), SPLIT_AR, ids=ids(SPLIT_AR))
def test_a_split_cue_fires_in_simulated_arabic(seeded, engine, messages, category):
    visit_id = make_visit(seeded, ARABIC)
    assert_stopped(seeded, engine, visit_id, say(seeded, SIM, visit_id, *messages), category)


@pytest.mark.parametrize(("messages", "category"), SPLIT_EN, ids=ids(SPLIT_EN))
def test_a_split_cue_fires_on_the_real_path_english(seeded, engine, messages, category):
    client = model_questions(len(messages) - 1)
    visit_id = make_visit(seeded, ENGLISH)
    result = say(seeded, real(client), visit_id, *messages)
    assert len(client.calls) == len(messages) - 1  # none on the turn that fired
    assert_stopped(seeded, engine, visit_id, result, category)


@pytest.mark.parametrize(("messages", "category"), SPLIT_AR, ids=ids(SPLIT_AR))
def test_a_split_cue_fires_on_the_real_path_arabic(seeded, engine, messages, category):
    client = model_questions(len(messages) - 1, "ar")
    visit_id = make_visit(seeded, ARABIC)
    result = say(seeded, real(client), visit_id, *messages)
    assert len(client.calls) == len(messages) - 1
    assert_stopped(seeded, engine, visit_id, result, category)


@pytest.mark.parametrize(
    ("text", "category"), [*SAME_MESSAGE_EN, *SAME_MESSAGE_AR], ids=ids([*SAME_MESSAGE_EN, *SAME_MESSAGE_AR])
)
def test_one_message_can_hold_both_sides(seeded, engine, text, category):
    client = FakeChatClient([])
    visit_id = make_visit(seeded, ENGLISH)
    result = say(seeded, real(client), visit_id, text)
    assert client.calls == []
    assert_stopped(seeded, engine, visit_id, result, category)


@pytest.mark.parametrize(
    ("patient", "rows"),
    [(ENGLISH, row) for row in ROW_SPLITS_EN] + [(ARABIC, row) for row in ROW_SPLITS_AR],
    ids=ids([*ROW_SPLITS_EN, *ROW_SPLITS_AR]),
)
def test_a_listed_cue_fires_under_its_own_label(seeded, patient, rows):
    messages, category, label = rows
    visit_id = make_visit(seeded, patient)
    say(seeded, SIM, visit_id, *messages)
    hits = [p for name, p in event_rows(seeded, visit_id) if name == "redflag.hit"]
    assert hits == [
        {"category": category, "cue": hits[0]["cue"], "label": label}
    ]
    assert " + " in hits[0]["cue"]  # came through _COMPOUNDS, not a single phrase


def pairs_with(partner, *words):
    return [(word, partner) for word in words]


# Written out rather than read from _SIDES, so a word dropped from the rules fails here.
EVERY_SIDE_WORD = [
    *pairs_with(
        "there was blood",
        "vomit", "vomits", "vomiting", "vomited", "throw up", "throwing up", "threw up",
    ),
    *pairs_with(
        "فيه دم",
        "ترجيع", "استفراغ", "أستفرغ", "استفرغت", "أرجع", "قيء", "تقيؤ", "أتقيأ", "تقيأت",
    ),
    *pairs_with("I vomited", "blood", "the blood", "دم", "الدم", "بدم", "ودم", "بالدم", "والدم"),
    *pairs_with(
        "I have pain",
        *(
            f"{way} {place}"
            for way in ("to", "down", "into")
            for place in (
                "my arm", "my left arm", "my right arm", "left arm", "right arm", "the arm",
                "the left arm", "arm", "my jaw", "my left jaw", "left jaw", "the jaw", "jaw",
            )
        ),
    ),
    *pairs_with(
        "عندي ألم",
        *(
            f"{verb} {link}{place}"
            for verb in ("يمتد", "ينتشر", "ينزل", "تمتد", "تنتشر", "تنزل")
            for link in ("", "في ", "على ")
            for place in ("ذراعي", "يدي", "إيدي", "فكي", "الذراع", "اليد", "الفك")
        ),
        *(f"إلى {place}" for place in ("ذراعي", "يدي", "إيدي", "فكي", "الذراع", "اليد", "الفك")),
        "لذراعي", "ليدي", "لإيدي", "لفكي", "للذراع", "لليد", "للفك",
    ),
    *pairs_with("my throat", "swelling", "swollen", "swelled"),
    *pairs_with(
        "حلقي", "انتفاخ", "تورم", "منتفخ", "منتفخة", "متورم", "متورمة", "انتفخ", "انتفخت", "تورمت",
    ),
    *pairs_with("I have swelling", "throat", "tongue", "lip", "lips"),
    *pairs_with(
        "عندي انتفاخ",
        "حلق", "الحلق", "حلقي", "حلقه", "حلقها", "لسان", "اللسان", "لساني", "لسانه", "لسانها",
        "شفة", "شفتي", "شفايف", "الشفايف", "شفايفي", "شفايفه", "شفايفها", "شفاه", "الشفاه", "شفاهي",
    ),
    *pairs_with("it is drooping", "face", "the face"),
    *pairs_with("مايل", "وجه", "الوجه", "وجهي", "وجهه", "وجهها"),
    *pairs_with("my face", "droop", "drooping", "drooped", "droopy"),
    *pairs_with("وجهي", "مايل", "مائل", "مايلة", "مائلة", "معوج"),
    *pairs_with("slurred", "speech", "my speech", "my words"),
    *pairs_with("my speech", "slurred", "slurring"),
    *pairs_with("ثقيل", "كلامي"),
    *pairs_with("كلامي", "ثقيل"),
    *pairs_with(
        "my arm",
        "can't move", "cant move", "cannot move", "can not move", "ما أقدر أحرك",
        "مو قادر أحرك", "لا أقدر أحرك", "لا أستطيع تحريك", "أحركها", "أحركه",
    ),
    *pairs_with(
        "I can't move",
        "arm", "my arm", "left arm", "right arm", "leg", "my leg",
        "يدي", "إيدي", "ذراعي", "رجلي",
    ),
    *pairs_with("عندي ضيق", "تنفس", "التنفس", "بالتنفس", "أتنفس"),
    *pairs_with("في التنفس", "ضيق", "الضيق", "ضيقة", "الضيقة"),
]
NOT_THE_SIDE = [
    *pairs_with(
        "I vomited",
        "blood pressure", "blood test", "blood tests", "blood sugar",
        "تحليل دم", "تحليل الدم", "تحاليل دم", "تحاليل الدم", "فحص دم", "فحص الدم",
        "ضغط دم", "ضغط الدم", "سكر دم", "سكر الدم", "بضغط الدم", "وسكر الدم",
    ),
    *pairs_with(
        "I have swelling",
        "sore throat", "ألم في الحلق", "ألم بالحلق", "ألم الحلق", "وجع في الحلق",
        "وجع بالحلق", "وجع الحلق", "وجع حلق", "التهاب الحلق", "التهاب في الحلق", "التهاب حلق",
    ),
]


# "arm" also matches inside "my arm", so no dialogue can show those four dropped. The
# written-out side can, and the row must hold what was asked for word for word.
ROW_WORDS = [
    *(("cant_move", word) for word in (
        "can't move", "cant move", "cannot move", "can not move", "ما أقدر أحرك",
        "مو قادر أحرك", "لا أقدر أحرك", "لا أستطيع تحريك", "أحركها", "أحركه",
    )),
    *(("limb", word) for word in (
        "arm", "my arm", "left arm", "right arm", "leg", "my leg",
        "يدي", "إيدي", "ذراعي", "رجلي",
    )),
    *(("narrow", word) for word in ("ضيق", "ضيقة")),
    *(("breath", word) for word in ("تنفس", "أتنفس")),
]


@pytest.mark.parametrize(("side", "word"), ROW_WORDS)
def test_a_row_holds_every_word_written_for_it(side, word):
    assert phrase_tokens(word) in redflags._SIDES[side]


def history_of(*messages):
    return [{"role": "user", "content": message} for message in messages]


@pytest.mark.parametrize(("word", "partner"), EVERY_SIDE_WORD)
def test_every_word_of_a_side_counts(word, partner):
    assert redflags.check_conversation(word, history_of(partner)).emergency


@pytest.mark.parametrize(("phrase", "partner"), NOT_THE_SIDE)
def test_a_side_word_inside_another_phrase_is_not_that_side(phrase, partner):
    assert not redflags.check_conversation(phrase, history_of(partner)).emergency
    assert not redflags.check_conversation(partner, history_of(phrase)).emergency


@pytest.mark.parametrize(
    ("first", "second"),
    [
        ("I didn't vomit", "there was blood"),
        ("I haven't vomited", "there was blood"),
        ("she hasn't vomited", "there was blood"),
        ("I never vomit", "there was blood"),
        ("ما أرجع", "فيه دم"),
        ("أستفرغ", "ما فيه دم"),
        ("أستفرغ", "مافيه دم"),
    ],
)
def test_a_side_right_after_a_plain_denial_is_not_live(first, second):
    assert not redflags.check_conversation(second, history_of(first)).emergency


def test_the_reported_run_stops_at_chest(seeded, engine):
    """The sequence that reached issue_ticket: the last two answers are never asked."""
    visit_id = make_visit(seeded, ENGLISH)
    result = say(seeded, SIM, visit_id, "I have pain", "yesterday", "8", "chest")
    assert_stopped(seeded, engine, visit_id, result, "chest_pain")
    after = say(seeded, SIM, visit_id, "no", "no")
    assert after.emergency
    assert refused_a_ticket(seeded, engine, visit_id)


def test_a_compound_hit_uses_the_listed_labels():
    for row in redflags._COMPOUNDS:
        sides, category, label = row
        listed = [cue for cue in redflags.CUES if cue.label_en == label]
        assert listed, label
        assert category in {cue.category for cue in listed}, label
        assert set(sides) <= set(redflags._SIDES)


def test_a_compound_event_says_which_sides_met_and_no_patient_words(seeded):
    visit_id = make_visit(seeded, ENGLISH)
    say(seeded, SIM, visit_id, "private words pain", "my chest")
    hits = [payload for name, payload in event_rows(seeded, visit_id) if name == "redflag.hit"]
    assert hits == [{"category": "chest_pain", "cue": "pain + chest", "label": "chest pain"}]


@pytest.mark.parametrize(
    "text",
    [
        "chest", "my chest", "pain", "I am pregnant", "my baby", "heavy", "صدري", "حامل",
        "blood", "I vomited", "my throat", "my lips", "swollen", "my face", "drooping",
        "my speech", "slurred", "to my left arm", "دم", "ترجيع", "حلقي", "مايل", "ثقيل", "لذراعي",
    ],
)
def test_check_alone_keeps_its_behaviour(text):
    assert not redflags.check(text).emergency


def test_redflags_does_not_import_simulated():
    tree = ast.parse(Path(inspect.getfile(redflags)).read_text(encoding="utf-8"))
    names = [
        *(alias.name for node in ast.walk(tree) if isinstance(node, ast.Import) for alias in node.names),
        *(
            f"{node.module}.{alias.name}"
            for node in ast.walk(tree)
            if isinstance(node, ast.ImportFrom)
            for alias in node.names
        ),
    ]
    assert not [name for name in names if "simulated" in name]


def test_there_is_one_set_of_yes_words():
    assert simulated._YES_WORDS is redflags.YES_WORDS
    for word in ("yes", "yeah", "yep", "yup", "نعم", "اي", "ايوه", "ايه", "اكيد"):
        assert word in redflags.YES_WORDS


def question_history(question):
    return [
        {"role": "assistant", "content": simulated.OPENING["en"], "slot": "complaint"},
        {"role": "user", "content": "I feel unwell", "slot": None},
        {"role": "assistant", "content": question, "slot": None},
    ]


YES_CASES = [
    ("Do you have chest pain?", "yes", "chest_pain"),
    ("Do you have chest pain?", "Yes.", "chest_pain"),
    ("Do you have chest pain?", "yeah", "chest_pain"),
    ("Do you have chest pain?", "yep it started today", "chest_pain"),
    ("Is the pain in your chest?", "yes", "chest_pain"),
    ("Thanks. Is the pain in your chest?", "yes", "chest_pain"),
    ("Are you short of breath?", "yes", "breathing"),
    ("Have you fainted?", "yup", "consciousness"),
    ("Did you faint?", "yes", "consciousness"),
    ("Did you pass out?", "yes", "consciousness"),
    ("Are you pregnant and bleeding?", "yes", "pregnancy"),
    ("Do you want to hurt yourself?", "yes", "self_harm"),
    ("Do you want to end your life?", "yes", "self_harm"),
    ("عندك الم في الصدر؟", "ايوه", "chest_pain"),
    ("عندك ألم في الصدر؟", "نعم", "chest_pain"),
    ("هل الألم في صدرك؟", "اي", "chest_pain"),
    ("عندك ضيق تنفس؟", "إيوه", "breathing"),
    ("ما تقدر تتنفس؟", "إيوه", "breathing"),
    ("عندك نزيف؟", "أكيد", "bleeding"),
    ("أغمي عليك؟", "نعم", "consciousness"),
    ("وجهك مايل؟", "ايه", "stroke"),
    ("تبي تقتل نفسك؟", "ايه", "self_harm"),
    ("Is your throat swollen?", "yes", "allergy"),
    ("Does the pain go to your arm?", "yes", "chest_pain"),
    ("حلقك منتفخ؟", "نعم", "allergy"),
    ("هل الألم ينزل لفكك؟", "نعم", "chest_pain"),
]


def ask(conn, visit_id, patient, question):
    """Puts a question in the transcript, as a turn that showed it would have."""
    state = session._load_state(conn, visit_id, patient)
    state["messages"].append({"role": "assistant", "content": question, "slot": None})
    session._store_state(conn, visit_id, state)


@pytest.mark.parametrize("mode", ["simulated", "real"])
@pytest.mark.parametrize(("question", "answer", "category"), YES_CASES)
def test_a_yes_makes_the_question_the_patients_own_words(
    seeded, engine, mode, question, answer, category
):
    client = FakeChatClient([])
    ai = SIM if mode == "simulated" else real(client)
    visit_id = make_visit(seeded, ENGLISH)
    with db.transaction(seeded):
        ask(seeded, visit_id, {"preferred_lang": "en"}, question)
    result = say(seeded, ai, visit_id, answer)
    assert client.calls == []
    assert_stopped(seeded, engine, visit_id, result, category)
    assert result.self_harm is (category == "self_harm")


@pytest.mark.parametrize(
    ("patient", "first", "question", "answer"),
    [
        (ENGLISH, "I feel unwell", "Do you have chest pain?", "yes"),
        (ARABIC, "تعبان", "عندك الم في الصدر؟", "ايوه"),
    ],
)
def test_a_question_the_model_asked_counts_when_it_passed_the_gate(
    seeded, engine, patient, first, question, answer
):
    client = FakeChatClient([question])
    visit_id = make_visit(seeded, patient)
    assert say(seeded, real(client), visit_id, first).source == "model"
    result = say(seeded, real(client), visit_id, answer)
    assert len(client.calls) == 1
    assert_stopped(seeded, engine, visit_id, result, "chest_pain")


@pytest.mark.parametrize(
    ("patient", "first", "question", "answer"),
    [
        (ENGLISH, "I feel unwell", "Do you have chest pain?", "yes"),
        (ARABIC, "تعبان", "عندك الم في الصدر؟", "ايوه"),
    ],
)
def test_a_timeout_on_the_yes_never_gets_the_chance(seeded, engine, patient, first, question, answer):
    """The turn that used to fall back and carry on. The rule runs before the model."""
    client = FakeChatClient([question, TimeoutError("slow")])
    visit_id = make_visit(seeded, patient)
    say(seeded, real(client), visit_id, first)
    result = say(seeded, real(client), visit_id, answer)
    assert len(client.calls) == 1
    assert "ai.fallback" not in event_types(seeded, visit_id)
    assert_stopped(seeded, engine, visit_id, result, "chest_pain")


def test_a_fallback_question_then_a_split_cue_still_fires(seeded, engine):
    client = FakeChatClient([TimeoutError("slow"), TimeoutError("slow")])
    visit_id = make_visit(seeded, ENGLISH)
    say(seeded, real(client), visit_id, "I have pain", "yesterday")
    assert event_types(seeded, visit_id).count("ai.fallback") == 2
    result = say(seeded, real(client), visit_id, "my chest")
    assert len(client.calls) == 2
    assert_stopped(seeded, engine, visit_id, result, "chest_pain")


@pytest.mark.parametrize(
    ("asked", "answers", "category"),
    [
        (("Any pain?", "Where is it?"), ("I feel unwell", "yes", "my chest"), "chest_pain"),
        (("Are you pregnant?", "Anything else?"), ("I feel unwell", "yes", "I am bleeding"), "pregnancy"),
    ],
)
def test_an_earlier_yes_still_counts_on_a_later_turn(seeded, engine, asked, answers, category):
    visit_id = make_visit(seeded, ENGLISH)
    result = say(seeded, real(FakeChatClient(list(asked))), visit_id, *answers)
    assert_stopped(seeded, engine, visit_id, result, category)


FATIMA = ("عندي حرارة وكحة من ثلاث أيام", "٦", "بنادول", "لا")


def test_fatimas_demo_run_is_unchanged(seeded, engine):
    visit_id = make_visit(seeded, ARABIC)
    result = say(seeded, SIM, visit_id, *FATIMA)
    assert result.done and not result.emergency
    assert result.intake["service"] == "gp"
    assert result.intake["duration"] == "3 days"
    assert "redflag.hit" not in event_types(seeded, visit_id)
    assert engine.issue_ticket(visit_id, TRIAGE).state == "reserved"


@pytest.mark.parametrize(
    "text",
    ["I need my usual blood pressure pills", "I need my usual blood pressure tablets.", "أبي حبوب الضغط المعتادة"],
)
def test_ahmeds_refill_is_unchanged(seeded, text):
    visit_id = make_visit(seeded, AHMED)
    result = say(seeded, SIM, visit_id, text)
    assert result.refill == {"medicine": "amlodipine 5 mg once daily"}
    assert visit_status(seeded, visit_id) == "deflected_refill"
    assert "redflag.hit" not in event_types(seeded, visit_id)


@pytest.mark.parametrize(
    ("patient", "text"),
    [(ENGLISH, "Chest pain going to my left arm."), (ARABIC, "عندي ألم في صدري يمتد إلى ذراعي")],
)
def test_ravis_emergency_is_unchanged(seeded, engine, patient, text):
    visit_id = make_visit(seeded, patient)
    assert_stopped(seeded, engine, visit_id, say(seeded, SIM, visit_id, text), "chest_pain")


QUIET_SEQUENCES = [
    ("no vomiting", "blood test"),
    ("no vomiting", "there was blood"),
    ("I need a blood test", "I vomited"),
    ("I vomited", "I need a blood test"),
    ("I need blood tests", "I vomited"),
    ("blood pressure tablets", "I vomited"),
    ("my blood sugar is high", "I vomited"),
    ("I vomited, no blood",),
    ("I vomited without blood",),
    ("I vomited", "no blood"),
    ("no blood", "I vomited"),
    ("ما في ترجيع", "تحليل دم"),
    ("ما في ترجيع", "فيه دم"),
    ("أستفرغ", "تحليل دم"),
    ("أستفرغ", "فحص الدم"),
    ("أستفرغ", "تحاليل الدم"),
    ("أستفرغ", "ضغط الدم"),
    ("أستفرغ", "ضغط دم"),
    ("أستفرغ", "سكر الدم"),
    ("أستفرغ", "ما في دم"),
    ("أستفرغ", "ما فيه دم"),
    ("I have pain", "my left arm"),
    ("I have pain", "my arm"),
    ("I have pain", "my jaw"),
    ("I have pain", "left arm"),
    ("I have pain", "in my left arm"),
    ("my arm hurts", "for 2 days"),
    ("my left arm hurts",),
    ("عندي ألم", "ذراعي"),
    ("عندي ألم", "يدي"),
    ("عندي ألم", "فكي"),
    ("عندي ألم", "في يدي"),
    ("no pain", "to my left arm"),
    ("I have pain", "not to my arm"),
    ("no pain to my arm", "I have pain in my leg"),
    ("no pain going all the way down my arm", "I have pain in my leg"),
    ("ما عندي ألم", "لذراعي"),
    ("عندي ألم", "مو لذراعي"),
    ("no swelling", "my throat"),
    ("my throat", "no swelling"),
    ("I have swelling", "not my throat"),
    ("I have swelling", "not in my lips"),
    ("I have swelling", "not on my lips"),
    ("no swelling in my throat", "my leg is swollen"),
    ("my leg is swollen", "no swelling in my throat"),
    ("no swelling on my lips", "my leg is swollen"),
    ("sore throat and swollen glands",),
    ("I have a sore throat", "my glands are swollen"),
    ("عندي ألم في الحلق وغدد منتفخة",),
    ("عندي التهاب الحلق", "الغدد متورمة"),
    ("ما في انتفاخ", "حلقي"),
    ("بدون تورم", "شفايفي"),
    ("عندي انتفاخ", "مو في حلقي"),
    ("no drooping", "my face"),
    ("my face", "it is not drooping"),
    ("no drooping on my face", "my eyelid is droopy"),
    ("my speech", "it is not slurred"),
    ("no slurring in my speech", "it is slurred on and off"),
    ("وجهي", "مو مايل"),
    ("ما في شي مايل", "وجهي"),
    ("كلامي", "مو ثقيل"),
    ("no chest pain, I have stomach pain",),
    ("I hurt", "for 2 days", "5", "in my side"),
    ("no bleeding", "I am pregnant"),
    ("I am pregnant", "no"),
    ("I am pregnant", "I have no bleeding"),
    ("no pain", "my chest feels fine"),
    ("no pain in my chest", "I have stomach pain"),
    ("I have stomach pain", "no pain in my chest"),
    ("I have stomach pain", "not in my chest"),
    ("I have stomach pain", "not my chest"),
    ("I have blood pressure", "and a chest cold"),
    ("I have pain", "no chest"),
    ("I have a headache", "for 2 days"),
    ("I am pregnant", "not severe pain"),
    ("I have pain", "not severe", "I am pregnant"),
    ("I am bleeding", "not heavy"),
    ("my baby", "no fever"),
    ("my baby has a fever", "not high"),
    ("my baby is sleepy",),
    ("my baby", "she is feeding well"),
    ("no baby", "not feeding"),
    ("my son has a high fever",),
    ("my son", "not eating"),
    ("ولدي", "حرارة عالية"),
    ("ما عندي ألم في الصدر، عندي ألم في البطن",),
    ("عندي صداع", "مو في صدري"),
    ("ما عندي نزيف", "أنا حامل"),
    ("أنا حامل", "لا"),
    ("I can't move",),
    ("I cannot move",),
    ("ما أقدر أحرك",),
    ("my arm",),
    ("يدي",),
    ("I can't move", "it is not my arm"),
    ("I can't move", "it is not my left arm"),
    ("I can't move", "it is not my right arm"),
    ("I can't move", "it is not my leg"),
    ("I can't move", "it is not my left leg"),
    ("I can't move", "it is not my right leg"),
    ("I can't move", "not in my arm"),
    ("I can't move", "not on my leg"),
    ("I can't move", "no arm"),
    ("ما أقدر أحرك", "مو يدي"),
    ("ما أقدر أحرك", "ما يدي"),
    ("ضيق",),
    ("عندي ضيق",),
    ("في التنفس",),
    ("ما عندي ضيق", "في التنفس"),
    ("ما في ضيق", "في التنفس"),
    ("ما في ضيق تنفس",),
    ("ما في ضيق تنفس", "عندي ضيق"),
    ("ما عندي أي ضيق في التنفس", "عندي ضيق"),  # past the 3 word window, only the row denies it
    ("ما في ضيق شديد في التنفس", "عندي ضيق"),
    ("عندي ضيق", "ما في تنفس"),
    ("عندي ضيق", "مو في التنفس"),
]


@pytest.mark.parametrize("messages", QUIET_SEQUENCES, ids=[" / ".join(m) for m in QUIET_SEQUENCES])
def test_a_live_pair_is_needed_to_fire(seeded, messages):
    visit_id = make_visit(seeded, ENGLISH)
    result = say(seeded, SIM, visit_id, *messages)
    assert not result.emergency
    assert visit_status(seeded, visit_id) == "intake"
    assert "redflag.hit" not in event_types(seeded, visit_id)


@pytest.mark.parametrize("messages", QUIET_SEQUENCES, ids=[" / ".join(m) for m in QUIET_SEQUENCES])
def test_a_live_pair_is_needed_on_the_real_path(seeded, messages):
    client = model_questions(len(messages))
    visit_id = make_visit(seeded, ENGLISH)
    result = say(seeded, real(client), visit_id, *messages)
    assert not result.emergency
    assert len(client.calls) == len(messages)


def test_a_denial_stays_when_the_stomach_is_the_pain(seeded):
    visit_id = make_visit(seeded, ENGLISH)
    result = say(seeded, SIM, visit_id, "no chest pain, I have stomach pain")
    assert result.denied == ["chest pain"]
    assert session.history(seeded, visit_id)["denied"] == ["chest pain"]


@pytest.mark.parametrize(
    ("question", "answer"),
    [
        ("Do you have chest pain?", "no"),
        ("Do you have chest pain?", "لا"),
        ("Do you have a fever?", "yes"),
        ("عندك حرارة؟", "ايوه"),
        ("Do you have chest pain?", "not sure"),
        ("Since when?", "yes"),
    ],
)
def test_no_is_not_yes_and_a_fever_is_not_a_red_flag(question, answer):
    client = FakeChatClient(["Since when?"])
    llm = Llm(mode="real", model_id="test", client=client)
    result = receptionist.run_turn(llm, answer, question_history(question), RECORD)
    assert not result.emergency
    assert len(client.calls) == 1


def dialogue(conn, ai, visit_id, turns):
    """Each turn is a question, as the transcript would show it, and the reply."""
    result = None
    for question, answer in turns:
        with db.transaction(conn):
            ask(conn, visit_id, {"preferred_lang": "en"}, question)
        result = session.handle_message(conn, ai, visit_id, answer)
    return result


ANY_VOMITING = simulated.FOLLOW_UPS["vomiting"]["en"]
ANY_VOMITING_AR = simulated.FOLLOW_UPS["vomiting"]["ar"]
WHERE_PAIN = simulated.FOLLOW_UPS["pain"]["en"]
WHERE_PAIN_AR = simulated.FOLLOW_UPS["pain"]["ar"]
STOMACH = ("I have stomach pain", "for 2 days", "5")
STOMACH_AR = ("عندي ألم في البطن", "يومين", "5")

ANSWERS_WITHOUT_A_YES = [
    (ANY_VOMITING, "blood"),
    (ANY_VOMITING, "blood in it"),
    (ANY_VOMITING, "a little blood"),
    (ANY_VOMITING, "not sure, there was blood"),
    (ANY_VOMITING, "no idea, there was blood"),
    (ANY_VOMITING, "no clue, there was blood"),
    ("Did you vomit?", "blood"),
    (ANY_VOMITING_AR, "فيه دم"),
    (ANY_VOMITING_AR, "دم"),
    (ANY_VOMITING_AR, "مع دم"),
    (ANY_VOMITING_AR, "مو كثير بس فيه دم"),
    (ANY_VOMITING_AR, "لا أدري، فيه دم"),
    (ANY_VOMITING_AR, "لا أعرف، فيه دم"),
    (ANY_VOMITING_AR, "لا أعلم، فيه دم"),
    ("ترجع؟", "دم"),
    ("تستفرغ؟", "فيه دم"),
]


@pytest.mark.parametrize("mode", ["simulated", "real"])
@pytest.mark.parametrize(("question", "answer"), ANSWERS_WITHOUT_A_YES)
def test_a_vomiting_question_is_the_other_half_of_blood(seeded, engine, mode, question, answer):
    client = FakeChatClient([])
    ai = SIM if mode == "simulated" else real(client)
    visit_id = make_visit(seeded, ENGLISH)
    result = dialogue(seeded, ai, visit_id, [(question, answer)])
    assert client.calls == []
    assert_stopped(seeded, engine, visit_id, result, "bleeding")


@pytest.mark.parametrize(
    ("patient", "first", "asked", "answer"),
    [
        (ENGLISH, STOMACH, ANY_VOMITING, "blood"),
        (ARABIC, STOMACH_AR, ANY_VOMITING_AR, "فيه دم"),
    ],
)
def test_the_simulated_vomiting_question_then_blood(seeded, engine, patient, first, asked, answer):
    visit_id = make_visit(seeded, patient)
    assert say(seeded, SIM, visit_id, *first).reply == asked
    assert_stopped(seeded, engine, visit_id, say(seeded, SIM, visit_id, answer), "bleeding")


@pytest.mark.parametrize(
    ("patient", "first", "asked", "answer"),
    [
        (ENGLISH, "I feel unwell", ANY_VOMITING, "blood"),
        (ARABIC, "تعبان", ANY_VOMITING_AR, "فيه دم"),
    ],
)
def test_the_models_vomiting_question_then_blood(seeded, engine, patient, first, asked, answer):
    """The question reaches the patient through the gate, so its other half counts."""
    client = FakeChatClient([asked])
    visit_id = make_visit(seeded, patient)
    assert say(seeded, real(client), visit_id, first).source == "model"
    result = say(seeded, real(client), visit_id, answer)
    assert len(client.calls) == 1
    assert_stopped(seeded, engine, visit_id, result, "bleeding")


@pytest.mark.parametrize(
    ("patient", "first", "asked", "answer", "category", "label"),
    [
        (ENGLISH, "I have swelling", "Where is the swelling?", "my throat", "allergy", "throat swelling"),
        (ENGLISH, "I have swelling", "Where is the swelling?", "my lips", "allergy", "lip swelling"),
        (ENGLISH, "I am swollen", "Where is the swelling?", "my tongue", "allergy", "throat swelling"),
        (ARABIC, "عندي انتفاخ", "وين الانتفاخ؟", "حلقي", "allergy", "throat swelling"),
        (ARABIC, "عندي تورم", "وين التورم؟", "شفايفي", "allergy", "lip swelling"),
        (ENGLISH, "I have pain", WHERE_PAIN, "down my left arm", "chest_pain", "pain spreading to arm or jaw"),
        (ENGLISH, "I have pain", WHERE_PAIN, "to my jaw", "chest_pain", "pain spreading to arm or jaw"),
        (ARABIC, "عندي ألم", WHERE_PAIN_AR, "يمتد إلى ذراعي", "chest_pain", "pain spreading to arm or jaw"),
        (ARABIC, "عندي ألم", WHERE_PAIN_AR, "لفكي", "chest_pain", "pain spreading to arm or jaw"),
        (ENGLISH, "I can't move", "Since when?", "my arm", "stroke", "unable to move arm"),
        (ENGLISH, "my arm", "Since when?", "I can't move it", "stroke", "unable to move arm"),
        (ARABIC, "ما أقدر أحرك", "من متى؟", "يدي", "stroke", "unable to move arm"),
        (ARABIC, "يدي", "من متى؟", "ما أقدر أحركها", "stroke", "unable to move arm"),
        (ARABIC, "عندي ضيق", "وين الضيق؟", "في التنفس", "breathing", "shortness of breath"),
        (ARABIC, "ضيق", "من متى؟", "بالتنفس من أمس", "breathing", "shortness of breath"),
    ],
)
def test_the_patient_named_one_half_and_the_model_asked_where(
    seeded, engine, patient, first, asked, answer, category, label
):
    client = FakeChatClient([asked])
    visit_id = make_visit(seeded, patient)
    opened = say(seeded, real(client), visit_id, first)
    assert (opened.source, opened.reply) == ("model", asked)
    result = say(seeded, real(client), visit_id, answer)
    assert len(client.calls) == 1
    assert_stopped(seeded, engine, visit_id, result, category)
    hits = [p["label"] for name, p in event_rows(seeded, visit_id) if name == "redflag.hit"]
    assert hits == [label]


@pytest.mark.parametrize(
    ("patient", "first", "answer"),
    [
        (ENGLISH, ("I have pain", "yesterday", "8"), "down my left arm"),
        (ARABIC, ("عندي ألم", "أمس", "8"), "ينزل لذراعي"),
    ],
)
def test_the_simulated_where_question_then_spreading(seeded, engine, patient, first, answer):
    visit_id = make_visit(seeded, patient)
    asked = say(seeded, SIM, visit_id, *first).reply
    assert asked == simulated.FOLLOW_UPS["pain"]["en" if patient == ENGLISH else "ar"]
    assert_stopped(seeded, engine, visit_id, say(seeded, SIM, visit_id, answer), "chest_pain")


QUIET_ANSWERS = [
    ((ANY_VOMITING, "no"),),
    ((ANY_VOMITING, "nope"), ("Since when?", "there was blood")),
    ((ANY_VOMITING, "nah"), ("Since when?", "there was blood")),
    ((ANY_VOMITING, "none"), ("Since when?", "there was blood")),
    ((ANY_VOMITING, "never"), ("Since when?", "there was blood")),
    ((ANY_VOMITING, "not at all"), ("Since when?", "there was blood")),
    ((ANY_VOMITING, "no blood"),),
    ((ANY_VOMITING, "no"), ("Since when?", "there was blood")),
    ((ANY_VOMITING, "not really"), ("Since when?", "there was blood")),
    ((ANY_VOMITING, "I have no vomiting, there is blood in my stool"),),
    ((ANY_VOMITING, "yes, no blood"),),
    ((ANY_VOMITING, "I need a blood test"),),
    ((ANY_VOMITING, "blood pressure tablets"),),
    ((ANY_VOMITING, "blood sugar"),),
    ((ANY_VOMITING, "I didn't vomit"), ("Since when?", "there was blood")),
    ((ANY_VOMITING_AR, "لا"),),
    ((ANY_VOMITING_AR, "لا"), ("من متى؟", "فيه دم")),
    ((ANY_VOMITING_AR, "أبدا"), ("من متى؟", "فيه دم")),
    ((ANY_VOMITING_AR, "كلا"), ("من متى؟", "فيه دم")),
    ((ANY_VOMITING_AR, "مافي"), ("من متى؟", "فيه دم")),
    ((ANY_VOMITING_AR, "ما في"), ("من متى؟", "فيه دم")),
    ((ANY_VOMITING_AR, "مافيه"), ("من متى؟", "فيه دم")),
    ((ANY_VOMITING_AR, "ما فيه"), ("من متى؟", "فيه دم")),
    ((ANY_VOMITING_AR, "ما عندي"), ("من متى؟", "فيه دم")),
    ((ANY_VOMITING_AR, "ولا شي"), ("من متى؟", "فيه دم")),
    ((ANY_VOMITING_AR, "ولا شيء"), ("من متى؟", "فيه دم")),
    ((ANY_VOMITING_AR, "ما في دم"),),
    ((ANY_VOMITING_AR, "ما فيه دم"),),
    ((ANY_VOMITING_AR, "مافيه دم"),),
    ((ANY_VOMITING_AR, "بدون دم"),),
    ((ANY_VOMITING_AR, "ما عندي دم"),),
    ((ANY_VOMITING_AR, "ما أرجع"), ("من متى؟", "فيه دم")),
    ((ANY_VOMITING_AR, "ما في"), ("من متى؟", "تحليل دم")),
    ((ANY_VOMITING_AR, "ضغط الدم"),),
    ((ANY_VOMITING_AR, "سكر الدم"),),
    ((ANY_VOMITING_AR, "تحليل دم"),),
    (("Is the pain in your chest?", "it is in my stomach"),),
    (("Is the swelling in your throat?", "it is in my knee"),),
    (("Where is the pain?", "my left arm"),),
    (("Where is the pain?", "my arm"),),
    (("Where is the pain?", "يدي"),),
    ((WHERE_PAIN, "my arm"),),
    ((WHERE_PAIN_AR, "يدي"),),
]


def show_turns(turns):
    return " / ".join(f"{question} -> {answer}" for question, answer in turns)


@pytest.mark.parametrize("mode", ["simulated", "real"])
@pytest.mark.parametrize("turns", QUIET_ANSWERS, ids=[show_turns(t) for t in QUIET_ANSWERS])
def test_a_question_alone_does_not_complete_a_pair(seeded, mode, turns):
    client = model_questions(len(turns))
    ai = SIM if mode == "simulated" else real(client)
    visit_id = make_visit(seeded, ENGLISH)
    result = dialogue(seeded, ai, visit_id, turns)
    assert not result.emergency
    assert visit_status(seeded, visit_id) == "intake"
    assert "redflag.hit" not in event_types(seeded, visit_id)


def test_a_question_the_gate_refused_is_not_the_other_half(seeded):
    """The patient never saw it, so "blood" answers the fallback question instead."""
    client = FakeChatClient(["Any vomiting or zorblax?", "Since when?"])
    visit_id = make_visit(seeded, ENGLISH)
    refused = say(seeded, real(client), visit_id, "I feel unwell")
    assert refused.source == "simulated"
    assert not say(seeded, real(client), visit_id, "there was blood").emergency


def test_an_early_vomiting_answer_still_counts_later(seeded, engine):
    visit_id = make_visit(seeded, ENGLISH)
    assert not dialogue(seeded, SIM, visit_id, [(ANY_VOMITING, "sometimes")]).emergency
    result = say(seeded, SIM, visit_id, "there was blood")
    assert_stopped(seeded, engine, visit_id, result, "bleeding")


def test_an_old_cue_question_does_not_carry_past_its_no(seeded):
    client = FakeChatClient(["Do you have chest pain?", "Any fever?", "Since when?"])
    visit_id = make_visit(seeded, ENGLISH)
    result = say(seeded, real(client), visit_id, "I feel unwell", "no", "yes")
    assert not result.emergency


# A listed cue said across a question and its answer. Only the question names one side.
QUESTION_NAMED_THE_OTHER_HALF = [
    ("Any swelling?", "my throat", "allergy"),
    ("Any vomiting or swelling?", "my throat", "allergy"),
    ("Any blood?", "I vomited", "bleeding"),
    ("Any drooping?", "my face", "stroke"),
    ("Any trouble with your speech?", "slurred", "stroke"),
    ("Any pain?", "to my left arm", "chest_pain"),
]


@pytest.mark.parametrize("mode", ["simulated", "real"])
@pytest.mark.parametrize(("question", "answer", "category"), QUESTION_NAMED_THE_OTHER_HALF)
def test_a_question_and_its_answer_can_hold_the_two_sides(
    seeded, engine, mode, question, answer, category
):
    client = FakeChatClient([])
    ai = SIM if mode == "simulated" else real(client)
    visit_id = make_visit(seeded, ENGLISH)
    result = dialogue(seeded, ai, visit_id, [(question, answer)])
    assert client.calls == []
    assert_stopped(seeded, engine, visit_id, result, category)


SCRIPTED_QUESTIONS = [
    (lang, entry[lang])
    for table in (simulated.QUESTIONS, simulated.FOLLOW_UPS)
    for entry in table.values()
    for lang in ("en", "ar")
]


def sides_raised_by(question):
    return redflags._live_sides(redflags._in_patient_voice(question))


def phrases_of(side, lang):
    phrases = (" ".join(phrase) for phrase in redflags._SIDES[side])
    return [phrase for phrase in phrases if has_arabic(phrase) == (lang == "ar")]


# Read from the live tables, so a new compound or a new scripted question is swept with
# no change here. Every order counts, because any remaining side can be the one left.
SCRIPTED_SPLITS = [
    (sides, category, label, lang, question, order)
    for sides, category, label in redflags._COMPOUNDS
    for lang, question in SCRIPTED_QUESTIONS
    if sides_raised_by(question) & set(sides)
    for order in permutations([s for s in sides if s not in sides_raised_by(question)])
    if order
]


def after_earlier_messages(earlier, question, lang):
    history = []
    for said in earlier:
        history += [
            {"role": "assistant", "content": simulated.OPENING[lang]},
            {"role": "user", "content": said},
        ]
    return [*history, {"role": "assistant", "content": question}]


def show_split(case):
    _, _, label, lang, question, order = case
    return f"{label} / {lang} / {question} / {'+'.join(order)}"


def test_the_sweep_reaches_every_scripted_question_that_raises_a_side():
    swept = {(label, question) for _, _, label, _, question, _ in SCRIPTED_SPLITS}
    expected = {
        (label, question)
        for label, entry in (
            ("baby with high fever", simulated.FOLLOW_UPS["fever"]),
            ("chest pain", simulated.FOLLOW_UPS["pain"]),
            ("pain spreading to arm or jaw", simulated.FOLLOW_UPS["pain"]),
            ("severe pain while pregnant", simulated.FOLLOW_UPS["pain"]),
            ("vomiting blood", simulated.FOLLOW_UPS["vomiting"]),
        )
        for question in entry.values()
    }
    assert expected <= swept


@pytest.mark.parametrize("case", SCRIPTED_SPLITS, ids=show_split)
def test_every_scripted_question_completes_its_compound_with_no_yes(case):
    _, _, label, lang, question, order = case
    phrases = [phrases_of(side, lang) for side in order]
    assert all(phrases), order
    for *earlier, reply in product(*phrases):
        assert not redflags.means_yes(tokenise(reply))
        result = redflags.check_conversation(
            reply, after_earlier_messages(earlier, question, lang)
        )
        assert label in {hit.label_en for hit in result.hits}, (earlier, reply)


@pytest.mark.parametrize("case", SCRIPTED_SPLITS, ids=show_split)
def test_a_scripted_split_ends_at_the_engine(seeded, engine, case):
    _, category, _, lang, question, order = case
    *earlier, reply = [phrases_of(side, lang)[0] for side in order]
    visit_id = make_visit(seeded, ENGLISH if lang == "en" else ARABIC)
    say(seeded, SIM, visit_id, *earlier)
    result = dialogue(seeded, SIM, visit_id, [(question, reply)])
    assert_stopped(seeded, engine, visit_id, result, category)


FEVER = simulated.FOLLOW_UPS["fever"]
BABY_RUN = {"en": ("my baby is sick", "today", "6"), "ar": ("طفلي مريض", "اليوم", "6")}
FEVER_ASKED = {"en": ("I am sick", "today", "6"), "ar": ("أنا مريض", "اليوم", "6")}
HIGH_ANSWERS = [
    ("en", "high"),
    ("en", "very high"),
    ("en", "it is high"),
    ("ar", "عالية"),
    ("ar", "عالية جدا"),
    ("ar", "مرتفعة"),
]


def assert_still_in_intake(conn, visit_id, result):
    assert not result.emergency
    assert visit_status(conn, visit_id) == "intake"
    assert "redflag.hit" not in event_types(conn, visit_id)


def at_question(conn, mode, lang, opening, asked, *more):
    """Runs the opening up to a scripted question, and proves the patient was asked it.

    `more` is what a real model says after that, one reply per message still to come.
    """
    lead = [simulated.QUESTIONS[slot][lang] for slot in ("duration", "severity")]
    client = FakeChatClient([*lead[: len(opening) - 1], asked, *more])
    ai = SIM if mode == "simulated" else real(client)
    visit_id = make_visit(conn, ENGLISH if lang == "en" else ARABIC)
    assert say(conn, ai, visit_id, *opening).reply == asked
    return ai, client, visit_id


@pytest.mark.parametrize("mode", ["simulated", "real"])
@pytest.mark.parametrize(("lang", "answer"), HIGH_ANSWERS)
def test_high_to_the_fever_question_stops_a_baby(seeded, engine, mode, lang, answer):
    ai, client, visit_id = at_question(seeded, mode, lang, BABY_RUN[lang], FEVER[lang])
    calls = len(client.calls)
    result = say(seeded, ai, visit_id, answer)
    assert len(client.calls) == calls
    assert_stopped(seeded, engine, visit_id, result, "infant")


@pytest.mark.parametrize("mode", ["simulated", "real"])
@pytest.mark.parametrize(
    ("lang", "high", "baby"),
    [("en", "high", "it is my baby"), ("ar", "عالية", "هذا طفلي")],
    ids=["en", "ar"],
)
def test_the_baby_named_on_a_later_turn_still_fires(seeded, engine, mode, lang, high, baby):
    ai, _, visit_id = at_question(
        seeded, mode, lang, FEVER_ASKED[lang], FEVER[lang], simulated.QUESTIONS["medicine"][lang]
    )
    assert not say(seeded, ai, visit_id, high).emergency
    assert visit_status(seeded, visit_id) == "intake"
    assert_stopped(seeded, engine, visit_id, say(seeded, ai, visit_id, baby), "infant")


@pytest.mark.parametrize("mode", ["simulated", "real"])
@pytest.mark.parametrize(
    ("lang", "sometimes", "high"),
    [("en", "sometimes", "it is high"), ("ar", "أحيانا", "عالية")],
    ids=["en", "ar"],
)
def test_a_bare_fever_answer_still_counts_when_high_comes_later(
    seeded, engine, mode, lang, sometimes, high
):
    """The reply names no side of the row, so only the question can hold the fever."""
    ai, _, visit_id = at_question(
        seeded, mode, lang, BABY_RUN[lang], FEVER[lang], simulated.QUESTIONS["medicine"][lang]
    )
    assert_still_in_intake(seeded, visit_id, say(seeded, ai, visit_id, sometimes))
    assert_stopped(seeded, engine, visit_id, say(seeded, ai, visit_id, high), "infant")


@pytest.mark.parametrize("mode", ["simulated", "real"])
@pytest.mark.parametrize(
    ("lang", "opening", "sometimes", "blood"),
    [("en", STOMACH, "sometimes", "there was blood"), ("ar", STOMACH_AR, "أحيانا", "فيه دم")],
    ids=["en", "ar"],
)
def test_blood_on_the_turn_after_a_bare_vomiting_answer(
    seeded, engine, mode, lang, opening, sometimes, blood
):
    ai, _, visit_id = at_question(
        seeded,
        mode,
        lang,
        opening,
        simulated.FOLLOW_UPS["vomiting"][lang],
        simulated.QUESTIONS["medicine"][lang],
    )
    assert not say(seeded, ai, visit_id, sometimes).emergency
    assert_stopped(seeded, engine, visit_id, say(seeded, ai, visit_id, blood), "bleeding")


@pytest.mark.parametrize("mode", ["simulated", "real"])
@pytest.mark.parametrize(
    ("turns", "last", "category"),
    [
        (((FEVER["en"], "sometimes"), (ANY_VOMITING, "sometimes")), "there was blood", "bleeding"),
        (((ANY_VOMITING, "sometimes"), (FEVER["en"], "sometimes")), "my baby, it is high", "infant"),
    ],
    ids=["fever_first", "vomiting_first"],
)
def test_one_raised_side_does_not_end_the_search_for_another(
    seeded, engine, mode, turns, last, category
):
    client = model_questions(len(turns))
    ai = SIM if mode == "simulated" else real(client)
    visit_id = make_visit(seeded, ENGLISH)
    assert not dialogue(seeded, ai, visit_id, turns).emergency
    assert_stopped(seeded, engine, visit_id, say(seeded, ai, visit_id, last), category)


@pytest.mark.parametrize("mode", ["simulated", "real"])
@pytest.mark.parametrize(
    ("lang", "first", "question", "answer"),
    [("en", "I feel ill", WHERE_PAIN, "chest"), ("ar", "تعبان", WHERE_PAIN_AR, "صدري")],
    ids=["en", "ar"],
)
def test_the_pain_question_then_the_place_fires_with_pain_never_said(
    seeded, engine, mode, lang, first, question, answer
):
    client = FakeChatClient([question])
    ai = SIM if mode == "simulated" else real(client)
    visit_id = make_visit(seeded, ENGLISH if lang == "en" else ARABIC)
    if mode == "simulated":
        say(seeded, ai, visit_id, first)
        result = dialogue(seeded, ai, visit_id, [(question, answer)])
    else:
        assert say(seeded, ai, visit_id, first).reply == question
        result = say(seeded, ai, visit_id, answer)
        assert len(client.calls) == 1
    assert_stopped(seeded, engine, visit_id, result, "chest_pain")


@pytest.mark.parametrize("mode", ["simulated", "real"])
@pytest.mark.parametrize(("lang", "answer"), [("en", "high"), ("ar", "عالية"), ("ar", "مرتفعة")])
def test_high_to_the_fever_question_is_a_normal_visit_for_an_adult(seeded, mode, lang, answer):
    ai, _, visit_id = at_question(
        seeded, mode, lang, FEVER_ASKED[lang], FEVER[lang], simulated.QUESTIONS["medicine"][lang]
    )
    assert_still_in_intake(seeded, visit_id, say(seeded, ai, visit_id, answer))


@pytest.mark.parametrize("mode", ["simulated", "real"])
@pytest.mark.parametrize(
    ("lang", "answer"),
    [
        ("en", "no"),
        ("ar", "لا"),
        ("en", "not high"),
        ("ar", "مو عالية"),
        ("en", "I don't have a fever, it is high"),
    ],
)
def test_a_baby_with_no_high_fever_stays_a_visit(seeded, mode, lang, answer):
    ai, _, visit_id = at_question(
        seeded, mode, lang, BABY_RUN[lang], FEVER[lang], simulated.QUESTIONS["medicine"][lang]
    )
    assert_still_in_intake(seeded, visit_id, say(seeded, ai, visit_id, answer))


REPLIES_THAT_COMPLETE_NOTHING = [
    ("Is the pain in your chest?", "the pain is in my stomach"),
    ("Is the pain in your chest?", "it is in my stomach"),
    (WHERE_PAIN, "my stomach"),
    (WHERE_PAIN_AR, "بطني"),
    (WHERE_PAIN, "not my chest"),
    (WHERE_PAIN, "my arm"),
    ("Any blood?", "no, I vomited"),
    ("Any blood?", "I vomited, no blood"),
]


@pytest.mark.parametrize("mode", ["simulated", "real"])
@pytest.mark.parametrize(("question", "answer"), REPLIES_THAT_COMPLETE_NOTHING)
def test_a_reply_must_add_a_side_of_its_own(seeded, mode, question, answer):
    client = model_questions(1)
    ai = SIM if mode == "simulated" else real(client)
    visit_id = make_visit(seeded, ENGLISH)
    result = dialogue(seeded, ai, visit_id, [(question, answer)])
    assert_still_in_intake(seeded, visit_id, result)


@pytest.mark.parametrize("mode", ["simulated", "real"])
@pytest.mark.parametrize("answer", ["نعم", "عالية"])
def test_fatima_answers_the_fever_question_and_stays_a_gp_visit(seeded, engine, mode, answer):
    """She is an adult, so a high fever is the demo's normal visit, not the baby row."""
    question = FEVER["ar"]
    visit_id = make_visit(seeded, ARABIC)
    if mode == "simulated":
        say(seeded, SIM, visit_id, FATIMA[0])
        assert not dialogue(seeded, SIM, visit_id, [(question, answer)]).emergency
        result = say(seeded, SIM, visit_id, *FATIMA[1:])
    else:
        client = FakeChatClient([question, model_intake(language="ar-gulf", duration="3 days")])
        assert say(seeded, real(client), visit_id, FATIMA[0]).reply == question
        result = say(seeded, real(client), visit_id, answer)
    assert result.done and not result.emergency
    assert result.intake["service"] == "gp"
    assert "redflag.hit" not in event_types(seeded, visit_id)
    assert engine.issue_ticket(visit_id, TRIAGE).state == "reserved"


def test_a_yes_to_a_denial_is_a_denial():
    result = receptionist.run_turn(
        Llm(mode="real", model_id="test", client=FakeChatClient(["Since when?"])),
        "yes",
        question_history("So no chest pain?"),
        RECORD,
    )
    assert not result.emergency
    assert result.denied == ["chest pain"]


@pytest.mark.parametrize("patient", [ENGLISH, ARABIC])
def test_a_yes_to_the_read_back_confirms_it_and_nothing_else(seeded, engine, patient):
    """The read-back ends in a question and names the denied cue just before it."""
    words = (
        ("no chest pain, I have stomach pain", "2 days", "5", "no", "no", "no")
        if patient == ENGLISH
        else ("ما عندي ألم في الصدر، عندي ألم في البطن", "يومين", "5", "لا", "لا", "لا")
    )
    visit_id = make_visit(seeded, patient)
    result = say(seeded, SIM, visit_id, *words)
    assert result.done
    assert "chest pain" in result.intake["denied_red_flags"]
    confirm = say(seeded, SIM, visit_id, "yes" if patient == ENGLISH else "ايوه")
    assert not confirm.emergency
    assert visit_status(seeded, visit_id) == "intake"
    assert engine.issue_ticket(visit_id, TRIAGE).state == "reserved"


def test_a_fired_label_leaves_denied(seeded):
    visit_id = make_visit(seeded, ENGLISH)
    first = say(seeded, SIM, visit_id, "no chest pain, I have a cough")
    assert first.denied == ["chest pain"]
    result = say(seeded, SIM, visit_id, "no i have chest pain")
    assert result.emergency
    assert result.denied == []
    assert session.history(seeded, visit_id)["denied"] == []
    assert session.history(seeded, visit_id)["last_turn"]["denied"] == []


def test_a_fired_label_leaves_denied_on_the_real_path(seeded):
    client = model_questions(1)
    visit_id = make_visit(seeded, ENGLISH)
    result = say(seeded, real(client), visit_id, "no chest pain, I have a cough", "no i have chest pain")
    assert result.denied == []
    assert session.history(seeded, visit_id)["denied"] == []


@pytest.mark.parametrize(
    ("denial", "pair", "label"),
    [
        ("no vomiting blood, I have a cough", ("I vomited", "there was blood"), "vomiting blood"),
        ("no pain to my arm, I have a cough", ("I have pain", "to my arm"), "pain spreading to arm or jaw"),
        ("no throat swelling, I have a cough", ("I have swelling", "my throat"), "throat swelling"),
        ("no lip swelling, I have a cough", ("I have swelling", "my lips"), "lip swelling"),
        ("no face drooping, I have a cough", ("my face", "drooping"), "facial drooping"),
        ("no slurred speech, I have a cough", ("my speech", "slurred"), "slurred speech"),
        ("no arm is numb, I have a cough", ("I can't move", "my arm"), "unable to move arm"),
        ("no sudden weakness, I have a cough", ("my arm", "I can't move it"), "unable to move arm"),
        ("ما في ضيق تنفس، عندي كحة", ("عندي ضيق", "في التنفس"), "shortness of breath"),
        ("no shortness of breath, I have a cough", ("ضيق", "بالتنفس"), "shortness of breath"),
    ],
)
def test_a_new_row_clears_its_denial_when_it_fires(seeded, engine, denial, pair, label):
    visit_id = make_visit(seeded, ENGLISH)
    assert say(seeded, SIM, visit_id, denial).denied == [label]
    result = say(seeded, SIM, visit_id, *pair)
    assert result.emergency
    assert result.denied == []
    assert session.history(seeded, visit_id)["denied"] == []
    assert refused_a_ticket(seeded, engine, visit_id)


@pytest.mark.parametrize("mode", ["simulated", "real"])
def test_a_denied_shortness_of_breath_stays_denied(seeded, mode):
    client = model_questions(1, "ar")
    ai = SIM if mode == "simulated" else real(client)
    visit_id = make_visit(seeded, ARABIC)
    result = say(seeded, ai, visit_id, "ما في ضيق تنفس")
    assert not result.emergency
    assert result.denied == ["shortness of breath"]
    assert visit_status(seeded, visit_id) == "intake"
    assert session.history(seeded, visit_id)["denied"] == ["shortness of breath"]


@pytest.mark.parametrize("text", ["ضيق في الصدر", "ضيقة في الصدر"])
def test_a_tight_chest_keeps_its_own_label(seeded, engine, text):
    """ضيق sits on two rows now, and only the chest one is met."""
    visit_id = make_visit(seeded, ARABIC)
    assert_stopped(seeded, engine, visit_id, say(seeded, SIM, visit_id, text), "chest_pain")
    labels = {p["label"] for name, p in event_rows(seeded, visit_id) if name == "redflag.hit"}
    assert labels == {"chest tightness", "chest pain"}


def test_a_vomiting_question_clears_the_denial_when_it_fires(seeded):
    visit_id = make_visit(seeded, ENGLISH)
    assert say(seeded, SIM, visit_id, "no vomiting blood, I have a cough").denied == ["vomiting blood"]
    result = dialogue(seeded, SIM, visit_id, [(ANY_VOMITING, "blood")])
    assert result.emergency
    assert session.history(seeded, visit_id)["denied"] == []


def test_a_compound_clears_the_label_it_fired(seeded):
    visit_id = make_visit(seeded, ENGLISH)
    say(seeded, SIM, visit_id, "no chest pain, I have a cough")
    result = say(seeded, SIM, visit_id, "I have pain in my chest area")
    assert result.emergency
    assert session.history(seeded, visit_id)["denied"] == []


def test_a_yes_clears_the_label_it_fired(seeded):
    client = FakeChatClient(["Do you have chest pain?"])
    visit_id = make_visit(seeded, ENGLISH)
    say(seeded, real(client), visit_id, "no chest pain, I have a cough")
    result = say(seeded, real(client), visit_id, "yes")
    assert result.emergency
    assert result.denied == []
    assert session.history(seeded, visit_id)["denied"] == []


def test_only_the_label_that_fired_leaves(seeded):
    visit_id = make_visit(seeded, ENGLISH)
    say(seeded, SIM, visit_id, "no chest pain and no choking")
    result = say(seeded, SIM, visit_id, "no i have chest pain")
    assert result.denied == ["choking"]
    assert session.history(seeded, visit_id)["denied"] == ["choking"]


def test_a_later_denial_cannot_bring_a_fired_label_back(seeded):
    visit_id = make_visit(seeded, ENGLISH)
    say(seeded, SIM, visit_id, "I have chest pain")
    result = say(seeded, SIM, visit_id, "no chest pain, I want to end my life")
    assert result.self_harm
    assert result.denied == []
    assert session.history(seeded, visit_id)["denied"] == []


def test_a_label_is_never_a_hit_and_denied_together():
    history = question_history("Do you have chest pain?")
    result = redflags.check_conversation("yes, no chest pain", history)
    assert result.emergency
    labels = {hit.label_en for hit in result.hits}
    assert not labels & {hit.label_en for hit in result.denied}


def test_a_refused_refill_message_can_complete_a_pair(seeded, engine):
    """A deflected visit runs rules only, so nothing else would remember the first half."""
    visit_id = make_visit(seeded, AHMED)
    say(seeded, SIM, visit_id, "I need my usual blood pressure pills")
    with pytest.raises(session.SessionError):
        say(seeded, SIM, visit_id, "I have pain")
    assert visit_status(seeded, visit_id) == "deflected_refill"
    client = FakeChatClient([])
    result = say(seeded, real(client), visit_id, "my chest")
    assert client.calls == []
    assert_stopped(seeded, engine, visit_id, result, "chest_pain")


def test_rule_emergency_reads_the_whole_conversation():
    history = [
        {"role": "user", "content": "I have pain", "slot": None},
        {"role": "assistant", "content": "Where?", "slot": None},
    ]
    hit = receptionist.rule_emergency("chest", history, RECORD)
    assert hit is not None and hit.emergency
    assert receptionist.rule_emergency("my side", history, RECORD) is None


def test_a_cue_after_the_intake_is_ready_still_stops_the_ticket(seeded, engine):
    visit_id = make_visit(seeded, ENGLISH)
    result = say(seeded, SIM, visit_id, "I hurt", "for 2 days", "5", "in my side", "no", "no")
    assert result.done
    after = say(seeded, SIM, visit_id, "also my chest")
    assert_stopped(seeded, engine, visit_id, after, "chest_pain")


class RacingClient(FakeChatClient):
    """Delivers a second message on its own connection while the model is thinking."""

    def __init__(self, replies, db_path, visit_id, message):
        super().__init__(replies)
        self.db_path, self.visit_id, self.message = db_path, visit_id, message

    def chat_completion(self, messages, **kw):
        if self.message:
            message, self.message = self.message, None
            other = db.connect(self.db_path)
            try:
                session.handle_message(other, SIM, self.visit_id, message)
            finally:
                other.close()
        return super().chat_completion(messages, **kw)


def test_the_other_half_landing_during_a_model_call_still_fires(seeded, engine, db_path):
    visit_id = make_visit(seeded, ENGLISH)
    seeded.commit()
    client = RacingClient(["Since when?"], db_path, visit_id, "my chest")
    result = say(seeded, real(client), visit_id, "I have pain")
    assert_stopped(seeded, engine, visit_id, result, "chest_pain")


def test_a_refused_message_is_kept_for_the_visit_that_goes_on(seeded, engine):
    visit_id = make_visit(seeded, AHMED)
    say(seeded, SIM, visit_id, "I need my usual blood pressure pills")
    with pytest.raises(session.SessionError):
        say(seeded, SIM, visit_id, "I have pain")
    session.continue_after_refill(seeded, visit_id)
    result = say(seeded, SIM, visit_id, "my chest")
    assert_stopped(seeded, engine, visit_id, result, "chest_pain")


# The gate. These words are on no list, and the first test proves it, so only the
# shape of the reply can refuse them.
INVENTED = ("zorblax", "plinzomab", "gravimorrhea", "tolvexin", "quendrix", "krimpitis")
INVENTED_AR = ("زوربلكس", "بلنزوماب", "كويندركس")
SHAPES = (
    "You have {w}.",
    "{w} is best.",
    "{w}",
    "{w}?",
    "You have {w}?",
    "Is it {w}?",
    "Is this {w}?",
    "Any {w}?",
    "Any fever or {w}?",
    "Do you have {w}?",
    "Did you take {w}?",
    "Are you on {w}?",
    "Have you had {w}?",
    "Have you tried {w}?",
    "How long have you had {w}?",
    "When did {w} start?",
    "Where is the {w}?",
    "Take {w}?",
    "How about {w}?",
    "Okay. {w} is best.",
    "Noted, {w}. Since when?",
    "Thanks, {w} helps. Since when?",
    "Since when? You have {w}.",
    "Since when? {w}",
    "Since when? ({w})",
    "Is {w} the problem?",
    "Has {w} started?",
    "Does {w} help?",
    "Is your {w} worse?",
    "What about {w}?",
    "Okay, {w}?",
    "Do you have a fever or a {w} rash?",
    "Are you taking {w} tablets?",
    "Sorry. You have {w}?",
)
SHAPES_AR = (
    "عندك {w}.",
    "{w} هو الأفضل.",
    "عندك {w}؟",
    "هل هو {w}؟",
    "هل عندك {w}؟",
    "في {w}؟",
    "أخذت {w}؟",
    "شكرا. {w} يفيدك.",
)
INVENTED_REPLIES = [
    *(shape.format(w=word) for word in INVENTED for shape in SHAPES),
    *(shape.format(w=word) for word in INVENTED_AR for shape in SHAPES_AR),
]


def source_of_the_ai_layer():
    return "\n".join(
        path.read_text(encoding="utf-8").lower()
        for path in Path(filters.__file__).parent.glob("*.py")
    )


@pytest.mark.parametrize("word", [*INVENTED, *INVENTED_AR])
def test_the_invented_words_are_on_no_list(word):
    assert word not in source_of_the_ai_layer()


@pytest.mark.parametrize("reply", INVENTED_REPLIES)
def test_the_gate_refuses_an_invented_word_by_shape(seeded, monkeypatch, reply):
    """Every filter is switched off, so nothing but the gate can be doing this."""
    monkeypatch.setattr(filters, "check_reply", lambda *a, **k: filters.FilterResult(True, ()))
    arabic = any("؀" <= letter <= "ۿ" for letter in reply)
    client = FakeChatClient([reply])
    visit_id = make_visit(seeded, ARABIC if arabic else ENGLISH)
    result = say(seeded, real(client), visit_id, "عندي كحة" if arabic else "I have a cough")
    assert result.source == "simulated"
    assert result.reply == simulated.QUESTIONS["duration"]["ar" if arabic else "en"]
    assert reply not in json.dumps(session.history(seeded, visit_id), ensure_ascii=False)
    reasons = [p["reason"] for name, p in event_rows(seeded, visit_id) if name == "ai.fallback"]
    assert reasons == ["bad_shape"]


# Every word here is one the gate allows, so only the frame can refuse them.
OUT_OF_SHAPE = (
    "You have a fever?",
    "It is bad?",
    "The pain is worse?",
    "What about the fever?",
    "What if it is bad?",
    "Do you know the doctor?",
)


@pytest.mark.parametrize("reply", OUT_OF_SHAPE)
def test_the_gate_refuses_allowed_words_in_the_wrong_frame(seeded, monkeypatch, reply):
    monkeypatch.setattr(filters, "check_reply", lambda *a, **k: filters.FilterResult(True, ()))
    visit_id = make_visit(seeded, ENGLISH)
    result = say(seeded, real(FakeChatClient([reply])), visit_id, "I have a cough")
    assert result.source == "simulated"
    assert reply not in json.dumps(session.history(seeded, visit_id), ensure_ascii=False)


@pytest.mark.parametrize("text", ["Since when?", "Thanks. Since when?", "من متى؟", "سلامتك، من متى؟"])
def test_the_gate_lets_a_plain_question_reach_the_patient(seeded, text):
    client = FakeChatClient([text])
    visit_id = make_visit(seeded, ENGLISH)
    result = say(seeded, real(client), visit_id, "I have a cough")
    assert result.source == "model"
    assert result.reply == text


def model_intake(**changes):
    return json.dumps(
        {
            "language": "en",
            "chief_complaint": "cough",
            "chief_complaint_patient_words": "x",
            "service": "gp",
            "service_confidence": 0.9,
            "summary_for_nurse": "34F, cough.",
            "questions_asked": 1,
            **changes,
        }
    )


def test_model_prose_never_reaches_the_patient(seeded):
    prose = model_intake(
        summary_for_nurse="34F, cough, plinzomab noted.",
        chief_complaint="plinzomab cough",
        patient_concerns="plinzomab",
        associated=["plinzomab"],
        self_medication=["plinzomab"],
    )
    visit_id = make_visit(seeded, ENGLISH)
    result = say(seeded, real(FakeChatClient([prose])), visit_id, "I have a cough for 2 days")
    assert result.done
    assert "plinzomab" not in result.reply
    assert "plinzomab" not in str(result.to_api())
    assert result.intake["self_medication"] == []


@pytest.mark.parametrize(
    ("duration", "spoken"),
    [("plinzomab", None), ("You have plinzomab", None), ("plinzomab for 2 days", "2 days")],
)
def test_the_read_back_takes_only_a_validated_duration(seeded, duration, spoken):
    visit_id = make_visit(seeded, ENGLISH)
    output = model_intake(duration=duration, severity_0_10=4)
    result = say(seeded, real(FakeChatClient([output])), visit_id, "I have a cough")
    assert result.done
    assert "plinzomab" not in result.reply
    assert "plinzomab" not in str(result.to_api())
    assert result.intake["duration"] == duration  # a nurse still reads the model's words
    if spoken:
        assert spoken in result.reply


def test_the_gate_holds_on_the_turn_the_question_cap_retries(seeded):
    """At the cap a reply is retried for intake, so prose gets a second way out."""
    client = FakeChatClient(["Since when?"] * 6 + ["You have zorblax."])
    visit_id = make_visit(seeded, ENGLISH)
    result = say(seeded, real(client), visit_id, *(f"detail {n}" for n in "abcdef"))
    assert len(client.calls) == 7  # five questions, the capped one, and the retry
    assert result.source == "simulated"
    assert "zorblax" not in json.dumps(session.history(seeded, visit_id), ensure_ascii=False)
    assert "ai.fallback" in event_types(seeded, visit_id)


def test_the_read_back_uses_the_patients_words_and_the_servers_medicines(seeded):
    visit_id = make_visit(seeded, ENGLISH)
    output = model_intake(chief_complaint="something else entirely", self_medication=[])
    result = say(seeded, real(FakeChatClient([output])), visit_id, "I have a cough, took paracetamol")
    assert result.intake["self_medication"] == ["paracetamol"]
    assert "cough" in result.reply
    assert "something else" not in result.reply
