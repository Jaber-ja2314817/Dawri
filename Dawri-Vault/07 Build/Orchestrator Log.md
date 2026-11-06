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

## Phase 3: Full API (approved in review round 4 of 4, 6 Nov 2026)

### Plan
`backend/main.py` and routers for every route in [[API]] plus those added by [[Build Decisions]]: SSE streams, centres with wait estimates and the suggestion rule, reserve, arrive with geofence and door code, staff flows, walk-in, fast-forward, reset, stats, the `SIMULATE_LOAD` simulator and static SPA serving. An API-level test walks all three demo patients end to end, and proves that a nurse edit reaches the doctor, that a red flag gives no ticket, and that SSE stays live while a model call blocks.

### What was built
- Routers: `visits.py`, `centres.py`, `staff.py`, `demo.py`, `streams.py`. 38 method and path pairs. Every `/api` endpoint is plain def except the 3 streams.
- `visit_flow.py`: `emergency_today` (dated by when the emergency happened, not when the visit opened), `leave_the_queue`, the allergy check, consult and dispensing.
- `centres.py`: services, distance and the suggestion rule, with no model. `geo.py` for distance. `views.py` for the shared ticket shape. `spa.py` for the frontend fallback.
- Engine additions: `advance`, `finish_visit`, `escalate`, `complete_simulated`, `live_ticket`, `latest_ticket`, and a floor of 30 s on samples so demo clicks cannot move an estimate.
- `session.py` additions only: `start_walk_in`, `desk_red_flag`, `red_flag_past_arrival`.
- `simulate.tick` moves the other centres one ticket at a time and leaves Al Wakra alone.
- Startup resets a database from an earlier day and keeps a same-day one.

The frontend, Dockerfile and README are later work. None were added here.

### Verdict
Approved. Every acceptance check passed on the orchestrator's own runs. The round 3 failure was re-tested and is fixed: a visit opened at 23:50 Doha and flagged at 00:10 blocks a new visit and the desk until 23:59 of the flag's own day, and frees them on the next Doha day. The same holds for a nurse urgent after midnight.

### Evidence
- `.venv/bin/python -m pytest -q -rs`: 10500 passed, none skipped, above 9731. 3 runs in a row, then `TZ=UTC` and `TZ=Asia/Tokyo`, all 10500. All 15 named files collected.
- `test_api_sse_threadpool`, `test_api_e2e` and `test_sse_e2e`: 23 passed, 5 runs in a row.
- Fresh Python 3.12.15 venv from `requirements.txt`: pip exit 0, 10500 passed, `compileall` exit 0. Also exit 0 on 3.14. `requirements.txt` has an empty diff, and there is no `sse-starlette`.
- Route inventory by a flat walk: nothing missing, nothing extra. FastAPI 0.162 hides included routers from a plain loop over `app.routes`, so the script walks `original_router`.
- Live server on 7863 with `SIMULATE_LOAD=1` and a temp DB, my own HTTP scripts:
  - Fatima: reserved ticket with number null, "Check-in valid for 45 minutes" and the Arabic text, T-014 with 3 ahead and 12 min, map Al Wakra first at 12 and Airport 36, call-next auto-completed 3 and called T-014, D-GP-023 on `C-WAKRA-D4`, P-031, completed, medicines in Arabic.
  - Ahmed: `deflected_refill`, 0 ticket rows, reserve refused, `refill/continue` reached centres as GP with his registered centre as default.
  - Ravi: emergency true, `redirected_emergency`, nearest ED, 0 ticket rows. Override wrote one event and returned the staff route. Reserve, arrive, draft, fast-forward, a new visit and the desk were all refused.
  - A red flag after reservation, one in the waiting room, a walk-in chest pain and nurse urgent to ED all left no live ticket for that patient.
  - A red flag on a lapsed visit, a refill-deflected visit and a confirmed intake each ended the visit, and the next reserve or continue was refused.
  - Nurse edit: confirm after an edit gave 409 `draft_required`. After a re-draft the doctor saw the edit in intake and `handoff.final_text`, and turns kept the patient's words byte for byte.
