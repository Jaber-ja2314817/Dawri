"""The patient's visit: consent, chat, voice, confirming and the emergency red line."""

from __future__ import annotations

import inspect
import json
import os
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

import pytest

from backend import db, timeutil
from backend.adapters.queue_base import InvalidTransition
from backend.ai import runtime, session
from backend.ai.asr import ASR_UNAVAILABLE_AR, ASR_UNAVAILABLE_EN
from backend.ai.receptionist import TurnResult
from backend.routers import centres as centres_router
from backend.routers import visits
from backend.tests.ai_fakes import WAV_BYTES, FakeAsrClient
from backend.tests.api_helpers import (
    AHMED_QID,
    AHMED_TEXT,
    FATIMA_ANSWERS,
    FATIMA_QID,
    NURSE,
    RAVI_QID,
    RAVI_TEXT,
    bearer,
    patient_token,
    say,
    staff_token,
    start_visit,
)
from backend.tests.conftest import FakeClock, make_visit

T1 = "C-WAKRA-T1"
LIMIT = visits.MAX_AUDIO_BYTES
STAFF_ROUTE_EN = "Speak to a member of staff at the centre, or call 999"
STAFF_ROUTE_AR = "تحدث إلى أحد الموظفين في المركز، أو اتصل بـ 999"
STAFF_ONLY_KEYS = {
    "summary_for_nurse",
    "chief_complaint",
    "duration",
    "associated",
    "patient_concerns",
    "turns",
    "patient_words",
}
TRANSCRIPT = "I have had a sore throat for two days."


@pytest.fixture
def conn(api):
    connection = db.connect()
    yield connection
    connection.close()


@pytest.fixture
def fatima(api):
    return patient_token(api, FATIMA_QID)


@pytest.fixture
def ravi(api):
    return patient_token(api, RAVI_QID)


@pytest.fixture
def ahmed(api):
    return patient_token(api, AHMED_QID)


@pytest.fixture
def asr_client(api):
    """Real-mode voice with a fake client. The LLM stays simulated."""
    client = FakeAsrClient(TRANSCRIPT)
    api.app.state.ai = runtime.build_runtime(asr_client=client)
    return client


def _post(api, token, path, body=None):
    return api.post(path, json=body, headers=bearer(token))


def _state(api, token, visit_id):
    response = api.get(f"/api/visits/{visit_id}", headers=bearer(token))
    assert response.status_code == 200, response.text
    return response.json()


def _chat_audio(api, token, visit_id, audio=WAV_BYTES):
    return api.post(
        f"/api/visits/{visit_id}/chat",
        files={"audio": ("clip.wav", audio, "audio/wav")},
        headers=bearer(token),
    )


def _intake_row(conn, visit_id):
    row = conn.execute("SELECT * FROM intake WHERE visit_id = ?", (visit_id,)).fetchone()
    return row, json.loads(row["json"])


def _events(conn, visit_id, event_type):
    return conn.execute(
        "SELECT * FROM event WHERE visit_id = ? AND type = ?", (visit_id, event_type)
    ).fetchall()


def _tickets(conn, visit_id):
    return conn.execute("SELECT * FROM ticket WHERE visit_id = ?", (visit_id,)).fetchall()


def _visit_count(conn):
    return conn.execute("SELECT COUNT(*) FROM visit").fetchone()[0]


def _keys(value):
    if isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from _keys(item)
    elif isinstance(value, list):
        for item in value:
            yield from _keys(item)


def _assert_patient_safe(conn, visit_id, response):
    assert not STAFF_ONLY_KEYS & set(_keys(response.json())), response.text
    row = conn.execute("SELECT json FROM intake WHERE visit_id = ?", (visit_id,)).fetchone()
    summary = json.loads(row["json"]).get("summary_for_nurse") if row else None
    if summary:
        assert summary not in response.text


def _finished_chat(api, token):
    visit_id = start_visit(api, token)
    say(api, token, visit_id, *FATIMA_ANSWERS)
    return visit_id


def _confirmed(api, token):
    visit_id = _finished_chat(api, token)
    assert _post(api, token, f"/api/visits/{visit_id}/intake/confirm").status_code == 200
    return visit_id


def _reserved(api, token, centre_id="C-WAKRA"):
    visit_id = _confirmed(api, token)
    response = _post(api, token, f"/api/visits/{visit_id}/reserve", {"centre_id": centre_id})
    assert response.status_code == 200, response.text
    return visit_id


def _arrived(api, token):
    visit_id = _reserved(api, token)
    response = _post(api, token, f"/api/visits/{visit_id}/arrive", {"button": True})
    assert response.status_code == 200, response.text
    return visit_id


def _confirmed_child(api, token):
    visit_id = start_visit(api, token, "P004")
    say(api, token, visit_id, "She has a sore throat for 2 days", "5", "no", "no", "no")
    assert _post(api, token, f"/api/visits/{visit_id}/intake/confirm").status_code == 200
    return visit_id


# Consent


@pytest.mark.parametrize(
    "body",
    [{"consent": False}, {}, {"consent": "true"}, {"consent": 1}, None],
    ids=["false", "missing", "a string", "a number", "no body"],
)
def test_consent_must_be_true(api, fatima, conn, body):
    response = _post(api, fatima, "/api/visits", body)
    assert response.status_code == 422
    assert response.json()["error"] == "consent_required"
    assert _visit_count(conn) == 0


def test_starting_a_visit(api, fatima, conn):
    response = _post(api, fatima, "/api/visits", {"consent": True})
    assert response.status_code == 200
    body = response.json()
    assert set(body) == {"visit_id", "status", "language", "opening"}
    assert body["visit_id"].startswith("V_")
    assert body["status"] == "intake"
    assert body["language"] == "ar"
    assert body["opening"] == "شو اللي يتعبك اليوم؟"
    row = conn.execute("SELECT * FROM visit WHERE id = ?", (body["visit_id"],)).fetchone()
    assert (row["patient_id"], row["booked_by"], row["status"]) == ("P001", "P001", "intake")
    assert len(_events(conn, body["visit_id"], "consent.given")) == 1


