# Dawri for iPhone

The patient side of Dawri as a native SwiftUI app. It runs the scripted receptionist, the
emergency rules, the refill route and the demo clinic on the phone itself, with no server, no
model and no account. The authority for what it does is `Dawri-Vault/08 iOS/iOS Brief.md`, and
for how it looks and behaves, `Dawri-Vault/08 iOS/iOS Design.md`.

The app has two modes, chosen in Settings:

| Mode | What it is |
| --- | --- |
| **On this phone** (the default) | `LocalClinicService`: the scripted receptionist, the emergency rules, the refill route, the queue and a labelled demo clinic, all in Swift on the phone. It needs no network, no server, no Mac and no account, from the first launch |
| **Clinic server** (optional) | `RemoteClinicService`: the same REST and event-stream API the web app uses, against a Dawri backend on your Mac in simulated mode, over the local network. The real web staff consoles then move the patient's ticket live |

The hospital side (nurse, doctor, pharmacy, front desk, display, dashboard) stays on the website.
Everything in the app is synthetic demo data, and it is not connected to PHCC or HMC systems.

All commands below run from the repository root.

## Open in Xcode

- Xcode 27.2. The deployment target is iOS 18.0, iPhone only, portrait, Swift 6 language mode.
- Open `ios/Dawri.xcodeproj` and choose the **Dawri** scheme.
- There are no packages to resolve. The project has no third-party dependencies, no CocoaPods and
  no XcodeGen. Its one package is `DawriCore` in `ios/DawriCore`, a local Swift package that holds
  the models, the engine, the remote client and the strings, and builds for macOS too.
- The targets are `Dawri` (the app), `DawriLiveExtension` (the Live Activity, from
  `ios/DawriLive`) and `DawriUITests`. Their folders are synchronized, so adding a Swift file does
  not change `project.pbxproj`.
- Signing settings live in one file, `ios/Config/Shared.xcconfig`, which the project applies to
  every target.

## Run on an iPhone with a free Personal Team

The app is built for a free Personal Team. It asks for no capability that needs the paid Apple
Developer Program.

1. **Add your Apple ID to Xcode.** Xcode > Settings > Accounts, then + and Apple ID. Your free
   team then shows as "<your name> (Personal Team)".
2. **Set the team and the bundle prefix** in `ios/Config/Shared.xcconfig`:

   ```
   DEVELOPMENT_TEAM = 4Y4YQ65B78
   BUNDLE_ID_PREFIX = com.jaber.dawri
   ```

   These are the owner's. With another Apple ID, change both:
   - `DEVELOPMENT_TEAM` to your own team ID. Xcode shows it in Settings > Accounts when you
     select the team, and in the Signing & Capabilities tab once a target uses the team.
   - `BUNDLE_ID_PREFIX` to something only you use, such as `com.<yourname>.dawri`. A bundle ID
     belongs to the first team that registers it, so another team cannot sign
     `com.jaber.dawri`. The extension becomes `<prefix>.live` and the UI tests
     `<prefix>.uitests` on their own.

   Leave `CODE_SIGN_STYLE = Automatic`, which every target already uses.
3. **Connect the iPhone** by cable, unlock it and tap Trust on the phone. Choose it as the run
   destination in Xcode.
4. **Turn on Developer Mode** on the phone: Settings > Privacy & Security > Developer Mode, then
   restart the phone and confirm. The switch appears only after the phone has been connected
   to Xcode once.
5. **Run** (Command-R). Xcode registers the phone with your team and makes the provisioning
   profiles for the app and the extension itself.
6. **Trust the developer** the first time: on the phone, Settings > General > VPN & Device
   Management, choose your Apple ID under Developer App, and tap Trust. Then open Dawri.

Limits of a free team:
- **Profiles expire after 7 days.** After that the app will not open. Connect the phone and Run
  from Xcode again to renew it. The signed device build of 13 Nov 2026 still carried the
  profiles Xcode made on 9 Nov 2026 at 00:06 Doha time, which expire on 16 Nov 2026 at 00:06. A
  phone test after that needs one Run from Xcode first, which makes new ones.
- **Three apps at most.** A free team can have only 3 of its apps installed on a device at the
  same time. Dawri counts as one, with its Live Activity extension inside it. Free teams can
  also register only a few new App IDs a week, which matters only when you change
  `BUNDLE_ID_PREFIX` often.

Why the app asks for nothing more:
- **No App Groups, no push notifications, no iCloud, no Associated Domains**, and no other
  capability a free team cannot sign. The project sets no `CODE_SIGN_ENTITLEMENTS`. The signed
  app and extension carry only the three entitlements Xcode always adds:
  `application-identifier`, `com.apple.developer.team-identifier` and `get-task-allow`.
- **The Live Activity works on a free team.** It is started and updated by the app with
  `pushType: nil`, so it needs no push entitlement, only `NSSupportsLiveActivities` in the
  Info.plist. The extension reads nothing shared with the app, so it needs no App Group.
- **Local notifications work on a free team.** They are scheduled on the phone and need no
  entitlement. In On this phone mode the demo clinic's steps are known ahead, so the notices are
  scheduled ahead. In Clinic server mode there is no push, so a notice is posted only for a
  change the app sees while it runs.
- Location is when-in-use only, read once per tap. There is no background mode.

## Tests

**Core tests, in seconds, with no simulator:**

```bash
swift test --package-path ios/DawriCore --scratch-path <a folder outside ios/>
```

