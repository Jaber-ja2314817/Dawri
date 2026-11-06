from __future__ import annotations

import json
from pathlib import Path

import pytest

from backend.ai import filters, simulated
from backend.ai.filters import check_handoff, check_reply
from backend.ai.text import phrase_tokens

SEED_DRUGS = Path(__file__).resolve().parents[1] / "seed" / "drugs.json"


def assert_clean(result):
    assert result.ok
    assert result.reasons == ()


@pytest.mark.parametrize(
    "text",
    [
        "You have the flu.",
        "You have the flu",
        "It looks like you have influenza",
        "عندك انفلونزا",
        "عندك إنفلونزا",
        "شكلك مصاب بالتهاب",
        "You've got a cold.",
        "You may have pneumonia.",
        "You might have asthma.",
        "You probably have bronchitis.",
        "This is sinusitis.",
        "It is tonsillitis.",
        "It's a migraine.",
        "Sounds like an ulcer.",
        "This could be gastritis.",
        "Likely anemia.",
        "Probably appendicitis.",
        "Have a rest, you have the flu.",
        "لديك ربو",
        "تعاني من قرحة",
        "مصابة بالسكري",
        "يمكن عندك ضغط دم",
        "Your diagnosis is the flu.",
        "The diagnosis is a chest infection",
        "تشخيصك واضح",
        "You seem to have the flu",
        "You caught a cold",
        "You have a virus",
        "You have a viral illness",
        "حالتك انفلونزا",
        "This looks like strep",
        "You're fighting a bacterial thing.",
        "Your asthma is back.",
        "انت معك فيروس",
        "فيك بكتيريا",
        "معك سكر",
    ],
)
def test_diagnosis_fails(text):
    assert "diagnosis" in check_reply(text).reasons


@pytest.mark.parametrize(
    "text",
    [
        "Do you have a fever?",
        "Do you have asthma?",
        "Do you have diabetes",
        "Any history of asthma",
        "عندك حرارة؟",
        "عندك حساسية من شي؟",
        "عندك سكري؟",
        "You have a fever",
        "You have a cough and a fever.",
        "I can't give a diagnosis.",
        "لا أستطيع إعطاء تشخيص.",
        "How long have you had this?",
        "",
        "Do you have a virus?",
        "Have you had the flu?",
        "Is your asthma worse?",
        "حالتك كيف؟",
    ],
)
def test_not_a_diagnosis(text):
    assert "diagnosis" not in check_reply(text).reasons


def test_statement_before_a_question_in_one_sentence_still_fails():
    assert "diagnosis" in check_reply("You have the flu, do you have a fever?").reasons


@pytest.mark.parametrize(
    "text",
    [
        "Take 500 mg",
        "500mg",
        "2 tablets",
        "two tablets",
        "1 capsule",
        "10 ml",
        "250 mcg",
        "1 g",
        "1.5 g",
        "1 pill",
        "500 ملغ",
        "٥٠٠ ملغ",
        "500 مغ",
        "500 ملجم",
        "10 مل",
        "2 حبة",
        "3 حبات",
        "خذ حبتين",
        "1 قرص",
        "Did you take 500 mg?",
        "هل أخذت 500 ملغ؟",
    ],
)
def test_dose_fails(text):
    assert "drug_dose" in check_reply(text).reasons


@pytest.mark.parametrize(
    "text",
    ["Temp 38.5", "Pain 6 out of 10", "BP 150/90", "Weight 70 kg", "Glucose 110 mg/dl"],
)
def test_other_numbers_are_not_doses(text):
    assert "drug_dose" not in check_handoff(text).reasons


def test_dose_on_the_record_passes():
    assert check_reply("Your amlodipine 5 mg stays the same.", allowed_meds=[
        "amlodipine 5 mg once daily"
    ]).ok


@pytest.mark.parametrize(
    "text",
    ["amlodipine 15 mg", "amlodipine 0.5 mg", "ibuprofen 5 mg", "amlodipine 5 ml"],
)
def test_different_dose_or_drug_is_not_covered_by_the_record(text):
    result = check_reply(text, allowed_meds=["amlodipine 5 mg once daily"])
    assert "drug_dose" in result.reasons


def test_listed_drug_with_another_listed_drugs_dose_fails():
    allowed = ["amlodipine 5 mg once daily", "metformin 500 mg twice daily"]
    assert "drug_dose" in check_reply("amlodipine 500 mg", allowed_meds=allowed).reasons


def test_two_listed_drugs_with_their_own_doses_pass():
    allowed = ["amlodipine 5 mg once daily", "metformin 500 mg twice daily"]
    text = "amlodipine 5 mg and metformin 500 mg"
    assert "drug_dose" not in check_reply(text, allowed_meds=allowed).reasons


def test_arabic_dose_matches_english_record():
    result = check_reply("أملوديبين 5 ملغ", allowed_meds=["amlodipine 5 mg once daily"])
    assert "drug_dose" not in result.reasons


@pytest.mark.parametrize(
    "text",
    [
        "Take paracetamol.",
        "Try ibuprofen.",
        "Use panadol",
        "You should take adol",
        "I recommend brufen",
        "Take aspirin",
        "Take augmentin",
        "Take an antibiotic",
        "خذ بنادول",
        "خذي باراسيتامول",
        "جرب بروفين",
        "جربي مضاد حيوي",
        "استخدم مضاد حيوي",
        "تناول أموكسيسيلين",
        "أنصحك بنادول",
        "انصحك باراسيتامول",
    ],
)
def test_treatment_advice_fails(text):
    assert "treatment_advice" in check_reply(text).reasons


@pytest.mark.parametrize(
    "text",
    [
        "Did you take any medicine for it?",
        "Did you take paracetamol?",
        "أخذت أي دوا له؟",
        "Take a seat.",
        "Take your time.",
        "هل أخذت بنادول؟",
    ],
)
def test_questions_and_harmless_imperatives_pass(text):
    assert_clean(check_reply(text))


@pytest.mark.parametrize(
    "text",
    [
        "You need antibiotics",
        "You need paracetamol",
        "She needs ibuprofen.",
        "You must get aspirin.",
        "You have to get paracetamol.",
        "Have to get paracetamol.",
        "Do take paracetamol.",
        "Treat it with paracetamol.",
        "Give it paracetamol.",
        "Start ibuprofen.",
        "Consider ibuprofen.",
        "Prescribe amoxicillin.",
        "تحتاج مضاد حيوي",
        "تحتاجين بنادول",
        "لازم بنادول",
        "اشرب بنادول",
        "اشربي باراسيتامول",
        "تَحْتَاج بَنَادُول",
    ],
)
def test_new_advice_triggers_fail(text):
    assert "treatment_advice" in check_reply(text).reasons


@pytest.mark.parametrize(
    "text",
    [
        "Do you need your usual medicine?",
        "Do you need paracetamol?",
        "Did you give it paracetamol?",
        "Have you had to take paracetamol?",
        "هل تحتاج بنادول؟",
        "You need to see the nurse.",
        "You must rest.",
        "لازم تشوف الممرضة.",
    ],
)
def test_new_advice_triggers_leave_questions_and_drugless_text_alone(text):
    assert "treatment_advice" not in check_reply(text).reasons


