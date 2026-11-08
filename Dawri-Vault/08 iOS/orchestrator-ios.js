export const meta = {
  name: 'dawri-ios-build',
  description: 'Vault-driven orchestrator builds the native Dawri iPhone patient app in phases, approves each against the vault, commits and pushes to build/dawri-ios. No Hugging Face or API usage.',
  whenToUse: 'Phased build of the Dawri iOS patient app',
  phases: [
    { title: 'Phase 1: Foundation', detail: 'Xcode project, DawriCore, design spec and system, strings, models, ClinicService, shell' },
    { title: 'Phase 2: On-device engine', detail: 'Rules, scripted receptionist, refill, queue, visit flow, seeds, safety goldens' },
    { title: 'Phase 3: Patient screens', detail: 'S01 to S12 and Settings, AR and EN, every state' },
    { title: 'Phase 4: Native features', detail: 'Speech, MapKit, location, QR, Live Activity, notifications, accessibility' },
    { title: 'Phase 5: Clinic server and ship-ready', detail: 'Remote client, guards, live staff link, UI tests, device build, README' },
  ],
}

const ROOT = '/Users/jaberal-boenain/Desktop/Dawri'
const BRANCH = 'build/dawri-ios'
const BRIEF = 'Dawri-Vault/08 iOS/iOS Brief.md'
const LOG_NOTE = 'Dawri-Vault/08 iOS/iOS Build Log.md'
const MAX_ROUNDS = 4
const ENGINE = 'Phase 2: On-device engine'
const roundLimit = (title) => (title === ENGINE ? 6 : MAX_ROUNDS)

const NO_CREDIT = `ABSOLUTE RULE FROM THE OWNER: nothing may touch the Hugging Face account or any API usage. Never read or print .env. Never send a request to any *.hf.space, *.huggingface.co or model provider host, not even a health check. Never run hf. Never redeploy. Any backend process or Python importing backend.* must run with HF_TOKEN= blank, exactly as "${BRIEF}" shows, and you must confirm /api/health says ai_mode simulated before using a server. Do not spend credits by any route.`

const IDENTITY = `You are the ORCHESTRATOR of the Dawri iOS build, the boss of every agent on it.
The vault at ${ROOT}/Dawri-Vault is your brain. "${BRIEF}" is the authority for this app: read it first and in full. Then read "Dawri-Vault/07 Build/Build Decisions.md", then "${LOG_NOTE}" for what earlier phases did, and whichever notes and code bear on this phase (HANDOFF.md, Screens, Patient Journey, Safety Guardrails, AI Receptionist Design, Risks & Red Lines, backend/, frontend/src/).
The owner is away and cannot be asked anything. Decide using the vault. Never touch the main branch or real data.
${NO_CREDIT}`

