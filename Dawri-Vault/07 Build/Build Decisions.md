---
tags: [build, decisions, authority]
updated: 2026-11-06
---

# Build Decisions (overrides the rest of the vault)

The orchestrator approves every phase against the vault. **Where this note disagrees with an older note, this note wins.** The older notes were left unedited; each override below says what it replaces. Anything not mentioned here: the older note stands.

Progress and approvals are recorded in [[Orchestrator Log]].

## Ground rules for the build
- No Hugging Face work yet. Do not install `hf`, create a Space, or deploy. The app must run fully on this laptop first, and HF becomes a config change later.
- No real token exists on this machine. Never invent or commit one.
- Red lines in [[Risks & Red Lines]] and hard rules in [[01 Enhanced Prompt]] are absolute.
- Synthetic patients only. Real facility names are allowed, PHCC/HMC logos are not.
- Python 3.12-compatible code (local venv at `.venv/`, Python 3.14; Docker uses 3.12). Node 26 locally. `.venv/bin/python -m pytest` is the test command.
- All FastAPI routes that call the AI layer are plain `def`, so they run in the threadpool and do not stall SSE.

## Overrides of the vault

### AI and models (replaces [[Model Choices]], decision 3 in [[Open Questions]])
- Fanar 27B has no Inference Provider. Default `LLM_MODEL_ID=QCRI/Fanar-1-9B-Instruct`, `LLM_PROVIDER=featherless-ai` (env override). ASR `openai/whisper-large-v3-turbo`. Drop MedGemma and TTS: the same LLM writes the handoff.
- Two AI modes in one adapter, chosen at startup: `real` when `HF_TOKEN` is set, `simulated` otherwise.
- `simulated` is a deterministic scripted receptionist in Arabic and English that follows the same 6-question flow and produces schema-valid intake. It exists so the app runs without a token and so the demo survives a model failure. In `real` mode, a model failure or two invalid JSON attempts falls back to it for that turn, and the event log records it.
- Never pass simulated output off as a model. `GET /api/health` returns `ai_mode`. Staff consoles always show it, and the patient footer shows "AI: simulated" when simulated.
- `/api/asr` in simulated mode returns 503 with a clear message and the UI tells the patient to type. Never fabricate a transcript.
- The browser converts recorded audio to 16 kHz mono WAV before upload, so ASR does not depend on webm support. Audio is never stored.
- The real LLM and ASR paths cannot be tested tonight. Cover them with a fake client in tests, and say plainly in the README that they are untested against the live API.

### Live model (7 Nov, replaces the Fanar default above)
Live tests through the app on 7 Nov: Fanar 9B on featherless-ai failed 0 of 8 with capacity errors. The owner chose `google/gemma-4-26B-A4B-it` on `novita` as the default, with `meta-llama/Llama-3.3-70B-Instruct` on `ovhcloud` as the backup. `LLM_MODEL_ID` and `LLM_PROVIDER` still switch it. Fanar remains the base for fine-tuning, with results in [[Orchestrator Log]]. A token now exists in the gitignored `.env`.

### Demo and queue fixes (replaces parts of [[Mock Health System]], [[Queue Engine]], [[Screens]], [[Demo Script]])
1. **Simulated load must not block real patients.** Tickets from `SIMULATE_LOAD=1` carry `simulated=1`, have no intake, and count toward people ahead and wait estimates. When staff press "Call next", any simulated tickets ahead of the first real ticket are completed automatically ("handled by a colleague on shift"), never shown as a called patient, and the real ticket is called. If only simulated tickets remain, one is completed and the API returns no called patient. They appear greyed and labelled "Simulated" on consoles.
2. **Wording.** Never say "place held". Use "Check-in valid for 45 minutes" / "تسجيل الوصول صالح لمدة 45 دقيقة". A reserved ticket has **no number and no place**. The number and `seq` are assigned at activation.
3. **No-show claims** are dropped from any UI text or README.
4. **Arrival fairness.** Add a Front desk console (T07): staff register a walk-in without a phone by demo QID and one-line complaint, creating an active triage ticket stamped at that moment. Order is by arrival stamp for everyone. The README must not claim "nobody skips anyone" beyond that.
5. **Red-flag rules** must normalise text first and handle negation.
   - Normalise Arabic: strip diacritics and tatweel, unify أإآ→ا, ى→ي, ة→ه, so the vault's misspelled `أغمى علي` and correct `أغمي علي` both match. Lowercase English.
   - A cue is negated only when a negator sits within 3 words before it in the same clause (`no`, `not`, `without`, `denies`, `don't have`, `ما عندي`, `مو`, `مافي`, `ما في`, `بدون`, `لا يوجد`, `ليس`). Commas, full stops, `but`, `لكن`, `بس` end a clause, so "no, I have chest pain" and "no fever but chest pain" still fire. Cues that themselves contain a negator ("can't breathe", `ما أقدر أتنفس`) are never treated as negated.
   - Negated cues do not stop the patient, but they are passed to the model as context and shown to the nurse as "Patient denied: chest pain".
   - Rules run on every patient message before the model. The model cannot clear a rule hit.
   - The list has not been reviewed by a clinician. Say so in the README.
