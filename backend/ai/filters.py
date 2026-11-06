"""The model text gate, and the banned-output filters behind it.

gate_reply is the guarantee for a model chat reply. It accepts one short question,
optionally after one acknowledgement. The question must open on a frame the gate
allows, hold only words and spaces, and use only words the gate knows, so a disease,
a drug or a number nobody has listed fails for being unknown and nothing here has to
recognise it. The only other source of words is `known`: what the patient said and
what the record says. The summary read back to the patient is built by the server,
so it never needs this gate.

The filters are the second layer. They run sentence by sentence on normalised text,
so diacritics cannot hide a banned phrase. The cost of a false positive is one
fallback turn. The cost of a miss is the AI diagnosing or prescribing, so doubtful
wording fails.

The word lists catch what the model names. The opener rules catch what it does
not: check_reply also fails a condition or a guess stated about the patient, a drug
outside the record, and a clause that orders a treatment, whatever the object is.

check_reply has two modes. By default it reads a model reply, and any statement
naming a disease fails. With read_back=True it reads the server's own summary, which
may echo the patient, so disease wording needs a trigger and a drug needs a took-word.

A question mark excuses very little. A question naming a disease passes check_reply
only as a history question, and a question opening on an order is still an order.
check_handoff keeps its own shorter word sets, since a draft may say "Rest of
history: none."
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable, Sequence

from backend.ai.text import (
    Token,
    contains_any,
    normalise,
    phrase_starts,
    phrase_tokens,
    split_sentences,
    token_matches,
    tokenise,
)


def _phrases(*items: str) -> tuple[tuple[str, ...], ...]:
    return tuple(phrase_tokens(item) for item in items)


DISEASE_TERMS = _phrases(
    "flu", "influenza", "a cold", "common cold", "covid", "coronavirus", "corona",
    "pneumonia", "bronchitis", "asthma", "diabetes", "hypertension", "infection",
    "sinusitis", "tonsillitis", "laryngitis", "pharyngitis", "strep throat",
    "migraine", "ulcer", "gastritis", "gastroenteritis", "food poisoning", "anemia",
    "anaemia", "appendicitis", "hepatitis", "meningitis", "tuberculosis", "malaria",
    "dengue", "arthritis", "gout", "epilepsy", "cancer", "tumor", "tumour",
    "heart attack", "heart disease", "angina", "depression", "virus", "viral",
    "viral illness", "strep", "bacterial",
    "فيروس", "فايروس", "بكتيريا", "انفلونزا", "نزلة برد", "نزلة معوية", "زكام", "كورونا", "كوفيد", "التهاب",
    "سكري", "سكر", "ربو", "ضغط دم", "ارتفاع ضغط", "قرحة", "فقر دم", "أنيميا",
    "سرطان", "ورم", "جلطة", "ذبحة", "شقيقة", "صداع نصفي", "سل", "ملاريا", "اكتئاب",
    "eczema", "uti", "reflux", "gerd", "conjunctivitis", "cystitis", "otitis",
    "stomach bug", "bad cold", "head cold", "chest cold", "dehydration", "dehydrated",
    "diabetic", "anemic", "anaemic", "asthmatic", "hypertensive", "heat stroke",
    "high blood pressure",
    "برد", "رشح", "اكزيما", "جفاف", "تسمم", "ضربة شمس",
)

_CONDITION_TRIGGERS = _phrases(
    "you have", "you've got", "you got", "you may have", "you might have",
    "you could have", "you must have", "you probably have", "you likely have",
    "looks like", "sounds like", "seems like", "seems to be", "appears to be",
    "this is", "it is", "it's", "that is", "that's", "could be", "might be",
    "may be", "must be", "likely", "probably", "i think", "i suspect",
    "suffering from", "is it", "is this", "is that", "could it", "could this",
    "could that", "might it", "might this", "chance", "possible", "possibly",
    "عندك", "عندج", "لديك", "مصاب", "مصابة", "تعاني من", "تعانين من", "شكلك",
    "شكله", "يمكن", "ممكن", "يبدو", "ربما", "غالبا", "هذا", "هذه", "هذي",
)
# The only ways a question may name a disease. What follows the opener is still read
# against _CONDITION_TRIGGERS, so "Any chance this is the flu?" does not pass.
_HISTORY_OPENERS = _phrases(
    "do you have", "did you have", "have you had", "have you ever had", "any", "is your",
    "are you", "عندك", "هل عندك", "هل لديك", "هل عندك اي",
)
# A disease term in a statement aimed at the patient presents it as theirs, however
# the model words it. A summary echoing "34F, I have asthma" has no such marker.
_SECOND_PERSON = _phrases(
    "you", "you're", "youre", "you've", "your", "انت", "انتي", "معك", "معج", "فيك",
    "فيج", "حالتك", "حالتج",
)
# These say the patient has something, so the object must be a symptom they reported.
# "allergy" stays off DISEASE_TERMS because "Allergies:" is a handoff label; this rule
# is what stops "You have an allergy."
_CONDITION_OPENERS = _phrases(
    "you have", "you've got", "you've", "you got", "you caught", "you've caught",
    "عندك", "عندج", "لديك", "معك", "معج", "فيك", "فيج", "مصاب", "مصابة", "تعاني من",
    "تعانين من",
)
_REPORTING_VERBS = frozenset({"told", "said", "mentioned", "asked", "been", "had"})
_SYMPTOMS = _phrases(
    "fever", "temperature", "cough", "pain", "ache", "headache", "sore throat",
    "vomiting", "nausea", "rash", "dizzy", "dizziness",
    "حرارة", "سخونة", "كحة", "سعال", "صداع", "ألم", "وجع", "ترجيع", "استفراغ", "دوخة",
    "طفح",
)
# A guess at what is wrong fails with any object, so no disease term is needed.
_GUESS_OPENERS = _phrases(
    "looks like", "sounds like", "seems like", "seems to be", "appears to be",
    "could be", "might be", "may be", "must be", "probably", "likely", "i think",
    "i suspect", "looks",
    "شكلك", "شكله", "شكلها", "يبدو", "ربما", "غالبا", "على الأغلب", "في الغالب", "الأرجح",
    "أعتقد", "احتمال",
)
_DIAGNOSIS_WORDS = _phrases("diagnosis", "تشخيص", "تشخيصك", "تشخيصي", "تشخيصه")
_REFUSALS = frozenset(
    {"can't", "cant", "cannot", "not", "unable", "won't", "لا", "ما", "لست", "لن"}
)

_SPECULATION_TERMS = _phrases(
    "likely", "unlikely", "probable", "probably", "possible", "possibly", "suspected",
    "suspect", "consistent with", "suggestive of", "differential", "diagnosis",
    "impression", "assessment", "rule out", "r/o", "ddx", "viral", "virus", "bacterial",
    "urti", "uti", "sepsis", "تشخيص", "يرجح", "فيروس", "فايروس", "بكتيريا",
)

# Canonical drug -> every written form. Mirrors backend/seed/drugs.json in code
# so this module stays free of I/O; a test keeps the two in step. The generic forms
# at the end are here too, because simulated.py reads this table for self_medication.
DRUG_NAMES: dict[str, tuple[str, ...]] = {
    "paracetamol": (
        "paracetamol", "acetaminophen", "panadol", "adol", "tylenol",
        "باراسيتامول", "بنادول", "أدول",
    ),
    "dextromethorphan": ("dextromethorphan", "ديكستروميثورفان"),
    "amoxicillin": ("amoxicillin", "أموكسيسيلين"),
    "co-amoxiclav": ("co-amoxiclav", "amoxiclav", "augmentin", "كلافولانيك", "أوجمنتين"),
    "azithromycin": ("azithromycin", "zithromax", "أزيثرومايسين"),
    "ibuprofen": ("ibuprofen", "brufen", "nurofen", "advil", "إيبوبروفين", "بروفين"),
    "cetirizine": ("cetirizine", "zyrtec", "سيتريزين"),
    "amlodipine": ("amlodipine", "norvasc", "أملوديبين"),
    "metformin": ("metformin", "glucophage", "ميتفورمين"),
    "aspirin": ("aspirin", "أسبرين"),
    "penicillin": ("penicillin", "بنسلين"),
    "antibiotic": ("antibiotic", "antibiotics", "مضاد حيوي", "مضادات حيوية"),
    "painkiller": ("painkiller", "painkillers", "مسكن"),
    "insulin": ("insulin", "أنسولين"),
    "antihistamine": ("antihistamine", "antihistamines", "مضاد هيستامين"),
    "decongestant": ("decongestant", "decongestants"),
    "cough syrup": ("cough syrup", "syrup", "شراب كحة", "شراب"),
    "lozenges": ("lozenge", "lozenges"),
    "nasal spray": ("nasal spray",),
    "inhaler": ("inhaler", "inhalers", "بخاخ"),
    "ointment": ("ointment", "مرهم"),
    "vitamin": ("vitamin", "vitamins", "فيتامين"),
}
_DRUG_PHRASES = {
    canonical: tuple(phrase_tokens(name) for name in names)
    for canonical, names in DRUG_NAMES.items()
}

# Read back only. A drug in the summary must be something the patient took.
_TOOK_WORDS = _phrases(
    "took", "taken", "tried", "used", "had", "أخذت", "أخذ", "تناولت", "تناول", "استخدمت",
)

_ADVICE_TRIGGERS = _phrases(
    "take", "try", "use", "you should", "should take", "continue", "i recommend",
    "i suggest", "i advise", "recommend", "need", "needs", "must", "have to", "treat",
    "give", "start", "consider", "prescribe",
    "خذ", "خذي", "جرب", "جربي", "استخدم", "استخدمي", "تناول", "تناولي", "انصحك",
    "أنصح", "نوصي", "تحتاج", "تحتاجين", "لازم", "اشرب", "اشربي",
    "تاخذ", "تاخذي", "تاخذين", "يفيدك", "ينفعك", "يساعدك", "help", "helps", "good for",
)
# An order at the start of a clause fails with any object, named drug or not.
_HANDOFF_IMPERATIVES = frozenset(
    token
    for phrase in _phrases(
        "take", "try", "use", "drink", "apply", "خذ", "خذي", "جرب", "جربي", "استخدم",
        "استخدمي", "تناول", "تناولي", "اشرب", "اشربي",
    )
    for token in phrase
)
_IMPERATIVES = _HANDOFF_IMPERATIVES | frozenset(
    token
    for phrase in _phrases(
        "rest", "gargle", "avoid", "stay", "ارتاح", "ارتاحي", "تجنب", "تجنبي", "غرغر",
    )
    for token in phrase
)
_HARMLESS_ORDERS = (("a", "seat"), ("your", "time"))
# Words that can stand before an order without changing it.
_LEAD_INS = frozenset(
    {"and", "but", "please", "kindly", "just", "then", "و", "بس", "لكن", "ولكن"}
)

_QUANTITY = r"\d+(?:\.\d+)?"
_UNITS = {
    "mg": ("mg", "mgs", "milligram", "milligrams", "ملغ", "مغ", "ملجم", "مليجرام"),
    "ml": ("ml", "millilitre", "millilitres", "milliliter", "milliliters", "مل"),
    "mcg": ("mcg", "microgram", "micrograms"),
    "g": ("g", "gram", "grams", "جرام", "غرام"),
    "tablet": ("tablet", "tablets", "tab", "tabs", "pill", "pills", "حبه", "حبات",
               "حبتين", "قرص", "اقراص"),
    "capsule": ("capsule", "capsules", "cap", "caps", "كبسوله", "كبسولات"),
}
_UNIT_CANONICAL = {form: unit for unit, forms in _UNITS.items() for form in forms}
_UNIT_PATTERN = "|".join(sorted(_UNIT_CANONICAL, key=len, reverse=True))
_DOSE = re.compile(rf"({_QUANTITY})\s*({_UNIT_PATTERN})(?![\w/])")
_NUMBER_WORDS = {"one": "1", "two": "2", "three": "3", "four": "4", "half a": "0.5"}
_SPELLED_DOSE = re.compile(
    r"\b(one|two|three|four|half a)\s+(tablets?|pills?|capsules?)\b"
)
_ARABIC_DUAL_DOSE = re.compile(r"(?<!\w)[وفبل]?(?:حبتين|قرصين)(?!\w)")

# T-014, D-GP-023, ت-014, T014. Without a hyphen a Latin letter needs two digits, so
# "O2" passes, and an Arabic letter three, so "ل3" and "و10" (a joined proclitic) pass.
_TICKET_LETTER = "[a-z\u0621-\u064a]"
_TICKET = re.compile(
    rf"\b(?:{_TICKET_LETTER}(?:-{_TICKET_LETTER}+)?-\d{{1,3}}"
    rf"|[a-z]\d{{2,3}}|[\u0621-\u064a]\d{{3}})\b"
)
_HANDOFF_QUEUE_TERMS = _phrases(
    "your number", "queue number", "your position", "in line", "people ahead",
    "ahead of you", "your turn", "next in", "you are next", "you're next",
    "you are first", "you're first", "the next one",
    "رقمك", "دورك", "ترتيبك", "قدامك", "أمامك", "انت التالي",
)
_QUEUE_TERMS = (
    *_HANDOFF_QUEUE_TERMS,
    *_phrases("you will be next", "you'll be next", "be next"),
)
_ORDINAL_PLACE = re.compile(
    r"(?<!\w)(?:you are|you're|youre)\s+(?:the\s+)?"
    r"(?:\d+(?:st|nd|rd|th)|first|second|third|fourth|fifth|sixth|seventh|eighth"
    r"|ninth|tenth)(?!\w)"
    r"|(?<!\w)(?:انت|انتي)\s+(?:الاول|الثاني|الثالث|الرابع|الخامس|السادس|السابع"
    r"|الثامن|التاسع|العاشر)ه?(?!\w)"
)
_MINUTES = re.compile(
    r"(?<![\w.])(?:\d+|five|ten|fifteen|twenty|thirty|خمس|عشر|عشرين|ثلاثين)\s*"
    r"(?:mins?|minutes?|دقيقه|دقايق|دقائق)(?!\w)"
)
# Any hour word counts, so this also covers "an hour" and "half an hour". It only
# fails beside a wait term, so "It started 3 hours ago." stays a plain duration.
_HOURS = re.compile(
    r"(?<![^\W\d])[وبل]?(?:hours?|hrs?|ساعه|ساعات|ساعتين)(?!\w)"
)
_WAIT_TERMS = _phrases(
    "wait", "waiting", "seen", "called", "queue", "انتظار", "انتظر", "تنتظر",
    "تنتظري", "تنتظرين", "دورك", "انتظارك",
)
# Any statement naming the queue fails, with or without a number.
_QUEUE_WORDS = _phrases(
    "queue", "queues", "ticket", "tickets", "طابور", "طوابير", "تذكره", "تذكرتك",
    "تذكرتج", "تذكرتي", "تذاكر",
)
# These need a number in the sentence, because alone they are ordinary words. The
# Arabic forms are listed since a suffix changes the token. دوره is left out because
# it also means a course or a cycle.
_PLACE_WORDS = _phrases(
    "number", "position", "line", "turn", "ahead", "before you",
    "رقم", "رقمك", "رقمج", "رقمي", "دور", "دورك", "دورج", "دوري", "ترتيب", "ترتيبك",
    "ترتيبج", "قدام", "قدامك", "قدامج", "امام", "امامك", "امامج", "قبلك", "قبلج",
    "انتظارك", "people", "patients", "waiting", "ناس", "اشخاص", "مرضى",
)
_COUNT_WORDS = (
    "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
    "eleven", "twelve", "fifteen", "twenty", "thirty",
    "واحد", "اثنين", "ثنين", "ثلاث", "ثلاثه", "اربع", "اربعه", "خمس", "خمسه", "ست",
    "سته", "سبع", "سبعه", "ثمان", "ثمانيه", "تسع", "تسعه", "عشر", "عشره",
)
_COUNT = re.compile(rf"\d|(?<!\w)و?(?:{'|'.join(_COUNT_WORDS)})(?!\w)")
_PAIN_SCALE = re.compile(
    r"(?<![\d.])[01]\s*(?:to|-|–|الي|ل)\s*10(?!\d)|(?:out of|من)\s*10(?!\d)"
)

_CLAUSE_SPLIT = re.compile(r"[,،;؛]")
_QUESTION_OPENERS = frozenset({"do", "did", "are", "have"})
_QUESTION_SUBJECTS = frozenset(
    {"you", "your", "they", "he", "she", "it", "we", "the", "this", "that", "there", "any"}
)
_SENTENCE_CLOSERS = " .!\"'”»)]"

# The gate. These are the only words it lets through, so anything else fails closed.
_MAX_ACK_WORDS = 6
_MAX_QUESTION_WORDS = 15
_ACK_WORDS = frozenset(
    phrase_tokens(
        "ok okay alright right thanks thank you good sorry to hear that about i see got "
        "it understood noted for telling me sharing hello hi welcome "
        "شكرا مشكور مشكوره تمام طيب حسنا زين فهمت واضح اسف اسفه سلامتك سلامتج "
        "الله يعافيك يعافيج مرحبا اهلا اوكي ماشي"
    )
)
# Words and single spaces only, so no bracket, slash, colon, semicolon, quote or dash
# can hold a second clause. An apostrophe counts only inside a word, as in don't.
_GATE_WORD = r"[^\W_]+(?:'[^\W_]+)?"
_QUESTION_SHAPE = re.compile(rf"{_GATE_WORD}(?: {_GATE_WORD})*")
_ACK_SHAPE = re.compile(rf"{_GATE_WORD}(?:(?:[,،] ?| ){_GATE_WORD})*")
_ACK_COMMA = re.compile("[,،]")
# A question opens on one of these. Can, could and why are left out on purpose, since
# each one turns a harmless clause into a suggestion: "Why not take a tablet?".
_GATE_FRAMES = _phrases(
    "what", "when", "where", "which", "who", "how long", "how much", "how many",
    "how bad", "how severe", "how often", "how far", "how is", "how are", "how did",
    "how do", "since when", "do you", "did you", "does it", "does the", "does your",
    "are you", "is your", "is the", "is it", "have you", "has", "any", "anything",
    "هل", "متى", "من متى", "منذ متى", "وين", "اين", "كم", "شو", "ايش", "وش", "ماذا",
    "ما", "كيف", "في", "فيه", "عندك", "عندج", "لديك", "اخذت", "اخذتي", "تناولت",
    "تناولتي", "استخدمت", "جربت", "تعاني", "تعانين", "تحس", "تحسين", "تشعر", "تشعرين",
    "اي",
)
# These open on an allowed frame and still put an idea in the patient's head.
_REFUSED_FRAMES = _phrases(
    "what about", "what if", "did you know", "do you know", "do you like", "are you aware",
)
_GATE_LEAD_INS = frozenset(phrase_tokens("and so و"))
# A digit reaches the patient only here, or as the patient's or the record's own word.
_SCALES = _phrases("from 0 to 10", "0 to 10", "من 0 الى 10", "0 الى 10")
_SCALE_FRAMES = _phrases("how bad", "how severe", "how much", "how is", "كم")
# What "Is your X" may ask about, and so the only words X may be.
_GATE_SUBJECTS = frozenset(
    phrase_tokens(
        "problem problems trouble symptom symptoms "
        "fever temperature cough coughing pain pains sore throat headache headaches "
        "nausea vomit vomiting vomited sick rash itch itchy itching dizzy dizziness tired "
        "tiredness weak weakness sneezing runny nose chills sweating swelling swollen "
        "numb numbness diarrhoea diarrhea constipation phlegm mucus burning bleeding "
        "cramps stiff stiffness "
        "head chest stomach tummy belly abdomen back neck ear ears eye eyes mouth tooth "
        "teeth gum gums arm arms leg legs hand hands foot feet knee knees shoulder "
        "shoulders skin side left right lower upper joint joints muscle muscles "
        "اعراض عرض مشكله مشاكل "
        "حراره سخونه حمي كحه سعال صداع الم الام وجع ترجيع استفراغ "
        "قيء غثيان دوخه دوار طفح حكه تعب ارهاق اسهال امساك عطس بلغم قشعريره تعرق تورم "
        "انتفاخ نزيف "
        "راس صدر بطن ظهر حلق اذن عين سن ضرس رقبه يد رجل جسم كتف ركبه انف فم يمين يسار"
    )
)
# Diseases are not here. One reaches a question the way a drug does: from `known`.
_GATE_WORDS = _GATE_SUBJECTS | frozenset(
    phrase_tokens(
        # Grammar. "should" has a rule of its own, see _offers_treatment.
        "a an the this that these those it its is are was were be been am do does did "
        "have has had should don't doesn't didn't haven't i you your you're "
        "my me we our he she they them their his her there here what when where which who "
        "how long many much often far and or but not no any anything else something "
        "some other another more most less than very too so just still also only ever "
        "now then again of in on at to from for with without by about into over under "
        "after before during since until as like per up down out off all both each "
        "every same new thing things "
        # Time. No number gets through here, spelled out or not.
        "today tonight yesterday morning afternoon evening night nights day days week "
        "weeks month months year years hour hours minute minutes time times ago last past "
        "first scale rate rating level severity severe bad worse worst better mild "
        "moderate strong sharp dull constant usually always sometimes usual "
        # What a receptionist asks.
        "start started starting begin began come came comes coming go goes going get got "
        "getting gets feel feeling felt feels help helps helped change changed make makes "
        "made keep keeps stop stopped happen happened happening tell know share mention "
        "describe take taken took taking try tried use used using eat eating drink "
        "drinking sleep sleeping travel travelled hurt hurts hurting ache aches aching "
        "bring brings main nurse doctor visit "
        "allergy allergies allergic medicine medicines medication medications tablet "
        "tablets pill pills history family pregnant period appetite food water "
        # The same in Arabic.
        "هل متى منذ من وين اين كم شو ايش وش ماذا ما كيف في فيه فيها عندك عندج لديك عندي له "
        "لها لك بك فيك معك اي اللي الذي التي هذا هذه هذي ذلك هو هي انت انتي شي شيء ثاني "
        "ثانيه اخر اخري غير علي الي عن مع او بعد قبل حتي لما بس "
        "اليوم امس البارحه الصبح الليل الليله صباح مساء يوم ايام اسبوع "
        "اسابيع شهر شهور سنه ساعه ساعات وقت مره مرات "
        "شده شدته شدتها درجه درجته مقياس قوي شديد خفيف متوسط اسوا احسن كثير وايد شوي "
        "قليل دايم دائما احيانا عاده مستمر بالضبط تحديدا بالتحديد "
        "يوجعك يوجعج توجعك يؤلمك نوم شهيه "
        "دوا دواء ادويه علاج حبوب حبه اخذت اخذتي اخذ تناولت تناولتي تتناول تاخذ تاخذين "
        "استخدمت جربت تعاني تعانين تحس تحسين تشعر تشعرين حسيت بديت بدا بدات صار "
        "صارلك صارلج يتعبك يتعبج تعبك يزيد يخف زاد خف تحسن تغير حدث حصل "
        "مرض امراض مزمنه حساسيه عمليه حامل ممرضه الدكتور طبيب "
        "تبي تبين تحب تعرفه تعرف تعرفها يعرف تقول تذكر"
    )
)
# `known` is the patient's words, and a patient's "I think it's shingles, should I take
# Panadol?" gives the model no licence to reason with them. These closed classes come
# from the gate or not at all: modals, hedges, belief, advice, and verdict words.
_NEVER_FROM_KNOWN = frozenset(
    phrase_tokens(
        "why can can't cannot could couldn't would wouldn't will won't shall should "
        "shouldn't must may might maybe perhaps probably possibly likely chance if "
        "think thinks thought believe suspect guess sure aware suggest recommend advise "
        "need needs want wants best good ok okay fine safe because due cause caused causes "
        "mean means it's that's this's what's "
        "ليش لماذا ممكن يمكن لازم ربما غالبا شكلك شكله شكلها اعتقد اكيد افضل رايك "
        "تحتاج تحتاجين تقدر تقدرين تريد تريدين تبغي تبغين ودك"
    )
)
_NOUN_LEADS = frozenset(phrase_tokens("a an the your my it this that"))
# A patient's word may be asked about. It may not be named as the cause of anything or
# equated with anything, so these never stand next to one.
_CAUSE_WORDS = frozenset(phrase_tokens("from with like من مع"))
_COPULAS = frozenset(phrase_tokens("is are was were be been am هو هي هذا هذه هذي"))

_INFINITIVE_ORDERS = _phrases(
    "to take", "to try", "to use", "to stop", "to drink", "to eat", "to keep", "to start",
)
# A try-word asks what the patient did, so it takes an open object or their own word.
# "Have you tried drinking water?" is a suggestion in the shape of a question.
_TRY_WORDS = frozenset(phrase_tokens("try tries tried trying جربت جربتي"))
_TRY_OBJECTS = frozenset(phrase_tokens("any anything something اي شي شيء"))
_WANT_VERBS = frozenset(phrase_tokens("تبي تبين تحب تحبين تريد تريدين تبغي تبغين ودك"))
_SECOND_PERSON_TAKE = frozenset(
    phrase_tokens(
        "تاخذ تاخذين تاخذي تجرب تجربين تجربي تشرب تشربين تشربي تستخدم تستخدمين تستخدمي "
        "تتناول تتناولين تتناولي اخذت اخذتي جربت جربتي تناولت تناولتي استخدمت استخدمتي"
    )
)
_TAKING_WORDS = _SECOND_PERSON_TAKE | frozenset(phrase_tokens("حبه حبوب دوا دواء علاج"))

_IS_IT = _phrases("is it", "هل هو", "هل هي", "هل هذا", "هل هذي", "هل هذه")
_IS_SUBJECT = _phrases("is your", "is the")
_HAL = phrase_tokens("هل")
# After هل these ask about the patient. Anything else names a subject, as "Is your" does.
_HAL_ASKS = frozenset(
    phrase_tokens(
        "عندك عندج لديك اخذت اخذتي تناولت تناولتي تتناول تاخذ تاخذين استخدمت جربت تعاني "
        "تعانين تحس تحسين تشعر تشعرين في فيه"
    )
)
# "Is it X?" and "Is your Y X?" guess at the cause unless X only describes the symptom.
_DESCRIPTORS = frozenset(
    phrase_tokens(
        "worse better there sharp dull constant bad severe mild sore itchy stiff numb "
        "swollen burning runny اسوا احسن قوي شديد خفيف مستمر"
    )
)
_DESCRIPTOR_LEADS = frozenset(phrase_tokens("still getting very more so too"))
# "Is the pain in your chest?" is the other thing a patient can be asked to confirm.
_LOCATION_LEADS = frozenset(phrase_tokens("in on في"))
_LOCATION_WORDS = _GATE_SUBJECTS | frozenset(phrase_tokens("your my the"))
# What may follow a descriptor: when it happens, and nothing about why.
_DESCRIPTOR_TAILS = frozenset(
    phrase_tokens(
        "at in on when after before during now today tonight than since all "
        "في بعد قبل لما الان اليوم الليل الصبح"
    )
)


@dataclass(frozen=True)
class FilterResult:
    ok: bool
    reasons: tuple[str, ...]


def _is_question(sentence: str) -> bool:
    return sentence.rstrip(_SENTENCE_CLOSERS).endswith(("?", "؟"))


def _opens_like_question(clause: str) -> bool:
    """True for "Any fever" and "Do you...", false for orders like "Have to take it"."""
    words = [token.text for token in tokenise(clause)[:2]]
    if not words:
        return False
    if words[0] == "any":
        return True
    return (
        words[0] in _QUESTION_OPENERS
        and len(words) == 2
        and words[1] in _QUESTION_SUBJECTS
    )


def _statement_part(sentence: str) -> str:
    """Drop the interrogative parts of a sentence, keeping any statement in it.

    A question mark exempts only the clause it closes and an opening "Have" only
    its own clause, so "Have a rest, you have the flu." is still checked.
    """
    is_question = _is_question(sentence)
    clauses = _CLAUSE_SPLIT.split(sentence)
    kept = [
        clause
        for index, clause in enumerate(clauses)
        if not (is_question and index == len(clauses) - 1)
        and not _opens_like_question(clause)
    ]
    return ", ".join(kept)


def _interrogative_clauses(sentence: str) -> list[str]:
    """Every clause a question could hide in, with or without a question mark."""
    clauses = _CLAUSE_SPLIT.split(sentence)
    if _is_question(sentence):
        return clauses
    return [clause for clause in clauses if _opens_like_question(clause)]


def _first_word(tokens: Sequence[Token]) -> int:
    """Index of the first token that is not a lead-in such as "and" or "please"."""
    for index, token in enumerate(tokens):
        if token.text not in _LEAD_INS:
            return index
    return len(tokens)


def _questions_a_condition(tokens: Sequence[Token]) -> bool:
    """True for "Is it the flu?", false for the history question "Do you have asthma?"."""
    if not contains_any(tokens, DISEASE_TERMS):
        return False
    first = _first_word(tokens)
    for opener in _HISTORY_OPENERS:
        if first in phrase_starts(tokens, opener):
            return contains_any(tokens[first + len(opener) :], _CONDITION_TRIGGERS)
    return True


def _names_diagnosis_word(tokens: Sequence[Token]) -> bool:
    for phrase in _DIAGNOSIS_WORDS:
        for start in phrase_starts(tokens, phrase):
            if not any(token.text in _REFUSALS for token in tokens[:start]):
                return True
    return False


def _presents_diagnosis(tokens: Sequence[Token], *, read_back: bool) -> bool:
    """Any disease in a model's statement. A read-back may echo one with no trigger."""
    if _names_diagnosis_word(tokens):
        return True
    if not contains_any(tokens, DISEASE_TERMS):
        return False
    if not read_back:
        return True
    return contains_any(tokens, _CONDITION_TRIGGERS) or contains_any(
        tokens, _SECOND_PERSON
    )


