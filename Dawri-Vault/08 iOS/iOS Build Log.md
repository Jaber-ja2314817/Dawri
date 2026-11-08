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

## Phase 3: Patient screens (approved on review round 2 of 4, 8 Nov)

### Plan
Build every patient screen, S01 to S12, and a Settings screen in SwiftUI on `ClinicService`, in every state listed in [[Screens]] and [[iOS Design]] section 8. Each screen behaves as `frontend/src/pages/patient`, `frontend/src/features` and `frontend/src/components` do. That covers:
- consent, dependents, and chat with the summary card and the is-this-right confirm
- the emergency override with no ticket, and the refill route
- the centre list, with a map placeholder until Phase 4
- the reserved countdown and expiry, live ticket steps, and complete with medicines and rating
- history, the language toggle everywhere, and the demo footer and AI simulated line on every screen
- the labelled Demo next step control

Screens are judged from simulator screenshots in AR and EN, light and dark, at the Dawri Build iPhone Air size. The Phase 3 acceptance list was rebuilt for the resumed run from the round 1 reviewer's evidence, because the original plan was not saved.

### What was built
- **Screens** (`ios/Dawri/Screens/`):
  - Account: Login, Home, Who, Consent, History, Settings.
  - Chat: `ChatScreen`.
  - Emergency: `EmergencyScreen`, a root `fullScreenCover` with Call 999 pinned at the bottom.
  - Visit: `RefillScreen`, `CentreScreen` with `CentreMapSlot`, `ReservedScreen` with `DoorCodeSheet`, `TicketScreen`, `CompleteScreen`.
- **App shell:** `AppModel` with one language path, `changeLanguage`. Also `VisitGate` with its loading, error and gone states, `VisitWatcher`, `VisitList`, `RootView` and `PhoneFeatures`. The phone features are seams with honest defaults for Phase 4.
- **DawriCore `Patient/`:** `ChatModel`, `ChatRules`, `VoiceModel`, `TicketRules`, `VisitRules`, and `ServerAddress`, the guard that refuses Hugging Face hosts and non-local `http`. Each has its own test suite. Six phone-only string keys were added to each language.
- **Debug only:** `DemoLaunch`, `DemoClinicProxy`, `DemoAccount`, `DemoChat`, `DemoVisit` and gallery pages, compiled out of Release.
- **Shot tables:** `ios/Tools/shots/{account,chat,shell,visit}.tsv`, 116 rows.
- **UI tests:** `JourneyTests` (Fatima, Ahmed and Ravi in AR and EN, plus Fatima for a dependent) and per-screen suites: Account, Chat, Emergency, Visit, Session, SwipeHold and AccessibilityAudit.
- **Code:** WIP commit `64e1525`. The round 2 fix is one change to `ios/Tools/shots/visit.tsv`.

### Round 1 failure and its fix
- **Failure, round 1:** shot-table coverage. Design section 8 lists VisitGate loading (skeleton) and VisitGate error (ErrorBlock with retry) for every visit screen, and neither had a row in `ios/Tools/shots/*.tsv`.
- **Fix, `gate-shot-rows`:** four rows and a two-line comment at the end of `visit.tsv`, with no app code changed:
  - `gate-loading` (S10, ax3)
  - `gate-error` (S10)
  - `gate-s08-loading`
  - `gate-s08-error` (ax3)

  They use `-demoHold getVisit` and `-demoFail getVisit=network`. Gone stays covered by `s03-demo-reset`.
- **Re-verified in round 2:** `git diff 64e1525` touches only `visit.tsv` under `ios/`. All four rows rendered through the real `VisitGate`:
  - loading: the screen title, a 200 by 20 bar and a card-sized bar
  - error: the network `ErrorBlock` with Retry

  Every state in Screens.md and Design section 8 now has a row. The only exclusions are Map selection, camera denied and Live Activity, which belong to Phase 4.

### Evidence (the reviewer's own runs, round 2)
Everything below is from my own runs on `build/dawri-ios`, in `scratchpad/r2`. I started no server, never read `.env`, ran no `hf`, and sent nothing to any Hugging Face or model provider host. The Mac was on battery for the first part and wrapped in `caffeinate -i`, and `pmset` logged no sleep. Charging started during the shoot.

