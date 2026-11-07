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

## Phase 5: Staff consoles (approved in review round 2 of 4, 6 Nov 2026)

### Plan
`/staff` screens T01 to T09 in the same frontend: login, nurse queue, intake card with vitals and urgency, handoff confirm, doctor queue with prescription picker and allergy warning, pharmacy, front desk walk-in, waiting-room display, dashboard, demo reset and fast-forward. Live through SSE, `ai_mode` always visible, same design rules and inspector. Five tasks in three waves, then one round of two small fixes. Features in scope: F08, F09 (the nurse confirm step), F10, F16, F20 and F21.

### What was built
- Backend, small on purpose: `db.read_snapshot` around the reads in `queue_engine.position` and `queue_snapshot`, `GET /api/staff/me`, `red_flags_raised` and `arrived_at` on the staff visit, `text_ar` on the draft. `test_queue_position_race.py` and `test_api_staff_console.py` are new. `test_api_redlines.py` changes by one line, the staff route count from 19 to 20.
- Frontend: `pages/staff`, `features/staff`, `components/staff`, `state/staff` with a separate staff token and the generic `useLive` hook, `api/staff.ts`, 8 staff dictionaries, 6 staff specs and the T screens in `inspect-all.mjs`. No new dependency.

Decisions the vault left open, taken at planning. The owner can overrule any of them:
- Staff have their own token, so a patient and a staff session sit side by side in one browser. `sessionStorage` keeps each tab its own person.
- Consoles default to English, with the toggle present. T08 always shows both languages.
- The reset control sits in the staff shell, behind two taps. T08 has no shell and no reset.
- The label for the no-show route is "Not here", because [[Build Decisions]] 3 bans the word.
- The doctor gets no preselected medicine, and a chosen medicine with no second acknowledgement cannot be sent.
- At most one EventSource per tab. Dashboard and desk poll, and a hidden tab closes its stream, so plain HTTP/1.1 on the demo laptop stays under the browser's six connections.
- T08 and T09 need a staff login, as Phase 3 accepted.
- `text_ar` is the fixed Arabic template and is labelled as not following edits.

### Verdict
Approved. Every acceptance check passed on the orchestrator's own runs in round 2. Round 1 failed two checks, and both are re-tested and closed:
- BACKEND: the pinned staff route count. Fixed by the one-line test change, and suites are green.
- LANGUAGE: six backend error codes had no entry. They now have AR and EN entries, and two separate enumerations of the backend codes find none missing.