def _names_symptom_throughout(tokens: Sequence[Token]) -> bool:
    """True when each "and" part up to the next punctuation mark names a symptom.

    "You have a cough and a fever." passes, "You have a fever and an allergy." does
    not, because the second part is a condition on the patient all the same.
    """
    parts: list[list[Token]] = [[]]
    for token in tokens:
        if token.after_punctuation:
            break
        if token.starts_clause and parts[-1]:
            parts.append([])
        parts[-1].append(token)
    return all(contains_any(part, _SYMPTOMS) for part in parts)


def _claims_condition(tokens: Sequence[Token]) -> bool:
    """True for "You have X" and "عندك X" where X is anything but a reported symptom."""
    for opener in _CONDITION_OPENERS:
        for start in phrase_starts(tokens, opener):
            rest = tokens[start + len(opener) :]
            if rest and rest[0].text in _REPORTING_VERBS:
                continue
            if not _names_symptom_throughout(rest):
                return True
    return False


def _drugs_named(tokens: Sequence[Token]) -> set[str]:
    return {
        canonical
        for canonical, phrases in _DRUG_PHRASES.items()
        if contains_any(tokens, phrases)
    }


def _drug_without_took_word(sentence: str) -> bool:
    """True for "Paracetamol is best." and false for "34F, took paracetamol."."""
    for clause in _CLAUSE_SPLIT.split(sentence):
        tokens = tokenise(clause)
        took = [start for phrase in _TOOK_WORDS for start in phrase_starts(tokens, phrase)]
        earliest = min(took, default=len(tokens))
        for phrases in _DRUG_PHRASES.values():
            for phrase in phrases:
                if any(start < earliest for start in phrase_starts(tokens, phrase)):
                    return True
    return False


