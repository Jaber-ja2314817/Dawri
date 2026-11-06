import {
  agree,
  AHMED_WORDS,
  answerToSummary,
  confirmSummary,
  DOCTOR,
  DOCTOR_COUNTER,
  eventRows,
  expect,
  expectNotReloaded,
  FATIMA_WORDS,
  login,
  markThePage,
  NURSE,
  PHARMACIST,
  PHARMACY_COUNTER,
  RAVI_WORDS,
  reserveHere,
  say,
  send,
  sql,
  startCheckIn,
  streamOpen,
  test,
  ticketRows,
  TRIAGE_COUNTER,
  visitIdOf,
  type Page,
  type Windows,
} from './fixtures'

/*
 * Demo Script as written, with Build Decisions' overrides, in real parallel windows.
 * Patient on a phone, staff on a laptop, and every staff step through its own screen.
 */

const NURSE_EDIT = 'Nurse note: seen with her own thermometer reading of 38.5.'
const NO_RELOAD_MS = 2_000
const DASHBOARD_POLL_MS = 8_000
const AIRPORT = 'C-AIRPORT'
const AIRPORT_NURSE = 'S-AIR-NURSE1'
const RAYYAN = 'C-RAYYAN'
const RAYYAN_NURSE = 'S-RAY-NURSE1'

function collectErrors(errors: string[], ...pages: Page[]) {
  for (const page of pages) {
    page.on('pageerror', (error) => errors.push(`${page.url()}: ${error.message}`))
  }
}

const queueRow = (page: Page, number: string) =>
  page.locator(`[data-testid=queue-row][data-number="${number}"]`)

const displayCell = (page: Page, counterId: string) =>
  page.locator(`[data-testid=display-counter][data-counter="${counterId}"]`)

const expectChimes = (page: Page, count: number) =>
  expect(page.getByTestId('display-root')).toHaveAttribute('data-chimes', String(count))

const figure = (page: Page, id: string) => page.getByTestId(`figure-${id}`)

async function resetFromConsole(page: Page) {
  await page.getByTestId('reset-demo').click()
  await page.getByTestId('reset-confirm').click()
  await expect(page.getByTestId('staff-notice')).toHaveText(say('en', 'staff.reset.done'))
  await expect(page.getByTestId('live-state')).toHaveAttribute('data-live', 'live')
}

async function openDisplayTab(page: Page) {
  const tab = await page.context().newPage()
  await tab.goto('/staff/display')
  await expect(tab.getByTestId('display-root')).toHaveAttribute('data-live', 'live')
  await expectChimes(tab, 0)
  for (const counterId of [TRIAGE_COUNTER, DOCTOR_COUNTER, PHARMACY_COUNTER]) {
    await expect(displayCell(tab, counterId).getByTestId('display-number')).toHaveText('—')
  }
  return tab
}

async function openDashboardTab(page: Page) {
  const tab = await page.context().newPage()
  await tab.goto('/staff/dashboard')
  await expect(figure(tab, 'waiting-total')).toHaveAttribute('data-value', /\d+/)
  return tab
}

async function patientThroughUi(phone: Page, nurse: Page) {
  await login(phone, 'P001')
  await startCheckIn(phone)
  await phone.getByTestId('who-P001').click()
  await agree(phone)
  const visitId = visitIdOf(phone)

  await answerToSummary(phone)
  await expect(phone.locator('[data-testid=bubble][data-role=user]').first()).toHaveText(
    FATIMA_WORDS,
  )
  await expect(phone.getByTestId('chat-summary-text')).toContainText('3 أيام')
  await confirmSummary(phone)

  // Build Decisions centres: the registered centre leads and the other is visibly slower.
  await phone.getByTestId('view-list').click()
  const rows = phone.getByTestId('centre-row')
  await expect(rows.first()).toHaveAttribute('data-centre-id', 'C-WAKRA')
  await expect(rows.first()).toContainText('12')
  await expect(rows.filter({ hasText: 'مركز المطار الصحي' })).toContainText('3')

  await reserveHere(phone)
  await expect(phone.locator('main')).toContainText('تسجيل الوصول صالح لمدة 45 دقيقة')
  await expect(phone.getByTestId('ticket-number')).toHaveCount(0)

  // The pause in the script: the phone and the nurse's table at the same moment.
  await expect(queueRow(nurse, 'T-014')).toHaveCount(0)
  await markThePage(nurse)
  const tapped = Date.now()
  await phone.getByTestId('im-here').click()
  await queueRow(nurse, 'T-014').waitFor({ state: 'visible', timeout: 5_000 })
  const shownAfter = Date.now() - tapped
  test.info().annotations.push({ type: 'im-here-to-table-ms', description: String(shownAfter) })
  expect(shownAfter, `T-014 reached the nurse in ${shownAfter} ms`).toBeLessThan(1_500)

  await phone.waitForURL('**/ticket')
  await expect(phone.getByTestId('ticket-number')).toHaveText('T-014')
  await expectNotReloaded(nurse)
  await streamOpen(phone)
  await markThePage(phone)

  const simulated = nurse.locator('[data-testid=queue-row][data-simulated=true]')
  await expect(simulated).toHaveCount(3)
  for (const row of await simulated.all()) {
    await expect(row).toContainText(say('en', 'queue.simulated'))
    await expect(row).not.toContainText('Fatima')
  }
  await expect(queueRow(nurse, 'T-014')).toContainText('Fatima Al-Demo')
  return visitId
}