@pytest.mark.parametrize(
    "text",
    ["Have you got a virus?", "Do you take paracetamol?", "Did the paracetamol help?"],
)
def test_real_questions_still_count_as_questions(text):
    assert filters._statement_part(text) == ""


@pytest.mark.parametrize("text", ["Have to rest", "Do rest", "Have a rest", "Are"])
def test_an_opener_alone_does_not_make_a_question(text):
    assert filters._statement_part(text) == text


def test_mixed_text_fails_on_its_second_sentence():
    result = check_reply("Have you taken paracetamol? Take 1000 mg now.")
    assert "drug_dose" in result.reasons


def test_advice_in_second_sentence_after_a_question():
    result = check_reply("Any fever? Take paracetamol.")
    assert "treatment_advice" in result.reasons


@pytest.mark.parametrize(
    "text",
    [
        "Your number is T-014",
        "T-014",
        "p-031",
        "D-GP-023",
        "Your queue number will be sent",
        "Your position is third",
        "You are in line",
        "There are 3 people ahead",
        "Two patients ahead of you",
        "Your turn is next",
        "رقمك 14",
        "دورك رقم 5",
        "ترتيبك الثالث",
        "قدامك 3 أشخاص",
        "أمامك ثلاثة",
        "The wait is about 12 minutes.",
        "You will be seen in 10 mins",
        "وقت الانتظار 12 دقيقة",
        "تنتظر 10 دقايق",
        "You are number 5 in the queue",
        "Your ticket number is 14",
        "Your queue position is 5",
        "You are next in the queue",
        "You are next in",
        "There are 3 people before you",
        "There are three people before you",
        "أنت رقم 5 في الطابور",
        "رقم تذكرتك 14",
        "انتظارك 12 دقيقة",
        "انتظارك 12",
        "انتظارك عشرين دقيقة",
        "دورك بعد 3 أشخاص",
        "دورك بعد ثلاثة أشخاص",
        "قبلك 4 أشخاص",
        "The queue is short.",
        "Keep your ticket.",
        "الطابور طويل",
        "احتفظ بالتذكرة",
        "You are 3 in line.",
        "Position 2.",
        "Turn 7 is yours.",
        "2 ahead.",
        "Is your number 14?",
        "Is 14 your position?",
    ],
)
def test_queue_number_fails(text):
    assert "queue_number" in check_reply(text).reasons


@pytest.mark.parametrize(
    "text",
    [
        "The pain lasted 30 minutes?",
        "covid-19",
        "Thanks, see the nurse when you arrive.",
        "How bad is it from 0 to 10?",
        "كم شدته من 0 إلى 10؟",
        "On a scale of 0 to 10, what number is the pain?",
        "What number is it, 0 to 10?",
        "What is your number from 0-10?",
        "What number out of 10?",
        "رقم كم من 0 إلى 10؟",
        "Do you have a fever?",
        "عندك حرارة؟",
        "Did you take any medicine for it?",
        "Is there a long queue where you are?",
        "شكرا على انتظارك",
        "It started 3 days ago.",
        "Please go to the emergency department or call 999.",
        "Please message your centre's refill line.",
    ],
)
def test_queue_rule_leaves_these_alone(text):
    assert "queue_number" not in check_reply(text).reasons


@pytest.mark.parametrize(
    "text",
    [
        "You are number 5, how bad is it from 0 to 10?",
        "You are number 5 from 0 to 10?",
        "Your position is third, how bad is it from 0 to 10?",
        "Your ticket is T-014, how bad is it from 0 to 10?",
        "You are number 5 from 0 to 10.",
    ],
)
def test_the_scale_exception_excuses_only_the_scale(text):
    assert "queue_number" in check_reply(text).reasons


def test_a_listed_word_with_no_number_is_not_a_queue_claim():
    assert "queue_number" not in check_reply("Where in this line did it start?").reasons
    assert "queue_number" not in check_reply("دور البرد").reasons


@pytest.mark.parametrize(
    ("text", "reason"),
    [
        ("عِنْدَكَ إِنْفْلُوَنْزَا", "diagnosis"),
        ("شَكْلَكَ مُصَابٌ بِالْتِهَابٍ", "diagnosis"),
        ("تَشْخِيصُكَ وَاضِح", "diagnosis"),
        ("خُذْ ٥٠٠ مَلْغ", "drug_dose"),
        ("خُذْ حَبَّتَيْنِ", "drug_dose"),
        ("خُذْ بَنَادُول", "treatment_advice"),
        ("رَقَمُكَ ١٤", "queue_number"),
        ("قُدَّامَكَ ثَلَاثَة", "queue_number"),
        ("حَالَتُكَ إِنْفْلُوَنْزَا", "diagnosis"),
        ("مَعَكَ فَيْرُوس", "diagnosis"),
        ("لَازِم بَنَادُول", "treatment_advice"),
        ("أَنْتَ رَقْم ٥ فِي الطَّابُور", "queue_number"),
        ("اِنْتِظَارُكَ ١٢ دَقِيقَة", "queue_number"),
    ],
)
def test_arabic_with_diacritics_cannot_hide(text, reason):
    assert reason in check_reply(text).reasons


def test_reasons_come_back_in_a_fixed_order():
    result = check_reply("You have the flu. Take paracetamol 500 mg. Your number is T-014")
    assert result.reasons == (
        "diagnosis",
        "drug_dose",
        "treatment_advice",
        "queue_number",
    )
    assert not result.ok


@pytest.mark.parametrize(
    "text",
    [
        "What brings you in today?",
        "شو اللي يتعبك اليوم؟",
        "How bad is it from 0 to 10?",
        "Anything else the nurse should know?",
        "Since when?",
    ],
)
def test_the_vault_questions_pass(text):
    assert_clean(check_reply(text))


def test_seed_drugs_are_all_in_the_lexicon():
    known = {
        phrase
        for names in filters.DRUG_NAMES.values()
        for phrase in (phrase_tokens(name) for name in names)
    }
    words = {word for phrase in known for word in phrase}
    for drug in json.loads(SEED_DRUGS.read_text(encoding="utf-8")):
        english = phrase_tokens(drug["name_en"].removesuffix(" syrup"))
        arabic = phrase_tokens(drug["name_ar"])
        assert set(english) <= words, drug["name_en"]
        assert any(token in words for token in arabic), drug["name_ar"]


@pytest.mark.parametrize(
    "name", ["paracetamol", "باراسيتامول", "co-amoxiclav", "ديكستروميثورفان"]
)
def test_seed_names_are_caught_in_advice(name):
    assert "treatment_advice" in check_reply(f"خذ {name}").reasons


def test_history_on_the_record_passes():
    assert_clean(check_handoff("History: hypertension.", chronic=["hypertension"]))


def test_record_term_inside_a_longer_entry_passes():
    assert_clean(check_handoff("History: diabetes.", chronic=["type 2 diabetes"]))


def test_history_not_on_the_record_fails():
    assert "diagnosis" in check_handoff("History: hypertension.").reasons


def test_another_condition_is_not_covered_by_the_record():
    result = check_handoff("History: asthma.", chronic=["hypertension"])
    assert "diagnosis" in result.reasons