def _gives_advice(tokens: Sequence[Token]) -> bool:
    if not _drugs_named(tokens):
        return False
    for phrase in _ADVICE_TRIGGERS:
        for start in phrase_starts(tokens, phrase):
            follower = start + len(phrase)
            is_noun_use = (
                phrase == ("use",)
                and follower < len(tokens)
                and tokens[follower].text == "of"
            )
            if not is_noun_use:
                return True
    return False


def _is_order(
    tokens: Sequence[Token], index: int, imperatives: frozenset[str]
) -> bool:
    """True when the token at `index` opens a clause as an imperative.

    Attached و is treated as "and", since وخذ never appears as a token of its own.
    """
    token = tokens[index]
    joined = token.text.startswith("و") and token.text[1:] in imperatives
    if token.text not in imperatives and not joined:
        return False
    opens = (
        joined
        or token.starts_clause
        or (index > 0 and tokens[index - 1].text in _LEAD_INS)
    )
    following = tuple(item.text for item in tokens[index + 1 : index + 3])
    harmless = following in _HARMLESS_ORDERS or following[:1] == ("of",)
    return opens and not harmless


def _orders_treatment(tokens: Sequence[Token], imperatives: frozenset[str]) -> bool:
    return any(_is_order(tokens, index, imperatives) for index in range(len(tokens)))


