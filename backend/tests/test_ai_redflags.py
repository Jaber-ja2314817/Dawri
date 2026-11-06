from __future__ import annotations

import re
from itertools import product
from pathlib import Path

import pytest

from backend.ai import redflags
from backend.ai.redflags import CATEGORIES, CUES, check, denied_text
from backend.ai.text import _NEGATORS, has_arabic, normalise, phrase_tokens

GUARDRAILS = (
    Path(__file__).resolve().parents[2]
    / "Dawri-Vault"
    / "04 AI"
    / "Safety Guardrails.md"
)
CATEGORY_BY_HEADING = {
    "Chest pain": "chest_pain",
    "Breathing": "breathing",
    "Stroke": "stroke",
    "Bleeding": "bleeding",
    "Consciousness": "consciousness",
    "Allergy": "allergy",
    "Pregnancy": "pregnancy",
    "Infant": "infant",
    "Self-harm": "self_harm",
}


def vault_cues():
    cues = []
    for line in GUARDRAILS.read_text(encoding="utf-8").splitlines():
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) != 3 or cells[0] not in CATEGORY_BY_HEADING:
            continue
        category = CATEGORY_BY_HEADING[cells[0]]
        for cell in cells[1:]:
            for cue in re.split("[,،]", cell):
                cue = cue.strip()
                if "left arm/jaw" in cue:
                    cues.append((category, cue.replace("left arm/jaw", "left arm")))
                    cues.append((category, cue.replace("left arm/jaw", "jaw")))
                    cues.append((category, cue.replace("left arm/jaw", "left jaw")))
                else:
                    cues.append((category, cue))
    return cues


def denied_labels(result):
    return [hit.label_en for hit in result.denied]


def hit_labels(result):
    return [hit.label_en for hit in result.hits]


def test_vault_table_was_parsed():
    cues = vault_cues()
    assert {category for category, _ in cues} == set(CATEGORIES)
    assert len(cues) >= 40


@pytest.mark.parametrize(("category", "cue"), vault_cues())
def test_every_vault_cue_fires_in_its_category(category, cue):
    result = check(cue)
    assert result.emergency
    assert category in result.categories


EXTENDED_CUES = [
    ("chest_pain", phrase)
    for phrase in (
        "chest pains",
        "pain in my chest",
        "pain in chest",
        "chest tightness",
        "pressure in my chest",
        "pain to my left arm",
        "pain to my jaw",
        "spreading to my left arm",
        "my chest hurts",
        "I think I'm having a heart attack",
        "الم بالصدر",
        "الم في صدري",
        "الم بصدري",
        "وجع في الصدر",
        "صدري يوجعني",
        "ضيقه بصدري",
    )
] + [
    ("breathing", phrase)
    for phrase in (
        "cannot breathe",
        "can not breathe",
        "cant breathe",
        "shortness of breath",
        "trouble breathing",
        "difficulty breathing",
        "ضيق في التنفس",
        "ضيق بالتنفس",
    )
] + [
    ("stroke", phrase)
    for phrase in (
        "can't move my arm",
        "cannot move my arm",
        "I'm having a stroke",
        "وجهي مائل",
    )
] + [
    ("bleeding", phrase)
    for phrase in ("throwing up blood", "coughing up blood", "استفراغ دم")
] + [
    ("consciousness", phrase)
    for phrase in ("seizures", "اغماء", "تشنجات", "اغمي عليه", "اغمي عليها")
] + [
    ("allergy", phrase)
    for phrase in ("swollen throat", "swollen lips", "تورم الشفاه")
] + [
    ("pregnancy", phrase)
    for phrase in ("pregnant and bleeding", "severe pain while pregnant")
] + [
    ("infant", phrase)
    for phrase in (
        "baby is not feeding",
        "baby isn't feeding",
        "my baby has a high fever",
        "البيبي ما يرضع",
    )
] + [
    ("self_harm", phrase)
    for phrase in (
        "kill myself",
        "suicide",
        "hurt myself",
        "ابغى اذي نفسي",
        "ابي اذي نفسي",
        "اؤذي نفسي",
        "انتحر",
        "انهي حياتي",
    )
]


@pytest.mark.parametrize(("category", "cue"), EXTENDED_CUES)
def test_extended_cue_fires(category, cue):
    assert category in check(cue).categories


INTENSE_CHEST_PAIN = [
    f"{pain} {intensity} {place}"
    for pain, intensity, place in product(
        ("ألم", "وجع"),
        ("شديد", "قوي", "حاد", "كبير", "فظيع"),
        ("في الصدر", "بالصدر", "في صدري", "بصدري"),
    )
]

RECALL_CUES = [
    ("chest_pain", phrase)
    for phrase in (
        *INTENSE_CHEST_PAIN,
        "عندي ألم شديد في الصدر",
        "وجع قوي في صدري",
        "ضيق في صدري",
        "ضيق بصدري",
        "ضيق في الصدر",
        "ضيق الصدر",
        "صدري ضيق",
        "صدري يألمني",
        "يؤلمني صدري",
        "pressure on my chest",
        "pressure on chest",
        "my chest feels tight",
        "chest feels tight",
        "chest is tight",
    )
] + [
    ("breathing", phrase)
    for phrase in (
        "can't breath",
        "cant breath",
        "cannot breath",
        "can not breath",
        "مقدر أتنفس",
        "ما قادرة أتنفس",
        "مو قادرة أتنفس",
        "hard to breath",
    )
] + [
    ("allergy", phrase)
    for phrase in (
        "throat is swollen",
        "my throat is swollen",
        "tongue is swollen",
        "lips are swollen",
        "my lips are swollen",
        "تورم في الحلق",
        "انتفاخ في الحلق",
        "تورم في الشفايف",
        "انتفاخ في الشفايف",
        "حلقي منتفخ",
        "حلقي متورم",
        "لساني منتفخ",
        "شفايفي منتفخة",
        "شفايفي متورمة",
        "شفتي منتفخة",
    )
] + [
    ("stroke", phrase) for phrase in ("يدي ما تتحرك", "إيدي ما تتحرك")
] + [
    ("pregnancy", phrase) for phrase in ("حامل وأنزف", "حامل وأنا أنزف")
] + [
    ("infant", phrase) for phrase in ("الرضيعة ما ترضع", "حرارة الرضيع عالية")
] + [
    ("self_harm", phrase)
    for phrase in (
        "don't want to live",
        "dont want to live",
        "do not want to live",
        "ما أبي أعيش",
        "ما أبغى أعيش",
    )
]