### Evidence
- Clean `npm ci`, typecheck, `npm run test` (510 passed, 29 files), `npm run build`: all exit 0. `git diff 0dcc28e` of `package.json`, the lock file and `requirements.txt` is empty.
- `npm run e2e`: 3 runs in a row, 143 passed each, 0 skipped, exit 0, all 19 specs, including the 38 patient tests and all 6 staff specs (105 staff tests). The skip, fixme and only grep prints nothing. I read the staff specs: `staff-demo` drives every staff step through the UI, and the others use the API only for set-up around the screen under test.
- `.venv/bin/python -m pytest -q -rs`: 10559 passed, none skipped, twice. Fresh Python 3.12.15 venv from `requirements.txt`: pip exit 0, 3 runs of 10559 passed, none skipped, the third with `npm run e2e` alongside. `compileall` exit 0 on both Pythons. `test_arrivals_racing_call_next_keep_each_ticket_once` passed 25 of 25 alone.
- Race fix: `test_queue_position_race.py` forces the call deterministically, and it fails with ValueError in a scratch copy with `read_snapshot` removed from `position`.
- Scope: the tracked backend diff is `db.py`, `queue_engine.py`, `routers/staff.py` and `test_api_redlines.py`, plus the two new test files. `backend/ai`, `visit_flow.py` and `routers/visits.py`, `demo.py` and `streams.py` have an empty diff. Patient pages and the chat, map and ticket features have an empty diff.
- API: a flat walk of 40 routes finds only the 3 streams async. `/api/staff/me` returns staff, centre, counters and centre_counters, 401 with no token, 403 for a patient token. Health is exactly `{status, ai_mode, simulate_load}`.
- Fatima live, my two-browser script on 7867 with a temp DB, `SIMULATE_LOAD=1` and a copy of `dist`: reset from the shell, T-014 on the nurse table with no reload in 61 ms (40 ms on the first run), 3 grey Simulated rows with no name. Call next auto-completed T-011 to T-013, never showed one as called, and called T-014. Penicillin, vitals, scripted label, Dr. Noor with reason, `in_triage` until confirm, D-GP-023 on the phone, Done, P-031, Dispensed, S11 with Arabic medicines. 0 page errors.
- Nurse backstop: 11 turns equal the API, Arabic diacritics byte for byte, also during editing and after the summary was edited. In real mode with a stand-in client, a marker in `summary_for_nurse` showed on T03 and never in the patient DOM or any patient response.
- Denied and flags: "Patient denied: chest pain" in English and المريض نفى: ألم في الصدر on an Arabic console. A flagged visit shows its flags from `red_flags_raised`, never "none detected".
- Nurse edit: edited complaint, re-draft, edited line, and a second edit from another session while T04 was open. Confirm gave the re-draft and a clear sentence, stayed `in_triage` and kept the nurse's text. T05 showed both edits.
- Nothing sent without confirm: `in_triage` and no row on either doctor queue before confirm. A non-suggested doctor got the ticket on C-WAKRA-D3. Urgency has no default and the primary action stays disabled until one is chosen. A service changed on T03 reached T04: a dentist was suggested.
- Draft honesty: scripted label in simulated mode. Model label in real mode. A banned draft fell back, was labelled scripted, and `ai.fallback` recorded `banned_output`.
- Urgent: the first tap changed nothing, the second left no live ticket, and the phone reached S06 with no reload.
- Allergy: nothing preselected, warnings on amoxicillin and co-amoxiclav before selection in AR and EN, Done disabled until the box is ticked. Adding a second warned medicine cleared the tick. Two warned medicines wrote exactly one `prescription.allergy_override`. Layla's visit showed no warning, no box and no event on amoxicillin.
- Pharmacy: T06 showed the prescription and medicine lines, and Dispensed completed the visit. An empty prescription completed with no P ticket. A chosen medicine and its note survived "Patient here" and a poll.
- Walk-in: Salem by chip got T-015 after T-014 and appeared on T02 in 57 ms with no reload, complaint in turns. A second walk-in was refused. English and Arabic chest pain gave the emergency panel, 0 ticket rows and no number. Ravi's QID after an emergency was refused.
- Display at 1920, 1440 and 390: 1 chime per call, none on first snapshot, serve, reconnect or reset. Sound toggle works. No sideways scroll. The round 1 network assertion was too loose, so this round hooked the page's EventSource and filtered to `/api/` responses: no name or visit id in 12 API bodies, 10 stream messages, URLs or the DOM.
- Dashboard: every figure equalled my SQL at 7 points: seed, walk-in, refill, emergency, at doctor, at pharmacy, completed. 0 prints 0, a null wait prints a dash, no no-show text.
- AI mode: 40 of 40 screen combinations, T01 to T09 at 1440 and 390 in AR and EN, simulated and real, visible and in view with no menu open.
- Fast-forward: labelled Demo, completed through the normal engine with event rows, the phone reached S11 with no reload. With a real patient ahead it showed "Another patient is next at this counter." and changed nothing.
- Reset: two taps. T03 and T04 went to the queue with a notice, the phone went Home, no reload, seeded rows back, T-014 reached again, no errors.
- Stream drop: polling delivered in 4.4 s, `live-state` read Reconnecting, back to live 10.8 s after restore.
- One profile: six role tabs plus a patient tab completed a full Fatima run. Desk and dashboard held 0 open EventSources. Hidden-tab closing is confirmed in `useLive.test.tsx` and `staff-live`.
- Sessions: patient token and language survive staff login and logout. A reload keeps the console, a wrong role redirects, and `/staff/unknown` shows the staff not-found page signed in and out.
- Language: every staff pair has identical keys. The banned-phrase grep prints only the test's own list. 60 backend codes all have `error.` entries in AR and EN. The toggle sets rtl and ltr on T01 to T07 and T09, and T08 stays fixed.
- Design: `npm run inspect` exit 0, 68 screens, 0 FAIL, 95 WARN. `report.json` confirms `kpi-size` only on t08 and s10, `colour-sprawl` only on s06. `lint.mjs --app src`: 0 FAIL, 3 WARN.
- Screens read at 1440 and 390 in Arabic and English: T02, T03, T04, T05, T08 and T09. app-screens 2.7: (1) the called number, the patient's words beside the card, the draft, the handoff, the serving numbers and the waiting counts are the largest thing on their screens. (2) Blocks share the edges, and no stretched card or dead strip. (3) Colour sits only on numbers, the penicillin pill, the warning and status, with near-black on the primary action. (4) Numbers agree: T09 1 + 0 + 0 = 1, and the T-014 and D-GP-023 copies match in each screen's rows and banner. (5) Zeros print 0, and missing values are dashes. (6) No charts. (7) Navigation folds on the phone, and each block still answers its question.
- Kept WARNs: `hero-void` and `blank-gap`, a short queue leaves honest canvas. `ragged-row`, a transcript is never padded or clipped. `tiny-text`, the mandated footer and 12 px pills. `panel-void` on t08, a dash cell holds a number's height. `numeric-align` at 390, folded rows. `app-title-size`, the Phase 4 keep. Lint: `padStart` in clocks and the dash placeholder.
- Greps on `frontend/src`: no physical left or right CSS, gradient, blur, indigo, violet or emoji. Sizes over 30 px sit only in `display.css` and in the S10 number, the Phase 4 [[Build Decisions]] exception. `#1d5fbf` is only the data token. `inspect_` is in 0 `dist` files. In `dist` the only hits are vendor: Leaflet's physical CSS, a Tailwind transition variable name, and two emoji in React Router's developer message, which is not rendered.
- Mutations in a scratch copy, 11 of 11 failed their named suite: patient-words, ai-mode, simulated label, allergy warning, acknowledge true, Done gate (unit and `staff-doctor`), desk number, first-snapshot chime (unit), stream ignored with poll stretched, patient token, position snapshot. Each named e2e suite ran with `--max-failures=1`, so each result is the first failing test.
- Scope and safety: no Dockerfile or README. No `.env`, DB, `node_modules`, `dist`, `.dist-*` or `.inspect-dist` in git status. No `hf_` token. `HF_TOKEN` blank in `.env.example`. `main` equals `origin/main` at a2ac73a, also by `git ls-remote`. Only the GitHub remote, `hf` not on the PATH, `.obsidian` unstaged, nothing staged. All servers stopped and every port I used is free.

