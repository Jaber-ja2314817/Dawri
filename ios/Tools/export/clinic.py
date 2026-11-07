"""The queue, seed and small-function section.

DATA, written to Sources/DawriCore/Resources.

engine.clinic.seed.json
    seed: {centres, counters, dependents, doctors, drugs, patients, staff}, each file of
    backend/seed/ verbatim. Then under their Python names: NEXT_REAL_NUMBER and
    SIMULATED_TICKETS as [key, value] rows in source order, PROTECTED_CENTRES, RESERVATION_MINUTES,
    NO_SHOW_LIMIT, ROLLING_WINDOW, MIN_ROLLING_SAMPLES, MIN_SAMPLE_SEC, GEOFENCE_M, NEAR_KM,
    MUCH_SHORTER_MIN, SIMULATE_INTERVAL_SEC, DEMO_OTP. Also RESERVABLE_STATUSES, NO_TICKET_STATUSES,
    _SIMULATED_NOTE, STAGES, ACTIVE_STATUSES, _AT_THE_CENTRE, _AT_A_COUNTER, _GP_ROUTED and
    _EARTH_RADIUS_M, which the port reads the same way.

engine.clinic.text.json
    medicines: _FREQUENCY_EN, _FREQUENCY_AR, _FORM_AR, _UNIT_AR ([key, value] rows).
    doctors: _CLINIC_EN, _CLINIC_AR, _LANGUAGE_EN, _LANGUAGE_AR, _SPEAKS_AR, _DEFAULT_SPEAKS_AR,
    _MISSING_CLINIC_EN, _MISSING_CLINIC_AR.
    visit_flow: _ALLERGEN_AR. visits: STAFF_ROUTE_EN/AR and CHECK_IN_EN/AR.
    templates, each from calling the real function with sentinels, with {placeholders}:
      doctor_reason.{en,ar}: speaks, not_speaks (ar has one per gender), gender_suffix,
        missing_suffix ({label}), missing_default_label
      suggestion_reason: en, ar ({name} {wait} {usual})
      allergy: en, ar ({allergen} {drug})
      medicine_days: en_one, en_many, ar_one, ar_two, ar_few, ar_many ({days}), ar_many_from
      medicine_line: en, ar ({name} {dose} {frequency} {notes}), bare ("{name}."), joiner.{en,ar}
    Nothing Arabic in this file is retyped by the exporter.

engine.clinic.manifest.json
    As the rules manifest: schema, unidata_version, sources, files.

GOLDENS, written to Fixtures/goldens/clinic. Common layout in common.py.

queue_traces.json   [family, name, setup, ops, final], one row per trace, each on the real
                    SqliteQueueEngine with a fake clock and its own temp database.
                    setup: {start, queue, watch}. start is the clock in UTC. queue is "empty" (no
                    number_sequence rows, so T-001 is first), "sequences" (seed_queue_state with no
                    load, so T-014 is first) or "load" (seed_queue_state with load, and its
                    simulated tickets). watch is the counters snapshotted after every op. It is
                    empty in the lazy_expiry family, because taking a snapshot expires tickets
                    itself, which would hide each method's own lazy expiry.
                    ops rows are [op, args, result, error, messages, snapshots, snapshot_messages]:
                      op         an engine method, or one of the harness steps:
                                 new_visit(patient, status?, created_at?), new_patient(dob),
                                 set_visit_status(visit, status), tick (moves the clock by
                                 kwargs.seconds), add_event(visit, type) as audit.record does
                                 at the clock, or a visit_flow or medicines function:
                                 leave_the_queue(patient, visit), emergency_today(patient,
                                 other_than?), complete_consult(visit, comma-joined drug ids,
                                 actor, kwargs.overrides), dispense(visit, actor) and
                                 for_visit(visit, lang). The last ones take the live ticket of
                                 the visit, and the overrides are allergy_conflicts for its
                                 patient.
                      args       ids as aliases: V1, V2 for visits, T1, T2 for tickets, by first
                                 appearance in the trace. An alias is stable through a trace only.
                      result     the return value as JSON, or null. A Ticket or Position is an
                                 object under its Python field names.
                      error      a QueueError code, or null.
                      messages   [channel, event] rows in publish order. A queue.changed row for
                                 several waiters comes in ix_ticket_queue order: active before
                                 called, and queue order inside each.
                      snapshots  {counter: rows}, queue_snapshot of each watched counter after the
                                 op, as rows in the header's `snapshot_columns` order.
                      snapshot_messages  what taking the snapshots published, which is only ever
                                 a lazy expiry, since queue_snapshot expires first.
                    final is what the database holds when the trace ends, in rowid order:
                      visits     rows of the header's `visit_columns`
                      tickets    [id, day], the column no result shows
                      sequences  [centre_id, prefix, day, last_value]
                      events     [visit_id, type, payload, at], payload parsed
medicines.json      [item, lang, drug, line], drug the seed row or null
doctors.json        [state index, centre, service, patient_lang, gender_pref, limit, suggestions]
                    A suggestion is a row in the header's `suggestion_columns` order. `states` in
                    the header gives the doctor queues: {counter: waiting tickets}. A state with an
                    entry in `extra_counters`, {state index: seed row}, also has that counter.
centres.json        [case, ...] by the first column:
                    ["list", state index, patient, service, lat, lng, status, body] from the
                    real route function. status is 200 or the error status, and body the error
                    code in that case.
                    ["routed_service", service, result]
                    ["nearest_ed", patient, result]
                    ["nearest_emergency", lat, lng, result]
                    ["emergency_list", lat, lng, result]
                    ["rank", entries, lat, lng, ids in result order]
                    ["suggest", entries, lat, lng, result]
geo.json            [lat1, lng1, lat2, lng2, distance_m]
time.json           [function, args, result] for age_on, doha_day, iso and parse round trips
allergy.json        [case, ...] by the first column:
                    ["conflict", patient, drug, result]
                    ["default_items", patient id, forced demo_default drug ids, resolved items]
mock_health.json    [function, args, result] for get_patient, get_dependents, list_demo_patients,
                    get_record and find_by_qid
"""

from __future__ import annotations

import dataclasses
import json
import random
import re
import shutil
import tempfile
import unicodedata
from datetime import date, datetime, timedelta, timezone
from functools import partial
from pathlib import Path

from export import common, variants

SOURCES = (
    "backend/queue_engine.py",
    "backend/adapters/queue_base.py",
    "backend/visit_flow.py",
    "backend/centres.py",
    "backend/simulate.py",
    "backend/geo.py",
    "backend/timeutil.py",
    "backend/mock_health.py",
    "backend/views.py",
    "backend/auth.py",
    "backend/main.py",
    "backend/ai/medicines.py",
    "backend/ai/doctors.py",
    "backend/ai/audit.py",
    "backend/routers/visits.py",
    "backend/routers/auth.py",
    "backend/routers/centres.py",
    "backend/routers/demo.py",
    "backend/seed/centres.json",
    "backend/seed/counters.json",
    "backend/seed/dependents.json",
    "backend/seed/doctors.json",
    "backend/seed/drugs.json",
    "backend/seed/patients.json",
    "backend/seed/staff.json",
)
SEED_FILES = ("centres", "counters", "dependents", "doctors", "drugs", "patients", "staff")

SNAPSHOT_COLUMNS = (
    "ticket_id", "number", "state", "priority", "simulated", "visit_id", "activated_at",
    "called_at", "call_count", "label", "position",
)
VISIT_COLUMNS = ("id", "patient_id", "centre_id", "status", "arrived_at", "completed_at", "booked_by")
SUGGESTION_COLUMNS = (
    "doctor_id", "name", "counter_id", "counter_label", "clinic", "waiting", "speaks_language",
    "gender_ok", "score", "clinic_fallback", "reason_en", "reason_ar",
)
ON = date(2026, 11, 7)
UTC = timezone.utc


def _pairs(table: dict) -> list[list]:
    return [[key, value] for key, value in table.items()]


