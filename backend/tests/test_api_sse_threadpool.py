"""AI routes must not stall the streams, and the bus must survive many threads at once.

Real uvicorn throughout: TestClient would hide what the event loop is doing.
"""

from __future__ import annotations

import inspect
import json
import threading
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from types import SimpleNamespace

import httpx
import pytest

from backend import events, main
from backend.ai import runtime
from backend.routers import streams
from backend.tests.ai_fakes import FakeAsrClient
from backend.tests.api_helpers import (
    AHMED_QID,
    DESK,
    FATIMA_ANSWERS,
    FATIMA_QID,
    NURSE,
    RAVI_QID,
    live_server,
    open_stream,
)
from backend.tests.test_api_e2e import (
    GATE_PASSING_REPLY,
    arrive,
    flat_routes,
    open_visit,
    patient,
    reserved_visit,
    staff,
)
from backend.tests.test_api_staff import SALEM_ANSWERS, T1, rows

MODEL_SEC = 1.5
HEARTBEAT_SEC = 0.2
HEALTH_LIMIT_SEC = 0.5
SALEM_QID = "DEMO-10006"
STREAM_ROUTES = {
    "/api/counters/{counter_id}/stream",
    "/api/visits/{visit_id}/stream",
    "/api/display/{centre_id}/stream",
}
BURST = 40
# Every one of these has simulated tickets, so each call-next here does real work.
BUSY_COUNTERS = {
    "C-WAKRA-T1": "S-WAK-NURSE1",
    "C-WAKRA-D3": "S-WAK-DOC1",
    "C-AIRPORT-T1": "S-AIR-NURSE1",
    "C-AIRPORT-D1": "S-AIR-DOC1",
    "C-RAYYAN-T1": "S-RAY-NURSE1",
    "C-MESAIMEER-T1": "S-MES-NURSE1",
    "C-MESAIMEER-D1": "S-MES-DOC1",
    "C-WESTBAY-T1": "S-WBY-NURSE1",
    "C-WESTBAY-D1": "S-WBY-DOC1",
}
# Who can arrive during the burst, and where, so each counter sees arrivals and calls.
ARRIVALS = (
    (FATIMA_QID, None, "C-WAKRA"),
    (FATIMA_QID, "P004", "C-AIRPORT"),
    (FATIMA_QID, "P005", "C-RAYYAN"),
    (SALEM_QID, None, "C-MESAIMEER"),
    (AHMED_QID, None, "C-WESTBAY"),
    (RAVI_QID, None, "C-AIRPORT"),
)


class SlowChatClient:
    """A model call that holds its thread, as a real one does."""

    def __init__(self, delay: float, reply: str) -> None:
        self.delay = delay
        self.reply = reply
        self.started = threading.Event()

    def chat_completion(self, messages, **kwargs) -> object:
        self.started.set()
        time.sleep(self.delay)
        message = SimpleNamespace(content=self.reply)
        return SimpleNamespace(choices=[SimpleNamespace(message=message)])


@pytest.fixture
def slow_model():
    return SlowChatClient(MODEL_SEC, GATE_PASSING_REPLY)


@pytest.fixture
def slow_live(api_env, slow_model, monkeypatch):
    built = runtime.build_runtime(llm_client=slow_model, asr_client=FakeAsrClient())
    monkeypatch.setattr(main.runtime, "build_runtime", lambda: built)
    monkeypatch.setattr(streams, "HEARTBEAT_SEC", HEARTBEAT_SEC)
    with live_server(main.app) as live:
        yield live


def subscriptions() -> int:
    return sum(len(subs) for subs in list(events.bus._subs.values()))


def events_from(lines) -> list[dict]:
    return [json.loads(line[len("data: "):]) for line in lines if line.startswith("data: ")]


def ticket_events(stream, count: int, timeout: float = 10.0) -> list[dict]:
    """Read until `count` ticket events came in. queue.changed and heartbeats do not count."""
    found: list[dict] = []
    deadline = time.monotonic() + timeout
    while len(found) < count:
        line = stream.lines.get(timeout=max(deadline - time.monotonic(), 0.01))
        for event in events_from([line]):
            if event["type"].startswith("ticket."):
                found.append(event)
    return found


# The rule itself


def test_only_the_three_stream_routes_are_coroutines():
    routes = [route for route in flat_routes() if route.path.startswith("/api")]
    assert len(routes) > 30  # A plain walk over app.routes finds one.
    coroutines = {
        route.path for route in routes if inspect.iscoroutinefunction(route.endpoint)
    }
    assert coroutines == STREAM_ROUTES


# A slow model


