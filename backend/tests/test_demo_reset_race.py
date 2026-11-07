"""A demo reset runs beside live requests, and none of them may notice it happening."""

from __future__ import annotations

import json
import sqlite3
import threading
from collections import Counter
from collections.abc import Iterator
from concurrent.futures import Future, ThreadPoolExecutor
from contextlib import closing, contextmanager

import httpx
import pytest
from fastapi.testclient import TestClient

from backend import bootstrap, db, seeding, simulate, visit_flow
from backend.adapters.queue_base import InvalidTransition
from backend.ai import handoff, session
from backend.ai.handoff import HandoffError
from backend.queue_engine import SqliteQueueEngine
from backend.routers import staff as staff_routes
from backend.tests.api_helpers import (
    AHMED_QID,
    AHMED_TEXT,
    DESK,
    DOCTOR2,
    FATIMA_QID,
    NURSE,
    RAVI_TEXT,
    Live,
    bearer,
    patient_token,
    say,
    staff_token,
    start_visit,
)
from backend.tests.test_api_staff import D4, Staff, arrived, at_doctor, at_vitals

T1 = "C-WAKRA-T1"
WAKRA = "C-WAKRA"
SIMULATED_AT_T1 = 3
HOLD_LIMIT_SEC = 10
RESETS = 12
READERS = 6
FORBIDDEN_CODES = ("unknown_counter", "invalid_transition")
VISIT_GONE = (404, "visit_not_found")
TICKET_GONE = (404, "ticket_not_found")
ROUTINE_VITALS = {"bp_sys": 120, "bp_dia": 80, "hr": 72, "temp_c": 38.1, "urgency": "routine"}
ONE_MEDICINE = {"prescription": [{"drug_id": "DR-PARA"}]}


class Hold:
    """Stops one thread at a chosen line until the test lets it go."""

    def __init__(self) -> None:
        self.reached = threading.Event()
        self.release = threading.Event()

    def stop_here(self) -> None:
        self.reached.set()
        assert self.release.wait(HOLD_LIMIT_SEC), "the test never released the reset"


@contextmanager
def reset_held(hold: Hold) -> Iterator[Future]:
    """A reset running on its own thread, stopped at the hold when the body starts."""
    with ThreadPoolExecutor(max_workers=1) as pool:
        running = pool.submit(bootstrap.reset_demo)
        try:
            assert hold.reached.wait(HOLD_LIMIT_SEC), "the reset never reached the hold"
            yield running
        finally:
            hold.release.set()
        running.result(timeout=HOLD_LIMIT_SEC)


def has_fresh_attached(conn: sqlite3.Connection) -> bool:
    return len(conn.execute("PRAGMA database_list").fetchall()) > 1


def count(conn: sqlite3.Connection, table: str) -> int:
    return conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]


def hold_the_swap_commit(monkeypatch: pytest.MonkeyPatch, hold: Hold) -> None:
    """Stops the transaction that has the fresh file attached, just before its COMMIT."""
    transaction = db.transaction

    @contextmanager
    def held_commit(conn: sqlite3.Connection) -> Iterator[sqlite3.Connection]:
        swapping = has_fresh_attached(conn)
        with transaction(conn):
            yield conn
            if swapping:
                hold.stop_here()

    monkeypatch.setattr(db, "transaction", held_commit)


def walk_in(client, token: str) -> str:
    response = client.post(
        "/api/desk/walk-in",
        json={"qid": "DEMO-10001", "complaint": "I have a cough"},
        headers=bearer(token),
    )
    assert response.status_code == 200, response.text
    return response.json()["visit_id"]


def answer(response: httpx.Response) -> tuple[int, str | None]:
    return response.status_code, response.json().get("error")


def reset_before_call(monkeypatch: pytest.MonkeyPatch, owner: object, name: str) -> None:
    """The next call of owner.name finds the reset already done."""
    real = getattr(owner, name)

    def after_a_reset(*args: object, **kwargs: object) -> object:
        monkeypatch.setattr(owner, name, real)
        bootstrap.reset_demo()
        return real(*args, **kwargs)

    monkeypatch.setattr(owner, name, after_a_reset)