### Open issues from the builder reports
Closed:
- P5-T1 and P5-T5, route count: fixed in round 1.
- P5-T1, `voice.spec` failure: did not reproduce in 6 full runs across two rounds.
- P5-T1, inspector coverage and the `kpi-size` allowance: added and confirmed from `report.json`.
- P5-T1, `arrived_at`: accepted, tested, and needed by the banner.
- P5-T1, hidden-tab behaviour in a real browser: covered in `staff-live`.
- P5-R1-T2, `invalid_request`: it has AR and EN entries. Only the test list is missing it, see below.

Phase 4 gaps closed by this phase:
- The `queue_engine.position` race. Fixed with one read snapshot, covered by a deterministic test.
- `/staff/*` rendering NotFound. Every route now has its screen, and an unknown staff path has its own page.

The rest are under known gaps.

### Features ticked
F08, F09, F10, F16, F20 and F21. F09 is ticked on the scripted path and a stand-in client: the live model stays untested, as [[Build Decisions]] expects. F20 is covered by T07, as [[Build Decisions]] 8 says. Left open on purpose: F12 waits for Hugging Face, and F22 and F23 are dropped.

### Known gaps
- **For the owner to read:** text typed in T03's edit form and not saved is dropped if the nurse presses Confirm & generate handoff (from reading the code). The draft on T04 then shows what was saved, and the nurse reads it before confirming.
- **For the owner to read:** an Arabic T05 reads "حساسية مسجلة: penicillin", because `visit_flow.allergy_conflict` puts the record's English term in `text_ar`. The warning and the gate work. `visit_flow.py` is held at an empty diff this phase. `i18n/record.ts` has the Arabic.
- `red_flags_raised` pills show English labels on an Arabic console, because the API returns English only. The flag still shows.
- On an Arabic console Latin digits take different glyph shapes from the English console, as on T09 and T-014. CDP reports a custom IBM Plex font in both, so this is no system fallback.
- T03 says "AI summary" and "Reason (AI)" in simulated mode, matching the vault's card, with "AI: simulated" always in view. T04 is the only surface that labels the draft's source.
- When a raised flag exists, T03 shows it and hides any "Patient denied" line on the same visit. Such a visit is already an emergency.
- On a phone, Reset demo leaves the menu sheet open after the second tap, so the done notice sits behind it. The reset works, and the demo uses the laptop.
- `PUT /api/visits/{id}/intake` publishes no event, so a second nurse tab on the same T03 shows an edit only at the 20 s backstop. T02 tabs stay in step.
- From reading the code, not reproduced: two nurse tabs on one visit, where tab B edits and re-drafts, leave a draft row, so tab A can still confirm its older text. T05 still shows the edited complaint from the intake above the final text.
- A staff tab sends the patient's token on `GET /api/me` and `GET /api/health` when a patient is signed in beside it. Every staff route carries only the staff token.
- A new tab in one profile opens as the last person to sign in, so a second role needs Log out in that tab. Open tabs keep their own session. The demo uses separate browsers or logs out first.
- Staff logout does not reset the language, so a patient on the same browser is not disturbed.
- The reset status line is carried in router state, so a reload straight after a reset shows it again.
- `PatientBanner` shows a 24 px dash in the data hue when the ticket is null, as on T03 after an emergency.
- T06 shows the allergy pill in the banner but no per-medicine warning on an acknowledged override.
- `ERROR_CODES` in `i18n.test.ts` lists 59 of the 60 backend codes. `invalid_request` has its entries but no test guards it.
- `field-sizing` on the T04 textarea was tested in Chrome only. Older Safari falls back to 8 rows with scrolling.
- `frontend/e2e` and `frontend/scripts` are still not typechecked (Phase 4 gap).
- The other Phase 3 and 4 gaps stand, including the ones marked before the demo: press Reset before going on stage, and a server left running past midnight does not reset. The live HF paths are untested, and the README must say so.

