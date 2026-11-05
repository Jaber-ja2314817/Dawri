from __future__ import annotations

from backend.tests.conftest import make_visit

T1 = "C-WAKRA-T1"
D3 = "C-WAKRA-D3"
D4 = "C-WAKRA-D4"


def _serve_one(engine, conn, clock, seconds):
    ticket = engine.issue_active(make_visit(conn, "P003"), T1)
    engine.call_next(T1)
    clock.advance(seconds=seconds)
    engine.complete(ticket.id)


def test_formula_with_seed_values(engine, seeded):
    for patient_id in ("P001", "P003", "P006"):
        engine.issue_active(make_visit(seeded, patient_id), T1)
    last = engine.issue_active(make_visit(seeded, "P004"), T1)
    position = engine.position(last.id)
    assert position.people_ahead == 3
    assert position.est_wait_min == 12


def test_called_ticket_counts_as_ahead(engine, seeded):
    engine.issue_active(make_visit(seeded, "P001"), T1)
    last = engine.issue_active(make_visit(seeded, "P003"), T1)
    engine.call_next(T1)
    assert engine.position(last.id).people_ahead == 1
    assert engine.position(last.id).est_wait_min == 4


def test_called_and_serving_report_zero(engine, seeded):
    ticket = engine.issue_active(make_visit(seeded, "P001"), T1)
    engine.call_next(T1)
    assert engine.position(ticket.id).people_ahead == 0
    assert engine.position(ticket.id).est_wait_min == 0
    engine.serve(ticket.id)
    assert engine.position(ticket.id).people_ahead == 0


def test_estimate_rounds_up(engine, seeded):
    seeded.execute("UPDATE counter SET avg_service_sec = 250 WHERE id = ?", (T1,))
    engine.issue_active(make_visit(seeded, "P001"), T1)
    last = engine.issue_active(make_visit(seeded, "P003"), T1)
    assert engine.position(last.id).est_wait_min == 5  # 250 / 60 is 4.17


def test_rolling_mean_needs_five_samples(engine, seeded, clock):
    assert engine.avg_service_sec(T1) == 240
    for count in range(1, 5):
        _serve_one(engine, seeded, clock, 100)
        assert engine.avg_service_sec(T1) == 240, count
    _serve_one(engine, seeded, clock, 100)
    assert engine.avg_service_sec(T1) == 100


def test_rolling_mean_is_the_mean(engine, seeded, clock):
    for seconds in (60, 120, 180, 240, 300):
        _serve_one(engine, seeded, clock, seconds)
    assert engine.avg_service_sec(T1) == 180


def test_rolling_mean_uses_the_last_twenty(engine, seeded, clock):
    for _ in range(5):
        _serve_one(engine, seeded, clock, 1000)
    for _ in range(20):
        _serve_one(engine, seeded, clock, 100)
    assert engine.avg_service_sec(T1) == 100


def test_rolling_mean_drives_the_estimate(engine, seeded, clock):
    for _ in range(5):
        _serve_one(engine, seeded, clock, 120)
    engine.issue_active(make_visit(seeded, "P001"), T1)
    assert engine.counter_wait(T1) == {"people_ahead": 1, "wait_min": 2}


def test_counter_wait_on_an_empty_counter(engine):
    assert engine.counter_wait(T1) == {"people_ahead": 0, "wait_min": 0}


def test_centre_wait_uses_the_shortest_gp_counter(engine, seeded):
    engine.issue_active(make_visit(seeded, "P001"), T1)
    engine.issue_active(make_visit(seeded, "P003"), D3)
    engine.issue_active(make_visit(seeded, "P006"), D3)
    assert engine.centre_wait("C-WAKRA", "gp") == {"people_ahead": 1, "wait_min": 4}
    engine.issue_active(make_visit(seeded, "P004"), D4)
    assert engine.centre_wait("C-WAKRA", "gp") == {"people_ahead": 1, "wait_min": 12}


def test_centre_wait_only_looks_at_the_chosen_service(engine, seeded):
    engine.issue_active(make_visit(seeded, "P003"), "C-WAKRA-DEN1")
    assert engine.centre_wait("C-WAKRA", "dental")["wait_min"] == 10
    assert engine.centre_wait("C-WAKRA", "gp")["wait_min"] == 0


def test_centre_wait_without_a_matching_doctor(engine, seeded):
    engine.issue_active(make_visit(seeded, "P001"), T1)
    assert engine.centre_wait("C-WAKRA", "vaccination") == {"people_ahead": 1, "wait_min": 4}


def test_centre_wait_for_a_hospital_is_zero(engine):
    assert engine.centre_wait("H-HGH", "gp") == {"people_ahead": 0, "wait_min": 0}


def test_triage_counter(engine):
    assert engine.triage_counter("C-WAKRA") == T1
    assert engine.triage_counter("C-RAYYAN") == "C-RAYYAN-T1"