async function nurseThroughUi(nurse: Page, phone: Page, display: Page, visitId: string) {
  await nurse.getByTestId('call-next').click()
  await nurse.waitForURL(`**/staff/nurse/${visitId}`)
  await expect(nurse.getByTestId('banner-number')).toHaveText('T-014')
  await expect(nurse.getByTestId('auto-completed')).toContainText('T-011, T-012, T-013')
  await expect(phone.getByTestId('ticket-called')).toBeVisible({ timeout: NO_RELOAD_MS })
  await expect(displayCell(display, TRIAGE_COUNTER).getByTestId('display-number')).toHaveText(
    'T-014',
  )
  await expectChimes(display, 1)

  // The intake card is already filled, and the patient's words stand beside it.
  await expect(nurse.getByTestId('intake-allergies').getByTestId('allergy-flag')).toHaveText(
    'penicillin',
  )
  await expect(nurse.getByTestId('intake-reason')).not.toHaveText('—')
  await expect(nurse.getByTestId('ai-summary')).not.toHaveText('—')
  const turns = nurse.locator('[data-testid=patient-words] [data-testid=turn][data-role=patient]')
  await expect(turns.first().locator('p')).toHaveText(FATIMA_WORDS)

  const submit = nurse.getByTestId('vitals-submit')
  await nurse.getByTestId('vital-bp_sys').fill('118')
  await nurse.getByTestId('vital-bp_dia').fill('76')
  await nurse.getByTestId('vital-hr').fill('88')
  await nurse.getByTestId('vital-temp_c').fill('38.2')
  await nurse.getByTestId('vital-spo2').fill('98')
  await nurse.getByTestId('vital-weight_kg').fill('62')
  await expect(submit).toBeDisabled()
  await nurse.getByTestId('urgency-routine').check()
  await submit.click()
  await nurse.waitForURL(`**/staff/nurse/${visitId}/handoff`)

  const draft = nurse.getByTestId('handoff-text')
  await expect(draft).toBeVisible()
  await expect(nurse.getByTestId('handoff-source')).toHaveAttribute('data-source', 'simulated')
  await expect(nurse.getByTestId('handoff-source')).toHaveText(/scripted/i)
  await expect(nurse.getByTestId(`doctor-${DOCTOR}`)).toBeChecked()
  const suggested = nurse.getByTestId('doctor-option').first()
  await expect(suggested).toHaveAttribute('data-doctor', DOCTOR)
  await expect(suggested).toContainText('Dr. Noor Al-Demo')
  await expect(suggested.getByTestId('doctor-reason')).toContainText(/\S/)

  // Nothing leaves before Confirm & send.
  expect(sql('SELECT status FROM visit WHERE id = ?', visitId)).toEqual([['in_triage']])
  const lines = (await draft.inputValue()).split('\n')
  lines[0] = `${lines[0]} ${NURSE_EDIT}`
  await draft.fill(lines.join('\n'))
  await nurse.getByTestId('handoff-confirm').click()

  await expect(nurse.getByTestId('sent-number')).toHaveText('D-GP-023')
  await expect(nurse.getByTestId('sent-doctor')).toContainText('Dr. Noor Al-Demo')
  await expect(nurse.getByTestId('handoff-final-text')).toContainText(NURSE_EDIT)
  await expect(phone.getByTestId('ticket-number')).toHaveText('D-GP-023', { timeout: NO_RELOAD_MS })
  await expect(phone.getByTestId('step-doctor')).toHaveAttribute('aria-current', 'step')
  await expectNotReloaded(phone)
}

