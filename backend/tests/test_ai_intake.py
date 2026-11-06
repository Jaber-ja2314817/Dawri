from __future__ import annotations

import json

import pytest

from backend import db
from backend.ai import intake
from backend.ai.intake import Intake, IntakeParseError
from backend.tests.conftest import make_visit

PATIENT_WORDS = "عندي حرارة وكحة من ثلاث أيام"
# The sample in the vault's AI Receptionist Design note, unchanged.
VAULT_SAMPLE = {
    "emergency": False,
    "language": "ar-gulf",
    "chief_complaint": "fever and dry cough",
    "chief_complaint_patient_words": PATIENT_WORDS,
    "duration": "3 days",
    "severity_0_10": 6,
    "associated": ["fever"],
    "self_medication": ["paracetamol"],
    "service": "gp",
    "service_confidence": 0.86,
    "summary_for_nurse": "34F, 3 days fever and dry cough, severity 6/10, took paracetamol.",
    "refill_request": None,
    "questions_asked": 5,
}


def sample(**changes):
    return {**VAULT_SAMPLE, **changes}


def without(field):
    return {key: value for key, value in VAULT_SAMPLE.items() if key != field}


def add_intake(conn, json_text, edited=None):
    visit_id = make_visit(conn, "P001")
    conn.execute(
        "INSERT INTO intake (visit_id, json, edited_json) VALUES (?, ?, ?)",
        (visit_id, json_text, edited),
    )
    return visit_id


def test_the_vault_sample_validates_field_for_field():
    result = intake.validate_intake(VAULT_SAMPLE)
    assert result.model_dump(exclude={"denied_red_flags", "patient_concerns"}) == VAULT_SAMPLE
    assert result.denied_red_flags == []
    assert result.patient_concerns is None


def test_the_enums_match_the_vault():
    assert intake.SERVICES == (
        "gp",
        "dental",
        "refill",
        "vaccination",
        "lab_only",
        "womens_health",
        "mental_health",
        "other",
    )
    assert intake.LANGUAGES == ("ar-gulf", "ar-msa", "en")


@pytest.mark.parametrize("service", intake.SERVICES)
def test_every_service_is_accepted(service):
    assert intake.validate_intake(sample(service=service)).service == service


@pytest.mark.parametrize("language", intake.LANGUAGES)
def test_every_language_is_accepted(language):
    assert intake.validate_intake(sample(language=language)).language == language


@pytest.mark.parametrize(
    "field, value",
    [
        ("severity_0_10", 11),
        ("severity_0_10", -1),
        ("severity_0_10", "6"),
        ("severity_0_10", True),
        ("severity_0_10", 6.0),
        ("service", "surgery"),
        ("language", "fr"),
        ("service_confidence", 1.2),
        ("service_confidence", -0.1),
        ("service_confidence", True),
        ("service_confidence", float("nan")),
        ("questions_asked", 7),
        ("questions_asked", -1),
        ("questions_asked", True),
        ("chief_complaint", ""),
        ("chief_complaint", "   \n"),
        ("chief_complaint", "x" * 201),
        ("chief_complaint_patient_words", ""),
        ("chief_complaint_patient_words", "x" * 1001),
        ("summary_for_nurse", "  "),
        ("summary_for_nurse", "x" * 401),
        ("associated", "fever"),
        ("self_medication", [1]),
    ],
)
def test_each_field_rule_rejects(field, value):
    with pytest.raises(IntakeParseError, match=field):
        intake.validate_intake(sample(**{field: value}))


@pytest.mark.parametrize(
    "field",
    [
        "language",
        "chief_complaint",
        "chief_complaint_patient_words",
        "service",
        "service_confidence",
        "summary_for_nurse",
        "questions_asked",
    ],
)
def test_required_fields(field):
    with pytest.raises(IntakeParseError, match=field):
        intake.validate_intake(without(field))


@pytest.mark.parametrize(
    "field, value",
    [
        ("severity_0_10", 0),
        ("severity_0_10", 10),
        ("service_confidence", 0),
        ("service_confidence", 1),
        ("questions_asked", 0),
        ("questions_asked", 6),
        ("chief_complaint", "x" * 200),
        ("chief_complaint_patient_words", "x" * 1000),
        ("summary_for_nurse", "x" * 400),
    ],
)
def test_limits_are_inclusive(field, value):
    assert getattr(intake.validate_intake(sample(**{field: value})), field) == value


