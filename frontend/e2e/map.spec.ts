import { expect, fatimaToCentre, reserveHere, say, serveTiles, test, TILES } from './fixtures'

test('with tiles blocked, S08 falls to the list with the notice and a reservation completes', async ({
  page,
}) => {
  await page.route(TILES, (route) => route.abort())
  await fatimaToCentre(page)

  const notice = page.getByTestId('map-failed')
  await expect(notice).toHaveText(say('ar', 'centre.mapFailed'))
  await expect(notice).toHaveAttribute('data-reason', 'tiles')
  await expect(page.getByTestId('centre-map')).toHaveCount(0)
  await expect(page.getByTestId('centre-row').first()).toHaveAttribute('data-centre-id', 'C-WAKRA')

  await page.getByTestId('centre-row').nth(1).click()
  await expect(page.getByTestId('centre-row').nth(1)).toHaveAttribute('aria-pressed', 'true')
  await page.getByTestId('centre-row').first().click()
  await reserveHere(page)
  await expect(page.locator('h1')).toHaveText('مركز الوكرة الصحي')
})

test('with tiles available, pins show their wait and a tap selects that centre', async ({
  page,
}) => {
  await serveTiles(page)
  const tileRequests: string[] = []
  page.on('response', (response) => {
    if (response.url().includes('tile.openstreetmap.org')) tileRequests.push(response.url())
  })
  await fatimaToCentre(page)
  // If the list ever replaces the map here, this line prints why.
  await expect(page.getByTestId('map-failed')).toHaveCount(0)
  await expect(page.getByTestId('centre-map')).toBeVisible()

  const wakra = page.locator('[data-testid=centre-pin][data-centre-id=C-WAKRA]')
  const airport = page.locator('[data-testid=centre-pin][data-centre-id=C-AIRPORT]')
  await expect(wakra).toBeVisible()
  await expect(wakra).toContainText('12')
  await expect(airport).toBeVisible()
  await expect(airport).toContainText(/3\d/)
  await expect(wakra).toHaveAttribute('aria-pressed', 'true')
  await expect(wakra).toHaveClass(/is-selected/)
  expect(tileRequests.length).toBeGreaterThan(0)

  await airport.click()
  await expect(airport).toHaveAttribute('aria-pressed', 'true')
  await expect(page.getByTestId('selected-centre')).toContainText('مركز المطار الصحي')
  await expect(wakra).toHaveAttribute('aria-pressed', 'false')

  // No failure notice while the tiles are good, however long the map stays up.
  await page.waitForTimeout(5_500)
  await expect(page.getByTestId('centre-map')).toBeVisible()
  await expect(page.getByTestId('map-failed')).toHaveCount(0)
})
