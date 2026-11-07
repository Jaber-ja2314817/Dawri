---
tags: [build, resume]
updated: 2026-11-06
---

# Resume Point

Paused by the owner on Fri 6 Nov 2026 at about 17:25 Doha, so Claude could be restarted. **Read this first after a restart.** See [[Orchestrator Log]] and [[Build Decisions]].

## Where the build stands

| Phase | Status | Commit |
|---|---|---|
| 1. Foundation | Approved, pushed | `d0521fc` |
| 2. AI layer | Approved, pushed | `629d522` |
| 3. Full API | Approved, pushed | `5df531c` |
| 4. Patient app | **In progress, not approved.** Builders finished, first review was stopped partway | Saved as a WIP commit, see below |
| 5. Staff consoles | Not started | |
| 6. Integration and ship-ready | Not started | |

## The exact step
Phase 4, `orchestrator:review-1`. All four builder tasks had returned: T2 and T3 done, **T1 and T4 reported partial**. The review had started and returned no verdict, so nothing in Phase 4 has been verified or approved.

## Next actions, in order
1. Rerun the Phase 4 review against the vault, including what T1 and T4 left partial. Their reports are in the run journal.
2. Fix what it finds. Limit: 4 rounds.
3. Commit and push Phase 4, then run Phases 5 and 6 the same way.

Owner's standing instruction: **keep building until the main build is finished and do not stop for decisions.** Connections and Hugging Face come after the build. A phase that cannot pass after its last round is logged here in the vault, committed with `PROVISIONAL, not approved` in the subject, and the build moves on.

## Known at pause
- `.venv/bin/python -m pytest -q`: **10537 passed, 2 failed.** `test_api_visits.py::test_a_fresh_visit` and `test_the_list_is_mine_and_my_dependents_newest_first` assert an exact key set. Phase 4 added `rating` and `refill` to the visit response in `backend/routers/visits.py` and did not update these tests. Phase 4 must resolve this.
- The WIP commit holds unapproved work. Its subject starts `WIP, not approved:`.
- `Dawri-Vault/.obsidian/` changes are the owner's own and stay out of commits.
- Frontend unit tests and e2e were not rerun at pause.

## How to resume
- **Same session** (`claude --resume`): run Workflow with `scriptPath` set to the script below and `resumeFromRunId: wf_925fae5b-c90`. Cached agents replay and the Phase 4 review reruns.
- **New session:** resume is not available. Start a new workflow from `07 Build/orchestrator-workflow.js` (a copy of the script) with `PHASES` trimmed to Phases 4, 5 and 6. Begin Phase 4 with a review of the existing `frontend/` and do not rebuild it. Stage `Dawri-Vault/07 Build` in every commit, and use the attribution trailer in force in that session.
- Original script: `~/.claude/projects/-Users-jaberal-boenain-Desktop-Dawri/4c03dfbd-8767-4791-a2f8-95a198f5289f/workflows/scripts/dawri-orchestrated-build-wf_925fae5b-c90.js`
- Run journal: `~/.claude/projects/-Users-jaberal-boenain-Desktop-Dawri/4c03dfbd-8767-4791-a2f8-95a198f5289f/subagents/workflows/wf_925fae5b-c90/journal.jsonl`

## Update, Fri 6 Nov, about 17:35 Doha
Build resumed in a new session as run `wf_b653a907-cb4`, script `07 Build/orchestrator-workflow-resume.js`, with Phase 4 data in `07 Build/phase4-handover.json`. It reviews Phase 4 without rebuilding it, then builds Phases 5 and 6. The two stale tests in `test_api_visits.py` were widened first, so the backend suite started at 10539 passed. Docker Desktop was started for Phase 6.

- **Same session:** Workflow with that `scriptPath` and `resumeFromRunId: wf_b653a907-cb4`.
- **New session:** check `git log` to see which phases landed, trim `ALL_PHASES.slice(3)` in the script to what is left, and remove `PHASES[0].resume` unless Phase 4 is still unreviewed.
- Journal: `~/.claude/projects/-Users-jaberal-boenain-Desktop-Dawri/d2706c8e-316d-477a-8c11-293891467d78/subagents/workflows/wf_b653a907-cb4/journal.jsonl`

## Update, Sat 7 Nov, about 05:10 Doha
**Main build finished.** Read this section first, because the status table at the top is from 6 Nov.

| Phase | Status |
|---|---|
| 1 to 5 | Approved, pushed |
| 6. Integration and ship-ready | Approved in review round 4 of 4. Commit follows from the workflow |

- Evidence, the acceptance table and known gaps are in [[Orchestrator Log]], Phase 6.
- F12 stays unticked: nothing is deployed to a Hugging Face Space. F22 and F23 are dropped. Every other feature is ticked.
- Next is the Hugging Face work, which the owner runs: the README's numbered steps, after the three changes listed under "What is left for Hugging Face" in the log.
- `main` is untouched. The owner merges at the very end.
- This machine now holds a real token in the gitignored `.env`, so a plain local uvicorn runs in real mode. Start it with `HF_TOKEN=` set blank for simulated.

## Update, Sat 7 Nov, about 06:50 Doha
All six phases are approved and pushed on `build/dawri-app`. Submission is **14:00 Doha**. Private Space `xTamim/dawri` is live. Left: team tests on a real phone, Arabic and red-flag review, rehearsal, then on the owner's word make the Space public and merge to `main`. The tuned Fanar model must stay out of live chat.

## Update, Sat 7 Nov, about 07:05 Doha
On the owner's word, the Space `xTamim/dawri` is **public** and `build/dawri-app` is merged to `main`. The full handoff for the team is the "Dawri Team Handoff" doc.

