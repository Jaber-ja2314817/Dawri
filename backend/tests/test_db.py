from __future__ import annotations

import sqlite3
from datetime import date, datetime, timedelta, timezone

import pytest

from backend import config, db, seeding, timeutil


def _insert_visit(conn, visit_id="V1", patient_id="P001"):
    conn.execute(
        "INSERT INTO visit (id, patient_id, status) VALUES (?, ?, 'intake')",
        (visit_id, patient_id),
    )


def _insert_ticket(conn, ticket_id="TK1", **columns):
    row = {
        "id": ticket_id,
        "centre_id": "C-WAKRA",
        "counter_id": "C-WAKRA-T1",
        "state": "active",
        "day": "2026-11-06",
        **columns,
    }
    names = ", ".join(row)
    marks = ", ".join("?" for _ in row)
    conn.execute(f"INSERT INTO ticket ({names}) VALUES ({marks})", tuple(row.values()))


def test_connection_uses_wal_and_foreign_keys(conn):
    assert conn.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
    assert conn.execute("PRAGMA foreign_keys").fetchone()[0] == 1
    assert conn.execute("PRAGMA busy_timeout").fetchone()[0] == 5000


def test_foreign_keys_are_enforced(conn):
    with pytest.raises(sqlite3.IntegrityError, match="FOREIGN KEY"):
        _insert_visit(conn, patient_id="nobody")


def test_connect_rejects_memory_database():
    with pytest.raises(ValueError):
        db.connect(":memory:")


def test_connect_creates_parent_directories(tmp_path):
    path = tmp_path / "a" / "b" / "test.db"
    connection = db.connect(path)
    connection.close()
    assert path.exists()


def test_init_schema_twice_is_fine(seeded):
    before = seeded.execute("SELECT COUNT(*) FROM centre").fetchone()[0]
    db.init_schema(seeded)
    assert seeded.execute("SELECT COUNT(*) FROM centre").fetchone()[0] == before


def test_reserved_ticket_with_number_violates_check(seeded):
    _insert_visit(seeded)
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _insert_ticket(seeded, visit_id="V1", state="reserved", number="T-001")


def test_reserved_ticket_with_seq_violates_check(seeded):
    _insert_visit(seeded)
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _insert_ticket(seeded, visit_id="V1", state="reserved", seq=1)


def test_reserved_ticket_without_number_is_allowed(seeded):
    _insert_visit(seeded)
    _insert_ticket(seeded, visit_id="V1", state="reserved")


def test_simulated_ticket_with_visit_violates_check(seeded):
    _insert_visit(seeded)
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _insert_ticket(seeded, visit_id="V1", simulated=1, number="T-001", seq=1)


def test_real_ticket_without_visit_violates_check(seeded):
    with pytest.raises(sqlite3.IntegrityError, match="CHECK"):
        _insert_ticket(seeded, number="T-001", seq=1)


def test_second_live_ticket_for_a_visit_violates_unique_index(seeded):
    _insert_visit(seeded)
    _insert_ticket(seeded, visit_id="V1", number="T-001", seq=1)
    with pytest.raises(sqlite3.IntegrityError, match="ticket.visit_id"):
        _insert_ticket(seeded, "TK2", visit_id="V1", number="T-002", seq=2)


def test_finished_ticket_does_not_block_the_next_one(seeded):
    _insert_visit(seeded)
    _insert_ticket(seeded, visit_id="V1", number="T-001", seq=1, state="done")
    _insert_ticket(seeded, "TK2", visit_id="V1", number="D-GP-001", seq=1)


def test_duplicate_number_on_centre_and_day_violates_unique_index(seeded):
    _insert_visit(seeded)
    _insert_visit(seeded, "V2", "P002")
    _insert_ticket(seeded, visit_id="V1", number="T-001", seq=1)
    with pytest.raises(sqlite3.IntegrityError, match="ticket.number"):
        _insert_ticket(seeded, "TK2", visit_id="V2", number="T-001", seq=2)


def test_same_number_on_another_day_is_allowed(seeded):
    _insert_visit(seeded)
    _insert_visit(seeded, "V2", "P002")
    _insert_ticket(seeded, visit_id="V1", number="T-001", seq=1)
    _insert_ticket(
        seeded, "TK2", visit_id="V2", number="T-001", seq=1, day="2026-11-07"
    )


def test_transaction_commits(conn):
    with db.transaction(conn):
        conn.execute("INSERT INTO drug (id) VALUES ('X')")
    assert conn.execute("SELECT COUNT(*) FROM drug").fetchone()[0] == 1


def test_transaction_rolls_back_and_reraises(conn):
    with pytest.raises(RuntimeError, match="boom"):
        with db.transaction(conn):
            conn.execute("INSERT INTO drug (id) VALUES ('X')")
            raise RuntimeError("boom")
    assert conn.execute("SELECT COUNT(*) FROM drug").fetchone()[0] == 0
    assert not conn.in_transaction


