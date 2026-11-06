"""The three demo patients, over HTTP only. The helpers here serve test_api_redlines too.

Nothing here calls the engine. The database is read to check what was stored, and only
app.state.engine.clock is touched, to move time.
"""

from __future__ import annotations

import json
import queue
import time
from contextlib import contextmanager

import pytest
from fastapi.routing import APIRoute
from fastapi.testclient import TestClient

from backend import main
from backend.ai import runtime
from backend.main import app
from backend.tests.ai_fakes import WAV_BYTES, FakeAsrClient, FakeChatClient
from backend.tests.api_helpers import (
    AHMED_QID,
    AHMED_TEXT,
    DOCTOR2,
    FATIMA_ANSWERS,
    FATIMA_QID,
    NURSE,
    PHARMACIST,
    RAVI_QID,
    RAVI_TEXT,
    bearer,
    open_stream,
    patient_token,
    staff_token,
)
from backend.tests.test_api_staff import D4, P1, T1, Staff, event_types, rows

LIVE_STATES = ("reserved", "active", "called", "serving")
RAYYAN_NURSE = "S-RAY-NURSE1"
RAYYAN_T1 = "C-RAYYAN-T1"
VITALS = {"bp_sys": 120, "bp_dia": 80, "hr": 72, "temp_c": 38.1, "spo2": 98, "urgency": "routine"}
PRESCRIPTION = {"prescription": [{"drug_id": "DR-PARA"}, {"drug_id": "DR-DEXT"}]}
CHECK_IN_EN = "Check-in valid for 45 minutes"
CHECK_IN_AR = "تسجيل الوصول صالح لمدة 45 دقيقة"
STAFF_ROUTE_EN = "Speak to a member of staff at the centre, or call 999"
GATE_PASSING_REPLY = "How long have you had this?"
MODEL_INTAKE = {
    "language": "ar-gulf",
    "chief_complaint": "fever and cough",
    "chief_complaint_patient_words": "x",
    "service": "gp",
    "service_confidence": 0.9,
    "summary_for_nurse": "34F, fever and cough.",
    "questions_asked": 1,
}


class Caller(Staff):
    """One logged-in person. Every response lands in `log`, for the walks over all of them."""

    def __init__(self, api, token, log=None):
        self.api = api
        self.token = token
        self.headers = bearer(token)
        self.log = [] if log is None else log

    def _kept(self, response):
        self.log.append(response)
        return response

    def get(self, path):
        return self._kept(super().get(path))

    def post(self, path, json=None):
        return self._kept(super().post(path, json))

    def put(self, path, json=None):
        return self._kept(super().put(path, json))

    def read(self, path):
        response = self.get(path)
        assert response.status_code == 200, response.text
        return response.json()


def patient(api, qid, log=None):
    return Caller(api, patient_token(api, qid), log)


def staff(api, staff_id, log=None):
    return Caller(api, staff_token(api, staff_id), log)


def open_visit(person, patient_id=None):
    body = {"consent": True} if patient_id is None else {"consent": True, "patient_id": patient_id}
    return person.ok("/api/visits", body)["visit_id"]


def tell(person, visit_id, *texts):
    """Each message in order. Returns the last reply's JSON."""
    last = {}
    for text in texts:
        last = person.ok(f"/api/visits/{visit_id}/chat", {"text": text})
    return last


def confirmed_visit(person, answers=FATIMA_ANSWERS, patient_id=None):
    visit_id = open_visit(person, patient_id)
    assert tell(person, visit_id, *answers)["done"]
    person.ok(f"/api/visits/{visit_id}/intake/confirm")
    return visit_id


def reserve(person, visit_id, centre_id="C-WAKRA"):
    return person.post(f"/api/visits/{visit_id}/reserve", {"centre_id": centre_id})


def arrive(person, visit_id):
    return person.post(f"/api/visits/{visit_id}/arrive", {"button": True})


def reserved_visit(person, answers=FATIMA_ANSWERS, patient_id=None, centre_id="C-WAKRA"):
    visit_id = confirmed_visit(person, answers, patient_id)
    response = reserve(person, visit_id, centre_id)
    assert response.status_code == 200, response.text
    return visit_id


