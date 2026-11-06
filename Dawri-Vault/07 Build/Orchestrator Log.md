---
tags: [build, log]
---

# Orchestrator Log

The orchestrator's memory between phases. One section per phase: plan, what was built, verdict, evidence, known gaps. See [[Build Decisions]].

## Phase 1: Foundation (approved in review round 1 of 4, 6 Nov 2026)

### Plan
Repo scaffold under `backend/`, `requirements.txt`, SQLite schema and db layer, seeds, `mock_health`, demo auth, the deterministic queue engine and `adapters/queue_base.py`, the event bus for SSE, and a pytest suite for the ticket rules. Features in scope: F01 backend, F02, F06 and F07 core.

### What was built
- Config, time helpers (fixed Doha offset), schema, db layer and seeds: 6 patients, 2 dependents, 7 centres, 8 doctors, 15 staff, 18 counters, 9 drugs.
- `mock_health.py`: synthetic records as a FHIR-like Bundle.
- `queue_engine.py`, `adapters/queue_base.py` and `simulate.py`: reserve, activate, call, serve, no-show, complete, release and expiry, with event rows and SSE fan-out after commit.
- `events.py`: thread-safe event bus and SSE stream.
- `main.py`, `bootstrap.py`, `auth.py`, `deps.py` and routers: `/api/health`, auth, `/api/me`, `/api/auth/demo-patients`, `/api/staff/login`, `/api/counters/{id}/stream`, and the background expiry task.

Patient and staff workflow routes (reserve, arrive, call-next and the rest), the visit and display streams, AI, frontend and Dockerfile are later work. None were added here.

### Verdict
Approved. Every acceptance check passed on the orchestrator's own runs.

One check needed a correction. The demo-numbers script says "complete that" straight after `issue_active` on `C-WAKRA-D4`, but D-GP-023 is still `active` at that point. The engine refuses with `InvalidTransition`, which is what the lifecycle in [[Queue Engine]] requires. The run added `call_next('C-WAKRA-D4')` before `complete()`, and P-031 followed. The check was wrong, not the engine, so no code change was asked for.

### Evidence
- `.venv/bin/python -m pytest -q`: 283 passed, none skipped, exit 0, with all 14 named test files collected.
- Real Python 3.12 run: a fresh 3.12 venv built from `requirements.txt` also passed 283. This goes beyond the required `compileall`, which also exited 0.
- The suite passed under `TZ` UTC, Asia/Tokyo and America/Los_Angeles. `test_sse_e2e` and `test_app` passed 5 runs in a row.
- Centres one-liner exit 0, and no Siddiq or Ghuwailina in the seeds.
- P001-P003 equal the vault JSON field for field, parsed from [[Mock Health System]] by a separate script. All 6 QIDs match `DEMO-\d{5}`. P001 has dependents P004 and P005.
- Demo run on a temp DB with `reset_demo(simulate_load=True)`: reserved ticket has number and seq None, T-014, people ahead 3, wait 12 min, called with 3 auto-completed, D-GP-023, P-031.
- Seeded waits for GP: Al Wakra 12 min, Airport 36 min.
- Red line: `redirected_emergency` and `deflected_refill` visits were refused by both `issue_ticket` and `issue_active` with the ticket count unchanged. A redirected visit holding an old reservation could not activate.
- Live server on port 7861: health ok with `ai_mode` simulated, patient login, `/api/me` with penicillin and dependents, staff login, stream 200 `text/event-stream` with `: connected`, 401 with no token. Also 403 for a patient token and for another centre's staff. Server stopped and the port confirmed free.
- SSE: `test_sse_e2e.py` was read and passed. A real uvicorn stream delivers `ticket.called` with the vault's keys, published from another thread. `test_display_event_has_no_visit_id` passed.
- Fairness run written from the vault rules: arrival beats reservation order, 65+ goes first with a dependent judged on their own age, `D-GP` numbers stay unique across two doctors, the third no-show goes to the back, a busy counter refuses, and simulated-only gives no called patient.
- Stress: 60 visits on real threads with 3 callers gave no errors, no duplicate numbers and no double live tickets.
- Background expiry: a past-due reservation was released on a running app, and the visit became `expired`.
- 16 deliberate rule breaks in a scratch copy were each caught by the suite.
- Static checks: the AI, wording and secret greps printed nothing, the priority signature check exited 0, and the ordering string is present. No `.env`, DB or `backend/data` appears in git status. `main` equals `origin/main`, `hf` is not installed and the only remote is GitHub.

