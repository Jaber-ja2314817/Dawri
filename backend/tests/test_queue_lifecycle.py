from __future__ import annotations

import json

import pytest

from backend import db, events as channels
from backend.adapters.queue_base import (
    InvalidTransition,
    TicketNotFound,
    VisitHasLiveTicket,
    VisitNotEligible,
)
from backend.queue_engine import SqliteQueueEngine
from backend.tests.conftest import make_visit

T1 = "C-WAKRA-T1"
D4 = "C-WAKRA-D4"
P1 = "C-WAKRA-P1"


def _state(conn, ticket_id):
    return conn.execute("SELECT state FROM ticket WHERE id = ?", (ticket_id,)).fetchone()[0]


def _visit(conn, visit_id):
    return conn.execute("SELECT * FROM visit WHERE id = ?", (visit_id,)).fetchone()


def _event_types(conn, ticket_id):
    rows = conn.execute("SELECT type, payload FROM event ORDER BY id").fetchall()
    return [r["type"] for r in rows if json.loads(r["payload"])["ticket_id"] == ticket_id]


def _reserved(engine, conn):
    return engine.issue_ticket(make_visit(conn, "P001"), T1)


def _at(engine, conn, state):
    """A ticket driven to the given state."""
    ticket = _reserved(engine, conn)
    if state == "reserved":
        return ticket
    if state == "released":
        return engine.release(ticket.id, "cancel")
    engine.activate(ticket.id)
    if state == "active":
        return ticket
    engine.call_next(T1)
    if state == "called":
        return ticket
    engine.serve(ticket.id)
    if state == "serving":
        return ticket
    return engine.complete(ticket.id)


def test_full_lifecycle(engine, seeded):
    visit_id = make_visit(seeded, "P001")
    ticket = engine.issue_ticket(visit_id, T1)
    assert ticket.state == "reserved"
    assert engine.activate(ticket.id).state == "active"
    assert engine.call_next(T1).called.id == ticket.id
    assert _state(seeded, ticket.id) == "called"
    assert engine.serve(ticket.id).state == "serving"
    done = engine.complete(ticket.id)
    assert done.state == "done" and done.done_at is not None


def test_no_show_returns_to_active(engine, seeded):
    ticket = _at(engine, seeded, "called")
    assert engine.no_show(ticket.id).state == "active"


def test_complete_walks_called_through_serving(engine, seeded):
    ticket = _at(engine, seeded, "called")
    assert engine.complete(ticket.id).state == "done"
    types = _event_types(seeded, ticket.id)
    assert types[-2:] == ["ticket.serving", "ticket.done"]


def test_reserved_ticket_has_no_number_or_place(engine, seeded):
    ticket = _reserved(engine, seeded)
    assert ticket.number is None
    assert ticket.seq is None
    assert ticket.activated_at is None
    row = seeded.execute("SELECT day FROM ticket WHERE id = ?", (ticket.id,)).fetchone()
    assert row["day"] is None
    position = engine.position(ticket.id)
    assert position.people_ahead is None and position.est_wait_min is None
    assert position.expires_at is not None


def test_issue_ticket_sets_visit_reserved_and_centre(engine, seeded):
    visit_id = make_visit(seeded, "P001")
    ticket = engine.issue_ticket(visit_id, T1)
    visit = _visit(seeded, visit_id)
    assert visit["status"] == "reserved"
    assert visit["centre_id"] == "C-WAKRA"
    assert ticket.centre_id == "C-WAKRA"


@pytest.mark.parametrize(
    "state, method",
    [
        ("reserved", "serve"),
        ("reserved", "no_show"),
        ("reserved", "complete"),
        ("active", "activate"),
        ("active", "serve"),
        ("active", "no_show"),
        ("active", "complete"),
        ("called", "activate"),
        ("serving", "activate"),
        ("serving", "serve"),
        ("serving", "no_show"),
        ("done", "activate"),
        ("done", "serve"),
        ("done", "no_show"),
        ("done", "complete"),
        ("done", "release"),
        ("released", "activate"),
        ("released", "serve"),
        ("released", "no_show"),
        ("released", "complete"),
        ("released", "release"),
    ],
)
def test_illegal_transitions(engine, seeded, state, method):
    ticket = _at(engine, seeded, state)
    action = getattr(engine, method)
    args = (ticket.id, "cancel") if method == "release" else (ticket.id,)
    with pytest.raises(InvalidTransition) as error:
        action(*args)
    assert error.value.code == "invalid_transition"
    assert _state(seeded, ticket.id) == state


def test_reservation_needs_a_triage_counter(engine, seeded):
    with pytest.raises(InvalidTransition):
        engine.issue_ticket(make_visit(seeded, "P001"), D4)


