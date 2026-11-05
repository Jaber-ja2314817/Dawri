---
tags: [hackathon, demo]
duration: 3 min
---

# Demo Script (3 minutes)

**Setup:** phone (patient, mirrored to screen) on the left · laptop (nurse console) on the right · second tab: waiting-room display. Backup video ready.

## 0:00 — Hook (15 s)
"Most visits to Qatar's health centres are walk-ins. Each one starts the same way: a queue at the front desk, to tell a receptionist what you'll tell the nurse again five minutes later. We removed the desk."

## 0:15 — Fatima, normal visit (90 s)
1. Login with demo QID → profile appears (registered: Al Wakra, allergy: penicillin).
2. Tap mic, speak Arabic: **"عندي حرارة وكحة من ثلاث أيام"**. Transcript appears, she confirms.
3. AI asks 2–3 short questions in Gulf Arabic. Summary card → confirm. Service: GP.
4. Map: Al Wakra 12 min vs another centre 35 min. Pick Al Wakra → "place held 45 min".
5. Tap **"I'm here"** → **T-014** appears on her phone **and** on the nurse console at the same moment. ← pause, let judges see it.
6. Nurse: call next → intake card already filled, penicillin allergy highlighted → enter vitals → **AI handoff draft** → confirm doctor.
7. Phone updates to **D-GP-023**, then doctor "done" → **P-031** → ✅ visit complete, medicines in Arabic.

## 1:45 — Ahmed, refill (25 s)
English or Arabic: "I need my usual blood pressure tablets." → "You don't need a visit — message your centre's refill line." **One less person in the waiting room.**

## 2:10 — Ravi, emergency (25 s)
"Chest pain going to my left arm." → full red screen, call 999, nearest emergency department. **No ticket.** "Our receptionist knows when it shouldn't be a receptionist."

## 2:35 — Close (25 s)
"Built on **Fanar**, Qatar's own open Arabic model, with Whisper, all on Hugging Face. The health system behind this line is a mock with the same interface as a real integration — it's designed to plug into Nar'aakom and Lbaih. Arrive, don't register."

## Fallbacks
- Voice fails → type the same sentence.
- Model slow → pre-warm with one request 2 minutes before going on stage.
- Wi-Fi dies → play the backup video, narrate live.