@pytest.mark.parametrize(("category", "cue"), RECALL_CUES)
def test_recall_cue_fires_in_its_category(category, cue):
    result = check(cue)
    assert result.emergency
    assert category in result.categories
    assert result.denied == ()


def test_recall_list_covers_every_intensity_row():
    assert len(INTENSE_CHEST_PAIN) == 40
    assert len(set(INTENSE_CHEST_PAIN)) == 40
    assert set(INTENSE_CHEST_PAIN) <= {phrase for _, phrase in RECALL_CUES}


NEVER_NEGATED_RECALL = [
    ("breathing", "no", "can't breath"),
    ("breathing", "no", "cant breath"),
    ("breathing", "no", "cannot breath"),
    ("breathing", "no", "can not breath"),
    ("breathing", "مو", "مقدر أتنفس"),
    ("breathing", "مو", "ما قادرة أتنفس"),
    ("breathing", "ما عندي", "مو قادرة أتنفس"),
    ("stroke", "مو", "يدي ما تتحرك"),
    ("stroke", "مو", "إيدي ما تتحرك"),
    ("infant", "مو", "الرضيعة ما ترضع"),
    ("self_harm", "no", "don't want to live"),
    ("self_harm", "no", "dont want to live"),
    ("self_harm", "no", "do not want to live"),
    ("self_harm", "مو", "ما أبي أعيش"),
    ("self_harm", "مو", "ما أبغى أعيش"),
]


@pytest.mark.parametrize(("category", "negator", "cue"), NEVER_NEGATED_RECALL)
def test_recall_cue_with_its_own_negator_fires_behind_another(
    category, negator, cue
):
    result = check(f"{negator} {cue}")
    assert category in result.categories
    assert result.denied == ()


@pytest.mark.parametrize(
    ("text", "label"),
    [
        ("ما عندي ألم شديد في الصدر", "chest pain"),
        ("ما عندي وجع قوي في صدري", "chest pain"),
        ("مافي ألم حاد بالصدر", "chest pain"),
        ("no pressure on my chest", "chest pain"),
        ("ما عندي ضيق في صدري", "chest tightness"),
        ("ما في ضيق الصدر", "chest tightness"),
        ("my chest is not tight", None),
        ("no swollen lips and my lips are not swollen", "lip swelling"),
        ("بدون تورم في الحلق", "throat swelling"),
        ("مو حرارة الرضيع عالية", "baby with high fever"),
        ("not hard to breath", "shortness of breath"),
    ],
)
def test_recall_cues_without_a_negator_inside_can_be_denied(text, label):
    result = check(text)
    assert not result.emergency
    assert denied_labels(result) == ([label] if label else [])


@pytest.mark.parametrize(
    "text",
    [
        "ما عندي حرارة، بس عندي ألم شديد في الصدر",
        "ما عندي حرارة وألم شديد في الصدر",
        "ما عندي حرارة ووجع قوي في صدري",
    ],
)
def test_intense_chest_pain_fires_in_a_new_clause(text):
    result = check(text)
    assert result.categories == ("chest_pain",)
    assert result.denied == ()


def test_intense_chest_pain_ignores_diacritics_and_tatweel():
    assert check("أَلَم شَدِيد في الصّدر").categories == ("chest_pain",)
    assert check("ألـــم قـــوي بصدري").categories == ("chest_pain",)


def test_intensity_gap_is_one_word_of_the_listed_set():
    assert not check("ألم في الظهر").emergency
    assert not check("ألم شديد في الظهر").emergency
    assert not check("ألم خفيف في الصدر").emergency
    assert not check("ألم شديد").emergency


def test_recall_cues_fire_inside_a_sentence():
    assert check("my throat is swollen since this morning").categories == (
        "allergy",
    )
    assert check("I can't breath at all").categories == ("breathing",)
    assert check("I really don't want to live anymore").self_harm
    assert check("ما أبي أعيش بعد اليوم").self_harm


@pytest.mark.parametrize(
    "text",
    [
        "no, I have chest pain",
        "no fever but chest pain",
        "no fever and chest pain",
        "no chest pain yesterday. chest pain now.",
        "no I can't breathe",
        "Chest pain spreading to my arm",
        "Chest pain going to my left arm.",
        "know chest pain",
        "no real history of any chest pain",
        "ما عندي حرارة، بس عندي ألم في الصدر",
        "ما عندي حرارة لكن ألم في الصدر",
        "ما عندي حرارة وألم في الصدر",
        "مو حرارة بس ضيق تنفس",
        "ما أقدر أتنفس",
        "أَلَم في الصّدر",
        "ألـــم في الصدر",
        "أغمى علي",
        "أغمي علي",
        "can’t breathe",
        "CHEST PAIN",
    ],
)
def test_fires(text):
    result = check(text)
    assert result.emergency
    assert not set(hit_labels(result)) & set(denied_labels(result))


