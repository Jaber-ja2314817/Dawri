"""Whole conversations and whole visits. It has no data resources, only goldens.

Written to Fixtures/goldens/journeys. Common layout in common.py.

sessions.json
    [family, patient, on, initial, turns], one row per conversation, each on its own visit in a
    temp database, through session.handle_message with the fixed date `on`.
    initial is null for a new visit, or {status, state} for one that starts with a stored
    transcript, as the harvested calls do. state is {messages, denied, language, last_turn}.
    A turn is a row in the header's `turn_columns` order:
      do       say                 session.handle_message(text)
               past_arrival        session.red_flag_past_arrival(text), what the chat route does
                                   for a patient in triage, with a doctor or at the pharmacy
               continue_refill     session.continue_after_refill
               set_status          writes the status `text` straight to the visit row, the way a
                                   reservation, an arrival or a completion would have
      text     the input
      error    a SessionError code, or null
      result   null on an error or a set_status. For continue_refill, the intake as an
               `intake_keys` row. Otherwise a row in `result_columns` order, with its intake as an
               `intake_keys` row.
      status   visit.status after the step
      service  visit.service after the step
      added    the stored messages this step added, as [role, content, slot], role 0 user, 1
               assistant
      count    how many messages are stored now, which is 0 while no transcript exists
      denied   the stored denied list
      language the stored language, or null while no transcript exists
      last_turn  the stored last_turn as a `last_turn_columns` row, or null. Its intake is the
               patient's view, as an object.
      events   the event rows this step wrote, as [type, payload]

    Plans cross complaint family, duration, severity form, medicine answer and concern answer by
    stepping each through its own list, whose lengths share no factor. See variants.plans.

api.json
    [walk, step, actor, method, path, request, status, response], in order, through the FastAPI app
    in process with TestClient on the simulated path. Each walk starts from /api/demo/reset with
    the clock at common.START, and the clock moves one second before each request. A step whose
    actor is "harness" is not a request: it wrote `request` to the temp database, and a test
    harness has to do the same.

    Scrubbing runs over path, request and response, in that order, with sorted object keys:
      a `token` value      "<token>"
      V_...                V1, V2 by first appearance in the walk
      tkt_...              T1, T2 by first appearance in the walk
      a UTC timestamp      time1, time2 by first appearance in the walk
    So to compare with LocalClinicService, apply the same pass to its responses. The same instant
    gets the same alias, so a port's clock must stand still within a request and move between
    two requests.

refusals.json
    [name, setup, actor, method, path, request, status, response]. Every error a patient route
    can return, each on a fresh demo, scrubbed the same way. response is the whole body: {error,
    message} and any of message_ar, visit_id, distance_m. setup is what had to happen first:
    [actor, method, path, request] rows from that fresh demo, in order, each of which succeeded.
    An actor of "clock" moved the clock by request.minutes, and "harness" wrote to the temp
    database, because a few states cannot be reached by a patient alone. Each setup row also
    moved the clock one second, as in api.json.
"""

from __future__ import annotations

import json
import os
import random
import re
import tempfile
from datetime import date, timedelta
from pathlib import Path

from export import clinic, common, rules, variants

SOURCES = (
    "backend/ai/session.py",
    "backend/ai/receptionist.py",
    "backend/ai/simulated.py",
    "backend/ai/redflags.py",
    "backend/ai/refill.py",
    "backend/ai/filters.py",
    "backend/ai/text.py",
    "backend/ai/intake.py",
    "backend/ai/medicines.py",
    "backend/ai/handoff.py",
    "backend/queue_engine.py",
    "backend/visit_flow.py",
    "backend/views.py",
    "backend/deps.py",
    "backend/main.py",
    "backend/centres.py",
    "backend/mock_health.py",
    "backend/routers/visits.py",
    "backend/routers/auth.py",
    "backend/routers/centres.py",
    "backend/routers/demo.py",
    "backend/routers/staff.py",
)
ON = date(2026, 11, 7)
TURN_COLUMNS = (
    "do", "text", "error", "result", "status", "service", "added", "count", "denied", "language",
    "last_turn", "events",
)
RESULT_COLUMNS = (
    "reply", "done", "emergency", "intake", "refill", "denied", "source", "emergency_category",
    "self_harm", "language", "slot", "fired",
)
LAST_TURN_COLUMNS = (
    "reply", "done", "emergency", "intake", "refill", "denied", "ai_source", "self_harm",
    "emergency_category",
)
CLOSED = ("reserved", "expired", "deflected_refill", "redirected_emergency", "in_triage", "completed")
AT_THE_CENTRE = ("in_triage", "in_doctor", "in_pharmacy")


def result_row(result) -> list:
    return [
        result.reply,
        result.done,
        result.emergency,
        rules.intake_row(result.intake),
        result.refill,
        result.denied,
        result.source,
        result.emergency_category,
        result.self_harm,
        result.language,
        result.slot,
        result.fired,
    ]


