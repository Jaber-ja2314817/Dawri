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
