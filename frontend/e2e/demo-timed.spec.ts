import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import {
  agree,
  AHMED_WORDS,
  confirmSummary,
  expect,
  expectNotReloaded,
  FATIMA_ANSWERS,
  FATIMA_WORDS,
  fillVitals,
  liveConsole,
  login,
  markThePage,
  NURSE,
  queueRow,
  RAVI_WORDS,
  send,
  startCheckIn,
  streamOpen,
  test,
  ticketRows,
  TRIAGE_COUNTER,
  visitIdOf,
  watchForFaults,
  type Page,
} from './fixtures'

/*
 * The Demo Script as a run in real time: phone at 390, nurse at 1440, display as a second tab.
 * Build Decisions overrides apply: "Check-in valid for 45 minutes", and the labelled skip after
 * handoff confirm. The sentence is typed, the script's own voice fallback, since simulated mode
 * has no ASR.
 *
 * This proves the script fits at the assumed pace below. It does not prove that a person
 * rehearsed it: no one has. Each beat runs its app steps, then waits until its elapsed time
 * reaches its pace, so a slow app overruns the budgets and a fast one cannot fake a short run.
 */

/** Seconds a presenter takes at each beat. */
const PACE = {
  hook: 15,
  loginAndProfile: 5,
  startWhoAgree: 3,
  sentence: 5,
  eachAnswer: 4,
  summaryRead: 4,
  confirm: 1,
  mapAndPick: 6,
  reserved: 2,
  imHereAndPause: 5,
  callNext: 2,
  intakeRead: 4,
  vitals: 12,
  draftRead: 5,
  handoffConfirm: 2,
  phoneUpdate: 3,
  fastForward: 2,
  completeRead: 5,
  ahmed: 15,
  ravi: 15,
  close: 25,
}

const BUDGET_S = { fatima: 90, ahmed: 25, ravi: 25, whole: 180 }
const PAGE_TIMEOUT_MS = 240_000

type Part = 'hook' | 'fatima' | 'ahmed' | 'ravi' | 'close'

interface Row {
  part: Part
  beat: string
  pace_s: number
  app_s: number
  elapsed_s: number
}

const seconds = (ms: number) => Math.round(ms / 10) / 100

class Run {
  rows: Row[] = []
  private started = Date.now()

  constructor(private clock: Page) {}

  async beat(part: Part, beat: string, pace: number, steps: () => Promise<void> = async () => {}) {
    const start = Date.now()
    await steps()
    const app = Date.now() - start
    if (app < pace * 1_000) await this.clock.waitForTimeout(pace * 1_000 - app)
    this.rows.push({
      part,
      beat,
      pace_s: pace,
      app_s: seconds(app),
      elapsed_s: seconds(Date.now() - start),
    })
  }

  spent(part: Part) {
    return this.rows.filter((row) => row.part === part).reduce((sum, row) => sum + row.elapsed_s, 0)
  }

  get total() {
    return seconds(Date.now() - this.started)
  }

  table() {
    const cell = (value: string | number, width: number) => String(value).padEnd(width)
    const lines = this.rows.map(
      ({ part, beat, pace_s, app_s, elapsed_s }) =>
        `${cell(part, 8)}${cell(beat, 22)}${cell(pace_s, 7)}${cell(app_s, 8)}${elapsed_s}`,
    )
    return [`${cell('part', 8)}${cell('beat', 22)}${cell('pace', 7)}${cell('app', 8)}elapsed`, ...lines]
  }
}