- SSE by `curl -N`: `: connected`, heartbeat inside 17 s of connecting, `ticket.called` with exactly type, visit_id, ticket, counter and people_ahead on the visit and counter streams, and no visit_id on the display. 401 with no token, 403 for another patient and another centre's staff, 200 with `?token=`.
- Nurse backstop: turns sit next to `summary_for_nurse` for staff, 403 for a patient, 401 with none. In real mode with a fake client and marker text in the summary and complaint, no marker and no staff key appeared in any patient response. Arabic denied text is present. A visit booked for a dependent uses the dependent's record, and a dependent's red flag leaves the guardian's ticket alone.
- Arrival: own coordinates, 140 m, button and `DOOR-C-WAKRA` all gave T-014. 200 m gave 409 `too_far`, `DOOR-C-AIRPORT` gave 409 `wrong_door`, and `{"lat":NaN}` gave 422. Arrival order beat reservation order, and a 65+ patient got priority 1 and 0 ahead.
- Expiry: 45 minutes on `engine.clock` gave 410 and `expired`, and a re-reserve then worked. On the running server the background loop released a past-due ticket in 25 s.
- Walk-in: T-014 in arrival order with app patients, schema-valid intake, complaint in turns, and a phone visit could not then take a second place.
- Simulated load: 20 ticks left Al Wakra tickets and sequences identical and Fatima on T-014. Airport triage stayed 6-7 against a seed of 7 and its GP wait stayed 32-36. Labelled "Simulated", and never returned as called. The live 60 s loop was seen ticking.
- Fast-forward and reset: 3 tickets done through the engine with event rows. Refused with nothing changed when a real patient was ahead or a counter was busy. 10 instant runs left the estimate at 480 s. Reset restored T-014, kept tokens and reached open streams. A DB rewritten to an earlier day was reset at startup, and a same-day restart kept its tickets.
- Allergy and medicines: amoxicillin warned, gave 409 `allergy_conflict`, and with acknowledgement succeeded and logged `prescription.allergy_override`. An unknown drug gave 422. No model call for medicine lines in real mode with a fake client.
- Centres: dental lists only Al Wakra, `mental_health` and `other` list GP centres with `service_fallback` true, hospitals only for `emergency` and sorted by distance. A suggestion needed Al Wakra at 52 min and left `default_centre_id` on the registered centre.
- Stats: matched SQL on real rows, with no simulated tickets and no no-show field.
- ASR and modes: 503 with a clear message and no transcript in simulated mode. In real mode with a fake client the transcript returned, a 3 MB upload never spooled to disk, and a spoken red flag fired. Health is exactly `{status, ai_mode, simulate_load}`.
- SPA: `/` and `/staff/nurse` return index.html, a real asset returns itself, `/api/unknown` is JSON 404, 8 traversal paths leaked nothing, `/docs` works, and no build gives a JSON 404.
- 834 concurrent HTTP calls over 3 patient flows and 4 pollers: all 200, no duplicate numbers, no errors in the server log.
- Fuzz of 34 bad bodies and ids: no 5xx.
- Greps and scope: wording, queue calls under `backend/ai` and the priority signature check are clean. `filters.py` and `redflags.py` have an empty diff, `session.py` has additions only. No frontend or Dockerfile, no `.env`, DB, `backend/data` or `hf_` token in git status. `HF_TOKEN` blank in `.env.example`. `main` equals `origin/main` at a2ac73a. Only the GitHub remote. Nothing staged. No commit. Server stopped and the port confirmed free.
- Mutations in scratch copies, full suite: async chat with a blocking fake, dropped release in chat, `staff_view` in a patient route, no draft clear, no sample floor, no protected-centre check, no `not_next_in_queue` (either site), `created_at` dating, no emergency check at arrive, no emergency check at reserve. All 11 failed. Each copy also fails `test_env_example_lists_the_static_dir_blank`, only because `.env.example` is not copied, and each has at least one other failure. The async chat copy fails `test_a_slow_model_does_not_stall_sse`.

### Features ticked
F07 and F19. F19 because [[Build Decisions]] 8 asks only that the backend accept `{qr_code}`. Left open on purpose, by the same reading as Phases 1 and 2, because each still needs its screen:
- F01, F08, F10, F11, F13, F14, F16, F17, F18, F20, F21: no screen yet.
- F03, F09, F15, F24: routes are done and verified, screens are not.
- F06: routes are done and verified, the "I'm here" button is not.
- F12: Hugging Face is later work.

