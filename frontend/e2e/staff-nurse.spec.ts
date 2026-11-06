import type { Browser, Page as PlaywrightPage } from '@playwright/test'
import {
  DemoApi,
  DOCTOR,
  DOCTOR_COUNTER,
  expect,
  expectNotReloaded,
  FATIMA_ANSWERS,
  FATIMA_WORDS,
  markThePage,
  NURSE,
  QID,
  say,
  sql,
  staffLogin,
  test,
  TRIAGE_COUNTER,
  type Page,
} from './fixtures'

const DESKTOP = { width: 1440, height: 900 }
const PHONE = { width: 390, height: 844 }
const MUTED = 'rgb(107, 107, 107)'
const EXPECT_BASE = process.env.DAWRI_E2E_BASE as string

test.use({ viewport: DESKTOP })

test.beforeEach(async ({ api }) => {
  await api.reset()
})

/* A nurse's steps, each through the screen. */

async function liveQueue(page: Page) {
  await staffLogin(page, NURSE)
  await expect(page.getByTestId('live-state')).toHaveAttribute('data-live', 'live')
}

async function callNext(page: Page, visitId: string) {
  await page.getByTestId('call-next').click()
  await page.waitForURL(`**/staff/nurse/${visitId}`)
  await expect(page.getByTestId('intake-card')).toBeVisible()
}

async function arrivedThenCalled(
  page: Page,
  api: DemoApi,
  qid = QID.fatima,
  words = FATIMA_WORDS,
  answers = FATIMA_ANSWERS,
) {
  const arrived = await api.arrivedVisit(qid, words, answers)
  await liveQueue(page)
  await callNext(page, arrived.visitId)
  return arrived
}

const fatimaAtTriage = (page: Page, api: DemoApi) => arrivedThenCalled(page, api)

async function fillVitals(page: Page) {
  await page.getByTestId('vital-bp_sys').fill('118')
  await page.getByTestId('vital-bp_dia').fill('76')
  await page.getByTestId('vital-hr').fill('88')
  await page.getByTestId('vital-temp_c').fill('38.2')
  await page.getByTestId('vital-spo2').fill('98')
  await page.getByTestId('vital-weight_kg').fill('62')
}

async function toHandoff(page: Page, visitId: string) {
  await fillVitals(page)
  await page.getByTestId('urgency-routine').check()
  await page.getByTestId('vitals-submit').click()
  await page.waitForURL(`**/staff/nurse/${visitId}/handoff`)
  await expect(page.getByTestId('handoff-text')).toBeVisible()
}

async function editIntakeField(page: Page, field: string, value: string) {
  await page.getByTestId('intake-edit').click()
  await page.getByTestId(`edit-${field}`).fill(value)
  await page.getByTestId('intake-save').click()
  await expect(page.getByTestId('intake-form')).toHaveCount(0)
}

const staffVisit = (api: DemoApi, visitId: string, staffId = NURSE) =>
  api.asStaff(staffId, 'GET', `/api/staff/visits/${visitId}`)

const queueNumbers = async (api: DemoApi, counter: string, staffId = NURSE) => {
  const queue = await api.asStaff(staffId, 'GET', `/api/counters/${counter}/queue`)
  return queue.tickets.map((ticket: { number: string }) => ticket.number) as string[]
}

/** The patient's own phone, signed in with the token from the set-up. */
async function phone(browser: Browser, token: string, path: string): Promise<PlaywrightPage> {
  const context = await browser.newContext({
    baseURL: EXPECT_BASE,
    viewport: PHONE,
    locale: 'en-GB',
    timezoneId: 'Asia/Qatar',
  })
  await context.addInitScript((value) => localStorage.setItem('dawri.token', value), token)
  const page = await context.newPage()
  await page.goto(path)
  return page
}

async function expectNoSideScroll(page: Page, where: string) {
  const widths = await page.evaluate(() => ({
    content: document.documentElement.scrollWidth,
    screen: window.innerWidth,
  }))
  expect(widths.content, where).toBeLessThanOrEqual(widths.screen)
}