6. **S06 override.** "I'm not in danger" logs the override, issues no ticket, and shows a route to staff ("Speak to a member of staff at the centre, or call 999"). Add `POST /api/visits/{id}/emergency/override`.
7. **Demo time.** Add a clearly labelled "Demo: skip to visit complete" button on the nurse console after handoff confirm, calling `POST /api/demo/fast-forward/{visit_id}`, which walks doctor and pharmacy with the default prescription through the normal engine. Add `POST /api/demo/reset`, a staff-side reset button, and a 3-tap flow for each demo patient via quick-pick chips.
8. **Priorities.** Refill (F15), map (F14), dependents (F24) and voice (F13) are in scope tonight. F18 geofence: browser geolocation, 150 m, with an "I'm here" demo button. F19: backend accepts `{qr_code}` (`DOOR-<centre id>`), no camera UI needed. F20 is covered by T07. F21 dashboard: simple numbers from real rows. F22 TTS and F23 wait ML are dropped.
9. **Backend gaps.** Add `python-multipart`. SQLite path from `DAWRI_DB`, default `backend/data/dawri.db`, Dockerfile sets `/tmp/dawri.db` because Spaces run non-root. Add `POST /api/tickets/{id}/serve` (called → serving, also done automatically on vitals submit) and `POST /api/tickets/{id}/no-show` (back to active; after 3 calls, back of queue).

### Centres (replaces the list in [[Mock Health System]])
Coordinates from OpenStreetMap Nominatim, 6 Nov 2026. Abu Baker Al Siddiq and Umm Ghuwailina were not found, so they are **left out rather than guessed**. Service lists are demo assumptions.

| id | name | operator | lat | lng |
|---|---|---|---|---|
| C-WAKRA | Al Wakra Health Centre / مركز الوكرة الصحي | PHCC | 25.17302 | 51.59575 |
| C-RAYYAN | Al Rayyan Health Centre / مركز الريان الصحي | PHCC | 25.27992 | 51.43243 |
| C-MESAIMEER | Mesaimeer Health Centre / مركز مسيمير الصحي | PHCC | 25.23369 | 51.48246 |
| C-AIRPORT | Airport Health Centre / مركز المطار الصحي | PHCC | 25.25580 | 51.55778 |
| C-WESTBAY | West Bay Health Centre / مركز الخليج الغربي الصحي | PHCC | 25.33767 | 51.50388 |
| H-HGH | Hamad General Hospital / مستشفى حمد العام | HMC, emergency | 25.29349 | 51.50222 |
| H-WAKRA | Al Wakra Hospital / مستشفى الوكرة | HMC, emergency | 25.16750 | 51.58742 |

Seed load so the demo reads well: Al Wakra about 12 min, a nearby alternative about 35 min. Seed Al Wakra triage so Fatima's number lands on T-014 on a fresh reset when possible.

### Model text gate (added 6 Nov, 03:30, after four Phase 2 reviews)
Reviews kept finding new wordings because a blocklist cannot be complete. Patient-facing safety now rests on the shape of the text, and the filters remain as a second layer.

- A model chat reply reaches the patient only if it is **one short question**: optionally one acknowledgement of at most 6 words, then a single question. The acknowledgement holds no digits, drug or disease wording. Any other shape is rejected and that turn uses the simulated fallback, recorded as `ai.fallback`.
- The summary read back to the patient is **rendered by the server** from a fixed AR/EN template using the patient's own words from the transcript, validated duration and severity, and the server-built medicines list. Model free prose such as `summary_for_nurse` is never shown to the patient.
- `self_medication` is built by the server from what the patient said, never taken from the model.
- Model text may reach staff, after filtering, because a nurse confirms everything at triage ([[Safety Guardrails]] layer 4).
- The red-flag list stays a starter list until a clinician reviews it. New synonyms are review items. Structural holes are bugs.

