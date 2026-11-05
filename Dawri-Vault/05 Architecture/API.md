---
tags: [architecture, api]
skill: replica-architect
---

# API

All under `/api`. JSON in/out. Auth = demo session token in a header.

## Patient flow
| Method | Route | Body / result | Step |
|---|---|---|---|
| POST | `/auth/start` | `{qid}` → `{otp_sent:true}` | 1 |
| POST | `/auth/verify` | `{qid, otp:"0000"}` → `{token, patient}` | 1 |
| GET | `/me` | profile + dependents (from mock record) | 2 |
| POST | `/visits` | `{patient_id}` → `{visit_id}` (status `intake`) | 3 |
| POST | `/visits/{id}/chat` | `{text}` or audio upload → `{reply, done, emergency, intake?}` | 3 |
| POST | `/asr` | audio → `{text}` | 3 |
| POST | `/visits/{id}/intake/confirm` | `{json}` | 3 |
| GET | `/centres?service=gp&lat=&lng=` | centres with `wait_min`, `people_ahead` | 4 |
| POST | `/visits/{id}/reserve` | `{centre_id}` → reserved ticket | 5 |
| POST | `/visits/{id}/arrive` | `{lat,lng}` or `{qr_code}` → active ticket | 6 |
| GET | `/visits/{id}` | full state: stage, ticket, people ahead, est. wait | 6–10 |
| GET | `/visits/{id}/stream` | **SSE** live updates for the patient | 6–10 |

## Staff
| Method | Route | Purpose |
|---|---|---|
| POST | `/staff/login` | `{staff_id}` (demo) |
| GET | `/counters/{id}/queue` | queue list |
| GET | `/counters/{id}/stream` | **SSE** live queue |
| POST | `/counters/{id}/call-next` | next active ticket → `called` |
| PUT | `/visits/{id}/intake` | nurse edits intake |
| POST | `/visits/{id}/vitals` | vitals + urgency |
| POST | `/visits/{id}/handoff/draft` | AI draft + doctor suggestions |
| POST | `/visits/{id}/handoff/confirm` | `{final_text, doctor_id}` → doctor ticket |
| POST | `/visits/{id}/consult/done` | `{prescription:[...]}` → pharmacy ticket |
| POST | `/visits/{id}/dispensed` | visit `completed` |
| GET | `/display/{centre_id}/stream` | **SSE** for waiting-room TV |
| GET | `/stats/{centre_id}` | dashboard numbers (Could) |

## SSE event shape
```json
{"type":"ticket.called","visit_id":"V123","ticket":"T-014","counter":"Triage 1","people_ahead":0}
```
