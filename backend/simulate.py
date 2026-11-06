"""Demo queue state: sequence starts, simulated waiting tickets and the load tick.

tick() keeps the other centres' triage queues moving, one ticket at a time around
their seed counts, so their waits stay steady. Protected centres are left alone:
a tick there would consume numbers and break T-014 between a reset and the demo.
"""

from __future__ import annotations

import sqlite3
from collections import Counter
from contextlib import closing

from backend import db, timeutil
from backend.queue_engine import SqliteQueueEngine

# The next real number per (centre, prefix) on a fresh reset.
NEXT_REAL_NUMBER = {
    "C-WAKRA": {"T": 14, "D-GP": 23, "P": 31},
    "C-AIRPORT": {"T": 21, "D-GP": 15, "P": 12},
    "C-RAYYAN": {"T": 9, "D-GP": 6, "P": 7},
    "C-MESAIMEER": {"T": 18, "D-GP": 11, "P": 9},
    "C-WESTBAY": {"T": 16, "D-GP": 10, "P": 8},
}

PROTECTED_CENTRES = ("C-WAKRA",)

SIMULATED_TICKETS = {
    "C-WAKRA-T1": 3,
    "C-WAKRA-D3": 1,
    "C-AIRPORT-T1": 7,
    "C-AIRPORT-D1": 1,
    "C-RAYYAN-T1": 4,
    "C-MESAIMEER-T1": 5,
    "C-MESAIMEER-D1": 1,
    "C-WESTBAY-T1": 6,
    "C-WESTBAY-D1": 1,
}


def seed_queue_state(
    engine: SqliteQueueEngine, conn: sqlite3.Connection, simulate_load: bool
) -> None:
    """Start today's sequences so the real numbers land the same with or without load."""
    day = timeutil.doha_day(engine.clock())
    tickets = SIMULATED_TICKETS if simulate_load else {}
    simulated = Counter()
    for counter_id, count in tickets.items():
        counter = conn.execute(
            "SELECT centre_id, prefix FROM counter WHERE id = ?", (counter_id,)
        ).fetchone()
        simulated[counter["centre_id"], counter["prefix"]] += count

    with db.transaction(conn):
        for centre_id, prefixes in NEXT_REAL_NUMBER.items():
            for prefix, next_real in prefixes.items():
                conn.execute(
                    "INSERT INTO number_sequence (centre_id, prefix, day, last_value) "
                    "VALUES (?, ?, ?, ?) "
                    "ON CONFLICT (centre_id, prefix, day) "
                    "DO UPDATE SET last_value = excluded.last_value",
                    (centre_id, prefix, day, next_real - 1 - simulated[centre_id, prefix]),
                )

    for counter_id, count in tickets.items():
        for _ in range(count):
            engine.issue_simulated(counter_id)


def _tick_counters(conn: sqlite3.Connection) -> list[tuple[str, int, int]]:
    """Each ticked counter with its seed target and its waiting simulated tickets."""
    ticked = []
    for counter_id, target in SIMULATED_TICKETS.items():
        counter = conn.execute(
            "SELECT centre_id, stage FROM counter WHERE id = ?", (counter_id,)
        ).fetchone()
        if counter["stage"] != "triage" or counter["centre_id"] in PROTECTED_CENTRES:
            continue
        waiting = conn.execute(
            "SELECT COUNT(*) FROM ticket WHERE counter_id = ? AND state = 'active' "
            "AND simulated = 1",
            (counter_id,),
        ).fetchone()[0]
        ticked.append((counter_id, target, waiting))
    return ticked


def tick(engine: SqliteQueueEngine) -> None:
    """Move each counter one ticket towards or away from its target, so it stays within one."""
    with closing(db.connect()) as conn:
        ticked = _tick_counters(conn)
    for counter_id, target, waiting in ticked:
        if waiting >= target:
            engine.complete_simulated(counter_id)
        else:
            engine.issue_simulated(counter_id)
