---
tags: [architecture, mock, data]
---

# Mock Health System ("demo account")

We cannot connect to PHCC/HMC or Tawtheeq in 48 hours, and we must not use real data. So we build a **fake national health record service** with the same *shape* a real integration would have, and label it clearly.

## What it pretends to be
| Real thing | Our mock |
|---|---|
| Tawtheeq national login | `/auth/start` + `/auth/verify`, OTP always `0000`, demo-patient quick-pick chips |
| National health record | `mock_health.py` returning FHIR-like JSON (Patient, AllergyIntolerance, Condition, MedicationStatement) from `seed/patients.json` |
| Centre queue system | Our own [[Queue Engine]], with an `adapters/` folder showing where a real queue integration would plug in |

Pitch line: *"Everything behind this dotted line is a mock with the same interface a real PHCC integration would use. Swapping it is an adapter, not a rewrite."*

## Seed patients (`seed/patients.json`)
```json
[
  {"id":"P001","qid_demo":"DEMO-10001","full_name_en":"Fatima Al-Demo","full_name_ar":"فاطمة التجريبية",
   "dob":"1992-03-14","sex":"F","preferred_lang":"ar","registered_centre_id":"C-WAKRA",
   "allergies":["penicillin"],"chronic":[],"active_meds":[]},
  {"id":"P002","qid_demo":"DEMO-10002","full_name_en":"Ahmed Al-Demo","full_name_ar":"أحمد التجريبي",
   "dob":"1959-07-02","sex":"M","preferred_lang":"ar","registered_centre_id":"C-RAYYAN",
   "allergies":[],"chronic":["hypertension"],"active_meds":["amlodipine 5 mg once daily"]},
  {"id":"P003","qid_demo":"DEMO-10003","full_name_en":"Ravi Demo","full_name_ar":"رافي",
   "dob":"1981-11-20","sex":"M","preferred_lang":"en","registered_centre_id":"C-AIRPORT",
   "allergies":[],"chronic":["type 2 diabetes"],"active_meds":["metformin 500 mg twice daily"]}
]
```
Need more? Generate synthetic patients with **Synthea** or a script — never real people.

## Centres (`seed/centres.json`)
Use real PHCC/HMC facility **names** (public info) so the map feels local, with coordinates taken from OpenStreetMap / Google Maps by hand. Start with 6–8 centres:
- PHCC: Al Wakra, Mesaimeer, Al Rayyan, Airport, West Bay, Abu Baker Al Siddiq, Umm Ghuwailina (all named in PHCC/press coverage)
- HMC (emergency layer): Hamad General Hospital, Al Wakra Hospital

```json
{"id":"C-WAKRA","name_en":"Al Wakra Health Centre","name_ar":"مركز الوكرة الصحي",
 "operator":"PHCC","lat":null,"lng":null,
 "services":["gp","dental","vaccination","lab_only","womens_health"],"has_emergency":0}
```
⚠ Fill `lat/lng` from a map before the demo — don't guess them.

## Simulated load
A small script adds 3–10 fake waiting tickets per counter on startup and advances queues every ~60 s, so the map shows different waits and the queue moves during the demo. Toggle with `SIMULATE_LOAD=1`.

## Labels
Every patient screen footer: **"Demo — synthetic data, not connected to PHCC/HMC systems."**
