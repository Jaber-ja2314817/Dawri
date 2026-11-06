"""The red lines over HTTP: what no route may ever do, whichever way it is reached."""

from __future__ import annotations

import re
from collections.abc import Iterator
from datetime import datetime, timezone

import pytest

from backend import timeutil
from backend.ai import runtime
from backend.main import app
from backend.routers import demo
from backend.tests.ai_fakes import FakeAsrClient, FakeChatClient
from backend.tests.api_helpers import (
    AHMED_QID,
    AHMED_TEXT,
    DESK,
    DOCTOR2,
    FATIMA_ANSWERS,
    FATIMA_QID,
    NURSE,
    PHARMACIST,
    RAVI_QID,
    RAVI_TEXT,
    bearer,
)
from backend.tests.conftest import FakeClock
from backend.tests.test_api_e2e import (
    GATE_PASSING_REPLY,
    RAYYAN_NURSE,
    VITALS,
    Caller,
    all_tickets,
    arrive,
    arrived_visit,
    confirmed_visit,
    dispense,
    flat_routes,
    hand_off,
    live_tickets,
    model_intake,
    open_visit,
    patient,
    real_mode_api,
    reserve,
    reserved_visit,
    see_doctor,
    staff,
    stored_visit,
    tell,
    to_counter,
    wav_upload,
)
from backend.tests.test_api_staff import (
    D4,
    FATIMA,
    SALEM_ANSWERS,
    T1,
    event_types,
    execute,
    rows,
    table_dump,
)

SALEM_QID = "DEMO-10006"
MARIAM = "P005"
CHEST_PAIN = "I have chest pain now"
DESK_WORDS = "Chest pain since morning"
BABY_AR = ("ابني الرضيع مريض", "اليوم", "٦")
EDITED = "Sharp pain when swallowing, 5 days"
CANNOT_BREATHE = "I can't breathe"
AT_THE_CENTRE = ("in_triage", "in_doctor", "in_pharmacy")
PATIENT_LIVE = "('reserved', 'active', 'called', 'serving')"


def walk(value) -> Iterator[tuple[str | None, object]]:
    """Every (key, value) pair in a JSON value, with key None for a list item or the root."""
    if isinstance(value, dict):
        for key, item in value.items():
            yield key, item
            yield from walk(item)
    elif isinstance(value, list):
        for item in value:
            yield None, item
            yield from walk(item)


def strings_in(value) -> Iterator[str]:
    if isinstance(value, str):
        yield value
    for _, item in walk(value):
        if isinstance(item, str):
            yield item


def keys_in(value) -> set[str]:
    return {key for key, _ in walk(value) if key is not None}


# Nurse edit reaches the doctor


def test_nurse_edit_reaches_the_doctor(api):
    fatima = patient(api, FATIMA_QID)
    nurse = staff(api, NURSE)
    doctor = staff(api, DOCTOR2)
    visit_id = arrived_visit(fatima)
    to_counter(nurse, visit_id)
    original = rows("SELECT transcript, json FROM intake WHERE visit_id = ?", visit_id)[0]

    edit = nurse.put(f"/api/visits/{visit_id}/intake", {"json": {"chief_complaint": EDITED}})
    assert edit.status_code == 200, edit.text
    assert edit.json()["edited"] is True
    assert edit.json()["intake"]["chief_complaint"] == EDITED

    draft = nurse.ok(f"/api/visits/{visit_id}/handoff/draft")
    assert EDITED.lower() in draft["text"].lower()
    final_text = draft["text"]
    body = {"final_text": final_text, "doctor_id": DOCTOR2}
    assert nurse.ok(f"/api/visits/{visit_id}/handoff/confirm", body)["ticket"]["number"]

    seen = doctor.read(f"/api/staff/visits/{visit_id}")
    assert seen["intake"]["chief_complaint"] == EDITED
    assert seen["edited"] is True
    assert seen["handoff"]["final_text"] == final_text
    assert EDITED.lower() in seen["handoff"]["final_text"].lower()

    # Byte for byte: the edit lands beside the transcript and never in it.
    spoken = [turn["text"] for turn in seen["turns"] if turn["role"] == "patient"]
    assert spoken == list(FATIMA_ANSWERS)
    assert seen["patient_words"] == list(FATIMA_ANSWERS)
    after = rows("SELECT transcript, json FROM intake WHERE visit_id = ?", visit_id)[0]
    assert after == original


def test_the_doctor_sees_a_final_text_the_nurse_retyped(api):
    fatima = patient(api, FATIMA_QID)
    nurse = staff(api, NURSE)
    doctor = staff(api, DOCTOR2)
    visit_id = arrived_visit(fatima)
    to_counter(nurse, visit_id)
    nurse.ok(f"/api/visits/{visit_id}/handoff/draft")
    body = {"final_text": f"Nurse wrote this. {EDITED}.", "doctor_id": DOCTOR2}
    nurse.ok(f"/api/visits/{visit_id}/handoff/confirm", body)
    assert doctor.read(f"/api/staff/visits/{visit_id}")["handoff"]["final_text"] == (
        f"Nurse wrote this. {EDITED}."
    )


def test_an_edit_after_a_draft_forces_a_new_draft(api):
    fatima = patient(api, FATIMA_QID)
    nurse = staff(api, NURSE)
    visit_id = arrived_visit(fatima)
    to_counter(nurse, visit_id)
    stale = nurse.ok(f"/api/visits/{visit_id}/handoff/draft")["text"]

    edit = nurse.put(f"/api/visits/{visit_id}/intake", {"json": {"chief_complaint": EDITED}})
    assert edit.json()["draft_cleared"] is True

    body = {"final_text": stale, "doctor_id": DOCTOR2}
    refused = nurse.post(f"/api/visits/{visit_id}/handoff/confirm", body)
    assert refused.status_code == 409
    assert refused.json()["error"] == "draft_required"
    assert len(live_tickets(visit_id)) == 1
    assert live_tickets(visit_id)[0]["number"] == "T-014"

    fresh = nurse.ok(f"/api/visits/{visit_id}/handoff/draft")["text"]
    assert EDITED.lower() in fresh.lower()
    body["final_text"] = fresh
    moved = nurse.ok(f"/api/visits/{visit_id}/handoff/confirm", body)
    assert moved["ticket"]["number"] == "D-GP-023"


# No ticket on a red flag


def visit_at(status, api, person, nurse):
    """A visit in one of the statuses past arrival, reached through the normal routes."""
    visit_id = arrived_visit(person)
    if status != "in_triage":
        to_counter(nurse, visit_id)
        hand_off(nurse, visit_id)
    if status == "in_pharmacy":
        see_doctor(staff(api, DOCTOR2), visit_id)
    assert stored_visit(visit_id)["status"] == status
    return visit_id


class Scene:
    """A visit stopped by a red flag, and the people who could try to carry on."""

    def __init__(self, api, visit_id, person, qid, nurse, arrive_status=409):
        self.api = api
        self.visit_id = visit_id
        self.person = person
        self.qid = qid
        self.nurse = nurse
        self.arrive_status = arrive_status


def ravi_in_english(api, nurse):
    ravi = patient(api, RAVI_QID)
    visit_id = open_visit(ravi)
    assert tell(ravi, visit_id, RAVI_TEXT)["emergency"]
    return Scene(api, visit_id, ravi, RAVI_QID, nurse)


def ravi_in_arabic(api, nurse):
    ravi = patient(api, RAVI_QID)
    visit_id = open_visit(ravi)
    assert tell(ravi, visit_id, "ألم في الصدر ينزل إلى ذراعي اليسار")["emergency"]
    return Scene(api, visit_id, ravi, RAVI_QID, nurse)


