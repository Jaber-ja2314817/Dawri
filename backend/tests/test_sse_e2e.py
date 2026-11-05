"""A real uvicorn server: TestClient hangs on an infinite stream."""

from __future__ import annotations

import json
import queue
import socket
import sqlite3
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass

import httpx
import pytest
import uvicorn

from backend import db, events
from backend.main import app
from backend.tests.conftest import make_visit

T1 = "C-WAKRA-T1"
EVENT_KEYS = ["type", "visit_id", "ticket", "counter", "people_ahead"]


@dataclass
class Live:
    base_url: str
    http: httpx.Client

    def staff_token(self, staff_id="S-WAK-NURSE1"):
        response = self.http.post("/api/staff/login", json={"staff_id": staff_id})
        assert response.status_code == 200
        return response.json()["token"]

    def stream_url(self, counter_id=T1):
        return f"/api/counters/{counter_id}/stream"


def _stop(server, thread):
    server.should_exit = True
    thread.join(timeout=3)
    if thread.is_alive():  # A stream left open by a failed test blocks a clean exit.
        server.force_exit = True
        thread.join(timeout=3)


@pytest.fixture
def live(db_path, monkeypatch):
    monkeypatch.setattr("backend.main.load_dotenv", lambda: None)
    monkeypatch.setenv("SIMULATE_LOAD", "1")
    threads_before = set(threading.enumerate())

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(app, log_level="warning"))
    thread = threading.Thread(target=server.run, kwargs={"sockets": [sock]}, daemon=True)
    thread.start()
    deadline = time.monotonic() + 5
    while not server.started and thread.is_alive() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert server.started

    base_url = f"http://127.0.0.1:{port}"
    with httpx.Client(base_url=base_url, trust_env=False, timeout=5) as http:
        yield Live(base_url, http)

    _stop(server, thread)
    sock.close()
    assert not thread.is_alive()
    deadline = time.monotonic() + 2
    while set(threading.enumerate()) - threads_before and time.monotonic() < deadline:
        time.sleep(0.01)
    assert not set(threading.enumerate()) - threads_before


@contextmanager
def open_stream(live, token):
    """Read the stream in a thread until ticket.called; yields the line queue."""
    lines: queue.Queue[str] = queue.Queue()
    url = f"{live.base_url}{live.stream_url()}"

    def read():
        timeout = httpx.Timeout(5, read=5)
        try:
            with httpx.stream(
                "GET", url, params={"token": token}, timeout=timeout, trust_env=False
            ) as response:
                lines.put(f"status {response.status_code}")
                lines.put(f"type {response.headers['content-type']}")
                for line in response.iter_lines():
                    lines.put(line)
                    if '"ticket.called"' in line:
                        return
        except httpx.TimeoutException:
            lines.put("timeout")

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    try:
        yield lines
    finally:
        reader.join(timeout=6)
        assert not reader.is_alive()


def read_until(lines, wanted, timeout=5.0):
    """Lines up to and including the first one containing `wanted`."""
    seen = []
    deadline = time.monotonic() + timeout
    while True:
        line = lines.get(timeout=max(deadline - time.monotonic(), 0.01))
        seen.append(line)
        if wanted in line:
            return seen


def test_ticket_called_reaches_a_real_stream(live, monkeypatch):
    connections = []
    real_connect = db.connect

    def tracked(*args, **kwargs):
        conn = real_connect(*args, **kwargs)
        connections.append(conn)
        return conn

    monkeypatch.setattr(db, "connect", tracked)
    token = live.staff_token()
    connections.clear()
    conn = real_connect()
    visit_id = make_visit(conn, "P001")
    conn.close()
    engine = app.state.engine

    with open_stream(live, token) as lines:
        head = read_until(lines, ": connected")
        assert head[0] == "status 200"
        assert head[1].startswith("type text/event-stream")

        # The stream is up, and the request's connections are already closed.
        assert connections
        for opened in connections:
            with pytest.raises(sqlite3.ProgrammingError):
                opened.execute("SELECT 1")

        ticket = engine.activate(engine.issue_ticket(visit_id, T1).id)
        result = engine.call_next(T1)
        assert result.called.id == ticket.id
        assert len(result.auto_completed) == 3

        seen = read_until(lines, "ticket.called")

    data = [json.loads(line[len("data: "):]) for line in seen if line.startswith("data: ")]
    called = data[-1]
    assert list(called) == EVENT_KEYS
    assert called == {
        "type": "ticket.called",
        "visit_id": visit_id,
        "ticket": "T-014",
        "counter": "Triage 1",
        "people_ahead": 0,
    }
    # Simulated tickets finish silently: they are never announced as called.
    assert [event["type"] for event in data] == [
        "ticket.reserved",
        "ticket.activated",
        "ticket.simulated_done",
        "ticket.simulated_done",
        "ticket.simulated_done",
        "ticket.called",
    ]

    # The client went away, so the server must drop its subscription.
    channel = events.counter_channel(T1)
    deadline = time.monotonic() + 2
    while channel in events.bus._subs and time.monotonic() < deadline:
        time.sleep(0.01)
    assert channel not in events.bus._subs


def test_stream_needs_a_token(live):
    assert live.http.get(live.stream_url()).status_code == 401


def test_stream_rejects_an_unknown_token(live):
    response = live.http.get(live.stream_url(), params={"token": "nope"})
    assert response.status_code == 401


def test_stream_rejects_staff_of_another_centre(live):
    token = live.staff_token("S-RAY-NURSE1")
    response = live.http.get(live.stream_url(), params={"token": token})
    assert response.status_code == 403
    assert response.json()["error"] == "wrong_centre"


def test_stream_rejects_a_patient_token(live):
    token = live.http.post(
        "/api/auth/verify", json={"qid": "DEMO-10001", "otp": "0000"}
    ).json()["token"]
    response = live.http.get(live.stream_url(), params={"token": token})
    assert response.status_code == 403


def test_stream_unknown_counter(live):
    token = live.staff_token()
    response = live.http.get(live.stream_url("C-NOPE"), params={"token": token})
    assert response.status_code == 404
    assert response.json()["error"] == "unknown_counter"


def test_stream_accepts_the_header_too(live):
    token = live.staff_token("S-RAY-NURSE1")
    response = live.http.get(
        live.stream_url(), headers={"Authorization": f"Bearer {token}"}
    )
    assert response.status_code == 403  # Authenticated by the header, stopped by centre.