@pytest.mark.parametrize(
    "text",
    [
        "no chest pain",
        "I don't have chest pain",
        "I don’t have any chest pain",
        "denies chest pain",
        "without chest pain",
        "no history of chest pain",
        "ما عندي ألم في الصدر",
        "مافي ألم في الصدر",
        "ما في ضيق تنفس",
        "مو ألم في الصدر",
        "بدون نزيف",
        "لا يوجد ألم في الصدر",
        "ليس عندي ألم في الصدر",
        "ما عندي حرارة ولا ألم في الصدر",
    ],
)
def test_denied_and_not_firing(text):
    result = check(text)
    assert not result.emergency
    assert len(result.denied) == 1


def test_denied_cue_and_fired_cue_in_one_message():
    result = check("no chest pain, short of breath")
    assert result.categories == ("breathing",)
    assert denied_labels(result) == ["chest pain"]


def test_label_that_fires_is_removed_from_denied():
    result = check("no chest pain yesterday. chest pain now.")
    assert hit_labels(result) == ["chest pain"]
    assert result.denied == ()


def test_different_cues_of_one_label_also_clear_denied():
    result = check("no chest pain, but pressure in my chest")
    assert hit_labels(result) == ["chest pain"]
    assert result.denied == ()


def test_hits_and_denied_are_deduplicated_by_label():
    assert len(check("chest pain, chest pain, pain in my chest").hits) == 1
    assert len(check("no chest pain. no chest pain").denied) == 1


def test_hit_carries_both_labels_and_category():
    hit = check("chest pain").hits[0]
    assert hit.category == "chest_pain"
    assert hit.cue == "chest pain"
    assert hit.label_en == "chest pain"
    assert hit.label_ar == "ألم في الصدر"


@pytest.mark.parametrize(
    "text",
    [
        "عندي حرارة وكحة من ثلاث أيام",
        "fever and cough for three days",
        "I have a high fever",
        "bleeding",
        "my gum is bleeding a little",
        "حرارة عالية",
        "fever",
        "cough",
        "I have a cough and a fever",
        "my lips are dry",
        "حرارة",
        "كحة",
        "عندي كحة",
        "حرارة الطفل",
        "حامل",
        "حامل وعندي كحة",
        "",
        "hello",
    ],
)
def test_ordinary_complaints_do_not_fire(text):
    assert not check(text).emergency


def test_no_bare_fever_or_bleeding_cue_in_the_table():
    assert not {"bleeding", "fever", "high fever"} & {cue.phrase for cue in CUES}


def test_a_cue_cannot_span_punctuation():
    assert not check("my chest, pain in my leg").emergency
    assert not check("chest. pain").emergency


def test_a_cue_with_and_inside_it_matches_across_the_clause_word():
    assert check("I am pregnant and bleeding").categories == ("pregnancy",)


@pytest.mark.parametrize(
    "text",
    ["عندي الم بالصدر", "والم في الصدر", "فالم في الصدر", "حراره عاليه للرضيع"],
)
def test_arabic_proclitics(text):
    assert check(text).emergency


def test_short_words_do_not_reduce_to_a_cue_token():
    assert not check("لم في الصدر").emergency


def test_waw_that_belongs_to_the_word_does_not_start_a_clause():
    result = check("ما عندي وجع في الصدر")
    assert not result.emergency
    assert denied_labels(result) == ["chest pain"]


def test_waw_proclitic_on_a_word_starting_with_waw_starts_a_clause():
    assert check("ما عندي حرارة ووجع في الصدر").emergency


def test_every_cue_with_a_negator_inside_is_never_negated():
    negators = {"not", "no", "can't", "cant", "cannot", "don't", "dont", "isn't",
                "isnt", "won't", "wont", "couldn't", "ما", "مو", "مش", "مقدر",
                "لا", "ماقدر", "ماني", "مب"}
    for cue in CUES:
        if cue.phrase in {"won't stop bleeding", "baby won't wake up"}:
            continue  # "won't" here is not a denial of the symptom
        if negators & set(phrase_tokens(cue.phrase)):
            assert cue.never_negated, cue.phrase


@pytest.mark.parametrize(
    "text",
    [
        "no I can't breathe",
        "no cannot move my arm",
        "not baby not feeding",
        "بدون ما أقدر أتنفس",
        "مو الطفل ما يرضع",
    ],
)
def test_never_negated_cues_fire_behind_a_negator(text):
    assert check(text).emergency


