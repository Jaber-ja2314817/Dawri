"""A read of the queue must see one moment, whatever call_next does beside it."""

from __future__ import annotations

import pytest

from backend import queue_engine
from backend.tests.conftest import make_visit

T1 = "C-WAKRA-T1"


def active_ticket(engine, conn):
    ticket = engine.issue_ticket(make_visit(conn, "P001"), T1)
    return engine.activate(ticket.id)


@pytest.fixture
def call_next_mid_read(engine, monkeypatch):
    """Arms a call_next, committed on its own connection, just before the next _active read."""
    real_active = queue_engine._active
    state = {"armed": False, "ran": False}

    def racing(conn, counter_id):
        if state["armed"]:
            state["armed"] = False  # call_next reads _active too, and must not land back here.
            assert engine.call_next(counter_id).called is not None
            state["ran"] = True
        return real_active(conn, counter_id)

    monkeypatch.setattr(queue_engine, "_active", racing)
    return state


def test_position_survives_call_next_between_its_reads(engine, seeded, call_next_mid_read):
    ticket = active_ticket(engine, seeded)
    call_next_mid_read["armed"] = True

    position = engine.position(ticket.id)

    assert call_next_mid_read["ran"]
    # The answer is the moment the read began. The ticket really was next.
    assert (position.state, position.people_ahead) == ("active", 0)
    # A later read shows the call.
    assert engine.position(ticket.id).state == "called"


def test_queue_snapshot_never_loses_a_ticket_between_its_reads(
    engine, seeded, call_next_mid_read
):
    ticket = active_ticket(engine, seeded)
    call_next_mid_read["armed"] = True

    rows = engine.queue_snapshot(T1)

    assert call_next_mid_read["ran"]
    # Read in two steps, it would be off the waiting list and not yet at the counter.
    assert [row["ticket_id"] for row in rows] == [ticket.id]