They hold every safety golden (red flags, conversations, refill, text, regex, parsers, read-back,
clinic rules and the session replay), the drift checks against the Python exports, both
Clinic server guards, and the shared `ClinicContract` suite run against the on-this-phone
service. On 13 Nov 2026, from an empty scratch folder: "Test run with 627 tests in 93 suites
passed after 23.248 seconds", with 0 skipped, 0 failed and 0 compiler warnings (no `warning:` line
in the build log).
That includes every safety golden suite by name: red flag goldens (single messages),
conversation goldens, the refill golden, text, regex, parser and read-back goldens, the
`next_turn` golden, the session replay, the clinic rule goldens, the queue traces and the golden
manifests. A grep for `XCTSkip`, `.disabled(` and `withKnownIssue` in `DawriCore/Tests` and
`DawriUITests` finds nothing.

**UI tests on a simulator:**

```bash
xcodebuild test -project ios/Dawri.xcodeproj -scheme Dawri \
  -destination 'platform=iOS Simulator,name=Dawri Build' \
  -derivedDataPath <a folder outside ios/>
```

- The tests and screenshots were checked on an iPhone Air simulator on iOS 26.5 called
  "Dawri Build". Put your own simulator's name in `-destination`.
- The **Dawri** scheme walks Fatima, Ahmed and Ravi in Arabic and English in On this phone mode,
  every screen and state, the native features with fakes, and an accessibility audit of every
  screen in both languages. It needs no server and no network.
- Before a run that must see the notification permission prompt, uninstall the app and reboot
  the simulator. Until it reboots, the simulator keeps the permission across an uninstall,
  and in that state it accepts scheduled requests and then drops them. Wait about 15 s after
  `xcrun simctl uninstall` before shutting the simulator down, and check with
  `xcrun simctl listapps` after the boot: an uninstall followed at once by a shutdown came back
  installed after the reboot.
- Keep the Mac awake and on power during a full run, for example with `caffeinate -i`. A sleep
  during a run fails UI tests with "Timed out while synthesizing event".
- The **DawriServer** scheme runs only `ServerModeTests`, which need a local simulated server. The
  Dawri scheme never runs them: its test action lists `ServerModeTests` under skipped tests, and
  DawriServer's selects only that class. The tests find the server through the `DAWRI_SERVER`
  environment variable, which `ios/Tools/server-proof.sh` hands to the test runner as
  `TEST_RUNNER_DAWRI_SERVER=<url>`. When it is missing, or is anything but
  `http://127.0.0.1:8101` to `8199`, every test fails with the reason. None is ever skipped. Run
  them through `server-proof.sh`, below, which starts and stops the server for you.
- On 13 Nov 2026, after uninstalling the app (and the test runner), waiting 15 s and rebooting
  Dawri Build, with `simctl listapps` showing no Dawri app, the Dawri scheme from an empty
  derived folder ran **163 UI tests in 22 classes in 4,739 s** (about 79 minutes), on AC power
  under `caffeinate -i`, with no sleep or wake in `pmset -g log` (the last was at 01:24 that
  morning). 161 passed on the first run. Per class: AccessibilityAuditTests 2,
  AccountScreenTests 28, ArrivalNativeTests 8, BackTests 3, ChatScreenTests 11,
  EmergencyScreenTests 15, EngineOnDeviceTests 5, EverywhereTests 4, FoundationHookTests 14,
  JourneyTests 7, LanguageTests 6, LiveActivityTests 7, MapTests 8, NotificationTests 5,
  ScreenTests 2, SessionTests 11, SmokeTests 1, StageTableTests 3, SwipeHoldTests 2,
  VisitScreenTests 13, VoiceNativeTests 3, WelcomeTests 5. `ServerModeTests` was compiled but
  not run.
- Two tests failed in that run, both inside Xcode's test machinery, not in the app, and both
  passed on the rerun:
  - `AccessibilityAuditTests.testEveryScreenInEnglish`: on `s09-reserved` XCTest's audit gave
    up with "Audit failed to complete in time" (code -56) after 155 s. The simulator's log shows
    the app idle and asked nothing from 18:59:52 to 19:02:20, while testmanagerd ran the audit
    after its element-vision asset query. `Audit.swift` now runs an audit call once more when,
    and only when, XCTest's audit service times out, with a line in the log; findings never
    throw, so none can be retried away.
  - `EverywhereTests.testEveryScreenFromEnglish`, on S02: the synthesized tap on the language
    toggle drew its pressed state, but backboardd logged "didn't see a previous touch down or
    range-in event for pathIndex:2; skipping event" seven times for it, so the touch never
    ended in the app. No other tap in that test logged it.
- The rerun, after another uninstall and reboot: `AccessibilityAuditTests` passed 2 of 2 on the
  first try (968 s, all 84 rows settled, the new retry never used), and
  `EverywhereTests.testEveryScreenFromEnglish` passed (370 s).
- The screenshot review then found one real fault: at AX3 the empty server address field cut its
  sample, `http://192.168.1.20:8100`, to "http://192.168.1.2…", because a field's own prompt keeps
  to one line. `DSTextField` now draws the sample as wrapping text behind the empty field at
  accessibility sizes, and a tap anywhere on the box focuses the field.
  `AccountScreenTests.testAtAX3TheEmptyAddressFieldWrapsItsSampleAndStillTypes` checks it in both
  languages and failed on the old code (the empty field stood 53 pt, no taller than with one
  letter). The Dawri scheme now holds 164 UI tests. After the fix `AccountScreenTests` (29),
  `ChatScreenTests` (11) and `AccessibilityAuditTests` (2) ran again: 42 of 42 passed, with no
  audit retry. `ChatScreenTests.testATextSizeChangeKeepsYesAndChangeAboveTheComposer` likewise
  failed with the chat's old scroll key ("chat-summary-change is covered after the size change"
  in Arabic) and passes with the text size in it.
