from __future__ import annotations

import json
from datetime import date
from pathlib import Path

import pytest

from backend import db
from backend.adapters.queue_base import VisitHasLiveTicket, VisitNotEligible
from backend.ai import filters, receptionist, session, simulated
from backend.ai.asr import Asr
from backend.ai.llm import Llm
from backend.ai.runtime import AiRuntime
from backend.ai.session import SessionError
from backend.tests.ai_fakes import FakeChatClient
from backend.tests.conftest import make_visit

ASR = Asr(mode="simulated", model_id="simulated")
SIM = AiRuntime(llm=Llm(mode="simulated", model_id="simulated"), asr=ASR)


def real(client):
    return AiRuntime(llm=Llm(mode="real", model_id="test", client=client), asr=ASR)


def intake_json(**changes):
    base = {
        "language": "en",
        "chief_complaint": "cough",
        "chief_complaint_patient_words": "x",
        "service": "gp",
        "service_confidence": 0.9,
        "summary_for_nurse": "34F, cough.",
        "questions_asked": 1,
    }
    return json.dumps({**base, **changes})


def visit_status(conn, visit_id):
    return conn.execute("SELECT status FROM visit WHERE id = ?", (visit_id,)).fetchone()[0]


def visit_service(conn, visit_id):
    return conn.execute("SELECT service FROM visit WHERE id = ?", (visit_id,)).fetchone()[0]


def transcript(conn, visit_id):
    row = conn.execute("SELECT transcript FROM intake WHERE visit_id = ?", (visit_id,)).fetchone()
    return json.loads(row[0])


def stored_json(conn, visit_id):
    return conn.execute("SELECT json FROM intake WHERE visit_id = ?", (visit_id,)).fetchone()[0]


def events(conn, visit_id):
    rows = conn.execute(
        "SELECT type, payload FROM event WHERE visit_id = ? ORDER BY id", (visit_id,)
    ).fetchall()
    return [(row["type"], json.loads(row["payload"])) for row in rows]


def event_types(conn, visit_id):
    return [name for name, _ in events(conn, visit_id)]


def test_first_message_creates_the_row_with_empty_json(seeded):
    visit_id = make_visit(seeded, "P001")
    session.handle_message(seeded, SIM, visit_id, "عندي حرارة وكحة من ثلاث أيام")
    assert stored_json(seeded, visit_id) == "{}"
    state = transcript(seeded, visit_id)
    assert set(state) == {"messages", "denied", "language", "last_turn"}
    assert state["language"] == "ar"
    assert [m["role"] for m in state["messages"]] == ["assistant", "user", "assistant"]
    assert state["messages"][0]["content"] == simulated.OPENING["ar"]
    assert state["messages"][2]["slot"] == "severity"


def test_language_starts_from_the_patient_preference(seeded):
    visit_id = make_visit(seeded, "P003")
    assert session.history(seeded, visit_id)["language"] == "en"
    assert session.history(seeded, visit_id)["messages"][0]["content"] == simulated.OPENING["en"]


def test_history_writes_nothing(seeded):
    visit_id = make_visit(seeded, "P001")
    assert session.history(seeded, visit_id)["messages"][0]["content"] == simulated.OPENING["ar"]
    assert seeded.execute("SELECT COUNT(*) FROM intake").fetchone()[0] == 0


def test_history_returns_the_conversation_and_the_intake(seeded):
    visit_id = make_visit(seeded, "P003")
    for text in ("I have a rash for 2 days", "5", "no", "no", "no"):
        result = session.handle_message(seeded, SIM, visit_id, text)
    assert result.done
    view = session.history(seeded, visit_id)
    assert view["status"] == "intake"
    assert view["intake"] == receptionist.patient_intake(result.intake)
    assert "summary_for_nurse" not in view["intake"]
    assert json.loads(stored_json(seeded, visit_id)) == result.intake
    assert view["last_turn"]["done"] is True


def test_history_of_an_unknown_visit(seeded):
    with pytest.raises(SessionError) as error:
        session.history(seeded, "V_nope")
    assert error.value.code == "visit_not_found"


def test_unknown_visit(seeded):
    with pytest.raises(SessionError) as error:
        session.handle_message(seeded, SIM, "V_nope", "hello")
    assert error.value.code == "visit_not_found"


@pytest.mark.parametrize("text", ["", "   ", "\n\t", "x" * 2001, None])
def test_invalid_text(seeded, text):
    visit_id = make_visit(seeded, "P001")
    with pytest.raises(SessionError) as error:
        session.handle_message(seeded, SIM, visit_id, text)
    assert error.value.code == "invalid_text"


def test_two_thousand_chars_is_accepted(seeded):
    visit_id = make_visit(seeded, "P001")
    assert session.handle_message(seeded, SIM, visit_id, "x" * 2000).slot == "duration"


@pytest.mark.parametrize("status", ["reserved", "completed", "deflected_refill", "cancelled"])
def test_only_intake_visits_chat(seeded, status):
    visit_id = make_visit(seeded, "P001", status=status)
    with pytest.raises(SessionError) as error:
        session.handle_message(seeded, SIM, visit_id, "hello there")
    assert error.value.code == "visit_not_in_intake"


def test_the_intake_is_stored_on_done_and_sets_the_service(seeded):
    visit_id = make_visit(seeded, "P001")
    for text in ("my tooth hurts from two days", "5", "no", "no", "no"):
        result = session.handle_message(seeded, SIM, visit_id, text)
    assert result.done
    assert json.loads(stored_json(seeded, visit_id)) == result.intake
    assert visit_service(seeded, visit_id) == "dental"
    assert visit_status(seeded, visit_id) == "intake"
    assert transcript(seeded, visit_id)["messages"][-1]["slot"] == simulated.NOT_A_QUESTION


def test_a_correction_after_the_summary_updates_the_intake_and_keeps_the_count(seeded):
    visit_id = make_visit(seeded, "P003")
    for text in ("I have a rash for 2 days", "5", "no", "no", "no"):
        first = session.handle_message(seeded, SIM, visit_id, text)
    seeded.execute("UPDATE intake SET confirmed_by_patient = 1 WHERE visit_id = ?", (visit_id,))
    second = session.handle_message(seeded, SIM, visit_id, "8")
    assert second.done
    assert second.intake["severity_0_10"] == 8
    assert second.intake["questions_asked"] == first.intake["questions_asked"]
    row = seeded.execute(
        "SELECT confirmed_by_patient FROM intake WHERE visit_id = ?", (visit_id,)
    ).fetchone()
    assert row[0] == 0


@pytest.mark.parametrize(
    ("answers", "correction", "read_back"),
    [
        (("I have a rash for 2 days", "5", "no", "no", "no"), "actually it is 8", "severity 8/10"),
        (("عندي كحة من يومين", "خمسة", "لا", "لا", "لا"), "لا، ثمانية", "الشدة 8 من 10"),
    ],
)
def test_a_severity_correction_reaches_the_stored_intake(seeded, answers, correction, read_back):
    visit_id = make_visit(seeded, "P003")
    for text in answers:
        first = session.handle_message(seeded, SIM, visit_id, text)
    assert first.done and first.intake["severity_0_10"] == 5

    second = session.handle_message(seeded, SIM, visit_id, correction)

    assert second.done
    assert read_back in second.reply
    assert json.loads(stored_json(seeded, visit_id))["severity_0_10"] == 8
    assert session.history(seeded, visit_id)["intake"]["severity_0_10"] == 8
    assert session.staff_view(seeded, visit_id)["intake"]["severity_0_10"] == 8
    assert session.staff_view(seeded, visit_id)["turns"][-2]["text"] == correction


def test_rules_still_win_over_a_severity_correction(seeded):
    visit_id = make_visit(seeded, "P003")
    for text in ("I have a rash for 2 days", "5", "no", "no", "no"):
        session.handle_message(seeded, SIM, visit_id, text)
    result = session.handle_message(seeded, SIM, visit_id, "actually it is 8, and chest pain")
    assert result.emergency
    assert visit_status(seeded, visit_id) == "redirected_emergency"


def test_red_flags_still_run_after_the_summary(seeded):
    visit_id = make_visit(seeded, "P003")
    for text in ("I have a rash for 2 days", "5", "no", "no", "no"):
        session.handle_message(seeded, SIM, visit_id, text)
    result = session.handle_message(seeded, SIM, visit_id, "actually I can't breathe")
    assert result.emergency
    assert visit_status(seeded, visit_id) == "redirected_emergency"


def test_emergency_changes_status_and_logs_in_one_write(seeded):
    visit_id = make_visit(seeded, "P003")
    result = session.handle_message(seeded, SIM, visit_id, "Chest pain going to my left arm.")
    assert result.emergency
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    assert "redflag.hit" in event_types(seeded, visit_id)


def test_a_failed_event_write_leaves_the_status_alone(seeded, monkeypatch):
    visit_id = make_visit(seeded, "P003")

    def broken(*args, **kwargs):
        raise RuntimeError("disk full")

    monkeypatch.setattr(session.audit, "record", broken)
    with pytest.raises(RuntimeError):
        session.handle_message(seeded, SIM, visit_id, "I can't breathe")
    assert visit_status(seeded, visit_id) == "intake"
    assert not seeded.in_transaction