def test_the_opening_is_in_the_patients_language(api, ravi):
    body = _post(api, ravi, "/api/visits", {"consent": True}).json()
    assert body["language"] == "en"
    assert body["opening"] == "What brings you in today?"


def test_starting_needs_a_patient(api):
    assert api.post("/api/visits", json={"consent": True}).status_code == 401
    token = staff_token(api, NURSE)
    assert _post(api, token, "/api/visits", {"consent": True}).status_code == 403


# Dependents


def test_a_visit_for_a_dependent_records_who_booked_it(api, fatima, conn):
    visit_id = start_visit(api, fatima, "P004")
    row = conn.execute("SELECT * FROM visit WHERE id = ?", (visit_id,)).fetchone()
    assert (row["patient_id"], row["booked_by"]) == ("P004", "P001")
    state = _state(api, fatima, visit_id)
    assert (state["patient_id"], state["booked_by"]) == ("P004", "P001")


@pytest.mark.parametrize("patient_id", ["P004", "P001", "P-NOPE"])
def test_a_stranger_cannot_book_for_someone(api, ravi, conn, patient_id):
    response = _post(api, ravi, "/api/visits", {"consent": True, "patient_id": patient_id})
    assert response.status_code == 403
    assert response.json()["error"] == "forbidden"
    assert _visit_count(conn) == 0


def test_a_dependent_has_their_own_active_visit(api, fatima):
    _reserved(api, fatima)
    assert start_visit(api, fatima, "P004")


def test_the_active_check_is_on_the_patient_not_the_booker(api, fatima):
    child = start_visit(api, fatima, "P004")
    say(api, fatima, child, *FATIMA_ANSWERS)
    _post(api, fatima, f"/api/visits/{child}/intake/confirm")
    _post(api, fatima, f"/api/visits/{child}/reserve", {"centre_id": "C-WAKRA"})
    response = _post(api, fatima, "/api/visits", {"consent": True, "patient_id": "P004"})
    assert response.status_code == 409
    assert response.json()["visit_id"] == child
    assert start_visit(api, fatima)


# Refusals on a new visit


@pytest.mark.parametrize("status", ["reserved", "in_triage", "in_doctor", "in_pharmacy"])
def test_active_visit(api, fatima, conn, status):
    visit_id = make_visit(conn, "P001", status=status)
    before = _visit_count(conn)
    response = _post(api, fatima, "/api/visits", {"consent": True})
    assert response.status_code == 409
    body = response.json()
    assert body["error"] == "active_visit"
    assert body["visit_id"] == visit_id
    assert _visit_count(conn) == before


@pytest.mark.parametrize(
    "status", ["intake", "deflected_refill", "expired", "completed", "cancelled"]
)
def test_other_visits_do_not_block_a_new_one(api, fatima, conn, status):
    make_visit(conn, "P001", status=status)
    assert start_visit(api, fatima)


def test_emergency_today_blocks_a_fresh_chat(api, ravi, conn):
    visit_id = start_visit(api, ravi)
    say(api, ravi, visit_id, RAVI_TEXT)
    before = _visit_count(conn)
    response = _post(api, ravi, "/api/visits", {"consent": True})
    assert response.status_code == 409
    body = response.json()
    assert body["error"] == "emergency_today"
    assert body["visit_id"] == visit_id
    assert body["message"] == STAFF_ROUTE_EN
    assert body["message_ar"] == STAFF_ROUTE_AR
    assert _visit_count(conn) == before


def _at(day, hour, minute=0):
    return datetime(2026, 11, day, hour, minute, tzinfo=timezone.utc)


@pytest.mark.parametrize(
    ("created", "now", "blocked"),
    [
        (_at(6, 22), _at(7, 1), True),  # Two UTC dates, one Doha day: the 7th.
        (_at(6, 21), _at(6, 22), True),  # The first minute of the Doha day.
        (_at(6, 20, 59), _at(6, 21), False),  # Either side of Doha's midnight.
        (_at(5, 12), _at(6, 12), False),  # Yesterday.
    ],
    ids=["same doha day", "start of the day", "across midnight", "yesterday"],
)
def test_emergency_today_is_the_doha_day(api, ravi, conn, monkeypatch, created, now, blocked):
    visit_id = make_visit(conn, "P003", status="redirected_emergency")
    conn.execute(
        "UPDATE visit SET created_at = ? WHERE id = ?", (timeutil.iso(created), visit_id)
    )
    monkeypatch.setattr("backend.timeutil.utcnow", lambda: now)
    response = _post(api, ravi, "/api/visits", {"consent": True})
    assert response.status_code == (409 if blocked else 200), response.text


def test_an_emergency_does_not_block_the_guardian(api, fatima):
    child = start_visit(api, fatima, "P004")
    say(api, fatima, child, "She has chest pain.")
    assert _state(api, fatima, child)["status"] == "redirected_emergency"
    assert start_visit(api, fatima)


def test_an_older_open_visit_cannot_walk_around_the_red_line(api, fatima, conn):
    older = _confirmed(api, fatima)
    newer = start_visit(api, fatima)
    say(api, fatima, newer, "I have chest pain.")
    response = _post(api, fatima, f"/api/visits/{older}/reserve", {"centre_id": "C-WAKRA"})
    assert response.status_code == 409
    assert response.json()["error"] == "emergency_today"
    assert response.json()["visit_id"] == newer
    assert _tickets(conn, older) == []


def test_a_reservation_held_on_another_visit_cannot_be_activated(api, fatima, conn):
    other = start_visit(api, fatima)
    reserved = _reserved(api, fatima)
    say(api, fatima, other, "I have chest pain.")
    response = _post(api, fatima, f"/api/visits/{reserved}/arrive", {"button": True})
    assert response.status_code == 409
    assert response.json()["error"] == "emergency_today"
    assert conn.execute(
        "SELECT state FROM ticket WHERE visit_id = ?", (reserved,)
    ).fetchone()["state"] == "released"


# One queue place per patient


def _two_confirmed(api, token):
    """Two sibling visits, each ready to reserve. The second opens before any ticket exists."""
    first = _confirmed(api, token)
    return first, _confirmed(api, token)


