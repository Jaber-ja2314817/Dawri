from __future__ import annotations

import pytest

from backend import simulate
from backend.tests.conftest import make_visit

T1 = "C-WAKRA-T1"
D4 = "C-WAKRA-D4"
P1 = "C-WAKRA-P1"


def _walk_fatima(engine, conn):
    """Fatima's whole visit, returning the triage position and each number."""
    visit_id = make_visit(conn, "P001")
    reserved = engine.issue_ticket(visit_id, T1)
    assert reserved.number is None and reserved.seq is None
    triage = engine.activate(reserved.id)
    position = engine.position(triage.id)
    result = engine.call_next(T1)
    assert result.called.id == triage.id
    engine.complete(triage.id)
    doctor = engine.issue_active(visit_id, D4)
    engine.call_next(D4)
    engine.complete(doctor.id)
    pharmacy = engine.issue_active(visit_id, P1)
    return position, result, triage, doctor, pharmacy


def test_fatima_gets_t014_on_fresh_reset(engine, seeded):
    simulate.seed_queue_state(engine, seeded, simulate_load=True)
    position, result, triage, doctor, pharmacy = _walk_fatima(engine, seeded)
    assert triage.number == "T-014"
    assert position.people_ahead == 3
    assert position.est_wait_min == 12
    assert len(result.auto_completed) == 3
    assert doctor.number == "D-GP-023"
    assert pharmacy.number == "P-031"


def test_same_numbers_without_simulated_load(engine, seeded):
    simulate.seed_queue_state(engine, seeded, simulate_load=False)
    position, result, triage, doctor, pharmacy = _walk_fatima(engine, seeded)
    assert triage.number == "T-014"
    assert position.people_ahead == 0
    assert result.auto_completed == []
    assert doctor.number == "D-GP-023"
    assert pharmacy.number == "P-031"
    assert seeded.execute("SELECT COUNT(*) FROM ticket WHERE simulated = 1").fetchone()[0] == 0


def test_al_wakra_wait(engine, seeded):
    simulate.seed_queue_state(engine, seeded, simulate_load=True)
    assert engine.centre_wait("C-WAKRA", "gp")["wait_min"] == 12


def test_airport_wait(engine, seeded):
    simulate.seed_queue_state(engine, seeded, simulate_load=True)
    assert 33 <= engine.centre_wait("C-AIRPORT", "gp")["wait_min"] <= 37


@pytest.mark.parametrize("simulate_load", [True, False])
@pytest.mark.parametrize(
    "centre_id, prefix, expected",
    [
        ("C-WAKRA", "T", 14),
        ("C-WAKRA", "D-GP", 23),
        ("C-WAKRA", "P", 31),
        ("C-AIRPORT", "T", 21),
        ("C-AIRPORT", "D-GP", 15),
        ("C-AIRPORT", "P", 12),
        ("C-RAYYAN", "T", 9),
        ("C-RAYYAN", "D-GP", 6),
        ("C-RAYYAN", "P", 7),
        ("C-MESAIMEER", "T", 18),
        ("C-MESAIMEER", "D-GP", 11),
        ("C-MESAIMEER", "P", 9),
        ("C-WESTBAY", "T", 16),
        ("C-WESTBAY", "D-GP", 10),
        ("C-WESTBAY", "P", 8),
    ],
)
def test_next_real_number_for_every_centre(engine, seeded, simulate_load, centre_id, prefix, expected):
    simulate.seed_queue_state(engine, seeded, simulate_load)
    counter = seeded.execute(
        "SELECT id FROM counter WHERE centre_id = ? AND prefix = ? LIMIT 1", (centre_id, prefix)
    ).fetchone()
    ticket = engine.issue_active(make_visit(seeded, "P003"), counter["id"])
    assert ticket.seq == expected


def test_simulated_counts_per_counter(engine, seeded):
    simulate.seed_queue_state(engine, seeded, simulate_load=True)
    rows = seeded.execute(
        "SELECT counter_id, COUNT(*) AS n FROM ticket WHERE simulated = 1 GROUP BY counter_id"
    ).fetchall()
    assert {row["counter_id"]: row["n"] for row in rows} == simulate.SIMULATED_TICKETS


def test_sequences_use_the_doha_day_of_the_engine_clock(engine, seeded, clock):
    clock.advance(minutes=15 * 60)  # 21:00 UTC is already the next Doha day
    simulate.seed_queue_state(engine, seeded, simulate_load=False)
    days = {row["day"] for row in seeded.execute("SELECT day FROM number_sequence")}
    assert days == {"2026-11-07"}