# (category, label_en, never_negated, phrases): rows added to close recall gaps.
GAP_ROWS = [
    (
        "chest_pain",
        "chest pain",
        False,
        (
            "آلام في الصدر",
            "آلام في صدري",
            "آلام بالصدر",
            "آلام بصدري",
            "آلام الصدر",
            "أوجاع في الصدر",
            "أوجاع في صدري",
            "أوجاع بالصدر",
            "أوجاع بصدري",
            "أوجاع الصدر",
            "آلام شديدة في الصدر",
            "أوجاع قوية في صدري",
            "آلام حادة بالصدر",
            "ألم شديد جدا في الصدر",
            "ألم قوي جدا في الصدر",
            "آلام شديدة جدا في الصدر",
            "صدري يعورني",
            "يعورني صدري",
            "صدري يعور",
            "chest ache",
            "chest aches",
            "my chest aches",
        ),
    ),
    (
        "chest_pain",
        "chest tightness",
        False,
        ("كتمة", "كتمة في صدري", "كتمة في الصدر", "كتمة بصدري"),
    ),
    (
        "chest_pain",
        "pain spreading to arm or jaw",
        False,
        (
            "spreading to my arm",
            "spreading to arm",
            "pain going to my arm",
            "pain going down my arm",
            "pain goes to my arm",
            "pain goes down my arm",
            "pain goes down my left arm",
            "pain down my left arm",
            "radiating to my arm",
        ),
    ),
    (
        "breathing",
        "shortness of breath",
        True,
        (
            "لا أستطيع التنفس",
            "لا أستطيع أن أتنفس",
            "لا أستطيع أتنفس",
            "لا أقدر أتنفس",
            "لا أقدر على التنفس",
            "ماقدر أتنفس",
            "ماني قادر أتنفس",
            "can barely breathe",
        ),
    ),
    (
        "breathing",
        "shortness of breath",
        False,
        ("struggling to breath", "out of breath", "breathless"),
    ),
    (
        "stroke",
        "unable to move arm",
        True,
        (
            "can't move my left arm",
            "can't move my right arm",
            "cannot move my left arm",
            "cannot move my right arm",
            "cant move my left arm",
            "لا أستطيع تحريك يدي",
            "لا أستطيع تحريك ذراعي",
            "لا أستطيع تحريك رجلي",
            "لا أقدر أحرك يدي",
        ),
    ),
    ("stroke", "slurred speech", True, ("ما أقدر أتكلم", "لا أستطيع الكلام")),
    (
        "stroke",
        "facial drooping",
        False,
        (
            "فمي مايل",
            "فمي مائل",
            "وجهي معوج",
            "my face is droopy",
            "face is droopy",
        ),
    ),
    ("bleeding", "heavy bleeding", False, ("أنزف", "نزف")),
    (
        "bleeding",
        "heavy bleeding",
        True,
        ("bleeding won't stop", "bleeding wont stop"),
    ),
    ("bleeding", "vomiting blood", False, ("أتقيأ دم", "تقيؤ دم", "قيء دم")),
    ("consciousness", "fainting", False, ("فقدان الوعي", "غبت عن الوعي")),
    ("consciousness", "seizure", False, ("نوبة صرع",)),
    (
        "allergy",
        "throat swelling",
        False,
        ("tongue is swelling", "my tongue is swelling", "throat is closing up"),
    ),
    ("allergy", "lip swelling", False, ("lips swelled up", "my lips swelled up")),
    (
        "pregnancy",
        "bleeding while pregnant",
        False,
        (
            "pregnant and i am bleeding",
            "pregnant and i'm bleeding",
            "i am bleeding and i am pregnant",
            "i'm bleeding and i'm pregnant",
            "bleeding and pregnant",
            "حامل ونزفت",
            "حامل ونزف",
        ),
    ),
    (
        "pregnancy",
        "severe pain while pregnant",
        False,
        ("pregnant and i have severe pain",),
    ),
    (
        "infant",
        "baby not feeding",
        True,
        (
            "ولدي ما يرضع",
            "بنتي ما ترضع",
            "رضيعي ما يرضع",
            "رضيعتي ما ترضع",
            "ولدي الرضيع ما يرضع",
            "بنتي الرضيعة ما ترضع",
        ),
    ),
    (
        "infant",
        "baby with high fever",
        False,
        (
            "رضيعي حرارته عالية",
            "حرارة رضيعي عالية",
            "الرضيعة عندها حرارة عالية",
            "newborn has a high fever",
            "newborn has high fever",
            "newborn with high fever",
            "infant has a high fever",
            "infant with high fever",
        ),
    ),
    (
        "self_harm",
        "thoughts of self-harm",
        False,
        ("ودي أموت", "want to end it all", "end it all"),
    ),
    (
        "self_harm",
        "thoughts of self-harm",
        True,
        (
            "don't want to be alive",
            "dont want to be alive",
            "do not want to be alive",
        ),
    ),
    (
        "self_harm",
        "possible overdose",
        False,
        (
            "overdose",
            "took an overdose",
            "took too many pills",
            "took too many tablets",
            "too many of my pills",
            "جرعة زائدة",
            "بلعت حبوب كثيرة",
            "بلعت كل الحبوب",
        ),
    ),
    ("self_harm", "thoughts of self-harm", False, ("بنتحر",)),
    (
        "self_harm",
        "thoughts of self-harm",
        True,
        ("no reason to live", "not worth living", "ما عندي سبب أعيش"),
    ),
    (
        "stroke",
        "possible stroke",
        False,
        ("having a stroke", "stroke", "a stroke", "جلطة", "سكتة"),
    ),
    ("stroke", "facial drooping", False, ("face drooped", "face is numb")),
    (
        "stroke",
        "unable to move arm",
        False,
        ("arm is numb", "numb on one side", "numbness on one side", "sudden weakness"),
    ),
    ("stroke", "slurred speech", True, ("can't speak", "cannot speak")),
    ("breathing", "shortness of breath", True, ("مب قادر أتنفس", "مب قادر اتنفس")),
    ("consciousness", "seizure", False, ("had a fit", "having a fit")),
    (
        "infant",
        "baby with high fever",
        False,
        ("newborn has a fever", "newborn with a fever"),
    ),
    (
        "pregnancy",
        "severe pain while pregnant",
        False,
        (
            "severe pain and pregnant",
            "severe stomach pain and pregnant",
            "severe stomach pain while pregnant",
        ),
    ),
]
GAP_CUES = [
    (category, label, never_negated, phrase)
    for category, label, never_negated, phrases in GAP_ROWS
    for phrase in phrases
]
GAP_NORMAL = [row for row in GAP_CUES if not row[2]]
GAP_NEVER_NEGATED = [row for row in GAP_CUES if row[2]]


