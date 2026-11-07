"""Visit and display streams on a real server, and the display snapshot."""

from __future__ import annotations

import json
import sqlite3
import time
from types import SimpleNamespace

import pytest

from backend import db, events
from backend.main import app
from backend.routers import streams
from backend.tests.api_helpers import (
    FATIMA_QID,
    NURSE,
    RAVI_QID,
    bearer,
    open_stream,
    patient_token,
    staff_token,
)
from backend.tests.conftest import make_visit
from backend.tests.test_api_staff import arrived

T1 = "C-WAKRA-T1"
OTHER_NURSE = "S-RAY-NURSE1"


@pytest.fixture
def conn(live_api):
    connection = db.connect()
    yield connection
    connection.close()


def _at_wakra(conn, patient_id="P001", booked_by=None):
    visit_id = make_visit(conn, patient_id, booked_by=booked_by)
    conn.execute("UPDATE visit SET centre_id = 'C-WAKRA' WHERE id = ?", (visit_id,))
    return visit_id


def _stream_status(live, path, token=None, headers=None):
    """The status of a stream, leaving it the moment the head arrives."""
    params = {} if token is None else {"token": token}
    with live.http.stream("GET", path, params=params, headers=headers) as response:
        return response.status_code


def _events(lines):
    return [json.loads(line[len("data: "):]) for line in lines if line.startswith("data: ")]


def _walk(value):
    """Every key and every string in a JSON value."""
    if isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from _walk(item)
    elif isinstance(value, list):
        for item in value:
            yield from _walk(item)
    elif isinstance(value, str):
        yield value


# Visit stream


def test_visit_stream_needs_a_token(live_api, conn):
    visit_id = make_visit(conn, "P001")
    assert live_api.http.get(f"/api/visits/{visit_id}/stream").status_code == 401


def test_visit_stream_rejects_a_bad_token(live_api, conn):
    visit_id = make_visit(conn, "P001")
    response = live_api.http.get(f"/api/visits/{visit_id}/stream", params={"token": "nope"})
    assert response.status_code == 401


def test_visit_stream_unknown_visit(live_api):
    token = patient_token(live_api.http, FATIMA_QID)
    response = live_api.http.get("/api/visits/V-NOPE/stream", params={"token": token})
    assert response.status_code == 404
    assert response.json()["error"] == "visit_not_found"


def test_visit_stream_unknown_visit_with_no_token_is_401_first(live_api):
    assert live_api.http.get("/api/visits/V-NOPE/stream").status_code == 401


@pytest.mark.parametrize(
    ("patient_id", "booked_by", "qid", "status"),
    [
        ("P001", None, FATIMA_QID, 200),  # The patient.
        ("P004", None, FATIMA_QID, 200),  # The guardian of a dependent.
        ("P002", "P003", RAVI_QID, 200),  # Whoever booked it.
        ("P001", None, RAVI_QID, 403),  # Another patient.
        ("P004", None, RAVI_QID, 403),  # Not this child's guardian.
    ],
    ids=["patient", "guardian", "booked_by", "other patient", "other guardian"],
)
def test_visit_stream_for_patients(live_api, conn, patient_id, booked_by, qid, status):
    visit_id = _at_wakra(conn, patient_id, booked_by)
    token = patient_token(live_api.http, qid)
    assert _stream_status(live_api, f"/api/visits/{visit_id}/stream", token) == status


def test_visit_stream_for_staff(live_api, conn):
    visit_id = _at_wakra(conn)
    path = f"/api/visits/{visit_id}/stream"
    assert _stream_status(live_api, path, staff_token(live_api.http, NURSE)) == 200
    assert _stream_status(live_api, path, staff_token(live_api.http, OTHER_NURSE)) == 403


def test_visit_stream_refuses_staff_before_the_visit_has_a_centre(live_api, conn):
    visit_id = make_visit(conn, "P001")
    token = staff_token(live_api.http, NURSE)
    assert _stream_status(live_api, f"/api/visits/{visit_id}/stream", token) == 403


def test_visit_stream_accepts_the_header(live_api, conn):
    visit_id = _at_wakra(conn)
    token = patient_token(live_api.http, FATIMA_QID)
    path = f"/api/visits/{visit_id}/stream"
    assert _stream_status(live_api, path, headers=bearer(token)) == 200