def reset_after_call(monkeypatch: pytest.MonkeyPatch, owner: object, name: str) -> None:
    """The next call of owner.name does its work, and the reset lands as it returns."""
    real = getattr(owner, name)

    def then_a_reset(*args: object, **kwargs: object) -> object:
        monkeypatch.setattr(owner, name, real)
        result = real(*args, **kwargs)
        bootstrap.reset_demo()
        return result

    monkeypatch.setattr(owner, name, then_a_reset)


def reset_before_next_transaction(monkeypatch: pytest.MonkeyPatch) -> None:
    """The last moment open to a reset: once the write lock is held, it would have to wait."""
    transaction = db.transaction
    armed = [True]

    @contextmanager
    def after_a_reset(conn: sqlite3.Connection) -> Iterator[sqlite3.Connection]:
        if armed:
            armed.clear()
            bootstrap.reset_demo()
        with transaction(conn):
            yield conn

    monkeypatch.setattr(db, "transaction", after_a_reset)


def reset_at_transaction_inside(monkeypatch: pytest.MonkeyPatch, owner: object, name: str) -> None:
    """owner.name makes its reads, and the reset lands just before its first transaction."""
    real = getattr(owner, name)

    def armed(*args: object, **kwargs: object) -> object:
        reset_before_next_transaction(monkeypatch)
        return real(*args, **kwargs)

    monkeypatch.setattr(owner, name, armed)


def seeded_state(conn: sqlite3.Connection) -> dict[str, list]:
    """Every table but session, in row order, without the ids and stamps a run makes up."""
    tables = [
        row["name"]
        for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT IN ('session', 'sqlite_sequence') ORDER BY name"
        )
    ]
    state = {
        table: [dict(row) for row in conn.execute(f"SELECT * FROM {table} ORDER BY rowid")]
        for table in tables
    }
    for row in state["ticket"]:
        del row["id"], row["activated_at"]
    for row in state["event"]:
        row["payload"] = {
            key: value for key, value in json.loads(row["payload"]).items() if key != "ticket_id"
        }
        del row["at"]
    state["autoincrement"] = [
        dict(row)
        for row in conn.execute(
            "SELECT name, seq FROM sqlite_sequence WHERE seq > 0 ORDER BY name"
        )
    ]
    return state


def state_of_a_new_database(path, monkeypatch, load: bool) -> dict[str, list]:
    with monkeypatch.context() as scope:
        scope.setenv("DAWRI_DB", str(path))
        bootstrap.startup(simulate_load=load)
        with closing(db.connect()) as conn:
            return seeded_state(conn)


def state_now() -> dict[str, list]:
    with closing(db.connect()) as conn:
        return seeded_state(conn)


# Paused inside the reset


def test_a_session_is_served_while_the_seed_runs(api, monkeypatch):
    """The gap of the old reset: every table empty, the seed still to come."""
    nurse = bearer(staff_token(api, NURSE))
    patient = bearer(patient_token(api, FATIMA_QID))
    visit_id = walk_in(api, staff_token(api, DESK))
    hold = Hold()
    seed_static = seeding.seed_static

    def held_seed(conn: sqlite3.Connection) -> None:
        hold.stop_here()
        seed_static(conn)

    monkeypatch.setattr(seeding, "seed_static", held_seed)

    with reset_held(hold):
        me = api.get("/api/staff/me", headers=nurse)
        queue = api.get(f"/api/counters/{T1}/queue", headers=nurse)
        assert me.status_code == 200, me.text
        assert me.json()["centre"]["id"] == WAKRA
        assert queue.status_code == 200, queue.text
        assert api.get("/api/me", headers=patient).status_code == 200
        assert api.get(f"/api/staff/visits/{visit_id}", headers=nurse).status_code == 200

    assert api.get("/api/staff/me", headers=nurse).status_code == 200
    assert api.get(f"/api/staff/visits/{visit_id}", headers=nurse).status_code == 404


