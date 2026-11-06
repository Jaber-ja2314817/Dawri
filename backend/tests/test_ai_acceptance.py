"""The vault's acceptance sentences, driven through session.handle_message."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from backend.adapters.queue_base import VisitNotEligible
from backend.ai import filters, handoff, intake, session, simulated
from backend.ai.asr import Asr
from backend.ai.llm import Llm
from backend.ai.runtime import AiRuntime
from backend.ai.text import has_arabic, normalise
from backend.tests.ai_fakes import FakeChatClient
from backend.tests.conftest import make_visit

ASR = Asr(mode="simulated", model_id="simulated")
SIM = AiRuntime(llm=Llm(mode="simulated", model_id="simulated"), asr=ASR)
TRIAGE = "C-WAKRA-T1"
FATIMA_AR = "عندي حرارة وكحة من ثلاث أيام"
FATIMA_EN = "I have had a fever and cough for three days"
RAVI = (
    "Chest pain spreading to my arm",
    "Chest pain going to my left arm.",
    "عندي ألم في الصدر ينتشر إلى ذراعي",
)
AHMED = (
    "I need my usual blood pressure pills",
    "I need my usual blood pressure tablets.",
    "أبي حبوب الضغط المعتادة",
)
AHMED_MED = "amlodipine 5 mg once daily"


def real(client):
    return AiRuntime(llm=Llm(mode="real", model_id="test", client=client), asr=ASR)


def intake_json(**changes):
    base = {
        "emergency": False,
        "language": "ar-gulf",
        "chief_complaint": "fever and cough",
        "chief_complaint_patient_words": "x",
        "duration": "3 days",
        "severity_0_10": 6,
        "associated": ["cough"],
        "self_medication": ["paracetamol"],
        "service": "gp",
        "service_confidence": 0.9,
        "summary_for_nurse": "34F, 3 days fever and cough, severity 6/10, took paracetamol.",
        "refill_request": None,
        "questions_asked": 4,
    }
    return json.dumps({**base, **changes}, ensure_ascii=False)


# For a patient who named no drug: a model intake naming one would be refused.
NO_DRUG = {"self_medication": [], "summary_for_nurse": "34F, 3 days fever and cough."}


def say(conn, ai, visit_id, *messages):
    result = None
    for message in messages:
        result = session.handle_message(conn, ai, visit_id, message)
    return result


def visit_status(conn, visit_id):
    return conn.execute("SELECT status FROM visit WHERE id = ?", (visit_id,)).fetchone()[0]


def ticket_count(conn):
    return conn.execute("SELECT COUNT(*) FROM ticket").fetchone()[0]


def stored_text(conn, visit_id):
    return conn.execute("SELECT transcript FROM intake WHERE visit_id = ?", (visit_id,)).fetchone()[0]


def fallbacks(conn, visit_id):
    rows = conn.execute(
        "SELECT payload FROM event WHERE visit_id = ? AND type = 'ai.fallback' ORDER BY id",
        (visit_id,),
    ).fetchall()
    return [json.loads(row[0]) for row in rows]


def question_total(conn, visit_id):
    state = session.history(conn, visit_id)
    return simulated.question_count(state["messages"])


@pytest.mark.parametrize(
    "answers",
    [(FATIMA_AR, "٦", "بنادول", "لا"), (FATIMA_EN, "6", "paracetamol", "no")],
    ids=["ar", "en"],
)
def test_fatima_simulated_reaches_a_gp_intake_and_a_ticket(seeded, engine, answers):
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, SIM, visit_id, *answers)
    assert result.done
    assert result.source == "simulated"
    validated = intake.validate_intake(result.intake)
    assert validated.service == "gp"
    assert validated.duration == "3 days"
    assert validated.questions_asked == 4
    assert validated.summary_for_nurse == (
        "34F, 3 days fever and cough, severity 6/10, took paracetamol."
    )
    ticket = engine.issue_ticket(visit_id, TRIAGE)
    assert ticket.state == "reserved"


@pytest.mark.parametrize("first", [FATIMA_AR, FATIMA_EN], ids=["ar", "en"])
def test_fatima_real_reaches_a_gp_intake_and_a_ticket(seeded, engine, first):
    visit_id = make_visit(seeded, "P001")
    client = FakeChatClient(["كم شدته؟", "أخذت أي دوا؟", intake_json()])
    first_turn = session.handle_message(seeded, real(client), visit_id, first)
    assert first_turn.source == "model"
    result = say(seeded, real(client), visit_id, "٦", "بنادول")
    assert result.done
    assert result.source == "model"
    assert result.intake["duration"] == "3 days"
    assert result.intake["questions_asked"] == 3
    assert result.intake["chief_complaint_patient_words"] == first
    system = client.calls[0]["messages"][0]["content"]
    assert "You are NOT a doctor or nurse." in system
    assert '"age": 34' in system
    assert "Fatima" not in system
    assert "فاطمة" not in system
    assert "DEMO-10001" not in system
    assert engine.issue_ticket(visit_id, TRIAGE).state == "reserved"


@pytest.mark.parametrize("sentence", RAVI)
@pytest.mark.parametrize("mode", ["simulated", "real"])
def test_ravi_gets_an_emergency_and_no_ticket(seeded, engine, sentence, mode):
    client = FakeChatClient([intake_json()])
    ai = SIM if mode == "simulated" else real(client)
    visit_id = make_visit(seeded, "P003")
    result = session.handle_message(seeded, ai, visit_id, sentence)
    assert result.emergency
    assert result.source == "rules"
    assert result.reply == simulated.emergency_reply(result.language, False)
    assert client.calls == []
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    before = ticket_count(seeded)
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, TRIAGE)
    assert ticket_count(seeded) == before


@pytest.mark.parametrize("mode", ["simulated", "real"])
@pytest.mark.parametrize(
    ("lang", "opening", "answer"),
    [
        ("en", ("my baby is sick", "today", "6"), "high"),
        ("en", ("my baby is sick", "today", "6"), "very high"),
        ("en", ("my baby is sick", "today", "6"), "it is high"),
        ("ar", ("طفلي مريض", "اليوم", "6"), "عالية"),
        ("ar", ("طفلي مريض", "اليوم", "6"), "عالية جدا"),
        ("ar", ("طفلي مريض", "اليوم", "6"), "مرتفعة"),
    ],
)
def test_a_baby_with_a_high_fever_gets_no_ticket(seeded, engine, mode, lang, opening, answer):
    """The red line, across the model's own fever question, with no yes word in it."""
    question = simulated.FOLLOW_UPS["fever"][lang]
    client = FakeChatClient(
        [simulated.QUESTIONS["duration"][lang], simulated.QUESTIONS["severity"][lang], question]
    )
    ai = SIM if mode == "simulated" else real(client)
    visit_id = make_visit(seeded, "P001")
    assert say(seeded, ai, visit_id, *opening).reply == question
    assert visit_status(seeded, visit_id) == "intake"
    calls = len(client.calls)
    before = ticket_count(seeded)

    result = session.handle_message(seeded, ai, visit_id, answer)

    assert result.emergency
    assert result.source == "rules"
    assert result.reply == simulated.emergency_reply(result.language, False)
    assert len(client.calls) == calls
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    rows = seeded.execute(
        "SELECT payload FROM event WHERE visit_id = ? AND type = 'redflag.hit'", (visit_id,)
    ).fetchall()
    assert [json.loads(row[0])["label"] for row in rows] == ["baby with high fever"]
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, TRIAGE)
    assert ticket_count(seeded) == before


