---
tags: [product, features]
skill: replica-recon
---

# Feature Matrix

**Must** = demo fails without it · **Should** = big win if time · **Could** = mention in pitch only

| ID | Feature | Priority | Owner role | Status |
|---|---|:---:|---|:---:|
| F01 | Mock Tawtheeq login (QID + OTP 0000) | Must | Frontend | ☑ |
| F02 | Mock national health record (3+ synthetic patients) | Must | Backend | ☑ |
| F03 | AI chat intake (text), AR + EN | Must | AI | ☑ |
| F04 | Red-flag rules (AR/EN) before model | Must | AI | ☑ |
| F05 | Service classification → intake JSON | Must | AI | ☑ |
| F06 | Ticket reserve → activate on arrival ("I'm here" button for demo) | Must | Backend | ☑ |
| F07 | Queue engine: triage, doctor, pharmacy queues; live updates (SSE) | Must | Backend | ☑ |
| F08 | Nurse console: call next, intake card, vitals, confirm | Must | Frontend | ☑ |
| F09 | AI handoff summary + doctor suggestion (nurse confirms) | Must | AI | ☑ |
| F10 | Doctor + pharmacy consoles (simple) | Must | Frontend | ☑ |
| F11 | Visit complete screen | Must | Frontend | ☑ |
| F12 | Deployed on a Hugging Face Space | Must | Backend | ☐ |
| F13 | Voice input (Whisper) with transcript confirm | Should | AI | ☑ |
| F14 | Centre map with wait badges (Leaflet/OSM) | Should | Frontend | ☑ |
| F15 | Refill deflection | Should | AI | ☑ |
| F16 | Waiting-room display screen | Should | Frontend | ☑ |
| F17 | Arabic RTL polish | Should | Frontend | ☑ |
| F18 | Real geofence (browser geolocation) | Could | Frontend | ☑ |
| F19 | QR at entrance | Could | Frontend | ☑ |
| F20 | Kiosk mode | Could | Frontend | ☑ |
| F21 | Centre dashboard / stats | Could | Frontend | ☑ |
| F22 | Voice reply (TTS) | Could | AI | ☐ |
| F23 | Wait-time ML model | Could | AI | ☐ |
| F24 | Dependents | Could | Backend | ☑ |

## Build order (vertical slice first — replica-architect rule)
1. F02 → F01 → F03 (text only) → F05 → F06 → F07 → F08 → F11 = **one patient end-to-end** (Friday morning)
2. F04, F09, F10, F12
3. F13, F14, F15, F16, F17
4. Anything in Could, only if all Must/Should are green