def split_cue_in_english(api, nurse):
    salem = patient(api, SALEM_QID)
    visit_id = open_visit(salem)
    assert tell(salem, visit_id, "my baby is sick", "today", "6")["reply"] == (
        "Do you have a fever?"
    )
    assert tell(salem, visit_id, "high")["emergency"]
    return Scene(api, visit_id, salem, SALEM_QID, nurse)


def split_cue_in_arabic(api, nurse):
    salem = patient(api, SALEM_QID)
    visit_id = open_visit(salem)
    assert not tell(salem, visit_id, *BABY_AR)["emergency"]
    assert tell(salem, visit_id, "عالية")["emergency"]
    return Scene(api, visit_id, salem, SALEM_QID, nurse)


def chest_pain_after_reservation(api, nurse):
    fatima = patient(api, FATIMA_QID)
    visit_id = reserved_visit(fatima)
    assert live_tickets(visit_id)[0]["state"] == "reserved"
    assert tell(fatima, visit_id, CHEST_PAIN)["emergency"]
    assert [row["state"] for row in all_tickets(visit_id)] == ["released"]
    return Scene(api, visit_id, fatima, FATIMA_QID, nurse)


def chest_pain_on_a_lapsed_reservation(api, nurse):
    fatima = patient(api, FATIMA_QID)
    clock = FakeClock(timeutil.utcnow())
    api.app.state.engine.clock = clock
    visit_id = reserved_visit(fatima)
    clock.advance(minutes=45)
    assert fatima.read(f"/api/visits/{visit_id}")["status"] == "expired"
    assert tell(fatima, visit_id, CHEST_PAIN)["emergency"]
    # That ticket lapsed in its own right, so the arrival reports the lapse.
    return Scene(api, visit_id, fatima, FATIMA_QID, nurse, arrive_status=410)


def walk_in_with_chest_pain(api, nurse):
    desk = staff(api, DESK)
    body = desk.ok("/api/desk/walk-in", {"qid": SALEM_QID, "complaint": "Chest pain since morning"})
    assert body["emergency"] is True
    assert body["ticket"] is None
    return Scene(api, body["visit_id"], patient(api, SALEM_QID), SALEM_QID, nurse)


def chest_pain_told_to_the_desk_after_reservation(api, nurse):
    fatima = patient(api, FATIMA_QID)
    visit_id = reserved_visit(fatima)
    body = staff(api, DESK).ok("/api/desk/walk-in", {"qid": FATIMA_QID, "complaint": DESK_WORDS})
    assert body["emergency"] is True
    assert body["ticket"] is None
    assert body["visit_id"] == visit_id
    assert [row["state"] for row in all_tickets(visit_id)] == ["released"]
    return Scene(api, visit_id, fatima, FATIMA_QID, nurse)


def chest_pain_told_to_another_centres_desk(api, nurse):
    fatima = patient(api, FATIMA_QID)
    visit_id = reserved_visit(fatima, centre_id="C-AIRPORT")
    rayyan_desk = staff(api, "S-RAY-DESK1")
    body = rayyan_desk.ok("/api/desk/walk-in", {"qid": FATIMA_QID, "complaint": DESK_WORDS})
    assert body["emergency"] is True
    assert body["visit_id"] == visit_id
    return Scene(api, visit_id, fatima, FATIMA_QID, nurse)


def chest_pain_told_to_the_desk_while_waiting_at_triage(api, nurse):
    fatima = patient(api, FATIMA_QID)
    visit_id = arrived_visit(fatima)
    assert live_tickets(visit_id)[0]["state"] == "active"
    body = staff(api, DESK).ok("/api/desk/walk-in", {"qid": FATIMA_QID, "complaint": DESK_WORDS})
    assert body["emergency"] is True
    assert body["visit_id"] == visit_id
    return Scene(api, visit_id, fatima, FATIMA_QID, nurse)


def red_flag_on_a_sibling_of_a_ticket(api, nurse):
    fatima = patient(api, FATIMA_QID)
    sibling = open_visit(fatima)
    visit_id = arrived_visit(fatima)
    assert tell(fatima, sibling, CHEST_PAIN)["emergency"]
    return Scene(api, visit_id, fatima, FATIMA_QID, nurse)


def red_flag_on_a_sibling_of_a_reservation(api, nurse):
    fatima = patient(api, FATIMA_QID)
    sibling = open_visit(fatima)
    visit_id = reserved_visit(fatima)
    assert live_tickets(visit_id)[0]["state"] == "reserved"
    assert tell(fatima, sibling, CHEST_PAIN)["emergency"]
    return Scene(api, visit_id, fatima, FATIMA_QID, nurse)


def nurse_urgent_to_ed(api, nurse):
    fatima = patient(api, FATIMA_QID)
    visit_id = arrived_visit(fatima)
    answer = to_counter(nurse, visit_id, {**VITALS, "urgency": "urgent"})
    assert answer["escalated"] is True
    assert answer["ticket"]["state"] == "released"
    assert [row["state"] for row in all_tickets(visit_id)] == ["released"]
    return Scene(api, visit_id, fatima, FATIMA_QID, nurse)


def chest_pain_in_the_waiting_room(api, nurse):
    fatima = patient(api, FATIMA_QID)
    visit_id = arrived_visit(fatima)
    assert live_tickets(visit_id)[0]["number"] == "T-014"
    assert tell(fatima, visit_id, RAVI_TEXT)["emergency"]
    return Scene(api, visit_id, fatima, FATIMA_QID, nurse)


def cannot_breathe_at_the_doctor(api, nurse):
    fatima = patient(api, FATIMA_QID)
    visit_id = visit_at("in_doctor", api, fatima, nurse)
    assert tell(fatima, visit_id, CANNOT_BREATHE)["emergency"]
    return Scene(api, visit_id, fatima, FATIMA_QID, nurse)


def chest_pain_at_the_pharmacy(api, nurse):
    fatima = patient(api, FATIMA_QID)
    visit_id = visit_at("in_pharmacy", api, fatima, nurse)
    assert tell(fatima, visit_id, CHEST_PAIN)["emergency"]
    return Scene(api, visit_id, fatima, FATIMA_QID, nurse)


SCENES = [
    ravi_in_english,
    ravi_in_arabic,
    split_cue_in_english,
    split_cue_in_arabic,
    chest_pain_after_reservation,
    chest_pain_on_a_lapsed_reservation,
    walk_in_with_chest_pain,
    chest_pain_told_to_the_desk_after_reservation,
    chest_pain_told_to_another_centres_desk,
    chest_pain_told_to_the_desk_while_waiting_at_triage,
    red_flag_on_a_sibling_of_a_ticket,
    red_flag_on_a_sibling_of_a_reservation,
    nurse_urgent_to_ed,
    chest_pain_in_the_waiting_room,
    cannot_breathe_at_the_doctor,
    chest_pain_at_the_pharmacy,
]