- The accessibility audit of the five chat rows, repeated with `-test-iterations 5` and
  `TEST_RUNNER_AUDIT_ONLY=chat-opening,chat-summary,chat-error-retry,chat-listening,chat-transcript-confirm`,
  passed 10 of 10, 50 row audits, with no retry.

**Screenshots** for review, every row in `ios/Tools/shots/*.tsv`, in Arabic and English, light and
dark, and at AX3 where a row asks:

```bash
ios/Tools/shoot.sh <outdir>
ios/Tools/shoot.sh --only 's10*' <outdir>
```

It uses only the Dawri Build simulator and leaves it as it found it. Before the first row it
launches the app once and throws that launch away, because the first launch after a boot or an
install is cold and once drew S01 in place of the first row's Settings screen.

Each row gives 4 images (Arabic and English, light and dark), 8 with `ax3`, and an `island` row
gives 2 (light only). On 13 Nov 2026 the full run printed "Done: 132 rows, 650 images", exactly
the tables' count: 100 plain rows at 4, 31 AX3 rows at 8 and 1 Island row at 2, in about 43
minutes. Every Settings row (on this phone, reset confirm, server, connecting, connected,
refused host, refused mode, unreachable, refused address, in use after a relaunch, in use and
refused, back on the phone) was viewed in both languages and themes, with the AX3 rows,
against iOS Design section 11; the first image, `settings-local-ar-light`, shows Settings. That
review found the AX3 address sample cut short, described above; after the fix
`shoot.sh --only 'settings*'` gave "12 rows, 56 images", with the sample wrapped in full.
The colour scan of all 650 (the top 170 px left out, each channel within 30) finds the hue
`#1d5fbf` or its dark form `#689ce8` only on S10, the Live views, the galleries, and MapKit's own
water label inside the S08 map; it finds `#c4242a` above 1% of an image only on S06 (68 of 68),
on the S06 rows of the Live switch and in a component gallery.

**The no-credit search:**

```bash
ios/Tools/no-credit-check.sh
```

It reads files only. It prints every line in the app's folders that names a Hugging Face host,
a model provider or the server's speech upload path, with its verdict, and exits 1 if any is
outside its allowlist: the refusal guards, their tests and the banned lists. Foundation's network
session type may appear only in the Clinic server client. The DawriCore suite
`NoCreditSourceTests` runs the same search with the same allowlist.

**Strings and exported engine data** stay in step with the web app and the Python source:

```bash
python3 ios/Tools/sync-strings.py --check
HF_TOKEN= HF_HUB_OFFLINE=1 SIMULATE_LOAD=1 DAWRI_DB=<temp file outside the repo> \
  PYTHONDONTWRITEBYTECODE=1 .venv/bin/python ios/Tools/export-engine-data.py --check
HF_TOKEN= HF_HUB_OFFLINE=1 SIMULATE_LOAD=1 DAWRI_DB=<temp file outside the repo> \
  PYTHONDONTWRITEBYTECODE=1 .venv/bin/python ios/Tools/export-goldens.py --check
```

The exporters import the backend, so they run with `HF_TOKEN=` blank, and they stop unless the
backend reports simulated mode. On 13 Nov 2026 all three exited 0: "sync-strings: up to date"
(38 phone-only keys in each language in `ios/Tools/strings`, 270 and 270 in DawriCore, with equal
key sets), and the engine export printed "ai_mode simulated" for the rules and the clinic.

## Clinic server mode

This is optional. On this phone mode needs none of it.

### Start the local server, in simulated mode only

The Dawri backend must run with `HF_TOKEN=` set to blank. The backend loads `.env` without
overriding what is already set, so the blank value wins over any token there, and the server
runs in simulated mode: the scripted receptionist, no model, no credits. Never start it without
`HF_TOKEN=`.

The script does the steps below for you, on `127.0.0.1` with a free port from 8101 to 8199 and a
temp database. It checks `/api/health` before anything uses the server, and if that does not say
`ai_mode` simulated it stops the server at once and exits 3:

```bash
ios/Tools/clinic-server.sh start                # prints "ai_mode simulated <url>"
ios/Tools/clinic-server.sh status
ios/Tools/clinic-server.sh contract <scratch>   # start, run ClinicContract against it, stop
ios/Tools/clinic-server.sh stop
```

`contract` runs the shared `ClinicContract` suite through
`swift test --scratch-path <scratch> --no-parallel --filter ClinicContract` against the live
server, then stops the server whatever happened. It reads `/api/health` once more just before
the suite. The server's address and its temp database reach the suite as
`DAWRI_CONTRACT_SERVER` and `DAWRI_CONTRACT_DB`, and a plain `swift test` without them runs the
on-this-phone harness only. The script keeps its state (`url=`, `pid=`, `db=`, `dir=`) in
`$DAWRI_SERVER_STATE`, by default `$TMPDIR/dawri-clinic-server.state`, and the server's log is
`server.log` in that `dir`. `stop` kills only that pid, and only if it is this uvicorn.

