from __future__ import annotations

import inspect

import pytest

from backend.adapters.queue_base import CounterBusy, QueueAdapter
from backend.tests.conftest import make_visit

T1 = "C-WAKRA-T1"
D4 = "C-WAKRA-D4"


def _walk_in(engine, conn, patient_id="P003", counter_id=T1):
    return engine.issue_active(make_visit(conn, patient_id), counter_id)


def test_arrival_beats_reservation_time(engine, seeded, clock):
    home = engine.issue_ticket(make_visit(seeded, "P001"), T1)
    clock.advance(minutes=1)
    walk_in = _walk_in(engine, seeded)
    clock.advance(minutes=1)
    engine.activate(home.id)
    assert engine.call_next(T1).called.id == walk_in.id
    engine.complete(walk_in.id)
    assert engine.call_next(T1).called.id == home.id


def test_arrival_order_across_three(engine, seeded, clock):
    tickets = []
    for patient_id in ("P001", "P003", "P006"):
        tickets.append(_walk_in(engine, seeded, patient_id))
        clock.advance(seconds=30)
    for ticket in tickets:
        assert engine.call_next(T1).called.id == ticket.id
        engine.complete(ticket.id)


def test_arrival_outranks_seq_across_doha_midnight(engine, seeded, clock):
    """The sequence restarts at midnight, so seq alone would put 00:05 ahead of 23:50."""
    clock.advance(minutes=14 * 60 + 50)  # 20:50 UTC, 23:50 in Doha
    seeded.execute(
        "INSERT INTO number_sequence (centre_id, prefix, day, last_value) "
        "VALUES ('C-WAKRA', 'T', '2026-11-06', 49)"
    )
    before = _walk_in(engine, seeded, "P001")
    clock.advance(minutes=15)  # 00:05 in Doha, the sequence starts over
    after = _walk_in(engine, seeded, "P003")
    assert (before.number, after.number) == ("T-050", "T-001")
    assert engine.position(after.id).people_ahead == 1
    assert engine.call_next(T1).called.id == before.id


def test_same_stamp_falls_back_to_seq(engine, seeded):
    first = _walk_in(engine, seeded, "P001")
    second = _walk_in(engine, seeded, "P003")
    assert first.activated_at == second.activated_at
    assert engine.call_next(T1).called.id == first.id


def test_doctor_ticket_joins_behind_those_waiting(engine, seeded, clock):
    waiting = _walk_in(engine, seeded, "P003", D4)
    clock.advance(minutes=1)
    triage = _walk_in(engine, seeded, "P001")
    engine.call_next(T1)
    engine.complete(triage.id)
    doctor = engine.issue_active(triage.visit_id, D4)
    assert engine.position(doctor.id).people_ahead == 1
    assert engine.call_next(D4).called.id == waiting.id


def test_older_patient_goes_first(engine, seeded, clock):
    fatima = _walk_in(engine, seeded, "P001")
    assert fatima.priority == 0
    clock.advance(minutes=1)
    ahmed = _walk_in(engine, seeded, "P002")
    assert ahmed.priority == 1
    assert engine.position(ahmed.id).people_ahead == 0
    assert engine.position(fatima.id).people_ahead == 1
    assert engine.call_next(T1).called.id == ahmed.id


def test_priority_tickets_keep_arrival_order(engine, seeded, clock):
    _walk_in(engine, seeded, "P001")
    clock.advance(minutes=1)
    ahmed = _walk_in(engine, seeded, "P002")
    clock.advance(minutes=1)
    mariam = _walk_in(engine, seeded, "P005")
    assert engine.call_next(T1).called.id == ahmed.id
    engine.complete(ahmed.id)
    assert engine.call_next(T1).called.id == mariam.id


def test_priority_is_set_at_activation(engine, seeded):
    ticket = engine.issue_ticket(make_visit(seeded, "P002"), T1)
    assert ticket.priority == 0
    assert engine.activate(ticket.id).priority == 1


def test_priority_follows_the_centre_rule(engine, seeded):
    seeded.execute("UPDATE centre SET priority_age_min = 70 WHERE id = 'C-WAKRA'")
    assert _walk_in(engine, seeded, "P002").priority == 0
    assert _walk_in(engine, seeded, "P005").priority == 1


def test_dependent_age_decides_not_the_guardian(engine, seeded):
    """Fatima (34) books for her mother (78) and for a child: the patient decides."""
    mother = make_visit(seeded, "P005", booked_by="P001")
    assert engine.issue_active(mother, T1).priority == 1

    reserved = engine.issue_ticket(make_visit(seeded, "P005", booked_by="P001"), T1)
    assert engine.activate(reserved.id).priority == 1

    child = make_visit(seeded, "P004", booked_by="P001")
    assert engine.issue_active(child, T1).priority == 0


def test_no_public_method_takes_priority_or_position():
    methods = inspect.getmembers(QueueAdapter, inspect.isfunction)
    assert methods
    for name, method in methods:
        parameters = inspect.signature(method).parameters
        assert "priority" not in parameters, name
        assert "position" not in parameters, name


def test_no_show_stays_at_front_twice_then_goes_behind(engine, seeded, clock):
    late = _walk_in(engine, seeded, "P001")
    clock.advance(minutes=1)
    other = _walk_in(engine, seeded, "P003")

    for call in (1, 2):
        clock.advance(minutes=1)
        called = engine.call_next(T1).called
        assert called.id == late.id and called.call_count == call
        ticket = engine.no_show(late.id)
        assert ticket.activated_at == late.activated_at
        assert ticket.seq == late.seq
        assert engine.position(late.id).people_ahead == 0

    clock.advance(minutes=1)
    assert engine.call_next(T1).called.id == late.id
    moved = engine.no_show(late.id)
    assert moved.number == late.number
    assert moved.activated_at > late.activated_at
    assert moved.seq > other.seq
    assert engine.position(late.id).people_ahead == 1
    assert engine.call_next(T1).called.id == other.id


def test_counter_busy_while_called_or_serving(engine, seeded):
    first = _walk_in(engine, seeded, "P001")
    second = _walk_in(engine, seeded, "P003")
    engine.call_next(T1)
    with pytest.raises(CounterBusy) as error:
        engine.call_next(T1)
    assert error.value.code == "counter_busy"
    engine.serve(first.id)
    with pytest.raises(CounterBusy):
        engine.call_next(T1)
    assert engine.position(second.id).state == "active"
    engine.complete(first.id)
    assert engine.call_next(T1).called.id == second.id


def test_snapshot_lists_called_first_then_order(engine, seeded, clock):
    called = _walk_in(engine, seeded, "P001")
    engine.call_next(T1)
    clock.advance(minutes=1)
    plain = _walk_in(engine, seeded, "P003")
    clock.advance(minutes=1)
    priority = _walk_in(engine, seeded, "P002")
    snapshot = engine.queue_snapshot(T1)
    assert [row["ticket_id"] for row in snapshot] == [called.id, priority.id, plain.id]
    assert [row["position"] for row in snapshot] == [None, 1, 2]
    assert set(snapshot[0]) == {
        "ticket_id",
        "number",
        "state",
        "priority",
        "simulated",
        "visit_id",
        "activated_at",
        "called_at",
        "call_count",
        "label",
        "position",
    }
