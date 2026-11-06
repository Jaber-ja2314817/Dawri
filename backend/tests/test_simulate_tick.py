"""The periodic load: other centres move, Al Wakra's numbers never do."""

from __future__ import annotations

import ast
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from backend import db, main, simulate
from backend.main import app
from backend.simulate import PROTECTED_CENTRES, SIMULATED_TICKETS
from backend.tests.conftest import make_visit

AIRPORT_T = "C-AIRPORT-T1"
AIRPORT_D = "C-AIRPORT-D1"
WAKRA_T = "C-WAKRA-T1"
TICKS = 20


@pytest.fixture
def loaded(engine, seeded):
    simulate.seed_queue_state(engine, seeded, simulate_load=True)
    return engine


def _rows(conn, sql, *params):
    return [tuple(row) for row in conn.execute(sql, params).fetchall()]


def _wakra(conn):
    return (
        _rows(conn, "SELECT * FROM ticket WHERE centre_id = 'C-WAKRA' ORDER BY rowid"),
        _rows(conn, "SELECT * FROM number_sequence WHERE centre_id = 'C-WAKRA' ORDER BY prefix"),
    )


def _waiting(conn, counter_id):
    return conn.execute(
        "SELECT COUNT(*) FROM ticket WHERE counter_id = ? AND state = 'active' AND simulated = 1",
        (counter_id,),
    ).fetchone()[0]


def _triage_targets(conn):
    return {
        counter_id: target
        for counter_id, target in SIMULATED_TICKETS.items()
        if conn.execute("SELECT stage FROM counter WHERE id = ?", (counter_id,)).fetchone()[0]
        == "triage"
    }


def test_al_wakra_is_protected():
    assert "C-WAKRA" in PROTECTED_CENTRES


def test_twenty_ticks_leave_every_al_wakra_row_alone(loaded, seeded):
    before = _wakra(seeded)
    assert before[0]
    for _ in range(TICKS):
        simulate.tick(loaded)
    assert _wakra(seeded) == before


def test_fatima_still_lands_on_t014_after_ticks(loaded, seeded):
    for _ in range(TICKS):
        simulate.tick(loaded)
    ticket = loaded.activate(loaded.issue_ticket(make_visit(seeded, "P001"), WAKRA_T).id)
    assert ticket.number == "T-014"
    position = loaded.position(ticket.id)
    assert position.people_ahead == 3
    assert position.est_wait_min == 12


def test_a_real_al_wakra_patient_sees_no_change_from_ticks(loaded, seeded):
    ticket = loaded.issue_active(make_visit(seeded, "P001"), WAKRA_T)
    before = _wakra(seeded)
    for _ in range(TICKS):
        simulate.tick(loaded)
    assert _wakra(seeded) == before
    assert loaded.position(ticket.id).people_ahead == 3


def test_each_triage_counter_stays_within_one_of_its_target(loaded, seeded):
    targets = _triage_targets(seeded)
    assert AIRPORT_T in targets
    moved = {counter_id: set() for counter_id in targets}
    for _ in range(TICKS):
        simulate.tick(loaded)
        for counter_id, target in targets.items():
            waiting = _waiting(seeded, counter_id)
            assert abs(waiting - target) <= 1, counter_id
            moved[counter_id].add(waiting)
    for counter_id, target in targets.items():
        if not counter_id.startswith("C-WAKRA"):
            assert moved[counter_id] == {target - 1, target}, counter_id


def test_doctor_counters_are_left_alone(loaded, seeded):
    doctors = _rows(
        seeded,
        "SELECT ticket.* FROM ticket JOIN counter ON counter.id = ticket.counter_id "
        "WHERE counter.stage = 'doctor' ORDER BY ticket.rowid",
    )
    assert doctors
    for _ in range(TICKS):
        simulate.tick(loaded)
    assert doctors == _rows(
        seeded,
        "SELECT ticket.* FROM ticket JOIN counter ON counter.id = ticket.counter_id "
        "WHERE counter.stage = 'doctor' ORDER BY ticket.rowid",
    )


def test_airport_gp_wait_stays_between_32_and_36_minutes(loaded):
    waits = {loaded.centre_wait("C-AIRPORT", "gp")["wait_min"]}
    for _ in range(TICKS):
        simulate.tick(loaded)
        waits.add(loaded.centre_wait("C-AIRPORT", "gp")["wait_min"])
    assert waits == {32, 36}