def _question_opens_on_order(tokens: Sequence[Token]) -> bool:
    """True for "Take paracetamol?". Only the opening counts: "Can you eat and drink?"."""
    first = _first_word(tokens)
    return first < len(tokens) and _is_order(tokens, first, _IMPERATIVES)


def _doses(text: str) -> set[str]:
    doses = {
        f"{quantity}{_UNIT_CANONICAL[unit]}" for quantity, unit in _DOSE.findall(text)
    }
    for word, unit in _SPELLED_DOSE.findall(text):
        doses.add(f"{_NUMBER_WORDS[word]}{_UNIT_CANONICAL[unit]}")
    if _ARABIC_DUAL_DOSE.search(text):
        doses.add("2tablet")
    return doses


def _has_unlisted_dose(
    sentence: str, allowed: Sequence[tuple[set[str], set[str]]]
) -> bool:
    doses = _doses(sentence)
    if not doses:
        return False
    named = _drugs_named(tokenise(sentence))
    allowed_drugs = set().union(*(drugs for _, drugs in allowed)) if allowed else set()
    if named - allowed_drugs:
        return True
    for dose in doses:
        holders = [drugs for entry_doses, drugs in allowed if dose in entry_doses]
        if not holders:
            return True
        if named and not any(named & drugs for drugs in holders):
            return True
    return False


