"""The generated corpus. Seeded and pure: the same tables give the same list, in order.

Nothing here imports backend. rules.py and journeys.py pass the tables in, so this module holds
only the ways of disturbing text and the frames to put a cue in. Each generator yields tuples
that start with a family name, and the golden rows keep that name, so a family can be sampled
from the golden files directly.

Families, by what they cover:

    edit.*        one change to a phrase: edit.diacritics, edit.shadda, edit.tatweel,
                  edit.alef.<form>, edit.alef_back.<form>, edit.ya, edit.ta_marbuta,
                  edit.digits.*, edit.case.*, edit.zero_width, edit.bidi, edit.space.<name>
                  (NBSP, tab, CRLF, CR, U+2028, U+2029, U+0085 and friends),
                  edit.apostrophe.<form>, edit.presentation, edit.proclitic.<form>, edit.mark.*
                  (U+0610, U+06D6 and decomposed U+0654, which are not dropped)
    frame.*       a phrase inside a sentence
    side.edit.*   the same edits on a compound side phrase
    neg.window.N  a negator N words before a cue, 0 to 5, in both languages
    neg.cross     a negator in the other language
    clause.<name> a clause break between negator and cue, one family per break
    decimal.*     38.5 does not break a clause, and 38. 5 does
    exception     an exception word between negator and cue
    affirmation   an affirmation word between negator and cue
    waw           a cue led by و
    never_negated a cue that holds its own negator, under another negator
    repeat        one occurrence negated and one not
    near_miss     blood pressure, blood test, sore throat, لما and the like
    long.*        2000 and 2001 code points, astral characters and marks at the cut
    number.*      huge digit strings, leading zeros
    turn.*        multi-turn: yes to a cue question, cues split across messages, denied then
                  fired, compounds with sides split over turns, no and unsure replies
"""

from __future__ import annotations

import random
import unicodedata
from collections.abc import Iterator, Sequence

SEED = 20261107

DIACRITICS = "ًٌٍَُِْ"
SHADDA = "ّ"
TATWEEL = "ـ"
ALEF_FORMS = {"hamza_above": "أ", "hamza_below": "إ", "madda": "آ", "wasla": "ٱ"}
ZERO_WIDTH = "​‌‍﻿"
BIDI = "‎‏‪‫‬‭‮⁦⁧⁨⁩"
ARABIC_INDIC = "٠١٢٣٤٥٦٧٨٩"
PERSIAN = "۰۱۲۳۴۵۶۷۸۹"
SPACES = {
    "nbsp": " ",
    "narrow_nbsp": " ",
    "ideographic": "　",
    "thin": " ",
    "two": "  ",
    "tab": "\t",
    "crlf": "\r\n",
    "cr": "\r",
    "lf": "\n",
    "ls": " ",
    "ps": " ",
    "nel": "\u0085",
    "vt": "\x0b",
    "ff": "\x0c",
    "fs": "\x1c",
}
APOSTROPHES = {"right": "’", "left": "‘", "modifier": "ʼ", "prime": "′"}
PROCLITICS = {
    "waw": "و", "fa": "ف", "ba": "ب", "lam": "ل", "al": "ال", "bal": "بال", "wal": "وال",
    "lil": "لل",
}
KEPT_MARKS = {"u0610": "ؐ", "u06d6": "ۖ"}
ARABIC_LETTERS = frozenset("ءآأؤإئابةتثجحخدذرزسشصضطظعغفقكلمنهوىي")

CLAUSE_BREAKS = {
    "comma": ",", "full_stop": ".", "arabic_comma": "،", "arabic_semicolon": "؛",
    "colon": ":", "question": "?", "arabic_question": "؟", "bang": "!", "newline": "\n",
    "but": "but", "however": "however", "though": "though", "although": "although",
    "and": "and", "lakin": "لكن", "walakin": "ولكن", "bas": "بس", "wabas": "وبس", "wa": "و",
}
PUNCTUATION_BREAKS = frozenset(
    {"comma", "full_stop", "arabic_comma", "arabic_semicolon", "colon", "question",
     "arabic_question", "bang", "newline"}
)