@pytest.mark.parametrize(
    "field", ["duration", "severity_0_10", "refill_request", "patient_concerns"]
)
def test_nullable_fields_accept_null(field):
    assert getattr(intake.validate_intake(sample(**{field: None})), field) is None


@pytest.mark.parametrize("field", ["duration", "severity_0_10"])
def test_duration_and_severity_are_never_invented(field):
    assert getattr(intake.validate_intake(without(field)), field) is None


def test_extra_keys_are_ignored():
    assert not hasattr(intake.validate_intake(sample(diagnosis="flu")), "diagnosis")


def test_lists_are_not_shared_between_intakes():
    data = without("associated")
    first = intake.validate_intake(data)
    first.associated.append("cough")
    assert intake.validate_intake(data).associated == []


def test_a_parse_error_is_a_value_error():
    assert issubclass(IntakeParseError, ValueError)


def test_a_parse_error_keeps_the_patients_words_out_of_the_retry_prompt():
    secret = "my very private words"
    with pytest.raises(IntakeParseError) as caught:
        intake.validate_intake(sample(service=secret, chief_complaint="", language=secret))
    assert secret not in str(caught.value)
    assert len(str(caught.value)) <= 300


def test_a_parse_error_on_many_fields_stays_short():
    with pytest.raises(IntakeParseError) as caught:
        intake.validate_intake({})
    assert len(str(caught.value)) <= 300


@pytest.mark.parametrize("data", [None, [], "text", 3])
def test_validate_rejects_a_non_object(data):
    with pytest.raises(IntakeParseError):
        intake.validate_intake(data)


@pytest.mark.parametrize(
    "text",
    [
        '{"a": 1}',
        '```json\n{"a": 1}\n```',
        '```\n{"a": 1}\n```',
        'Here is the intake:\n{"a": 1}\nThanks!',
        'Here you go: ```json\n{"a": 1}\n``` done',
        '{broken} then {"a": 1}',
        'an open { brace then {"a": 1}',
        '[1, 2] {"a": 1} {"b": 2}',
    ],
)
def test_extract_json_finds_the_object(text):
    assert intake.extract_json(text) == {"a": 1}


def test_extract_json_respects_braces_inside_strings():
    text = 'x {"a": "}{", "b": "\\"}", "c": {"d": "{"}} y'
    assert intake.extract_json(text) == {"a": "}{", "b": '"}', "c": {"d": "{"}}


@pytest.mark.parametrize("text", ["", "no json here", "{", "}{", "[1, 2]", '{"a": 1', "{'a': 1}"])
def test_extract_json_returns_none_when_there_is_none(text):
    assert intake.extract_json(text) is None


def test_extract_json_survives_hostile_nesting():
    assert intake.extract_json('{"a":' * 100_000) is None
    assert intake.extract_json("{" * 100_000) is None


def test_extract_json_looks_past_a_few_stray_braces():
    assert intake.extract_json("{ " * 20 + '{"a": 1}') == {"a": 1}


def test_hostile_nesting_cannot_hide_an_emergency():
    assert intake.says_emergency("{ " * 1000 + '{"emergency": true}') is True


@pytest.mark.parametrize(
    "template",
    ["{}", "```json\n{}\n```", "Sure, the intake is below.\n{}\nAll done."],
)
def test_parse_intake_handles_wrapped_json(template):
    result = intake.parse_intake(template.replace("{}", json.dumps(VAULT_SAMPLE)))
    assert result.service == "gp"
    assert result.chief_complaint_patient_words == PATIENT_WORDS


def test_parse_intake_rejects_a_reply_with_no_object():
    with pytest.raises(IntakeParseError):
        intake.parse_intake("How long have you had it?")


def test_parse_intake_rejects_an_invalid_object():
    with pytest.raises(IntakeParseError, match="severity_0_10"):
        intake.parse_intake(json.dumps(sample(severity_0_10=11)))


@pytest.mark.parametrize(
    "text",
    [
        '{"emergency": true}',
        '{"emergency":true}',
        '{"emergency": "true"}',
        '{"emergency": "True"}',
        '{"emergency": 1}',
        '```json\n{"emergency": true}\n```',
        'This is urgent.\n{"emergency": true}\nPlease call 999.',
        json.dumps(sample(emergency=True, severity_0_10=99, service="surgery")),
        '{"emergency": true, "language": ',
        '{"emergency" : true,, "x": }',
        '"emergency":\n true',
        '{"emergency": true, "nested": {"a": 1}',
        '{"intake": {"emergency": true}}',
        '{"emergency": True}',
        "{'emergency': True}",
        '{"a": 1} then {"emergency": true}',
        '{emergency: true}',
        '{ emergency : true }',
        '{"emergency": yes}',
        '{"emergency": 1,',
        '{"emergency_flag": true}',
        '{"is_emergency": true}',
        'emergency = true',
        '{emergency = true}',
        '{"emergency" = yes}',
        "{emergency: 1}",
        '{"Emergency": "YES"}',
        '{"needs-emergency-care": true}',
    ],
)
def test_says_emergency_escalates(text):
    assert intake.says_emergency(text) is True