**Core tests**
- `swift test` from a clean scratch path: 479 tests in 75 suites passed, 0 warnings, 0 skipped, exit 0. Every safety golden ran and passed: `redflags_single`, `redflags_conversation`, refill, text, regex, parsers, readback, `next_turn`, the session replay, the clinic goldens and the manifests.
- A grep for `XCTSkip`, `.disabled(` and `withKnownIssue` in `DawriCore/Tests` and `DawriUITests` finds nothing.

**UI tests**
- `xcodebuild test` of the full Dawri scheme on Dawri Build from a clean derived data folder: 124 of 124 passed with 0 failures in 3,606 s, in a single run with nothing to rerun.

| Suite | Tests |
| --- | --- |
| JourneyTests | 7 |
| AccountScreenTests | 23 |
| EmergencyScreenTests | 15 |
| VisitScreenTests | 13 |
| ChatScreenTests | 10 |
| SessionTests | 9 |
| EverywhereTests | 4 |
| BackTests, EngineOnDeviceTests, FoundationHookTests, StageTableTests | 3 each |
| AccessibilityAuditTests, LanguageTests, SwipeHoldTests | 2 each |
| WelcomeTests | 1 |

- The JourneyTests ran with only `-demoLang` and `-demoFreeze 0`:
  - Fatima in AR and EN, and for a dependent: ticket, medicines with no penicillin family, rating, History.
  - Ahmed in AR and EN: S07 with no ticket or number, then S08.
  - Ravi in AR and EN: S06 with no back and no ticket.

**Screenshots**
- `ios/Tools/shoot.sh` over all rows, with its own derived folder: "116 rows, 576 images", exit 0. The PNGs were written to the scratchpad, outside `ios/`.
- The file set equals the expected list exactly: ar and en, light and dark, plus the 28 ax3 rows. All 576 are 1260x2736.
- Colour scan, my own CoreGraphics scanner (top 170 px excluded, tolerance 30 per channel):
  - no `#1d5fbf` or `#689ce8` pixel outside S10 and the gallery
  - a wider saturated-blue net also finds none there
  - S09 has 0 blue
  - every S10 row has hue
  - no image other than S06 and the gallery is above 1% `#c4242a`, and the gate rows have 0
- Contact sheets viewed:
  - S02, S03, S04, Consent, S05, S06, S07, S08, S09, S10, S11, S12, Settings, live-s06, the four gate rows, and every ax3 row
  - in AR light, EN dark and the full gate set

  What they show:
  - Arabic is right-aligned and joined. Back is on the right in Arabic.
  - The stage track starts on the right in Arabic. Digits are Latin.
  - The footer and AI simulated line are on every screen, including the door sheet.
  - S06 has a white status bar, no back, and Call 999 pinned at every size.
  - Nothing is clipped at AX3.

**Release and device**
- Release simulator build: BUILD SUCCEEDED. `strings` on the Release binary finds no launch hook (`demoScreen`, `demoFreeze`, `demoHold`, `demoFail`, `demoControls`, `demoTheme`: 0). The Debug dylib has them, so the search works. Only engine type names and `DemoNextStepButton` remain.
- `generic/platform=iOS` with `CODE_SIGNING_ALLOWED=NO`: BUILD SUCCEEDED.

**Exporters**, run with `HF_TOKEN=` blank, `HF_HUB_OFFLINE=1`, `SIMULATE_LOAD=1` and a temp `DAWRI_DB`:
- `sync-strings --check`: up to date, exit 0.
- `export-engine-data --check`: exit 0, and it prints "ai_mode simulated" for rules and clinic.
- `export-goldens --check`: exit 0, all minimums met.
- The backend reports `ai_mode simulated` through `common.enter`.

**Repo and greps**
- `git diff bb37797 -- backend frontend` is empty.
- Since `a58b63b`, the only changed resources are the two strings files (six phone-only keys each). Goldens and `engine.rules.*` / `engine.clinic.*` are unchanged.
- The network grep over `ios/` hits only:
  - `ServerAddress.swift`, and its tests
  - the two known `/api/asr` comments (`ClinicService.swift:16`, `Responses.swift:35`) and the guard tests
  - plist DOCTYPE lines and the sample LAN address
- No `URLSession` anywhere. No Hugging Face host outside the refusal guards.
- No `Speech`, `CoreLocation` or `AVFoundation` import in `ios/Dawri`. `MapKit` is imported only in `EmergencyScreen` for `MKMapItem.openInMaps`, as Design section 8 says.
- No "place held" or "no-show" in `ios/Dawri` or the strings.
- My `xcodebuild` runs recreated `ios/DawriCore/.swiftpm` (empty), and I removed it. Nothing built or ignored is under `ios/`.

