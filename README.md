---
title: Dawri
colorFrom: gray
colorTo: gray
sdk: docker
app_port: 7860
pinned: false
short_description: Queue check-in demo with an AI receptionist, synthetic data
---

# Dawri

## What Dawri is

Dawri takes a patient through a Qatar health-centre visit on their phone: an AI receptionist in Arabic or English takes the reason for the visit, and the patient joins the queue on arrival at the centre. Nurse, doctor, pharmacy, front desk and waiting-room screens carry the same visit through to the end.

This is a demo with synthetic data, not connected to PHCC/HMC systems. It uses real facility names, carries no logos, and has no endorsement from PHCC or HMC.

## Run it locally

You need Python 3.12 and Node 22.22.2 or later.

```bash
python3.12 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
cd frontend && npm ci && npm run build && cd ..
.venv/bin/uvicorn backend.main:app --port 7860
```

Open http://127.0.0.1:7860. For frontend work, leave the server running and start Vite on port 5173, which proxies `/api` to port 7860:

```bash
cd frontend && npm run dev
```

With Docker:

```bash
docker build -t dawri:local .
docker run -p 7860:7860 dawri:local
```

Tests:

```bash
.venv/bin/python -m pytest
(cd frontend && npm run test)
(cd frontend && npm run typecheck && npm run typecheck:e2e)
(cd frontend && npm run e2e)
frontend/scripts/docker-check.sh
frontend/scripts/e2e-container.sh
```

`npm run e2e` builds the frontend, starts its own servers and needs Google Chrome installed. It has two projects. `simulated` runs every spec except `e2e/real-mode.spec.ts`, and `stand-in` runs that one on `backend/tests/standin_server.py`: real mode with injected chat and speech clients and a blank `HF_TOKEN`, so no network call is possible. `docker-check.sh` and `e2e-container.sh` need Docker and a free port 7860, and take an image name that defaults to `dawri:local`. `e2e-container.sh` runs the `simulated` project against the image, read-only and as uid 1000.

Timed run of the Demo Script: 148 s in total against the 180 s budget (Fatima 78 s, Ahmed 15 s, Ravi 15 s), from `frontend/e2e/demo-timed.spec.ts` at real speed. This proves the script fits at the pace table assumed at the top of that spec. It does not prove that a person rehearsed it, and nobody has yet.

## Environment

Copy `.env.example` to `.env` for local use. `.env` is ignored by git and stays out of the image.

| Key | Default | Purpose |
|---|---|---|
| `HF_TOKEN` | blank | Hugging Face token. Set means real mode, blank means simulated mode. |
| `LLM_MODEL_ID` | `google/gemma-4-26B-A4B-it` | Chat model in real mode. |
| `LLM_PROVIDER` | `novita` | Inference Provider for the chat model. |
| `ASR_MODEL_ID` | `openai/whisper-large-v3-turbo` | Speech-to-text model in real mode. |
| `ASR_PROVIDER` | `hf-inference` | Inference Provider for speech-to-text. |
| `LLM_TIMEOUT_SEC` | `10` | Seconds allowed for one model or speech call. |
| `SIMULATE_LOAD` | off when unset; `1` in `.env.example` and in the image | Exactly `1` fills the queues with simulated tickets. |
| `DAWRI_DB` | `backend/data/dawri.db`; `/tmp/dawri.db` in the image | Path of the SQLite file. |
| `DAWRI_STATIC_DIR` | blank, which uses `backend/static`, then `frontend/dist` | Folder of the built frontend. |

## Simulated and real AI

`GET /api/health` reports `ai_mode`, and the mode is chosen once at startup. Staff screens always show it, and the patient footer shows "AI: simulated" in simulated mode.

- **Simulated, without `HF_TOKEN`.** A deterministic scripted receptionist runs in Arabic and English. `POST /api/asr` returns 503 and the patient types. No transcript is ever invented.
- **Real, with `HF_TOKEN`.** The chat model is `google/gemma-4-26B-A4B-it` on `novita`, with `meta-llama/Llama-3.3-70B-Instruct` on `ovhcloud` as the tested backup through the same two settings, and speech-to-text is `openai/whisper-large-v3-turbo` on `hf-inference`. A failed turn falls back to the scripted receptionist for that turn, and an `ai.fallback` row is recorded in the event table.

