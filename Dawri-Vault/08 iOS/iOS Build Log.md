# iOS Build Log

Per-phase evidence for the native iPhone app. Spec: [[iOS Brief]].

## Phase 1: Foundation (approved on review round 1 of 4, 7 Nov)

### Plan
Agree the design in [[iOS Design]], then build `ios/`: the Xcode project, the `DawriCore` package, the models and `ClinicService`, the string sync, the design system, and an app shell on a stub service that shows a real S01 in Arabic and English.

### What was built
- **Design:** `iOS Design.md` records what each skill decided and how conflicts were settled. It covers light and dark tokens, contrast ratios, Dynamic Type, springs, haptics, Reduce Motion, RTL, the system chrome ruling, S01 to S12 plus Consent and Settings, Live Activity layouts and Swift names.
- **Project:** `Dawri.xcodeproj`, objectVersion 77, with three synchronized groups. Targets are Dawri, DawriLiveExtension and DawriUITests, plus the shared Dawri scheme. `Config/Shared.xcconfig` sets team and bundle prefix. No entitlements and no remote packages.
- **DawriCore:** all 31 types from `types.ts`, `ClinicError`, `ClinicService` with the `visitUpdates` stream, `StubClinicService`, the stage, route and gate rules, strings, language state, `DSPalette`, and `TicketActivityAttributes` guarded by `#if os(iOS)`.
- **Tools:** `sync-strings.py`, `export-api-fixtures.py`, `make-icon.swift`, `shoot.sh`.
- **App:** design system components, `PatientScaffold`, `VisitGate`, `VisitWatcher`, `DirectionBridge` for live RTL, the real S01, placeholders for all other routes, and DEBUG hooks. The Live Activity is a placeholder that nothing starts yet.

### Evidence (the reviewer's own runs)
- `swift test`: 112 tests in 15 suites passed, 0 warnings. `xcodebuild -scheme DawriCore` for iOS Simulator succeeded.
- `xcodebuild test` on Dawri Build: 20 of 20 UI tests passed. They cover S01 in both languages, the default Arabic launch, the full stage table, the never-offers-chat flips, Back cannot reach chat after an emergency, and live switches both ways that keep the path and move Back and the swipe edge.
- Release simulator build: the built plist matches the brief, and `strings` finds no demo hooks. A fresh install launched in Arabic, and launch arguments were ignored. `generic/platform=iOS` built with `CODE_SIGNING_ALLOWED=NO`.
- `DawriLiveExtension.appex` is embedded as `com.jaber.dawri.live`. `assetutil` shows the icon's default, dark and tinted forms. The three icons regenerate byte for byte from `make-icon.swift`.
- Strings: 258 keys in each language, equal key sets, no `staff.*`, placeholders match. Changing a generated Arabic value failed both `--check` and the Swift drift test. The file was restored and verified identical.
- Exporter: refused with exit 2 before any backend import, with `HF_TOKEN` unset and with `HF_TOKEN=abc`.
- Design: 17 ratios recomputed independently and all matched, including footer text (4.84, 7.87) and the dark hue on a dark card (6.16). `DSPalette` matches all 38 tokens in section 1.1.
- Screenshots: all 61 from `shoot.sh` viewed. S01 ground is `#f2f4f7` and `#101113`. Below the status bar, S01 has no saturated pixel, so no hue and no red. The footer and AI line are visible in both languages. Arabic is right-aligned and shaped. Nothing is clipped at AX3.
- No credits: `grep` finds no `hf.space`, `huggingface` or `URLSession` under `ios/`. The Bash commands in the six builder transcripts include no `hf`, no read of `.env` and no started `uvicorn`. The only backend run was the in-process exporter with `HF_TOKEN=` blank.
- Repo: on `build/dawri-ios`, `main` at `bb37797`, no change in `backend/` or `frontend/`, and no build output under `ios/`. The iPhone 17 simulator stayed booted and unused.

### Known gaps
- **`iOS Design.md` has fallen behind the code in four places.** Correct it before Phase 2 or brief builders around it.
  - Section 7.4 still says to rebuild with `.id(language)`. The app must not, because the tested method is `DirectionBridge`. A builder who follows the note would break the path.
  - Section 4.4 names `.accessibilityLanguage`, which is not a SwiftUI modifier.
  - Section 12 says `ios/Dawri/DesignSystem/`. The folder is `ios/Dawri/Design/`.
  - Section 10 says upscale 2x. `make-icon.swift` sharpens at 4x and averages down.
