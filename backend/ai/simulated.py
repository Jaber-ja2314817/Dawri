"""The scripted receptionist: same 6-question flow, deterministic, always labelled.

next_turn is a pure function of the history. Every slot comes from scanning all
the user messages, so this can take over mid-conversation from the model for a
single turn without restarting. A question's tag only helps read a bare answer
such as "6" or "لا", and untagged model questions are read by their keywords.

Nothing here computes a queue position, or invents a duration or a severity.
"""

from __future__ import annotations

import re
from collections import Counter
from collections.abc import Sequence
from dataclasses import dataclass, field

from backend.ai import filters, redflags
from backend.ai import intake as intake_schema
from backend.ai.prompts import MAX_QUESTIONS
from backend.ai.text import (
    Token,
    contains_any,
    has_arabic,
    has_leading_waw,
    is_negated,
    normalise,
    phrase_starts,
    phrase_tokens,
    tokenise,
)

# Marks a stored assistant message that was not a question, so it is not counted.
NOT_A_QUESTION = "summary"

_MAX_COMPLAINT = 200
_MAX_PATIENT_WORDS = 1000
_MAX_SUMMARY = 400
_MAX_CONCERNS = 500
_SEVERITY_ASKS = 2

OPENING = {"en": "What brings you in today?", "ar": "شو اللي يتعبك اليوم؟"}
QUESTIONS = {
    "duration": {"en": "Since when?", "ar": "من متى؟"},
    "severity": {"en": "How bad is it from 0 to 10?", "ar": "كم شدته من 0 إلى 10؟"},
    "medicine": {"en": "Did you take any medicine for it?", "ar": "أخذت أي دوا له؟"},
    "other": {
        "en": "Anything else the nurse should know?",
        "ar": "في شي ثاني تبي الممرضة تعرفه؟",
    },
}
FOLLOW_UPS = {
    "fever": {"en": "Do you have a fever?", "ar": "عندك حرارة؟"},
    "pain": {"en": "Where is the pain?", "ar": "وين الألم بالضبط؟"},
    "vomiting": {"en": "Any vomiting?", "ar": "في ترجيع؟"},
}
_EMERGENCY = {
    "en": "This needs urgent care. Please go to the nearest emergency department now, "
    "or call 999.",
    "ar": "هذا يحتاج رعاية عاجلة. توجه الآن إلى أقرب قسم طوارئ، أو اتصل على 999.",
}
_SUPPORT = {
    "en": "You are not alone. Please talk to someone right now, a person you trust or "
    "the team on 999.",
    "ar": "أنت لست وحدك. كلم أحد الآن، شخص تثق فيه أو الفريق على 999.",
}
_REFILL = {
    "en": "Your usual medicine ({medicine}) can be handled without a visit. "
    "Please message your centre's refill line.",
    "ar": "دواك المعتاد ({medicine}) ما يحتاج زيارة. راسل خط إعادة الصرف في مركزك.",
}
_SUMMARY_INTRO = {
    "en": "Thanks. Here is what I will tell the nurse:",
    "ar": "شكرا. هذا اللي بقوله للممرضة:",
}
_SUMMARY_CHECK = {"en": "Is this right?", "ar": "هل هذا صحيح؟"}
_SUMMARY_LABELS = {
    "en": {"severity": "severity {}/10", "took": "took ", "and": " and "},
    "ar": {"severity": "الشدة {} من 10", "took": "أخذت ", "and": " و"},
}
_SUMMARY_PLAIN = {
    "en": "Thanks, I have your details for the nurse. Please check the summary card.",
    "ar": "شكرا، وصلتني معلوماتك للممرضة. راجع بطاقة الملخص لو سمحت.",
}


def _phrases(*items: str) -> tuple[tuple[str, ...], ...]:
    return tuple(phrase_tokens(item) for item in items)


