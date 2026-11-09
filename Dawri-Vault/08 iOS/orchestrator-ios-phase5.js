export const meta = {
  name: 'dawri-ios-phase5-resume',
  description: 'Resume Dawri iOS Phase 5 at T4-integrate-ship, then review, commit and build log entry on build/dawri-ios. No Hugging Face or API usage.',
  whenToUse: 'Finish the paused Dawri iOS build from Phase 5 T4',
  phases: [
    { title: 'Phase 5: Clinic server and ship-ready', detail: 'T4 integrator live (T1-T3 saved), review rounds, commit' },
  ],
}

const ROOT = '/Users/jaberal-boenain/Desktop/Dawri'
const BRANCH = 'build/dawri-ios'
const BRIEF = 'Dawri-Vault/08 iOS/iOS Brief.md'
const LOG_NOTE = 'Dawri-Vault/08 iOS/iOS Build Log.md'
const RDIR = 'Dawri-Vault/08 iOS/phase5-reports'
const MAX_ROUNDS = 4
const DATE = args.date
const P = 'Phase 5: Clinic server and ship-ready'

const NO_CREDIT = `ABSOLUTE RULE FROM THE OWNER: nothing may touch the Hugging Face account or any API usage. Never read or print .env. Never send a request to any *.hf.space, *.huggingface.co, hf.co or model provider host, not even a health check. Never run hf. Never redeploy. Any backend process or Python importing backend.* must run with HF_TOKEN= blank (start servers only through ios/Tools/clinic-server.sh), and you must confirm /api/health says ai_mode simulated before using a server. Do not spend credits by any route.`

const POWER = `Power note: the Mac is on battery (about 74%) with caffeinate running from the main session. Before any long UI test run, check pmset -g batt and pmset -g log for sleep, and wrap long runs in caffeinate -i. If a UI test fails with "Timed out while synthesizing event", a signal term, or a gap that matches a sleep or CoreSimulatorService restart in the logs, it is environmental: rerun just those tests and report both runs honestly. Never touch the owner's iPhone Air simulator F7E60EDF, the iPhone 17 C72FD56D, or the physical iPhone. The extra simulator "Dawri Map" FC231CFD is not to be used.`

const IDENTITY = `You are the ORCHESTRATOR of the Dawri iOS build, the boss of every agent on it.
The vault at ${ROOT}/Dawri-Vault is your brain. "${BRIEF}" is the authority for this app: read it first and in full. Then read "Dawri-Vault/07 Build/Build Decisions.md", then "${LOG_NOTE}" for what earlier phases did, then "Dawri-Vault/08 iOS/iOS Design.md", and whichever notes and code bear on this phase.
This is a resumed run. Phases 1 to 4 are approved (47c8458, a58b63b, 42e6e73, 7fe835f). Phase 5 builders T1, T2 and T3 finished in an earlier session, and T4 was stopped mid-run. All of that is in WIP commit 68a1ced. T4 has now been re-run in this session.
The owner is away and cannot be asked anything. Decide using the vault. Never touch the main branch or real data. Main moved with teammates' commits; this branch starts at bb37797, so compare backend and frontend against bb37797, not main.
${NO_CREDIT}
${POWER}`

const PLAN = args.plan
const SAVED = ['T1-remote-core', 'T2-harden-docs-sign', 'T3-app-server-mode'].map(id => ({
  id, status: 'done',
  what_changed: `Finished in an earlier session. Full report (what changed, test evidence, open issues) in ${ROOT}/${RDIR}/p5-report-${id}.json. Treat it as claims, not facts.`,
  test_evidence: `See ${RDIR}/p5-report-${id}.json`, open_issues: [`See ${RDIR}/p5-report-${id}.json`],
}))

const REPORT_SCHEMA = { type: 'object', properties: {
  id: { type: 'string' },
  status: { type: 'string', enum: ['done', 'partial', 'blocked'] },
  what_changed: { type: 'string' }, test_evidence: { type: 'string' },
  open_issues: { type: 'array', items: { type: 'string' } },
}, required: ['id', 'status', 'what_changed', 'test_evidence', 'open_issues'] }
const TASK_SCHEMA = { type: 'object', properties: {
  id: { type: 'string' }, title: { type: 'string' },
  owned_paths: { type: 'array', items: { type: 'string' } },
  brief: { type: 'string' },
  vault_notes: { type: 'array', items: { type: 'string' } },
}, required: ['id', 'title', 'owned_paths', 'brief', 'vault_notes'] }
const VERDICT_SCHEMA = { type: 'object', properties: {
  approved: { type: 'boolean' }, evidence: { type: 'string' },
  failed: { type: 'array', items: { type: 'string' } },
  known_gaps: { type: 'array', items: { type: 'string' } },
  fix_waves: { type: 'array', items: { type: 'object', properties: { tasks: { type: 'array', items: TASK_SCHEMA } }, required: ['tasks'] } },
}, required: ['approved', 'evidence', 'failed', 'known_gaps', 'fix_waves'] }
const COMMIT_SCHEMA = { type: 'object', properties: {
  committed: { type: 'boolean' }, pushed: { type: 'boolean' }, sha: { type: 'string' }, notes: { type: 'string' },
}, required: ['committed', 'pushed', 'sha', 'notes'] }

