from __future__ import annotations

import time

import pytest
from fastapi import Depends
from fastapi.testclient import TestClient

from backend import auth, bootstrap, db, deps, main, simulate
from backend.adapters.queue_base import (
    CounterBusy,
    InvalidTransition,
    TicketExpired,
    TicketNotFound,
    VisitHasLiveTicket,
    VisitNotEligible,
)
from backend.main import app
from backend.queue_engine import SqliteQueueEngine
from backend.tests.conftest import make_visit

T1 = "C-WAKRA-T1"
SIMULATED_TOTAL = sum(simulate.SIMULATED_TICKETS.values())


@pytest.fixture(autouse=True)
def isolated_env(db_path, monkeypatch):
    # A developer's .env must not leak a token or load setting into these tests.
    monkeypatch.setattr("backend.main.load_dotenv", lambda: None)
    monkeypatch.delenv("HF_TOKEN", raising=False)
    monkeypatch.delenv("SIMULATE_LOAD", raising=False)


@pytest.fixture
def open_conn():
    conn = db.connect()
    yield conn
    conn.close()


@pytest.fixture
def add_route():
    saved = list(app.router.routes)
    yield app.add_api_route
    app.router.routes[:] = saved


def count(conn, table):
    return conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]


def wait_until(condition, timeout=2.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.005)
    return condition()


