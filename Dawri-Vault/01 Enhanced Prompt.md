---
tags: [prompt, spec]
---

# 01 Enhanced Prompt

> This is our original idea, rewritten with the corrections from the research. Paste the block below into Claude Code / Codex, or read it out to the team. Everything in it is linked to a note that explains *why*.

## What changed from the original idea (and why)

| Original idea | Enhanced version | Why |
|---|---|---|
| "Hospital registration" | **PHCC health-centre walk-ins** first, HMC hospitals later | Health centres are run by **PHCC**, not Hamad (HMC runs the hospitals). PHCC's 2025 snapshot shows most visits are walk-ins — that's where the front-desk queue is. See [[Competitor Landscape]] |
| "Sign in with name, QID" | **Tawtheeq-style login (mocked)** + QID | Real apps (Nar'aakom, Lbaih) log in through Qatar's national authentication. We fake it with a demo account. See [[Mock Health System]] |
| "Pull data from the Qatari health system" | **Mock national health record** with synthetic patients, shaped like FHIR | We can't get real access in 48h; judges accept a clearly labelled mock. See [[Mock Health System]] |
| "Map of legit health centres by Hamad" | Map of **PHCC centres** (+ HMC hospitals as a second layer) with live wait estimates | Correct operator; wait time makes the map useful, not decoration |
| "AI assigns the health centre" | AI **suggests** (nearest + shortest wait + has the needed service); patient confirms | Patient keeps control; registered centre rules still apply |
| "Choose the service" | AI receptionist **asks in Arabic/English (voice or text)** and turns the answer into a structured intake | This is where the AI earns its place. See [[AI Receptionist Design]] |
| "Connected to the hospital numbering system" | **Adapter** to the centre's queue system; for the demo our own [[Queue Engine]] issues numbers in the centre's format | We plug into what exists, we don't replace it |
| (missing) | **Ticket activates only on arrival** (geofence or QR at the door) | Stops people holding a place from home and skipping others; tackles no-shows |
| (missing) | **Red-flag check first** → "go to Emergency / call 999" | An AI receptionist must never queue a heart attack. See [[Safety Guardrails]] |
| "AI assigns a doctor" | AI **drafts** nurse → doctor handoff and **suggests** a doctor by clinic, load and language; nurse confirms | Clinical assignment needs a human in the loop |
| "Medicine refill" visit | Refill requests can **skip the visit entirely** (route to the centre's existing refill/delivery service) | Fewer people in the building = shorter queue for everyone |
| (missing) | **Staff console** (nurse + front desk + display screen) | The demo needs the other side of the queue to be believable. See [[Staff Console]] |

---

## The prompt

```text
ROLE
You are the lead engineer on a 3–4 person team at the Qai × Hugging Face
Hackathon in Doha (48 hours, ends Saturday 7 Nov 2026, 5 PM). The brief:
"Build an AI system that solves a real problem in Qatar." Projects must be
built with open-source tools on Hugging Face and submitted as a live demo.

PRODUCT
Dawri (دوري, "my turn") — an AI front desk for Qatar's PHCC health centres.
A patient checks in from their phone before arriving. An open-source model
from Hugging Face acts as the receptionist: it talks to the patient in
Arabic (Khaleeji + MSA) or English, by voice or text, collects the reason for
the visit, screens for emergencies, and produces a structured intake. The
patient's ticket activates when they arrive at the centre, and they go
straight to triage — no front-desk registration.

PROBLEM (Qatar-specific, evidence in the vault)
- Most PHCC visits are walk-ins; walk-in patients queue at reception, then
  again for triage, doctor and pharmacy.
- Existing apps (PHCC Nar'aakom, HMC Lbaih) handle appointments, records and
  health cards, but not remote check-in, live queue position or pre-visit
  intake for walk-ins.
- Reception staff spend time typing what the patient could have said on the
  way, and repeat it to the nurse.

PATIENT FLOW (build in this order)
1. Login: mocked Tawtheeq screen → QID + OTP (demo OTP 0000). Load the
   patient's profile from the MOCK national record (name, age, sex,
   registered health centre, allergies, chronic conditions, active meds,
   dependents). Clearly label it "Demo data".
2. Choose who the visit is for (self or a dependent).
3. AI receptionist chat (voice or text, AR/EN):
   a. FIRST run the red-flag check (rules + model). If any red flag →
      stop, show "Go to Emergency now / call 999", with the nearest HMC
      emergency department. No ticket.
   b. Otherwise ask 3–6 short questions: main complaint, how long, how bad
      (0–10), fever?, medicines taken, anything else.
   c. Classify the service: GP, dental, medication refill, vaccination,
      lab test only, women's health, mental health, other.
   d. If REFILL of an existing chronic medicine → offer the centre's
      refill/delivery route instead of a visit.
   e. Output a JSON intake (schema in the vault) + a 3-line plain summary.
4. Centre selection: map (Leaflet + OpenStreetMap) of PHCC centres with
   estimated wait per service. Default = patient's registered centre;
   the AI may suggest another if it is near and much shorter. Patient picks.
5. Reserve: create a visit + a RESERVED triage ticket. Show "Your place is
   held for 45 min. It activates when you arrive."
6. Arrive: geofence (within ~150 m) or scan the QR at the entrance →
   ticket becomes ACTIVE in the triage queue, in arrival order, with the
   centre's own priority rules (elderly, disability, pregnancy) — never
   reordered by the AI. Show number (e.g. T-014), people ahead, est. wait.
7. Triage: nurse calls T-014 on the staff console, sees the AI intake,
   records vitals, edits/confirms the complaint and urgency.
8. AI drafts the nurse→doctor handoff (summary + vitals + history) and
   suggests a doctor by clinic, current load and language. Nurse confirms.
   Patient gets a doctor ticket (e.g. D-GP-023) appended to the end of that
   doctor's queue — nobody is skipped.
9. Doctor: sees the handoff, marks consultation done, adds prescription
   (demo: pick from a list).
10. Pharmacy ticket (e.g. P-031). When dispensed → "Visit complete" screen
    with medicines in plain Arabic/English and any follow-up.

STAFF SIDE (same app, /staff routes)
- Nurse console: triage queue, call next, intake card, vitals form,
  confirm handoff.
- Doctor console: my queue, handoff card, done + prescription.
- Pharmacy console: queue, dispensed.
- Waiting-room display (TV): current numbers per counter, AR/EN.
- All screens update live (SSE/WebSocket).

AI COMPONENTS (all from the Hugging Face Hub; verify each on the Hub at
kickoff and pick what runs within our compute)
- Dialogue + intake + routing: QCRI/Fanar-2-27B-Instruct (Qatar's own
  Arabic-first model, Apache-2.0); smaller fallback if latency is bad.
- Speech-to-text: openai/whisper-large-v3-turbo (Arabic + English).
- Clinical summary for the doctor (English): google/medgemma-27b-text-it
  (gated — accept terms) or the same Fanar model.
- Red flags: deterministic keyword/rule list in AR/EN FIRST, model second.
- Wait estimate: people ahead × rolling average service time per counter.

HARD RULES
- The AI never diagnoses, never prescribes, never changes queue order.
- Red-flag rules run before the model and cannot be overridden by it.
- Every AI output shown to staff is editable and must be confirmed.
- Only synthetic patients. No real QIDs or health data anywhere.
- Arabic is a first-class language (RTL layout, Arabic voice).
- Show "Demo — not connected to PHCC/HMC systems" on every patient screen.

STACK
- Frontend: React + Vite + Tailwind, mobile-first PWA, RTL support, Leaflet.
- Backend: FastAPI (Python), SQLite (or Supabase if the team prefers),
  SSE for live queues.
- AI: huggingface_hub InferenceClient (Inference Providers / Endpoints)
  or a ZeroGPU Space; one adapter module so models can be swapped.
- Deploy: one Hugging Face Space (Docker SDK) serving API + built frontend.

DELIVERABLES BY SATURDAY 5 PM
1. Live HF Space with the full flow on 3 demo patients.
2. A 3-minute demo script that runs: normal visit, refill deflection,
   red-flag emergency.
3. Pitch: problem → demo → why AI → why Qatar (Fanar) → path to Nar'aakom.

ACCEPTANCE TESTS
- Arabic voice "عندي حرارة وكحة من ثلاث أيام" → GP intake, ticket issued.
- "Chest pain spreading to my arm" → emergency screen, no ticket.
- "I need my usual blood pressure pills" → refill route offered.
- Ticket stays RESERVED until arrival; activating it appends to the end.
- Nurse edits the AI summary; the doctor sees the edited version.
- Two browsers (patient + staff) update live without refresh.
```

## Related
- [[Patient Journey]] · [[Feature Matrix]] · [[48h Build Plan]]
