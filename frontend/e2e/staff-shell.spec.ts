import {
  DESK,
  DOCTOR,
  expect,
  NURSE,
  PHARMACIST,
  QID,
  say,
  staffLogin,
  test,
  TRIAGE_COUNTER,
  type Page,
} from './fixtures'

const DESKTOP = { width: 1440, height: 900 }
const PHONE = { width: 390, height: 844 }
const TOKEN = 'dawri.token'
const STAFF_TOKEN = 'dawri.staff.token'

test.use({ viewport: DESKTOP })

const stored = (page: Page, key: string) =>
  page.evaluate((name) => localStorage.getItem(name), key)

async function expectAiPill(page: Page, where: string) {
  const pill = page.getByTestId('ai-mode')
  await expect(pill, where).toBeVisible()
  await expect(pill, where).toHaveAttribute('data-mode', 'simulated')
  await expect(page.getByTestId('staff-sheet'), `${where}, no menu open`).toHaveCount(0)
}

async function expectNoSideScroll(page: Page, where: string) {
  const widths = await page.evaluate(() => ({
    content: document.documentElement.scrollWidth,
    screen: window.innerWidth,
  }))
  expect(widths.content, where).toBeLessThanOrEqual(widths.screen)
}

test('each of the four roles signs in by chip and lands on its console', async ({ page }) => {
  const roles = [
    [NURSE, '/staff/nurse', 'Amal Al-Demo'],
    [DOCTOR, '/staff/doctor', 'Dr. Noor Al-Demo'],
    [PHARMACIST, '/staff/pharmacy', 'Hassan Al-Demo'],
    [DESK, '/staff/desk', 'Dana Al-Demo'],
  ] as const
  for (const [staffId, path, name] of roles) {
    await staffLogin(page, staffId)
    await expect(page).toHaveURL(new RegExp(`${path}$`))
    await expect(page.getByTestId('staff-name')).toContainText(name)
    await expect(page.getByTestId('centre-name')).toContainText('Al Wakra Health Centre')
    await expect(page.locator('html')).toHaveAttribute('lang', 'en')
    await page.getByTestId('staff-logout').click()
    await page.waitForURL('**/staff/login')
  }
})

test('T01 asks who is working, by role and centre, with the note on Dr. Noor', async ({ page }) => {
  await page.goto('/staff/login')
  await expect(page.locator('h1')).toHaveText(say('ar', 'staff.login.title'))
  await page.getByTestId('language-toggle').click()
  await expect(page.locator('h1')).toHaveText('Who is working?')
  for (const role of ['nurse', 'doctor', 'pharmacist', 'desk']) {
    await expect(page.getByTestId(`staff-group-${role}`)).toBeVisible()
  }
  await expect(page.getByTestId(`staff-chip-${DOCTOR}`)).toContainText('Dr. Noor Al-Demo')
  await expect(page.getByTestId(`staff-chip-${DOCTOR}`)).toContainText('Room 4')
  await expect(page.getByTestId('noor-note')).toHaveText(say('en', 'staff.login.noorNote'))
  await expect(page.getByTestId('footer')).toContainText(say('en', 'footer.demo'))

  await page.getByTestId('staff-centre').selectOption('C-RAYYAN')
  await expect(page.getByTestId('staff-chip-S-RAY-NURSE1')).toBeVisible()
  await expect(page.getByTestId(`staff-chip-${NURSE}`)).toHaveCount(0)
  await expect(page.getByTestId('noor-note')).toHaveCount(0)
})

test('T01 keeps working when the list fails, and offers a retry', async ({ page }) => {
  let refuse = true
  await page.route('**/api/staff/demo-staff', (route) =>
    refuse ? route.fulfill({ status: 500, json: { error: 'internal_error' } }) : route.fallback(),
  )
  await page.goto('/staff/login')
  await expect(page.getByRole('alert')).toBeVisible()
  await expect(page.getByTestId('ai-mode')).toBeVisible()
  refuse = false
  await page.getByRole('button', { name: say('ar', 'common.retry') }).click()
  await expect(page.getByTestId(`staff-chip-${NURSE}`)).toBeVisible()
})

