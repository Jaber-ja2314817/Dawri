# Dawri explainer video script

A three-minute voiceover script, about 440 words at a steady 150 a minute, with on-screen cues from the problem to the aim. Every claim comes from the team handoff of 7 November 2026; items to verify before recording are in the last section.

## Scene 1: The problem (0:00 to 0:25)

**On screen:** Title card "Dawri دوري". Then a plain flow: front desk, triage, doctor, pharmacy. Two text labels, "Nar'aakom" and "Lbaih", each tagged "appointments, records". No logos.

**Voiceover:** "Most visits to Qatar's primary health centres are walk-ins. Each one starts at the front desk, where staff record why you came. Then come triage, the doctor and the pharmacy. Qatar's apps, Nar'aakom and Lbaih, handle appointments and records. But in our research, we found no digital path for walk-ins. That is the gap. This is Dawri, دوري, which means 'my turn'."

## Scene 2: How a visit works (0:25 to 1:42)

One patient, Fatima, goes through the whole visit. Then two quick cuts show a refill and an emergency.

| Time | On screen | Voiceover |
| --- | --- | --- |
| 0:25 | Dawri on a phone. Quick-pick demo patients. Footer: "Demo, synthetic data, not connected to PHCC/HMC systems". | "Dawri is an AI front desk. Fatima, 34, checks in on her phone before she arrives. This is a demo, with synthetic patients." |
| 0:34 | Arabic chat. She types or speaks: عندي حرارة وكحة من ثلاث أيام. Short follow-up questions appear one at a time. | "She tells the AI receptionist, in Arabic, by text or voice: fever and cough for three days. It asks a few short questions, one at a time." |
| 0:45 | Map of centres with estimated waits. Reservation screen. | "She picks a centre on a map with estimated waits. That is a reservation, not yet a place in line." |
| 0:53 | She taps "I'm here". Live ticket T-014. | "When she arrives, she taps 'I'm here'. Her ticket activates and gets a number, T-014. Order comes from arrival and the centre's own priority rule. Plain code, no AI." |
| 1:05 | Nurse console: her exact words, the AI intake, penicillin allergy, vitals form, handoff draft. | "At triage, the nurse sees her exact words, the AI's intake, and her penicillin allergy. The nurse enters vitals and confirms the handoff to the doctor." |
| 1:15 | Doctor console with the amoxicillin allergy warning. Pharmacy. "Visit complete". | "The doctor prescribes, and the system warns about amoxicillin, because of her penicillin allergy. Then the pharmacy, and the visit is done." |
| 1:24 | Split screen. Ahmed: refill route, no ticket. Ravi: red emergency screen, "call 999", nearest hospital. | "Ahmed asks for his usual blood-pressure pills. He is offered the refill route, with no ticket. Ravi types that he has chest pain spreading to his arm. A rule catches it first. He sees 'call 999' and the nearest hospital, and gets no ticket." |

## Scene 3: How it stays safe (1:42 to 2:14)

**On screen:** Five layers appear one at a time: "Rules first", "Model reply check", "No diagnosis, no prescribing", "Nurse confirms", "Queue engine: no AI". Last card: "Red-flag list: not clinically reviewed yet".

**Voiceover:** "Safety does not depend on the model behaving. Rules check every message for emergency wording, in Arabic and English, and a hit stops the chat. The model cannot overrule it. A model's reply reaches the patient only if it is one short, plain question. The AI never diagnoses and never prescribes. A nurse confirms everything before the doctor sees it, and the queue is code the AI cannot touch. And we say plainly: no clinician has reviewed our red-flag list yet."

## Scene 4: Models and stack (2:14 to 2:41)

**On screen:** The architecture diagram from the handoff: patient app, red-flag rules, receptionist, Hugging Face Inference Providers (Gemma 4 26B, Whisper), reply check, staff consoles, queue engine, SQLite. Then two cards, "Gemma 4 26B" and "Whisper large-v3-turbo". Optional, with the label "our test": emergency recognition, base Fanar 9 of 13, tuned Fanar 0 of 13.

**Voiceover:** "Under the hood: a FastAPI service with SQLite and a React app, in one Docker container on a Hugging Face Space. Chat, intake and the nurse's handoff draft run on Gemma 4 26B, through Hugging Face Inference Providers. Whisper large-v3-turbo handles speech. We chose Gemma after testing sixteen model and provider pairs. We wanted Qatar's Fanar, but it had no provider capacity. Our fine-tuned Fanar 9B lost emergency recognition, so we kept it out."

## Scene 5: The aim (2:41 to 3:00)

**On screen:** Three lines, one at a time: "Reception step removed", "Structured intake for nurses", "People decide everything clinical". Then the title card: "Dawri. Arrive, don't register."

**Voiceover:** "Our aim: take the reception step off the walk-in's path, and give nurses a structured intake, with people deciding everything clinical. This is a prototype. Going live would need partnership, a clinical review and data-protection approval. Dawri. Arrive, don't register."

## Before you record: verify and avoid

Time check: the voiceover is about 440 words, so read it aloud once. If it runs past 3:00, cut "We chose Gemma after testing sixteen model and provider pairs" first.

**Verify first**

- "Most visits are walk-ins": the vault read about 69% from a PHCC Annual Snapshot 2025 table and says to check the slide before quoting a figure. Say "most" unless you have confirmed it.
- Voice input, real-phone location and iOS Safari were untested when the handoff was written at 07:05. If they fail, record with typing and the "I'm here" button. The script still holds.
- No Qatari speaker has read the Arabic yet. Check the on-screen Arabic sentence.
- Scene 3's last line is true only until a clinician reviews the red-flag list. Change it if one does.
- The Fanar tuning numbers come from the training run's own report and a small test. Show them only with the label "our test".
- Waits and busy queues on screen are partly simulated. The app's demo footer says so.

**Never say or show**

- That Fanar runs the live app. Gemma 4 26B does.
- That a place is held, that nobody can skip the line, that no-shows fall, or any minutes saved.
- That the red-flag list is clinically validated, that Dawri connects to PHCC or HMC, or that it is ready for real patients.
- That the AI assigns doctors or changes queue order.
- The Hugging Face token or the reset passcode.

If a judge asks how it was built, the handoff says Claude agents built it in phases, each independently reviewed before commit.