/** Reset, the phone's whole run to a confirmed handoff, and the nurse in between. */
async function fatimaToDoctor(phone: Page, windows: Windows, errors: string[]) {
  const nurse = await windows.staff(NURSE)
  collectErrors(errors, phone, nurse)
  await expect(nurse.getByTestId('live-state')).toHaveAttribute('data-live', 'live')
  await resetFromConsole(nurse)
  const display = await openDisplayTab(nurse)
  const dashboard = await openDashboardTab(nurse)
  collectErrors(errors, display, dashboard)
  await expect(figure(dashboard, 'completed')).toHaveText('0')

  const visitId = await patientThroughUi(phone, nurse)
  await markThePage(display)
  await nurseThroughUi(nurse, phone, display, visitId)
  return { nurse, display, dashboard, visitId }
}

async function ahmedHasNoVisit(windows: Windows, errors: string[]) {
  const phone = await windows.phone()
  collectErrors(errors, phone)
  await login(phone, 'P002')
  await startCheckIn(phone)
  await agree(phone)
  const visitId = visitIdOf(phone)
  await send(phone, AHMED_WORDS)
  await phone.waitForURL('**/refill')
  await expect(phone.getByTestId('refill-medicine')).toHaveText('amlodipine 5 mg once daily')
  await expect(phone.getByTestId('ticket-number')).toHaveCount(0)
  expect(ticketRows(visitId)).toBe(0)
  return visitId
}

async function raviIsSentAway(windows: Windows, errors: string[]) {
  const phone = await windows.phone()
  collectErrors(errors, phone)
  await login(phone, 'P003')
  await startCheckIn(phone, 'en')
  await agree(phone, 'en')
  const visitId = visitIdOf(phone)
  await send(phone, RAVI_WORDS)
  await phone.waitForURL('**/emergency')
  await expect(phone.getByTestId('emergency-call')).toHaveAttribute('href', 'tel:999')
  await expect(phone.getByTestId('emergency-nearest')).toContainText('Hamad General Hospital')
  await expect(phone.getByTestId('ticket-number')).toHaveCount(0)
  await expect(phone.getByTestId('chat-input')).toHaveCount(0)
  expect(ticketRows(visitId)).toBe(0)
  expect(sql('SELECT status FROM visit WHERE id = ?', visitId)).toEqual([['redirected_emergency']])
  return visitId
}