test('T01 says so when a centre has nobody listed', async ({ page }) => {
  await page.route('**/api/staff/demo-staff', (route) => route.fulfill({ json: [] }))
  await page.goto('/staff/login')
  await expect(page.getByTestId('staff-empty')).toHaveText(say('ar', 'staff.login.empty'))
})

test('the AI pill shows on T01 and every console, at 1440 and at 390, no menu open', async ({
  page,
  api,
}) => {
  test.setTimeout(120_000)
  const { visitId } = await api.arrivedVisit(QID.fatima)
  const consoles = [
    [NURSE, ['/staff/nurse', `/staff/nurse/${visitId}`, `/staff/nurse/${visitId}/handoff`]],
    [NURSE, ['/staff/desk', '/staff/display', '/staff/dashboard']],
    [DOCTOR, ['/staff/doctor']],
    [PHARMACIST, ['/staff/pharmacy']],
    [DESK, ['/staff/desk']],
  ] as const

  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize(viewport)
    await page.goto('/staff/login')
    await expectAiPill(page, `T01 at ${viewport.width}`)
    await expectNoSideScroll(page, `T01 at ${viewport.width}`)
    await expect(page.getByTestId('language-toggle')).toBeVisible()
    await expect(page.getByTestId('footer')).toBeVisible()

    for (const [staffId, paths] of consoles) {
      await staffLogin(page, staffId)
      for (const path of paths) {
        await page.goto(path)
        await expect(page.locator('h1')).toBeVisible()
        await expect(page).toHaveURL(new RegExp(`${path}$`))
        await expectAiPill(page, `${path} at ${viewport.width}`)
        await expectNoSideScroll(page, `${path} at ${viewport.width}`)
      }
      await page.evaluate((key) => {
        localStorage.removeItem(key)
        sessionStorage.removeItem(key)
      }, STAFF_TOKEN)
    }
  }
})

test('the AI pill reads model in real mode', async ({ page }) => {
  await page.route('**/api/health', (route) =>
    route.fulfill({ json: { status: 'ok', ai_mode: 'real', simulate_load: true } }),
  )
  await staffLogin(page, NURSE)
  await expect(page.getByTestId('ai-mode')).toHaveAttribute('data-mode', 'real')
  await expect(page.getByTestId('ai-mode')).toHaveText('AI: model')
})

test('on a phone the bar folds, and the AI pill stays beside an open menu', async ({ page }) => {
  await page.setViewportSize(PHONE)
  await staffLogin(page, NURSE)
  await expect(page.getByTestId('staff-logout')).toHaveCount(0)
  await expect(page.getByTestId('reset-demo')).toHaveCount(0)

  const menu = page.getByTestId('staff-menu')
  const box = await menu.boundingBox()
  expect(box?.width).toBeGreaterThanOrEqual(44)
  expect(box?.height).toBeGreaterThanOrEqual(44)

  await menu.click()
  await expect(page.getByTestId('staff-sheet')).toBeVisible()
  await expect(page.getByTestId('ai-mode')).toBeVisible()
  await expect(page.getByTestId('staff-sheet').getByTestId('ai-mode')).toHaveCount(0)
  await expect(page.getByTestId('staff-nav-desk')).toBeVisible()
  await expect(page.getByTestId('language-toggle')).toBeVisible()
  await expect(page.getByTestId('reset-demo')).toBeVisible()
  await expect(page.getByTestId('staff-logout')).toBeVisible()

  await page.keyboard.press('Escape')
  await expect(page.getByTestId('staff-sheet')).toHaveCount(0)

  await menu.click()
  await page.getByTestId('staff-nav-display').click()
  await page.waitForURL('**/staff/display')
  await expect(page.getByTestId('staff-sheet')).toHaveCount(0)
  await expect(page.getByTestId('ai-mode')).toBeVisible()
})