def test_the_swap_shows_nothing_until_it_commits(api, monkeypatch):
    """The last moment of the reset: tables cleared and refilled, the commit still to come.

    Only reads that need no write lock can run here: the rest wait, as the next test shows.
    """
    nurse = bearer(staff_token(api, NURSE))
    visit_id = walk_in(api, staff_token(api, DESK))
    before = api.get(f"/api/counters/{T1}/queue", headers=nurse).json()["tickets"]
    assert len(before) == SIMULATED_AT_T1 + 1
    with closing(db.connect()) as conn:
        before_rows = count(conn, "ticket")
    hold = Hold()
    hold_the_swap_commit(monkeypatch, hold)

    with reset_held(hold):
        with closing(db.connect()) as reader:
            seen = (count(reader, "ticket"), count(reader, "staff") > 0, count(reader, "visit"))
        assert seen == (before_rows, True, 1)
        me = api.get("/api/staff/me", headers=nurse)
        assert me.status_code == 200, me.text

    after = api.get(f"/api/counters/{T1}/queue", headers=nurse).json()["tickets"]
    assert len(after) == SIMULATED_AT_T1
    assert api.get(f"/api/staff/visits/{visit_id}", headers=nurse).status_code == 404


def test_a_queue_read_waits_out_the_swap_and_is_served(api, monkeypatch):
    """The queue route takes the write lock for its lazy expiry, so it queues behind the swap."""
    nurse = bearer(staff_token(api, NURSE))
    hold = Hold()
    hold_the_swap_commit(monkeypatch, hold)

    with reset_held(hold), ThreadPoolExecutor(max_workers=1) as pool:
        read = pool.submit(api.get, f"/api/counters/{T1}/queue", headers=nurse)
        threading.Timer(0.2, hold.release.set).start()
        response = read.result(timeout=HOLD_LIMIT_SEC)

    assert response.status_code == 200, response.text
    assert len(response.json()["tickets"]) == SIMULATED_AT_T1


def test_the_swap_is_one_commit(api, monkeypatch):
    """Read after each commit of the swap: a second commit would leave a gap before it."""
    seen = []
    transaction = db.transaction

    @contextmanager
    def watched(conn: sqlite3.Connection) -> Iterator[sqlite3.Connection]:
        swapping = has_fresh_attached(conn)
        with transaction(conn):
            yield conn
        if swapping:
            with closing(db.connect()) as reader:
                seen.append((count(reader, "staff") > 0, count(reader, "ticket") > 0))

    monkeypatch.setattr(db, "transaction", watched)
    bootstrap.reset_demo()
    assert seen == [(True, True)]


# A reset landing inside a request, at each read the request makes after its visit check


def test_a_queue_row_a_reset_removed_is_left_out_and_the_queue_is_served(api, monkeypatch):
    nurse = Staff(api, NURSE)
    walk_in(api, staff_token(api, DESK))
    reset_after_call(monkeypatch, SqliteQueueEngine, "queue_snapshot")

    response = nurse.get(f"/api/counters/{T1}/queue")

    assert response.status_code == 200, response.text
    assert [row["visit_id"] for row in response.json()["tickets"]] == [None] * SIMULATED_AT_T1


def _called_to_triage(api: TestClient) -> str:
    visit_id = arrived(api)
    Staff(api, NURSE).ok(f"/api/counters/{T1}/call-next")
    return visit_id


def test_vitals_on_a_visit_a_reset_removed_answer_404(api, monkeypatch):
    visit_id = _called_to_triage(api)
    reset_before_call(monkeypatch, staff_routes, "_visit_status")
    response = Staff(api, NURSE).post(f"/api/visits/{visit_id}/vitals", ROUTINE_VITALS)
    assert answer(response) == VISIT_GONE


def test_an_intake_edit_on_a_visit_a_reset_removed_answers_404(api, monkeypatch):
    visit_id = arrived(api)
    reset_before_next_transaction(monkeypatch)
    response = Staff(api, NURSE).put(
        f"/api/visits/{visit_id}/intake", {"json": {"chief_complaint": "fever"}}
    )
    assert answer(response) == VISIT_GONE


def test_a_handoff_draft_on_a_visit_a_reset_removed_answers_404(api, monkeypatch):
    nurse = Staff(api, NURSE)
    visit_id = at_vitals(nurse, api)
    reset_before_call(monkeypatch, staff_routes, "_visit_status")
    assert answer(nurse.post(f"/api/visits/{visit_id}/handoff/draft")) == VISIT_GONE