def seed_data() -> dict:
    from backend import auth, centres, geo, main, queue_engine, simulate
    from backend.routers import visits

    seed = {
        name: json.loads((common.REPO / "backend" / "seed" / f"{name}.json").read_text(encoding="utf-8"))
        for name in SEED_FILES
    }
    return {
        "schema": common.SCHEMA,
        "seed": seed,
        "NEXT_REAL_NUMBER": [[centre, _pairs(row)] for centre, row in simulate.NEXT_REAL_NUMBER.items()],
        "SIMULATED_TICKETS": _pairs(simulate.SIMULATED_TICKETS),
        "PROTECTED_CENTRES": list(simulate.PROTECTED_CENTRES),
        "RESERVATION_MINUTES": queue_engine.RESERVATION_MINUTES,
        "NO_SHOW_LIMIT": queue_engine.NO_SHOW_LIMIT,
        "ROLLING_WINDOW": queue_engine.ROLLING_WINDOW,
        "MIN_ROLLING_SAMPLES": queue_engine.MIN_ROLLING_SAMPLES,
        "MIN_SAMPLE_SEC": queue_engine.MIN_SAMPLE_SEC,
        "GEOFENCE_M": visits.GEOFENCE_M,
        "NEAR_KM": centres.NEAR_KM,
        "MUCH_SHORTER_MIN": centres.MUCH_SHORTER_MIN,
        "SIMULATE_INTERVAL_SEC": main.SIMULATE_INTERVAL_SEC,
        "DEMO_OTP": auth.DEMO_OTP,
        "RESERVABLE_STATUSES": list(queue_engine.RESERVABLE_STATUSES),
        "NO_TICKET_STATUSES": list(queue_engine.NO_TICKET_STATUSES),
        "_SIMULATED_NOTE": queue_engine._SIMULATED_NOTE,
        "STAGES": _pairs(visits.STAGES),
        "ACTIVE_STATUSES": list(visits.ACTIVE_STATUSES),
        "_AT_THE_CENTRE": list(visits._AT_THE_CENTRE),
        "_AT_A_COUNTER": list(visits._AT_A_COUNTER),
        "_GP_ROUTED": list(centres._GP_ROUTED),
        "_EARTH_RADIUS_M": geo._EARTH_RADIUS_M,
    }


def _reason_templates() -> dict:
    from backend.ai import doctors

    def row(gender: str) -> dict:
        return {"name": "{name}", "clinic": "{clinic}", "waiting": "{waiting}", "gender": gender}

    language = "{language}"
    known = next(iter(doctors._MISSING_CLINIC_EN))
    en_speaks = doctors._reason_en(row("M"), language, True, True, None)
    en_not = doctors._reason_en(row("M"), language, False, True, None)
    en_gender = doctors._reason_en(row("M"), language, True, False, None)[len(en_speaks):]
    en_missing = doctors._reason_en(row("M"), language, True, True, known)[len(en_speaks):]
    en_default = doctors._reason_en(row("M"), language, True, True, "⟦none⟧")[len(en_speaks):]

    ar_female = doctors._reason_ar(row("F"), language, True, True, None)
    ar_male = doctors._reason_ar(row("M"), language, True, True, None)
    ar_female_not = doctors._reason_ar(row("F"), language, False, True, None)
    ar_male_not = doctors._reason_ar(row("M"), language, False, True, None)
    ar_gender = doctors._reason_ar(row("M"), language, True, False, None)[len(ar_male):]
    ar_missing = doctors._reason_ar(row("M"), language, True, True, known)[len(ar_male):]
    ar_default = doctors._reason_ar(row("M"), language, True, True, "⟦none⟧")[len(ar_male):]

    en_label = doctors._MISSING_CLINIC_EN[known]
    ar_label = doctors._MISSING_CLINIC_AR[known]
    en_template = en_missing.replace(en_label, "{label}")
    ar_template = ar_missing.replace(ar_label, "{label}")
    head_en, tail_en = en_template.split("{label}")
    head_ar, tail_ar = ar_template.split("{label}")
    return {
        "en": {
            "speaks": en_speaks,
            "not_speaks": en_not,
            "gender_suffix": en_gender,
            "missing_suffix": en_template,
            "missing_default_label": en_default[len(head_en): len(en_default) - len(tail_en)],
        },
        "ar": {
            "speaks": {"F": ar_female, "M": ar_male},
            "not_speaks": {"F": ar_female_not, "M": ar_male_not},
            "gender_suffix": ar_gender,
            "missing_suffix": ar_template,
            "missing_default_label": ar_default[len(head_ar): len(ar_default) - len(tail_ar)],
        },
    }


def _suggestion_template() -> dict:
    from backend import centres

    registered = {"id": "A", "name_en": "a", "name_ar": "a", "lat": 0.0, "lng": 0.0, "registered": True, "wait_min": 2222}
    other = {"id": "B", "name_en": "{name}", "name_ar": "{name}", "lat": 0.0, "lng": 0.0, "registered": False, "wait_min": 1111}
    found = centres.suggest([registered, other], (0.0, 0.0))
    return {
        lang: found[f"reason_{lang}"].replace("1111", "{wait}").replace("2222", "{usual}")
        for lang in ("en", "ar")
    }


def _allergy_template() -> dict:
    from backend import visit_flow

    found = visit_flow.allergy_conflict(
        {"allergies": ["{allergen}"]},
        {"name_en": "{drug}", "name_ar": "{drug}", "allergy_tags": ["{allergen}"]},
    )
    return {"en": found["text_en"], "ar": found["text_ar"]}


def _medicine_templates() -> tuple[dict, dict]:
    from backend.ai import medicines

    def spaced(text: str, value: int) -> str:
        return text.replace(str(value), "{days}")

    many_from = next(days for days in range(3, 400) if medicines._days_ar(days) != spaced(medicines._days_ar(3), 3).replace("{days}", str(days)))
    days = {
        "en_one": medicines._days_en(1),
        "en_many": spaced(medicines._days_en(7), 7),
        "ar_one": medicines._days_ar(1),
        "ar_two": medicines._days_ar(2),
        "ar_few": spaced(medicines._days_ar(3), 3),
        "ar_many": spaced(medicines._days_ar(many_from), many_from),
        "ar_many_from": many_from,
    }
    item = {"drug": "{name}", "dose": "{dose}", "frequency": "{frequency}", "days": None, "notes": "{notes}"}
    line = {
        "en": medicines.plain_line(item, "en"),
        "ar": medicines.plain_line(item, "ar"),
        "bare": medicines.plain_line({"drug": "{name}"}, "en"),
        "joiner": {
            "en": common.literal("backend/ai/medicines.py", "plain_line", ", "),
            "ar": common.literal("backend/ai/medicines.py", "plain_line", "، "),
        },
    }
    return days, line


def text_data() -> dict:
    from backend import visit_flow
    from backend.ai import doctors, medicines
    from backend.routers import visits

    days, line = _medicine_templates()
    return {
        "schema": common.SCHEMA,
        "medicines": {
            name: _pairs(getattr(medicines, name))
            for name in ("_FREQUENCY_EN", "_FREQUENCY_AR", "_FORM_AR", "_UNIT_AR")
        },
        "doctors": {
            "_CLINIC_EN": _pairs(doctors._CLINIC_EN),
            "_CLINIC_AR": _pairs(doctors._CLINIC_AR),
            "_LANGUAGE_EN": _pairs(doctors._LANGUAGE_EN),
            "_LANGUAGE_AR": _pairs(doctors._LANGUAGE_AR),
            "_SPEAKS_AR": _pairs(doctors._SPEAKS_AR),
            "_DEFAULT_SPEAKS_AR": doctors._DEFAULT_SPEAKS_AR,
            "_MISSING_CLINIC_EN": _pairs(doctors._MISSING_CLINIC_EN),
            "_MISSING_CLINIC_AR": _pairs(doctors._MISSING_CLINIC_AR),
        },
        "visit_flow": {"_ALLERGEN_AR": _pairs(visit_flow._ALLERGEN_AR)},
        "visits": {
            "STAFF_ROUTE_EN": visits.STAFF_ROUTE_EN,
            "STAFF_ROUTE_AR": visits.STAFF_ROUTE_AR,
            "CHECK_IN_EN": visits.CHECK_IN_EN,
            "CHECK_IN_AR": visits.CHECK_IN_AR,
        },
        "templates": {
            "doctor_reason": _reason_templates(),
            "suggestion_reason": _suggestion_template(),
            "allergy": _allergy_template(),
            "medicine_days": days,
            "medicine_line": line,
        },
    }


def data() -> dict[str, bytes]:
    documents = {"engine.clinic.seed.json": seed_data(), "engine.clinic.text.json": text_data()}
    files = {name: common.resource_bytes(document) for name, document in documents.items()}
    manifest = {
        "schema": common.SCHEMA,
        "unidata_version": unicodedata.unidata_version,
        "sources": common.sources(SOURCES),
        "files": {name: common.sha256(body) for name, body in sorted(files.items())},
    }
    return {**files, "engine.clinic.manifest.json": common.manifest_bytes(manifest)}


# Databases


class Templates:
    """Seeded database files in a scratch folder, copied once per trace."""

    def __init__(self, scratch: Path) -> None:
        from backend import db, seeding

        self.scratch = scratch
        self.blank = scratch / "template.db"
        conn = db.connect(self.blank)
        db.init_schema(conn)
        seeding.seed_static(conn)
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        conn.close()
        self.serial = 0

    def copy(self) -> Path:
        self.serial += 1
        path = self.scratch / f"run-{self.serial}.db"
        shutil.copy(self.blank, path)
        return path

    def drop(self, path: Path) -> None:
        for suffix in ("", "-wal", "-shm"):
            Path(f"{path}{suffix}").unlink(missing_ok=True)


_ID = re.compile(r"\b(V|tkt)_[0-9a-f]{12}\b")


