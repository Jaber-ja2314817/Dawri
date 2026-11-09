export const meta = {
  name: 'dawri-ios-build-resume',
  description: 'Resume the Dawri iOS build: Phase 3 fix wave gate-shot-rows and review round 2, then Phases 4 and 5. Commits to build/dawri-ios. No Hugging Face or API usage.',
  whenToUse: 'Resume the paused Dawri iOS build from Phase 3 round 2',
  phases: [
    { title: 'Phase 3: Patient screens', detail: 'Round 2: gate-shot-rows fix, then re-review' },
    { title: 'Phase 4: Native features', detail: 'Speech, MapKit, location, QR, Live Activity, notifications, accessibility' },
    { title: 'Phase 5: Clinic server and ship-ready', detail: 'Remote client, guards, live staff link, UI tests, device build, README' },
  ],
}

const ROOT = '/Users/jaberal-boenain/Desktop/Dawri'
const BRANCH = 'build/dawri-ios'
const BRIEF = 'Dawri-Vault/08 iOS/iOS Brief.md'
const LOG_NOTE = 'Dawri-Vault/08 iOS/iOS Build Log.md'
const MAX_ROUNDS = 4

const NO_CREDIT = `ABSOLUTE RULE FROM THE OWNER: nothing may touch the Hugging Face account or any API usage. Never read or print .env. Never send a request to any *.hf.space, *.huggingface.co or model provider host, not even a health check. Never run hf. Never redeploy. Any backend process or Python importing backend.* must run with HF_TOKEN= blank, exactly as "${BRIEF}" shows, and you must confirm /api/health says ai_mode simulated before using a server. Do not spend credits by any route.`

const POWER = `Power note: the Mac may be on battery. Before any long UI test run, check pmset -g batt and pmset -g log for sleep. If a UI test fails with "Timed out while synthesizing event", a signal term, or a gap that matches a sleep or CoreSimulatorService restart in the logs, it is environmental: rerun just those tests and report both runs honestly. Never touch the owner's iPhone Air simulator F7E60EDF.`

const IDENTITY = `You are the ORCHESTRATOR of the Dawri iOS build, the boss of every agent on it.
The vault at ${ROOT}/Dawri-Vault is your brain. "${BRIEF}" is the authority for this app: read it first and in full. Then read "Dawri-Vault/07 Build/Build Decisions.md", then "${LOG_NOTE}" for what earlier phases did, then "Dawri-Vault/08 iOS/iOS Design.md", and whichever notes and code bear on this phase (HANDOFF.md, Screens, Patient Journey, Safety Guardrails, AI Receptionist Design, Risks & Red Lines, backend/, frontend/src/).
This is a resumed run. Phases 1 and 2 were approved earlier (47c8458, a58b63b). Phase 3 was built and saved as WIP commit 64e1525 after review round 1 rejected it for one gap.
The owner is away and cannot be asked anything. Decide using the vault. Never touch the main branch or real data. Main moved with teammates' commits (a70cedd, 07ec7f7, 542bc32); this branch starts at bb37797, so compare backend and frontend against bb37797, not main.
${NO_CREDIT}
${POWER}`