### Known gaps
- **For the owner to read:** a chat message sent to a **completed** visit is refused with 409 and the rules do not run on it. If the same patient holds a live ticket on another visit, a red-flag message sent there leaves that ticket live (run, not just read). Only a client that offers chat on a completed visit can reach it, so it stayed out of the failures. **The frontend must not show a chat box on a completed visit.** A later fix could run the rules there.
- From reading the code, not reproduced: a sibling visit flagged in the milliseconds between reserve's emergency check and the issue can leave a reservation, which arrive then refuses. The same window at the walk-in desk would leave an active ticket.
- **Must act before the demo, from reading the code:** a server left running past midnight does not reset. Numbers restart at T-001, and once any row exists for the new day a restart will not reset either, because the startup check only asks whether today has a row. Press the demo reset before going on stage.
- The display routes need a staff token, so the TV must log in as staff.
- `emergencies_redirected` counts by the day a visit opened, so a flag after midnight counts on the earlier day.
- `NEAR_KM = 12` for the suggestion is a builder's value. The vault only says "near".
- A nurse edit shows in the patient's own `intake` view, for its whitelisted fields only.
- The patient routes read `timeutil.utcnow` and the desk reads `engine.clock`. They are the same function in production, but a test that patches one needs to patch both.
- `.venv/bin/hf` exists as an entry point of `huggingface_hub`. `hf` is not on the PATH, and nothing was set up with it.
- The live HF paths are untested, as [[Build Decisions]] expects. The README must say so.

## Phase 4: Patient app (approved in review round 1 of 4, 6 Nov 2026)

The builders finished before a restart and the first review was cut off. This review ran in a new session against WIP commit `cb61c24`, with [[Resume Point]] and `07 Build/phase4-handover.json` as the record. Nothing was rebuilt.

### Plan
`frontend/` with Vite, React, Tailwind, router, AR/EN with RTL, a PWA manifest, the API and SSE client, and S01 to S12 with consent, dependents, chat, voice with WAV conversion and transcript confirm, emergency, refill, Leaflet map with list fallback, reserved countdown, live ticket, visit complete and history. Four tasks in three waves, plus three small backend additions. Features in scope: F01, F11, F13, F14, F17, F18, and the screens that F03, F06, F15 and F24 were waiting for.

### What was built
- Frontend, 112 tracked files: pages, `features/chat`, `features/map`, `features/ticket`, `voice/`, `i18n/`, `state/`, 16 unit test files with 275 tests, 13 Playwright specs with 38 tests, `scripts/inspect-all.mjs`.
- Backend: `GET /api/visits/{id}` gains `refill` and `rating`. `GET /api/visits` rows gain `centre` and `completed_at`. New `POST /api/visits/{id}/rating`, stored as one `visit.rated` event. `test_api_patient_app.py` is new with 37 tests, `test_api_redlines.py` gains one route line, and `test_api_visits.py` gains 4 lines that widen two stale key sets.

Decisions the vault left open, taken at planning. The owner can overrule any of them:
- Manifest only, no service worker, so a cached page cannot serve a stale build on stage.
- S02 chips show the three demo patients. P006 logs in by typing the QID.
- S11 follow-up is fixed safety-net text. "Message your centre" shows a demo notice, because the seed has no refill channel.
- No chat box after intake is confirmed, including on S10. No door-code UI.
- Arrival happens on a tap. Geolocation is never requested on page load.
- Language: Arabic before login, then the record's language until the viewer taps the toggle, kept until logout.

### Verdict
Approved. Every acceptance check passed on the orchestrator's own runs, with one disclosure on the backend check. The first fresh Python 3.12 run had 1 failure out of 10539, in a Phase 3 race that was already there. It is explained under known gaps. The check limiting `backend/` changes predates the `test_api_visits.py` edit, which the review brief allows.

The Phase 3 known gap is confirmed closed. `screensFor` lists chat only for an unconfirmed intake, and `VisitGate` guards every visit screen. A deep link to chat on a completed visit landed on S11 with no text input, in the spec and in my own run. The same holds for reserved, in-triage and emergency visits.