class Aliases:
    """V_... and tkt_... to V1 and T1 in order of first appearance."""

    def __init__(self) -> None:
        self.names: dict[str, str] = {}
        self.counts = {"V": 0, "tkt": 0}

    def _swap(self, match: re.Match) -> str:
        found = match.group()
        if found not in self.names:
            kind = match.group(1)
            self.counts[kind] += 1
            self.names[found] = f"{'V' if kind == 'V' else 'T'}{self.counts[kind]}"
        return self.names[found]

    def __call__(self, value):
        if isinstance(value, str):
            return _ID.sub(self._swap, value)
        if isinstance(value, dict):
            return {key: self(value[key]) for key in sorted(value)}
        if isinstance(value, (list, tuple)):
            return [self(item) for item in value]
        return value


class Trace:
    def __init__(self, templates: Templates, family: str, name: str, start: datetime, queue: str, watch: list[str]) -> None:
        from backend import db, simulate
        from backend.queue_engine import SqliteQueueEngine

        self.templates = templates
        self.family = family
        self.name = name
        self.path = templates.copy()
        self.clock = common.Clock(start)
        self.published: list[tuple[str, dict]] = []
        self.conn = db.connect(self.path)
        self.engine = SqliteQueueEngine(
            conn_factory=partial(db.connect, self.path),
            clock=self.clock,
            publish=lambda channel, event: self.published.append((channel, event)),
        )
        self.alias = Aliases()
        self.setup = {"start": start.isoformat(), "queue": queue, "watch": watch}
        self.watch = watch
        self.ops: list[list] = []
        if queue != "empty":
            simulate.seed_queue_state(self.engine, self.conn, queue == "load")
        self.published.clear()
        self.patient_serial = 0

    def _new_visit(
        self, patient_id: str, status: str = "intake", created_at: str = "2026-11-06T06:00:00.000000+00:00"
    ) -> str:
        from backend import db

        visit_id = db.new_id("V")
        self.conn.execute(
            "INSERT INTO visit (id, patient_id, status, created_at, booked_by) "
            "VALUES (?, ?, ?, ?, NULL)",
            (visit_id, patient_id, status, created_at),
        )
        return visit_id

    def _new_patient(self, dob: str) -> str:
        self.patient_serial += 1
        patient_id = f"PX{self.patient_serial}"
        self.conn.execute(
            "INSERT INTO patient (id, qid_demo, full_name_en, full_name_ar, dob, sex, preferred_lang, "
            "registered_centre_id, allergies, chronic, active_meds) "
            "VALUES (?, ?, 'Test', 'Test', ?, 'F', 'ar', 'C-WAKRA', '[]', '[]', '[]')",
            (patient_id, f"TEST-{self.patient_serial}", dob),
        )
        return patient_id

    def _add_event(self, visit_id: str, event_type: str) -> None:
        from backend.ai import audit
        from backend.ai.audit import AiEvent

        audit.record(self.conn, visit_id, [AiEvent(event_type, {})], at=self.clock())

    def _leave_the_queue(self, patient_id: str, visit_id: str) -> None:
        from backend import visit_flow

        visit_flow.leave_the_queue(self.engine, patient_id, visit_id)

    def _emergency_today(self, patient_id: str, other_than: str | None = None) -> str | None:
        from backend import visit_flow

        return visit_flow.emergency_today(self.conn, patient_id, self.clock(), other_than)

    def _complete_consult(self, visit_id: str, drugs: str, actor: str, overrides: bool = False):
        from backend import mock_health, visit_flow

        requested = [{"drug_id": drug} for drug in drugs.split(",") if drug]
        items = visit_flow.resolve_items(self.conn, requested)
        row = self.conn.execute("SELECT patient_id FROM visit WHERE id = ?", (visit_id,)).fetchone()
        patient = mock_health.get_patient(self.conn, row["patient_id"], ON)
        conflicts = visit_flow.allergy_conflicts(patient, items) if overrides else ()
        ticket = self.engine.live_ticket(visit_id)
        return visit_flow.complete_consult(self.conn, self.engine, visit_id, ticket, items, actor, conflicts)

    def _dispense(self, visit_id: str, actor: str):
        from backend import visit_flow

        ticket = self.engine.live_ticket(visit_id)
        return visit_flow.dispense(self.conn, self.engine, visit_id, ticket, actor)

    def _for_visit(self, visit_id: str, lang: str) -> list[dict]:
        from backend.ai import medicines

        return medicines.for_visit(self.conn, visit_id, lang)

    def op(self, name: str, *args, **kwargs):
        """Runs one step on the real engine and records everything it did. Returns the value."""
        from backend.adapters.queue_base import QueueError

        self.published.clear()
        result, error = None, None
        try:
            if name == "new_visit":
                result = self._new_visit(*args, **kwargs)
            elif name == "new_patient":
                result = self._new_patient(*args, **kwargs)
            elif name == "set_visit_status":
                self.conn.execute("UPDATE visit SET status = ? WHERE id = ?", (args[1], args[0]))
            elif name == "tick":
                self.clock.advance(seconds=kwargs["seconds"])
            elif name in ("add_event", "leave_the_queue", "emergency_today", "complete_consult", "dispense", "for_visit"):
                result = getattr(self, f"_{name}")(*args, **kwargs)
            else:
                result = getattr(self.engine, name)(*args, **kwargs)
        except QueueError as failure:
            error = failure.code
        messages = list(self.published)
        self.published.clear()
        snapshots = {}
        for counter in self.watch:
            rows = self.engine.queue_snapshot(counter)
            snapshots[counter] = [[row[key] for key in SNAPSHOT_COLUMNS] for row in rows]
        snapshot_messages = list(self.published)
        self.published.clear()
        arguments = {"args": list(args), "kwargs": kwargs}
        plain = dataclasses.asdict(result) if dataclasses.is_dataclass(result) else result
        if isinstance(result, list):
            plain = [dataclasses.asdict(item) if dataclasses.is_dataclass(item) else item for item in result]
        self.ops.append(
            [
                name,
                self.alias(arguments),
                self.alias(plain),
                error,
                self.alias(messages),
                self.alias(snapshots),
                self.alias(snapshot_messages),
            ]
        )
        return result

    def _final(self) -> dict:
        conn = self.conn
        return {
            "visits": [
                [row[key] for key in VISIT_COLUMNS]
                for row in conn.execute("SELECT * FROM visit ORDER BY rowid")
            ],
            "tickets": [
                [row["id"], row["day"]] for row in conn.execute("SELECT id, day FROM ticket ORDER BY rowid")
            ],
            "sequences": [
                [row["centre_id"], row["prefix"], row["day"], row["last_value"]]
                for row in conn.execute("SELECT * FROM number_sequence ORDER BY rowid")
            ],
            "events": [
                [row["visit_id"], row["type"], json.loads(row["payload"]), row["at"]]
                for row in conn.execute("SELECT * FROM event ORDER BY id")
            ],
        }

    def row(self) -> list:
        final = self.alias(self._final())
        self.conn.close()
        self.templates.drop(self.path)
        return [self.family, self.name, self.setup, self.ops, final]


NOON = datetime(2026, 11, 7, 9, 0, tzinfo=UTC)  # 12:00 in Doha.
LATE = datetime(2026, 11, 7, 20, 59, 0, tzinfo=UTC)  # 23:59 in Doha.
T1, D3, D4, P1 = "C-WAKRA-T1", "C-WAKRA-D3", "C-WAKRA-D4", "C-WAKRA-P1"
DEN, WH = "C-WAKRA-DEN1", "C-WAKRA-WH1"
PATIENTS = ("P001", "P002", "P003", "P004", "P005", "P006")


def arrive(trace: Trace, patient: str, counter: str = T1):
    """Reserve and activate a visit, through the engine as the routes do."""
    visit = trace.op("new_visit", patient)
    ticket = trace.op("issue_ticket", visit, counter)
    return visit, trace.op("activate", ticket.id, "button")