_COMPLAINT_FORMS = {
    "fever": ("fever", "temperature", "حرارة", "سخونة"),
    "cough": ("cough", "coughing", "كحة", "سعال"),
    "headache": ("headache", "headaches", "صداع", "وجع راس", "راسي يوجعني"),
    "sore throat": (
        "sore throat", "throat pain", "throat hurts", "ألم في الحلق", "ألم بالحلق",
        "وجع في الحلق", "وجع حلق", "حلقي يوجعني",
    ),
    "stomach pain": (
        "stomach pain", "stomach ache", "stomachache", "tummy pain", "abdominal pain",
        "ألم في البطن", "ألم بالبطن", "ألم في بطني", "وجع في البطن", "وجع بطن",
        "بطني يوجعني", "مغص",
    ),
    "vomiting": ("vomiting", "vomit", "throwing up", "ترجيع", "استفراغ", "قيء"),
    "diarrhoea": ("diarrhoea", "diarrhea", "إسهال"),
    "back pain": (
        "back pain", "backache", "ألم في الظهر", "ألم بالظهر", "ألم في ظهري",
        "وجع في الظهر", "وجع ظهر", "ظهري يوجعني",
    ),
    "ear pain": (
        "ear pain", "earache", "ألم في الأذن", "ألم بالأذن", "ألم في أذني",
        "وجع في الأذن", "وجع أذن", "أذني توجعني",
    ),
    "rash": ("rash", "طفح"),
    "dizziness": ("dizziness", "dizzy", "دوخة", "دايخ", "دوار"),
    "tooth pain": (
        "tooth pain", "toothache", "tooth hurts", "ألم في السن", "ألم في الضرس",
        "ألم في ضرسي", "وجع ضرس", "وجع سن", "ضرسي يوجعني",
    ),
}
_COMPLAINTS = {name: _phrases(*forms) for name, forms in _COMPLAINT_FORMS.items()}
_COMPLAINT_AR = {
    "fever": "حرارة", "cough": "كحة", "headache": "صداع", "sore throat": "ألم في الحلق",
    "stomach pain": "ألم في البطن", "vomiting": "ترجيع", "diarrhoea": "إسهال",
    "back pain": "ألم في الظهر", "ear pain": "ألم في الأذن", "rash": "طفح جلدي",
    "dizziness": "دوخة", "tooth pain": "ألم في السن",
}
_PAIN_WORDS = _phrases("pain", "ache", "hurt", "hurts", "hurting", "ألم", "وجع", "يوجعني")

_SERVICE_KEYWORDS = (
    ("dental", _phrases(
        "tooth", "teeth", "toothache", "dental", "dentist",
        "ضرس", "ضرسي", "سن", "سني", "اسنان", "اسناني",
    )),
    ("vaccination", _phrases("vaccine", "vaccination", "تطعيم", "لقاح")),
    ("lab_only", _phrases("blood test", "lab test", "تحليل")),
    ("womens_health", _phrases("pregnant", "period", "حامل", "الدوره")),
    ("mental_health", _phrases("anxiety", "anxious", "depression", "قلق", "اكتئاب")),
    ("other", _phrases("sick note", "sick leave", "certificate", "شهاده")),
)
_GULF_MARKERS = _phrases("ابي", "شو", "عندي", "ابغى", "وايد")

_MEDICINES = {
    canonical: _phrases(*names) for canonical, names in filters.DRUG_NAMES.items()
}
_NOT_TAKEN = _phrases(
    "didn't take", "didnt take", "did not take", "haven't taken", "have not taken",
    "ما أخذت", "ما اخذيت", "لم آخذ",
)
# A drug the patient wants or asks about is not a drug they took.
_NOT_A_DOSE_TAKEN = (
    *_NOT_TAKEN,
    *_phrases(
        "allergic to", "حساسية من", "want", "wants", "would like", "need", "can i get",
        "can i have", "can i take", "should i take", "should i", "try", "ابي", "أبغى",
        "أريد", "أحتاج", "ينفع",
    ),
)

_NO_WORDS = frozenset(
    phrase_tokens("no nope nah none nothing لا مافي ماشي خلاص")
)
_NO_PHRASES = _phrases("that's all", "thats all", "ما في", "ما شي", "بس كذا")
_YES_WORDS = redflags.YES_WORDS
_WHERE_WORDS = _phrases("where", "وين", "أين")

# Reads an untagged model question. Order matters: "Did you take anything for the
# fever?" is a medicine question, and "When did the fever start?" a duration one.
_SLOT_HINTS = (
    ("other", _phrases("anything else", "should know", "شي ثاني", "شي اخر", "شيء اخر")),
    ("severity", _phrases(
        "how bad", "how severe", "how strong", "0 to 10", "out of 10", "scale",
        "شدته", "شدتها", "الشدة", "من 0",
    )),
    ("duration", _phrases(
        "since when", "how long", "when did", "how many days", "started", "من متى",
        "منذ متى", "متى", "كم يوم",
    )),
    ("medicine", _phrases(
        "medicine", "medicines", "medication", "painkiller", "take", "took", "دوا",
        "دواء", "علاج", "أخذت", "مسكن",
    )),
    ("followup", _phrases(
        "fever", "temperature", "where", "vomiting", "حرارة", "وين", "أين", "ترجيع",
        "استفراغ",
    )),
)