FRAMES_EN = (
    "i have {c}", "my husband says {c} today", "{c} since yesterday", "please help, {c}",
    "there is {c} now", "{c}!", "Doctor, {c}?",
)
FRAMES_AR = (
    "عندي {c}", "يا دكتور {c}", "{c} من أمس", "اليوم {c}", "أحس {c}", "{c}!", "{c}؟",
)
FILLERS_EN = ("really", "very", "much", "severe", "sudden", "recent", "big")
FILLERS_AR = ("شي", "اليوم", "كثير", "جدا", "حاليا", "مره", "الحين")
NEAR_MISSES = (
    "my blood pressure is high", "blood pressure", "i need a blood test",
    "blood test results please", "blood sugar check", "sore throat", "i have a sore throat",
    "sore throat and fever", "my throat is sore", "a chest x-ray", "chest infection",
    "chest cold", "a blood pressure cuff is tight", "i bled a little from a paper cut",
    "my baby has a fever", "fever and a pregnant sister", "my left arm", "pain in my left arm",
    "pain in my stomach", "pain on the left side", "swollen ankle", "swollen gums",
    "my face is red", "i can't sleep", "i cannot eat", "can't move my car", "no worries",
    "لما", "لما أكلت", "لما أمشي", "لما أكلت يوجعني بطني", "لما كنت صغير", "ضغط دم",
    "تحليل دم", "فحص دم", "سكر دم", "ألم حلق", "ألم في حلق", "وجع حلق", "التهاب حلق",
    "التهاب في حلق", "عندي التهاب حلق", "الضغط عالي", "حرارة عالية", "ما أقدر أنام",
    "ما أقدر آكل", "يدي توجعني", "رجلي توجعني", "صدري بخير", "ولدي عنده حرارة", "حامل",
    "أنا حامل", "نزيف بسيط من الأنف", "دم", "وجه", "حلق",
)
NUMBERS = (
    "99999999999999999999 days", "99999999999999999999", "007 days", "00 days", "0 days",
    "1 days", "2 day", "000000000000000000000000000007 days", "٠٠٧ يوم", "١٢ يوم",
    "99999999999999999999 أيام", "99999999999999999999/10", "007/10", "10/10", "11/10",
    "0/10", "00/10", "١٠/١٠", "۷ من ۱۰", "८ days", "८", "፩ days", "፩", "٨", "२/10",
)


def arabic_positions(text: str) -> list[int]:
    return [index for index, char in enumerate(text) if char in ARABIC_LETTERS]


def has_arabic_letters(text: str) -> bool:
    return any(char in ARABIC_LETTERS for char in text)


def _sprinkle(text: str, marks: str, rng: random.Random) -> str:
    """A mark after about half of the Arabic letters, and always after one."""
    positions = set(arabic_positions(text))
    chosen = {index for index in positions if rng.random() < 0.5} or set(list(sorted(positions))[:1])
    return "".join(
        char + (rng.choice(marks) if index in chosen else "") for index, char in enumerate(text)
    )


def _between(text: str, marks: str, rng: random.Random) -> str:
    """Marks dropped anywhere, also inside words."""
    if len(text) < 2:
        return rng.choice(marks) + text
    points = sorted(rng.sample(range(1, len(text)), k=min(3, len(text) - 1)), reverse=True)
    for point in points:
        text = f"{text[:point]}{rng.choice(marks)}{text[point:]}"
    return text


def presentation_table() -> dict[str, list[str]]:
    """Every single presentation form that NFKC folds to one Arabic letter."""
    table: dict[str, list[str]] = {}
    for code in [*range(0xFB50, 0xFE00), *range(0xFE70, 0xFEFD)]:
        form = chr(code)
        base = unicodedata.normalize("NFKC", form)
        if len(base) == 1 and base != form:
            table.setdefault(base, []).append(form)
    return table


_PRESENTATION = presentation_table()


def _presentation(text: str, rng: random.Random) -> str:
    return "".join(
        rng.choice(_PRESENTATION[char]) if char in _PRESENTATION else char for char in text
    )


def _random_case(text: str, rng: random.Random) -> str:
    return "".join(char.upper() if rng.random() < 0.5 else char.lower() for char in text)