def numbering_traces(templates: Templates) -> list[list]:
    rows = []
    centres = {
        "C-WAKRA": ("C-WAKRA-T1", "C-WAKRA-D3", "C-WAKRA-DEN1", "C-WAKRA-WH1", "C-WAKRA-P1"),
        "C-RAYYAN": ("C-RAYYAN-T1", "C-RAYYAN-D1", "C-RAYYAN-P1"),
        "C-MESAIMEER": ("C-MESAIMEER-T1", "C-MESAIMEER-D1", "C-MESAIMEER-P1"),
        "C-AIRPORT": ("C-AIRPORT-T1", "C-AIRPORT-D1", "C-AIRPORT-P1"),
        "C-WESTBAY": ("C-WESTBAY-T1", "C-WESTBAY-D1", "C-WESTBAY-P1"),
    }
    for queue in ("empty", "sequences", "load"):
        for centre, counters in centres.items():
            trace = Trace(templates, "numbering", f"{centre}.{queue}", NOON, queue, list(counters))
            for index, counter in enumerate(counters * 2):
                visit = trace.op("new_visit", PATIENTS[index % len(PATIENTS)])
                trace.op("issue_active", visit, counter)
                trace.op("issue_simulated", counter)
            rows.append(trace.row())
    # Two doctors on one prefix share its numbers, as D3 and D4 do.
    trace = Trace(templates, "numbering", "shared_prefix", NOON, "sequences", [D3, D4])
    for index in range(4):
        trace.op("issue_simulated", D3 if index % 2 else D4)
    rows.append(trace.row())
    # Reserved tickets take no number, so numbers follow arrival and not reservation.
    trace = Trace(templates, "numbering", "reservation_order", NOON, "sequences", [T1])
    first = trace.op("issue_ticket", trace.op("new_visit", "P001"), T1)
    second = trace.op("issue_ticket", trace.op("new_visit", "P006"), T1)
    trace.op("activate", second.id, "qr")
    trace.op("activate", first.id, "geofence")
    rows.append(trace.row())
    return rows


def midnight_traces(templates: Templates) -> list[list]:
    rows = []
    for queue in ("empty", "sequences", "load"):
        for step in (30, 59, 60, 61, 90):
            trace = Trace(templates, "midnight", f"{queue}.{step}", LATE, queue, [T1])
            trace.op("issue_simulated", T1)
            visit = trace.op("new_visit", "P001")
            trace.op("issue_active", visit, T1)
            trace.op("tick", seconds=step)
            trace.op("issue_simulated", T1)
            other = trace.op("new_visit", "P006")
            trace.op("issue_active", other, T1)
            trace.op("call_next", T1)
            rows.append(trace.row())
    # A reservation made before midnight, activated after it, takes the new day's number.
    trace = Trace(templates, "midnight", "reserved_across", LATE, "sequences", [T1])
    ticket = trace.op("issue_ticket", trace.op("new_visit", "P001"), T1)
    trace.op("tick", seconds=120)
    trace.op("activate", ticket.id, "button")
    rows.append(trace.row())
    # The age rule reads the Doha date. These patients turn 65 at Doha's midnight.
    for dob in ("1961-11-08", "1961-11-07", "1961-11-09"):
        trace = Trace(templates, "midnight", f"birthday.{dob}", LATE, "empty", [T1])
        patient = trace.op("new_patient", dob)
        trace.op("issue_active", trace.op("new_visit", patient), T1)
        trace.op("tick", seconds=120)
        trace.op("issue_active", trace.op("new_visit", patient), T1)
        rows.append(trace.row())
    return rows


def priority_traces(templates: Templates) -> list[list]:
    rows = []
    orders = (
        ("P001", "P005", "P006"), ("P005", "P001", "P002"), ("P002", "P005", "P001"),
        ("P006", "P001", "P005"), ("P004", "P005", "P002", "P006"), ("P001", "P006", "P004"),
    )
    for index, order in enumerate(orders):
        trace = Trace(templates, "priority", f"order.{index}", NOON, "sequences", [T1])
        for patient in order:
            arrive(trace, patient)
            trace.op("tick", seconds=5)
        for _ in order:
            called = trace.op("call_next", T1)
            if called.called is not None:
                trace.op("position", called.called.id)
                trace.op("complete", called.called.id)
            trace.op("tick", seconds=60)
        rows.append(trace.row())
    for index, order in enumerate(orders):
        trace = Trace(templates, "priority", f"with_load.{index}", NOON, "load", [T1])
        tickets = []
        for patient in order:
            tickets.append(arrive(trace, patient)[1])
        for ticket in tickets:
            trace.op("position", ticket.id)
        trace.op("call_next", T1)
        rows.append(trace.row())
    # The same stamp: seq decides, and the elderly patient still goes first.
    trace = Trace(templates, "priority", "same_stamp", NOON, "sequences", [T1])
    for patient in ("P001", "P006", "P005"):
        trace.op("issue_active", trace.op("new_visit", patient), T1)
    rows.append(trace.row())
    return rows


def simulated_traces(templates: Templates) -> list[list]:
    rows = []
    for counter in (T1, D3, "C-AIRPORT-T1", "C-MESAIMEER-T1"):
        for count in (0, 1, 3):
            trace = Trace(templates, "simulated", f"{counter}.{count}", NOON, "empty", [counter])
            for _ in range(count):
                trace.op("issue_simulated", counter)
            visit = trace.op("new_visit", "P001")
            ticket = trace.op("issue_active", visit, counter)
            for _ in range(count):
                trace.op("issue_simulated", counter)
            trace.op("position", ticket.id)
            trace.op("counter_wait", counter)
            trace.op("call_next", counter)
            trace.op("complete", ticket.id)
            for _ in range(count + 1):
                trace.op("call_next", counter)
            trace.op("complete_simulated", counter)
            rows.append(trace.row())
    trace = Trace(templates, "simulated", "only_simulated", NOON, "load", [T1])
    for _ in range(4):
        trace.op("call_next", T1)
    trace.op("complete_simulated", T1)
    rows.append(trace.row())
    trace = Trace(templates, "simulated", "complete_never_touches_real", NOON, "load", [T1])
    arrive(trace, "P001")
    for _ in range(5):
        trace.op("complete_simulated", T1)
    trace.op("call_next", T1)
    rows.append(trace.row())
    return rows


def expiry_traces(templates: Templates) -> list[list]:
    rows = []
    for seconds in (2699, 2699.999999, 2700, 2700.000001, 2701, 3600):
        for final in ("activate", "expire_due", "position", "queue_snapshot"):
            trace = Trace(templates, "expiry", f"{final}.{seconds}", NOON, "sequences", [T1])
            visit = trace.op("new_visit", "P001")
            ticket = trace.op("issue_ticket", visit, T1)
            trace.op("position", ticket.id)
            trace.op("tick", seconds=seconds)
            trace.op("live_ticket", visit)
            if final == "activate":
                trace.op("activate", ticket.id, "button")
            elif final == "expire_due":
                trace.op("expire_due")
            elif final == "position":
                trace.op("position", ticket.id)
            else:
                trace.op("queue_snapshot", T1)
            trace.op("latest_ticket", visit)
            rows.append(trace.row())
    # A lapsed reservation can be reserved again, and a second lapse is the same.
    trace = Trace(templates, "expiry", "reserve_again", NOON, "sequences", [T1])
    visit = trace.op("new_visit", "P001")
    trace.op("issue_ticket", visit, T1)
    trace.op("tick", seconds=2700)
    trace.op("expire_due")
    again = trace.op("issue_ticket", visit, T1)
    trace.op("activate", again.id, "button")
    rows.append(trace.row())
    # An emergency that landed during the reservation stays an emergency.
    trace = Trace(templates, "expiry", "emergency_stays", NOON, "sequences", [T1])
    visit = trace.op("new_visit", "P001")
    ticket = trace.op("issue_ticket", visit, T1)
    trace.op("set_visit_status", visit, "redirected_emergency")
    trace.op("activate", ticket.id, "button")
    trace.op("tick", seconds=2700)
    trace.op("expire_due")
    trace.op("issue_ticket", visit, T1)
    rows.append(trace.row())
    # Two lapse together, and they go in the order they were made.
    trace = Trace(templates, "expiry", "two_lapse", NOON, "sequences", [T1])
    trace.op("issue_ticket", trace.op("new_visit", "P006"), T1)
    trace.op("tick", seconds=60)
    trace.op("issue_ticket", trace.op("new_visit", "P001"), T1)
    trace.op("tick", seconds=2640)
    trace.op("expire_due")
    rows.append(trace.row())
    # Released in time, so activate says invalid and not expired.
    trace = Trace(templates, "expiry", "released_in_time", NOON, "sequences", [T1])
    ticket = trace.op("issue_ticket", trace.op("new_visit", "P001"), T1)
    trace.op("release", ticket.id, "cancelled")
    trace.op("activate", ticket.id, "button")
    trace.op("tick", seconds=2800)
    trace.op("activate", ticket.id, "button")
    rows.append(trace.row())
    return rows


def no_show_traces(templates: Templates) -> list[list]:
    rows = []
    for ahead in (0, 1, 3):
        for rounds in (1, 2, 3, 4):
            trace = Trace(templates, "no_show", f"ahead{ahead}.rounds{rounds}", NOON, "sequences", [T1])
            _, ticket = arrive(trace, "P001")
            others = [arrive(trace, PATIENTS[1 + index])[1] for index in range(ahead)]
            for _ in range(rounds):
                trace.op("call_next", T1)
                trace.op("position", ticket.id)
                trace.op("no_show", ticket.id)
                trace.op("position", ticket.id)
                trace.op("tick", seconds=30)
                for other in others:
                    trace.op("position", other.id)
            trace.op("no_show", ticket.id)
            rows.append(trace.row())
    trace = Trace(templates, "no_show", "third_goes_to_the_back", NOON, "sequences", [T1])
    _, first = arrive(trace, "P006")
    _, second = arrive(trace, "P001")
    for _ in range(3):
        called = trace.op("call_next", T1)
        trace.op("no_show", called.called.id)
    trace.op("call_next", T1)
    rows.append(trace.row())
    trace = Trace(templates, "no_show", "not_called", NOON, "sequences", [T1])
    _, ticket = arrive(trace, "P001")
    trace.op("no_show", ticket.id)
    trace.op("serve", ticket.id)
    trace.op("no_show", "tkt_000000000000")
    rows.append(trace.row())
    return rows