### Features ticked
Only F02. Left open on purpose:
- F01: the login screen does not exist yet.
- F06: the engine is done, but there are no reserve or arrive routes and no "I'm here" button.
- F07: the engine and counter stream are done, but there are no call-next routes and no visit or display streams.
- F24: dependents are seeded only.

### Known gaps
- **Orchestrator's reading, the owner can overrule:** [[Mock Health System]] says 3-10 fake tickets per counter and queues advancing every ~60 s. `simulate.py` seeds fewer on some counters and has no timer. Build Decisions fix 1 moves simulated tickets on "Call next", and its seed targets need Al Wakra at 12 min. A timer would change those numbers while the demo runs, so this was accepted as overridden.
- **Must act before the demo:** a database seeded on an earlier Doha day is not re-seeded at startup. The next-day run gave T-001 with yesterday's simulated tickets still waiting. The demo needs a reset first, so the later `POST /api/demo/reset` phase must cover this.
- **For the nurse and emergency routes:** `call_next` does not check visit status, and `release` leaves the visit status alone. An escalation route must release the ticket and set the status together.
- **For the fast-forward phase (from reading the code, not run):** after 5 real samples the wait uses real spans, so repeated instant fast-forwards can push a counter's estimate towards 0 until a reset.
- **For the AI and map phases:** no centre lists `mental_health` or `other`, and no doctor has those clinics. Routing must handle them.
- A third no-show takes a fresh sequence value, so one printed number gets skipped. The ticket keeps its own number.
- A priority ticket that hits the no-show limit goes to the back of the priority group only, so it stays ahead of priority 0.
- `/api/auth/demo-patients` returns 4 patients including P006, so the login screen would show a fourth chip. Dependents can also log in with their own demo QIDs (from reading the code).
- Builder report, not re-tested: uvicorn did not exit on SIGTERM while an SSE client stayed connected. Consider `--timeout-graceful-shutdown` at the ship phase.
- The stream's `?token=` value appears in uvicorn access logs. Build Decisions accepts query tokens for the demo.
- Drug default regimens are demo values no clinician reviewed. The README must say so.

## Phase 2: AI layer (approved in review round 1 of 4, 6 Nov 2026)

### Plan
`backend/ai`: red-flag rules with normalisation and negation, LLM and ASR adapter with real and simulated modes and per-turn fallback, simulated AR/EN receptionist, intake schema validation with retry and fallback, banned-output filter and text gate, handoff draft, doctor suggestion rules, plain-language medicines, refill detection, and `ai_mode` on health. Features in scope: F03, F04, F05, F09, F15 and F13 backend.

### What was built
- Layer 1 rules on every message before the model, for the conversation as a whole. A question's sides count when a reply completes a compound, without a yes word: "my baby is sick", "today", "6", "high" now ends in `redirected_emergency`.
- `_asked_sides` keeps vomit and fever once raised unless the reply denies them. Any other side counts only when the reply states a different side of the same compound, so "Is the pain in your chest?", "it is in my stomach" stays quiet.
- Model turn with fixed order, the [[Build Decisions]] text gate, two-attempt JSON handling and scripted fallback for one turn, recorded as `ai.fallback`.
- Server-rendered read-back, server-built `self_medication`, handoff from the effective intake, rule-scored doctor suggestions, deterministic medicines, refill deflection with "I still want a visit".
- `session.staff_view(conn, visit_id, on=None)`, the read-only nurse backstop for the Phase 3 staff route. It returns status, language, turns, patient_words, denied, denied_text, intake, confirmed_by_patient and edited.
- `app.state.ai` built once at startup. Health reports its mode.

No patient or staff AI routes exist yet. They are Phase 3.

### Verdict
Approved. Every acceptance check passed on the orchestrator's own runs. One detail for later readers: in real mode the gate refuses three of the six moved questions ("Any blood?", "Any drooping?", "Any trouble with your speech?") before a patient sees them, so those three were tested by placing the question in the transcript. The rule fires on all six.