def edits(text: str, rng: random.Random) -> Iterator[tuple[str, str]]:
    """Each single spelling change that applies to this text."""
    arabic = has_arabic_letters(text)
    latin = any(char.isascii() and char.isalpha() for char in text)
    if arabic:
        yield "edit.diacritics", _sprinkle(text, DIACRITICS, rng)
        yield "edit.shadda", _sprinkle(text, SHADDA, rng)
        yield "edit.tatweel", _sprinkle(text, TATWEEL, rng)
        for name, form in ALEF_FORMS.items():
            if "ا" in text:
                yield f"edit.alef.{name}", text.replace("ا", form)
            if form in text:
                yield f"edit.alef_back.{name}", text.replace(form, "ا")
        if "ي" in text or "ى" in text:
            yield "edit.ya", text.translate({ord("ي"): "ى", ord("ى"): "ي"})
        if "ة" in text or "ه" in text:
            yield "edit.ta_marbuta", text.translate({ord("ة"): "ه", ord("ه"): "ة"})
        yield "edit.presentation", _presentation(text, rng)
        for name, form in PROCLITICS.items():
            yield f"edit.proclitic.{name}", form + text
        for name, mark in KEPT_MARKS.items():
            yield f"edit.mark.{name}", _sprinkle(text, mark, rng)
        hamza_seats = [index for index, char in enumerate(text) if char in "اوي"]
        if hamza_seats:
            seat = rng.choice(hamza_seats)
            yield "edit.mark.u0654", f"{text[: seat + 1]}ٔ{text[seat + 1:]}"
    if latin:
        yield "edit.case.upper", text.upper()
        yield "edit.case.title", text.title()
        yield "edit.case.random", _random_case(text, rng)
    if any(char.isdigit() for char in text):
        yield "edit.digits.arabic_indic", text.translate(
            {ord(str(index)): form for index, form in enumerate(ARABIC_INDIC)}
        )
        yield "edit.digits.persian", text.translate(
            {ord(str(index)): form for index, form in enumerate(PERSIAN)}
        )
    yield "edit.zero_width", _between(text, ZERO_WIDTH, rng)
    yield "edit.bidi", _between(text, BIDI, rng)
    if " " in text:
        for name, space in SPACES.items():
            yield f"edit.space.{name}", text.replace(" ", space)
    yield "edit.space.leading", f"\r\n\t {text}"
    yield "edit.space.trailing", f"{text}  \u0085"
    if "'" in text:
        for name, form in APOSTROPHES.items():
            yield f"edit.apostrophe.{name}", text.replace("'", form)


def framed(cue: str, *, arabic: bool) -> Iterator[tuple[str, str]]:
    for index, frame in enumerate(FRAMES_AR if arabic else FRAMES_EN):
        yield f"frame.{index}", frame.format(c=cue)


def negation_window(
    cue: str, negator: str, fillers: Sequence[str], distance: int
) -> str:
    gap = " ".join(fillers[index % len(fillers)] for index in range(distance))
    return " ".join(part for part in (negator, gap, cue) if part)


def clause_break(cue: str, negator: str, name: str) -> Iterator[tuple[str, str]]:
    mark = CLAUSE_BREAKS[name]
    if name in PUNCTUATION_BREAKS:
        yield f"clause.{name}", f"{negator}{mark} {cue}"
        yield f"clause.{name}", f"{negator} {mark} {cue}"
        yield f"clause.{name}", f"{negator}{mark}{cue}"
    else:
        yield f"clause.{name}", f"{negator} {mark} {cue}"


def decimals(cue: str, negator: str) -> Iterator[tuple[str, str]]:
    yield "decimal.kept", f"{negator} 38.5 {cue}"
    yield "decimal.kept", f"{negator} ٣٨.٥ {cue}"
    yield "decimal.kept", f"{negator} 1.5 {cue}"
    yield "decimal.broken", f"{negator} 38. 5 {cue}"
    yield "decimal.broken", f"{negator} 38 .5 {cue}"
    yield "decimal.broken", f"{negator} a.b {cue}"


def long_messages(cue: str) -> Iterator[tuple[str, str]]:
    """Cues before and after the 2000 code point cut, and awkward characters on the cut."""
    filler = "a " * 1100
    yield "long.2000", (filler[: 2000 - len(cue) - 1] + " " + cue)
    yield "long.2000", (filler[: 2000 - len(cue)] + " " + cue)
    yield "long.2001", (filler[: 2001 - len(cue) - 1] + " " + cue)
    yield "long.after_cut", filler[:2100] + " " + cue
    yield "long.astral_at_cut", "a" * 1999 + "😀😀 " + cue
    yield "long.astral_at_cut", "ب" * 1999 + "𝒜" + cue
    yield "long.mark_at_cut", "a" * 1999 + "é́ " + cue
    yield "long.mark_at_cut", "ب" * 1999 + "ّٔ " + cue