- `emergencyLink` and `track.stepOf` exist in code but are missing from sections 1.1 and 12.
- `AppModel.switchLanguage` is the only path that updates `DirectionBridge`. `LanguageState.applyPreferred` on login and `reset` on logout will change the language without moving the bars, so the login phase must route them through it.
- `TicketLiveState` lacks the ticket state and centre name that section 9 needs. `live.go` and `live.ahead` are not yet in the strings. The placeholder hard-codes hex values instead of reading `DSPalette`.
- S06 is a pushed placeholder until the S06 build moves it to the root `fullScreenCover`. Its white status bar relies on `.preferredColorScheme(.dark)`, which needs checking on the cover.
- `VisitGate` has no `redFlag` branch yet, so 999 before the visit loads belongs to the S06 build. `send.ts` helpers are not ported. The mid-swipe wait in `AppModel.replace` was read in code but not exercised.
- Only the iOS 26.5 runtime exists here. The iOS 18 look and live RTL on iOS 18 to 25 are unproven. VoiceOver speech, motion and haptics are not proven by these tests.
- The Arabic of the new phone-only keys has had no native review.
- `DawriUITests/Support.swift:54` gives one main-actor warning, in test code only.
- `xcodebuild` recreates `ios/DawriCore/.swiftpm` and empty folders in `project.xcworkspace`. Neither holds files git would track.
- `news_app` files changed during this phase. The peer session `news-app-3f` was busy at the time, the diff never mentions Dawri, and no Dawri command wrote there. It was not changed from here.
- Nothing is committed yet. `ios/` and this folder are still untracked.

## Phase 2: On-device engine (approved on review round 1 of 6, 7 Nov)

### Plan
Port the clinic to Swift as `LocalClinicService`, so the app works on a phone with nothing else running. Rule cues, normalisation tables and seeds are exported from the Python source, not retyped. A golden corpus from the real Python functions proves the port. The driver for the demo clinic applies the allergy rule, and state persists as JSON in Application Support. The contract suite is shared, so the Remote phase can reuse every case. No screen work in this phase: S02 to S12 stay placeholders.

### What was built
- **Exporters:** `ios/Tools/export-engine-data.py`, `export-goldens.py` and `ios/Tools/export/`. `harvested-inputs.json` is checked in, so a rerun needs no pytest.
- **Resources:** `engine.rules.*.json` and `engine.clinic.*.json` in `DawriCore`.
- **Goldens:** 25 files in three folders under `Fixtures/goldens/`, about 30 MB, each with a manifest of counts, hashes and stated exclusions.
- **`Engine/Rules`:** ports of `text`, `redflags`, `refill`, `simulated` and the scripted paths of `receptionist` and `intake`. Rule text is held as `[UInt32]`, and `\w`, `\s` and digits come from exported tables. `gate_reply`, `check_handoff` and every model path are absent.
- **`Engine/Clinic`:** `QueueEngine`, `VisitFlow`, centres, doctors, medicines, mock health, simulated load, Doha time and geo.
- **`Engine/Local`:** `LocalClinicService`, `ChatFlow`, `FileClinicStore`, `DemoClinic` and the separate `DemoDriving` protocol.
- **App:** `AppModel.launch` uses `LocalClinicService`, `StubClinicService` is deleted, and `DemoLaunch` stages visits by walking the real engine. Five new engine-on-iOS UI tests were added.
- **`iOS Design.md`:** sections 7.4, 4.4, 12, 10 and 1.1 corrected as Phase 1 listed. The diff touches only those sections.

### Evidence (the reviewer's own runs)
- **`swift test`:** 300 tests in 49 suites passed, 31 s from a clean build, 0 warnings. Three more full runs also passed. The builder's one-off `no counter C-WAKRA-D9` failure did not recur.
- **The same 300 tests on iOS:** `xcodebuild test -scheme DawriCore` on Dawri Build (iOS 26.5) passed, goldens included, so iOS Foundation and ICU agree with the corpus there.
- **`xcodebuild test` on Dawri Build:** 25 of 25 UI tests passed in 372 s, including Ravi in both languages with Back unable to reach chat, Ahmed's Arabic sentence reaching refill, and Fatima's Arabic sentence staying in chat.
- **Corpus, read from the manifests:** all minimums met.