def test_a_second_reservation_is_refused(api, fatima, conn):
    first, second = _two_confirmed(api, fatima)
    assert _post(api, fatima, f"/api/visits/{first}/reserve", {"centre_id": "C-WAKRA"}).is_success
    response = _post(api, fatima, f"/api/visits/{second}/reserve", {"centre_id": "C-WAKRA"})
    assert response.status_code == 409
    assert response.json()["error"] == "active_visit"
    assert response.json()["visit_id"] == first
    assert _tickets(conn, second) == []
    assert _state(api, fatima, second)["status"] == "intake"


def test_a_ticket_in_the_queue_also_blocks_a_reservation(api, fatima, conn):
    other = _confirmed(api, fatima)
    arrived = _arrived(api, fatima)
    response = _post(api, fatima, f"/api/visits/{other}/reserve", {"centre_id": "C-RAYYAN"})
    assert response.status_code == 409
    assert response.json()["error"] == "active_visit"
    assert response.json()["visit_id"] == arrived
    assert _tickets(conn, other) == []


@pytest.mark.parametrize("status", ["completed", "cancelled", "expired", "deflected_refill"])
def test_a_finished_sibling_does_not_block_a_reservation(api, fatima, conn, status):
    other = _confirmed(api, fatima)
    make_visit(conn, "P001", status=status)
    response = _post(api, fatima, f"/api/visits/{other}/reserve", {"centre_id": "C-WAKRA"})
    assert response.status_code == 200, response.text


def test_a_sibling_in_intake_does_not_block_a_reservation(api, fatima):
    other = start_visit(api, fatima)
    assert _reserved(api, fatima)
    assert _state(api, fatima, other)["status"] == "intake"


def test_a_guardian_can_reserve_beside_a_dependent(api, fatima):
    child = _confirmed_child(api, fatima)
    _post(api, fatima, f"/api/visits/{child}/reserve", {"centre_id": "C-WAKRA"})
    assert _reserved(api, fatima)


def test_a_lapsed_reservation_can_be_taken_again(api, fatima):
    visit_id = _reserved(api, fatima)
    clock = FakeClock(timeutil.utcnow())
    api.app.state.engine.clock = clock
    clock.advance(minutes=46)
    assert _state(api, fatima, visit_id)["status"] == "expired"
    response = _post(api, fatima, f"/api/visits/{visit_id}/reserve", {"centre_id": "C-WAKRA"})
    assert response.status_code == 200, response.text


def test_reserving_the_same_visit_twice_keeps_its_own_answer(api, fatima):
    visit_id = _reserved(api, fatima)
    response = _post(api, fatima, f"/api/visits/{visit_id}/reserve", {"centre_id": "C-WAKRA"})
    assert response.status_code == 409
    assert response.json()["error"] == "visit_has_live_ticket"


@pytest.mark.parametrize("round_number", range(5))
def test_two_siblings_reserving_at_once_get_one_ticket(live_api, round_number):
    """Real threads against a real server: nothing but a lock joins the check to the issue."""
    live = live_api
    token = patient_token(live.http, FATIMA_QID)
    visits_opened = []
    for _ in range(4):
        visit_id = start_visit(live.http, token)
        say(live.http, token, visit_id, *FATIMA_ANSWERS)
        assert _post(live.http, token, f"/api/visits/{visit_id}/intake/confirm").is_success
        visits_opened.append(visit_id)
    start = threading.Barrier(len(visits_opened))

    def attempt(visit_id):
        start.wait(timeout=5)
        return _post(live.http, token, f"/api/visits/{visit_id}/reserve", {"centre_id": "C-WAKRA"})

    with ThreadPoolExecutor(len(visits_opened)) as pool:
        answers = list(pool.map(attempt, visits_opened))
    assert sorted(answer.status_code for answer in answers) == [200, 409, 409, 409]
    assert {a.json()["error"] for a in answers if a.status_code == 409} == {"active_visit"}
    conn = db.connect()
    try:
        tickets = conn.execute("SELECT * FROM ticket WHERE state = 'reserved'").fetchall()
    finally:
        conn.close()
    assert len(tickets) == 1


# The visit list


def test_the_list_is_mine_and_my_dependents_newest_first(api, fatima, ravi, conn):
    mine = make_visit(conn, "P001", status="completed")
    child = make_visit(conn, "P004", status="reserved")
    strangers = make_visit(conn, "P003", status="completed")
    conn.execute("UPDATE visit SET created_at = '2026-11-05T06:00:00.000000+00:00' "
                 "WHERE id = ?", (mine,))
    response = api.get("/api/visits", headers=bearer(fatima))
    assert response.status_code == 200
    rows = response.json()
    assert [row["visit_id"] for row in rows] == [child, mine]
    assert strangers not in {row["visit_id"] for row in rows}
    assert set(rows[0]) == {
        "visit_id",
        "patient_id",
        "status",
        "stage",
        "service",
        "centre_id",
        "centre",
        "created_at",
        "completed_at",
        "active",
    }
    assert (rows[0]["patient_id"], rows[0]["active"], rows[0]["stage"]) == (
        "P004",
        True,
        "reserved",
    )
    assert (rows[1]["active"], rows[1]["stage"]) == (False, "completed")


def test_an_empty_list(api, ravi):
    assert api.get("/api/visits", headers=bearer(ravi)).json() == []


def test_the_list_needs_a_patient(api):
    assert api.get("/api/visits").status_code == 401
    assert api.get("/api/visits", headers=bearer(staff_token(api, NURSE))).status_code == 403


# Full state


def test_a_fresh_visit(api, fatima):
    visit_id = start_visit(api, fatima)
    state = _state(api, fatima, visit_id)
    assert set(state) == {
        "visit_id",
        "patient_id",
        "booked_by",
        "status",
        "stage",
        "service",
        "created_at",
        "arrived_at",
        "completed_at",
        "centre",
        "ticket",
        "intake",
        "confirmed_by_patient",
        "chat",
        "medicines",
        "emergency",
        "go_to",
        "refill",
        "rating",
    }
    assert state["stage"] == "intake"
    assert state["centre"] is None
    assert state["ticket"] is None
    assert state["intake"] is None
    assert state["confirmed_by_patient"] is False
    assert state["emergency"] is None
    assert state["go_to"] is None
    assert state["medicines"] == {"en": [], "ar": []}
    assert state["chat"]["language"] == "ar"
    assert state["chat"]["messages"][0]["role"] == "assistant"


