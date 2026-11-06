"""One receptionist turn: rules first, then the model, with a per-turn fallback.

The order is fixed. Red-flag rules run on every message and a hit never reaches
the model. A layer can only make the outcome more cautious, so a model reply
that says emergency escalates even when the rest of it is broken.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass, field

from backend.ai import filters, intake, prompts, redflags, refill, simulated
from backend.ai.audit import AiEvent
from backend.ai.intake import IntakeParseError
from backend.ai.llm import Llm, LlmError
from backend.ai.text import contains_any, normalise, phrase_tokens, tokenise

_MAX_QUESTION_MARKS = 1
_MAX_TOKENS = 700  # The intake JSON runs past the adapter's default of 400.
_MAX_PATIENT_WORDS = 1000
_FORCE_INTAKE = "Output ONLY the intake JSON now."
# Model prose. A nurse confirms it at triage, and the patient reads the server's own
# read-back in `reply` instead.
_STAFF_ONLY = ("summary_for_nurse", "chief_complaint", "duration", "associated", "patient_concerns")


def patient_intake(intake_data: dict | None) -> dict | None:
    """An intake with the model's free text removed, for anything a patient sees."""
    if intake_data is None:
        return None
    return {key: value for key, value in intake_data.items() if key not in _STAFF_ONLY}


@dataclass
class TurnResult:
    reply: str
    done: bool
    emergency: bool
    intake: dict | None
    refill: dict | None
    denied: list[str]
    source: str
    emergency_category: str | None
    self_harm: bool
    language: str
    slot: str | None
    events: list[AiEvent] = field(default_factory=list)
    fired: list[str] = field(default_factory=list)  # labels that may not stay denied

    def to_api(self) -> dict:
        return {
            "reply": self.reply,
            "done": self.done,
            "emergency": self.emergency,
            "intake": patient_intake(self.intake),
            "refill": self.refill,
            "denied": self.denied,
            "ai_source": self.source,
            "self_harm": self.self_harm,
        }


@dataclass
class _Turn:
    """What a turn knows once the rules have cleared the message."""

    text: str
    history: list[dict]
    patient: dict
    denied: list[str]
    language: str
    events: list[AiEvent]
    fired: list[str]

    @property
    def asked(self) -> int:
        return simulated.question_count(self.history)

    @property
    def conversation(self) -> list[dict]:
        return [*self.history, {"role": "user", "content": self.text, "slot": None}]

    @property
    def said(self) -> list[str]:
        """Every patient message so far, this one included."""
        return [m["content"] for m in self.conversation if m["role"] == "user"]

    @property
    def stated_medicines(self) -> list[str]:
        """What the patient said they took. Only this may become self_medication."""
        names = (name for text in self.said for name in simulated.parse_medicines(text))
        return list(dict.fromkeys(names))

    @property
    def stated_complaints(self) -> list[str]:
        complaints = (name for text in self.said for name in simulated.find_complaints(text))
        return list(dict.fromkeys(complaints))

    @property
    def known_words(self) -> list[str]:
        """What a model question may repeat besides the gate's own vocabulary."""
        record = self.patient
        return [*self.said, *record["chronic"], *record["allergies"], *record["active_meds"]]

    @property
    def refill_blocked(self) -> bool:
        """A symptom or a medicine problem anywhere in the chat must reach a nurse."""
        return any(refill.blocks_refill(tokenise(text)) for text in self.said)

    def result(
        self,
        reply: str,
        source: str,
        *,
        slot: str | None = None,
        done: bool = False,
        intake: dict | None = None,
        refill: dict | None = None,
        emergency: bool = False,
        category: str | None = None,
        self_harm: bool = False,
    ) -> TurnResult:
        asked_now = intake["questions_asked"] if intake else self.asked + _is_question(
            done, emergency, refill
        )
        events = [
            *self.events,
            AiEvent("ai.turn", {"source": source, "questions_asked": asked_now, "done": done}),
        ]
        if done:
            events.append(AiEvent("ai.intake_ready", {"service": intake["service"], "source": source}))
        return TurnResult(
            reply=reply,
            done=done,
            emergency=emergency,
            intake=intake,
            refill=refill,
            denied=self.denied,
            source=source,
            emergency_category=category,
            self_harm=self_harm,
            language=self.language,
            slot=slot,
            events=events,
            fired=self.fired,
        )


def _is_question(done: bool, emergency: bool, refill_found: dict | None) -> int:
    return 0 if done or emergency or refill_found else 1