@pytest.mark.parametrize(
    "text",
    [
        "Likely viral infection",
        "Probable pneumonia.",
        "Possible chest problem.",
        "Suspected sinus trouble.",
        "Findings consistent with a virus.",
        "Suggestive of a virus.",
        "Differential includes a virus.",
        "Diagnosis pending.",
        "Impression: virus.",
        "تشخيص أولي",
        "يرجح أنها عدوى",
    ],
)
def test_handoff_speculation_fails(text):
    assert "diagnosis" in check_handoff(text).reasons


def test_listed_drug_with_dose_passes():
    assert_clean(
        check_handoff(
            "Medicines: amlodipine 5 mg once daily.",
            allowed_meds=["amlodipine 5 mg once daily"],
        )
    )


def test_drug_with_dose_not_listed_fails():
    assert "drug_dose" in check_handoff("Took paracetamol 500 mg.").reasons


def test_self_medication_without_a_dose_passes():
    took = ["paracetamol"]
    assert_clean(check_handoff("Took paracetamol", self_medication=took))
    assert_clean(check_handoff("Reports use of paracetamol.", self_medication=took))


def test_self_medication_allows_the_name_and_never_a_dose():
    result = check_handoff("Took paracetamol 500 mg.", self_medication=["paracetamol 500 mg"])
    assert "drug_dose" in result.reasons


def test_a_self_medication_brand_covers_the_generic():
    assert_clean(check_handoff("Took paracetamol.", self_medication=["Panadol"]))
    assert_clean(check_handoff("أخذ باراسيتامول.", self_medication=["paracetamol"]))


@pytest.mark.parametrize(
    "text",
    ["Took paracetamol", "On metformin.", "No antibiotics taken.", "Is she on ibuprofen?"],
)
def test_a_drug_on_no_list_fails_even_without_advice(text):
    assert "treatment_advice" in check_handoff(text).reasons


def test_each_list_can_name_a_drug():
    assert_clean(check_handoff("Allergy: penicillin.", allergies=["penicillin"]))
    assert_clean(check_handoff("On amlodipine.", allowed_meds=["amlodipine 5 mg once daily"]))
    assert_clean(check_handoff("Took ibuprofen.", self_medication=["ibuprofen"]))


def test_one_listed_drug_does_not_cover_another():
    result = check_handoff("Took paracetamol and ibuprofen.", self_medication=["paracetamol"])
    assert "treatment_advice" in result.reasons


def test_a_drug_named_as_an_allergy_is_not_a_drug_to_give():
    result = check_handoff("Give penicillin.", allergies=["penicillin"])
    assert "treatment_advice" in result.reasons


def test_handoff_keeps_the_reply_bans():
    assert "treatment_advice" in check_handoff("Take paracetamol.").reasons
    assert "queue_number" in check_handoff("Ticket T-014.").reasons


def test_handoff_questions_are_not_exempt_from_the_disease_check():
    assert "diagnosis" in check_handoff("Is this the flu?").reasons


def test_full_template_style_handoff_passes():
    text = (
        "34F, Arabic speaker.\n"
        "Fever and dry cough for 3 days, severity 6/10.\n"
        "History: none recorded. Allergies: penicillin.\n"
        "Vitals: temperature 38.5 C, BP 120/80, pulse 88, SpO2 98.\n"
        "Concerns: Patient denied: chest pain. Took paracetamol."
    )
    assert_clean(check_handoff(text, allergies=["penicillin"], self_medication=["paracetamol"]))


@pytest.mark.parametrize(
    "text",
    [
        "Assessment: stable.",
        "Rule out a chest problem.",
        "R/O chest problem.",
        "DDx includes dehydration.",
        "Viral.",
        "A virus.",
        "Bacterial.",
        "URTI.",
        "UTI.",
        "Sepsis.",
        "فيروس.",
        "بكتيريا.",
    ],
)
def test_handoff_speculation_terms_fail(text):
    assert "diagnosis" in check_handoff(text).reasons


@pytest.mark.parametrize(
    "text",
    [
        "Treat with amoxicillin.",
        "Give paracetamol.",
        "Consider antibiotics.",
        "Start ibuprofen.",
        "Needs azithromycin.",
        "Must have cetirizine.",
        "Prescribe metformin.",
    ],
)
def test_handoff_advice_triggers_fail_even_for_a_listed_drug(text):
    listed = [name for name in filters.DRUG_NAMES if name in text.lower()] + ["antibiotics"]
    result = check_handoff(text, allowed_meds=listed, self_medication=listed)
    assert "treatment_advice" in result.reasons


def with_diacritics(text):
    """Put a fatha after every Arabic letter, the worst case for a word match."""
    return "".join(f"{ch}َ" if "ء" <= ch <= "ي" else ch for ch in text)


ARABIC_DIAGNOSES = [
    "عندك برد.",
    "عندك رشح.",
    "عندك حساسية.",
    "عندك جفاف.",
    "عندك إكزيما.",
    "يبدو أنه برد.",
    "هذا زكام.",
    "هذي نزلة برد.",
    "هذه نزلة برد.",
    "عندج موعد.",
    "لديك مشكلة.",
    "معك مشكلة.",
    "معج مشكلة.",
    "فيك مشكلة.",
    "فيج مشكلة.",
    "مصاب بشيء.",
    "مصابة بشيء.",
    "تعاني من مشكلة.",
    "تعانين من مشكلة.",
    "شكلك تعبان.",
    "شكله تعب.",
    "شكلها تعب.",
    "ربما تعب.",
    "غالبا تعب.",
    "على الأغلب تعب.",
]


@pytest.mark.parametrize(
    "text",
    [
        "You have eczema.",
        "You have a UTI.",
        "You have a stomach bug.",
        "You have reflux.",
        "You have an allergy.",
        "You have high blood pressure.",
        "You've caught a cold.",
        "You have a bad cold.",
        "You're dehydrated.",
        "You are diabetic.",
        "You are anemic.",
        "This looks like eczema.",
        "That could be conjunctivitis.",
        "You have something unusual.",
        "You've got something going around.",
        "You got something from work.",
        "You caught something.",
        "You've something unusual.",
        "You have a fever and an allergy.",
        "You have an allergy and a fever.",
        "This looks like nothing serious.",
        "It sounds like a seasonal thing.",
        "It seems like a passing problem.",
        "It seems to be a passing problem.",
        "It appears to be a passing problem.",
        "This could be nothing.",
        "It might be nothing.",
        "It may be nothing.",
        "It must be the weather.",
        "Probably nothing.",
        "Likely nothing.",
        "I think it is nothing.",
        "I suspect a passing problem.",
        *ARABIC_DIAGNOSES,
        *(with_diacritics(text) for text in ARABIC_DIAGNOSES),
    ],
)
def test_a_condition_or_a_guess_fails_with_any_object(text):
    assert "diagnosis" in check_reply(text).reasons


