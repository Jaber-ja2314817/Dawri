from __future__ import annotations

import re
import threading

from backend import db
from backend.queue_engine import SqliteQueueEngine
from backend.tests.conftest import make_visit

T1 = "C-WAKRA-T1"
D3 = "C-WAKRA-D3"
D4 = "C-WAKRA-D4"
P1 = "C-WAKRA-P1"


def _issue(engine, conn, counter_id, patient_id="P003"):
    return engine.issue_active(make_visit(conn, patient_id), counter_id)


def test_numbers_are_zero_padded(engine, seeded):
    assert _issue(engine, seeded, T1).number == "T-001"
    assert _issue(engine, seeded, D4).number == "D-GP-001"
    assert _issue(engine, seeded, P1).number == "P-001"
    seeded.execute("UPDATE number_sequence SET last_value = 13 WHERE prefix = 'T'")
    ticket = _issue(engine, seeded, T1)
    assert ticket.number == "T-014" and ticket.seq == 14
    assert re.fullmatch(r"T-\d{3}", ticket.number)


def test_activation_numbers_in_arrival_order(engine, seeded):
    first = engine.issue_ticket(make_visit(seeded, "P001"), T1)
    second = engine.issue_ticket(make_visit(seeded, "P003"), T1)
    assert engine.activate(second.id).number == "T-001"
    assert engine.activate(first.id).number == "T-002"


def test_d_gp_is_shared_across_rooms(engine, seeded):
    numbers = [
        _issue(engine, seeded, counter_id).number
        for counter_id in (D3, D4, D3, D4)
    ]
    assert numbers == ["D-GP-001", "D-GP-002", "D-GP-003", "D-GP-004"]
    assert len(set(numbers)) == 4


def test_prefixes_are_independent(engine, seeded):
    assert _issue(engine, seeded, T1).number == "T-001"
    assert _issue(engine, seeded, T1).number == "T-002"
    assert _issue(engine, seeded, P1).number == "P-001"
    assert _issue(engine, seeded, "C-WAKRA-DEN1").number == "D-DEN-001"


def test_centres_are_independent(engine, seeded):
    assert _issue(engine, seeded, T1).number == "T-001"
    assert _issue(engine, seeded, T1).number == "T-002"
    assert _issue(engine, seeded, "C-RAYYAN-T1").number == "T-001"


def test_next_day_restarts(engine, seeded, clock):
    _issue(engine, seeded, T1)
    assert _issue(engine, seeded, T1).number == "T-002"
    clock.advance(minutes=24 * 60)
    assert _issue(engine, seeded, T1).number == "T-001"


def test_day_boundary_is_doha_not_utc(engine, seeded, clock):
    clock.advance(minutes=14 * 60 + 59)  # 20:59 UTC, 23:59 in Doha
    _issue(engine, seeded, T1)
    assert _issue(engine, seeded, T1).number == "T-002"
    clock.advance(minutes=1)  # 21:00 UTC on the same UTC date, 00:00 in Doha
    assert _issue(engine, seeded, T1).number == "T-001"


def test_eight_threads_get_eight_consecutive_numbers(engine, seeded, db_path, clock):
    tickets = [engine.issue_ticket(make_visit(seeded, "P003"), T1) for _ in range(8)]
    barrier = threading.Barrier(8)
    results, errors = [], []

    def worker(ticket_id):
        # A separate engine per thread: nothing is shared but the database.
        own = SqliteQueueEngine(lambda: db.connect(db_path), clock)
        barrier.wait()
        try:
            results.append(own.activate(ticket_id))
        except Exception as error:  # noqa: BLE001
            errors.append(error)

    threads = [threading.Thread(target=worker, args=(t.id,)) for t in tickets]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert errors == []
    assert sorted(ticket.seq for ticket in results) == list(range(1, 9))
    assert sorted(ticket.number for ticket in results) == [f"T-{n:03d}" for n in range(1, 9)]