def assert_everything_is_refused(scene):
    """Each attempt is refused, and none of them changes a stored row."""
    visit_id = scene.visit_id
    person = scene.person
    nurse = scene.nurse
    assert live_tickets(visit_id) == []
    before = table_dump("ticket", "visit", "handoff", "vitals")

    for centre_id in ("C-WAKRA", "C-RAYYAN"):
        assert reserve(person, visit_id, centre_id).status_code == 409
    assert arrive(person, visit_id).status_code == scene.arrive_status
    door = person.post(f"/api/visits/{visit_id}/arrive", {"qr_code": "DOOR-C-WAKRA"})
    assert door.status_code == scene.arrive_status

    # A nurse at another centre is refused sooner, and a visit that never had a centre
    # belongs to no nurse.
    assert nurse.post(f"/api/visits/{visit_id}/handoff/draft").status_code in (403, 409)
    body = {"final_text": "Anything.", "doctor_id": DOCTOR2}
    confirm = nurse.post(f"/api/visits/{visit_id}/handoff/confirm", body)
    assert confirm.status_code in (403, 409)
    assert nurse.post(f"/api/visits/{visit_id}/vitals", VITALS).status_code in (403, 409)
    assert nurse.post(f"/api/demo/fast-forward/{visit_id}").status_code in (403, 409)

    again = person.post("/api/visits", {"consent": True})
    assert again.status_code == 409
    assert again.json()["error"] == "emergency_today"
    desk = staff(scene.api, DESK)
    walk_in = desk.post("/api/desk/walk-in", {"qid": scene.qid, "complaint": "Sore throat"})
    assert walk_in.status_code == 409

    assert table_dump("ticket", "visit", "handoff", "vitals") == before
    assert live_tickets(visit_id) == []
    assert stored_visit(visit_id)["status"] == "redirected_emergency"
    state = person.read(f"/api/visits/{visit_id}")
    assert state["stage"] == "emergency"
    assert state["ticket"] is None
    assert state["go_to"] is None


@pytest.mark.parametrize("scene", SCENES, ids=lambda scene: scene.__name__)
def test_no_ticket_on_a_red_flag(api, scene):
    assert_everything_is_refused(scene(api, staff(api, NURSE)))


def live_of_patient(patient_id):
    return rows(
        "SELECT ticket.* FROM ticket JOIN visit ON visit.id = ticket.visit_id "
        f"WHERE visit.patient_id = ? AND ticket.state IN {PATIENT_LIVE}",
        patient_id,
    )


def chat_audio(person, visit_id):
    return person.api.post(
        f"/api/visits/{visit_id}/chat", files=wav_upload(), headers=bearer(person.token)
    )


def use_voice(api, words):
    """Real-mode voice with a fake client. The LLM stays simulated."""
    api.app.state.ai = runtime.build_runtime(asr_client=FakeAsrClient(words))


# A red flag past arrival


@pytest.mark.parametrize("status", AT_THE_CENTRE)
@pytest.mark.parametrize(
    "words", [RAVI_TEXT, CANNOT_BREATHE, "ألم في الصدر ينزل إلى ذراعي اليسار"]
)
def test_a_red_flag_past_arrival_stops_the_visit(api, status, words):
    fatima = patient(api, FATIMA_QID)
    nurse = staff(api, NURSE)
    visit_id = visit_at(status, api, fatima, nurse)

    body = tell(fatima, visit_id, words)

    assert body["emergency"] is True
    assert body["status"] == "redirected_emergency"
    assert body["nearest_ed"]["id"] == "H-WAKRA"
    assert body["transcript"] is None
    assert live_of_patient(FATIMA) == []

    card = nurse.read(f"/api/staff/visits/{visit_id}")
    assert card["red_flags_checked"].startswith("Red flag raised: ")
    assert card["patient_words"][-1] == words
    assert {"role": "patient", "text": words} in card["turns"]
    assert "redflag.hit" in event_types(visit_id)

    state = fatima.read(f"/api/visits/{visit_id}")
    assert state["stage"] == "emergency"
    assert state["ticket"] is None
    assert state["emergency"]["nearest_ed"]["id"] == "H-WAKRA"


def test_the_answer_has_the_shape_of_any_other_chat_emergency(api):
    fatima = patient(api, FATIMA_QID)
    ravi = patient(api, RAVI_QID)
    usual = tell(ravi, open_visit(ravi), RAVI_TEXT)
    late = tell(fatima, arrived_visit(fatima), RAVI_TEXT)
    assert set(late) == set(usual)
    assert late["ai_source"] == usual["ai_source"] == "rules"
    assert not keys_in(late) & {"summary_for_nurse", "turns", "patient_words"}


def test_a_called_patient_is_stopped_at_the_counter(api):
    fatima = patient(api, FATIMA_QID)
    nurse = staff(api, NURSE)
    visit_id = arrived_visit(fatima)
    assert nurse.ok(f"/api/counters/{T1}/call-next")["called"]["visit_id"] == visit_id
    assert tell(fatima, visit_id, RAVI_TEXT)["status"] == "redirected_emergency"
    assert live_of_patient(FATIMA) == []


def test_a_walk_in_can_report_a_red_flag_from_the_waiting_room(api):
    desk = staff(api, DESK)
    body = desk.ok("/api/desk/walk-in", {"qid": SALEM_QID, "complaint": "Sore knee"})
    salem = patient(api, SALEM_QID)
    answer = tell(salem, body["visit_id"], CHEST_PAIN)
    assert answer["status"] == "redirected_emergency"
    assert live_tickets(body["visit_id"]) == []


def test_self_harm_past_arrival_gets_the_support(api):
    fatima = patient(api, FATIMA_QID)
    visit_id = arrived_visit(fatima)
    body = tell(fatima, visit_id, "I want to end my life")
    assert body["emergency"] is True
    assert body["self_harm"] is True
    assert live_tickets(visit_id) == []


def test_a_cue_past_the_storage_cut_still_stops_the_visit(api):
    fatima = patient(api, FATIMA_QID)
    nurse = staff(api, NURSE)
    visit_id = arrived_visit(fatima)
    message = "my day was long. " * 200 + CANNOT_BREATHE
    assert len(message) > 3000

    body = tell(fatima, visit_id, message)

    assert body["status"] == "redirected_emergency"
    assert live_tickets(visit_id) == []
    stored = nurse.read(f"/api/staff/visits/{visit_id}")["patient_words"][-1]
    assert stored == message[:2000]


def test_voice_past_arrival_goes_the_same_way(api):
    fatima = patient(api, FATIMA_QID)
    visit_id = arrived_visit(fatima)
    use_voice(api, RAVI_TEXT)

    response = chat_audio(fatima, visit_id)

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["emergency"] is True
    assert body["status"] == "redirected_emergency"
    assert body["transcript"] == RAVI_TEXT
    assert live_tickets(visit_id) == []
    assert "redflag.hit" in event_types(visit_id)


def test_arriving_during_the_transcription_does_not_lose_the_words(api):
    """The status is read once the words are known, and not before."""
    fatima = patient(api, FATIMA_QID)
    visit_id = reserved_visit(fatima)
    engine = api.app.state.engine

    class ArrivesWhileListening(FakeAsrClient):
        def automatic_speech_recognition(self, audio, **kw):
            engine.activate(engine.live_ticket(visit_id).id)
            return super().automatic_speech_recognition(audio, **kw)

    api.app.state.ai = runtime.build_runtime(asr_client=ArrivesWhileListening(RAVI_TEXT))
    body = chat_audio(fatima, visit_id).json()
    assert body["status"] == "redirected_emergency"
    assert live_tickets(visit_id) == []
    assert "redflag.hit" in event_types(visit_id)


