import {
  agree,
  documentLoads,
  DOCTOR,
  DESK,
  expect,
  expectNotReloaded,
  fatimaToCentre,
  liveConsole,
  login,
  markThePage,
  NURSE,
  PHARMACIST,
  QID,
  queueNumbers,
  queueRow,
  reserveHere,
  send,
  sql,
  startCheckIn,
  streamOpen,
  test,
  ticketRows,
  vitalsToDraft,
  visitIdOf,
  type BrowserContext,
} from './fixtures'

/*
 * The acceptance tests of 01 Enhanced Prompt, in its own words, one test each.
 * A1 needs the stand-in server, so it lives in real-mode.spec.ts.
 */

const TO_TABLE_MS = 1_500
const TO_PHONE_MS = 2_000
const WALK_IN = 'sore throat since yesterday'
const SALEM = 'P006'
const SUMMARY_EDIT = 'Nurse: temperature taken at home was 38.5, no rash.'
const HANDOFF_EDIT = 'Nurse note: asked for a sick note for work.'

const ticket = (visitId: string) =>
  sql('SELECT state, number, seq FROM ticket WHERE visit_id = ?', visitId)

/** Runs the tap, then measures how long until the sign shows on the other screen. */
async function timed(tap: () => Promise<void>, shown: () => Promise<void>) {
  const tapped = Date.now()
  await tap()
  await shown()
  return Date.now() - tapped
}

/** Another staff member in the same browser context. Open tabs keep their own session. */
async function staffTab(context: BrowserContext, staffId: string) {
  const tab = await context.newPage()
  await tab.goto('/staff/login')
  await tab.waitForURL((url) => url.pathname !== '/staff/login')
  await tab.getByTestId('staff-logout').click()
  await tab.waitForURL('**/staff/login')
  await tab.getByTestId(`staff-chip-${staffId}`).click()
  await tab.waitForURL((url) => url.pathname !== '/staff/login')
  await liveConsole(tab)
  return tab
}

test('A2 "Chest pain spreading to my arm" reaches the emergency screen with no ticket', async ({
  page,
}) => {
  await login(page, 'P003')
  await startCheckIn(page, 'en')
  await agree(page, 'en')
  const visitId = visitIdOf(page)

  await send(page, 'Chest pain spreading to my arm')
  await page.waitForURL('**/emergency')
  await expect(page.getByTestId('emergency-call')).toHaveAttribute('href', 'tel:999')
  await expect(page.getByTestId('emergency-nearest')).toContainText('Hamad General Hospital')
  await expect(page.getByTestId('ticket-number')).toHaveCount(0)
  expect(ticketRows(visitId)).toBe(0)
  expect(sql('SELECT status FROM visit WHERE id = ?', visitId)).toEqual([['redirected_emergency']])
})

test('A3 "I need my usual blood pressure pills" is offered the refill route', async ({ page }) => {
  await login(page, 'P002')
  await startCheckIn(page)
  await agree(page)
  const visitId = visitIdOf(page)

  await send(page, 'I need my usual blood pressure pills')
  await page.waitForURL('**/refill')
  await expect(page.getByTestId('refill-medicine')).toContainText('أملوديبين')
  await expect(page.getByTestId('refill-message')).toBeVisible()
  await expect(page.getByTestId('ticket-number')).toHaveCount(0)
  expect(ticketRows(visitId)).toBe(0)
  expect(sql('SELECT status, service FROM visit WHERE id = ?', visitId)).toEqual([
    ['deflected_refill', 'refill'],
  ])
})

test('A4 a ticket stays reserved until arrival, and activating it appends to the end', async ({
  page: phone,
  windows,
}) => {
  const nurse = await windows.staff(NURSE)
  await liveConsole(nurse)
  await fatimaToCentre(phone)
  await reserveHere(phone)
  const visitId = visitIdOf(phone)

  // Reserved: no number, no place, and nothing for the nurse to call.
  expect(ticket(visitId)).toEqual([['reserved', null, null]])
  await expect(phone.getByTestId('ticket-number')).toHaveCount(0)
  await expect(phone.locator('main')).not.toContainText(/T-\d/)
  await expect(phone.locator('main')).toContainText('تسجيل الوصول صالح لمدة 45 دقيقة')
  await phone.getByTestId('language-toggle').click()
  await expect(phone.locator('main')).toContainText('Check-in valid for 45 minutes')
  await phone.getByTestId('language-toggle').click()
  await expect(nurse.locator('[data-testid=queue-row][data-simulated=false]')).toHaveCount(0)

  // Someone with no phone registers at the desk while she is on her way.
  const desk = await windows.staff(DESK)
  await desk.goto('/staff/desk')
  await desk.getByTestId(`desk-chip-${SALEM}`).click()
  await desk.getByTestId('desk-complaint').fill(WALK_IN)
  await desk.getByTestId('desk-complaint').press('Enter')
  await expect(desk.getByTestId('walkin-number')).toHaveText('T-014')
  await expect(queueRow(nurse, 'T-014')).toContainText('Salem Al-Demo')
  expect(ticket(visitId)).toEqual([['reserved', null, null]])

  await phone.getByTestId('im-here').click()
  await phone.waitForURL('**/ticket')
  await expect(phone.getByTestId('ticket-number')).toHaveText('T-015')
  await expect(phone.getByTestId('people-ahead')).toContainText('4')

  const [[state, number, seq]] = ticket(visitId)
  expect([state, number]).toEqual(['active', 'T-015'])
  expect(seq).toBe(15)
  await expect(queueRow(nurse, 'T-015')).toContainText('Fatima Al-Demo')
  await expect.poll(() => queueNumbers(nurse)).toEqual([
    'T-011',
    'T-012',
    'T-013',
    'T-014',
    'T-015',
  ])
})