**Simulators**
- Dawri Build was shut down at the start and was left shut down.
- The owner's iPhone Air `F7E60EDF` was shut down throughout and never named.

### Known gaps and phone test items
- **Phone-only items, implemented and tested with fakes:** VoiceOver order and isolation of S06 from the stack under it, haptics, the 999 dialer, Maps for the map link, Reduce Motion at runtime, the iOS 18 look, and the high-priority called announcement.
- **Accessibility audit exclusions** that have a written reason but deserve a look on a phone:
  - textClipped on the Settings server field (cause not found)
  - textClipped by label on the Arabic footer and two other Arabic strings
  - contrast for anything in the top 200 pt under the system bar

  The screenshots show all of these whole.
- **Seams for later phases:** location, camera, microphone (on-device Speech), MapKit and Live Activity have honest defaults: `NoLocationSource`, `NoServerProbe`, `UnavailableVoiceEngine` and `CentreMapSlot`. In Release, S05's mic says voice is unavailable and the patient types.
- Fatima's first chat question is in Arabic even when the app is in English. The engine uses the record's preferred language, as the web does.
- In the staged Arabic chat screenshots, the patient's own answer shows the Eastern Arabic digit ٦. Messages are never altered, and the app's own figures are Latin.
- The system segmented controls (Settings, S08) stay small at AX3, which Design section 5 accepts.
- **Environment, round 1:** sleep and a CoreSimulatorService restart failed 4 UI tests, and all passed on a rerun. In round 2 the full suite passed in one run with `caffeinate -i` and no sleep. Keep the Mac awake for future runs.
- **Exporter output:** `export-goldens` and `sync-strings` print no "ai_mode simulated" line of their own:
  - `export-goldens` enforces simulated mode through `common.enter`, which aborts otherwise.
  - `sync-strings` imports no backend code.
- **Simulator artefact:** a few AX3 and S06 shots show the simulator's Dynamic Island box. It is the simulator, not app content.
- **Not committed:** the round 2 change (`visit.tsv`) is not committed yet. `64e1525` is still labelled WIP, not approved.

## Phase 4: Native features (approved on review round 2 of 4, 8 Nov)

### Plan
Build the native table in [[iOS Brief]] on Apple's own frameworks, free and with no account, each behind a protocol with a fake so its logic is tested and the hardware part is listed honestly for the phone:
- on-device speech with a transcript confirm and a typing fallback, never server recognition
- MapKit centres with wait badges and the list fallback
- one Core Location reading on the patient's tap for "I'm here", with the door code kept
- QR scanning with the typed fallback
- a Live Activity and Dynamic Island driven locally with no push, and local notifications scheduled ahead in On this phone mode
- haptics, native sheets, swipe back, pull to refresh, keyboard handling, tel 999
- Info.plist usage strings in both languages, privacy manifests, VoiceOver in AR and EN, Dynamic Type to AX3, Reduce Motion and dark mode
- everything signs on a free Personal Team

Shot rows were added for the Phase 3 exclusions: Map selection, camera denied and the Live Activity.

### What was built
- **`ios/Dawri/Native/`:**
  - `SpeechVoiceEngine`: `Speech` with `requiresOnDeviceRecognition = true`, fed by an `AVAudioEngine` tap, with no file or recorder.
  - `CoreLocationSource`: one when-in-use reading, a 10 s timeout, and one temporary precise prompt with the `ArrivalCheck` purpose key.
  - `CameraDoorScanner` and `DoorScannerView`: `AVCaptureSession` reading QR codes only, and nothing read is opened.
  - `ActivityTicketLive`: `Activity.request` with `pushType: nil`.
  - `LocalVisitNotifier`: notices go to Notification Centre only while the app is open.
  - `LiveTicketCoordinator`: keeps the activity and the notices in step with every visit the app reads.
- **Screens:**
  - `Screens/Visit/CentreMap.swift` replaced `CentreMapSlot`: a MapKit `Map` with one `Annotation` `WaitBadge` per centre, LTR in Arabic, the camera fitted once, and `NWPathMonitor` deciding the list-only state.
  - The door sheet's camera block and the S09 imprecise-location notice.
  - Settings `settings.notifyLocal`.
