"""What the staff consoles read: the session route, raised flags and the Arabic draft."""

from __future__ import annotations

import pytest

from backend import visit_flow
from backend.ai import handoff
from backend.tests import standin_server
from backend.tests.ai_fakes import FakeChatClient
from backend.tests.api_helpers import (
    AHMED_QID,
    AHMED_TEXT,
    DESK,
    DOCTOR2,
    FATIMA_ANSWERS,
    FATIMA_QID,
    NURSE,
    PHARMACIST,
    bearer,
    patient_token,
    staff_token,
)
from backend.tests.test_api_clinical import DENIED_ANSWERS, confirm, detail, draft
from backend.tests.test_api_e2e import (
    GATE_PASSING_REPLY,
    arrive,
    arrived_visit,
    model_intake,
    open_visit,
    patient,
    real_mode_api,
    reserve,
    staff,
    tell,
)
from backend.tests.test_api_staff import (
    FATIMA,
    OTHER_NURSE,
    P1,
    T1,
    Staff,
    arrived,
    at_vitals,
    chat,
    doctor,  # noqa: F401
    event_types,
    execute,
    new_visit,
    nurse,  # noqa: F401
    rows,
)

ME = "/api/staff/me"
QUESTION = GATE_PASSING_REPLY
DOWN = TimeoutError("down")
# The script reads an answer by the question before it, so these let it finish on the last turn.
THREE_QUESTIONS = ("كم شدتها من 0 إلى 10؟", "هل أخذت أي دواء؟", "هل عندك شي ثاني؟")
SCRIPTED_INTAKE = (*THREE_QUESTIONS, DOWN)


def me(api, staff_id):
    response = api.get(ME, headers=bearer(staff_token(api, staff_id)))
    assert response.status_code == 200, response.text
    return response.json()


def test_me_returns_exactly_the_shape_the_session_reads(api):
    body = me(api, NURSE)
    assert set(body) == {"staff", "centre", "counters", "centre_counters"}
    assert body["staff"] == {
        "id": NURSE,
        "name": "Amal Al-Demo",
        "role": "nurse",
        "clinic": None,
        "centre_id": "C-WAKRA",
    }
    assert body["centre"] == {
        "id": "C-WAKRA",
        "name_en": "Al Wakra Health Centre",
        "name_ar": "مركز الوكرة الصحي",
    }
    assert body["counters"] == [
        {"id": T1, "label": "Triage 1", "label_ar": "الفرز 1", "stage": "triage", "prefix": "T"}
    ]


def test_me_lists_every_counter_of_the_centre_and_only_that_centre(api):
    centre = me(api, NURSE)["centre_counters"]
    assert [counter["id"] for counter in centre] == [
        "C-WAKRA-D3",
        "C-WAKRA-D4",
        "C-WAKRA-DEN1",
        "C-WAKRA-P1",
        "C-WAKRA-T1",
        "C-WAKRA-WH1",
    ]
    assert all(set(counter) == {"id", "label", "label_ar", "stage"} for counter in centre)

    other = me(api, OTHER_NURSE)
    assert other["centre"]["id"] == "C-RAYYAN"
    assert all(counter["id"].startswith("C-RAYYAN") for counter in other["centre_counters"])


@pytest.mark.parametrize(
    ("staff_id", "own"),
    [(DOCTOR2, ["C-WAKRA-D4"]), (PHARMACIST, [P1]), (DESK, [])],
)
def test_me_lists_own_counters_for_every_role(api, staff_id, own):
    assert [counter["id"] for counter in me(api, staff_id)["counters"]] == own


def test_me_needs_a_session(api):
    response = api.get(ME)
    assert response.status_code == 401
    assert response.json()["error"] == "unauthorized"


def test_me_refuses_a_patient(api):
    response = api.get(ME, headers=bearer(patient_token(api, FATIMA_QID)))
    assert response.status_code == 403


