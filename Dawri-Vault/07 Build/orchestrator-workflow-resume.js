export const meta = {
  name: 'dawri-orchestrated-build-resume',
  description: 'Resume the Dawri build: review and finish Phase 4, then build Phases 5 and 6, approving each against the vault and pushing to build/dawri-app',
  whenToUse: 'Overnight phased build of the Dawri app, run by a vault-grounded orchestrator',
  phases: [
    { title: 'Phase 4: Patient app', detail: 'Mobile-first React PWA, AR/EN, chat, voice, map, tickets' },
    { title: 'Phase 5: Staff consoles', detail: 'Nurse, doctor, pharmacy, front desk, display, dashboard' },
    { title: 'Phase 6: Integration and ship-ready', detail: 'E2E on the three demo patients, Docker image, README' },
  ],
}

const ROOT = '/Users/jaberal-boenain/Desktop/Dawri'
const BRANCH = 'build/dawri-app'
const MAX_ROUNDS = 4
const PHASE2 = 'Phase 2: AI layer'
const roundLimit = (title) => (title === PHASE2 ? 9 : MAX_ROUNDS)
const shownMax = (title, round) => {
  if (title === 'Phase 1: Foundation') return 4
  if (title !== PHASE2) return MAX_ROUNDS
  return round <= 4 ? 4 : (round <= 6 ? 6 : (round <= 8 ? 8 : 9))
}
const FINAL_ROUNDS_NOTE = `

Final Phase 2 rounds. This phase has had many reviews and this is the last extension. Check the four failures from the previous review and everything that passed before. The class of cues split across turns is in scope only where a question the receptionist scripts, or a listed cue in plain wording, produces the split. Other splits go in known_gaps as clinician review items, because the nurse now sees the patient's exact words (see "Nurse backstop" in Build Decisions). Red lines stay absolute.`
const STRUCTURAL_NOTE = `

ORCHESTRATOR ADDITION, this outranks anything above that conflicts with it. Read the section "Model text gate" in Build Decisions and implement it in this task where your owned paths allow. The filters stay as a second layer, but the guarantee must come from the gate, so a new disease or drug word cannot reach the patient by being missing from a list. Tests must prove the gate by shape: several unlisted invented words such as 'You have zorblax.' or 'zorblax is best.' must be rejected without being added to any list.`
const REVIEW_DISCIPLINE = `

Review discipline for this round. Judge guarantees, not strings.
1. Re-verify every failure from the previous review, then run your acceptance checks and the full suite.
2. A new item belongs in failed only if you can show a concrete path that breaks a guarantee: a red line, a hard rule, a vault requirement of this phase, or a Demo Script step. Red lines stay absolute: a structural route to a ticket with a listed red-flag cue present, or model text that diagnoses, prescribes or names a queue number reaching a patient, is always a failure.
3. Build Decisions says the red-flag list is a starter list awaiting clinician review. An unlisted synonym, or unusual phrasing that does not defeat a structural guarantee, goes in known_gaps as a clinician review item, not in failed.
4. Do not add work outside this phase's goal.`
const reviewDiscipline = (title, round) => (title === 'Phase 1: Foundation' || (title === PHASE2 && round <= 4)) ? '' : (REVIEW_DISCIPLINE + ((title === PHASE2 && round >= 7) ? FINAL_ROUNDS_NOTE : ''))

const IDENTITY = `You are the ORCHESTRATOR of the Dawri build, the boss of every agent on it.
The vault at ${ROOT}/Dawri-Vault is your brain: it is the only source of truth for what Dawri must be.
Read "Dawri-Vault/07 Build/Build Decisions.md" first: it overrides older notes where they disagree.
Then read "Dawri-Vault/07 Build/Orchestrator Log.md" for what earlier phases did, and whichever notes bear on this phase
(Feature Matrix, Patient Journey, Screens, Staff Console, AI Receptionist Design, Safety Guardrails, Data Model, API,
Mock Health System, Queue Engine, Stack, Demo Script, Risks & Red Lines, 01 Enhanced Prompt).
The owner's standing instruction is to keep building until the main build is finished and not to stop for decisions. Decide using the vault. Never touch Hugging Face setup, the main branch, or real data.`