@pytest.mark.parametrize("method", ["activate", "serve", "no_show", "complete", "position"])
def test_unknown_ticket(engine, method):
    with pytest.raises(TicketNotFound) as error:
        getattr(engine, method)("nope")
    assert error.value.code == "ticket_not_found"


@pytest.mark.parametrize("state", ["reserved", "active", "called", "serving"])
def test_release_ends_a_live_ticket_and_leaves_the_visit_alone(engine, seeded, state):
    ticket = _at(engine, seeded, state)
    before = _visit(seeded, ticket.visit_id)["status"]
    released = engine.release(ticket.id, "urgent_to_ed")
    assert released.state == "released" and released.released_at is not None
    assert _visit(seeded, ticket.visit_id)["status"] == before


def test_visit_status_follows_the_stages(engine, seeded):
    visit_id = make_visit(seeded, "P001")
    triage = engine.issue_ticket(visit_id, T1)
    engine.activate(triage.id)
    assert _visit(seeded, visit_id)["status"] == "in_triage"
    arrived_at = _visit(seeded, visit_id)["arrived_at"]
    assert arrived_at is not None

    engine.call_next(T1)
    engine.complete(triage.id)
    doctor = engine.issue_active(visit_id, D4)
    assert _visit(seeded, visit_id)["status"] == "in_doctor"

    engine.call_next(D4)
    engine.complete(doctor.id)
    engine.issue_active(visit_id, P1)
    visit = _visit(seeded, visit_id)
    assert visit["status"] == "in_pharmacy"
    assert visit["arrived_at"] == arrived_at


def test_engine_does_not_complete_the_visit(engine, seeded):
    ticket = _at(engine, seeded, "done")
    assert _visit(seeded, ticket.visit_id)["status"] == "in_triage"


def test_walk_in_sets_centre_and_arrival(engine, seeded):
    visit_id = make_visit(seeded, "P001")
    ticket = engine.issue_active(visit_id, T1)
    visit = _visit(seeded, visit_id)
    assert ticket.state == "active" and ticket.number and ticket.activated_at
    assert visit["centre_id"] == "C-WAKRA"
    assert visit["arrived_at"] == ticket.activated_at


def test_second_live_ticket_is_refused(engine, seeded):
    visit_id = make_visit(seeded, "P001")
    ticket = engine.issue_ticket(visit_id, T1)
    with pytest.raises(VisitHasLiveTicket):
        engine.issue_ticket(visit_id, T1)
    with pytest.raises(VisitHasLiveTicket):
        engine.issue_active(visit_id, D4)
    engine.activate(ticket.id)
    with pytest.raises(VisitHasLiveTicket):
        engine.issue_active(visit_id, D4)


@pytest.mark.parametrize("status", ["redirected_emergency", "deflected_refill"])
@pytest.mark.parametrize("method", ["issue_ticket", "issue_active"])
def test_red_line_visits_never_get_a_ticket(engine, seeded, status, method):
    visit_id = make_visit(seeded, "P003", status=status)
    with pytest.raises(VisitNotEligible) as error:
        getattr(engine, method)(visit_id, T1)
    assert error.value.code == "visit_not_eligible"
    assert seeded.execute("SELECT COUNT(*) FROM ticket").fetchone()[0] == 0
    assert _visit(seeded, visit_id)["status"] == status


@pytest.mark.parametrize("status", ["completed", "cancelled", "expired"])
def test_issue_active_refuses_finished_visits(engine, seeded, status):
    with pytest.raises(VisitNotEligible):
        engine.issue_active(make_visit(seeded, "P001", status=status), T1)


@pytest.mark.parametrize("status", ["reserved", "in_triage", "completed", "cancelled"])
def test_issue_ticket_refuses_other_statuses(engine, seeded, status):
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(make_visit(seeded, "P001", status=status), T1)


def test_unknown_visit_is_not_eligible(engine):
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket("nope", T1)
    with pytest.raises(VisitNotEligible):
        engine.issue_active("nope", T1)


def test_redirected_visit_with_a_stale_reservation_cannot_activate(engine, seeded):
    ticket = _reserved(engine, seeded)
    seeded.execute(
        "UPDATE visit SET status = 'redirected_emergency' WHERE id = ?", (ticket.visit_id,)
    )
    with pytest.raises(VisitNotEligible):
        engine.activate(ticket.id)
    row = seeded.execute("SELECT * FROM ticket WHERE id = ?", (ticket.id,)).fetchone()
    assert row["state"] == "reserved" and row["number"] is None


def test_event_rows_are_written_in_order(engine, seeded):
    ticket = _at(engine, seeded, "done")
    assert _event_types(seeded, ticket.id) == [
        "ticket.reserved",
        "ticket.activated",
        "ticket.called",
        "ticket.serving",
        "ticket.done",
    ]
    rows = seeded.execute("SELECT * FROM event WHERE type = 'ticket.called'").fetchall()
    payload = json.loads(rows[0]["payload"])
    assert payload == {"ticket_id": ticket.id, "number": "T-001", "counter_id": T1}
    assert rows[0]["visit_id"] == ticket.visit_id