def test_the_staff_visit_lists_raised_flags_as_labels(api, nurse):  # noqa: F811
    visit_id = new_visit(FATIMA)
    chat(api, visit_id, "Chest pain going to my left arm.")
    execute("UPDATE visit SET centre_id = 'C-WAKRA' WHERE id = ?", visit_id)

    body = detail(nurse, visit_id)

    assert body["red_flags_raised"]
    assert all(isinstance(label, str) for label in body["red_flags_raised"])
    assert body["red_flags_checked"] == "Red flag raised: " + ", ".join(body["red_flags_raised"])


def test_raised_flags_come_in_arabic_beside_the_english(api, nurse):  # noqa: F811
    visit_id = new_visit(FATIMA)
    chat(api, visit_id, "Chest pain going to my left arm.")
    execute("UPDATE visit SET centre_id = 'C-WAKRA' WHERE id = ?", visit_id)

    body = detail(nurse, visit_id)

    assert "chest pain" in body["red_flags_raised"]
    arabic = body["red_flags_raised_ar"]
    assert len(arabic) == len(body["red_flags_raised"])
    assert "ألم في الصدر" in arabic
    assert not any(letter.isascii() and letter.isalpha() for label in arabic for letter in label)


def test_the_staff_visit_has_an_empty_list_when_nothing_was_raised(api, nurse):  # noqa: F811
    body = detail(nurse, arrived(api))
    assert body["red_flags_raised"] == []
    assert body["red_flags_raised_ar"] == []
    assert body["red_flags_checked"] == "none detected"


def test_a_denied_cue_is_not_a_raised_flag(api, nurse):  # noqa: F811
    body = detail(nurse, arrived(api, answers=DENIED_ANSWERS))
    assert body["red_flags_raised"] == []
    assert body["red_flags_checked"] == "Patient denied: chest pain"


def test_the_staff_visit_says_when_the_patient_arrived(api, nurse):  # noqa: F811
    assert detail(nurse, arrived(api))["arrived_at"] is not None


def test_the_staff_visit_refuses_another_centre(api):
    visit_id = arrived(api)
    other = bearer(staff_token(api, OTHER_NURSE))
    response = api.get(f"/api/staff/visits/{visit_id}", headers=other)
    assert response.status_code == 403
    assert response.json()["error"] == "wrong_centre"


def test_the_staff_visit_needs_a_session_and_refuses_a_patient(api):
    path = f"/api/staff/visits/{arrived(api)}"
    assert api.get(path).status_code == 401
    assert api.get(path, headers=bearer(patient_token(api, FATIMA_QID))).status_code == 403


def test_the_draft_offers_the_arabic_template_beside_the_english(api, nurse):  # noqa: F811
    visit_id = at_vitals(nurse, api)

    body = draft(nurse, visit_id)

    assert set(body) == {"text", "text_ar", "source", "suggestions", "denied_text", "draft_id"}
    assert body["source"] == "simulated"
    assert body["text_ar"] != body["text"]
    assert any("؀" <= letter <= "ۿ" for letter in body["text_ar"])
    assert len(body["text_ar"].splitlines()) == len(body["text"].splitlines())


def test_the_arabic_draft_is_never_stored(api, nurse):  # noqa: F811
    visit_id = at_vitals(nurse, api)

    body = draft(nurse, visit_id)

    stored = detail(nurse, visit_id)["handoff"]
    assert stored["ai_draft"] == body["text"]
    assert stored["final_text"] is None


def test_the_draft_keeps_its_guards(api):
    path = f"/api/visits/{at_vitals(Staff(api, NURSE), api)}/handoff/draft"
    assert api.post(path).status_code == 401
    assert api.post(path, headers=bearer(patient_token(api, FATIMA_QID))).status_code == 403
    pharmacist = bearer(staff_token(api, PHARMACIST))
    assert api.post(path, headers=pharmacist).status_code == 403
    other = bearer(staff_token(api, OTHER_NURSE))
    response = api.post(path, headers=other)
    assert (response.status_code, response.json()["error"]) == (403, "wrong_centre")


# The allergy warning in Arabic