def test_a_slow_model_does_not_stall_sse(slow_live, slow_model):
    http = slow_live.http
    nurse = staff(http, NURSE)
    desk = staff(http, DESK)
    walked_in = desk.ok("/api/desk/walk-in", {"qid": SALEM_QID, "complaint": "Sore knee"})
    fatima = patient(http, FATIMA_QID)
    chat_visit = open_visit(fatima)

    answer = {}

    def chat() -> None:
        with httpx.Client(base_url=slow_live.base_url, trust_env=False, timeout=10) as client:
            answer["response"] = client.post(
                f"/api/visits/{chat_visit}/chat",
                json={"text": FATIMA_ANSWERS[0]},
                headers=fatima.headers,
            )

    with open_stream(
        slow_live, f"/api/visits/{walked_in['visit_id']}/stream", nurse.token
    ) as stream:
        stream.until(": connected")
        worker = threading.Thread(target=chat, daemon=True)
        worker.start()
        assert slow_model.started.wait(1.0)

        deadline = time.monotonic() + MODEL_SEC
        heartbeats = 0
        for _ in range(3):
            stream.until(": heartbeat", timeout=max(deadline - time.monotonic(), 0.01))
            heartbeats += 1
        assert heartbeats == 3
        assert worker.is_alive()

        began = time.monotonic()
        health = http.get("/api/health")
        took = time.monotonic() - began
        assert health.status_code == 200
        assert took < HEALTH_LIMIT_SEC
        assert worker.is_alive()

        call = nurse.post(f"/api/counters/{T1}/call-next")
        assert call.status_code == 200, call.text
        assert call.json()["called"]["visit_id"] == walked_in["visit_id"]
        lines = stream.until("ticket.called", timeout=max(deadline - time.monotonic(), 0.01))
        called = [event for event in events_from(lines) if event["type"] == "ticket.called"]
        assert called[0]["ticket"] == "T-014"
        assert worker.is_alive()  # All of the above happened with the model still thinking.

        worker.join(timeout=5)
        assert not worker.is_alive()

    response = answer["response"]
    assert response.status_code == 200, response.text
    assert response.json()["reply"] == GATE_PASSING_REPLY
    assert response.json()["ai_source"] == "model"


# Many threads


def _arrivals_ready(live) -> list:
    """Visits with a reservation, each ready for its arrival during the burst."""
    ready = []
    people = {}
    for qid, patient_id, centre_id in ARRIVALS:
        person = people.setdefault(qid, patient(live.http, qid))
        answers = SALEM_ANSWERS if qid == SALEM_QID else FATIMA_ANSWERS
        visit_id = reserved_visit(person, answers, patient_id, centre_id)
        ready.append((person, visit_id))
    return ready


def _burst_calls(ready: list, callers: dict) -> list:
    """Exactly BURST calls: the arrivals, then call-next round the busy counters."""
    calls = [
        (f"/api/visits/{visit_id}/arrive", person.headers, {"button": True})
        for person, visit_id in ready
    ]
    counters = list(BUSY_COUNTERS)
    while len(calls) < BURST:
        counter_id = counters[len(calls) % len(counters)]
        calls.append((f"/api/counters/{counter_id}/call-next", callers[counter_id].headers, None))
    return calls


def _send_together(base_url: str, calls: list) -> list[int]:
    barrier = threading.Barrier(len(calls))

    def send(call: tuple) -> int:
        path, headers, body = call
        with httpx.Client(base_url=base_url, trust_env=False, timeout=30) as client:
            barrier.wait(timeout=10)
            return client.post(path, json=body, headers=headers).status_code

    with ThreadPoolExecutor(max_workers=len(calls)) as pool:
        return list(pool.map(send, calls))


