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
