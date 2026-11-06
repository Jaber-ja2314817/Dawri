import {
  backdateReservation,
  expect,
  fatimaToCentre,
  reserveHere,
  say,
  test,
  ticketRows,
  visitIdOf,
} from './fixtures'

test('a lapsed check-in shows expired, and choosing again needs no second chat', async ({
  page,
}) => {
  await fatimaToCentre(page)
  await reserveHere(page)
  const visitId = visitIdOf(page)
  const messages = await page.evaluate(async (id) => {
    const token = localStorage.getItem('dawri.token')
    const response = await fetch(`/api/visits/${id}`, {
      headers: { Authorization: `Bearer ${token}` },
    })
    return (await response.json()).chat.messages.length
  }, visitId)

  backdateReservation(visitId)
  await page.reload()

  await expect(page.locator('h1')).toHaveText(say('ar', 'reserved.expiredTitle'))
  await expect(page.getByTestId('countdown')).toHaveCount(0)
  await expect(page.getByTestId('ticket-number')).toHaveCount(0)
  await expect(page.getByTestId('im-here')).toHaveCount(0)
  await expect(page.locator('main')).not.toContainText(/[TDP]-(GP-)?\d{3}/)

  await page.getByTestId('choose-again').click()
  await page.waitForURL('**/centre')
  await expect(page.getByTestId('chat-input')).toHaveCount(0)
  await reserveHere(page)
  await expect(page.getByTestId('countdown')).toHaveText(/^44:\d\d$/)
  expect(ticketRows(visitId)).toBe(2)

  const after = await page.evaluate(async (id) => {
    const token = localStorage.getItem('dawri.token')
    const response = await fetch(`/api/visits/${id}`, {
      headers: { Authorization: `Bearer ${token}` },
    })
    return (await response.json()).chat.messages.length
  }, visitId)
  expect(after).toBe(messages)
})

test('the live countdown reaching zero turns S09 to expired with no reload', async ({ page }) => {
  await fatimaToCentre(page)
  await reserveHere(page)
  const visitId = visitIdOf(page)

  // The server keeps its own 45 minutes, so only the clock on screen is brought forward.
  const soon = new Date(Date.now() + 4_000).toISOString().replace('Z', '+00:00')
  await page.route(`**/api/visits/${visitId}`, async (route) => {
    const response = await route.fetch()
    const visit = await response.json()
    if (visit.ticket?.state === 'reserved') visit.ticket.expires_at = soon
    await route.fulfill({ response, json: visit })
  })
  await page.reload()

  const countdown = page.getByTestId('countdown')
  await expect(countdown).toHaveText(/^00:0[0-3]$/)

  // What the screen must not do is sit at 00:00: at zero it asks the server, and the server says so.
  backdateReservation(visitId)
  await expect(page.locator('h1')).toHaveText(say('ar', 'reserved.expiredTitle'), {
    timeout: 8_000,
  })
  await expect(page.getByTestId('im-here')).toHaveCount(0)
})