@pytest.mark.parametrize(
    ("status", "stage"),
    [
        ("intake", "intake"),
        ("redirected_emergency", "emergency"),
        ("deflected_refill", "refill"),
        ("reserved", "reserved"),
        ("expired", "expired"),
        ("in_triage", "triage"),
        ("in_doctor", "doctor"),
        ("in_pharmacy", "pharmacy"),
        ("completed", "completed"),
        ("cancelled", "cancelled"),
    ],
)
def test_the_stage_of_every_status(api, fatima, conn, status, stage):
    visit_id = make_visit(conn, "P001", status=status)
    assert _state(api, fatima, visit_id)["stage"] == stage


def test_the_visit_needs_its_owner(api, fatima, ravi):
    visit_id = start_visit(api, fatima)
    assert api.get(f"/api/visits/{visit_id}").status_code == 401
    response = api.get(f"/api/visits/{visit_id}", headers=bearer(ravi))
    assert response.status_code == 403
    assert response.json()["error"] == "forbidden"
    response = api.get(f"/api/visits/{visit_id}", headers=bearer(staff_token(api, NURSE)))
    assert response.status_code == 403
    assert api.get("/api/visits/V-NOPE", headers=bearer(fatima)).status_code == 404


def test_a_guardian_reads_a_dependents_visit_and_a_stranger_does_not(api, fatima, ravi):
    visit_id = start_visit(api, fatima, "P004")
    assert _state(api, fatima, visit_id)["patient_id"] == "P004"
    assert api.get(f"/api/visits/{visit_id}", headers=bearer(ravi)).status_code == 403


def _complete(api, conn, visit_id):
    """Walk the visit through the engine and write a prescription."""
    engine = api.app.state.engine
    called = engine.call_next(T1).called
    assert called.visit_id == visit_id
    doctor = engine.advance(called.id, "C-WAKRA-D4")
    called = engine.call_next("C-WAKRA-D4").called
    assert called.id == doctor.id
    conn.execute(
        "INSERT INTO prescription_item (visit_id, drug, dose, frequency, days, notes) "
        "VALUES (?, 'paracetamol', '500 mg', 'every 6 hours as needed', 3, NULL)",
        (visit_id,),
    )
    pharmacy = engine.advance(called.id, "C-WAKRA-P1")
    called = engine.call_next("C-WAKRA-P1").called
    assert called.id == pharmacy.id
    return engine.finish_visit(called.id)


def test_a_completed_visit_shows_its_last_ticket_and_medicines(api, fatima, conn):
    visit_id = _arrived(api, fatima)
    last = _complete(api, conn, visit_id)
    state = _state(api, fatima, visit_id)
    assert state["status"] == "completed"
    assert state["completed_at"] is not None
    assert state["ticket"]["id"] == last.id
    assert state["ticket"]["state"] == "done"
    assert state["ticket"]["number"].startswith("P-")
    assert state["go_to"] is None
    assert "take 500 mg" in state["medicines"]["en"][0]["line"]
    assert "الجرعة 500 ملغ" in state["medicines"]["ar"][0]["line"]


@pytest.mark.parametrize("stage", ["doctor", "pharmacy"])
def test_later_stages_show_the_ticket_for_that_stage(api, fatima, conn, stage):
    visit_id = _arrived(api, fatima)
    engine = api.app.state.engine
    called = engine.call_next(T1).called
    ticket = engine.advance(called.id, "C-WAKRA-D4")
    expected = "Room 4"
    if stage == "pharmacy":
        called = engine.call_next("C-WAKRA-D4").called
        ticket = engine.advance(called.id, "C-WAKRA-P1")
        expected = "Pharmacy"
    state = _state(api, fatima, visit_id)
    assert state["stage"] == stage
    assert state["ticket"]["id"] == ticket.id
    assert state["go_to"]["counter"] == expected


def test_a_nurse_escalation_shows_the_emergency_card(api, fatima):
    visit_id = _arrived(api, fatima)
    engine = api.app.state.engine
    called = engine.call_next(T1).called
    engine.escalate(called.id, "nurse_urgent")
    state = _state(api, fatima, visit_id)
    assert state["stage"] == "emergency"
    assert state["ticket"] is None
    assert state["go_to"] is None
    assert state["emergency"]["self_harm"] is False
    assert state["emergency"]["reply"]
    assert state["emergency"]["nearest_ed"]["id"] == "H-WAKRA"


def test_an_emergency_never_shows_a_ticket_even_if_one_is_still_live(api, fatima, conn):
    """Between the status change and the release, or after a crash between them."""
    visit_id = _reserved(api, fatima)
    conn.execute("UPDATE visit SET status = 'redirected_emergency' WHERE id = ?", (visit_id,))
    state = _state(api, fatima, visit_id)
    assert api.app.state.engine.live_ticket(visit_id) is not None
    assert state["ticket"] is None
    assert state["go_to"] is None


# Chat


def test_a_chat_turn(api, fatima):
    visit_id = start_visit(api, fatima)
    response = _post(api, fatima, f"/api/visits/{visit_id}/chat", {"text": FATIMA_ANSWERS[0]})
    assert response.status_code == 200
    body = response.json()
    assert {"reply", "done", "emergency", "intake", "status", "transcript", "nearest_ed"} <= set(
        body
    )
    assert body["done"] is False
    assert body["emergency"] is False
    assert body["intake"] is None
    assert body["status"] == "intake"
    assert body["transcript"] is None
    assert body["nearest_ed"] is None


def test_the_finished_chat_carries_the_patient_intake(api, fatima, conn):
    visit_id = start_visit(api, fatima)
    body = say(api, fatima, visit_id, *FATIMA_ANSWERS)
    assert body["done"] is True
    assert body["intake"]["service"] == "gp"
    assert "summary_for_nurse" not in body["intake"]
    assert _state(api, fatima, visit_id)["service"] == "gp"