def arrived_visit(person, answers=FATIMA_ANSWERS, patient_id=None, centre_id="C-WAKRA"):
    visit_id = reserved_visit(person, answers, patient_id, centre_id)
    response = arrive(person, visit_id)
    assert response.status_code == 200, response.text
    return visit_id


def to_counter(nurse, visit_id, vitals=VITALS):
    """Called to triage with the vitals taken, which serves the ticket."""
    assert nurse.ok(f"/api/counters/{T1}/call-next")["called"]["visit_id"] == visit_id
    return nurse.ok(f"/api/visits/{visit_id}/vitals", vitals)


def hand_off(nurse, visit_id, doctor_id=DOCTOR2):
    text = nurse.ok(f"/api/visits/{visit_id}/handoff/draft")["text"]
    body = {"final_text": text, "doctor_id": doctor_id}
    return nurse.ok(f"/api/visits/{visit_id}/handoff/confirm", body)


def see_doctor(doctor, visit_id):
    assert doctor.ok(f"/api/counters/{D4}/call-next")["called"]["visit_id"] == visit_id
    return doctor.ok(f"/api/visits/{visit_id}/consult/done", PRESCRIPTION)


def dispense(pharmacist, visit_id):
    assert pharmacist.ok(f"/api/counters/{P1}/call-next")["called"]["visit_id"] == visit_id
    return pharmacist.ok(f"/api/visits/{visit_id}/dispensed")


def flat_routes(routes=None):
    """Every APIRoute of the app. FastAPI keeps an included router as one wrapper entry
    in app.routes, so a plain loop over app.routes sees /api/health and nothing else."""
    for route in app.routes if routes is None else routes:
        included = getattr(route, "original_router", None)
        if included is not None:
            yield from flat_routes(included.routes)
        elif isinstance(route, APIRoute):
            yield route


def live_tickets(visit_id):
    marks = ", ".join("?" for _ in LIVE_STATES)
    return rows(
        f"SELECT * FROM ticket WHERE visit_id = ? AND state IN ({marks})", visit_id, *LIVE_STATES
    )


def all_tickets(visit_id):
    return rows("SELECT * FROM ticket WHERE visit_id = ?", visit_id)


def stored_visit(visit_id):
    return rows("SELECT * FROM visit WHERE id = ?", visit_id)[0]


def model_intake(**changes):
    return json.dumps({**MODEL_INTAKE, **changes}, ensure_ascii=False)


@contextmanager
def real_mode_api(monkeypatch, chat_client, asr_client=None):
    """The app in real mode. The call to the runtime seam is the only thing replaced."""
    voice = asr_client or FakeAsrClient()
    built = runtime.build_runtime(llm_client=chat_client, asr_client=voice)
    monkeypatch.setattr(main.runtime, "build_runtime", lambda: built)
    with TestClient(app) as client:
        yield client


class Spoken(FakeAsrClient):
    """Transcribes to each line in turn."""

    def __init__(self, *lines):
        super().__init__()
        self._lines = list(lines)

    def automatic_speech_recognition(self, audio, **kw):
        self._text = self._lines.pop(0)
        return super().automatic_speech_recognition(audio, **kw)


def wav_upload():
    return {"audio": ("voice.wav", WAV_BYTES, "audio/wav")}


def data_lines(stream, count, timeout=5.0):
    """The next `count` SSE events, skipping heartbeats."""
    found = []
    deadline = time.monotonic() + timeout
    while len(found) < count:
        line = stream.lines.get(timeout=max(deadline - time.monotonic(), 0.01))
        if line.startswith("data: "):
            found.append(json.loads(line[len("data: "):]))
    return found


def no_more_events(stream, wait=0.2):
    """Whatever else arrives in a short wait, so an exact list stays exact."""
    extra = []
    deadline = time.monotonic() + wait
    while True:
        try:
            line = stream.lines.get(timeout=max(deadline - time.monotonic(), 0.01))
        except queue.Empty:
            return extra
        if line.startswith("data: "):
            extra.append(json.loads(line[len("data: "):]))


