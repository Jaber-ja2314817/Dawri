import type { Browser, Page } from '@playwright/test'
import type { DemoApi } from '../scripts/lib/demo-api.mjs'
import {
  DOCTOR,
  eventRows,
  expect,
  expectNotReloaded,
  markThePage,
  NURSE,
  PHARMACIST,
  QID,
  say,
  serveTiles,
  sql,
  staffLogin,
  streamOpen,
  test,
} from './fixtures'

const DESKTOP = { width: 1440, height: 900 }
const PHONE = { width: 390, height: 844 }
const OVERRIDE = 'prescription.allergy_override'
const EDITED_COMPLAINT = 'Fever and dry cough, worse at night'
const EDITED_LINE = 'Nurse note: asked to be seen with her chart from last spring.'
const DRUG_COUNT = 9
const SECOND_DOCTOR = 'S-WAK-DOC1'

test.use({ viewport: DESKTOP })

test.beforeEach(async ({ api }) => {
  await api.reset()
})

/** Called at triage, vitals taken, handoff confirmed. The doctor steps stay in the UI. */
async function nurseHandsOver(api: DemoApi, visitId: string) {
  await api.callNext()
  await api.vitals(visitId)
  await api.handoff(visitId)
}

async function fatimaAtDoctor(api: DemoApi) {
  const visit = await api.arrivedVisit(QID.fatima)
  await nurseHandsOver(api, visit.visitId)
  return visit
}

async function laylaAtDoctor(api: DemoApi) {
  const { token } = await api.patient(QID.fatima)
  const visitId = await api.newVisit(token, 'P004')
  await api.toSummary(token, visitId, 'عندها حرارة وكحة من ثلاث أيام')
  await api.confirm(token, visitId)
  await api.reserve(token, visitId)
  await api.arrive(token, visitId)
  await nurseHandsOver(api, visitId)
  return { token, visitId }
}

async function doctorCalls(page: Page) {
  await staffLogin(page, DOCTOR)
  await page.getByTestId('call-next').click()
  await expect(page.getByTestId('at-counter')).toHaveAttribute('data-state', 'called')
  await expect(page.getByTestId('prescription')).toBeVisible()
  await expect(page.getByTestId(/^drug-DR-/)).toHaveCount(DRUG_COUNT)
}

async function pharmacistCalls(page: Page) {
  await staffLogin(page, PHARMACIST)
  await page.getByTestId('call-next').click()
  await expect(page.getByTestId('at-counter')).toHaveAttribute('data-number', 'P-031')
  await expect(page.getByTestId('handover')).toBeVisible()
}

async function signedInPatient(browser: Browser, baseURL: string, token: string, path: string) {
  const context = await browser.newContext({ baseURL, viewport: PHONE, locale: 'en-GB' })
  await context.addInitScript((value) => localStorage.setItem('dawri.token', value), token)
  const page = await context.newPage()
  await serveTiles(page)
  await page.goto(path)
  return page
}

/** The queue card clips, so a column that does not fit is lost rather than scrolled to. */
async function queueFits(page: Page, where: string) {
  const fit = await page.getByTestId('queue-table').evaluate((card) => ({
    table: card.querySelector('table')?.scrollWidth ?? 0,
    card: card.clientWidth,
  }))
  expect(fit.table, where).toBeLessThanOrEqual(fit.card)
}

const bodies = (page: Page, visitId: string) => {
  const sent: Record<string, unknown>[] = []
  page.on('request', (request) => {
    if (request.url().endsWith(`/api/visits/${visitId}/consult/done`)) {
      sent.push(request.postDataJSON())
    }
  })
  return sent
}