@pytest.mark.parametrize(
    "text",
    [
        '{"emergency": false}',
        '{"emergency": "false"}',
        '{"emergency": null}',
        '{"emergency": 0}',
        '{"emergency": 10}',
        '{"emergency": "maybe"}',
        '{"emergency_flag": false}',
        '{emergency: false}',
        '{"emergency": yesterday}',
        json.dumps(sample()),
        json.dumps(sample(summary_for_nurse='said "emergency": true')),
        "How long have you had it?",
        "",
    ],
)
def test_says_emergency_stays_false(text):
    assert intake.says_emergency(text) is False


@pytest.mark.parametrize(
    "text",
    [
        "هذه حالة طارئة، اتصل على 999 الآن.",
        "Please call 999.",
        "Call an ambulance.",
        "Go to the emergency department now.",
        "EMERGENCY",
        "emergency true",
        "توجه إلى قسم الطوارئ",
        "توجه للطوارئ",
        "هذا أمر طارئ",
        "اتصل بالإسعاف",
        "اتصل على ٩٩٩",
        "This is not an emergency, but call 999.",
        '"emergency": false, then please call 999',
    ],
)
def test_prose_escalates(text):
    assert intake.says_emergency(text) is True


@pytest.mark.parametrize(
    "text",
    [
        "This is not an emergency",
        "This isn't an emergency",
        "no emergency",
        "هذه ليست حالة طارئة",
        "ليس طارئ",
        "مو طارئة",
        "My number is 9999",
        '"emergency": false, "language": "en"',
        "'emergency': False",
        "```json\n\"emergency\": false\n```",
    ],
)
def test_prose_stays_false(text):
    assert intake.says_emergency(text) is False


@pytest.mark.parametrize(
    "text",
    [
        '{"emergency": false, "summary_for_nurse": "wants the emergency department"}',
        '{"emergency": false, "summary_for_nurse": "call 999',
        '{"emergency": false, broken',
        'Here is the intake, no ambulance needed { "emergency": false',
        'call 999 {"emergency": false}',
    ],
)
def test_prose_rule_stays_out_of_json(text):
    assert intake.says_emergency(text) is False


def test_every_true_the_schema_accepts_is_an_emergency():
    for value in (True, 1, "true", "1", "yes", "on"):
        data = sample(emergency=value)
        assert intake.validate_intake(data).emergency is True
        assert intake.says_emergency(json.dumps(data)) is True


def test_load_effective_returns_the_stored_intake(conn, seeded):
    visit_id = add_intake(conn, json.dumps(VAULT_SAMPLE))
    assert intake.load_effective(conn, visit_id) == VAULT_SAMPLE


def test_load_effective_prefers_the_nurse_edit(conn, seeded):
    edited = sample(chief_complaint="fever, cough and rash")
    visit_id = add_intake(conn, json.dumps(VAULT_SAMPLE), json.dumps(edited))
    assert intake.load_effective(conn, visit_id)["chief_complaint"] == "fever, cough and rash"


@pytest.mark.parametrize("edited", [None, "", "   \n"])
def test_load_effective_ignores_a_blank_edit(conn, seeded, edited):
    visit_id = add_intake(conn, json.dumps(VAULT_SAMPLE), edited)
    assert intake.load_effective(conn, visit_id) == VAULT_SAMPLE


def test_load_effective_is_none_for_no_row(conn, seeded):
    assert intake.load_effective(conn, make_visit(conn, "P001")) is None


def test_load_effective_is_none_for_an_empty_intake(conn, seeded):
    assert intake.load_effective(conn, add_intake(conn, "{}")) is None


def test_intake_round_trips_through_the_database(conn, seeded):
    stored = db.dumps(Intake.model_validate(sample(denied_red_flags=["chest pain"])).model_dump())
    loaded = intake.load_effective(conn, add_intake(conn, stored))
    assert intake.validate_intake(loaded).denied_red_flags == ["chest pain"]