test('at 320 px in Arabic the AI pill and the menu both still fit', async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 640 })
  await page.goto('/staff/login')
  await expect(page.getByTestId('ai-mode')).toBeVisible()
  await expect(page.getByTestId('language-toggle')).toBeVisible()
  await expectNoSideScroll(page, 'T01 at 320')

  await page.getByTestId(`staff-chip-${NURSE}`).click()
  await page.waitForURL('**/staff/nurse')
  await page.getByTestId('staff-menu').click()
  await page.getByTestId('language-toggle').click()
  await expect(page.locator('html')).toHaveAttribute('dir', 'rtl')
  await page.keyboard.press('Escape')
  await expect(page.getByTestId('ai-mode')).toBeVisible()
  await expect(page.getByTestId('staff-menu')).toBeVisible()
  await expectNoSideScroll(page, 'console at 320')
})

test('the nav follows the role: a nurse also gets the front desk', async ({ page }) => {
  await staffLogin(page, NURSE)
  await expect(page.getByTestId(/^staff-nav-/)).toHaveText([
    say('en', 'staff.nav.nurse'),
    say('en', 'staff.nav.desk'),
    say('en', 'staff.nav.display'),
    say('en', 'staff.nav.dashboard'),
  ])
  await page.getByTestId('staff-logout').click()
  await page.waitForURL('**/staff/login')

  await staffLogin(page, DOCTOR)
  await expect(page.getByTestId(/^staff-nav-/)).toHaveText([
    say('en', 'staff.nav.doctor'),
    say('en', 'staff.nav.display'),
    say('en', 'staff.nav.dashboard'),
  ])
})

test('a reload keeps the staff session', async ({ page }) => {
  await staffLogin(page, NURSE)
  await page.reload()
  await expect(page).toHaveURL(/\/staff\/nurse$/)
  await expect(page.getByTestId('staff-name')).toContainText('Amal Al-Demo')
  await page.goto('/staff')
  await page.waitForURL('**/staff/nurse')
  await page.goto('/staff/login')
  await page.waitForURL('**/staff/nurse')
})

test('patient and staff sessions live side by side in one browser', async ({ page, context }) => {
  await page.goto('/login')
  await page.getByTestId('chip-P001').click()
  await page.waitForURL('**/home')
  const patientToken = await stored(page, TOKEN)
  expect(patientToken).not.toBeNull()

  const tab = await context.newPage()
  const denied: string[] = []
  tab.on('response', (response) => {
    if (response.status() === 401 || response.status() === 403) denied.push(response.url())
  })
  await staffLogin(tab, NURSE)
  const staffToken = await stored(tab, STAFF_TOKEN)
  expect(staffToken).not.toBeNull()
  expect(staffToken).not.toBe(patientToken)
  expect(await stored(tab, TOKEN)).toBe(patientToken)

  await tab.reload()
  await expect(tab.getByTestId('staff-name')).toContainText('Amal Al-Demo')
  await page.reload()
  await expect(page.getByRole('button', { name: /./ }).first()).toBeVisible()
  await expect(page).toHaveURL(/\/home$/)

  await tab.getByTestId('staff-logout').click()
  await tab.waitForURL('**/staff/login')
  expect(await stored(tab, STAFF_TOKEN)).toBeNull()
  expect(await stored(tab, TOKEN)).toBe(patientToken)
  expect(denied).toEqual([])
})

test('a staff 401 ends the staff session and leaves the patient token alone', async ({
  page,
  api,
}) => {
  const { token } = await api.patient(QID.fatima)
  await page.goto('/staff/login')
  await page.evaluate(
    ([patientKey, patient, staffKey]) => {
      localStorage.setItem(patientKey, patient)
      localStorage.setItem(staffKey, 'not-a-real-session')
    },
    [TOKEN, token, STAFF_TOKEN],
  )
  const answer = page.waitForResponse('**/api/staff/me')
  await page.goto('/staff/nurse')
  expect((await answer).status()).toBe(401)
  await page.waitForURL('**/staff/login')
  expect(await stored(page, STAFF_TOKEN)).toBeNull()
  expect(await stored(page, TOKEN)).toBe(token)
})