_NUMBER_WORDS = {
    **{
        word: value
        for value, word in enumerate(
            "zero one two three four five six seven eight nine ten".split()
        )
    },
    **{
        normalise(word): value
        for word, value in (
            ("صفر", 0), ("واحد", 1), ("واحدة", 1), ("اثنين", 2), ("ثنين", 2), ("اثنان", 2),
            ("ثلاث", 3), ("ثلاثة", 3), ("أربع", 4), ("أربعة", 4), ("خمس", 5), ("خمسة", 5),
            ("ست", 6), ("ستة", 6), ("سبع", 7), ("سبعة", 7), ("ثمان", 8), ("ثماني", 8),
            ("ثمانية", 8), ("تسع", 9), ("تسعة", 9), ("عشر", 10), ("عشرة", 10),
        )
    },
}
_NUMBER_PATTERN = "|".join(sorted(_NUMBER_WORDS, key=len, reverse=True))
_OUT_OF_TEN = re.compile(
    rf"(?<![\w.])(\d+|{_NUMBER_PATTERN})\s*(?:/|out of|over|من|على)\s*(?:10|ten|عشره)(?!\d)"
)
_SEVERITY_NUMBER = re.compile(r"(?<![\d.-])\d+(?:\.\d+)?")

_UNITS = {
    "day": "day", "days": "day", "يوم": "day", "ايام": "day",
    "week": "week", "weeks": "week", "اسبوع": "week", "اسابيع": "week",
    "month": "month", "months": "month", "شهر": "month", "اشهر": "month", "شهور": "month",
    "hour": "hour", "hours": "hour", "ساعه": "hour", "ساعات": "hour",
    "year": "year", "years": "year", "سنه": "year", "سنوات": "year", "سنين": "year",
}
_UNIT_PATTERN = "|".join(sorted(_UNITS, key=len, reverse=True))
_DUALS = {"يومين": "day", "اسبوعين": "week", "شهرين": "month", "ساعتين": "hour", "سنتين": "year"}
_SINGULARS = "day|week|month|hour|year|يوم|اسبوع|شهر|ساعه|سنه"
_SINCE = r"(?:for|from|since|about|past|last|over|almost|nearly|من|منذ|قبل|صار|صارلي|لي|له|حوالي)"

_COUNTED = re.compile(rf"(?<!\w)(\d+|{_NUMBER_PATTERN})\s+({_UNIT_PATTERN})(?!\w)")
_DUAL = re.compile(rf"(?<!\w)[لو]?({'|'.join(_DUALS)})(?!\w)")
_SINGLE = re.compile(
    rf"(?<!\w){_SINCE}\s+(?:(?:a|an|one)\s+)?({_SINGULARS})(?!\w)"
    rf"|(?<!\w)(?:a|an)\s+({_SINGULARS})\s+ago(?!\w)"
)
_POINTS_IN_TIME = (
    (re.compile(r"(?<!\w)(?:yesterday|امس|مبارح)(?!\w)"), "since yesterday"),
    (re.compile(r"(?<!\w)(?:last night|البارحه)(?!\w)"), "since last night"),
    (re.compile(rf"(?<!\w){_SINCE}\s+(?:this morning|الصبح)(?!\w)"), "since this morning"),
    (re.compile(rf"(?<!\w){_SINCE}\s+(?:today|اليوم)(?!\w)"), "since today"),
)
_AR_UNITS = {
    "day": ("يوم", "يومين", "أيام"),
    "week": ("أسبوع", "أسبوعين", "أسابيع"),
    "month": ("شهر", "شهرين", "أشهر"),
    "hour": ("ساعة", "ساعتين", "ساعات"),
    "year": ("سنة", "سنتين", "سنوات"),
}
_AR_POINTS = {
    "since yesterday": "من أمس",
    "since last night": "من البارحة",
    "since this morning": "من الصبح",
    "since today": "من اليوم",
}
_COUNTED_ENGLISH = re.compile(r"(\d+) (day|week|month|hour|year)s?")