@pytest.mark.parametrize("status", AT_THE_CENTRE)
@pytest.mark.parametrize(
    "words",
    ["hello", "No chest pain, I am just tired", "x " * 1500],
    ids=["plain", "denied", "over long"],
)
def test_no_hit_past_arrival_stays_refused_and_changes_nothing(api, status, words):
    fatima = patient(api, FATIMA_QID)
    visit_id = visit_at(status, api, fatima, staff(api, NURSE))
    before = table_dump("ticket", "visit", "intake", "event")

    response = fatima.post(f"/api/visits/{visit_id}/chat", {"text": words})

    assert response.status_code == 409
    assert response.json()["error"] == "visit_not_in_intake"
    assert table_dump("ticket", "visit", "intake", "event") == before


def test_voice_with_no_hit_past_arrival_stays_refused(api):
    fatima = patient(api, FATIMA_QID)
    visit_id = arrived_visit(fatima)
    use_voice(api, "How long is the wait?")
    response = chat_audio(fatima, visit_id)
    assert response.status_code == 409
    assert response.json()["error"] == "visit_not_in_intake"
    assert len(live_tickets(visit_id)) == 1


def test_a_blank_message_past_arrival_is_still_invalid(api):
    fatima = patient(api, FATIMA_QID)
    visit_id = arrived_visit(fatima)
    response = fatima.post(f"/api/visits/{visit_id}/chat", {"text": "   "})
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_text"


@pytest.mark.parametrize("status", ["completed", "cancelled"])
def test_a_finished_visit_still_refuses_a_red_flag(api, status):
    """Only a visit in the centre is read: nothing here is left to take out of the queue."""
    fatima = patient(api, FATIMA_QID)
    visit_id = open_visit(fatima)
    execute("UPDATE visit SET status = ? WHERE id = ?", status, visit_id)
    response = fatima.post(f"/api/visits/{visit_id}/chat", {"text": CANNOT_BREATHE})
    assert response.status_code == 409
    assert response.json()["error"] == "visit_not_in_intake"


def test_the_model_is_never_called_past_arrival(api_env, monkeypatch):
    chat = FakeChatClient([model_intake()])  # A second call would fail the test.
    with real_mode_api(monkeypatch, chat) as client:
        fatima = patient(client, FATIMA_QID)
        visit_id = confirmed_visit(fatima, answers=("I have a fever and a cough",))
        assert reserve(fatima, visit_id).status_code == 200
        assert arrive(fatima, visit_id).status_code == 200
        calls = len(chat.calls)
        refused = fatima.post(f"/api/visits/{visit_id}/chat", {"text": "hello"})
        assert refused.status_code == 409
        assert tell(fatima, visit_id, RAVI_TEXT)["ai_source"] == "rules"
        assert len(chat.calls) == calls


def test_a_ticket_that_moves_on_during_the_red_flag_still_leaves_the_queue(api, monkeypatch):
    """The handoff lands between the look at the tickets and the escalate."""
    fatima = patient(api, FATIMA_QID)
    nurse = staff(api, NURSE)
    visit_id = arrived_visit(fatima)
    to_counter(nurse, visit_id)
    engine = api.app.state.engine
    real_escalate = engine.escalate
    moved = []

    def moved_first(ticket_id, reason):
        if not moved:
            moved.append(engine.advance(ticket_id, D4))
        return real_escalate(ticket_id, reason)

    monkeypatch.setattr(engine, "escalate", moved_first)
    assert tell(fatima, visit_id, CANNOT_BREATHE)["status"] == "redirected_emergency"
    assert moved
    assert live_of_patient(FATIMA) == []


def test_the_nurse_sees_what_the_desk_heard(api):
    fatima = patient(api, FATIMA_QID)
    nurse = staff(api, NURSE)
    visit_id = reserved_visit(fatima)
    staff(api, DESK).ok("/api/desk/walk-in", {"qid": FATIMA_QID, "complaint": DESK_WORDS})
    card = nurse.read(f"/api/staff/visits/{visit_id}")
    assert DESK_WORDS in card["patient_words"]
    assert card["patient_words"][: len(FATIMA_ANSWERS)] == list(FATIMA_ANSWERS)
    assert card["red_flags_checked"].startswith("Red flag raised: ")
    assert "redflag.hit" in event_types(visit_id)
    assert "desk.red_flag" in event_types(visit_id)


def test_the_desk_stops_only_the_patient_it_heard(api):
    fatima = patient(api, FATIMA_QID)
    salem = patient(api, SALEM_QID)
    other = arrived_visit(salem, SALEM_ANSWERS)
    visit_id = reserved_visit(fatima)
    staff(api, DESK).ok("/api/desk/walk-in", {"qid": FATIMA_QID, "complaint": DESK_WORDS})
    assert live_tickets(visit_id) == []
    assert [row["state"] for row in live_tickets(other)] == ["active"]


def test_a_plain_complaint_for_an_open_visit_is_still_refused_and_stores_nothing(api):
    fatima = patient(api, FATIMA_QID)
    visit_id = reserved_visit(fatima)
    before = table_dump("ticket", "visit", "intake")
    body = {"qid": FATIMA_QID, "complaint": "Sore throat"}
    refused = staff(api, DESK).post("/api/desk/walk-in", body)
    assert refused.status_code == 409
    assert refused.json()["error"] == "active_visit"
    assert refused.json()["visit_id"] == visit_id
    assert table_dump("ticket", "visit", "intake") == before


def test_a_denied_cue_at_the_desk_does_not_stop_the_open_visit(api):
    fatima = patient(api, FATIMA_QID)
    visit_id = reserved_visit(fatima)
    body = {"qid": FATIMA_QID, "complaint": "No chest pain, just a sore throat"}
    assert staff(api, DESK).post("/api/desk/walk-in", body).status_code == 409
    assert [row["state"] for row in live_tickets(visit_id)] == ["reserved"]


def test_a_second_desk_report_of_an_emergency_changes_nothing(api):
    fatima = patient(api, FATIMA_QID)
    desk = staff(api, DESK)
    visit_id = reserved_visit(fatima)
    desk.ok("/api/desk/walk-in", {"qid": FATIMA_QID, "complaint": DESK_WORDS})
    before = table_dump("ticket", "visit", "intake")
    again = desk.post("/api/desk/walk-in", {"qid": FATIMA_QID, "complaint": DESK_WORDS})
    assert again.status_code == 409
    assert again.json()["visit_id"] == visit_id
    assert table_dump("ticket", "visit", "intake") == before


def test_the_split_cue_never_reaches_the_model(api_env, monkeypatch):
    chat = FakeChatClient(["Do you have a fever?"])  # A second call would fail the test.
    with real_mode_api(monkeypatch, chat) as client:
        salem = patient(client, SALEM_QID)
        visit_id = open_visit(salem)
        first = tell(salem, visit_id, "my baby is sick")
        assert first["reply"] == "Do you have a fever?"
        assert first["ai_source"] == "model"
        answer = tell(salem, visit_id, "high")
        assert answer["emergency"] is True
        assert answer["ai_source"] != "model"
        assert_everything_is_refused(Scene(client, visit_id, salem, SALEM_QID, staff(client, NURSE)))
    assert len(chat.calls) == 1


def test_a_model_that_says_emergency_also_stops_the_ticket(api_env, monkeypatch):
    chat = FakeChatClient([model_intake(emergency=True)])
    with real_mode_api(monkeypatch, chat) as client:
        fatima = patient(client, FATIMA_QID)
        visit_id = open_visit(fatima)
        assert tell(fatima, visit_id, "I feel strange")["emergency"] is True
        scene = Scene(client, visit_id, fatima, FATIMA_QID, staff(client, NURSE))
        assert_everything_is_refused(scene)