def _mentions_queue(sentence: str, queue_terms: Sequence[tuple[str, ...]]) -> bool:
    if _TICKET.search(sentence):
        return True
    if contains_any(tokenise(_statement_part(sentence)), _QUEUE_WORDS):
        return True

    # A pain scale question may say "number" and "0 to 10". Only those words are
    # excused: another number, or a statement beside the question, is still checked.
    body = _PAIN_SCALE.sub(" ", sentence) if _is_question(sentence) else sentence
    named = _statement_part(sentence) if body != sentence else sentence
    if contains_any(tokenise(named), queue_terms):
        return True
    if _COUNT.search(body) and contains_any(tokenise(body), _PLACE_WORDS):
        return True

    if _ORDINAL_PLACE.search(sentence):
        return True

    tokens = tokenise(sentence)
    gives_time = _MINUTES.search(sentence) or _HOURS.search(sentence)
    return bool(gives_time) and contains_any(tokens, _WAIT_TERMS)


def _allowed_entries(
    allowed_meds: Iterable[str],
) -> list[tuple[set[str], set[str]]]:
    entries = []
    for med in allowed_meds:
        norm = normalise(med)
        entries.append((_doses(norm), _drugs_named(tokenise(norm))))
    return entries


def _result(found: set[str]) -> FilterResult:
    order = ("diagnosis", "drug_dose", "treatment_advice", "queue_number")
    reasons = tuple(reason for reason in order if reason in found)
    return FilterResult(ok=not reasons, reasons=reasons)