test('T05 shows the handoff the nurse confirmed, with her edits, and never the AI draft', async ({
  page,
  api,
}) => {
  const { visitId } = await api.arrivedVisit(QID.fatima)
  await api.callNext()
  await api.vitals(visitId)
  await api.asStaff(NURSE, 'PUT', `/api/visits/${visitId}/intake`, {
    json: { chief_complaint: EDITED_COMPLAINT },
  })
  const draft = await api.asStaff(NURSE, 'POST', `/api/visits/${visitId}/handoff/draft`)
  await api.asStaff(NURSE, 'POST', `/api/visits/${visitId}/handoff/confirm`, {
    final_text: `${draft.text}\n${EDITED_LINE}`,
    doctor_id: DOCTOR,
  })

  await doctorCalls(page)
  const card = page.getByTestId('handoff-card')
  await expect(card).toHaveAttribute('dir', 'ltr')
  await expect(card).toContainText(EDITED_LINE)
  await expect(card).toHaveCSS('white-space', 'pre-wrap')
  await expect(page.getByTestId('handoff-complaint')).toHaveText(EDITED_COMPLAINT)
  const [stored, finalText] = sql(
    'SELECT ai_draft, final_text FROM handoff WHERE visit_id = ?',
    visitId,
  )[0] as [string, string]
  expect(finalText.endsWith(`\n${EDITED_LINE}`)).toBe(true)
  expect(await card.textContent()).toBe(finalText)
  expect(finalText).not.toBe(stored)

  await expect(page.getByTestId('urgency')).toHaveAttribute('data-urgency', 'routine')
  await expect(page.getByTestId('vital-bp')).toHaveText('118/76')
  await expect(page.getByTestId('vital-hr')).toHaveText('88')
  await expect(page.getByTestId('vital-temp')).toHaveText('38.2')
  await expect(page.getByTestId('vital-spo2')).toHaveText('98')
  await expect(page.getByTestId('vital-weight')).toHaveText('62')

  const banner = page.getByTestId('patient-banner')
  await expect(banner).toContainText('Fatima Al-Demo')
  await expect(page.getByTestId('banner-number')).toHaveText('D-GP-023')
  await expect(page.getByTestId('allergy-flag')).toHaveText('penicillin')

  // Hers, word for word, behind the disclosure.
  const words = page.getByTestId('doctor-patient-words')
  await expect(words.locator('li').first()).toBeHidden()
  await words.locator('summary').click()
  await expect(words.locator('li').first()).toHaveText('عندي حرارة وكحة من ثلاث أيام')
})

test('a missing vital is a grey dash, not a blank', async ({ page, api }) => {
  const { visitId } = await api.arrivedVisit(QID.fatima)
  await api.callNext()
  await api.asStaff(NURSE, 'POST', `/api/visits/${visitId}/vitals`, {
    temp_c: 37.5,
    urgency: 'soon',
  })
  await api.handoff(visitId)

  await doctorCalls(page)
  await expect(page.getByTestId('vital-bp')).toHaveText('—')
  await expect(page.getByTestId('vital-hr')).toHaveText('—')
  await expect(page.getByTestId('vital-temp')).toHaveText('37.5')
  await expect(page.getByTestId('vital-spo2')).toHaveText('—')
  await expect(page.getByTestId('urgency')).toHaveText(say('en', 'doctor.urgency.soon'))
})

test('nothing is preselected, and the allergy warning shows first, in AR and EN', async ({
  page,
  api,
}) => {
  await fatimaAtDoctor(api)
  await doctorCalls(page)

  const boxes = page.getByTestId(/^drug-DR-/)
  for (const box of await boxes.all()) await expect(box).not.toBeChecked()
  await expect(page.getByTestId(/^allergy-warning-/)).toHaveCount(2)

  const amoxicillin = page.getByTestId('allergy-warning-DR-AMOX')
  const coAmoxiclav = page.getByTestId('allergy-warning-DR-AUGM')
  await expect(amoxicillin).toContainText(say('en', 'doctor.allergy.pill'))
  await expect(amoxicillin).toContainText(
    'Allergy on record: penicillin. Check before prescribing amoxicillin.',
  )
  await expect(coAmoxiclav).toContainText('Check before prescribing co-amoxiclav.')
  await expect(page.getByTestId('allergy-warning-DR-PARA')).toHaveCount(0)

  await page.getByTestId('language-toggle').click()
  await expect(page.locator('html')).toHaveAttribute('dir', 'rtl')
  await expect(amoxicillin).toContainText(say('ar', 'doctor.allergy.pill'))
  await expect(amoxicillin).toContainText('راجع قبل وصف أموكسيسيلين.')
  await expect(coAmoxiclav).toContainText('راجع قبل وصف أموكسيسيلين مع كلافولانيك.')
  await expect(page.getByTestId('drug-row-DR-AMOX')).toContainText('أموكسيسيلين')
  for (const box of await boxes.all()) await expect(box).not.toBeChecked()
})