def test_the_arabic_warning_names_the_allergen_in_arabic(api, nurse, doctor):  # noqa: F811
    visit_id = at_vitals(nurse, api)
    nurse.ok(
        f"/api/visits/{visit_id}/handoff/confirm",
        {"final_text": draft(nurse, visit_id)["text"], "doctor_id": DOCTOR2},
    )
    drugs = {row["id"]: row for row in doctor.get(f"/api/staff/visits/{visit_id}/drugs").json()}

    warning = drugs["DR-AMOX"]["allergy_warning"]

    assert warning["text_ar"] == "حساسية مسجلة: البنسلين. راجع قبل وصف أموكسيسيلين."
    assert "penicillin" not in warning["text_ar"]
    assert warning["allergen"] == "penicillin"
    assert warning["text_en"] == "Allergy on record: penicillin. Check before prescribing amoxicillin."


@pytest.mark.parametrize("stored", ["penicillin", "Penicillin", " PENICILLIN "])
def test_the_arabic_allergen_ignores_how_the_record_wrote_it(stored):
    conflict = visit_flow.allergy_conflict(
        {"allergies": [stored]}, {"name_en": "Amoxicillin", "name_ar": "أموكسيسيلين",
                                  "allergy_tags": ["penicillin"]}
    )
    assert conflict["text_ar"].startswith("حساسية مسجلة: البنسلين.")
    assert conflict["allergen"] == stored


def test_an_unknown_allergen_stays_as_stored_and_is_never_guessed():
    conflict = visit_flow.allergy_conflict(
        {"allergies": ["sulfa"]}, {"name_en": "Co-trimoxazole", "name_ar": "كو-تريموكسازول",
                                   "allergy_tags": ["sulfa"]}
    )
    assert conflict["text_ar"] == "حساسية مسجلة: sulfa. راجع قبل وصف كو-تريموكسازول."


# Two nurse tabs on one visit


def test_the_draft_id_names_the_stored_draft(api, nurse):  # noqa: F811
    visit_id = at_vitals(nurse, api)
    body = draft(nurse, visit_id)
    assert body["draft_id"] == handoff.draft_id(detail(nurse, visit_id)["handoff"]["ai_draft"])
    assert body["draft_id"] != handoff.draft_id(body["text"] + " Changed.")
    assert draft(nurse, visit_id)["draft_id"] == body["draft_id"]


def test_an_older_draft_cannot_be_confirmed_after_another_tab_redrafted(api, nurse):  # noqa: F811
    visit_id = at_vitals(nurse, api)
    tab_a = draft(nurse, visit_id)

    edit = nurse.put(f"/api/visits/{visit_id}/intake", {"json": {"severity_0_10": 9}})
    assert edit.status_code == 200, edit.text
    tab_b = draft(nurse, visit_id)
    assert tab_b["draft_id"] != tab_a["draft_id"]

    stale = nurse.post(
        f"/api/visits/{visit_id}/handoff/confirm",
        {"final_text": tab_a["text"], "doctor_id": DOCTOR2, "draft_id": tab_a["draft_id"]},
    )

    assert (stale.status_code, stale.json()["error"]) == (409, "draft_stale")
    after = detail(nurse, visit_id)
    assert after["status"] == "in_triage"
    assert after["handoff"]["final_text"] is None
    assert after["handoff"]["confirmed_by"] is None

    current = nurse.post(
        f"/api/visits/{visit_id}/handoff/confirm",
        {"final_text": tab_b["text"], "doctor_id": DOCTOR2, "draft_id": tab_b["draft_id"]},
    )
    assert current.status_code == 200, current.text


def test_the_draft_id_stays_optional_for_a_caller_that_sends_none(api, nurse):  # noqa: F811
    visit_id = at_vitals(nurse, api)
    draft(nurse, visit_id)
    assert confirm(nurse, visit_id).status_code == 200