def test_an_emergency_stays_sticky_afterwards(seeded, engine):
    client = FakeChatClient([intake_json()])
    visit_id = make_visit(seeded, "P003")
    session.handle_message(seeded, real(client), visit_id, RAVI[1])
    result = session.handle_message(seeded, real(client), visit_id, "I feel fine now, I have a cough")
    assert result.emergency
    assert client.calls == []
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, TRIAGE)


@pytest.mark.parametrize("mode", ["simulated", "real"])
def test_severe_chest_pain_in_arabic_gets_no_ticket(seeded, engine, mode):
    client = FakeChatClient([])
    ai = SIM if mode == "simulated" else real(client)
    visit_id = make_visit(seeded, "P001")
    before = ticket_count(seeded)
    result = say(seeded, ai, visit_id, "عندي ألم شديد في الصدر")
    assert result.emergency
    assert result.source == "rules"
    assert client.calls == []
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, TRIAGE)
    assert ticket_count(seeded) == before


def test_self_harm_after_an_emergency_adds_the_support_with_no_model(seeded, engine):
    client = FakeChatClient([])
    visit_id = make_visit(seeded, "P003")
    say(seeded, real(client), visit_id, RAVI[1])
    result = say(seeded, real(client), visit_id, "I want to end my life")
    assert result.self_harm
    assert "999" in result.reply
    assert "talk to someone" in result.reply
    assert client.calls == []
    assert say(seeded, real(client), visit_id, "thank you").reply == result.reply
    assert "I want to end my life" in stored_text(seeded, visit_id)
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, TRIAGE)


@pytest.mark.parametrize("sentence", ["I can't breathe", "عندي ألم شديد في الصدر"])
def test_a_red_flag_after_a_refill_deflection_gets_no_ticket(seeded, engine, sentence):
    client = FakeChatClient([])
    visit_id = make_visit(seeded, "P002")
    say(seeded, real(client), visit_id, AHMED[0])
    before = ticket_count(seeded)
    result = say(seeded, real(client), visit_id, sentence)
    assert result.emergency
    assert result.source == "rules"
    assert client.calls == []
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, TRIAGE)
    assert ticket_count(seeded) == before


def test_a_clear_message_after_a_refill_deflection_is_refused(seeded):
    client = FakeChatClient([])
    visit_id = make_visit(seeded, "P002")
    say(seeded, real(client), visit_id, AHMED[0])
    with pytest.raises(session.SessionError) as error:
        say(seeded, real(client), visit_id, "thank you very much")
    assert error.value.code == "visit_not_in_intake"
    assert client.calls == []


PROSE = "هذه حالة طارئة، اتصل على 999 الآن."


@pytest.mark.parametrize(
    "replies",
    [[PROSE], ['{"language": "en"}', PROSE]],
    ids=["first_reply", "retry"],
)
def test_a_model_saying_emergency_in_words_gets_no_ticket(seeded, engine, replies):
    client = FakeChatClient(replies)
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, real(client), visit_id, FATIMA_AR)
    assert result.emergency
    assert result.source == "model"
    assert result.reply == simulated.emergency_reply("ar", False)
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    assert len(client.calls) == len(replies)
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, TRIAGE)
    again = say(seeded, real(client), visit_id, "شكرا لك")
    assert again.emergency
    assert again.source == "model"
    assert len(client.calls) == len(replies)


def test_a_model_saying_not_an_emergency_goes_on(seeded):
    client = FakeChatClient(["This is not an emergency. How long have you had it?"])
    visit_id = make_visit(seeded, "P003")
    result = say(seeded, real(client), visit_id, "I have a cough")
    assert not result.emergency
    assert visit_status(seeded, visit_id) == "intake"


@pytest.mark.parametrize(
    "bad",
    [
        {"duration": "3 days, likely influenza"},
        {"self_medication": ["paracetamol 1000 mg"]},
        {"patient_concerns": "you have pneumonia"},
        {"associated": ["influenza"]},
    ],
)
def test_a_bad_free_field_ends_in_the_fallback(seeded, bad):
    output = intake_json(**bad)
    client = FakeChatClient([output, output])
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, real(client), visit_id, FATIMA_AR)
    assert result.source == "simulated"
    assert [event["reason"] for event in fallbacks(seeded, visit_id)] == ["invalid_json"]
    assert "influenza" not in stored_text(seeded, visit_id)
    assert "pneumonia" not in stored_text(seeded, visit_id)
    assert "1000" not in stored_text(seeded, visit_id)


def test_the_fatima_model_intake_with_paracetamol_stays_model(seeded):
    client = FakeChatClient([intake_json(self_medication=["paracetamol"])])
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, real(client), visit_id, f"{FATIMA_AR} وأخذت بنادول")
    assert result.done
    assert result.source == "model"
    assert result.intake["self_medication"] == ["paracetamol"]


def stored_intake(conn, visit_id):
    return conn.execute("SELECT json FROM intake WHERE visit_id = ?", (visit_id,)).fetchone()[0]


def assert_never_reached_anyone(conn, visit_id, result, word):
    assert word not in result.reply
    assert word not in stored_intake(conn, visit_id)
    assert word not in stored_text(conn, visit_id)


@pytest.mark.parametrize(
    ("drug", "summary"),
    [
        ("amoxicillin", "34F, cough, amoxicillin twice daily."),
        ("amoxicillin", "amoxicillin is best."),
        ("azithromycin", "azithromycin for this cough."),
        ("ibuprofen", "ibuprofen three times a day would work."),
    ],
)
def test_the_model_cannot_allow_a_drug_the_patient_never_said(seeded, drug, summary):
    output = intake_json(self_medication=[drug], summary_for_nurse=summary)
    client = FakeChatClient([output, output])
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, real(client), visit_id, "I have a cough")
    assert len(client.calls) == 2
    assert result.source == "simulated"
    assert_never_reached_anyone(seeded, visit_id, result, drug)
    assert fallbacks(seeded, visit_id)[0]["reason"] == "invalid_json"


