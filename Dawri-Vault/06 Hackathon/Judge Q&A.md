---
tags: [hackathon, qa]
---

# Judge Q&A (prepare these)

**"Why wouldn't PHCC just add this to Nar'aakom?"**
They should — that's our path. Dawri is built as a module with clean adapters for login, health record and queue. The value we proved this weekend is the AI intake and the arrival-activated queue logic.

**"Isn't an AI receptionist dangerous in healthcare?"**
It doesn't diagnose, prescribe or reorder the queue. Emergency rules run before the model and can't be overruled by it. Every AI output is confirmed by a nurse. [Show the chest-pain demo.]

**"What about patient data?"**
Demo uses synthetic data only. In production: open models deployed inside Qatar, minimal data, consent, audio deleted after transcription, full audit log. Health data is sensitive under Qatar's data protection law, so a compliance review with the operator is step one of a pilot.

**"Can't people book from home and skip the line?"**
No — a reserved ticket has no place until you arrive. On arrival you join the end. Unused reservations release after 45 minutes.

**"What about elderly people or people without smartphones?"**
Kiosk mode at the door runs the same AI. Family members can check in dependents (Nar'aakom already supports dependents).

**"Why do you need AI? A form could do this."**
A form can't understand "عندي حرارة وكحة من ثلاث أيام" spoken in Gulf Arabic, ask the right follow-up, or write a nurse-ready summary. Voice in the patient's dialect is the accessibility win.

**"Why Fanar?"**
Arabic-first, open (Apache-2.0), built in Qatar by QCRI and published on Hugging Face — it fits the language and the data-sovereignty story.

**"How accurate is the routing?"**
Honest answer: tested on our scenario set (N cases) this weekend → state the number. Pilot would measure against nurse decisions.

**"Business model?"**
B2G: licensed to PHCC/HMC (or private clinics) per centre; the private clinic market is the faster first customer.