# All a correction at the read-back may hold beside its number, so that "I took 2 tablets"
# changes nothing. A score is never read out of a sentence about something else.
_CORRECTION_WORDS = frozenset(
    word
    for phrase in _phrases(
        "actually no nope sorry oh wait well i mean meant said say would it it's its is was",
        "the a an my pain severity score more like about around make change to now really",
        "لا آسف عفوا قصدي أقصد يعني هو هي كان كانت صار صارت الشدة الألم الوجع",
        "شدته شدتها خلها خله غيرها غيره إلى حوالي تقريبا بالأحرى",
    )
    for word in phrase
)
_NOT_THIS_NUMBER = re.compile(rf"(?<!\S)(?:not|مو|مش|ليس)\s+(?:\d+|{_NUMBER_PATTERN})(?!\S)")


@dataclass(frozen=True)
class SimTurn:
    reply: str
    slot: str | None
    intake: dict | None
    language: str


def _key(lang: str) -> str:
    return "ar" if lang.startswith("ar") else "en"


def question_count(history: list[dict]) -> int:
    """Questions asked so far. A history that starts with the patient had the opening."""
    asked = sum(
        1
        for message in history
        if message["role"] == "assistant" and message.get("slot") != NOT_A_QUESTION
    )
    seeded = bool(history) and history[0]["role"] == "assistant"
    return asked if seeded else asked + 1


def detect_lang(text: str, current: str) -> str:
    """Only a sentence switches language. Single words and digits keep the current one."""
    words = text.split()
    if len(words) < 2:
        return current
    arabic = sum(1 for word in words if has_arabic(word))
    latin = sum(1 for word in words if re.search("[A-Za-z]", word))
    if arabic == latin:
        return current
    return "ar" if arabic > latin else "en"


def _is_live(tokens: Sequence[Token], start: int, cue: str) -> bool:
    return has_leading_waw(cue, tokens[start].text) or not is_negated(tokens, start)


def _live_starts(tokens: Sequence[Token], phrases: Sequence[tuple[str, ...]]) -> list[int]:
    return [
        start
        for phrase in phrases
        for start in phrase_starts(tokens, phrase)
        if _is_live(tokens, start, phrase[0])
    ]


def find_complaints(text: str) -> list[str]:
    """Canonical English complaint words, in the order the patient said them."""
    tokens = tokenise(text)
    found = {}
    for canonical, phrases in _COMPLAINTS.items():
        starts = _live_starts(tokens, phrases)
        if starts:
            found[canonical] = min(starts)
    return sorted(found, key=found.__getitem__)


def parse_medicines(text: str) -> list[str]:
    """Medicine names only. A dose in the sentence is never carried over."""
    tokens = tokenise(text)
    return [
        canonical
        for canonical, phrases in _MEDICINES.items()
        if any(
            not is_negated(tokens, start, extra=_NOT_A_DOSE_TAKEN)
            for phrase in phrases
            for start in phrase_starts(tokens, phrase)
        )
    ]


def _number(word: str) -> int | None:
    return int(word) if word.isdigit() else _NUMBER_WORDS.get(word)


def _duration_text(count: int, unit: str) -> str:
    return f"{count} {unit}" if count == 1 else f"{count} {unit}s"


def parse_duration(text: str, tagged: bool = False) -> str | None:
    """Normalised English duration, or None. `tagged` means it answers "since when?"."""
    norm = normalise(text)
    for candidate in (norm, f"from {norm}") if tagged else (norm,):
        counted = _COUNTED.search(candidate)
        if counted:
            count = _number(counted.group(1))
            if count:
                return _duration_text(count, _UNITS[counted.group(2)])
        dual = _DUAL.search(candidate)
        if dual:
            return _duration_text(2, _DUALS[dual.group(1)])
        single = _SINGLE.search(candidate)
        if single:
            return _duration_text(1, _UNITS[single.group(1) or single.group(2)])
        for pattern, value in _POINTS_IN_TIME:
            if pattern.search(candidate):
                return value
    return None


def _in_range(value: int | None) -> int | None:
    return value if value is not None and 0 <= value <= 10 else None


