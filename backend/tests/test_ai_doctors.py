from __future__ import annotations

from dataclasses import FrozenInstanceError
from pathlib import Path

import pytest

import backend.ai.doctors as doctors_module
from backend import bootstrap, db
from backend.ai.doctors import suggest


@pytest.fixture
def demo(conn):
    bootstrap.reset_demo(simulate_load=True)
    return conn


def add_ticket(conn, counter_id, centre_id, state="active"):
    conn.execute(
        "INSERT INTO ticket (id, centre_id, counter_id, state, simulated) VALUES (?, ?, ?, ?, 1)",
        (db.new_id("T"), centre_id, counter_id, state),
    )


def add_doctor(
    conn,
    doctor_id,
    *,
    centre="H-HGH",
    clinic="gp",
    languages=("ar", "en"),
    gender="F",
    waiting=0,
):
    """H-HGH starts with no doctors, so each row here stands alone."""
    counter_id = f"CTR-{doctor_id}"
    conn.execute(
        "INSERT INTO staff (id, centre_id, name, role, clinic, languages, gender) "
        "VALUES (?, ?, ?, 'doctor', ?, ?, ?)",
        (doctor_id, centre, f"Dr. {doctor_id}", clinic, db.dumps(list(languages)), gender),
    )
    conn.execute(
        "INSERT INTO counter (id, centre_id, stage, label, label_ar, staff_id, prefix) "
        "VALUES (?, ?, 'doctor', 'Room X', 'غرفة X', ?, 'D-GP')",
        (counter_id, centre, doctor_id),
    )
    for _ in range(waiting):
        add_ticket(conn, counter_id, centre)


def test_fatima_at_wakra_gets_the_empty_room_first(demo):
    first, second = suggest(demo, "C-WAKRA", "gp", "ar")
    assert (first.doctor_id, first.counter_id, first.counter_label) == (
        "S-WAK-DOC2",
        "C-WAKRA-D4",
        "Room 4",
    )
    assert (first.waiting, first.score) == (0, 0.0)
    assert (second.doctor_id, second.waiting, second.score) == ("S-WAK-DOC1", 1, 1.0)
    assert first.clinic == "gp"
    assert first.speaks_language and first.gender_ok and not first.clinic_fallback


@pytest.mark.parametrize(
    "languages, gender, pref, waiting, score",
    [
        (("ar", "en"), "F", None, 0, 0.0),
        (("ar", "en"), "F", None, 3, 3.0),
        (("en",), "F", None, 0, 2.0),
        (("ar", "en"), "M", None, 0, 0.0),
        (("ar", "en"), "M", "M", 0, 0.0),
        (("ar", "en"), "M", "F", 0, 5.0),
        (("en",), "M", "F", 4, 11.0),
    ],
)
def test_score_is_the_vault_formula(seeded, languages, gender, pref, waiting, score):
    add_doctor(seeded, "D1", languages=languages, gender=gender, waiting=waiting)
    [only] = suggest(seeded, "H-HGH", "gp", "ar", pref)
    assert only.score == score
    assert only.speaks_language == ("ar" in languages)
    assert only.gender_ok == (pref is None or pref == gender)


def test_equal_scores_prefer_the_shorter_queue(seeded):
    add_doctor(seeded, "D-A-LONGER", waiting=2)
    add_doctor(seeded, "D-Z-SHORTER", languages=("en",), waiting=0)
    ranked = suggest(seeded, "H-HGH", "gp", "ar")
    assert [s.doctor_id for s in ranked] == ["D-Z-SHORTER", "D-A-LONGER"]
    assert [s.score for s in ranked] == [2.0, 2.0]


def test_gender_preference_outweighs_a_short_queue(seeded):
    add_doctor(seeded, "D-M", gender="M")
    add_doctor(seeded, "D-F", gender="F", waiting=3)
    assert [s.doctor_id for s in suggest(seeded, "H-HGH", "gp", "ar", "F")] == ["D-F", "D-M"]


def test_equal_scores_and_queues_fall_back_to_doctor_id(seeded):
    for doctor_id in ("D-B", "D-C", "D-A"):
        add_doctor(seeded, doctor_id)
    assert [s.doctor_id for s in suggest(seeded, "H-HGH", "gp", "ar")] == ["D-A", "D-B", "D-C"]


@pytest.mark.parametrize(
    "state, counted",
    [
        ("active", True),
        ("called", True),
        ("serving", True),
        ("done", False),
        ("released", False),
    ],
)
def test_only_live_tickets_count(seeded, state, counted):
    add_doctor(seeded, "D1")
    add_ticket(seeded, "CTR-D1", "H-HGH", state)
    assert suggest(seeded, "H-HGH", "gp", "ar")[0].waiting == (1 if counted else 0)


def test_simulated_tickets_count(demo):
    simulated = demo.execute(
        "SELECT COUNT(*) FROM ticket WHERE counter_id = 'C-WAKRA-D3' AND simulated = 1"
    ).fetchone()[0]
    assert simulated == 1
    assert suggest(demo, "C-WAKRA", "gp", "ar")[1].waiting == 1


def test_limit_defaults_to_three(seeded):
    for index in range(5):
        add_doctor(seeded, f"D{index}")
    assert len(suggest(seeded, "H-HGH", "gp", "ar")) == 3
    assert len(suggest(seeded, "H-HGH", "gp", "ar", limit=1)) == 1


