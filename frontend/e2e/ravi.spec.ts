import {
  agree,
  eventRows,
  expect,
  login,
  RAVI_WORDS,
  say,
  send,
  startCheckIn,
  test,
  ticketRows,
  visitIdOf,
  type Route,
} from './fixtures'

const SUPPORTIVE = /talk to someone|you are not alone/i

test.beforeEach(async ({ page }) => {
  await login(page, 'P003')
  await expect(page.locator('html')).toHaveAttribute('lang', 'en')
  await expect(page.locator('html')).toHaveAttribute('dir', 'ltr')
  await expect(page.getByRole('button', { name: 'Start check-in' })).toBeVisible()
})

test('Ravi reaches the emergency route with no ticket, and nothing leads back to chat', async ({
  page,
}) => {
  await startCheckIn(page, 'en')
  await agree(page, 'en')
  const visitId = visitIdOf(page)

  await send(page, RAVI_WORDS)
  await page.waitForURL('**/emergency')
  const emergencyUrl = page.url()
  await expect(page.getByTestId('emergency-call')).toHaveAttribute('href', 'tel:999')
  await expect(page.getByTestId('emergency-nearest')).toContainText('Hamad General Hospital')
  await expect(page.getByTestId('chat-input')).toHaveCount(0)
  expect(ticketRows(visitId)).toBe(0)

  await page.goBack()
  await page.waitForTimeout(400)
  expect(page.url()).toBe(emergencyUrl)
  await expect(page.getByTestId('emergency-call')).toBeVisible()

  await page.getByTestId('emergency-override').click()
  await expect(page.getByTestId('emergency-route')).toContainText(
    'Speak to a member of staff at the centre, or call 999',
  )
  expect(ticketRows(visitId)).toBe(0)
  expect(eventRows(visitId, 'emergency.override')).toBe(1)

  await page.getByTestId('emergency-home').click()
  await page.waitForURL('**/home')
  await startCheckIn(page, 'en')
  await page.getByRole('button', { name: say('en', 'consent.agree') }).click()
  await page.waitForURL(`**/visit/${visitId}/emergency`)
  await expect(page.getByTestId('emergency-call')).toBeVisible()
  await expect(page.getByTestId('chat-input')).toHaveCount(0)
  await expect(page.locator('input, textarea')).toHaveCount(0)
  expect(ticketRows(visitId)).toBe(0)
})

test('the chat answer alone reaches S06 and 999, even if nothing else can load', async ({
  page,
}) => {
  await startCheckIn(page, 'en')
  await agree(page, 'en')
  const visitId = visitIdOf(page)
  await expect(page.getByTestId('chat-input')).toBeVisible()

  // The venue's connection drops right after the message lands.
  await page.route('**/api/visits/*/stream*', (route) => route.abort())
  const offline = (route: Route) =>
    route.request().method() === 'GET' ? route.abort() : route.continue()
  await page.route(`**/api/visits/${visitId}`, offline)

  await send(page, RAVI_WORDS)
  await page.waitForURL('**/emergency')
  await expect(page.getByTestId('emergency-call')).toHaveAttribute('href', 'tel:999')
  await expect(page.locator('h1')).toHaveText('Go to Emergency now')
  await expect(page.getByTestId('chat-input')).toHaveCount(0)
  await expect(page.locator('input, textarea')).toHaveCount(0)
  await expect(page.getByTestId('footer')).toBeVisible()
  await expect(page.getByTestId('language-toggle')).toBeVisible()
  expect(ticketRows(visitId)).toBe(0)
  await page.screenshot({
    path: `${process.env.DAWRI_E2E_ROOT}/.taste-skill/inspect/playwright/s06-before-load-en-390.png`,
  })

  // The rest of the screen arrives when the connection does.
  await page.unroute(`**/api/visits/${visitId}`, offline)
  await expect(page.getByTestId('emergency-nearest')).toContainText('Hamad General Hospital', {
    timeout: 6_000,
  })
})

test('a red flag after several normal turns still stops the chat at once', async ({ page }) => {
  await startCheckIn(page, 'en')
  await agree(page, 'en')
  const visitId = visitIdOf(page)

  await send(page, 'I have a headache')
  await send(page, 'for two days')
  await send(page, 'about 4')
  await expect(page.locator('[data-testid=bubble][data-role=user]')).toHaveCount(3)
  expect(new URL(page.url()).pathname).toMatch(/\/chat$/)

  await send(page, 'now I have chest pain going to my left arm')
  await page.waitForURL('**/emergency')
  await expect(page.getByTestId('emergency-call')).toHaveAttribute('href', 'tel:999')
  expect(ticketRows(visitId)).toBe(0)
})

test('a self-harm message shows the supportive line with 999', async ({ page }) => {
  await startCheckIn(page, 'en')
  await agree(page, 'en')
  const visitId = visitIdOf(page)

  await send(page, 'I want to end my life')
  await page.waitForURL('**/emergency')
  await expect(page.getByTestId('emergency-reply')).toHaveText(SUPPORTIVE)
  await expect(page.getByTestId('emergency-call')).toHaveAttribute('href', 'tel:999')
  expect(ticketRows(visitId)).toBe(0)
})