def test_the_chat_is_kept_for_the_patient(api, fatima):
    visit_id = start_visit(api, fatima)
    say(api, fatima, visit_id, FATIMA_ANSWERS[0])
    messages = _state(api, fatima, visit_id)["chat"]["messages"]
    assert [message["role"] for message in messages] == ["assistant", "user", "assistant"]
    assert messages[1]["content"] == FATIMA_ANSWERS[0]


def _raw_chat(api, token, visit_id, content):
    return api.post(
        f"/api/visits/{visit_id}/chat",
        content=content,
        headers={**bearer(token), "Content-Type": "application/json"},
    )


@pytest.mark.parametrize(
    "content",
    [
        b"",
        b"{",
        b"not json",
        b"[]",
        b'"hello"',
        b"{}",
        b'{"text": null}',
        b'{"text": 7}',
        b'{"text": ""}',
        b'{"text": "   "}',
        b'{"text": "\\ud83d"}',
        b"\xff\xfe\xfa",
        b"[" * 200_000,
    ],
    ids=[
        "empty",
        "broken",
        "not json",
        "array",
        "string",
        "no text",
        "null",
        "number",
        "blank",
        "spaces",
        "lone surrogate",
        "not utf-8",
        "deep nesting",
    ],
)
def test_invalid_text(api, fatima, conn, content):
    visit_id = start_visit(api, fatima)
    response = _raw_chat(api, fatima, visit_id, content)
    assert response.status_code == 422, response.text
    assert response.json()["error"] == "invalid_text"
    assert conn.execute("SELECT COUNT(*) FROM intake").fetchone()[0] == 0


def test_a_body_past_the_limit_is_refused_without_a_crash(api, fatima):
    visit_id = start_visit(api, fatima)
    content = json.dumps({"text": "x" * (LIMIT + 100_000)}).encode()
    response = _raw_chat(api, fatima, visit_id, content)
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_text"


def test_a_form_with_no_audio_field(api, fatima):
    visit_id = start_visit(api, fatima)
    response = api.post(
        f"/api/visits/{visit_id}/chat",
        files={"other": ("clip.wav", WAV_BYTES, "audio/wav")},
        headers=bearer(fatima),
    )
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_text"


def test_audio_sent_as_a_plain_field_is_not_audio(api, fatima):
    visit_id = start_visit(api, fatima)
    response = api.post(
        f"/api/visits/{visit_id}/chat",
        data={"audio": "hello", "pad": "x"},
        files={"unused": ("a", b"b")},
        headers=bearer(fatima),
    )
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_text"


def test_broken_multipart_is_invalid_text_and_not_a_400(api, fatima):
    visit_id = start_visit(api, fatima)
    response = api.post(
        f"/api/visits/{visit_id}/chat",
        content=b"no boundary",
        headers={**bearer(fatima), "Content-Type": "multipart/form-data"},
    )
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_text"


def test_a_chat_past_intake_is_refused(api, fatima):
    visit_id = _arrived(api, fatima)
    response = _post(api, fatima, f"/api/visits/{visit_id}/chat", {"text": "hello"})
    assert response.status_code == 409
    assert response.json()["error"] == "visit_not_in_intake"


def test_the_chat_needs_the_owner_before_any_body_is_read(api, ravi, fatima):
    visit_id = start_visit(api, fatima)
    assert api.post(f"/api/visits/{visit_id}/chat", content=b"{").status_code == 401
    response = _raw_chat(api, ravi, visit_id, b"{")
    assert response.status_code == 403


# Voice


def test_chat_by_voice(api, fatima, asr_client, conn):
    visit_id = start_visit(api, fatima)
    response = _chat_audio(api, fatima, visit_id)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["transcript"] == TRANSCRIPT
    assert asr_client.calls == [WAV_BYTES]
    messages = _state(api, fatima, visit_id)["chat"]["messages"]
    assert messages[1]["content"] == TRANSCRIPT


def test_a_red_flag_by_voice(api, ravi, conn):
    client = FakeAsrClient(RAVI_TEXT)
    api.app.state.ai = runtime.build_runtime(asr_client=client)
    visit_id = start_visit(api, ravi)
    body = _chat_audio(api, ravi, visit_id).json()
    assert body["emergency"] is True
    assert body["status"] == "redirected_emergency"
    assert body["nearest_ed"]["id"]
    assert _tickets(conn, visit_id) == []


def _files_under(root):
    return {
        os.path.join(folder, name) for folder, _, names in os.walk(root) for name in names
    }


def _assert_no_audio_stored(root, audio):
    for path in _files_under(root):
        assert audio not in Path(path).read_bytes(), path


MARKED_AUDIO = WAV_BYTES + b"DAWRI-AUDIO-MARKER" * 200


def test_voice_leaves_nothing_on_disk(api, fatima, asr_client, db_path):
    visit_id = start_visit(api, fatima)
    assert _chat_audio(api, fatima, visit_id, MARKED_AUDIO).status_code == 200
    assert api.post(
        "/api/asr",
        files={"audio": ("clip.wav", MARKED_AUDIO, "audio/wav")},
        headers=bearer(fatima),
    ).status_code == 200
    _assert_no_audio_stored(db_path.parent, b"DAWRI-AUDIO-MARKER")


@pytest.mark.parametrize("path", ["chat", "asr"])
def test_a_long_recording_never_spills_to_a_temp_file(api, fatima, asr_client, monkeypatch, path):
    def spilled(self):
        raise AssertionError("audio reached a temp file")

    monkeypatch.setattr(tempfile.SpooledTemporaryFile, "rollover", spilled)
    url = "/api/asr" if path == "asr" else f"/api/visits/{start_visit(api, fatima)}/chat"
    audio = WAV_BYTES + b"\x00" * (LIMIT - len(WAV_BYTES))
    response = api.post(
        url, files={"audio": ("clip.wav", audio, "audio/wav")}, headers=bearer(fatima)
    )
    assert response.status_code == 200, response.text
    assert asr_client.calls == [audio]


def test_audio_at_the_limit_is_taken_and_past_it_is_refused(api, fatima, asr_client):
    visit_id = start_visit(api, fatima)
    audio = WAV_BYTES + b"\x00" * (LIMIT + 1 - len(WAV_BYTES))
    response = _chat_audio(api, fatima, visit_id, audio)
    assert response.status_code == 413
    assert response.json()["error"] == "audio_too_large"
    assert asr_client.calls == []
    assert _chat_audio(api, fatima, visit_id, audio[:-1]).status_code == 200