def test_an_arabic_drug_from_the_model_never_reaches_the_reply(seeded):
    drug = "أموكسيسيلين مرتين يوميا"
    output = intake_json(self_medication=[drug], summary_for_nurse="34F, cough.")
    client = FakeChatClient([output, output])
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, real(client), visit_id, "عندي كحة")
    assert result.source == "simulated"
    assert_never_reached_anyone(seeded, visit_id, result, "أموكسيسيلين")
    assert fallbacks(seeded, visit_id)[0]["reason"] == "invalid_json"


def test_the_patients_own_drug_reads_back_from_the_model_path(seeded):
    output = intake_json(
        self_medication=["paracetamol"], summary_for_nurse="34F, cough, took paracetamol."
    )
    client = FakeChatClient([output])
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, real(client), visit_id, "I took panadol for my cough")
    assert result.done
    assert result.source == "model"
    assert "took paracetamol" in result.reply
    assert result.intake["self_medication"] == ["paracetamol"]
    assert fallbacks(seeded, visit_id) == []


def test_a_drug_only_a_word_on_no_list_cannot_reach_self_medication(seeded):
    """check_handoff cannot know zorblax, so this rests on the server's override."""
    output = intake_json(self_medication=["zorblax"], summary_for_nurse="34F, cough.")
    client = FakeChatClient([output])
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, real(client), visit_id, "I took panadol for my cough")
    assert result.done
    assert result.intake["self_medication"] == ["paracetamol"]
    assert "zorblax" not in result.reply


def test_the_model_cannot_add_to_what_the_patient_took(seeded):
    output = intake_json(
        self_medication=["paracetamol", "amoxicillin"],
        summary_for_nurse="34F, cough, took paracetamol and amoxicillin.",
    )
    client = FakeChatClient([output, output])
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, real(client), visit_id, "I took panadol for my cough")
    assert result.source == "simulated"
    assert_never_reached_anyone(seeded, visit_id, result, "amoxicillin")


def test_a_wanted_drug_gives_the_model_no_permission(seeded):
    output = intake_json(
        self_medication=["amoxicillin"], summary_for_nurse="34F, cough, took amoxicillin."
    )
    client = FakeChatClient([output, output])
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, real(client), visit_id, "I have a cough and I want amoxicillin")
    assert result.source == "simulated"
    assert "took amoxicillin" not in result.reply
    assert "amoxicillin" not in stored_intake(seeded, visit_id)


def test_model_prose_stays_with_the_nurse_and_out_of_the_read_back(seeded):
    prose = "34F, cough, notes zorblax."
    client = FakeChatClient([intake_json(self_medication=[], summary_for_nurse=prose)])
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, real(client), visit_id, "I have a cough")
    assert result.done
    assert result.source == "model"
    assert result.intake["summary_for_nurse"] == prose
    assert "zorblax" not in result.reply
    assert "34F" not in result.reply


@pytest.mark.parametrize("reply", ["Maybe flu.", "Seems viral.", "Definitely strep."])
def test_a_bare_diagnosis_from_the_model_falls_back(seeded, reply):
    client = FakeChatClient([reply])
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, real(client), visit_id, "I have a cough")
    assert result.source == "simulated"
    assert result.reply != reply
    assert fallbacks(seeded, visit_id) == [
        {"surface": "chat", "reason": "banned_output", "mode": "real", "served_by": "simulated"}
    ]
    assert reply not in stored_text(seeded, visit_id)


@pytest.mark.parametrize(
    "reply",
    [
        "You have zorblax.",
        "zorblax is best.",
        "quelmora twice daily.",
        "zorblax?",
        "Is it zorblax?",
        "You have zorblax, right?",
        "When did your zorblax start?",
        "Thanks. zorblax would work.",
        "zorblax is best. Since when?",
        "عندك زوربلاكس.",
        "زوربلاكس هو الأفضل.",
        "من متى عندك زوربلاكس؟",
    ],
)
def test_an_unlisted_word_never_reaches_the_patient(seeded, reply):
    client = FakeChatClient([reply])
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, real(client), visit_id, "I have a cough")
    assert result.source == "simulated"
    assert result.reply == simulated.QUESTIONS["duration"]["en"]
    assert reply not in stored_text(seeded, visit_id)
    assert "zorblax" not in stored_text(seeded, visit_id)
    assert len(fallbacks(seeded, visit_id)) == 1
    assert fallbacks(seeded, visit_id)[0]["reason"] in ("banned_output", "bad_shape")


def test_the_model_returns_on_the_turn_after_the_gate(seeded):
    client = FakeChatClient(["zorblax is best.", "How bad is it from 0 to 10?"])
    ai = real(client)
    visit_id = make_visit(seeded, "P001")
    first = say(seeded, ai, visit_id, "I have a cough")
    second = say(seeded, ai, visit_id, "3 days")
    assert (first.source, second.source) == ("simulated", "model")
    assert second.reply == "How bad is it from 0 to 10?"
    assert fallbacks(seeded, visit_id)[0]["reason"] == "bad_shape"


def test_self_harm_gets_999_and_support(seeded):
    visit_id = make_visit(seeded, "P003")
    result = session.handle_message(seeded, SIM, visit_id, "I want to end my life")
    assert result.emergency
    assert result.self_harm
    assert "999" in result.reply
    assert "talk to someone" in result.reply


@pytest.mark.parametrize("sentence", AHMED)
@pytest.mark.parametrize("mode", ["simulated", "real"])
def test_ahmed_is_deflected_to_the_refill_line(seeded, engine, sentence, mode):
    client = FakeChatClient([])
    ai = SIM if mode == "simulated" else real(client)
    visit_id = make_visit(seeded, "P002")
    result = session.handle_message(seeded, ai, visit_id, sentence)
    assert result.refill == {"medicine": AHMED_MED}
    assert result.source == "rules"
    assert client.calls == []
    assert visit_status(seeded, visit_id) == "deflected_refill"
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, "C-RAYYAN-T1")


@pytest.mark.parametrize("sentence", AHMED)
def test_the_same_sentence_for_fatima_is_no_refill(seeded, sentence):
    visit_id = make_visit(seeded, "P001")
    result = session.handle_message(seeded, SIM, visit_id, sentence)
    assert result.refill is None
    assert visit_status(seeded, visit_id) == "intake"


def test_a_side_effect_for_ahmed_is_no_refill(seeded):
    visit_id = make_visit(seeded, "P002")
    result = session.handle_message(
        seeded, SIM, visit_id, "my usual blood pressure pills make me dizzy"
    )
    assert result.refill is None
    assert visit_status(seeded, visit_id) == "intake"