def conversation_cases(
    *,
    cues: Sequence[str],
    cue_tokens: Sequence[Sequence[str]],
    compounds: Sequence[Sequence[str]],
    sides: dict[str, Sequence[Sequence[str]]],
    yes_words: Sequence[str],
    no_answers: Sequence[Sequence[str]],
    unsure_answers: Sequence[Sequence[str]],
    questions: Sequence[str],
    rng: random.Random,
) -> Iterator[tuple[str, list[dict], str]]:
    """(family, history, text) for check_conversation. History does not include `text`."""

    def asked(text: str) -> dict:
        return {"role": "assistant", "content": text}

    def said(text: str) -> dict:
        return {"role": "user", "content": text}

    def question_for(cue: str) -> str:
        return f"هل عندك {cue}؟" if has_arabic_letters(cue) else f"Do you have {cue}?"

    for index, cue in enumerate(cues):
        question = question_for(cue)
        yes = yes_words[index % len(yes_words)]
        yield "turn.yes_to_cue", [asked(question)], yes
        yield "turn.yes_to_cue", [asked(question)], f"{yes} {cue}"
        yield "turn.no_to_cue", [asked(question)], no_answers[index % len(no_answers)][0]
        yield "turn.unsure_to_cue", [asked(question)], " ".join(
            unsure_answers[index % len(unsure_answers)]
        )
        yield "turn.denied_then_fired", [said(f"no {cue}"), asked("Since when?")], cue
        yield "turn.denied_then_fired", [said(f"ما عندي {cue}"), asked("من متى؟")], cue
        yield "turn.denied_then_fired", [said(cue), asked("Since when?")], f"no {cue}"
        words = cue_tokens[index]
        if len(words) > 1:
            cut = 1 + index % (len(words) - 1)
            first, second = " ".join(words[:cut]), " ".join(words[cut:])
            yield "turn.split_cue", [said(first)], second
            yield "turn.split_cue", [said(first), asked("Where is it?")], second
            yield "turn.split_cue", [said(second), asked("Where is it?")], first

    for compound_index, names in enumerate(compounds):
        options = [list(sides[name]) for name in names]
        for repeat in range(10):
            chosen = [" ".join(rng.choice(phrases)) for phrases in options]
            yield "turn.compound_split", [said(chosen[0])], " ".join(chosen[1:])
            yield "turn.compound_split", [
                said(chosen[0]), asked(rng.choice(questions)),
            ], " ".join(chosen[1:])
            yield "turn.compound_reversed", [
                said(" ".join(chosen[1:])), asked(rng.choice(questions)),
            ], chosen[0]
            yield "turn.compound_asked", [
                asked(f"Any {chosen[0]}?"),
            ], chosen[-1]
            yield "turn.compound_asked_no", [
                asked(f"Any {chosen[0]}?"),
            ], f"no {chosen[-1]}"
            yield "turn.compound_denied", [said(f"no {chosen[0]}")], " ".join(chosen[1:])

    for phrase in no_answers:
        answer = " ".join(phrase)
        for question in questions:
            yield "turn.no_reply", [asked(question)], answer
            yield "turn.no_reply", [asked(question)], f"{answer} chest pain"
    for phrase in unsure_answers:
        answer = " ".join(phrase)
        for question in questions:
            yield "turn.unsure_reply", [asked(question)], answer


def cue_sample(items: Sequence, size: int, rng: random.Random) -> list:
    return rng.sample(list(items), k=min(size, len(items)))


# Scripted conversations. The same plans feed the next_turn goldens and the session goldens.
# Each dimension steps through its own list with a length that shares no factor with the
# others, so a few hundred plans cross every pair of dimensions.