def test_a_huge_body_is_refused_with_the_audio_error(api, fatima, asr_client):
    visit_id = start_visit(api, fatima)
    response = _chat_audio(api, fatima, visit_id, b"\x00" * (LIMIT + 1024 * 1024))
    assert response.status_code == 413
    assert response.json()["error"] == "audio_too_large"


def test_chat_audio_in_simulated_mode(api, fatima, conn):
    visit_id = start_visit(api, fatima)
    response = _chat_audio(api, fatima, visit_id)
    assert response.status_code == 503
    assert response.json()["error"] == "asr_unavailable"
    assert conn.execute("SELECT COUNT(*) FROM intake").fetchone()[0] == 0


def test_asr_route(api, fatima, asr_client):
    response = api.post(
        "/api/asr", files={"audio": ("clip.wav", WAV_BYTES, "audio/wav")}, headers=bearer(fatima)
    )
    assert response.status_code == 200
    assert response.json() == {"text": TRANSCRIPT}
    assert asr_client.calls == [WAV_BYTES]


def test_asr_in_simulated_mode_never_invents_a_transcript(api, fatima, db_path):
    response = api.post(
        "/api/asr", files={"audio": ("clip.wav", WAV_BYTES, "audio/wav")}, headers=bearer(fatima)
    )
    assert response.status_code == 503
    assert response.json() == {
        "error": "asr_unavailable",
        "message": ASR_UNAVAILABLE_EN,
        "message_ar": ASR_UNAVAILABLE_AR,
    }
    _assert_no_audio_stored(db_path.parent, WAV_BYTES)


def test_asr_size_limit(api, fatima, asr_client):
    audio = WAV_BYTES + b"\x00" * (LIMIT + 1 - len(WAV_BYTES))
    response = api.post(
        "/api/asr", files={"audio": ("clip.wav", audio, "audio/wav")}, headers=bearer(fatima)
    )
    assert response.status_code == 413
    assert response.json()["error"] == "audio_too_large"
    assert asr_client.calls == []


def test_asr_bad_audio(api, fatima, asr_client):
    response = api.post(
        "/api/asr", files={"audio": ("clip.wav", b"not a wav", "audio/wav")}, headers=bearer(fatima)
    )
    assert response.status_code == 400
    assert response.json()["error"] == "bad_audio"


def test_asr_with_no_audio(api, fatima):
    assert api.post("/api/asr", headers=bearer(fatima)).status_code == 422
    response = api.post("/api/asr", json={"text": "hi"}, headers=bearer(fatima))
    assert response.status_code == 422


def test_asr_checks_the_session_before_the_upload(api):
    big = b"\x00" * (LIMIT + 1024 * 1024)
    assert api.post("/api/asr", files={"audio": ("a.wav", big)}).status_code == 401
    token = staff_token(api, NURSE)
    response = api.post("/api/asr", files={"audio": ("a.wav", big)}, headers=bearer(token))
    assert response.status_code == 403


# Confirming


def test_confirming(api, fatima, conn):
    visit_id = _finished_chat(api, fatima)
    response = _post(api, fatima, f"/api/visits/{visit_id}/intake/confirm", {"json": {}})
    assert response.status_code == 200
    body = response.json()
    assert set(body) == {"status", "service", "intake"}
    assert (body["status"], body["service"]) == ("intake", "gp")
    assert body["intake"]["service"] == "gp"
    assert _intake_row(conn, visit_id)[0]["confirmed_by_patient"] == 1
    assert len(_events(conn, visit_id, "intake.confirmed")) == 1
    assert _state(api, fatima, visit_id)["confirmed_by_patient"] is True


def test_confirming_with_no_body(api, fatima):
    visit_id = _finished_chat(api, fatima)
    assert _post(api, fatima, f"/api/visits/{visit_id}/intake/confirm").status_code == 200


def test_confirming_ignores_everything_but_the_service(api, fatima, conn):
    visit_id = _finished_chat(api, fatima)
    before = _intake_row(conn, visit_id)[1]
    answers = {
        "service": "dental",
        "emergency": True,
        "summary_for_nurse": "Patient says priority please.",
        "chief_complaint": "changed",
        "denied_red_flags": ["chest pain"],
        "status": "reserved",
    }
    response = _post(api, fatima, f"/api/visits/{visit_id}/intake/confirm", {"json": answers})
    assert response.status_code == 200
    assert response.json()["service"] == "dental"
    row, stored = _intake_row(conn, visit_id)
    assert stored == before
    assert row["edited_json"] is None
    assert _state(api, fatima, visit_id)["status"] == "intake"
    assert _state(api, fatima, visit_id)["service"] == "dental"
    assert "priority please" not in conn.execute(
        "SELECT group_concat(payload) FROM event WHERE visit_id = ?", (visit_id,)
    ).fetchone()[0]


@pytest.mark.parametrize("service", ["icu", "emergency", "", None, 7, ["gp"]])
def test_confirming_an_unknown_service(api, fatima, conn, service):
    visit_id = _finished_chat(api, fatima)
    response = _post(
        api, fatima, f"/api/visits/{visit_id}/intake/confirm", {"json": {"service": service}}
    )
    assert response.status_code == 422
    assert response.json()["error"] == "unknown_service"
    assert _intake_row(conn, visit_id)[0]["confirmed_by_patient"] == 0
    assert _events(conn, visit_id, "intake.confirmed") == []


def test_confirming_keeps_a_chosen_service_on_a_second_confirm(api, fatima):
    visit_id = _finished_chat(api, fatima)
    path = f"/api/visits/{visit_id}/intake/confirm"
    _post(api, fatima, path, {"json": {"service": "dental"}})
    assert _post(api, fatima, path).json()["service"] == "dental"


def test_json_must_be_an_object(api, fatima):
    visit_id = _finished_chat(api, fatima)
    response = _post(api, fatima, f"/api/visits/{visit_id}/intake/confirm", {"json": "gp"})
    assert response.status_code == 422