def test_i_still_want_a_visit_is_reservable(seeded, engine):
    visit_id = make_visit(seeded, "P002")
    session.handle_message(seeded, SIM, visit_id, AHMED[0])
    gp = session.continue_after_refill(seeded, visit_id)
    assert gp["service"] == "gp"
    assert intake.validate_intake(gp)
    assert engine.issue_ticket(visit_id, "C-RAYYAN-T1").state == "reserved"


@pytest.mark.parametrize("mode", ["simulated", "real"])
def test_denied_chest_pain_reaches_model_intake_and_summary(seeded, mode):
    client = FakeChatClient(["Since when?", intake_json(language="en")])
    ai = SIM if mode == "simulated" else real(client)
    visit_id = make_visit(seeded, "P003")
    result = session.handle_message(seeded, ai, visit_id, "no chest pain, I have a cough")
    assert not result.emergency
    assert result.denied == ["chest pain"]
    if mode == "simulated":
        result = say(seeded, ai, visit_id, "since yesterday", "5", "no", "no", "no")
    else:
        result = say(seeded, ai, visit_id, "since yesterday, I took panadol")
        assert "Patient denied: chest pain" in client.calls[0]["messages"][0]["content"]
        assert "Patient denied: chest pain" in client.calls[1]["messages"][0]["content"]
    assert result.done
    assert result.intake["denied_red_flags"] == ["chest pain"]
    assert "Patient denied: chest pain" in result.intake["summary_for_nurse"]


def test_a_rule_hit_makes_no_call_so_no_model_reply_can_clear_it(seeded):
    client = FakeChatClient(['{"emergency": false}', intake_json()])
    visit_id = make_visit(seeded, "P001")
    result = session.handle_message(seeded, real(client), visit_id, "I can't breathe")
    assert result.emergency
    assert client.calls == []


@pytest.mark.parametrize(
    "replies, reason",
    [
        ([TimeoutError("secret leaked here")], "model_error"),
        (["{broken", "{broken again"], "invalid_json"),
        (["You have the flu"], "banned_output"),
    ],
    ids=["timeout", "invalid", "banned"],
)
def test_each_fallback_serves_the_script_then_the_model_returns(seeded, replies, reason):
    client = FakeChatClient([*replies, "Since when?"])
    ai = real(client)
    visit_id = make_visit(seeded, "P003")
    fallback = session.handle_message(seeded, ai, visit_id, "I have a cough")
    assert fallback.source == "simulated"
    assert fallbacks(seeded, visit_id) == [
        {"surface": "chat", "reason": reason, "mode": "real", "served_by": "simulated"}
    ]
    assert "secret" not in str(fallbacks(seeded, visit_id))
    calls_so_far = len(client.calls)
    after = session.handle_message(seeded, ai, visit_id, "from two days")
    assert after.source == "model"
    assert len(client.calls) == calls_so_far + 1


def test_unquoted_emergency_replies_redirect_the_visit(seeded, engine):
    client = FakeChatClient(["{emergency: true}", "{emergency: true}"])
    visit_id = make_visit(seeded, "P003")
    tickets = ticket_count(seeded)
    result = say(seeded, real(client), visit_id, "I feel strange")
    assert result.emergency
    assert result.source == "model"
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, TRIAGE)
    assert ticket_count(seeded) == tickets


def test_an_unquoted_emergency_on_the_retry_redirects_the_visit(seeded):
    client = FakeChatClient(['{"broken": ', '{"is_emergency": yes}'])
    visit_id = make_visit(seeded, "P003")
    result = say(seeded, real(client), visit_id, "I feel strange")
    assert result.emergency
    assert len(client.calls) == 2
    assert visit_status(seeded, visit_id) == "redirected_emergency"


def test_a_gp_intake_stores_no_refill_text_from_the_model(seeded):
    bad = "You have the flu, take paracetamol 500 mg"
    client = FakeChatClient([intake_json(refill_request=bad)])
    visit_id = make_visit(seeded, "P003")
    result = say(seeded, real(client), visit_id, "I have a cough and I took panadol")
    assert result.done
    stored = seeded.execute("SELECT json FROM intake WHERE visit_id = ?", (visit_id,)).fetchone()[0]
    assert json.loads(stored)["refill_request"] is None
    assert bad not in stored
    assert bad not in stored_text(seeded, visit_id)


def test_seven_questions_in_one_reply_fall_back_and_the_model_returns(seeded):
    seven = "One? Two? Three? Four? Five? Six? Seven?"
    client = FakeChatClient([seven, "How long?"])
    ai = real(client)
    visit_id = make_visit(seeded, "P003")
    first = say(seeded, ai, visit_id, "I have a cough")
    assert first.source == "simulated"
    assert fallbacks(seeded, visit_id)[0]["reason"] == "multiple_questions"
    assert seven not in stored_text(seeded, visit_id)

    second = say(seeded, ai, visit_id, "two days")
    assert second.source == "model"
    assert len(client.calls) == 2


@pytest.mark.parametrize(
    "sentence",
    [
        "I took too many of my usual blood pressure pills",
        "My usual blood pressure tablets aren't working",
        "حبوب الضغط المعتادة ما تنفع",
    ],
)
def test_a_problem_with_a_medicine_is_no_refill(seeded, sentence):
    visit_id = make_visit(seeded, "P002")
    result = say(seeded, SIM, visit_id, sentence)
    assert result.refill is None
    assert visit_status(seeded, visit_id) == "intake"


def test_a_seventh_question_ends_in_an_intake(seeded):
    client = FakeChatClient(
        ["How long?", "How bad?", "Any fever?", "Any vomiting?", "Anything else?",
         "seventh?", "seventh again?"]
    )
    ai = real(client)
    visit_id = make_visit(seeded, "P003")
    result = say(seeded, ai, visit_id, "I have a cough", "a", "b", "c", "d", "e")
    assert result.done
    assert result.source == "simulated"
    assert result.intake["questions_asked"] == 6
    assert fallbacks(seeded, visit_id)[0]["reason"] == "question_cap"
    assert question_total(seeded, visit_id) == 6
    assert "seventh" not in stored_text(seeded, visit_id)