class Chat:
    """One visit, stepped through the real session functions."""

    def __init__(self, conn, ai, patient: str, initial: dict | None = None) -> None:
        from backend import db

        self.conn = conn
        self.ai = ai
        self.visit = db.new_id("V")
        self.turns: list[list] = []
        status = initial["status"] if initial else "intake"
        conn.execute(
            "INSERT INTO visit (id, patient_id, status, created_at) "
            "VALUES (?, ?, ?, '2026-11-07T09:00:00.000000+00:00')",
            (self.visit, patient, status),
        )
        if initial and initial.get("state") is not None:
            conn.execute(
                "INSERT INTO intake (visit_id, json, transcript) VALUES (?, '{}', ?)",
                (self.visit, db.dumps(initial["state"])),
            )
        self.seen = self._state()
        self.last_event = 0

    def _state(self) -> dict | None:
        row = self.conn.execute(
            "SELECT transcript FROM intake WHERE visit_id = ?", (self.visit,)
        ).fetchone()
        return None if row is None or not row["transcript"] else json.loads(row["transcript"])

    def _events(self) -> list[list]:
        rows = self.conn.execute(
            "SELECT id, type, payload FROM event WHERE visit_id = ? AND id > ? ORDER BY id",
            (self.visit, self.last_event),
        ).fetchall()
        if rows:
            self.last_event = rows[-1]["id"]
        return [[row["type"], json.loads(row["payload"])] for row in rows]

    def step(self, do: str, text: str | None = None):
        from backend.ai import session

        error, result_value, result = None, None, None
        try:
            if do == "say":
                result = session.handle_message(self.conn, self.ai, self.visit, text, ON)
                result_value = result_row(result)
            elif do == "past_arrival":
                result = session.red_flag_past_arrival(self.conn, self.visit, text, ON)
                result_value = result_row(result)
            elif do == "continue_refill":
                result_value = rules.intake_row(session.continue_after_refill(self.conn, self.visit, ON))
            elif do == "set_status":
                self.conn.execute("UPDATE visit SET status = ? WHERE id = ?", (text, self.visit))
            else:
                raise SystemExit(f"no step {do}")
        except session.SessionError as failure:
            error = failure.code
        visit = self.conn.execute(
            "SELECT status, service FROM visit WHERE id = ?", (self.visit,)
        ).fetchone()
        state = self._state()
        before = len(self.seen["messages"]) if self.seen else 0
        messages = state["messages"] if state else []
        last = state["last_turn"] if state else None
        self.turns.append(
            [
                do,
                text,
                error,
                result_value,
                visit["status"],
                visit["service"],
                [
                    [0 if item["role"] == "user" else 1, item["content"], item.get("slot")]
                    for item in messages[before:]
                ],
                len(messages),
                state["denied"] if state else [],
                state["language"] if state else None,
                None if last is None else [last[key] for key in LAST_TURN_COLUMNS],
                self._events(),
            ]
        )
        self.seen = state
        return result


def play_plan(chat: Chat, plan: dict) -> None:
    """Answers each question the real receptionist asks, until the chat ends."""
    slot = "complaint"
    for turn in range(9):
        result = chat.step("say", variants.next_message(plan, turn, slot))
        if result is None or result.emergency or result.refill:
            return
        if result.done:
            if plan.get("read_back"):
                chat.step("say", plan["read_back"])
            return
        slot = result.slot


class Sessions:
    def __init__(self, folder: common.Folder, conn, ai) -> None:
        self.folder = folder
        self.conn = conn
        self.ai = ai
        self.rows: list[list] = []
        self.families = rules.Families()

    def run(self, family: str, patient: str, body, initial: dict | None = None) -> None:
        chat = Chat(self.conn, self.ai, patient, initial)
        try:
            body(chat)
        except Exception as error:  # noqa: BLE001
            reason = f"the real function raised {type(error).__name__}: {error}"
            self.folder.exclude("sessions", chat.turns[-1][1] if chat.turns else family, reason)
            return
        self.rows.append([self.families(family), patient, ON.isoformat(), initial, chat.turns])


LONG_PLAIN = "a " * 1100
CUES = {"en": "chest pain", "ar": "ألم في الصدر"}
SELF_HARM = {"en": "i want to end my life", "ar": "أبي أأذي نفسي"}
HALF_CUE = {"en": ("pain", "chest"), "ar": ("ألم", "صدري")}


def closed_status(sessions: Sessions, plan_family: str, plan: dict, lang: str) -> None:
    """Every kind of message after each status a chat can close in."""
    patient = plan["patient"]
    cue, harm = CUES[lang], SELF_HARM[lang]
    half = HALF_CUE[lang]
    messages = {
        "plain": ["thanks", "شكرا"],
        "cue": [cue],
        "self_harm": [harm],
        "half_cue": list(half),
        "over_long": [LONG_PLAIN[:2001]],
        "over_long_cue": [f"{LONG_PLAIN[:2100]} {cue}"],
        "over_long_self_harm": [f"{LONG_PLAIN[:2100]} {harm}"],
        "cue_then_self_harm": [cue, harm],
        "cue_then_more": [cue, "ok"],
    }
    for status in CLOSED:
        for name, texts in messages.items():
            def body(chat: Chat) -> None:
                play_plan(chat, {**plan, "read_back": None})
                chat.step("set_status", status)
                for text in texts:
                    if status in AT_THE_CENTRE:
                        chat.step("past_arrival", text)
                    chat.step("say", text)

            sessions.run(f"closed.{status}.{name}", patient, body)