@pytest.mark.parametrize(
    "text",
    [
        "You have a fever",
        "You have a cough and a fever.",
        "You have a sore throat.",
        "You've got a headache.",
        "عندك حرارة.",
        "عندك كحة وحرارة.",
        "You have told me enough.",
        "You have said that.",
        "You've mentioned it already.",
        "You have asked the nurse.",
        "You have been very clear.",
        "You have had this for 3 days.",
        "Do you have a fever?",
        "Do you have eczema?",
        "عندك حساسية؟",
        "Could this be from food?",
        "Is it likely to come back?",
    ],
)
def test_reported_symptoms_and_questions_are_not_a_condition(text):
    assert "diagnosis" not in check_reply(text).reasons


@pytest.mark.parametrize(
    "text",
    [
        "Paracetamol will help.",
        "Paracetamol should help with that.",
        "Two Panadol should help.",
        "Panadol helps.",
        "Ibuprofen is good for this.",
        "Antibiotics are common.",
        "Vitamins are fine.",
        "بنادول يفيدك.",
        "البنادول يساعدك.",
        "البنادول ينفعك.",
        "ممكن تاخذ بنادول.",
        "تقدر تاخذ بنادول.",
        "تقدرين تاخذين بنادول.",
        "Take Cataflam.",
        "Take an antihistamine.",
        "Take some cough syrup.",
        "Try a decongestant.",
        "Use a nasal spray.",
        "اشرب شراب كحة.",
        "Take rest.",
        "Please drink water.",
        "Rest and drink water.",
        "Apply a cold cloth.",
        "Here is what I will tell the nurse: Take rest and drink water.",
        "خذ راحة.",
        "خذي راحة.",
        "جرب العسل.",
        "جربي العسل.",
        "استخدم الكمادات.",
        "استخدمي الكمادات.",
        "تناول الزنجبيل.",
        "تناولي الزنجبيل.",
        "اشرب ماء.",
        "اشربي ماء.",
        "ارتاح واشرب ماء.",
    ],
)
def test_treatment_fails_with_any_object(text):
    assert "treatment_advice" in check_reply(text).reasons
    if any("ء" <= ch <= "ي" for ch in text):
        assert "treatment_advice" in check_reply(with_diacritics(text)).reasons


@pytest.mark.parametrize(
    "text",
    ["Take rest.", "Try honey.", "Use a cold cloth.", "Drink water.", "Apply ice.", "اشرب ماء"],
)
def test_an_order_also_fails_a_handoff(text):
    assert "treatment_advice" in check_handoff(text).reasons


@pytest.mark.parametrize(
    "text",
    [
        "34F, can't drink water",
        "34F, cannot use her left hand.",
        "Reports use of an inhaler.",
        "Use of an inhaler reported.",
        "Patient wants to try again.",
    ],
)
def test_a_summary_is_not_an_order(text):
    result = check_handoff(text, self_medication=["inhaler"])
    assert "treatment_advice" not in result.reasons


@pytest.mark.parametrize(
    "text",
    [
        "Take a seat.",
        "Please take a seat.",
        "Take your time.",
        "Did you take any medicine for it?",
        "Did you try anything for it?",
        "Do you drink enough water?",
        "Did you take paracetamol?",
        "Did the cough syrup help?",
    ],
)
def test_harmless_orders_and_questions_pass(text):
    assert "treatment_advice" not in check_reply(text).reasons


def test_a_drug_on_the_record_may_be_named_and_no_other():
    allowed = ["amlodipine 5 mg once daily"]
    assert_clean(check_reply("Your amlodipine 5 mg stays the same.", allowed_meds=allowed))
    assert_clean(check_reply("Your amlodipine stays the same.", allowed_meds=allowed))
    assert_clean(check_reply("أملوديبين كما هو.", allowed_meds=allowed))
    result = check_reply("Your metformin stays the same.", allowed_meds=allowed)
    assert "treatment_advice" in result.reasons


def test_the_handoff_keeps_its_own_drug_list():
    """Rule 5 is check_reply only: a handoff has its own on-file drug list."""
    assert_clean(check_handoff("Took paracetamol.", self_medication=["paracetamol"]))


@pytest.mark.parametrize(
    ("said", "canonical"),
    [
        ("took cough syrup", "cough syrup"),
        ("I took some syrup", "cough syrup"),
        ("أخذت شراب كحة", "cough syrup"),
        ("took an antihistamine", "antihistamine"),
        ("took vitamins", "vitamin"),
        ("استخدمت بخاخ", "inhaler"),
    ],
)
def test_the_simulated_receptionist_reads_generic_forms(said, canonical):
    assert simulated.parse_medicines(said) == [canonical]


def test_a_patient_saying_they_took_cough_syrup_reaches_a_valid_intake():
    history = [{"role": "assistant", "content": simulated.OPENING["en"], "slot": "complaint"}]
    answers = ["I have a cough for 2 days", "5", "took cough syrup", "no"]
    patient = {"age": 34, "sex": "F"}
    turn = None
    for answer in answers:
        history.append({"role": "user", "content": answer})
        turn = simulated.next_turn(history, patient, (), "en")
        history.append({"role": "assistant", "content": turn.reply, "slot": turn.slot})
    assert turn.intake is not None
    assert turn.intake["self_medication"] == ["cough syrup"]


@pytest.mark.parametrize(
    "text",
    [
        "You are next.",
        "You're next.",
        "You are first.",
        "You're first.",
        "You are 3rd.",
        "You're 3rd.",
        "You are third.",
        "You're the second.",
        "T014",
        "t14",
        "ت-014",
        "ت-٠١٤",
        "ت014",
        "3 people are waiting.",
        "Three patients are here.",
        "5 waiting.",
        "3 ناس",
        "ثلاثة اشخاص",
        "4 مرضى",
        "Please wait for your turn.",
        "Your turn will come in about an hour.",
        "Wait one hour.",
        "Wait half an hour.",
        "Expect to wait 2 hours.",
        "انتظر ساعة.",
        "انتظر نص ساعة.",
        "انتظر ساعتين.",
        "دورك قريب.",
        "أنت التالي.",
        "أنت الثالث.",
        "You will see the next one.",
    ],
)
def test_general_queue_claims_fail(text):
    assert "queue_number" in check_reply(text).reasons
    assert "queue_number" in check_reply(with_diacritics(text)).reasons


@pytest.mark.parametrize(
    "text",
    [
        "Did it turn red?",
        "Dr. Noor will see you.",
        "Go to room 4.",
        "It started 3 hours ago.",
        "It started about an hour ago.",
        "من ساعة تقريبا.",
        "SpO2 98, O2 fine.",
        "لمدة ل3 أيام",
        "الشدة 6 من 10",
        "covid-19",
        "كوفيد-19",
        "Patient denied: chest pain.",
        "You are not alone.",
    ],
)
def test_general_queue_rules_leave_these_alone(text):
    assert "queue_number" not in check_reply(text).reasons


@pytest.mark.parametrize(
    "text",
    [
        "Do you have a fever?",
        "عندك حرارة؟",
        "Did you take any medicine for it?",
        "How bad is it from 0 to 10?",
        "Did it turn red?",
        "Dr. Noor will see you.",
        "Go to room 4.",
    ],
)
def test_the_listed_strings_stay_clean(text):
    assert_clean(check_reply(text))


def test_allergies_stays_a_handoff_label():
    assert_clean(check_handoff("Allergies: penicillin.", allergies=["penicillin"]))
    assert ("allergy",) not in filters.DISEASE_TERMS
    assert ("allergies",) not in filters.DISEASE_TERMS