def test_real_tickets_are_never_touched(loaded, seeded):
    active = loaded.issue_active(make_visit(seeded, "P001"), AIRPORT_T)
    at_doctor = loaded.issue_active(make_visit(seeded, "P002"), AIRPORT_D)
    called = loaded.issue_active(make_visit(seeded, "P003"), "C-AIRPORT-P1")
    loaded.call_next("C-AIRPORT-P1")
    ids = (active.id, at_doctor.id, called.id)
    query = "SELECT * FROM ticket WHERE id IN (?, ?, ?) ORDER BY id"
    before = _rows(seeded, query, *ids)
    for _ in range(TICKS):
        simulate.tick(loaded)
    assert _rows(seeded, query, *ids) == before


def test_a_real_patient_behind_simulated_tickets_sees_people_ahead_fall(loaded, seeded):
    ticket = loaded.issue_active(make_visit(seeded, "P001"), AIRPORT_T)
    assert loaded.position(ticket.id).people_ahead == 7
    seen = []
    for _ in range(TICKS):
        simulate.tick(loaded)
        seen.append(loaded.position(ticket.id).people_ahead)
    assert seen == sorted(seen, reverse=True)
    assert seen[0] == 6
    assert seen[-1] == 0


def test_a_new_simulated_ticket_joins_behind_the_real_patient(loaded, seeded):
    ticket = loaded.issue_active(make_visit(seeded, "P001"), AIRPORT_T)
    simulate.tick(loaded)  # Seven waiting, so one finishes.
    assert loaded.position(ticket.id).people_ahead == 6
    simulate.tick(loaded)  # Six waiting, so one joins, behind the patient.
    assert loaded.position(ticket.id).people_ahead == 6


def test_no_simulated_ticket_is_ever_called(loaded, seeded):
    for _ in range(TICKS):
        simulate.tick(loaded)
    found = seeded.execute(
        "SELECT COUNT(*) FROM ticket WHERE simulated = 1 AND called_at IS NOT NULL"
    ).fetchone()[0]
    assert found == 0


def test_tick_on_a_day_with_no_load_rebuilds_towards_the_target(engine, seeded):
    simulate.seed_queue_state(engine, seeded, simulate_load=False)
    simulate.tick(engine)
    assert _waiting(seeded, AIRPORT_T) == 1
    assert _waiting(seeded, WAKRA_T) == 0


def test_the_module_docstring_describes_the_tick():
    tree = ast.parse(Path(simulate.__file__).read_text(encoding="utf-8"))
    docstring = ast.get_docstring(tree)
    assert "no periodic tick" not in docstring
    assert "tick()" in docstring


# The background loop


@pytest.fixture
def app_env(db_path, monkeypatch):
    monkeypatch.setattr("backend.main.load_dotenv", lambda: None)
    monkeypatch.delenv("HF_TOKEN", raising=False)
    monkeypatch.setattr(main, "SIMULATE_INTERVAL_SEC", 0.01)


def _wait_until(condition, timeout=2.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.005)
    return condition()


def test_loop_runs_when_load_is_on_and_stops_on_shutdown(app_env, monkeypatch):
    monkeypatch.setenv("SIMULATE_LOAD", "1")
    calls = []
    monkeypatch.setattr(simulate, "tick", lambda engine: calls.append(engine))
    with TestClient(app):
        assert _wait_until(lambda: len(calls) >= 3)
        assert calls[0] is app.state.engine
    after_shutdown = len(calls)
    time.sleep(0.05)
    assert len(calls) == after_shutdown


def test_loop_does_not_run_without_load(app_env, monkeypatch):
    monkeypatch.delenv("SIMULATE_LOAD", raising=False)
    calls = []
    monkeypatch.setattr(simulate, "tick", lambda engine: calls.append(engine))
    with TestClient(app):
        time.sleep(0.1)
    assert calls == []


def test_loop_survives_a_failure(app_env, monkeypatch, caplog):
    monkeypatch.setenv("SIMULATE_LOAD", "1")
    calls = []

    def flaky(engine):
        calls.append(1)
        if len(calls) == 1:
            raise RuntimeError("tick failed")

    monkeypatch.setattr(simulate, "tick", flaky)
    with TestClient(app):
        assert _wait_until(lambda: len(calls) >= 3)
    assert "simulated load tick failed" in caplog.text


def test_the_real_loop_keeps_wakra_still_on_a_running_app(app_env, monkeypatch, db_path):
    monkeypatch.setenv("SIMULATE_LOAD", "1")
    conn = db.connect()

    def airport_tickets():
        return conn.execute(
            "SELECT COUNT(*) FROM ticket WHERE counter_id = ?", (AIRPORT_T,)
        ).fetchone()[0]

    with TestClient(app):
        before = _wakra(conn)
        start = airport_tickets()
        assert _wait_until(lambda: airport_tickets() > start + 2)
        assert _wakra(conn) == before
    conn.close()
