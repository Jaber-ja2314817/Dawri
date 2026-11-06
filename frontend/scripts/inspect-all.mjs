#!/usr/bin/env node
/*
 * Runs the app-screens inspector over every patient screen and every staff screen (T01 to T09),
 * each in its real state, in Arabic and English. It builds nothing and starts nothing. First:
 *
 *   cd frontend && npm run build:inspect
 *   DAWRI_DB=/tmp/x/dawri.db SIMULATE_LOAD=1 HF_TOKEN= DAWRI_STATIC_DIR=frontend/.inspect-dist \
 *     .venv/bin/uvicorn backend.main:app --port 8143          (from the repo root)
 *   DAWRI_DB=/tmp/x/dawri.db npm run inspect                  (from frontend/)
 *
 * DAWRI_DB must be the server's own file: only a backdated row can show an expired check-in.
 * SIMULATE_LOAD=1 is what puts the grey Simulated rows on T02 and T-014 on a fresh reset.
 * DAWRI_INSPECT_BASE overrides the address. `-- --only s05,t03` inspects just those names.
 * Output lands in .taste-skill/inspect/<name> at the repo root, which git ignores.
 */
import { execFileSync, spawn } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  AHMED_WORDS,
  DemoApi,
  DESK,
  DOCTOR,
  DOCTOR_COUNTER,
  NURSE,
  PHARMACIST,
  PHARMACY_COUNTER,
  QID,
  RAVI_WORDS,
  TRIAGE_COUNTER,
} from './lib/demo-api.mjs'

const SKILL =
  process.env.DAWRI_TASTE_SKILL ??
  '/Users/jaberal-boenain/.claude/skills/synced/ddd8c2b9-2481-43cd-aa18-1f6974f19786_999def73-b1a3-414d-af0d-3cd25cf671ac/design-taste-frontend'
const INSPECT = join(SKILL, 'scripts/inspect.mjs')
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const BASE = (process.env.DAWRI_INSPECT_BASE ?? 'http://127.0.0.1:8143').replace(/\/$/, '')
const DB = process.env.DAWRI_DB
const AT_ONCE = 3
const SALEM_QID = 'DEMO-10006'
const MARIAM_QID = 'DEMO-10005'
const WALK_IN_COMPLAINT = 'sore throat since yesterday'

const onlyAt = process.argv.indexOf('--only')
const only = onlyAt === -1 ? null : process.argv[onlyAt + 1].split(',')

const WIDTHS = '1440,390'
const TV_WIDTHS = '1920,1440,390'

// The only allowances, and each stands on one screen: see Build Decisions.
const ALLOW = { s10: ['kpi-size'], s06: ['colour-sprawl'], t08: ['kpi-size'] }

const results = []

function backdate(visitId) {
  const past = new Date(Date.now() - 46 * 60_000).toISOString().replace('Z', '+00:00')
  const script = [
    'import sqlite3, sys',
    'conn = sqlite3.connect(sys.argv[1])',
    "conn.execute(\"UPDATE ticket SET reserved_at = ? WHERE visit_id = ? AND state = 'reserved'\", sys.argv[2:4])",
    'conn.commit()',
  ].join('\n')
  execFileSync(join(ROOT, '.venv/bin/python'), ['-c', script, DB, past, visitId])
}

function urlFor(screen) {
  const query = new URLSearchParams({ lang: screen.lang })
  if (screen.token) query.set('inspect_token', screen.token)
  if (screen.staffToken) query.set('inspect_staff_token', screen.staffToken)
  const joiner = screen.path.includes('?') ? '&' : '?'
  return `${BASE}${screen.path}${joiner}${query}`
}