| Family | Count |
| --- | --- |
| Red-flag single | 83,288 (en 30,303, ar 52,985) |
| `check_conversation` | 5,979 |
| Refill | 9,943 |
| Text | 16,370 |
| Regex | 9,145 |
| Parsers | 5,417 |
| Read-back | 6,742 |
| `next_turn` | 6,659 |
| Sessions | 3,498 |
| Queue traces | 302 |
| Medicines | 1,318 |
| Doctors | 945 |
| Centres | 2,067 |
| Geo | 218 |
| Time | 230 |
| Allergy | 189 |
| Refusals | 61 |

- **Cue coverage:** an independent count over the golden gives 44 cases for the least-covered of the 736 cues, the same as the manifest. Each corpus family was sampled from the golden files and `variants.py`.
- **Differential fuzz, not in the repo:** a reviewer-written generator ran 120,000 hostile messages and 30,000 conversations through the real Python functions. It used ligatures, presentation forms, NFD and NFKD, fullwidth, astral characters, bidi marks, every line break and mixed languages. Swift matched on every field: normalise, tokens, hits, denied, refill and all parsers. About 58% of the singles fired a rule.
- **Second corpus, not in the repo:** all goldens were regenerated on a scratch mirror with a different seed and extra hostile answers fed into the conversation plans. The whole suite passed unchanged against them.
- **Mutations, on a scratch mirror, each failed `swift test`:**
  - The seven listed: cue removed, window 3 to 4, U+0640 kept, ، not a clause break, queue order flipped, allergy filter removed, comment added to `redflags.py`. The data mutants were also run with the manifest hash repaired, so the decision goldens had to catch them unaided.
  - Mine: window 3 to 2, waw guard off, never-negated off, `emergency_today` off, the long-message rule path off, decimal point breaks a clause, sticky emergency off, and `summary_reply` keeping a rejected read-back.
- **Exporters:**
  - `--check` exit 0 for both.
  - Two full runs with different hash seeds are byte-identical and equal to the checked-in files.
  - With `HF_TOKEN` unset and `HF_TOKEN=abc`, each exits 2 with 0 backend imports under `-X importtime`.
- **Static checks:** no Arabic in `Engine/Rules`, no `Character`, `Set<String>`, Swift regex or rule-text `String ==` there, `StubClinicService` gone. `ClinicContract.swift` names no concrete service and covers the brief's list.
- **Screens:**
  - All 63 captured with `shoot.sh`. Viewed S01, S09 and S10 in both languages, the emergency stage in both, AX3 Arabic and the Release launch. Footer and AI line are visible, Arabic is right-aligned, and nothing is clipped.
  - Compared with the Phase 1 review set, 46 are byte-identical. The 15 that differ show only anti-aliasing or the simulator's Dynamic Island box, not app content.
- **Release:** `strings` finds no demo hooks. A fresh install with launch arguments still showed the Arabic welcome, with no session and no visits, and wrote `clinic-state.json` under Application Support (24,342 bytes). `generic/platform=iOS` built with `CODE_SIGNING_ALLOWED=NO`.
- **No credits:** 609 builder and reviewer Bash commands searched. None ran `hf`, read `.env`, started `uvicorn` or called a Hugging Face or provider host. The hits are guards and searches. Every backend-importing run went through `common.enter` with `HF_TOKEN=` blank and sockets blocked. The harvest ran only its allowlist.

### Known gaps
- **`main` moved during this review, but not from this build.** It went from `bb37797` to `542bc32` at 23:03 by a fast-forward to `origin/main`, the minute GitHub Desktop started on this Mac. The three commits are O0OP's from the morning of 7 Nov and touch `dawri*`, `README.md`, a `.claude` file and `Dawri-Vault/08 Submission`, with nothing in `backend`, `frontend` or `ios`. No agent ran a pull, fetch or merge on it. `git diff main -- backend frontend` is still empty and `build/dawri-ios` is unaffected. Later reviews should use `542bc32` as the baseline.
- **Two acceptance greps are not literally empty, and neither hides a real problem.**
  - The network grep hits two comments in Sources saying the app never calls `/api/asr` (`Responses.swift:35`, `ClinicService.swift:16`), plus three guards in `DriftTests`, `JourneyTests` and `harvest_plugin.py`. Rewording the two comments would make the Sources grep empty.
  - The skip grep hits `DSPalette.disabledText` in `DesignContrastTests.swift`. Use `\.disabled\(` from now on.
