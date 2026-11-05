from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from backend import db, seeding

VAULT_NOTE = (
    Path(__file__).resolve().parents[2]
    / "Dawri-Vault"
    / "05 Architecture"
    / "Mock Health System.md"
)

CENTRES = {
    "C-WAKRA": (25.17302, 51.59575),
    "C-RAYYAN": (25.27992, 51.43243),
    "C-MESAIMEER": (25.23369, 51.48246),
    "C-AIRPORT": (25.25580, 51.55778),
    "C-WESTBAY": (25.33767, 51.50388),
    "H-HGH": (25.29349, 51.50222),
    "H-WAKRA": (25.16750, 51.58742),
}
PHCC_CENTRES = [c for c in CENTRES if c.startswith("C-")]


def _seed_file(name):
    return json.loads((seeding.SEED_DIR / name).read_text(encoding="utf-8"))


def _vault_patients():
    note = VAULT_NOTE.read_text(encoding="utf-8")
    return json.loads(re.search(r"```json\n(\[.*?\])\n```", note, re.DOTALL).group(1))


def _counts(conn):
    tables = [
        row["name"]
        for row in conn.execute(
            "SELECT name FROM sqlite_master "
            "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        )
    ]
    return {t: conn.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0] for t in tables}


def test_exact_centres_and_coordinates(seeded):
    rows = seeded.execute("SELECT id, lat, lng FROM centre").fetchall()
    assert {row["id"]: (row["lat"], row["lng"]) for row in rows} == CENTRES


def test_excluded_centres_are_absent(seeded):
    names = " ".join(
        f"{row['name_en']} {row['name_ar']}"
        for row in seeded.execute("SELECT name_en, name_ar FROM centre")
    )
    assert "Siddiq" not in names
    assert "Ghuwailina" not in names


def test_centre_operators_and_services(seeded):
    centres = {row["id"]: row for row in seeded.execute("SELECT * FROM centre")}
    for centre_id in PHCC_CENTRES:
        assert centres[centre_id]["operator"] == "PHCC"
        assert centres[centre_id]["has_emergency"] == 0
    for centre_id in ("H-HGH", "H-WAKRA"):
        assert centres[centre_id]["operator"] == "HMC"
        assert centres[centre_id]["has_emergency"] == 1
        assert db.loads_list(centres[centre_id]["services"]) == ["emergency"]
    assert db.loads_list(centres["C-WAKRA"]["services"]) == [
        "gp",
        "dental",
        "vaccination",
        "lab_only",
        "womens_health",
    ]
    assert db.loads_list(centres["C-AIRPORT"]["services"]) == [
        "gp",
        "vaccination",
        "lab_only",
    ]
    assert {row["priority_age_min"] for row in centres.values()} == {65}


def test_every_qid_is_synthetic(seeded):
    file_qids = [row["qid_demo"] for row in _seed_file("patients.json")]
    db_qids = [row[0] for row in seeded.execute("SELECT qid_demo FROM patient")]
    assert sorted(file_qids) == sorted(db_qids)
    assert len(file_qids) == 6
    for qid in file_qids:
        assert re.fullmatch(r"DEMO-\d{5}", qid)


def test_first_three_patients_equal_the_vault():
    vault_rows = _vault_patients()
    assert [row["id"] for row in vault_rows] == ["P001", "P002", "P003"]
    assert _seed_file("patients.json")[:3] == vault_rows


def test_patient_rows_stored_as_seeded(seeded):
    for expected in _seed_file("patients.json"):
        row = dict(
            seeded.execute(
                "SELECT * FROM patient WHERE id = ?", (expected["id"],)
            ).fetchone()
        )
        for column in ("allergies", "chronic", "active_meds"):
            row[column] = db.loads_list(row[column])
        assert row == expected


def test_p001_has_dependents(seeded):
    rows = seeded.execute(
        "SELECT dependent_id FROM dependent_link WHERE guardian_id = 'P001' "
        "ORDER BY dependent_id"
    ).fetchall()
    assert [row[0] for row in rows] == ["P004", "P005"]


@pytest.mark.parametrize("centre_id", PHCC_CENTRES)
def test_each_phcc_centre_has_all_stages(seeded, centre_id):
    rows = seeded.execute(
        "SELECT DISTINCT stage FROM counter WHERE centre_id = ?", (centre_id,)
    ).fetchall()
    assert sorted(row[0] for row in rows) == ["doctor", "pharmacy", "triage"]


