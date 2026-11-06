from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

import backend.ai.medicines as medicines_module
from backend.ai.medicines import for_visit, plain_line
from backend.seeding import SEED_DIR
from backend.tests.conftest import make_visit

DRUGS = {
    row["id"]: row
    for row in json.loads((SEED_DIR / "drugs.json").read_text(encoding="utf-8"))
}
PARACETAMOL = DRUGS["DR-PARA"]
AMOXICILLIN = DRUGS["DR-AMOX"]
SYRUP = DRUGS["DR-DEXT"]
ALL_SEED = sorted(DRUGS)
DIGITS = re.compile(r"\d+")


def default_item(drug: dict) -> dict:
    return {
        "drug": drug["id"],
        "dose": drug["default_dose"],
        "frequency": drug["default_frequency"],
        "days": drug["default_days"],
        "notes": None,
    }


def add_item(conn, visit_id, drug, dose=None, frequency=None, days=None, notes=None):
    conn.execute(
        "INSERT INTO prescription_item (visit_id, drug, dose, frequency, days, notes) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (visit_id, drug, dose, frequency, days, notes),
    )


def test_paracetamol_lines_match_the_agreed_wording():
    item = default_item(PARACETAMOL)
    assert (
        plain_line(item, "en", PARACETAMOL)
        == "Paracetamol (tablet): take 500 mg, every 6 hours when needed, for 3 days."
    )
    assert (
        plain_line(item, "ar", PARACETAMOL)
        == "باراسيتامول (أقراص): الجرعة 500 ملغ، كل 6 ساعات عند الحاجة، لمدة 3 أيام."
    )


def test_amoxicillin_five_days_in_both_languages():
    item = default_item(AMOXICILLIN)
    assert (
        plain_line(item, "en", AMOXICILLIN)
        == "Amoxicillin (capsule): take 500 mg, three times a day, for 5 days."
    )
    assert (
        plain_line(item, "ar", AMOXICILLIN)
        == "أموكسيسيلين (كبسولات): الجرعة 500 ملغ، ثلاث مرات يومياً، لمدة 5 أيام."
    )


@pytest.mark.parametrize("drug_id", ALL_SEED)
def test_every_seed_drug_reads_cleanly_in_english(drug_id):
    drug = DRUGS[drug_id]
    line = plain_line(default_item(drug), "en", drug)
    assert line.lower().startswith(drug["name_en"].lower())
    assert line.endswith(".")
    assert drug["default_dose"] in line
    assert "daily" not in line and "as needed" not in line


@pytest.mark.parametrize("drug_id", ALL_SEED)
def test_every_seed_drug_is_fully_arabic(drug_id):
    drug = DRUGS[drug_id]
    line = plain_line(default_item(drug), "ar", drug)
    assert line.startswith(drug["name_ar"])
    assert re.search(r"[A-Za-z]", line) is None


@pytest.mark.parametrize("lang", ["en", "ar"])
@pytest.mark.parametrize("drug_id", ALL_SEED)
def test_every_number_comes_from_the_prescription(drug_id, lang):
    drug = DRUGS[drug_id]
    item = default_item(drug)
    source = " ".join(str(item[key]) for key in ("dose", "frequency", "days", "notes"))
    allowed = set(DIGITS.findall(source))
    assert set(DIGITS.findall(plain_line(item, lang, drug))) <= allowed


def test_a_number_is_never_filled_in_from_the_drug_defaults():
    item = {"drug": "DR-PARA", "dose": "250 mg", "frequency": "once daily", "days": 4}
    line = plain_line(item, "en", PARACETAMOL)
    assert "250 mg" in line and "for 4 days" in line
    assert "500" not in line and "6" not in line


@pytest.mark.parametrize("field", ["dose", "days"])
@pytest.mark.parametrize("lang", ["en", "ar"])
def test_missing_dose_or_days_is_omitted_not_invented(field, lang):
    item = {**default_item(PARACETAMOL), field: None}
    line = plain_line(item, lang, PARACETAMOL)
    assert "None" not in line
    assert "500" not in line if field == "dose" else "3" not in line


def test_an_item_with_nothing_but_a_name_stays_a_clean_line():
    assert plain_line({"drug": "DR-PARA"}, "en", PARACETAMOL) == "Paracetamol (tablet)."


def test_form_is_not_repeated_when_the_name_says_it():
    line = plain_line(default_item(SYRUP), "en", SYRUP)
    assert line == "Dextromethorphan syrup: take 10 ml, every 8 hours when needed, for 3 days."
    assert "syrup (syrup)" not in line


def test_arabic_syrup_keeps_its_form_because_the_name_lacks_it():
    line = plain_line(default_item(SYRUP), "ar", SYRUP)
    assert line == "ديكستروميثورفان (شراب): الجرعة 10 مل، كل 8 ساعات عند الحاجة، لمدة 3 أيام."
    assert line.count("شراب") == 1