def session_goldens(folder: common.Folder, scratch: Path) -> None:
    from backend import db, seeding
    from backend.ai import runtime

    ai = runtime.build_runtime()
    if ai.mode != "simulated":
        raise SystemExit("the runtime is not simulated")
    path = scratch / "sessions.db"
    conn = db.connect(path)
    conn.execute("PRAGMA synchronous=OFF")
    db.init_schema(conn)
    seeding.seed_static(conn)
    seeded = [row["id"] for row in conn.execute("SELECT id FROM patient ORDER BY id")]
    sessions = Sessions(folder, conn, ai)
    complaints = rules.complaints_by_language()

    plain_plans = list(variants.plans(complaints, seeded, 1100))
    for family, plan in plain_plans:
        sessions.run(family, plan["patient"], lambda chat, plan=plan: play_plan(chat, plan))

    # An emergency at each turn.
    for index, (family, plan) in enumerate(plain_plans[:240]):
        lang = plan["lang"]
        text = variants.INJECTED[lang][index % len(variants.INJECTED[lang])]
        injected = variants.with_injection(plan, index % 6, text)
        sessions.run(f"emergency.turn{index % 6}", plan["patient"], lambda chat, p=injected: play_plan(chat, p))

    # Sticky emergency, and self-harm after a closed emergency.
    for lang in ("en", "ar"):
        for index, patient in enumerate(seeded):
            def sticky(chat: Chat, lang=lang) -> None:
                chat.step("say", CUES[lang])
                chat.step("say", "ok")
                chat.step("say", "شكرا")
                chat.step("say", SELF_HARM[lang])
                chat.step("say", "ok")
                chat.step("say", CUES[lang])

            sessions.run("emergency.sticky", patient, sticky)

    # Refill and continue_after_refill, for every record with medicines.
    refill_openers = (
        "I need my usual blood pressure tablets.", "أبي حبوب الضغط المعتادة", "refill my amlodipine",
        "i ran out of metformin", "خلصت حبوب السكر", "تجديد", "refill", "i need my usual tablets",
        "حبوب الضغط المعتادة",
    )
    follow_ups = (
        (), ("continue_refill",), ("continue_refill", "thanks"), ("thanks",), ("chest pain",),
        ("continue_refill", "ألم في الصدر"), ("أبي أأذي نفسي",), ("thanks", "continue_refill"),
    )
    for opener in refill_openers:
        for patient in seeded:
            for steps in follow_ups:
                def refill_chat(chat: Chat, opener=opener, steps=steps) -> None:
                    chat.step("say", opener)
                    for step in steps:
                        if step == "continue_refill":
                            chat.step("continue_refill")
                        else:
                            chat.step("say", step)

                sessions.run("refill", patient, refill_chat)
    sessions.run("refill.refused", "P001", lambda chat: chat.step("continue_refill"))

    # Over-long messages, with the cut on awkward characters.
    for lang, cue in CUES.items():
        for _, text in variants.long_messages(cue):
            for patient in ("P001", "P002"):
                sessions.run("long", patient, lambda chat, text=text: chat.step("say", text))
                sessions.run(
                    "long.after_opening", patient,
                    lambda chat, text=text: (chat.step("say", "i have a cough"), chat.step("say", text)),
                )
    for text in (
        "a" * 2000, "ب" * 2000, " " * 5 + "a" * 2000, "a" * 2001, "😀" * 2000, "😀" * 2001, "a" * 1999 + "😀",
        "a" * 198 + "   " + "b" * 40, "a" * 199 + "\x1cb", "ب" * 999 + "​" + "ب" * 20, "a" * 399 + " b",
        "", "   ", "\n\t", "​", "ـ", " ",
    ):
        sessions.run("long.edge", "P006", lambda chat, text=text: chat.step("say", text))

    # Language switches, in both directions, and words that must not switch.
    switches = (
        ("عندي حرارة", "since yesterday it has been bad", "6", "لا"),
        ("i have a cough", "من أمس وأنا تعبان", "٦", "no"),
        ("عندي صداع", "ok", "yes", "fine", "thanks"),
        ("i have a rash", "نعم", "لا", "طيب"),
        ("عندي حرارة", "من أمس", "hello there my friend", "6", "no"),
    )
    for patient in seeded:
        for script in switches:
            def switch(chat: Chat, script=script) -> None:
                for text in script:
                    chat.step("say", text)

            sessions.run("language", patient, switch)

    for lang in ("en", "ar"):
        for index, (family, plan) in enumerate(plain_plans[:4]):
            if plan["lang"] == lang:
                closed_status(sessions, family, plan, lang)

    # The harvested calls, with the visit as the test had it.
    calls = common.load_harvest()["calls"]["session.handle_message"]
    for text, _on, status, patient, state in calls:
        if not isinstance(text, str) or patient not in seeded or not common.encodable([text, state]):
            continue
        sessions.run(
            "harvest.session", patient,
            lambda chat, text=text: chat.step("say", text),
            {"status": status, "state": state},
        )

    conn.close()
    folder.add(
        "sessions", "sessions",
        ["family", "patient", "on", "initial", "turns"],
        {
            "families": sessions.families.header,
            "turn_columns": list(TURN_COLUMNS),
            "result_columns": list(RESULT_COLUMNS),
            "last_turn_columns": list(LAST_TURN_COLUMNS),
            "intake_keys": list(rules.INTAKE_KEYS),
        },
        sessions.rows,
    )


# The API


_TIME = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}\+00:00")


class Scrub(clinic.Aliases):
    def __init__(self) -> None:
        super().__init__()
        self.times: dict[str, str] = {}

    def _time(self, match: re.Match) -> str:
        return self.times.setdefault(match.group(), f"time{len(self.times) + 1}")

    def __call__(self, value):
        if isinstance(value, str):
            return _TIME.sub(self._time, super().__call__(value))
        if isinstance(value, dict):
            return {
                key: "<token>" if key == "token" else self(value[key]) for key in sorted(value)
            }
        if isinstance(value, (list, tuple)):
            return [self(item) for item in value]
        return value