def test_an_older_open_visit_cannot_walk_around_the_emergency(api):
    fatima = patient(api, FATIMA_QID)
    older = confirmed_visit(fatima)
    newer = open_visit(fatima)
    assert tell(fatima, newer, CHEST_PAIN)["emergency"]
    refused = reserve(fatima, older)
    assert refused.status_code == 409
    assert refused.json()["error"] == "emergency_today"
    assert all_tickets(older) == []


def test_a_dependent_stays_free_to_be_seen(api):
    """The rule follows the patient in the emergency, not whoever holds the phone."""
    fatima = patient(api, FATIMA_QID)
    assert tell(fatima, open_visit(fatima), CHEST_PAIN)["emergency"]
    mariam = arrived_visit(fatima, patient_id=MARIAM)
    assert live_tickets(mariam)[0]["state"] == "active"


def test_a_reservation_on_a_sibling_visit_never_becomes_a_ticket(api):
    """It never had a number or a place, and the red flag releases it on the spot."""
    fatima = patient(api, FATIMA_QID)
    nurse = staff(api, NURSE)
    sibling = open_visit(fatima)
    visit_id = reserved_visit(fatima)
    assert tell(fatima, sibling, CHEST_PAIN)["emergency"]

    for attempt in (arrive(fatima, visit_id), arrive(fatima, visit_id)):
        assert attempt.status_code == 409
        assert attempt.json()["error"] == "emergency_today"
    ticket = all_tickets(visit_id)[0]
    assert ticket["state"] == "released"
    assert ticket["number"] is None and ticket["seq"] is None
    assert nurse.ok(f"/api/counters/{T1}/call-next")["called"] is None


def test_a_red_flag_shows_on_the_reservation_of_its_sibling(api):
    fatima = patient(api, FATIMA_QID)
    sibling = open_visit(fatima)
    visit_id = reserved_visit(fatima)
    assert tell(fatima, sibling, RAVI_TEXT)["emergency"]

    state = fatima.read(f"/api/visits/{visit_id}")
    assert state["status"] == "redirected_emergency"
    assert state["ticket"] is None
    assert state["emergency"] is not None
    assert state["emergency"]["nearest_ed"] is not None


def test_a_red_flag_before_doha_midnight_still_counts_after_it(api, monkeypatch):
    """Past midnight the emergency is yesterday's, so only the release keeps the line."""
    clock = FakeClock(datetime(2026, 11, 6, 20, 40, tzinfo=timezone.utc))  # 23:40 in Doha.
    monkeypatch.setattr(timeutil, "utcnow", clock)
    api.app.state.engine.clock = timeutil.utcnow
    fatima = patient(api, FATIMA_QID)
    sibling = open_visit(fatima)
    clock.advance(minutes=5)
    visit_id = reserved_visit(fatima)  # 23:45
    clock.advance(minutes=5)
    assert tell(fatima, sibling, CHEST_PAIN)["emergency"]  # 23:50
    flagged_on = timeutil.doha_day(clock.now)
    clock.advance(minutes=15)
    assert timeutil.doha_day(clock.now) != flagged_on

    attempt = arrive(fatima, visit_id)  # 00:05

    assert attempt.status_code == 409, attempt.text
    assert live_of_patient(FATIMA) == []
    assert stored_visit(visit_id)["status"] == "redirected_emergency"
    ticket = all_tickets(visit_id)[0]
    assert ticket["number"] is None and ticket["seq"] is None


def before_midnight(api, monkeypatch):
    """Both clocks at 23:50 in Doha on 6 Nov, so event stamps and the day agree."""
    clock = FakeClock(datetime(2026, 11, 6, 20, 50, tzinfo=timezone.utc))
    monkeypatch.setattr(timeutil, "utcnow", clock)
    api.app.state.engine.clock = timeutil.utcnow
    return clock


def new_visit_attempt(person):
    return person.post("/api/visits", {"consent": True})


def desk_attempt(api, qid=FATIMA_QID):
    return staff(api, DESK).post(
        "/api/desk/walk-in", {"qid": qid, "complaint": "Sore throat for two days"}
    )


def assert_refused(attempt, error, visit_id):
    assert attempt.status_code == 409, attempt.text
    assert attempt.json()["error"] == error
    assert attempt.json()["visit_id"] == visit_id


def visits_of(patient_id):
    return rows("SELECT * FROM visit WHERE patient_id = ?", patient_id)


def flagged_after_midnight(person, clock):
    """Opened at 23:50 and flagged at 00:05. It is 00:06 on return."""
    visit_id = open_visit(person)
    clock.advance(minutes=15)
    assert tell(person, visit_id, CHEST_PAIN)["emergency"]
    clock.advance(minutes=1)
    return visit_id


def test_a_flag_after_midnight_blocks_a_new_visit(api, monkeypatch):
    clock = before_midnight(api, monkeypatch)
    fatima = patient(api, FATIMA_QID)
    flagged = flagged_after_midnight(fatima, clock)

    assert_refused(new_visit_attempt(fatima), "emergency_today", flagged)

    assert [row["id"] for row in visits_of(FATIMA)] == [flagged]
    assert live_of_patient(FATIMA) == []


def test_a_flag_after_midnight_blocks_an_older_open_sibling(api, monkeypatch):
    clock = before_midnight(api, monkeypatch)
    fatima = patient(api, FATIMA_QID)
    older = confirmed_visit(fatima)
    flagged = flagged_after_midnight(fatima, clock)

    assert_refused(reserve(fatima, older), "emergency_today", flagged)

    assert all_tickets(older) == []
    assert live_of_patient(FATIMA) == []


def test_a_flag_after_midnight_blocks_the_desk(api, monkeypatch):
    clock = before_midnight(api, monkeypatch)
    fatima = patient(api, FATIMA_QID)
    flagged = flagged_after_midnight(fatima, clock)

    assert_refused(desk_attempt(api), "active_visit", flagged)

    assert [row["id"] for row in visits_of(FATIMA)] == [flagged]
    assert all_tickets(flagged) == []
    assert live_of_patient(FATIMA) == []


def test_a_nurse_urgent_after_midnight_blocks_a_new_visit_and_the_desk(api, monkeypatch):
    clock = before_midnight(api, monkeypatch)
    fatima = patient(api, FATIMA_QID)
    nurse = staff(api, NURSE)
    visit_id = arrived_visit(fatima)
    clock.advance(minutes=15)
    assert to_counter(nurse, visit_id, {**VITALS, "urgency": "urgent"})["escalated"] is True
    clock.advance(minutes=1)

    assert_refused(new_visit_attempt(fatima), "emergency_today", visit_id)
    assert_refused(desk_attempt(api), "active_visit", visit_id)

    assert [row["id"] for row in visits_of(FATIMA)] == [visit_id]
    assert live_of_patient(FATIMA) == []


def test_a_flag_stops_counting_when_its_own_day_ends(api, monkeypatch):
    clock = before_midnight(api, monkeypatch)
    fatima = patient(api, FATIMA_QID)
    flagged = flagged_after_midnight(fatima, clock)
    clock.advance(minutes=23 * 60 + 53)  # 23:59 on the day of the flag.
    assert_refused(new_visit_attempt(fatima), "emergency_today", flagged)
    assert_refused(desk_attempt(api), "active_visit", flagged)
    clock.advance(minutes=2)  # 00:01 on the next day.

    # The override is a later row on that visit, and says nothing about when it happened.
    fatima.ok(f"/api/visits/{flagged}/emergency/override")

    assert new_visit_attempt(fatima).status_code == 200
    assert desk_attempt(api).status_code == 200
    assert stored_visit(flagged)["status"] == "redirected_emergency"