def test_a_failure_after_four_model_questions_stays_within_six(seeded):
    client = FakeChatClient(
        ["How long?", "How bad is it from 0 to 10?", "Any fever?", "Any medicine?",
         TimeoutError("down"), intake_json(language="en")]
    )
    ai = real(client)
    visit_id = make_visit(seeded, "P003")
    results = [
        session.handle_message(seeded, ai, visit_id, text)
        for text in ("I have a cough", "3 days", "6", "no", "panadol", "nothing")
    ]
    assert [r.source for r in results] == [
        "model", "model", "model", "model", "simulated", "model",
    ]
    assert results[4].reply == simulated.QUESTIONS["other"]["en"]
    assert results[-1].done
    assert results[-1].intake["questions_asked"] == 6
    assert question_total(seeded, visit_id) == 6


@pytest.mark.parametrize(
    "banned",
    [
        "You have the flu",
        "Take paracetamol 500 mg",
        "Your number is T-014",
        "عندك انفلونزا",
        "شكلك مصاب بالتهاب",
        "خذ بنادول",
        "رقمك 14",
        "عِنْدَكَ انفلونزا",
    ],
)
def test_banned_replies_never_reach_the_patient_or_the_transcript(seeded, banned):
    client = FakeChatClient([banned])
    visit_id = make_visit(seeded, "P003")
    result = session.handle_message(seeded, real(client), visit_id, "I have a cough")
    assert result.source == "simulated"
    assert banned not in result.reply
    assert banned not in stored_text(seeded, visit_id)


def test_a_model_refill_with_no_match_becomes_gp(seeded):
    client = FakeChatClient([intake_json(service="refill", refill_request="vitamin d", **NO_DRUG)])
    visit_id = make_visit(seeded, "P001")
    result = session.handle_message(seeded, real(client), visit_id, "I need more vitamins please")
    assert result.intake["service"] == "gp"
    assert result.intake["refill_request"] is None
    assert visit_status(seeded, visit_id) == "intake"
    row = seeded.execute(
        "SELECT service FROM visit WHERE id = ?", (visit_id,)
    ).fetchone()
    assert row[0] == "gp"


def test_a_model_refill_with_a_match_closes_the_visit(seeded):
    client = FakeChatClient([intake_json(service="refill", refill_request="amlodipine", **NO_DRUG)])
    visit_id = make_visit(seeded, "P002")
    result = session.handle_message(seeded, real(client), visit_id, "can I get more amlodipine")
    assert result.refill == {"medicine": AHMED_MED}
    assert result.source == "model"
    assert visit_status(seeded, visit_id) == "deflected_refill"


def test_simulated_mode_never_says_model(seeded):
    visit_id = make_visit(seeded, "P003")
    answers = ("I have a cough", "from yesterday", "5", "no", "no", "no")
    results = [session.handle_message(seeded, SIM, visit_id, text) for text in answers]
    assert {r.source for r in results} == {"simulated"}
    rows = seeded.execute(
        "SELECT payload FROM event WHERE visit_id = ? AND type = 'ai.turn'", (visit_id,)
    ).fetchall()
    assert {json.loads(row[0])["source"] for row in rows} == {"simulated"}


def test_event_payloads_hold_no_patient_sentence(seeded):
    client = FakeChatClient([TimeoutError("x"), "You have the flu", "{bad", "{bad"])
    ai = real(client)
    visit_id = make_visit(seeded, "P003")
    sentences = (
        "my private cough story one",
        "no chest pain in my private story two",
        "private story three",
    )
    for text in sentences:
        session.handle_message(seeded, ai, visit_id, text)
    rows = seeded.execute("SELECT type, payload FROM event WHERE visit_id = ?", (visit_id,)).fetchall()
    assert rows
    for row in rows:
        assert "private" not in row["payload"]
        assert "flu" not in row["payload"]


def test_real_path_reads_the_summary_back_with_took_paracetamol(seeded, engine):
    client = FakeChatClient(
        ["How bad is it from 0 to 10?", "Did you take any medicine for it?", intake_json(language="en")]
    )
    ai = real(client)
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, ai, visit_id, FATIMA_EN, "6", "paracetamol")
    assert result.done
    assert result.source == "model"
    assert result.intake["self_medication"] == ["paracetamol"]
    assert result.reply == (
        "Thanks. Here is what I will tell the nurse: "
        "fever and cough, 3 days, severity 6/10, took paracetamol. Is this right?"
    )
    assert "took paracetamol" in result.reply
    assert len(client.calls) == 3
    assert fallbacks(seeded, visit_id) == []
    assert result.reply in stored_text(seeded, visit_id)
    assert engine.issue_ticket(visit_id, TRIAGE).state == "reserved"


def test_simulated_arabic_reads_the_summary_back_with_panadol(seeded, engine):
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, SIM, visit_id, FATIMA_AR, "٦", "بنادول", "لا")
    assert result.done
    assert result.source == "simulated"
    assert result.intake["self_medication"] == ["paracetamol"]
    assert result.reply == (
        "شكرا. هذا اللي بقوله للممرضة: "
        "حرارة وكحة، 3 أيام، الشدة 6 من 10، أخذت باراسيتامول. هل هذا صحيح؟"
    )
    assert "أخذت باراسيتامول" in result.reply
    assert fallbacks(seeded, visit_id) == []
    assert result.reply in stored_text(seeded, visit_id)
    assert engine.issue_ticket(visit_id, TRIAGE).state == "reserved"


@pytest.mark.parametrize("sentence", ["ما عندي غير ألم في الصدر", "not only chest pain"])
def test_only_this_symptom_is_an_emergency_and_gets_no_ticket(seeded, engine, sentence):
    client = FakeChatClient([])
    visit_id = make_visit(seeded, "P001")
    before = ticket_count(seeded)
    result = say(seeded, real(client), visit_id, sentence)
    assert result.emergency
    assert result.source == "rules"
    assert result.denied == []
    assert client.calls == []
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, TRIAGE)
    assert ticket_count(seeded) == before


@pytest.mark.parametrize("mode", ["simulated", "real"])
def test_too_many_pills_gets_999_and_the_supportive_line(seeded, engine, mode):
    client = FakeChatClient([])
    ai = SIM if mode == "simulated" else real(client)
    visit_id = make_visit(seeded, "P003")
    before = ticket_count(seeded)
    result = say(seeded, ai, visit_id, "I took too many pills")
    assert result.emergency
    assert result.self_harm
    assert result.source == "rules"
    assert result.reply == simulated.emergency_reply(result.language, True)
    assert "999" in result.reply
    assert "talk to someone" in result.reply
    assert client.calls == []
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, TRIAGE)
    assert ticket_count(seeded) == before


# The patient corrects themselves. The first sentence is an ordinary visit, and the
# second opens on a negator that belongs to nothing, or to the fever only.
CORRECTIONS = (
    ("I have a cough", "no i have chest pain", "Since when?"),
    ("عندي كحة", "ما عندي حرارة عندي ألم في الصدر", "من متى؟"),
)


