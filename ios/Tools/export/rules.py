"""The red-flag, text and scripted-receptionist section.

DATA, written to Sources/DawriCore/Resources. A key is the Python name of the table, so
`_NEGATORS` here is text._NEGATORS. A tuple is a JSON array in the same order. A frozenset is a
sorted array, because its order means nothing. A dict is an array of [key, value] rows in
source order, because a JSON object would lose that order and the code iterates it.

engine.rules.unicode.json
    unidata_version, and inclusive [first,last] code point ranges:
    word     str.isalnum() or "_", which is Python's \\w
    space    str.isspace, which is Python's \\s and what str.strip and str.split use
    decimal  str.isdecimal, which is Python's \\d
    digit    str.isdigit, a superset of decimal
    decimal_values  [first,last,value of first]: value(cp) = value of first + (cp - first)
    intake_strip    the characters pydantic strips from an intake's text fields. It is not the
                    same set as `space`: U+001C to U+001F stay. Found by asking pydantic.

engine.rules.text.json
    _DROPPED (ranges), _CHAR_MAP ([code point, replacement]), _CLAUSE_PUNCTUATION, _CLAUSE_WORDS,
    _PROCLITICS, _NEGATORS (token tuples), _NEGATION_EXCEPTIONS, _ENGLISH_AFFIRMATIONS,
    _ARABIC_AFFIRMATIONS, _ARABIC_LETTER (ranges), _LINE_BREAKS (ranges, plus "\\r\\n" as one
    break), and literals: {waw, contracted_proclitic, article}, the Arabic that text.py's
    functions hard-code.

engine.rules.redflags.json
    CUES: [category, phrase, label_en, label_ar, never_negated, token tuple], in source order.
    CATEGORIES, YES_WORDS, _SIDES ([name, token tuples]), _NEVER_NEGATED_SIDES,
    _COMPOUNDS ([sides, category, label]), _NOT_THE_SIDE, _DENIED_WITH, _NOT_HERE, _NO_ANSWERS,
    _UNSURE_ANSWERS, _CUE_WORDS, _PATIENT_VOICE, _ASKED_SYMPTOMS, _LABEL_AR.
    denied_text: {en|ar: {prefix, separator}}, from calling the real function with sentinels.
    literals: the Arabic in _patient_word and _question_in, the compound cue joiner, and the
    category that means self-harm.

engine.rules.refill.json
    Every tuple, frozenset and dict at module level of refill.py, under its Python name.

engine.rules.simulated.json
    OPENING, QUESTIONS, FOLLOW_UPS, _EMERGENCY, _SUPPORT, _REFILL, _SUMMARY_INTRO, _SUMMARY_CHECK,
    _SUMMARY_LABELS, _SUMMARY_PLAIN, _COMPLAINT_FORMS, _COMPLAINTS, _COMPLAINT_AR, _PAIN_WORDS,
    _SERVICE_KEYWORDS, _GULF_MARKERS, _MEDICINES, _NOT_TAKEN, _NOT_A_DOSE_TAKEN, _NO_WORDS,
    _NO_PHRASES, _YES_WORDS, _WHERE_WORDS, _SLOT_HINTS, _NUMBER_WORDS, _UNITS, _DUALS, _AR_UNITS,
    _AR_POINTS, _CORRECTION_WORDS, MAX_QUESTIONS, NOT_A_QUESTION, _MAX_COMPLAINT,
    _MAX_PATIENT_WORDS, _MAX_SUMMARY, _MAX_CONCERNS, _SEVERITY_ASKS, session (_MAX_TEXT, _RULES_ONLY,
    _TAKES_RULES, _KEEPS_REFUSED), receptionist (_STAFF_ONLY), intake (SERVICES, LANGUAGES),
    and literals: the joiners _read_back and _read_back_complaint hard-code, the slot names, the
    complaints _follow_up reads, and the wording of the nurse line and the refill visit.

engine.rules.filters.json
    Only what check_reply(read_back=True) reaches, each under its Python name. Nothing that only
    gate_reply or check_handoff reads. literals: the Arabic question mark, the joined waw, and
    the English words _opens_like_question, _gives_advice, _is_order and _doses hard-code.

engine.rules.regex.json
    patterns: [{name, python, flags, icu, options, groups, value}]. `name` is module._NAME, or
    module._NAME[i] for an entry of _POINTS_IN_TIME, whose `value` is the fixed reading. `flags`
    are Python's, `icu` is the translation, and `options` are NSRegularExpression options.
    See icu.py for what the translation does.

engine.rules.manifest.json
    schema, unidata_version, sources ({path: sha256} of every Python source read), and
    files ({resource: sha256}).

GOLDENS, written to Fixtures/goldens/rules. Common layout in common.py. A family column is an
index into the file's `families` header. Every result comes from calling the real function.

text.json             [family, input, normalise, tokens, phrase_tokens, split_sentences, has_arabic]
                      tokens are [text, flags]: bit 0 starts_clause, bit 1 after_punctuation.
text_negation.json    [family, tokens, cue_start_index, window, extra, is_negated]
text_proclitics.json  [token, sorted _proclitic_forms, cue token, token_matches, has_leading_waw]
regex.json            [pattern name, input, matches], with a match [start, end, group spans...]
                      in code points. A group that did not take part is null.
redflags_single.json  [family, lang, text, hits, denied, categories, emergency, self_harm]
                      lang is 0 for English, 1 for Arabic (has_arabic). hits and denied are in
                      order, as indexes into the `hits` header of [category, cue, label_en,
                      label_ar]. categories index the `categories` header. emergency and
                      self_harm are 0 or 1.
redflags_conversation.json
                      [family, history, text, hits, denied, fired, categories, emergency, self_harm]
                      history rows are [role, content, slot]: role 0 is user, 1 assistant.
                      fired is sorted labels.
refill.json           [family, text, active_meds index, medicine or null, cue or null, blocks_refill]
parsers.json          [family, text, find_complaints, parse_medicines, parse_duration,
                      parse_duration tagged, parse_severity, parse_severity loose,
                      detect_lang with current en, detect_lang with current ar]
parsers_question_count.json
                      [history, question_count]
readback.json         [family, text, allowed_meds, ok, reasons] from check_reply(read_back=True)
readback_summary.json [family, intake, lang, reply, is_plain_line], with intake the object
                      summary_reply reads.
next_turn.json        [family, history, patient index, denied, lang, reply, slot, intake, language]
run_turn.json         [family, function, text, history, patient index, denied, lang, result]
                      function is run_turn or rule_emergency. result is null when rule_emergency
                      returned None, else [reply, done, emergency, intake, refill, denied, source,
                      emergency_category, self_harm, language, slot, events, fired], with events
                      [type, payload] rows. An intake row follows the `intake_keys` header.
"""

from __future__ import annotations

import ast
import random
import re
import sys
import tempfile
import unicodedata
from datetime import date
from pathlib import Path

from export import common, icu, variants

SOURCES = (
    "backend/ai/text.py",
    "backend/ai/redflags.py",
    "backend/ai/simulated.py",
    "backend/ai/receptionist.py",
    "backend/ai/refill.py",
    "backend/ai/filters.py",
    "backend/ai/intake.py",
    "backend/ai/session.py",
    "backend/ai/prompts.py",
)

ON = date(2026, 11, 7)
FILTER_TABLES = (
    "DRUG_NAMES", "_DRUG_PHRASES", "DISEASE_TERMS", "_CONDITION_TRIGGERS", "_HISTORY_OPENERS",
    "_SECOND_PERSON", "_CONDITION_OPENERS", "_REPORTING_VERBS", "_SYMPTOMS", "_GUESS_OPENERS",
    "_DIAGNOSIS_WORDS", "_REFUSALS", "_TOOK_WORDS", "_ADVICE_TRIGGERS", "_IMPERATIVES",
    "_HANDOFF_IMPERATIVES", "_HARMLESS_ORDERS", "_LEAD_INS", "_UNIT_CANONICAL", "_NUMBER_WORDS",
    "_QUEUE_TERMS", "_QUEUE_WORDS", "_PLACE_WORDS", "_WAIT_TERMS", "_QUESTION_OPENERS",
    "_QUESTION_SUBJECTS", "_SENTENCE_CLOSERS",
)
SIMULATED_TABLES = (
    "OPENING", "QUESTIONS", "FOLLOW_UPS", "_EMERGENCY", "_SUPPORT", "_REFILL", "_SUMMARY_INTRO",
    "_SUMMARY_CHECK", "_SUMMARY_LABELS", "_SUMMARY_PLAIN", "_COMPLAINT_FORMS", "_COMPLAINTS",
    "_COMPLAINT_AR", "_PAIN_WORDS", "_SERVICE_KEYWORDS", "_GULF_MARKERS", "_MEDICINES", "_NOT_TAKEN",
    "_NOT_A_DOSE_TAKEN", "_NO_WORDS", "_NO_PHRASES", "_YES_WORDS", "_WHERE_WORDS", "_SLOT_HINTS",
    "_NUMBER_WORDS", "_UNITS", "_DUALS", "_AR_UNITS", "_AR_POINTS", "_CORRECTION_WORDS",
    "MAX_QUESTIONS", "NOT_A_QUESTION", "_MAX_COMPLAINT", "_MAX_PATIENT_WORDS", "_MAX_SUMMARY",
    "_MAX_CONCERNS", "_SEVERITY_ASKS",
)
REDFLAG_TABLES = (
    "CATEGORIES", "YES_WORDS", "_SIDES", "_NEVER_NEGATED_SIDES", "_COMPOUNDS", "_NOT_THE_SIDE",
    "_DENIED_WITH", "_NOT_HERE", "_NO_ANSWERS", "_UNSURE_ANSWERS", "_CUE_WORDS", "_PATIENT_VOICE",
    "_ASKED_SYMPTOMS", "_LABEL_AR",
)
TEXT_SETS = (
    "_CLAUSE_PUNCTUATION", "_CLAUSE_WORDS", "_PROCLITICS", "_NEGATORS", "_NEGATION_EXCEPTIONS",
    "_ENGLISH_AFFIRMATIONS", "_ARABIC_AFFIRMATIONS",
)
SENTINEL = "⟦{}⟧"