## Phase 6: Integration and ship-ready (approved in review round 4 of 4, 7 Nov 2026)

### Plan
Close the build in two waves: fix the logged Phase 4 and 5 defects and write the container, then prove the whole app end to end. Headless Chrome against the production build served by FastAPI, in Arabic and English, through Fatima, Ahmed and Ravi, with patient and staff in separate browser contexts. A timed run of the [[Demo Script]]. A multi-stage image that runs as uid 1000 on 7860. `.env.example`. A README that is both the Space card and the setup guide. Nothing pushed, deployed or tagged for a registry.

### What was built
- Fixes for 18 of the logged gaps across the backend, nurse screens and patient screens, including the Yes gate at the summary, Arabic allergen and flag labels, the intake edit event, the stale-day check on restart, the draft id, the T03 scripted labels and the S06 reply following the toggle.
- `Dockerfile`, `.dockerignore`, `requirements-dev.txt`, `frontend/scripts/docker-check.sh`, `frontend/scripts/e2e-container.sh`, `backend/tests/standin_server.py`, `test_ship_files.py`.
- `frontend/e2e`: `acceptance`, `journeys`, `demo-timed` and `real-mode` specs, 23 spec files and 178 tests in all.
- `README.md` and a commented `.env.example`.

Round history. Round 1: the reset race, T03 labels in real mode, and README facts. Round 2: the reset race not fully closed, and pytest depending on the time of day. Round 3: two spec defects, `voice.spec` stopping a recording too early and a race in `shell.spec` `walk()`. Round 4 reviewed the two-line fixes for those and reran everything.

### Verdict
Approved in round 4. Every acceptance check passed on the orchestrator's own runs, with two disclosures, because the owner's own work overtook them during the review:

1. **`hf` is on the PATH.** The check as written no longer holds. The owner ran the installer from their own prompt at 03:34 Doha, which the session transcript shows. No build agent ran it: I searched the tool calls of the agents that mention it. What the check protects still holds, since the build did no Hugging Face work.
2. **The README has two status lines that are now out of date.** See "For the owner to read" below.

### Acceptance tests of [[01 Enhanced Prompt]]

