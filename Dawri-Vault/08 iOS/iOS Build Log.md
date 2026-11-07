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