class Walker:
    """A client for one fresh demo, that keeps every response under a walk name."""

    def __init__(self, api, helpers, name: str, sink: list[list] | None) -> None:
        from backend import db

        self.api = api
        self.helpers = helpers
        self.name = name
        self.sink = sink
        self.scrub = Scrub()
        self.step = 0
        self.db = db
        self.log: list[list] = []
        common.CLOCK.set(common.START)
        self.nurse = helpers.staff_token(api, helpers.NURSE)
        self.doctor = helpers.staff_token(api, helpers.DOCTOR2)
        self.pharmacist = helpers.staff_token(api, helpers.PHARMACIST)
        response = api.post("/api/demo/reset", headers=helpers.bearer(self.nurse))
        assert response.status_code == 200, response.text
        health = api.get("/api/health").json()
        if health.get("ai_mode") != "simulated":
            raise SystemExit(f"/api/health says ai_mode {health.get('ai_mode')!r}")
        self.tokens = {"nurse": self.nurse, "doctor": self.doctor, "pharmacist": self.pharmacist}

    def record(self, actor, method, path, request, status, response) -> None:
        if self.sink is None:
            self.log.append([actor, method, self.scrub(path), self.scrub(request)])
            return
        self.sink.append(
            [
                self.name,
                self.step,
                actor,
                method,
                self.scrub(path),
                self.scrub(request),
                status,
                self.scrub(response),
            ]
        )
        self.step += 1

    def call(self, actor: str, method: str, path: str, body=None, *, want=None, keep=True):
        common.CLOCK.advance(seconds=1)
        token = self.tokens.get(actor)
        headers = self.helpers.bearer(token) if token else {}
        if method == "GET":
            response = self.api.get(path, headers=headers)
        else:
            response = self.api.post(path, json=body, headers=headers)
        if want is not None:
            assert response.status_code == want, f"{self.name} {path}: {response.text}"
        payload = response.json()
        if keep:
            self.record(actor, method, path, body, response.status_code, payload)
        return payload

    def login(self, who: str, qid: str, patient_step: bool = True) -> dict:
        self.call(who, "POST", "/api/auth/start", {"qid": qid}, want=200)
        body = self.call(who, "POST", "/api/auth/verify", {"qid": qid, "otp": "0000"}, want=200)
        self.tokens[who] = body["token"]
        return body

    def harness(self, description: dict, sql: str, *params) -> None:
        conn = self.db.connect()
        conn.execute(sql, params)
        conn.close()
        self.record("harness", "SQL", sql, {**description, "params": list(params)}, 0, None)

    def wait(self, minutes: int) -> None:
        common.CLOCK.advance(minutes=minutes)
        self.record("clock", "WAIT", "", {"minutes": minutes}, 0, None)

    def visit(self, who: str, visit_id: str) -> dict:
        return self.call(who, "GET", f"/api/visits/{visit_id}", want=200)

    def say(self, who: str, visit_id: str, *texts: str) -> dict:
        last: dict = {}
        for text in texts:
            last = self.call(who, "POST", f"/api/visits/{visit_id}/chat", {"text": text}, want=200)
        return last


def open_app(who: str, walker: Walker, qid: str) -> None:
    walker.call("anonymous", "GET", "/api/auth/demo-patients", want=200)
    walker.call("anonymous", "GET", "/api/health", want=200)
    walker.login(who, qid)
    walker.call(who, "GET", "/api/me", want=200)
    walker.call(who, "GET", "/api/visits", want=200)


VITALS = {"bp_sys": 120, "bp_dia": 80, "hr": 72, "temp_c": 38.1, "spo2": 98, "urgency": "routine"}
FATIMA = {
    "ar": ("عندي حرارة وكحة من ثلاث أيام", "٦", "بنادول", "لا"),
    "en": ("I have a fever and cough for three days", "6", "panadol", "no"),
}
AHMED = {"ar": "أبي حبوب الضغط المعتادة", "en": "I need my usual blood pressure tablets."}
RAVI = {"ar": "عندي ألم في الصدر ينتشر إلى ذراعي", "en": "Chest pain going to my left arm."}


def to_triage(walker: Walker, who: str, visit_id: str, centre: str, arrive: dict) -> dict:
    walker.call(who, "POST", f"/api/visits/{visit_id}/reserve", {"centre_id": centre}, want=200)
    walker.visit(who, visit_id)
    body = walker.call(who, "POST", f"/api/visits/{visit_id}/arrive", arrive, want=200)
    walker.visit(who, visit_id)
    return body


def to_doctor(walker: Walker, who: str, visit_id: str, triage: str, doctor: str) -> dict:
    walker.call("nurse", "POST", f"/api/counters/{triage}/call-next", want=200)
    walker.visit(who, visit_id)
    walker.call("nurse", "POST", f"/api/visits/{visit_id}/vitals", VITALS, want=200)
    walker.visit(who, visit_id)
    text = walker.call("nurse", "POST", f"/api/visits/{visit_id}/handoff/draft", want=200)["text"]
    body = walker.call(
        "nurse", "POST", f"/api/visits/{visit_id}/handoff/confirm",
        {"final_text": text, "doctor_id": doctor}, want=200,
    )
    walker.visit(who, visit_id)
    return body