test.describe('T02, the queue', () => {
  test('a ticket activated on a phone appears with no reload, beside 3 grey Simulated rows', async ({
    page,
    api,
  }) => {
    await liveQueue(page)
    await expect(page.locator('h1')).toHaveText('Triage 1')
    await markThePage(page)
    await expect(page.locator('[data-testid=queue-row]')).toHaveCount(3)

    const { number } = await api.arrivedVisit(QID.fatima)
    expect(number).toBe('T-014')
    const row = page.locator('[data-testid=queue-row][data-number="T-014"]')
    await expect(row).toBeVisible({ timeout: 1_500 })
    await expect(row).toContainText('Fatima')
    await expect(row).toHaveAttribute('data-simulated', 'false')
    await expectNotReloaded(page)

    const simulated = page.locator('[data-testid=queue-row][data-simulated=true]')
    await expect(simulated).toHaveCount(3)
    for (const one of await simulated.all()) {
      await expect(one).toContainText('Simulated')
      await expect(one).not.toContainText('Fatima')
      await expect(one.getByRole('link')).toHaveCount(0)
      await expect(one.getByRole('button')).toHaveCount(0)
      const number = await one.getByRole('cell').nth(1).evaluate((cell) => getComputedStyle(cell).color)
      expect(number).toBe(MUTED)
    }

    await simulated.first().click()
    await expect(page).toHaveURL(/\/staff\/nurse$/)
  })

  test('the subline counts the rows, and an Arabic console titles the counter in Arabic', async ({
    page,
    api,
  }) => {
    await api.arrivedVisit(QID.fatima)
    await liveQueue(page)
    await expect(page.getByTestId('queue-subline')).toContainText('4 waiting')
    const wait = (await api.asStaff(NURSE, 'GET', `/api/counters/${TRIAGE_COUNTER}/queue`)).wait
    await expect(page.getByTestId('queue-subline')).toContainText(`about ${wait.wait_min} min`)

    await page.getByTestId('language-toggle').click()
    await expect(page.locator('html')).toHaveAttribute('dir', 'rtl')
    await expect(page.locator('h1')).not.toHaveText('Triage 1')
    await expect(page.locator('h1')).toHaveText(/[؀-ۿ]/)
  })

  test('call next opens Fatima, calls no simulated patient, and names what a colleague handled', async ({
    page,
    api,
  }) => {
    const { visitId } = await arrivedThenCalled(page, api)
    await expect(page.getByTestId('banner-number')).toHaveText('T-014')
    await expect(page.getByTestId('patient-banner')).toContainText('Fatima')
    await expect(page.getByTestId('auto-completed')).toHaveText(
      'T-011, T-012, T-013 handled by a colleague on shift',
    )
    expect((await staffVisit(api, visitId)).ticket.state).toBe('called')

    await page.getByTestId('back-to-queue').click()
    await page.waitForURL('**/staff/nurse')
    const rows = page.locator('[data-testid=queue-row]')
    await expect(rows).toHaveCount(1)
    await expect(rows).toHaveAttribute('data-number', 'T-014')
    await expect(page.locator('[data-simulated=true]')).toHaveCount(0)

    const current = page.getByTestId('current-ticket')
    await expect(current).toContainText('T-014')
    await expect(current).toContainText('Fatima')
    await expect(page.getByTestId('call-next')).toHaveCount(0)
    await page.getByTestId('open-intake').click()
    await page.waitForURL(`**/staff/nurse/${visitId}`)
  })

  test('with only simulated tickets left, call next stays here and calls nobody', async ({ page }) => {
    await liveQueue(page)
    await expect(page.locator('[data-testid=queue-row]')).toHaveCount(3)
    await page.getByTestId('call-next').click()
    await expect(page.getByTestId('auto-completed')).toContainText('T-011')
    await expect(page.locator('[data-testid=queue-row]')).toHaveCount(2)
    await expect(page).toHaveURL(/\/staff\/nurse$/)
    await expect(page.getByTestId('at-counter')).toHaveCount(0)
    await expect(page.getByTestId('current-ticket')).toHaveCount(0)
  })

  test('counter_busy shows as a sentence', async ({ page, api }) => {
    await api.arrivedVisit(QID.fatima)
    await liveQueue(page)
    await page.route('**/call-next', (route) =>
      route.fulfill({ status: 409, json: { error: 'counter_busy', message: 'raw' } }),
    )
    await page.getByTestId('call-next').click()
    await expect(page.getByRole('alert')).toContainText(say('en', 'error.counter_busy'))
    await expect(page).toHaveURL(/\/staff\/nurse$/)
  })

  test('the empty queue keeps its frame, and the next arrival lands in it live', async ({
    page,
    api,
  }) => {
    await liveQueue(page)
    for (let left = 3; left > 0; left -= 1) {
      await expect(page.locator('[data-testid=queue-row]')).toHaveCount(left)
      await api.callNext()
    }
    await expect(page.getByTestId('queue-empty')).toBeVisible()
    await expect(page.getByTestId('queue-table').locator('thead')).toHaveCount(1)
    await expect(page.getByTestId('call-next')).toBeDisabled()
    await api.arrivedVisit(QID.fatima)
    await expect(page.locator('[data-testid=queue-row]')).toHaveCount(1, { timeout: 1_500 })
    await expect(page.getByTestId('call-next')).toBeEnabled()
  })
})