def test_an_emergency_is_sticky_with_no_rule_and_no_model(seeded, monkeypatch):
    visit_id = make_visit(seeded, "P003")
    first = session.handle_message(seeded, SIM, visit_id, "I want to end my life")
    client = FakeChatClient([])

    def no_rules(*args, **kwargs):
        raise AssertionError("no rule may run on a sticky emergency")

    monkeypatch.setattr(session.receptionist, "run_turn", no_rules)
    again = session.handle_message(seeded, real(client), visit_id, "I feel better now")
    assert again.emergency
    assert again.self_harm
    assert again.reply == first.reply
    assert again.source == "rules"
    assert again.emergency_category == "self_harm"
    assert client.calls == []
    assert again.events == []
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    assert "I feel better now" not in json.dumps(transcript(seeded, visit_id))


def test_a_sticky_emergency_with_no_transcript_still_says_999(seeded):
    visit_id = make_visit(seeded, "P003", status="redirected_emergency")
    result = session.handle_message(seeded, SIM, visit_id, "hello there")
    assert result.emergency
    assert "999" in result.reply


def test_an_emergency_model_turn_is_sticky_as_model(seeded):
    visit_id = make_visit(seeded, "P001")
    client = FakeChatClient(['{"emergency": true}'])
    first = session.handle_message(seeded, real(client), visit_id, "I feel very strange")
    assert first.source == "model"
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    again = session.handle_message(seeded, real(client), visit_id, "hello again")
    assert again.emergency
    assert again.source == "model"
    assert len(client.calls) == 1


SELF_HARM = "I want to end my life"


def users_said(conn, visit_id):
    return [m["content"] for m in transcript(conn, visit_id)["messages"] if m["role"] == "user"]


def test_self_harm_on_a_closed_emergency_adds_the_support(seeded):
    visit_id = make_visit(seeded, "P003")
    first = session.handle_message(seeded, SIM, visit_id, "I can't breathe")
    assert not first.self_harm
    client = FakeChatClient([])
    result = session.handle_message(seeded, real(client), visit_id, SELF_HARM)
    assert result.emergency
    assert result.self_harm
    assert result.source == "rules"
    assert result.reply == simulated.emergency_reply("en", True)
    assert "999" in result.reply
    assert "talk to someone" in result.reply
    assert client.calls == []
    assert SELF_HARM in users_said(seeded, visit_id)
    hits = [p for name, p in events(seeded, visit_id) if name == "redflag.hit"]
    assert [p["category"] for p in hits] == ["breathing", "self_harm"]
    assert visit_status(seeded, visit_id) == "redirected_emergency"


def test_later_replays_keep_the_supportive_reply(seeded):
    visit_id = make_visit(seeded, "P003")
    session.handle_message(seeded, SIM, visit_id, "I can't breathe")
    hit = session.handle_message(seeded, SIM, visit_id, SELF_HARM)
    written = event_types(seeded, visit_id)
    for later in ("I feel better now", "I can't breathe", "hello"):
        again = session.handle_message(seeded, SIM, visit_id, later)
        assert again.reply == hit.reply
        assert again.self_harm
        assert again.emergency_category == "self_harm"
    assert event_types(seeded, visit_id) == written


def test_self_harm_on_a_visit_with_no_transcript_is_stored(seeded):
    visit_id = make_visit(seeded, "P003", status="redirected_emergency")
    result = session.handle_message(seeded, SIM, visit_id, SELF_HARM)
    assert result.self_harm
    assert users_said(seeded, visit_id) == [SELF_HARM]
    assert session.handle_message(seeded, SIM, visit_id, "hello there").reply == result.reply


def test_a_model_emergency_gains_the_support_too(seeded):
    visit_id = make_visit(seeded, "P001")
    client = FakeChatClient(['{"emergency": true}'])
    session.handle_message(seeded, real(client), visit_id, "I feel very strange")
    result = session.handle_message(seeded, real(client), visit_id, SELF_HARM)
    assert result.self_harm
    assert result.source == "rules"
    assert len(client.calls) == 1


def test_arabic_self_harm_on_a_closed_emergency_answers_in_arabic(seeded):
    visit_id = make_visit(seeded, "P001")
    session.handle_message(seeded, SIM, visit_id, "ما أقدر أتنفس")
    result = session.handle_message(seeded, SIM, visit_id, "أبي أأذي نفسي")
    assert result.self_harm
    assert result.reply == simulated.emergency_reply("ar", True)


def test_another_rule_hit_on_a_closed_emergency_changes_nothing(seeded):
    visit_id = make_visit(seeded, "P003")
    first = session.handle_message(seeded, SIM, visit_id, "I can't breathe")
    written = event_types(seeded, visit_id)
    said = users_said(seeded, visit_id)
    client = FakeChatClient([])
    again = session.handle_message(seeded, real(client), visit_id, "I have chest pain")
    assert again.reply == first.reply
    assert not again.self_harm
    assert again.emergency_category == "breathing"
    assert again.events == []
    assert client.calls == []
    assert event_types(seeded, visit_id) == written
    assert users_said(seeded, visit_id) == said


def test_a_failed_write_on_a_closed_emergency_saves_no_message(seeded, monkeypatch):
    visit_id = make_visit(seeded, "P003")
    session.handle_message(seeded, SIM, visit_id, "I can't breathe")

    def broken(*args, **kwargs):
        raise RuntimeError("disk full")

    monkeypatch.setattr(session.audit, "record", broken)
    with pytest.raises(RuntimeError):
        session.handle_message(seeded, SIM, visit_id, SELF_HARM)
    assert not seeded.in_transaction
    assert SELF_HARM not in users_said(seeded, visit_id)


def deflected_visit(conn):
    visit_id = make_visit(conn, "P002")
    session.handle_message(conn, SIM, visit_id, "I need my usual blood pressure pills")
    assert visit_status(conn, visit_id) == "deflected_refill"
    return visit_id


def test_a_rule_hit_on_a_deflected_visit_is_an_emergency(seeded):
    visit_id = deflected_visit(seeded)
    client = FakeChatClient([])
    result = session.handle_message(seeded, real(client), visit_id, "I can't breathe")
    assert result.emergency
    assert result.source == "rules"
    assert result.refill is None
    assert "999" in result.reply
    assert client.calls == []
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    assert "redflag.hit" in event_types(seeded, visit_id)
    assert "I can't breathe" in users_said(seeded, visit_id)


def test_a_deflected_emergency_stays_sticky(seeded):
    visit_id = deflected_visit(seeded)
    first = session.handle_message(seeded, SIM, visit_id, "I can't breathe")
    assert session.handle_message(seeded, SIM, visit_id, "hello there").reply == first.reply
    with pytest.raises(SessionError) as error:
        session.continue_after_refill(seeded, visit_id)
    assert error.value.code == "visit_not_deflected"


def test_self_harm_on_a_deflected_visit_carries_the_support(seeded):
    visit_id = deflected_visit(seeded)
    result = session.handle_message(seeded, SIM, visit_id, SELF_HARM)
    assert result.self_harm
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    assert session.handle_message(seeded, SIM, visit_id, "hello there").reply == result.reply


@pytest.mark.parametrize("text", ["hello there", "no chest pain"])
def test_a_clear_message_on_a_deflected_visit_is_refused(seeded, text):
    visit_id = deflected_visit(seeded)
    written = event_types(seeded, visit_id)
    client = FakeChatClient([])
    with pytest.raises(SessionError) as error:
        session.handle_message(seeded, real(client), visit_id, text)
    assert error.value.code == "visit_not_in_intake"
    assert client.calls == []
    assert visit_status(seeded, visit_id) == "deflected_refill"
    assert event_types(seeded, visit_id) == written


@pytest.mark.parametrize(
    "status", ["completed", "cancelled", "in_triage", "in_doctor", "in_pharmacy"]
)
def test_a_rule_hit_on_any_other_status_is_still_refused(seeded, status):
    visit_id = make_visit(seeded, "P003", status=status)
    with pytest.raises(SessionError) as error:
        session.handle_message(seeded, SIM, visit_id, "I can't breathe")
    assert error.value.code == "visit_not_in_intake"
    assert visit_status(seeded, visit_id) == status
    assert event_types(seeded, visit_id) == []


def reserved_visit(conn, engine):
    """A finished intake with a real reserved ticket, as a patient at home has."""
    visit_id = make_visit(conn, "P003")
    for text in ("I have a rash for 2 days", "5", "no", "no", "no"):
        result = session.handle_message(conn, SIM, visit_id, text)
    assert result.done
    ticket = engine.issue_ticket(visit_id, "C-WAKRA-T1")
    assert visit_status(conn, visit_id) == "reserved"
    return visit_id, ticket


def hit_categories(conn, visit_id):
    return [p["category"] for name, p in events(conn, visit_id) if name == "redflag.hit"]


def tickets_of(conn, visit_id):
    return conn.execute("SELECT COUNT(*) FROM ticket WHERE visit_id = ?", (visit_id,)).fetchone()[0]


def test_a_rule_hit_on_a_reserved_visit_stops_the_ticket(seeded, engine, clock):
    visit_id, ticket = reserved_visit(seeded, engine)
    client = FakeChatClient([])
    result = session.handle_message(seeded, real(client), visit_id, "I can't breathe")
    assert result.emergency
    assert result.source == "rules"
    assert result.reply == simulated.emergency_reply("en", False)
    assert "999" in result.reply
    assert client.calls == []
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    assert hit_categories(seeded, visit_id) == ["breathing"]
    said = transcript(seeded, visit_id)["messages"]
    assert said[-2]["content"] == "I can't breathe"
    assert said[-1]["content"] == result.reply

    with pytest.raises(VisitNotEligible):
        engine.activate(ticket.id)
    clock.advance(minutes=46)
    engine.expire_due()
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, "C-WAKRA-T1")
    assert tickets_of(seeded, visit_id) == 1