const ALL_PHASES = [
  { title: 'Phase 1: Foundation', goal: `Repo scaffold under backend/, requirements.txt, SQLite schema and db layer, seeds (patients, dependents, centres with the exact coordinates from Build Decisions, staff, counters, drugs), mock_health, demo auth, deterministic queue engine and adapters/queue_base.py, event bus for SSE, pytest suite for ticket lifecycle, ordering, priority, numbering, expiry, simulated-ticket rule. Features F01 backend, F02, F06, F07 core.` },
  { title: 'Phase 2: AI layer', goal: `backend/ai: red-flag rules with normalisation and negation, llm and asr adapter with real and simulated modes and per-turn fallback, simulated AR/EN receptionist, intake schema validation with retry and fallback, banned-output filter, handoff draft, doctor suggestion rules, plain-language medicines, refill detection, health ai_mode. Tests must cover the vault's acceptance sentences in AR and EN, negation edge cases, and the real path through a fake client. Features F03, F04, F05, F09, F15 and F13 backend.` },
  { title: 'Phase 3: Full API', goal: `backend/main.py and routers implementing every route in API.md plus those added by Build Decisions, SSE streams, centres with wait estimates and suggestion, reserve, arrive with geofence and door code, staff flows, walk-in, fast-forward, reset, stats, SIMULATE_LOAD simulator, static SPA serving. An API-level test walks all three demo patients end to end, and proves nurse edit reaches the doctor, no ticket on red flag, and threadpool safety of SSE.` },
  { title: 'Phase 4: Patient app', goal: `frontend/ with Vite, React, Tailwind, router, i18n AR/EN with RTL, PWA manifest, api and SSE client, screens S01 to S12 including consent, dependents, chat, voice with WAV conversion and transcript confirm, emergency, refill, Leaflet map with list fallback, reserved countdown, live ticket, visit complete, history. Follow the design direction in Build Decisions. Use the anthropic-skills:design-taste-frontend skill's app-screens rules and run its inspector at 390px and desktop. Features F01, F11, F13, F14, F17, F18.` },
  { title: 'Phase 5: Staff consoles', goal: `In the same frontend, /staff screens T01 to T09: login, nurse queue, intake card with vitals and urgency, handoff confirm, doctor queue with prescription picker and allergy warning, pharmacy, front desk walk-in, waiting-room display with AR/EN and chime, dashboard, demo reset and fast-forward. Live via SSE, ai_mode always visible. Same design rules and inspector. Features F08, F10, F16, F20, F21.` },
  { title: 'Phase 6: Integration and ship-ready', goal: `Headless Playwright using the installed Chrome (channel chrome), kept as frontend/e2e, drives the real production build served by FastAPI, in Arabic and English, through Fatima, Ahmed and Ravi, with patient and staff in two browser contexts proving live updates without refresh; timed run of the Demo Script. Multi-stage Dockerfile builds and the container runs as non-root and serves the app on 7860, tested locally with docker. .env.example. README as a Hugging Face Space card and a setup guide, honest about what is simulated and untested, listing exactly the steps to switch on HF later. If the Docker daemon is not up, run open -a Docker and wait for it. Do not push any image or deploy anywhere. Fix every bug found. Every acceptance test in 01 Enhanced Prompt is checked and reported.` },
]

const PHASES = ALL_PHASES.slice(3)
PHASES[0].resume = true

const HANDOVER = `${ROOT}/Dawri-Vault/07 Build/phase4-handover.json`
const RESUME_PLAN = {
  summary: 'Phase 4 was built before the pause (commit cb61c24, WIP). It is being reviewed, not rebuilt.',
  waves: [],
  acceptance: [`Every check in the "acceptance" array of ${HANDOVER}`],
}
const RESUME_NOTE = `

This phase was paused and is being resumed in a new session. The frontend already exists in commit cb61c24 and was never reviewed. Do not rebuild it. Read ${HANDOVER} in full: "acceptance" holds the checks set at planning, all of them binding, and "reports" holds the T1 to T4 builder reports, which are claims. T1 and T4 reported partial, and only because of two stale backend tests. Those tests were widened before this review, so test_api_visits.py is allowed in the diff alongside the files the checks name. Note that the check limiting backend/ changes predates that edit. Go through every open_issues entry in the reports and decide each one: fix, or known gap. Also confirm the known gap from Phase 3: the frontend must not show a chat box on a completed visit. Frontend unit tests, npm run e2e and npm run inspect were not rerun at the pause, so run them yourself, using the commands the checks and scripts describe.`

