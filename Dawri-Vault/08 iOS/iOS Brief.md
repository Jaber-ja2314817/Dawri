---
tags: [ios, build, decisions, authority]
updated: 2026-11-07
---

# iOS Brief (the authority for the phone app)

The hackathon has ended. The team wants to keep going with Dawri. This note specifies a **native iPhone app for the patient side**, built in Xcode. The hospital side (nurse, doctor, pharmacy, front desk, display, dashboard) stays on the website and is not rebuilt.

Where this note disagrees with an older note, this note wins for the iOS app. Everything else stands: [[Build Decisions]], [[Risks & Red Lines]], the hard rules in [[01 Enhanced Prompt]], [[Screens]], [[Patient Journey]], [[Safety Guardrails]]. Where a vault note and the working code disagree on behaviour, the working code (`backend/`, `frontend/src/pages/patient/`) wins, because it passed every phase review. Progress goes in [[iOS Build Log]].

## The owner's instructions, word for word in effect
1. Build it as a native app in Xcode.
2. **Do not use anything from the Hugging Face account. No API usage.** The credits on `xTamim` must not be touched.
3. The owner tests on their own iPhone after the whole build, as with Daily Edition. No per-phase phone tests.
4. Same workflow as the Dawri build: vault-driven orchestrator, phases, independent review, commit and push.

## No-credit rules (absolute, for every agent, no exceptions)
- Never read, print, copy or source `.env`. Never read a token from anywhere.
- Never send any request to `*.hf.space`, `huggingface.co`, `*.huggingface.co` or any model provider. Not even a health check. Never run `hf` or `huggingface-cli`. Never redeploy the Space.
- The only allowed way to start the backend, with a free port above 8100 and a temp database:
  `HF_TOKEN= SIMULATE_LOAD=1 DAWRI_DB=<temp> .venv/bin/python -m uvicorn backend.main:app --host 127.0.0.1 --port <port>`
  Blank `HF_TOKEN=` must be present. It was tested: it wins over the token in `.env` and `/api/health` reports `ai_mode: simulated`. Check that value before using a server, and stop if it says `real`.
- Any Python that imports `backend.*` runs with `HF_TOKEN=` blank too.
- Never touch `main`, the Space, or real patient data. Synthetic data only.

## Architecture
A SwiftUI app with two interchangeable back ends behind one protocol.

| Mode | What it is | Default |
| --- | --- | --- |
| **On this phone** | `LocalClinicService`: a Swift port of the scripted receptionist, emergency rules, refill route, queue and visit flow, plus seeded synthetic patients and centres. Needs no network, no server, no Mac and no account | Yes. The app must work from the first launch on a phone with nothing else running |
| **Clinic server** | `RemoteClinicService`: the existing REST and SSE API from `frontend/src/api/`, against a Dawri backend on the owner's Mac in simulated mode, over the local network. The real web staff consoles then drive the patient's ticket live | Optional, chosen in Settings |

Both implement one `ClinicService` protocol that mirrors `frontend/src/api/endpoints.ts`. Screens only know the protocol. One shared contract test suite runs against both.

**Guards in Clinic server mode, which are the product's guarantee that this app cannot spend credits:**
- The server field refuses any host ending in `hf.space` or `huggingface.co`, with a plain message.
- Before connecting, the app reads `/api/health` and refuses any server whose `ai_mode` is not `simulated`, with a plain message. Both guards are tested.
- Only `http` on local addresses and `https` are allowed. Use `NSAllowsLocalNetworking`, never a blanket ATS exception. Include `NSLocalNetworkUsageDescription`.
- The app never calls `/api/asr`. Voice is always transcribed on the phone.

The app has no model and calls no model. No LLM, on-device or remote. The receptionist on the phone is the scripted one, so the reply gate in `filters.py` has nothing to gate and is not ported. **Honest labelling stands:** the patient footer shows "AI: simulated" as on the web, and nothing claims live AI.

## Project layout and conventions
Copy the shape of `/Users/jaberal-boenain/Desktop/news_app` (read-only reference, never edit it): one xcconfig, one local package, synchronized folders, no third-party dependencies.