def fatima_visit(walker: Walker, lang: str) -> str:
    open_app("fatima", walker, walker.helpers.FATIMA_QID)
    visit_id = walker.call("fatima", "POST", "/api/visits", {"consent": True}, want=200)["visit_id"]
    walker.visit("fatima", visit_id)
    for text in FATIMA[lang]:
        walker.say("fatima", visit_id, text)
    walker.visit("fatima", visit_id)
    walker.call("fatima", "POST", f"/api/visits/{visit_id}/intake/confirm", {}, want=200)
    walker.visit("fatima", visit_id)
    walker.call("fatima", "GET", f"/api/centres?service=gp&visit_id={visit_id}", want=200)
    walker.call("fatima", "GET", f"/api/centres?service=gp&visit_id={visit_id}&lat=25.2&lng=51.5", want=200)
    ticket = to_triage(walker, "fatima", visit_id, "C-WAKRA", {"button": True})
    assert ticket["ticket"]["number"] == "T-014", ticket
    doctor = to_doctor(walker, "fatima", visit_id, "C-WAKRA-T1", walker.helpers.DOCTOR2)
    assert doctor["ticket"]["number"] == "D-GP-023", doctor
    return visit_id


def fatima_by_hand(walker: Walker, lang: str) -> None:
    visit_id = fatima_visit(walker, lang)
    walker.call("doctor", "POST", "/api/counters/C-WAKRA-D4/call-next", want=200)
    walker.call(
        "doctor", "POST", f"/api/visits/{visit_id}/consult/done",
        {"prescription": [{"drug_id": "DR-PARA"}, {"drug_id": "DR-DEXT"}]}, want=200,
    )
    pharmacy = walker.visit("fatima", visit_id)
    assert pharmacy["ticket"]["number"] == "P-031", pharmacy
    walker.call("pharmacist", "POST", "/api/counters/C-WAKRA-P1/call-next", want=200)
    walker.call("pharmacist", "POST", f"/api/visits/{visit_id}/dispensed", want=200)
    walker.visit("fatima", visit_id)
    walker.call("fatima", "POST", f"/api/visits/{visit_id}/rating", {"stars": 5}, want=200)
    walker.visit("fatima", visit_id)
    walker.call("fatima", "GET", "/api/visits", want=200)


def fatima_fast_forward(walker: Walker, lang: str, forced_drug: str | None = None) -> None:
    visit_id = fatima_visit(walker, lang)
    if forced_drug:
        walker.harness(
            {"demo_default": forced_drug}, "UPDATE drug SET demo_default = 1 WHERE id = ?", forced_drug
        )
    walker.call("nurse", "POST", f"/api/demo/fast-forward/{visit_id}", want=200)
    done = walker.visit("fatima", visit_id)
    drugs = [line["drug"] for line in done["medicines"]["en"]]
    assert "DR-AMOX" not in drugs, drugs
    walker.call("fatima", "POST", f"/api/visits/{visit_id}/rating", {"stars": 4}, want=200)
    walker.visit("fatima", visit_id)


def ahmed(walker: Walker, lang: str) -> None:
    open_app("ahmed", walker, walker.helpers.AHMED_QID)
    visit_id = walker.call("ahmed", "POST", "/api/visits", {"consent": True}, want=200)["visit_id"]
    reply = walker.say("ahmed", visit_id, AHMED[lang])
    assert reply["refill"] is not None, reply
    walker.visit("ahmed", visit_id)
    walker.call("ahmed", "GET", "/api/visits", want=200)
    walker.call("ahmed", "POST", f"/api/visits/{visit_id}/refill/continue", want=200)
    walker.visit("ahmed", visit_id)
    walker.call("ahmed", "GET", f"/api/centres?service=gp&visit_id={visit_id}", want=200)
    to_triage(walker, "ahmed", visit_id, "C-RAYYAN", {"qr_code": "DOOR-C-RAYYAN"})
    walker.call("ahmed", "GET", "/api/visits", want=200)


def ahmed_stops(walker: Walker, lang: str) -> None:
    """The refill route where it ends: no ticket and nothing to reserve."""
    open_app("ahmed", walker, walker.helpers.AHMED_QID)
    visit_id = walker.call("ahmed", "POST", "/api/visits", {"consent": True}, want=200)["visit_id"]
    walker.say("ahmed", visit_id, AHMED[lang])
    walker.call("ahmed", "POST", f"/api/visits/{visit_id}/reserve", {"centre_id": "C-RAYYAN"})
    walker.visit("ahmed", visit_id)


def ravi(walker: Walker, lang: str) -> None:
    open_app("ravi", walker, walker.helpers.RAVI_QID)
    visit_id = walker.call("ravi", "POST", "/api/visits", {"consent": True}, want=200)["visit_id"]
    reply = walker.say("ravi", visit_id, RAVI[lang])
    assert reply["emergency"], reply
    walker.visit("ravi", visit_id)
    walker.call("ravi", "POST", f"/api/visits/{visit_id}/emergency/override", want=200)
    walker.visit("ravi", visit_id)
    walker.call("ravi", "POST", "/api/visits", {"consent": True}, want=409)
    walker.call("ravi", "POST", f"/api/visits/{visit_id}/reserve", {"centre_id": "C-AIRPORT"})
    walker.say("ravi", visit_id, "ok")
    walker.say("ravi", visit_id, "i want to end my life" if lang == "en" else "أبي أأذي نفسي")
    walker.visit("ravi", visit_id)
    walker.call("ravi", "GET", "/api/visits", want=200)


def fatima_lapsed(walker: Walker, lang: str) -> None:
    open_app("fatima", walker, walker.helpers.FATIMA_QID)
    visit_id = walker.call("fatima", "POST", "/api/visits", {"consent": True}, want=200)["visit_id"]
    walker.say("fatima", visit_id, *FATIMA[lang])
    walker.call("fatima", "POST", f"/api/visits/{visit_id}/intake/confirm", {}, want=200)
    walker.call("fatima", "POST", f"/api/visits/{visit_id}/reserve", {"centre_id": "C-WAKRA"}, want=200)
    walker.wait(46)
    walker.visit("fatima", visit_id)
    walker.call("fatima", "POST", f"/api/visits/{visit_id}/arrive", {"button": True}, want=410)
    walker.call("fatima", "POST", f"/api/visits/{visit_id}/reserve", {"centre_id": "C-WAKRA"}, want=200)
    walker.visit("fatima", visit_id)