test.describe('T03, the intake card', () => {
  test('the penicillin allergy is flagged from the record', async ({ page, api }) => {
    await fatimaAtTriage(page, api)
    await expect(page.getByTestId('intake-card').getByTestId('allergy-flag')).toHaveText('penicillin')
    await expect(page.getByTestId('patient-banner').getByTestId('allergy-flag')).toHaveText(
      'penicillin',
    )
  })

  test('every turn shows byte for byte, also while editing and after the summary drops a detail', async ({
    page,
    api,
  }) => {
    const words = 'عِنْدِي حَرَارَة وكحة مع دم من ثلاث أيام'
    const { visitId } = await arrivedThenCalled(page, api, QID.fatima, words)
    const block = page.getByTestId('patient-words')
    const turns = (await staffVisit(api, visitId)).turns as { role: string; text: string }[]
    expect(turns.length).toBeGreaterThan(2)
    expect(turns.filter((turn) => turn.role === 'patient')[0].text).toBe(words)

    const expectEveryTurn = async () => {
      await expect(block).toBeVisible()
      const shown = block.getByTestId('turn')
      await expect(shown).toHaveCount(turns.length)
      for (const [index, turn] of turns.entries()) {
        await expect(shown.nth(index)).toHaveAttribute('data-role', turn.role)
        const text = shown.nth(index).locator('p')
        expect(await text.textContent()).toBe(turn.text)
        await expect(text).toHaveAttribute('dir', 'auto')
      }
    }

    await expectEveryTurn()
    expect(await block.textContent()).toContain(words)
    const colours = await block.locator('[data-testid=turn] p').evaluateAll((all) =>
      all.map((one) => getComputedStyle(one).color),
    )
    expect(new Set(colours).size).toBe(2)

    await page.getByTestId('intake-edit').click()
    await expect(page.getByTestId('intake-form')).toBeVisible()
    await expectEveryTurn()

    await page.getByTestId('edit-summary_for_nurse').fill('Fever only.')
    await page.getByTestId('intake-save').click()
    await expect(page.getByTestId('ai-summary')).toHaveText('Fever only.')
    await expect(page.getByTestId('edited-pill')).toHaveText('Edited by nurse')
    await expectEveryTurn()
  })

  test('a patient who said no chest pain reads as denied, in English', async ({ page, api }) => {
    await arrivedThenCalled(page, api, QID.fatima, 'no chest pain, I have a cough', [
      '3 days',
      '5',
      'no',
      'no',
      'no',
    ])
    await expect(page.getByTestId('denied')).toHaveText('Patient denied: chest pain')
    await expect(page.getByTestId('no-flags')).toHaveCount(0)
  })

  test('a patient who said no chest pain reads as denied, on an Arabic console', async ({
    page,
    api,
  }) => {
    await arrivedThenCalled(page, api, QID.fatima, 'ما عندي ألم في الصدر، عندي كحة', [
      'ثلاث أيام',
      'خمسة',
      'لا',
      'لا',
      'لا',
    ])
    await page.getByTestId('language-toggle').click()
    await expect(page.getByTestId('denied')).toHaveText('المريض نفى: ألم في الصدر')
  })

  test('nothing denied reads none detected, and a raised flag never does', async ({ page, api }) => {
    const { visitId } = await arrivedThenCalled(page, api)
    await expect(page.getByTestId('no-flags')).toHaveText('none detected')

    const stopped = await api.walkIn(QID.fatima, 'chest pain going to my left arm')
    expect(stopped.emergency).toBe(true)
    await page.reload()
    await expect(page.getByTestId('flags-raised')).toContainText('chest pain')
    await expect(page.getByTestId('no-flags')).toHaveCount(0)
    await expect(page.getByTestId('sent-to-ed')).toBeVisible()
    expect((await staffVisit(api, visitId)).red_flags_raised.length).toBeGreaterThan(0)
  })

  test('a missing value is a grey dash, and severity 0 prints as 0', async ({ page, api }) => {
    const { visitId } = await arrivedThenCalled(page, api)
    await editIntakeField(page, 'severity_0_10', '٠')
    await expect(page.getByTestId('intake-severity')).toHaveText('0/10')
    expect((await staffVisit(api, visitId)).intake.severity_0_10).toBe(0)

    await editIntakeField(page, 'duration', '')
    const dash = page.getByTestId('intake-duration')
    await expect(dash).toHaveText('—')
    expect(await dash.locator('span').evaluate((one) => getComputedStyle(one).color)).toBe(MUTED)
  })

  test('save sends only what changed, and a 422 shows in the form', async ({ page, api }) => {
    await fatimaAtTriage(page, api)
    const sent: unknown[] = []
    page.on('request', (request) => {
      if (request.method() === 'PUT') sent.push(request.postDataJSON())
    })
    await editIntakeField(page, 'chief_complaint', 'dry cough with fever')
    expect(sent).toEqual([{ json: { chief_complaint: 'dry cough with fever' } }])

    await page.getByTestId('intake-edit').click()
    await page.getByTestId('edit-chief_complaint').fill('')
    await page.getByTestId('intake-save').click()
    await expect(page.getByTestId('intake-form').getByRole('alert')).toHaveText(
      say('en', 'error.invalid_intake'),
    )
    await expect(page.getByTestId('intake-form')).toBeVisible()
    await page.getByTestId('intake-cancel').click()
    await expect(page.getByTestId('intake-reason')).toHaveText('dry cough with fever')

    await page.getByTestId('intake-edit').click()
    await expect(page.getByTestId('edit-service').locator('option')).toHaveCount(8)
    await page.getByTestId('edit-service').selectOption('dental')
    await page.getByTestId('intake-save').click()
    await expect(page.getByTestId('intake-service')).toHaveText(say('en', 'service.dental'))
  })

  test('the primary action stays disabled until the nurse chooses, and nothing is preselected', async ({
    page,
    api,
  }) => {
    const { visitId } = await fatimaAtTriage(page, api)
    await fillVitals(page)
    const primary = page.getByTestId('vitals-submit')
    await expect(primary).toBeDisabled()
    await expect(page.getByTestId('urgency-hint')).toBeVisible()
    for (const urgency of ['routine', 'soon', 'urgent']) {
      await expect(page.getByTestId(`urgency-${urgency}`)).not.toBeChecked()
    }
    await page.keyboard.press('Enter')
    expect((await staffVisit(api, visitId)).vitals).toBeNull()

    await page.getByTestId('urgency-soon').check()
    await expect(primary).toBeEnabled()
    await expect(primary).toHaveText('Confirm & generate handoff')
  })

  test('Arabic digits convert, an empty field is null, and an out-of-range value stays here', async ({
    page,
    api,
  }) => {
    const { visitId } = await fatimaAtTriage(page, api)
    await page.getByTestId('vital-bp_sys').fill('٩٠٠')
    await page.getByTestId('vital-hr').click()
    await expect(page.getByTestId('vitals-form')).toContainText('Enter 40 to 300.')

    await page.getByTestId('vital-bp_sys').fill('١١٨')
    await page.getByTestId('vital-temp_c').fill('٣٨٫٢')
    await page.getByTestId('urgency-routine').check()
    await page.getByTestId('vitals-submit').click()
    await page.waitForURL(`**/staff/nurse/${visitId}/handoff`)

    const { vitals } = await staffVisit(api, visitId)
    expect(vitals).toMatchObject({ bp_sys: 118, temp_c: 38.2, hr: null, urgency: 'routine' })
  })

  test('urgent needs a second tap, ends with no live ticket, and the phone reaches S06 live', async ({
    page,
    api,
    browser,
  }) => {
    const { visitId, token, number } = await fatimaAtTriage(page, api)
    const patient = await phone(browser, token, `/visit/${visitId}/ticket`)
    await expect(patient.getByTestId('ticket-card')).toHaveAttribute('data-live', 'live')
    await markThePage(patient)

    await page.getByTestId('urgency-urgent').check()
    const primary = page.getByTestId('vitals-submit')
    await expect(primary).toHaveText('Send to emergency')
    await primary.click()
    await expect(primary).toHaveText('Tap again to send to emergency')
    await expect(page.getByTestId('ed-warning')).toBeVisible()
    expect((await staffVisit(api, visitId)).status).toBe('in_triage')

    await primary.click()
    await expect(page.getByTestId('sent-to-ed')).toContainText('No ticket remains')
    const after = await staffVisit(api, visitId)
    expect(after.status).toBe('redirected_emergency')
    expect(after.ticket).toBeNull()
    expect(await queueNumbers(api, TRIAGE_COUNTER)).not.toContain(number)
    expect(
      sql("SELECT state FROM ticket WHERE visit_id = ? AND state IN ('active','called','serving')", visitId),
    ).toEqual([])

    await patient.waitForURL(`**/visit/${visitId}/emergency`, { timeout: 6_000 })
    await expectNotReloaded(patient)
    await patient.context().close()

    await page.getByTestId('ed-back').click()
    await page.waitForURL('**/staff/nurse')
  })

  test('changing the mind on urgent disarms the second tap', async ({ page, api }) => {
    const { visitId } = await fatimaAtTriage(page, api)
    await page.getByTestId('urgency-urgent').check()
    await page.getByTestId('vitals-submit').click()
    await expect(page.getByTestId('ed-cancel')).toBeVisible()
    await page.getByTestId('ed-cancel').click()
    await expect(page.getByTestId('vitals-submit')).toHaveText('Send to emergency')

    await page.getByTestId('vitals-submit').click()
    await page.getByTestId('urgency-soon').check()
    await expect(page.getByTestId('vitals-submit')).toHaveText('Confirm & generate handoff')
    expect((await staffVisit(api, visitId)).status).toBe('in_triage')
  })

  test('Not here puts the ticket back, and shows only while called', async ({ page, api }) => {
    const { visitId, number } = await fatimaAtTriage(page, api)
    await expect(page.getByTestId('not-here')).toHaveText('Not here')
    await page.getByTestId('not-here').click()
    await page.waitForURL('**/staff/nurse')

    const row = page.locator(`[data-testid=queue-row][data-number="${number}"]`)
    await expect(row).toHaveAttribute('data-state', 'active')
    await expect(page.getByTestId('at-counter')).toHaveCount(0)
    expect((await staffVisit(api, visitId)).ticket.state).toBe('active')

    await callNext(page, visitId)
    await expect(page.getByTestId('not-here')).toBeVisible()
    await page.getByTestId('patient-here').click()
    await expect(page.getByTestId('not-here')).toHaveCount(0)
    await expect(page.getByTestId('patient-here')).toHaveCount(0)
    expect((await staffVisit(api, visitId)).ticket.state).toBe('serving')
  })

  test('a ticket not yet called says so, and takes no vitals', async ({ page, api }) => {
    const { visitId } = await api.arrivedVisit(QID.fatima)
    await liveQueue(page)
    await page
      .locator('[data-testid=queue-row][data-number="T-014"]')
      .getByTestId('open-visit')
      .click()
    await page.waitForURL(`**/staff/nurse/${visitId}`)
    await expect(page.getByTestId('not-called')).toContainText('Call this patient first')
    await expect(page.getByTestId('vitals-submit')).toBeDisabled()
    await expect(page.getByTestId('vital-bp_sys')).toBeDisabled()
    await expect(page.getByTestId('not-here')).toHaveCount(0)
    await expect(page.getByTestId('patient-words')).toBeVisible()
  })

  test('a visit that left triage locks the form with a sentence and a way back', async ({
    page,
    api,
  }) => {
    const { visitId } = await fatimaAtTriage(page, api)
    await toHandoff(page, visitId)
    await page.getByTestId('handoff-confirm').click()
    await expect(page.getByTestId('handoff-sent')).toBeVisible()

    await page.goto(`/staff/nurse/${visitId}`)
    await expect(page.getByTestId('visit-locked')).toContainText(say('en', 'nurse.visit.locked'))
    await expect(page.getByTestId('vitals-submit')).toBeDisabled()
    await expect(page.getByTestId('intake-edit')).toHaveCount(0)
    await page.getByTestId('visit-locked').getByRole('link').click()
    await page.waitForURL('**/staff/nurse')
  })

  test('a reload keeps the edit, the words and the form on T03', async ({ page, api }) => {
    const { visitId } = await fatimaAtTriage(page, api)
    await editIntakeField(page, 'chief_complaint', 'fever, seen at triage')
    await page.reload()
    await expect(page.getByTestId('intake-reason')).toHaveText('fever, seen at triage')
    await expect(page.getByTestId('edited-pill')).toBeVisible()
    await expect(page.getByTestId('patient-words')).toContainText(FATIMA_WORDS)
    await expect(page.getByTestId('banner-number')).toHaveText('T-014')
    await expect(page).toHaveURL(new RegExp(`/staff/nurse/${visitId}$`))
    await expect(page.getByTestId('vitals-submit')).toBeDisabled()
  })

  test('a reset under an open T03 returns to the queue with a notice', async ({ page, api }) => {
    await fatimaAtTriage(page, api)
    await expect(page.getByTestId('live-state')).toHaveAttribute('data-live', 'live')
    await api.reset()
    await page.waitForURL('**/staff/nurse', { timeout: 6_000 })
    await expect(page.getByTestId('staff-notice')).toHaveText(say('en', 'nurse.visit.gone'))
    await expect(page.locator('[data-testid=queue-row]')).toHaveCount(3)
  })
})