def parse_severity(text: str, loose: bool = False) -> int | None:
    """A 0-10 score. `loose` reads a number inside a sentence that answers the question."""
    norm = normalise(text)
    explicit = _OUT_OF_TEN.search(norm)
    if explicit:
        return _in_range(_number(explicit.group(1)))
    tokens = tokenise(norm)
    if not loose and len(tokens) != 1:
        return None
    digits = _SEVERITY_NUMBER.search(norm)
    if digits:
        return None if "." in digits.group() else _in_range(int(digits.group()))
    for token in tokens:
        if token.text in _NUMBER_WORDS:
            return _NUMBER_WORDS[token.text]
    return None


def _corrected_severity(text: str) -> int | None:
    """The score in a short correction at the read-back, as in "actually it is 8" or
    "لا، ثمانية". "8, not 6" means 8, and "it is not 8" names no score."""
    spoken = " ".join(token.text for token in tokenise(text))
    words = _NOT_THIS_NUMBER.sub(" ", spoken).split()
    numbers = [word for word in words if _number(word) is not None]
    others = {word for word in words if _number(word) is None}
    if len(numbers) != 1 or not others <= _CORRECTION_WORDS:
        return None
    return _in_range(_number(numbers[0]))


def _means_no(tokens: Sequence[Token]) -> bool:
    if not tokens or len(tokens) > 3:
        return False
    return tokens[0].text in _NO_WORDS or contains_any(tokens, _NO_PHRASES)


@dataclass
class _Facts:
    complaints: list[str] = field(default_factory=list)
    duration: str | None = None
    severity: int | None = None
    medicines: list[str] = field(default_factory=list)
    said_no_medicine: bool = False
    concerns: str | None = None
    location: str | None = None
    asked: Counter = field(default_factory=Counter)

    def add_complaints(self, words: Sequence[str]) -> None:
        self.complaints.extend(word for word in words if word not in self.complaints)


def _asked_slot(message: dict) -> str | None:
    slot = message.get("slot")
    if slot:
        return None if slot == NOT_A_QUESTION else slot
    tokens = tokenise(message["content"])
    for name, phrases in _SLOT_HINTS:
        if contains_any(tokens, phrases):
            return name
    return None


def _absorb(
    facts: _Facts, text: str, slot: str | None, question: str, at_read_back: bool = False
) -> None:
    tokens = tokenise(text)
    facts.add_complaints(find_complaints(text))

    duration = parse_duration(text, tagged=slot == "duration")
    if duration:
        facts.duration = duration

    bare_allowed = slot in (None, "severity") and duration is None
    severity = (
        parse_severity(text, loose=slot == "severity")
        if bare_allowed
        else parse_severity(text) if len(tokens) > 1 else None
    )
    if severity is None and at_read_back and duration is None:
        severity = _corrected_severity(text)
    if severity is not None:
        facts.severity = severity

    facts.medicines.extend(
        name for name in parse_medicines(text) if name not in facts.medicines
    )
    facts.said_no_medicine = facts.said_no_medicine or contains_any(tokens, _NOT_TAKEN)

    if slot == "other":
        facts.concerns = None if _means_no(tokens) else text[:_MAX_CONCERNS]
    elif slot == "followup":
        if redflags.means_yes(tokens):
            facts.add_complaints(find_complaints(question))
        elif not _means_no(tokens) and contains_any(tokenise(question), _WHERE_WORDS):
            facts.location = text


def _read(history: list[dict]) -> _Facts:
    facts = _Facts()
    slot: str | None = "complaint"
    question = ""
    at_read_back = False
    for message in history:
        if message["role"] == "assistant":
            slot = _asked_slot(message)
            question = message["content"]
            at_read_back = message.get("slot") == NOT_A_QUESTION
            if slot:
                facts.asked[slot] += 1
        else:
            _absorb(facts, message["content"], slot, question, at_read_back)
            slot = None
            question = ""
            at_read_back = False
    return facts


def _user_messages(history: list[dict]) -> list[str]:
    return [message["content"] for message in history if message["role"] == "user"]


def _service(history: list[dict]) -> str | None:
    messages = [tokenise(text) for text in _user_messages(history)]
    for service, phrases in _SERVICE_KEYWORDS:
        if any(_live_starts(tokens, phrases) for tokens in messages):
            return service
    return None


