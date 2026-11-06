"""Refill detection. A deflection needs a match in the record's active_meds.

Detection needs a refill intent, a medicine reference and that drug on the
record. A symptom word, a problem with the medicine or a question about it
cancels it, because that must reach a nurse rather than a refill line. "My usual
pills" is only an intent beside a request word, since people say it about pills
they already take.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

from backend.ai.text import (
    Token,
    contains_any,
    is_negated,
    normalise,
    phrase_starts,
    phrase_tokens,
    token_matches,
    tokenise,
)

INTENT_PHRASES = (
    "refill", "refills", "repeat", "renew", "renewal", "ran out",
    "run out", "running out", "out of", "need more",
    "تجديد", "أجدد", "جدد",
    "خلص", "خلصت", "خلصان", "خلصانة", "نفد", "نفذ",
)
USUAL_PHRASES = ("usual", "regular", "المعتاد", "المعتادة", "معتاد", "معتادة", "العادي")
REQUEST_PHRASES = (
    "need", "want", "get", "can i have", "can i get",
    "أبي", "أبغى", "أحتاج", "أريد", "ممكن", "بدي",
)
BARE_REFILL_PHRASES = ("refill", "تجديد")
MEDICATION_NOUNS = (
    "pills", "pill", "tablets", "tablet", "medicine", "medicines", "medication",
    "medications", "meds", "prescription",
    "دوا", "دواء", "دوائي", "أدوية", "حبوب", "علاج",
)
DRUG_CLASSES: dict[str, tuple[str, ...]] = {
    "amlodipine": (
        "blood pressure", "bp", "pressure", "hypertension", "ضغط", "الضغط",
    ),
    "metformin": ("diabetes", "sugar", "سكر", "السكر", "سكري", "السكري"),
}
DRUG_ARABIC_NAMES: dict[str, tuple[str, ...]] = {
    "amlodipine": ("أملوديبين",),
    "metformin": ("ميتفورمين",),
}
SYMPTOM_WORDS = (
    "pain", "pains", "ache", "aches", "hurt", "hurts", "sore", "dizzy", "dizziness",
    "rash", "itch", "itchy", "swelling", "swollen", "nausea", "nauseous", "vomiting",
    "vomit", "fever", "cough", "coughing", "headache", "headaches", "side effect",
    "side effects",
    "دوخة", "دايخ", "دوار", "حكة", "طفح", "ألم", "وجع", "يوجعني", "تورم", "غثيان",
    "ترجيع", "استفراغ", "حرارة", "كحة", "سعال", "صداع", "تعبتني", "تعبني",
)
# Trouble with a medicine, or a question or a change to it, rather than a request
# for more of it. The spellings with no apostrophe and the spelled-out forms are
# the same phrases as typed. normalise folds أ to ا, so أوقف also covers اوقف, and
# the same goes for أغير, أسأل and the rest.
CANCEL_PHRASES = (
    "too many", "too much", "overdose", "double", "extra", "stopped", "stop",
    "change", "switch", "ask", "know", "safe",
    "not working", "aren't working", "arent working", "isn't working", "isnt working",
    "don't work", "dont work", "do not work", "doesn't work", "doesnt work",
    "does not work", "not helping", "wrong", "missed",
    "زيادة", "جرعة", "بلعت", "كلها", "وقفت", "ما تنفع", "ما ينفع", "ما يفيد", "غلط", "نسيت",
    "أوقف", "أغير", "أبدل", "أسأل", "أعرف",
)
# Words that may surround a bare "refill". Anything else names something this
# module cannot place, such as another drug, so the patient goes to a visit.
_BARE_FILLER = frozenset(
    phrase_tokens(
        "i need want would like a an my the please can could may get have to for of "
        "me do you this today now thanks medicine medicines medication medications "
        "meds prescription "
        "أبي أبغى أريد أحتاج ممكن لو سمحت من فضلك عندي لي اليوم الحين دوا دواء "
        "دوائي أدوية حبوب علاج وصفة"
    )
)
_REFILL_NEGATORS = tuple(
    phrase_tokens(item)
    for item in ("don't need", "dont need", "doesn't need", "ما", "لا", "مش")
)
# These sit before the request word itself, so "don't need" above cannot be used.
_REQUEST_NEGATORS = tuple(
    phrase_tokens(item)
    for item in (
        "don't", "dont", "doesn't", "doesnt", "didn't", "didnt", "can't", "cant", "cannot",
        "won't", "wont", "never", "ما", "لا", "مش",
    )
)
_POLITE_WORDS = frozenset(phrase_tokens("please لو سمحت من فضلك"))


def _phrases(items: Sequence[str]) -> tuple[tuple[str, ...], ...]:
    return tuple(phrase_tokens(item) for item in items)


_INTENTS = _phrases(INTENT_PHRASES)
_BARE_REFILLS = _phrases(BARE_REFILL_PHRASES)
_NOUNS = _phrases(MEDICATION_NOUNS)
_SYMPTOMS = _phrases(SYMPTOM_WORDS)
_CANCELS = _phrases(CANCEL_PHRASES)
_USUALS = _phrases(USUAL_PHRASES)
_REQUESTS = _phrases(REQUEST_PHRASES)
_CLASSES = {drug: _phrases(words) for drug, words in DRUG_CLASSES.items()}
_DRUG_NAMES = {drug: _phrases(names) for drug, names in DRUG_ARABIC_NAMES.items()}
_ARABIC_TO_LATIN = {
    phrase[0]: drug for drug, phrases in _DRUG_NAMES.items() for phrase in phrases
}


@dataclass(frozen=True)
class RefillMatch:
    medicine: str  # the exact entry from active_meds
    cue: str


def _drug_key(entry: str) -> str | None:
    words = normalise(entry).split()
    if not words:
        return None
    return _ARABIC_TO_LATIN.get(words[0], words[0])


def blocks_refill(tokens: Sequence[Token]) -> bool:
    """A symptom or a problem with the medicine: a nurse must hear this."""
    return contains_any(tokens, _SYMPTOMS) or contains_any(tokens, _CANCELS)


def _live_cue(
    tokens: Sequence[Token],
    phrases: Sequence[tuple[str, ...]],
    negators: Sequence[tuple[str, ...]] = _REFILL_NEGATORS,
) -> str | None:
    for phrase in phrases:
        for start in phrase_starts(tokens, phrase):
            if not is_negated(tokens, start, extra=negators):
                return " ".join(phrase)
    return None


def _is_medicine_alone(tokens: Sequence[Token]) -> bool:
    """True for "حبوب الضغط المعتادة": a medicine noun first, and nothing but its name."""
    if not any(token_matches(word, tokens[0].text) for phrase in _NOUNS for word in phrase):
        return False
    class_words = (phrase for phrases in _CLASSES.values() for phrase in phrases)
    allowed = {word for phrase in (*_NOUNS, *_USUALS, *class_words) for word in phrase}
    return all(
        token.text in _POLITE_WORDS or any(token_matches(word, token.text) for word in allowed)
        for token in tokens
    )


def _intent_cue(tokens: Sequence[Token]) -> str | None:
    cue = _live_cue(tokens, _INTENTS)
    if cue:
        return cue
    usual = _live_cue(tokens, _USUALS)
    if usual and (_live_cue(tokens, _REQUESTS, _REQUEST_NEGATORS) or _is_medicine_alone(tokens)):
        return usual
    return None


def _is_bare_request(tokens: Sequence[Token]) -> bool:
    bare = {word for phrase in _BARE_REFILLS for word in phrase}
    return all(
        any(token_matches(word, token.text) for word in bare | _BARE_FILLER)
        for token in tokens
    )


def detect(text: str, active_meds: Sequence[str]) -> RefillMatch | None:
    """Return the active medicine a patient is asking to refill, if any."""
    tokens = tokenise(text)
    if blocks_refill(tokens):
        return None
    cue = _intent_cue(tokens)
    if cue is None:
        return None

    medicines = [(entry, _drug_key(entry)) for entry in active_meds]
    medicines = [(entry, drug) for entry, drug in medicines if drug]
    has_noun = contains_any(tokens, _NOUNS)
    for entry, drug in medicines:
        names = ((drug,), *_DRUG_NAMES.get(drug, ()))
        if contains_any(tokens, names):
            return RefillMatch(entry, cue)
        if has_noun and contains_any(tokens, _CLASSES.get(drug, ())):
            return RefillMatch(entry, cue)

    bare_cue = _live_cue(tokens, _BARE_REFILLS)
    if bare_cue and len(medicines) == 1 and _is_bare_request(tokens):
        return RefillMatch(medicines[0][0], bare_cue)
    return None
