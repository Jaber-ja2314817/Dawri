"""Text normalisation and the shared negation rule for the safety layer.

Pure functions only. Everything that looks for words in patient or model text
goes through here, so Arabic diacritics, tatweel and letter variants cannot
change what the red-flag rules, refill detection or banned-output filters see.
"""
from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from functools import lru_cache
from typing import Iterable, Sequence

_DROPPED = re.compile(
    "[\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff"  # zero-width and bidi marks
    "\u064b-\u065f\u0670"  # Arabic diacritics
    "\u0640]"  # tatweel
)

_CHAR_MAP = str.maketrans(
    {
        "أ": "ا",
        "إ": "ا",
        "آ": "ا",
        "ٱ": "ا",
        "ى": "ي",
        "ة": "ه",
        "’": "'",
        "‘": "'",
        "ʼ": "'",
        **{chr(0x0660 + i): str(i) for i in range(10)},  # Arabic-Indic digits
        **{chr(0x06F0 + i): str(i) for i in range(10)},  # Persian digits
    }
)

_LINE_BREAKS = re.compile("\r\n?|[\x0b\x0c\x85\u2028\u2029]")
_HORIZONTAL_SPACE = re.compile(r"[^\S\n]+")
_SPACE_AT_NEWLINE = re.compile(r" ?\n ?")

_WORD = re.compile(r"\w+(?:'\w+)?")
_ARABIC_LETTER = re.compile(
    "[\u0620-\u064a\u066e-\u06d3\u06fa-\u06fc\u0750-\u077f\u08a0-\u08ff"
    "\ufb50-\ufdff\ufe70-\ufefc]"
)
_SENTENCE_END = re.compile(
    r"(?:[!?؟]|(?<!\d)\.|\.(?!\d))[.!?؟\"'”»)\]]*|\n"
)

_CLAUSE_PUNCTUATION = frozenset(",.،;؛:?؟!\n")
_CLAUSE_WORDS = frozenset(
    {"but", "however", "though", "although", "and", "لكن", "ولكن", "بس", "وبس", "و"}
)
_PROCLITICS = ("وال", "بال", "لل", "ال", "و", "ف", "ب", "ل")


def normalise(text: str) -> str:
    """Return the canonical form every safety check compares against."""
    text = unicodedata.normalize("NFKC", text)
    text = _DROPPED.sub("", text)
    text = text.translate(_CHAR_MAP).lower()
    text = _LINE_BREAKS.sub("\n", text)
    text = _HORIZONTAL_SPACE.sub(" ", text)
    text = _SPACE_AT_NEWLINE.sub("\n", text)
    return text.strip()


@dataclass(frozen=True)
class Token:
    text: str
    starts_clause: bool
    after_punctuation: bool = False  # a cue may not span this token's left edge


def _gap_breaks_clause(gap: str, before: str, after: str) -> bool:
    if gap == "." and before.isdigit() and after.isdigit():
        return False  # decimal point, as in 38.5
    return any(ch in _CLAUSE_PUNCTUATION for ch in gap)


def tokenise(text: str) -> list[Token]:
    """Split into word tokens and mark where each clause starts."""
    norm = normalise(text)
    tokens: list[Token] = []
    previous_end = 0
    for match in _WORD.finditer(norm):
        word = match.group()
        if not tokens:
            punctuated = False
            starts_clause = True
        else:
            gap = norm[previous_end:match.start()]
            punctuated = _gap_breaks_clause(gap, norm[previous_end - 1], word[0])
            starts_clause = punctuated or word in _CLAUSE_WORDS
        tokens.append(Token(word, starts_clause, punctuated))
        previous_end = match.end()
    return tokens


def phrase_tokens(phrase: str) -> tuple[str, ...]:
    """Return a phrase as the token tuple the matchers compare with."""
    return tuple(token.text for token in tokenise(phrase))


_NEGATORS: tuple[tuple[str, ...], ...] = tuple(
    phrase_tokens(phrase)
    for phrase in (
        "no",
        "not",
        "without",
        "denies",
        "don't have",
        "ما عندي",
        "مو",
        "مافي",
        "ما في",
        "بدون",
        "لا يوجد",
        "ليس",
    )
)

# A word between a negator and a cue that means the cue is not being denied:
# "not only chest pain", "ما عندي غير ألم في الصدر", "no relief from chest pain".
_NEGATION_EXCEPTIONS = frozenset(
    normalise(word)
    for word in (
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
        "إلا",
        "غير",
        "فقط",
        "سوى",
        "سبب",
        "دوا",
        "دواء",
        "علاج",
        "حل",
    )
)

# A word that says the patient has the symptom. In "no i have chest pain" the "no"
# answers something else, so a cue after one of these is not being denied. The
# negator test runs first, so "ما عندي" and "don't have" are still negators.
_ENGLISH_AFFIRMATIONS = frozenset(
    normalise(word)
    for word in ("i", "i'm", "im", "i've", "my", "it", "it's", "he", "she", "we", "they")
)
_ARABIC_AFFIRMATIONS = frozenset(
    normalise(word) for word in ("عندي", "فيني", "معي", "احس", "أحس", "أشعر", "حاس")
)