ARABIC_DISEASE_QUESTIONS = ["هذا برد؟", "يمكن انفلونزا؟"]


@pytest.mark.parametrize(
    "text",
    [
        "You have the flu?",
        "Is it the flu?",
        "Is this the flu?",
        "Could this be the flu?",
        "Could it be an infection?",
        "Do you think this is pneumonia?",
        "Do you think you have the flu?",
        "Have you considered that it might be the flu?",
        *ARABIC_DISEASE_QUESTIONS,
        *(with_diacritics(text) for text in ARABIC_DISEASE_QUESTIONS),
        "Is this the flu",
        "Do you think this is pneumonia",
        "Is this the flu, do you think?",
        "Do you think you have the flu, then?",
        "Thanks, is it the flu?",
        "Do you have a fever, is it the flu?",
        "Do you have a fever or could it be the flu?",
        "Any chance this is the flu?",
        "Any chance of the flu?",
        "Are you sure it's not the flu?",
        "The flu?",
    ],
)
def test_a_question_cannot_name_a_disease_unless_it_asks_for_history(text):
    assert "diagnosis" in check_reply(text).reasons


HISTORY_QUESTIONS = [
    "Do you have asthma?",
    "Did you have asthma as a child?",
    "Have you had the flu?",
    "Have you ever had pneumonia?",
    "Do you have a virus?",
    "Is your asthma worse?",
    "Are you diabetic?",
    "Any history of asthma",
    "Any history of asthma?",
    "And do you have asthma?",
    "Thanks, do you have asthma?",
    "عندك سكري؟",
    "هل عندك سكري؟",
    "هل لديك ربو؟",
    "هل عندك أي التهاب؟",
    "وعندك سكري؟",
    "وهل عندك ربو؟",
]


@pytest.mark.parametrize("text", HISTORY_QUESTIONS)
def test_a_history_question_may_name_a_disease(text):
    assert_clean(check_reply(text))


@pytest.mark.parametrize(
    "text", [question for question in HISTORY_QUESTIONS if "ء" <= question[0] <= "ي"]
)
def test_a_history_question_passes_with_diacritics(text):
    assert_clean(check_reply(with_diacritics(text)))


SCRIPTED_QUESTIONS = [
    *simulated.OPENING.values(),
    *(line for lines in simulated.QUESTIONS.values() for line in lines.values()),
    *(line for lines in simulated.FOLLOW_UPS.values() for line in lines.values()),
    *simulated._SUMMARY_CHECK.values(),
]
SCRIPTED_REPLIES = [
    *simulated._SUMMARY_PLAIN.values(),
    *simulated._SUMMARY_INTRO.values(),
    *simulated._EMERGENCY.values(),
    *simulated._SUPPORT.values(),
]


@pytest.mark.parametrize("text", SCRIPTED_QUESTIONS + SCRIPTED_REPLIES)
def test_every_scripted_line_passes(text):
    assert_clean(check_reply(text))


def test_the_scripted_list_is_not_empty():
    assert len(SCRIPTED_QUESTIONS) == 18
    assert len(SCRIPTED_REPLIES) == 8


@pytest.mark.parametrize(
    "text",
    [
        "Take paracetamol?",
        "خذ بنادول؟",
        "خُذْ بَنَادُول؟",
        "Try some Panadol?",
        "واشرب بنادول؟",
        "And take paracetamol?",
        "Please try some Panadol?",
        "Do you have a fever, drink some water?",
        "Rest for two days?",
        "وارتاح يومين؟",
    ],
)
def test_a_question_opening_on_an_order_is_still_an_order(text):
    assert "treatment_advice" in check_reply(text).reasons


@pytest.mark.parametrize(
    "text",
    [
        "Did you take paracetamol?",
        "Can you eat and drink?",
        "Did you take any medicine for it?",
        "Take a seat?",
        "Please take a seat?",
    ],
)
def test_only_the_opening_of_a_question_counts_as_an_order(text):
    assert "treatment_advice" not in check_reply(text).reasons


@pytest.mark.parametrize(
    "text",
    [
        "Rest for two days",
        "Please rest for two days.",
        "Avoid dairy",
        "Stay hydrated",
        "Gargle with salt water",
        "ارتاح يومين",
        "ارتاحي يومين",
        "تجنب الألبان",
        "تجنبي الألبان",
        "غرغر بماء وملح",
        "واشرب ماء وتجنب الألبان",
    ],
)
def test_the_new_imperatives_fail_with_any_object(text):
    assert "treatment_advice" in check_reply(text).reasons
    if any("ء" <= ch <= "ي" for ch in text):
        assert "treatment_advice" in check_reply(with_diacritics(text)).reasons


@pytest.mark.parametrize("text", ["Take a seat", "Take your time", "Take a seat.", "Take your time."])
def test_the_harmless_orders_stay_exempt(text):
    assert_clean(check_reply(text))


@pytest.mark.parametrize(
    "text",
    [
        "Looks viral",
        "Looks serious.",
        "It looks fine.",
        "في الغالب انفلونزا",
        "في الغالب تعب.",
        "على الأرجح تعب.",
        "الأرجح تعب.",
        "أعتقد تعب.",
        "احتمال عندك التهاب",
        "احتمال تعب.",
    ],
)
def test_the_new_guess_openers_fail(text):
    assert "diagnosis" in check_reply(text).reasons
    if any("ء" <= ch <= "ي" for ch in text):
        assert "diagnosis" in check_reply(with_diacritics(text)).reasons


@pytest.mark.parametrize(
    "text",
    ["Thanks, tell me more.", "Tell me more about the pain."],
)
def test_plain_statements_keep_passing(text):
    assert_clean(check_reply(text))


BARE_DIAGNOSES = [
    "Maybe flu.",
    "Seems viral.",
    "Definitely strep.",
    "Pneumonia.",
    "انفلونزا على الأرجح",
    "The flu season is here.",
    "34F, I have asthma.",
    "Thanks, flu.",
    "Flu, do you have a fever?",
]


@pytest.mark.parametrize("text", BARE_DIAGNOSES)
def test_a_statement_can_never_name_a_disease(text):
    assert "diagnosis" in check_reply(text).reasons


@pytest.mark.parametrize("text", ["Do you have asthma?", "عندك سكري؟"])
def test_a_history_question_still_names_a_disease(text):
    assert_clean(check_reply(text))


ECHOES = ["34F, I have asthma.", "The flu season is here.", "I need a flu vaccine"]


@pytest.mark.parametrize("text", ECHOES)
def test_a_read_back_may_echo_a_disease_with_no_trigger(text):
    assert_clean(check_reply(text, read_back=True))


@pytest.mark.parametrize("text", ["You have the flu.", "Likely flu.", "عندك انفلونزا"])
def test_a_read_back_keeps_the_trigger_rule(text):
    assert "diagnosis" in check_reply(text, read_back=True).reasons