def rolling_traces(templates: Templates) -> list[list]:
    rows = []
    spans_table = {
        "below_five": (100, 200, 300, 400),
        "exactly_five": (100, 200, 300, 400, 500),
        "six": (100, 200, 300, 400, 500, 600),
        "short_ignored_below_five": (29, 29, 100, 200, 300, 400),
        "floor_exactly_30": (30, 30, 30, 30, 30),
        "floor_29_out": (29, 30, 30, 30, 30),
        "fractional": (31, 47, 53, 61, 73),
        "over_window": tuple(range(100, 360, 10)),
        "short_inside_window": (29, *range(100, 300, 10)),
        "very_long": (7200, 7200, 7200, 7200, 7200),
        # Newest first, as the query reads them, Python's compensated sum() lands one bit away
        # from plain addition on these.
        "compensated": (768.762208, 106.626251, 628.231464, 364.386696, 99.396117, 191.52923),
    }
    for name, spans in spans_table.items():
        for counter in (T1, P1):
            trace = Trace(templates, "rolling", f"{name}.{counter}", NOON, "empty", [counter])
            for index, seconds in enumerate(spans):
                visit = trace.op("new_visit", PATIENTS[index % len(PATIENTS)])
                ticket = trace.op("issue_active", visit, counter)
                trace.op("call_next", counter)
                trace.op("tick", seconds=seconds)
                trace.op("complete", ticket.id)
                trace.op("avg_service_sec", counter)
                trace.op("counter_wait", counter)
            for _ in range(3):
                trace.op("issue_simulated", counter)
                trace.op("counter_wait", counter)
            rows.append(trace.row())
    # A simulated finish is no sample, and a serve in between changes nothing.
    trace = Trace(templates, "rolling", "simulated_is_no_sample", NOON, "empty", [T1])
    for _ in range(6):
        trace.op("issue_simulated", T1)
        trace.op("tick", seconds=200)
        trace.op("call_next", T1)
        trace.op("avg_service_sec", T1)
    rows.append(trace.row())
    return rows


def flow_traces(templates: Templates) -> list[list]:
    rows = []
    for patient in PATIENTS:
        trace = Trace(templates, "flow", f"whole_visit.{patient}", NOON, "sequences", [T1, D4, P1])
        visit, ticket = arrive(trace, patient)
        called = trace.op("call_next", T1)
        trace.op("serve", called.called.id)
        trace.op("tick", seconds=240)
        doctor = trace.op("advance", ticket.id, D4)
        trace.op("position", doctor.id)
        trace.op("live_ticket", visit)
        trace.op("call_next", D4)
        trace.op("tick", seconds=480)
        pharmacy = trace.op("advance", doctor.id, P1)
        trace.op("call_next", P1)
        trace.op("tick", seconds=180)
        trace.op("finish_visit", pharmacy.id)
        trace.op("latest_ticket", visit)
        trace.op("live_ticket", visit)
        trace.op("centre_wait", "C-WAKRA", "gp")
        rows.append(trace.row())

    # Each way a transition is refused, from each state.
    states = ("reserved", "active", "called", "serving", "done", "released")
    methods = ("activate", "serve", "no_show", "complete", "release", "escalate", "finish_visit", "advance")
    for state in states:
        for method in methods:
            trace = Trace(templates, "transition", f"{method}.from_{state}", NOON, "sequences", [T1, D4])
            visit = trace.op("new_visit", "P001")
            ticket = trace.op("issue_ticket", visit, T1)
            if state != "reserved":
                if state == "released":
                    trace.op("release", ticket.id, "test")
                else:
                    trace.op("activate", ticket.id, "button")
                    if state in ("called", "serving", "done"):
                        trace.op("call_next", T1)
                    if state in ("serving", "done"):
                        trace.op("serve", ticket.id)
                    if state == "done":
                        trace.op("complete", ticket.id)
            if method == "activate":
                trace.op("activate", ticket.id, "button")
            elif method in ("release", "escalate"):
                trace.op(method, ticket.id, "test")
            elif method == "advance":
                trace.op("advance", ticket.id, D4)
            else:
                trace.op(method, ticket.id)
            trace.op("live_ticket", visit)
            rows.append(trace.row())

    trace = Trace(templates, "flow", "refusals", NOON, "sequences", [T1])
    visit = trace.op("new_visit", "P001")
    trace.op("issue_ticket", "V_000000000000", T1)
    trace.op("issue_ticket", visit, D4)
    trace.op("issue_ticket", visit, "C-NOPE")
    trace.op("activate", "tkt_000000000000", "button")
    ticket = trace.op("issue_ticket", visit, T1)
    trace.op("issue_ticket", visit, T1)
    trace.op("issue_active", visit, T1)
    for status in ("redirected_emergency", "deflected_refill", "completed", "cancelled", "in_triage"):
        other = trace.op("new_visit", "P006", status)
        trace.op("issue_ticket", other, T1)
        trace.op("issue_active", other, T1)
    trace.op("call_next", "C-NOPE")
    trace.op("counter_wait", "C-NOPE")
    trace.op("activate", ticket.id, "button")
    trace.op("call_next", T1)
    trace.op("call_next", T1)
    trace.op("serve", ticket.id)
    trace.op("advance", ticket.id, "C-RAYYAN-D1")
    rows.append(trace.row())

    trace = Trace(templates, "flow", "finish_refused_on_emergency", NOON, "sequences", [T1])
    visit, ticket = arrive(trace, "P001")
    trace.op("call_next", T1)
    trace.op("set_visit_status", visit, "redirected_emergency")
    trace.op("finish_visit", ticket.id)
    trace.op("live_ticket", visit)
    rows.append(trace.row())

    # Several waiters hear of one change: active before called, and queue order inside each.
    trace = Trace(templates, "flow", "queue_changed_order", NOON, "sequences", [T1])
    for patient in ("P001", "P006", "P005", "P002"):
        arrive(trace, patient)
    trace.op("call_next", T1)
    trace.op("issue_simulated", T1)
    trace.op("complete_simulated", T1)
    rows.append(trace.row())

    for counter in (T1, D3, D4, DEN, WH, P1):
        trace = Trace(templates, "flow", f"walk_in.{counter}", NOON, "sequences", [counter])
        trace.op("issue_active", trace.op("new_visit", "P005"), counter)
        trace.op("counter_wait", counter)
        trace.op("centre_wait", "C-WAKRA", "gp")
        trace.op("centre_wait", "C-WAKRA", "dental")
        trace.op("centre_wait", "C-WAKRA", "womens_health")
        trace.op("centre_wait", "C-WAKRA", "vaccination")
        trace.op("centre_wait", "H-HGH", "gp")
        trace.op("triage_counter", "C-WAKRA")
        trace.op("triage_counter", "H-HGH")
        rows.append(trace.row())
    return rows


def lazy_expiry_traces(templates: Templates) -> list[list]:
    """Each method after the window ran out, with nothing watched: only what it does itself shows."""
    rows = []
    steps = (
        ("issue_ticket", "third", T1), ("activate", "lapsing_ticket", "button"), ("issue_active", "third", T1),
        ("issue_simulated", T1), ("call_next", T1), ("complete_simulated", T1), ("serve", "called"),
        ("no_show", "called"), ("complete", "called"), ("advance", "called", D4), ("finish_visit", "called"),
        ("release", "called", "test"), ("escalate", "called", "test"), ("expire_due",), ("position", "called"),
        ("live_ticket", "lapsing"), ("live_tickets_of_patient", "P001"), ("latest_ticket", "lapsing"),
        ("queue_snapshot", T1), ("avg_service_sec", T1), ("counter_wait", T1), ("centre_wait", "C-WAKRA", "gp"),
        ("triage_counter", "C-WAKRA"),
    )
    for step in steps:
        trace = Trace(templates, "lazy_expiry", step[0], NOON, "sequences", [])
        lapsing = trace.op("new_visit", "P001")
        lapsing_ticket = trace.op("issue_ticket", lapsing, T1)
        called = trace.op("issue_active", trace.op("new_visit", "P006"), T1)
        trace.op("call_next", T1)
        third = trace.op("new_visit", "P002")
        trace.op("tick", seconds=2700)
        names = {"third": third, "lapsing": lapsing, "lapsing_ticket": lapsing_ticket.id, "called": called.id}
        trace.op(step[0], *(names.get(arg, arg) for arg in step[1:]))
        trace.op("latest_ticket", lapsing)
        rows.append(trace.row())
    return rows