const PHASES = [
  { title: 'Phase 1: Foundation', goal: `Wave one writes "Dawri-Vault/08 iOS/iOS Design.md": the design spec agreed between taste (anthropic-skills:design-taste-frontend for palette, type, layout) and Apple behaviour (anthropic-skills:apple-design for motion, interaction, accessibility), light and dark, LTR and RTL. Then build: ios/ with Dawri.xcodeproj (objectVersion 77 with synchronized folders, modelled on /Users/jaberal-boenain/Desktop/news_app which is read-only), Config/Shared.xcconfig, app target, DawriLive widget extension target that compiles with a placeholder Live Activity, DawriUITests target, shared scheme, app icon generated from frontend/public/icons. DawriCore package building for iOS and macOS. Codable models for every shape in frontend/src/api/types.ts. The ClinicService protocol mirroring frontend/src/api/endpoints.ts including the live-update stream. String sync script from the patient i18n JSON plus a drift test, runtime language switch with RTL. Design system in SwiftUI from the spec. App shell with navigation driven by the same stage logic as frontend/src/lib/stages.ts, using a stub service. DEBUG launch-argument screen hooks compiled out of Release. The app launches on the "Dawri Build" simulator and shows a real themed S01 in AR and EN, with screenshots.` },
  { title: 'Phase 2: On-device engine', goal: `LocalClinicService in DawriCore: the Swift port of backend/ai/text.py, redflags.py, simulated.py, session.py, the scripted paths of receptionist.py, intake.py, refill.py, medicines.py, doctors.py, plus queue_engine.py, visit_flow.py, mock_health.py, centres.py, simulate.py and geo.py, with persistence as Codable state in Application Support, plus the DemoClinic driver with the allergy rule. Rule cues, normalisation tables and seeds are exported by a script in ios/Tools into DawriCore resources, not retyped. Golden corpus exported from the real Python functions and checked in as fixtures: red-flag decisions at large scale in AR and EN (use the inputs in backend/tests, vault acceptance sentences, generated variants covering diacritics, tatweel, letter variants, negation windows, clause breaks), refill decisions, whole scripted conversations, queue ordering and numbering, simulated-ticket rule, expiry, medicines text. Every golden must pass in swift test with none skipped. Fatima, Ahmed and Ravi run end to end in AR and EN at service level. The shared ClinicService contract test suite exists and passes for LocalClinicService.` },
  { title: 'Phase 3: Patient screens', goal: `Every patient screen S01 to S12 and a Settings screen in SwiftUI on ClinicService, in every state listed in Screens and every behaviour of frontend/src/pages/patient, frontend/src/features and frontend/src/components (consent, dependents, chat with summary card and is-this-right confirm, emergency override with no ticket, refill, centre list with a map placeholder for Phase 4, reserved countdown and expiry, live ticket steps, complete with medicines and rating, history, language toggle everywhere, demo footer and AI simulated label everywhere, labelled Demo next step control). Follow iOS Design.md. Judge from simulator screenshots of every screen in AR and EN, light and dark, at the Dawri Build iPhone Air size. Screenshots go in a scratchpad folder, not in the repo.` },
  { title: 'Phase 4: Native features', goal: `The native table in iOS Brief in full: on-device speech with transcript confirm and typing fallback and never server recognition, MapKit centres with wait badges and list fallback, Core Location geofence for I'm here with the door code, QR scanning with typed fallback, ActivityKit Live Activity and Dynamic Island driven locally with no push, local notifications scheduled ahead in On this phone mode, haptics, native sheets, swipe back, pull to refresh, keyboard handling, tel 999, Info.plist usage strings in both languages, privacy manifest, VoiceOver in AR and EN, Dynamic Type to AX3, Reduce Motion, dark mode. Everything signs on a free Personal Team. Hardware-only behaviour is isolated behind protocols with fakes so logic is tested, and is listed honestly as needing the phone rather than claimed as verified. Use simctl location for the geofence where possible.` },
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
  return agent(`You are a builder on the Dawri iOS team and you report to the orchestrator. Working directory: ${ROOT}. Branch: ${BRANCH}.
Read "${BRIEF}" first, it is the authority. Then read these: ${task.vault_notes.join(', ')}.
${NO_CREDIT}

Task ${task.id}: ${task.title}
${task.brief}

You own only these paths: ${task.owned_paths.join(', ')}. Other agents may be editing other paths at the same time, so do not edit outside yours. If you need a change elsewhere, record it in open_issues.

Phase acceptance criteria, for context:
${acceptance.map(a => '- ' + a).join('\n')}

Rules:
- Follow "Parallel build rules" in the brief: your own --scratch-path and -derivedDataPath, outside ios/. Use the "Dawri Build" simulator only if this brief names you its owner for this wave. Never touch the owner's booted iPhone 17 simulator or the physical iPhone.
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

const history = []

for (const p of PHASES) {
  phase(p.title)
  log(`${p.title}: orchestrator is planning from the vault`)

  const plan = await agent(`${IDENTITY}

Plan ${p.title}. Goal: ${p.goal}

Earlier phases in this run:
${JSON.stringify(history.map(h => ({ phase: h.phase, provisional: h.provisional, summary: h.summary, known_gaps: h.known_gaps })))}

Inspect the actual current state of the repo before planning. Do not edit anything.
Return waves of tasks. Tasks in one wave run in parallel, so their owned_paths must never overlap, and later waves can rely on earlier ones. Prefer 2 to 5 builders in total for the phase, each with a self-contained brief naming exact files, the Python or TypeScript source it ports where relevant, and the checks it must run. In each wave name at most one task as the owner of the "Dawri Build" simulator, in its brief.
Acceptance must be concrete checks that an independent reviewer can run, drawn from the goal and the brief's Definition of done, including screenshot review where a screen is involved.`,
    { label: 'orchestrator:plan', phase: p.title, schema: PLAN_SCHEMA })

  if (!plan) { log(`${p.title}: the plan agent failed, skipping to the next phase`); history.push({ phase: p.title, provisional: true, open_failures: ['Plan agent failed'], summary: 'none', known_gaps: [] }); continue }

  let waves = plan.waves
  let verdict = null
  const allReports = []
  const limit = roundLimit(p.title)

  for (let round = 1; round <= limit; round++) {
    log(`${p.title}: round ${round} of ${limit}, building`)
    const reports = await runWaves(waves, p.title, plan.acceptance)
    allReports.push(...reports)

    verdict = await agent(`${IDENTITY}

Review ${p.title}, round ${round} of ${limit}. Goal: ${p.goal}

Acceptance checks:
${plan.acceptance.map(a => '- ' + a).join('\n')}

Builder reports. Treat these as claims, not facts:
${JSON.stringify(reports)}

Verify independently: read the code, run the tests and the app yourself with your own derived data path, take simulator screenshots on "Dawri Build" and look at them where screens exist, and exercise each check. Compare the result with "${BRIEF}" and try to find where it falls short.

Review discipline. Judge guarantees, not strings.
1. Re-verify every failure from any previous round, then every acceptance check, then the full test suite for this phase.
2. An item belongs in failed only if you can show a concrete break of a red line, a hard rule, the brief, or a demo patient's path. A skipped or disabled safety golden is always a failure. A route that lets a listed red-flag cue reach a ticket is always a failure. Any path to a Hugging Face host or any spending of credits is always a failure.
3. Anything that only real hardware can prove goes in known_gaps as a phone test item, never in failed, provided the logic is tested with a fake and the feature is really implemented. A stub is a failure.
4. Do not add work outside this phase's goal.

approved=true only if every acceptance check passes on your own evidence. If not approved, give fix_waves that address every failure, with the same no-overlap rule, and do not fix anything yourself.

If approved, and only then, you may edit one file: append a section to "${LOG_NOTE}" with the plan, what was built, the evidence and known gaps. Stop any server you started.`,
      { label: `orchestrator:review-${round}`, phase: p.title, schema: VERDICT_SCHEMA })

    if (!verdict) { verdict = { approved: false, evidence: 'Review agent failed', failed: ['Review agent failed'], known_gaps: [], fix_waves: [] }; break }
    log(`${p.title}: round ${round} ${verdict.approved ? 'APPROVED' : 'rejected, ' + verdict.failed.length + ' failures'}`)
    if (verdict.approved) break
    if (!verdict.fix_waves.length) break
    waves = verdict.fix_waves
  }

  const provisional = !verdict || !verdict.approved
  if (provisional) {
    const open = verdict ? verdict.failed : ['Review agent failed']
    log(`${p.title}: not approved after the last round, ${open.length} open failures. Logged, and the build continues as in the earlier Dawri build.`)
    await agent(`Append one section to "${ROOT}/${LOG_NOTE}" and edit nothing else. Title: "${p.title}: PROVISIONAL, not approved". State that this phase did not pass review, and list every item below word for word under "Open failures", then every item under "Known gaps".

Open failures:
${open.map(a => '- ' + a).join('\n')}

Known gaps:
${(verdict ? verdict.known_gaps : []).map(a => '- ' + a).join('\n')}`,
      { label: 'orchestrator:log-provisional', phase: p.title, effort: 'low' })
  }

  const commit = await agent(`Commit and push the ${provisional ? 'provisional, not fully approved' : 'approved'} work for "${p.title}". Working directory: ${ROOT}. Do exactly this and nothing more.

1. Confirm the current branch is ${BRANCH}. If not, stop and report it. Never touch main.
2. Stage only the paths from this list that exist and have changes: ios "Dawri-Vault/08 iOS" .gitignore .dockerignore backend frontend. If backend or frontend show changes, list them in your notes.
3. Check the staged diff for secrets and junk: hf_ tokens, API keys, .env files, .venv, node_modules, .build, DerivedData, xcuserdata, database files. If you find junk, unstage it. If you find a real secret, stop and report without committing.
4. Commit with a concise message describing what this phase built${provisional ? ', with a subject line starting "PROVISIONAL, not approved:" and a body saying the open failures are in the iOS Build Log' : ''}, ending with this exact trailer:
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
5. Run: git push -u origin ${BRANCH}. Never force push. If there is nothing to commit, report that.

Report the short sha, and whether the commit and push succeeded.`,
    { label: 'orchestrator:commit', phase: p.title, effort: 'low', schema: COMMIT_SCHEMA })

  history.push({ phase: p.title, provisional, open_failures: provisional && verdict ? verdict.failed : [], summary: plan.summary, evidence: verdict ? verdict.evidence : 'none', known_gaps: verdict ? verdict.known_gaps : [], commit, open_issues: allReports.flatMap(r => r.open_issues) })

  if (!commit || !commit.committed) log(`${p.title}: commit failed, the next phase's commit will carry this work: ${commit ? commit.notes : 'commit agent died'}`)
  else if (!commit.pushed) log(`${p.title}: committed ${commit.sha} but the push failed: ${commit.notes}`)
}

return { completed: history.map(h => ({ phase: h.phase, provisional: h.provisional, open_failures: h.open_failures, commit: h.commit, known_gaps: h.known_gaps, evidence: h.evidence })) }