# Fatima, the full demo


def test_fatima_full_demo(api):
    nurse = staff(api, NURSE)
    assert nurse.ok("/api/demo/reset")["ok"] is True

    assert api.post("/api/auth/start", json={"qid": FATIMA_QID}).json() == {"otp_sent": True}
    verified = api.post("/api/auth/verify", json={"qid": FATIMA_QID, "otp": "0000"})
    assert verified.status_code == 200, verified.text
    fatima = Caller(api, verified.json()["token"])

    me = fatima.read("/api/me")
    assert me["patient"]["allergies"] == ["penicillin"]
    assert me["patient"]["registered_centre"]["id"] == "C-WAKRA"
    assert me["patient"]["registered_centre"]["name_en"] == "Al Wakra Health Centre"
    assert [dependent["id"] for dependent in me["dependents"]] == ["P004", "P005"]

    visit_id = open_visit(fatima)
    replies = [tell(fatima, visit_id, answer) for answer in FATIMA_ANSWERS]
    assert [reply["done"] for reply in replies] == [False, False, False, True]
    assert not any(reply["emergency"] for reply in replies)
    assert replies[-1]["reply"]
    confirmed = fatima.ok(f"/api/visits/{visit_id}/intake/confirm")
    assert confirmed["service"] == "gp"

    centres = fatima.read("/api/centres?service=gp")
    assert centres["default_centre_id"] == "C-WAKRA"
    assert centres["suggestion"] is None
    by_id = {centre["id"]: centre for centre in centres["centres"]}
    assert centres["centres"][0]["id"] == "C-WAKRA"
    assert by_id["C-WAKRA"]["wait_min"] == 12
    assert 30 <= by_id["C-AIRPORT"]["wait_min"] <= 40

    reserved = reserve(fatima, visit_id).json()
    assert reserved["ticket"]["number"] is None
    assert reserved["ticket"]["state"] == "reserved"
    assert reserved["ticket"]["people_ahead"] is None
    assert reserved["message"] == CHECK_IN_EN
    assert reserved["message_ar"] == CHECK_IN_AR

    arrived = arrive(fatima, visit_id).json()["ticket"]
    assert arrived["number"] == "T-014"
    assert arrived["people_ahead"] == 3
    assert arrived["est_wait_min"] == 12

    call = nurse.ok(f"/api/counters/{T1}/call-next")
    assert call["called"]["number"] == "T-014"
    assert call["called"]["visit_id"] == visit_id
    assert len(call["auto_completed"]) == 3
    assert "T-014" not in call["auto_completed"]
    queue_now = nurse.read(f"/api/counters/{T1}/queue")["tickets"]
    assert [row["number"] for row in queue_now if row["state"] == "called"] == ["T-014"]
    assert not any(row["simulated"] for row in queue_now)

    card = nurse.read(f"/api/staff/visits/{visit_id}")
    assert "penicillin" in card["patient"]["allergies"]
    spoken = [turn["text"] for turn in card["turns"] if turn["role"] == "patient"]
    assert spoken == list(FATIMA_ANSWERS)
    assert FATIMA_ANSWERS[0] == "عندي حرارة وكحة من ثلاث أيام"

    served = nurse.ok(f"/api/visits/{visit_id}/vitals", VITALS)
    assert served["ticket"]["state"] == "serving"
    assert served["escalated"] is False

    draft = nurse.ok(f"/api/visits/{visit_id}/handoff/draft")
    first = draft["suggestions"][0]
    assert first["name"].startswith("Dr. Noor")
    assert first["counter_id"] == "C-WAKRA-D4"
    assert first["doctor_id"] == DOCTOR2
    confirm = {"final_text": draft["text"], "doctor_id": first["doctor_id"]}
    moved = nurse.ok(f"/api/visits/{visit_id}/handoff/confirm", confirm)
    assert moved["ticket"]["number"] == "D-GP-023"

    state = fatima.read(f"/api/visits/{visit_id}")
    assert state["ticket"]["number"] == "D-GP-023"
    assert state["ticket"]["counter_id"] == "C-WAKRA-D4"
    assert state["stage"] == "doctor"

    doctor = staff(api, DOCTOR2)
    assert doctor.ok(f"/api/counters/{D4}/call-next")["called"]["number"] == "D-GP-023"
    consult = doctor.ok(f"/api/visits/{visit_id}/consult/done", PRESCRIPTION)
    assert consult["ticket"]["number"] == "P-031"
    state = fatima.read(f"/api/visits/{visit_id}")
    assert state["stage"] == "pharmacy"
    assert state["ticket"]["number"] == "P-031"

    pharmacist = staff(api, PHARMACIST)
    assert pharmacist.ok(f"/api/counters/{P1}/call-next")["called"]["number"] == "P-031"
    finished = pharmacist.ok(f"/api/visits/{visit_id}/dispensed")
    assert finished["status"] == "completed"

    # The default dose, frequency and days of both drugs reach the patient in both languages.
    english = {line["drug"]: line["line"] for line in finished["medicines"]["en"]}
    arabic = {line["drug"]: line["line"] for line in finished["medicines"]["ar"]}
    assert set(english) == set(arabic) == {"DR-PARA", "DR-DEXT"}
    assert "Paracetamol" in english["DR-PARA"]
    assert "500 mg" in english["DR-PARA"]
    assert "every 6 hours" in english["DR-PARA"]
    assert "3 days" in english["DR-PARA"]
    assert "10 ml" in english["DR-DEXT"]
    assert "باراسيتامول" in arabic["DR-PARA"]
    assert "ديكستروميثورفان" in arabic["DR-DEXT"]
    assert fatima.read(f"/api/visits/{visit_id}")["status"] == "completed"
    assert fatima.read(f"/api/visits/{visit_id}")["medicines"] == finished["medicines"]

    types = event_types(visit_id)
    for wanted in ("consent.given", "intake.confirmed", "handoff.confirmed", "dispensed"):
        assert wanted in types
    assert not live_tickets(visit_id)