const P3_ACCEPTANCE = [
  'swift test for ios/DawriCore from a clean scratch path passes with 0 failures, and a grep for XCTSkip, .disabled( and withKnownIssue in DawriCore/Tests and DawriUITests finds nothing. Every safety golden runs.',
  'The full Dawri UI test suite on the Dawri Build simulator passes, including JourneyTests for Fatima (ticket, medicines with no penicillin family, rating, History), Ahmed (S07 with no ticket, then S08) and Ravi (S06) in AR and EN. Environmental failures are rerun and both runs reported.',
  'Every state in Screens.md and iOS Design section 8 has a row in ios/Tools/shots/*.tsv, including the VisitGate loading (SkeletonBars) and error (ErrorBlock with retry) states. The only allowed exclusions are Map selection, camera denied and Live Activity, which belong to Phase 4.',
  'ios/Tools/shoot.sh over all rows gives PNGs that are all 1260x2736, in ar and en, light and dark, plus the ax3 rows, written outside ios/. Viewed contact sheets show Arabic right-aligned and joined, Back on the right in Arabic, stage track starting on the right, Latin digits, footer and AI simulated line on every screen, nothing clipped at AX3, and S06 with a white status bar, no back and a pinned Call 999.',
  'Colour scan of every shot (top 170 px excluded): no #1d5fbf or #689ce8 outside S10 and the gallery, and no image other than S06 and the gallery above 1% #c4242a.',
  'A Release simulator build succeeds and strings shows no DEBUG launch hooks. generic/platform=iOS with CODE_SIGNING_ALLOWED=NO builds.',
  'sync-strings --check, export-engine-data --check and export-goldens --check exit 0, run with HF_TOKEN= blank and HF_HUB_OFFLINE=1, and report ai_mode simulated.',
  'git diff bb37797 -- backend frontend is empty. Goldens and rule resources are unchanged since a58b63b. Nothing built or ignored (.swiftpm, DerivedData, .build) is under ios/.',
  'The network grep over ios/ hits only ServerAddress.swift and known comments. No Hugging Face host or model call exists outside the refusal guards. No Speech, CoreLocation or AVFoundation import in ios/Dawri yet.',
]

const P3_PREV_FAILURES = [
  'Shot-table coverage: Design section 8 lists VisitGate loading (skeleton) and VisitGate error (ErrorBlock with retry) for every visit screen, and neither has a row in ios/Tools/shots/*.tsv. The only getVisit rows are the S06 rows and s03-demo-reset (gone). The acceptance check needs every state in Screens.md and Design section 8 to have a row. The states work when shot by hand with -demoScreen s10 -demoFreeze 1 -demoHold getVisit and with -demoFail getVisit=network, so only the rows are missing.',
]

const GATE_TASK = {
  id: 'gate-shot-rows',
  title: 'Add VisitGate loading and error rows to the shot table',
  owned_paths: ['ios/Tools/shots/visit.tsv'],
  vault_notes: ['Dawri-Vault/08 iOS/iOS Design.md (section 8)', 'Dawri-Vault/08 iOS/iOS Build Log.md (Phase 3 section)'],
  brief: `Design section 8 says every visit screen has VisitGate states: loading (SkeletonBars under the screen's title), an ErrorBlock with retry, and gone. Gone already has the row s03-demo-reset. Loading and error have no row in any ios/Tools/shots/*.tsv, so the shot-coverage check fails.

Add two rows to ios/Tools/shots/visit.tsv, matching the existing column format exactly:
- gate-loading, settle about 3 s, flags ax3, arguments -demoScreen s10 -demoFreeze 1 -demoHold getVisit
- gate-error, settle about 3 s, arguments -demoScreen s10 -demoFreeze 1 -demoFail getVisit=network
You may also add one more of each on another visit screen, such as s08. The reviewer shot these by hand and they render correctly, so no app code should change. If a row does not show the state, report it and do not change app code outside your path.

Then run, with your own --derived folder and an output folder in your scratchpad, never under ios/:
  ios/Tools/shoot.sh --only 'gate-*' <scratchpad>/shots
Confirm:
- every PNG is 1260x2736, in ar and en, light and dark, plus ax3
- the colour scan finds no #1d5fbf or #689ce8 hue and no image above 1% #c4242a
View the images: Arabic right-aligned, Back on the right, footer and AI line present, nothing clipped at AX3.

You are the owner of the Dawri Build simulator (B55FEAC2-08EB-460D-9261-E28A60F4B5CC) for this wave; use only it and leave it shut down. Remove ios/DawriCore/.swiftpm if xcodebuild creates it. Do not commit.`,
}