def test_a_missing_draft_is_still_draft_required_with_a_draft_id(api, nurse):  # noqa: F811
    visit_id = at_vitals(nurse, api)
    response = nurse.post(
        f"/api/visits/{visit_id}/handoff/confirm",
        {"final_text": "Text.", "doctor_id": DOCTOR2, "draft_id": "abc"},
    )
    assert (response.status_code, response.json()["error"]) == (409, "draft_required")


# What wrote the intake, which T03 names


def sources(visit_id):
    found = rows(
        "SELECT json_extract(payload, '$.source') AS source FROM event "
        "WHERE visit_id = ? AND type = 'ai.intake_ready' ORDER BY id",
        visit_id,
    )
    return [row["source"] for row in found]


def test_the_staff_visit_returns_exactly_the_keys_the_consoles_read(api, nurse):  # noqa: F811
    assert set(detail(nurse, arrived(api))) == {
        "status",
        "language",
        "turns",
        "patient_words",
        "denied",
        "denied_text",
        "denied_text_en",
        "denied_text_ar",
        "intake",
        "confirmed_by_patient",
        "edited",
        "red_flags_checked",
        "red_flags_raised",
        "red_flags_raised_ar",
        "arrived_at",
        "patient",
        "vitals",
        "handoff",
        "prescription",
        "medicines",
        "ticket",
        "service",
        "ai_mode",
        "intake_source",
    }


def test_all_model_turns_read_as_the_model_in_real_mode(api_env, monkeypatch):
    chat_client = FakeChatClient([QUESTION, model_intake()])
    with real_mode_api(monkeypatch, chat_client) as client:
        visit_id = arrived_visit(patient(client, FATIMA_QID), FATIMA_ANSWERS[:2])
        body = detail(staff(client, NURSE), visit_id)

    assert body["ai_mode"] == "real"
    assert body["intake_source"] == "model"
    assert sources(visit_id) == ["model"]
    assert "ai.fallback" not in event_types(visit_id)


@pytest.mark.parametrize(
    "replies",
    [SCRIPTED_INTAKE, (DOWN, DOWN, DOWN, DOWN), (*THREE_QUESTIONS, "{bad", "{bad")],
    ids=["failed-on-the-last-turn", "failed-on-every-turn", "two-invalid-json"],
)
def test_a_model_failure_on_the_turn_that_built_the_intake_reads_as_scripted(
    api_env, monkeypatch, replies
):
    with real_mode_api(monkeypatch, FakeChatClient(list(replies))) as client:
        visit_id = arrived_visit(patient(client, FATIMA_QID))
        body = detail(staff(client, NURSE), visit_id)

    assert body["ai_mode"] == "real"
    assert body["intake_source"] == "simulated"
    assert sources(visit_id) == ["simulated"]
    assert "ai.fallback" in event_types(visit_id)


def test_a_fallback_on_an_earlier_turn_leaves_the_model_as_the_author(api_env, monkeypatch):
    chat_client = FakeChatClient([QUESTION, DOWN, model_intake()])
    with real_mode_api(monkeypatch, chat_client) as client:
        visit_id = arrived_visit(patient(client, FATIMA_QID), FATIMA_ANSWERS[:3])
        body = detail(staff(client, NURSE), visit_id)

    assert body["intake_source"] == "model"
    assert "ai.fallback" in event_types(visit_id)


@pytest.mark.parametrize(
    ("last_reply", "expected"),
    [(model_intake(), ["simulated", "model"]), (DOWN, ["model", "simulated"])],
    ids=["model-after-script", "script-after-model"],
)
def test_the_latest_intake_decides(api_env, monkeypatch, last_reply, expected):
    first = DOWN if expected[0] == "simulated" else model_intake()
    chat_client = FakeChatClient([*THREE_QUESTIONS, first, last_reply])
    answers = (*FATIMA_ANSWERS, "لا، الشدة ٧")
    with real_mode_api(monkeypatch, chat_client) as client:
        visit_id = arrived_visit(patient(client, FATIMA_QID), answers)
        body = detail(staff(client, NURSE), visit_id)

    assert sources(visit_id) == expected
    assert body["intake_source"] == expected[-1]