def dependent(walker: Walker, lang: str) -> None:
    open_app("fatima", walker, walker.helpers.FATIMA_QID)
    visit_id = walker.call(
        "fatima", "POST", "/api/visits", {"consent": True, "patient_id": "P004"}, want=200
    )["visit_id"]
    walker.visit("fatima", visit_id)
    walker.say("fatima", visit_id, *FATIMA[lang])
    walker.call("fatima", "POST", f"/api/visits/{visit_id}/intake/confirm", {}, want=200)
    to_triage(walker, "fatima", visit_id, "C-WAKRA", {"lat": 25.17302, "lng": 51.59575})
    walker.call("fatima", "GET", "/api/visits", want=200)


def api_goldens(folder: common.Folder, api, helpers) -> None:
    rows: list[list] = []
    walks = (
        ("fatima.by_hand", fatima_by_hand),
        ("fatima.fast_forward", fatima_fast_forward),
        ("fatima.lapsed", fatima_lapsed),
        ("ahmed.continues", ahmed),
        ("ahmed.stops", ahmed_stops),
        ("ravi", ravi),
        ("dependent", dependent),
    )
    for name, walk in walks:
        for lang in ("ar", "en"):
            walk(Walker(api, helpers, f"{name}.{lang}", rows), lang)
    for lang in ("ar", "en"):
        fatima_fast_forward(
            Walker(api, helpers, f"fatima.forced_penicillin_default.{lang}", rows), lang, "DR-AMOX"
        )
    folder.add(
        "api", "api",
        ["walk", "step", "actor", "method", "path", "request", "status", "response"], {}, rows,
    )


# Refusals