const TASK_SCHEMA = {
  type: 'object',
  properties: {
    id: { type: 'string' },
    title: { type: 'string' },
    owned_paths: { type: 'array', items: { type: 'string' } },
    brief: { type: 'string' },
    vault_notes: { type: 'array', items: { type: 'string' } },
  },
  required: ['id', 'title', 'owned_paths', 'brief', 'vault_notes'],
}
const PLAN_SCHEMA = {
  type: 'object',
  properties: {
    summary: { type: 'string' },
    waves: { type: 'array', minItems: 1, items: { type: 'object', properties: { tasks: { type: 'array', minItems: 1, items: TASK_SCHEMA } }, required: ['tasks'] } },
    acceptance: { type: 'array', items: { type: 'string' } },
  },
  required: ['summary', 'waves', 'acceptance'],
}
const REPORT_SCHEMA = {
  type: 'object',
  properties: {
    id: { type: 'string' },
    status: { type: 'string', enum: ['done', 'partial', 'blocked'] },
    what_changed: { type: 'string' },
    test_evidence: { type: 'string' },
    open_issues: { type: 'array', items: { type: 'string' } },
  },
  required: ['id', 'status', 'what_changed', 'test_evidence', 'open_issues'],
}
const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    approved: { type: 'boolean' },
    evidence: { type: 'string' },
    failed: { type: 'array', items: { type: 'string' } },
    known_gaps: { type: 'array', items: { type: 'string' } },
    fix_waves: { type: 'array', items: { type: 'object', properties: { tasks: { type: 'array', items: TASK_SCHEMA } }, required: ['tasks'] } },
  },
  required: ['approved', 'evidence', 'failed', 'known_gaps', 'fix_waves'],
}
const COMMIT_SCHEMA = {
  type: 'object',
  properties: {
    committed: { type: 'boolean' },
    pushed: { type: 'boolean' },
    sha: { type: 'string' },
    notes: { type: 'string' },
  },
  required: ['committed', 'pushed', 'sha', 'notes'],
}

function runTask(task, phaseTitle, acceptance, extra) {
  return agent(`You are a builder on the Dawri team and you report to the orchestrator. Working directory: ${ROOT}. Branch: ${BRANCH}.
Read "Dawri-Vault/07 Build/Build Decisions.md" first, it overrides older notes. Then read these vault notes: ${task.vault_notes.join(', ')}.

Task ${task.id}: ${task.title}
${task.brief}${extra}

You own only these paths: ${task.owned_paths.join(', ')}. Other agents may be editing other paths at the same time, so do not edit outside yours. If you need a change elsewhere, record it in open_issues.

Phase acceptance criteria, for context:
${acceptance.map(a => '- ' + a).join('\n')}

Rules:
- Use .venv/bin/python and .venv/bin/pip for Python. If a server is needed, pick a free port above 8100, use a temporary DAWRI_DB under the scratchpad or a temp folder, and stop it before you finish.
- Run what you built and report real results. Never claim a check you did not run. Do not stub a feature and call it done.
- You may use any listed skill that genuinely helps.
- Do not commit, push, or switch branches. The orchestrator handles git after approval.
- Do not install hf, create a Space, or set up any real token.`,
    { label: `build:${task.id}`, phase: phaseTitle, schema: REPORT_SCHEMA })
}

async function runWaves(waves, phaseTitle, acceptance, extra) {
  const reports = []
  for (const wave of waves) {
    const results = await parallel(wave.tasks.map(t => () => runTask(t, phaseTitle, acceptance, extra)))
    wave.tasks.forEach((t, i) => {
      reports.push(results[i] || { id: t.id, status: 'blocked', what_changed: 'Agent died without a report', test_evidence: 'none', open_issues: ['No report returned'] })
    })
  }
  return reports
}

const history = []
let halted = null