- **DawriCore:**
  - `Patient/`: `VoiceAvailability`, `LocationRules` and `DoorScan`.
  - `Live/`: `LiveTicketRules`, `NotificationPlan`, `TicketLiveViews`, and `TicketLiveState.ticketState` and `centreName`.
  - Suites for each, plus `LocationGuardTests`, which keeps `CLLocationManager` inside `CoreLocationSource` and forbids `UserAnnotation`, `showsUserLocation`, `startUpdatingLocation`, `MapUserLocationButton`, `startMonitoring`, `CLMonitor` and `requestAlwaysAuthorization`.
- **The widget extension** draws the shared DawriCore views with `DSPalette` colours.
- **Plist and privacy:** `PrivacyInfo.xcprivacy` in the app and the extension. `InfoPlist.xcstrings` holds the AR and EN usage strings.
- **Phone-only keys:** six in each language: `reserved.scanHint`, `reserved.cameraLabel`, `reserved.cameraUnavailable`, `reserved.locationImprecise`, `centre.pinSelected` and `settings.notifyLocal`.
- **Debug only:** `DemoFeatures`, the `-demoCamera`, `-demoVoice device`, `-demoNotify`, `-demoLiveProbe`, `-demoOffline` and `-demoSelect` hooks, and `LiveGallery`.
- **UI tests:** `MapTests`, `ArrivalNativeTests`, `VoiceNativeTests`, `LiveActivityTests` and `NotificationTests`.
- **Shot tables:** `ios/Tools/shots/arrival.tsv` and `live.tsv`, and the S08 map rows in `visit.tsv`.
- **`ios/README.md`:** "What only a real iPhone can prove".
- **Round 1 failure and its fix:** S08's map showed the patient's dot and the location arrow whenever when-in-use was allowed, through `UserAnnotation()`. That broke the usage string's "once, only when you tap" promise. The fix removed the dot and every location read from `CentreMap.swift`, and added `LocationGuardTests`.

### Evidence (the reviewer's own runs, round 2)
Everything below is from my own runs on `build/dawri-ios`, with my own scratch and derived folders in the session scratchpad. The Mac was on AC power at 100%, every long run was wrapped in `caffeinate -i`, and `pmset -g log` shows no sleep during the runs. I started no server, never read `.env`, ran no `hf`, and sent nothing to any Hugging Face or model-provider host. The exporters ran with every socket connect blocked by `common.py`.

**Round 1 failure, re-verified**
- `CentreMap.swift` has no `UserAnnotation`, `CLLocationManager` or location read. A grep of `ios/Dawri`, `ios/DawriLive` and `DawriCore/Sources` finds `CLLocationManager` only in `Native/CoreLocationSource.swift`, and none of the seven forbidden names.
- With location granted through `simctl privacy`, a plain launch onto the S08 map shows no Location Services arrow and no patient dot. After the Use my location tap, the card shows "Distance 5 km" and there is still no dot.

**Core tests**
- `swift test --scratch-path <tmp>`: 570 tests in 86 suites passed, 0 skipped, exit 0. It includes:
  - the new suites: VoiceAvailability, LocationRules, location source guards, DoorScan, LiveTicketRules, NotificationPlan and TicketLiveState fields
  - every safety golden: red flags, conversation, refill, text, regex, parsers, read-back, clinic rules, session replay and the manifests
- The build gives 8 warnings in `TicketLiveTextTests.swift`: a main-actor initialiser called from a nonisolated context.
- A grep for `XCTSkip`, `.disabled(` and `withKnownIssue` in `DawriCore/Tests` and `DawriUITests` finds nothing.

**Strings and exporters**
- `sync-strings --check`: exit 0.
- The six new keys are in both languages, with equal key sets: 267 and 267 in DawriCore, and 35 and 35 in `Tools/strings`.
- `export-engine-data --check` and `export-goldens --check`: exit 0. They ran with `HF_TOKEN=` blank, `HF_HUB_OFFLINE=1`, `SIMULATE_LOAD=1` and a temp `DAWRI_DB`, and the engine export printed "ai_mode simulated" for rules and clinic.