test.describe('Demo Script, two browsers', () => {
  test('Fatima to S11, then Ahmed, then Ravi, every staff step on its own screen', async ({
    page: phone,
    windows,
  }) => {
    test.setTimeout(180_000)
    const errors: string[] = []
    const { nurse, display, dashboard, visitId } = await fatimaToDoctor(phone, windows, errors)

    await expectChimes(display, 1)

    const doctor = await windows.staff(DOCTOR)
    collectErrors(errors, doctor)
    await expect(doctor.getByTestId('call-next')).toBeVisible()
    await doctor.getByTestId('call-next').click()
    await expect(doctor.getByTestId('at-counter')).toHaveAttribute('data-number', 'D-GP-023')
    await expect(doctor.getByTestId('handoff-card')).toContainText(NURSE_EDIT)
    await expect(doctor.getByTestId('patient-banner').getByTestId('allergy-flag')).toHaveText(
      'penicillin',
    )
    await expect(doctor.getByTestId('allergy-warning-DR-AMOX')).toContainText(
      'Check before prescribing amoxicillin.',
    )
    await expect(doctor.getByTestId('drug-DR-AMOX')).not.toBeChecked()

    await expect(displayCell(display, DOCTOR_COUNTER).getByTestId('display-number')).toHaveText(
      'D-GP-023',
    )
    await expectChimes(display, 2)

    await doctor.getByTestId('drug-DR-PARA').check()
    await expect(doctor.getByTestId('ack-allergy')).toHaveCount(0)
    await doctor.getByTestId('consult-done').click()
    await expect(doctor.getByTestId('moved-number')).toHaveText('P-031')
    await expect(phone.getByTestId('ticket-number')).toHaveText('P-031', { timeout: NO_RELOAD_MS })
    await expect(phone.getByTestId('step-pharmacy')).toHaveAttribute('aria-current', 'step')
    expect(eventRows(visitId, 'prescription.allergy_override')).toBe(0)

    const pharmacy = await windows.staff(PHARMACIST)
    collectErrors(errors, pharmacy)
    await pharmacy.getByTestId('call-next').click()
    await expect(pharmacy.getByTestId('at-counter')).toHaveAttribute('data-number', 'P-031')
    await expect(pharmacy.getByTestId('rx-row')).toHaveCount(1)
    await expect(pharmacy.getByTestId('medicine-name')).toContainText(/paracetamol/i)
    await expect(displayCell(display, PHARMACY_COUNTER).getByTestId('display-number')).toHaveText(
      'P-031',
    )
    await expectChimes(display, 3)

    await pharmacy.getByTestId('dispensed').click()
    await expect(pharmacy.getByTestId('dispensed-outcome')).toContainText('P-031')
    await phone.waitForURL('**/complete', { timeout: NO_RELOAD_MS })
    await expectNotReloaded(phone)
    await expectNotReloaded(display)
    const medicine = phone.getByTestId('medicine').first()
    await expect(medicine).toContainText('باراسيتامول')
    await expect(medicine).toContainText('كل 6 ساعات')

    await expect(figure(dashboard, 'completed')).toHaveText('1', { timeout: DASHBOARD_POLL_MS })
    await expect(figure(dashboard, 'waiting-total')).toHaveText('0')
    await expect(figure(dashboard, 'emergencies')).toHaveText('0')

    // Ahmed, one less person in the waiting room, counted at his own centre.
    const ahmed = await ahmedHasNoVisit(windows, errors)
    const rayyan = await windows.staff(RAYYAN_NURSE, RAYYAN)
    await rayyan.goto('/staff/dashboard')
    await expect(figure(rayyan, 'deflections')).toHaveText('1')
    await expect(figure(rayyan, 'waiting-total')).toHaveText('0')
    expect(ticketRows(ahmed)).toBe(0)

    // Ravi, watched live by the staff at the centre he is registered with.
    const airportQueue = await windows.staff(AIRPORT_NURSE, AIRPORT)
    const airportBoard = await openDashboardTab(airportQueue)
    collectErrors(errors, airportQueue, airportBoard)
    await expect(figure(airportBoard, 'emergencies')).toHaveText('0')

    const ravi = await raviIsSentAway(windows, errors)
    await expect(figure(airportBoard, 'emergencies')).toHaveText('1', {
      timeout: DASHBOARD_POLL_MS,
    })
    await expect(figure(airportBoard, 'waiting-total')).toHaveText('0')
    // Only Simulated rows: the simulator moves Airport's own, so their number is not fixed.
    await expect(airportQueue.locator('[data-testid=queue-row][data-simulated=false]')).toHaveCount(0)
    expect(ticketRows(ravi)).toBe(0)

    await expect(figure(dashboard, 'emergencies')).toHaveText('0')
    await expect(figure(dashboard, 'completed')).toHaveText('1')
    await expectNotReloaded(nurse)
    expect(errors).toEqual([])
  })

  test('the same path, with Demo: skip to visit complete after confirm', async ({
    page: phone,
    windows,
  }) => {
    test.setTimeout(120_000)
    const errors: string[] = []
    const { nurse, dashboard, visitId } = await fatimaToDoctor(phone, windows, errors)

    const skip = nurse.getByTestId('fast-forward')
    await expect(skip).toHaveText(say('en', 'nurse.sent.skip'))
    await expect(skip).toContainText('Demo')
    await skip.click()

    await expect(nurse.getByTestId('visit-complete')).toBeVisible()
    await phone.waitForURL('**/complete', { timeout: NO_RELOAD_MS })
    await expectNotReloaded(phone)
    await expect(phone.getByTestId('medicine').first()).toContainText(/[؀-ۿ]/)
    await expect(figure(dashboard, 'completed')).toHaveText('1', { timeout: DASHBOARD_POLL_MS })

    // The normal engine: three tickets, each done, and each step on the record.
    const tickets = sql('SELECT number, state FROM ticket WHERE visit_id = ?', visitId)
    expect(tickets).toHaveLength(3)
    expect(tickets).toEqual(
      expect.arrayContaining([
        ['T-014', 'done'],
        ['D-GP-023', 'done'],
        ['P-031', 'done'],
      ]),
    )
    expect(eventRows(visitId, 'ticket.done')).toBe(3)
    expect(sql('SELECT status FROM visit WHERE id = ?', visitId)).toEqual([['completed']])
    expect(errors).toEqual([])
  })
})