function inspectOne(screen) {
  const family = screen.name.split('-')[0]
  const allow = ALLOW[family] ?? []
  const out = `.taste-skill/inspect/${screen.name}`
  const widths = screen.widths ?? WIDTHS
  const args = [INSPECT, urlFor(screen), '--app', '--widths', widths, '--out', out]
  if (allow.length) args.push('--allow', allow.join(','))
  return new Promise((done) => {
    const child = spawn('node', args, { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'] })
    let stderr = ''
    child.stdout.resume()
    child.stderr.on('data', (chunk) => {
      stderr += chunk
    })
    child.on('close', (code) => {
      const reportPath = join(ROOT, out, 'report.json')
      const report = existsSync(reportPath) ? JSON.parse(readFileSync(reportPath, 'utf8')) : null
      const findings = report?.findings ?? []
      const fails = findings.filter((finding) => finding.level === 'FAIL')
      const warns = findings.filter((finding) => finding.level === 'WARN')
      const broken = report === null || (code !== 0 && fails.length === 0)
      results.push({ screen, code, fails, warns, broken, stderr })
      console.log(
        `${broken ? 'BROKEN' : fails.length ? 'FAIL' : 'ok'.padEnd(4)} ${screen.name.padEnd(24)} ${fails.length} FAIL, ${warns.length} WARN`,
      )
      for (const finding of [...fails, ...warns]) {
        const widths = [finding.width, ...(finding.alsoAt ?? [])].join('+')
        console.log(`       ${finding.level} [${finding.id}] @${widths} ${finding.message}`)
      }
      if (broken) console.log(stderr.slice(0, 600))
      done()
    })
  })
}

async function run(screens) {
  const wanted = screens.filter(
    (screen) => only === null || only.some((name) => screen.name.startsWith(name)),
  )
  const queue = [...wanted]
  const worker = async () => {
    for (let screen = queue.shift(); screen; screen = queue.shift()) await inspectOne(screen)
  }
  await Promise.all(Array.from({ length: AT_ONCE }, worker))
}

/** The same path in both languages. */
const both = (name, path, token) =>
  ['ar', 'en'].map((lang) => ({ name: `${name}-${lang}`, path, token, lang }))

/** The same path in both languages, signed in as staff. */
const staffBoth = (name, path, staffToken, extra = {}) =>
  ['ar', 'en'].map((lang) => ({ name: `${name}-${lang}`, path, staffToken, lang, ...extra }))

/** T07's ticket slip exists only after a tap, so no URL reaches it and it is not listed. */
async function staffScreens(api) {
  await api.reset()
  const nurse = await api.staffToken(NURSE)
  const doctor = await api.staffToken(DOCTOR)
  const pharmacist = await api.staffToken(PHARMACIST)
  const desk = await api.staffToken(DESK)

  await run([
    ...both('t01', '/staff/login'),
    ...staffBoth('t02-seeded', '/staff/nurse', nurse),
    ...staffBoth('t05-empty', '/staff/doctor', doctor),
    ...staffBoth('t06-empty', '/staff/pharmacy', pharmacist),
  ])

  const fatima = await api.arrivedVisit(QID.fatima)
  const walkIn = await api.walkIn(SALEM_QID, WALK_IN_COMPLAINT)
  await run(staffBoth('t07', '/staff/desk', desk))

  await api.callNext()
  await run([
    ...staffBoth('t02-called', '/staff/nurse', nurse),
    ...staffBoth('t03', `/staff/nurse/${fatima.visitId}`, nurse),
  ])

  await api.vitals(fatima.visitId)
  const handoffPath = `/staff/nurse/${fatima.visitId}/handoff`
  await run(staffBoth('t04', handoffPath, nurse))

  await api.handoff(fatima.visitId)
  await run(staffBoth('t04-confirmed', handoffPath, nurse))

  await api.callNext(DOCTOR_COUNTER, DOCTOR)
  await run(staffBoth('t05-card', '/staff/doctor', doctor))

  const prescription = await api.prescription(fatima.visitId)
  await api.asStaff(DOCTOR, 'POST', `/api/visits/${fatima.visitId}/consult/done`, { prescription })
  await api.callNext(PHARMACY_COUNTER, PHARMACIST)
  await run(staffBoth('t06-card', '/staff/pharmacy', pharmacist))

  // A busy room: one number up at each stage, and something to count.
  await api.callNext()
  await api.vitals(walkIn.visit_id)
  await api.handoff(walkIn.visit_id)
  await api.callNext(DOCTOR_COUNTER, DOCTOR)
  await api.walkIn(MARIAM_QID, WALK_IN_COMPLAINT)
  await api.callNext()
  await api.walkIn(QID.ahmed, WALK_IN_COMPLAINT)
  await run([
    ...staffBoth('t08', '/staff/display', nurse, { widths: TV_WIDTHS }),
    ...staffBoth('t09', '/staff/dashboard', nurse),
  ])

  await api.reset()
  const denied = await api.arrivedVisit(QID.fatima, 'no chest pain, I have a cough', [
    '3 days',
    '5',
    'no',
    'no',
    'no',
  ])
  await api.callNext()
  await run(staffBoth('t03-denied', `/staff/nurse/${denied.visitId}`, nurse))
}

async function main() {
  if (!existsSync(INSPECT)) throw new Error(`no inspector at ${INSPECT}`)
  if (!DB || !existsSync(DB)) throw new Error('set DAWRI_DB to the running server\'s database file')
  const api = new DemoApi(BASE)
  try {
    await api.request('GET', '/api/health')
  } catch {
    throw new Error(`no server at ${BASE}: see the top of this file`)
  }
  const index = await fetch(`${BASE}/`).then((response) => response.text())
  if (!index.includes('assets/')) throw new Error('that server has no built frontend')

  await api.reset()
  const fatima = (await api.patient(QID.fatima)).token
  const ravi = (await api.patient(QID.ravi)).token
  const ahmed = (await api.patient(QID.ahmed)).token

  await run([
    ...both('s01', '/'),
    ...both('s02', '/login'),
    ...both('s03-none', '/home', fatima),
    ...both('s04', '/check-in/who', fatima),
    ...both('consent', '/check-in/consent?for=P001', fatima),
    ...both('s12-empty', '/history', fatima),
  ])

  // The chat is real, so each language shows its own conversation.
  const fatimaVisit = await api.newVisit(fatima)
  await api.say(fatima, fatimaVisit, 'عندي حرارة وكحة من ثلاث أيام')
  await api.say(fatima, fatimaVisit, 'خمسة')
  const raviVisit = await api.newVisit(ravi)
  await api.say(ravi, raviVisit, 'I have a cough and a fever since yesterday')
  await api.say(ravi, raviVisit, 'about 4')
  await run([
    { name: 's05-mid-ar', path: `/visit/${fatimaVisit}/chat`, token: fatima, lang: 'ar' },
    { name: 's05-mid-en', path: `/visit/${raviVisit}/chat`, token: ravi, lang: 'en' },
  ])

  await api.say(fatima, fatimaVisit, 'لا')
  await api.say(fatima, fatimaVisit, 'لا')
  await api.say(ravi, raviVisit, 'no')
  await api.say(ravi, raviVisit, 'no')
  await run([
    { name: 's05-summary-ar', path: `/visit/${fatimaVisit}/chat`, token: fatima, lang: 'ar' },
    { name: 's05-summary-en', path: `/visit/${raviVisit}/chat`, token: ravi, lang: 'en' },
  ])

  const refill = await api.newVisit(ahmed)
  await api.say(ahmed, refill, AHMED_WORDS)
  await run(both('s07', `/visit/${refill}/refill`, ahmed))

  await api.say(ravi, raviVisit, RAVI_WORDS)
  const ahmedEmergency = await api.newVisit(ahmed)
  await api.say(ahmed, ahmedEmergency, 'عندي ألم في الصدر')
  await run([
    { name: 's06-ar', path: `/visit/${ahmedEmergency}/emergency`, token: ahmed, lang: 'ar' },
    { name: 's06-en', path: `/visit/${raviVisit}/emergency`, token: ravi, lang: 'en' },
  ])

  await api.confirm(fatima, fatimaVisit)
  await run(both('s08', `/visit/${fatimaVisit}/centre`, fatima))

  await api.reserve(fatima, fatimaVisit)
  await run([
    ...both('s09-reserved', `/visit/${fatimaVisit}/reserved`, fatima),
    ...both('s03-active', '/home', fatima),
  ])

  backdate(fatimaVisit)
  await run(both('s09-expired', `/visit/${fatimaVisit}/reserved`, fatima))

  await api.reserve(fatima, fatimaVisit)
  await api.arrive(fatima, fatimaVisit)
  await run(both('s10-active', `/visit/${fatimaVisit}/ticket`, fatima))

  await api.callNext(TRIAGE_COUNTER)
  await run(both('s10-called', `/visit/${fatimaVisit}/ticket`, fatima))

  await api.vitals(fatimaVisit)
  await api.handoff(fatimaVisit)
  await api.consultDone(fatimaVisit)
  await run(both('s10-pharmacy', `/visit/${fatimaVisit}/ticket`, fatima))

  await api.dispensed(fatimaVisit)
  await run([
    ...both('s11', `/visit/${fatimaVisit}/complete`, fatima),
    ...both('s12-rows', '/history', fatima),
  ])

  // Last: on a dependent, so nothing above depends on it.
  const selfHarmAr = await api.newVisit(fatima, 'P005')
  await api.say(fatima, selfHarmAr, 'أبي أأذي نفسي')
  const selfHarmEn = await api.newVisit(fatima, 'P004')
  await api.say(fatima, selfHarmEn, 'I want to end my life')
  await run([
    { name: 's06-selfharm-ar', path: `/visit/${selfHarmAr}/emergency`, token: fatima, lang: 'ar' },
    { name: 's06-selfharm-en', path: `/visit/${selfHarmEn}/emergency`, token: fatima, lang: 'en' },
  ])

  await staffScreens(api)
  await api.reset()

  const failed = results.filter((result) => result.fails.length > 0 || result.broken)
  const warnings = results.reduce((count, result) => count + result.warns.length, 0)
  console.log(`\n${results.length} screens, ${failed.length} failing, ${warnings} WARN`)
  if (failed.length > 0) process.exitCode = 1
}

main().catch((cause) => {
  console.error(cause.message)
  process.exitCode = 2
})