def _shared_reasons(
    sentence: str,
    allowed: Sequence[tuple[set[str], set[str]]],
    imperatives: frozenset[str],
    queue_terms: Sequence[tuple[str, ...]],
) -> set[str]:
    found = set()
    if _has_unlisted_dose(sentence, allowed):
        found.add("drug_dose")
    statement = tokenise(_statement_part(sentence))
    if _gives_advice(statement) or _orders_treatment(statement, imperatives):
        found.add("treatment_advice")
    if _mentions_queue(sentence, queue_terms):
        found.add("queue_number")
    return found


def _all_words_are(tokens: Sequence[Token], allowed: frozenset[str]) -> bool:
    """Every token is in `allowed`, bare or with an Arabic proclitic."""
    return all(
        token.text in allowed or any(token_matches(word, token.text) for word in allowed)
        for token in tokens
    )


def _word_is(token: Token, words: frozenset[str]) -> bool:
    return _all_words_are((token,), words)


def _is_patients_word(token: Token, said: frozenset[str]) -> bool:
    """True for a word the question has only from `known`, not from the gate."""
    return _word_is(token, said) and not _word_is(token, _GATE_WORDS)


def _opens_on(tokens: Sequence[Token], phrases: Iterable[Sequence[str]]) -> bool:
    return any(0 in phrase_starts(tokens, phrase) for phrase in phrases)