def visit_flow_traces(templates: Templates) -> list[list]:
    rows = []
    stamp = "2026-11-07T09:00:00.000000+00:00"

    def to_stage(trace: Trace, visit: str, stage: str) -> None:
        """Walks a visit to one stage of the whole journey."""
        ticket = trace.op("issue_ticket", visit, T1)
        if stage == "reserved":
            return
        trace.op("activate", ticket.id, "button")
        if stage == "active":
            return
        trace.op("call_next", T1)
        if stage == "called":
            return
        trace.op("serve", ticket.id)
        if stage == "serving":
            return
        doctor = trace.op("advance", ticket.id, D4)
        if stage == "doctor":
            return
        trace.op("call_next", D4)
        pharmacy = trace.op("advance", doctor.id, P1)
        if stage == "pharmacy":
            return
        trace.op("call_next", P1)
        trace.op("finish_visit", pharmacy.id)

    # A red flag at each stage leaves no live ticket, and the day stays stopped.
    for stage in ("intake", "reserved", "active", "called", "serving", "doctor", "pharmacy", "done"):
        trace = Trace(templates, "visit_flow", f"red_flag.{stage}", NOON, "load", [T1, D4, P1])
        visit = trace.op("new_visit", "P001", "intake", stamp)
        if stage != "intake":
            to_stage(trace, visit, stage)
        trace.op("add_event", visit, "redflag.hit")
        trace.op("leave_the_queue", "P001", visit)
        trace.op("live_tickets_of_patient", "P001")
        trace.op("emergency_today", "P001")
        trace.op("emergency_today", "P001", visit)
        trace.op("issue_ticket", visit, T1)
        rows.append(trace.row())

    # The line belongs to the patient: a second visit goes too, and a dependent's does not.
    trace = Trace(templates, "visit_flow", "red_flag.second_visit", NOON, "sequences", [T1])
    first = trace.op("new_visit", "P001", "intake", stamp)
    second = trace.op("new_visit", "P001", "intake", stamp)
    child = trace.op("new_visit", "P004", "intake", stamp)
    trace.op("issue_active", first, T1)
    trace.op("issue_ticket", second, T1)
    trace.op("issue_active", child, T1)
    trace.op("leave_the_queue", "P001", first)
    trace.op("live_tickets_of_patient", "P001")
    trace.op("live_tickets_of_patient", "P004")
    trace.op("emergency_today", "P004")
    rows.append(trace.row())

    # Which day an emergency belongs to, around Doha's midnight.
    for event in ("redflag.hit", "ai.emergency", "ticket.released", "consent", None):
        for step in (30, 90):
            name = f"emergency_day.{event}.{step}"
            trace = Trace(templates, "visit_flow", name, LATE, "sequences", [T1])
            visit = trace.op("new_visit", "P001", "redirected_emergency", "2026-11-07T20:50:00.000000+00:00")
            trace.op("emergency_today", "P001")
            trace.op("tick", seconds=step)
            if event is not None:
                trace.op("add_event", visit, event)
            trace.op("emergency_today", "P001")
            trace.op("emergency_today", "P002")
            trace.op("tick", seconds=86400)
            trace.op("emergency_today", "P001")
            rows.append(trace.row())
    trace = Trace(templates, "visit_flow", "emergency_day.newest_first", NOON, "sequences", [T1])
    older = trace.op("new_visit", "P001", "redirected_emergency", "2026-11-07T06:00:00.000000+00:00")
    newer = trace.op("new_visit", "P001", "redirected_emergency", "2026-11-07T07:00:00.000000+00:00")
    trace.op("emergency_today", "P001")
    trace.op("emergency_today", "P001", newer)
    trace.op("emergency_today", "P001", older)
    trace.op("new_visit", "P001", "completed", "2026-11-07T08:00:00.000000+00:00")
    trace.op("emergency_today", "P001")
    rows.append(trace.row())

    # The consult, through to the plain-language lines.
    consults = (
        ("P001", "DR-DEXT,DR-PARA", False),
        ("P001", "DR-AMOX", True),
        ("P001", "DR-AMOX,DR-PARA,DR-AUGM", True),
        ("P001", "", False),
        ("P002", "DR-AMLO", False),
        ("P005", "DR-IBU,DR-PARA", False),
    )
    for index, (patient, drugs, overrides) in enumerate(consults):
        trace = Trace(templates, "visit_flow", f"consult.{index}", NOON, "sequences", [T1, D4, P1])
        visit = trace.op("new_visit", patient, "intake", stamp)
        to_stage(trace, visit, "doctor")
        trace.op("call_next", D4)
        trace.op("complete_consult", visit, drugs, "S-WAK-DOC2", overrides=overrides)
        trace.op("for_visit", visit, "en")
        trace.op("for_visit", visit, "ar")
        if drugs:
            trace.op("call_next", P1)
            trace.op("dispense", visit, "S-WAK-PHARM1")
            trace.op("for_visit", visit, "ar-gulf")
            trace.op("live_ticket", visit)
        rows.append(trace.row())

    # An uncalled patient is refused, and a second consult replaces the first list.
    trace = Trace(templates, "visit_flow", "consult.refused", NOON, "sequences", [D4, P1])
    visit = trace.op("new_visit", "P001", "intake", stamp)
    trace.op("issue_active", visit, D4)
    trace.op("complete_consult", visit, "DR-PARA", "S-WAK-DOC2")
    trace.op("for_visit", visit, "en")
    trace.op("call_next", D4)
    trace.op("complete_consult", visit, "DR-PARA", "S-WAK-DOC2")
    trace.op("for_visit", visit, "en")
    trace.op("call_next", P1)
    trace.op("complete_consult", visit, "DR-DEXT", "S-WAK-DOC2")
    trace.op("for_visit", visit, "en")
    rows.append(trace.row())

    # A dispense refused on an emergency keeps the visit one, and logs nothing.
    trace = Trace(templates, "visit_flow", "dispense.on_emergency", NOON, "sequences", [P1])
    visit = trace.op("new_visit", "P001", "intake", stamp)
    trace.op("issue_active", visit, P1)
    trace.op("call_next", P1)
    trace.op("set_visit_status", visit, "redirected_emergency")
    trace.op("dispense", visit, "S-WAK-PHARM1")
    trace.op("live_ticket", visit)
    rows.append(trace.row())
    return rows


def random_traces(templates: Templates, count: int) -> list[list]:
    rows = []
    for index in range(count):
        rng = random.Random(variants.SEED + 100 + index)
        queue = rng.choice(("empty", "sequences", "load"))
        start = rng.choice((NOON, LATE, NOON + timedelta(hours=3)))
        trace = Trace(templates, "random", f"seed{index}", start, queue, [T1, D4, P1])
        visits: list[str] = []
        tickets: list[str] = []
        for _ in range(rng.randint(14, 30)):
            choice = rng.random()
            live = tickets[-6:]
            ticket = rng.choice(live) if live else "tkt_000000000000"
            visit = rng.choice(visits) if visits else "V_000000000000"
            counter = rng.choice((T1, T1, D4, P1))
            if choice < 0.14:
                visits.append(trace.op("new_visit", rng.choice(PATIENTS)))
            elif choice < 0.26:
                made = trace.op("issue_ticket", visit, T1)
                if made is not None:
                    tickets.append(made.id)
            elif choice < 0.38:
                made = trace.op("activate", ticket, rng.choice(("button", "qr", "geofence")))
                if made is not None and made.id not in tickets:
                    tickets.append(made.id)
            elif choice < 0.48:
                called = trace.op("call_next", counter)
                if called is not None and called.called is not None and called.called.id not in tickets:
                    tickets.append(called.called.id)
            elif choice < 0.55:
                trace.op("serve", ticket)
            elif choice < 0.61:
                trace.op("no_show", ticket)
            elif choice < 0.67:
                trace.op("complete", ticket)
            elif choice < 0.74:
                made = trace.op("advance", ticket, rng.choice((D4, P1)))
                if made is not None:
                    tickets.append(made.id)
            elif choice < 0.78:
                trace.op("finish_visit", ticket)
            elif choice < 0.81:
                trace.op("release", ticket, "test")
            elif choice < 0.84:
                trace.op("escalate", ticket, "emergency")
            elif choice < 0.87:
                trace.op("issue_simulated", counter)
            elif choice < 0.89:
                trace.op("complete_simulated", counter)
            elif choice < 0.92:
                trace.op("position", ticket)
            elif choice < 0.94:
                trace.op("expire_due")
            else:
                trace.op("tick", seconds=rng.choice((5, 29, 30, 60, 300, 1200, 2700)))
        rows.append(trace.row())
    return rows


