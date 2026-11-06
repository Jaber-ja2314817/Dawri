"""Which centres a patient can use, and the one rule that suggests another.

No model is involved. A suggestion is a rule over the wait numbers, its reason is a
fixed template, and it never changes the patient's default centre.
"""

from __future__ import annotations

import sqlite3
from collections.abc import Iterable, Sequence

from backend import db, geo

NEAR_KM = 12
MUCH_SHORTER_MIN = 15

_GP_ROUTED = ("mental_health", "other", "refill")

Point = tuple[float, float]


def routed_service(service: str) -> str:
    """The service a centre has to offer. These three are seen by a GP first."""
    return "gp" if service in _GP_ROUTED else service


def _km(origin: Point, row: sqlite3.Row | dict) -> float:
    return geo.distance_m(*origin, row["lat"], row["lng"]) / 1000


def _summary(row: sqlite3.Row) -> dict:
    return {key: row[key] for key in ("id", "name_en", "name_ar", "operator", "lat", "lng")}


def registered_centre(conn: sqlite3.Connection, patient_id: str) -> sqlite3.Row | None:
    return conn.execute(
        "SELECT centre.* FROM centre "
        "JOIN patient ON patient.registered_centre_id = centre.id "
        "WHERE patient.id = ?",
        (patient_id,),
    ).fetchone()


def _hospitals(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    return conn.execute("SELECT * FROM centre WHERE has_emergency = 1 ORDER BY id").fetchall()


def nearest_emergency(conn: sqlite3.Connection, lat: float, lng: float) -> dict | None:
    origin = (lat, lng)
    hospital = min(_hospitals(conn), key=lambda row: _km(origin, row), default=None)
    if hospital is None:
        return None
    summary = _summary(hospital)
    del summary["operator"]
    return {**summary, "distance_km": round(_km(origin, hospital), 1)}


def nearest_ed(conn: sqlite3.Connection, patient_id: str) -> dict | None:
    """Measured from the registered centre, because the chat has no location."""
    home = registered_centre(conn, patient_id)
    return None if home is None else nearest_emergency(conn, home["lat"], home["lng"])


def emergency_list(conn: sqlite3.Connection, origin: Point | None) -> list[dict]:
    """Emergency departments by distance. They take no ticket, so they show no wait."""
    entries = [
        {
            **_summary(row),
            "wait_min": None,
            "people_ahead": None,
            "distance_km": None if origin is None else round(_km(origin, row), 1),
            "registered": False,
        }
        for row in _hospitals(conn)
    ]
    if origin is not None:
        entries.sort(key=lambda entry: _km(origin, entry))
    return entries


def offering(conn: sqlite3.Connection, service: str) -> list[sqlite3.Row]:
    """PHCC centres with this service. Hospitals are for emergencies only."""
    rows = conn.execute("SELECT * FROM centre WHERE operator = 'PHCC' ORDER BY id").fetchall()
    return [row for row in rows if service in db.loads_list(row["services"])]


def entry(
    row: sqlite3.Row, wait: dict, located_at: Point | None, registered_id: str | None
) -> dict:
    return {
        **_summary(row),
        "wait_min": wait["wait_min"],
        "people_ahead": wait["people_ahead"],
        "distance_km": None if located_at is None else round(_km(located_at, row), 1),
        "registered": row["id"] == registered_id,
    }


def rank(entries: Iterable[dict], located_at: Point | None) -> list[dict]:
    """Registered centre first, then nearest if we have a location, else shortest wait."""

    def order(item: dict) -> tuple[bool, float, str]:
        measure = item["wait_min"] if located_at is None else _km(located_at, item)
        return (not item["registered"], measure, item["id"])

    return sorted(entries, key=order)


def suggest(entries: Sequence[dict], reference: Point | None) -> dict | None:
    """Another centre that is near and much shorter, or None."""
    registered = next((item for item in entries if item["registered"]), None)
    if registered is None or reference is None:
        return None
    longest_wait = registered["wait_min"] - MUCH_SHORTER_MIN
    candidates = [
        item
        for item in entries
        if not item["registered"]
        and _km(reference, item) <= NEAR_KM
        and item["wait_min"] <= longest_wait
    ]
    if not candidates:
        return None
    best = min(candidates, key=lambda item: (item["wait_min"], _km(reference, item), item["id"]))
    wait, usual = best["wait_min"], registered["wait_min"]
    return {
        "centre_id": best["id"],
        "reason_en": f"{best['name_en']} is close by: about {wait} min, "
        f"against about {usual} min at your registered centre.",
        "reason_ar": f"{best['name_ar']} قريب منك: حوالي {wait} دقيقة، "
        f"مقابل حوالي {usual} دقيقة في مركزك المسجل.",
    }