test('Done waits for the allergy check, and the override writes one event', async ({
  page,
  api,
}) => {
  const { visitId } = await fatimaAtDoctor(api)
  await doctorCalls(page)
  const sent = bodies(page, visitId)

  await page.getByTestId('drug-DR-AMOX').check()
  const done = page.getByTestId('consult-done')
  const ack = page.getByTestId('ack-allergy')
  await expect(done).toBeDisabled()
  await expect(ack).not.toBeChecked()
  await expect(page.getByTestId('done-why')).toHaveText(say('en', 'doctor.done.allergy'))

  // Prefilled, and the doctor's change is what goes.
  await expect(page.getByTestId('rx-dose-DR-AMOX')).toHaveValue('500 mg')
  await expect(page.getByTestId('rx-frequency-DR-AMOX')).toHaveValue('three times daily')
  await expect(page.getByTestId('rx-days-DR-AMOX')).toHaveValue('5')
  await page.getByTestId('rx-days-DR-AMOX').fill('366')
  await ack.check()
  await expect(done).toBeDisabled()
  await expect(page.getByTestId('done-why')).toHaveText(say('en', 'doctor.done.details'))
  await page.getByTestId('rx-days-DR-AMOX').fill('7')
  await page.getByTestId('rx-notes-DR-AMOX').fill('after food')
  await expect(done).toBeEnabled()

  await ack.uncheck()
  await expect(done).toBeDisabled()
  expect(sent).toEqual([])
  expect(eventRows(visitId, OVERRIDE)).toBe(0)

  await ack.check()
  await done.click()
  await expect(page.getByTestId('moved-number')).toHaveText('P-031')
  await expect(page.getByTestId('call-next')).toBeVisible()
  await expect(page.getByTestId('doctor-empty')).toBeVisible()

  expect(sent).toEqual([
    {
      prescription: [
        {
          drug_id: 'DR-AMOX',
          dose: '500 mg',
          frequency: 'three times daily',
          days: 7,
          notes: 'after food',
        },
      ],
      acknowledge_allergy: true,
    },
  ])
  expect(eventRows(visitId, OVERRIDE)).toBe(1)
  expect(sql('SELECT drug, days, notes FROM prescription_item WHERE visit_id = ?', visitId)).toEqual([
    ['DR-AMOX', 7, 'after food'],
  ])
})

test('a safe medicine goes with no box and no event, and sends the tick as false', async ({
  page,
  api,
}) => {
  const { visitId } = await fatimaAtDoctor(api)
  await doctorCalls(page)
  const sent = bodies(page, visitId)

  await page.getByTestId('drug-DR-PARA').check()
  await expect(page.getByTestId('ack-allergy')).toHaveCount(0)
  await page.getByTestId('consult-done').click()
  await expect(page.getByTestId('moved-number')).toHaveText('P-031')

  expect(sent).toHaveLength(1)
  expect(sent[0].acknowledge_allergy).toBe(false)
  expect(eventRows(visitId, OVERRIDE)).toBe(0)
})

test('a 409 from the server shows its conflicts and moves nothing', async ({ page, api }) => {
  const { visitId } = await fatimaAtDoctor(api)
  // A list that says nothing of the allergy, so only the server stands in the way.
  await page.route('**/drugs', async (route) => {
    const response = await route.fetch()
    const drugs = (await response.json()) as { allergy_warning: unknown }[]
    await route.fulfill({ response, json: drugs.map((drug) => ({ ...drug, allergy_warning: null })) })
  })
  await doctorCalls(page)
  const sent = bodies(page, visitId)

  await page.getByTestId('drug-DR-AMOX').check()
  await expect(page.getByTestId('ack-allergy')).toHaveCount(0)
  await page.getByTestId('consult-done').click()

  await expect(page.getByTestId('allergy-conflicts')).toContainText(
    'Check before prescribing amoxicillin.',
  )
  await expect(page.getByRole('alert')).toContainText(say('en', 'error.allergy_conflict'))
  expect(sent).toHaveLength(1)
  expect(sent[0].acknowledge_allergy).toBe(false)
  expect(eventRows(visitId, OVERRIDE)).toBe(0)
  expect(sql('SELECT status FROM visit WHERE id = ?', visitId)).toEqual([['in_doctor']])

  // Now a warned medicine like any other: the doctor ticks and it goes, once.
  await expect(page.getByTestId('consult-done')).toBeDisabled()
  await page.getByTestId('ack-allergy').check()
  await page.getByTestId('consult-done').click()
  await expect(page.getByTestId('moved-number')).toHaveText('P-031')
  expect(sent[1].acknowledge_allergy).toBe(true)
  expect(eventRows(visitId, OVERRIDE)).toBe(1)
})