**UI tests on Dawri Build**
- **Run 1**, the full Dawri scheme from a clean derived folder: 157 tests, 155 passed, in 4,129 s.
  - All of these passed: MapTests 8, ArrivalNativeTests 8, VoiceNativeTests 3, LiveActivityTests 7, NotificationTests 5, JourneyTests 7, Emergency 15, Chat 10, Visit 13, Account 23, Session 11, Back 3, SwipeHold 2, Everywhere 4, and the rest.
  - `AccessibilityAuditTests` failed in AR and EN on one row, `chat-summary`:
    - AR: contrast on "Change something", and four "potentially inaccessible text" findings with no element
    - EN: contrast on two question bubbles and "Change something"
  - The xcresult's screen recording, at the moment of the EN audit, shows those elements at rest, black text on white.
  - Earlier phases did not change this screen, and the round 1 review run passed it.
- **Rerun** of `AccessibilityAuditTests` alone: AR and EN both passed, with every row including `s08-map-selected`, `s09-door-camera-denied` and `live-gallery-active`.
- **Repeats:** the chat rows repeated four times per language with `-test-iterations 4` passed 8 of 8. No sleep or power event was logged.
- So I record this as a flake of the audit in the first minutes of a fresh run, not as a product defect. It is listed under Known gaps.
- **NotificationTests from a fresh install:**
  - With `simctl uninstall` and no reboot, three tests failed. The simulator's own log shows "Added notification request: hasError: 0" for each notice, then "Got 0 pending". The system dropped requests it had accepted, and it kept the permission as authorized across the uninstall.
  - After a simulator reboot, all 5 passed.
  - After uninstall and reboot, all 5 passed:
    - no prompt on a launch onto S10, and none on S09 before arrival
    - the system prompt at I'm here, answered Allow
    - the plan's notices pending
    - rescheduled after Demo: next step
    - none after completion
  - This was environmental, from simulator state, with log evidence. Both runs are reported.
- **LiveActivityTests from a fresh install:** 7 of 7 passed.

**Location by shell**, with `xcrun simctl location set` and permission granted:
- about 20 m from Al Wakra, `-demoArrive location` gives S10 with T-014
- about 5 km away gives "You are 5004 m from the centre, and check-in works within 150 m."
- Afterwards the location was cleared and privacy reset.

**Screenshots**
- `ios/Tools/shoot.sh` over all rows: "128 rows, 630 images", exit 0. That equals the count from the tables.
- I viewed every Phase 4 image against iOS Design section 11:
  - **s08-map:** AR light and EN dark.
  - **s08-map-selected:** all four. The selected badge is ink, not the hue: black in light, the light ink in dark.
  - **s08-map-ax3:** all four AX3.
  - **s08-map-offline:** the notice and the list only, with no picker.
  - **s09-door-camera-denied:** all four, plus AX3: the typed field only, under `reserved.cameraUnavailable`.
  - **s09-location-imprecise.**
  - **The live gallery:** active, called, serving, between, stale and ended, in AR and EN, light and dark.
  - **live-island:** the system's real compact Dynamic Island, with T-014 in the hue.
- In all of them:
  - The map stays LTR in Arabic, with Al Wakra east of Al Rayyan.
  - Arabic is right-aligned, with Latin digits.
  - The footer and AI line are present.
  - Nothing is clipped at AX3.
- **Colour scan** (top 170 px excluded, tolerance 30). The MapKit rectangle is excluded on S08 map views; it is found as the band of tile rows, for example y 646 to 1637 px.
  - No hue or saturated blue outside S10, the galleries, the Live views and the Island.
  - The map tiles' water was the only hit before the exclusion.
  - No image outside S06 is above 1% `#c4242a`.
  - Every S10 and Live state has hue, except `ended`, which by design has none.