def test_a_handoff_confirm_on_a_visit_a_reset_removed_answers_404(api, monkeypatch):
    nurse = Staff(api, NURSE)
    visit_id = at_vitals(nurse, api)
    text = nurse.ok(f"/api/visits/{visit_id}/handoff/draft")["text"]
    reset_before_next_transaction(monkeypatch)
    response = nurse.post(
        f"/api/visits/{visit_id}/handoff/confirm", {"final_text": text, "doctor_id": DOCTOR2}
    )
    assert answer(response) == VISIT_GONE


def _called_to_doctor(api: TestClient) -> tuple[str, Staff]:
    doctor = Staff(api, DOCTOR2)
    visit_id = at_doctor(Staff(api, NURSE), api)
    doctor.ok(f"/api/counters/{D4}/call-next")
    return visit_id, doctor


def test_a_consult_whose_visit_a_reset_removed_as_it_finished_answers_404(api, monkeypatch):
    visit_id, doctor = _called_to_doctor(api)
    reset_after_call(monkeypatch, visit_flow, "complete_consult")
    response = doctor.post(f"/api/visits/{visit_id}/consult/done", ONE_MEDICINE)
    assert answer(response) == VISIT_GONE


@pytest.mark.parametrize("step", ["draft_for_visit", "_service"])
def test_a_reset_during_the_draft_answers_404_and_stores_no_draft(api, monkeypatch, step):
    nurse = Staff(api, NURSE)
    visit_id = at_vitals(nurse, api)
    reset_before_call(monkeypatch, handoff, step)

    response = nurse.post(f"/api/visits/{visit_id}/handoff/draft")

    assert answer(response) == VISIT_GONE
    with closing(db.connect()) as conn:
        assert count(conn, "handoff") == 0


def test_a_visit_still_here_keeps_the_draft_refusal(api, monkeypatch):
    """Only a visit that is gone turns no_intake into a 404."""
    nurse = Staff(api, NURSE)
    visit_id = at_vitals(nurse, api)

    def no_intake(*_: object) -> None:
        raise HandoffError("no_intake")

    monkeypatch.setattr(handoff, "draft_for_visit", no_intake)
    response = nurse.post(f"/api/visits/{visit_id}/handoff/draft")
    assert answer(response) == (409, "no_intake")


@pytest.mark.parametrize("complaint", ["I have a cough", RAVI_TEXT])
def test_a_walk_in_whose_visit_a_reset_removed_answers_404(api, monkeypatch, complaint):
    """Both ways through start_walk_in: a plain complaint and one the rules stop."""
    reset_at_transaction_inside(monkeypatch, session, "start_walk_in")
    response = Staff(api, DESK).post(
        "/api/desk/walk-in", {"qid": FATIMA_QID, "complaint": complaint}
    )
    assert answer(response) == VISIT_GONE


def _deflected_to_refill(api: TestClient) -> tuple[str, str]:
    token = patient_token(api, AHMED_QID)
    visit_id = start_visit(api, token)
    assert say(api, token, visit_id, AHMED_TEXT)["refill"]
    return visit_id, token


def test_a_refused_message_on_a_visit_a_reset_removed_answers_404(api, monkeypatch):
    visit_id, token = _deflected_to_refill(api)
    reset_at_transaction_inside(monkeypatch, session, "_note_refused")
    response = api.post(
        f"/api/visits/{visit_id}/chat", json={"text": "thank you"}, headers=bearer(token)
    )
    assert answer(response) == VISIT_GONE


def test_a_refill_refused_by_a_reset_stops_before_storing_anything(api, monkeypatch):
    """Its guarded UPDATE finds no row, so this one never reaches the store."""
    visit_id, token = _deflected_to_refill(api)
    reset_at_transaction_inside(monkeypatch, session, "continue_after_refill")
    response = api.post(f"/api/visits/{visit_id}/refill/continue", headers=bearer(token))
    assert answer(response) == (409, "visit_not_deflected")