def test_a_rule_hit_on_a_reserved_visit_keeps_the_stored_intake(seeded, engine):
    visit_id, _ = reserved_visit(seeded, engine)
    before = stored_json(seeded, visit_id)
    session.handle_message(seeded, SIM, visit_id, "I can't breathe")
    assert stored_json(seeded, visit_id) == before


def test_a_rule_hit_works_on_a_reserved_visit_with_no_transcript(seeded):
    visit_id = make_visit(seeded, "P003", status="reserved")
    result = session.handle_message(seeded, SIM, visit_id, "I can't breathe")
    assert result.emergency
    assert visit_status(seeded, visit_id) == "redirected_emergency"


@pytest.mark.parametrize(
    "patient, lang, text, support",
    [
        ("P003", "en", SELF_HARM, "talk to someone"),
        ("P001", "ar", "أبي أأذي نفسي", simulated._SUPPORT["ar"]),
    ],
)
def test_self_harm_on_a_reserved_visit_gets_999_and_the_support(
    seeded, engine, patient, lang, text, support
):
    visit_id = make_visit(seeded, patient)
    ticket = engine.issue_ticket(visit_id, "C-WAKRA-T1")
    client = FakeChatClient([])
    result = session.handle_message(seeded, real(client), visit_id, text)
    assert result.emergency
    assert result.self_harm
    assert result.reply == simulated.emergency_reply(lang, True)
    assert "999" in result.reply
    assert support in result.reply
    assert client.calls == []
    assert hit_categories(seeded, visit_id) == ["self_harm"]
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    with pytest.raises(VisitNotEligible):
        engine.activate(ticket.id)


@pytest.mark.parametrize("later", ["hello there", "I have chest pain"])
def test_a_message_after_a_reserved_emergency_is_sticky(seeded, engine, later):
    visit_id, _ = reserved_visit(seeded, engine)
    first = session.handle_message(seeded, SIM, visit_id, "I can't breathe")
    written = event_types(seeded, visit_id)
    said = users_said(seeded, visit_id)
    client = FakeChatClient([])
    again = session.handle_message(seeded, real(client), visit_id, later)
    assert again.emergency
    assert again.reply == first.reply
    assert client.calls == []
    assert event_types(seeded, visit_id) == written
    assert users_said(seeded, visit_id) == said


@pytest.mark.parametrize("text", ["hello there", "no chest pain", "I need my usual pills"])
def test_a_clear_message_on_a_reserved_visit_is_refused_and_kept(seeded, engine, text):
    visit_id, ticket = reserved_visit(seeded, engine)
    written = event_types(seeded, visit_id)
    before = stored_json(seeded, visit_id)
    last_turn = transcript(seeded, visit_id)["last_turn"]
    client = FakeChatClient([])
    with pytest.raises(SessionError) as error:
        session.handle_message(seeded, real(client), visit_id, text)
    assert error.value.code == "visit_not_in_intake"
    assert client.calls == []
    assert visit_status(seeded, visit_id) == "reserved"
    assert event_types(seeded, visit_id) == written
    assert users_said(seeded, visit_id)[-1] == text
    assert stored_json(seeded, visit_id) == before
    assert transcript(seeded, visit_id)["last_turn"] == last_turn
    assert engine.activate(ticket.id).state == "active"


@pytest.mark.parametrize(
    "first, second, category",
    [
        ("I have pain", "chest", "chest_pain"),
        ("chest", "it is a bad pain", "chest_pain"),
        ("عندي ألم", "في الصدر", "chest_pain"),
    ],
)
def test_a_split_cue_completes_across_refused_messages(seeded, engine, first, second, category):
    visit_id, ticket = reserved_visit(seeded, engine)
    client = FakeChatClient([])
    with pytest.raises(SessionError):
        session.handle_message(seeded, real(client), visit_id, first)
    assert visit_status(seeded, visit_id) == "reserved"
    result = session.handle_message(seeded, real(client), visit_id, second)
    assert result.emergency
    assert client.calls == []
    assert hit_categories(seeded, visit_id) == [category]
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    assert users_said(seeded, visit_id)[-2:] == [first, second]
    with pytest.raises(VisitNotEligible):
        engine.activate(ticket.id)


def test_a_cue_split_across_the_reservation_completes_too(seeded, engine):
    visit_id = make_visit(seeded, "P003")
    session.handle_message(seeded, SIM, visit_id, "I have pain")
    engine.issue_ticket(visit_id, "C-WAKRA-T1")
    result = session.handle_message(seeded, SIM, visit_id, "chest")
    assert result.emergency
    assert visit_status(seeded, visit_id) == "redirected_emergency"


def expired_visit(conn, engine, clock):
    """A real reservation that lapsed, so the visit is where the engine leaves it."""
    visit_id, _ = reserved_visit(conn, engine)
    lapse(conn, engine, clock, visit_id)
    return visit_id


def lapse(conn, engine, clock, visit_id):
    clock.advance(minutes=46)
    engine.expire_due()
    assert visit_status(conn, visit_id) == "expired"


@pytest.mark.parametrize(
    "patient, lang, text, category",
    [
        ("P003", "en", "I have chest pain", "chest_pain"),
        ("P001", "ar", "عندي ألم في الصدر", "chest_pain"),
    ],
)
def test_a_rule_hit_on_an_expired_visit_stops_the_ticket(
    seeded, engine, clock, patient, lang, text, category
):
    visit_id = make_visit(seeded, patient)
    engine.issue_ticket(visit_id, "C-WAKRA-T1")
    lapse(seeded, engine, clock, visit_id)
    client = FakeChatClient([])
    result = session.handle_message(seeded, real(client), visit_id, text)
    assert result.emergency
    assert result.source == "rules"
    assert result.reply == simulated.emergency_reply(lang, False)
    assert "999" in result.reply
    assert client.calls == []
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    assert hit_categories(seeded, visit_id) == [category]
    said = transcript(seeded, visit_id)["messages"]
    assert said[-2]["content"] == text
    assert said[-1]["content"] == result.reply

    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, "C-WAKRA-T1")
    assert tickets_of(seeded, visit_id) == 1


def test_a_rule_hit_on_an_expired_visit_keeps_the_stored_intake(seeded, engine, clock):
    visit_id = expired_visit(seeded, engine, clock)
    before = stored_json(seeded, visit_id)
    session.handle_message(seeded, SIM, visit_id, "I have chest pain")
    assert stored_json(seeded, visit_id) == before


@pytest.mark.parametrize("later", ["hello there", "I have chest pain"])
def test_a_message_after_an_expired_emergency_is_sticky(seeded, engine, clock, later):
    visit_id = expired_visit(seeded, engine, clock)
    first = session.handle_message(seeded, SIM, visit_id, "I can't breathe")
    written = event_types(seeded, visit_id)
    said = users_said(seeded, visit_id)
    client = FakeChatClient([])
    again = session.handle_message(seeded, real(client), visit_id, later)
    assert again.emergency
    assert again.reply == first.reply
    assert client.calls == []
    assert event_types(seeded, visit_id) == written
    assert users_said(seeded, visit_id) == said


@pytest.mark.parametrize(
    "patient, lang, text, support",
    [
        ("P003", "en", SELF_HARM, "talk to someone"),
        ("P001", "ar", "أبي أأذي نفسي", simulated._SUPPORT["ar"]),
    ],
)
def test_self_harm_on_an_expired_visit_gets_999_and_the_support(
    seeded, engine, clock, patient, lang, text, support
):
    visit_id = make_visit(seeded, patient)
    engine.issue_ticket(visit_id, "C-WAKRA-T1")
    lapse(seeded, engine, clock, visit_id)
    client = FakeChatClient([])
    result = session.handle_message(seeded, real(client), visit_id, text)
    assert result.emergency
    assert result.self_harm
    assert result.reply == simulated.emergency_reply(lang, True)
    assert "999" in result.reply
    assert support in result.reply
    assert client.calls == []
    assert hit_categories(seeded, visit_id) == ["self_harm"]
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, "C-WAKRA-T1")
    assert session.handle_message(seeded, SIM, visit_id, "hello there").reply == result.reply


def test_self_harm_after_an_expired_emergency_adds_the_support(seeded, engine, clock):
    visit_id = expired_visit(seeded, engine, clock)
    session.handle_message(seeded, SIM, visit_id, "I can't breathe")
    result = session.handle_message(seeded, SIM, visit_id, SELF_HARM)
    assert result.self_harm
    assert hit_categories(seeded, visit_id) == ["breathing", "self_harm"]


@pytest.mark.parametrize("text", ["hello there", "no chest pain", "I need my usual pills"])
def test_a_clear_message_on_an_expired_visit_is_refused_and_kept(seeded, engine, clock, text):
    visit_id = expired_visit(seeded, engine, clock)
    written = event_types(seeded, visit_id)
    before = stored_json(seeded, visit_id)
    last_turn = transcript(seeded, visit_id)["last_turn"]
    client = FakeChatClient([])
    with pytest.raises(SessionError) as error:
        session.handle_message(seeded, real(client), visit_id, text)
    assert error.value.code == "visit_not_in_intake"
    assert client.calls == []
    assert visit_status(seeded, visit_id) == "expired"
    assert event_types(seeded, visit_id) == written
    assert users_said(seeded, visit_id)[-1] == text
    assert stored_json(seeded, visit_id) == before
    assert transcript(seeded, visit_id)["last_turn"] == last_turn

    assert engine.issue_ticket(visit_id, "C-WAKRA-T1").state == "reserved"
    assert visit_status(seeded, visit_id) == "reserved"
    assert tickets_of(seeded, visit_id) == 2