@pytest.mark.parametrize(
    "text",
    [
        "Paracetamol is best.",
        "paracetamol twice daily.",
        "paracetamol would work.",
        "حبة بنادول مرتين",
        "Paracetamol, took ibuprofen.",
        "paracetamol took",
    ],
)
def test_a_read_back_drug_needs_a_took_word_before_it(text):
    check = check_reply(text, allowed_meds=["paracetamol", "ibuprofen"], read_back=True)
    assert "treatment_advice" in check.reasons


@pytest.mark.parametrize(
    "text",
    [
        "34F, cough, took paracetamol.",
        "took paracetamol and ibuprofen",
        "أخذت باراسيتامول",
        "had paracetamol",
        "I have tried panadol",
        "تناولت بنادول",
        "استخدمت بنادول",
    ],
)
def test_a_read_back_drug_after_a_took_word_passes(text):
    assert_clean(check_reply(text, allowed_meds=["paracetamol", "ibuprofen"], read_back=True))


def test_read_back_does_not_widen_what_is_allowed():
    check = check_reply("took ibuprofen", allowed_meds=["paracetamol"], read_back=True)
    assert "treatment_advice" in check.reasons


def test_the_default_mode_has_no_took_word_rule():
    assert_clean(check_reply("Paracetamol is best.", allowed_meds=["paracetamol"]))


def test_the_handoff_filter_stays_as_it_was():
    assert_clean(check_handoff("Paracetamol, 34F.", self_medication=["paracetamol"]))


INVENTED_WORDS = ["zorblax", "quelmora", "fentrix-9", "زوربلاكس", "كويلمورا"]
# Every shape a claim could take once a filter no longer knows the word.
CLAIM_SHAPES = [
    "You have {w}.",
    "{w} is best.",
    "{w}.",
    "{w}",
    "Probably {w}.",
    "Maybe {w}, since when?",
    "{w} twice daily.",
    "{w}?",
    "{w} is best?",
    "You have {w}?",
    "You have {w}, right?",
    "Take {w}?",
    "Is it {w}?",
    "Could it be {w}?",
    "When did your {w} start?",
    "How long have you had {w}?",
    "Do you want {w}?",
    "Have you tried {w}?",
    "Would {w} help?",
    "Thanks. You have {w}.",
    "You have {w}. Since when?",
    "{w} is best. Since when?",
    "Thanks, {w}. Since when?",
    "Sorry, you have {w}?",
    "Since when? {w} is best.",
    "Since when?\n{w}",
    "عندك {w}.",
    "عندك {w}؟",
    "{w} هو الأفضل.",
    "هل هو {w}؟",
    "من متى عندك {w}؟",
]


def test_the_invented_words_are_on_no_list():
    known = {word for phrase in filters.DISEASE_TERMS for word in phrase}
    known |= {word for phrases in filters._DRUG_PHRASES.values() for p in phrases for word in p}
    known |= filters._GATE_WORDS
    for word in INVENTED_WORDS:
        assert not known & set(phrase_tokens(word))


@pytest.mark.parametrize("word", INVENTED_WORDS)
@pytest.mark.parametrize("shape", CLAIM_SHAPES)
def test_the_gate_refuses_an_unlisted_word_in_any_shape(shape, word):
    assert not filters.gate_reply(shape.format(w=word))


@pytest.mark.parametrize(
    "text",
    [
        "Since when?",
        "How long?",
        "How long have you had it?",
        "How long have you had the cough?",
        "How bad is it from 0 to 10?",
        "Do you have a fever?",
        "Did you take any medicine for it?",
        "Any fever?",
        "Any medicine?",
        "Anything else?",
        "Anything else the nurse should know?",
        "Where is the pain?",
        "Is the pain worse at night?",
        "Is it getting worse?",
        "Thanks. How long have you had it?",
        "Thanks, how long have you had it?",
        "Sorry to hear that. Since when?",
        "Okay, and when did it start?",
        "من متى؟",
        "منذ متى؟",
        "عندك حرارة؟",
        "كم شدته؟",
        "كم شدته من 0 إلى 10؟",
        "أخذت أي دوا؟",
        "أخذت أي دوا له؟",
        "وين الألم بالضبط؟",
        "في ترجيع؟",
        "شو اللي يتعبك اليوم؟",
        "في شي ثاني تبي الممرضة تعرفه؟",
        "هل عندك حرارة؟",
        "شكرا. من متى؟",
        "تمام، كم شدته؟",
    ],
)
def test_the_gate_lets_a_short_question_through(text):
    assert filters.gate_reply(text)


@pytest.mark.parametrize(
    "text",
    [
        "",
        "?",
        "Thanks.",
        "Since when",
        "Since when? How bad?",
        "Thanks. Okay. Since when?",
        "Thanks. Okay, since when?",
        "Thanks thanks thanks thanks thanks thanks thanks. Since when?",
        "Your number is 14. Since when?",
        "This is not an emergency. Since when?",
        "I am a nurse, since when?",
        "Do you have " + "a fever and " * 6 + "a cough?",
        "Is it a chest problem?",
        "Is it allergies?",
        "Is this your stomach?",
        "Did you take 500 mg?",
    ],
)
def test_the_gate_refuses_any_other_shape(text):
    assert not filters.gate_reply(text)


def test_the_gate_keeps_a_drug_out_until_the_patient_or_record_names_it():
    question = "Did you take amoxicillin?"
    assert check_reply(question).ok
    assert not filters.gate_reply(question)
    assert filters.gate_reply(question, known=["I took amoxicillin"])
    assert filters.gate_reply("Are you still on amlodipine 5 mg once daily?",
                              known=["amlodipine 5 mg once daily"])


def test_the_gate_lets_the_patient_be_asked_in_their_own_words():
    assert not filters.gate_reply("When did the zorblax start?")
    assert filters.gate_reply("When did the zorblax start?", known=["I took zorblax"])


def test_known_words_never_excuse_the_shape():
    known = ["zorblax is best"]
    assert not filters.gate_reply("zorblax is best.", known=known)
    assert not filters.gate_reply("zorblax is best?", known=known)
    assert not filters.gate_reply("Is it zorblax?", known=known)


def test_the_gate_cannot_be_hidden_from_by_diacritics():
    assert not filters.gate_reply("عِنْدَكَ زوربلاكس.")
    assert filters.gate_reply("عِنْدَكَ حَرَارَة؟")


@pytest.mark.parametrize(
    "text",
    [
        "You will be next.",
        "You'll be next.",
        "You’ll be next.",
        "You should be next.",
        "Will you be next?",
    ],
)
def test_being_next_is_a_queue_claim(text):
    assert "queue_number" in check_reply(text).reasons


@pytest.mark.parametrize(
    ("text", "reason"),
    [
        ("Rest of history: none.", "treatment_advice"),
        ("Stay hydrated.", "treatment_advice"),
        ("Avoid dairy.", "treatment_advice"),
        ("Gargle with salt water.", "treatment_advice"),
        ("ارتاح يومين.", "treatment_advice"),
        ("Drink water?", "treatment_advice"),
        ("Will be next.", "queue_number"),
    ],
)
def test_check_handoff_keeps_its_old_word_sets(text, reason):
    assert reason not in check_handoff(text).reasons


