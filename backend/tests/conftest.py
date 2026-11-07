from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from huggingface_hub.utils import _detect_agent

from backend import timeutil

# Ticket numbers and the one-emergency-a-day rule turn over at Doha midnight, and many tests
# start a clock from utcnow and move it 45 minutes on. So the whole session runs from Doha
# midday on a fixed date, whatever the hour or day it is started: time flows as usual, and no
# run can cross midnight. A test about midnight pins its own clock.
# This has to come before the imports below: SqliteQueueEngine takes utcnow as a default
# argument, so it keeps whichever function is here when queue_engine is first imported.
SUITE_START = datetime(2026, 11, 7, 9, 0, tzinfo=timezone.utc)  # 12:00 in Doha.
_wall_clock = timeutil.utcnow
_to_suite_start = SUITE_START - _wall_clock()
timeutil.utcnow = lambda: _wall_clock() + _to_suite_start

# The first request huggingface_hub makes in a process also refreshes its list of agent
# harnesses, unless the home cache has a copy under a day old. Under a fake transport that
# refresh takes the fake's answer, which breaks the client and overwrites the cache, so the
# real-client tests turned red the moment the copy aged out. Holding the list empty means
# neither the hour nor the home directory matters, and the suite never touches that file.
_detect_agent._registry = _detect_agent._EMPTY_REGISTRY

from backend import db, seeding  # noqa: E402
from backend.main import app  # noqa: E402
from backend.queue_engine import SqliteQueueEngine  # noqa: E402
from backend.tests.api_helpers import live_server  # noqa: E402


@pytest.fixture
def db_path(tmp_path, monkeypatch):
    path = tmp_path / "test.db"
    monkeypatch.setenv("DAWRI_DB", str(path))
    return path


@pytest.fixture
def conn(db_path):
    connection = db.connect()
    db.init_schema(connection)
    yield connection
    connection.close()


@pytest.fixture
def seeded(conn):
    seeding.seed_static(conn)
    return conn


class FakeClock:
    def __init__(self, start=datetime(2026, 11, 6, 6, 0, tzinfo=timezone.utc)):
        self.now = start

    def __call__(self):
        return self.now

    def advance(self, minutes=0, seconds=0):
        self.now += timedelta(minutes=minutes, seconds=seconds)


class EventCollector(list):
    def publish(self, channel, event):
        self.append((channel, event))

    def on(self, channel):
        return [event for name, event in self if name == channel]


def make_visit(conn, patient_id, status="intake", booked_by=None):
    visit_id = db.new_id("V")
    conn.execute(
        "INSERT INTO visit (id, patient_id, status, created_at, booked_by) "
        "VALUES (?, ?, ?, '2026-11-06T06:00:00.000000+00:00', ?)",
        (visit_id, patient_id, status, booked_by),
    )
    return visit_id


@pytest.fixture
def clock():
    return FakeClock()


@pytest.fixture
def events():
    return EventCollector()


@pytest.fixture
def engine(seeded, db_path, clock, events):
    return SqliteQueueEngine(
        conn_factory=lambda: db.connect(db_path), clock=clock, publish=events.publish
    )


@pytest.fixture
def api_env(db_path, monkeypatch):
    """A developer's .env must not leak a token or load setting into these tests."""
    monkeypatch.setattr("backend.main.load_dotenv", lambda: None)
    monkeypatch.delenv("HF_TOKEN", raising=False)
    monkeypatch.setenv("SIMULATE_LOAD", "1")


@pytest.fixture
def api(api_env):
    with TestClient(app) as client:
        yield client


@pytest.fixture
def live_api(api_env):
    with live_server(app) as live:
        yield live