def test_the_desk_stopping_a_visit_a_reset_removed_answers_404(api, monkeypatch):
    desk = Staff(api, DESK)
    walk_in(api, staff_token(api, DESK))
    reset_after_call(monkeypatch, session, "desk_red_flag")
    response = desk.post("/api/desk/walk-in", {"qid": FATIMA_QID, "complaint": RAVI_TEXT})
    assert answer(response) == VISIT_GONE


def test_a_consult_whose_ticket_a_reset_removed_answers_404(api, monkeypatch):
    visit_id, doctor = _called_to_doctor(api)
    reset_at_transaction_inside(monkeypatch, visit_flow, "complete_consult")
    response = doctor.post(f"/api/visits/{visit_id}/consult/done", ONE_MEDICINE)
    assert answer(response) == TICKET_GONE


def test_a_fast_forward_whose_ticket_a_reset_removed_answers_404(api, monkeypatch):
    nurse = Staff(api, NURSE)
    visit_id = at_doctor(nurse, api)
    reset_at_transaction_inside(monkeypatch, visit_flow, "complete_consult")
    assert answer(nurse.post(f"/api/demo/fast-forward/{visit_id}")) == TICKET_GONE


def test_a_ticket_still_here_in_the_wrong_state_stays_an_invalid_transition(api):
    nurse = Staff(api, NURSE)
    visit_id = at_doctor(nurse, api)
    engine = api.app.state.engine
    waiting = engine.live_ticket(visit_id)
    assert waiting.state == "active"
    with closing(db.connect()) as conn, pytest.raises(InvalidTransition):
        visit_flow.complete_consult(conn, engine, visit_id, waiting, [], "test")


# Real threads


def _read_until_stopped(live: Live, token: str, stop: threading.Event) -> list[tuple]:
    """Each answer as (route, status, error code, real tickets), over what a console polls."""
    routes = (
        "/api/staff/me",
        f"/api/counters/{T1}/queue",
        f"/api/display/{WAKRA}",
        f"/api/stats/{WAKRA}",
    )
    answers = []
    with httpx.Client(base_url=live.base_url, trust_env=False, timeout=10) as http:
        while not stop.is_set():
            for route in routes:
                response = http.get(route, headers=bearer(token))
                body = response.json()
                code = None if response.is_success else body.get("error")
                tickets = body.get("tickets", []) if response.is_success else []
                real = sum(1 for row in tickets if row["visit_id"] is not None)
                answers.append((route, response.status_code, code, real))
    return answers


def test_resets_beside_reads_cost_no_session_and_no_error(live_api):
    token = staff_token(live_api.http, NURSE)
    desk = staff_token(live_api.http, DESK)
    stop = threading.Event()

    with ThreadPoolExecutor(max_workers=READERS) as pool:
        readers = [
            pool.submit(_read_until_stopped, live_api, token, stop) for _ in range(READERS)
        ]
        try:
            for _ in range(RESETS):
                walk_in(live_api.http, desk)  # A real ticket, whose visit the reset removes.
                response = live_api.http.post("/api/demo/reset", headers=bearer(token), timeout=10)
                assert response.status_code == 200, response.text
        finally:
            stop.set()
        answers = [answer for reader in readers for answer in reader.result()]

    assert len(answers) > RESETS * 4
    wrong = Counter(
        (route, status, code)
        for route, status, code, _ in answers
        if status == 401 or status >= 500 or code in FORBIDDEN_CODES
    )
    assert not wrong
    assert {status for _, status, _, _ in answers} == {200}
    assert sum(real for *_, real in answers) > 0


def test_two_resets_at_once_leave_one_clean_demo(live_api, tmp_path, monkeypatch):
    fresh = state_of_a_new_database(tmp_path / "new.db", monkeypatch, load=True)
    token = staff_token(live_api.http, NURSE)

    def reset(_: int) -> int:
        response = live_api.http.post("/api/demo/reset", headers=bearer(token), timeout=10)
        return response.status_code

    with ThreadPoolExecutor(max_workers=4) as pool:
        assert set(pool.map(reset, range(8))) == {200}

    after = state_now()
    assert [row for row in after["event"] if row["type"] != "demo.reset"] == fresh["event"]
    after.pop("event"), fresh.pop("event")
    after.pop("autoincrement"), fresh.pop("autoincrement")
    assert after == fresh