def refusal_goldens(folder: common.Folder, api, helpers) -> None:
    rows: list[list] = []

    def fresh() -> Walker:
        return Walker(api, helpers, "setup", None)

    def note(walker: Walker, name, actor, method, path, body, want) -> None:
        response = walker.call(actor, method, path, body, keep=False, want=want)
        rows.append(
            [name, list(walker.log), actor, method, walker.scrub(path), walker.scrub(body), want,
             walker.scrub(response)]
        )

    def patient(walker: Walker, who="fatima", qid=helpers.FATIMA_QID) -> None:
        walker.login(who, qid)

    def new_visit(walker: Walker, who="fatima") -> str:
        return walker.call(who, "POST", "/api/visits", {"consent": True}, want=200)["visit_id"]

    def confirmed(walker: Walker, who="fatima", lang="en") -> str:
        visit_id = new_visit(walker, who)
        walker.say(who, visit_id, *FATIMA[lang])
        walker.call(who, "POST", f"/api/visits/{visit_id}/intake/confirm", {}, want=200)
        return visit_id

    def reserved(walker: Walker) -> str:
        visit_id = confirmed(walker)
        walker.call("fatima", "POST", f"/api/visits/{visit_id}/reserve", {"centre_id": "C-WAKRA"}, want=200)
        return visit_id

    def arrived(walker: Walker) -> str:
        visit_id = reserved(walker)
        walker.call("fatima", "POST", f"/api/visits/{visit_id}/arrive", {"button": True}, want=200)
        return visit_id

    def completed(walker: Walker) -> str:
        visit_id = arrived(walker)
        walker.call("nurse", "POST", "/api/counters/C-WAKRA-T1/call-next", want=200)
        walker.call("nurse", "POST", f"/api/visits/{visit_id}/vitals", VITALS, want=200)
        text = walker.call("nurse", "POST", f"/api/visits/{visit_id}/handoff/draft", want=200)["text"]
        walker.call(
            "nurse", "POST", f"/api/visits/{visit_id}/handoff/confirm",
            {"final_text": text, "doctor_id": helpers.DOCTOR2}, want=200,
        )
        walker.call("nurse", "POST", f"/api/demo/fast-forward/{visit_id}", want=200)
        return visit_id

    # Signing in
    walker = fresh()
    note(walker, "unknown_qid.start", "anonymous", "POST", "/api/auth/start", {"qid": "DEMO-99999"}, 404)
    note(walker, "unknown_qid.verify", "anonymous", "POST", "/api/auth/verify", {"qid": "DEMO-99999", "otp": "0000"}, 404)
    note(walker, "invalid_otp", "anonymous", "POST", "/api/auth/verify", {"qid": helpers.FATIMA_QID, "otp": "1234"}, 401)
    note(walker, "invalid_otp.blank", "anonymous", "POST", "/api/auth/verify", {"qid": helpers.FATIMA_QID, "otp": ""}, 401)
    note(walker, "invalid_request.no_otp", "anonymous", "POST", "/api/auth/verify", {"qid": helpers.FATIMA_QID}, 422)
    note(walker, "unauthorized.me", "anonymous", "GET", "/api/me", None, 401)
    note(walker, "unauthorized.visits", "anonymous", "POST", "/api/visits", {"consent": True}, 401)
    note(walker, "forbidden.staff_token", "nurse", "GET", "/api/me", None, 403)

    # Starting a visit
    walker = fresh()
    patient(walker)
    note(walker, "consent_required.false", "fatima", "POST", "/api/visits", {"consent": False}, 422)
    note(walker, "consent_required.missing", "fatima", "POST", "/api/visits", {}, 422)
    note(walker, "consent_required.string", "fatima", "POST", "/api/visits", {"consent": "true"}, 422)
    note(walker, "consent_required.no_body", "fatima", "POST", "/api/visits", None, 422)
    note(walker, "forbidden.someone_elses_patient", "fatima", "POST", "/api/visits", {"consent": True, "patient_id": "P003"}, 403)

    walker = fresh()
    patient(walker)
    visit_id = reserved(walker)
    note(walker, "active_visit.reserved", "fatima", "POST", "/api/visits", {"consent": True}, 409)
    walker.call("fatima", "POST", f"/api/visits/{visit_id}/arrive", {"button": True}, want=200)
    note(walker, "active_visit.in_triage", "fatima", "POST", "/api/visits", {"consent": True}, 409)

    walker = fresh()
    patient(walker, "ravi", helpers.RAVI_QID)
    visit_id = new_visit(walker, "ravi")
    walker.say("ravi", visit_id, RAVI["en"])
    note(walker, "emergency_today.new_visit", "ravi", "POST", "/api/visits", {"consent": True}, 409)
    note(walker, "visit_not_in_intake.confirm", "ravi", "POST", f"/api/visits/{visit_id}/intake/confirm", {}, 409)
    note(walker, "intake_not_confirmed.emergency", "ravi", "POST", f"/api/visits/{visit_id}/reserve", {"centre_id": "C-AIRPORT"}, 409)

    # A visit opened before the emergency, and one reserved before it.
    walker = fresh()
    patient(walker)
    older = confirmed(walker)
    second = walker.call("fatima", "POST", "/api/visits", {"consent": True}, want=200)["visit_id"]
    walker.say("fatima", second, CUES["en"])
    note(walker, "emergency_today.reserve", "fatima", "POST", f"/api/visits/{older}/reserve", {"centre_id": "C-WAKRA"}, 409)

    walker = fresh()
    patient(walker)
    held = reserved(walker)
    second = walker.call("fatima", "POST", "/api/visits", {"consent": True, "patient_id": "P004"}, want=200)["visit_id"]
    walker.harness({}, "UPDATE visit SET status = 'redirected_emergency', patient_id = 'P001' WHERE id = ?", second)
    note(walker, "emergency_today.arrive", "fatima", "POST", f"/api/visits/{held}/arrive", {"button": True}, 409)

    # The chat
    walker = fresh()
    patient(walker)
    visit_id = new_visit(walker)
    other = "V_000000000000"
    note(walker, "invalid_text.empty", "fatima", "POST", f"/api/visits/{visit_id}/chat", {"text": ""}, 422)
    note(walker, "invalid_text.blank", "fatima", "POST", f"/api/visits/{visit_id}/chat", {"text": "   "}, 422)
    note(walker, "invalid_text.not_text", "fatima", "POST", f"/api/visits/{visit_id}/chat", {"text": 5}, 422)
    note(walker, "invalid_text.missing", "fatima", "POST", f"/api/visits/{visit_id}/chat", {}, 422)
    note(walker, "invalid_text.over_long", "fatima", "POST", f"/api/visits/{visit_id}/chat", {"text": "a " * 1001}, 422)
    note(walker, "visit_not_found", "fatima", "GET", f"/api/visits/{other}", None, 404)
    note(walker, "visit_not_found.chat", "fatima", "POST", f"/api/visits/{other}/chat", {"text": "hi"}, 404)
    note(walker, "no_intake", "fatima", "POST", f"/api/visits/{visit_id}/intake/confirm", {}, 409)
    note(walker, "intake_not_confirmed", "fatima", "POST", f"/api/visits/{visit_id}/reserve", {"centre_id": "C-WAKRA"}, 409)
    note(walker, "unknown_centre", "fatima", "POST", f"/api/visits/{visit_id}/reserve", {"centre_id": "C-NOPE"}, 404)
    note(walker, "not_emergency", "fatima", "POST", f"/api/visits/{visit_id}/emergency/override", None, 409)
    note(walker, "visit_not_completed", "fatima", "POST", f"/api/visits/{visit_id}/rating", {"stars": 5}, 409)
    note(walker, "visit_not_deflected", "fatima", "POST", f"/api/visits/{visit_id}/refill/continue", None, 409)
    note(walker, "no_reservation", "fatima", "POST", f"/api/visits/{visit_id}/arrive", {"button": True}, 409)
    note(walker, "invalid_request.reserve_no_centre", "fatima", "POST", f"/api/visits/{visit_id}/reserve", {}, 422)
    note(walker, "arrival_method_required.none", "fatima", "POST", f"/api/visits/{visit_id}/arrive", {}, 422)
    note(walker, "arrival_method_required.two", "fatima", "POST", f"/api/visits/{visit_id}/arrive", {"button": True, "qr_code": "x"}, 422)
    note(walker, "arrival_method_required.half", "fatima", "POST", f"/api/visits/{visit_id}/arrive", {"lat": 25.0}, 422)
    note(walker, "invalid_request.lat_range", "fatima", "POST", f"/api/visits/{visit_id}/arrive", {"lat": 95.0, "lng": 51.0}, 422)
    note(walker, "unknown_service.list", "fatima", "GET", "/api/centres?service=nope", None, 422)

    walker.login("ravi", helpers.RAVI_QID)
    note(walker, "forbidden.someone_elses_visit", "ravi", "GET", f"/api/visits/{visit_id}", None, 403)
    note(walker, "forbidden.someone_elses_chat", "ravi", "POST", f"/api/visits/{visit_id}/chat", {"text": "hi"}, 403)
    note(walker, "forbidden.someone_elses_centres", "ravi", "GET", f"/api/centres?visit_id={visit_id}", None, 403)

    walker = fresh()
    patient(walker)
    visit_id = new_visit(walker)
    walker.say("fatima", visit_id, *FATIMA["en"])
    note(walker, "unknown_service.confirm", "fatima", "POST", f"/api/visits/{visit_id}/intake/confirm", {"json": {"service": "nope"}}, 422)
    walker.call("fatima", "POST", f"/api/visits/{visit_id}/intake/confirm", {"json": {"service": "dental"}}, want=200)
    note(walker, "service_not_offered", "fatima", "POST", f"/api/visits/{visit_id}/reserve", {"centre_id": "C-RAYYAN"}, 409)
    note(walker, "service_not_offered.hospital", "fatima", "POST", f"/api/visits/{visit_id}/reserve", {"centre_id": "H-HGH"}, 409)

    # Arriving
    walker = fresh()
    patient(walker)
    visit_id = reserved(walker)
    note(walker, "too_far", "fatima", "POST", f"/api/visits/{visit_id}/arrive", {"lat": 25.2, "lng": 51.5}, 409)
    note(walker, "too_far.just_outside", "fatima", "POST", f"/api/visits/{visit_id}/arrive", {"lat": 25.17302 + 151 / 111_195, "lng": 51.59575}, 409)
    note(walker, "wrong_door", "fatima", "POST", f"/api/visits/{visit_id}/arrive", {"qr_code": "DOOR-C-RAYYAN"}, 409)
    note(walker, "visit_not_in_intake.reserved_confirm", "fatima", "POST", f"/api/visits/{visit_id}/intake/confirm", {}, 409)
    note(walker, "visit_has_live_ticket", "fatima", "POST", f"/api/visits/{visit_id}/reserve", {"centre_id": "C-WAKRA"}, 409)
    note(walker, "visit_not_in_intake.reserved_chat", "fatima", "POST", f"/api/visits/{visit_id}/chat", {"text": "thanks"}, 409)

    walker = fresh()
    patient(walker)
    visit_id = reserved(walker)
    walker.wait(46)
    note(walker, "ticket_expired", "fatima", "POST", f"/api/visits/{visit_id}/arrive", {"button": True}, 410)

    walker = fresh()
    patient(walker)
    visit_id = arrived(walker)
    note(walker, "visit_not_in_intake.in_triage", "fatima", "POST", f"/api/visits/{visit_id}/chat", {"text": "thanks"}, 409)
    note(walker, "invalid_transition.arrive_twice", "fatima", "POST", f"/api/visits/{visit_id}/arrive", {"button": True}, 409)
    note(walker, "invalid_text.in_triage", "fatima", "POST", f"/api/visits/{visit_id}/chat", {"text": "  "}, 422)

    # After the visit
    walker = fresh()
    patient(walker)
    visit_id = completed(walker)
    note(walker, "visit_not_in_intake.completed", "fatima", "POST", f"/api/visits/{visit_id}/chat", {"text": "thanks"}, 409)
    note(walker, "invalid_text.completed_over_long", "fatima", "POST", f"/api/visits/{visit_id}/chat", {"text": "a " * 1001}, 422)
    note(walker, "invalid_request.stars", "fatima", "POST", f"/api/visits/{visit_id}/rating", {"stars": 6}, 422)
    note(walker, "invalid_request.stars_text", "fatima", "POST", f"/api/visits/{visit_id}/rating", {"stars": "3"}, 422)
    walker.call("fatima", "POST", f"/api/visits/{visit_id}/rating", {"stars": 5}, want=200)
    note(walker, "already_rated", "fatima", "POST", f"/api/visits/{visit_id}/rating", {"stars": 4}, 409)

    folder.add(
        "refusals", "refusals",
        ["name", "setup", "actor", "method", "path", "request", "status", "response"], {}, rows,
    )
    codes = sorted({row[7]["error"] for row in rows})
    folder.notes["refusal_codes"] = codes


