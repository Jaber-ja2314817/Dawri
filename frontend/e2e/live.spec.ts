import {
  expect,
  expectNotReloaded,
  fatimaToCentre,
  imHere,
  markThePage,
  reserveHere,
  say,
  streamOpen,
  test,
  TRIAGE_COUNTER,
} from './fixtures'

const STREAM = '**/api/visits/*/stream*'

test('with the stream down, a nurse action still lands by polling and the screen says so', async ({
  page,
  api,
}) => {
  await page.route(STREAM, (route) => route.abort())
  await fatimaToCentre(page)
  await reserveHere(page)
  await imHere(page)
  await markThePage(page)

  const freshness = page.getByTestId('freshness')
  await expect(freshness).toBeVisible()
  await expect(freshness).toContainText(say('ar', 'ticket.slower'))
  await expect(page.getByTestId('ticket-card')).toHaveAttribute('data-live', 'polling')

  const called = await api.callNext(TRIAGE_COUNTER)
  expect(called.called.number).toBe('T-014')
  await expect(page.getByTestId('ticket-called')).toBeVisible({ timeout: 6_000 })
  await expectNotReloaded(page)
})

test('a demo reset under an open S10 goes Home with the notice', async ({ page, api }) => {
  await fatimaToCentre(page)
  await reserveHere(page)
  await imHere(page)
  await streamOpen(page)

  await api.reset()
  await page.waitForURL('**/home', { timeout: 6_000 })
  await expect(page.getByRole('status').filter({ hasText: say('ar', 'home.demoReset') })).toBeVisible()
  await expect(page.getByTestId('open-visit')).toHaveCount(0)
})