def test_a_second_reservation_still_takes_rules(seeded, engine, clock):
    visit_id = expired_visit(seeded, engine, clock)
    ticket = engine.issue_ticket(visit_id, "C-WAKRA-T1")
    assert session.handle_message(seeded, SIM, visit_id, "I have chest pain").emergency
    with pytest.raises(VisitNotEligible):
        engine.activate(ticket.id)


@pytest.mark.parametrize(
    "first, second",
    [("I have pain", "chest"), ("chest", "it is a bad pain"), ("عندي ألم", "في الصدر")],
)
@pytest.mark.parametrize("first_lands", ["in_intake", "on_the_reservation", "after_expiry"])
def test_a_split_cue_completes_after_expiry(seeded, engine, clock, first, second, first_lands):
    visit_id = make_visit(seeded, "P003")

    def say_first_and_be_refused():
        with pytest.raises(SessionError):
            session.handle_message(seeded, SIM, visit_id, first)

    if first_lands == "in_intake":
        session.handle_message(seeded, SIM, visit_id, first)
    engine.issue_ticket(visit_id, "C-WAKRA-T1")
    if first_lands == "on_the_reservation":
        say_first_and_be_refused()
    lapse(seeded, engine, clock, visit_id)
    if first_lands == "after_expiry":
        say_first_and_be_refused()
        assert visit_status(seeded, visit_id) == "expired"

    client = FakeChatClient([])
    result = session.handle_message(seeded, real(client), visit_id, second)
    assert result.emergency
    assert client.calls == []
    assert hit_categories(seeded, visit_id) == ["chest_pain"]
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, "C-WAKRA-T1")
    assert tickets_of(seeded, visit_id) == 1


def lapses_during_the_call(engine, clock, visit_id, then=None):
    """A model call long enough for the patient to reserve and for that to lapse."""

    class Racer(FakeChatClient):
        def chat_completion(self, messages, **kw):
            engine.issue_ticket(visit_id, "C-WAKRA-T1")
            clock.advance(minutes=46)
            engine.expire_due()
            if then:
                then()
            return super().chat_completion(messages, **kw)

    return Racer


@pytest.mark.parametrize(
    "reply", ['{"emergency": true}', 'not json "emergency": true {', "This is an emergency."]
)
def test_an_emergency_reaching_the_save_after_expiry_still_stops_the_ticket(
    seeded, engine, clock, reply
):
    visit_id = make_visit(seeded, "P001")
    client = lapses_during_the_call(engine, clock, visit_id)([reply])
    result = session.handle_message(seeded, real(client), visit_id, "I feel strange")
    assert result.emergency
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    assert "ai.emergency" in event_types(seeded, visit_id)
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, "C-WAKRA-T1")
    assert tickets_of(seeded, visit_id) == 1


def test_a_cue_completed_during_the_call_still_stops_an_expired_visit(
    seeded, engine, clock, db_path
):
    visit_id = make_visit(seeded, "P003")

    def second_half():
        other = db.connect(db_path)
        with pytest.raises(SessionError):
            session.handle_message(other, SIM, visit_id, "chest")
        other.close()

    client = lapses_during_the_call(engine, clock, visit_id, second_half)(["Since when?"])
    result = session.handle_message(seeded, real(client), visit_id, "I have pain")
    assert result.emergency
    assert result.source == "rules"
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, "C-WAKRA-T1")


def test_a_clear_turn_reaching_the_save_after_expiry_is_refused(seeded, engine, clock):
    visit_id = make_visit(seeded, "P003")
    client = lapses_during_the_call(engine, clock, visit_id)(["Since when?"])
    with pytest.raises(SessionError) as error:
        session.handle_message(seeded, real(client), visit_id, "I have a cough")
    assert error.value.code == "visit_not_in_intake"
    assert not seeded.in_transaction
    assert visit_status(seeded, visit_id) == "expired"
    assert engine.issue_ticket(visit_id, "C-WAKRA-T1").state == "reserved"


LONG = 2500
FILLERS = {"en": "today was a long day at home ", "ar": "كان اليوم طويل في البيت "}
CUES = {"en": "I have chest pain", "ar": "عندي ألم في الصدر"}


def padded(text, lang, where, length=LONG):
    room = length - len(text) - 1
    filler = (FILLERS[lang] * (length // len(FILLERS[lang]) + 1))[:room]
    message = f"{text} {filler}" if where == "start" else f"{filler} {text}"
    assert len(message) == length
    return message


def finished_visit(conn):
    visit_id = make_visit(conn, "P003")
    for text in ("I have a rash for 2 days", "5", "no", "no", "no"):
        result = session.handle_message(conn, SIM, visit_id, text)
    assert result.done
    return visit_id


@pytest.mark.parametrize("lang", ["en", "ar"])
@pytest.mark.parametrize("where", ["start", "end"])
@pytest.mark.parametrize("stage", ["fresh", "finished"])
def test_an_over_long_cue_stops_a_visit_in_intake(seeded, engine, lang, where, stage):
    visit_id = make_visit(seeded, "P003") if stage == "fresh" else finished_visit(seeded)
    message = padded(CUES[lang], lang, where)
    client = FakeChatClient([])
    result = session.handle_message(seeded, real(client), visit_id, message)
    assert result.emergency
    assert result.source == "rules"
    assert result.reply == simulated.emergency_reply(lang, False)
    assert client.calls == []
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    assert hit_categories(seeded, visit_id) == ["chest_pain"]
    assert users_said(seeded, visit_id)[-1] == message[:2000]
    assert len(users_said(seeded, visit_id)[-1]) == 2000
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, "C-WAKRA-T1")
    assert tickets_of(seeded, visit_id) == 0
    again = session.handle_message(seeded, real(client), visit_id, "hello there")
    assert again.emergency
    assert client.calls == []


@pytest.mark.parametrize("lang", ["en", "ar"])
@pytest.mark.parametrize("where", ["start", "end"])
def test_an_over_long_cue_stops_a_reserved_visit(seeded, engine, clock, lang, where):
    visit_id, ticket = reserved_visit(seeded, engine)
    message = padded(CUES[lang], lang, where)
    client = FakeChatClient([])
    result = session.handle_message(seeded, real(client), visit_id, message)
    assert result.emergency
    assert client.calls == []
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    assert hit_categories(seeded, visit_id) == ["chest_pain"]
    assert users_said(seeded, visit_id)[-1] == message[:2000]
    with pytest.raises(VisitHasLiveTicket):
        engine.issue_ticket(visit_id, "C-WAKRA-T1")
    with pytest.raises(VisitNotEligible):
        engine.activate(ticket.id)
    clock.advance(minutes=46)
    engine.expire_due()
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, "C-WAKRA-T1")
    assert tickets_of(seeded, visit_id) == 1


@pytest.mark.parametrize("lang", ["en", "ar"])
@pytest.mark.parametrize("where", ["start", "end"])
def test_an_over_long_cue_stops_an_expired_visit(seeded, engine, clock, lang, where):
    visit_id = expired_visit(seeded, engine, clock)
    message = padded(CUES[lang], lang, where)
    result = session.handle_message(seeded, SIM, visit_id, message)
    assert result.emergency
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    assert len(users_said(seeded, visit_id)[-1]) == 2000
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, "C-WAKRA-T1")
    assert tickets_of(seeded, visit_id) == 1


@pytest.mark.parametrize("where", ["start", "end"])
def test_an_over_long_cue_stops_a_deflected_visit(seeded, where):
    visit_id = deflected_visit(seeded)
    result = session.handle_message(seeded, SIM, visit_id, padded(CUES["en"], "en", where))
    assert result.emergency
    assert visit_status(seeded, visit_id) == "redirected_emergency"


@pytest.mark.parametrize(
    "patient, lang, text",
    [("P003", "en", SELF_HARM), ("P001", "ar", "أبي أأذي نفسي")],
)
@pytest.mark.parametrize("where", ["start", "end"])
def test_over_long_self_harm_gets_the_support(seeded, patient, lang, text, where):
    visit_id = make_visit(seeded, patient)
    result = session.handle_message(seeded, SIM, visit_id, padded(text, lang, where))
    assert result.self_harm
    assert result.reply == simulated.emergency_reply(lang, True)
    assert "999" in result.reply


@pytest.mark.parametrize("where", ["start", "end"])
def test_over_long_self_harm_on_a_closed_emergency_adds_the_support(seeded, where):
    visit_id = make_visit(seeded, "P003")
    session.handle_message(seeded, SIM, visit_id, "I can't breathe")
    message = padded(SELF_HARM, "en", where)
    result = session.handle_message(seeded, SIM, visit_id, message)
    assert result.self_harm
    assert result.reply == simulated.emergency_reply("en", True)
    assert hit_categories(seeded, visit_id) == ["breathing", "self_harm"]
    assert users_said(seeded, visit_id)[-1] == message[:2000]
    assert session.handle_message(seeded, SIM, visit_id, "hello there").reply == result.reply


