---
tags: [ios, build, resume]
updated: 2026-11-08
---

# Resume Point (iOS build)

Paused on 8 Nov 2026 at about 10:30 Doha, at the owner's request, right after Phase 3 review round 1. Details and the fix brief are in [[iOS Build Log]].

| Phase | State | Commit |
| --- | --- | --- |
| 1 Foundation | Approved, round 1 | `47c8458` |
| 2 On-device engine | Approved, round 1. 479 core tests and every safety golden pass | `a58b63b` |
| 3 Patient screens | Built, **not approved**. One open failure: two screenshot-table states missing | WIP commit after `a58b63b` |
| 4 Native features | Not started | none |
| 5 Clinic server and ship-ready | Not started | none |

## To resume
1. The workflow run cannot resume in a new session. Start a new run from `orchestrator-ios.js` in this folder, edited so it:
   - begins at Phase 3 with the round 2 fix wave `gate-shot-rows` from the build log, then runs the Phase 3 review as round 2,
   - then runs Phases 4 and 5 unchanged.
2. Keep the no-credit rules in [[iOS Brief]].
3. Keep the Mac awake and on AC power during UI test runs. Clamshell sleep failed 4 UI tests in round 1, and all 4 passed after a rerun.
4. Main moved during the build: teammates added `a70cedd`, `07ec7f7` and `542bc32` (a 45-second ad). This branch starts at `bb37797`, so check those before merging.

## Resumed 8 Nov 2026
The owner asked to continue. New run `wf_a81a1fd8-724` from `orchestrator-ios-resume.js` in this folder. It starts at Phase 3 round 2 with `gate-shot-rows`, then plans and builds Phases 4 and 5 as before. The Phase 3 acceptance list was rebuilt from the round 1 reviewer's evidence, because the original plan was not saved. If this run dies in a later session, edit `orchestrator-ios-resume.js` to skip the phases already committed, as was done here.
