---
tags: [assessment, risk]
---

# Risks & Red Lines

## Red lines (never cross, even in the demo)
- ❌ The AI **diagnoses** or tells the patient what they have.
- ❌ The AI **prescribes** or suggests doses.
- ❌ The AI **reorders the queue** or lets anyone skip ahead.
- ❌ The AI **issues a ticket when a red flag is present.**
- ❌ **Real** QIDs, names or health data anywhere — synthetic only.
- ❌ Using PHCC/HMC logos or names as if they endorsed us.

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|:---:|:---:|---|
| Judges: "PHCC can just add this" | High | Med | Agree. Position as module/API for Nar'aakom & Lbaih → [[Judge Q&A]] |
| Medical-safety challenge | High | High | Live red-flag demo, human-confirmed triage, no diagnosis → [[Safety Guardrails]] |
| Data protection | High | High | Qatar's personal data law treats health data as sensitive; show: synthetic data, minimal fields, data kept in Qatar (sovereign/on-prem deployment), consent screen |
| Queue gaming (reserve from home, show up late) | Med | Med | Ticket RESERVED until arrival; joins the END on activation; 45-min hold then released → [[Queue Engine]] |
| Fairness for people without smartphones | Med | Med | Kiosk mode at the door uses the same AI; dependents (family) check-in |
| 27B model too slow/expensive at the venue | Med | High | Smaller fallback model + cached prompts; ask HF mentors about inference credits → [[Model Choices]] |
| Arabic dialect speech errors | Med | Med | Show transcript for the patient to confirm; allow typing |
| Wi-Fi fails during demo | Low | High | Record a backup video of the full flow by Saturday noon |
| Scope creep | High | High | Cut lines in [[48h Build Plan]] |
| Official challenge (revealed at kickoff) differs from our theme | Med | High | Check now. Map our idea to the official wording; keep the core flow → [[Open Questions]] |
