from __future__ import annotations

import json

import pytest

from backend import events as channels
from backend.adapters.queue_base import InvalidTransition, TicketExpired
from backend.tests.conftest import make_visit

T1 = "C-WAKRA-T1"


def _reserve(engine, conn, patient_id="P001"):
    visit_id = make_visit(conn, patient_id)
    return visit_id, engine.issue_ticket(visit_id, T1)


def _status(conn, visit_id):
    return conn.execute("SELECT status FROM visit WHERE id = ?", (visit_id,)).fetchone()[0]


def _ticket(conn, ticket_id):
    return conn.execute("SELECT * FROM ticket WHERE id = ?", (ticket_id,)).fetchone()


def test_44_59_activates(engine, seeded, clock):
    _, ticket = _reserve(engine, seeded)
    clock.advance(minutes=44, seconds=59)
    assert engine.activate(ticket.id).state == "active"


def test_45_00_is_expired_and_the_release_survives(engine, seeded, clock):
    visit_id, ticket = _reserve(engine, seeded)
    clock.advance(minutes=45)
    with pytest.raises(TicketExpired) as error:
        engine.activate(ticket.id)
    assert error.value.code == "ticket_expired"
    row = _ticket(seeded, ticket.id)
    assert row["state"] == "released" and row["released_at"] is not None
    assert _status(seeded, visit_id) == "expired"


def test_activate_after_an_earlier_sweep_still_says_expired(engine, seeded, clock):
    _, ticket = _reserve(engine, seeded)
    clock.advance(minutes=45)
    engine.expire_due()
    with pytest.raises(TicketExpired):
        engine.activate(ticket.id)


def test_cancelled_ticket_is_not_reported_as_expired(engine, seeded, clock):
    _, ticket = _reserve(engine, seeded)
    engine.release(ticket.id, "cancel")
    clock.advance(minutes=60)
    with pytest.raises(InvalidTransition):
        engine.activate(ticket.id)


def test_expire_due_batch(engine, seeded, clock):
    old_visit, old = _reserve(engine, seeded)
    older_visit, older = _reserve(engine, seeded, "P003")
    clock.advance(minutes=30)
    fresh_visit, fresh = _reserve(engine, seeded, "P006")
    clock.advance(minutes=15)
    expired = engine.expire_due()
    assert {ticket.id for ticket in expired} == {old.id, older.id}
    assert all(ticket.state == "released" for ticket in expired)
    assert _status(seeded, old_visit) == "expired"
    assert _status(seeded, older_visit) == "expired"
    assert _status(seeded, fresh_visit) == "reserved"
    assert _ticket(seeded, fresh.id)["state"] == "reserved"
    assert engine.expire_due() == []


def test_expire_due_leaves_active_tickets(engine, seeded, clock):
    _, ticket = _reserve(engine, seeded)
    engine.activate(ticket.id)
    clock.advance(minutes=120)
    assert engine.expire_due() == []
    assert _ticket(seeded, ticket.id)["state"] == "active"


def test_expiry_does_not_reopen_a_visit_that_moved_on(engine, seeded, clock):
    visit_id, ticket = _reserve(engine, seeded)
    seeded.execute(
        "UPDATE visit SET status = 'redirected_emergency' WHERE id = ?", (visit_id,)
    )
    clock.advance(minutes=45)
    engine.expire_due()
    assert _ticket(seeded, ticket.id)["state"] == "released"
    assert _status(seeded, visit_id) == "redirected_emergency"


def test_call_next_expires_lazily(engine, seeded, clock):
    visit_id, ticket = _reserve(engine, seeded)
    clock.advance(minutes=45)
    result = engine.call_next(T1)
    assert result.called is None
    assert _ticket(seeded, ticket.id)["state"] == "released"
    assert _status(seeded, visit_id) == "expired"


def test_position_and_snapshot_expire_lazily(engine, seeded, clock):
    _, ticket = _reserve(engine, seeded)
    clock.advance(minutes=44)
    position = engine.position(ticket.id)
    assert position.state == "reserved"
    assert position.expires_at == "2026-11-06T06:45:00.000000+00:00"
    clock.advance(minutes=1)
    position = engine.position(ticket.id)
    assert position.state == "released"
    assert position.people_ahead is None and position.est_wait_min is None
    assert position.expires_at is None

    _, other = _reserve(engine, seeded, "P003")
    clock.advance(minutes=45)
    assert engine.queue_snapshot(T1) == []
    assert _ticket(seeded, other.id)["state"] == "released"


def test_expired_ticket_never_consumes_a_number(engine, seeded, clock):
    _, ticket = _reserve(engine, seeded)
    clock.advance(minutes=45)
    engine.expire_due()
    row = _ticket(seeded, ticket.id)
    assert row["number"] is None and row["seq"] is None and row["day"] is None
    assert seeded.execute("SELECT COUNT(*) FROM number_sequence").fetchone()[0] == 0
    walk_in = engine.issue_active(make_visit(seeded, "P003"), T1)
    assert walk_in.number == "T-001"


def test_visit_can_reserve_again_after_expiry(engine, seeded, clock):
    visit_id, first = _reserve(engine, seeded)
    clock.advance(minutes=45)
    engine.expire_due()
    second = engine.issue_ticket(visit_id, T1)
    assert second.id != first.id and second.state == "reserved"
    assert _status(seeded, visit_id) == "reserved"
    assert engine.activate(second.id).state == "active"


def test_reserving_again_works_before_any_sweep(engine, seeded, clock):
    visit_id, first = _reserve(engine, seeded)
    clock.advance(minutes=45)
    second = engine.issue_ticket(visit_id, T1)
    assert second.id != first.id
    assert _ticket(seeded, first.id)["state"] == "released"


def test_expired_tickets_emit_released(engine, seeded, clock, events):
    visit_id, ticket = _reserve(engine, seeded)
    events.clear()
    clock.advance(minutes=45)
    engine.expire_due()
    rows = seeded.execute("SELECT * FROM event WHERE type = 'ticket.released'").fetchall()
    assert len(rows) == 1 and rows[0]["visit_id"] == visit_id
    payload = json.loads(rows[0]["payload"])
    assert payload["ticket_id"] == ticket.id and payload["reason"] == "expired"
    sent = events.on(channels.visit_channel(visit_id))
    assert [event["type"] for event in sent] == ["ticket.released"]
    assert [e["type"] for e in events.on(channels.counter_channel(T1))] == ["ticket.released"]
