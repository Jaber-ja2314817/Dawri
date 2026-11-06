import {
  expect,
  expectNotReloaded,
  fatimaToCentre,
  imHere,
  markThePage,
  QID,
  reserveHere,
  streamOpen,
  test,
  ticketRows,
  TRIAGE_COUNTER,
  visitIdOf,
} from './fixtures'

const textBoxes = 'input, textarea'

test('a deep link to chat on a reserved visit shows no chat box', async ({ page }) => {
  await fatimaToCentre(page)
  await reserveHere(page)
  const visitId = visitIdOf(page)

  await page.goto(`/visit/${visitId}/chat`)
  await page.waitForURL(`**/visit/${visitId}/reserved`)
  await expect(page.getByTestId('countdown')).toBeVisible()
  await expect(page.locator(textBoxes)).toHaveCount(0)
})

test('a deep link to chat at triage shows no chat box', async ({ page }) => {
  await fatimaToCentre(page)
  await reserveHere(page)
  await imHere(page)
  const visitId = visitIdOf(page)

  await page.goto(`/visit/${visitId}/chat`)
  await page.waitForURL(`**/visit/${visitId}/ticket`)
  await expect(page.getByTestId('ticket-number')).toHaveText('T-014')
  await expect(page.locator(textBoxes)).toHaveCount(0)
})

test('a deep link to chat on a completed visit lands on S11 with no chat box', async ({
  page,
  api,
}) => {
  await fatimaToCentre(page)
  await reserveHere(page)
  await imHere(page)
  const visitId = visitIdOf(page)

  await api.callNext(TRIAGE_COUNTER)
  await api.vitals(visitId)
  await api.handoff(visitId)
  await api.consultDone(visitId)
  await api.dispensed(visitId)
  await page.waitForURL('**/complete')

  await page.goto(`/visit/${visitId}/chat`)
  await page.waitForURL(`**/visit/${visitId}/complete`)
  await expect(page.getByTestId('complete-check')).toBeVisible()
  await expect(page.getByTestId('chat-input')).toHaveCount(0)
  await expect(page.locator(textBoxes)).toHaveCount(0)
})

test('a nurse sending the patient to the ED moves an open S10 to S06 with no reload', async ({
  page,
  api,
}) => {
  await fatimaToCentre(page)
  await reserveHere(page)
  await imHere(page)
  const visitId = visitIdOf(page)
  await streamOpen(page)
  await markThePage(page)

  await api.callNext(TRIAGE_COUNTER)
  await expect(page.getByTestId('ticket-called')).toBeVisible({ timeout: 2_000 })
  const result = await api.vitals(visitId, 'urgent')
  expect(result.escalated).toBe(true)

  await page.waitForURL('**/emergency', { timeout: 2_000 })
  await expect(page.getByTestId('emergency-call')).toHaveAttribute('href', 'tel:999')
  await expect(page.getByTestId('ticket-number')).toHaveCount(0)
  await expectNotReloaded(page)

  // The ticket row stays as a record, and it is finished: nothing on it can be called.
  expect(ticketRows(visitId)).toBe(1)
  const patient = await api.patient(QID.fatima)
  const visit = await api.getVisit(patient.token, visitId)
  expect(visit.stage).toBe('emergency')
  expect(visit.ticket?.state ?? 'none').not.toMatch(/active|called|serving|reserved/)
})