def queue_goldens(folder: common.Folder, templates: Templates) -> None:
    rows = [
        *numbering_traces(templates),
        *midnight_traces(templates),
        *priority_traces(templates),
        *simulated_traces(templates),
        *expiry_traces(templates),
        *no_show_traces(templates),
        *rolling_traces(templates),
        *flow_traces(templates),
        *lazy_expiry_traces(templates),
        *visit_flow_traces(templates),
        *random_traces(templates, 60),
    ]
    folder.add(
        "queue_traces", "queue_traces",
        ["family", "name", "setup", "ops", "final"],
        {
            "op_columns": ["op", "args", "result", "error", "messages", "snapshots", "snapshot_messages"],
            "snapshot_columns": list(SNAPSHOT_COLUMNS),
            "visit_columns": list(VISIT_COLUMNS),
        },
        rows,
    )


# The small functions


def seed_rows(name: str) -> list[dict]:
    return json.loads((common.REPO / "backend" / "seed" / f"{name}.json").read_text(encoding="utf-8"))


def medicine_goldens(folder: common.Folder) -> None:
    from backend.ai import medicines

    rng = random.Random(variants.SEED + 10)
    drugs = [None, *seed_rows("drugs")]
    for row in drugs[1:]:
        row["allergy_tags"] = json.dumps(row["allergy_tags"])
    doses = (None, "", "500 mg", "10ml", "5 MG", "1 tablet", "  20 ml  ", "2.5mg", "10 mg/ml", "500mgs")
    frequencies = (
        None, "", "once daily", "Twice Daily", "three times daily", "every 6 hours as needed",
        "every 8 hours as needed", "when you need it", "كل يوم",
    )
    days = (None, 0, 1, 2, 3, 7, 10, 11, 14, 30, "5", 1.5)
    notes = (None, "", "after food", "بعد الأكل", "  ")
    names = ("paracetamol", "", None, "unknown drug", "DR-PARA")
    rows = []
    seen = set()
    while len(rows) < 1300:
        drug = rng.choice(drugs)
        item = {
            "drug": rng.choice(names),
            "dose": rng.choice(doses),
            "frequency": rng.choice(frequencies),
            "days": rng.choice(days),
            "notes": rng.choice(notes),
        }
        lang = rng.choice(("en", "ar", "ar-gulf", "ar-msa"))
        key = common.text_of([item, lang, drug])
        if key in seen:
            continue
        seen.add(key)
        rows.append([item, lang, drug, medicines.plain_line(item, lang, drug)])
    for drug in drugs[1:]:
        for lang in ("en", "ar"):
            item = {"drug": drug["id"], "dose": drug["default_dose"], "frequency": drug["default_frequency"], "days": drug["default_days"], "notes": None}
            rows.append([item, lang, drug, medicines.plain_line(item, lang, drug)])
    folder.add("medicines", "medicines", ["item", "lang", "drug", "line"], {}, rows)


def doctor_goldens(folder: common.Folder, templates: Templates) -> None:
    from backend import db
    from backend.ai import doctors
    from backend.queue_engine import SqliteQueueEngine

    states = (
        {},
        {D3: 1},
        {D4: 2},
        {D3: 3, D4: 1},
        {D3: 1, D4: 1},
        {DEN: 2, WH: 1},
        {"C-RAYYAN-D1": 4, "C-AIRPORT-D1": 2},
    )
    centre_ids = ("C-WAKRA", "C-RAYYAN", "C-MESAIMEER", "C-AIRPORT", "C-WESTBAY", "H-HGH")
    services = ("gp", "dental", "womens_health", "vaccination", "lab_only", "mental_health", "refill", "other")
    second_room = {
        "id": "C-WAKRA-D9", "centre_id": "C-WAKRA", "stage": "doctor", "label": "Room 9", "label_ar": "Room 9",
        "staff_id": "S-WAK-DOC1", "prefix": "D-GP", "avg_service_sec": 480,
    }
    # Kept in full after the sample below: a tie on score that waiting decides, and one doctor
    # on two counters, in both orders, which shows the better one on a single line.
    kept_states = ({D3: 5}, {D4: 5}, {D3: 2}, {"C-WAKRA-D9": 2}, {D3: 1, "C-WAKRA-D9": 1})
    extra_counters = {str(len(states) + index): second_room for index in (2, 3, 4)}

    def open_state(state: dict, extra: dict | None) -> tuple[Path, object]:
        path = templates.copy()
        conn = db.connect(path)
        if extra is not None:
            conn.execute(
                "INSERT INTO counter (id, centre_id, stage, label, label_ar, staff_id, prefix, avg_service_sec) "
                "VALUES (:id, :centre_id, :stage, :label, :label_ar, :staff_id, :prefix, :avg_service_sec)",
                extra,
            )
        engine = SqliteQueueEngine(conn_factory=partial(db.connect, path), clock=common.Clock(NOON))
        for counter, waiting in state.items():
            for _ in range(waiting):
                engine.issue_simulated(counter)
        return path, conn

    rows = []
    for state_index, state in enumerate(states):
        path, conn = open_state(state, None)
        for centre in centre_ids:
            for service in services:
                for lang in ("ar", "en", "fr"):
                    for gender in (None, "F", "M"):
                        for limit in (3, 1):
                            if limit == 1 and (lang != "ar" or gender is not None):
                                continue
                            found = doctors.suggest(conn, centre, service, lang, gender, limit)
                            suggestions = [
                                [getattr(item, key) for key in SUGGESTION_COLUMNS] for item in found
                            ]
                            rows.append([state_index, centre, service, lang, gender, limit, suggestions])
        conn.close()
        templates.drop(path)
    rng = random.Random(variants.SEED + 11)
    rows = [rows[index] for index in sorted(rng.sample(range(len(rows)), 900))]
    for offset, state in enumerate(kept_states):
        state_index = len(states) + offset
        path, conn = open_state(state, extra_counters.get(str(state_index)))
        for lang in ("ar", "en", "fr"):
            for gender in (None, "F", "M"):
                found = doctors.suggest(conn, "C-WAKRA", "gp", lang, gender, 3)
                suggestions = [[getattr(item, key) for key in SUGGESTION_COLUMNS] for item in found]
                rows.append([state_index, "C-WAKRA", "gp", lang, gender, 3, suggestions])
        conn.close()
        templates.drop(path)
    folder.add(
        "doctors", "doctors",
        ["state", "centre", "service", "patient_lang", "gender_pref", "limit", "suggestions"],
        {
            "states": [dict(state) for state in (*states, *kept_states)],
            "extra_counters": extra_counters,
            "suggestion_columns": list(SUGGESTION_COLUMNS),
        },
        rows,
    )


AT_NEAR_KM = (25.307836616006252, 51.50465)


def centre_goldens(folder: common.Folder, templates: Templates) -> None:
    from backend import centres, db, simulate
    from backend.deps import ApiError
    from backend.queue_engine import SqliteQueueEngine
    from backend.routers import centres as routes

    services = ("gp", "dental", "vaccination", "lab_only", "womens_health", "mental_health", "other", "refill", "emergency", "nope")
    locations = (
        (None, None), (25.2, 51.5), (25.17302, 51.59575), (25.27992, 51.43243), (25.3, 51.5),
        (25.1, 51.6), (24.0, 50.0), (25.18, 51.6),
    )
    # Wakra's triage grows, so the suggestion rule has something to say.
    loads = (0, 6, 12, 30)
    rows = []
    for load_index, load in enumerate(loads):
        path = templates.copy()
        conn = db.connect(path)
        engine = SqliteQueueEngine(conn_factory=partial(db.connect, path), clock=common.Clock(NOON))
        simulate.seed_queue_state(engine, conn, True)
        for _ in range(load):
            engine.issue_simulated(T1)
        for patient in PATIENTS:
            for service in services:
                for lat, lng in locations:
                    try:
                        body = routes.list_centres(
                            service=service, lat=lat, lng=lng, visit_id=None,
                            account={"subject_id": patient}, conn=conn, engine=engine,
                        )
                        rows.append(["list", load_index, patient, service, lat, lng, 200, body])
                    except ApiError as error:
                        rows.append(["list", load_index, patient, service, lat, lng, error.status_code, error.code])
        for lat, lng in locations:
            origin = None if lat is None else (lat, lng)
            rows.append(["emergency_list", lat, lng, centres.emergency_list(conn, origin)])
            if origin is not None:
                rows.append(["nearest_emergency", lat, lng, centres.nearest_emergency(conn, lat, lng)])
        for patient in (*PATIENTS, "P999"):
            rows.append(["nearest_ed", patient, centres.nearest_ed(conn, patient)])
        conn.close()
        templates.drop(path)
    for service in (*services, "womens_health"):
        rows.append(["routed_service", service, centres.routed_service(service)])

    entry = lambda ident, wait, registered, lat, lng: {  # noqa: E731
        "id": ident, "name_en": ident, "name_ar": ident, "wait_min": wait,
        "people_ahead": 0, "lat": lat, "lng": lng, "registered": registered,
    }
    sets = (
        [entry("A", 40, True, 25.2, 51.5), entry("B", 20, False, 25.21, 51.5), entry("C", 25, False, 25.22, 51.5)],
        [entry("A", 40, True, 25.2, 51.5), entry("B", 25, False, 25.21, 51.5)],
        [entry("A", 40, True, 25.2, 51.5), entry("B", 26, False, 25.21, 51.5)],
        [entry("A", 15, True, 25.2, 51.5), entry("B", 0, False, 25.21, 51.5)],
        [entry("A", 40, True, 25.2, 51.5), entry("B", 10, False, 25.4, 51.5)],
        [entry("A", 40, False, 25.2, 51.5), entry("B", 10, False, 25.21, 51.5)],
        [entry("A", 40, True, 25.2, 51.5), entry("B", 10, False, 25.21, 51.5), entry("C", 10, False, 25.205, 51.5), entry("D", 10, False, 25.205, 51.5)],
        # Exactly NEAR_KM from (25.2, 51.5), which is still near.
        [entry("A", 40, True, 25.2, 51.5), entry("B", 10, False, *AT_NEAR_KM)],
    )
    assert centres._km((25.2, 51.5), sets[-1][1]) == centres.NEAR_KM
    for entries in sets:
        for point in ((None, None), (25.2, 51.5), (25.25, 51.5)):
            origin = None if point[0] is None else point
            ordered = centres.rank(entries, origin)
            rows.append(["rank", entries, point[0], point[1], [item["id"] for item in ordered]])
            rows.append(["suggest", entries, point[0], point[1], centres.suggest(entries, origin)])
    folder.add("centres", "centres", ["case", "..."], {"loads": list(loads)}, rows)