def test_another_over_long_hit_on_a_closed_emergency_changes_nothing(seeded):
    visit_id = make_visit(seeded, "P003")
    first = session.handle_message(seeded, SIM, visit_id, "I can't breathe")
    written = event_types(seeded, visit_id)
    said = users_said(seeded, visit_id)
    client = FakeChatClient([])
    again = session.handle_message(
        seeded, real(client), visit_id, padded(CUES["en"], "en", "end")
    )
    assert again.emergency
    assert again.reply == first.reply
    assert again.events == []
    assert client.calls == []
    assert event_types(seeded, visit_id) == written
    assert users_said(seeded, visit_id) == said


def test_a_clear_over_long_message_on_a_closed_emergency_is_refused(seeded):
    visit_id = make_visit(seeded, "P003")
    session.handle_message(seeded, SIM, visit_id, "I can't breathe")
    with pytest.raises(SessionError) as error:
        session.handle_message(seeded, SIM, visit_id, "x" * LONG)
    assert error.value.code == "invalid_text"


def test_an_over_long_message_can_complete_a_split_cue(seeded, engine):
    visit_id, _ = reserved_visit(seeded, engine)
    with pytest.raises(SessionError):
        session.handle_message(seeded, SIM, visit_id, "I have pain")
    result = session.handle_message(seeded, SIM, visit_id, padded("chest", "en", "end"))
    assert result.emergency
    assert hit_categories(seeded, visit_id) == ["chest_pain"]


@pytest.mark.parametrize("text", ["x" * LONG, padded("no chest pain", "en", "end")])
@pytest.mark.parametrize("stage", ["intake", "reserved", "expired", "deflected"])
def test_a_clear_over_long_message_is_refused_with_no_model_and_no_write(
    seeded, engine, clock, stage, text
):
    if stage == "deflected":
        visit_id = deflected_visit(seeded)
    elif stage == "intake":
        visit_id = finished_visit(seeded)
    else:
        visit_id, _ = reserved_visit(seeded, engine)
        if stage == "expired":
            lapse(seeded, engine, clock, visit_id)
    written = event_types(seeded, visit_id)
    before = transcript(seeded, visit_id)
    status = visit_status(seeded, visit_id)
    client = FakeChatClient([])
    with pytest.raises(SessionError) as error:
        session.handle_message(seeded, real(client), visit_id, text)
    assert error.value.code == "invalid_text"
    assert client.calls == []
    assert visit_status(seeded, visit_id) == status
    assert event_types(seeded, visit_id) == written
    assert transcript(seeded, visit_id) == before


@pytest.mark.parametrize(
    "status", ["completed", "cancelled", "in_triage", "in_doctor", "in_pharmacy"]
)
def test_an_over_long_cue_past_the_rules_statuses_is_invalid_text(seeded, status):
    visit_id = make_visit(seeded, "P003", status=status)
    with pytest.raises(SessionError) as error:
        session.handle_message(seeded, SIM, visit_id, padded(CUES["en"], "en", "end"))
    assert error.value.code == "invalid_text"
    assert visit_status(seeded, visit_id) == status
    assert event_types(seeded, visit_id) == []


@pytest.mark.parametrize("text", [" " * LONG, "\n\t" * LONG, None, 7, b"chest pain"])
@pytest.mark.parametrize("status", ["intake", "reserved", "expired", "redirected_emergency"])
def test_blank_and_non_text_stay_invalid(seeded, status, text):
    visit_id = make_visit(seeded, "P003", status=status)
    with pytest.raises(SessionError) as error:
        session.handle_message(seeded, SIM, visit_id, text)
    assert error.value.code == "invalid_text"
    assert event_types(seeded, visit_id) == []


def test_one_character_over_the_limit_takes_the_over_long_path(seeded):
    visit_id = make_visit(seeded, "P003")
    message = padded(CUES["en"], "en", "end", length=2001)
    assert session.handle_message(seeded, SIM, visit_id, message).emergency
    assert len(users_said(seeded, visit_id)[-1]) == 2000


# The model text gate. These words are invented, and test_invented_words_are_on_no_list
# proves they appear nowhere in backend/ai, so only the shape can be refusing them.
INVENTED = ("zorblax", "quorvane", "blimtrex", "زوربلاكس", "كورفانيت")
NOT_ONE_QUESTION = (
    "You have {w}.",
    "{w} is best.",
    "Take {w}.",
    "Try {w}.",
    "You probably have {w}.",
    "It looks like {w}.",
    "Thanks. {w} is best.",
    "{w}. How long have you had it?",
    "How long have you had it? {w} is best.",
    "عندك {w}.",
    "{w} افضل شي.",
    "خذ {w}.",
    "Thanks for {w}. How long have you had it?",
    "Sorry about your {w}. How long have you had it?",
    "Okay, {w}, how long have you had it?",
    "How long have you had it?\n{w}",
    "شكرا على {w}. من متى عندك الكحة؟",
)
OPENS_ON_NO_FRAME = ("You have {w}?", "{w} is best, okay?", "Is it {w}?", "Take {w}?")
UNKNOWN_WORD_IN_A_QUESTION = ("Do you have {w}?", "Did you take {w}?", "عندك {w}؟", "هل اخذت {w}؟")


def switch_off_the_filters(monkeypatch):
    passed = filters.FilterResult(True, ())
    monkeypatch.setattr(filters, "check_reply", lambda *a, **k: passed)


def fallback_reasons(conn, visit_id):
    return [p["reason"] for name, p in events(conn, visit_id) if name == "ai.fallback"]


def everything_the_patient_gets(conn, visit_id, result):
    shown = [result.to_api(), session.history(conn, visit_id)]
    return json.dumps(shown, ensure_ascii=False)


@pytest.mark.parametrize("word", INVENTED)
def test_invented_words_are_on_no_list(word):
    source = Path(filters.__file__).parent.glob("*.py")
    assert not any(word in path.read_text(encoding="utf-8") for path in source)


@pytest.mark.parametrize("word", INVENTED)
@pytest.mark.parametrize("shape", NOT_ONE_QUESTION + OPENS_ON_NO_FRAME + UNKNOWN_WORD_IN_A_QUESTION)
def test_the_gate_keeps_an_unlisted_word_from_the_patient(seeded, monkeypatch, shape, word):
    """Every filter is off, so nothing but the gate can be doing this."""
    switch_off_the_filters(monkeypatch)
    client = FakeChatClient([shape.format(w=word), "Since when?"])
    visit_id = make_visit(seeded, "P003")
    result = session.handle_message(seeded, real(client), visit_id, "I have a cough")
    assert result.source == "simulated"
    assert not result.done
    assert word not in everything_the_patient_gets(seeded, visit_id, result)
    assert fallback_reasons(seeded, visit_id) == ["bad_shape"]

    after = session.handle_message(seeded, real(client), visit_id, "it is getting worse")
    assert after.source == "model"
    assert after.reply == "Since when?"
    assert len(client.calls) == 2


@pytest.mark.parametrize("word", INVENTED)
@pytest.mark.parametrize("shape", NOT_ONE_QUESTION + OPENS_ON_NO_FRAME)
def test_the_patient_saying_a_word_does_not_excuse_the_shape(seeded, monkeypatch, shape, word):
    switch_off_the_filters(monkeypatch)
    client = FakeChatClient([shape.format(w=word)])
    visit_id = make_visit(seeded, "P003")
    result = session.handle_message(seeded, real(client), visit_id, f"I think it is {word}")
    assert result.source == "simulated"
    assert fallback_reasons(seeded, visit_id) == ["bad_shape"]


@pytest.mark.parametrize(
    "reply",
    [
        "How long have you had it?",
        "Thanks. How long have you had it?",
        "Sorry to hear that. Do you have a fever?",
        "شكرا. من متى عندك الكحة؟",
    ],
)
def test_one_short_question_reaches_the_patient(seeded, reply):
    visit_id = make_visit(seeded, "P003")
    result = session.handle_message(seeded, real(FakeChatClient([reply])), visit_id, "I have a cough")
    assert result.source == "model"
    assert result.reply == reply
    assert fallback_reasons(seeded, visit_id) == []


@pytest.mark.parametrize(
    "reply",
    [
        "Thanks thanks thanks thanks thanks thanks thanks. How long have you had it?",
        "Thanks 3. How long have you had it?",
        "Thanks. Okay. How long have you had it?",
        "Sorry about the flu. How long have you had it?",
        "Okay panadol. How long have you had it?",
        "عندك انفلونزا. من متى عندك الكحة؟",
        "Do you have 3 tablets?",
        "How long have you had it and how long have you had it and how long now?",
        "How long have you had it?\nHow long now",
    ],
)
def test_the_gate_refuses_any_other_shape(seeded, monkeypatch, reply):
    switch_off_the_filters(monkeypatch)
    client = FakeChatClient([reply])
    visit_id = make_visit(seeded, "P003")
    result = session.handle_message(seeded, real(client), visit_id, "I have a cough")
    assert result.source == "simulated"
    assert result.reply != reply
    assert reply not in everything_the_patient_gets(seeded, visit_id, result)
    assert fallback_reasons(seeded, visit_id) == ["bad_shape"]


@pytest.mark.parametrize("word", INVENTED)
def test_prose_in_a_retry_after_broken_json_never_reaches_the_patient(seeded, monkeypatch, word):
    switch_off_the_filters(monkeypatch)
    client = FakeChatClient([f"{{{word}", f"You have {word}."])
    visit_id = make_visit(seeded, "P003")
    result = session.handle_message(seeded, real(client), visit_id, "I have a cough")
    assert result.source == "simulated"
    assert word not in everything_the_patient_gets(seeded, visit_id, result)
    assert fallback_reasons(seeded, visit_id) == ["invalid_json"]