async function amoxicillinAcknowledged(page: Page, api: DemoApi) {
  const { visitId } = await fatimaAtDoctor(api)
  await doctorCalls(page)
  await page.getByTestId('drug-DR-AMOX').check()
  await page.getByTestId('drug-DR-PARA').check()
  await page.getByTestId('ack-allergy').check()
  await page.getByTestId('consult-done').click()
  await expect(page.getByTestId('moved-number')).toHaveText('P-031')
  await page.getByTestId('staff-logout').click()
  await page.waitForURL('**/staff/login')
  return visitId
}

const rxRow = (page: Page, drugId: string) =>
  page.locator(`[data-testid=rx-row][data-drug="${drugId}"]`)

test('T06 warns on the row of an acknowledged override, in the console language, and on no other', async ({
  page,
  api,
}) => {
  await amoxicillinAcknowledged(page, api)
  await pharmacistCalls(page)

  const warning = rxRow(page, 'DR-AMOX').getByTestId('rx-warning')
  await expect(warning).toContainText(say('en', 'doctor.allergy.pill'))
  await expect(warning).toContainText(
    'Allergy on record: penicillin. Check before prescribing amoxicillin.',
  )
  await expect(rxRow(page, 'DR-PARA')).toBeVisible()
  await expect(rxRow(page, 'DR-PARA').getByTestId('rx-warning')).toHaveCount(0)
  await expect(page.getByTestId('rx-warning')).toHaveCount(1)

  await page.getByTestId('language-toggle').click()
  await expect(warning).toContainText(say('ar', 'doctor.allergy.pill'))
  await expect(warning).toContainText('راجع قبل وصف أموكسيسيلين.')
  await page.getByTestId('language-toggle').click()

  // It tells, and it holds nothing back.
  await expect(page.getByTestId('dispensed')).toBeEnabled()
  await page.getByTestId('dispensed').click()
  await expect(page.getByTestId('dispensed-outcome')).toContainText('P-031')
})

test('T06 shows no warning at all on a safe prescription', async ({ page, api }) => {
  const { visitId } = await fatimaAtDoctor(api)
  await doctorCalls(page)
  await page.getByTestId('drug-DR-PARA').check()
  await page.getByTestId('consult-done').click()
  await expect(page.getByTestId('moved-number')).toHaveText('P-031')
  await page.getByTestId('staff-logout').click()
  await page.waitForURL('**/staff/login')

  const drugs = page.waitForResponse(`**/api/staff/visits/${visitId}/drugs`)
  await pharmacistCalls(page)
  expect((await drugs).status()).toBe(200)
  await expect(page.getByTestId('rx-row')).toHaveCount(1)
  await expect(page.getByTestId('rx-warning')).toHaveCount(0)
  await expect(page.getByTestId('rx-warnings-unread')).toHaveCount(0)
})

test('T06 says so when the warnings cannot be read, and the handover still goes', async ({
  page,
  api,
}) => {
  await amoxicillinAcknowledged(page, api)
  await page.route('**/api/staff/visits/*/drugs', (route) =>
    route.fulfill({ status: 500, json: { error: 'internal_error' } }),
  )
  await pharmacistCalls(page)
  await expect(page.getByTestId('rx-warnings-unread')).toHaveText(
    say('en', 'pharmacy.warningsUnread'),
  )
  await expect(page.getByTestId('rx-warning')).toHaveCount(0)
  await expect(page.getByTestId('dispensed')).toBeEnabled()
})