@pytest.mark.parametrize("mode", ["simulated", "real"])
@pytest.mark.parametrize("patient", ["P003", "P001"])
@pytest.mark.parametrize(("first", "second", "question"), CORRECTIONS, ids=["en", "ar"])
def test_a_correction_to_chest_pain_stops_the_visit(
    seeded, engine, mode, patient, first, second, question
):
    client = FakeChatClient([question])
    ai = SIM if mode == "simulated" else real(client)
    visit_id = make_visit(seeded, patient)
    opening = say(seeded, ai, visit_id, first)
    assert not opening.emergency
    assert opening.reply == question
    calls = len(client.calls)
    assert calls == (0 if mode == "simulated" else 1)
    tickets = ticket_count(seeded)

    result = say(seeded, ai, visit_id, second)

    assert result.emergency
    assert result.source == "rules"
    assert result.emergency_category == "chest_pain"
    assert result.reply == simulated.emergency_reply(result.language, False)
    assert "chest pain" not in result.denied
    assert "chest pain" not in session.history(seeded, visit_id)["denied"]
    assert len(client.calls) == calls
    assert visit_status(seeded, visit_id) == "redirected_emergency"
    with pytest.raises(VisitNotEligible):
        engine.issue_ticket(visit_id, TRIAGE)
    assert ticket_count(seeded) == tickets


@pytest.mark.parametrize(
    "answers",
    [
        ("I want amoxicillin", "since yesterday", "5", "no", "no", "no"),
        ("I have a cough and I want amoxicillin", "since yesterday", "5", "no", "no", "no"),
        ("I have a cough", "since yesterday", "5", "no", "I want amoxicillin", "no"),
        ("I have a cough", "since yesterday", "5", "no", "no", "I want amoxicillin"),
        ("أبي أموكسيسيلين", "امس", "٥", "لا", "لا", "لا"),
    ],
    ids=["opening", "with_a_complaint", "at_the_medicine_question", "at_the_last_question", "ar"],
)
def test_wanting_a_drug_is_not_having_taken_it(seeded, answers):
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, SIM, visit_id, *answers)
    assert result.done
    assert result.source == "simulated"
    validated = intake.validate_intake(result.intake)
    assert "amoxicillin" not in validated.self_medication
    assert validated.self_medication == []
    assert "took amoxicillin" not in validated.summary_for_nurse
    assert "took" not in validated.summary_for_nurse
    assert "took" not in result.reply
    assert "أخذت" not in result.reply


DRUG_NAMES = tuple(normalise(word) for word in ("amoxicillin", "أموكسيسيلين"))
COUGH_ONLY = {"chief_complaint": "cough", "associated": []}
CLEAN_DRAFT = "34F.\nCough for 3 days.\nAllergy: penicillin.\nVitals not recorded."


def assert_no_drug(*texts):
    for text in texts:
        for name in DRUG_NAMES:
            assert name not in normalise(text)


def assistant_lines(conn, visit_id):
    messages = session.history(conn, visit_id)["messages"]
    return [m["content"] for m in messages if m["role"] == "assistant"]


def saved_draft(conn, visit_id):
    return conn.execute("SELECT ai_draft FROM handoff WHERE visit_id = ?", (visit_id,)).fetchone()[0]


LAUNDERED_DRAFT = (
    "34F.\nCough for 3 days, took amoxicillin.\nAllergy: penicillin.\nVitals not recorded."
)


@pytest.mark.parametrize("claimed", [["amoxicillin"], []], ids=["claimed", "summary_only"])
@pytest.mark.parametrize(
    "summary",
    [
        "34F, 3 days cough, took amoxicillin.",
        "34F, 3 days cough. Patient reports having taken amoxicillin.",
        "34F, 3 days cough, on amoxicillin since Monday.",
        "34F, 3 days cough, wants amoxicillin.",
        "34F, 3 days cough, took AMOXICILLIN.",
        "34F، كحة من 3 أيام، أخذت أموكسيسيلين.",
    ],
)
def test_a_laundered_summary_leaves_no_drug_after_a_full_run(seeded, summary, claimed):
    """The model never lets go, so every turn from the request on is scripted."""
    laundered = intake_json(
        language="en", self_medication=claimed, summary_for_nurse=summary, **COUGH_ONLY
    )
    client = FakeChatClient(
        ["Since when?", "How bad is it from 0 to 10?", "Did you take any medicine for it?"]
        + [laundered] * 8
    )
    ai = real(client)
    visit_id = make_visit(seeded, "P001")
    result = say(
        seeded, ai, visit_id, "I have a cough", "3 days", "6", "I want amoxicillin", "no", "no"
    )
    assert result.done
    assert result.source == "simulated"
    assert result.intake["self_medication"] == []
    assert {event["reason"] for event in fallbacks(seeded, visit_id)} == {"invalid_json"}

    drafted = handoff.draft_for_visit(seeded, real(FakeChatClient([LAUNDERED_DRAFT])), visit_id)

    assert drafted["source"] == "simulated"
    assert fallbacks(seeded, visit_id)[-1] == {
        "surface": "handoff", "reason": "banned_output", "mode": "real", "served_by": "simulated",
    }
    assert_no_drug(
        result.reply,
        stored_intake(seeded, visit_id),
        *assistant_lines(seeded, visit_id),
        drafted["text"],
        saved_draft(seeded, visit_id),
    )


def test_a_model_that_drops_the_laundered_drug_on_retry_finishes_clean(seeded):
    laundered = intake_json(
        language="en",
        self_medication=["amoxicillin"],
        summary_for_nurse="34F, 3 days cough, took amoxicillin.",
        **COUGH_ONLY,
    )
    clean = intake_json(
        language="en",
        self_medication=[],
        summary_for_nurse="34F, 3 days cough, severity 6/10.",
        **COUGH_ONLY,
    )
    client = FakeChatClient(
        ["Since when?", "How bad is it from 0 to 10?", laundered, clean, CLEAN_DRAFT]
    )
    ai = real(client)
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, ai, visit_id, "I have a cough", "3 days", "6 and I want amoxicillin")
    assert result.done
    assert result.source == "model"
    assert result.intake["self_medication"] == []
    assert fallbacks(seeded, visit_id) == []

    drafted = handoff.draft_for_visit(seeded, ai, visit_id)

    assert drafted["source"] == "model"
    assert_no_drug(
        result.reply,
        stored_intake(seeded, visit_id),
        *assistant_lines(seeded, visit_id),
        drafted["text"],
        saved_draft(seeded, visit_id),
    )