### Evidence
- Clean `npm ci`, typecheck, `npm run test` (275 passed), `npm run build`: all exit 0. Exact versions, lock file present.
- `.venv/bin/python -m pytest -q -rs`: 10539 passed, none skipped, twice. `test_api_patient_app.py` collected 37.
- Fresh Python 3.12.15 venv from `requirements.txt`: first run 1 failed and 10538 passed while my browser scripts ran alongside. Then 3 runs with nothing else running: 10539 passed each. `compileall` exit 0. `requirements.txt` has an empty diff.
- Backend scope: only `routers/visits.py` and the three test files differ from `5df531c`. `filters.py`, `redflags.py`, `session.py` and `queue_engine.py` have an empty diff. `test_api_redlines.py` differs by the one rating line.
- `npm run e2e`: 3 runs in a row, 38 passed, 0 skipped, exit 0, all 13 specs. I read the specs: patient steps go through the UI, staff through the API, and no `skip`, `fixme` or `only` exists.
- Fatima, my own script on port 7865 with `SIMULATE_LOAD=1`, a temp DB and `frontend/dist`: chip login, consent, the Arabic sentence, summary, confirm. Pins Al Wakra 12 and Airport 36. Reserve showed `تسجيل الوصول صالح لمدة 45 دقيقة`, 45:00 then 44:58, no number on screen and `number` null in the API. I'm here gave T-014, 3 ahead, 12 min. Staff calls in a second session, no reload: called 23 ms, serving 24 ms, D-GP-023 12 ms, P-031 12 ms, S11 19 ms, with Arabic medicines. 0 page errors. Rating left `/api/stats` unchanged and survived a reload.
- Ahmed: S07 with amlodipine, reload kept it, 0 ticket rows, I still want a visit reached S08 with C-RAYYAN first.
- Ravi: full red field, `tel:999`, Hamad General Hospital, 0 ticket rows. Back twice stayed on S06. One `emergency.override` event and the staff route. Home then Start check-in returned to the same visit on S06 with no input, and a deep link to chat did too.
- Real mode with a stand-in client, the same seam the tests use, in the browser: the AI footer line goes, a banned model reply never reached the screen and showed the scripted note, the summary card and confirm worked, a model `emergency` reached S06, and marker text in `summary_for_nurse` never appeared in the DOM or the patient GET. The browser's upload reached the server's ASR client as 16 kHz, mono, 16-bit WAV. The transcript waited for Send with 0 chat POSTs, then a spoken red flag reached S06 with no ticket.
- Adversarial runs in the browser: a red flag in a correction at the summary, AR and EN, reached S06 and confirm was then refused. A stale tab lost its chat box as soon as another tab reserved. A second patient's people-ahead figure updated live. Another patient's deep link showed only "no access". A demo reset under an open chat went Home. Dental listed only Al Wakra, and mental health showed the GP note.
- Map: with `tile.openstreetmap.org` blocked, S08 fell to the list with the notice and a reservation completed. With tiles, pins showed wait badges and the registered centre came first.
- Live updates: stream open under 25 ms. Stream aborted, polling delivered in 1.8 s.
- Geofence: own coordinates gave T-014, 200 m showed `too_far` with 200 and 150, denied location left I'm here working, 0 geolocation calls before a tap.
- `npm run inspect` against a `build:inspect` server: exit 0, 40 screens at 1440 and 390, 0 FAIL, 54 WARN. Allowances confirmed from each `report.json`: `kpi-size` on S10 and `colour-sprawl` on S06 only. `lint.mjs --app src`: 0 FAIL. I read S03, S05, S06, S08, S09, S10 and S11 at 390 in Arabic, and S06, S08 and S10 at desktop.
- Greps on `frontend/src` and `dist`: banned wording, physical left and right CSS, gradient, blur, indigo, violet and emoji all print nothing outside the test that lists the banned words. `#1d5fbf` sits only on the ticket number, the current step and the selected pin. No browser storage in `src/voice`. `inspect_token` is in 0 `dist` files.
- PWA: manifest served as `application/manifest+json`, 3 icons 200 `image/png`, deep links return the SPA, no service worker. The icon is the plain word دوري.
- Mutations in a scratch copy, each failing its named suite: chat allowed on completed (`stages.test` and `safety.spec`), emergency navigate removed (`ravi.spec`), auto-send (`voice.spec`, 4 failed), `encodeWav` at 44100 (`voice.spec`), tile fallback removed (`map.spec`), footer dropped on the emergency tone (`shell.spec`), and my added one, Back guard removed (`ravi.spec`).
- Scope: no Dockerfile or README. No `.env`, DB, `node_modules`, `dist` or `.inspect-dist` in git status. No `hf_` token. `HF_TOKEN` blank in `.env.example`. `main` equals `origin/main` at a2ac73a, only the GitHub remote, `hf` not on the PATH, `.obsidian` unstaged. All servers stopped and ports 7865, 7866, 8142, 8143 and 8155 free.