test('the patient moves to P-031 with no reload, and the pharmacy hands over to S11', async ({
  page,
  api,
  browser,
  baseURL,
}) => {
  const { token, visitId } = await fatimaAtDoctor(api)
  const patient = await signedInPatient(browser, baseURL as string, token, `/visit/${visitId}/ticket`)
  await expect(patient.getByTestId('ticket-number')).toHaveText('D-GP-023')
  await streamOpen(patient)
  await markThePage(patient)

  await doctorCalls(page)
  await page.getByTestId('patient-here').click()
  await expect(page.getByTestId('at-counter')).toHaveAttribute('data-state', 'serving')
  await queueFits(page, 'English, serving')
  await page.getByTestId('language-toggle').click()
  await expect(page.locator('html')).toHaveAttribute('dir', 'rtl')
  await queueFits(page, 'Arabic, serving')
  await page.getByTestId('language-toggle').click()
  await page.getByTestId('drug-DR-PARA').check()
  await page.getByTestId('drug-DR-DEXT').check()
  await page.getByTestId('consult-done').click()
  await expect(page.getByTestId('moved-number')).toHaveText('P-031')
  await expect(patient.getByTestId('ticket-number')).toHaveText('P-031', { timeout: 2_000 })
  await expectNotReloaded(patient)

  await page.getByTestId('staff-logout').click()
  await page.waitForURL('**/staff/login')
  await pharmacistCalls(page)
  const rows = page.getByTestId('rx-row')
  await expect(rows).toHaveCount(2)
  await expect(page.getByTestId('patient-banner')).toContainText('Fatima Al-Demo')
  await expect(page.getByTestId('allergy-flag')).toHaveText('penicillin')
  await expect(page.getByTestId('medicine-name').first()).toHaveText('Paracetamol')
  await expect(page.getByTestId('medicine-line').first()).toHaveText(
    'Paracetamol (tablet): take 500 mg, every 6 hours when needed, for 3 days.',
  )
  await page.getByTestId('language-toggle').click()
  await expect(page.getByTestId('medicine-name').first()).toHaveText('باراسيتامول')
  await expect(page.getByTestId('medicine-line').first()).toContainText('الجرعة 500 ملغ')
  await page.getByTestId('language-toggle').click()

  await page.getByTestId('patient-here').click()
  await expect(page.getByTestId('at-counter')).toHaveAttribute('data-state', 'serving')
  await page.getByTestId('dispensed').click()
  await expect(page.getByTestId('dispensed-outcome')).toContainText('P-031')
  await expect(page.getByTestId('pharmacy-empty')).toBeVisible()
  await expect(page.getByTestId('call-next')).toBeVisible()

  await patient.waitForURL('**/complete', { timeout: 2_000 })
  await expect(patient.getByTestId('complete-check')).toBeVisible()
  const medicines = patient.getByTestId('medicine')
  await expect(medicines).toHaveCount(2)
  await expect(medicines.first()).toContainText('باراسيتامول')
  await expect(medicines.first()).toContainText('الجرعة 500 ملغ')
  await expectNotReloaded(patient)
  await patient.context().close()
})