const PHASES = [
  { title: 'Phase 3: Patient screens',
    goal: `Every patient screen S01 to S12 and a Settings screen in SwiftUI on ClinicService, in every state listed in Screens and every behaviour of frontend/src/pages/patient, frontend/src/features and frontend/src/components (consent, dependents, chat with summary card and is-this-right confirm, emergency override with no ticket, refill, centre list with a map placeholder for Phase 4, reserved countdown and expiry, live ticket steps, complete with medicines and rating, history, language toggle everywhere, demo footer and AI simulated label everywhere, labelled Demo next step control). Follow iOS Design.md. Judge from simulator screenshots of every screen in AR and EN, light and dark, at the Dawri Build iPhone Air size. Screenshots go in a scratchpad folder, not in the repo.`,
    resume: {
      summary: 'Phase 3 screens were built in round 1 (WIP commit 64e1525). Round 1 review rejected only for two missing shot-table rows. Round 2 adds them and re-reviews.',
      waves: [{ tasks: [GATE_TASK] }],
      acceptance: P3_ACCEPTANCE,
      startRound: 2,
      prevFailures: P3_PREV_FAILURES,
    },
  },
  { title: 'Phase 4: Native features', goal: `The native table in iOS Brief in full: on-device speech with transcript confirm and typing fallback and never server recognition, MapKit centres with wait badges and list fallback, Core Location geofence for I'm here with the door code, QR scanning with typed fallback, ActivityKit Live Activity and Dynamic Island driven locally with no push, local notifications scheduled ahead in On this phone mode, haptics, native sheets, swipe back, pull to refresh, keyboard handling, tel 999, Info.plist usage strings in both languages, privacy manifest, VoiceOver in AR and EN, Dynamic Type to AX3, Reduce Motion, dark mode. Everything signs on a free Personal Team. Hardware-only behaviour is isolated behind protocols with fakes so logic is tested, and is listed honestly as needing the phone rather than claimed as verified. Use simctl location for the geofence where possible. Add shot-table rows for the Phase 4 states that Phase 3 excluded: Map selection, camera denied, and the Live Activity where a simulator can show it.` },
  { title: 'Phase 5: Clinic server and ship-ready', goal: `RemoteClinicService with REST and SSE plus polling fallback against the existing API, Settings mode switch and server field, both credit guards from iOS Brief with tests, ATS local networking only, and the shared contract suite passing against a real local backend in simulated mode. Prove live: a patient in the simulator gets a ticket and staff API calls move it with the app updating without refresh. XCUITests walk Fatima, Ahmed and Ravi in AR and EN in On this phone mode. A Release device build compiles and signs with generic/platform=iOS and team 4Y4YQ65B78 using -allowProvisioningUpdates if needed, and is never installed. A search proves no Hugging Face host or model call exists in ios/ except inside the refusal guards and their tests. ios/README.md per the definition of done, honest about what only a real phone can prove. Every line of Definition of done in iOS Brief is checked and reported. Fix every bug found.` },
]

const TASK_SCHEMA = { type: 'object', properties: {
  id: { type: 'string' }, title: { type: 'string' },
  owned_paths: { type: 'array', items: { type: 'string' } },
  brief: { type: 'string' },
  vault_notes: { type: 'array', items: { type: 'string' } },
}, required: ['id', 'title', 'owned_paths', 'brief', 'vault_notes'] }
const PLAN_SCHEMA = { type: 'object', properties: {
  summary: { type: 'string' },
  waves: { type: 'array', minItems: 1, items: { type: 'object', properties: { tasks: { type: 'array', minItems: 1, items: TASK_SCHEMA } }, required: ['tasks'] } },
  acceptance: { type: 'array', items: { type: 'string' } },
}, required: ['summary', 'waves', 'acceptance'] }
const REPORT_SCHEMA = { type: 'object', properties: {
  id: { type: 'string' },
  status: { type: 'string', enum: ['done', 'partial', 'blocked'] },
  what_changed: { type: 'string' }, test_evidence: { type: 'string' },
  open_issues: { type: 'array', items: { type: 'string' } },
}, required: ['id', 'status', 'what_changed', 'test_evidence', 'open_issues'] }
const VERDICT_SCHEMA = { type: 'object', properties: {
  approved: { type: 'boolean' }, evidence: { type: 'string' },
  failed: { type: 'array', items: { type: 'string' } },
  known_gaps: { type: 'array', items: { type: 'string' } },
  fix_waves: { type: 'array', items: { type: 'object', properties: { tasks: { type: 'array', items: TASK_SCHEMA } }, required: ['tasks'] } },
}, required: ['approved', 'evidence', 'failed', 'known_gaps', 'fix_waves'] }
const COMMIT_SCHEMA = { type: 'object', properties: {
  committed: { type: 'boolean' }, pushed: { type: 'boolean' }, sha: { type: 'string' }, notes: { type: 'string' },
}, required: ['committed', 'pushed', 'sha', 'notes'] }