test('a wrong role goes to its own console', async ({ page }) => {
  await staffLogin(page, DOCTOR)
  for (const path of ['/staff/nurse', '/staff/nurse/V_x', '/staff/pharmacy', '/staff/desk']) {
    await page.goto(path)
    await page.waitForURL('**/staff/doctor')
  }
  await page.goto('/staff/display')
  await expect(page).toHaveURL(/\/staff\/display$/)
})

test('signed out, a console goes to the staff login, not the patient one', async ({ page }) => {
  for (const path of ['/staff', '/staff/nurse', '/staff/dashboard']) {
    await page.goto(path)
    await page.waitForURL('**/staff/login')
    await expect(page.getByTestId(`staff-chip-${NURSE}`)).toBeVisible()
  }
})

test('an unknown staff path shows the staff not-found page', async ({ page }) => {
  await page.goto('/staff/no-such-page')
  await expect(page.getByTestId('staff-not-found')).toBeVisible()
  await expect(page.getByTestId('ai-mode')).toBeVisible()

  await staffLogin(page, NURSE)
  await page.goto('/staff/nurse/V_x/no-such-page')
  await expect(page.getByTestId('staff-not-found')).toBeVisible()
  await expect(page.locator('h1')).toHaveText(say('en', 'staff.notFound.title'))
  await page.getByRole('link', { name: say('en', 'staff.notFound.home') }).click()
  await page.waitForURL('**/staff/nurse')
})

test('log out ends the session', async ({ page }) => {
  await staffLogin(page, NURSE)
  await page.getByTestId('staff-logout').click()
  await page.waitForURL('**/staff/login')
  expect(await stored(page, STAFF_TOKEN)).toBeNull()
  await page.goto('/staff/nurse')
  await page.waitForURL('**/staff/login')
})

test('reset takes two taps, goes home and says so', async ({ page, api }) => {
  const queue = () => api.asStaff(NURSE, 'GET', `/api/counters/${TRIAGE_COUNTER}/queue`)
  await api.arrivedVisit(QID.fatima)
  const before = (await queue()).tickets.length

  await staffLogin(page, NURSE)
  await page.goto('/staff/dashboard')
  await page.getByTestId('reset-demo').click()
  expect((await queue()).tickets.length).toBe(before)

  await page.getByTestId('reset-cancel').click()
  await expect(page.getByTestId('reset-confirm')).toHaveCount(0)
  expect((await queue()).tickets.length).toBe(before)

  await page.getByTestId('reset-demo').click()
  await page.getByTestId('reset-confirm').click()
  await page.waitForURL('**/staff/nurse')
  await expect(page.getByTestId('staff-notice')).toHaveText(say('en', 'staff.reset.done'))
  expect((await queue()).tickets.length).toBe(before - 1)
  await expect(page.getByTestId('staff-name')).toContainText('Amal Al-Demo')
})

test('the language toggle sets dir on the staff screens', async ({ page }) => {
  await staffLogin(page, NURSE)
  const root = page.locator('html')
  await expect(root).toHaveAttribute('dir', 'ltr')
  await page.getByTestId('language-toggle').click()
  await expect(root).toHaveAttribute('dir', 'rtl')
  await expect(root).toHaveAttribute('lang', 'ar')
  // T02 is titled by its counter, in the console's language: see staff-nurse.
  await expect(page.locator('h1')).toHaveText('الفرز 1')
  await page.reload()
  await expect(page.locator('h1')).toHaveText('الفرز 1')
  await expect(root).toHaveAttribute('dir', 'rtl')
  await page.getByTestId('language-toggle').click()
  await expect(root).toHaveAttribute('dir', 'ltr')
})