for (const p of PHASES) {
  phase(p.title)
  log(`${p.title}: orchestrator is planning from the vault`)

  const plan = p.resume ? RESUME_PLAN : await agent(`${IDENTITY}

Plan ${p.title}. Goal: ${p.goal}

Phases 1 to 3 are approved and pushed; the Orchestrator Log has their evidence and known gaps, including work left for the screens. Earlier phases in this run: ${JSON.stringify(history)}

Inspect the actual repo before planning. Split the work dynamically into waves. Tasks in a wave run in parallel in one shared working tree, so their owned_paths must not overlap and a task must not depend on another in its wave. Any file that several tasks need, such as a router or an app entry point, belongs to exactly one task. Use as few agents as gets the job done well: usually 2 to 4 tasks, one if the work is tightly coupled. Give each task a full brief with file names, interfaces and contracts, because the builder sees nothing but your brief and the vault.

Write acceptance as concrete checks you can run yourself, each traced to a vault note. Plan only; do not build.`,
    { label: `orchestrator:plan`, phase: p.title, schema: PLAN_SCHEMA })

  if (!plan) { halted = { phase: p.title, reason: 'Orchestrator planning agent failed' }; break }
  log(`${p.title}: ${plan.summary}`)

  let waves = plan.waves
  let verdict = null
  const allReports = []

  for (let round = 1; round <= roundLimit(p.title); round++) {
    const reports = (p.resume && round === 1) ? [] : await runWaves(waves, p.title, plan.acceptance, p.resume ? `\n\nThe phase's acceptance checks are in ${HANDOVER}.` : '')
    allReports.push(...reports)

    verdict = await agent(`${IDENTITY}

Review ${p.title}, round ${round} of ${shownMax(p.title, round)}. Goal: ${p.goal}

Acceptance checks you set:
${plan.acceptance.map(a => '- ' + a).join('\n')}

Builder reports. Treat these as claims, not facts:
${JSON.stringify(reports)}${p.resume ? RESUME_NOTE : ''}

Verify independently: read the code, run the tests and the app yourself, and exercise each check. Compare the result with the vault and Build Decisions, and try to find where it falls short. Red lines and hard rules are never waivable. Anything required by the vault for this phase that is stubbed, faked or untested is a failure, except the live HF calls, which Build Decisions says cannot be tested tonight.

approved=true only if every acceptance check passes on your own evidence. Minor polish that no vault requirement demands may go in known_gaps. If not approved, give fix_waves that address every failure, using the same no-overlap rule, and do not fix anything yourself.

If approved, and only then, you may edit these two files: append a section to "Dawri-Vault/07 Build/Orchestrator Log.md" with the plan, what was built, the evidence and known gaps; and tick the finished features in "Dawri-Vault/03 Product/Feature Matrix.md" by changing the status cell to ☑. Tick only what you verified. Stop any server you started.${reviewDiscipline(p.title, round)}`,
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
    log(`${p.title}: not approved after the last round, ${open.length} open failures. The owner told the build not to stop, so these are logged and the build continues.`)
    await agent(`Append one section to "${ROOT}/Dawri-Vault/07 Build/Orchestrator Log.md" and edit nothing else. Title: "${p.title}: PROVISIONAL, not approved". State that the owner instructed the build to keep going until finished, that this phase did not pass review, and list every item below word for word under "Open failures", then every item under "Known gaps".

Open failures:
${open.map(a => '- ' + a).join('\n')}

Known gaps:
${(verdict ? verdict.known_gaps : []).map(a => '- ' + a).join('\n')}`,
      { label: `orchestrator:log-provisional`, phase: p.title, effort: 'low' })
  }

  const commit = await agent(`Commit and push the ${provisional ? "provisional, not fully approved" : "approved"} work for "${p.title}". Working directory: ${ROOT}. Do exactly this and nothing more.

1. Confirm the current branch is ${BRANCH}. If not, stop and report it. Never touch main.
2. Stage only the paths from this list that exist: backend frontend Dockerfile README.md .env.example .gitignore requirements.txt${p.title === 'Phase 1: Foundation' ? '' : ' pytest.ini'} "Dawri-Vault/07 Build" "Dawri-Vault/03 Product/Feature Matrix.md". Do not stage anything else in Dawri-Vault/.obsidian.
3. Check the staged diff for secrets: search for hf_ tokens, api keys, .env files, .venv, node_modules, database files. If you find any, unstage them, and if it is a real secret, stop and report without committing.
4. Commit with a concise message describing what this phase built${provisional ? ', with a subject line starting "PROVISIONAL, not approved:" and a body saying the open failures are in Dawri-Vault/07 Build/Orchestrator Log.md' : ''}, ending with this exact trailer:
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
5. Run: git push -u origin ${BRANCH}. Never force push. If there is nothing to commit, report that.

Report the short sha, and whether the commit and push succeeded.`,
    { label: `orchestrator:commit`, phase: p.title, effort: 'low', schema: COMMIT_SCHEMA })

  history.push({ phase: p.title, provisional, open_failures: provisional && verdict ? verdict.failed : [], summary: plan.summary, evidence: verdict.evidence, known_gaps: verdict.known_gaps, commit, open_issues: allReports.flatMap(r => r.open_issues) })

  if (!commit || !commit.committed) log(`${p.title}: commit failed, the next phase's commit will carry this work: ${commit ? commit.notes : 'commit agent died'}`)
  if (commit && !commit.pushed) log(`${p.title}: committed ${commit.sha} but the push failed: ${commit.notes}`)
}

return { completed: history.map(h => ({ phase: h.phase, provisional: h.provisional, open_failures: h.open_failures, commit: h.commit, known_gaps: h.known_gaps })), halted }