@pytest.mark.parametrize("word", INVENTED)
def test_prose_at_the_question_cap_never_reaches_the_patient(seeded, monkeypatch, word):
    switch_off_the_filters(monkeypatch)
    questions = ["Since when?"] * (simulated.MAX_QUESTIONS - 1)
    client = FakeChatClient([*questions, f"You have {word}.", f"{word} is best."])
    visit_id = make_visit(seeded, "P003")
    for text in ("I have a cough", "yesterday", "it is bad", "at night", "no"):
        session.handle_message(seeded, real(client), visit_id, text)
    result = session.handle_message(seeded, real(client), visit_id, "that is all")
    assert result.source == "simulated"
    assert word not in everything_the_patient_gets(seeded, visit_id, result)
    assert fallback_reasons(seeded, visit_id) == ["question_cap"]


@pytest.mark.parametrize("word", INVENTED)
def test_model_prose_in_an_intake_stays_with_staff(seeded, word):
    client = FakeChatClient(
        [
            intake_json(
                chief_complaint=word,
                chief_complaint_patient_words=word,
                duration=f"{word} for 3 days",
                associated=[word],
                self_medication=[word],
                summary_for_nurse=f"45M, cough, {word}.",
                patient_concerns=word,
                refill_request=word,
            )
        ]
    )
    visit_id = make_visit(seeded, "P003")
    result = session.handle_message(seeded, real(client), visit_id, "I have a cough")
    assert result.done
    assert result.source == "model"
    assert word not in result.reply
    assert word not in everything_the_patient_gets(seeded, visit_id, result)
    assert word not in json.dumps(transcript(seeded, visit_id), ensure_ascii=False)

    stored = json.loads(stored_json(seeded, visit_id))
    assert stored["summary_for_nurse"] == f"45M, cough, {word}."
    assert stored["self_medication"] == []
    assert stored["refill_request"] is None
    assert stored["chief_complaint_patient_words"] == "I have a cough"


def test_the_read_back_uses_the_validated_duration_and_severity(seeded):
    client = FakeChatClient(
        [intake_json(duration="zorblax for 3 days", severity_0_10=4, summary_for_nurse="Cough.")]
    )
    visit_id = make_visit(seeded, "P003")
    result = session.handle_message(seeded, real(client), visit_id, "I have a cough")
    assert result.reply == simulated.summary_reply(
        {
            **result.intake,
            "chief_complaint": "cough",
            "duration": "3 days",
            "summary_for_nurse": "never read",
        },
        "en",
    )
    assert "3 days" in result.reply
    assert "4" in result.reply


def test_the_read_back_uses_the_patients_complaint_and_not_the_models(seeded):
    client = FakeChatClient([intake_json(chief_complaint="fever")])
    visit_id = make_visit(seeded, "P003")
    result = session.handle_message(seeded, real(client), visit_id, "I have a cough")
    assert result.done
    assert "cough" in result.reply
    assert "fever" not in result.reply


def test_self_medication_comes_from_the_patient_and_never_the_model(seeded):
    client = FakeChatClient([intake_json(self_medication=["zorblax"])])
    visit_id = make_visit(seeded, "P003")
    text = "I have a cough and I took paracetamol"
    result = session.handle_message(seeded, real(client), visit_id, text)
    assert result.done
    assert result.intake["self_medication"] == ["paracetamol"]
    assert json.loads(stored_json(seeded, visit_id))["self_medication"] == ["paracetamol"]


def test_a_nurse_edit_shows_no_staff_prose_to_the_patient(seeded):
    visit_id = make_visit(seeded, "P003")
    for text in ("I have a rash for 2 days", "5", "no", "no", "no"):
        session.handle_message(seeded, SIM, visit_id, text)
    edit = {**json.loads(stored_json(seeded, visit_id)), "summary_for_nurse": "nurse note"}
    seeded.execute(
        "UPDATE intake SET edited_json = ? WHERE visit_id = ?", (json.dumps(edit), visit_id)
    )
    view = session.history(seeded, visit_id)
    assert view["intake"]["service"] == edit["service"]
    assert "nurse note" not in json.dumps(view)


def test_a_refill_sets_status_and_service(seeded):
    visit_id = make_visit(seeded, "P002")
    result = session.handle_message(seeded, SIM, visit_id, "I need my usual blood pressure tablets.")
    assert result.refill == {"medicine": "amlodipine 5 mg once daily"}
    assert visit_status(seeded, visit_id) == "deflected_refill"
    assert visit_service(seeded, visit_id) == "refill"
    assert stored_json(seeded, visit_id) == "{}"


def test_continue_after_refill_goes_on_as_gp(seeded):
    visit_id = make_visit(seeded, "P002")
    session.handle_message(seeded, SIM, visit_id, "I need my usual blood pressure tablets.")
    result = session.continue_after_refill(seeded, visit_id)
    assert result["service"] == "gp"
    assert result["refill_request"] == "amlodipine 5 mg once daily"
    assert visit_status(seeded, visit_id) == "intake"
    assert visit_service(seeded, visit_id) == "gp"
    assert json.loads(stored_json(seeded, visit_id)) == result
    assert ("refill.declined", {"medicine": "amlodipine 5 mg once daily"}) in events(seeded, visit_id)


def test_continue_after_refill_counts_only_questions(seeded):
    visit_id = make_visit(seeded, "P002")
    session.handle_message(seeded, SIM, visit_id, "I need my usual blood pressure tablets.")
    assert session.continue_after_refill(seeded, visit_id)["questions_asked"] == 1


@pytest.mark.parametrize("status", ["intake", "reserved", "redirected_emergency"])
def test_continue_needs_a_deflected_visit(seeded, status):
    visit_id = make_visit(seeded, "P002", status=status)
    with pytest.raises(SessionError) as error:
        session.continue_after_refill(seeded, visit_id)
    assert error.value.code == "visit_not_deflected"


def test_continue_cannot_run_twice(seeded):
    visit_id = make_visit(seeded, "P002")
    session.handle_message(seeded, SIM, visit_id, "I need my usual blood pressure tablets.")
    session.continue_after_refill(seeded, visit_id)
    with pytest.raises(SessionError):
        session.continue_after_refill(seeded, visit_id)


def test_denied_accumulates_across_turns(seeded):
    visit_id = make_visit(seeded, "P003")
    session.handle_message(seeded, SIM, visit_id, "no chest pain, I have a cough")
    result = session.handle_message(seeded, SIM, visit_id, "not short of breath, since yesterday")
    assert result.denied == ["chest pain", "shortness of breath"]
    assert transcript(seeded, visit_id)["denied"] == ["chest pain", "shortness of breath"]


def test_events_are_written_with_the_turn(seeded):
    visit_id = make_visit(seeded, "P003")
    session.handle_message(seeded, SIM, visit_id, "I have a private cough")
    log = events(seeded, visit_id)
    assert log == [("ai.turn", {"source": "simulated", "questions_asked": 2, "done": False})]


def test_a_dependent_uses_their_own_record(seeded):
    visit_id = make_visit(seeded, "P004", booked_by="P001")
    client = FakeChatClient(["Since when?"])
    session.handle_message(seeded, real(client), visit_id, "she has a cough")
    system = client.calls[0]["messages"][0]["content"]
    assert '"allergies": []' in system
    assert "penicillin" not in system
    assert '"age": 7' in system


def test_a_dependent_summary_uses_their_age(seeded):
    visit_id = make_visit(seeded, "P004", booked_by="P001")
    for text in ("حرارة من يومين", "٥", "لا", "لا"):
        result = session.handle_message(seeded, SIM, visit_id, text)
    assert result.done
    assert result.intake["summary_for_nurse"].startswith("7F, 2 days fever")


def test_the_model_is_not_called_inside_a_transaction(seeded):
    visit_id = make_visit(seeded, "P001")
    seen = []

    class Spy(FakeChatClient):
        def chat_completion(self, messages, **kw):
            seen.append(seeded.in_transaction)
            return super().chat_completion(messages, **kw)

    session.handle_message(seeded, real(Spy(["Since when?"])), visit_id, "I have a cough")
    assert seen == [False]


def test_another_writer_gets_through_during_the_model_call(seeded, db_path):
    visit_id = make_visit(seeded, "P001")

    class Writer(FakeChatClient):
        def chat_completion(self, messages, **kw):
            other = db.connect(db_path)
            other.execute("PRAGMA busy_timeout=0")
            with db.transaction(other):
                other.execute("UPDATE visit SET service = 'probe' WHERE id = ?", (visit_id,))
            other.close()
            return super().chat_completion(messages, **kw)

    session.handle_message(seeded, real(Writer(["Since when?"])), visit_id, "I have a cough")
    assert visit_service(seeded, visit_id) == "probe"


def test_an_emergency_landing_during_the_model_call_wins(seeded, db_path):
    visit_id = make_visit(seeded, "P001")

    class Racer(FakeChatClient):
        def chat_completion(self, messages, **kw):
            other = db.connect(db_path)
            session.handle_message(other, SIM, visit_id, "I can't breathe")
            other.close()
            return super().chat_completion(messages, **kw)

    client = Racer([intake_json()])
    result = session.handle_message(seeded, real(client), visit_id, "I have a cough")
    assert result.emergency
    assert result.intake is None
    assert stored_json(seeded, visit_id) == "{}"
    assert visit_status(seeded, visit_id) == "redirected_emergency"