def test_visit_stream_delivers_the_called_event(live_api, conn):
    visit_id = make_visit(conn, "P001")
    token = patient_token(live_api.http, FATIMA_QID)
    engine = app.state.engine
    path = f"/api/visits/{visit_id}/stream"
    with open_stream(live_api, path, token) as stream:
        head = stream.until(": connected")
        assert head[0] == "status 200"
        engine.activate(engine.issue_ticket(visit_id, T1).id)
        engine.call_next(T1)
        seen = stream.until("ticket.called")
    called = _events(seen)[-1]
    assert list(called) == ["type", "visit_id", "ticket", "counter", "people_ahead"]
    assert called == {
        "type": "ticket.called",
        "visit_id": visit_id,
        "ticket": "T-014",
        "counter": "Triage 1",
        "people_ahead": 0,
    }


def test_visit_stream_only_carries_its_own_visit(live_api, conn):
    mine = make_visit(conn, "P001")
    other = make_visit(conn, "P003")
    token = patient_token(live_api.http, FATIMA_QID)
    engine = app.state.engine
    with open_stream(live_api, f"/api/visits/{mine}/stream", token) as stream:
        stream.until(": connected")
        engine.issue_active(other, "C-AIRPORT-T1")
        engine.issue_active(mine, T1)
        seen = stream.until("ticket.activated")
    assert [event["visit_id"] for event in _events(seen)] == [mine]


def test_a_stream_holds_no_database_connection(live_api, conn, monkeypatch):
    opened = []
    real_connect = db.connect

    def tracked(*args, **kwargs):
        connection = real_connect(*args, **kwargs)
        opened.append(connection)
        return connection

    token = patient_token(live_api.http, FATIMA_QID)
    visit_id = make_visit(conn, "P001")
    monkeypatch.setattr(db, "connect", tracked)
    path = f"/api/visits/{visit_id}/stream"
    with open_stream(live_api, path, token) as stream:
        stream.until(": connected")
        assert opened
        for connection in opened:
            with pytest.raises(sqlite3.ProgrammingError):
                connection.execute("SELECT 1")


def test_heartbeat_uses_the_module_value(live_api, conn, monkeypatch):
    monkeypatch.setattr(streams, "HEARTBEAT_SEC", 0.05)
    visit_id = make_visit(conn, "P001")
    token = patient_token(live_api.http, FATIMA_QID)
    path = f"/api/visits/{visit_id}/stream"
    with open_stream(live_api, path, token) as stream:
        stream.until(": connected")
        stream.until(": heartbeat", timeout=3)


def test_heartbeat_default():
    assert streams.HEARTBEAT_SEC == 15.0


def test_a_closed_stream_drops_its_subscription(live_api, conn):
    visit_id = make_visit(conn, "P001")
    token = patient_token(live_api.http, FATIMA_QID)
    path = f"/api/visits/{visit_id}/stream"
    with open_stream(live_api, path, token) as stream:
        stream.until(": connected")
        assert events.visit_channel(visit_id) in events.bus._subs
    deadline = time.monotonic() + 2
    while events.visit_channel(visit_id) in events.bus._subs and time.monotonic() < deadline:
        time.sleep(0.01)
    assert events.visit_channel(visit_id) not in events.bus._subs


def test_a_nurse_edit_reaches_a_second_tab_on_the_visit_stream(live_api):
    api = live_api.http
    visit_id = arrived(SimpleNamespace(app=app))
    token = staff_token(api, NURSE)
    with open_stream(live_api, f"/api/visits/{visit_id}/stream", token) as stream:
        stream.until(": connected")
        response = api.put(
            f"/api/visits/{visit_id}/intake",
            json={"json": {"chief_complaint": "dry cough"}},
            headers=bearer(token),
        )
        assert response.status_code == 200, response.text
        line = stream.until("intake.edited", timeout=2)[-1]
    assert json.loads(line.removeprefix("data: ")) == {"type": "intake.edited"}


def test_a_refused_edit_publishes_nothing(api, monkeypatch):
    visit_id = arrived(api)
    published = []
    monkeypatch.setattr(events.bus, "publish", lambda *event: published.append(event))
    response = api.put(
        f"/api/visits/{visit_id}/intake",
        json={"json": {"chief_complaint": ""}},
        headers=bearer(staff_token(api, NURSE)),
    )
    assert response.status_code == 422
    assert published == []


# Display stream


DISPLAY_STREAM = "/api/display/C-WAKRA/stream"


def test_display_stream_needs_a_token(live_api):
    assert live_api.http.get(DISPLAY_STREAM).status_code == 401


def test_display_stream_rejects_a_patient(live_api):
    token = patient_token(live_api.http, FATIMA_QID)
    assert live_api.http.get(DISPLAY_STREAM, params={"token": token}).status_code == 403


