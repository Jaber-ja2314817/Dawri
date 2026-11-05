---
tags: [product, flow]
skill: replica-recon
---

# Patient Journey

## The whole visit at a glance
```mermaid
flowchart TD
  A[1. Login<br/>mock Tawtheeq · QID + OTP] --> B[2. Profile loaded<br/>from mock national record]
  B --> C[Who is the visit for?<br/>me / dependent]
  C --> D[3. AI receptionist<br/>voice or text · AR/EN]
  D --> RF{Red flag?}
  RF -- yes --> ER[🚨 Go to Emergency / call 999<br/>nearest HMC ED · no ticket]
  RF -- no --> SVC{Service?}
  SVC -- refill of usual meds --> RX[Refill route<br/>centre WhatsApp / delivery<br/>no visit needed]
  SVC -- GP / dental / vaccine / lab ... --> MAP[4. Pick centre on map<br/>registered centre default · wait shown]
  MAP --> RES[5. Ticket RESERVED<br/>held 45 min]
  RES --> ARR{6. Arrived?<br/>geofence or door QR}
  ARR -- no, 45 min passed --> REL[Place released<br/>patient notified]
  ARR -- yes --> T[Triage ticket ACTIVE<br/>T-014 · joins end of queue]
  T --> N[7. Nurse: vitals + confirms intake]
  N --> H[8. AI drafts handoff<br/>suggests doctor · nurse confirms]
  H --> DQ[9. Doctor ticket D-GP-023<br/>end of that doctor's queue]
  DQ --> DR[Consultation done<br/>prescription added]
  DR --> PQ[Pharmacy ticket P-031]
  PQ --> DONE[10. ✅ Visit complete<br/>meds explained AR/EN]
```

## Step by step (enhanced)

| # | Step | Patient sees | System does | AI involved? |
|---|---|---|---|---|
| 1 | Login | "Log in with Tawtheeq (demo)" → QID → OTP | Mock auth; issues session | No |
| 2 | Profile | Name, age, registered centre, dependents. Banner: *Demo data* | Fetches synthetic record from [[Mock Health System]] | No |
| 3 | Receptionist chat | Mic button + chat; transcript shown to confirm | Whisper → text; red-flag rules; Fanar asks 3–6 questions; produces intake JSON | **Yes** |
| 3a | Red flag | Full-screen red card, call 999 button, nearest ED on map | Visit logged as `redirected_emergency`; no ticket | Rules first, model second |
| 3b | Refill | "You can get this without a visit" → open centre's refill channel | Visit closed as `deflected_refill` | Yes (classification) |
| 4 | Centre | Map pins with wait estimates; registered centre highlighted | Wait = people ahead × avg service time | Suggestion text only |
| 5 | Reserve | "Your place is held for 45 min" + countdown | Ticket `RESERVED` | No |
| 6 | Arrive | Big number T-014, people ahead, est. wait, "go to triage area" | Geofence/QR → `ACTIVE`, appended to end | No |
| 7 | Triage | "Nurse is calling T-014" (+ display screen) | Nurse console shows intake; vitals form | Intake shown |
| 8 | Handoff | "Next: Dr. room 4 — D-GP-023" | AI drafts summary + doctor suggestion; nurse confirms | **Yes** (draft only) |
| 9 | Doctor | Live position in doctor queue | Doctor marks done, picks prescription | Summary shown |
| 10 | Pharmacy & done | Pharmacy ticket → "Visit complete", meds in plain language | Visit `COMPLETED`; timestamps for stats | Plain-language med text |

## Three demo patients (see [[Mock Health System]])
1. **Fatima, 34** — Arabic voice: fever + cough for 3 days → full flow to pharmacy.
2. **Ahmed, 67** — "I need my usual blood pressure tablets" → refill deflection.
3. **Ravi, 45** — English: chest pain spreading to left arm → emergency screen.

Related: [[Screens]] · [[Queue Engine]] · [[AI Receptionist Design]]