def test_a_doctor_with_two_counters_appears_once_at_the_shorter_queue(seeded):
    add_doctor(seeded, "D1", waiting=2)
    seeded.execute(
        "INSERT INTO counter (id, centre_id, stage, label, staff_id, prefix) "
        "VALUES ('CTR-D1-B', 'H-HGH', 'doctor', 'Room Y', 'D1', 'D-GP')"
    )
    [only] = suggest(seeded, "H-HGH", "gp", "ar")
    assert (only.counter_id, only.waiting) == ("CTR-D1-B", 0)


def test_a_doctor_without_a_doctor_counter_is_not_on_shift(seeded):
    seeded.execute(
        "INSERT INTO staff (id, centre_id, name, role, clinic, languages, gender) "
        "VALUES ('D-OFF', 'H-HGH', 'Dr. Off', 'doctor', 'gp', '[\"ar\"]', 'F')"
    )
    seeded.execute(
        "INSERT INTO counter (id, centre_id, stage, label, staff_id, prefix) "
        "VALUES ('CTR-OFF', 'H-HGH', 'triage', 'Triage', 'D-OFF', 'T')"
    )
    assert suggest(seeded, "H-HGH", "gp", "ar") == []


def test_dental_gets_the_dentist_and_womens_health_its_doctor(demo):
    assert [s.doctor_id for s in suggest(demo, "C-WAKRA", "dental", "ar")] == ["S-WAK-DEN1"]
    assert [s.doctor_id for s in suggest(demo, "C-WAKRA", "womens_health", "ar")] == ["S-WAK-WH1"]


@pytest.mark.parametrize(
    "service, phrase",
    [
        ("vaccination", "No vaccination clinic here"),
        ("lab_only", "No lab clinic here"),
        ("mental_health", "No mental health clinic here"),
        ("refill", "No refill clinic here"),
        ("other", "No matching clinic here"),
    ],
)
def test_no_such_clinic_suggests_a_gp(demo, service, phrase):
    ranked = suggest(demo, "C-WAKRA", service, "ar")
    assert [s.doctor_id for s in ranked] == ["S-WAK-DOC2", "S-WAK-DOC1"]
    assert all(s.clinic == "gp" and s.clinic_fallback for s in ranked)
    assert phrase in ranked[0].reason_en
    assert "a GP is suggested" in ranked[0].reason_en
    assert "نقترح طبيباً عاماً" in ranked[0].reason_ar


def test_dental_at_a_centre_without_a_dentist_falls_back_to_gp(demo):
    [only] = suggest(demo, "C-RAYYAN", "dental", "ar")
    assert (only.doctor_id, only.clinic_fallback) == ("S-RAY-DOC1", True)


@pytest.mark.parametrize("centre", ["H-HGH", "H-WAKRA"])
@pytest.mark.parametrize(
    "service",
    [
        "gp",
        "dental",
        "refill",
        "vaccination",
        "lab_only",
        "womens_health",
        "mental_health",
        "other",
    ],
)
def test_hospitals_have_no_doctors_to_suggest(demo, centre, service):
    assert suggest(demo, centre, service, "ar") == []


def test_reason_matches_staff_console(seeded):
    seeded.execute("UPDATE staff SET name = 'Dr. Noor Al-Demo' WHERE id = 'S-WAK-DOC2'")
    for _ in range(2):
        add_ticket(seeded, "C-WAKRA-D4", "C-WAKRA")
    noor = next(s for s in suggest(seeded, "C-WAKRA", "gp", "ar") if s.doctor_id == "S-WAK-DOC2")
    assert noor.reason_en == "Dr. Noor Al-Demo — GP, 2 waiting, speaks Arabic"
    assert noor.reason_ar == "Dr. Noor Al-Demo — طب عام، 2 في الانتظار، تتحدث العربية"


def test_reason_names_a_missing_language(seeded):
    add_doctor(seeded, "D1", languages=("en",), gender="M", waiting=1)
    [only] = suggest(seeded, "H-HGH", "gp", "ar")
    assert only.reason_en == "Dr. D1 — GP, 1 waiting, does not speak Arabic"
    assert "لا يتحدث العربية" in only.reason_ar


def test_reason_uses_the_patients_language(demo):
    first = suggest(demo, "C-AIRPORT", "gp", "en")[0]
    assert first.reason_en.endswith("speaks English")
    assert first.reason_ar.endswith("يتحدث الإنجليزية")


def test_reason_says_when_the_gender_preference_is_not_met(seeded):
    add_doctor(seeded, "D1", gender="M")
    [only] = suggest(seeded, "H-HGH", "gp", "ar", "F")
    assert "does not match the gender preference" in only.reason_en
    assert "لا يطابق تفضيل الجنس" in only.reason_ar


def test_suggestion_is_frozen(demo):
    first = suggest(demo, "C-WAKRA", "gp", "ar")[0]
    with pytest.raises(FrozenInstanceError):
        first.score = 99.0  # type: ignore[misc]


def test_rules_only_no_model_import():
    source = Path(doctors_module.__file__).read_text(encoding="utf-8")
    assert "llm" not in source.lower()