def test_fatima_voice_real_mode_fake_client(api_env, monkeypatch):
    chat = FakeChatClient([GATE_PASSING_REPLY, model_intake()])
    voice = Spoken(FATIMA_ANSWERS[0], FATIMA_ANSWERS[1])
    with real_mode_api(monkeypatch, chat, voice) as client:
        health = client.get("/api/health").json()
        assert health == {"status": "ok", "ai_mode": "real", "simulate_load": True}

        fatima = patient(client, FATIMA_QID)
        visit_id = open_visit(fatima)
        heard = client.post("/api/asr", files=wav_upload(), headers=fatima.headers)
        assert heard.status_code == 200, heard.text
        assert heard.json() == {"text": FATIMA_ANSWERS[0]}

        first = fatima.ok(f"/api/visits/{visit_id}/chat", heard.json())
        assert first["reply"] == GATE_PASSING_REPLY
        assert first["ai_source"] == "model"
        assert first["done"] is False
        assert first["transcript"] is None

        # The same recording can go straight to the chat route.
        spoken = client.post(
            f"/api/visits/{visit_id}/chat", files=wav_upload(), headers=fatima.headers
        )
        assert spoken.status_code == 200, spoken.text
        second = spoken.json()
        assert second["transcript"] == FATIMA_ANSWERS[1]
        assert second["done"] is True
        assert second["ai_source"] == "model"

        fatima.ok(f"/api/visits/{visit_id}/intake/confirm")
        assert reserve(fatima, visit_id).json()["ticket"]["number"] is None
        ticket = arrive(fatima, visit_id).json()["ticket"]
        assert ticket["number"] == "T-014"

        nurse = staff(client, NURSE)
        assert nurse.ok(f"/api/counters/{T1}/call-next")["called"]["number"] == "T-014"
        assert nurse.read(f"/api/staff/visits/{visit_id}")["ai_mode"] == "real"
    assert len(chat.calls) == 2
    assert voice.calls == [WAV_BYTES, WAV_BYTES]