test('no medicine takes its own second tap and ends the visit with no P ticket', async ({
  page,
  api,
  browser,
  baseURL,
}) => {
  const { token, visitId } = await fatimaAtDoctor(api)
  const patient = await signedInPatient(browser, baseURL as string, token, `/visit/${visitId}/ticket`)
  await streamOpen(patient)
  await markThePage(patient)
  await doctorCalls(page)

  await expect(page.getByTestId('consult-done')).toHaveText(say('en', 'doctor.done.empty'))
  // A double tap on the one button only asks: the second tap has to be aimed.
  await page.getByTestId('consult-done').dblclick()
  await expect(page.getByTestId('done-empty-note')).toHaveText(say('en', 'doctor.done.emptyNote'))
  expect(sql('SELECT status FROM visit WHERE id = ?', visitId)).toEqual([['in_doctor']])

  await page.getByTestId('done-empty-cancel').click()
  await expect(page.getByTestId('done-empty-note')).toHaveCount(0)
  expect(sql('SELECT status FROM visit WHERE id = ?', visitId)).toEqual([['in_doctor']])

  await page.getByTestId('consult-done').click()
  await page.getByTestId('done-empty-confirm').click()
  await expect(page.getByTestId('visit-finished')).toHaveText(say('en', 'doctor.finished'))
  await expect(page.getByTestId('doctor-empty')).toBeVisible()

  expect(sql('SELECT status FROM visit WHERE id = ?', visitId)).toEqual([['completed']])
  expect(sql("SELECT COUNT(*) FROM ticket WHERE visit_id = ? AND number LIKE 'P-%'", visitId)).toEqual(
    [[0]],
  )
  expect(sql('SELECT COUNT(*) FROM prescription_item WHERE visit_id = ?', visitId)).toEqual([[0]])

  await patient.waitForURL('**/complete', { timeout: 2_000 })
  await expect(patient.getByTestId('no-medicines')).toBeVisible()
  await expectNotReloaded(patient)
  await patient.context().close()
})

test('Not here sends the patient back to the line, at both counters', async ({ page, api }) => {
  const { visitId } = await fatimaAtDoctor(api)
  await doctorCalls(page)
  await page.getByTestId('drug-DR-PARA').check()

  await page.getByTestId('not-here').click()
  await expect(page.getByTestId('doctor-empty')).toBeVisible()
  await expect(page.getByTestId('patient-gone')).toHaveCount(0)
  await expect(page.locator('[data-testid=queue-row][data-number=D-GP-023]')).toHaveAttribute(
    'data-state',
    'active',
  )

  // Called again, she starts from a clean picker.
  await page.getByTestId('call-next').click()
  await expect(page.getByTestId('at-counter')).toHaveAttribute('data-number', 'D-GP-023')
  await expect(page.getByTestId('drug-DR-PARA')).not.toBeChecked()
  await page.getByTestId('drug-DR-PARA').check()
  await page.getByTestId('consult-done').click()
  await expect(page.getByTestId('moved-number')).toHaveText('P-031')

  await page.getByTestId('staff-logout').click()
  await page.waitForURL('**/staff/login')
  await pharmacistCalls(page)
  await page.getByTestId('not-here').click()
  await expect(page.getByTestId('pharmacy-empty')).toBeVisible()
  await expect(page.getByTestId('patient-gone')).toHaveCount(0)
  await expect(page.locator('[data-testid=queue-row][data-number=P-031]')).toHaveAttribute(
    'data-state',
    'active',
  )
  expect(sql('SELECT status FROM visit WHERE id = ?', visitId)).toEqual([['in_pharmacy']])
})

test('a dependent is judged on her own record, not her guardian', async ({ page, api }) => {
  const { visitId } = await laylaAtDoctor(api)
  await doctorCalls(page)

  await expect(page.getByTestId('patient-banner')).toContainText('Layla Al-Demo')
  await expect(page.getByTestId('patient-banner')).toContainText(say('en', 'queue.noAllergies'))
  await expect(page.getByTestId('allergy-flag')).toHaveCount(0)
  await expect(page.getByTestId(/^allergy-warning-/)).toHaveCount(0)

  await page.getByTestId('drug-DR-AMOX').check()
  await expect(page.getByTestId('ack-allergy')).toHaveCount(0)
  await page.getByTestId('consult-done').click()
  await expect(page.getByTestId('moved-number')).toHaveText('P-031')
  expect(eventRows(visitId, OVERRIDE)).toBe(0)
})