def test_health_simulated_without_a_token():
    with TestClient(app) as client:
        response = client.get("/api/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "ai_mode": "simulated", "simulate_load": False}


def test_health_real_with_a_token(monkeypatch):
    monkeypatch.setenv("HF_TOKEN", "dummy-not-a-real-token")
    with TestClient(app) as client:
        assert client.get("/api/health").json()["ai_mode"] == "real"


def test_health_reports_simulated_load(monkeypatch):
    monkeypatch.setenv("SIMULATE_LOAD", "1")
    with TestClient(app) as client:
        assert client.get("/api/health").json()["simulate_load"] is True


def test_lifespan_creates_a_publishing_engine():
    with TestClient(app):
        assert isinstance(app.state.engine, SqliteQueueEngine)
        assert app.state.engine._publish == main.events.bus.publish


def test_startup_seeds_exactly_once(open_conn):
    bootstrap.startup(simulate_load=True)
    assert count(open_conn, "ticket") == SIMULATED_TOTAL
    engine = SqliteQueueEngine()
    reserved = engine.issue_ticket(make_visit(open_conn, "P001"), T1)
    activated = engine.activate(reserved.id)
    open_conn.execute("UPDATE patient SET full_name_en = 'Changed' WHERE id = 'P002'")
    sequences = open_conn.execute(
        "SELECT * FROM number_sequence ORDER BY centre_id, prefix"
    ).fetchall()

    bootstrap.startup(simulate_load=True)

    assert count(open_conn, "ticket") == SIMULATED_TOTAL + 1
    assert count(open_conn, "visit") == 1
    name = open_conn.execute("SELECT full_name_en FROM patient WHERE id = 'P002'").fetchone()
    assert name[0] == "Changed"
    after = open_conn.execute(
        "SELECT * FROM number_sequence ORDER BY centre_id, prefix"
    ).fetchall()
    assert [tuple(row) for row in after] == [tuple(row) for row in sequences]
    assert engine.position(activated.id).number == "T-014"


def test_app_restart_keeps_tickets(open_conn, monkeypatch):
    monkeypatch.setenv("SIMULATE_LOAD", "1")
    with TestClient(app):
        pass
    assert count(open_conn, "ticket") == SIMULATED_TOTAL
    with TestClient(app):
        pass
    assert count(open_conn, "ticket") == SIMULATED_TOTAL


@pytest.mark.parametrize(("env", "expected"), [("1", SIMULATED_TOTAL), (None, 0)])
def test_startup_load_defaults_to_config(open_conn, monkeypatch, env, expected):
    if env is not None:
        monkeypatch.setenv("SIMULATE_LOAD", env)
    bootstrap.startup()
    assert count(open_conn, "ticket") == expected


def test_startup_argument_beats_config(open_conn, monkeypatch):
    monkeypatch.setenv("SIMULATE_LOAD", "1")
    bootstrap.startup(simulate_load=False)
    assert count(open_conn, "ticket") == 0


def test_reset_demo_works_on_a_brand_new_database(db_path):
    assert not db_path.exists()
    bootstrap.reset_demo(simulate_load=True)
    conn = db.connect()
    assert count(conn, "ticket") == SIMULATED_TOTAL
    conn.close()


def test_reset_demo_restores_t014_and_keeps_sessions(open_conn):
    bootstrap.startup(simulate_load=True)
    engine = SqliteQueueEngine()
    token = auth.create_session(open_conn, "staff", "S-WAK-NURSE1")
    for patient_id in ("P001", "P002"):
        reserved = engine.issue_ticket(make_visit(open_conn, patient_id), T1)
        engine.activate(reserved.id)

    bootstrap.reset_demo(simulate_load=True)

    assert count(open_conn, "visit") == 0
    assert count(open_conn, "ticket") == SIMULATED_TOTAL
    assert auth.lookup_session(open_conn, token) is not None
    reserved = engine.issue_ticket(make_visit(open_conn, "P001"), T1)
    assert engine.activate(reserved.id).number == "T-014"


@pytest.mark.parametrize(
    ("error", "status", "code"),
    [
        (TicketNotFound, 404, "ticket_not_found"),
        (TicketExpired, 410, "ticket_expired"),
        (InvalidTransition, 409, "invalid_transition"),
        (VisitNotEligible, 409, "visit_not_eligible"),
        (VisitHasLiveTicket, 409, "visit_has_live_ticket"),
        (CounterBusy, 409, "counter_busy"),
    ],
)
def test_queue_error_handler(add_route, error, status, code):
    def boom():
        raise error("the detail")

    add_route("/api/test-boom", boom)
    with TestClient(app) as client:
        response = client.get("/api/test-boom")
    assert response.status_code == status
    assert response.json() == {"error": code, "message": "the detail"}


def test_get_engine_returns_the_app_engine(add_route):
    def engine_id(engine=Depends(deps.get_engine)):
        return {"same": engine is app.state.engine}

    add_route("/api/test-engine", engine_id)
    with TestClient(app) as client:
        assert client.get("/api/test-engine").json() == {"same": True}


def test_expiry_loop_releases_a_past_due_ticket(open_conn, monkeypatch):
    monkeypatch.setattr(main, "EXPIRY_INTERVAL_SEC", 0.01)
    with TestClient(app):
        visit_id = make_visit(open_conn, "P001")
        ticket = app.state.engine.issue_ticket(visit_id, T1)
        open_conn.execute(
            "UPDATE ticket SET reserved_at = '2026-01-01T00:00:00.000000+00:00' WHERE id = ?",
            (ticket.id,),
        )

        def released():
            row = open_conn.execute(
                "SELECT state FROM ticket WHERE id = ?", (ticket.id,)
            ).fetchone()
            return row["state"] == "released"

        assert wait_until(released)
    status = open_conn.execute("SELECT status FROM visit WHERE id = ?", (visit_id,)).fetchone()
    assert status["status"] == "expired"


def test_expiry_loop_leaves_a_ticket_inside_its_window(open_conn, monkeypatch):
    monkeypatch.setattr(main, "EXPIRY_INTERVAL_SEC", 0.01)
    with TestClient(app):
        ticket = app.state.engine.issue_ticket(make_visit(open_conn, "P001"), T1)
        time.sleep(0.1)
        assert app.state.engine.position(ticket.id).state == "reserved"


def test_expiry_loop_survives_a_failure_and_stops_on_shutdown(monkeypatch, caplog):
    monkeypatch.setattr(main, "EXPIRY_INTERVAL_SEC", 0.01)
    calls = []

    def flaky():
        calls.append(1)
        if len(calls) == 1:
            raise RuntimeError("expiry failed")
        return []

    with TestClient(app):
        monkeypatch.setattr(app.state.engine, "expire_due", flaky)
        assert wait_until(lambda: len(calls) >= 3)
    assert "reservation expiry pass failed" in caplog.text
    after_shutdown = len(calls)
    time.sleep(0.05)
    assert len(calls) == after_shutdown