def _is_acknowledgement(text: str) -> bool:
    bare = text.rstrip(" .!")
    tokens = tokenise(bare)
    return (
        _ACK_SHAPE.fullmatch(bare) is not None
        and 0 < len(tokens) <= _MAX_ACK_WORDS
        and _all_words_are(tokens, _ACK_WORDS)
    )


def _describes(tokens: Sequence[Token]) -> bool:
    """True for "worse", "still there", "worse at night" and "in your chest"."""
    if len(tokens) > 1 and _word_is(tokens[0], _LOCATION_LEADS):
        return _all_words_are(tokens[1:], _LOCATION_WORDS)
    rest = list(tokens)
    while rest and rest[0].text in _DESCRIPTOR_LEADS:
        rest.pop(0)
    if not rest or not _word_is(rest[0], _DESCRIPTORS):
        return False
    tail = rest[1:]
    return not tail or (
        _word_is(tail[0], _DESCRIPTOR_TAILS) and _all_words_are(tail, _GATE_WORDS)
    )


def _describes_a_subject(tokens: Sequence[Token], said: frozenset[str]) -> bool:
    """True for "pain worse" and "left arm sore", false for "problem shingles"."""
    starts = _DESCRIPTORS | _DESCRIPTOR_LEADS | _LOCATION_LEADS
    for index in range(1, len(tokens)):
        if _word_is(tokens[index], starts):
            return _all_words_are(tokens[:index], _GATE_SUBJECTS | said) and _describes(
                tokens[index:]
            )
    return False


def _guesses_a_cause(tokens: Sequence[Token], said: frozenset[str]) -> bool:
    if _opens_on(tokens, _IS_IT):
        return not _describes(tokens[2:])
    if _opens_on(tokens, _IS_SUBJECT):
        return not _describes_a_subject(tokens[2:], said)
    if _opens_on(tokens, (_HAL,)):
        asks = len(tokens) > 1 and _word_is(tokens[1], _HAL_ASKS)
        return not asks and not _describes_a_subject(tokens[1:], said)
    return False


def _offers_treatment(tokens: Sequence[Token], said: frozenset[str]) -> bool:
    """True for a suggestion worded as a question, in vocabulary the gate allows."""
    if contains_any(tokens, _INFINITIVE_ORDERS):
        return True
    for index, token in enumerate(tokens):
        rest = tokens[index + 1 :]
        if token.text == "should" and (not rest or rest[0].text != "know"):
            return True
        if _word_is(token, _TRY_WORDS) and not (
            rest and (_word_is(rest[0], _TRY_OBJECTS) or _is_patients_word(rest[0], said))
        ):
            return True
        if _word_is(token, _WANT_VERBS) and any(
            _word_is(later, _TAKING_WORDS) or _is_patients_word(later, said) for later in rest
        ):
            return True
        if (
            token_matches("ما", token.text)
            and rest
            and _word_is(rest[0], _SECOND_PERSON_TAKE)
        ):
            return True
    return False


