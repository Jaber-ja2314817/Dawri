---
tags: [ios, build, resume]
updated: 2026-11-09
---

# Resume Point (iOS build)

Paused again on 9 Nov 2026 at about 07:15 Doha, at the owner's request, during Phase 5. Details are in [[iOS Build Log]].

| Phase | State | Commit |
| --- | --- | --- |
| 1 Foundation | Approved, round 1 | `47c8458` |
| 2 On-device engine | Approved, round 1 | `a58b63b` |
| 3 Patient screens | Approved, round 2 | `42e6e73` |
| 4 Native features | Approved, round 2 | `7fe835f` |
| 5 Clinic server and ship-ready | Builders T1, T2 and T3 done. T4-integrate-ship was stopped mid-run. **Not reviewed** | WIP commit after `7fe835f` |

## Phase 5 state
- Plan (waves, briefs and acceptance): `phase5-reports/phase5-plan.json`.
  - Wave 1: T1-remote-core, T2-harden-docs-sign.
  - Wave 2: T3-app-server-mode.
  - Wave 3: T4-integrate-ship.
- Finished builder reports: `phase5-reports/p5-report-T1-remote-core.json`, `p5-report-T2-harden-docs-sign.json` and `p5-report-T3-app-server-mode.json`.
- T4-integrate-ship was stopped partway. Its edits, if any, are in the WIP commit. Its run must start again, and it should check the tree first.

## To resume
1. The workflow run (`wf_a81a1fd8-724`) cannot resume in a new session. Write a new run from `orchestrator-ios-resume.js` in this folder that:
   - skips Phases 3 and 4,
   - uses the saved Phase 5 plan instead of planning again,
   - returns the saved reports for T1, T2 and T3 instead of running them (the script already has a `done` and `reportDir` override for this),
   - runs T4-integrate-ship live, then the Phase 5 review, the commit, and the final build log entry.
2. Lesson from 8 Nov: when you skip finished agents, skip every one of them. If you skip only a failed one, the cache is lost for every agent after it.
3. Keep the no-credit rules in [[iOS Brief]]. Keep the Mac awake and on AC power during UI runs. The full UI suite is about 157 tests and takes about 70 minutes.
4. The extra simulator "Dawri Map" (FC231CFD) was made for the p4-map re-run and can be deleted.
5. Main moved during the build (teammates' `a70cedd`, `07ec7f7` and `542bc32`). This branch starts at `bb37797`.