| Test | Result | Evidence |
|---|---|---|
| A1 Arabic voice | Pass, on the stand-in server | عندي حرارة وكحة من ثلاث أيام: GP intake, T-014, 0 `ai.fallback` rows. Whisper and the microphone are stand-ins. The live model has not been tried on this path |
| A2 chest pain | Pass | S06, `tel:999`, Hamad General Hospital, 0 ticket rows |
| A3 refill | Pass | Refill route, 0 ticket rows, status `deflected_refill` |
| A4 reserved until arrival | Pass | Reserved with no number or seq, a walk-in took T-014, activation gave T-015 at the end, 4 ahead |
| A5 nurse edit | Pass | The T03 and T04 edits show on the doctor's T05, and the original summary does not |
| A6 two browsers | Pass | No reload. To the table 40 to 50 ms, called 30 to 39, D ticket 48 to 64, P ticket 54 to 55, complete 32 to 53. Limits 1500 and 2000 |

### Evidence
- BUILD: `rm -rf node_modules`, `npm ci`, `typecheck`, `typecheck:e2e`, `test` (572 passed, 31 files), `build`: all exit 0. The package diff from `dd4fc93` is the 2 scripts, the `@types/node` 22.19.1 pin, and that pin's `undici-types` lock entry.
- BACKEND: `.venv` Python 3.14 twice: 10730 passed, 0 skipped. Fresh Python 3.12.15 venv from `requirements-dev.txt`: pip exit 0, 3 runs of 10730, 0 skipped, the third beside `npm run e2e`. `compileall` exit 0 on both.
- E2E: `npm run e2e` 3 in a row: 178 passed each, 0 failed, 0 skipped, 0 retries, exit 0, 23 of 23 spec files, 7.8 to 7.9 min, channel chrome, headless, `frontend/dist` on uvicorn. The grep for `.skip`, `.only` and `fixme` prints nothing. I read the acceptance, journeys, demo-timed and real-mode bodies: steps go through the UI and the assertions can fail.
- Round 3 failures re-verified, both closed, each with a control. Voice: 30 of 30 with the hold, and removing the hold failed 1 of 4. `walk()`: a sweep of `/api/me` delays 0 to 44 ms passed 135 of 135, and removing the fix failed 27 of 45 with the reported signature.
- JOURNEYS: `journeys.spec` passed all six in every run. My own two-context script on a temp DB: Fatima in Arabic and in English reached T-014, D-GP-023, P-031 and S11 with medicines in the screen's language, dir and lang right, no reload, 0 page errors, 0 failed `/api/` responses, updates in 31 to 109 ms.
- TIMED RUN: at the assumed pace table, real time. Budgets Fatima 90, Ahmed 25, Ravi 25, whole 180. This is no human rehearsal.

| Run | Fatima | Ahmed | Ravi | Total |
|---|---|---|---|---|
| 1 | 78.10 | 15.01 | 15.00 | 148.33 |
| 2 | 78.03 | 15.00 | 15.01 | 148.28 |
| 3 | 78.04 | 15.00 | 15.00 | 148.33 |
| Container | 78.10 | 15.00 | 15.00 | 148.36 |