def test_confirming_before_the_chat_is_done(api, fatima):
    visit_id = start_visit(api, fatima)
    response = _post(api, fatima, f"/api/visits/{visit_id}/intake/confirm")
    assert response.status_code == 409
    assert response.json()["error"] == "no_intake"
    say(api, fatima, visit_id, FATIMA_ANSWERS[0])
    response = _post(api, fatima, f"/api/visits/{visit_id}/intake/confirm")
    assert response.json()["error"] == "no_intake"


def test_an_emergency_cannot_be_confirmed(api, ravi, conn):
    visit_id = start_visit(api, ravi)
    say(api, ravi, visit_id, RAVI_TEXT)
    response = _post(api, ravi, f"/api/visits/{visit_id}/intake/confirm")
    assert response.status_code == 409
    assert response.json()["error"] == "visit_not_in_intake"


def test_a_finished_chat_that_turns_into_an_emergency_cannot_be_confirmed(api, fatima):
    visit_id = _finished_chat(api, fatima)
    say(api, fatima, visit_id, "Now I have chest pain.")
    response = _post(api, fatima, f"/api/visits/{visit_id}/intake/confirm")
    assert response.status_code == 409
    assert response.json()["error"] == "visit_not_in_intake"


def test_a_stranger_cannot_confirm(api, fatima, ravi):
    visit_id = _finished_chat(api, fatima)
    assert _post(api, ravi, f"/api/visits/{visit_id}/intake/confirm").status_code == 403


# Refill


def _deflected(api, token):
    visit_id = start_visit(api, token)
    body = say(api, token, visit_id, AHMED_TEXT)
    assert body["status"] == "deflected_refill"
    return visit_id, body


def test_ahmed_is_offered_the_refill_route(api, ahmed, conn):
    visit_id, body = _deflected(api, ahmed)
    assert body["refill"]["medicine"] == "amlodipine 5 mg once daily"
    assert _state(api, ahmed, visit_id)["stage"] == "refill"
    assert _tickets(conn, visit_id) == []


def test_a_deflected_visit_cannot_reserve(api, ahmed, conn):
    visit_id, _ = _deflected(api, ahmed)
    response = _post(api, ahmed, f"/api/visits/{visit_id}/reserve", {"centre_id": "C-RAYYAN"})
    assert response.status_code == 409
    assert _tickets(conn, visit_id) == []


def test_still_wanting_a_visit_goes_straight_to_the_map_as_gp(api, ahmed, conn):
    visit_id, _ = _deflected(api, ahmed)
    response = _post(api, ahmed, f"/api/visits/{visit_id}/refill/continue")
    assert response.status_code == 200
    body = response.json()
    assert (body["status"], body["service"]) == ("intake", "gp")
    _assert_patient_safe(conn, visit_id, response)
    assert _intake_row(conn, visit_id)[0]["confirmed_by_patient"] == 1
    assert len(_events(conn, visit_id, "refill.declined")) == 1
    assert len(_events(conn, visit_id, "intake.confirmed")) == 1
    response = _post(api, ahmed, f"/api/visits/{visit_id}/reserve", {"centre_id": "C-RAYYAN"})
    assert response.status_code == 200
    assert response.json()["ticket"]["number"] is None


def test_continue_needs_a_deflected_visit(api, fatima):
    visit_id = start_visit(api, fatima)
    response = _post(api, fatima, f"/api/visits/{visit_id}/refill/continue")
    assert response.status_code == 409
    assert response.json()["error"] == "visit_not_deflected"


def test_a_red_flag_on_the_refill_screen_stops_continue(api, ahmed, conn):
    visit_id, _ = _deflected(api, ahmed)
    assert say(api, ahmed, visit_id, "I have chest pain.")["emergency"] is True
    assert _post(api, ahmed, f"/api/visits/{visit_id}/refill/continue").status_code == 409
    assert _tickets(conn, visit_id) == []


# Emergency


def test_chest_pain_means_no_ticket(api, ravi, conn):
    visit_id = start_visit(api, ravi)
    body = say(api, ravi, visit_id, RAVI_TEXT)
    assert body["emergency"] is True
    assert body["status"] == "redirected_emergency"
    assert body["nearest_ed"]["id"] in {"H-HGH", "H-WAKRA"}
    assert set(body["nearest_ed"]) == {"id", "name_en", "name_ar", "lat", "lng", "distance_km"}
    assert _tickets(conn, visit_id) == []


def test_the_emergency_card_in_the_full_state(api, ravi):
    visit_id = start_visit(api, ravi)
    reply = say(api, ravi, visit_id, RAVI_TEXT)["reply"]
    state = _state(api, ravi, visit_id)
    assert state["stage"] == "emergency"
    assert state["ticket"] is None
    assert state["emergency"]["reply"] == reply
    assert state["emergency"]["self_harm"] is False
    assert state["emergency"]["nearest_ed"]["distance_km"] > 0


def test_the_nearest_ed_is_from_the_registered_centre(api, fatima):
    visit_id = start_visit(api, fatima)
    assert say(api, fatima, visit_id, "I have chest pain.")["nearest_ed"]["id"] == "H-WAKRA"


def test_self_harm_keeps_the_supportive_line(api, ravi):
    visit_id = start_visit(api, ravi)
    body = say(api, ravi, visit_id, "I want to end my life")
    assert body["self_harm"] is True
    card = _state(api, ravi, visit_id)["emergency"]
    assert card["self_harm"] is True
    assert card["reply"] == body["reply"]


def test_override_writes_an_event_and_issues_no_ticket(api, ravi, conn):
    visit_id = start_visit(api, ravi)
    say(api, ravi, visit_id, RAVI_TEXT)
    response = _post(api, ravi, f"/api/visits/{visit_id}/emergency/override")
    assert response.status_code == 200
    assert response.json() == {
        "status": "redirected_emergency",
        "ticket": None,
        "message": STAFF_ROUTE_EN,
        "message_ar": STAFF_ROUTE_AR,
    }
    assert len(_events(conn, visit_id, "emergency.override")) == 1
    assert _tickets(conn, visit_id) == []
    assert _state(api, ravi, visit_id)["status"] == "redirected_emergency"