- **The golden coverage test has a blind spot for `refill.json`.** The doc comment in `GoldenSupport.swift` contains the exact call it searches for, so it would still pass if the real test stopped loading that file. It caught the same change on `text_proclitics`. The golden itself is loaded and run. `mock_health` is also named there, by a real load.
- **`saveTurn` passes `chat.language` where `_save_turn` passes `result.language`.** That branch cannot fire on the phone, because `run_turn` has already run the same rules on the same history. It should still be aligned.
- **A non-decimal digit such as `፩` at the read-back has no golden.** Python raises a 500 and Swift treats it as no number and carries on. Five manifest exclusions record this. `ChatFlow`'s 500 path is not exercised by a test.
- **19 cues are shadowed by an earlier cue of the same label, so they never appear in a result.** A decision golden cannot catch removing one, but the resource hash test can, and did in the reviewer's run.
- **Unicode data on older iOS is unproven.** Goldens pass on macOS and iOS 26.5, with Python's 16.0 tables exported. On iOS 18, NFKC and lower-casing could differ, but only on recently assigned characters. Launch time on a real phone is also unmeasured, because seeding runs on the main thread.
- **Audit and behaviour choices with no Python equivalent:** the `demo.step` event, `demo:clinic` as actor, and catch-up stamping a step at its due time.
- **`QueueEngine.swift:228` keeps Python's staff error text with "no-show".** It is not a claim, and no patient route reaches it.
- **The owner's iPhone 17 simulator shows Shutdown, and a different iPhone Air (`F7E60EDF`) is booted.** No command in this phase named either, so the change came from outside it. Dawri Build was left shut down.
- **Carried to the screen phases:**
  - `LanguageState.applyPreferred` and `reset` still bypass `AppModel.switchLanguage`.
  - A saved session shows Welcome briefly on relaunch.
  - Staged DEBUG launches run the demo clinic on the real clock, so a screen left open moves on.
  - `DawriCore_DawriCore.bundle` is embedded in both the app and the extension.
- **Nothing from this phase is committed yet.**

## Phase 3: Patient screens, PAUSED after review round 1 (not approved)

Paused by the owner on 8 Nov 2026 at about 10:30 Doha, right after review round 1. The run (`wf_004c4ea5-656`) was stopped before round 2 changed any file. The work is committed as WIP so nothing is lost. Phases 1 and 2 were approved in round 1 and are in `47c8458` and `a58b63b`.

### Open failures (review round 1, word for word)

