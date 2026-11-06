from __future__ import annotations

import json
import logging
import socket
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient
from huggingface_hub import InferenceClient

from backend import db, deps, timeutil
from backend.ai import audit, runtime
from backend.ai.audit import AiEvent
from backend.main import app
from backend.tests.ai_fakes import WAV_BYTES, FakeAsrClient, FakeChatClient
from backend.tests.conftest import make_visit

DUMMY_TOKEN = "dummy-not-a-real-token"


@pytest.fixture(autouse=True)
def isolated_env(db_path, monkeypatch):
    # A developer's .env must not leak a token or load setting into these tests.
    monkeypatch.setattr("backend.main.load_dotenv", lambda: None)
    monkeypatch.delenv("HF_TOKEN", raising=False)
    monkeypatch.delenv("SIMULATE_LOAD", raising=False)


@pytest.fixture
def blocked_sockets(monkeypatch):
    attempts = []

    def refuse(*args, **kwargs):
        attempts.append(args)
        raise OSError("network is blocked in this test")

    monkeypatch.setattr(socket.socket, "connect", refuse)
    monkeypatch.setattr(socket.socket, "connect_ex", refuse)
    monkeypatch.setattr(socket, "create_connection", refuse)
    monkeypatch.setattr(socket, "getaddrinfo", refuse)
    return attempts


def events_of(conn, visit_id):
    return conn.execute(
        "SELECT type, payload, at FROM event WHERE visit_id = ? ORDER BY id", (visit_id,)
    ).fetchall()


def test_without_a_token_the_runtime_is_simulated():
    ai = runtime.build_runtime()
    assert ai.mode == "simulated"
    assert ai.llm.mode == "simulated"
    assert ai.asr.mode == "simulated"


def test_injected_clients_reach_the_adapters():
    chat = FakeChatClient(["hello"])
    voice = FakeAsrClient(text="spoken")

    ai = runtime.build_runtime(llm_client=chat, asr_client=voice)

    assert ai.mode == "real"
    assert ai.llm.chat([{"role": "user", "content": "hi"}]) == "hello"
    assert ai.asr.transcribe(WAV_BYTES) == "spoken"


def test_the_mode_follows_the_llm():
    ai = runtime.build_runtime(asr_client=FakeAsrClient())
    assert ai.mode == "simulated"
    assert ai.asr.mode == "real"


def test_the_runtime_is_frozen():
    with pytest.raises(AttributeError):
        runtime.build_runtime().llm = None


def test_health_is_simulated_without_a_token():
    with TestClient(app) as client:
        body = client.get("/api/health").json()
        assert app.state.ai.mode == "simulated"
    assert body == {"status": "ok", "ai_mode": "simulated", "simulate_load": False}


def test_health_is_real_with_a_dummy_token_and_startup_stays_offline(monkeypatch, blocked_sockets):
    monkeypatch.setenv("HF_TOKEN", DUMMY_TOKEN)

    with TestClient(app) as client:
        body = client.get("/api/health").json()
        assert app.state.ai.mode == "real"
        assert isinstance(app.state.ai.llm.client, InferenceClient)
        assert isinstance(app.state.ai.asr.client, InferenceClient)

    assert body == {"status": "ok", "ai_mode": "real", "simulate_load": False}
    assert blocked_sockets == []


def test_the_blocked_sockets_fixture_does_block(blocked_sockets):
    with pytest.raises(OSError, match="blocked"):
        socket.create_connection(("127.0.0.1", 9))
    assert len(blocked_sockets) == 1


def test_health_reads_the_mode_chosen_at_startup(monkeypatch):
    with TestClient(app) as client:
        monkeypatch.setenv("HF_TOKEN", DUMMY_TOKEN)
        assert client.get("/api/health").json()["ai_mode"] == "simulated"


def test_a_token_from_the_dotenv_file_is_seen(monkeypatch):
    monkeypatch.setattr(
        "backend.main.load_dotenv", lambda: monkeypatch.setenv("HF_TOKEN", DUMMY_TOKEN)
    )
    with TestClient(app) as client:
        assert client.get("/api/health").json()["ai_mode"] == "real"


def test_startup_logs_the_mode_once(caplog):
    caplog.set_level(logging.INFO, logger="backend.main")
    with TestClient(app):
        pass
    assert [r.getMessage() for r in caplog.records if "AI mode" in r.getMessage()] == [
        "AI mode: simulated"
    ]


def test_startup_never_logs_the_token(monkeypatch, caplog):
    caplog.set_level(logging.DEBUG)
    monkeypatch.setenv("HF_TOKEN", DUMMY_TOKEN)
    with TestClient(app) as client:
        client.get("/api/health")
    assert DUMMY_TOKEN not in caplog.text


def test_get_ai_returns_the_runtime():
    with TestClient(app) as client:
        fake_request = type("Request", (), {"app": client.app})()
        assert deps.get_ai(fake_request) is app.state.ai


def test_record_writes_a_row_per_event(seeded):
    visit_id = make_visit(seeded, "P001")
    moment = datetime(2026, 11, 6, 7, 0, tzinfo=timezone.utc)

    audit.record(
        seeded,
        visit_id,
        [AiEvent("ai.turn", {"source": "model"}), AiEvent("ai.fallback", {"reason": "حرارة"})],
        at=moment,
    )

    rows = events_of(seeded, visit_id)
    assert [row["type"] for row in rows] == ["ai.turn", "ai.fallback"]
    assert json.loads(rows[0]["payload"]) == {"source": "model"}
    assert "حرارة" in rows[1]["payload"]
    assert {row["at"] for row in rows} == {timeutil.iso(moment)}


def test_record_stamps_now_by_default(seeded):
    visit_id = make_visit(seeded, "P001")
    before = timeutil.utcnow()
    audit.record(seeded, visit_id, [AiEvent("ai.turn", {})])
    assert before <= timeutil.parse(events_of(seeded, visit_id)[0]["at"]) <= timeutil.utcnow()


def test_record_takes_any_iterable(seeded):
    visit_id = make_visit(seeded, "P001")
    audit.record(seeded, visit_id, (AiEvent(f"e{n}", {}) for n in range(3)))
    assert len(events_of(seeded, visit_id)) == 3


def test_record_with_no_events_writes_nothing(seeded):
    visit_id = make_visit(seeded, "P001")
    audit.record(seeded, visit_id, [])
    assert events_of(seeded, visit_id) == []


def test_record_joins_the_enclosing_transaction(seeded):
    visit_id = make_visit(seeded, "P001")

    with pytest.raises(RuntimeError):
        with db.transaction(seeded):
            audit.record(seeded, visit_id, [AiEvent("ai.turn", {})])
            raise RuntimeError("roll it back")

    assert events_of(seeded, visit_id) == []


def test_record_commits_with_the_enclosing_transaction(seeded):
    visit_id = make_visit(seeded, "P001")
    with db.transaction(seeded):
        audit.record(seeded, visit_id, [AiEvent("ai.turn", {})])
    assert len(events_of(seeded, visit_id)) == 1