def goldens() -> dict[str, bytes]:
    from fastapi.testclient import TestClient

    from backend import main as backend_main
    from backend.tests import api_helpers

    folder = common.Folder("journeys", SOURCES)
    saved = os.environ["DAWRI_DB"]
    intervals = backend_main.SIMULATE_INTERVAL_SEC, backend_main.EXPIRY_INTERVAL_SEC
    # The background loops would race a walk, so they sleep through it.
    backend_main.SIMULATE_INTERVAL_SEC = backend_main.EXPIRY_INTERVAL_SEC = 10**9
    with tempfile.TemporaryDirectory(prefix="dawri-journeys-") as scratch:
        os.environ["DAWRI_DB"] = str(Path(scratch) / "api.db")
        try:
            session_goldens(folder, Path(scratch))
            common.CLOCK.set(common.START)
            with TestClient(backend_main.app) as api:
                health = api.get("/api/health").json()
                if health.get("ai_mode") != "simulated":
                    raise SystemExit(f"/api/health says ai_mode {health.get('ai_mode')!r}")
                api_goldens(folder, api, api_helpers)
                refusal_goldens(folder, api, api_helpers)
        finally:
            os.environ["DAWRI_DB"] = saved
            backend_main.SIMULATE_INTERVAL_SEC, backend_main.EXPIRY_INTERVAL_SEC = intervals
    return folder.finish()