```
ios/
  Dawri.xcodeproj          objectVersion 77, PBXFileSystemSynchronizedRootGroup for every target
  Config/Shared.xcconfig   DEVELOPMENT_TEAM = 4Y4YQ65B78, BUNDLE_ID_PREFIX = com.jaber.dawri
  Dawri/                   App target: SwiftUI screens, design system, platform features
  DawriLive/               Widget extension for the Live Activity, bundle id $(BUNDLE_ID_PREFIX).live
  DawriCore/               Local Swift package: models, ClinicService, engine, remote client, strings
    Sources/ Tests/
  DawriUITests/            XCUITest
  Tools/                   Golden export and asset scripts
```

- Swift 6 language mode, SwiftUI, iOS 18.0 deployment target, iPhone only, portrait. Xcode 27.2. No third-party packages, no CocoaPods, no XcodeGen.
- The owner has a **free Personal Team**. So: no App Groups, no push notifications, no capabilities that need the paid program. `CODE_SIGN_STYLE = Automatic`. Add no entitlement a free team cannot sign.
- All logic that needs no UIKit lives in `DawriCore` and builds for macOS too, so `swift test` runs it in seconds without a simulator. Package platforms `.iOS(.v18), .macOS(.v15)`.
- Because folders are synchronized, adding a Swift file does not touch `project.pbxproj`. Only the Foundation phase edits that file unless a task owns it.

## Parallel build rules
- `swift test` always takes `--scratch-path <own folder in the scratchpad or a temp dir>`. `xcodebuild` always takes `-derivedDataPath <own folder>`. Never share them between agents. Never write build output into `ios/`.
- Only one agent in a wave may use the simulator. The orchestrator names it in the brief. The device is **"Dawri Build"**, UDID `B55FEAC2-08EB-460D-9261-E28A60F4B5CC`, an iPhone Air on iOS 26.5, matching the owner's phone. Never use or shut down the owner's booted "iPhone 17" simulator. Never touch the physical iPhone.
- DEBUG-only launch arguments reach any screen in any state, so screenshots need no tapping: `-demoScreen <id> -demoLang ar|en -demoPatient <qid>` and similar. They compile out of Release.

## Scope
**Patient screens S01 to S12**, every state from [[Screens]], matching what `frontend/src/pages/patient/` does today: welcome and language, login with QID and OTP `0000` and quick-pick chips, home, who-is-this-for with dependents, consent, chat, emergency, refill, centre selection, reserved with the 45-minute check-in countdown, live ticket, visit complete with rating, history, plus a Settings screen for language, mode and server.

**Three demo patients must behave exactly as in [[HANDOFF]]:** Fatima (normal visit, ticket, medicines in plain language), Ahmed (refill route, no ticket), Ravi (emergency, 999, no ticket), in Arabic and English.

**Out of scope:** staff screens, any model, Android, iPad layouts, backend features, changes to the website. Backend code changes only if Clinic server mode cannot work without them, and then the smallest possible, with its tests still green. The app store, TestFlight and paid-program work are out of scope.

## The Swift port is safety-critical
The emergency rules are the core promise. A hand-retyped port would drift silently.

- **Data is exported, not retyped.** Rule cue lists, normalisation tables and seeds are generated from the Python source by a script in `ios/Tools/` into JSON resources in `DawriCore`. A later clinician edit to `redflags.py` flows through a rerun.
- **Goldens prove the port.** A Python export runs the real backend functions, with `HF_TOKEN=` blank and no network, over a corpus built from `backend/tests/`, the vault's acceptance sentences, and generated variants, in Arabic and English, recording the expected decision for each input. The Swift tests must reproduce **every** decision. No skipped case passes review. Python `re` and Swift regex treat Arabic and word boundaries differently, so the goldens must cover diacritics, tatweel, letter variants, negation windows and clause breaks.
- **Conversation goldens.** Whole scripted chats run through the backend's simulated path, and the Swift receptionist must give the same next question, the same stage changes and the same intake.
- Every message passes the rules before anything else. A rule hit stops the chat and gives no ticket. The override path logs and still gives no ticket. The red-flag list stays labelled as not clinically reviewed.

