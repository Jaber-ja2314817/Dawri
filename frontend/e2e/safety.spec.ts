import {
  agree,
  answerToSummary,
  expect,
  expectNotReloaded,
  fatimaToCentre,
  imHere,
  login,
  markThePage,
  QID,
  RAVI_WORDS,
  reserveHere,
  say,
  send,
  startCheckIn,
  streamOpen,
  test,
  ticketRows,
  TRIAGE_COUNTER,
  visitIdOf,
  type Page,
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

/** The server answers the turn at once, and the page only hears when the test says so. */
async function holdTheReply(page: Page, visitId: string) {
  let answered!: () => void
  const landed = new Promise<void>((resolve) => {
    answered = resolve
  })
  let release!: () => void
  const held = new Promise<void>((resolve) => {
    release = resolve
  })
  await page.route(`**/api/visits/${visitId}/chat`, async (route) => {
    const response = await route.fetch()
    answered()
    await held
    // A page that gave up on the request leaves nothing to answer.
    await route.fulfill({ response }).catch(() => {})
  })
  return { landed, release }
}

async function raviSendsAndLeaves(page: Page) {
  await login(page, 'P003')
  await startCheckIn(page, 'en')
  await agree(page, 'en')
  const visitId = visitIdOf(page)
  const reply = await holdTheReply(page, visitId)
  await page.getByTestId('chat-input').fill(RAVI_WORDS)
  await page.getByTestId('chat-send').click()
  await expect(page.getByTestId('chat-thinking')).toBeVisible()
  await reply.landed
  await page.getByTestId('back').click()
  await page.waitForURL('**/home')
  return { visitId, release: reply.release }
}

test('a red-flag reply that lands after the patient left chat takes them from Home to S06', async ({
  page,
}) => {
  const { visitId, release } = await raviSendsAndLeaves(page)
  await markThePage(page)
  await expect(page.getByTestId('emergency-call')).toHaveCount(0)

  release()
  await page.waitForURL(`**/visit/${visitId}/emergency`)
  await expect(page.getByTestId('emergency-call')).toHaveAttribute('href', 'tel:999')
  await expect(page.locator('input, textarea')).toHaveCount(0)
  await expectNotReloaded(page)
  expect(ticketRows(visitId)).toBe(0)
})

test('a red-flag reply reaches S06 from a screen further on than Home', async ({ page }) => {
  const { visitId, release } = await raviSendsAndLeaves(page)
  await page.getByRole('link', { name: say('en', 'home.history') }).click()
  await page.waitForURL('**/history')

  release()
  await page.waitForURL(`**/visit/${visitId}/emergency`)
  await expect(page.getByTestId('emergency-call')).toBeVisible()
  expect(ticketRows(visitId)).toBe(0)
})

test("today's emergency stays open on Home, and its card leads to S06", async ({ page }) => {
  await login(page, 'P003')
  await startCheckIn(page, 'en')
  await agree(page, 'en')
  const visitId = visitIdOf(page)
  await send(page, RAVI_WORDS)
  await page.waitForURL('**/emergency')

  await page.goto('/home')
  const card = page.getByTestId('open-visit')
  await expect(card).toContainText(say('en', 'status.redirected_emergency'))
  await card.click()
  await page.waitForURL(`**/visit/${visitId}/emergency`)
  await expect(page.getByTestId('emergency-call')).toHaveAttribute('href', 'tel:999')
  expect(ticketRows(visitId)).toBe(0)
})

test('words left in the box hold Yes at the summary, and Send reaches S06 with no ticket', async ({
  page,
}) => {
  await login(page, 'P001')
  await startCheckIn(page)
  await page.getByTestId('who-P001').click()
  await agree(page)
  const visitId = visitIdOf(page)
  await answerToSummary(page)

  const yes = page.getByTestId('chat-summary-yes')
  const line = page.getByTestId('chat-summary-unsent')
  const box = page.getByTestId('chat-input')
  await expect(yes).toBeEnabled()
  await expect(line).toHaveCount(0)

  await box.fill('chest pain')
  await expect(yes).toBeDisabled()
  await expect(line).toHaveText(say('ar', 'chat.summary.unsent'))
  await page.getByTestId('language-toggle').click()
  await expect(line).toHaveText(say('en', 'chat.summary.unsent'))
  await page.getByTestId('language-toggle').click()

  await box.fill('')
  await expect(yes).toBeEnabled()
  await expect(line).toHaveCount(0)

  await box.fill('chest pain')
  await expect(yes).toBeDisabled()
  await page.getByTestId('chat-send').click()
  await page.waitForURL(`**/visit/${visitId}/emergency`)
  await expect(page.getByTestId('emergency-call')).toHaveAttribute('href', 'tel:999')
  expect(ticketRows(visitId)).toBe(0)
})