- Shot-table coverage: Design section 8 lists VisitGate loading (skeleton) and VisitGate error (ErrorBlock with retry) for every visit screen, and neither has a row in ios/Tools/shots/*.tsv. The only getVisit rows are the S06 rows and s03-demo-reset (gone). The acceptance check needs every state in Screens.md and Design section 8 to have a row. The states work when shot by hand with -demoScreen s10 -demoFreeze 1 -demoHold getVisit and with -demoFail getVisit=network, so only the rows are missing.

### Fix brief for round 2

**gate-shot-rows: Add VisitGate loading and error rows to the shot table**
Owned paths: ios/Tools/shots/visit.tsv

Design section 8 says every visit screen has VisitGate states: loading (SkeletonBars under the screen's title), an ErrorBlock with retry, and gone. Gone already has the row s03-demo-reset. Loading and error have no row in any ios/Tools/shots/*.tsv, so the shot-coverage check fails.

Add two rows to ios/Tools/shots/visit.tsv:
- gate-loading, settle about 3 s, flags ax3, arguments -demoScreen s10 -demoFreeze 1 -demoHold getVisit
- gate-error, settle about 3 s, arguments -demoScreen s10 -demoFreeze 1 -demoFail getVisit=network
You may also add one more of each on another visit screen, such as s08. The reviewer shot these by hand and they render correctly, so no app code should change. If a row does not show the state, report it and do not change app code outside your path.

Then run, with your own --derived folder and an output folder in the scratchpad, never under ios/:
  ios/Tools/shoot.sh --only 'gate-*' <scratchpad>/shots
Confirm:
- every PNG is 1260x2736, in ar and en, light and dark, plus ax3
- the colour scan finds no #1d5fbf or #689ce8 hue and no image above 1% #c4242a
View the images: Arabic right-aligned, Back on the right, footer and AI line present, nothing clipped at AX3.

Use only the Dawri Build simulator (B55FEAC2-08EB-460D-9261-E28A60F4B5CC) and leave it shut down. Keep the Mac awake: if the lid is closed on battery it sleeps, and runs stall. Remove ios/DawriCore/.swiftpm if xcodebuild creates it.

The no-credit rules apply in full: no hf, no .env, no server, no request to any Hugging Face or provider host. Do not commit.

### Known gaps and phone test items (review round 1, word for word)

- Environment: in the clean full UI run, 4 tests failed only because the Mac went into clamshell or maintenance sleep on battery (pmset log, 08:07 to 09:12 and 09:27 to 09:29), and because CoreSimulatorService restarted at 09:33:17. All 4 passed on a rerun with the Mac awake. Future full runs need the lid open or AC power.
- The 09:33 CoreSimulatorService restart shut down the owner's iPhone Air simulator F7E60EDF, which was booted at the start. No command in this review named it. Other agent sessions on this Mac (a Maghselty iOS project) were active at the time.
- Accessibility audit exclusions that have a written reason but deserve a look on a phone:
- textClipped on the Settings server field (cause not found)
- textClipped by label on the Arabic footer and two other Arabic strings
- contrast for anything in the top 200 pt under the system bar
The screenshots show all of these whole.
- Phone-only items, implemented and tested with fakes: VoiceOver order and isolation of S06 from the stack under it, haptics, the 999 dialer, Maps for the map link, Reduce Motion at runtime, the iOS 18 look, and the high-priority called announcement.
- Location, camera, microphone (on-device Speech), MapKit and Live Activity are seams with honest defaults (NoLocationSource, NoServerProbe, UnavailableVoiceEngine, CentreMapSlot) for later phases. In Release, S05's mic says voice is unavailable and the patient types.
- Fatima's first chat question is in Arabic even when the app is in English. The engine uses the record's preferred language, as the web does.
- In the staged Arabic chat screenshots, the patient's own answer shows the Eastern Arabic digit ٦. Messages are never altered, and the app's own figures are Latin.
- The system segmented controls (Settings, S08) stay small at AX3, which Design section 5 accepts.
- Nothing from Phase 3 is committed yet. The iOS Build Log has no Phase 3 section until approval.

### Reviewer evidence (round 1)

Everything below is from my own runs on build/dawri-ios. Main is at 542bc32. I started no server, never read .env, ran no hf command, and sent nothing to any Hugging Face or model provider host.

CORE TESTS
- swift test from a clean scratch path (scratchpad/rev3/spm): 479 tests in 75 suites passed, 0 warnings.
- A grep for XCTSkip, .disabled( and withKnownIssue in DawriCore/Tests and DawriUITests finds nothing.
- xcodebuild test -scheme DawriCore on Dawri Build: 479 tests passed, goldens included (TEST SUCCEEDED).

UI TESTS (scratchpad/rev3/ui.log, ui-rerun.log)
- The full Dawri run from a clean derived data folder (rev3/dd-ui): 120 of 124 passed.
- The 4 failures were environmental, not app faults:
  - EverywhereTests, both walks: "Timed out while synthesizing event". pmset shows the Mac in clamshell or maintenance sleep from 08:07 to 09:12, with 466 to 1000 s stalls in XCTest.
  - StageTable testEveryRowLandsOnItsCanonicalScreen: its 98 s gap is exactly the 09:27:12 to 09:29:06 clamshell sleep.
  - VisitScreen testFatimaWalks: "crashed with signal term". CoreSimulatorService restarted at 09:33:17, which also shut down the owner's iPhone Air F7E60EDF. No command of mine named it.
- Rerun of those 4 tests with the Mac awake and no sleep logged: all passed (exit 0). EverywhereTests passed in Arabic and English (348 s each), and so did StageTable and testFatimaWalks.
- Total: 124 of 124. That includes:
  - JourneyTests 7: Fatima to T-014, then D-GP-023 and P-031, medicines with no penicillin family, rating, History; Ahmed to S07 with no ticket, then S08; Ravi to S06, then Start check-in returns to S06 with no chat. In AR and EN.
  - EmergencyScreenTests 15, ChatScreenTests 10, AccountScreenTests 23, VisitScreenTests 13, SessionTests 9, AccessibilityAuditTests 2, SwipeHoldTests 2.
  - The 25 earlier behaviours.

CODE READING
- JourneyTests: each launch passes only -demoLang and -demoFreeze 0, with no -demoControls and no staging hook.
- RootView: S06 is a root fullScreenCover on its own Color.clear with disablesAnimations, and its binding setter is a no-op.
- EmergencyCallButton: the action is only openURL(tel://999), with no await, haptic or dialog.
- EmergencyPending shows the title and Call 999 while getVisit is held.
- ChatModel:
  - applyTurn handles a red flag first, and toEmergency checks the session token.
  - A retry calls landed() before it sends.
  - sendText leaves the draft alone.
- ChatModelTests names every ChatScreen.test.tsx and Screens.test.tsx case word for word. The unported cases are listed with where they are covered: scroll, the scripted note, ASR codes, and S06, which is in EmergencyScreenTests.
- ServerAddressTests cover case, trailing dot, userinfo, port, subdomain, disguised spellings and http to non-local hosts. NoServerProbe throws, so Release can never show Connected.
- AppModel.changeLanguage is the only language path. switchLanguage, applyPreferred and reset all call it, and it moves DirectionBridge.
- There is no .id( on the NavigationStack.
- Every transition is chosen by reduceMotion and every animation uses a DS.Motion constant.
- VoiceOver labels are present on the countdown, the track and the ticket number. The called announcement is high priority.

SCREENSHOTS
- shoot.sh over all 112 rows: 552 PNGs, all 1260x2736. Every row exists in ar and en, light and dark, plus 26 ax3 rows. None are under ios/.
- I viewed contact sheets of S02, S03, S04, Consent, S05, S06, S07, S08, S09, S10, S11, S12, Settings and live-s06, in AR and EN, light, dark and AX3, and found no fail against the 21 points:
  - Arabic is right-aligned and joined. Back is on the right in Arabic. The stage track starts on the right. Digits are Latin.
  - D-GP-023 fills the card. Nothing clips at AX3.
  - S06 has a white status bar, no back, and a pinned Call 999.
  - Footer and AI line are on every screen.
- The S05 AX3 scroll-under-bar softness is the system edge effect.
- My own colour scanner (rev3/scan.py, top 170 px excluded) passed all 552:
  - no #1d5fbf or #689ce8 outside S10 and the gallery
  - no image other than S06 and the gallery above 1% #c4242a
  - all 44 S09 images have zero hue
  - every S10 state with a number has hue

RELEASE AND DEVICE
- Release simulator build succeeded. strings shows no launch hooks (only engine field names).
- A fresh Release install launched with -demoScreen s10 -demoLang en -demoControls 1 -demoTheme dark showed the Arabic light welcome.
- generic/platform=iOS with CODE_SIGNING_ALLOWED=NO: BUILD SUCCEEDED.
- sync-strings --check exits 0. export-engine-data --check and export-goldens --check both exit 0 with HF_TOKEN= blank, HF_HUB_OFFLINE=1, SIMULATE_LOAD=1 and a temp DAWRI_DB, and report ai_mode simulated.

GREPS
- The network grep hits only ServerAddress.swift and the two known comments.
- No Speech, CoreLocation or AVFoundation import in ios/Dawri.
- No "place held" or "no-show" in ios/Dawri or the strings.
- PlaceholderScreen and placeholder.title are gone.

REPO
- git diff main -- backend frontend is empty.
- Under Engine/ only LocalClinicService.swift (restoredSession) and LocalClinicService+Debug.swift changed. Goldens and rule resources are unchanged.
- I removed ios/DawriCore/.swiftpm (created by xcodebuild). Nothing ignored or built is under ios/.

TRANSCRIPTS
- A line-level scan of 1,256 builder Bash commands found:
  - no hf or huggingface-cli
  - no curl or wget
  - no read of .env
  - no uvicorn start

SIMULATOR
- Dawri Build was left shut down, as I found it.

THE ONE FAILING CHECK: state coverage of the shot tables
- iOS Design section 8 says every visit screen has VisitGate states: loading with SkeletonBars, an ErrorBlock with retry, and gone.
- "Gone" has a row (s03-demo-reset). Loading and error have no row in any ios/Tools/shots/*.tsv. The only getVisit rows are the S06 ones and the 404 reset.
- I captured both states by hand on S10 and S08 (rev3/gate/*.png). They render correctly: a title with skeleton bars, and the network ErrorBlock with Retry. So only the rows are missing.
- Every other state in Screens.md and Design section 8 has a row. The exclusions are Map selection, camera denied (the door-sheet row stands in) and Live Activity, which are later phases.