Checked on 13 Nov 2026: `contract` printed
`health http://127.0.0.1:8101/api/health: {"status":"ok","ai_mode":"simulated","simulate_load":true}`
and `ai_mode simulated http://127.0.0.1:8101`, then "Test run with 32 tests in 1 suite passed
after 2.362 seconds": 35 cases for the on-this-phone harness and 35 for the clinic server, with
the same tests on each, then "clinic-server: stopped pid 89085". The server's log held 474
requests, all from 127.0.0.1, none to the speech path. `pgrep -fl uvicorn` was empty afterwards.

The same by hand, from the repository root, with a free port above 8100 and a new temp
database:

```bash
HF_TOKEN= HF_HUB_OFFLINE=1 DEMO_PASSCODE= SIMULATE_LOAD=1 DAWRI_DB="$(mktemp -d)/dawri.db" \
  .venv/bin/python -m uvicorn backend.main:app --host 127.0.0.1 --port 8101
```

The `.venv` comes from `python3 -m venv .venv` and `.venv/bin/pip install -r requirements.txt`.

**Then check health before anything uses the server:**

```bash
curl -s http://127.0.0.1:8101/api/health
```

It must say `"ai_mode":"simulated"`. If it says `real`, stop the server at once. The app checks
the same thing itself and refuses any server whose `ai_mode` is not `simulated`.

### The web staff consoles

The staff consoles are served by the same backend at `http://<host>:<port>/staff`. They need the
web app built first, because `backend/spa.py` serves `frontend/dist` (or `backend/static` when
that exists) and answers `frontend_not_built` otherwise:

```bash
cd frontend && npm ci && npm run build && cd ..
```

Log in on `/staff/login` as a nurse, doctor or pharmacist (staff login has no password in the
demo). Calling, serving, the nurse handoff, the doctor and the pharmacy steps then move the
patient's ticket on the phone live, through the event stream, with polling as the fallback.
Updates arrive only while the app runs. There is no push, so a closed or suspended app hears
nothing until it runs again, and posts no notice or Live Activity change in the meantime.

### From the simulator

Run the server on `127.0.0.1` as above. In the app, open Settings, choose **Clinic server**, type
`http://127.0.0.1:8101` and tap **Connect**. The pill reads "Connected, simulated mode", and the
app then uses the server until you choose **On this phone** again, which switches back at once.
Connect leaves you on Settings, signed out of the server: the two modes never share a session,
so sign in again from the start screen.
Reset and Demo: next step are hidden in Clinic server mode, because real staff move the ticket.
The server-proof screenshots show exactly this: Settings with the green "Connected, simulated
mode" pill, the line "The app is using this clinic server:" with the address, the notice that
updates arrive only while the app runs, and no Reset; S10 has no Demo: next step. After a
relaunch the app is still on the server and still signed in, and On this phone brings Reset
back at once.

The automated live proof is:

```bash
ios/Tools/server-proof.sh <outdir>
```

It starts a simulated server, signs Fatima in on Dawri Build in Clinic server mode, moves her
ticket with staff API calls through called, serving, the doctor, the pharmacy and complete, and
checks that each change shows on the phone without a refresh. It runs the **DawriServer**
scheme, which holds only `ServerModeTests`, four tests:

- `testFatimaInEnglishThroughEveryStaffStep`: Settings, Connect, Fatima's chip, the chat to the
  read-back, Al Wakra, I'm here, S10 with T-014, then staff calls: nurse call-next (called),
  vitals (with the team), the handoff (D-GP-023 at the doctor), the doctor's call-next, consult
  done (P-031 at the pharmacy), the pharmacist's call-next and dispensed (S11, with paracetamol
  and dextromethorphan and no penicillin).
- `testFatimaInArabicThroughTheDoctor`: the same in Arabic, launched in Clinic server mode,
  through called, serving, D-GP-023 and the doctor's call.
- `testWithTheStreamDownAStaffMoveArrivesByPolling`: the event stream forced down; S10 shows
  "Updates may be slower. Last updated …", and the nurse's call still arrives by polling.
- `testARelaunchStaysOnTheServerUntilOnThisPhone`: with no launch hook, Connect, sign in,
  relaunch (still on the server, signed in from the Keychain), then On this phone.

Run on 13 Nov 2026 on Dawri Build: `server-proof: PASSED`, 4 of 4 tests (relaunch 41.4 s,
Arabic 74.5 s, English 88.1 s, polling 61.8 s). Every staff move showed on screen between 0.14 s
and 0.33 s after the staff call returned, with no pull to refresh, no relaunch and no tap (the
limit is 10 s):

| Run | Staff call | Seen after |
| --- | --- | --- |
| English | nurse call-next (called) | 0.25 s |
| English | vitals (with the team) | 0.26 s |
| English | handoff confirm (D-GP-023 at the doctor) | 0.15 s |
| English | doctor call-next | 0.33 s |
| English | consult done (P-031 at the pharmacy) | 0.14 s |
| English | pharmacist call-next | 0.32 s |
| English | dispensed (S11) | 0.23 s |
| Arabic | nurse call-next, vitals, handoff confirm, doctor call-next | 0.24 s, 0.24 s, 0.14 s, 0.33 s |
| Stream down | nurse call-next, by polling, under "Updates may be slower" | 0.47 s |