test('the Demo Script fits its budgets at the assumed pace, in real time', async ({
  page: phone,
  windows,
}) => {
  test.setTimeout(PAGE_TIMEOUT_MS)
  const faults: string[] = []

  // Ready before the talk starts, so none of this is on the clock.
  const nurse = await windows.staff(NURSE)
  await liveConsole(nurse)
  const display = await nurse.context().newPage()
  await display.goto('/staff/display')
  await expect(display.getByTestId('display-root')).toHaveAttribute('data-live', 'live')
  watchForFaults(faults, phone, nurse, display)
  await nurse.bringToFront()

  const run = new Run(nurse)
  let visitId = ''

  await run.beat('hook', 'hook', PACE.hook)

  await run.beat('fatima', 'login and profile', PACE.loginAndProfile, async () => {
    await login(phone, 'P001')
    await expect(phone.locator('main')).toContainText('مركز الوكرة الصحي')
    await expect(phone.locator('main')).toContainText('البنسلين')
  })
  await run.beat('fatima', 'start, who, agree', PACE.startWhoAgree, async () => {
    await startCheckIn(phone)
    await phone.getByTestId('who-P001').click()
    await agree(phone)
    visitId = visitIdOf(phone)
  })
  await run.beat('fatima', 'sentence', PACE.sentence, () => send(phone, FATIMA_WORDS))
  for (const [index, answer] of FATIMA_ANSWERS.entries()) {
    await run.beat('fatima', `answer ${index + 1}`, PACE.eachAnswer, async () => {
      if ((await phone.getByTestId('chat-summary').count()) === 0) await send(phone, answer)
    })
  }
  await run.beat('fatima', 'summary read', PACE.summaryRead, async () => {
    await expect(phone.getByTestId('chat-summary-text')).toContainText('3 أيام')
  })
  await run.beat('fatima', 'confirm', PACE.confirm, () => confirmSummary(phone))
  await run.beat('fatima', 'map and pick', PACE.mapAndPick, async () => {
    const pin = (id: string) => phone.locator(`[data-testid=centre-pin][data-centre-id=${id}]`)
    await expect(pin('C-WAKRA')).toContainText('12')
    await expect(pin('C-AIRPORT')).toContainText(/3\d/)
    await phone.getByTestId('check-in-here').click()
    await phone.waitForURL('**/reserved')
  })
  await run.beat('fatima', 'reserved', PACE.reserved, async () => {
    await expect(phone.locator('main')).toContainText('تسجيل الوصول صالح لمدة 45 دقيقة')
    await expect(phone.getByTestId('ticket-number')).toHaveCount(0)
  })
  await markThePage(phone)
  await markThePage(nurse)
  await markThePage(display)
  await run.beat('fatima', "I'm here and pause", PACE.imHereAndPause, async () => {
    await phone.getByTestId('im-here').click()
    await expect(phone.getByTestId('ticket-number')).toHaveText('T-014')
    await expect(queueRow(nurse, 'T-014')).toBeVisible()
    await streamOpen(phone)
  })
  await run.beat('fatima', 'call next', PACE.callNext, async () => {
    await nurse.getByTestId('call-next').click()
    await nurse.waitForURL(`**/staff/nurse/${visitId}`)
    await expect(phone.getByTestId('ticket-called')).toBeVisible()
    await expect(
      display.locator(`[data-counter="${TRIAGE_COUNTER}"]`).getByTestId('display-number'),
    ).toHaveText('T-014')
  })
  await run.beat('fatima', 'intake read', PACE.intakeRead, async () => {
    await expect(nurse.getByTestId('intake-allergies').getByTestId('allergy-flag')).toHaveText(
      'penicillin',
    )
    await expect(nurse.getByTestId('intake-reason')).not.toHaveText('—')
  })
  await run.beat('fatima', 'vitals', PACE.vitals, async () => {
    await fillVitals(nurse)
    await nurse.getByTestId('urgency-routine').check()
    await nurse.getByTestId('vitals-submit').click()
    await nurse.waitForURL(`**/staff/nurse/${visitId}/handoff`)
  })
  await run.beat('fatima', 'draft read', PACE.draftRead, async () => {
    await expect(nurse.getByTestId('handoff-text')).toBeVisible()
    await expect(nurse.getByTestId('handoff-source')).toHaveAttribute('data-source', 'simulated')
  })
  await run.beat('fatima', 'handoff confirm', PACE.handoffConfirm, async () => {
    await nurse.getByTestId('handoff-confirm').click()
    await expect(nurse.getByTestId('sent-number')).toHaveText('D-GP-023')
  })
  await run.beat('fatima', 'phone update', PACE.phoneUpdate, async () => {
    await expect(phone.getByTestId('ticket-number')).toHaveText('D-GP-023')
  })
  await run.beat('fatima', 'skip', PACE.fastForward, async () => {
    await expect(nurse.getByTestId('fast-forward')).toContainText('Demo')
    await nurse.getByTestId('fast-forward').click()
    await expect(nurse.getByTestId('visit-complete')).toBeVisible()
  })
  await run.beat('fatima', 'S11 read', PACE.completeRead, async () => {
    await phone.waitForURL('**/complete')
    const medicine = phone.getByTestId('medicine').first()
    await expect(medicine).toContainText(/[؀-ۿ]/)
    await expect(medicine).not.toContainText(/[A-Za-z]/)
  })
  await expectNotReloaded(phone)
  await expectNotReloaded(nurse)
  await expectNotReloaded(display)

  const ahmedPhone = await windows.phone()
  const raviPhone = await windows.phone()
  watchForFaults(faults, ahmedPhone, raviPhone)

  await run.beat('ahmed', 'refill', PACE.ahmed, async () => {
    await login(ahmedPhone, 'P002')
    await startCheckIn(ahmedPhone)
    await agree(ahmedPhone)
    const ahmedVisit = visitIdOf(ahmedPhone)
    await send(ahmedPhone, AHMED_WORDS)
    await ahmedPhone.waitForURL('**/refill')
    await expect(ahmedPhone.getByTestId('refill-message')).toBeVisible()
    expect(ticketRows(ahmedVisit)).toBe(0)
  })
  await run.beat('ravi', 'emergency', PACE.ravi, async () => {
    await login(raviPhone, 'P003')
    await startCheckIn(raviPhone, 'en')
    await agree(raviPhone, 'en')
    const raviVisit = visitIdOf(raviPhone)
    await send(raviPhone, RAVI_WORDS)
    await raviPhone.waitForURL('**/emergency')
    await expect(raviPhone.getByTestId('emergency-call')).toHaveAttribute('href', 'tel:999')
    await expect(raviPhone.getByTestId('emergency-nearest')).toContainText('Hamad General Hospital')
    expect(ticketRows(raviVisit)).toBe(0)
  })
  await run.beat('close', 'close', PACE.close)

  const total = run.total
  const summary = {
    note: 'Proves the script fits at the assumed pace. No person rehearsed it.',
    fatima_s: seconds(run.spent('fatima') * 1_000),
    ahmed_s: seconds(run.spent('ahmed') * 1_000),
    ravi_s: seconds(run.spent('ravi') * 1_000),
    total_s: total,
    budgets_s: BUDGET_S,
    beats: run.rows,
  }
  const out = process.env.DAWRI_E2E_OUTPUT
    ? join(process.env.DAWRI_E2E_OUTPUT, 'demo-timed.json')
    : test.info().outputPath('demo-timed.json')
  mkdirSync(dirname(out), { recursive: true })
  writeFileSync(out, JSON.stringify(summary, null, 2))
  console.log(
    [
      ...run.table(),
      `fatima ${summary.fatima_s} s, ahmed ${summary.ahmed_s} s, ravi ${summary.ravi_s} s, total ${total} s`,
      `written to ${out}`,
    ].join('\n'),
  )

  expect(summary.fatima_s).toBeLessThanOrEqual(BUDGET_S.fatima)
  expect(summary.ahmed_s).toBeLessThanOrEqual(BUDGET_S.ahmed)
  expect(summary.ravi_s).toBeLessThanOrEqual(BUDGET_S.ravi)
  expect(total).toBeLessThanOrEqual(BUDGET_S.whole)
  expect(faults).toEqual([])
})