def test_a_flag_before_midnight_does_not_block_the_next_doha_day(api, monkeypatch):
    clock = before_midnight(api, monkeypatch)
    fatima = patient(api, FATIMA_QID)
    assert tell(fatima, open_visit(fatima), CHEST_PAIN)["emergency"]  # 23:50
    clock.advance(minutes=15)

    assert new_visit_attempt(fatima).status_code == 200
    assert desk_attempt(api).status_code == 200


def test_a_model_emergency_after_midnight_is_covered(api_env, monkeypatch):
    chat = FakeChatClient([model_intake(emergency=True)])
    with real_mode_api(monkeypatch, chat) as client:
        clock = before_midnight(client, monkeypatch)
        fatima = patient(client, FATIMA_QID)
        visit_id = open_visit(fatima)
        clock.advance(minutes=15)
        assert tell(fatima, visit_id, "I feel strange")["emergency"] is True
        clock.advance(minutes=1)
        types = event_types(visit_id)
        assert "ai.emergency" in types and "redflag.hit" not in types

        assert_refused(new_visit_attempt(fatima), "emergency_today", visit_id)
        assert_refused(desk_attempt(client), "active_visit", visit_id)
        assert live_of_patient(FATIMA) == []


def test_a_red_flag_on_a_lapsed_visit_releases_the_reservation_beside_it(api):
    fatima = patient(api, FATIMA_QID)
    clock = FakeClock(timeutil.utcnow())
    api.app.state.engine.clock = clock
    lapsed = reserved_visit(fatima)
    clock.advance(minutes=45)
    assert fatima.read(f"/api/visits/{lapsed}")["status"] == "expired"
    visit_id = reserved_visit(fatima)
    assert live_tickets(visit_id)[0]["state"] == "reserved"

    assert tell(fatima, lapsed, CHEST_PAIN)["emergency"]

    assert [row["state"] for row in all_tickets(visit_id)] == ["released"]
    assert live_of_patient(FATIMA) == []
    assert stored_visit(visit_id)["status"] == "redirected_emergency"
    refused = arrive(fatima, visit_id)
    assert refused.status_code == 409
    assert refused.json()["error"] == "emergency_today"


def test_a_guardians_red_flag_leaves_a_dependents_ticket_alone(api):
    fatima = patient(api, FATIMA_QID)
    mariam = reserved_visit(fatima, patient_id=MARIAM)
    assert tell(fatima, open_visit(fatima), CHEST_PAIN)["emergency"]
    assert [row["state"] for row in live_tickets(mariam)] == ["reserved"]
    assert stored_visit(mariam)["status"] == "reserved"


# Reordering


def waiting_ids(nurse):
    tickets = nurse.read(f"/api/counters/{T1}/queue")["tickets"]
    return [row["visit_id"] for row in tickets if row["state"] == "active" and not row["simulated"]]


def assert_order_comes_from_the_columns(nurse):
    shown = nurse.read(f"/api/counters/{T1}/queue")["tickets"]
    shown_ids = [row["ticket_id"] for row in shown if row["state"] == "active"]
    stored = rows("SELECT * FROM ticket WHERE counter_id = ? AND state = 'active'", T1)
    stored.sort(key=lambda row: row["seq"])
    stored.sort(key=lambda row: row["activated_at"])
    stored.sort(key=lambda row: row["priority"], reverse=True)
    assert shown_ids == [row["id"] for row in stored]


def test_a_model_reply_cannot_appear_in_the_queue_order(api_env, monkeypatch):
    pushy = model_intake(
        priority=9,
        position=1,
        queue_position=1,
        people_ahead=0,
        ticket="T-001",
        number="T-001",
        activated_at="2000-01-01T00:00:00.000000+00:00",
        seq=1,
    )
    chat = FakeChatClient(["You are number 1 in the queue, come straight in.", pushy])
    with real_mode_api(monkeypatch, chat) as client:
        nurse = staff(client, NURSE)
        desk = staff(client, DESK)
        first = desk.ok("/api/desk/walk-in", {"qid": SALEM_QID, "complaint": "Sore knee"})

        fatima = patient(client, FATIMA_QID)
        visit_id = open_visit(fatima)
        said = tell(fatima, visit_id, FATIMA_ANSWERS[0])
        assert "T-001" not in said["reply"]
        assert "number 1" not in said["reply"]
        assert said["ai_source"] != "model"
        assert tell(fatima, visit_id, FATIMA_ANSWERS[1])["done"]

        fatima.ok(f"/api/visits/{visit_id}/intake/confirm")
        assert reserve(fatima, visit_id).status_code == 200
        ticket = arrive(fatima, visit_id).json()["ticket"]

        assert ticket["number"] == "T-015"
        assert ticket["people_ahead"] == 4
        assert live_tickets(visit_id)[0]["priority"] == 0
        assert waiting_ids(nurse) == [first["visit_id"], visit_id]
        assert_order_comes_from_the_columns(nurse)


def test_a_remote_reservation_made_first_does_not_beat_an_earlier_arrival(api):
    fatima = patient(api, FATIMA_QID)
    salem = patient(api, SALEM_QID)
    nurse = staff(api, NURSE)
    from_home = reserved_visit(fatima)
    in_the_room = reserved_visit(salem, SALEM_ANSWERS)
    assert arrive(salem, in_the_room).json()["ticket"]["number"] == "T-014"
    assert waiting_ids(nurse) == [in_the_room]

    ticket = arrive(fatima, from_home).json()["ticket"]
    assert ticket["number"] == "T-015"
    assert ticket["people_ahead"] == 4
    assert waiting_ids(nurse) == [in_the_room, from_home]
    assert_order_comes_from_the_columns(nurse)
    assert nurse.ok(f"/api/counters/{T1}/call-next")["called"]["visit_id"] == in_the_room


def test_a_late_reservation_joins_the_end(api):
    fatima = patient(api, FATIMA_QID)
    salem = patient(api, SALEM_QID)
    nurse = staff(api, NURSE)
    clock = FakeClock(timeutil.utcnow())
    api.app.state.engine.clock = clock

    lapsed = reserved_visit(fatima)
    clock.advance(minutes=45)
    assert arrive(fatima, lapsed).status_code == 410

    clock.advance(minutes=1)
    arrived = arrived_visit(salem, SALEM_ANSWERS)
    clock.advance(minutes=1)
    desk = staff(api, DESK)
    walked_in = desk.ok("/api/desk/walk-in", {"qid": "DEMO-10002", "complaint": "Sore knee"})

    assert reserve(fatima, lapsed).status_code == 200
    clock.advance(minutes=1)
    ticket = arrive(fatima, lapsed).json()["ticket"]
    # Ahmed is 65+, so the centre rule moves him up. Nobody moves Fatima up.
    assert waiting_ids(nurse) == [walked_in["visit_id"], arrived, lapsed]
    assert ticket["people_ahead"] == 5
    assert ticket["number"] == "T-016"
    assert_order_comes_from_the_columns(nurse)


def test_priority_only_goes_to_the_centre_rule_and_order_breaks_ties_by_seq(api):
    """A frozen clock gives equal stamps, so seq is all that separates these two."""
    fatima = patient(api, FATIMA_QID)
    salem = patient(api, SALEM_QID)
    nurse = staff(api, NURSE)
    clock = FakeClock(timeutil.utcnow())
    api.app.state.engine.clock = clock

    young = arrived_visit(salem, SALEM_ANSWERS)
    other = arrived_visit(fatima, patient_id="P004")
    elder = arrived_visit(fatima, patient_id=MARIAM)

    assert live_tickets(young)[0]["priority"] == 0
    assert live_tickets(other)[0]["priority"] == 0
    assert live_tickets(elder)[0]["priority"] == 1
    assert live_tickets(young)[0]["activated_at"] == live_tickets(other)[0]["activated_at"]
    assert waiting_ids(nurse) == [elder, young, other]
    assert_order_comes_from_the_columns(nurse)