def with_marks(phrase):
    """Put a fatha after each word's first letter and tatweel after its second."""
    return " ".join(
        f"{word[0]}\u064e{word[1]}\u0640{word[2:]}" if len(word) > 1 else word
        for word in phrase.split(" ")
    )


GAP_ARABIC = [row for row in GAP_CUES if has_arabic(row[3])]


def test_with_marks_changes_the_text_but_not_its_normal_form():
    assert with_marks("كتمة في صدري") != "كتمة في صدري"
    assert normalise(with_marks("كتمة في صدري")) == normalise("كتمة في صدري")


@pytest.mark.parametrize(("category", "label", "never_negated", "cue"), GAP_CUES)
def test_gap_cue_fires_in_its_category(category, label, never_negated, cue):
    result = check(cue)
    assert category in result.categories
    assert label in hit_labels(result)
    assert result.denied == ()


@pytest.mark.parametrize(("category", "label", "never_negated", "cue"), GAP_ARABIC)
def test_gap_cue_fires_with_diacritics_and_tatweel(
    category, label, never_negated, cue
):
    result = check(with_marks(cue))
    assert category in result.categories
    assert label in hit_labels(result)


@pytest.mark.parametrize(
    ("category", "text"),
    [
        ("chest_pain", "آلَام فِي الصَّدر"),
        ("chest_pain", "أَوْجَاع فِي صَدْرِي"),
        ("chest_pain", "أَلَمٌ شَدِيدٌ جِدًّا فِي الصَّدْرِ"),
        ("chest_pain", "صـــدري يعـــورني"),
        ("chest_pain", "كَتْمَة فِي صَدْرِي"),
        ("chest_pain", "كـــتـــمة"),
        ("breathing", "لَا أَسْتَطِيعُ التَّنَفُّس"),
        ("breathing", "ماني قـــادر أتنفس"),
        ("stroke", "فَمِي مَائِل"),
        ("stroke", "لا أستطيع الكـــلام"),
        ("bleeding", "أَنْزِف"),
        ("bleeding", "نَزْف"),
        ("bleeding", "قَيْء دَم"),
        ("bleeding", "تَقَيُّؤ دَم"),
        ("consciousness", "فِقْدَان الوَعْي"),
        ("consciousness", "نَوْبَة صَرَع"),
        ("pregnancy", "حَامِل ونَزَفْت"),
        ("infant", "رَضِيعِي مَا يَرْضَع"),
        ("infant", "حرارة رضـــيعي عـــالية"),
        ("self_harm", "وَدِّي أَمُوت"),
    ],
)
def test_gap_cue_fires_from_hand_written_marks(category, text):
    assert category in check(text).categories


@pytest.mark.parametrize(("category", "label", "never_negated", "cue"), GAP_CUES)
def test_gap_row_sits_in_the_stated_block(category, label, never_negated, cue):
    row = next(row for row in CUES if row.phrase == cue)
    assert (row.category, row.label_en, row.never_negated) == (
        category,
        label,
        never_negated,
    )


def test_a_cue_appears_only_once_in_the_table():
    phrases = [cue.phrase for cue in CUES]
    assert len(phrases) == len(set(phrases))


ALL_PAIN = ("ألم", "وجع", "آلام", "أوجاع")
ALL_INTENSITY = ("شديد", "قوي", "حاد", "كبير", "فظيع", "شديدة", "قوية", "حادة")
ALL_PLACES = ("في الصدر", "بالصدر", "في صدري", "بصدري")


def test_every_intense_chest_pain_form_fires_and_can_be_denied():
    for pain, intensity, very, place in product(
        ALL_PAIN, ALL_INTENSITY, ("", " جدا"), ALL_PLACES
    ):
        phrase = f"{pain} {intensity}{very} {place}"
        assert check(phrase).categories == ("chest_pain",), phrase
        denied = check(f"ما عندي {phrase}")
        assert not denied.emergency, phrase
        assert denied_labels(denied) == ["chest pain"], phrase


def test_existing_intense_rows_stay_first():
    assert list(redflags._INTENSE_CHEST_PAIN[:40]) == INTENSE_CHEST_PAIN


@pytest.mark.parametrize(
    ("label", "first_row"),
    [
        ("chest pain", "chest pain"),
        ("chest tightness", "chest tightness"),
        ("pain spreading to arm or jaw", "pain to left arm"),
        ("shortness of breath", "short of breath"),
        ("facial drooping", "face drooping"),
        ("unable to move arm", "can't move arm"),
        ("slurred speech", "slurred speech"),
        ("heavy bleeding", "heavy bleeding"),
        ("vomiting blood", "vomiting blood"),
        ("fainting", "fainted"),
        ("seizure", "seizure"),
        ("throat swelling", "throat swelling"),
        ("lip swelling", "lips swelling"),
        ("bleeding while pregnant", "bleeding while pregnant"),
        ("severe pain while pregnant", "severe pain pregnant"),
        ("baby not feeding", "baby not feeding"),
        ("baby with high fever", "baby with high fever"),
        ("thoughts of self-harm", "want to hurt myself"),
        ("possible overdose", "overdose"),
    ],
)
def test_existing_rows_stay_first_in_their_groups(label, first_row):
    assert next(cue for cue in CUES if cue.label_en == label).phrase == first_row


AFFIRMING_OPENERS = ("my ", "i am ", "i'm ")

# "ونزف" opens its own clause, so this row is checked in the test below it. A cue on
# an affirming opener is an affirmation after "no", so that row is checked further down.
GAP_DENIABLE = [
    row
    for row in GAP_NORMAL
    if row[3] != "حامل ونزف" and not row[3].startswith(AFFIRMING_OPENERS)
]
GAP_AFFIRMING = [row for row in GAP_NORMAL if row[3].startswith(AFFIRMING_OPENERS)]