def test_override_needs_an_emergency(api, fatima, conn):
    visit_id = start_visit(api, fatima)
    response = _post(api, fatima, f"/api/visits/{visit_id}/emergency/override")
    assert response.status_code == 409
    assert response.json()["error"] == "not_emergency"
    assert _events(conn, visit_id, "emergency.override") == []


def test_after_an_override_every_route_to_a_ticket_is_closed(api, ravi, conn):
    visit_id = start_visit(api, ravi)
    say(api, ravi, visit_id, RAVI_TEXT)
    _post(api, ravi, f"/api/visits/{visit_id}/emergency/override")
    assert (
        _post(api, ravi, f"/api/visits/{visit_id}/reserve", {"centre_id": "C-AIRPORT"}).status_code
        == 409
    )
    assert _post(api, ravi, f"/api/visits/{visit_id}/arrive", {"button": True}).status_code == 409
    assert _post(api, ravi, "/api/visits", {"consent": True}).status_code == 409
    assert _tickets(conn, visit_id) == []


def test_a_confirmed_visit_that_turns_into_an_emergency_cannot_reserve(api, fatima, conn):
    visit_id = _confirmed(api, fatima)
    say(api, fatima, visit_id, "Now I have chest pain.")
    response = _post(api, fatima, f"/api/visits/{visit_id}/reserve", {"centre_id": "C-WAKRA"})
    assert response.status_code == 409
    assert response.json()["error"] == "visit_not_eligible"
    assert _tickets(conn, visit_id) == []


def test_a_red_flag_while_reserved_releases_the_ticket(api, fatima, conn):
    visit_id = _reserved(api, fatima)
    body = say(api, fatima, visit_id, "I have chest pain.")
    assert body["emergency"] is True
    assert body["status"] == "redirected_emergency"
    assert body["nearest_ed"]["id"] == "H-WAKRA"
    assert api.app.state.engine.live_ticket(visit_id) is None
    state = _state(api, fatima, visit_id)
    assert state["ticket"] is None
    assert state["emergency"] is not None
    released = _events(conn, visit_id, "ticket.released")
    assert [json.loads(row["payload"])["reason"] for row in released] == ["emergency"]

    response = _post(api, fatima, f"/api/visits/{visit_id}/arrive", {"button": True})
    assert response.status_code == 409
    assert api.app.state.engine.live_ticket(visit_id) is None


def _emergency_turn():
    return TurnResult(
        reply="Go to emergency.",
        done=False,
        emergency=True,
        intake=None,
        refill=None,
        denied=[],
        source="rules",
        emergency_category="chest_pain",
        self_harm=False,
        language="en",
        slot=None,
    )


def test_an_emergency_landing_after_arrival_does_not_strand_the_visit(
    api, fatima, conn, monkeypatch
):
    """The patient reserved and arrived while the model was still thinking."""
    visit_id = _reserved(api, fatima)
    engine = api.app.state.engine

    def arrives_while_thinking(*args):
        engine.activate(engine.live_ticket(visit_id).id)
        return _emergency_turn()

    monkeypatch.setattr(session, "handle_message", arrives_while_thinking)
    body = say(api, fatima, visit_id, "anything")
    assert body["status"] == "redirected_emergency"
    assert api.app.state.engine.live_ticket(visit_id) is None


def test_a_ticket_that_lapses_during_the_release_still_shows_the_emergency(
    api, fatima, monkeypatch
):
    visit_id = _reserved(api, fatima)

    def lapsed(ticket_id, reason):
        raise InvalidTransition("cannot release a released ticket")

    monkeypatch.setattr(api.app.state.engine, "escalate", lapsed)
    assert say(api, fatima, visit_id, "I have chest pain.")["emergency"] is True


def test_a_second_red_flag_changes_nothing(api, ravi, conn):
    visit_id = start_visit(api, ravi)
    first = say(api, ravi, visit_id, RAVI_TEXT)
    second = say(api, ravi, visit_id, "hello")
    assert second["emergency"] is True
    assert second["reply"] == first["reply"]


# What a patient may read


def test_no_patient_response_holds_staff_text(api, fatima, ahmed, ravi, conn):
    visit_id = start_visit(api, fatima)
    chats = [
        _post(api, fatima, f"/api/visits/{visit_id}/chat", {"text": text})
        for text in FATIMA_ANSWERS
    ]
    assert chats[-1].json()["done"] is True
    responses = [
        *chats,
        api.get(f"/api/visits/{visit_id}", headers=bearer(fatima)),
        _post(api, fatima, f"/api/visits/{visit_id}/intake/confirm"),
        _post(api, fatima, f"/api/visits/{visit_id}/reserve", {"centre_id": "C-WAKRA"}),
        api.get(f"/api/visits/{visit_id}", headers=bearer(fatima)),
        _post(api, fatima, f"/api/visits/{visit_id}/arrive", {"button": True}),
        api.get(f"/api/visits/{visit_id}", headers=bearer(fatima)),
        api.get("/api/visits", headers=bearer(fatima)),
        api.get("/api/centres", params={"visit_id": visit_id}, headers=bearer(fatima)),
    ]
    for response in responses:
        assert response.status_code == 200, response.text
        _assert_patient_safe(conn, visit_id, response)


def test_a_nurse_edit_stays_staff_text(api, fatima, conn):
    visit_id = _finished_chat(api, fatima)
    edited = dict(_intake_row(conn, visit_id)[1], summary_for_nurse="NURSE-ONLY-EDIT")
    conn.execute(
        "UPDATE intake SET edited_json = ? WHERE visit_id = ?", (db.dumps(edited), visit_id)
    )
    response = api.get(f"/api/visits/{visit_id}", headers=bearer(fatima))
    assert "NURSE-ONLY-EDIT" not in response.text


def test_the_routes_never_read_the_staff_view():
    source = Path(visits.__file__).read_text(encoding="utf-8")
    assert "staff_view" not in source
    assert "summary_for_nurse" not in source


# The threadpool rule


@pytest.mark.parametrize("module", [visits, centres_router], ids=["visits", "centres"])
def test_every_route_is_plain_def(module):
    for route in module.router.routes:
        assert not inspect.iscoroutinefunction(route.endpoint), route.path