def test_fast_forward_refuses_if_someone_slipped_in_ahead(api, monkeypatch):
    """The check before any change can pass and a patient still arrive first, so the call
    itself is checked. Here the first check is told it found nobody."""
    fatima = patient(api, FATIMA_QID)
    salem = patient(api, SALEM_QID)
    nurse = staff(api, NURSE)
    first = arrived_visit(fatima)
    second = arrived_visit(salem, SALEM_ANSWERS)
    for visit_id in (first, second):
        to_counter(nurse, visit_id)
        hand_off(nurse, visit_id)
    monkeypatch.setattr(demo, "_blocked_here", lambda rows, visit_id: False)
    refused = nurse.post(f"/api/demo/fast-forward/{second}")
    assert refused.status_code == 409
    assert refused.json()["error"] == "not_next_in_queue"
    assert stored_visit(second)["status"] == "in_doctor"
    assert not event_types(second).count("demo.fast_forward")


# Everything the three journeys send back


def fatima_journey(api, log):
    nurse = staff(api, NURSE, log["staff"])
    doctor = staff(api, DOCTOR2, log["staff"])
    pharmacist = staff(api, PHARMACIST, log["staff"])
    fatima = patient(api, FATIMA_QID, log["patient"])
    fatima.read("/api/me")
    visit_id = reserved_visit(fatima)
    fatima.read("/api/visits")
    fatima.read("/api/centres?service=gp")
    fatima.read("/api/centres?service=emergency")
    fatima.read(f"/api/visits/{visit_id}")
    assert arrive(fatima, visit_id).status_code == 200
    fatima.read(f"/api/visits/{visit_id}")
    to_counter(nurse, visit_id)
    nurse.read(f"/api/counters/{T1}/queue")
    nurse.read(f"/api/staff/visits/{visit_id}")
    edit = {"chief_complaint": "EDITED-BY-NURSE", "summary_for_nurse": "NURSE-ONLY-SUMMARY"}
    assert nurse.put(f"/api/visits/{visit_id}/intake", {"json": edit}).status_code == 200
    fatima.read(f"/api/visits/{visit_id}")
    hand_off(nurse, visit_id)
    fatima.read(f"/api/visits/{visit_id}")
    see_doctor(doctor, visit_id)
    fatima.read(f"/api/visits/{visit_id}")
    dispense(pharmacist, visit_id)
    fatima.read(f"/api/visits/{visit_id}")
    nurse.read("/api/display/C-WAKRA")
    nurse.read("/api/stats/C-WAKRA")
    fatima.read("/api/visits")
    return visit_id


def ahmed_journey(api, log):
    ahmed = patient(api, AHMED_QID, log["patient"])
    ahmed.read("/api/me")
    visit_id = open_visit(ahmed)
    tell(ahmed, visit_id, AHMED_TEXT)
    ahmed.read(f"/api/visits/{visit_id}")
    assert reserve(ahmed, visit_id, "C-RAYYAN").status_code == 409
    ahmed.ok(f"/api/visits/{visit_id}/refill/continue")
    ahmed.read(f"/api/visits/{visit_id}")
    assert reserve(ahmed, visit_id, "C-RAYYAN").status_code == 200
    assert arrive(ahmed, visit_id).status_code == 200
    ahmed.read(f"/api/visits/{visit_id}")
    staff(api, RAYYAN_NURSE, log["staff"]).read("/api/counters/C-RAYYAN-T1/queue")


def ravi_journey(api, log):
    ravi = patient(api, RAVI_QID, log["patient"])
    ravi.read("/api/me")
    visit_id = open_visit(ravi)
    tell(ravi, visit_id, RAVI_TEXT)
    ravi.read(f"/api/visits/{visit_id}")
    assert reserve(ravi, visit_id, "C-AIRPORT").status_code == 409
    assert arrive(ravi, visit_id).status_code == 409
    ravi.ok(f"/api/visits/{visit_id}/emergency/override")
    ravi.read(f"/api/visits/{visit_id}")
    assert ravi.post("/api/visits", {"consent": True}).status_code == 409


@pytest.fixture
def journeys(api):
    """Every response of the three journeys, split by who received it."""
    log = {"patient": [], "staff": []}
    fatima_journey(api, log)
    ahmed_journey(api, log)
    ravi_journey(api, log)
    for path in ("/api/auth/demo-patients", "/api/staff/demo-staff", "/api/health"):
        log["staff"].append(api.get(path))
    return log


def test_the_journeys_really_cover_the_flow(journeys):
    paths = {response.request.url.path.split("V_")[-1] for response in journeys["patient"]}
    for ending in ("/chat", "/intake/confirm", "/reserve", "/arrive", "/refill/continue"):
        assert any(path.endswith(ending) for path in paths), ending
    assert any(path.endswith("/emergency/override") for path in paths)
    assert len(journeys["patient"]) >= 30


PATIENT_NEVER_GETS = {"summary_for_nurse", "turns", "patient_words", "denied_text", "edited"}


def test_no_patient_response_holds_a_staff_field(journeys):
    for response in journeys["patient"]:
        body = response.json()
        assert not keys_in(body) & PATIENT_NEVER_GETS, response.request.url
        said = "\n".join(strings_in(body))
        assert "NURSE-ONLY-SUMMARY" not in said, response.request.url
        assert "EDITED-BY-NURSE" not in said, response.request.url


def test_the_chat_route_keeps_the_model_prose_from_the_patient(api_env, monkeypatch):
    prose = "PROSE-FOR-THE-NURSE only."
    chat = FakeChatClient([model_intake(summary_for_nurse=prose, chief_complaint="PROSE-WORD")])
    log = []
    with real_mode_api(monkeypatch, chat) as client:
        fatima = patient(client, FATIMA_QID, log)
        nurse = staff(client, NURSE)
        visit_id = open_visit(fatima)
        said = tell(fatima, visit_id, FATIMA_ANSWERS[0])
        assert said["done"] is True
        fatima.ok(f"/api/visits/{visit_id}/intake/confirm")
        reserve(fatima, visit_id)
        arrive(fatima, visit_id)
        fatima.read(f"/api/visits/{visit_id}")
        nurse.ok(f"/api/counters/{T1}/call-next")
        card = nurse.read(f"/api/staff/visits/{visit_id}")
    assert prose in card["intake"]["summary_for_nurse"]
    for response in log:
        assert "PROSE" not in response.text


def another_patients_visit(api):
    """A confirmed visit of Fatima's, plus Ravi's token."""
    fatima = patient(api, FATIMA_QID)
    return confirmed_visit(fatima), patient(api, RAVI_QID)


@pytest.mark.parametrize(
    ("method", "ending", "body"),
    [
        ("get", "", None),
        ("post", "/chat", {"text": "hello"}),
        ("post", "/intake/confirm", None),
        ("post", "/refill/continue", None),
        ("post", "/emergency/override", None),
        ("post", "/reserve", {"centre_id": "C-WAKRA"}),
        ("post", "/arrive", {"button": True}),
    ],
    ids=["get", "chat", "confirm", "refill", "override", "reserve", "arrive"],
)
def test_another_patient_gets_403(api, method, ending, body):
    visit_id, ravi = another_patients_visit(api)
    before = table_dump("ticket", "visit", "intake")
    path = f"/api/visits/{visit_id}{ending}"
    response = ravi.get(path) if method == "get" else ravi.post(path, body)
    assert response.status_code == 403
    assert response.json()["error"] == "forbidden"
    assert table_dump("ticket", "visit", "intake") == before