def _phrase_ends_at(
    tokens: Sequence[Token], position: int, phrase: Sequence[str]
) -> bool:
    start = position - len(phrase) + 1
    if start < 0:
        return False
    if any(tokens[start + i].text != word for i, word in enumerate(phrase)):
        return False
    return not any(tokens[i].starts_clause for i in range(start + 1, position + 1))


def _is_negation_exception(word: str) -> bool:
    """True for an exception word, bare or with an Arabic proclitic, as in بسبب."""
    return word in _NEGATION_EXCEPTIONS or not _NEGATION_EXCEPTIONS.isdisjoint(
        _proclitic_forms(word)
    )


def _is_affirmation(tokens: Sequence[Token], position: int) -> bool:
    """True when this token says the patient has the symptom.

    An Arabic word right after a negator is negated itself, as in "ليس عندي" and
    "لا يوجد عندي".
    """
    word = tokens[position].text
    if word in _ENGLISH_AFFIRMATIONS:
        return True
    if word not in _ARABIC_AFFIRMATIONS and _ARABIC_AFFIRMATIONS.isdisjoint(
        _proclitic_forms(word)
    ):
        return False
    return not any(
        _phrase_ends_at(tokens, position - 1, phrase) for phrase in _NEGATORS
    )


def is_negated(
    tokens: Sequence[Token],
    cue_start_index: int,
    window: int = 3,
    *,
    extra: Iterable[Sequence[str]] = (),
) -> bool:
    """Say whether a negator sits within `window` tokens before a cue, same clause.

    An exception word between the negator and the cue cancels the negation, so
    the red-flag rules fire on "not only chest pain". So does an affirmation word,
    there or opening the cue itself, so "no i have chest pain" fires.

    `extra` adds negator phrases for one caller, as token sequences. Refill
    detection needs this for "don't need"; the red-flag rules pass nothing. A
    negated refill cue sends the patient to a visit, which is the cautious way
    round, so the exception and affirmation words apply only when `extra` is empty.
    """
    if tokens[cue_start_index].starts_clause:
        return False
    phrases = (*_NEGATORS, *extra)
    has_exceptions = len(phrases) == len(_NEGATORS)
    if has_exceptions and _is_affirmation(tokens, cue_start_index):
        return False
    lowest = max(cue_start_index - window, 0)
    for position in range(cue_start_index - 1, lowest - 1, -1):
        if any(_phrase_ends_at(tokens, position, phrase) for phrase in phrases):
            return True
        if tokens[position].starts_clause:
            return False
        if has_exceptions and (
            _is_negation_exception(tokens[position].text)
            or _is_affirmation(tokens, position)
        ):
            return False
    return False


@lru_cache(maxsize=4096)
def _proclitic_forms(token: str) -> frozenset[str]:
    forms: set[str] = set()
    for proclitic in _PROCLITICS:
        if token.startswith(proclitic):
            stem = token[len(proclitic) :]
            forms.add(stem)
            if proclitic == "لل":  # ل + ال contracts, so للرضيع is ل + الرضيع
                forms.add("ال" + stem)
    return frozenset(forms)


def token_matches(cue_token: str, text_token: str) -> bool:
    """Exact match, or a match after stripping one Arabic proclitic from the text."""
    return text_token == cue_token or cue_token in _proclitic_forms(text_token)


def has_leading_waw(cue_token: str, text_token: str) -> bool:
    """True when the text token matched the cue only by carrying a leading و."""
    return text_token != cue_token and text_token.startswith("و")


def phrase_starts(tokens: Sequence[Token], phrase: Sequence[str]) -> list[int]:
    """Indexes where `phrase` occurs as consecutive tokens, not across punctuation."""
    starts = []
    for start in range(len(tokens) - len(phrase) + 1):
        for offset, word in enumerate(phrase):
            token = tokens[start + offset]
            if offset and token.after_punctuation:
                break
            if not token_matches(word, token.text):
                break
        else:
            starts.append(start)
    return starts


def contains_any(
    tokens: Sequence[Token], phrases: Iterable[Sequence[str]]
) -> bool:
    return any(phrase_starts(tokens, phrase) for phrase in phrases)


def has_arabic(text: str) -> bool:
    return _ARABIC_LETTER.search(text) is not None


def split_sentences(text: str) -> list[str]:
    """Split on . ! ? ؟ and newlines, keeping the end mark with its sentence."""
    sentences = []
    start = 0
    for match in _SENTENCE_END.finditer(text):
        sentences.append(text[start : match.end()].strip())
        start = match.end()
    sentences.append(text[start:].strip())
    return [sentence for sentence in sentences if sentence]
