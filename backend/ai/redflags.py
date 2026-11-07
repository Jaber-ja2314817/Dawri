"""Deterministic red-flag rules: layer 1 of the safety design.

The cue list has not been reviewed by a clinician. It runs on every patient
message before the model, and the model can never clear a hit.

check reads one piece of text. check_conversation is what a turn calls: it adds a
yes to a cue question, and cues split across messages, because a patient answers
"chest" to "where is the pain?" and "blood" to "any vomiting?". simulated imports
this module, so the yes words live here and never the other way round.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from itertools import accumulate
from typing import Iterable, NamedTuple, Sequence

from backend.ai.text import (
    Token,
    has_leading_waw,
    is_negated,
    normalise,
    phrase_starts,
    phrase_tokens,
    split_sentences,
    tokenise,
)

YES_WORDS = frozenset(phrase_tokens("yes yeah yep yup نعم اي ايوه ايه اكيد"))

CATEGORIES = (
    "chest_pain",
    "breathing",
    "stroke",
    "bleeding",
    "consciousness",
    "allergy",
    "pregnancy",
    "infant",
    "self_harm",
)


class Cue(NamedTuple):
    category: str
    phrase: str
    label_en: str
    label_ar: str
    never_negated: bool


def _cues(
    category: str,
    label_en: str,
    label_ar: str,
    phrases: Iterable[str],
    *,
    never_negated: bool = False,
) -> tuple[Cue, ...]:
    return tuple(
        Cue(category, phrase, label_en, label_ar, never_negated) for phrase in phrases
    )


_SINGULAR_PAIN = ("ألم", "وجع")
_PLURAL_PAIN = ("آلام", "أوجاع")
_INTENSITY = ("شديد", "قوي", "حاد", "كبير", "فظيع")
_PLURAL_INTENSITY = ("شديدة", "قوية", "حادة")
_CHEST_PLACES = ("في الصدر", "بالصدر", "في صدري", "بصدري")


def _intense(
    pains: Iterable[str], intensities: Iterable[str], very: str = ""
) -> tuple[str, ...]:
    return tuple(
        f"{pain} {intensity}{very} {place}"
        for pain in pains
        for intensity in intensities
        for place in _CHEST_PLACES
    )


_PLURAL_CHEST_PAIN: tuple[str, ...] = tuple(
    f"{pain} {place}" for pain in _PLURAL_PAIN for place in (*_CHEST_PLACES, "الصدر")
)

# One intensity word, with an optional جدا, may sit between the pain word and its
# place, in Arabic only.
_INTENSE_CHEST_PAIN: tuple[str, ...] = (
    *_intense(_SINGULAR_PAIN, _INTENSITY),
    *_intense(_SINGULAR_PAIN, _PLURAL_INTENSITY),
    *_intense(_PLURAL_PAIN, (*_INTENSITY, *_PLURAL_INTENSITY)),
    *_intense(
        (*_SINGULAR_PAIN, *_PLURAL_PAIN), (*_INTENSITY, *_PLURAL_INTENSITY), " جدا"
    ),
)

# Do not add bare "bleeding", "fever" or "high fever": a cold with a temperature
# is a normal visit. Rows with never_negated=True contain a negator themselves.
CUES: tuple[Cue, ...] = (
    *_cues(
        "chest_pain",
        "chest pain",
        "ألم في الصدر",
        (
            "chest pain",
            "chest pains",
            "pain in chest",
            "pain in my chest",
            "pain in the chest",
            "pressure in chest",
            "pressure in my chest",
            "pressure in the chest",
            "chest pressure",
            "chest hurts",
            "chest is hurting",
            "pressure on my chest",
            "pressure on chest",
            "heart attack",
            "ألم في الصدر",
            "ألم في صدري",
            "ألم بالصدر",
            "ألم بصدري",
            "ألم الصدر",
            "وجع في الصدر",
            "وجع في صدري",
            "وجع بالصدر",
            "وجع بصدري",
            "وجع الصدر",
            "يوجعني صدري",
            "صدري يوجعني",
            "صدري يألمني",
            "يؤلمني صدري",
            *_INTENSE_CHEST_PAIN,
            *_PLURAL_CHEST_PAIN,
            "صدري يعورني",
            "يعورني صدري",
            "صدري يعور",
            "chest ache",
            "chest aches",
            "my chest aches",
        ),
    ),
    *_cues(
        "chest_pain",
        "chest tightness",
        "ضيق في الصدر",
        (
            "chest tightness",
            "tightness in my chest",
            "tightness in chest",
            "tight chest",
            "my chest feels tight",
            "chest feels tight",
            "chest is tight",
            "ضيقة في الصدر",
            "ضيقة بالصدر",
            "ضيقة بصدري",
            "ضيقة في صدري",
            "ضيق في صدري",
            "ضيق بصدري",
            "ضيق في الصدر",
            "ضيق الصدر",
            "صدري ضيق",
            "كتمة",
            "كتمة في صدري",
            "كتمة في الصدر",
            "كتمة بصدري",
        ),
    ),
    *_cues(
        "chest_pain",
        "pain spreading to arm or jaw",
        "ألم يمتد إلى الذراع أو الفك",
        (
            "pain to left arm",
            "pain to my left arm",
            "pain to arm",
            "pain to my arm",
            "pain to left jaw",
            "pain to my left jaw",
            "pain to jaw",
            "pain to my jaw",
            "pain going to my left arm",
            "pain going to my jaw",
            "spreading to left arm",
            "spreading to my left arm",
            "spreading to my jaw",
            "radiating to my left arm",
            "radiating to my jaw",
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
    *_cues(
        "breathing",
        "shortness of breath",
        "ضيق تنفس",
        (
            "short of breath",
            "shortness of breath",
            "trouble breathing",
            "difficulty breathing",
            "difficulty in breathing",
            "hard to breathe",
            "hard to breath",
            "struggling to breathe",
            "unable to breathe",
            "stopped breathing",
            "gasping for air",
            "ضيق تنفس",
            "ضيق التنفس",
            "ضيق في التنفس",
            "ضيق بالتنفس",
            "صعوبة في التنفس",
            "صعوبة بالتنفس",
            "صعوبة تنفس",
            "struggling to breath",
            "out of breath",
            "breathless",
        ),
    ),
    *_cues(
        "breathing",
        "shortness of breath",
        "ضيق تنفس",
        (
            "can't breathe",
            "cant breathe",
            "cannot breathe",
            "can not breathe",
            "can't breath",
            "cant breath",
            "cannot breath",
            "can not breath",
            "couldn't breathe",
            "could not breathe",
            "can't catch my breath",
            "not breathing",
            "ما أقدر أتنفس",
            "ما قدرت أتنفس",
            "ما قادر أتنفس",
            "مو قادر أتنفس",
            "مش قادر أتنفس",
            "مقدر أتنفس",
            "ما قادرة أتنفس",
            "مو قادرة أتنفس",
            "لا أستطيع التنفس",
            "لا أستطيع أن أتنفس",
            "لا أستطيع أتنفس",
            "لا أقدر أتنفس",
            "لا أقدر على التنفس",
            "ماقدر أتنفس",
            "ماني قادر أتنفس",
            "can barely breathe",
            "مب قادر أتنفس",
            "مب قادر اتنفس",
        ),
        never_negated=True,
    ),
    *_cues(
        "breathing",
        "choking",
        "اختناق",
        ("choking", "choked", "اختناق", "أختنق"),
    ),
    *_cues(
        "stroke",
        "facial drooping",
        "ميلان في الوجه",
        (
            "face drooping",
            "drooping face",
            "face droop",
            "face is drooping",
            "وجهي مايل",
            "وجهي مائل",
            "فمي مايل",
            "فمي مائل",
            "وجهي معوج",
            "my face is droopy",
            "face is droopy",
            "face drooped",
            "face is numb",
        ),
    ),
    *_cues(
        "stroke",
        "unable to move arm",
        "عدم القدرة على تحريك اليد",
        (
            "can't move arm",
            "can't move my arm",
            "cant move my arm",
            "cannot move arm",
            "cannot move my arm",
            "can not move my arm",
            "can't move my leg",
            "cannot move my leg",
            "ما أقدر أحرك يدي",
            "ما أقدر أحرك إيدي",
            "ما أقدر أحرك ذراعي",
            "ما أقدر أحرك رجلي",
            "مو قادر أحرك يدي",
            "يدي ما تتحرك",
            "إيدي ما تتحرك",
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
        never_negated=True,
    ),
    *_cues(
        "stroke",
        "unable to move arm",
        "عدم القدرة على تحريك اليد",
        (
            "arm is numb",
            "numb on one side",
            "numbness on one side",
            "sudden weakness",
        ),
    ),
    *_cues(
        "stroke",
        "slurred speech",
        "ثقل في الكلام",
        (
            "slurred speech",
            "speech is slurred",
            "slurring my words",
            "كلامي ثقيل",
            "لساني ثقيل",
        ),
    ),
    *_cues(
        "stroke",
        "possible stroke",
        "جلطة محتملة",
        ("having a stroke", "stroke", "a stroke", "جلطة", "سكتة"),
    ),
    *_cues(
        "stroke",
        "slurred speech",
        "ثقل في الكلام",
        ("ما أقدر أتكلم", "لا أستطيع الكلام", "can't speak", "cannot speak"),
        never_negated=True,
    ),
    *_cues(
        "bleeding",
        "heavy bleeding",
        "نزيف",
        (
            "heavy bleeding",
            "severe bleeding",
            "bleeding heavily",
            "bleeding a lot",
            "won't stop bleeding",
            "نزيف",
            "أنزف",
            "نزف",
        ),
    ),
    *_cues(
        "bleeding",
        "heavy bleeding",
        "نزيف",
        ("bleeding won't stop", "bleeding wont stop"),
        never_negated=True,
    ),
    *_cues(
        "bleeding",
        "vomiting blood",
        "استفراغ دم",
        (
            "vomiting blood",
            "vomited blood",
            "throwing up blood",
            "threw up blood",
            "أستفرغ دم",
            "استفراغ دم",
            "ترجيع دم",
            "أتقيأ دم",
            "تقيؤ دم",
            "قيء دم",
        ),
    ),
    *_cues(
        "bleeding",
        "coughing up blood",
        "كحة مع دم",
        ("coughing up blood", "coughing blood", "أكح دم", "كحة دم"),
    ),
    *_cues(
        "consciousness",
        "fainting",
        "إغماء",
        (
            "fainted",
            "fainting",
            "passed out",
            "blacked out",
            "lost consciousness",
            "unconscious",
            "collapsed",
            "أغمى علي",
            "أغمي علي",
            "أغمي عليه",
            "أغمي عليها",
            "مغمى علي",
            "مغمى عليه",
            "مغمى عليها",
            "إغماء",
            "فقدت الوعي",
            "فاقد الوعي",
            "فاقدة الوعي",
            "فقدان الوعي",
            "غبت عن الوعي",
        ),
    ),
    *_cues(
        "consciousness",
        "seizure",
        "تشنج",
        (
            "seizure",
            "seizures",
            "convulsions",
            "convulsing",
            "تشنج",
            "تشنجات",
            "نوبة صرع",
            "had a fit",
            "having a fit",
        ),
    ),
    *_cues(
        "allergy",
        "throat swelling",
        "تورم الحلق",
        (
            "throat swelling",
            "swollen throat",
            "throat is swelling",
            "swelling in my throat",
            "throat is swollen",
            "my throat is swollen",
            "throat is closing",
            "tongue swelling",
            "swollen tongue",
            "tongue is swollen",
            "anaphylaxis",
            "انتفاخ الحلق",
            "تورم الحلق",
            "انتفاخ اللسان",
            "تورم اللسان",
            "تورم في الحلق",
            "انتفاخ في الحلق",
            "حلقي منتفخ",
            "حلقي متورم",
            "لساني منتفخ",
            "tongue is swelling",
            "my tongue is swelling",
            "throat is closing up",
        ),
    ),
    *_cues(
        "allergy",
        "lip swelling",
        "تورم الشفايف",
        (
            "lips swelling",
            "lip swelling",
            "swollen lips",
            "lips are swelling",
            "lips are swollen",
            "my lips are swollen",
            "تورم الشفايف",
            "تورم الشفاه",
            "انتفاخ الشفايف",
            "انتفاخ الشفاه",
            "تورم في الشفايف",
            "انتفاخ في الشفايف",
            "شفايفي منتفخة",
            "شفايفي متورمة",
            "شفتي منتفخة",
            "lips swelled up",
            "my lips swelled up",
        ),
    ),
    *_cues(
        "pregnancy",
        "bleeding while pregnant",
        "نزيف أثناء الحمل",
        (
            "bleeding while pregnant",
            "bleeding during pregnancy",
            "pregnant and bleeding",
            "نزيف وأنا حامل",
            "نزيف أثناء الحمل",
            "نزيف مع الحمل",
            "حامل وعندي نزيف",
            "حامل ونزيف",
            "حامل وأنزف",
            "حامل وأنا أنزف",
            "pregnant and i am bleeding",
            "pregnant and i'm bleeding",
            "i am bleeding and i am pregnant",
            "i'm bleeding and i'm pregnant",
            "bleeding and pregnant",
            "حامل ونزفت",
            "حامل ونزف",
        ),
    ),
    *_cues(
        "pregnancy",
        "severe pain while pregnant",
        "ألم شديد أثناء الحمل",
        (
            "severe pain pregnant",
            "severe pain while pregnant",
            "severe pain during pregnancy",
            "pregnant with severe pain",
            "pregnant and severe pain",
            "ألم شديد وأنا حامل",
            "وجع شديد وأنا حامل",
            "ألم شديد أثناء الحمل",
            "pregnant and i have severe pain",
            "severe pain and pregnant",
            "severe stomach pain and pregnant",
            "severe stomach pain while pregnant",
        ),
    ),
    *_cues(
        "infant",
        "baby not feeding",
        "الرضيع لا يرضع",
        (
            "baby not feeding",
            "baby is not feeding",
            "baby isn't feeding",
            "baby isnt feeding",
            "baby won't feed",
            "baby not breathing",
            "الطفل ما يرضع",
            "الطفلة ما ترضع",
            "طفلي ما يرضع",
            "طفلتي ما ترضع",
            "البيبي ما يرضع",
            "البيبي ما ترضع",
            "الرضيع ما يرضع",
            "الرضيعة ما ترضع",
            "ولدي ما يرضع",
            "بنتي ما ترضع",
            "رضيعي ما يرضع",
            "رضيعتي ما ترضع",
            "ولدي الرضيع ما يرضع",
            "بنتي الرضيعة ما ترضع",
        ),
        never_negated=True,
    ),
    *_cues(
        "infant",
        "very sleepy baby",
        "رضيع نعسان جدا",
        ("baby very sleepy", "baby is very sleepy", "baby won't wake up"),
    ),
    *_cues(
        "infant",
        "baby with high fever",
        "حرارة عالية للرضيع",
        (
            "baby with high fever",
            "baby with a high fever",
            "baby has high fever",
            "baby has a high fever",
            "حرارة عالية للرضيع",
            "حرارة عالية للبيبي",
            "الرضيع عنده حرارة عالية",
            "البيبي عنده حرارة عالية",
            "حرارة الرضيع عالية",
            "رضيعي حرارته عالية",
            "حرارة رضيعي عالية",
            "الرضيعة عندها حرارة عالية",
            "newborn has a high fever",
            "newborn has high fever",
            "newborn with high fever",
            "infant has a high fever",
            "infant with high fever",
            "newborn has a fever",
            "newborn with a fever",
        ),
    ),
    *_cues(
        "self_harm",
        "thoughts of self-harm",
        "أفكار إيذاء النفس",
        (
            "want to hurt myself",
            "hurt myself",
            "harm myself",
            "end my life",
            "take my own life",
            "kill myself",
            "want to die",
            "suicide",
            "suicidal",
            "أبي أأذي نفسي",
            "أبي أذي نفسي",
            "أبغى أذي نفسي",
            "أبغى أأذي نفسي",
            "أؤذي نفسي",
            "أأذي نفسي",
            "أذي نفسي",
            "أقتل نفسي",
            "أنتحر",
            "الانتحار",
            "أنهي حياتي",
            "أبي أموت",
            "أبغى أموت",
            "ودي أموت",
            "want to end it all",
            "end it all",
            "بنتحر",
        ),
    ),
    *_cues(
        "self_harm",
        "thoughts of self-harm",
        "أفكار إيذاء النفس",
        (
            "don't want to live",
            "dont want to live",
            "do not want to live",
            "ما أبي أعيش",
            "ما أبغى أعيش",
            "don't want to be alive",
            "dont want to be alive",
            "do not want to be alive",
            "no reason to live",
            "not worth living",
            "ما عندي سبب أعيش",
        ),
        never_negated=True,
    ),
    *_cues(
        "self_harm",
        "possible overdose",
        "جرعة زائدة محتملة",
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
)

_COMPILED: tuple[tuple[Cue, tuple[str, ...]], ...] = tuple(
    (cue, phrase_tokens(cue.phrase)) for cue in CUES
)
_LABEL_AR: dict[str, str] = {cue.label_en: cue.label_ar for cue in CUES}


@dataclass(frozen=True)
class Hit:
    category: str
    cue: str
    label_en: str
    label_ar: str


@dataclass(frozen=True)
class RedFlagResult:
    hits: tuple[Hit, ...]
    denied: tuple[Hit, ...]
    fired: frozenset[str] = frozenset()  # labels that ever fired, so never denied

    @property
    def emergency(self) -> bool:
        return bool(self.hits)

    @property
    def self_harm(self) -> bool:
        return "self_harm" in self.categories

    @property
    def categories(self) -> tuple[str, ...]:
        return tuple(dict.fromkeys(hit.category for hit in self.hits))


def _hit(cue: Cue) -> Hit:
    return Hit(cue.category, cue.phrase, cue.label_en, cue.label_ar)


def check(text: str) -> RedFlagResult:
    """Run every cue over the text. Repeats fire if any occurrence is not negated."""
    tokens = tokenise(text)
    hits: dict[str, Hit] = {}
    denied: dict[str, Hit] = {}
    for cue, phrase in _COMPILED:
        for start in phrase_starts(tokens, phrase):
            negated = (
                not cue.never_negated
                and not has_leading_waw(phrase[0], tokens[start].text)
                and is_negated(tokens, start)
            )
            target = denied if negated else hits
            target.setdefault(cue.label_en, _hit(cue))
    return RedFlagResult(
        hits=tuple(hits.values()),
        denied=tuple(hit for label, hit in denied.items() if label not in hits),
    )


def _side(*items: str) -> tuple[tuple[str, ...], ...]:
    return tuple(phrase_tokens(item) for item in items)


_SEVERE_WORDS = (
    "severe", "severely", "terrible", "unbearable", "excruciating", "very bad",
    "really bad", "شديد", "شديدة", "قوي", "قوية", "حاد", "حادة", "فظيع", "فظيعة",
)

# Only an infant nurses, so these pair with "my son" as well as with "baby".
_NURSING = _side(
    "not breastfeeding", "not nursing",
    "ما يرضع", "ما ترضع", "لا يرضع", "لا ترضع", "ما يبي يرضع", "ما تبي ترضع",
    "ما يبغى يرضع", "ما تبغى ترضع", "مو راضي يرضع", "مو راضية ترضع",
    "مب راضي يرضع", "مب راضية ترضع", "رافض الرضاعة", "رافضة الرضاعة",
)

_ARM_OR_JAW = (
    "my arm", "my left arm", "my right arm", "left arm", "right arm", "the arm",
    "the left arm", "arm", "my jaw", "my left jaw", "left jaw", "the jaw", "jaw",
)
_ARM_OR_JAW_AR = ("ذراعي", "يدي", "إيدي", "فكي", "الذراع", "اليد", "الفك")
_SPREADS_AR = ("يمتد", "ينتشر", "ينزل", "تمتد", "تنتشر", "تنزل")
_LIMBS = ("arm", "left arm", "right arm", "leg", "left leg", "right leg")
_LIMBS_AR = ("يدي", "إيدي", "ذراعي", "رجلي")

# Arm and jaw alone are not cues: the vault cue means pain spreading there, so only
# the to, down and into forms count, and "my left arm" answers "Where is the pain?"
# as a normal visit. What else counts as spreading is a clinician item. "blood" stays
# out of the bleeding words so a blood test is not a bleed, and a bare fever is a
# normal visit, so the baby row needs "high" as well.
_SIDES: dict[str, tuple[tuple[str, ...], ...]] = {
    "pain": _side(
        "pain", "pains", "painful", "ache", "aches", "aching", "hurt", "hurts", "hurting",
        "tight", "tightness", "pressure",
        "ألم", "آلام", "وجع", "أوجاع", "يوجع", "توجع", "يوجعني", "توجعني", "يوجعه",
        "يوجعها", "يعور", "تعور", "يعورني", "تعورني", "يؤلم", "تؤلم", "يؤلمني",
        "تؤلمني", "ضيق", "ضيقة", "كتمة",
    ),
    "chest": _side("chest", "صدر", "صدري", "صدرك", "صدرج", "صدره", "صدرها"),
    "bleeding": _side(
        "bleeding", "bleed", "bleeds", "bled", "haemorrhage", "hemorrhage",
        "نزيف", "نزف", "أنزف", "ينزف", "تنزف", "نزفت",
    ),
    "pregnant": _side("pregnant", "pregnancy", "حامل", "حاملة", "حبلى", "حمل"),
    "severe": _side(*_SEVERE_WORDS),
    "heavy": _side(
        *_SEVERE_WORDS, "heavy", "heavily", "a lot", "غزير", "غزيرة", "كثير", "كثيرة", "وايد",
    ),
    "baby": _side(
        "baby", "babies", "infant", "newborn", "بيبي", "رضيع", "رضيعة", "رضيعي",
        "رضيعتي", "طفل", "طفلة", "طفلي", "طفلتي", "مولود", "مولودة",
    ),
    "child": _side("my son", "my daughter", "ولدي", "بنتي", "ابني"),
    "nursing": _NURSING,
    "feeding": (
        *_NURSING,
        *_side(
            "not feeding", "isn't feeding", "isnt feeding", "won't feed", "wont feed",
            "stopped feeding", "refusing to feed", "refuses to feed", "not eating",
            "isn't eating", "won't eat", "not drinking", "not taking milk", "poor feeding",
            "feeding problem", "feeding problems", "trouble feeding", "difficulty feeding",
            "ما ياكل", "ما تاكل", "ما يشرب", "ما تشرب",
        ),
    ),
    "sleepy": _side(
        "very sleepy", "so sleepy", "too sleepy", "really sleepy", "extremely sleepy",
        "drowsy", "lethargic", "won't wake", "wont wake", "hard to wake",
        "نعسان جدا", "نعسانة جدا", "نعسان وايد", "نعسانة وايد", "نعسان كثير",
        "نعسانة كثير", "ما يصحى", "ما تصحى", "خامل", "خاملة",
    ),
    "fever": _side("fever", "temperature", "حرارة", "حرارته", "حرارتها", "سخونة", "حمى"),
    "high": _side("high", "عالية", "عالي", "مرتفعة", "مرتفع"),
    "vomit": _side(
        "vomit", "vomits", "vomiting", "vomited", "throw up", "throwing up", "threw up",
        "ترجيع", "استفراغ", "أستفرغ", "استفرغت", "أرجع", "قيء", "تقيؤ", "أتقيأ", "تقيأت",
    ),
    "blood": _side("blood", "دم"),
    "spreading": _side(
        *(f"{way} {place}" for way in ("to", "down", "into") for place in _ARM_OR_JAW),
        *(f"إلى {place}" for place in _ARM_OR_JAW_AR),
        "لذراعي", "ليدي", "لإيدي", "لفكي", "للذراع", "لليد", "للفك",
        *(
            f"{verb} {link}{place}"
            for verb in _SPREADS_AR
            for link in ("", "في ", "على ")
            for place in _ARM_OR_JAW_AR
        ),
    ),
    "swelling": _side(
        "swelling", "swollen", "swelled", "انتفاخ", "تورم", "منتفخ", "منتفخة", "متورم",
        "متورمة", "انتفخ", "انتفخت", "تورمت",
    ),
    "throat": _side(
        "throat", "tongue", "حلق", "حلقي", "حلقه", "حلقها", "لسان", "لساني", "لسانه", "لسانها",
    ),
    "lips": _side(
        "lip", "lips", "شفة", "شفتي", "شفايف", "شفايفي", "شفايفه", "شفايفها", "شفاه", "شفاهي",
    ),
    "face": _side("face", "وجه", "وجهي", "وجهه", "وجهها"),
    "droop": _side(
        "droop", "drooping", "drooped", "droopy", "مايل", "مائل", "مايلة", "مائلة", "معوج",
    ),
    "speech": _side("speech", "my words", "كلامي"),
    "slurred": _side("slurred", "slurring", "ثقيل"),
    "cant_move": _side(
        "can't move", "cant move", "cannot move", "can not move", "ما أقدر أحرك",
        "مو قادر أحرك", "لا أقدر أحرك", "لا أستطيع تحريك", "أحركها", "أحركه",
    ),
    # "not" and مو inside the wording would deny a limb right after it, so that wording
    # and its limb count as one mention. The split form fires, so the whole one must.
    "limb": _side(
        "arm", "my arm", "left arm", "right arm", "leg", "my leg", *_LIMBS_AR,
        *(f"can not move {limb}" for limb in _LIMBS),
        *(f"مو قادر أحرك {limb}" for limb in _LIMBS_AR),
    ),
    "narrow": _side("ضيق", "ضيقة"),  # ضيق alone is not breathing: ضيق في الصدر is chest
    "breath": _side("تنفس", "أتنفس"),
}
_NEVER_NEGATED_SIDES = frozenset(  # they carry their own negator
    {"feeding", "nursing", "cant_move"}
)

# (sides that must all be live, category, the label of the listed cue it stands for)
_COMPOUNDS: tuple[tuple[tuple[str, ...], str, str], ...] = (
    (("pain", "chest"), "chest_pain", "chest pain"),
    (("bleeding", "pregnant"), "pregnancy", "bleeding while pregnant"),
    (("severe", "pain", "pregnant"), "pregnancy", "severe pain while pregnant"),
    (("bleeding", "heavy"), "bleeding", "heavy bleeding"),
    (("baby", "feeding"), "infant", "baby not feeding"),
    (("child", "nursing"), "infant", "baby not feeding"),
    (("baby", "sleepy"), "infant", "very sleepy baby"),
    (("baby", "fever", "high"), "infant", "baby with high fever"),
    (("vomit", "blood"), "bleeding", "vomiting blood"),
    (("pain", "spreading"), "chest_pain", "pain spreading to arm or jaw"),
    (("swelling", "throat"), "allergy", "throat swelling"),
    (("swelling", "lips"), "allergy", "lip swelling"),
    (("face", "droop"), "stroke", "facial drooping"),
    (("speech", "slurred"), "stroke", "slurred speech"),
    (("cant_move", "limb"), "stroke", "unable to move arm"),
    (("narrow", "breath"), "breathing", "shortness of breath"),
)

# A side word inside one of these is not that side: "blood pressure" is no pain, a
# blood test is no blood, and a sore throat is no place that swelled. Matching strips
# ال and بال, so دم here also means الدم and حلق also means الحلق and بالحلق.
_NOT_THE_SIDE: dict[str, tuple[tuple[str, ...], ...]] = {
    "pain": _side("blood pressure"),
    "blood": _side(
        "blood pressure", "blood test", "blood tests", "blood sugar",
        "تحليل دم", "تحاليل دم", "فحص دم", "ضغط دم", "سكر دم",
    ),
    "throat": _side(
        "sore throat", "ألم حلق", "ألم في حلق", "وجع حلق", "وجع في حلق", "التهاب حلق",
        "التهاب في حلق",
    ),
    # _NOT_HERE marks only the word after "not my". "my arm" starts one word earlier and
    # the "arm" of "left arm" one word later, so each would stay live without this.
    "limb": _side(
        *(f"{lead} {limb}" for lead in ("not my", "not in my", "not on my") for limb in _LIMBS)
    ),
}
# Denying the first denies the second in that clause, as "no pain in my chest" does.
# "vomit" is not here: "I vomited without blood" still says they vomited.
_DENIED_WITH = {
    "chest": "pain",
    "spreading": "pain",
    "throat": "swelling",
    "lips": "swelling",
    "face": "droop",
    "speech": "slurred",
    "breath": "narrow",
}
# is_negated stops at "my", so that "no my chest hurts" fires. "not my chest" and
# "not in my chest" still say it is somewhere else. The rest are denials the vault's
# negators miss, which only ever deny the side right after them: "فيه دم" fires, so
# "ما فيه دم" must not. Matched exactly, because لما is "when", not a negator.
_NOT_HERE = _side(
    "not my", "not in my", "not on my", "didn't", "haven't", "hasn't", "never",
    "ما", "ما فيه", "مافيه",
)
# Only a plain no. Missing one is the cautious way round, and "مو كثير" means some, so
# this list stays short.
_NO_ANSWERS = _side(
    "no", "nope", "nah", "none", "never", "not really", "not at all",
    "لا", "كلا", "أبدا", "مافي", "ما في", "مافيه", "ما فيه", "ما عندي", "ولا شي", "ولا شيء",
)
_UNSURE_ANSWERS = _side("no idea", "no clue", "لا أدري", "لا أعرف", "لا أعلم")


_CUE_WORDS = frozenset(word for _, phrase in _COMPILED for word in phrase) | frozenset(
    word for phrases in _SIDES.values() for phrase in phrases for word in phrase
)
_PATIENT_VOICE = {
    "your": "my", "yourself": "myself", "faint": "fainted", "pass": "passed",
    "lose": "lost", "collapse": "collapsed", "vomit": "vomited",
}


def means_yes(tokens: Sequence[Token]) -> bool:
    return bool(tokens) and tokens[0].text in YES_WORDS


def _opens_on(tokens: Sequence[Token], phrases: Iterable[Sequence[str]]) -> bool:
    words = tuple(token.text for token in tokens)
    return any(words[: len(phrase)] == phrase for phrase in phrases)


def _means_no(tokens: Sequence[Token]) -> bool:
    return _opens_on(tokens, _NO_ANSWERS) and not _opens_on(tokens, _UNSURE_ANSWERS)


def _patient_word(match: re.Match[str]) -> str:
    word = match.group()
    if word in _PATIENT_VOICE:
        return _PATIENT_VOICE[word]
    forms = [f"ا{word[1:]}"] if word.startswith("ت") else []
    if word.endswith(("ك", "ج")):
        forms += [f"{word[:-1]}ي", word[:-1]]
    return next((form for form in forms if form in _CUE_WORDS), word)


def _in_patient_voice(question: str) -> str:
    """A question as the patient would say it, because cues are in the first person.

    So a yes to "Do you want to hurt yourself?" or "أغمي عليك؟" matches its cue. An
    Arabic word changes only into a word some cue uses: عليك to علي, تنزف to انزف.
    """
    return re.sub(r"\w+", _patient_word, normalise(question))


def _words_inside(tokens: Sequence[Token], phrases: Iterable[Sequence[str]]) -> set[int]:
    return {
        start + offset
        for phrase in phrases
        for start in phrase_starts(tokens, phrase)
        for offset in range(len(phrase))
    }


def _read_sides(text: str) -> tuple[set[str], set[str]]:
    """The sides this text states, and those it denies at least once.

    A side is live unless every mention is negated.
    """
    tokens = tokenise(text)
    clauses = list(accumulate(token.starts_clause for token in tokens))
    elsewhere = {
        start + len(phrase)
        for phrase in _NOT_HERE
        for start in phrase_starts(tokens, phrase)
        if tokens[start].text == phrase[0]
    }
    mentions: list[tuple[str, int, bool]] = []
    for name, phrases in _SIDES.items():
        not_this = _words_inside(tokens, _NOT_THE_SIDE.get(name, ()))
        for phrase in phrases:
            for start in phrase_starts(tokens, phrase):
                if start in not_this:
                    continue
                negated = (
                    name not in _NEVER_NEGATED_SIDES
                    and not has_leading_waw(phrase[0], tokens[start].text)
                    and (is_negated(tokens, start) or start in elsewhere)
                )
                mentions.append((name, clauses[start], negated))
    denied = {(name, clause) for name, clause, negated in mentions if negated}
    live = {
        name
        for name, clause, negated in mentions
        if not negated and (_DENIED_WITH.get(name), clause) not in denied
    }
    return live, {name for name, _ in denied}


def _live_sides(text: str) -> set[str]:
    return _read_sides(text)[0]


def _compound_hits(spoken: Sequence[str], asked: set[str]) -> tuple[Hit, ...]:
    live: set[str] = set(asked).union(*(_live_sides(text) for text in spoken))
    return tuple(
        Hit(category, " + ".join(sides), label, _LABEL_AR[label])
        for sides, category, label in _COMPOUNDS
        if live.issuperset(sides)
    )


def _question_in(message: dict) -> str:
    """The last question in an assistant message, or '' if it asked none.

    Only the question: a yes to the read-back's "Is this right?" must not turn the
    "Patient denied: chest pain" before it into a hit.
    """
    sentences = split_sentences(message["content"])
    asked = [item for item in sentences if "?" in item or "؟" in item]
    return _in_patient_voice(asked[-1]) if asked else ""


def _replies(history: Sequence[dict], text: str) -> list[tuple[str, str]]:
    """Every patient message, each with the question it replies to, or ''."""
    replies = []
    question = ""
    for message in (*history, {"role": "user", "content": text}):
        if message["role"] == "assistant":
            question = _question_in(message)
            continue
        replies.append((message["content"], question))
        question = ""
    return replies


def _answers(history: Sequence[dict], text: str) -> list[tuple[str, str]]:
    """Every patient message, each with the question it said yes to, or ''."""
    return [
        (said, question if means_yes(tokenise(said)) else "")
        for said, question in _replies(history, text)
    ]


# A bare answer to one of these still says the patient has it: "Any vomiting?",
# "sometimes" and "Do you have a fever?", "high".
_ASKED_SYMPTOMS = frozenset({"vomit", "fever"})


def _asked_sides(history: Sequence[dict], text: str) -> set[str]:
    """Sides named only in a question that a reply kept alive, on any turn so far.

    A reply that means no counts for nothing. Otherwise a symptom in _ASKED_SYMPTOMS
    stays raised unless the reply denies it, so "Do you have a fever?", "high", then
    "it is my baby" fires a turn later. Any other side counts only when the reply itself
    states a different side of the same compound: "Where is the pain?", "chest" fires,
    and "Is the pain in your chest?", "it is in my stomach" stays quiet.
    """
    raised: set[str] = set()
    for said, question in _replies(history, text):
        if not question or _means_no(tokenise(said)):
            continue
        asked = _live_sides(question)
        live, denied = _read_sides(said)
        raised |= (asked & _ASKED_SYMPTOMS) - denied
        for sides, _category, _label in _COMPOUNDS:
            compound = set(sides)
            if (live & compound) - asked:
                raised |= (asked & compound) - denied
    return raised


def check_conversation(text: str, history: Sequence[dict] = ()) -> RedFlagResult:
    """The rules for one new message, read with everything said before it.

    `history` does not include `text`. A question the patient said yes to counts as
    their own words, now and on later turns, so "Any pain?", "yes", "chest" fires.
    Only `text` and the question it answers can add a single-cue hit, because an
    earlier message had its turn. A compound can complete on any message, and it can
    use a side that only a question named, as _asked_sides decides, with no yes at all.
    """
    answers = _answers(history, text)
    spoken = [part for answer in answers for part in answer if part]
    current = [check(part) for part in answers[-1] if part]
    hits = {hit.label_en: hit for result in current for hit in result.hits}
    for hit in _compound_hits(spoken, _asked_sides(history, text)):
        hits.setdefault(hit.label_en, hit)
    fired = {hit.label_en for part in spoken for hit in check(part).hits} | set(hits)
    denied = {hit.label_en: hit for result in current for hit in result.denied}
    return RedFlagResult(
        hits=tuple(hits.values()),
        denied=tuple(hit for label, hit in denied.items() if label not in fired),
        fired=frozenset(fired),
    )


def label_ar(label: str) -> str:
    """The Arabic for an English cue label. An unknown one stays as it is."""
    return _LABEL_AR.get(label, label)


def denied_text(labels: Iterable[str], lang: str = "en") -> str:
    """Build the nurse-facing line, or '' when nothing was denied."""
    unique = list(dict.fromkeys(labels))
    if not unique:
        return ""
    if lang.startswith("ar"):
        arabic = [label_ar(label) for label in unique]
        return "المريض نفى: " + "، ".join(arabic)
    return "Patient denied: " + ", ".join(unique)