def test_reset_all_empties_tables_but_keeps_session(seeded):
    _insert_visit(seeded)
    _insert_ticket(seeded, visit_id="V1", number="T-001", seq=1)
    seeded.executescript(
        """
        INSERT INTO number_sequence VALUES ('C-WAKRA', 'T', '2026-11-06', 1);
        INSERT INTO intake (visit_id, json) VALUES ('V1', '{}');
        INSERT INTO vitals (visit_id) VALUES ('V1');
        INSERT INTO handoff (visit_id) VALUES ('V1');
        INSERT INTO prescription_item (visit_id, drug) VALUES ('V1', 'paracetamol');
        INSERT INTO event (visit_id, type) VALUES ('V1', 'test');
        INSERT INTO session VALUES ('tok', 'patient', 'P001', '2026-11-06');
        """
    )

    db.reset_all(seeded)

    tables = [
        row["name"]
        for row in seeded.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name <> 'session'"
        )
    ]
    assert "ticket" in tables and "sqlite_sequence" in tables
    for table in tables:
        assert seeded.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] == 0, table
    assert seeded.execute("SELECT COUNT(*) FROM session").fetchone()[0] == 1


def test_reset_all_restarts_autoincrement(conn):
    conn.execute("INSERT INTO event (type) VALUES ('first')")
    db.reset_all(conn)
    conn.execute("INSERT INTO event (type) VALUES ('second')")
    assert conn.execute("SELECT id FROM event").fetchone()[0] == 1


def test_reset_then_reseed(seeded):
    db.reset_all(seeded)
    assert not seeding.is_seeded(seeded)
    seeding.seed_static(seeded)
    assert seeding.is_seeded(seeded)


def test_json_helpers():
    assert db.loads_list(None) == []
    assert db.loads_list(db.dumps(["فاطمة"])) == ["فاطمة"]
    assert "فاطمة" in db.dumps(["فاطمة"])


def test_new_id_shape():
    value = db.new_id("V")
    assert value.startswith("V_") and len(value) == 14
    assert value != db.new_id("V")


def test_config_is_read_at_call_time(monkeypatch):
    monkeypatch.setenv("DAWRI_DB", "/tmp/elsewhere.db")
    monkeypatch.setenv("HF_TOKEN", "  ")
    monkeypatch.setenv("SIMULATE_LOAD", "1")
    assert str(config.db_path()) == "/tmp/elsewhere.db"
    assert config.ai_mode() == "simulated"
    assert config.simulate_load() is True

    monkeypatch.setenv("HF_TOKEN", "not-a-real-token")
    monkeypatch.delenv("DAWRI_DB")
    monkeypatch.delenv("SIMULATE_LOAD")
    assert config.ai_mode() == "real"
    assert config.simulate_load() is False
    assert config.db_path().parts[-3:] == ("backend", "data", "dawri.db")


def test_config_model_defaults(monkeypatch):
    for name in ("LLM_MODEL_ID", "LLM_PROVIDER", "ASR_MODEL_ID"):
        monkeypatch.delenv(name, raising=False)
    assert config.llm_model_id() == "google/gemma-4-26B-A4B-it"
    assert config.llm_provider() == "novita"
    assert config.asr_model_id() == "openai/whisper-large-v3-turbo"


def test_iso_lexical_order_is_time_order():
    whole_second = datetime(2026, 11, 6, 10, 0, 0, tzinfo=timezone.utc)
    later = whole_second + timedelta(microseconds=1)
    assert timeutil.iso(whole_second) < timeutil.iso(later)
    assert timeutil.iso(whole_second) == "2026-11-06T10:00:00.000000+00:00"


def test_iso_converts_to_utc_and_parse_round_trips():
    doha = timezone(timedelta(hours=3))
    dt = datetime(2026, 11, 6, 13, 0, 0, tzinfo=doha)
    assert timeutil.iso(dt) == "2026-11-06T10:00:00.000000+00:00"
    assert timeutil.parse(timeutil.iso(dt)) == dt


def test_doha_day_rolls_at_doha_midnight():
    assert timeutil.doha_day(datetime(2026, 11, 6, 20, 59, tzinfo=timezone.utc)) == "2026-11-06"
    assert timeutil.doha_day(datetime(2026, 11, 6, 21, 0, tzinfo=timezone.utc)) == "2026-11-07"


def test_age_turns_on_the_doha_date():
    assert timeutil.age_on("1992-11-07", datetime(2026, 11, 6, 20, 59, tzinfo=timezone.utc)) == 33
    assert timeutil.age_on("1992-11-07", datetime(2026, 11, 6, 21, 0, tzinfo=timezone.utc)) == 34
    assert timeutil.age_on("1992-11-07", date(2026, 11, 6)) == 33