@pytest.mark.parametrize(
    "days, english, arabic",
    [
        (1, "for 1 day.", "لمدة يوم واحد."),
        (2, "for 2 days.", "لمدة يومين."),
        (3, "for 3 days.", "لمدة 3 أيام."),
        (10, "for 10 days.", "لمدة 10 أيام."),
        (11, "for 11 days.", "لمدة 11 يوماً."),
        (30, "for 30 days.", "لمدة 30 يوماً."),
    ],
)
def test_day_forms(days, english, arabic):
    item = {**default_item(PARACETAMOL), "days": days}
    assert plain_line(item, "en", PARACETAMOL).endswith(english)
    assert plain_line(item, "ar", PARACETAMOL).endswith(arabic)


@pytest.mark.parametrize(
    "frequency, english, arabic",
    [
        ("once daily", "once a day", "مرة واحدة يومياً"),
        ("twice daily", "twice a day", "مرتين يومياً"),
        ("three times daily", "three times a day", "ثلاث مرات يومياً"),
        ("every 6 hours as needed", "every 6 hours when needed", "كل 6 ساعات عند الحاجة"),
        ("every 8 hours as needed", "every 8 hours when needed", "كل 8 ساعات عند الحاجة"),
    ],
)
def test_frequency_map_covers_the_seed(frequency, english, arabic):
    item = {**default_item(PARACETAMOL), "frequency": frequency}
    assert english in plain_line(item, "en", PARACETAMOL)
    assert arabic in plain_line(item, "ar", PARACETAMOL)


@pytest.mark.parametrize("lang", ["en", "ar"])
def test_unknown_frequency_is_copied_verbatim(lang):
    item = {**default_item(PARACETAMOL), "frequency": "2 puffs at bedtime Q12H"}
    assert "2 puffs at bedtime Q12H" in plain_line(item, lang, PARACETAMOL)


@pytest.mark.parametrize(
    "dose, shown",
    [("500 mg", "500 ملغ"), ("10 ml", "10 مل"), ("500mg", "500 ملغ"), ("2.5 ML", "2.5 مل")],
)
def test_arabic_dose_units(dose, shown):
    item = {**default_item(PARACETAMOL), "dose": dose}
    assert f"الجرعة {shown}،" in plain_line(item, "ar", PARACETAMOL)


def test_an_unknown_dose_unit_is_left_as_written():
    item = {**default_item(PARACETAMOL), "dose": "1 tablet"}
    assert "الجرعة 1 tablet،" in plain_line(item, "ar", PARACETAMOL)


@pytest.mark.parametrize("lang", ["en", "ar"])
def test_notes_are_appended_verbatim(lang):
    item = {**default_item(PARACETAMOL), "notes": "after food, avoid 2 hours before sleep"}
    assert plain_line(item, lang, PARACETAMOL).endswith(
        ". after food, avoid 2 hours before sleep"
    )


def test_for_visit_finds_the_drug_by_id_or_any_case_name(seeded):
    visit_id = make_visit(seeded, "P001")
    add_item(seeded, visit_id, "DR-PARA", "500 mg", "every 6 hours as needed", 3)
    add_item(seeded, visit_id, "AMOXICILLIN", "500 mg", "three times daily", 5)
    lines = for_visit(seeded, visit_id, "ar")
    assert lines == [
        {
            "drug": "DR-PARA",
            "name": "باراسيتامول",
            "line": "باراسيتامول (أقراص): الجرعة 500 ملغ، كل 6 ساعات عند الحاجة، لمدة 3 أيام.",
        },
        {
            "drug": "AMOXICILLIN",
            "name": "أموكسيسيلين",
            "line": "أموكسيسيلين (كبسولات): الجرعة 500 ملغ، ثلاث مرات يومياً، لمدة 5 أيام.",
        },
    ]
    assert for_visit(seeded, visit_id, "en")[1]["name"] == "Amoxicillin"


@pytest.mark.parametrize("lang", ["en", "ar"])
def test_unknown_drug_shows_the_raw_field(seeded, lang):
    visit_id = make_visit(seeded, "P001")
    add_item(seeded, visit_id, "Vitamin Z", "5 mg", "once daily", 7)
    [entry] = for_visit(seeded, visit_id, lang)
    assert entry["drug"] == "Vitamin Z"
    assert entry["name"] == "Vitamin Z"
    assert entry["line"].startswith("Vitamin Z:")


def test_for_visit_keeps_id_order_and_ignores_other_visits(seeded):
    visit_id = make_visit(seeded, "P001")
    other = make_visit(seeded, "P002")
    add_item(seeded, visit_id, "DR-IBU")
    add_item(seeded, other, "DR-METF")
    add_item(seeded, visit_id, "DR-CETI")
    assert [e["drug"] for e in for_visit(seeded, visit_id, "en")] == ["DR-IBU", "DR-CETI"]


def test_for_visit_with_no_prescription_is_empty(seeded):
    assert for_visit(seeded, make_visit(seeded, "P001"), "en") == []


def test_deterministic_no_model_import():
    source = Path(medicines_module.__file__).read_text(encoding="utf-8")
    assert "llm" not in source.lower()