def number(path: str, function: str, value: float) -> float:
    """A number a function hard-codes. Fails loudly once the source stops saying it."""
    tree = ast.parse((common.REPO / path).read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == function:
            found = [item.value for item in ast.walk(node) if isinstance(item, ast.Constant)]
            if value in found:
                return value
    raise SystemExit(f"{path}:{function} no longer holds the number {value!r}")


def plain(value):
    """A table as JSON: see the module docstring for why each container maps as it does."""
    if isinstance(value, dict):
        return [[key, plain(item)] for key, item in value.items()]
    if isinstance(value, (tuple, list)):
        return [plain(item) for item in value]
    if isinstance(value, frozenset):
        return sorted(value)
    return value


def tables(module, names) -> dict:
    return {name: plain(getattr(module, name)) for name in names}


def code_points(pattern: re.Pattern) -> list[list[int]]:
    return common.ranges(
        code for code in range(sys.maxunicode + 1) if pattern.fullmatch(chr(code))
    )


def checked_word_set() -> None:
    """icu.py writes \\w as [\\p{L}\\p{N}_]. That is only right while this holds."""
    for code in range(sys.maxunicode + 1):
        char = chr(code)
        python = char.isalnum() or char == "_"
        icu_set = unicodedata.category(char)[0] in "LN" or char == "_"
        if python != icu_set:
            raise SystemExit(f"\\w and [\\p{{L}}\\p{{N}}_] differ at U+{code:04X}")
        if char.isdecimal() != (unicodedata.category(char) == "Nd"):
            raise SystemExit(f"\\d and \\p{{Nd}} differ at U+{code:04X}")


def unicode_data() -> dict:
    from backend.ai.intake import Complaint
    from pydantic import TypeAdapter

    checked_word_set()
    points = [chr(code) for code in range(sys.maxunicode + 1)]
    decimal_values: list[list[int]] = []
    for char in points:
        if not char.isdecimal():
            continue
        code, value = ord(char), unicodedata.decimal(char)
        last = decimal_values[-1] if decimal_values else None
        if last and last[1] == code - 1 and last[2] + (code - last[0]) == value:
            last[1] = code
        else:
            decimal_values.append([code, code, value])
    adapter = TypeAdapter(Complaint)
    stripped = [
        ord(char)
        for char in points
        if (char.isspace() or char in "᠎​﻿\x00")
        and adapter.validate_python(f"a{char}") == "a"
    ]
    return {
        "schema": common.SCHEMA,
        "unidata_version": unicodedata.unidata_version,
        "word": common.ranges(ord(c) for c in points if c.isalnum() or c == "_"),
        "space": common.ranges(ord(c) for c in points if c.isspace()),
        "decimal": common.ranges(ord(c) for c in points if c.isdecimal()),
        "digit": common.ranges(ord(c) for c in points if c.isdigit()),
        "decimal_values": decimal_values,
        "intake_strip": common.ranges(stripped),
    }


def text_data() -> dict:
    from backend.ai import text

    path = "backend/ai/text.py"
    return {
        "schema": common.SCHEMA,
        "_DROPPED": code_points(text._DROPPED),
        "_CHAR_MAP": [[code, text._CHAR_MAP[code]] for code in sorted(text._CHAR_MAP)],
        **tables(text, TEXT_SETS),
        "_ARABIC_LETTER": code_points(text._ARABIC_LETTER),
        "_LINE_BREAKS": code_points(re.compile(f"(?:{text._LINE_BREAKS.pattern})")),
        "literals": {
            "waw": common.literal(path, "has_leading_waw", "و"),
            "contracted_proclitic": common.literal(path, "_proclitic_forms", "لل"),
            "article": common.literal(path, "_proclitic_forms", "ال"),
        },
    }


def redflags_data() -> dict:
    from backend.ai import redflags

    path = "backend/ai/redflags.py"
    one, two = SENTINEL.format(1), SENTINEL.format(2)
    wording = {}
    for lang in ("en", "ar"):
        line = redflags.denied_text([one, two], lang)
        prefix, rest = line.split(one)
        separator, tail = rest.split(two)
        assert tail == ""
        wording[lang] = {"prefix": prefix, "separator": separator}
    return {
        "schema": common.SCHEMA,
        "CUES": [
            [cue.category, cue.phrase, cue.label_en, cue.label_ar, cue.never_negated, list(tokens)]
            for cue, tokens in redflags._COMPILED
        ],
        **tables(redflags, REDFLAG_TABLES),
        "denied_text": wording,
        "literals": {
            "patient_word_prefix": common.literal(path, "_patient_word", "ت"),
            "patient_word_prefix_to": common.literal(path, "_patient_word", "ا"),
            "patient_word_suffixes": [
                common.literal(path, "_patient_word", "ك"),
                common.literal(path, "_patient_word", "ج"),
            ],
            "patient_word_suffix_to": common.literal(path, "_patient_word", "ي"),
            "question_marks": [
                common.literal(path, "_question_in", "?"),
                common.literal(path, "_question_in", "؟"),
            ],
            "compound_joiner": common.literal(path, "_compound_hits", " + "),
            "self_harm_category": common.literal(path, "self_harm", "self_harm"),
        },
    }


def refill_data() -> dict:
    from backend.ai import refill

    names = sorted(
        name
        for name, value in vars(refill).items()
        if isinstance(value, (tuple, frozenset, dict)) and not name.startswith("__")
    )
    return {"schema": common.SCHEMA, **tables(refill, names)}


def simulated_data() -> dict:
    from backend.ai import intake, receptionist, session, simulated

    path = "backend/ai/simulated.py"
    return {
        "schema": common.SCHEMA,
        **tables(simulated, SIMULATED_TABLES),
        "session": tables(session, ("_MAX_TEXT", "_RULES_ONLY", "_TAKES_RULES", "_KEEPS_REFUSED")),
        "receptionist": tables(receptionist, ("_STAFF_ONLY",)),
        "intake": tables(intake, ("SERVICES", "LANGUAGES")),
        "literals": {
            "read_back_joiner": {
                "ar": common.literal(path, "_read_back", "، "),
                "en": common.literal(path, "_read_back", ", "),
            },
            "complaint_joiner": {
                "ar": common.literal(path, "_read_back_complaint", " و"),
                "en": common.literal(path, "_read_back_complaint", " and "),
            },
            "complaint_split": common.literal(path, "_read_back_complaint", " and "),
            "read_back_end": common.literal(path, "_read_back", "."),
            "slots": {
                "complaint": common.literal(path, "next_turn", "complaint"),
                "duration": common.literal(path, "_next_question", "duration"),
                "severity": common.literal(path, "_next_question", "severity"),
                "followup": common.literal(path, "_next_question", "followup"),
                "medicine": common.literal(path, "_next_question", "medicine"),
                "other": common.literal(path, "_next_question", "other"),
            },
            "follow_up": {
                "pain": common.literal(path, "_follow_up", "pain"),
                "fever": common.literal(path, "_follow_up", "fever"),
                "vomiting": common.literal(path, "_follow_up", "vomiting"),
                "stomach_pain": common.literal(path, "_follow_up", "stomach pain"),
                "diarrhoea": common.literal(path, "_follow_up", "diarrhoea"),
                "dental": common.literal(path, "_follow_up", "dental"),
            },
            "intake_language": {
                "en": common.literal(path, "_intake_language", "en"),
                "gulf": common.literal(path, "_intake_language", "ar-gulf"),
                "msa": common.literal(path, "_intake_language", "ar-msa"),
            },
            "tagged_prefix": common.literal(path, "parse_duration", "from "),
            "since": common.literal(path, "_complaint_with_duration", "since"),
            "complaints_joiner": common.literal(path, "_build_intake", " and "),
            "location_joiner": common.literal(path, "_build_intake", ", "),
            "default_service": common.literal(path, "_build_intake", "gp"),
            "confidence": {
                "matched": number(path, "_build_intake", 0.85),
                "unmatched": number(path, "_build_intake", 0.6),
            },
            "nurse": {
                "severity_prefix": common.literal(path, "_nurse_summary", "severity "),
                "severity_suffix": common.literal(path, "_nurse_summary", "/10"),
                "took": common.literal(path, "_nurse_summary", "took "),
                "medicines_joiner": common.literal(path, "_nurse_summary", " and "),
                "joiner": common.literal(path, "_nurse_summary", ", "),
                "end": common.literal(path, "_nurse_summary", "."),
            },
            "refill_visit": {
                "fallback": common.literal(path, "gp_intake_after_refill", "medicine"),
                "complaint_suffix": common.literal(path, "gp_intake_after_refill", " refill"),
                "asked": common.literal(path, "gp_intake_after_refill", ", patient asked for a visit"),
                "service": common.literal(path, "gp_intake_after_refill", "gp"),
                "confidence": number(path, "gp_intake_after_refill", 0.85),
            },
        },
    }


def filters_data() -> dict:
    from backend.ai import filters

    path = "backend/ai/filters.py"
    return {
        "schema": common.SCHEMA,
        **tables(filters, FILTER_TABLES),
        "literals": {
            "question_marks": [
                common.literal(path, "_is_question", "?"),
                common.literal(path, "_is_question", "؟"),
            ],
            "joined_waw": common.literal(path, "_is_order", "و"),
            "any": common.literal(path, "_opens_like_question", "any"),
            "use": common.literal(path, "_gives_advice", "use"),
            "of": common.literal(path, "_gives_advice", "of"),
            "of_order": common.literal(path, "_is_order", "of"),
            "two_tablets": common.literal(path, "_doses", "2tablet"),
            "statement_joiner": common.literal(path, "_statement_part", ", "),
        },
    }


def regex_patterns() -> list[tuple[str, re.Pattern, str | None]]:
    from backend.ai import filters, medicines, simulated, text

    voice = common.function_constants("backend/ai/redflags.py", "_in_patient_voice")
    if r"\w+" not in voice:
        raise SystemExit("redflags._in_patient_voice no longer uses \\w+")
    latin = common.literal("backend/ai/simulated.py", "detect_lang", "[A-Za-z]")
    found: list[tuple[str, re.Pattern, str | None]] = [
        ("text._SENTENCE_END", text._SENTENCE_END, None)
    ]
    for name in ("_OUT_OF_TEN", "_SEVERITY_NUMBER", "_COUNTED", "_DUAL", "_SINGLE"):
        found.append((f"simulated.{name}", getattr(simulated, name), None))
    for index, (pattern, value) in enumerate(simulated._POINTS_IN_TIME):
        found.append((f"simulated._POINTS_IN_TIME[{index}]", pattern, value))
    for name in ("_COUNTED_ENGLISH", "_NOT_THIS_NUMBER"):
        found.append((f"simulated.{name}", getattr(simulated, name), None))
    for name in (
        "_DOSE", "_SPELLED_DOSE", "_ARABIC_DUAL_DOSE", "_TICKET", "_ORDINAL_PLACE", "_MINUTES",
        "_HOURS", "_COUNT", "_PAIN_SCALE", "_CLAUSE_SPLIT",
    ):
        found.append((f"filters.{name}", getattr(filters, name), None))
    found.append(("medicines._DOSE_UNIT", medicines._DOSE_UNIT, None))
    found.append(("redflags._in_patient_voice", re.compile(r"\w+"), None))
    found.append(("simulated.detect_lang", re.compile(latin), None))
    return found


def regex_data() -> dict:
    space = icu.space_set()
    patterns = []
    for name, pattern, value in regex_patterns():
        flag_names = [flag.name for flag in re.RegexFlag if pattern.flags & flag and flag is not re.UNICODE]
        patterns.append(
            {
                "name": name,
                "python": pattern.pattern,
                "flags": flag_names,
                "icu": icu.translate(pattern.pattern, space),
                "options": icu.options(pattern.flags),
                "groups": pattern.groups,
                "value": value,
            }
        )
    return {"schema": common.SCHEMA, "patterns": patterns}


def data() -> dict[str, bytes]:
    documents = {
        "engine.rules.unicode.json": unicode_data(),
        "engine.rules.text.json": text_data(),
        "engine.rules.redflags.json": redflags_data(),
        "engine.rules.refill.json": refill_data(),
        "engine.rules.simulated.json": simulated_data(),
        "engine.rules.filters.json": filters_data(),
        "engine.rules.regex.json": regex_data(),
    }
    files = {name: common.resource_bytes(document) for name, document in documents.items()}
    manifest = {
        "schema": common.SCHEMA,
        "unidata_version": unicodedata.unidata_version,
        "sources": common.sources(SOURCES),
        "files": {name: common.sha256(body) for name, body in sorted(files.items())},
    }
    return {**files, "engine.rules.manifest.json": common.manifest_bytes(manifest)}


# The corpus


class Families:
    """The family names of a file, as a header table."""

    def __init__(self) -> None:
        self.names = common.Index()

    def __call__(self, name: str) -> int:
        return self.names(name)

    @property
    def header(self) -> list[str]:
        return self.names.rows


class Corpus:
    def __init__(self) -> None:
        from backend.ai import redflags, text

        self.harvest = common.load_harvest()
        self.rng = random.Random(variants.SEED)
        self.cues = [cue.phrase for cue, _ in redflags._COMPILED]
        self.tokens = [list(tokens) for _, tokens in redflags._COMPILED]
        self.never_negated = [cue.phrase for cue in redflags.CUES if cue.never_negated]
        self.arabic = [cue for cue in self.cues if text.has_arabic(cue)]
        self.english = [cue for cue in self.cues if not text.has_arabic(cue)]
        words = [" ".join(phrase) for phrase in text._NEGATORS]
        self.negators_en = [word for word in words if not text.has_arabic(word)]
        self.negators_ar = [word for word in words if text.has_arabic(word)]
        self.calls = self.harvest["calls"]

    def harvested(self) -> list[tuple[str, str]]:
        """Every sentence from the tests and the vault, by where it came from."""
        found: list[tuple[str, str]] = []
        for row in self.calls["redflags.check"]:
            found.append(("harvest.check", row[0]))
        for row in self.calls["redflags.check_conversation"]:
            found.append(("harvest.conversation", row[0]))
        for row in self.calls["session.handle_message"]:
            if isinstance(row[0], str):
                found.append(("harvest.session", row[0]))
        for item in self.harvest["strings"]:
            found.append(("harvest.test_string", item))
        for item in self.harvest["vault"]:
            found.append(("harvest.vault", item))
        return found


def usable(folder: common.Folder, file: str, text) -> bool:
    if not isinstance(text, str):
        return False
    if not common.encodable(text):
        folder.exclude(file, text, "a lone surrogate, which a Swift String cannot hold")
        return False
    return True


# text.json and friends


def odd_characters() -> list[tuple[str, str]]:
    found = [
        ("unicode.sigma", "ΑΣ ΑΣ. Σ ΣΑ"),
        ("unicode.turkish_i", "İSTANBUL I ı"),
        ("unicode.sharp_s", "STRASSE straße ẞ"),
        ("unicode.ligature", "ﬁre ﬂu ﬀ"),
        ("unicode.fullwidth", "ＣＨＥＳＴ　ＰＡＩＮ １２３"),
        ("unicode.math", "𝐜𝐡𝐞𝐬𝐭 𝐩𝐚𝐢𝐧 𝟏𝟐𝟑"),
        ("unicode.circled", "① ② ⑩ ²"),
        ("unicode.roman", "Ⅷ ⅷ"),
        ("unicode.nul", "a\x00b \x00"),
        ("unicode.controls", "a\x1cb\x1dc\x1ed\x1fe"),
        ("unicode.empty", ""),
        ("unicode.only_space", " \t\n\r  "),
        ("unicode.only_marks", "َّـ‏"),
        ("unicode.apostrophe", "don't don’t don‘t donʼt don′t 'quoted' it's'not"),
        ("unicode.emoji", "😀 chest pain 😀 ألم في الصدر 👍🏽"),
        ("unicode.underscore", "chest_pain _chest pain_ ألم_في_الصدر"),
        ("unicode.mark_in_word", "é chest́ pain أ ؤ ئ كٔ"),
        ("unicode.sentences", 'Done. Really? "Yes!" (no.) 3.5 is 4. ok... ؟! a.b.'),
        ("unicode.digits", "٠١٢٣٤٥٦٧٨٩ ۰۱۲۳۴۵۶۷۸۹ ०१२३ ๐๑๒๓ 𝟎𝟏𝟐"),
    ]
    for start in range(0xFB50, 0xFE00, 0x40):
        found.append(("unicode.presentation_a", "".join(chr(c) for c in range(start, start + 0x40))))
    for start in range(0xFE70, 0xFEFD, 0x40):
        found.append(("unicode.presentation_b", "".join(chr(c) for c in range(start, min(start + 0x40, 0xFEFD)))))
    for start in range(0x0600, 0x0700, 0x20):
        found.append(("unicode.arabic_block", " ".join(chr(c) for c in range(start, start + 0x20))))
    for name, form in variants.SPACES.items():
        found.append((f"unicode.space.{name}", f"a{form}b {form} c{form}"))
    return found


def text_goldens(folder: common.Folder, corpus: Corpus) -> None:
    from backend.ai import text

    rng = random.Random(variants.SEED + 1)
    items = [*corpus.harvested(), *odd_characters()]
    for cue in rng.sample(corpus.cues, 60):
        items.extend(variants.edits(cue, rng))
    for name in variants.CLAUSE_BREAKS:
        items.extend(variants.clause_break("chest pain", "no", name))
        items.extend(variants.clause_break("ألم في الصدر", "ما عندي", name))
    items.extend(variants.decimals("chest pain", "no"))
    families = Families()
    rows = []
    for family, value in common.dedupe(items):
        if not usable(folder, "text", value):
            continue
        rows.append(
            [
                families(family),
                value,
                text.normalise(value),
                common.tokens_of(text.tokenise(value)),
                list(text.phrase_tokens(value)),
                text.split_sentences(value),
                1 if text.has_arabic(value) else 0,
            ]
        )
    folder.add(
        "text", "text",
        ["family", "input", "normalise", "tokens", "phrase_tokens", "split_sentences", "has_arabic"],
        {"families": families.header}, rows,
    )

    # is_negated
    fams = Families()
    negation = []
    negation_rows: list[list] = []
    for row in corpus.calls["text.is_negated"]:
        tokens, start, window, extra = row
        negation.append(("harvest.is_negated", tokens, start, window, extra))
    generated = []
    extras = [[], [["don't", "need"]], [["ما"], ["لا"]]]
    for negator in (*corpus.negators_en, *corpus.negators_ar):
        arabic = text.has_arabic(negator)
        fillers = variants.FILLERS_AR if arabic else variants.FILLERS_EN
        cue = "ألم في الصدر" if arabic else "chest pain"
        for distance in range(0, 6):
            value = variants.negation_window(cue, negator, fillers, distance)
            tokens = text.tokenise(value)
            starts = text.phrase_starts(tokens, text.phrase_tokens(cue))
            for window in (1, 2, 3, 4, 5, 6):
                for extra in extras:
                    generated.append(
                        (f"neg.window.{distance}", common.tokens_of(tokens), starts[0], window, extra)
                    )
    for words, name in (
        (sorted(text._NEGATION_EXCEPTIONS), "exception"),
        (sorted(text._ENGLISH_AFFIRMATIONS | text._ARABIC_AFFIRMATIONS), "affirmation"),
    ):
        for negator in (*corpus.negators_en, *corpus.negators_ar):
            for word in words:
                cue = "ألم في الصدر" if text.has_arabic(negator) else "chest pain"
                value = f"{negator} {word} {cue}"
                tokens = text.tokenise(value)
                for start in text.phrase_starts(tokens, text.phrase_tokens(cue)):
                    generated.append((name, common.tokens_of(tokens), start, 3, []))
    for family, tokens, start, window, extra in common.dedupe([*negation, *generated]):
        rebuilt = [text.Token(item[0], bool(item[1] & 1), bool(item[1] & 2)) for item in tokens]
        negation_result = text.is_negated(rebuilt, start, window, extra=[tuple(p) for p in extra])
        negation_rows.append(
            [fams(family), tokens, start, window, extra, 1 if negation_result else 0]
        )
    folder.add(
        "text_negation", "text",
        ["family", "tokens", "cue_start_index", "window", "extra", "is_negated"],
        {"families": fams.header}, negation_rows,
    )

    # proclitics
    stems = sorted({word for tokens in corpus.tokens for word in tokens if text.has_arabic(word)})
    english = ["chest", "pain", "و", "ال", "ب"]
    rows = []
    seen = set()
    for stem in [*stems[:200], *english]:
        for form in variants.PROCLITICS.values():
            for token in (f"{form}{stem}", stem, f"{form}{form}{stem}"):
                key = (token, stem)
                if key in seen:
                    continue
                seen.add(key)
                rows.append(
                    [
                        token,
                        sorted(text._proclitic_forms(token)),
                        stem,
                        1 if text.token_matches(stem, token) else 0,
                        1 if text.has_leading_waw(stem, token) else 0,
                    ]
                )
    folder.add(
        "text_proclitics", "text",
        ["token", "proclitic_forms", "cue_token", "token_matches", "has_leading_waw"], {}, rows,
    )


# regex.json

BOUNDARY_TEMPLATES = (
    "{s}", " {s} ", "x{s}", "{s}x", "_{s}", "{s}_", "١{s}", "{s}١", "1{s}", "{s}1", "ا{s}", "{s}ا",
    "ّ{s}", "{s}ّ", "́{s}", "{s}́", ".{s}", "{s}.", "𝐚{s}", "{s}𝐚", "-{s}",
    "{s}-", "‍{s}", "{s}‍", "\n{s}\n", " {s} ", " {s}", "٣{s}", "३{s}",
)
REGEX_SEEDS = {
    "text._SENTENCE_END": (
        "Done.", "Really?", "yes!", "3.5", "3. 5", "3 .5", "a.b", "ok...", "what?!", "لا؟", 'no."',
        "(no.)", "«لا.»", "line\nline", "4.", ".5", "1.5.", "”.",
    ),
    "simulated._OUT_OF_TEN": (
        "7/10", "7 / 10", "8 out of 10", "seven out of ten", "ثمانية من عشره", "٧ من ١٠", "9 over 10",
        "5 على 10", "10/10", "11/10", "7/100", "1.5/10", "007/10", "ten/ten", "عشر من 10",
    ),
    "simulated._SEVERITY_NUMBER": ("6", "6.5", "-3", ".5", "10", "1.2.3", "007", "٦", "6-7"),
    "simulated._COUNTED": (
        "3 days", "three days", "ثلاث ايام", "1 day", "12 hours", "2 weeks", "3 months", "4 years",
        "5 اسابيع", "6 ساعات", "7 سنين", "8 شهور", "3days", "007 days", "0 days",
    ),
    "simulated._DUAL": ("يومين", "ليومين", "ويومين", "اسبوعين", "شهرين", "ساعتين", "سنتين", "بيومين"),
    "simulated._SINGLE": (
        "for a day", "since a week", "for one month", "a day ago", "an hour ago", "from a year",
        "من يوم", "منذ اسبوع", "قبل شهر", "صارلي ساعه", "لي سنه", "about an hour", "past week",
    ),
    "simulated._POINTS_IN_TIME[0]": ("yesterday", "امس", "مبارح", "من امس"),
    "simulated._POINTS_IN_TIME[1]": ("last night", "البارحه"),
    "simulated._POINTS_IN_TIME[2]": ("from this morning", "من الصبح", "since this morning"),
    "simulated._POINTS_IN_TIME[3]": ("from today", "من اليوم", "since today", "about today"),
    "simulated._COUNTED_ENGLISH": ("3 days", "1 week", "2 months", "4 hours", "5 year", "3  days"),
    "simulated._NOT_THIS_NUMBER": ("not 8", "مو ٨", "مش 3", "ليس 4", "not eight", "not  8", "not 8.5"),
    "filters._DOSE": (
        "500 mg", "500mg", "1.5 ml", "2 tablets", "3 tabs", "1 capsule", "500 ملغ", "2 حبه", "5 g",
        "5 grams", "10 mcg", "500 mg/kg", "500 mgs", "5g", "2 حبتين",
    ),
    "filters._SPELLED_DOSE": ("one tablet", "two pills", "half a tablet", "four capsules", "three pill"),
    "filters._ARABIC_DUAL_DOSE": ("حبتين", "قرصين", "وحبتين", "بقرصين", "لحبتين", "فحبتين"),
    "filters._TICKET": (
        "t-014", "d-gp-023", "p-031", "ت-014", "t014", "o2", "ل3", "و10", "ت123", "a-1", "ab-12",
        "t-0144", "t1", "t12", "t123", "t1234", "x-y-1",
    ),
    "filters._ORDINAL_PLACE": (
        "you are first", "you're the second", "youre 3rd", "you are the 21st", "انت الاول",
        "انتي الثانيه", "انت العاشر",
    ),
    "filters._MINUTES": ("5 min", "5 mins", "ten minutes", "خمس دقايق", "20 دقيقه", "1.5 min", "30minutes"),
    "filters._HOURS": ("hour", "hours", "2 hours", "an hour", "hrs", "ساعه", "وساعات", "بساعتين", "2hr", "لساعه"),
    "filters._COUNT": ("3", "one", "واحد", "وثلاث", "twelve", "ten", "عشره", "two people"),
    "filters._PAIN_SCALE": ("0 to 10", "1-10", "0–10", "1 الي 10", "out of 10", "من 10", "0 ل 10", "2 to 10", "0 to 100"),
    "filters._CLAUSE_SPLIT": ("a, b", "a، b", "a; b", "a؛ b", "a b"),
    "medicines._DOSE_UNIT": ("500 mg", "500mg", "10 ML", "10Ml", "5 mgs", "5 mL ", "5 mgx", "5 g", "٥ mg"),
    "redflags._in_patient_voice": ("your", "chest_pain", "é", "don't", "عليك", "٣", "a b c"),
    "simulated.detect_lang": ("a", "Z", "1", "ا", "é", "ａ"),
}


def regex_goldens(folder: common.Folder, corpus: Corpus) -> None:
    from backend.ai import text

    rng = random.Random(variants.SEED + 2)
    sentences = [
        text.normalise(value)
        for _, value in corpus.harvested()
        if common.encodable(value) and len(value) < 200
    ]
    rows = []
    for name, pattern, _value in regex_patterns():
        seeds = REGEX_SEEDS.get(name)
        if seeds is None:
            raise SystemExit(f"no regex seeds for {name}")
        inputs = [template.format(s=seed) for seed in seeds for template in BOUNDARY_TEMPLATES]
        inputs += rng.sample(sentences, 120)
        for value in dict.fromkeys(inputs):
            matches = []
            for match in pattern.finditer(value):
                groups = []
                for group in range(1, pattern.groups + 1):
                    span = match.span(group)
                    groups.append(None if span == (-1, -1) else list(span))
                matches.append([match.start(), match.end(), *groups])
            rows.append([name, value, matches])
    folder.add("regex", "regex", ["pattern", "input", "matches"], {}, rows)


# redflags_single.json


def redflag_inputs(corpus: Corpus) -> list[tuple[str, str]]:
    from backend.ai import redflags, text

    rng = random.Random(variants.SEED + 3)
    items: list[tuple[str, str]] = [*corpus.harvested()]

    for cue in corpus.cues:
        arabic = text.has_arabic(cue)
        items.append(("plain", cue))
        items.extend(variants.edits(cue, rng))
        items.extend(item for item in variants.edits(f"{cue} 3", rng) if item[0].startswith("edit.digits"))
        for family, framed in variants.framed(cue, arabic=arabic):
            items.append((family, framed))
        negators = rng.sample(corpus.negators_ar, 2) if arabic else corpus.negators_en
        fillers = variants.FILLERS_AR if arabic else variants.FILLERS_EN
        for negator in negators:
            for distance in range(0, 6):
                items.append(
                    (f"neg.window.{distance}", variants.negation_window(cue, negator, fillers, distance))
                )
        other = rng.choice(corpus.negators_en if arabic else corpus.negators_ar)
        for distance in (0, 1, 3):
            items.append(("neg.cross", variants.negation_window(cue, other, fillers, distance)))
        if arabic:
            items.append(("waw", f"و{cue}"))
            items.append(("waw", f"ما عندي و{cue}"))
            items.append(("waw", f"بدون {cue} و{cue}"))

    for side in sorted({" ".join(phrase) for phrases in redflags._SIDES.values() for phrase in phrases}):
        items.extend((f"side.{family}", value) for family, value in variants.edits(side, rng))

    for cue in rng.sample(corpus.english, 30):
        for negator in corpus.negators_en:
            for name in variants.CLAUSE_BREAKS:
                items.extend(variants.clause_break(cue, negator, name))
    for cue in rng.sample(corpus.arabic, 12):
        for negator in corpus.negators_ar:
            for name in variants.CLAUSE_BREAKS:
                items.extend(variants.clause_break(cue, negator, name))

    for cue in rng.sample(corpus.cues, 30):
        arabic = text.has_arabic(cue)
        negators = corpus.negators_ar if arabic else corpus.negators_en
        for negator in negators:
            items.extend(variants.decimals(cue, negator))

    exception_words = sorted(text._NEGATION_EXCEPTIONS)
    affirmations = sorted(text._ENGLISH_AFFIRMATIONS | text._ARABIC_AFFIRMATIONS)
    for cue in rng.sample(corpus.english, 10) + rng.sample(corpus.arabic, 5):
        negators = corpus.negators_ar if text.has_arabic(cue) else corpus.negators_en
        for negator in negators:
            for word in exception_words:
                items.append(("exception", f"{negator} {word} {cue}"))
                if text.has_arabic(word):
                    items.append(("exception", f"{negator} ب{word} {cue}"))
            for word in affirmations:
                items.append(("affirmation", f"{negator} {word} {cue}"))

    for cue in corpus.never_negated:
        for negator in (*corpus.negators_en, *corpus.negators_ar):
            items.append(("never_negated", f"{negator} {cue}"))

    for cue in rng.sample(corpus.cues, 100):
        negator = corpus.negators_ar[0] if text.has_arabic(cue) else corpus.negators_en[0]
        items.append(("repeat", f"{negator} {cue}, {cue}"))
        items.append(("repeat", f"{cue}, {negator} {cue}"))
        items.append(("repeat", f"{negator} {cue} {negator} {cue}"))
        items.append(("repeat", f"{negator} {cue} but {cue}"))

    items.extend(("near_miss", value) for value in variants.NEAR_MISSES)
    for value in variants.NEAR_MISSES:
        items.append(("near_miss", f"no {value}"))
        items.append(("near_miss", f"ما عندي {value}"))

    for cue in ("chest pain", "ألم في الصدر", "i want to end my life"):
        items.extend(variants.long_messages(cue))

    # A sample of real sentences through the same edits.
    sentences = [value for _, value in corpus.harvested() if isinstance(value, str) and len(value) < 120]
    for value in rng.sample(sentences, 150):
        items.extend(variants.edits(value, rng))
    return items


def redflags_goldens(folder: common.Folder, corpus: Corpus) -> None:
    from backend.ai import redflags, text

    families = Families()
    hits = common.Index()
    categories = common.Index()
    for category in redflags.CATEGORIES:
        categories(category)
    rows = []
    counts = {"en": 0, "ar": 0}
    reported: dict[str, int] = {cue: 0 for cue in corpus.cues}
    cased: list[str] = []
    for family, value in common.dedupe(redflag_inputs(corpus)):
        if not usable(folder, "redflags_single", value):
            continue
        result = redflags.check(value)
        lang = 1 if text.has_arabic(value) else 0
        counts["ar" if lang else "en"] += 1
        for hit in (*result.hits, *result.denied):
            reported[hit.cue] += 1
        cased.append(value)
        rows.append(
            [
                families(family),
                lang,
                value,
                [hits([hit.category, hit.cue, hit.label_en, hit.label_ar]) for hit in result.hits],
                [hits([hit.category, hit.cue, hit.label_en, hit.label_ar]) for hit in result.denied],
                [categories(category) for category in result.categories],
                1 if result.emergency else 0,
                1 if result.self_harm else 0,
            ]
        )
    folder.add(
        "redflags_single", "redflags_single",
        ["family", "lang", "text", "hits", "denied", "categories", "emergency", "self_harm"],
        {"families": families.header, "hits": hits.rows, "categories": categories.rows},
        rows,
    )

    # A cue under a label an earlier cue already holds never shows in a result, so a cue's
    # coverage is the cases where it matched, whether or not it won the label.
    matched = dict(reported)
    tokenised = None
    for (cue, phrase), count in zip(redflags._COMPILED, reported.values()):
        if count >= 10:
            continue
        if tokenised is None:
            tokenised = [text.tokenise(value) for value in cased]
        matched[cue.phrase] = sum(1 for tokens in tokenised if text.phrase_starts(tokens, phrase))
    folder.notes["redflags_single"] = {
        "by_language": counts,
        "cues": len(corpus.cues),
        "fewest_cases_for_a_cue": min(matched.values()),
        "cues_with_under_10_cases": sorted(cue for cue, count in matched.items() if count < 10),
        "cues_matched_but_shadowed_by_an_earlier_cue_of_the_same_label": sorted(
            cue for cue, count in reported.items() if count < 10
        ),
    }


def history_row(history) -> list[list]:
    return [
        [0 if message["role"] == "user" else 1, message["content"], message.get("slot")]
        for message in history
    ]


def conversation_goldens(folder: common.Folder, corpus: Corpus) -> None:
    from backend.ai import redflags, simulated

    rng = random.Random(variants.SEED + 4)
    questions = [
        *(wording[lang] for wording in simulated.QUESTIONS.values() for lang in ("en", "ar")),
        *(wording[lang] for wording in simulated.FOLLOW_UPS.values() for lang in ("en", "ar")),
        "Do you want to hurt yourself?", "أغمي عليك؟", "تنزف؟", "Is the pain in your chest?",
        "Did you lose consciousness?", "Any vomiting? Patient denied: chest pain.",
    ]
    cases = [
        ("harvest.conversation", row[1], row[0]) for row in corpus.calls["redflags.check_conversation"]
    ]
    # Sides only reach a decision through a compound, so an edited side has to be paired up.
    for sides, _category, _label in redflags._COMPOUNDS:
        for name in sides:
            others = [" ".join(rng.choice(redflags._SIDES[other])) for other in sides if other != name]
            for phrase in rng.sample(redflags._SIDES[name], min(8, len(redflags._SIDES[name]))):
                for family, value in rng.sample(list(variants.edits(" ".join(phrase), rng)), 3):
                    cases.append((f"side.{family}", [], " ".join([value, *others])))
    for family, history, value in variants.conversation_cases(
        cues=corpus.cues[::5],
        cue_tokens=corpus.tokens[::5],
        compounds=[sides for sides, _category, _label in redflags._COMPOUNDS],
        sides=redflags._SIDES,
        yes_words=sorted(redflags.YES_WORDS),
        no_answers=redflags._NO_ANSWERS,
        unsure_answers=redflags._UNSURE_ANSWERS,
        questions=questions,
        rng=rng,
    ):
        cases.append((family, history, value))

    families = Families()
    hits = common.Index()
    categories = common.Index()
    rows = []
    for family, history, value in common.dedupe(cases):
        if not common.encodable([history, value]):
            folder.exclude("redflags_conversation", value, "a lone surrogate, which a Swift String cannot hold")
            continue
        result = redflags.check_conversation(value, history)
        rows.append(
            [
                families(family),
                history_row(history),
                value,
                [hits([hit.category, hit.cue, hit.label_en, hit.label_ar]) for hit in result.hits],
                [hits([hit.category, hit.cue, hit.label_en, hit.label_ar]) for hit in result.denied],
                sorted(result.fired),
                [categories(category) for category in result.categories],
                1 if result.emergency else 0,
                1 if result.self_harm else 0,
            ]
        )
    folder.add(
        "redflags_conversation", "redflags_conversation",
        ["family", "history", "text", "hits", "denied", "fired", "categories", "emergency", "self_harm"],
        {"families": families.header, "hits": hits.rows, "categories": categories.rows},
        rows,
    )


# refill.json

MED_LISTS = (
    [],
    ["amlodipine 5 mg once daily"],
    ["metformin 500 mg twice daily"],
    ["amlodipine 5 mg once daily", "metformin 500 mg twice daily"],
    ["أملوديبين 5 ملغ"],
    ["ميتفورمين 500 ملغ", "amlodipine 5 mg once daily"],
    ["atorvastatin 10 mg"],
    ["", "  "],
)


def refill_inputs(corpus: Corpus) -> list[tuple[str, str]]:
    from backend.ai import refill

    rng = random.Random(variants.SEED + 5)
    things_en = (
        "amlodipine", "metformin", "blood pressure tablets", "pressure pills", "sugar medicine",
        "diabetes meds", "bp pills", "medicine", "tablets", "prescription", "hypertension meds",
        "atorvastatin",
    )
    things_ar = (
        "أملوديبين", "ميتفورمين", "حبوب الضغط", "دوا السكر", "علاج السكري", "دواء الضغط", "حبوب",
        "علاج", "دوا", "أدوية",
    )
    items: list[tuple[str, str]] = []
    for row in corpus.calls["refill.detect"]:
        items.append(("harvest.detect", row[0]))
    for intent in refill.INTENT_PHRASES:
        for thing in (*things_en, *things_ar):
            items.append(("intent", f"{intent} {thing}"))
            items.append(("intent", f"i {intent} my {thing}"))
            items.append(("intent", f"{thing} {intent}"))
    for usual in refill.USUAL_PHRASES:
        for thing in (*things_en, *things_ar):
            items.append(("usual", f"{thing} {usual}"))
            for request in refill.REQUEST_PHRASES:
                items.append(("usual", f"{request} {usual} {thing}"))
    for phrase in ("refill", "refill please", "i want a refill", "i need a refill today",
                   "can i get a refill", "refill my medicine", "تجديد", "أبي تجديد",
                   "ممكن تجديد لو سمحت", "تجديد الوصفة", "refill for my son", "refill aspirin"):
        items.append(("bare", phrase))
    for negator in ("don't need", "dont need", "doesn't need", "ما", "لا", "مش", "no", "not"):
        for thing in things_en[:5] + things_ar[:5]:
            for distance in range(0, 5):
                gap = " ".join(variants.FILLERS_EN[:distance])
                items.append((f"negated.{distance}", f"{negator} {gap} refill {thing}"))
                items.append((f"negated.{distance}", f"{negator} {gap} ran out of {thing}"))
    bases = ("i need a refill of amlodipine", "ran out of my blood pressure pills", "أبي تجديد أملوديبين",
             "خلصت حبوب الضغط")
    for base in bases:
        for word in (*refill.SYMPTOM_WORDS, *refill.CANCEL_PHRASES):
            items.append(("blocked", f"{base} {word}"))
            items.append(("blocked", f"{word} {base}"))
    plain_refills = [value for family, value in items if family in ("intent", "usual", "bare")]
    for value in rng.sample(plain_refills, 220):
        items.extend(variants.edits(value, rng))
    return items


def refill_goldens(folder: common.Folder, corpus: Corpus) -> None:
    from backend.ai import refill, text

    families = Families()
    meds = common.Index()
    for row in MED_LISTS:
        meds(list(row))
    rows = []
    rng = random.Random(variants.SEED + 8)
    inputs = common.dedupe(refill_inputs(corpus))
    inputs = [inputs[index] for index in sorted(rng.sample(range(len(inputs)), 2400))]
    harvested_pairs = [(row[0], row[1]) for row in corpus.calls["refill.detect"]]
    # Each input runs with 0, 1 and 2 medicines; the harvested ones also with their own list.
    pairs = []
    for family, value in inputs:
        pairs.extend((family, value, row) for row in MED_LISTS[:4])
    pairs.extend(("harvest.detect", value, row) for value, row in harvested_pairs)
    seen = set()
    for family, value, active in pairs:
        key = common.text_of([value, active]) if common.encodable([value, active]) else None
        if key is None:
            folder.exclude("refill", value, "a lone surrogate, which a Swift String cannot hold")
            continue
        if key in seen:
            continue
        seen.add(key)
        match = refill.detect(value, active)
        rows.append(
            [
                families(family),
                value,
                meds(list(active)),
                None if match is None else match.medicine,
                None if match is None else match.cue,
                1 if refill.blocks_refill(text.tokenise(value)) else 0,
            ]
        )
    for value in ("i need a refill of amlodipine", "ran out of my blood pressure pills", "refill", "تجديد"):
        for active in MED_LISTS:
            key = common.text_of([value, list(active)])
            if key in seen:
                continue
            seen.add(key)
            match = refill.detect(value, list(active))
            rows.append(
                [
                    families("med_lists"),
                    value,
                    meds(list(active)),
                    None if match is None else match.medicine,
                    None if match is None else match.cue,
                    1 if refill.blocks_refill(text.tokenise(value)) else 0,
                ]
            )
    folder.add(
        "refill", "refill",
        ["family", "text", "active_meds", "medicine", "cue", "blocks_refill"],
        {"families": families.header, "active_meds": meds.rows},
        rows,
    )


# parsers.json


def parser_inputs(corpus: Corpus) -> list[tuple[str, str]]:
    from backend.ai import filters, simulated

    rng = random.Random(variants.SEED + 6)
    items: list[tuple[str, str]] = []
    for name in (
        "simulated.find_complaints", "simulated.parse_medicines", "simulated.parse_duration",
        "simulated.parse_severity", "simulated.detect_lang",
    ):
        items.extend((f"harvest.{name.split('.')[1]}", row[0]) for row in corpus.calls[name])
    for value in variants.NUMBERS:
        items.append(("number.edge", value))
        items.append(("number.edge", f"from {value}"))
        items.append(("number.edge", f"it has been {value}"))
    items.append(("number.edge", "1" * 4300 + " days"))
    items.append(("number.edge", "1" * 4301 + " days"))
    for count in ("1", "2", "3", "12", "٣", "۴", "one", "two", "three", "ten", "ثلاث", "خمسة", "عشر", "واحد"):
        for unit in sorted(simulated._UNITS):
            items.append(("duration.counted", f"{count} {unit}"))
            items.append(("duration.counted", f"from {count} {unit}"))
    for word in simulated._DUALS:
        for lead in ("", "و", "ل", "ب", "من "):
            items.append(("duration.dual", f"{lead}{word}"))
    for lead in ("for", "since", "from", "about", "past", "last", "over", "almost", "nearly", "من", "منذ", "قبل", "صار", "صارلي", "لي", "له", "حوالي"):
        for unit in ("day", "week", "month", "hour", "year", "يوم", "اسبوع", "شهر", "ساعه", "سنه"):
            items.append(("duration.single", f"{lead} {unit}"))
            items.append(("duration.single", f"{lead} a {unit}"))
    for unit in ("day", "week", "month", "hour", "year"):
        items.append(("duration.ago", f"a {unit} ago"))
    for value in ("yesterday", "last night", "this morning", "today", "امس", "مبارح", "البارحة", "الصبح", "اليوم"):
        for lead in ("", "since ", "from ", "من "):
            items.append(("duration.point", f"{lead}{value}"))
    for number in range(0, 13):
        for form in ("{}", "{}/10", "{} / 10", "{} out of 10", "{} over 10", "{} من 10", "{} على 10", "it is {}", "about {}", "{}.5"):
            items.append(("severity", form.format(number)))
            items.append(("severity", form.format(str(number).translate({48 + i: chr(0x0660 + i) for i in range(10)}))))
    for word in simulated._NUMBER_WORDS:
        for form in ("{}", "{}/10", "{} out of ten", "{} من عشره", "it is {}"):
            items.append(("severity.word", form.format(word)))
    for canonical, forms in filters.DRUG_NAMES.items():
        for form in forms:
            items.append(("medicine", form))
            items.append(("medicine", f"i took {form}"))
            items.append(("medicine", f"أخذت {form}"))
            items.append(("medicine.not_taken", f"didn't take {form}"))
            items.append(("medicine.not_taken", f"ما أخذت {form}"))
            items.append(("medicine.wanted", f"i want {form}"))
            items.append(("medicine.wanted", f"allergic to {form}"))
            items.append(("medicine.wanted", f"should i take {form}"))
    for canonical, forms in simulated._COMPLAINT_FORMS.items():
        for form in forms:
            items.append(("complaint", form))
            items.append(("complaint", f"i have {form}"))
            items.append(("complaint", f"عندي {form}"))
            items.append(("complaint.negated", f"no {form}"))
            items.append(("complaint.negated", f"ما عندي {form}"))
            items.append(("complaint.waw", f"و{form}"))
            items.append(("complaint.pair", f"{form} and rash"))
    for sentence in (
        "hello there", "مرحبا كيف الحال", "ok", "نعم", "6", "٦", "hello مرحبا", "two words", "كلمتين هنا",
        "chest pain ألم", "ألم في الصدر chest", "a b مرحبا", "١٢٣ ٤٥٦", "1 2", "é é", "ＡＢ ＣＤ",
    ):
        items.append(("language", sentence))
    for value in rng.sample([v for _, v in corpus.harvested() if len(v) < 160], 2200):
        items.append(("sample", value))
    return items


def parser_goldens(folder: common.Folder, corpus: Corpus) -> None:
    from backend.ai import simulated

    families = Families()
    rows = []
    for family, value in common.dedupe(parser_inputs(corpus)):
        if not usable(folder, "parsers", value):
            continue
        try:
            row = [
                families(family),
                value,
                simulated.find_complaints(value),
                simulated.parse_medicines(value),
                simulated.parse_duration(value),
                simulated.parse_duration(value, tagged=True),
                simulated.parse_severity(value),
                simulated.parse_severity(value, loose=True),
                simulated.detect_lang(value, "en"),
                simulated.detect_lang(value, "ar"),
            ]
        except Exception as error:  # noqa: BLE001
            folder.exclude("parsers", value, f"the real function raised {type(error).__name__}: {error}")
            continue
        rows.append(row)
    folder.add(
        "parsers", "parsers",
        ["family", "text", "find_complaints", "parse_medicines", "parse_duration",
         "parse_duration_tagged", "parse_severity", "parse_severity_loose", "detect_lang_en",
         "detect_lang_ar"],
        {"families": families.header},
        rows,
    )

    histories = [row[0] for row in corpus.calls["simulated.next_turn"]]
    histories += [
        [],
        [{"role": "user", "content": "hi"}],
        [{"role": "assistant", "content": "x"}],
        [{"role": "assistant", "content": "x", "slot": "summary"}],
        [{"role": "user", "content": "hi"}, {"role": "assistant", "content": "x", "slot": "summary"}],
        [{"role": "assistant", "content": "x"}, {"role": "user", "content": "y"},
         {"role": "assistant", "content": "z", "slot": "duration"}],
    ]
    seen = set()
    rows = []
    for history in histories:
        row = history_row(history)
        key = common.text_of(row)
        if key not in seen:
            seen.add(key)
            rows.append([row, simulated.question_count(history)])
    folder.add("parsers_question_count", "parsers", ["history", "question_count"], {}, rows)


# readback.json


def readback_goldens(folder: common.Folder, corpus: Corpus) -> None:
    from backend.ai import filters, simulated

    rng = random.Random(variants.SEED + 7)
    sentences = [value for _, value in corpus.harvested() if isinstance(value, str) and len(value) < 200 and common.encodable(value)]
    drugs = list(filters.DRUG_NAMES)
    allowed_lists = ([], ["paracetamol"], ["paracetamol", "ibuprofen"], ["amlodipine 5 mg once daily"], ["بنادول"])
    cases = [("harvest.check_reply", row[0], row[1]) for row in corpus.calls["filters.check_reply"]]
    for value in rng.sample(sentences, 800):
        cases.append(("sample", value, rng.choice(allowed_lists)))
        wrapped = f"Thanks. Here is what I will tell the nurse: {value}. Is this right?"
        cases.append(("sample.summary_shape", wrapped, rng.choice(allowed_lists)))
    templates = (
        "34F, fever, took {d}.", "took {d}", "Thanks: {d}.", "{d} is best.", "you should take {d}",
        "take {d} 500 mg", "500 mg of {d}", "took {d} 500 mg", "أخذت {d}", "{d} أخذت", "خذ {d}",
        "Did you take {d}?", "Take {d}?", "you have {d}", "had {d}, tried {d}",
    )
    for canonical, forms in filters.DRUG_NAMES.items():
        for form in forms:
            for template in templates:
                value = template.replace("{d}", form)
                cases.append(("drug", value, []))
                cases.append(("drug", value, [canonical]))
    families = Families()
    rows = []
    for family, value, allowed in common.dedupe(cases):
        if not common.encodable([value, allowed]):
            folder.exclude("readback", value, "a lone surrogate, which a Swift String cannot hold")
            continue
        result = filters.check_reply(value, allowed_meds=allowed, read_back=True)
        rows.append([families(family), value, allowed, 1 if result.ok else 0, list(result.reasons)])
    folder.add(
        "readback", "readback",
        ["family", "text", "allowed_meds", "ok", "reasons"], {"families": families.header}, rows,
    )

    # summary_reply. A complaint outside the fixed words is read back in the patient's words,
    # so these are where the plain line must take over.
    complaints = [
        *simulated._COMPLAINT_AR,
        "fever and cough", "headache and rash and dizziness", "fever and unknown", "unknown thing",
    ]
    durations = (None, "3 days", "1 day", "2 weeks", "since yesterday", "since last night",
                 "since this morning", "since today", "12 hours", "1 year", "soon", "2 months", "")
    severities = (None, 0, 5, 7, 10)
    medicine_lists = ([], ["paracetamol"], ["ibuprofen", "paracetamol"], ["cough syrup"], ["antibiotic"],
                      ["insulin", "vitamin"])
    denied_lists = ([], ["chest pain"], ["chest pain", "fainting"], ["unknown label"])
    worded = [
        "fever", "take paracetamol 500 mg", "you have the flu", "i think it is a virus", "T-014 please",
        "you are next", "عندك سكر", "خذ بنادول", "take 2 tablets", "wait 5 minutes", "ticket", "عندي برد",
        "دواء الضغط", "اسم الدواء بنادول", "panadol helps", *rng.sample(sentences, 330),
    ]
    keys = ("chief_complaint", "chief_complaint_patient_words", "duration", "severity_0_10", "self_medication", "denied_red_flags")
    families = Families()
    rows = []
    seen = set()
    for index in range(1500):
        # Every other case reads back the patient's own words, which is where the filter bites.
        complaint = "unknown thing" if index % 2 else complaints[index % len(complaints)]
        words = worded[index % len(worded)]
        intake = dict(
            zip(
                keys,
                (
                    complaint, words,
                    durations[index % len(durations)],
                    severities[index % len(severities)],
                    medicine_lists[index % len(medicine_lists)],
                    denied_lists[index % len(denied_lists)],
                ),
            )
        )
        for lang in ("en", "ar"):
            key = common.text_of([intake, lang])
            if key in seen:
                continue
            seen.add(key)
            reply = simulated.summary_reply(intake, lang)
            plain_line = reply == simulated._SUMMARY_PLAIN["ar" if lang.startswith("ar") else "en"]
            rows.append([families("summary"), intake, lang, reply, 1 if plain_line else 0])
    folder.add(
        "readback_summary", "readback",
        ["family", "intake", "lang", "reply", "is_plain_line"], {"families": families.header}, rows,
    )
    folder.notes["readback_summary"] = {
        "plain_line_cases": sum(row[4] for row in rows),
        "read_back_cases": sum(1 - row[4] for row in rows),
    }


# next_turn.json and run_turn.json

INTAKE_KEYS = (
    "emergency", "language", "chief_complaint", "chief_complaint_patient_words", "duration",
    "severity_0_10", "associated", "self_medication", "service", "service_confidence",
    "summary_for_nurse", "refill_request", "questions_asked", "denied_red_flags", "patient_concerns",
)


def intake_row(intake: dict | None) -> list | None:
    if intake is None:
        return None
    assert set(intake) == set(INTAKE_KEYS), set(intake) ^ set(INTAKE_KEYS)
    return [intake[key] for key in INTAKE_KEYS]


def turn_row(result) -> list:
    return [
        result.reply,
        result.done,
        result.emergency,
        intake_row(result.intake),
        result.refill,
        result.denied,
        result.source,
        result.emergency_category,
        result.self_harm,
        result.language,
        result.slot,
        [[event.type, event.payload] for event in result.events],
        result.fired,
    ]


def seeded_patients() -> list[dict]:
    from backend import db, mock_health, seeding

    with tempfile.TemporaryDirectory(prefix="dawri-rules-") as scratch:
        conn = db.connect(Path(scratch) / "patients.db")
        db.init_schema(conn)
        seeding.seed_static(conn)
        found = [
            mock_health.get_patient(conn, row["id"], ON)
            for row in conn.execute("SELECT id FROM patient ORDER BY id")
        ]
        conn.close()
    return found


def complaints_by_language() -> dict[str, dict[str, list[str]]]:
    from backend.ai import simulated, text

    return {
        name: {
            "en": [form for form in forms if not text.has_arabic(form)],
            "ar": [form for form in forms if text.has_arabic(form)],
        }
        for name, forms in simulated._COMPLAINT_FORMS.items()
    }


def next_turn_goldens(folder: common.Folder, corpus: Corpus) -> None:
    from backend.ai import receptionist, runtime, session, simulated

    llm = runtime.build_runtime().llm
    if llm.mode != "simulated":
        raise SystemExit("the llm is not simulated")
    patients = {patient["id"]: patient for patient in seeded_patients()}
    patient_rows = common.Index()
    next_families = Families()
    run_families = Families()
    next_rows: list[list] = []
    run_rows: list[list] = []
    next_seen: set[str] = set()
    run_seen: set[str] = set()

    def note_next(family, history, patient, denied, lang) -> None:
        key = common.text_of([history, patient, denied, lang])
        if key in next_seen:
            return
        next_seen.add(key)
        try:
            turn = simulated.next_turn(history, patient, denied, lang)
        except Exception as error:  # noqa: BLE001
            folder.exclude("next_turn", history[-1]["content"] if history else "", f"the real function raised {type(error).__name__}: {error}")
            return
        next_rows.append(
            [next_families(family), history_row(history), patient_rows(patient), list(denied), lang,
             turn.reply, turn.slot, intake_row(turn.intake), turn.language]
        )

    def note_run(family, function, value, history, patient, denied, lang):
        key = common.text_of([function, value, history, patient, denied, lang])
        fresh = key not in run_seen
        run_seen.add(key)
        try:
            if function == "run_turn":
                result = receptionist.run_turn(llm, value, history, patient, denied, lang)
            else:
                result = receptionist.rule_emergency(value, history, patient, denied, lang)
        except Exception as error:  # noqa: BLE001
            folder.exclude("run_turn", value, f"the real function raised {type(error).__name__}: {error}")
            return None
        if fresh:
            run_rows.append(
                [run_families(family), function, value, history_row(history), patient_rows(patient),
                 denied, lang, None if result is None else turn_row(result)]
            )
        return result

    for row in corpus.calls["simulated.next_turn"]:
        if common.encodable(row):
            note_next("harvest.next_turn", *row)
    for row in corpus.calls["receptionist.run_turn"]:
        if common.encodable(row):
            note_run("harvest.run_turn", "run_turn", *row)
    for row in corpus.calls["receptionist.rule_emergency"]:
        if common.encodable(row):
            note_run("harvest.rule_emergency", "rule_emergency", *row)

    def play(family: str, plan: dict) -> None:
        patient = patients[plan["patient"]]
        language = "ar" if (patient.get("preferred_lang") or "ar").startswith("ar") else "en"
        history = [{"role": "assistant", "content": simulated.OPENING[language], "slot": "complaint"}]
        denied: list[str] = []
        slot = "complaint"
        for turn in range(9):
            message = variants.next_message(plan, turn, slot)
            result = note_run(family, "run_turn", message, history, patient, denied, language)
            if turn % 3 == 0:
                note_run(family, "rule_emergency", message, history, patient, denied, language)
            if result is None:
                return
            conversation = [*history, {"role": "user", "content": message, "slot": None}]
            note_next(family, conversation, patient, result.denied, result.language)
            history = [
                *conversation,
                {"role": "assistant", "content": result.reply, "slot": session._stored_slot(result)},
            ]
            merged = dict.fromkeys([*denied, *result.denied])
            denied = [label for label in merged if label not in result.fired]
            language = result.language
            if result.emergency or result.refill:
                return
            if result.done:
                if turn < 8 and plan["read_back"] is not None:
                    final = plan["read_back"]
                    note_run("read_back", "run_turn", final, history, patient, denied, language)
                    note_next(
                        "read_back",
                        [*history, {"role": "user", "content": final, "slot": None}],
                        patient, denied, language,
                    )
                return
            slot = result.slot

    ids = sorted(patients)
    all_plans = list(variants.plans(complaints_by_language(), ids, 300))
    for family, plan in all_plans:
        play(family, plan)
    for index, (family, plan) in enumerate(all_plans[:60]):
        lang = plan["lang"]
        text = variants.INJECTED[lang][index % len(variants.INJECTED[lang])]
        play(f"inject.{index % 6}", variants.with_injection(plan, index % 6, text))

    folder.add(
        "next_turn", "next_turn",
        ["family", "history", "patient", "denied", "lang", "reply", "slot", "intake", "language"],
        {"families": next_families.header, "patients": patient_rows.rows, "intake_keys": list(INTAKE_KEYS)},
        next_rows,
    )
    folder.add(
        "run_turn", "next_turn",
        ["family", "function", "text", "history", "patient", "denied", "lang", "result"],
        {
            "families": run_families.header,
            "patients": patient_rows.rows,
            "intake_keys": list(INTAKE_KEYS),
            "result_columns": ["reply", "done", "emergency", "intake", "refill", "denied", "source",
                               "emergency_category", "self_harm", "language", "slot", "events", "fired"],
        },
        run_rows,
    )


def goldens() -> dict[str, bytes]:
    folder = common.Folder("rules", SOURCES)
    corpus = Corpus()
    folder.notes["harvest"] = {
        key: corpus.harvest[key] for key in ("passed_tests", "failed_tests", "left_out")
    }
    text_goldens(folder, corpus)
    regex_goldens(folder, corpus)
    redflags_goldens(folder, corpus)
    conversation_goldens(folder, corpus)
    refill_goldens(folder, corpus)
    parser_goldens(folder, corpus)
    readback_goldens(folder, corpus)
    next_turn_goldens(folder, corpus)
    return folder.finish()