@pytest.mark.parametrize(("category", "label", "never_negated", "cue"), GAP_DENIABLE)
def test_gap_normal_row_can_be_denied(category, label, never_negated, cue):
    negator = "بدون" if has_arabic(cue) else "no"
    result = check(f"{negator} {cue}")
    assert not result.emergency
    assert denied_labels(result) == [label]


def test_denying_pregnant_and_bleeding_leaves_the_bleeding_firing():
    result = check("مو حامل ونزف")
    assert result.categories == ("bleeding",)
    assert denied_labels(result) == ["bleeding while pregnant"]


@pytest.mark.parametrize(
    ("text", "label"),
    [
        ("ما عندي آلام في الصدر", "chest pain"),
        ("ما عندي أوجاع في صدري", "chest pain"),
        ("ما في آلام شديدة في الصدر", "chest pain"),
        ("ما عندي ألم شديد جدا في الصدر", "chest pain"),
        ("no chest ache", "chest pain"),
        ("I don't have chest aches", "chest pain"),
        ("ما عندي كتمة", "chest tightness"),
        ("ما عندي كتمة في صدري", "chest tightness"),
        ("بدون نزف", "heavy bleeding"),
        ("ما عندي نزف", "heavy bleeding"),
        ("ما عندي قيء دم", "vomiting blood"),
        ("ما عندي فقدان الوعي", "fainting"),
        ("ما عندي نوبة صرع", "seizure"),
        ("not out of breath", "shortness of breath"),
        ("I am not breathless", "shortness of breath"),
        ("ما عندي حرارة ولا كتمة", "chest tightness"),
    ],
)
def test_gap_cue_denied_in_a_sentence(text, label):
    result = check(text)
    assert not result.emergency
    assert hit_labels(result) == []
    assert denied_labels(result) == [label]


@pytest.mark.parametrize(
    ("category", "label", "never_negated", "cue"), GAP_NEVER_NEGATED
)
@pytest.mark.parametrize("negator", ["no", "not", "بدون", "مو", "ما عندي"])
def test_gap_never_negated_cue_fires_behind_a_negator(
    negator, category, label, never_negated, cue
):
    result = check(f"{negator} {cue}")
    assert category in result.categories
    assert result.denied == ()


@pytest.mark.parametrize(
    ("category", "text"),
    [
        ("chest_pain", "ما عندي حرارة، بس عندي آلام في الصدر"),
        ("chest_pain", "ما عندي حرارة وآلام في الصدر"),
        ("chest_pain", "ما عندي حرارة وكتمة في صدري"),
        ("chest_pain", "no fever but my chest aches"),
        ("chest_pain", "I have pain going down my arm"),
        ("breathing", "no fever and I am out of breath"),
        ("bleeding", "no fever but the bleeding won't stop"),
        ("stroke", "ما عندي حرارة بس فمي مايل"),
        ("self_harm", "sometimes I just want to end it all"),
        ("self_harm", "والله ودي أموت"),
        ("infant", "my newborn has a high fever"),
        ("infant", "ما عندي حرارة بس ولدي ما يرضع"),
        ("pregnancy", "I am pregnant and I have severe pain"),
        ("allergy", "my tongue is swelling since this morning"),
    ],
)
def test_gap_cue_fires_inside_a_sentence(category, text):
    assert category in check(text).categories


@pytest.mark.parametrize(
    "text",
    [
        "I have a cold",
        "fever",
        "cough",
        "حرارة",
        "كحة",
        "حامل",
        "عندي حرارة",
        "رضيعي عنده كحة",
        "ولدي عنده حرارة",
        "ما عندي حرارة",
        "my newborn has a cough",
        "the baby has a fever",
        "my arm hurts",
        "I am pregnant",
    ],
)
def test_ordinary_complaints_stay_quiet_after_the_gap_rows(text):
    assert not check(text).emergency


@pytest.mark.parametrize(
    "text",
    [
        "ما عندي غير ألم في الصدر",
        "ما عندي الا ألم في الصدر",
        "ما عندي إلا ألم في الصدر",
        "ليس فقط ألم في الصدر",
        "ما في غير ألم في الصدر",
        "مافي شي غير ضيق تنفس",
        "بدون سبب ألم في الصدر",
        "ما عندي دوا لألم في الصدر",
        "not only chest pain",
        "not just chest pain",
        "not sure if chest pain",
        "no doubt chest pain",
        "no idea chest pain",
        "no relief from chest pain",
        "no improvement in chest pain",
        "not getting better chest pain",
        "not only short of breath",
        "مَا عِنْدِي إِلَّا أَلَم فِي الصَّدْر",
        "ما عندي غـــير ألم في الصدر",
        "ما عندي سوى ألم في الصدر",
        "ما عندي دواء لألم في الصدر",
        "ما عندي علاج لألم في الصدر",
        "ما عندي حل لألم في الصدر",
        "ما عندي حرارة بسبب ألم في الصدر",
        "not certain if chest pain",
        "not helping chest pain",
        "no reason for chest pain",
        "no real history of any chest pain",
    ],
)
def test_exception_word_stops_a_false_denial(text):
    result = check(text)
    assert result.emergency
    assert not set(hit_labels(result)) & set(denied_labels(result))


@pytest.mark.parametrize(
    "text",
    [
        "no chest pain",
        "no more chest pain",
        "no history of chest pain",
        "ما عندي ألم في الصدر",
        "بدون نزيف",
        "no chest pain for three days",
        "just no chest pain",
    ],
)
def test_denial_without_an_exception_word_stands(text):
    result = check(text)
    assert not result.emergency
    assert len(result.denied) == 1