### Nurse backstop (added 6 Nov, 04:35)
The nurse intake card (T03) always shows the patient's exact words from the chat, turn by turn, next to the AI summary, whatever the summary says. The API must return them to staff. This is required, not polish: a summary can drop a detail such as "with blood", and the nurse is the last safety layer. Patient-facing routes still receive only `receptionist.patient_intake`, never `summary_for_nurse`.

### Other implementation decisions
- **Queue:** priority from centre rules only (age 65+ in the seed). Order: `priority DESC, activated_at ASC, seq ASC`. Numbers from a per-centre, per-prefix daily sequence, so `D-GP` stays unique across two GP doctors. Reserved tickets expire after 45 minutes through a lazy check plus a background task.
- **Doctor suggestion** is the rule score from [[AI Receptionist Design]], and the reason is a template. No model.
- **Plain-language medicines** are deterministic AR/EN templates from prescription fields. No model.
- **Prescription picker** warns deterministically on an allergy conflict, e.g. amoxicillin for Fatima's penicillin allergy.
- **Handoff** is built from the effective intake (`edited_json` if the nurse edited it), so the doctor sees the edit. Banned-output filter runs on patient replies and on handoff drafts.
- **Refill deflection** needs a match in the record's `active_meds`. "I still want a visit" continues to centre selection as GP.
- **Dependents:** seed at least one dependent for a demo patient (a synthetic child for Fatima; a synthetic elderly parent is a fine second example). Add `booked_by` on visits.
- **Consent:** one short consent step before the first chat ([[Safety Guardrails]]).
- **SSE:** `GET` streams take `?token=` because EventSource cannot send headers. Events are small; clients refetch state. Publish from threadpool routes with `loop.call_soon_threadsafe`. Heartbeat every 15 s. Clients fall back to polling if the stream drops.
- **Adapters:** `backend/adapters/queue_base.py` defines the interface and the SQLite engine implements it.
- **Offline venue:** no CDN assets. Fonts via `@fontsource`. OSM tiles need network, so the centre list must stay fully usable if tiles fail.

## Layout
Follow the repo layout in [[Stack]]. The repo root holds `backend/`, `frontend/`, `Dockerfile`, `README.md`, `.env.example`. Backend run: `.venv/bin/uvicorn backend.main:app --port 7860`. Frontend dev: Vite on 5173 proxying `/api`. Production: FastAPI serves `frontend/dist` with an SPA fallback, under `backend/static` in the image.

## Design direction (frontend)
App screens, so follow `references/app-screens.md` of the `anthropic-skills:design-taste-frontend` skill, including `inspect.mjs --app`. Style dealt: **Achromatic ledger**, seed 1733365508.

- Chrome is ink and neutrals. Near-black primary action, grey secondary. No brand colour on chrome. One hue, `#1d5fbf`, on the main data element only (the patient's own number, the current stage).
- Face: a calm blue-grey ground `#f2f4f7`, white cards, 1px `#e6e6e6` borders, no shadows at rest, radius 8/6.
- Tokens: text `#0a0a0a`, muted `#6b6b6b`, control `#d4d4d4`, positive `#2e7d32`, negative `#c4242a`, warning `#92400e`, row 44px, gap 12, pad 24. Pills: positive `#dcfae5/#04250e`, negative `#ffedea/#831c1e`, warning `#fffbeb/#92400e`, neutral `#eeeeee/#3d3d3d`.
- Type: IBM Plex Sans Arabic and IBM Plex Sans via `@fontsource`. Tabular figures. Sizes 12/14/16/24/30.
- Patient app: touch targets at least 44 px, a phone is the main device, one question per screen. RTL via logical CSS properties. Arabic is the default for Arabic-preferring patients. Language toggle on every screen.
- Footer on every patient screen: "Demo — synthetic data, not connected to PHCC/HMC systems." in AR/EN.
- No emoji, gradients, glass, violet or indigo, icon tiles, or KPI sparklines.

**Justified exceptions:** the ticket number on S10 and numbers on the TV display (T08) may exceed 48 px because they are read across a room or at a glance. The emergency screen (S06) may use a full red field because it must interrupt. Note both in the README's design section.
