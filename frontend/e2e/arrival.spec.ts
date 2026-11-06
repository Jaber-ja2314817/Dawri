import { expect, fatimaToCentre, reserveHere, say, test, type Page } from './fixtures'

const CENTRE = { latitude: 25.17302, longitude: 51.59575 }
// 0.0018 degrees of latitude is 200 m on the ground, near enough for the 150 m fence.
const AWAY = { latitude: CENTRE.latitude + 0.0018, longitude: CENTRE.longitude }

async function countGeolocationCalls(page: Page) {
  await page.addInitScript(() => {
    const counted = window as unknown as { __geoCalls: number }
    counted.__geoCalls = 0
    for (const name of ['getCurrentPosition', 'watchPosition'] as const) {
      const real = navigator.geolocation[name].bind(navigator.geolocation)
      navigator.geolocation[name] = ((...args: Parameters<typeof real>) => {
        counted.__geoCalls += 1
        return real(...args)
      }) as typeof navigator.geolocation.getCurrentPosition
    }
  })
}

const geoCalls = (page: Page) =>
  page.evaluate(() => (window as unknown as { __geoCalls: number }).__geoCalls)

test.describe('at the centre', () => {
  test.use({ geolocation: CENTRE, permissions: ['geolocation'] })

  test('the centre own coordinates give T-014, and no prompt comes before a tap', async ({
    page,
  }) => {
    await countGeolocationCalls(page)
    await fatimaToCentre(page)
    expect(await geoCalls(page)).toBe(0)
    await reserveHere(page)
    await page.reload()
    await expect(page.getByTestId('check-location')).toBeVisible()
    await page.waitForTimeout(300)
    expect(await geoCalls(page)).toBe(0)

    await page.getByTestId('check-location').click()
    await page.waitForURL('**/ticket')
    await expect(page.getByTestId('ticket-number')).toHaveText('T-014')
    expect(await geoCalls(page)).toBe(1)
  })

  test('S08 Use my location shows the distance to each centre', async ({ page }) => {
    await fatimaToCentre(page)
    await page.getByTestId('view-list').click()
    await expect(page.getByTestId('selected-centre')).not.toContainText('المسافة')

    await page.getByTestId('use-location').click()
    await expect(page.getByTestId('selected-centre')).toContainText('المسافة')
    await expect(page.getByTestId('selected-centre')).toContainText(/0 كم/)
    await expect(page.getByTestId('centre-row').first()).toContainText('كم')
  })
})

test.describe('200 m away', () => {
  test.use({ geolocation: AWAY, permissions: ['geolocation'] })

  test('too far shows the distance, and the button still works', async ({ page }) => {
    await fatimaToCentre(page)
    await reserveHere(page)

    await page.getByTestId('check-location').click()
    const notice = page.getByRole('status').filter({ hasText: 'م من المركز' })
    await expect(notice).toBeVisible()
    await expect(notice).toContainText('200')
    await expect(notice).toContainText('150')
    await expect(page.getByTestId('ticket-number')).toHaveCount(0)

    await page.getByTestId('im-here').click()
    await page.waitForURL('**/ticket')
    await expect(page.getByTestId('ticket-number')).toHaveText('T-014')
  })
})

test('a denied location points to I am here, which still works', async ({ page, context }) => {
  await context.clearPermissions() // No grant: Chrome itself refuses the position.
  await fatimaToCentre(page)
  await reserveHere(page)

  await page.getByTestId('check-location').click()
  await expect(page.getByRole('status').filter({ hasText: say('ar', 'reserved.locationFailed') })).toBeVisible()
  await expect(page.getByTestId('im-here')).toBeEnabled()

  await page.getByTestId('im-here').click()
  await page.waitForURL('**/ticket')
  await expect(page.getByTestId('ticket-number')).toHaveText('T-014')
})