How soon a polled change shows depends on where the call lands between two polls, so that last
figure varies from run to run. The server log held 187 requests, all from 127.0.0.1, none to the
speech path and none answered 401; after the polling run's reset it holds no stream request.
The run's 284 s `server-proof.mov` shows the same screens.

A second run the same evening, on the final code after the AX3 address fix, also printed
`server-proof: PASSED`, 4 of 4: every stream move showed in 0.16 s to 0.34 s, the polled one in
4.32 s with the slow line, and its log held 194 requests, all from 127.0.0.1, none to the speech
path, none answered 401, and no stream request after the polling run's reset.

What `<outdir>` holds afterwards:

| Path | What it is |
| --- | --- |
| `clinic-server-start.txt` | The health reply and the `ai_mode simulated <url>` line |
| `ServerProof.xcresult` | The test result, with its screenshots and timings |
| `attachments/` | Every screenshot by stage, such as `en-11-s10-doctor-D-GP-023.png` or `ar-09-s10-called.png`, the `timings-*.txt` files and `manifest.json` |
| `attachments.txt` | The list of those files |
| `timings.txt` | One `SERVER-PROOF` line per staff move: the time the call returned, the time the change was seen, and the seconds between |
| `server-proof.mov` | The simulator's screen for the whole run |
| `server.log` | The server's own log |
| `server-log-check.txt` | The count of requests, those not from 127.0.0.1, those to the speech path and those answered 401, then each 401 line. The run passes only when the last three are 0. A 401 is a request the app should not have sent, such as a visit read while signed out |
| `xcodebuild.log`, `recorder.log` | The full build and test output, and the recorder's |
| `.clinic-server.state` | The server's `url=`, `pid=`, `db=` and `dir=` while it runs; removed when it stops |

The attachments are named `<run>-<step>-<screen>.png`, where the run is `en`, `ar`, `en-polling`
or `relaunch`: 41 screenshots in all on 13 Nov 2026. English has 15, from
`en-01-settings-typed.png` to `en-15-s11-complete.png`; Arabic 11, from
`ar-02-settings-in-use.png` to `ar-12-s10-doctor-called.png`; the polling run 8, ending with
`en-polling-09-s10-slow.png` and `en-polling-10-s10-called-by-polling.png`; and the relaunch 7,
from `relaunch-01-settings-typed.png` to `relaunch-07-back-on-the-phone.png`.

### From a real iPhone over Wi-Fi

This is the owner's own run, not something the build agents do. A phone cannot reach
`127.0.0.1` on the Mac, so the server must listen on the Mac's Wi-Fi address:

```bash
HF_TOKEN= HF_HUB_OFFLINE=1 DEMO_PASSCODE= SIMULATE_LOAD=1 DAWRI_DB="$(mktemp -d)/dawri.db" \
  .venv/bin/python -m uvicorn backend.main:app --host 0.0.0.0 --port 8101
```

- **Only on a trusted network.** With `--host 0.0.0.0` anyone on that network can open the synthetic
  demo data and the staff consoles, which have no password, and with `DEMO_PASSCODE=` blank they
  can also reset the demo. Stop the server when you are done.
- Check `/api/health` says `simulated` first, as above.
- In the app's Settings, enter `http://<Mac name>.local:8101` or the Mac's LAN address, such as
  `http://192.168.1.20:8101`. `scutil --get LocalHostName` prints the name, and
  `ipconfig getifaddr en0` the address.
- The first Connect shows the system's **local network** prompt ("Dawri connects to a clinic server
  on your local network only if you choose Clinic server in Settings."). Allow it. If it was
  refused, turn it on in Settings > Privacy & Security > Local Network.
- macOS may ask whether Python may accept incoming connections. Allow it, or the phone cannot
  connect.
- A guest or public Wi-Fi network that isolates devices from each other blocks this. Use a home
  network or the Mac's own hotspot.
- The phone and the web consoles on the Mac (`http://127.0.0.1:8101/staff`, or the same LAN
  address from another device) share the one server.

## The guarantees: no model, no credits

This section is a banned list: it names the refused hosts and path on purpose.

The app has no model and calls no model, on the phone or anywhere else. The receptionist is the
scripted one, voice is turned into text on the phone with `requiresOnDeviceRecognition`, and the
footer says "AI: simulated" on every patient screen.

- **No `/api/asr`.** The app never calls the server's speech endpoint, and has no method that
  could. Voice never leaves the phone.
- **Guard 1, no Hugging Face host.** `ServerAddress` (`DawriCore/Sources/DawriCore/Patient/`)
  reads what was typed before any request exists. It refuses any host ending in `hf.space` or
  `hf.co`, or naming `huggingface`, in any case, with a trailing dot, user info or a port, with
  "This app does not connect to that host." It also refuses `http` to anything but a local
  address, so `https` is the only way to a public host. Tested in `ServerAddressTests`, in
  `CreditGuardTests` ("Credit guard 1") with a request-recording stub that must record zero
  requests for every refused form (`x.hf.space`, `huggingface.co`, upper case, a trailing dot,
  user info, a port, and `hf.co`), and in the Settings UI tests in `AccountScreenTests`:
  `testAPlainSpaceAddressIsRefusedWithNoProbe` (`https://dawri.hf.space` in English and Arabic)
  and `testARefusedHostShowsTheMessageWithNoProbe` (`https://User@Dawri.HF.Space.:443`) each show
  the refused-host message with the DEBUG probe count at 0, and
  `testAPublicHttpAddressIsRefusedWithNoProbe` does the same for `http://example.com`. All passed
  in the 13 Nov 2026 full run.