def _deflect(turn: _Turn, medicine: str, source: str) -> TurnResult:
    turn.events.append(AiEvent("refill.detected", {"medicine": medicine}))
    reply = simulated.refill_reply(medicine, turn.language)
    return turn.result(reply, source, refill={"medicine": medicine})


def _rule_emergency(turn: _Turn, flags: redflags.RedFlagResult) -> TurnResult:
    reply = simulated.emergency_reply(turn.language, flags.self_harm)
    return turn.result(
        reply,
        "rules",
        emergency=True,
        category=flags.categories[0],
        self_harm=flags.self_harm,
    )


def _model_emergency(turn: _Turn) -> TurnResult:
    turn.events.append(AiEvent("ai.emergency", {"source": "model"}))
    reply = simulated.emergency_reply(turn.language, False)
    return turn.result(reply, "model", emergency=True)


def _simulated_turn(turn: _Turn) -> TurnResult:
    scripted = simulated.next_turn(
        turn.conversation, turn.patient, turn.denied, turn.language
    )
    return turn.result(
        scripted.reply,
        "simulated",
        slot=scripted.slot,
        done=scripted.intake is not None,
        intake=scripted.intake,
    )


def _fallback(turn: _Turn, reason: str) -> TurnResult:
    """Scripted for this turn only. The next message tries the model again."""
    turn.events.append(
        AiEvent(
            "ai.fallback",
            {"surface": "chat", "reason": reason, "mode": "real", "served_by": "simulated"},
        )
    )
    return _simulated_turn(turn)


def _free_text(parsed: intake.Intake) -> str:
    """Everything the model wrote that a nurse reads.

    refill_request stays out: _finish never stores it. A matched request deflects
    to the record's medicine, and any other is dropped, so nobody ever reads it.
    """
    fields = [
        parsed.summary_for_nurse,
        parsed.chief_complaint,
        parsed.duration,
        *parsed.associated,
        *parsed.self_medication,
        parsed.patient_concerns,
    ]
    return "\n".join(field for field in fields if field)


def _checked_intake(output: str, turn: _Turn) -> intake.Intake:
    """The model's own self_medication allows nothing, only the patient's words do."""
    parsed = intake.parse_intake(output)
    patient = turn.patient
    check = filters.check_handoff(
        _free_text(parsed),
        chronic=patient["chronic"],
        allergies=patient["allergies"],
        allowed_meds=patient["active_meds"],
        self_medication=turn.stated_medicines,
    )
    if not check.ok:
        raise IntakeParseError(
            f"Invalid intake: a free-text field broke a safety rule ({', '.join(check.reasons)})."
        )
    return parsed


def _names_active_med(request: str | None, active_meds: Sequence[str]) -> str | None:
    if not request:
        return None
    tokens = tokenise(request)
    for entry in active_meds:
        drug = normalise(entry).split()[:1]
        names = [drug[0], *refill.DRUG_ARABIC_NAMES.get(drug[0], ())] if drug else []
        if contains_any(tokens, [phrase_tokens(name) for name in names]):
            return entry
    return None


def _refill_medicine(turn: _Turn, request: str | None) -> str | None:
    """The record's medicine a model refill stands on, or None.

    The model cannot send a patient with a symptom or a problem with their
    medicine to the refill line, the same rule _rule_refill applies.
    """
    active_meds = turn.patient["active_meds"]
    if turn.refill_blocked:
        return None
    for text in turn.said:
        match = refill.detect(text, active_meds)
        if match:
            return match.medicine
    return _names_active_med(request, active_meds)


def _finish(turn: _Turn, parsed: intake.Intake) -> TurnResult:
    """Apply the server's overrides to a valid model intake."""
    data = parsed.model_dump()
    first_words = next(m["content"] for m in turn.conversation if m["role"] == "user")
    data.update(
        emergency=False,
        questions_asked=min(turn.asked, simulated.MAX_QUESTIONS),
        denied_red_flags=list(turn.denied),
        chief_complaint_patient_words=first_words[:_MAX_PATIENT_WORDS],
        self_medication=turn.stated_medicines,
        summary_for_nurse=simulated.add_denied(data["summary_for_nurse"], turn.denied),
    )
    if data["service"] == "refill":
        medicine = _refill_medicine(turn, data["refill_request"])
        if medicine:
            return _deflect(turn, medicine, "model")
        data["service"] = "gp"
        turn.events.append(AiEvent("refill.unmatched", {}))
    data["refill_request"] = None  # Unfiltered model text, and nothing here needs it.
    final = intake.validate_intake(data).model_dump()
    spoken = {**final, "chief_complaint": " and ".join(turn.stated_complaints)}
    reply = simulated.summary_reply(spoken, turn.language)
    return turn.result(reply, "model", done=True, intake=final)