def test_a_model_emergency_cannot_replace_self_harm_landing_during_the_call(seeded, db_path):
    visit_id = make_visit(seeded, "P003")

    class Racer(FakeChatClient):
        def chat_completion(self, messages, **kw):
            other = db.connect(db_path)
            session.handle_message(other, SIM, visit_id, SELF_HARM)
            other.close()
            return super().chat_completion(messages, **kw)

    client = Racer(['{"emergency": true}'])
    result = session.handle_message(seeded, real(client), visit_id, "I feel strange")
    assert result.self_harm
    assert result.reply == simulated.emergency_reply("en", True)
    assert users_said(seeded, visit_id) == [SELF_HARM]
    assert session.handle_message(seeded, SIM, visit_id, "hello there").self_harm


def test_self_harm_landing_on_an_emergency_set_meanwhile_is_stored(seeded, db_path, monkeypatch):
    visit_id = make_visit(seeded, "P003")
    original = session.receptionist.run_turn

    def racing(*args, **kwargs):
        monkeypatch.setattr(session.receptionist, "run_turn", original)
        other = db.connect(db_path)
        session.handle_message(other, SIM, visit_id, "I can't breathe")
        other.close()
        return original(*args, **kwargs)

    monkeypatch.setattr(session.receptionist, "run_turn", racing)
    result = session.handle_message(seeded, SIM, visit_id, SELF_HARM)
    assert result.self_harm
    assert users_said(seeded, visit_id) == ["I can't breathe", SELF_HARM]
    assert session.handle_message(seeded, SIM, visit_id, "hello there").reply == result.reply


def test_a_deflection_landing_during_the_call_cannot_block_an_emergency(seeded, db_path):
    visit_id = make_visit(seeded, "P002")

    class Racer(FakeChatClient):
        def chat_completion(self, messages, **kw):
            other = db.connect(db_path)
            session.handle_message(other, SIM, visit_id, "I need my usual blood pressure pills")
            other.close()
            return super().chat_completion(messages, **kw)

    client = Racer(['{"emergency": true}'])
    result = session.handle_message(seeded, real(client), visit_id, "I feel strange")
    assert result.emergency
    assert visit_status(seeded, visit_id) == "redirected_emergency"


@pytest.mark.parametrize("reply", ['{"emergency": true}', 'not json "emergency": true {'])
def test_a_reservation_during_the_call_cannot_block_an_emergency(
    seeded, engine, clock, reply
):
    visit_id = make_visit(seeded, "P001")
    tickets = []

    class Racer(FakeChatClient):
        def chat_completion(self, messages, **kw):
            tickets.append(engine.issue_ticket(visit_id, "C-WAKRA-T1"))
            return super().chat_completion(messages, **kw)

    result = session.handle_message(seeded, real(Racer([reply])), visit_id, "I feel strange")
    assert result.emergency
    assert visit_status(seeded, visit_id) == "redirected_emergency"

    with pytest.raises(VisitNotEligible):
        engine.activate(tickets[0].id)
    live = seeded.execute(
        "SELECT COUNT(*) FROM ticket WHERE visit_id = ? "
        "AND state IN ('active', 'called', 'serving')",
        (visit_id,),
    ).fetchone()[0]
    assert live == 0

    clock.advance(minutes=46)
    engine.expire_due()
    assert visit_status(seeded, visit_id) == "redirected_emergency"


REFILL_REPLY = "How long have you had this?"


@pytest.mark.parametrize("mode", ["simulated", "real"])
def test_an_earlier_symptom_keeps_the_chat_going_past_a_refill_request(seeded, mode):
    visit_id = make_visit(seeded, "P002")
    client = FakeChatClient([REFILL_REPLY, REFILL_REPLY])
    ai = SIM if mode == "simulated" else real(client)
    session.handle_message(seeded, ai, visit_id, "I have a cough")
    result = session.handle_message(
        seeded, ai, visit_id, "I need a refill of my blood pressure tablets"
    )
    assert result.refill is None
    assert not result.done
    assert visit_status(seeded, visit_id) == "intake"
    assert "refill.detected" not in event_types(seeded, visit_id)
    assert len(client.calls) == (0 if mode == "simulated" else 2)


@pytest.mark.parametrize("mode", ["simulated", "real"])
@pytest.mark.parametrize(
    "text",
    [
        "I want to stop my usual blood pressure pills",
        "need to change my usual blood pressure pills",
        "I need to ask about my usual blood pressure pills",
        "I need to know if my usual blood pressure pills are safe",
        "أبي أوقف حبوب الضغط المعتادة",
    ],
)
def test_a_question_about_a_medicine_stays_in_the_chat(seeded, mode, text):
    visit_id = make_visit(seeded, "P002")
    ai = SIM if mode == "simulated" else real(FakeChatClient([REFILL_REPLY]))
    result = session.handle_message(seeded, ai, visit_id, text)
    assert result.refill is None
    assert visit_status(seeded, visit_id) == "intake"


@pytest.mark.parametrize(
    "text",
    [
        "I need my usual blood pressure pills",
        "I need my usual blood pressure tablets.",
        "أبي حبوب الضغط المعتادة",
        "I ran out of my blood pressure pills",
    ],
)
def test_a_plain_refill_still_deflects(seeded, text):
    visit_id = make_visit(seeded, "P002")
    result = session.handle_message(seeded, SIM, visit_id, text)
    assert result.refill == {"medicine": "amlodipine 5 mg once daily"}
    assert visit_status(seeded, visit_id) == "deflected_refill"


def test_a_status_change_during_the_model_call_refuses_the_turn(seeded, db_path):
    visit_id = make_visit(seeded, "P001")

    class Racer(FakeChatClient):
        def chat_completion(self, messages, **kw):
            other = db.connect(db_path)
            other.execute("UPDATE visit SET status = 'reserved' WHERE id = ?", (visit_id,))
            other.close()
            return super().chat_completion(messages, **kw)

    with pytest.raises(SessionError) as error:
        session.handle_message(seeded, real(Racer(["Since when?"])), visit_id, "I have a cough")
    assert error.value.code == "visit_not_in_intake"
    assert not seeded.in_transaction
    assert seeded.execute("SELECT COUNT(*) FROM intake").fetchone()[0] == 0


def test_concurrent_messages_append_rather_than_overwrite(seeded, db_path):
    visit_id = make_visit(seeded, "P001")

    class Racer(FakeChatClient):
        def chat_completion(self, messages, **kw):
            other = db.connect(db_path)
            session.handle_message(other, SIM, visit_id, "second message")
            other.close()
            return super().chat_completion(messages, **kw)

    session.handle_message(seeded, real(Racer(["Since when?"])), visit_id, "first message")
    said = [m["content"] for m in transcript(seeded, visit_id)["messages"] if m["role"] == "user"]
    assert sorted(said) == ["first message", "second message"]


def test_session_error_carries_the_code():
    error = SessionError("visit_not_found")
    assert error.code == "visit_not_found"
    assert str(error) == "visit_not_found"


STAFF_KEYS = {
    "status",
    "language",
    "turns",
    "patient_words",
    "denied",
    "denied_text",
    "intake",
    "confirmed_by_patient",
    "edited",
}
DROPPED_DETAIL = "Yesterday I saw some blood in my spit"
LEFT_OUT_SUMMARY = "45M, cough for 2 days."


def finished_with_a_dropped_detail(conn, mode):
    """A finished visit whose second message holds a detail the model's summary leaves out."""
    visit_id = make_visit(conn, "P003")
    if mode == "simulated":
        ai, texts = SIM, ("I have a cough for 2 days", "5", "no", "no", DROPPED_DETAIL)
    else:
        client = FakeChatClient(["How bad is it?", intake_json(summary_for_nurse=LEFT_OUT_SUMMARY)])
        ai, texts = real(client), ("I have a cough", DROPPED_DETAIL)
    for text in texts:
        result = session.handle_message(conn, ai, visit_id, text)
    assert result.done
    return visit_id, result


def row_counts(conn):
    return tuple(
        conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        for table in ("intake", "event", "visit", "ticket")
    )


def stored_rows(conn, visit_id):
    intake_rows = conn.execute("SELECT * FROM intake WHERE visit_id = ?", (visit_id,)).fetchall()
    event_rows = conn.execute("SELECT * FROM event WHERE visit_id = ?", (visit_id,)).fetchall()
    return [tuple(row) for row in intake_rows], [tuple(row) for row in event_rows]


def test_staff_see_the_exact_sentence_a_model_summary_left_out(seeded):
    visit_id, result = finished_with_a_dropped_detail(seeded, "real")
    assert result.source == "model"
    stored = json.loads(stored_json(seeded, visit_id))
    assert stored["summary_for_nurse"] == LEFT_OUT_SUMMARY
    assert "blood" not in json.dumps(stored).lower()

    view = session.staff_view(seeded, visit_id)
    assert set(view) == STAFF_KEYS
    assert view["intake"]["summary_for_nurse"] == LEFT_OUT_SUMMARY
    assert DROPPED_DETAIL in view["patient_words"]
    assert {"role": "patient", "text": DROPPED_DETAIL} in view["turns"]