- **Guard 2, simulated mode only.** `ServerCheck` then sends exactly one request,
  `GET /api/health`, follows no redirect, and refuses any server whose `ai_mode` is not
  `simulated`, with "This server is not in simulated mode, so the app will not use it." It
  checks again on every relaunch and reconnect, so a server that turns real is refused. Tested in
  `CreditGuardTests` ("Credit guard 2") with the same stub, where `real` and an unknown mode each
  record exactly one request, `GET /api/health`. The same suite shows that a redirect from
  `/api/health` to another host is not followed, that a server that turns real is refused on the
  next call after a reconnect or a dropped stream, and that a full scripted remote journey never
  asks for the speech path. In the UI, `AccountScreenTests.testAServerNotInSimulatedModeIsRefused`
  shows the refused-AI message on Connect, and `testARefusalKeepsTheServerInUse` shows it for the
  server already in use, which stays as it is. Both passed in the 13 Nov 2026 full run.
- **App Transport Security** allows plain `http` only to the local network:
  `NSAppTransportSecurity` is exactly `NSAllowsLocalNetworking = true`, with no arbitrary-loads
  key and no exception domains. The Live Activity extension has no ATS key and makes no request.
- **The search.** `ios/Tools/no-credit-check.sh` and `NoCreditSourceTests` find Hugging Face and
  model-provider hosts in the app's folders only in the refusal guards, their tests and banned
  lists, plus four provider words (`featherless`, `novita`, `openai`, `whisper`) that occur as
  rule-input text in the goldens harvested from the backend's tests, never as a host. On 13 Nov
  2026 the script printed "no-credit-check: clean (107 hits, every one allowed)" and exited 0.
  Foundation's network session type appears only in `DawriCore/Sources/DawriCore/Remote` and
  `DawriUITests/ServerModeTests.swift`.

The local server is the same guarantee from the other side: it runs only with `HF_TOKEN=` blank,
and the app refuses it otherwise.

## Definition of done

Each line of the Definition of done in `Dawri-Vault/08 iOS/iOS Brief.md`, with the evidence from
the Phase 5 integration runs of 13 Nov 2026 on `build/dawri-ios`. Full evidence for each phase is
in `Dawri-Vault/08 iOS/iOS Build Log.md`. PHONE-ONLY marks what a simulator cannot show; it is
listed in the next section and left for the owner's phone test.