def test_counter_service_times_by_stage(seeded):
    rows = seeded.execute(
        "SELECT stage, prefix, avg_service_sec FROM counter"
    ).fetchall()
    expected = {"T": 240, "D-GP": 480, "D-DEN": 600, "D-WH": 600, "P": 180}
    for row in rows:
        assert row["avg_service_sec"] == expected[row["prefix"]]


def test_counter_staff_match_centre_and_stage(seeded):
    rows = seeded.execute(
        """
        SELECT c.id, c.stage, s.role
        FROM counter c JOIN staff s ON s.id = c.staff_id AND s.centre_id = c.centre_id
        """
    ).fetchall()
    assert len(rows) == 18
    role_for_stage = {"triage": "nurse", "doctor": "doctor", "pharmacy": "pharmacist"}
    for row in rows:
        assert row["role"] == role_for_stage[row["stage"]], row["id"]


def test_al_wakra_has_two_gp_counters(seeded):
    rows = seeded.execute(
        "SELECT id FROM counter WHERE centre_id = 'C-WAKRA' AND prefix = 'D-GP' "
        "ORDER BY id"
    ).fetchall()
    assert [row[0] for row in rows] == ["C-WAKRA-D3", "C-WAKRA-D4"]


def test_hospitals_have_no_counters_or_staff(seeded):
    for table in ("counter", "staff"):
        count = seeded.execute(
            f"SELECT COUNT(*) FROM {table} WHERE centre_id LIKE 'H-%'"
        ).fetchone()[0]
        assert count == 0


def test_staff_rows(seeded):
    assert seeded.execute("SELECT COUNT(*) FROM staff").fetchone()[0] == 23
    for short in ("WAK", "RAY", "MES", "AIR", "WBY"):
        for suffix, role in (
            ("NURSE1", "nurse"),
            ("PHARM1", "pharmacist"),
            ("DESK1", "desk"),
        ):
            row = seeded.execute(
                "SELECT role, clinic FROM staff WHERE id = ?", (f"S-{short}-{suffix}",)
            ).fetchone()
            assert row["role"] == role
            assert row["clinic"] is None


def test_every_seed_row_was_inserted(seeded):
    # INSERT OR IGNORE silently drops a row that breaks a constraint.
    counts = _counts(seeded)
    assert counts["centre"] == len(_seed_file("centres.json")) == 7
    assert counts["patient"] == len(_seed_file("patients.json"))
    assert counts["dependent_link"] == len(_seed_file("dependents.json"))
    assert counts["counter"] == len(_seed_file("counters.json")) == 18
    assert counts["drug"] == len(_seed_file("drugs.json")) == 9
    assert counts["staff"] == len(_seed_file("doctors.json")) + len(_seed_file("staff.json"))


def test_amoxicillin_is_tagged_penicillin(seeded):
    row = seeded.execute(
        "SELECT allergy_tags FROM drug WHERE name_en = 'amoxicillin'"
    ).fetchone()
    assert db.loads_list(row[0]) == ["penicillin"]


def test_demo_default_drugs_have_no_penicillin_tag(seeded):
    rows = seeded.execute(
        "SELECT id, allergy_tags FROM drug WHERE demo_default = 1"
    ).fetchall()
    assert sorted(row["id"] for row in rows) == ["DR-DEXT", "DR-PARA"]
    for row in rows:
        assert "penicillin" not in db.loads_list(row["allergy_tags"])


def test_every_drug_has_a_default_regimen(seeded):
    rows = seeded.execute("SELECT * FROM drug").fetchall()
    for row in rows:
        assert row["name_ar"] and row["form"]
        assert row["default_dose"] and row["default_frequency"] and row["default_days"]


def test_seed_static_twice_leaves_counts_unchanged(seeded):
    before = _counts(seeded)
    seeding.seed_static(seeded)
    assert _counts(seeded) == before


def test_is_seeded(conn):
    assert not seeding.is_seeded(conn)
    seeding.seed_static(conn)
    assert seeding.is_seeded(conn)


def test_seed_does_not_touch_queue_state(seeded):
    counts = _counts(seeded)
    assert counts["ticket"] == 0
    assert counts["number_sequence"] == 0