def test_the_handoff_sets_are_the_reply_sets_less_the_additions():
    assert filters._IMPERATIVES - filters._HANDOFF_IMPERATIVES == frozenset(
        phrase_tokens("rest gargle avoid stay ارتاح ارتاحي تجنب تجنبي غرغر")
    )
    added = set(filters._QUEUE_TERMS) - set(filters._HANDOFF_QUEUE_TERMS)
    assert added == {
        ("you", "will", "be", "next"),
        ("you'll", "be", "next"),
        ("be", "next"),
    }


DISEASE_WORDS = [" ".join(term) for term in filters.DISEASE_TERMS]
# The vault's six questions and the follow-ups, which must survive every rule below.
MUST_PASS = [
    *simulated.OPENING.values(),
    *(line for lines in simulated.QUESTIONS.values() for line in lines.values()),
    *(line for lines in simulated.FOLLOW_UPS.values() for line in lines.values()),
    "Do you have a fever?",
    "عندك حرارة؟",
    "Did you take any medicine for it?",
    "Any vomiting?",
    "How many tablets do you take?",
    "Is it worse at night?",
    "Is it better now?",
    "Have you tried anything for it?",
    "Is your pain worse?",
    "How bad is it from 0 to 10?",
]


@pytest.mark.parametrize("text", MUST_PASS)
def test_the_questions_the_flow_needs_pass_the_gate(text):
    assert filters.gate_reply(text)
    assert filters.gate_reply(with_diacritics(text))


def test_no_disease_can_be_spelled_from_the_gate_vocabulary():
    assert not [term for term in filters.DISEASE_TERMS if set(term) <= filters._GATE_WORDS]


def test_only_ordinary_words_of_a_disease_term_stay_in_the_gate():
    shared = {word for term in filters.DISEASE_TERMS for word in term} & filters._GATE_WORDS
    assert shared == set(phrase_tokens("a bad chest food head stomach throat صداع"))


@pytest.mark.parametrize("term", DISEASE_WORDS)
@pytest.mark.parametrize(
    "shape",
    ["Do you have {x}?", "Have you had {x}?", "Any {x}?", "How long have you had {x}?",
     "Is your problem {x}?", "Is your pain from {x}?", "Are you sick with {x}?",
     "عندك {x}؟", "هل عندك {x}؟", "في {x}؟"],
)
def test_a_disease_needs_a_known_word_to_enter_a_question(shape, term):
    assert not filters.gate_reply(shape.format(x=term))
    assert not filters.gate_reply(with_diacritics(shape.format(x=term)))


@pytest.mark.parametrize(
    ("question", "known"),
    [
        ("Do you have asthma?", ["asthma"]),
        ("Do you have zorblax?", ["zorblax"]),
        ("Have you had asthma?", ["I have asthma"]),
        ("Is your asthma worse?", ["hypertension", "asthma"]),
        ("عندك سكري؟", ["عندي سكري"]),
    ],
)
def test_a_known_word_opens_the_question_and_the_filter_still_passes_it(question, known):
    assert filters.gate_reply(question, known=known)
    assert check_reply(question).ok


@pytest.mark.parametrize("question", ["Do you have asthma?", "عندك سكري؟", "Are you diabetic?"])
def test_the_gate_is_stricter_than_the_filter_on_a_history_question(question):
    assert not filters.gate_reply(question)
    assert_clean(check_reply(question))


@pytest.mark.parametrize("word", ["can", "could", "why", "should", "would", "will", "shall"])
def test_a_suggesting_word_opens_no_frame(word):
    assert (word,) not in filters._GATE_FRAMES
    assert not filters.gate_reply(f"{word.title()} you take a tablet?")


@pytest.mark.parametrize("word", ["can", "could", "why", "would", "will", "if"])
def test_a_suggesting_word_is_not_in_the_vocabulary_either(word):
    assert word not in filters._GATE_WORDS


REFUSED_FRAMES = [
    "Can you {c}?",
    "Could you {c}?",
    "Why {c}?",
    "Why not {c}?",
    "How about {c}?",
    "What about {c}?",
    "What if you {c}?",
    "What if {c}?",
    "Did you know {c}?",
    "Do you know {c}?",
    "Are you aware {c}?",
    "Is it better to {c}?",
    "Is it good to {c}?",
    "Is it ok to {c}?",
    "Is it okay to {c}?",
    "Thanks, why not {c}?",
    "And how about {c}?",
    "Sorry to hear that. What about {c}?",
]
CLAUSES = ["take a tablet", "stop your medicine", "drink more water", "a tablet every day"]


@pytest.mark.parametrize("clause", CLAUSES)
@pytest.mark.parametrize("frame", REFUSED_FRAMES)
def test_a_refused_frame_fails_with_any_clause(frame, clause):
    question = frame.format(c=clause)
    assert not filters.gate_reply(question)
    assert not filters.gate_reply(question, known=[question, "ibuprofen"])


def test_better_as_a_descriptor_is_not_better_as_advice():
    assert filters.gate_reply("Is it better now?")
    assert not filters.gate_reply("Is it better to rest now?")


@pytest.mark.parametrize(
    "text",
    [
        "Does it help to drink water?",
        "Did you try to take a tablet?",
        "Have you tried to stop your medicine?",
        "Have you tried drinking more water?",
        "Have you tried a tablet?",
        "Did you try water?",
        "Have you tried?",
        "How many tablets should you take?",
        "What should you drink?",
        "Anything else you should take?",
        "Do you like to take a tablet?",
        "جربت دوا؟",
    ],
)
def test_a_suggestion_in_allowed_words_fails(text):
    assert not filters.gate_reply(text)


ARABIC_OFFERS = [
    "تبي تاخذ حبة؟",
    "تبين تاخذين دوا؟",
    "تحب تجرب علاج؟",
    "تحبين تشربين دواء؟",
    "شو تبي تاخذ؟",
    "في شي تحب تجرب؟",
    "هل تبي تستخدم حبوب؟",
    "تبي حبوب؟",
    "تبي دوا؟",
    "تبي علاج؟",
    "وتبي حبة؟",
    "تبي الدوا؟",
    "ما تاخذ حبة؟",
    "ما تجرب دوا؟",
    "ما تشرب ماء؟",
    "ما تستخدم حبوب؟",
    "ما تاخذين دوا؟",
    "ما جربت حبوب؟",
    "وما تاخذ علاج؟",
]


@pytest.mark.parametrize("text", ARABIC_OFFERS)
def test_an_arabic_offer_of_treatment_fails(text):
    assert not filters.gate_reply(text)
    assert not filters.gate_reply(with_diacritics(text))
    assert not filters.gate_reply(text, known=[text])


def test_an_arabic_want_verb_with_no_taking_word_still_passes():
    assert filters.gate_reply("في شي ثاني تبي الممرضة تعرفه؟")


def test_an_arabic_offer_of_the_patients_own_word_fails():
    assert not filters.gate_reply("تبي بنادول؟", known=["أخذت بنادول"])


