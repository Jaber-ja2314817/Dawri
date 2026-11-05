---
tags: [product, screens]
skill: replica-recon
---

# Screens (inventory)

Mobile-first, RTL-ready. ⭐ = must exist for the demo.

## Patient app
| ID | Screen | Key elements | States |
|---|---|---|---|
| S01 ⭐ | Welcome / language | AR/EN toggle, "Log in with Tawtheeq (demo)" | — |
| S02 ⭐ | Login | QID field, OTP (0000), demo patient quick-pick chips | error, loading |
| S03 ⭐ | Home | Greeting, registered centre, "Start check-in", active visit card | no visit / active visit |
| S04 | Who is this for | Me + dependents list | — |
| S05 ⭐ | AI receptionist | Chat bubbles, big mic button, live transcript, "Is this right?" confirm | listening, thinking, error-retry |
| S06 ⭐ | Emergency | Red full screen, "Call 999", nearest ED, "I'm not in danger — go back" (logs override, still no ticket) | — |
| S07 | Refill route | Medicine name from profile, "Message your centre", "I still want a visit" | — |
| S08 ⭐ | Centre map | Leaflet map, pins with wait badges, list view toggle, registered centre first | loading, no services |
| S09 ⭐ | Ticket reserved | Countdown 45:00, "Activates when you arrive", "I'm here" (QR scan / geofence) | reserved, expired |
| S10 ⭐ | Live ticket | Big number (T-014), people ahead, est. minutes, current stage, progress steps | triage → doctor → pharmacy |
| S11 ⭐ | Visit complete | ✅, medicines in plain language, follow-up, rate visit | — |
| S12 | History | Past visits | empty |

## Staff app (`/staff`)
| ID | Screen | Key elements |
|---|---|---|
| T01 ⭐ | Staff login | Role pick: nurse / doctor / pharmacy / front desk (demo) |
| T02 ⭐ | Nurse queue | Queue list (number, age, complaint, wait time), "Call next" |
| T03 ⭐ | Intake card + vitals | AI intake (editable), red-flag warnings, vitals form (BP, HR, temp, SpO₂, weight), urgency select |
| T04 ⭐ | Handoff confirm | AI summary draft (editable), suggested doctor + reason, other doctors with load, "Confirm & send" |
| T05 ⭐ | Doctor queue + handoff | My queue, handoff card, "Done", prescription picker |
| T06 | Pharmacy queue | Queue, prescription, "Dispensed" |
| T07 | Front desk / kiosk | Check-in for walk-ins without phones — same AI chat on a tablet |
| T08 ⭐ | Waiting-room display | Now serving per counter (Triage 1, Room 4, Pharmacy), AR/EN, chime |
| T09 | Centre dashboard | Patients waiting per stage, avg wait, AI deflections, emergencies redirected |

## Wireframe sketch — S10 Live ticket
```
┌──────────────────────────┐
│  Al Wakra Health Centre  │
│                          │
│         T-014            │
│   ◉ Triage  ○ Doctor ○ Rx│
│                          │
│   4 people ahead         │
│   ~12 min                │
│                          │
│  Go to: Triage area, L1  │
│ ──────────────────────── │
│  Demo — not connected to │
│  PHCC/HMC systems        │
└──────────────────────────┘
```

Related: [[Feature Matrix]] · [[Staff Console]]