function runTask(task, phaseTitle, acceptance) {
  if (args && args.reportDir && args.done && args.done.includes(task.id)) {
    const file = `${args.reportDir}/p4-report-${task.id}.json`
    log(`${task.id}: already finished, using its saved report ${file}`)
    return Promise.resolve({ id: task.id, status: 'done',
      what_changed: `This builder finished in an earlier run segment. Its full report (what changed, test evidence, open issues) is in ${file}. Read that file in full and treat it as claims, not facts.${task.id === 'p4-map' ? ' Note: the original p4-map agent died in an internet outage and was re-run separately at the owner\'s request, on a second iPhone Air simulator "Dawri Map" FC231CFD-0100-4598-A329-3FEB3D62E7A6, so its UI tests did not run on Dawri Build.' : ''}`,
      test_evidence: `See ${file}`,
      open_issues: [`Open issues are listed in ${file}`] })
  }
  return agent(`You are a builder on the Dawri iOS team and you report to the orchestrator. Working directory: ${ROOT}. Branch: ${BRANCH}.
Read "${BRIEF}" first, it is the authority. Then read these: ${task.vault_notes.join(', ')}.
${NO_CREDIT}
${POWER}

Task ${task.id}: ${task.title}
${task.brief}${args && args.reportDir && phaseTitle === 'Phase 4: Native features' ? `

The earlier Phase 4 builders' full reports, including their open issues for you, are in ${args.reportDir}/p4-report-<id>.json (p4-groundwork, p4-map, p4-arrival-voice-scan, p4-live-notify). Read them first. p4-map was re-run separately after an internet outage and its UI tests ran on a second simulator "Dawri Map" FC231CFD, which is shut down. Do not use it: your simulator is Dawri Build.` : ''}

You own only these paths: ${task.owned_paths.join(', ')}. Other agents may be editing other paths at the same time, so do not edit outside yours. If you need a change elsewhere, record it in open_issues.

Phase acceptance criteria, for context:
${acceptance.map(a => '- ' + a).join('\n')}

Rules:
- Follow "Parallel build rules" in the brief: your own --scratch-path and -derivedDataPath, outside ios/. Use the "Dawri Build" simulator only if this brief names you its owner for this wave. Never touch the owner's iPhone Air simulator or the physical iPhone.
- Use .venv/bin/python for Python. Stop any server you start.
- Run what you built and report real results. Never claim a check you did not run. Do not stub a feature and call it done.
- Use the skills that genuinely help, especially anthropic-skills:write-swift for Swift and anthropic-skills:apple-design for interaction.
- Do not commit, push, or switch branches. The orchestrator handles git after approval.`,
    { label: `build:${task.id}`, phase: phaseTitle, schema: REPORT_SCHEMA })
}

async function runWaves(waves, phaseTitle, acceptance) {
  const reports = []
  for (const wave of waves) {
    const results = await parallel(wave.tasks.map(t => () => runTask(t, phaseTitle, acceptance)))
    wave.tasks.forEach((t, i) => {
      reports.push(results[i] || { id: t.id, status: 'blocked', what_changed: 'Agent died without a report', test_evidence: 'none', open_issues: ['No report returned'] })
    })
  }
  return reports
}

const history = [
  { phase: 'Phase 1: Foundation', provisional: false, summary: 'Approved round 1, commit 47c8458. Details in the iOS Build Log.', known_gaps: [] },
  { phase: 'Phase 2: On-device engine', provisional: false, summary: 'Approved round 1, commit a58b63b. 479 core tests and every safety golden pass. Details in the iOS Build Log.', known_gaps: [] },
]

for (const p of PHASES) {
  phase(p.title)

  let plan
  let startRound = 1
  let prevFailures = []
  if (p.resume) {
    log(`${p.title}: resuming at round ${p.resume.startRound} with the saved fix brief`)
    plan = { summary: p.resume.summary, waves: p.resume.waves, acceptance: p.resume.acceptance }
    startRound = p.resume.startRound
    prevFailures = p.resume.prevFailures
  } else {
    log(`${p.title}: orchestrator is planning from the vault`)
    plan = await agent(`${IDENTITY}

Plan ${p.title}. Goal: ${p.goal}

Earlier phases:
${JSON.stringify(history.map(h => ({ phase: h.phase, provisional: h.provisional, summary: h.summary, known_gaps: h.known_gaps })))}

Inspect the actual current state of the repo before planning. Do not edit anything.
Return waves of tasks. Tasks in one wave run in parallel, so their owned_paths must never overlap, and later waves can rely on earlier ones. Prefer 2 to 5 builders in total for the phase, each with a self-contained brief naming exact files, the Python or TypeScript source it ports where relevant, and the checks it must run. In each wave name at most one task as the owner of the "Dawri Build" simulator, in its brief.
Acceptance must be concrete checks that an independent reviewer can run, drawn from the goal and the brief's Definition of done, including screenshot review where a screen is involved.`,
      { label: 'orchestrator:plan', phase: p.title, schema: PLAN_SCHEMA })
  }

  if (!plan) { log(`${p.title}: the plan agent failed, skipping to the next phase`); history.push({ phase: p.title, provisional: true, open_failures: ['Plan agent failed'], summary: 'none', known_gaps: [] }); continue }

  let waves = plan.waves
  let verdict = null
  const allReports = []
  const limit = MAX_ROUNDS

  for (let round = startRound; round <= limit; round++) {
    log(`${p.title}: round ${round} of ${limit}, building`)
    const reports = await runWaves(waves, p.title, plan.acceptance)
    allReports.push(...reports)

    const isResumedPhase3 = !!p.resume
    verdict = await agent(`${IDENTITY}

Review ${p.title}, round ${round} of ${limit}. Goal: ${p.goal}

Acceptance checks:
${plan.acceptance.map(a => '- ' + a).join('\n')}

Failures from the previous round, to re-verify first:
${prevFailures.length ? prevFailures.map(a => '- ' + a).join('\n') : '- none'}

Builder reports. Treat these as claims, not facts:
${JSON.stringify(reports)}

Verify independently: read the code, run the tests and the app yourself with your own derived data path, take simulator screenshots on "Dawri Build" and look at them where screens exist, and exercise each check. Compare the result with "${BRIEF}" and try to find where it falls short.${isResumedPhase3 ? `
Round 1 evidence is in the Phase 3 section of "${LOG_NOTE}". Use git diff 64e1525 to see exactly what changed since round 1. You must still run the core tests, the full UI suite and the full shoot.sh yourself; do not rely on round 1 numbers.` : ''}

Review discipline. Judge guarantees, not strings.
1. Re-verify every failure from any previous round, then every acceptance check, then the full test suite for this phase.
2. An item belongs in failed only if you can show a concrete break of a red line, a hard rule, the brief, or a demo patient's path. A skipped or disabled safety golden is always a failure. A route that lets a listed red-flag cue reach a ticket is always a failure. Any path to a Hugging Face host or any spending of credits is always a failure.
3. Anything that only real hardware can prove goes in known_gaps as a phone test item, never in failed, provided the logic is tested with a fake and the feature is really implemented. A stub is a failure.
4. Do not add work outside this phase's goal.

approved=true only if every acceptance check passes on your own evidence. If not approved, give fix_waves that address every failure, with the same no-overlap rule, and do not fix anything yourself.

If approved, and only then, you may edit one file: "${LOG_NOTE}".${isResumedPhase3 ? ` Replace the existing "## Phase 3: Patient screens, PAUSED after review round 1 (not approved)" section with "## Phase 3: Patient screens (approved on review round ${round} of ${limit}, 8 Nov)" containing the plan, what was built, the round 1 failure and its fix, your evidence and the known gaps (keep the round 1 phone test items).` : ' Append a section with the plan, what was built, the evidence and known gaps.'} Leave the Dawri Build simulator shut down and stop any server you started.`,
      { label: `orchestrator:review-${round}`, phase: p.title, schema: VERDICT_SCHEMA })

    if (!verdict) { verdict = { approved: false, evidence: 'Review agent failed', failed: ['Review agent failed'], known_gaps: [], fix_waves: [] }; break }
    log(`${p.title}: round ${round} ${verdict.approved ? 'APPROVED' : 'rejected, ' + verdict.failed.length + ' failures'}`)
    if (verdict.approved) break
    if (!verdict.fix_waves.length) break
    waves = verdict.fix_waves
    prevFailures = verdict.failed
  }

  const provisional = !verdict || !verdict.approved
  if (provisional) {
    const open = verdict ? verdict.failed : ['Review agent failed']
    log(`${p.title}: not approved after the last round, ${open.length} open failures. Logged, and the build continues.`)
    await agent(`Edit only "${ROOT}/${LOG_NOTE}". ${p.resume ? 'Replace the existing "## Phase 3: Patient screens, PAUSED after review round 1 (not approved)" heading and its "Open failures" list' : 'Append one section'} titled "${p.title}: PROVISIONAL, not approved". State that this phase did not pass review, and list every item below word for word under "Open failures", then every item under "Known gaps".

Open failures:
${open.map(a => '- ' + a).join('\n')}

Known gaps:
${(verdict ? verdict.known_gaps : []).map(a => '- ' + a).join('\n')}`,
      { label: 'orchestrator:log-provisional', phase: p.title, effort: 'low' })
  }

  const commit = await agent(`Commit and push the ${provisional ? 'provisional, not fully approved' : 'approved'} work for "${p.title}". Working directory: ${ROOT}. Do exactly this and nothing more.

1. Confirm the current branch is ${BRANCH}. If not, stop and report it. Never touch main.
2. Stage only the paths from this list that exist and have changes: ios "Dawri-Vault/08 iOS" .gitignore .dockerignore backend frontend. If backend or frontend show changes, list them in your notes.
3. Check the staged diff for secrets and junk: hf_ tokens, API keys, .env files, .venv, node_modules, .build, DerivedData, xcuserdata, .swiftpm, database files. If you find junk, unstage it. If you find a real secret, stop and report without committing.
4. Commit with a concise message describing what this phase ${p.resume ? 'round 2 fixed and that Phase 3 is now ' + (provisional ? 'still not approved' : 'approved') : 'built'}${provisional ? ', with a subject line starting "PROVISIONAL, not approved:" and a body saying the open failures are in the iOS Build Log' : ''}, ending with this exact trailer:
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
5. Run: git push -u origin ${BRANCH}. Never force push. If there is nothing to commit, report that.

Report the short sha, and whether the commit and push succeeded.`,
    { label: 'orchestrator:commit', phase: p.title, effort: 'low', schema: COMMIT_SCHEMA })

  history.push({ phase: p.title, provisional, open_failures: provisional && verdict ? verdict.failed : [], summary: plan.summary, evidence: verdict ? verdict.evidence : 'none', known_gaps: verdict ? verdict.known_gaps : [], commit, open_issues: allReports.flatMap(r => r.open_issues) })

  if (!commit || !commit.committed) log(`${p.title}: commit failed, the next phase's commit will carry this work: ${commit ? commit.notes : 'commit agent died'}`)
  else if (!commit.pushed) log(`${p.title}: committed ${commit.sha} but the push failed: ${commit.notes}`)
}

return { completed: history.slice(2).map(h => ({ phase: h.phase, provisional: h.provisional, open_failures: h.open_failures, commit: h.commit, known_gaps: h.known_gaps, evidence: h.evidence })) }
