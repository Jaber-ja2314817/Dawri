import { expect, login, test } from './fixtures'

test('the manifest is served with its own type and all three icons are reachable', async ({
  request,
}) => {
  const manifest = await request.get('/manifest.webmanifest')
  expect(manifest.status()).toBe(200)
  expect(manifest.headers()['content-type']).toContain('application/manifest+json')

  const icons = (await manifest.json()).icons as { src: string }[]
  expect(icons.length).toBeGreaterThanOrEqual(3)
  const sources = [...new Set(icons.map((icon) => icon.src))]
  expect(sources.length).toBe(3)
  for (const src of sources) {
    const icon = await request.get(src)
    expect(icon.status(), src).toBe(200)
    expect(icon.headers()['content-type'], src).toContain('image/png')
  }
})

test('no service worker is registered, on any screen of a session', async ({ page }) => {
  await login(page, 'P001')
  const registrations = await page.evaluate(
    async () => (await navigator.serviceWorker.getRegistrations()).length,
  )
  expect(registrations).toBe(0)
})

test('deep links load through the SPA fallback', async ({ page, request }) => {
  for (const path of ['/visit/x/ticket', '/history']) {
    const response = await request.get(path)
    expect(response.status(), path).toBe(200)
    expect(response.headers()['content-type'], path).toContain('text/html')
    expect(await response.text(), path).toContain('<div id="root">')
  }

  await login(page, 'P001')
  await page.goto('/history')
  await expect(page.locator('h1')).toHaveText('السجل')
  await page.goto('/visit/x/ticket')
  await page.waitForURL('**/home') // No such visit.
})

test('IBM Plex Sans Arabic comes from the build and is loaded', async ({ page }) => {
  await login(page, 'P001')
  await page.evaluate(() => document.fonts.ready)
  const fonts = await page.evaluate(() =>
    [...document.fonts].filter((font) => font.status === 'loaded').map((font) => font.family),
  )
  expect(fonts.some((family) => family.includes('IBM Plex Sans Arabic'))).toBe(true)
  const check = await page.evaluate(() => document.fonts.check('16px "IBM Plex Sans Arabic"', 'م'))
  expect(check).toBe(true)
  const face = await page.evaluate(() => getComputedStyle(document.body).fontFamily)
  expect(face).toContain('IBM Plex Sans Arabic')
})