test.describe('T04, the handoff', () => {
  test('edit the complaint, re-draft, edit the draft, confirm: the doctor reads both edits', async ({
    page,
    api,
  }) => {
    const { visitId } = await fatimaAtTriage(page, api)
    await toHandoff(page, visitId)
    await expect(page.getByTestId('handoff-text')).not.toContainText('wheeze since this morning')

    await page.getByTestId('back-to-intake').click()
    await page.waitForURL(`**/staff/nurse/${visitId}`)
    await editIntakeField(page, 'chief_complaint', 'wheeze since this morning')
    await expect(page.getByTestId('draft-cleared')).toBeVisible()
    expect(sql('SELECT COUNT(*) FROM handoff WHERE visit_id = ?', visitId)).toEqual([[0]])

    await page.getByTestId('to-handoff').click()
    await page.waitForURL(`**/staff/nurse/${visitId}/handoff`)
    const box = page.getByTestId('handoff-text')
    await expect(box).toBeVisible()
    await expect(box).toHaveAttribute('dir', 'ltr')
    const draft = await box.inputValue()
    expect(draft).toContain('wheeze since this morning')
    const lines = draft.split('\n').length
    expect(lines).toBeGreaterThanOrEqual(3)
    expect(lines).toBeLessThanOrEqual(5)

    const finalText = `${draft}\nNurse note: seen walking well.`
    await box.fill(finalText)
    await page.getByTestId('handoff-confirm').click()
    await expect(page.getByTestId('handoff-sent')).toBeVisible()

    const seen = await staffVisit(api, visitId, DOCTOR)
    expect(seen.intake.chief_complaint).toBe('wheeze since this morning')
    expect(seen.handoff.final_text).toBe(finalText)
  })

  test('nothing reaches a doctor before Confirm, and the nurse can pick another doctor', async ({
    page,
    api,
  }) => {
    const { visitId } = await fatimaAtTriage(page, api)
    await toHandoff(page, visitId)

    const options = page.getByTestId('doctor-option')
    const count = await options.count()
    expect(count).toBeGreaterThan(1)
    await expect(options.first().locator('input')).toBeChecked()
    await expect(options.first().getByTestId('doctor-reason')).not.toBeEmpty()

    const before = await staffVisit(api, visitId)
    expect(before.status).toBe('in_triage')
    expect(before.handoff.confirmed_by).toBeNull()
    expect(await queueNumbers(api, DOCTOR_COUNTER, DOCTOR)).toEqual([])

    const other = await options.nth(1).getAttribute('data-doctor')
    await options.nth(1).locator('input').check()
    await page.getByTestId('handoff-confirm').click()
    await expect(page.getByTestId('sent-number')).toHaveText(/^D-GP-\d+$/)

    const after = await staffVisit(api, visitId)
    expect(after.status).toBe('in_doctor')
    expect(after.handoff.chosen_doctor_id).toBe(other)
    expect(after.handoff.suggested_doctor_id).not.toBe(other)
    const counter = sql('SELECT id FROM counter WHERE staff_id = ?', other as string)[0][0]
    expect(after.ticket.counter_id).toBe(counter)
  })

  test('a slow draft shows a skeleton the size of the text', async ({ page, api }) => {
    await fatimaAtTriage(page, api)
    await page.route('**/handoff/draft', async (route) => {
      await new Promise((resolve) => setTimeout(resolve, 700))
      await route.fallback()
    })
    await fillVitals(page)
    await page.getByTestId('urgency-routine').check()
    await page.getByTestId('vitals-submit').click()
    const skeleton = page.getByTestId('handoff-skeleton').locator('[aria-hidden=true]')
    await expect(skeleton).toBeVisible()
    const shell = await skeleton.boundingBox()
    const box = page.getByTestId('handoff-text')
    await expect(box).toBeVisible()
    const real = await box.boundingBox()
    expect(Math.abs((shell?.height ?? 0) - (real?.height ?? 0))).toBeLessThanOrEqual(2)
    expect(Math.abs((shell?.width ?? 0) - (real?.width ?? 0))).toBeLessThanOrEqual(2)
  })

  test('the draft is labelled for what it is', async ({ page, api }) => {
    const { visitId } = await fatimaAtTriage(page, api)
    await toHandoff(page, visitId)
    const source = page.getByTestId('handoff-source')
    await expect(source).toHaveAttribute('data-source', 'simulated')
    await expect(source).toHaveText('Scripted draft, not from a model')

    await page.route('**/handoff/draft', async (route) => {
      const response = await route.fetch()
      await route.fulfill({ response, json: { ...(await response.json()), source: 'model' } })
    })
    await page.reload()
    await expect(source).toHaveAttribute('data-source', 'model')
    await expect(source).toHaveText('Draft from the model')
  })

  test('the Arabic reading is read-only and says it does not follow edits', async ({
    page,
    api,
  }) => {
    const { visitId } = await fatimaAtTriage(page, api)
    await toHandoff(page, visitId)
    const arabic = page.getByTestId('handoff-arabic')
    await arabic.locator('summary').click()
    await expect(arabic).toContainText(say('en', 'nurse.handoff.arabicNote'))
    const text = page.getByTestId('handoff-text-ar')
    await expect(text).toContainText('فاطمة')
    await expect(arabic.locator('textarea')).toHaveCount(0)
    const before = await text.textContent()
    await page.getByTestId('handoff-text').fill('Edited by the nurse.')
    expect(await text.textContent()).toBe(before)
  })

  test('confirming over a cleared draft re-drafts, says so, and keeps the nurse text', async ({
    page,
    api,
  }) => {
    const { visitId } = await fatimaAtTriage(page, api)
    await toHandoff(page, visitId)
    const mine = 'My own careful summary for the doctor.'
    await page.getByTestId('handoff-text').fill(mine)

    await api.asStaff(NURSE, 'PUT', `/api/visits/${visitId}/intake`, {
      json: { chief_complaint: 'changed in another tab' },
    })

    await page.getByTestId('handoff-confirm').click()
    await expect(page.getByTestId('handoff-redrafted')).toHaveText(
      say('en', 'nurse.handoff.redrafted'),
    )
    await expect(page.getByTestId('handoff-text')).toHaveValue(/changed in another tab/)
    await expect(page.getByTestId('handoff-kept')).toContainText(mine)
    const held = await staffVisit(api, visitId)
    expect(held.status).toBe('in_triage')
    expect(held.handoff.final_text).toBeNull()

    await page.getByTestId('use-kept').click()
    await expect(page.getByTestId('handoff-text')).toHaveValue(mine)
    await page.getByTestId('handoff-confirm').click()
    await expect(page.getByTestId('handoff-sent')).toBeVisible()
    expect((await staffVisit(api, visitId)).handoff.final_text).toBe(mine)
  })

  test('a blank summary cannot be sent', async ({ page, api }) => {
    const { visitId } = await fatimaAtTriage(page, api)
    await toHandoff(page, visitId)
    await page.getByTestId('handoff-text').fill('   ')
    await expect(page.getByTestId('handoff-confirm')).toBeDisabled()
    await expect(page.getByTestId('handoff-unsent')).toHaveText(say('en', 'nurse.handoff.emptyText'))
  })

  test('with no vitals, T04 sends the nurse back and posts no draft', async ({ page, api }) => {
    const { visitId } = await fatimaAtTriage(page, api)
    const drafts: string[] = []
    page.on('request', (request) => {
      if (request.url().endsWith('/handoff/draft')) drafts.push(request.url())
    })
    await page.goto(`/staff/nurse/${visitId}/handoff`)
    await expect(page.getByTestId('vitals-first')).toContainText('Record the vitals')
    expect(drafts).toEqual([])
  })

  test('the draft posts once on mount', async ({ page, api }) => {
    const { visitId } = await fatimaAtTriage(page, api)
    const drafts: string[] = []
    page.on('request', (request) => {
      if (request.url().endsWith('/handoff/draft')) drafts.push(request.url())
    })
    await toHandoff(page, visitId)
    await page.waitForTimeout(300)
    expect(drafts).toHaveLength(1)
  })

  test('after confirm the number, doctor and room show, and a reload keeps them with no new draft', async ({
    page,
    api,
  }) => {
    const { visitId } = await fatimaAtTriage(page, api)
    await toHandoff(page, visitId)
    await page.getByTestId(`doctor-${DOCTOR}`).check()
    await page.getByTestId('handoff-confirm').click()

    const number = page.getByTestId('sent-number')
    await expect(number).toHaveText('D-GP-023')
    expect(await number.evaluate((one) => getComputedStyle(one).color)).toBe('rgb(29, 95, 191)')
    await expect(page.getByTestId('sent-doctor')).toHaveText('Dr. Noor Al-Demo')
    await expect(page.getByTestId('sent-room')).toHaveText('Room 4')

    const drafts: string[] = []
    page.on('request', (request) => {
      if (request.url().endsWith('/handoff/draft')) drafts.push(request.url())
    })
    await page.reload()
    await expect(number).toHaveText('D-GP-023')
    await expect(page.getByTestId('sent-doctor')).toHaveText('Dr. Noor Al-Demo')
    await expect(page.getByTestId('sent-room')).toHaveText('Room 4')
    await expect(page.getByTestId('handoff-final-text')).not.toBeEmpty()
    await expect(page.getByTestId('handoff-text')).toHaveCount(0)
    expect(drafts).toEqual([])

    await page.getByTestId('next-patient').click()
    await page.waitForURL('**/staff/nurse')
  })

  test('fast-forward completes through the engine and the phone reaches S11 live', async ({
    page,
    api,
    browser,
  }) => {
    const { visitId, token } = await fatimaAtTriage(page, api)
    const patient = await phone(browser, token, `/visit/${visitId}/ticket`)
    await expect(patient.getByTestId('ticket-card')).toHaveAttribute('data-live', 'live')
    await markThePage(patient)

    await toHandoff(page, visitId)
    await page.getByTestId(`doctor-${DOCTOR}`).check()
    await page.getByTestId('handoff-confirm').click()
    const button = page.getByTestId('fast-forward')
    await expect(button).toHaveText('Demo: skip to visit complete')
    await button.click()

    await expect(page.getByTestId('visit-complete')).toContainText('Visit complete')
    expect((await staffVisit(api, visitId)).status).toBe('completed')
    expect(
      sql("SELECT COUNT(*) FROM event WHERE visit_id = ? AND type = 'demo.fast_forward'", visitId),
    ).toEqual([[1]])

    await patient.waitForURL(`**/visit/${visitId}/complete`, { timeout: 6_000 })
    await expectNotReloaded(patient)
    await patient.context().close()

    await page.reload()
    await expect(page.getByTestId('visit-complete')).toBeVisible()
    await expect(page.getByTestId('fast-forward')).toHaveCount(0)
  })

  test('fast-forward with a real patient ahead shows the refusal and changes nothing', async ({
    page,
    api,
  }) => {
    const ahead = await api.arrivedVisit(QID.ahmed)
    await api.callNext()
    await api.vitals(ahead.visitId)
    await api.handoff(ahead.visitId)

    const { visitId } = await fatimaAtTriage(page, api)
    await toHandoff(page, visitId)
    await page.getByTestId(`doctor-${DOCTOR}`).check()
    await page.getByTestId('handoff-confirm').click()
    await page.getByTestId('fast-forward').click()

    await expect(page.getByRole('alert')).toContainText(say('en', 'error.not_next_in_queue'))
    await expect(page.getByTestId('visit-complete')).toHaveCount(0)
    expect((await staffVisit(api, visitId)).status).toBe('in_doctor')
    expect((await staffVisit(api, ahead.visitId)).status).toBe('in_doctor')
    expect(sql("SELECT COUNT(*) FROM event WHERE type = 'demo.fast_forward'")).toEqual([[0]])
  })
})