def test_a_laundered_summary_keeps_only_the_patients_own_quoted_words(seeded):
    """chief_complaint_patient_words is the first sentence as said. Nothing else may."""
    laundered = intake_json(
        language="en",
        self_medication=["amoxicillin"],
        summary_for_nurse="34F, cough, took amoxicillin.",
        **COUGH_ONLY,
    )
    sentence = "I have a cough and I want amoxicillin"
    client = FakeChatClient([laundered] * 12)
    ai = real(client)
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, ai, visit_id, sentence, "3 days", "6", "no", "no", "no")
    assert result.done
    assert result.source == "simulated"
    drafted = handoff.draft_for_visit(seeded, real(FakeChatClient([LAUNDERED_DRAFT])), visit_id)
    assert drafted["source"] == "simulated"

    kept = dict(result.intake)
    assert kept.pop("chief_complaint_patient_words") == sentence
    assert_no_drug(
        result.reply,
        json.dumps(kept, ensure_ascii=False),
        *assistant_lines(seeded, visit_id),
        drafted["text"],
    )


# The model text gate, by shape. These words are on no list, which the first test
# proves, so nothing but the shape of the reply can be what refuses them. Two are
# real: a disease and a drug the lists have never heard of behave like invented ones.
UNLISTED_EN = (
    "zorblax", "quelmora", "vintrazole", "kranthitis", "drelgapine", "ostavirin",
    "sarcoidosis", "vonoprazan",
)
UNLISTED_AR = ("زوربلاكس", "كويلمورا", "فينترازول", "درلجابين")
SHAPES_EN = (
    "You have {w}.",
    "{w} is best.",
    "{w} twice daily.",
    "{w}",
    "{w}?",
    "Is it {w}?",
    "You have {w}, right?",
    "When did your {w} start?",
    "Have you tried {w}?",
    "Do you need {w}?",
    "How about {w}?",
    "Thanks. {w} would work.",
    "Sorry about the {w}. Since when?",
    "This looks like {w}. Since when?",
    "{w} is best. Since when?",
    "Since when? {w} is best.",
)
SHAPES_AR = (
    "عندك {w}.",
    "{w} هو الأفضل.",
    "خذ {w}.",
    "عندك {w}؟",
    "هل هو {w}؟",
    "من متى عندك {w}؟",
    "شكرا. {w} يفيدك.",
    "{w} هو الأفضل. من متى؟",
)
UNLISTED_REPLIES = [
    *(shape.format(w=word) for word in UNLISTED_EN for shape in SHAPES_EN),
    *(shape.format(w=word) for word in UNLISTED_AR for shape in SHAPES_AR),
]
GATE_REASONS = ("banned_output", "bad_shape")


def opening_for(reply):
    """The patient writes in the reply's language, so a scripted turn comes back in it."""
    arabic = any("\u0600" <= letter <= "\u06ff" for letter in reply)
    return ("عندي كحة", "ar") if arabic else ("I have a cough", "en")


@pytest.mark.parametrize("word", [*UNLISTED_EN, *UNLISTED_AR])
def test_the_unlisted_words_are_on_no_list(word):
    source = "\n".join(
        path.read_text(encoding="utf-8")
        for path in Path(filters.__file__).parent.glob("*.py")
    )
    assert word not in source.lower()


@pytest.mark.parametrize("reply", UNLISTED_REPLIES)
def test_any_unlisted_word_is_refused_by_shape(seeded, reply):
    client = FakeChatClient([reply])
    first, key = opening_for(reply)
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, real(client), visit_id, first)
    assert result.source == "simulated"
    assert result.reply == simulated.QUESTIONS["duration"][key]
    assert reply not in stored_text(seeded, visit_id)
    events = fallbacks(seeded, visit_id)
    assert len(events) == 1
    assert events[0]["reason"] in GATE_REASONS


@pytest.mark.parametrize(
    "reply",
    [
        *UNLISTED_REPLIES,
        "You have the flu",
        "Take paracetamol 500 mg",
        "Your number is T-014",
        "Is it the flu?",
        "Take paracetamol 500 mg?",
        "Your number is T-014?",
        "عندك انفلونزا",
        "خذ بنادول",
        "رقمك 14",
    ],
)
def test_the_gate_holds_with_every_filter_turned_off(seeded, monkeypatch, reply):
    """The guarantee is the gate, so no list may be what saves the patient."""
    monkeypatch.setattr(filters, "check_reply", lambda *a, **k: filters.FilterResult(True, ()))
    client = FakeChatClient([reply])
    first, key = opening_for(reply)
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, real(client), visit_id, first)
    assert result.source == "simulated"
    assert result.reply == simulated.QUESTIONS["duration"][key]
    assert [event["reason"] for event in fallbacks(seeded, visit_id)] == ["bad_shape"]


@pytest.mark.parametrize(
    "reply",
    [
        *(q[lang] for q in simulated.QUESTIONS.values() for lang in ("en", "ar")),
        *(q[lang] for q in simulated.FOLLOW_UPS.values() for lang in ("en", "ar")),
        "Thanks. Since when?",
        "Sorry to hear that. When did it start?",
        "Okay, how long has it been?",
        "Thanks for telling me about that. Since when?",
        "شكرا. من متى؟",
        "سلامتك، من متى؟",
    ],
)
def test_one_short_question_reaches_the_patient_word_for_word(seeded, reply):
    client = FakeChatClient([reply])
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, real(client), visit_id, "I have a cough")
    assert result.source == "model"
    assert result.reply == reply
    assert fallbacks(seeded, visit_id) == []


@pytest.mark.parametrize(
    "reply",
    [
        "For how long",
        "Thanks.",
        "Thanks. Thanks. Since when?",
        "Thank you so much for telling me about that. Since when?",
        "Thanks for the 3 days. Since when?",
        "Thanks 14. Since when?",
        "Noted, the flu. Since when?",
        "Noted, paracetamol. Since when?",
        "Since when? How bad?",
        "Since when did this start and how bad has it been and did you take any medicine today?",
        "شكرا. شكرا. من متى؟",
        "شكرا 14. من متى؟",
        "سلامتك من الانفلونزا. من متى؟",
        "خذ بنادول. من متى؟",
    ],
)
def test_any_other_shape_falls_back_and_is_recorded(seeded, reply):
    client = FakeChatClient([reply])
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, real(client), visit_id, "I have a cough")
    assert result.source == "simulated"
    assert result.reply != reply
    assert reply not in stored_text(seeded, visit_id)
    events = fallbacks(seeded, visit_id)
    assert len(events) == 1
    assert events[0]["surface"] == "chat"