function runTask(task, extra) {
  return agent(`You are a builder on the Dawri iOS team and you report to the orchestrator. Working directory: ${ROOT}. Branch: ${BRANCH}.
Read "${BRIEF}" first, it is the authority. Then read these: ${task.vault_notes.join(', ')}.
${NO_CREDIT}
${POWER}

Task ${task.id}: ${task.title}
${task.brief}
${extra || ''}

You own only these paths: ${task.owned_paths.join(', ')}. Other agents may be editing other paths at the same time, so do not edit outside yours. If you need a change elsewhere, record it in open_issues.

Phase acceptance criteria, for context:
${PLAN.acceptance.map(a => '- ' + a).join('\n')}

Rules:
- Follow "Parallel build rules" in the brief: your own --scratch-path and -derivedDataPath, outside ios/. Use the "Dawri Build" simulator only if this brief names you its owner for this wave.
- Use .venv/bin/python for Python. Stop any server you start.
- Run what you built and report real results. Never claim a check you did not run. Do not stub a feature and call it done.
- Use the skills that genuinely help, especially anthropic-skills:write-swift for Swift and anthropic-skills:apple-design for interaction.
- Do not commit, push, or switch branches. The orchestrator handles git after approval.`,
    { label: `build:${task.id}`, phase: P, schema: REPORT_SCHEMA })
}

async function runWaves(waves, extraFor) {
  const reports = []
  for (const wave of waves) {
    const results = await parallel(wave.tasks.map(t => () => runTask(t, extraFor ? extraFor(t) : '')))
    wave.tasks.forEach((t, i) => reports.push(results[i] || { id: t.id, status: 'blocked', what_changed: 'Agent died without a report', test_evidence: 'none', open_issues: ['No report returned'] }))
  }
  return reports
}

phase(P)
log('T1, T2 and T3 use their saved reports. T4-integrate-ship runs live.')

const T4 = PLAN.t4
const T4_EXTRA = `

RESUME NOTE: an earlier T4 run was stopped partway through, and whatever it had edited is in WIP commit 68a1ced. Start by checking the tree: git status, git show --stat 68a1ced, and grep -rn 'TODO(T4)' ios/. Do not assume any check passed before; run every one yourself in this run.
The finished wave 1 and 2 builders' full reports are in ${RDIR}/p5-report-T1-remote-core.json, p5-report-T2-harden-docs-sign.json and p5-report-T3-app-server-mode.json. Read all three in full first. Their open_issues are handed to you, among them: the URLSession hit in harvest_plugin.py and README prose, the ChatModelTests /api/asr comment allowlist, the chat scroll after a Dynamic Type change in ChatScreen, the demoClinicEnabled match in the Release grep, the cold first-launch shot in shoot.sh (settings-local-ar-light shows S01), the 401 GET /api/visits from LiveTicketCoordinator when signed out on a server, and the 15 README TODO(T4) markers. Resolve each one or state plainly why it stays.
You are the ONLY owner of the Dawri Build simulator in this wave.`

let waves = [{ tasks: [T4] }]
let prevFailures = []
let verdict = null
const allReports = [...SAVED]