### Evidence
- `.venv/bin/python -m pytest -q -rs`: 9731 passed, none skipped, above 9591. All 16 `test_ai_*` files collected.
- Fresh Python 3.12.15 venv from `requirements.txt`: 9731 passed. `compileall` exit 0 on 3.12 and 3.14. `requirements.txt` has an empty diff.
- Red line: 12 runs (6 answers, simulated and real with a fake client) through `session.handle_message` and the real `SqliteQueueEngine` gave `redirected_emergency`, a `redflag.hit` labelled baby with high fever, no model call on that turn, ticket count unchanged and `VisitNotEligible`. 44 further spellings passed, including capitals, diacritics, tatweel and other baby words.
- Split sweep written from the live tables: 10 compound and question rows, 564 cases including sides said before the question and after the reply, 0 misses, no yes word in any.
- Model-asked splits fired in both modes, in EN and AR. Every over-firing case stayed in intake in both modes. All remaining `QUIET_ANSWERS` rows pass in the suite.
- Test integrity: `test_ai_crossturn.py` loses only the 6 named rows, plus an import line widened. `test_ai_acceptance.py` and `test_ai_session.py` have no removed lines, and no other test file changed.
- Demo flows passed in both modes: Fatima to GP intake and a reserved ticket, Ravi to the emergency reply with no ticket and no model call, Ahmed to the refill route and back to GP on "I still want a visit", a nurse edit visible in the handoff draft and in the model's payload.
- Nurse backstop: with a model summary that dropped the detail, the sentence stayed in `turns` byte for byte, with Arabic diacritics. A nurse edit changed intake and left turns unchanged.
- Read-only: every row in visit, intake, event, handoff and ticket identical after a call, `total_changes` unchanged, no row for a no-message visit, works on a `query_only` connection. `history` and `to_api` hold no `summary_for_nurse`.
- `filters.py` is byte-identical to the pre-build copy. Seven banned model replies fell back with `ai.fallback`. A failed model turn fell back once and the next turn used the model. Two invalid JSON attempts fell back.
- Live server on 7862 with outbound network denied by `sandbox-exec` and a socket guard: exactly `{status, ai_mode, simulate_load}`, simulated with a blank token, real with a dummy token, 0 outbound attempts. Stopped and the port confirmed free.
- Mutations in scratch copies, full suite: old `_asked_sides` 74 failed, fever removed 6 failed, `- asked` removed 2 failed, `staff_view` returning summary text 5 failed.
- `accept1.py`: 186 checks, 0 fails. `accept2.py`: 81, 0 fails.
- 1500 random conversations across both modes, with model errors and bad replies mixed in: no crash, no ticket after an emergency, staff words complete.
- All 7 services classified end to end in AR and EN.
- Scope: routers, `queue_engine.py`, adapters and `backend/tests` tracked files have an empty diff. No queue calls in `backend/ai`. No `.env`, DB, `backend/data` or `hf_` token. `HF_TOKEN` blank in `.env.example`. `main` equals `origin/main` at a2ac73a. No Hugging Face or Space work.

### Features ticked
F04 and F05. Left open on purpose, by the same reading as Phase 1:
- F03, F15: the logic is done and verified at the session layer, but there is no chat route or screen.
- F09: draft and suggestions are done, but the nurse confirm step belongs to the console.
- F13: backend adapter only.

### Known gaps
- **Clinician items, under the review stop rule.** A non-yes reply stays quiet when the patient never said the other side: "I am pregnant", "Any bleeding?", "a little". The same holds for "Do you have chest pain?", "a little", and for a reply that only repeats a side the question named when the patient never used a pain word: "Is the pain in your chest?", "my chest", and "Is the pain in your stomach?", "no, my chest". Scripted questions cannot produce the repeat case, which needs a model question naming both sides. If the patient said pain earlier, it fires. In these cases the model still runs and the nurse sees the exact words.
- A "no" to a question in the positive form does not fire: "Is your baby feeding?", "no". The gate refuses that question today, so a patient does not see it.
- Cautious direction, accepted: a reply that names a side can over-fire ("Any pain?", "my chest feels fine"). Raised sides are never retracted on a later turn.
- **Check on the first live run:** the gate refuses some reasonable model questions, such as "هل الألم في بطنك؟" and "Any blood?". That is safe, but the real demo may show more scripted fallback than expected.
- **For Phase 3:** the staff intake route must be staff-authenticated and never reachable from a patient route, because `staff_view` returns `summary_for_nurse`. Add a test when the route exists.
- `turns` holds what is stored: surrounding whitespace is stripped and an over-long message that fires a rule keeps its first 2000 characters. A message on a closed emergency with no rule hit is not stored.
- `denied_text` is English on Arabic visits. Phase 3 can call `redflags.denied_text(view['denied'], 'ar')`.
- The live HF paths are untested, as [[Build Decisions]] expects. The README must say so.
- `mental_health` and `other` have no clinic, so suggestions fall back to a GP with a reason saying so. This settles the Phase 1 routing gap for doctor suggestion. Centre selection still has to handle them.