def test_display_stream_rejects_staff_of_another_centre(live_api):
    token = staff_token(live_api.http, OTHER_NURSE)
    response = live_api.http.get(DISPLAY_STREAM, params={"token": token})
    assert response.status_code == 403
    assert response.json()["error"] == "wrong_centre"


def test_display_stream_unknown_centre(live_api):
    token = staff_token(live_api.http, NURSE)
    response = live_api.http.get("/api/display/C-NOPE/stream", params={"token": token})
    assert response.status_code == 404


def test_display_stream_accepts_a_query_token_and_the_header(live_api):
    token = staff_token(live_api.http, NURSE)
    assert _stream_status(live_api, DISPLAY_STREAM, token) == 200
    assert _stream_status(live_api, DISPLAY_STREAM, headers=bearer(token)) == 200


def test_display_event_has_no_visit_id(live_api, conn):
    visit_id = make_visit(conn, "P001")
    token = staff_token(live_api.http, NURSE)
    engine = app.state.engine
    with open_stream(live_api, DISPLAY_STREAM, token) as stream:
        head = stream.until(": connected")
        assert head[0] == "status 200"
        engine.activate(engine.issue_ticket(visit_id, T1).id)
        engine.call_next(T1)
        seen = stream.until("ticket.called")
    called = _events(seen)[-1]
    assert called == {
        "type": "ticket.called",
        "ticket": "T-014",
        "counter": "Triage 1",
        "people_ahead": 0,
    }
    for line in seen:
        assert "visit_id" not in line
        assert visit_id not in line


# Display snapshot


DISPLAY = "/api/display/C-WAKRA"


def test_display_snapshot_auth(live_api):
    http = live_api.http
    assert http.get(DISPLAY).status_code == 401
    assert http.get(DISPLAY, params={"token": "nope"}).status_code == 401
    patient = patient_token(http, FATIMA_QID)
    assert http.get(DISPLAY, params={"token": patient}).status_code == 403
    other = staff_token(http, OTHER_NURSE)
    assert http.get(DISPLAY, params={"token": other}).status_code == 403
    nurse = staff_token(http, NURSE)
    assert http.get(DISPLAY, params={"token": nurse}).status_code == 200
    assert http.get(DISPLAY, headers=bearer(nurse)).status_code == 200
    assert http.get("/api/display/C-NOPE", params={"token": nurse}).status_code == 404


def test_display_snapshot_shape(live_api, conn):
    token = staff_token(live_api.http, NURSE)
    visit_id = make_visit(conn, "P001")
    engine = app.state.engine
    engine.issue_active(visit_id, T1)

    body = live_api.http.get(DISPLAY, params={"token": token}).json()

    assert set(body) == {"centre", "counters"}
    assert body["centre"] == {
        "id": "C-WAKRA",
        "name_en": "Al Wakra Health Centre",
        "name_ar": "مركز الوكرة الصحي",
    }
    counters = {counter["id"]: counter for counter in body["counters"]}
    assert set(counters[T1]) == {"id", "label", "label_ar", "stage", "now_serving", "waiting"}
    assert counters[T1]["label"] == "Triage 1"
    assert counters[T1]["stage"] == "triage"
    assert counters[T1]["now_serving"] is None
    assert counters[T1]["waiting"] == 4  # Three simulated numbers and the patient.


def test_display_snapshot_shows_who_is_at_the_counter(live_api, conn):
    token = staff_token(live_api.http, NURSE)
    engine = app.state.engine
    ticket = engine.issue_active(make_visit(conn, "P001"), T1)

    def t1():
        body = live_api.http.get(DISPLAY, params={"token": token}).json()
        return next(counter for counter in body["counters"] if counter["id"] == T1)

    engine.call_next(T1)
    assert t1()["now_serving"] == "T-014"
    assert t1()["waiting"] == 0
    engine.serve(ticket.id)
    assert t1()["now_serving"] == "T-014"
    engine.complete(ticket.id)
    assert t1()["now_serving"] is None


def test_display_snapshot_has_no_visit_id_or_names(live_api, conn):
    token = staff_token(live_api.http, NURSE)
    visit_id = make_visit(conn, "P001")
    app.state.engine.issue_active(visit_id, T1)
    app.state.engine.call_next(T1)

    response = live_api.http.get(DISPLAY, params={"token": token})

    assert visit_id not in response.text
    found = set(_walk(response.json()))
    assert "visit_id" not in found
    for name in conn.execute("SELECT full_name_en, full_name_ar FROM patient").fetchall():
        assert name["full_name_en"] not in response.text
        assert name["full_name_ar"] not in response.text
    for staff in conn.execute("SELECT name FROM staff").fetchall():
        assert staff["name"] not in response.text