# What a reset leaves behind


@pytest.mark.parametrize("load", [True, False])
def test_seeded_rows_after_a_reset_equal_a_new_database(api, tmp_path, monkeypatch, load):
    desk = staff_token(api, DESK)
    walk_in(api, desk)
    with closing(db.connect()) as conn:
        conn.execute("UPDATE patient SET allergies = '[]' WHERE id = 'P001'")
        conn.execute("UPDATE drug SET default_days = 99")
        conn.execute("UPDATE counter SET avg_service_sec = 1")

    bootstrap.reset_demo(simulate_load=load)

    assert state_now() == state_of_a_new_database(tmp_path / "new.db", monkeypatch, load)


def test_the_next_number_after_a_reset_is_t_014(api):
    desk = staff_token(api, DESK)
    walk_in(api, desk)
    bootstrap.reset_demo()
    visit_id = walk_in(api, desk)
    numbers = [
        row["number"]
        for row in api.get(f"/api/counters/{T1}/queue", headers=bearer(staff_token(api, NURSE)))
        .json()["tickets"]
        if row["visit_id"] == visit_id
    ]
    assert numbers == ["T-014"]


def test_sessions_survive_and_the_new_event_ids_continue_from_the_seed(api):
    nurse = bearer(staff_token(api, NURSE))
    patient = bearer(patient_token(api, FATIMA_QID))
    assert api.post("/api/demo/reset", headers=nurse).status_code == 200
    assert api.get("/api/staff/me", headers=nurse).status_code == 200
    assert api.get("/api/me", headers=patient).status_code == 200
    with closing(db.connect()) as conn:
        simulated = conn.execute("SELECT COUNT(*) FROM ticket").fetchone()[0]
        last = conn.execute("SELECT MAX(id) FROM event").fetchone()[0]
    assert last == simulated + 1  # One ticket.activated each, then demo.reset.


def test_a_seed_that_fails_leaves_the_demo_as_it_was(api, db_path, monkeypatch):
    nurse = bearer(staff_token(api, NURSE))
    visit_id = walk_in(api, staff_token(api, DESK))

    def broken_seed(*_: object) -> None:
        raise RuntimeError("seed failed")

    monkeypatch.setattr(simulate, "seed_queue_state", broken_seed)
    with pytest.raises(RuntimeError, match="seed failed"):
        bootstrap.reset_demo()

    assert api.get(f"/api/staff/visits/{visit_id}", headers=nurse).status_code == 200
    assert [path.name for path in db_path.parent.glob(".dawri-reset-*")] == []


def test_a_swap_that_fails_leaves_the_demo_as_it_was(api, monkeypatch):
    nurse = bearer(staff_token(api, NURSE))
    visit_id = walk_in(api, staff_token(api, DESK))
    before = state_now()
    monkeypatch.setattr(db, "_RESET_ORDER", (*db._RESET_ORDER, "no_such_table"))

    with pytest.raises(sqlite3.OperationalError, match="no_such_table"):
        bootstrap.reset_demo()

    assert state_now() == before
    assert api.get(f"/api/staff/visits/{visit_id}", headers=nurse).status_code == 200


def test_the_build_writes_nothing_to_the_live_database(db_path, monkeypatch):
    """The engine must follow the scratch file: its default connection is the live one."""
    monkeypatch.setenv("SIMULATE_LOAD", "1")
    bootstrap.startup()
    with closing(db.connect()) as conn:
        conn.execute("UPDATE number_sequence SET last_value = 500")
    hold = Hold()
    swap = db.reset_all

    def held_swap(conn: sqlite3.Connection, fresh=None) -> None:
        hold.stop_here()
        swap(conn, fresh)

    monkeypatch.setattr(db, "reset_all", held_swap)

    with reset_held(hold):
        with closing(db.connect()) as conn:
            values = conn.execute("SELECT DISTINCT last_value FROM number_sequence").fetchall()
        assert [row[0] for row in values] == [500]

    engine = SqliteQueueEngine()
    assert engine.issue_simulated(T1).number == "T-014"