def test_activate_payload_records_method(engine, seeded):
    ticket = _reserved(engine, seeded)
    engine.activate(ticket.id, method="qr")
    row = seeded.execute("SELECT payload FROM event WHERE type = 'ticket.activated'").fetchone()
    assert json.loads(row["payload"])["method"] == "qr"


def test_no_show_and_release_events(engine, seeded):
    ticket = _at(engine, seeded, "called")
    engine.no_show(ticket.id)
    engine.release(ticket.id, "cancel")
    types = _event_types(seeded, ticket.id)
    assert types[-2:] == ["ticket.no_show", "ticket.released"]
    row = seeded.execute("SELECT payload FROM event WHERE type = 'ticket.released'").fetchone()
    assert json.loads(row["payload"])["reason"] == "cancel"


def test_publish_runs_after_commit(seeded, db_path, clock):
    """A fresh connection inside publish must already see the new state."""
    seen = []

    def publish(channel, event):
        if event["type"] == "ticket.called":
            check = db.connect(db_path)
            state = check.execute("SELECT state FROM ticket").fetchone()[0]
            check.close()
            seen.append(state)

    engine = SqliteQueueEngine(lambda: db.connect(db_path), clock, publish)
    engine.issue_active(make_visit(seeded, "P001"), T1)
    engine.call_next(T1)
    assert seen and set(seen) == {"called"}


def test_failed_transition_publishes_nothing(engine, seeded, events):
    ticket = _reserved(engine, seeded)
    events.clear()
    with pytest.raises(InvalidTransition):
        engine.serve(ticket.id)
    assert events == []


def test_failure_after_writes_rolls_back_and_publishes_nothing(engine, seeded, events, monkeypatch):
    """The transaction is real: a late failure leaves no ticket, event or message."""
    from backend import queue_engine

    def explode(*args):
        raise RuntimeError("boom")

    monkeypatch.setattr(queue_engine, "_people_ahead", explode)
    with pytest.raises(RuntimeError):
        engine.issue_active(make_visit(seeded, "P001"), T1)
    assert seeded.execute("SELECT COUNT(*) FROM ticket").fetchone()[0] == 0
    assert seeded.execute("SELECT COUNT(*) FROM event").fetchone()[0] == 0
    assert seeded.execute("SELECT COUNT(*) FROM number_sequence").fetchone()[0] == 0
    assert events == []


def test_sse_shape_and_channels(engine, seeded, events):
    visit_id = make_visit(seeded, "P001")
    ticket = engine.issue_active(visit_id, T1)
    events.clear()
    engine.call_next(T1)
    expected = {
        "type": "ticket.called",
        "visit_id": visit_id,
        "ticket": ticket.number,
        "counter": "Triage 1",
        "people_ahead": 0,
    }
    assert events.on(channels.counter_channel(T1)) == [expected]
    assert events.on(channels.visit_channel(visit_id)) == [expected]


def test_display_event_has_no_visit_id(engine, seeded, events):
    ticket = _at(engine, seeded, "done")
    shown = events.on(channels.display_channel("C-WAKRA"))
    assert [event["type"] for event in shown] == [
        "ticket.reserved",
        "ticket.activated",
        "ticket.called",
        "ticket.serving",
        "ticket.done",
    ]
    for event in shown:
        assert set(event) == {"type", "ticket", "counter", "people_ahead"}
    assert ticket.number in [event["ticket"] for event in shown]


def test_queue_changed_reaches_other_waiting_visits(engine, seeded, events):
    first = make_visit(seeded, "P001")
    second = make_visit(seeded, "P003")
    third = make_visit(seeded, "P006")
    for visit_id in (first, second, third):
        engine.issue_active(visit_id, T1)
    events.clear()
    engine.call_next(T1)
    changed = {"type": "queue.changed", "counter": "Triage 1"}
    assert events.on(channels.visit_channel(second)) == [changed]
    assert events.on(channels.visit_channel(third)) == [changed]
    assert [e["type"] for e in events.on(channels.visit_channel(first))] == ["ticket.called"]


def test_queue_changed_reaches_a_called_ticket_and_only_this_counter(engine, seeded, events):
    called = make_visit(seeded, "P001")
    waiting = make_visit(seeded, "P003")
    elsewhere = make_visit(seeded, "P006")
    engine.issue_active(called, T1)
    engine.issue_active(elsewhere, "C-RAYYAN-T1")
    engine.call_next(T1)
    events.clear()
    engine.issue_active(waiting, T1)
    assert events.on(channels.visit_channel(called)) == [
        {"type": "queue.changed", "counter": "Triage 1"}
    ]
    assert events.on(channels.visit_channel(elsewhere)) == []