def test_another_patient_gets_403_on_the_stream(api):
    visit_id, ravi = another_patients_visit(api)
    assert api.get(f"/api/visits/{visit_id}/stream?token={ravi.token}").status_code == 403
    assert api.get(f"/api/visits/{visit_id}/stream", headers=ravi.headers).status_code == 403


def test_another_patient_cannot_read_the_map_of_a_visit(api):
    visit_id, ravi = another_patients_visit(api)
    assert ravi.get(f"/api/centres?visit_id={visit_id}").status_code == 403


# Who may call what, from the live route table


PUBLIC_ROUTES = {
    ("GET", "/api/health"),
    ("POST", "/api/auth/start"),
    ("POST", "/api/auth/verify"),
    ("GET", "/api/auth/demo-patients"),
    ("POST", "/api/staff/login"),
    ("GET", "/api/staff/demo-staff"),
}
PATIENT_ROUTES = {
    ("GET", "/api/me"),
    ("POST", "/api/visits"),
    ("GET", "/api/visits"),
    ("GET", "/api/visits/{visit_id}"),
    ("GET", "/api/visits/{visit_id}/stream"),
    ("POST", "/api/visits/{visit_id}/chat"),
    ("POST", "/api/asr"),
    ("POST", "/api/visits/{visit_id}/intake/confirm"),
    ("POST", "/api/visits/{visit_id}/refill/continue"),
    ("POST", "/api/visits/{visit_id}/emergency/override"),
    ("GET", "/api/centres"),
    ("POST", "/api/visits/{visit_id}/reserve"),
    ("POST", "/api/visits/{visit_id}/arrive"),
    ("POST", "/api/visits/{visit_id}/rating"),
}


def api_routes():
    return {
        (method, route.path)
        for route in flat_routes()
        if route.path.startswith("/api")
        for method in route.methods - {"HEAD", "OPTIONS"}
    }


def route_ids(routes):
    return [f"{method} {path}" for method, path in routes]


STAFF_ROUTES = sorted(api_routes() - PUBLIC_ROUTES - PATIENT_ROUTES)
ALL_GUARDED_ROUTES = [*STAFF_ROUTES, *sorted(PATIENT_ROUTES)]
PLAIN_PATIENT_ROUTES = sorted(route for route in PATIENT_ROUTES if "stream" not in route[1])


def filled(path):
    values = {
        "visit_id": "V_nope",
        "counter_id": T1,
        "ticket_id": "tkt_nope",
        "centre_id": "C-WAKRA",
    }
    return re.sub(r"\{(\w+)\}", lambda match: values[match.group(1)], path)


def test_the_route_table_is_fully_classified():
    published = {
        (method.upper(), path)
        for path, operations in app.openapi()["paths"].items()
        for method in operations
    }
    assert api_routes() == published  # So the unwrapping above misses nothing.
    assert PATIENT_ROUTES <= api_routes()
    assert PUBLIC_ROUTES <= api_routes()
    staff_paths = {path for _, path in STAFF_ROUTES}
    for prefix in ("/api/staff/visits", "/api/counters", "/api/tickets", "/api/desk"):
        assert any(path.startswith(prefix) for path in staff_paths), prefix
    for prefix in ("/api/display", "/api/stats", "/api/demo"):
        assert any(path.startswith(prefix) for path in staff_paths), prefix
    assert ("PUT", "/api/visits/{visit_id}/intake") in STAFF_ROUTES
    assert ("POST", "/api/visits/{visit_id}/dispensed") in STAFF_ROUTES
    assert len(STAFF_ROUTES) == 20


@pytest.mark.parametrize(("method", "path"), STAFF_ROUTES, ids=route_ids(STAFF_ROUTES))
def test_a_patient_token_gets_403_on_every_staff_route(api, method, path):
    fatima = patient(api, FATIMA_QID)
    response = api.request(method, filled(path), headers=fatima.headers)
    assert response.status_code == 403
    assert response.json()["error"] == "forbidden"
    if path.endswith("/stream"):
        token = fatima.token
        assert api.get(filled(path), params={"token": token}).status_code == 403


@pytest.mark.parametrize(("method", "path"), ALL_GUARDED_ROUTES, ids=route_ids(ALL_GUARDED_ROUTES))
def test_no_token_gets_401(api, method, path):
    response = api.request(method, filled(path))
    assert response.status_code == 401
    assert response.json()["error"] == "unauthorized"


@pytest.mark.parametrize(
    ("method", "path"), PLAIN_PATIENT_ROUTES, ids=route_ids(PLAIN_PATIENT_ROUTES)
)
def test_a_staff_token_gets_403_on_every_patient_route(api, method, path):
    nurse = staff(api, NURSE)
    response = api.request(method, filled(path), headers=nurse.headers)
    assert response.status_code == 403


# Wording


BANNED_WORDING = re.compile(
    r"place held|held for|hold your place|nobody skips|no one skips|anyone skips"
    r"|skips? (?:anyone|the queue)|no[- ]?shows?\b|مكانك محجوز|محجوز لك|لن يتخطى|ما أحد يتخطى",
    re.IGNORECASE,
)


def test_no_response_makes_a_banned_claim(journeys):
    responses = [*journeys["patient"], *journeys["staff"]]
    assert len(responses) >= 50
    for response in responses:
        for text in strings_in(response.json()):
            assert not BANNED_WORDING.search(text), (response.request.url, text)
        for key in keys_in(response.json()):
            assert not BANNED_WORDING.search(key.replace("_", "-")), (response.request.url, key)


def test_the_filter_above_would_catch_the_wording():
    for claim in ("Your place held for 45", "place held", "Nobody skips anyone", "no-show rate"):
        assert BANNED_WORDING.search(claim)
    assert not BANNED_WORDING.search("Check-in valid for 45 minutes")


# No real data


QID = re.compile(r"^DEMO-\d{5}$")
# Real QIDs are 11 digits, so one standing alone is a leak whatever its key. A run of
# digits inside a random hex id such as tkt_672037741123 is not one.
LOOKS_LIKE_A_QID = re.compile(r"(?<![\w-])\d{11}(?![\w-])")


def test_the_qid_check_sees_a_real_shape_and_passes_our_ids():
    assert LOOKS_LIKE_A_QID.search("QID 28763400123.")
    assert LOOKS_LIKE_A_QID.search("28763400123")
    assert not LOOKS_LIKE_A_QID.search("tkt_672037741123")
    assert not LOOKS_LIKE_A_QID.search("V_a67203774112")
    assert not LOOKS_LIKE_A_QID.search("2026-11-06T10:06:07.475762+00:00")


def test_every_qid_is_a_demo_qid(journeys):
    found = set()
    for response in [*journeys["patient"], *journeys["staff"]]:
        body = response.json()
        for key, value in walk(body):
            if key is not None and "qid" in key.lower():
                assert isinstance(value, str) and QID.fullmatch(value), (key, value)
                found.add(value)
        for text in strings_in(body):
            assert not LOOKS_LIKE_A_QID.search(text), text
    assert {FATIMA_QID, AHMED_QID, RAVI_QID} <= found