test.describe('the screens fit', () => {
  test('T03 at 1440 shows every block side by side, with the primary action in view', async ({
    page,
    api,
  }) => {
    await fatimaAtTriage(page, api)
    const [intake, words, vitals] = await Promise.all(
      ['intake-card', 'patient-words', 'vitals-card'].map((id) =>
        page.getByTestId(id).boundingBox(),
      ),
    )
    expect(intake?.y).toBe(words?.y)
    expect(words?.y).toBe(vitals?.y)
    expect(intake?.width).toBeCloseTo(452, 0)
    expect(words?.width).toBeCloseTo(372, 0)
    expect(vitals?.width).toBeCloseTo(320, 0)
    await expect(page.getByTestId('vitals-submit')).toBeInViewport()
    await expectNoSideScroll(page, 'T03 at 1440')
  })

  test('T03 stacks below 1100 and takes one column at 390, in both languages', async ({
    page,
    api,
  }) => {
    await fatimaAtTriage(page, api)
    for (const viewport of [{ width: 1024, height: 768 }, PHONE]) {
      await page.setViewportSize(viewport)
      // The shell folds its header below 1024, so this waits for the new width to land.
      await expect(page.getByTestId('staff-logout').or(page.getByTestId('staff-menu'))).toBeVisible()
      await expect
        .poll(() => page.evaluate(() => document.documentElement.scrollWidth))
        .toBeLessThanOrEqual(viewport.width)
      const intake = await page.getByTestId('intake-card').boundingBox()
      const words = await page.getByTestId('patient-words').boundingBox()
      expect(words?.x).toBe(intake?.x)
      expect(words?.width).toBe(intake?.width)
      expect(words?.y ?? 0).toBeGreaterThan(intake?.y ?? 0)
      await expectNoSideScroll(page, `T03 at ${viewport.width}, en`)
    }
    await page.getByTestId('staff-menu').click()
    await page.getByTestId('language-toggle').click()
    await page.keyboard.press('Escape')
    await expect(page.locator('html')).toHaveAttribute('dir', 'rtl')
    await expectNoSideScroll(page, 'T03 at 390, ar')

    for (const id of ['vitals-submit', 'vital-hr', 'urgency-routine']) {
      const control = page.getByTestId(id)
      const box =
        id === 'urgency-routine'
          ? await control.locator('xpath=ancestor::label').boundingBox()
          : await control.boundingBox()
      expect(box?.height, id).toBeGreaterThanOrEqual(44)
    }
  })

  test('T04 stays within 390, before and after confirm', async ({ page, api }) => {
    const { visitId } = await fatimaAtTriage(page, api)
    await toHandoff(page, visitId)
    await page.setViewportSize(PHONE)
    await expect(page.getByTestId('staff-menu')).toBeVisible()
    await expectNoSideScroll(page, 'T04 at 390')
    await page.getByTestId('handoff-confirm').click()
    await expect(page.getByTestId('handoff-sent')).toBeVisible()
    await expectNoSideScroll(page, 'T04 confirmed at 390')
    const box = await page.getByTestId('fast-forward').boundingBox()
    expect(box?.height).toBeGreaterThanOrEqual(44)
  })
})