@pytest.mark.parametrize(
    "text",
    [
        "Is your problem shingles?",
        "Is your pain shingles?",
        "Is your pain from shingles?",
        "Is your pain from shingles worse?",
        "Is your pain worse from shingles?",
        "Is your pain worse with shingles?",
        "Is your problem a fever?",
        "Is your stomach the problem?",
        "Is the problem shingles?",
        "Is the cause shingles?",
        "Is the pain from shingles?",
        "Is it shingles?",
        "Is it still shingles?",
        "Is it getting shingles?",
        "Is it worse shingles?",
        "Is the pain in your shingles?",
        "Is it in your shingles?",
        "Is it in shingles?",
        "هل الألم من زوربلاكس؟",
        "هل الألم في زوربلاكس؟",
        "هل مشكلتك زوربلاكس؟",
        "هل هو زوربلاكس؟",
    ],
)
def test_a_patients_word_cannot_be_asserted_as_the_answer(text):
    known = ["I think it is shingles", "زوربلاكس"]
    assert not filters.gate_reply(text, known=known)


@pytest.mark.parametrize(
    "text",
    [
        "Is your pain worse?",
        "Is your pain still bad?",
        "Is your pain getting worse?",
        "Is your left arm sore?",
        "Is your sore throat worse at night?",
        "Is the pain worse in the morning?",
        "Is the pain sharp?",
        "Is it worse today than yesterday?",
        "Is it still there?",
        "Is it there all the time?",
        "Is the pain in your chest?",
        "Is your pain on your left side?",
        "Is it in your stomach?",
        "هل الألم في الصدر؟",
        "هل الألم شديد؟",
        "هل هو أسوأ في الليل؟",
        "هل الألم أسوأ بالليل؟",
    ],
)
def test_a_descriptor_may_be_asked_about(text):
    assert filters.gate_reply(text)


@pytest.mark.parametrize(
    "text",
    [
        "Do you think it is shingles?",
        "Do you believe it is shingles?",
        "Do you feel it is shingles?",
        "Does it feel like shingles?",
        "Does it mean shingles?",
        "Do you have pain from shingles?",
        "Are you sick with shingles?",
        "Has it been shingles?",
        "What is it shingles?",
        "Which is best for you ibuprofen?",
        "Do you have a fever and ibuprofen is best?",
        "Do you have a fever and shingles is it?",
        "Is it maybe shingles?",
        "Do you have probably shingles?",
        "Do you have shingles because of it?",
        "عندك زوربلاكس يمكن؟",
        "عندك ويمكن زوربلاكس؟",
    ],
)
def test_a_patients_opinion_gives_the_model_none(text):
    known = [
        "I think it's shingles, what does it mean? I believe ibuprofen is best, maybe, "
        "probably because of it",
        "ويمكن عندي زوربلاكس",
        "يمكن",
    ]
    assert not filters.gate_reply(text, known=known)


@pytest.mark.parametrize(
    "text",
    [
        "Has it been 10 minutes?",
        "How long, 10 minutes?",
        "Is it 10?",
        "Did you take 2?",
        "Do you take 2 tablets?",
        "Did you take 500 mg?",
        "How bad is it from 0 to 11?",
        "How bad is it from 1 to 10?",
        "How bad is it from 0 to 100?",
        "How bad is it from 3 to 10?",
        "How bad is it 0 to 10 tablets?",
        "How many tablets from 0 to 10?",
        "Do you take tablets from 0 to 10?",
        "Is it from 0 to 10?",
        "Any tablets 0 to 10?",
        "صار لك ١٠ دقايق؟",
        "كم حبة من 0 إلى 11؟",
        "Did you take two tablets?",
        "Do you take one tablet?",
        "صارلك يومين؟",
    ],
)
def test_no_number_gets_through_outside_the_scale(text):
    assert not filters.gate_reply(text)


@pytest.mark.parametrize(
    "text",
    [
        "How bad is it from 0 to 10?",
        "How bad is it 0 to 10?",
        "How severe is the pain from 0 to 10?",
        "How much does it hurt from 0 to 10?",
        "كم شدته من 0 إلى 10؟",
        "كم شدته من ٠ إلى ١٠؟",
        "Thanks, how bad is it from 0 to 10?",
    ],
)
def test_the_scale_phrase_passes(text):
    assert filters.gate_reply(text)


@pytest.mark.parametrize(
    ("text", "known"),
    [
        ("Has it been 10 minutes?", ["about 10 minutes ago"]),
        ("Are you still on amlodipine 5 mg once daily?", ["amlodipine 5 mg once daily"]),
        ("Did you take 2 tablets?", ["I took 2 tablets"]),
    ],
)
def test_a_number_may_be_the_patients_or_the_records_own_word(text, known):
    assert not filters.gate_reply(text)
    assert filters.gate_reply(text, known=known)


def test_a_known_number_does_not_stand_for_another():
    assert not filters.gate_reply("Has it been 11 minutes?", known=["10 minutes ago"])


@pytest.mark.parametrize(
    "text",
    [
        "Do you have a fever (it is shingles)?",
        "Do you have a fever / shingles?",
        "Do you have a fever/shingles?",
        "Do you have a fever: shingles?",
        "Do you have a fever; shingles?",
        'Do you have a "fever"?',
        "Do you have a 'fever'?",
        "Do you have a “fever”?",
        "Do you have a ‘fever’?",
        "Do you have a fever - shingles?",
        "Do you have a fever – shingles?",
        "Do you have a fever — shingles?",
        "Do you have a [fever]?",
        "Do you have a {fever}?",
        "Do you have a *fever*?",
        "Do you have a _fever_?",
        "Do you have a fever, shingles?",
        "Do you have a fever, any cough?",
        "How bad is it, 0 to 10?",
        "How bad, 0 to 10?",
        "How bad is it 0-10?",
        "Thanks, okay, since when?",
        "Thanks; since when?",
        "Thanks: since when?",
        "Thanks - since when?",
        "Got it (good). Since when?",
        '"Thanks." Since when?',
        '"Since when?"',
        "(Since when?)",
        "**Since when?**",
        "Since when?)",
        "من متى (زوربلاكس)؟",
        "عندك حرارة / زوربلاكس؟",
        "عندك حرارة: زوربلاكس؟",
        "عندك حرارة؛ زوربلاكس؟",
        "عندك حرارة، زوربلاكس؟",
    ],
)
def test_the_question_holds_no_punctuation_but_its_mark(text):
    known = ["shingles", "زوربلاكس"]
    assert not filters.gate_reply(text, known=known)


@pytest.mark.parametrize(
    "text",
    [
        "Thanks, since when?",
        "شكرا، من متى؟",
        "Okay, thanks. Since when?",
        "Thanks! Since when?",
        "Thanks. Since when?",
        "Does it hurt when you don't eat?",
        "Does it hurt when you don\u2019t eat?",
    ],
)
def test_an_acknowledgement_comma_and_a_word_apostrophe_are_all_it_allows(text):
    assert filters.gate_reply(text)


@pytest.mark.parametrize(
    "frame",
    ["Is there a fever?", "Is this worse?", "Did it start today?", "Was it bad?", "For how long?",
     "Were you sick?", "Had you eaten?", "How about now?", "Don't you have a fever?"],
)
def test_only_a_listed_frame_opens_a_question(frame):
    assert not filters.gate_reply(frame)


@pytest.mark.parametrize("text", ["من زوربلاكس؟", "منذ زوربلاكس؟"])
def test_arabic_from_alone_opens_no_question(text):
    assert not filters.gate_reply(text, known=["زوربلاكس"])