def test_asr_simulated_is_503_with_a_message(api):
    fatima = patient(api, FATIMA_QID)
    assert api.get("/api/health").json()["ai_mode"] == "simulated"
    response = api.post("/api/asr", files=wav_upload(), headers=fatima.headers)
    assert response.status_code == 503
    body = response.json()
    assert body["error"] == "asr_unavailable"
    assert body["message"] == "Voice is not available right now. Please type your message."
    assert body["message_ar"]
    assert "text" not in body and "transcript" not in body


# Ahmed, the refill


def test_ahmed_refill(api):
    ahmed = patient(api, AHMED_QID)
    visit_id = open_visit(ahmed)
    reply = tell(ahmed, visit_id, AHMED_TEXT)
    assert reply["refill"]
    assert reply["refill"]["medicine"]
    assert "amlodipine" in reply["refill"]["medicine"]
    assert reply["status"] == "deflected_refill"
    assert reply["emergency"] is False
    assert all_tickets(visit_id) == []

    refused = reserve(ahmed, visit_id, "C-RAYYAN")
    assert refused.status_code == 409
    assert all_tickets(visit_id) == []

    # The variant: he still wants a visit.
    went_on = ahmed.ok(f"/api/visits/{visit_id}/refill/continue")
    assert went_on["service"] == "gp"
    assert stored_visit(visit_id)["service"] == "gp"
    centres = ahmed.read("/api/centres?service=gp")
    assert centres["default_centre_id"] == "C-RAYYAN"

    assert reserve(ahmed, visit_id, "C-RAYYAN").json()["ticket"]["number"] is None
    ticket = arrive(ahmed, visit_id).json()["ticket"]
    assert ticket["centre_id"] == "C-RAYYAN"
    assert ticket["people_ahead"] == 0  # Ahead of the four simulated tickets.

    stored = live_tickets(visit_id)[0]
    assert stored["priority"] == 1

    nurse = staff(api, RAYYAN_NURSE)
    waiting = nurse.read(f"/api/counters/{RAYYAN_T1}/queue")["tickets"]
    assert waiting[0]["visit_id"] == visit_id
    assert waiting[0]["priority"] == 1
    assert len(waiting) == 5
    assert [row["priority"] for row in waiting[1:]] == [0, 0, 0, 0]
    assert all(row["simulated"] for row in waiting[1:])
    # His number came after theirs, and the rule still puts him first.
    assert all(ticket["number"] > row["number"] for row in waiting[1:])

    call = nurse.ok(f"/api/counters/{RAYYAN_T1}/call-next")
    assert call["called"]["visit_id"] == visit_id
    assert call["auto_completed"] == []


# Ravi, the emergency


def test_ravi_emergency(api):
    ravi = patient(api, RAVI_QID)
    visit_id = open_visit(ravi)
    reply = tell(ravi, visit_id, RAVI_TEXT)
    assert reply["emergency"] is True
    assert reply["status"] == "redirected_emergency"
    assert reply["done"] is False
    assert reply["intake"] is None
    assert reply["nearest_ed"]["id"] == "H-HGH"
    assert reply["nearest_ed"]["distance_km"] > 0
    assert not reply["reply"].rstrip().endswith(("?", "؟"))
    assert "999" in reply["reply"]
    assert all_tickets(visit_id) == []

    assert reserve(ravi, visit_id, "C-AIRPORT").status_code == 409
    assert arrive(ravi, visit_id).status_code == 409
    assert all_tickets(visit_id) == []

    override = ravi.ok(f"/api/visits/{visit_id}/emergency/override")
    assert override["ticket"] is None
    assert override["status"] == "redirected_emergency"
    assert override["message"] == STAFF_ROUTE_EN
    assert override["message_ar"]
    assert "emergency.override" in event_types(visit_id)
    assert all_tickets(visit_id) == []
    assert stored_visit(visit_id)["status"] == "redirected_emergency"

    again = ravi.post("/api/visits", {"consent": True})
    assert again.status_code == 409
    assert again.json()["error"] == "emergency_today"
    assert again.json()["visit_id"] == visit_id

    state = ravi.read(f"/api/visits/{visit_id}")
    assert state["stage"] == "emergency"
    assert state["ticket"] is None
    assert state["emergency"]["nearest_ed"]["id"] == "H-HGH"