test('T05 and T06 are live, and a reset empties T06 with a notice', async ({
  page,
  api,
  browser,
  baseURL,
}) => {
  await staffLogin(page, DOCTOR)
  await expect(page.getByTestId('doctor-empty')).toContainText(say('en', 'doctor.empty'))
  await expect(page.getByTestId('prescription')).toHaveCount(0)
  await expect(page.getByTestId('call-next')).toBeDisabled()
  await expect(page.getByTestId('live-state')).toHaveAttribute('data-live', 'live')
  await markThePage(page)

  const context = await browser.newContext({ baseURL, viewport: DESKTOP, locale: 'en-GB' })
  const pharmacy = await context.newPage()
  await staffLogin(pharmacy, PHARMACIST)
  await expect(pharmacy.getByTestId('pharmacy-empty')).toContainText(say('en', 'pharmacy.empty'))
  await expect(pharmacy.getByTestId('live-state')).toHaveAttribute('data-live', 'live')
  await markThePage(pharmacy)

  await fatimaAtDoctor(api)
  await expect(page.locator('[data-testid=queue-row][data-number=D-GP-023]')).toBeVisible({
    timeout: 2_000,
  })
  await page.getByTestId('call-next').click()
  await page.getByTestId('drug-DR-PARA').check()
  await page.getByTestId('consult-done').click()
  await expect(page.getByTestId('moved-number')).toHaveText('P-031')

  await expect(pharmacy.locator('[data-testid=queue-row][data-number=P-031]')).toBeVisible({
    timeout: 2_000,
  })
  await pharmacy.getByTestId('call-next').click()
  await expect(pharmacy.getByTestId('medicine-line')).toHaveCount(1)

  await api.reset()

  await expect(pharmacy.getByTestId('patient-gone')).toHaveText(say('en', 'pharmacy.gone'))
  await expect(pharmacy.getByTestId('pharmacy-empty')).toBeVisible()
  await expect(pharmacy.getByTestId('handover')).toHaveCount(0)
  await expect(pharmacy.getByRole('alert')).toHaveCount(0)
  await expectNotReloaded(pharmacy)
  await expectNotReloaded(page)
  await context.close()
})

test('a reset with a patient in the room empties T05 with a notice', async ({ page, api }) => {
  await fatimaAtDoctor(api)
  await doctorCalls(page)
  await page.getByTestId('drug-DR-PARA').check()
  await markThePage(page)

  await api.reset()

  await expect(page.getByTestId('patient-gone')).toHaveText(say('en', 'doctor.gone'))
  await expect(page.getByTestId('doctor-empty')).toBeVisible()
  await expect(page.getByTestId('at-counter')).toHaveCount(0)
  await expect(page.getByTestId('prescription')).toHaveCount(0)
  await expect(page.getByRole('alert')).toHaveCount(0)
  await expectNotReloaded(page)
})

test('a colleague at another counter gets the plain refusal', async ({ page, api }) => {
  const { visitId } = await fatimaAtDoctor(api)
  await doctorCalls(page)
  await page.getByTestId('drug-DR-PARA').check()

  // The session changes under the open screen: Dr. Khalid, on Room 3, presses Done.
  const colleague = await api.staffToken(SECOND_DOCTOR)
  await page.route('**/consult/done', async (route) => {
    const headers = { ...route.request().headers(), authorization: `Bearer ${colleague}` }
    await route.continue({ headers })
  })
  await page.getByTestId('consult-done').click()
  await expect(page.getByRole('alert')).toHaveText(say('en', 'error.not_your_counter'))
  expect(sql('SELECT status FROM visit WHERE id = ?', visitId)).toEqual([['in_doctor']])
})

test('on a phone one region shows at a time, with the patient first', async ({ page, api }) => {
  await fatimaAtDoctor(api)
  await page.setViewportSize(PHONE)
  await doctorCalls(page)

  const fits = async (where: string) => {
    const widths = await page.evaluate(() => ({
      content: document.documentElement.scrollWidth,
      screen: window.innerWidth,
    }))
    expect(widths.content, where).toBeLessThanOrEqual(widths.screen)
  }

  await expect(page.getByTestId('handoff-card')).toBeVisible()
  await expect(page.getByTestId('queue-table')).toBeHidden()
  await fits('patient region')

  await page.getByTestId('drug-DR-AMOX').check()
  const row = await page.getByTestId('drug-row-DR-PARA').boundingBox()
  expect(row?.height).toBeGreaterThanOrEqual(44)
  await fits('selected row')

  await page.getByTestId('region-queue').click()
  await expect(page.getByTestId('queue-table')).toBeVisible()
  await expect(page.getByTestId('handoff-card')).toBeHidden()
  await fits('queue region')

  await page.getByTestId('region-patient').click()
  await expect(page.getByTestId('drug-DR-AMOX')).toBeChecked()
})