def _follow_up(facts: _Facts, history: list[dict]) -> str | None:
    """Which follow-up to ask, or None when the complaint already answers it."""
    if facts.asked["followup"]:
        return None
    if _service(history) not in (None, "dental"):
        return None
    complaints = facts.complaints
    if not complaints and any(
        contains_any(tokenise(text), _PAIN_WORDS) for text in _user_messages(history)
    ):
        return "pain"
    if ("stomach pain" in complaints or "diarrhoea" in complaints) and (
        "vomiting" not in complaints
    ):
        return "vomiting"
    return None if "fever" in complaints else "fever"


def _next_question(facts: _Facts, history: list[dict]) -> tuple[str, dict[str, str]] | None:
    if facts.duration is None and not facts.asked["duration"]:
        return "duration", QUESTIONS["duration"]
    if facts.severity is None and facts.asked["severity"] < _SEVERITY_ASKS:
        return "severity", QUESTIONS["severity"]
    follow_up = _follow_up(facts, history)
    if follow_up:
        return "followup", FOLLOW_UPS[follow_up]
    medicine_known = facts.medicines or facts.said_no_medicine or facts.asked["medicine"]
    if not medicine_known:
        return "medicine", QUESTIONS["medicine"]
    if not facts.asked["other"]:
        return "other", QUESTIONS["other"]
    return None


def _intake_language(history: list[dict], lang: str) -> str:
    if _key(lang) == "en":
        return "en"
    messages = (tokenise(text) for text in _user_messages(history))
    return "ar-gulf" if any(contains_any(t, _GULF_MARKERS) for t in messages) else "ar-msa"


def add_denied(summary: str, denied: Sequence[str]) -> str:
    """Append the denial line, trimming the summary rather than losing the line."""
    line = redflags.denied_text(denied)
    if not line or line in summary:
        return summary
    room = max(_MAX_SUMMARY - len(line) - 2, 0)
    return f"{summary[:room].rstrip()} {line}."[:_MAX_SUMMARY]


def _complaint_with_duration(complaint: str, duration: str | None) -> str:
    if duration is None:
        return complaint
    return f"{complaint} {duration}" if duration.startswith("since") else f"{duration} {complaint}"


def _nurse_summary(
    patient: dict,
    complaint: str,
    duration: str | None,
    severity: int | None,
    medicines: Sequence[str],
) -> str:
    parts = [
        f"{patient['age']}{patient['sex']}",
        _complaint_with_duration(complaint, duration),
    ]
    if severity is not None:
        parts.append(f"severity {severity}/10")
    if medicines:
        parts.append("took " + " and ".join(medicines))
    return (", ".join(parts) + ".")[:_MAX_SUMMARY]


def _build_intake(
    history: list[dict], patient: dict, denied: Sequence[str], lang: str, facts: _Facts
) -> dict:
    first_words = _user_messages(history)[0]
    if facts.complaints:
        complaint = " and ".join(facts.complaints)
    elif facts.location:
        complaint = f"{first_words}, {facts.location}"
    else:
        complaint = first_words
    complaint = complaint[:_MAX_COMPLAINT]
    keyword_service = _service(history)
    matched = keyword_service is not None or bool(facts.complaints)
    summary = _nurse_summary(
        patient, complaint, facts.duration, facts.severity, facts.medicines
    )
    return intake_schema.validate_intake(
        {
            "emergency": False,
            "language": _intake_language(history, lang),
            "chief_complaint": complaint,
            "chief_complaint_patient_words": first_words[:_MAX_PATIENT_WORDS],
            "duration": facts.duration,
            "severity_0_10": facts.severity,
            "associated": facts.complaints[1:],
            "self_medication": facts.medicines,
            "service": keyword_service or "gp",
            "service_confidence": 0.85 if matched else 0.6,
            "summary_for_nurse": add_denied(summary, denied),
            "refill_request": None,
            "questions_asked": min(question_count(history), MAX_QUESTIONS),
            "denied_red_flags": list(denied),
            "patient_concerns": facts.concerns,
        }
    ).model_dump()


def next_turn(
    history: list[dict], patient: dict, denied: Sequence[str], lang: str
) -> SimTurn:
    """The next scripted turn. `history` includes the patient's latest message."""
    users = _user_messages(history)
    key = _key(detect_lang(users[-1], lang) if users else lang)
    if not users:
        return SimTurn(OPENING[key], "complaint", None, key)
    facts = _read(history)
    if question_count(history) < MAX_QUESTIONS:
        question = _next_question(facts, history)
        if question:
            slot, wording = question
            return SimTurn(wording[key], slot, None, key)
    intake = _build_intake(history, patient, denied, key, facts)
    return SimTurn(summary_reply(intake, key), None, intake, key)