def test_a_walk_in_reads_as_scripted_in_real_mode(api_env, monkeypatch):
    chat_client = FakeChatClient([])
    with real_mode_api(monkeypatch, chat_client) as client:
        desk = staff(client, DESK)
        visit_id = desk.ok(
            "/api/desk/walk-in", {"qid": "DEMO-10006", "complaint": "Sore throat and a mild cough"}
        )["visit_id"]
        body = detail(staff(client, NURSE), visit_id)

    assert body["ai_mode"] == "real"
    assert body["intake"]["chief_complaint"] == "Sore throat and a mild cough"
    assert sources(visit_id) == []
    assert body["intake_source"] == "simulated"
    assert chat_client.calls == []


def test_still_wanting_a_visit_replaces_a_model_intake_with_the_template(api_env, monkeypatch):
    chat_client = FakeChatClient([model_intake()])
    with real_mode_api(monkeypatch, chat_client) as client:
        ahmed = patient(client, AHMED_QID)
        visit_id = open_visit(ahmed)
        assert tell(ahmed, visit_id, "I have a question for the nurse")["done"]
        assert tell(ahmed, visit_id, AHMED_TEXT)["refill"]
        ahmed.ok(f"/api/visits/{visit_id}/refill/continue")
        assert reserve(ahmed, visit_id).status_code == 200
        assert arrive(ahmed, visit_id).status_code == 200
        body = detail(staff(client, NURSE), visit_id)

    assert sources(visit_id) == ["model"]
    assert body["intake_source"] == "simulated"


@pytest.mark.parametrize(
    ("replies", "answers", "source"),
    [
        ((QUESTION, model_intake()), FATIMA_ANSWERS[:2], "model"),
        (SCRIPTED_INTAKE, FATIMA_ANSWERS, "simulated"),
    ],
    ids=["model", "scripted"],
)
def test_a_nurse_edit_does_not_change_the_source(api_env, monkeypatch, replies, answers, source):
    with real_mode_api(monkeypatch, FakeChatClient(list(replies))) as client:
        visit_id = arrived_visit(patient(client, FATIMA_QID), answers)
        amal = staff(client, NURSE)
        amal.ok(f"/api/counters/{T1}/call-next")
        edit = amal.put(
            f"/api/visits/{visit_id}/intake", {"json": {"summary_for_nurse": "Seen at triage."}}
        )
        assert edit.status_code == 200, edit.text
        body = detail(amal, visit_id)

    assert body["edited"] is True
    assert body["intake"]["summary_for_nurse"] == "Seen at triage."
    assert body["intake_source"] == source


def test_simulated_mode_and_an_unfinished_chat_read_as_scripted(api, nurse):  # noqa: F811
    assert detail(nurse, arrived(api))["intake_source"] == "simulated"

    unfinished = new_visit(FATIMA)
    chat(api, unfinished, FATIMA_ANSWERS[0])
    execute("UPDATE visit SET centre_id = 'C-WAKRA' WHERE id = ?", unfinished)
    assert sources(unfinished) == []
    assert detail(nurse, unfinished)["intake_source"] == "simulated"


@pytest.mark.parametrize(
    ("last_answer", "fallbacks", "source"),
    [("لا", 0, "model"), (f"لا {standin_server.MODEL_DOWN}", 1, "simulated")],
    ids=["no-marker", "marker"],
)
def test_the_stand_in_fails_only_on_its_marker(api_env, monkeypatch, last_answer, fallbacks, source):
    answers = (standin_server.TRANSCRIPT, "5", "لا", last_answer)
    with real_mode_api(monkeypatch, standin_server.StandInChat()) as client:
        visit_id = arrived_visit(patient(client, FATIMA_QID), answers)
        body = detail(staff(client, NURSE), visit_id)

    assert body["intake_source"] == source
    assert event_types(visit_id).count("ai.fallback") == fallbacks


def test_the_a1_sentence_never_holds_the_stand_in_marker():
    assert standin_server.MODEL_DOWN not in standin_server.TRANSCRIPT