- DOCKER: `docker build --no-cache -t dawri:local .` exit 0, node 22.23.4 and python 3.12.16, 313 MB, arm64, user 1000. `docker-check.sh` 9 of 9 PASS, stop 3406 ms with a stream open. This build had the real `.env` in the context. My scan of 7114 files in the image found no `.env` and 0 matches for the real token by hash. The 53 token-shaped strings are Rust symbol names in `hf_xet`.
- AMD64: `--no-cache` build exit 0, 288 MB. `docker-check.sh` 9 of 9 PASS under emulation, stop 3352 ms.
- CONTAINER E2E: read-only, uid 1000, `dawri:local` on 127.0.0.1:7860: 175 passed, 0 skipped, exit 0, 22 specs. `real-mode.spec` is not run, because the stand-in server is deliberately not in the image. Accepted.
- SWITCH-ON: `--network none` and a dummy token: `ai_mode` real, chat fell back in 0.02 s against a 15 s limit, 1 `ai.fallback` row, `/api/asr` 502 with no transcript.
- FIXES: I located a guard test or spec for every item, and no `frontend/src` or `backend` file changed since round 3. Browser, my own run: T05 Arabic shows البنسلين outside the nurse-signed card, Arabic flag pills, second nurse tab in 48 and 61 ms, S06 follows the toggle, S08 Yes disabled with text and enabled when empty, S07 Arabic medicine, T06 row warning, T08 both languages, no "AI summary" on simulated T03.
- MUTATIONS: 10 of 10 killed on green controls. Yes gate: `safety.spec:179`. Red flag off: A2, no move to S06. Number at reserve: A4, stopped first by the database's own CHECK constraint, so that guarantee has two layers. Doctor shown the original: A5. Stream ignored: A6. Intake event removed: `staff-nurse.spec:352`. Stale check reverted: `test_a_restart_past_midnight_resets_once_the_new_day_has_a_row`. Arabic allergen reverted: 4 tests. T03 label: `staff-nurse.spec:332`. USER line removed: `test_dockerfile_runs_as_uid_1000_on_port_7860`, and docker-check FAIL 1 at `pid1_uid=0`.
- README: `test_ship_files` passes, 57 tests. I read it whole: valid card, setup, env table, simulated and real, untested paths, microphone, iOS Safari, proxy and SSE, unreviewed red flags and regimens, both design exceptions, numbered Hugging Face steps, demo-day checklist. No banned claim. The timed line reads 148 s, which matches.
- `.env.example`: keys equal the 9 in `config.py`, `HF_TOKEN` blank, one comment per key.
- DESIGN: `npm run inspect` exit 0, 68 screens, 0 FAIL, 95 WARN. `kpi-size` only on S10 and T08, `colour-sprawl` only on S06, from `report.json`. Lint 0 FAIL, 3 WARN, exit 0. I read T03, T05, T06, S05, S11 from my own run. Greps clean: the only hits are `onBlur` and the CSS `::backdrop` selector. `#1d5fbf` is only the data token. 0 emoji. All 7 dictionary pairs have identical keys.
- RED LINES: no "place held" or no-show in user-facing strings, the only hits being API paths and internal names. Footer and AI mode specs pass. Synthetic data only. The only images are the app's own icons.
- SAFETY AND SCOPE: no token in any tracked or changed file. `main` equals `origin/main` at a2ac73a, also by `git ls-remote`. Only the GitHub remote. Local tags `dawri:local` and `dawri:amd64` only, no push, no prune, no deploy by the build. maghselty containers have the same StartedAt and restart counts. 0 dawri containers, my ports free, nothing staged, `.obsidian` unstaged, no `.env`, DB, `node_modules`, `dist` or `.dist-*` in git status.

### Open issues from the builder reports
Closed:
- P6-R3-T1, the record language on the session restore path has no test. I tried it in the browser: Ravi restores in English, Fatima in Arabic, and a tapped language survives a reload. It works, so only the missing test remains, listed below.

### Features ticked
None added this phase, and F01 to F24 are unchanged. **F12 stays unticked: nothing has been deployed to a Hugging Face Space, because the build was told not to.** F22 and F23 stay dropped.

### What is left for Hugging Face
The README's numbered steps stand. Before following them, three things have changed since they were written:
1. A token now exists, in the gitignored `.env`.
2. The main session's live test on 7 Nov, run at the owner's request, found the default model failing on its provider (Fanar 9B on featherless, 0 of 4). The plan recorded at 04:05 Doha is to change the default after the build. This review changed nothing there, and did not test any other model.
3. Then create the Space, add the secret, upload with the README's command, and check `ai_mode` is real, one Arabic chat turn, and one voice clip on a real phone. Only after that can F12 be ticked.

### Known gaps
**For the owner to read:**
- `README.md` says "No token exists yet" and "None of these steps has been run", and says the live paths "have never run against the real API". The owner's work tonight overtook these: a token exists and model calls were tried from side scripts. The app's own routes have still not run live, so the README understates and does not overclaim. Correct both lines at switch-on, along with the model names if the default changes.
- [[Build Decisions]] also still says no token exists on this machine. It is left unedited.
- `load_dotenv()` runs at startup, so on this laptop a plain `.venv/bin/uvicorn backend.main:app` now runs in **real** mode and spends credits. To run simulated, start it with `HF_TOKEN=` set blank. The tests already force this: Playwright sets it blank and the pytest conftest patches `load_dotenv` out.
- A copy of the real token sits in `scratchpad/r3t1/copy/.env`, because a builder's scratch copy took the whole tree after the token landed. It is in this session's private temp folder, it was never used, and nothing else has it. The owner should delete that folder.
- A simulated preview server for the owner runs on port 8500 from the main session, with its own DB and a copy of `dist`. It is not part of this review and was left running.
- A Chrome Quit event reached the test browser through the Dock once in round 3. If Chrome shows in the Dock during a test run, do not quit it.