## Wording rules that carry over
Never say "place held". Use "Check-in valid for 45 minutes". A reserved ticket has no number and no place. No no-show claims. Never claim the rules are clinically reviewed or that this connects to PHCC or HMC. The footer "Demo — synthetic data, not connected to PHCC/HMC systems." appears on every patient screen in AR and EN. Reuse the web's text: bundle `frontend/src/i18n/*.json` patient files as the source of strings through a sync script, and a test fails if keys drift. Add new keys only for phone-only screens, in both languages. Language switches inside the app at any time, and Arabic is full RTL.

## What makes it feel like a phone app
These are the point of the rewrite. Each must use Apple's own frameworks, cost nothing and need no account.

| Native piece | Replaces | Notes |
| --- | --- | --- |
| On-device speech (`Speech`, `requiresOnDeviceRecognition`) | Whisper upload | Arabic and English, transcript confirmed before sending, audio never stored or sent anywhere. If on-device recognition is unavailable, say so and offer typing. Never fall back to server recognition |
| MapKit | Leaflet | Pins with wait badges, list fallback. No API key |
| Core Location | Browser geolocation | "I'm here" geofence, with the door code as today |
| QR scan (`AVFoundation`) | Door code entry | Typed code stays as the fallback |
| **Live Activity and Dynamic Island** (ActivityKit) | Keeping the tab open | The ticket number, stage, people ahead and estimated wait on the Lock Screen. Local updates only, no push |
| Local notifications | None | "You are next", stage changes. In On this phone mode the steps are known ahead of time, so they are scheduled ahead. Clinic server mode has no push, so updates arrive only while the app runs. State that limit |
| Haptics, native sheets, swipe back, pull to refresh, keyboard handling | Web equivalents | Follow the `anthropic-skills:apple-design` skill |
| One-tap `tel://999` | Web link | Must work from the emergency screen, and be reachable with VoiceOver |
| Accessibility | | VoiceOver labels in both languages, Dynamic Type to AX3 without clipped text, 44 pt targets, Reduce Motion, light and dark |

**Demo clinic, On this phone mode only:** with no staff behind the ticket, a `DemoClinic` driver moves triage, doctor, pharmacy and done on a short timer and from a clearly labelled "Demo: next step" control. It is never presented as real staff. Its demo prescription must pass the same allergy rule as the real flow, so Fatima never receives a penicillin in a demo.

## Design direction
Same identity as the web, rebuilt for iOS: **Achromatic ledger** from [[Build Decisions]]. Ink and neutrals, near-black primary, the ground `#f2f4f7`, white cards, and the one hue `#1d5fbf` only on the patient's own number and current stage. Full red only on the emergency screen. No emoji, gradients, violet or indigo.

The web's flat look is a starting point, not a rule against the platform. Use system text (SF Pro and SF Arabic) through Dynamic Type styles, native navigation and sheets, tabular figures, and iOS spring motion. Add a proper dark palette. As on Daily Edition, one design pass agrees a spec between taste (`anthropic-skills:design-taste-frontend`: palette, type, layout) and Apple behaviour (`anthropic-skills:apple-design`: motion, interaction, accessibility) in `Dawri-Vault/08 iOS/iOS Design.md`, and builders follow it. Screens are judged from simulator screenshots in Arabic and English, not from code.

## Definition of done
- `swift test` in `DawriCore` and `xcodebuild test` on "Dawri Build" are green, and every safety golden passes.
- XCUITests walk Fatima, Ahmed and Ravi in AR and EN in On this phone mode.
- In Clinic server mode, against a local simulated backend, a patient on the simulator gets a ticket, and that ticket moves from staff API calls with the app updating live.
- A device build signs and compiles with `generic/platform=iOS`, using team `4Y4YQ65B78`. Agents never install it. The owner's session does that.
- A log proves no request left for any Hugging Face host, for example by the guards' tests and a search of the code for those hosts.
- `ios/README.md` covers open in Xcode, run on an iPhone with a free team, starting the local server for Clinic server mode, and an honest list of what only a real phone can prove (microphone, on-device Arabic speech, geofence, QR camera, Live Activity on the real Dynamic Island, the 999 dialer, haptics).