def _retry(
    llm: Llm, turn: _Turn, messages: list[dict], output: str, note: str, reason: str
) -> TurnResult:
    """One more try, with the model's reply and what was wrong with it."""
    retry_messages = [
        *messages,
        {"role": "assistant", "content": output},
        {"role": "user", "content": note},
    ]
    try:
        second = llm.chat(retry_messages, max_tokens=_MAX_TOKENS)
    except LlmError:
        return _fallback(turn, reason)
    if intake.says_emergency(second):
        return _model_emergency(turn)
    try:
        return _finish(turn, _checked_intake(second, turn))
    except IntakeParseError:
        return _fallback(turn, reason)


def _too_many_questions(reply: str) -> bool:
    """The receptionist asks one thing at a time, and one mark is what it may show."""
    norm = normalise(reply)
    return norm.count("?") + norm.count("؟") > _MAX_QUESTION_MARKS


def _model_turn(llm: Llm, turn: _Turn) -> TurnResult:
    asked = turn.asked
    at_cap = asked >= simulated.MAX_QUESTIONS
    system = prompts.build_system(turn.patient, turn.denied, asked, at_cap)
    conversation = turn.conversation
    if not turn.history:
        opening = simulated.OPENING["ar" if turn.language.startswith("ar") else "en"]
        conversation = [{"role": "assistant", "content": opening}, *conversation]
    messages = [
        {"role": "system", "content": system},
        *({"role": m["role"], "content": m["content"]} for m in conversation),
    ]
    try:
        output = llm.chat(messages, max_tokens=_MAX_TOKENS)
    except LlmError:
        return _fallback(turn, "model_error")

    if intake.says_emergency(output):
        return _model_emergency(turn)
    if "{" in output:  # Broken JSON is still a JSON attempt, never a reply to show.
        try:
            return _finish(turn, _checked_intake(output, turn))
        except IntakeParseError as error:
            return _retry(llm, turn, messages, output, str(error), "invalid_json")
    if at_cap:
        return _retry(llm, turn, messages, output, _FORCE_INTAKE, "question_cap")
    if not filters.check_reply(output, allowed_meds=turn.patient["active_meds"]).ok:
        return _fallback(turn, "banned_output")
    if _too_many_questions(output):
        return _fallback(turn, "multiple_questions")
    if not filters.gate_reply(output, known=turn.known_words):
        return _fallback(turn, "bad_shape")
    return turn.result(output, "model")


def _read_rules(
    text: str,
    history: list[dict],
    patient: dict,
    denied: Sequence[str] | None,
    lang: str | None,
) -> tuple[_Turn, redflags.RedFlagResult]:
    language = simulated.detect_lang(text, lang or patient.get("preferred_lang") or "en")
    flags = redflags.check_conversation(text, history)
    new_denied = [hit.label_en for hit in flags.denied]
    events = [
        AiEvent("redflag.hit", {"category": hit.category, "cue": hit.cue, "label": hit.label_en})
        for hit in flags.hits
    ]
    if new_denied:
        events.append(AiEvent("redflag.denied", {"labels": new_denied}))
    merged = dict.fromkeys([*(denied or ()), *new_denied])
    turn = _Turn(
        text=text,
        history=history,
        patient=patient,
        denied=[label for label in merged if label not in flags.fired],
        language=language,
        events=events,
        fired=sorted(flags.fired),
    )
    return turn, flags


def _rule_refill(turn: _Turn) -> refill.RefillMatch | None:
    if turn.refill_blocked:
        return None
    return refill.detect(turn.text, turn.patient["active_meds"])


def rule_emergency(
    text: str,
    history: list[dict],
    patient: dict,
    denied: Sequence[str] | None = None,
    lang: str | None = None,
) -> TurnResult | None:
    """Rules alone, for a visit past intake: the emergency turn on a hit, else None."""
    turn, flags = _read_rules(text, history, patient, denied, lang)
    return _rule_emergency(turn, flags) if flags.emergency else None


def run_turn(
    llm: Llm,
    text: str,
    history: list[dict],
    patient: dict,
    denied: Sequence[str] | None = None,
    lang: str | None = None,
) -> TurnResult:
    """One patient message. `history` does not include `text`; empty means the opening."""
    turn, flags = _read_rules(text, history, patient, denied, lang)
    if flags.emergency:
        return _rule_emergency(turn, flags)

    match = _rule_refill(turn)
    if match:
        return _deflect(turn, match.medicine, "rules")

    if llm.mode != "real":
        return _simulated_turn(turn)
    return _model_turn(llm, turn)