| Brief line | Evidence | Status |
| --- | --- | --- |
| `swift test` in `DawriCore` is green, and every safety golden passes | From an empty scratch folder: "Test run with 627 tests in 93 suites passed after 23.248 seconds", 0 skipped, 0 compiler warnings. Every safety golden suite ran and passed by name: red flag goldens (single messages and conversations), the refill golden, text, regex, parser and read-back goldens, the `next_turn` and session replay suites, the clinic rule goldens, the queue traces and the golden manifests. No `XCTSkip`, `.disabled(` or `withKnownIssue` in `DawriCore/Tests` or `DawriUITests`. `sync-strings.py --check`, `export-engine-data.py --check` and `export-goldens.py --check` exit 0 | PASS |
| (the same line) The shared contract suite runs against both back ends | `ios/Tools/clinic-server.sh contract <scratch>` against a real local backend that printed `ai_mode simulated http://127.0.0.1:8101`: 32 tests, 35 cases on this phone and 35 on the clinic server, all passed; 474 requests, all from 127.0.0.1 | PASS |
| `xcodebuild test` on "Dawri Build" is green | Fresh derived folder, after uninstalling the app and rebooting the simulator, no sleep in `pmset -g log`: 163 UI tests in 22 classes, 161 passed on the first run. The 2 failures were in Xcode's test machinery, each with its log evidence above (an audit-service timeout with the app idle, and a synthesized tap whose touch backboardd dropped); after another uninstall and reboot both passed, `AccessibilityAuditTests` 2 of 2 on the first try. The chat audit rows passed 10 of 10 with `-test-iterations 5`. After the AX3 address fix under Tests, `AccountScreenTests`, `ChatScreenTests` and `AccessibilityAuditTests` ran again: 42 of 42 passed. The Dawri scheme does not run `ServerModeTests` | PASS, with the environmental rerun reported |
| XCUITests walk Fatima, Ahmed and Ravi in AR and EN in On this phone mode | `JourneyTests`, 7 of 7, launched with only `-demoLang` and `-demoFreeze 0`, no server argument: `testFatimaInArabic`, `testFatimaInEnglish` (ticket, medicines with no penicillin, rating, history), `testFatimaForADependent`, `testAhmedInArabic`, `testAhmedInEnglish` (refill route, no ticket), `testRaviInArabic`, `testRaviInEnglish` (emergency screen, 999, no ticket) | PASS |
| In Clinic server mode, against a local simulated backend, a patient on the simulator gets a ticket, and it moves from staff API calls with the app updating live | `ios/Tools/server-proof.sh <outdir>`: PASSED, 4 of 4, twice (the second on the final code). Fatima in English went from T-014 through called, serving, D-GP-023, the doctor's call, P-031, the pharmacy's call and S11 with paracetamol and dextromethorphan and no penicillin; in Arabic through the doctor's call. Each move showed in 0.14 s to 0.34 s with no refresh; with the stream down, polling showed it (0.47 s and 4.32 s) with the slow line. 187 and 194 requests in the server logs, all from 127.0.0.1, none to the speech path, none answered 401. The stage screenshots and frames of `server-proof.mov` were viewed in both languages. Over Wi-Fi from a real phone is PHONE-ONLY | PASS |
| A device build signs and compiles with `generic/platform=iOS`, using team `4Y4YQ65B78` | `xcodebuild -project ios/Dawri.xcodeproj -scheme Dawri -configuration Release -destination 'generic/platform=iOS' -derivedDataPath <fresh> -allowProvisioningUpdates build`: BUILD SUCCEEDED, signed with an Apple Development identity and "iOS Team Provisioning Profile: com.jaber.dawri" and "...: com.jaber.dawri.live" (team 4Y4YQ65B78, one device, made 9 Nov 2026, expiring 16 Nov 2026). `codesign -dvv`: TeamIdentifier=4Y4YQ65B78 on `Dawri.app` and `DawriLiveExtension.appex`. `codesign -d --entitlements -`: only `application-identifier`, `com.apple.developer.team-identifier` and `get-task-allow` on each, so no paid capability. `codesign --verify --deep --strict` passes. The device app's ATS is `{NSAllowsLocalNetworking: true}` and it holds none of the 13 DEBUG hooks | PASS |
| Agents never install it | No `devicectl`, `ios-deploy` or `simctl install` of the device build was run, and the physical iPhone was not touched. Installing is the owner's step | PASS |
| A log proves no request left for any Hugging Face host | Guard 1 and Guard 2 above: `CreditGuardTests` record zero requests for every refused host form and exactly one `GET /api/health` for a server not in simulated mode, and the Settings UI tests show the refused-host message with the probe count at 0. `no-credit-check.sh` exits 0 ("clean (107 hits, every one allowed)"), and a plain `grep -rniE` over `ios/` hits only the guards, their tests and banned lists (this README's guarantees section is one). The network session type appears only in `DawriCore/Sources/DawriCore/Remote` and `DawriUITests/ServerModeTests.swift`. The contract and server-proof logs show only 127.0.0.1. The Release app's `Info.plist` has `NSAppTransportSecurity` exactly `{NSAllowsLocalNetworking: true}`, the extension has no ATS key, and `NSLocalNetworkUsageDescription` is in both `ar.lproj` and `en.lproj` | PASS |
| `ios/README.md` covers open in Xcode, run on an iPhone with a free team, starting the local server for Clinic server mode, and an honest list of what only a real phone can prove | The sections above and below | PASS |
| What only a real phone can prove: microphone, on-device Arabic speech, geofence, QR camera, the Live Activity on the real Dynamic Island, the 999 dialer, haptics, and the rest listed below | Built, and tested as far as a simulator allows. Not claimed as verified | PHONE-ONLY |

Also checked on 13 Nov 2026: the Release simulator build succeeded, and `strings` on its app and
extension binaries finds none of the DEBUG launch hooks (`demoScreen`, `demoMode`, `demoAddress`,
`demoConnect`, `demoServer`, `demoClinic`, `demoFail`, `demoHold`, `demoCamera`, `demoVoice`,
`demoNotify`, `demoLiveProbe`, `demoFreeze`), nor the DEBUG types `DemoLaunch`, `DemoFeatures`,
`DemoAccount`, `DemoClinicProxy` and `LiveGallery`, while the Debug build's `Dawri.debug.dylib`
has every hook. The built app's `NSAppTransportSecurity` is exactly
`{NSAllowsLocalNetworking: true}`, and the AR and EN `InfoPlist.strings` hold
`NSLocalNetworkUsageDescription`. `git diff bb37797 -- backend frontend` is empty, and no build
output or `.swiftpm` folder is left under `ios/`.

## What only a real iPhone can prove

The simulator, the unit tests and the UI tests prove a great deal, but not everything. Each item
below is built and was exercised as far as a simulator allows. None of them is claimed as
verified on hardware. The owner's phone test after the build is where they are proved.

| Only a phone can prove | What the simulator and the tests proved instead |
| --- | --- |
| **The microphone, and on-device recognition in Arabic and English**: that the phone has on-device models for `ar-QA`, `ar-SA` or `ar-AE` and for English, and how well they hear a patient | `VoiceAvailabilityTests` (DawriCore): the order of the checks, that recognition is only ever requested on device, that an unsupported recogniser gives `VoiceFailure.unavailable` with no request made, and the locale choice. `SpeechVoiceEngine` sets `requiresOnDeviceRecognition = true`, and a grep finds no server recognition, recorder or audio file. `VoiceNativeTests`: on the real engine with the microphone refused, S05 shows `voice.error.denied` and typing still sends; nothing is sent before Send in the confirm step; a language switch while listening restarts in the new language. The listening and confirm flows ran on scripted fakes. No UI test records from the Mac's microphone |
| **A live QR read** of the printed `DOOR-C-WAKRA` on a centre's door, through the camera | `DoorScanTests`: only `DOOR-<id>` is accepted after normalisation, and links and anything else are refused. The simulator has no camera, so `ArrivalNativeTests` proved the sheet's typed field with `reserved.cameraUnavailable`, the same with `-demoCamera denied`, a fake read of `scan:DOOR-C-WAKRA` reaching S10 through the real submit, and a fake read of a link opening nothing. The `s09-door-camera-denied` shots show the sheet in both languages, light and dark, and at AX3 |
| **A real GPS geofence at a centre**, a real fix's accuracy against the 100 m bound, and the **precise-location prompt** (`ArrivalCheck`) when the patient has chosen approximate location | `LocationRulesTests`: when-in-use only, one reading per tap, the 10 s timeout, the 30 s age and 100 m accuracy bounds. `ArrivalNativeTests` set `XCUIDevice.shared.location`: about 20 m from Al Wakra reaches S10 with a number, about 5 km away shows the too-far notice with the metres, a refused permission shows location failed. A shell run with `xcrun simctl location set` gave the same arrived and too-far screens. The simulator always reports full accuracy, so the imprecise notice was shown only through `-demoLocation imprecise` |
| **The Lock Screen and the real Dynamic Island**, including the expansion and sound on the called alert, the ended activity staying 15 minutes, the stale state at its stale date, and the activity after the app is suspended or killed | `LiveTicketRulesTests` and `TicketLiveTextTests` (DawriCore): no activity while reserved, on an emergency or a refill; a start on a numbered ticket; the alert only on called; the stale date; the end at completion with a 15-minute dismissal; `pushType: nil`; no hex colour in the extension. `LiveActivityTests` read the system's own `Activity.activities` through a DEBUG probe: one activity with the S10 number, updated by Demo: next step, ended at completion, none on S09 or for Ravi, restarted in the new language after a switch. The `live-gallery-*` shots draw every presentation and state with the extension's own views, and the `live-island` shot is the simulator's real compact Island with the app in the background |
| **Notification delivery** while the phone is locked or the app is suspended, and when a notice actually arrives | `NotificationPlanTests` (DawriCore): call steps give `notify.next`, stage moves give `notify.stage`, past steps give nothing. `NotificationTests` with the real `UNUserNotificationCenter` behind `-demoNotify on`: the permission is asked only at arrival, the pending ids match the plan ahead of time, they are rescheduled after Demo: next step, none remain after completion, and without the flag no prompt appears. Pending requests prove scheduling, not delivery |
| **The 999 dialer**: that `tel://999` opens the phone's call screen in one tap | `EmergencyScreenTests`: Call 999 is the first element in the tree on S06, in Arabic and English, and one tap hands `tel://999` to `openURL`, which the DEBUG hook `-demoRecordLinks` records in place of opening it. The test reads the element tree, not VoiceOver's speech, and the simulator has no phone app, so no call screen was shown and no call placed |
| **Haptics**: that each event is felt, and that `micStart` plays before the audio session mutes haptics | By reading the code: every `DS.Haptic` event in iOS Design section 6.4 has its `.sensoryFeedback` on the state change that drives it. The simulator plays no haptics |
| **VoiceOver speech order** and how the labels sound in each language | `AccessibilityAuditTests` in Arabic and English over every screen in `ScreenTable`, the door sheet and the Live gallery, with each accepted finding written beside its reason. `EmergencyScreenTests` prove the S06 order in the element tree. Labels exist in both languages for the map pins, the scanner preview, the mic and the Live views. The speech itself was not heard |
| **Reduce Motion at runtime** | By reading the code: new animations go through `DS.Motion.resolved`, and the pin press has no scale under Reduce Motion. The Live views use `numericText`, which the system adapts. No test turns Reduce Motion on |
| **The iOS 18 look** | The review simulator runs iOS 26.5. iOS Design section 5 keeps the iOS 18 column a build rule, checked by reading code: no custom glass, one availability branch in `LanguageToggle` |
| **Clinic server from a real phone over Wi-Fi**, and the system's **local network prompt** with its usage text | `server-proof.sh` on the simulator: Connect to a simulated server on `127.0.0.1`, the Connected pill, a ticket moved live by staff API calls through every stage in English and to the doctor in Arabic, polling with the stream down, and a relaunch that stays on the server. `ServerHealthProbe` on a closed loopback port gives unreachable (`AccountScreenTests.testTheAppsOwnProbeFindsNothingOnAClosedPort`). `NSLocalNetworkUsageDescription` is in the built app's `ar.lproj` and `en.lproj`. The simulator shares the Mac's network and reaches its `127.0.0.1` with no local network prompt, so it cannot show the prompt, the Mac's firewall question, or a Wi-Fi network that keeps devices apart |
| **App Transport Security for `http` to a LAN address or a `.local` name on hardware** | The built `Dawri.app` Info.plist holds `NSAppTransportSecurity` = `{NSAllowsLocalNetworking: true}` and nothing else (checked on the signed Release device build), and `NoCreditSourceTests` in DawriCore checks the source plist. On the simulator the server is `127.0.0.1`. Whether iOS treats a given LAN address or `.local` name as local is only shown on a phone |
| **The Keychain session token** for a clinic server, kept across launches and removed on sign-out | `KeychainTokenStore` (`ios/Dawri/Native/`): one generic password item, `WhenUnlockedThisDeviceOnly`, no entitlement. `ServerModeTests.testARelaunchStaysOnTheServerUntilOnThisPhone` ran with no launch hook against the real simulated server: after Connect and Fatima's sign-in, a relaunch opened on Home, still signed in, with Settings showing Connected; On this phone then switched back at once. In DawriCore, `RemoteEndpointTests` and `RemoteErrorTests` show the token kept after `authVerify`, sent on the next call, cleared by sign-out and by a 401. The simulator's Keychain lives in a file on the Mac, so the phone's own Keychain, its data protection while locked, and a free-team signed build's access to it are only shown on a phone |