def _leans_on_a_known_word(tokens: Sequence[Token], said: frozenset[str]) -> bool:
    """True when a patient's word is given as a cause or equated with something.

    A copula that opens the question is the frame, which _guesses_a_cause reads.
    """
    for index, token in enumerate(tokens):
        if token.text.isdigit() or not _is_patients_word(token, said):
            continue
        before = index - 1
        while before >= 0 and tokens[before].text in _NOUN_LEADS:
            before -= 1
        if before >= 0 and _word_is(tokens[before], _CAUSE_WORDS):
            return True
        if before >= 1 and tokens[before].text in _COPULAS:
            return True
        if index + 1 < len(tokens) and tokens[index + 1].text in _COPULAS:
            return True
    return False


def _without_scale(tokens: Sequence[Token]) -> Sequence[Token]:
    """Drop a closing 0 to 10 scale from a question that asks how bad something is."""
    if not _opens_on(tokens, _SCALE_FRAMES):
        return tokens
    words = tuple(token.text for token in tokens)
    for scale in _SCALES:
        if words[-len(scale) :] == scale:
            return tokens[: -len(scale)]
    return tokens


def _is_plain_question(tokens: Sequence[Token], said: frozenset[str]) -> bool:
    body = tokens[1:] if tokens and tokens[0].text in _GATE_LEAD_INS else tokens
    words = _without_scale(body)
    return (
        0 < len(body) <= _MAX_QUESTION_WORDS
        and _opens_on(words, _GATE_FRAMES)
        and not _opens_on(words, _REFUSED_FRAMES)
        and _all_words_are(words, _GATE_WORDS | said)
        and not _guesses_a_cause(words, said)
        and not _offers_treatment(words, said)
        and not _leans_on_a_known_word(words, said)
    )


def _usable_known_words(known: Iterable[str]) -> frozenset[str]:
    said = {token.text for item in known for token in tokenise(item)}
    return frozenset(
        word
        for word in said
        if not any(token_matches(never, word) for never in _NEVER_FROM_KNOWN)
    )


def gate_reply(text: str, *, known: Iterable[str] = ()) -> bool:
    """True only for one short question, after at most one acknowledgement.

    `known` holds what the patient said and what the record says, so a question may
    use their words. Any other word outside the gate's vocabulary fails it, which is
    why an unlisted disease or drug needs no entry anywhere to be refused.
    """
    norm = normalise(text)
    if norm.count("?") + norm.count("؟") != 1:
        return False
    *acknowledgements, last = split_sentences(norm)
    if not last.endswith(("?", "؟")):
        return False
    parts = _ACK_COMMA.split(last[:-1])
    acknowledgements.extend(parts[:-1])
    if len(acknowledgements) > 1 or not all(map(_is_acknowledgement, acknowledgements)):
        return False
    question = parts[-1].strip()
    if not _QUESTION_SHAPE.fullmatch(question):
        return False
    return _is_plain_question(tokenise(question), _usable_known_words(known))


def check_reply(
    text: str, *, allowed_meds: Sequence[str] = (), read_back: bool = False
) -> FilterResult:
    """Check a reply bound for the patient.

    A drug outside `allowed_meds` fails in any statement, with or without advice
    wording. A question may name one, as "Did you take paracetamol?" does, unless it
    opens on an order. A question may name a disease only as a history question.

    `read_back` is for simulated.summary_reply alone. There a statement may echo a
    disease the patient named, and a drug passes only after a took-word in its clause.
    """
    allowed = _allowed_entries(allowed_meds)
    covered = set().union(*(drugs for _, drugs in allowed))
    found: set[str] = set()
    for sentence in split_sentences(normalise(text)):
        found |= _shared_reasons(sentence, allowed, _IMPERATIVES, _QUEUE_TERMS)
        statement = tokenise(_statement_part(sentence))
        questions = [tokenise(clause) for clause in _interrogative_clauses(sentence)]
        if (
            _presents_diagnosis(statement, read_back=read_back)
            or _claims_condition(statement)
            or contains_any(statement, _GUESS_OPENERS)
            or any(_questions_a_condition(question) for question in questions)
        ):
            found.add("diagnosis")
        if _drugs_named(statement) - covered or any(
            _question_opens_on_order(question) for question in questions
        ):
            found.add("treatment_advice")
        if read_back and _drug_without_took_word(_statement_part(sentence)):
            found.add("treatment_advice")
    return _result(found)


def check_handoff(
    text: str,
    *,
    chronic: Sequence[str] = (),
    allergies: Sequence[str] = (),
    allowed_meds: Sequence[str] = (),
    self_medication: Sequence[str] = (),
) -> FilterResult:
    """Check a draft for the doctor. Only what is on file may be named.

    A condition must be on the record, and a drug must be in `allowed_meds`,
    `allergies` or `self_medication`. `self_medication` gives the name only, so a
    dose beside it still needs an `allowed_meds` entry.
    """
    allowed = _allowed_entries(allowed_meds)
    on_file = set().union(
        *(_drugs_named(tokenise(item)) for item in (*allowed_meds, *allergies, *self_medication))
    )
    record = tokenise("\n".join(normalise(item) for item in (*chronic, *allergies)))
    unrecorded = tuple(
        term for term in DISEASE_TERMS if not phrase_starts(record, term)
    )
    found: set[str] = set()
    for sentence in split_sentences(normalise(text)):
        found |= _shared_reasons(
            sentence, allowed, _HANDOFF_IMPERATIVES, _HANDOFF_QUEUE_TERMS
        )
        tokens = tokenise(sentence)
        if contains_any(tokens, unrecorded) or contains_any(tokens, _SPECULATION_TERMS):
            found.add("diagnosis")
        if _drugs_named(tokens) - on_file:
            found.add("treatment_advice")
    return _result(found)
