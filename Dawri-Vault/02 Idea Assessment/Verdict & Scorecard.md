---
tags: [assessment]
skill: replica-entrepreneur
---

# Verdict & Scorecard

## Verdict
**Good idea for this hackathon — with three fixes.** The problem is real and local, the gap is real (nobody does remote check-in + AI intake for walk-ins in Qatar that we could find), and it showcases a Hugging Face model doing something a form can't: a bilingual, voice-first conversation that turns into structured clinical intake.

It is **not** "no system like this exists" in general — virtual queues and patient self check-in exist worldwide, and Qatar already has Nar'aakom (PHCC) and Lbaih (HMC). Our honest claim is narrower and stronger: *the walk-in front desk is still manual, and existing apps don't touch it.* See [[Competitor Landscape]].

### The three fixes
1. **Right operator.** Health centres = PHCC. Start there (walk-ins dominate), add HMC hospitals as "phase 2". → [[Competitor Landscape]]
2. **AI assists, humans decide.** AI collects and summarises; red-flag rules + nurse confirmation guard every clinical step. The AI never reorders the queue or assigns a doctor on its own. → [[Safety Guardrails]]
3. **Plug in, don't replace.** Pitch as a module that can sit inside Nar'aakom/Lbaih and talk to the centre's queue system — not a rival app asking 2M people to switch. → [[Fix Plan & Positioning]]

## Scorecard

| Criterion | Score | Why |
|---|:---:|---|
| Problem is real in Qatar | **8/10** | Walk-ins are the majority of PHCC visits, no-shows are high, public complaints about waits go back years ([[Sources]]) |
| Gap vs existing apps | **7/10** | Nar'aakom/Lbaih = appointments, records, cards. No remote walk-in check-in, live position or AI intake found. Risk: PHCC/HMC could add it |
| AI is necessary (not decoration) | **7/10** | Voice, Arabic dialect, free-text → structured intake, handoff summary. Weak spot: "assign doctor" — keep that rule-based |
| "Built on HF open source" fit | **9/10** | Fanar (QCRI, Qatar) + Whisper + MedGemma, all on the Hub. Using a Qatari model is a strong local story |
| Buildable in 48h | **7/10** | Yes if we mock the health system and own the queue engine. No if we try real integrations |
| Real-world deployability | **3/10** | Needs MoPH/PHCC/HMC partnership, national auth, data-protection approval. Normal for a hackathon; say it out loud |
| Demo wow factor | **8/10** | Live Arabic voice → ticket appears on the nurse screen in real time. Emergency path is a strong "trust" moment |
| **Overall** | **7.5/10** | Strong, if we scope it to one great vertical slice |

## Biggest risks (detail in [[Risks & Red Lines]])
- Judges: "Why wouldn't PHCC just add this to Nar'aakom?" → answer: *exactly — we built the module for them.* See [[Judge Q&A]].
- Medical safety questions → we show the red-flag stop live.
- Model latency on a 27B model → have a smaller fallback ready. See [[Model Choices]].
- Scope creep (map + four consoles + voice) → follow [[48h Build Plan]] cut lines.

## Score after the fixes
If the demo shows: Arabic voice intake, emergency stop, arrival-activated ticket, live nurse console → this is a top-tier entry for a "real problem in Qatar" brief.