**Before the demo:** press Reset. The timed run rests on an assumed pace and typed words, and no person has rehearsed it. Nobody has checked the Arabic or the red-flag list.

**Unverified:** a real microphone, iOS Safari, live Whisper, the live chat model through the app, the HF proxy and SSE through it, the Spaces builder, and `hf upload` as a live run. The browser suite did not run on the amd64 image, though docker-check did.

**Clinician review:** the red-flag list and drug default regimens are unreviewed. New synonyms belong in that review.

**Tests and code:**
- No test guards the record language on the session restore path, `session.tsx` line 60. It works in my run. If that line broke, the suite would stay green.
- Under the conftest shift every pytest run executes at 12:00 Doha by design, so midnight is covered only by tests that pin their own clock. Playwright and docker runs use the real clock, so a run crossing Doha midnight can fail. The README states the limit.
- `conftest.py` pins two private `huggingface_hub` names, valid for 2.4.0. An upgrade that renames them fails loudly.
- The Dockerfile comment says Node 20.19, while the correct floor is 22.22.2, as the README says. The image uses 22.23.4.
- `race/inject.py` still shows 8 `database is locked` results from resetting on the route's own thread, ruled a harness artefact in round 3. A reset between `_service` and the draft's stale check answers 409 `draft_stale` rather than 404, and can leave a `handoff.drafted` row until the next reset.
- A patient who taps Stop within about 100 ms is told the recording could not be read, not that it was too short. Nothing is uploaded, and no transcript is invented.
- Why `voice.spec` passed until 01:10 on 7 Nov and failed after is not established. The hold does not depend on the cause.
- Round 2's gaps stand: `emergency_today` ends at Doha midnight, a same-container restart keeps data only on the same day, `httpx2` arrives only through `huggingface_hub`, leaving T03 by navigation drops an unsaved edit, no auto-move to S06 after a full reload mid-turn, a hidden or polling staff tab keeps "Handled by a colleague" until its next Call next, `api/stream.ts` duplicates `openStream`, T05 always says "Summary from triage", Yes stays disabled while voice is starting, and the scripted-assistant note in real mode lasts for the page.
- The nurse-signed card on T05 stays in English on an Arabic console, by design from round 1. T06's dose line (`500 mg · three times daily`) is also English on an Arabic console, as seen in my run. That one was not a stated decision, and the Arabic sentence sits directly under it.

## After Phase 6: live checks on 7 Nov
- Default chat model is now Gemma 4 26B on novita, see [[Build Decisions]]. Whisper transcribed one English and one Arabic synthesised clip correctly through `/api/asr`. A real microphone and a real phone are still untested.
- 13 serious wordings passed the rules before this change. Gemma escalated 13 of 13 through the app. They are now rule cues as well, so a model failure cannot lose them. They are invented wordings and are **not clinician reviewed**.
- The reply gate now accepts an opening 0 to 10 scale and a comma list of plain symptoms. Both are rewritten into the plain form, so every other check still applies.
- Backend suite: 10767 passed. Browser and Docker suites were not rerun after these changes.
- Fine-tune of Fanar 9B, private repos on `xTamim`: gate 1 of 100 to 100 of 100, valid intake 6 of 63 to 56 of 63, emergency escalation 9 of 13 to 0 of 13. **It must not be used for live chat.** It mostly imitates the scripted receptionist.
- Reset demo now asks for `DEMO_PASSCODE` when it is set. The Arabic handoff uses the patient's Arabic words and translated record terms.
- Private Space `xTamim/dawri` is live on `cpu-upgrade`, about $0.03 an hour, because free CPU Docker Spaces need PRO. Uploaded from a `git archive` of the commit without the vault. Checked through the proxy: `ai_mode` real, Whisper in English and Arabic, chat in both languages, overdose wording caught by the rules, passcode refused then accepted, SSE connected with a heartbeat at 15 s. Not checked: a real phone, a real microphone. It stays private until the owner says otherwise, and F12 stays unticked until the phone test.