### Open issues from the builder reports
Closed:
- T1 and T4, stale backend tests: widened, suite green.
- T1, T2 and T3, Playwright's Chromium: specs use `channel: 'chrome'`.
- T1, S05 `fill`: in use.
- T1, no stream event on chat: chat uses the response and refetches.
- T2, the mutation risk on the emergency navigate: T4 added the spec, and the mutation now fails `ravi.spec`.
- T2, the Fatima sequence: either answer set reaches the summary.
- T2 and T3, brand link width: fixed, and the 390 sweep passes.
- T2, `npm run inspect` missing: now exists and was run.
- T3, repeated medicine name: S11 splits the line.
- T3, `.inspect-dist`: gitignored.
- T4, inspector setup: the steps are at the top of the script.
- T4, the live Fatima run: done above.

Known gaps are listed below.

### Features ticked
F01, F03, F06, F11, F13, F14, F15, F17, F18 and F24. F13 and F03 are ticked on the scripted path and a stand-in client: the live models stay untested, as [[Build Decisions]] expects, and the specs replace `getUserMedia`. Left open on purpose: F08, F09, F10, F16, F20 and F21 wait for the staff consoles, and F12 for Hugging Face.

### Known gaps
- **Fix in Phase 5 or 6, may flake the suite until then:** `queue_engine.position` reads the ticket, then the active list, on separate reads. If call-next takes that ticket between them, `order.index` raises ValueError and `POST /arrive` or `GET /api/visits/{id}` returns 500. `test_arrivals_racing_call_next_keep_each_ticket_once` hit this in 1 of 4 full Python 3.12 runs, the one with other work running. It passed 50 of 50 on its own (25 on each Python), the other 3 Python 3.12 runs and both Python 3.14 runs. No ticket, number or order goes wrong. With a forced 500 on arrive the screen still reached S10 through the stream, and a failed refresh keeps the last good screen. The fix sits in `queue_engine.py`, which this phase's check holds at an empty diff.
- **Orchestrator's reading, the owner can overrule:** [[Build Decisions]] 7 asks for "a 3-tap flow for each demo patient via quick-pick chips". I read that as chip, Start check-in, I agree. Ahmed and Ravi reach chat in 3 taps. Fatima takes 4, because she has dependents and S04 asks who the visit is for. The sentence is then typed or spoken.
- **Before the demo:** Airport reads 36 only soon after a reset, because simulated load drains the other centres (builder report). Reset before going on stage.
- **For the owner to read:** text typed into the box or held in the transcript step at the summary is dropped if the patient taps "Yes, that's right" instead of Send. Rules run only on what is sent, so a cue in unsent text is never read. Nothing fires, and the nurse sees only sent words.
- From reading the code, not reproduced: a patient who leaves chat while a red-flag reply is in flight lands on Home with no emergency shown. Start check-in then reaches S06.
- In real mode the scripted-assistant note lasts for the page's life, because `chat.messages` has no per-message `ai_source`. The event log still records `ai.fallback`.
- The emergency reply follows the patient's language, not the toggle, so an English reply can sit under an Arabic title.
- S07 shows the medicine in English on an Arabic screen, as stored in the record. `i18n/record.ts` has the Arabic, so this is a small change if the owner wants it.
- Builder report, not re-tested: in simulated mode a severity correction after the summary is ignored. A duration correction works. The nurse still sees the patient's words.
- Builder report: one unexplained false map fallback in about 100 loads, before T4 hardened it. None in my runs. The cause is not proven, `data-reason` now names the path, and the list stays usable.
- Inspector WARNs kept: `hero-void` on 38 desktop screens from the phone-width column, `tiny-text` on 11 from the mandated footer, `app-title-size` on 4 S06 screens, `blank-gap` on S01-en.
- S03 shows the name, centre and allergy, with no greeting word and no age.
- `endpoints.sendChat` and `demoPatients` are unused. `frontend/e2e` and `frontend/scripts` are not typechecked.
- Unverified here: a real microphone, iOS Safari and live Whisper. `getUserMedia` and geolocation need HTTPS on a phone, so plain LAN http falls back to typing and the I'm here button.
- `/staff/*` renders NotFound until Phase 5.
- For the ship phase: the README must carry the two design exceptions and the untested-live note, and the Docker build needs Node 20.19 or later, so use `node:22`.