def geo_goldens(folder: common.Folder) -> None:
    from backend import geo

    rng = random.Random(variants.SEED + 12)
    points = [(row["lat"], row["lng"]) for row in seed_rows("centres")]
    rows = []
    for a in points:
        for b in points:
            rows.append([*a, *b, geo.distance_m(*a, *b)])
    for _ in range(160):
        a = (rng.uniform(-90, 90), rng.uniform(-180, 180))
        b = (rng.uniform(-90, 90), rng.uniform(-180, 180))
        rows.append([*a, *b, geo.distance_m(*a, *b)])
    for metres in (0.0, 1.0, 149.0, 150.0, 151.0, 1000.0):
        lat, lng = points[0]
        moved = lat + metres / 111_195.0
        rows.append([lat, lng, moved, lng, geo.distance_m(lat, lng, moved, lng)])
    rows.append([0.0, 0.0, 0.0, 180.0, geo.distance_m(0.0, 0.0, 0.0, 180.0)])
    rows.append([90.0, 0.0, -90.0, 0.0, geo.distance_m(90.0, 0.0, -90.0, 0.0)])
    rows.append([0.0, -180.0, 0.0, 180.0, geo.distance_m(0.0, -180.0, 0.0, 180.0)])
    folder.add("geo", "geo", ["lat1", "lng1", "lat2", "lng2", "distance_m"], {}, rows)


def time_goldens(folder: common.Folder) -> None:
    from backend import timeutil

    rows = []
    instants = [
        datetime(2026, 11, 7, 20, 59, 59, 999999, tzinfo=UTC),
        datetime(2026, 11, 7, 21, 0, 0, tzinfo=UTC),
        datetime(2026, 11, 7, 9, 0, 0, tzinfo=UTC),
        datetime(2026, 12, 31, 21, 0, 0, tzinfo=UTC),
        datetime(2024, 2, 28, 21, 0, 0, tzinfo=UTC),
        datetime(2026, 11, 7, 0, 30, 0, tzinfo=timezone(timedelta(hours=3))),
        datetime(2026, 11, 7, 23, 30, 0, tzinfo=timezone(timedelta(hours=-5))),
        datetime(2026, 11, 7, 12, 0, 0),
    ]
    for instant in instants:
        rows.append(["doha_day", [instant.isoformat()], timeutil.doha_day(instant)])
        rows.append(["iso", [instant.isoformat()], timeutil.iso(instant)])
        rows.append(["parse", [instant.isoformat()], timeutil.iso(timeutil.parse(instant.isoformat()))])
    rng = random.Random(variants.SEED + 13)
    for _ in range(40):
        instant = NOON + timedelta(days=rng.randint(-900, 900), seconds=rng.randint(0, 86399), microseconds=rng.randint(0, 999999))
        rows.append(["doha_day", [instant.isoformat()], timeutil.doha_day(instant)])
        rows.append(["iso", [instant.isoformat()], timeutil.iso(instant)])
    births = ("1992-03-14", "1959-07-02", "1981-11-20", "2019-05-10", "1948-02-21", "1970-09-09", "1961-11-07", "2000-02-29", "2024-02-29")
    days = (
        date(2026, 11, 7), date(2026, 3, 13), date(2026, 3, 14), date(2026, 3, 15), date(2028, 2, 28),
        date(2028, 2, 29), date(2028, 3, 1), date(2027, 2, 28), date(2027, 3, 1),
    )
    for dob in births:
        for day in days:
            rows.append(["age_on", [dob, day.isoformat()], timeutil.age_on(dob, day)])
        for instant in instants[:5]:
            rows.append(["age_on", [dob, instant.isoformat()], timeutil.age_on(dob, instant)])
    folder.add("time", "time", ["function", "args", "result"], {}, rows)


def allergy_goldens(folder: common.Folder, templates: Templates) -> None:
    from backend import db, mock_health, visit_flow

    path = templates.copy()
    conn = db.connect(path)
    patients = [mock_health.get_patient(conn, patient, ON) for patient in PATIENTS]
    synthetic = [
        {"allergies": ["Penicillin "]}, {"allergies": ["nsaid"]}, {"allergies": ["NSAID", "penicillin"]},
        {"allergies": ["amox"]}, {"allergies": [""]}, {"allergies": ["  "]}, {"allergies": []},
        {"allergies": None}, {}, {"allergies": ["sulfa"]}, {"allergies": ["ibuprofen"]},
    ]
    drugs = [dict(row) for row in conn.execute("SELECT * FROM drug ORDER BY id")]
    rows = []
    for patient in [*patients, *synthetic]:
        for drug in drugs:
            rows.append(["conflict", patient, drug, visit_flow.allergy_conflict(patient, drug)])
    for forced in ((), ("DR-AMOX",), ("DR-AUGM",), ("DR-AMOX", "DR-IBU"), ("DR-IBU",), ("DR-AMOX", "DR-AUGM", "DR-IBU")):
        conn.execute("UPDATE drug SET demo_default = (id IN ('DR-PARA', 'DR-DEXT'))")
        for drug in forced:
            conn.execute("UPDATE drug SET demo_default = 1 WHERE id = ?", (drug,))
        for patient in patients:
            items = visit_flow.default_items(conn, patient)
            shown = [
                {"drug_id": item["drug"]["id"], "dose": item["dose"], "frequency": item["frequency"],
                 "days": item["days"], "notes": item["notes"]}
                for item in items
            ]
            rows.append(["default_items", patient["id"], list(forced), shown])
    conn.close()
    templates.drop(path)
    folder.add("allergy", "allergy", ["case", "..."], {}, rows)


def mock_health_goldens(folder: common.Folder, templates: Templates) -> None:
    from backend import db, mock_health

    path = templates.copy()
    conn = db.connect(path)
    rows = []
    dates = (ON, date(2026, 3, 13), date(2026, 3, 14), datetime(2026, 11, 7, 21, 0, tzinfo=UTC))
    for patient in (*PATIENTS, "P999"):
        for on in dates:
            rows.append(["get_patient", [patient, on.isoformat()], mock_health.get_patient(conn, patient, on)])
            rows.append(["get_dependents", [patient, on.isoformat()], mock_health.get_dependents(conn, patient, on)])
        rows.append(["get_record", [patient], mock_health.get_record(conn, patient)])
    rows.append(["list_demo_patients", [], mock_health.list_demo_patients(conn)])
    common.CLOCK.set(common.START)
    for qid in ("DEMO-10001", "DEMO-10002", "DEMO-10003", "DEMO-10004", "DEMO-99999", ""):
        rows.append(["find_by_qid", [qid], mock_health.find_by_qid(conn, qid)])
    conn.close()
    templates.drop(path)
    folder.add("mock_health", "mock_health", ["function", "args", "result"], {"clock": common.START.isoformat()}, rows)


def goldens() -> dict[str, bytes]:
    folder = common.Folder("clinic", SOURCES)
    with tempfile.TemporaryDirectory(prefix="dawri-clinic-") as scratch:
        templates = Templates(Path(scratch))
        queue_goldens(folder, templates)
        medicine_goldens(folder)
        doctor_goldens(folder, templates)
        centre_goldens(folder, templates)
        geo_goldens(folder)
        time_goldens(folder)
        allergy_goldens(folder, templates)
        mock_health_goldens(folder, templates)
    return folder.finish()