@pytest.mark.parametrize("mode", ["simulated", "real"])
def test_staff_turns_are_the_whole_chat_in_order(seeded, mode):
    visit_id, result = finished_with_a_dropped_detail(seeded, mode)
    view = session.staff_view(seeded, visit_id)
    messages = transcript(seeded, visit_id)["messages"]
    named = {"user": "patient", "assistant": "receptionist"}
    assert view["turns"] == [{"role": named[m["role"]], "text": m["content"]} for m in messages]
    assert view["turns"][0] == {"role": "receptionist", "text": simulated.OPENING["en"]}
    assert view["turns"][-1] == {"role": "receptionist", "text": result.reply}
    assert view["patient_words"] == [m["content"] for m in messages if m["role"] == "user"]
    assert DROPPED_DETAIL in view["patient_words"]
    assert all(set(turn) == {"role", "text"} for turn in view["turns"])
    assert view["status"] == "intake"
    assert view["language"] == "en"
    assert view["intake"] == json.loads(stored_json(seeded, visit_id))
    assert "summary_for_nurse" in view["intake"]
    assert view["confirmed_by_patient"] is False
    assert view["edited"] is False


ARABIC_WITH_MARKS = "عِنْدِي كُحَّةٌ مِنْ يَوْمَيْنِ وَرَأْسِي يُؤْلِمُنِي قَلِيلًا"
ARABIC_WITH_TATWEEL = "الكــحة زادت في الليل، والصوت مبحوح"


@pytest.mark.parametrize("mode", ["simulated", "real"])
@pytest.mark.parametrize("text", [ARABIC_WITH_MARKS, ARABIC_WITH_TATWEEL])
def test_staff_get_arabic_back_byte_for_byte(seeded, mode, text):
    visit_id = make_visit(seeded, "P001")
    ai = SIM if mode == "simulated" else real(FakeChatClient(["منذ متى؟"]))
    session.handle_message(seeded, ai, visit_id, text)
    view = session.staff_view(seeded, visit_id)
    assert view["language"] == "ar"
    assert view["patient_words"] == [text]
    assert view["patient_words"][0].encode("utf-8") == text.encode("utf-8")
    assert view["turns"][1] == {"role": "patient", "text": text}


@pytest.mark.parametrize("mode", ["simulated", "real"])
def test_a_nurse_edit_changes_the_intake_and_not_the_patients_words(seeded, mode):
    visit_id, _ = finished_with_a_dropped_detail(seeded, mode)
    before = session.staff_view(seeded, visit_id)
    edit = {**before["intake"], "summary_for_nurse": "Nurse: blood in spit, see doctor."}
    seeded.execute(
        "UPDATE intake SET edited_json = ? WHERE visit_id = ?",
        (json.dumps(edit), visit_id),
    )
    after = session.staff_view(seeded, visit_id)
    assert before["edited"] is False
    assert after["edited"] is True
    assert after["intake"] == edit
    assert after["turns"] == before["turns"]
    assert after["patient_words"] == before["patient_words"]


@pytest.mark.parametrize("blank", ["", "  \n", None])
def test_a_blank_edit_is_not_an_edit(seeded, blank):
    visit_id, _ = finished_with_a_dropped_detail(seeded, "simulated")
    seeded.execute("UPDATE intake SET edited_json = ? WHERE visit_id = ?", (blank, visit_id))
    view = session.staff_view(seeded, visit_id)
    assert view["edited"] is False
    assert view["intake"] == json.loads(stored_json(seeded, visit_id))


def test_staff_see_that_the_patient_confirmed(seeded):
    visit_id, _ = finished_with_a_dropped_detail(seeded, "simulated")
    seeded.execute("UPDATE intake SET confirmed_by_patient = 1 WHERE visit_id = ?", (visit_id,))
    assert session.staff_view(seeded, visit_id)["confirmed_by_patient"] is True


@pytest.mark.parametrize("mode", ["simulated", "real"])
def test_staff_see_a_denied_cue(seeded, mode):
    visit_id = make_visit(seeded, "P003")
    ai = SIM if mode == "simulated" else real(FakeChatClient(["Since when?"]))
    session.handle_message(seeded, ai, visit_id, "I have no chest pain")
    view = session.staff_view(seeded, visit_id)
    assert view["denied"] == ["chest pain"]
    assert view["denied_text"] == "Patient denied: chest pain"
    assert view["patient_words"] == ["I have no chest pain"]


def test_nothing_denied_gives_an_empty_line(seeded):
    visit_id = make_visit(seeded, "P003")
    session.handle_message(seeded, SIM, visit_id, "I have a cough")
    view = session.staff_view(seeded, visit_id)
    assert view["denied"] == []
    assert view["denied_text"] == ""


@pytest.mark.parametrize("mode", ["simulated", "real"])
def test_an_emergency_visit_keeps_its_turns(seeded, mode):
    text = "I have been vomiting with blood in it yesterday"
    client = FakeChatClient([])
    visit_id = make_visit(seeded, "P003")
    ai = SIM if mode == "simulated" else real(client)
    result = session.handle_message(seeded, ai, visit_id, text)
    assert result.emergency
    assert client.calls == []
    view = session.staff_view(seeded, visit_id)
    assert view["status"] == "redirected_emergency"
    assert view["patient_words"] == [text]
    assert view["turns"] == [
        {"role": "receptionist", "text": simulated.OPENING["en"]},
        {"role": "patient", "text": text},
        {"role": "receptionist", "text": result.reply},
    ]
    assert view["intake"] is None


def test_a_refused_message_reaches_staff_with_no_reply_after_it(seeded):
    visit_id = make_visit(seeded, "P002")
    first = "I need my usual blood pressure pills"
    assert session.handle_message(seeded, SIM, visit_id, first).refill
    with pytest.raises(SessionError) as error:
        session.handle_message(seeded, SIM, visit_id, "the pain came back")
    assert error.value.code == "visit_not_in_intake"
    view = session.staff_view(seeded, visit_id)
    assert view["status"] == "deflected_refill"
    assert view["patient_words"] == [first, "the pain came back"]
    assert view["turns"][-1] == {"role": "patient", "text": "the pain came back"}
    assert view["turns"][-2]["role"] == "receptionist"


@pytest.mark.parametrize("status", ["reserved", "expired"])
def test_a_refused_message_on_a_ticket_visit_reaches_staff(seeded, status):
    visit_id = make_visit(seeded, "P003", status=status)
    with pytest.raises(SessionError):
        session.handle_message(seeded, SIM, visit_id, "the pain came back")
    view = session.staff_view(seeded, visit_id)
    assert view["status"] == status
    assert view["patient_words"] == ["the pain came back"]
    assert view["turns"][-1] == {"role": "patient", "text": "the pain came back"}


@pytest.mark.parametrize(("patient", "lang"), [("P001", "ar"), ("P003", "en")])
def test_a_visit_with_no_message_shows_the_opening_and_creates_no_row(seeded, patient, lang):
    visit_id = make_visit(seeded, patient)
    before = row_counts(seeded)
    view = session.staff_view(seeded, visit_id)
    assert view == {
        "status": "intake",
        "language": lang,
        "turns": [{"role": "receptionist", "text": simulated.OPENING[lang]}],
        "patient_words": [],
        "denied": [],
        "denied_text": "",
        "intake": None,
        "confirmed_by_patient": False,
        "edited": False,
    }
    assert row_counts(seeded) == before
    rows = seeded.execute("SELECT COUNT(*) FROM intake WHERE visit_id = ?", (visit_id,))
    assert rows.fetchone()[0] == 0


@pytest.mark.parametrize("mode", ["simulated", "real"])
def test_staff_view_writes_nothing(seeded, mode):
    visit_id, _ = finished_with_a_dropped_detail(seeded, mode)
    counts, rows, written = row_counts(seeded), stored_rows(seeded, visit_id), seeded.total_changes
    first = session.staff_view(seeded, visit_id)
    assert session.staff_view(seeded, visit_id, on=date(2026, 11, 7)) == first
    assert row_counts(seeded) == counts
    assert stored_rows(seeded, visit_id) == rows
    assert seeded.total_changes == written
    assert not seeded.in_transaction


@pytest.mark.parametrize("started", [False, True])
def test_staff_view_runs_on_a_connection_that_refuses_writes(seeded, started):
    visit_id = make_visit(seeded, "P003")
    if started:
        session.handle_message(seeded, SIM, visit_id, "I have no chest pain")
    seeded.execute("PRAGMA query_only = ON")
    assert session.staff_view(seeded, visit_id)["status"] == "intake"


def test_staff_view_of_an_unknown_visit(seeded):
    with pytest.raises(SessionError) as error:
        session.staff_view(seeded, "V_nope")
    assert error.value.code == "visit_not_found"


def test_staff_view_with_a_missing_patient_row_matches_history(seeded):
    seeded.execute("PRAGMA foreign_keys = OFF")
    visit_id = make_visit(seeded, "P_gone")
    for read in (session.history, session.staff_view):
        with pytest.raises(SessionError) as error:
            read(seeded, visit_id)
        assert error.value.code == "visit_not_found"


@pytest.mark.parametrize("mode", ["simulated", "real"])
def test_the_patient_side_stays_closed_after_staff_read(seeded, mode):
    visit_id, result = finished_with_a_dropped_detail(seeded, mode)
    before = session.history(seeded, visit_id)
    staff = session.staff_view(seeded, visit_id)
    assert "summary_for_nurse" in staff["intake"]

    after = session.history(seeded, visit_id)
    assert after == before
    assert set(after) == {"messages", "denied", "language", "last_turn", "status", "intake"}
    for shown in (after, result.to_api()):
        said = json.dumps(shown, ensure_ascii=False)
        assert "summary_for_nurse" not in said
        assert staff["intake"]["summary_for_nurse"] not in said