for (let round = 1; round <= MAX_ROUNDS; round++) {
  log(`Round ${round} of ${MAX_ROUNDS}: building`)
  const reports = await runWaves(waves, t => (t.id === T4.id ? T4_EXTRA : `\nEarlier Phase 5 reports are in ${RDIR}/ (p5-report-*.json) and the T4 integrator report is given to the reviewer. Read what bears on your task.`))
  allReports.push(...reports)

  verdict = await agent(`${IDENTITY}

Review ${P}, round ${round} of ${MAX_ROUNDS}. Goal: RemoteClinicService with REST and SSE plus polling fallback against the existing API, Settings mode switch and server field, both credit guards from iOS Brief with tests, ATS local networking only, and the shared contract suite passing against a real local backend in simulated mode. Prove live: a patient in the simulator gets a ticket and staff API calls move it with the app updating without refresh. XCUITests walk Fatima, Ahmed and Ravi in AR and EN in On this phone mode. A Release device build compiles and signs with generic/platform=iOS and team 4Y4YQ65B78, never installed. No Hugging Face host or model call in ios/ except inside the refusal guards and their tests. ios/README.md per the definition of done, honest about what only a real phone can prove. Every line of Definition of done in iOS Brief is checked and reported.

The saved Phase 5 plan is ${RDIR}/phase5-plan.json.

Acceptance checks:
${PLAN.acceptance.map(a => '- ' + a).join('\n')}

Failures from the previous round, to re-verify first:
${prevFailures.length ? prevFailures.map(a => '- ' + a).join('\n') : '- none (this is the first Phase 5 review)'}

Builder reports. Treat these as claims, not facts:
${JSON.stringify(allReports)}

Verify independently: read the code, run the tests and the app yourself with your own derived data path, take simulator screenshots on "Dawri Build" and look at them, and exercise each check. Use git diff 7fe835f to see everything Phase 5 changed. You must run swift test, the contract suite, the full UI suite, server-proof.sh, shoot.sh, the Release and device builds and no-credit-check.sh yourself; do not rely on builder numbers. Compare the result with "${BRIEF}" and try to find where it falls short.

Review discipline. Judge guarantees, not strings.
1. Re-verify every failure from any previous round, then every acceptance check, then the full test suite for this phase.
2. An item belongs in failed only if you can show a concrete break of a red line, a hard rule, the brief, or a demo patient's path. A skipped or disabled safety golden is always a failure. A route that lets a listed red-flag cue reach a ticket is always a failure. Any path to a Hugging Face host or any spending of credits is always a failure.
3. Anything that only real hardware can prove goes in known_gaps as a phone test item, never in failed, provided the logic is tested with a fake and the feature is really implemented. A stub is a failure. A device-signing failure that is purely an Apple account issue, quoted exactly, with the unsigned build succeeding, goes in known_gaps.
4. Do not add work outside this phase's goal.

approved=true only if every acceptance check passes on your own evidence. If not approved, give fix_waves that address every failure, with the same no-overlap rule (at most one Dawri Build owner per wave, named in its brief), and do not fix anything yourself.

If approved, and only then, you may edit one file: "${LOG_NOTE}". Append a section "## Phase 5: Clinic server and ship-ready (approved on review round ${round} of ${MAX_ROUNDS}, ${DATE})" with the plan, what was built (T1 to T4 and any fix waves), the pause and resume of T4, your evidence, the signing outcome and the known gaps as a phone test list. Then append a short "## Build complete" section: all five phases approved with their commits (Phase 5's commit is the next one on the branch), and a pointer to ios/README.md for the phone test. Leave the Dawri Build simulator shut down and stop any server you started (pgrep -fl uvicorn empty).`,
    { label: `orchestrator:review-${round}`, phase: P, schema: VERDICT_SCHEMA })

  if (!verdict) { verdict = { approved: false, evidence: 'Review agent failed', failed: ['Review agent failed'], known_gaps: [], fix_waves: [] }; break }
  log(`Round ${round} ${verdict.approved ? 'APPROVED' : 'rejected, ' + verdict.failed.length + ' failures'}`)
  if (verdict.approved) break
  if (!verdict.fix_waves.length) break
  waves = verdict.fix_waves
  prevFailures = verdict.failed
}

const provisional = !verdict || !verdict.approved
if (provisional) {
  const open = verdict ? verdict.failed : ['Review agent failed']
  log(`Not approved after the last round, ${open.length} open failures. Logging them.`)
  await agent(`Edit only "${ROOT}/${LOG_NOTE}". Append one section titled "## ${P}: PROVISIONAL, not approved (${DATE})". State that this phase did not pass review, and list every item below word for word under "Open failures", then every item under "Known gaps".

Open failures:
${open.map(a => '- ' + a).join('\n')}

Known gaps:
${(verdict ? verdict.known_gaps : []).map(a => '- ' + a).join('\n')}`,
    { label: 'orchestrator:log-provisional', phase: P, effort: 'low' })
}

const commit = await agent(`Commit and push the ${provisional ? 'provisional, not fully approved' : 'approved'} work for "${P}". Working directory: ${ROOT}. Do exactly this and nothing more.

1. Confirm the current branch is ${BRANCH}. If not, stop and report it. Never touch main.
2. Stage only the paths from this list that exist and have changes: ios "Dawri-Vault/08 iOS" .gitignore .dockerignore. If backend or frontend show changes, do not stage them and list them in your notes.
3. Check the staged diff for secrets and junk: hf_ tokens, API keys, .env files, .venv, node_modules, .build, DerivedData, xcuserdata, .swiftpm, database files, xcresult bundles, screenshots or videos. If you find junk, unstage it. If you find a real secret, stop and report without committing.
4. Commit with a concise message saying Phase 5 (clinic server and ship-ready) is ${provisional ? 'built but not approved' : 'approved and the iOS build is complete'}, summarising what T4 and any fix rounds did${provisional ? ', with a subject line starting "PROVISIONAL, not approved:" and a body saying the open failures are in the iOS Build Log' : ''}, ending with this exact trailer:
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
5. Run: git push -u origin ${BRANCH}. Never force push. If there is nothing to commit, report that.

Report the short sha, and whether the commit and push succeeded.`,
  { label: 'orchestrator:commit', phase: P, effort: 'low', schema: COMMIT_SCHEMA })

return { provisional, open_failures: provisional && verdict ? verdict.failed : [], known_gaps: verdict ? verdict.known_gaps : [], evidence: verdict ? verdict.evidence : 'none', commit, reports: allReports.slice(3) }