def gp_intake_after_refill(
    history: list[dict],
    patient: dict,
    medicine: str,
    denied: Sequence[str],
    lang: str,
) -> dict:
    """"I still want a visit": a GP intake for a patient the refill line would have served."""
    facts = _read(history)
    name = medicine.split()[0] if medicine else "medicine"
    complaint = f"{name} refill"
    first_words = next(iter(_user_messages(history)), complaint)
    summary = _nurse_summary(patient, f"{complaint}, patient asked for a visit", None, None, ())
    return intake_schema.validate_intake(
        {
            "emergency": False,
            "language": _intake_language(history, lang),
            "chief_complaint": complaint,
            "chief_complaint_patient_words": first_words[:_MAX_PATIENT_WORDS],
            "duration": facts.duration,
            "severity_0_10": facts.severity,
            "associated": facts.complaints,
            "self_medication": facts.medicines,
            "service": "gp",
            "service_confidence": 0.85,
            "summary_for_nurse": add_denied(summary, denied),
            "refill_request": medicine or None,
            "questions_asked": min(question_count(history), MAX_QUESTIONS),
            "denied_red_flags": list(denied),
            "patient_concerns": facts.concerns,
        }
    ).model_dump()


def _arabic_duration(duration: str) -> str:
    if duration in _AR_POINTS:
        return _AR_POINTS[duration]
    counted = _COUNTED_ENGLISH.fullmatch(duration)
    if not counted:
        return duration
    count = int(counted.group(1))
    one, two, many = _AR_UNITS[counted.group(2)]
    if count == 1:
        return one
    return two if count == 2 else f"{count} {many}"


def _arabic_drug(canonical: str) -> str:
    forms = filters.DRUG_NAMES.get(canonical, ())
    return next((form for form in forms if has_arabic(form)), canonical)


def _read_back_complaint(intake: dict, key: str) -> str:
    """Our own fixed complaint words when they fit, else the patient's own words."""
    words = intake["chief_complaint"].split(" and ")
    if not all(word in _COMPLAINT_AR for word in words):
        return intake["chief_complaint_patient_words"][:_MAX_COMPLAINT]
    if key == "ar":
        return " و".join(_COMPLAINT_AR[word] for word in words)
    return " and ".join(words)


def _read_back(intake: dict, key: str) -> str:
    """Rendered from fixed parts. summary_for_nurse is model prose, so it is never read."""
    labels = _SUMMARY_LABELS[key]
    parts = [_read_back_complaint(intake, key)]
    duration = parse_duration(intake["duration"] or "")
    if duration:
        parts.append(_arabic_duration(duration) if key == "ar" else duration)
    if intake["severity_0_10"] is not None:
        parts.append(labels["severity"].format(intake["severity_0_10"]))
    medicines = intake["self_medication"]
    if medicines:
        names = [_arabic_drug(name) for name in medicines] if key == "ar" else medicines
        parts.append(labels["took"] + labels["and"].join(names))
    summary = ("، " if key == "ar" else ", ").join(parts) + "."
    denied = redflags.denied_text(intake["denied_red_flags"], key)
    return f"{summary} {denied}." if denied else summary


def summary_reply(intake: dict, lang: str) -> str:
    """The summary shown back to the patient, or a plain line if it would fail the filter.

    The patient's own medicines are allowed by name, so "took paracetamol" reads back.
    Any other drug, a dose, or an order still fails and gives the plain line.
    """
    key = _key(lang)
    reply = f"{_SUMMARY_INTRO[key]} {_read_back(intake, key)} {_SUMMARY_CHECK[key]}"
    check = filters.check_reply(
        reply, allowed_meds=intake["self_medication"], read_back=True
    )
    return reply if check.ok else _SUMMARY_PLAIN[key]


def emergency_reply(lang: str, self_harm: bool) -> str:
    key = _key(lang)
    return f"{_EMERGENCY[key]} {_SUPPORT[key]}" if self_harm else _EMERGENCY[key]


def refill_reply(medicine: str, lang: str) -> str:
    return _REFILL[_key(lang)].format(medicine=medicine)