DURATIONS = {
    "en": (
        "3 days", "since yesterday", "for a week", "two weeks", "last night", "a month ago",
        "about 5 hours", "yesterday", "since this morning", "i don't know", "1 day", "ten days",
        "007 days", "99999999999999999999 days",
    ),
    "ar": (
        "من ثلاث أيام", "يومين", "من أمس", "أسبوعين", "البارحة", "من الصبح", "شهرين", "٣ أيام",
        "ما أدري", "من يوم", "سنتين", "لي أسبوع", "مبارح", "صارلي ساعة", "007 يوم",
    ),
}
SEVERITIES = {
    "en": (
        "6", "٦", "7/10", "8 out of 10", "seven", "about 5", "11", "-3", "7.5", "bad",
        "it is a 4", "0", "10", "ten out of ten", "maybe 3 or 4", "99999999999999999999",
        "۷", "२",
    ),
    "ar": (
        "٦", "6", "٧ من ١٠", "ثمانية", "سبعة من عشرة", "حوالي 5", "شديد", "١١", "٠", "١٠",
        "۷", "3 على 10", "مو كثير", "أربعة", "7.5",
    ),
}
MEDICINE_ANSWERS = {
    "en": (
        "panadol", "no", "nothing", "i took ibuprofen and panadol", "took 2 tablets of adol",
        "i want antibiotics", "didn't take anything", "paracetamol 500 mg", "cough syrup",
        "no paracetamol", "nurofen", "none",
    ),
    "ar": (
        "بنادول", "لا", "ما أخذت شي", "أخذت بروفين وبنادول", "شراب كحة", "أبي مضاد حيوي", "مافي",
        "أخذت بنادول 500 ملغ", "لم آخذ", "مسكن", "ماشي", "فيتامين",
    ),
}
CONCERN_ANSWERS = {
    "en": (
        "no", "nothing", "that's all", "i am worried about my work", "nope",
        "my mother had the same thing", "none",
    ),
    "ar": ("لا", "ما في", "بس كذا", "خايفة على شغلي", "خلاص", "ماشي", "ما شي"),
}
FOLLOW_UP_ANSWERS = {
    "en": ("yes", "no", "not really", "in my stomach", "my left side", "sometimes", "a little"),
    "ar": ("نعم", "لا", "ايوه", "في بطني", "جهة اليسار", "أحيانا", "شوي"),
}
INJECTED = {
    "en": (
        "chest pain", "i can't breathe", "i want to end my life", "my baby is not feeding",
        "i fainted", "severe bleeding",
    ),
    "ar": (
        "ألم في الصدر", "ما أقدر أتنفس", "أبي أأذي نفسي", "الطفل ما يرضع", "أغمي علي", "نزيف شديد",
    ),
}
READ_BACK_REPLIES = {
    "en": (
        "actually it is 8", "8, not 6", "it is not 8", "no", "yes that is right",
        "i took 2 tablets", "sorry, more like 3", "actually 2 weeks", "፩",
    ),
    "ar": ("لا، ثمانية", "قصدي ٨", "مو ٨", "صحيح", "نعم", "الشدة صارت 9", "لا"),
}


def plans(complaints: dict[str, dict[str, list[str]]], patients: Sequence[str], count: int):
    """(family, plan) for the plain complaint conversations, with no injected event."""
    names = sorted(complaints)
    for index in range(count):
        lang = "ar" if index % 2 else "en"
        name = names[index % len(names)]
        forms = complaints[name][lang]
        form = forms[index // len(names) % len(forms)]
        first = f"عندي {form}" if lang == "ar" else f"i have {form}"
        duration = DURATIONS[lang][index % len(DURATIONS[lang])]
        if index % 3 == 0:
            first = f"{first} {duration}"
        yield f"plan.{name}", {
            "lang": lang,
            "patient": patients[index % len(patients)],
            "messages": {
                "complaint": first,
                "duration": duration,
                "severity": SEVERITIES[lang][index % len(SEVERITIES[lang])],
                "medicine": MEDICINE_ANSWERS[lang][index % len(MEDICINE_ANSWERS[lang])],
                "other": CONCERN_ANSWERS[lang][index % len(CONCERN_ANSWERS[lang])],
                "followup": FOLLOW_UP_ANSWERS[lang][index % len(FOLLOW_UP_ANSWERS[lang])],
            },
            "read_back": READ_BACK_REPLIES[lang][index % len(READ_BACK_REPLIES[lang])],
            "inject": None,
        }


def with_injection(plan: dict, turn: int, text: str) -> dict:
    """The same plan with `text` in place of the message at this turn."""
    return {**plan, "inject": [turn, text]}


def next_message(plan: dict, turn: int, slot: str | None) -> str:
    injection = plan["inject"]
    if injection is not None and injection[0] == turn:
        return injection[1]
    return plan["messages"].get(slot or "complaint") or plan["messages"]["other"]
