from __future__ import annotations

import json

from backend import events as channels
from backend.tests.conftest import make_visit

T1 = "C-WAKRA-T1"


def _state(conn, ticket_id):
    return conn.execute("SELECT state FROM ticket WHERE id = ?", (ticket_id,)).fetchone()[0]


def _real(engine, conn, patient_id="P001"):
    return engine.issue_active(make_visit(conn, patient_id), T1)


def test_simulated_count_toward_people_ahead_and_wait(engine, seeded):
    engine.issue_simulated(T1)
    engine.issue_simulated(T1)
    ticket = _real(engine, seeded)
    position = engine.position(ticket.id)
    assert position.people_ahead == 2
    assert position.est_wait_min == 8
    assert engine.counter_wait(T1) == {"people_ahead": 3, "wait_min": 12}


def test_call_next_clears_sims_ahead_of_the_real_ticket(engine, seeded, events):
    first = engine.issue_simulated(T1)
    second = engine.issue_simulated(T1)
    ticket = _real(engine, seeded)
    events.clear()
    result = engine.call_next(T1)
    assert result.called.id == ticket.id
    assert [t.id for t in result.auto_completed] == [first.id, second.id]
    for sim in result.auto_completed:
        assert sim.state == "done" and sim.done_at is not None
        assert sim.called_at is None and sim.call_count == 0
    types = [event["type"] for event in events.on(channels.counter_channel(T1))]
    assert types == ["ticket.simulated_done", "ticket.simulated_done", "ticket.called"]
    called = seeded.execute("SELECT COUNT(*) FROM event WHERE type = 'ticket.called'")
    assert called.fetchone()[0] == 1
    note = seeded.execute(
        "SELECT payload FROM event WHERE type = 'ticket.simulated_done'"
    ).fetchone()
    assert json.loads(note["payload"])["note"] == "handled by a colleague on shift"


def test_only_sims_complete_one_and_call_nobody(engine):
    first = engine.issue_simulated(T1)
    second = engine.issue_simulated(T1)
    result = engine.call_next(T1)
    assert result.called is None
    assert [t.id for t in result.auto_completed] == [first.id]
    assert engine.position(second.id).state == "active"
    assert engine.queue_snapshot(T1)[0]["ticket_id"] == second.id


def test_empty_queue(engine):
    result = engine.call_next(T1)
    assert result.called is None and result.auto_completed == []


def test_snapshot_labels_simulated(engine, seeded):
    sim = engine.issue_simulated(T1)
    ticket = _real(engine, seeded)
    rows = {row["ticket_id"]: row for row in engine.queue_snapshot(T1)}
    assert rows[sim.id]["label"] == "Simulated" and rows[sim.id]["simulated"] is True
    assert rows[ticket.id]["label"] is None and rows[ticket.id]["simulated"] is False
    assert rows[sim.id]["position"] == 1 and rows[ticket.id]["position"] == 2


def test_priority_real_ticket_passes_sims_and_only_those_ahead_complete(engine, seeded):
    sim = engine.issue_simulated(T1)
    plain = _real(engine, seeded, "P001")
    ahmed = _real(engine, seeded, "P002")
    assert ahmed.priority == 1 and sim.priority == 0

    result = engine.call_next(T1)
    assert result.called.id == ahmed.id
    assert result.auto_completed == []
    assert _state(seeded, sim.id) == "active"
    engine.complete(ahmed.id)

    result = engine.call_next(T1)
    assert result.called.id == plain.id
    assert [t.id for t in result.auto_completed] == [sim.id]


def test_sims_behind_the_real_ticket_are_left_waiting(engine, seeded):
    ahead = engine.issue_simulated(T1)
    ticket = _real(engine, seeded)
    behind = engine.issue_simulated(T1)
    result = engine.call_next(T1)
    assert result.called.id == ticket.id
    assert [t.id for t in result.auto_completed] == [ahead.id]
    assert _state(seeded, behind.id) == "active"


def test_simulated_ticket_has_no_visit_and_no_intake(engine, seeded, events):
    sim = engine.issue_simulated(T1)
    row = seeded.execute("SELECT * FROM ticket WHERE id = ?", (sim.id,)).fetchone()
    assert sim.simulated is True and row["simulated"] == 1
    assert row["visit_id"] is None and sim.priority == 0 and sim.state == "active"
    assert sim.number == "T-001"
    assert seeded.execute("SELECT COUNT(*) FROM visit").fetchone()[0] == 0
    assert seeded.execute("SELECT COUNT(*) FROM intake").fetchone()[0] == 0
    assert all(not name.startswith("visit:") for name, _ in events)


def test_simulated_excluded_from_rolling_average(engine, seeded, clock):
    for _ in range(5):
        ticket = _real(engine, seeded, "P003")
        engine.call_next(T1)
        clock.advance(seconds=100)
        engine.complete(ticket.id)
    assert engine.avg_service_sec(T1) == 100

    for _ in range(3):
        engine.issue_simulated(T1)
    clock.advance(seconds=900)
    ticket = _real(engine, seeded, "P003")
    engine.call_next(T1)
    clock.advance(seconds=100)
    engine.complete(ticket.id)
    assert engine.avg_service_sec(T1) == 100

    # Even a simulated row carrying both stamps must not count.
    seeded.execute(
        "UPDATE ticket SET called_at = '2026-11-06T00:00:00.000000+00:00' WHERE simulated = 1"
    )
    assert engine.avg_service_sec(T1) == 100
