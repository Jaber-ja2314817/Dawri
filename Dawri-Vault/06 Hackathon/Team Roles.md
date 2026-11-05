---
tags: [hackathon, team]
---

# Team Roles

Teams are 2–4. Adjust to our actual size and skills.

| Role | Owns | Features |
|---|---|---|
| **AI lead** | Prompts, intake JSON, red flags, handoff, model access/fallbacks, ASR | F03, F04, F05, F09, F13, F15 |
| **Backend lead** | FastAPI, SQLite, queue engine, SSE, mock health system, Docker/Space deploy | F02, F06, F07, F12 |
| **Frontend (patient)** | Patient PWA, chat UI, mic, map, ticket screens, RTL | F01, F11, F14, F17 |
| **Frontend (staff) + pitch** | Nurse/doctor/pharmacy consoles, display screen, deck, demo script | F08, F10, F16 + pitch |

**3 people:** merge the two frontend roles; AI lead also does the deck.
**2 people:** one does backend + AI, one does all frontend; cut Could + most Should.

## Working agreements
- One `main` branch, small commits, deploy to the Space after every working feature.
- Contracts first: agree [[API]] and the intake JSON schema ([[AI Receptionist Design]]) tonight so frontend can mock while backend builds.
- Stand-up every 4 hours: done / next / blocked (5 minutes).