def test_publishing_from_many_threads_drops_nothing(live_api, monkeypatch):
    monkeypatch.setattr(streams, "HEARTBEAT_SEC", HEARTBEAT_SEC)
    http = live_api.http
    callers = {counter: staff(http, owner) for counter, owner in BUSY_COUNTERS.items()}
    ready = _arrivals_ready(live_api)
    calls = _burst_calls(ready, callers)
    assert len(calls) == BURST

    with ExitStack() as stack:
        on_counter = {
            counter: stack.enter_context(
                open_stream(live_api, f"/api/counters/{counter}/stream", callers[counter].token)
            )
            for counter in BUSY_COUNTERS
        }
        on_visit = {
            visit_id: stack.enter_context(
                open_stream(live_api, f"/api/visits/{visit_id}/stream", person.token)
            )
            for person, visit_id in ready
        }
        watcher = callers["C-WAKRA-T1"]
        on_display = stack.enter_context(
            open_stream(live_api, "/api/display/C-WAKRA/stream", watcher.token)
        )
        open_now = [*on_counter.values(), *on_visit.values(), on_display]
        for stream in open_now:
            assert stream.until(": connected")[0] == "status 200"

        last_event = rows("SELECT COALESCE(MAX(id), 0) AS id FROM event")[0]["id"]
        dropped_before = events.bus.dropped
        subscribed = subscriptions()

        statuses = _send_together(live_api.base_url, calls)

        # 409 is a colleague having called first. Nothing else is acceptable.
        assert set(statuses) <= {200, 409}, Counter(statuses)
        assert statuses[: len(ready)] == [200] * len(ready)
        assert statuses.count(200) > len(ready)

        stored = rows("SELECT * FROM event WHERE id > ? ORDER BY id", last_event)
        details = [(row, json.loads(row["payload"])) for row in stored]
        tickets_only = [
            (row, payload) for row, payload in details if row["type"].startswith("ticket.")
        ]
        assert tickets_only
        for counter, stream in on_counter.items():
            expected = [
                (row["type"], payload["number"])
                for row, payload in tickets_only
                if payload["counter_id"] == counter
            ]
            received = ticket_events(stream, len(expected))
            assert Counter((e["type"], e["ticket"]) for e in received) == Counter(expected)
        for visit_id, stream in on_visit.items():
            expected = [
                (row["type"], payload["number"])
                for row, payload in tickets_only
                if row["visit_id"] == visit_id
            ]
            received = ticket_events(stream, len(expected))
            assert Counter((e["type"], e["ticket"]) for e in received) == Counter(expected)
        at_wakra = [
            (row["type"], payload["number"])
            for row, payload in tickets_only
            if payload["counter_id"].startswith("C-WAKRA-")
        ]
        received = ticket_events(on_display, len(at_wakra))
        assert Counter((e["type"], e["ticket"]) for e in received) == Counter(at_wakra)

        assert events.bus.dropped == dropped_before
        assert subscriptions() == subscribed

        # Every stream is still open and still fed.
        for stream in open_now:
            stream.until(": heartbeat", timeout=3)
        staff(http, DESK).ok("/api/demo/reset")
        for stream in open_now:
            stream.until("demo.reset", timeout=3)
        assert events.bus.dropped == dropped_before


def test_arrivals_racing_call_next_keep_each_ticket_once(live_api):
    """The same burst shape on one counter: numbers stay unique and the order stays sound."""
    http = live_api.http
    nurse = staff(http, NURSE)
    ready = _arrivals_ready(live_api)
    calls = [
        (f"/api/visits/{visit_id}/arrive", person.headers, {"button": True})
        for person, visit_id in ready
    ]
    calls += [(f"/api/counters/{T1}/call-next", nurse.headers, None)] * 6
    statuses = _send_together(live_api.base_url, calls)
    assert set(statuses) <= {200, 409}, Counter(statuses)

    numbered = rows("SELECT number FROM ticket WHERE number IS NOT NULL")
    numbers = [row["number"] for row in numbered]
    per_centre = rows(
        "SELECT centre_id, number, COUNT(*) AS copies FROM ticket "
        "WHERE number IS NOT NULL GROUP BY centre_id, number HAVING copies > 1"
    )
    assert numbers and per_centre == []
    assert len(rows("SELECT id FROM ticket WHERE state = 'called' AND counter_id = ?", T1)) <= 1


# Leaving


def test_closing_a_stream_removes_its_subscription(live_api):
    """The default 15 s heartbeat stays on, so the server must notice without writing."""
    http = live_api.http
    fatima = patient(http, FATIMA_QID)
    nurse = staff(http, NURSE)
    visit_id = open_visit(fatima)
    before = subscriptions()

    with ExitStack() as stack:
        for path, token in (
            (f"/api/counters/{T1}/stream", nurse.token),
            ("/api/display/C-WAKRA/stream", nurse.token),
        ):
            stack.enter_context(open_stream(live_api, path, token)).until(": connected")
        with open_stream(live_api, f"/api/visits/{visit_id}/stream", fatima.token) as stream:
            stream.until(": connected")
            assert subscriptions() == before + 3
        deadline = time.monotonic() + 2
        while subscriptions() > before + 2 and time.monotonic() < deadline:
            time.sleep(0.01)
        assert subscriptions() == before + 2  # The other two are still being watched.
        assert events.visit_channel(visit_id) not in events.bus._subs

    deadline = time.monotonic() + 2
    while subscriptions() > before and time.monotonic() < deadline:
        time.sleep(0.01)
    assert subscriptions() == before


def test_a_stream_still_delivers_after_a_neighbour_left(live_api):
    http = live_api.http
    fatima = patient(http, FATIMA_QID)
    nurse = staff(http, NURSE)
    visit_id = reserved_visit(fatima)
    with open_stream(live_api, f"/api/visits/{visit_id}/stream", fatima.token) as stays:
        stays.until(": connected")
        with open_stream(live_api, f"/api/visits/{visit_id}/stream", nurse.token) as leaves:
            assert leaves.lines.get(timeout=2).startswith("status")
        deadline = time.monotonic() + 2
        while subscriptions() > 1 and time.monotonic() < deadline:
            time.sleep(0.01)
        assert arrive(fatima, visit_id).status_code == 200
        assert any("ticket.activated" in line for line in stays.until("ticket.activated"))