@pytest.mark.parametrize(
    ("text", "label"),
    [
        ("no stroke", "possible stroke"),
        ("I did not have a stroke", "possible stroke"),
        ("ما عندي جلطة", "possible stroke"),
        ("no overdose", "possible overdose"),
        ("I did not take an overdose", "possible overdose"),
        ("ما عندي جرعة زائدة", "possible overdose"),
    ],
)
def test_stroke_and_overdose_can_be_denied(text, label):
    result = check(text)
    assert not result.emergency
    assert denied_labels(result) == [label]


@pytest.mark.parametrize(
    "text",
    [
        "I took an overdose of my pills",
        "I took too many tablets this morning",
        "بلعت كل الحبوب",
        "بنتحر",
        "there is no reason to live",
        "life is not worth living",
        "ما عندي سبب أعيش",
    ],
)
def test_overdose_and_despair_reach_the_self_harm_path(text):
    result = check(text)
    assert result.self_harm
    assert result.emergency


def test_overdose_has_its_own_arabic_label():
    hit = check("overdose").hits[0]
    assert hit.label_ar == "جرعة زائدة محتملة"
    assert denied_text(["possible overdose"], "ar") == "المريض نفى: جرعة زائدة محتملة"


@pytest.mark.parametrize(
    ("category", "text"),
    [
        ("stroke", "I think my father is having a stroke"),
        ("stroke", "أبوي عنده جلطة"),
        ("stroke", "I can't speak properly"),
        ("stroke", "my arm is numb"),
        ("consciousness", "my son had a fit"),
        ("infant", "my newborn has a fever"),
        ("pregnancy", "I have severe stomach pain and pregnant"),
        ("breathing", "مب قادر أتنفس أبدا"),
    ],
)
def test_new_cues_fire_inside_a_sentence(category, text):
    assert category in check(text).categories


AFFIRMED_RED_FLAGS = [
    ("no i have chest pain", "chest pain"),
    ("yes no I have chest pain", "chest pain"),
    ("no my chest hurts", "chest pain"),
    ("no it's chest pain", "chest pain"),
    ("no i feel chest pain", "chest pain"),
    ("no im having chest pain", "chest pain"),
    ("no I have pain in my chest", "chest pain"),
    ("no i am short of breath", "shortness of breath"),
    ("no i fainted", "fainting"),
    ("no i am bleeding heavily", "heavy bleeding"),
    ("ما عندي حرارة عندي ألم في الصدر", "chest pain"),
    ("مافي حرارة عندي ضيق تنفس", "shortness of breath"),
    ("ما عندي حرارة وعندي ألم في الصدر", "chest pain"),
    ("ما عندي كحة احس ألم في الصدر", "chest pain"),
    ("no I’m having chest pain", "chest pain"),
    ("NO I HAVE CHEST PAIN", "chest pain"),
    ("no he has chest pain", "chest pain"),
    ("no she fainted", "fainting"),
    ("no we have chest pain", "chest pain"),
    ("no they fainted", "fainting"),
    ("no i've got chest pain", "chest pain"),
    ("no it is chest pain", "chest pain"),
    ("no i'm bleeding and i'm pregnant", "bleeding while pregnant"),
    ("no i am bleeding and i am pregnant", "bleeding while pregnant"),
    ("no my chest feels tight", "chest tightness"),
    ("no i had a stroke", "possible stroke"),
    ("ما عندي حرارة فيني ضيق تنفس", "shortness of breath"),
    ("ما عندي حرارة معي ألم في الصدر", "chest pain"),
    ("ما عندي حرارة أحس ألم في الصدر", "chest pain"),
    ("ما عندي حرارة أشعر ألم في الصدر", "chest pain"),
    ("ما عندي حرارة حاس ألم في الصدر", "chest pain"),
    ("ما عندي حرارة واحس ألم في الصدر", "chest pain"),
]
AFFIRMED_WITH_MARKS = [
    ("مَا عِنْدِي حَرَارَة عِنْدِي أَلَم فِي الصَّدْر", "chest pain"),
    ("ما عندي حرارة عـــندي ألـــم في الصدر", "chest pain"),
    ("ما عندي حرارة وَعِنْدِي أَلَم فِي الصَّدْر", "chest pain"),
    ("ما عندي كحة أَحِسّ أَلَم فِي الصَّدْر", "chest pain"),
    ("ما عندي كحة إحس ألم في الصدر", "chest pain"),
]


@pytest.mark.parametrize(("text", "label"), AFFIRMED_RED_FLAGS + AFFIRMED_WITH_MARKS)
def test_a_patient_who_has_a_red_flag_is_never_recorded_as_denying_it(text, label):
    result = check(text)
    assert result.emergency
    assert label in hit_labels(result)
    assert label not in denied_labels(result)


@pytest.mark.parametrize(("category", "label", "never_negated", "cue"), GAP_AFFIRMING)
def test_a_cue_on_an_affirming_opener_fires_after_no(
    category, label, never_negated, cue
):
    result = check(f"no {cue}")
    assert category in result.categories
    assert label in hit_labels(result)
    assert label not in denied_labels(result)