**Info.plist, privacy and signing**
- **Info.plist:** the built `Dawri.app` has `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, `NSLocationWhenInUseUsageDescription`, `NSLocationTemporaryUsageDescriptionDictionary/ArrivalCheck`, `NSLocalNetworkUsageDescription` and `NSSupportsLiveActivities`. It has no Always-location key and no `UIBackgroundModes`.
- **Usage strings:** `ar.lproj` and `en.lproj` `InfoPlist.strings` each hold all six, non-empty. The AR and EN location text promises one reading per tap, which now holds.
- **Privacy manifests:** `PrivacyInfo.xcprivacy` is in the `.app` and the `.appex` and passes `plutil -lint`. It declares tracking false, no tracking domains, no collected data and UserDefaults `CA92.1`. A grep for other required-reason APIs finds none.
- **Entitlements:** there is no `CODE_SIGN_ENTITLEMENTS`. `codesign -d --entitlements -` shows none on the Debug and Release `.app` and `.appex`.
- **Device build:** `generic/platform=iOS` with `CODE_SIGNING_ALLOWED=NO`: BUILD SUCCEEDED.
- **Signing attempt** without `-allowProvisioningUpdates`: BUILD FAILED with "No profiles for 'com.jaber.dawri' / 'com.jaber.dawri.live' were found… pass -allowProvisioningUpdates". That is expected with no Xcode account session. No capability error appeared.
- **Release build:** the Release simulator build succeeded. `strings` on its binary and extension finds 0 of `demoScreen`, `demoCamera`, `demoVoice`, `demoLiveProbe`, `demoNotify`, `demoSelect`, `demoOffline`, `demoLocation`, `demoFreeze` and `live-probe`. The Debug dylib has them, so the search works.

**Code reading and greps**
- **Speech:** one recognition request, with `requiresOnDeviceRecognition = true`. There is no `= false`, `SFSpeechURLRecognitionRequest`, `AVAudioRecorder`, `AVAudioFile` or `URLSession` anywhere in `ios/`.
- **No restricted APIs:** no `startMonitoring`, `CLMonitor` or `requestAlwaysAuthorization`.
- **Scanner path:** no `openURL` or `UIApplication.open`.
- **Notifications:** no time-sensitive interruption level. Nothing is scheduled ahead without `DemoDriving`.
- **Hugging Face:** `hf.space` and `huggingface` appear only in the `ServerAddress` guards, their tests, a test's banned list, a shot row and the harvest plugin's banned regex.
- **Haptics:** every `DS.Haptic` event in Design 6.4 is wired.
- **Sheets:** the door sheet is `.large`, and reset uses a `confirmationDialog`.
- **Pull to refresh:** `.refreshable` on S03, S10 and S12.
- **Reduce Motion:** the new pin press goes through `DS.Motion.resolved`.
- **VoiceOver labels:** in both languages, for the pins, the scanner preview, the mic and the Live views.

**Repo and simulators**
- `git diff bb37797 -- backend frontend` is empty. Since `42e6e73`, every change is under `ios/`, apart from the S08, S09 and section 9 "As built" rows in `iOS Design.md`. `main` is still `542bc32`.
- My `xcodebuild` runs recreated an empty `ios/DawriCore/.swiftpm`, which I removed. Nothing ignored or built is under `ios/`.
- Dawri Build was left shut down, with its location cleared and its privacy reset. The owner's simulator was never named or touched.

### Known gaps and phone test items
- **Phone-only:** each is implemented and tested with fakes, and listed in `ios/README.md`. None is claimed as verified:
  - the microphone and on-device Arabic and English recognition
  - a live QR camera read
  - a real GPS geofence and the precise-location prompt (the simulator always reports full accuracy, so the imprecise notice was shown through `-demoLocation imprecise`)
  - the Lock Screen and the real Dynamic Island expanding on called
  - notification delivery while locked or suspended
  - the 999 dialer
  - haptics, VoiceOver speech order, Reduce Motion at runtime, and the iOS 18 look
- **Audit flake:** `AccessibilityAuditTests` `chat-summary` failed once in AR and EN at the start of a full run, and the Phase 4 builder saw it in EN too. The screen recording shows high-contrast text at rest, and it passed on the rerun and 8 of 8 repeats. Making that row wait until the chat's scroll has settled would remove it.
- **Notification permission on the simulator:** the permission survives `simctl uninstall` until a reboot, and requests are silently dropped in that state. Uninstall and reboot before a run that must see the prompt.
- **Test warnings:** the 8 Swift 6 isolation warnings in `TicketLiveTextTests.swift`.
- **Accepted audit exclusions,** each with its written reason:
  - MapKit's Legal link, about 29 by 11 pt
  - the Live gallery's capped Dynamic Type, two element-detection findings with no element, and the expanded Island centre name, which is scaled to fit
- **Precise-location prompt on S08:** S08's Use my location also asks once for precise location, and its purpose text names the 150 m arrival check.
- **Clinic server mode** posts notices only for changes seen while the app runs, as Settings says. The server probe is still `NoServerProbe` until Phase 5.
- **Not committed:** Phase 4 is in the working tree, uncommitted, at the time of this review.