MedGemma and text-to-speech were dropped. The same chat model writes the nurse's handoff draft.

## Untested and not reviewed

- The live LLM and ASR paths have never run against the real API. They are covered only by stand-in clients.
- A real microphone, iOS Safari and live Whisper are untested. Browser tests replace the microphone.
- The Hugging Face proxy is untested, including SSE through it. Clients fall back to polling if a stream drops.
- Spaces hosting itself is untested.
- `getUserMedia` and geolocation need HTTPS, so plain LAN http falls back to typing and the I'm here button.
- The red-flag list has not been reviewed by a clinician.
- Drug default regimens are demo values no clinician reviewed.
- The first live run may show more scripted fallback than expected, because the model text gate refuses some reasonable questions.

## Limits to know

- Data lives in `/tmp` in the image. It is lost when the container is replaced, as on a Space restart, and reseeded.
- Run one process only. The event bus is in-process, so a second worker would miss events.
- Staff login has no password, so a visitor can open the consoles. Set `DEMO_PASSCODE` as a Space secret, and Reset then asks for it.
- A stream token sits in the URL, because EventSource cannot send headers. The image turns the access log off, but a local uvicorn logs it.
- The waiting-room display (T08) needs a staff login.
- QR arrival is a backend route with no camera UI.
- Walk-ins join by arrival stamp. Order is by arrival stamp for everyone, after the centre's priority rule (age 65 and over in the seed data).
- Fatima takes four taps to reach the chat, because she has dependents and the app asks who the visit is for.
- Arabic consoles show Latin digits in a different glyph shape from the English consoles.
- A server left running past midnight restarts numbers at T-001, so press Reset.
- Airport reads about 36 minutes only soon after a reset, because simulated load drains the other centres.

## Design

The look is Achromatic ledger: ink and neutrals on a calm blue-grey ground, with one hue, `#1d5fbf`, kept for the main data element.

Two exceptions are justified. The S10 ticket number and the T08 numbers may exceed 48 px, because they are read across a room or at a glance. S06 may use a full red field, because it must interrupt.

## Switching on Hugging Face later

A token exists in the local `.env`. No Space has been created yet, so these steps have not been run end to end.

1. Check on the Hub that `google/gemma-4-26B-A4B-it` is still served by `novita`, and `openai/whisper-large-v3-turbo` by `hf-inference`.
2. Create a fine-grained token with permission to call Inference Providers. Keep it out of the repo.
3. Create a Space with the Docker SDK on the free CPU tier.
4. In the Space settings, add `HF_TOKEN` as a Secret. Add `LLM_MODEL_ID`, `LLM_PROVIDER`, `ASR_MODEL_ID` and `ASR_PROVIDER` as Variables only if they differ from the defaults.
5. Sign in on this machine with `.venv/bin/hf auth login`, using a token that can write to the Space. Then upload the repo from its root:

   ```bash
   .venv/bin/hf upload <user>/<space> . . --repo-type space \
     --exclude "Dawri-Vault/*" --exclude ".venv/*" --exclude "*node_modules/*" \
     --exclude ".env*" --exclude ".taste-skill/*" --exclude ".pytest_cache/*" \
     --exclude "*__pycache__/*" --exclude "*.db*" --exclude "backend/data/*" \
     --exclude "frontend/dist/*" --exclude "frontend/.*" --exclude "frontend/test-results/*"
   ```

   Use this rather than a plain git push, which may refuse the PNG icons without Xet or LFS.
6. Wait for the Space to build.
7. Open `https://<user>-<space>.hf.space` directly on the phone, because the embedded page's microphone and location are untested.
8. Check that `/api/health` says `ai_mode` is `real`.
9. Try one Arabic chat turn and one voice clip.
10. If it fails, delete the `HF_TOKEN` secret to return to simulated mode.

Tick nothing as tested until these steps have run.

## Demo-day checklist

- Press Reset demo in the staff shell before going on stage.
- Pre-warm with one request 2 minutes before going on stage.
- Keep the backup video ready.
- If voice fails, type the same sentence.