DENIED_RED_FLAGS = [
    ("no chest pain", "chest pain"),
    ("I don't have chest pain", "chest pain"),
    ("I don’t have any chest pain", "chest pain"),
    ("I do not have chest pain", "chest pain"),
    ("i have no chest pain", "chest pain"),
    ("denies chest pain", "chest pain"),
    ("without chest pain", "chest pain"),
    ("no history of chest pain", "chest pain"),
    ("no chest pain i have a cough", "chest pain"),
    ("ما عندي ألم في الصدر", "chest pain"),
    ("مافي ألم في الصدر", "chest pain"),
    ("ما في ضيق تنفس", "shortness of breath"),
    ("مو ألم في الصدر", "chest pain"),
    ("بدون نزيف", "heavy bleeding"),
    ("لا يوجد ألم في الصدر", "chest pain"),
    ("ليس عندي ألم في الصدر", "chest pain"),
    ("لا يوجد عندي ألم في الصدر", "chest pain"),
    ("ما عندي حرارة ولا ألم في الصدر", "chest pain"),
    ("it is not chest pain", "chest pain"),
    ("i am not short of breath", "shortness of breath"),
    ("my chest does not hurt and no chest pain", "chest pain"),
    ("مو عندي ألم في الصدر", "chest pain"),
    ("بدون معي ألم في الصدر", "chest pain"),
    ("مو حاس ألم في الصدر", "chest pain"),
    ("ليس فيني ضيق تنفس", "shortness of breath"),
]
DENIED_WITH_MARKS = [
    ("مَا عِنْدِي أَلَم فِي الصَّدْر", "chest pain"),
    ("لَيْسَ عِنْدِي أَلَم فِي الصَّدْر", "chest pain"),
    ("لا يـــوجد عـــندي ألـــم في الصدر", "chest pain"),
    ("لَا يُوجَد عِنْدِي أَلَم فِي الصَّدْر", "chest pain"),
]


@pytest.mark.parametrize(("text", "label"), DENIED_RED_FLAGS + DENIED_WITH_MARKS)
def test_a_real_denial_stays_denied(text, label):
    result = check(text)
    assert not result.emergency
    assert denied_labels(result) == [label]


def test_only_the_affirmed_cue_fires_when_a_denial_sits_in_the_same_message():
    result = check("no chest pain, no i have trouble breathing")
    assert hit_labels(result) == ["shortness of breath"]
    assert denied_labels(result) == ["chest pain"]


def test_an_affirmed_red_flag_leaves_the_denied_line_empty():
    result = check("no i have chest pain")
    labels = (hit.label_en for hit in result.denied)
    assert denied_text(labels) == ""


@pytest.mark.parametrize(
    ("text", "ticket_line"),
    [
        ("no stroke", "Patient denied: possible stroke"),
        ("no a stroke", "Patient denied: possible stroke"),
        ("not having a stroke", "Patient denied: possible stroke"),
        ("بدون جلطة", "Patient denied: possible stroke"),
        ("ما عندي سكتة", "Patient denied: possible stroke"),
    ],
)
def test_a_denied_stroke_reads_as_a_stroke_on_the_nurse_line(text, ticket_line):
    result = check(text)
    assert not result.emergency
    assert denied_text(hit.label_en for hit in result.denied) == ticket_line


def test_possible_stroke_has_its_own_arabic_label():
    hit = check("جلطة").hits[0]
    assert (hit.category, hit.label_en) == ("stroke", "possible stroke")
    assert hit.label_ar == "جلطة محتملة"
    assert denied_text(["possible stroke"], "ar") == "المريض نفى: جلطة محتملة"


@pytest.mark.parametrize(
    "cue", ["stroke", "a stroke", "having a stroke", "جلطة", "سكتة"]
)
def test_stroke_cues_left_the_slurred_speech_block(cue):
    row = next(row for row in CUES if row.phrase == cue)
    assert (row.category, row.label_en) == ("stroke", "possible stroke")
    assert not row.never_negated


@pytest.mark.parametrize(
    "cue", ["slurred speech", "speech is slurred", "slurring my words", "كلامي ثقيل"]
)
def test_slurred_speech_keeps_its_own_cues(cue):
    assert hit_labels(check(cue)) == ["slurred speech"]


def test_no_cue_with_a_negator_inside_sits_outside_a_never_negated_block():
    for cue in CUES:
        words = phrase_tokens(cue.phrase)
        has_negator = any(
            words[start : start + len(negator)] == negator
            for negator in _NEGATORS
            for start in range(len(words))
        )
        assert cue.never_negated or not has_negator, cue.phrase


def test_every_row_has_a_known_category_and_both_labels():
    for cue in CUES:
        assert cue.category in CATEGORIES
        assert cue.label_en and cue.label_ar


def test_each_label_has_one_arabic_translation():
    pairs = {(cue.label_en, cue.label_ar) for cue in CUES}
    assert len(pairs) == len({label for label, _ in pairs})


@pytest.mark.parametrize("text", ["I want to hurt myself", "أبي أأذي نفسي"])
def test_self_harm(text):
    result = check(text)
    assert result.self_harm
    assert result.emergency


def test_physical_emergency_is_not_self_harm():
    assert not check("chest pain").self_harm


def test_denied_text_english():
    assert denied_text(["chest pain"]) == "Patient denied: chest pain"


def test_denied_text_arabic():
    assert denied_text(["chest pain"], "ar") == "المريض نفى: ألم في الصدر"


def test_denied_text_accepts_gulf_language_code():
    assert denied_text(["chest pain"], "ar-gulf").startswith("المريض نفى")


def test_denied_text_empty():
    assert denied_text([]) == ""
    assert denied_text([], "ar") == ""


def test_denied_text_lists_each_label_once():
    labels = ["chest pain", "chest pain", "choking"]
    assert denied_text(labels) == "Patient denied: chest pain, choking"
    assert denied_text(labels, "ar") == "المريض نفى: ألم في الصدر، اختناق"


def test_denied_text_takes_labels_from_a_result():
    result = check("no chest pain")
    labels = (hit.label_en for hit in result.denied)
    assert redflags.denied_text(labels) == "Patient denied: chest pain"