test('A5 the nurse edits the AI summary, and the doctor sees the edited version', async ({
  api,
  windows,
}) => {
  const { visitId } = await api.arrivedVisit(QID.fatima)
  const nurse = await windows.staff(NURSE)
  await nurse.getByTestId('call-next').click()
  await nurse.waitForURL(`**/staff/nurse/${visitId}`)

  const words = nurse.locator('[data-testid=patient-words] [data-testid=turn][data-role=patient] p')
  await expect(words.first()).toBeVisible()
  const said = await words.allTextContents()
  expect(said.length).toBeGreaterThanOrEqual(2)
  const transcript = sql('SELECT transcript FROM intake WHERE visit_id = ?', visitId)
  const original = await nurse.getByTestId('ai-summary').textContent()

  await nurse.getByTestId('intake-edit').click()
  await nurse.getByTestId('edit-summary_for_nurse').fill(SUMMARY_EDIT)
  await nurse.getByTestId('intake-save').click()
  await expect(nurse.getByTestId('intake-form')).toHaveCount(0)
  await expect(nurse.getByTestId('ai-summary')).toHaveText(SUMMARY_EDIT)
  expect(await words.allTextContents()).toEqual(said)

  await vitalsToDraft(nurse, visitId)
  const draft = nurse.getByTestId('handoff-text')
  const lines = (await draft.inputValue()).split('\n')
  lines[1] = `${lines[1]} ${HANDOFF_EDIT}`
  await draft.fill(lines.join('\n'))
  await nurse.getByTestId('handoff-confirm').click()
  await expect(nurse.getByTestId('sent-number')).toHaveText('D-GP-023')

  const doctor = await windows.staff(DOCTOR)
  await doctor.getByTestId('call-next').click()
  await expect(doctor.getByTestId('at-counter')).toHaveAttribute('data-number', 'D-GP-023')
  await expect(doctor.getByTestId('handoff-summary')).toHaveText(SUMMARY_EDIT)
  await expect(doctor.getByTestId('handoff-card')).toContainText(HANDOFF_EDIT)
  await expect(doctor.locator('main')).not.toContainText(original as string)

  await doctor.getByTestId('doctor-patient-words').locator('summary').click()
  await expect(doctor.getByTestId('doctor-patient-words').locator('li')).toHaveText(said)
  expect(sql('SELECT transcript FROM intake WHERE visit_id = ?', visitId)).toEqual(transcript)
})

test('A6 two browsers, patient and staff, update live without refresh', async ({
  page: phone,
  windows,
}) => {
  test.setTimeout(120_000)
  const nurse = await windows.staff(NURSE)
  const staffContext = nurse.context()
  await liveConsole(nurse)
  const doctor = await staffTab(staffContext, DOCTOR)
  const pharmacy = await staffTab(staffContext, PHARMACIST)
  expect(staffContext).not.toBe(phone.context())

  await fatimaToCentre(phone)
  await reserveHere(phone)
  const visitId = visitIdOf(phone)

  await markThePage(phone)
  await markThePage(nurse)
  const phoneLoads = documentLoads(phone)
  const nurseLoads = documentLoads(nurse)
  const took: Record<string, number> = {}

  took.toTable = await timed(
    () => phone.getByTestId('im-here').click(),
    () => queueRow(nurse, 'T-014').waitFor({ state: 'visible', timeout: TO_TABLE_MS }),
  )
  expect(took.toTable).toBeLessThan(TO_TABLE_MS)
  await phone.waitForURL('**/ticket')
  await expect(phone.getByTestId('ticket-number')).toHaveText('T-014')
  await streamOpen(phone)

  took.called = await timed(
    () => nurse.getByTestId('call-next').click(),
    () => phone.getByTestId('ticket-called').waitFor({ state: 'visible', timeout: TO_PHONE_MS }),
  )
  expect(took.called).toBeLessThan(TO_PHONE_MS)
  await nurse.waitForURL(`**/staff/nurse/${visitId}`)
  await vitalsToDraft(nurse, visitId)

  const dTicket = phone.getByTestId('ticket-number').getByText('D-GP-023')
  took.doctorTicket = await timed(
    () => nurse.getByTestId('handoff-confirm').click(),
    () => dTicket.waitFor({ state: 'visible', timeout: TO_PHONE_MS }),
  )
  expect(took.doctorTicket).toBeLessThan(TO_PHONE_MS)

  await doctor.getByTestId('call-next').click()
  await expect(doctor.getByTestId('at-counter')).toHaveAttribute('data-number', 'D-GP-023')
  await doctor.getByTestId('drug-DR-PARA').check()
  const pTicket = phone.getByTestId('ticket-number').getByText('P-031')
  took.pharmacyTicket = await timed(
    () => doctor.getByTestId('consult-done').click(),
    () => pTicket.waitFor({ state: 'visible', timeout: TO_PHONE_MS }),
  )
  expect(took.pharmacyTicket).toBeLessThan(TO_PHONE_MS)

  await pharmacy.getByTestId('call-next').click()
  await expect(pharmacy.getByTestId('at-counter')).toHaveAttribute('data-number', 'P-031')
  took.complete = await timed(
    () => pharmacy.getByTestId('dispensed').click(),
    () => phone.waitForURL('**/complete', { timeout: TO_PHONE_MS }),
  )
  expect(took.complete).toBeLessThan(TO_PHONE_MS)
  await expect(phone.getByTestId('medicine').first()).toContainText('باراسيتامول')

  await expectNotReloaded(phone)
  await expectNotReloaded(nurse)
  expect(phoneLoads()).toBe(0)
  expect(nurseLoads()).toBe(0)
  console.log(`A6 live updates in ms: ${JSON.stringify(took)}`)
})