@pytest.mark.parametrize(
    ("sentence", "word", "language", "expected"),
    [
        (
            "I have a cough",
            "zorblax",
            "en",
            "Thanks. Here is what I will tell the nurse: "
            "cough, 3 days, severity 6/10. Is this right?",
        ),
        (
            "عندي كحة",
            "زوربلاكس",
            "ar-gulf",
            "شكرا. هذا اللي بقوله للممرضة: كحة، 3 أيام، الشدة 6 من 10. هل هذا صحيح؟",
        ),
    ],
    ids=["en", "ar"],
)
def test_the_read_back_is_rendered_by_the_server(seeded, sentence, word, language, expected):
    output = intake_json(
        language=language,
        chief_complaint=word,
        duration=f"{word} for 3 days",
        associated=[word],
        self_medication=[word],
        patient_concerns=word,
        summary_for_nurse=f"34F, {word}.",
    )
    client = FakeChatClient([output])
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, real(client), visit_id, sentence)
    assert result.done
    assert result.source == "model"
    assert result.reply == expected
    assert word not in result.reply
    assert result.intake["self_medication"] == []
    assert result.intake["summary_for_nurse"] == f"34F, {word}."


# The gate alone, crossed. check_reply is patched to pass everything, so whatever stops
# these replies is the gate. The first patient message is what `known` holds.
def force_filter_open(monkeypatch):
    monkeypatch.setattr(filters, "check_reply", lambda *a, **k: filters.FilterResult(True, ()))


def assert_gate_stops(conn, reply, first=None):
    client = FakeChatClient([reply])
    opening = first or opening_for(reply)[0]
    visit_id = make_visit(conn, "P001")
    result = say(conn, real(client), visit_id, opening)
    assert result.source == "simulated", reply
    assert result.reply != reply
    assert reply not in stored_text(conn, visit_id)
    assert [event["reason"] for event in fallbacks(conn, visit_id)] == ["bad_shape"]


def fatha(text):
    """A fatha after every Arabic letter, the worst case for a word match."""
    return "".join(f"{letter}َ" if "ء" <= letter <= "ي" else letter for letter in text)


REFUSED_FRAMES = (
    "Can you {c}?",
    "Could you {c}?",
    "Why {c}?",
    "Why not {c}?",
    "How about {c}?",
    "What about {c}?",
    "What if {c}?",
    "Did you know {c}?",
    "Do you know {c}?",
    "Are you aware {c}?",
    "Is it better to {c}?",
    "Is it good to {c}?",
    "Is it ok to {c}?",
)
REFUSED_CLAUSES = (
    "take a tablet", "stop your medicine", "drink more water", "a tablet every day",
    "take ibuprofen",
)
AR_REFUSED_FRAMES = ("تبي {c}؟", "تبين {c}؟", "تحب {c}؟", "تحبين {c}؟", "ما {c}؟")
AR_REFUSED_CLAUSES = ("تاخذ حبة", "تجرب دوا", "تشرب علاج", "تستخدم حبوب", "تاخذين دواء")
REFUSED_REPLIES = [
    *(frame.format(c=clause) for frame in REFUSED_FRAMES for clause in REFUSED_CLAUSES),
    *(frame.format(c=clause) for frame in AR_REFUSED_FRAMES for clause in AR_REFUSED_CLAUSES),
    *(
        fatha(frame.format(c=clause))
        for frame in AR_REFUSED_FRAMES
        for clause in AR_REFUSED_CLAUSES
    ),
]


@pytest.mark.parametrize("reply", REFUSED_REPLIES)
def test_each_refused_frame_is_stopped_by_the_gate_alone(seeded, monkeypatch, reply):
    force_filter_open(monkeypatch)
    assert_gate_stops(seeded, reply)


DISEASE_SHAPES = (
    "Is your problem {x}?",
    "Is your pain from {x}?",
    "Do you have {x}?",
    "Are you sick with {x}?",
)
AR_DISEASE_SHAPES = ("عندك {x}؟", "هل عندك {x}؟", "هل الألم من {x}؟")
DISEASE_REPLIES = [
    shape.format(x=" ".join(term))
    for term in filters.DISEASE_TERMS
    for shape in (*DISEASE_SHAPES, *(AR_DISEASE_SHAPES if has_arabic(term[0]) else ()))
]


def test_the_disease_crossing_covers_every_term():
    assert len(DISEASE_REPLIES) >= 4 * len(filters.DISEASE_TERMS)


@pytest.mark.parametrize("reply", DISEASE_REPLIES)
def test_each_disease_is_stopped_by_the_gate_alone(seeded, monkeypatch, reply):
    force_filter_open(monkeypatch)
    assert_gate_stops(seeded, reply)


NAMED = "I took ibuprofen and I think it is shingles. maybe it's best to take more"


@pytest.mark.parametrize(
    "reply",
    [
        "Why not take ibuprofen?",
        "How about ibuprofen?",
        "Did you know you have shingles?",
        "Do you have a fever (it is shingles)?",
        "Do you have a fever / shingles?",
        "Is your problem shingles?",
        "Is your pain from shingles?",
        "Is it shingles?",
        "Do you think it is shingles?",
        "Should you take ibuprofen?",
        "Can you take ibuprofen?",
        "Is it better to take ibuprofen?",
    ],
)
def test_a_word_the_patient_named_opens_no_refused_shape(seeded, monkeypatch, reply):
    force_filter_open(monkeypatch)
    assert_gate_stops(seeded, reply, first=NAMED)


@pytest.mark.parametrize(
    "reply",
    ["Do you have shingles?", "How long have you had shingles?", "Did you take ibuprofen today?"],
)
def test_a_word_the_patient_named_may_be_asked_about(seeded, monkeypatch, reply):
    force_filter_open(monkeypatch)
    visit_id = make_visit(seeded, "P001")
    result = say(seeded, real(FakeChatClient([reply])), visit_id, NAMED)
    assert result.source == "model"
    assert result.reply == reply


def test_the_record_lets_a_question_name_its_medicine(seeded, monkeypatch):
    force_filter_open(monkeypatch)
    reply = "Are you still on amlodipine 5 mg once daily?"
    visit_id = make_visit(seeded, "P002")
    result = say(seeded, real(FakeChatClient([reply])), visit_id, "I have a cough")
    assert result.source == "model"
    assert result.reply == reply
    assert_gate_stops(seeded, reply)


@pytest.mark.parametrize(
    "reply",
    [
        "Has it been 10 minutes?",
        "Do you have a fever, shingles?",
        "You have zorblax.",
        "zorblax is best.",
        "quelmora helps.",
        "Thanks. kranthitis is common.",
    ],
)
def test_numbers_punctuation_and_unlisted_words_stop_at_the_gate_alone(
    seeded, monkeypatch, reply
):
    force_filter_open(monkeypatch)
    assert_gate_stops(seeded, reply)