# Every screen, live


VISIT_STREAM = [
    ("ticket.activated", "T-014"),
    ("ticket.called", "T-014"),
    ("ticket.serving", "T-014"),
    ("ticket.done", "T-014"),
    ("ticket.activated", "D-GP-023"),
    ("ticket.called", "D-GP-023"),
    ("ticket.serving", "D-GP-023"),
    ("ticket.done", "D-GP-023"),
    ("ticket.activated", "P-031"),
    ("ticket.called", "P-031"),
    ("ticket.serving", "P-031"),
    ("ticket.done", "P-031"),
]
AT_TRIAGE = [
    ("ticket.activated", "T-014"),
    ("ticket.simulated_done", "T-011"),
    ("ticket.simulated_done", "T-012"),
    ("ticket.simulated_done", "T-013"),
    ("ticket.called", "T-014"),
    ("ticket.serving", "T-014"),
    ("ticket.done", "T-014"),
]
ON_THE_DISPLAY = [*AT_TRIAGE, *VISIT_STREAM[4:]]
VAULT_KEYS = {"type", "visit_id", "ticket", "counter", "people_ahead"}


def seen(events):
    return [(event["type"], event["ticket"]) for event in events]


def test_all_screens_update_on_one_journey(live_api):
    http = live_api.http
    fatima = patient(http, FATIMA_QID)
    nurse = staff(http, NURSE)
    doctor = staff(http, DOCTOR2)
    pharmacist = staff(http, PHARMACIST)
    visit_id = reserved_visit(fatima)

    with (
        open_stream(live_api, f"/api/visits/{visit_id}/stream", fatima.token) as on_phone,
        open_stream(live_api, f"/api/counters/{T1}/stream", nurse.token) as on_console,
        open_stream(live_api, "/api/display/C-WAKRA/stream", nurse.token) as on_tv,
    ):
        for stream in (on_phone, on_console, on_tv):
            assert stream.until(": connected")[0] == "status 200"

        assert arrive(fatima, visit_id).status_code == 200
        to_counter(nurse, visit_id)
        hand_off(nurse, visit_id)
        see_doctor(doctor, visit_id)
        assert dispense(pharmacist, visit_id)["status"] == "completed"

        phone = data_lines(on_phone, len(VISIT_STREAM))
        console = data_lines(on_console, len(AT_TRIAGE))
        tv = data_lines(on_tv, len(ON_THE_DISPLAY))
        extras = [no_more_events(stream) for stream in (on_phone, on_console, on_tv)]

    assert seen(phone) == VISIT_STREAM
    assert seen(console) == AT_TRIAGE
    assert seen(tv) == ON_THE_DISPLAY
    assert extras == [[], [], []]

    for event in [*phone, *console]:
        assert set(event) == VAULT_KEYS
    assert all(event["visit_id"] == visit_id for event in phone)
    assert [event["visit_id"] for event in console if "simulated" in event["type"]] == [None] * 3
    for event in tv:
        assert set(event) == VAULT_KEYS - {"visit_id"}

    called = next(event for event in phone if event["type"] == "ticket.called")
    assert called == {
        "type": "ticket.called",
        "visit_id": visit_id,
        "ticket": "T-014",
        "counter": "Triage 1",
        "people_ahead": 0,
    }


@pytest.mark.parametrize("wanted", LIVE_STATES)
def test_live_tickets_finds_each_live_state(api, wanted):
    """So a count of zero in the red-line tests cannot pass by looking at nothing."""
    fatima = patient(api, FATIMA_QID)
    nurse = staff(api, NURSE)
    visit_id = reserved_visit(fatima)
    if wanted != "reserved":
        arrive(fatima, visit_id)
    if wanted in ("called", "serving"):
        nurse.ok(f"/api/counters/{T1}/call-next")
    if wanted == "serving":
        nurse.ok(f"/api/visits/{visit_id}/vitals", VITALS)
    assert [ticket["state"] for ticket in live_tickets(visit_id)] == [wanted]
