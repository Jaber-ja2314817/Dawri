import type { Browser } from '@playwright/test'
import {
  AHMED_WORDS,
  backdateReservation,
  expect,
  QID,
  RAVI_WORDS,
  say,
  serveTiles,
  test,
  TRIAGE_COUNTER,
  type Page,
} from './fixtures'

const FOOTER = {
  en: 'Demo — synthetic data, not connected to PHCC/HMC systems.',
  ar: 'تجريبي — بيانات اصطناعية، غير متصل بأنظمة PHCC/HMC.',
} as const
const AI_LINE = { en: 'AI: simulated', ar: say('ar', 'footer.ai') } as const

type Lang = 'ar' | 'en'

async function expectShell(page: Page, lang: Lang, where: string) {
  await expect(page.locator('h1').first(), `${where} h1`).toBeVisible()
  await expect(page.getByTestId('footer').locator('p').first(), `${where} footer`).toHaveText(
    FOOTER[lang],
  )
  await expect(page.getByTestId('footer-ai'), `${where} AI line`).toHaveText(AI_LINE[lang])
  await expect(page.getByTestId('language-toggle'), `${where} toggle`).toBeVisible()
  await expect(page.locator('html')).toHaveAttribute('lang', lang)
  await expect(page.locator('html')).toHaveAttribute('dir', lang === 'ar' ? 'rtl' : 'ltr')
  const widths = await page.evaluate(() => ({
    content: document.documentElement.scrollWidth,
    screen: window.innerWidth,
  }))
  expect(widths.content, `${where} width in ${lang}`).toBeLessThanOrEqual(widths.screen)

  // A phone is the main device, so every control has to take a thumb.
  const small = await page.evaluate(() =>
    [...document.querySelectorAll('a, button, input, textarea, select, [role=button]')]
      .filter((element) => getComputedStyle(element).visibility !== 'hidden')
      .map((element) => ({ element, box: element.getBoundingClientRect() }))
      .filter(({ box }) => box.width > 0 && (box.height < 44 || box.width < 44))
      .map(({ element, box }) => `${element.tagName} "${element.textContent?.slice(0, 30)}" ${Math.round(box.width)}x${Math.round(box.height)}`),
  )
  expect(small, `${where} touch targets in ${lang}`).toEqual([])
}

/** Each language on one route, reached by the toggle the patient would use. */
async function walk(page: Page, path: string) {
  await page.goto(path)
  await expect(page.getByTestId('language-toggle')).toBeVisible()
  for (const lang of ['ar', 'en'] as const) {
    const current = await page.locator('html').getAttribute('lang')
    if (current !== lang) await page.getByTestId('language-toggle').click()
    await expectShell(page, lang, path)
  }
}

async function signIn(browser: Browser, baseURL: string, token: string) {
  const context = await browser.newContext({
    baseURL,
    viewport: { width: 390, height: 844 },
    locale: 'en-GB',
  })
  // The record language has its own test at the end of this file; walk() needs one that cannot change under it.
  await context.addInitScript((value) => {
    localStorage.setItem('dawri.token', value)
    localStorage.setItem('dawri.lang.chosen', '1')
  }, token)
  const page = await context.newPage()
  await serveTiles(page)
  return page
}

test('every route of the visit carries the shell, in both languages at 390 px', async ({
  page,
  api,
  browser,
  baseURL,
}) => {
  test.setTimeout(120_000)
  for (const path of ['/', '/login']) await walk(page, path)

  const fatima = await api.patient(QID.fatima)
  const token = fatima.token as string
  const patient = await signIn(browser, baseURL as string, token)

  await walk(patient, '/home')
  await walk(patient, '/check-in/who')
  await walk(patient, '/check-in/consent?for=P001')
  await walk(patient, '/history') // Empty.
  await walk(patient, '/no-such-page')

  const visitId = await api.newVisit(token)
  await walk(patient, `/visit/${visitId}/chat`)
  await api.toSummary(token, visitId)
  await walk(patient, `/visit/${visitId}/chat`) // The summary card.
  await api.confirm(token, visitId)
  await walk(patient, `/visit/${visitId}/centre`)
  await api.reserve(token, visitId)
  await walk(patient, `/visit/${visitId}/reserved`)
  backdateReservation(visitId)
  await walk(patient, `/visit/${visitId}/reserved`) // Expired.

  await api.reserve(token, visitId)
  await api.arrive(token, visitId)
  await walk(patient, `/visit/${visitId}/ticket`)
  await api.callNext(TRIAGE_COUNTER)
  await walk(patient, `/visit/${visitId}/ticket`) // Called.
  await api.vitals(visitId)
  await api.handoff(visitId)
  await walk(patient, `/visit/${visitId}/ticket`) // The longer doctor number.
  await api.consultDone(visitId)
  await walk(patient, `/visit/${visitId}/ticket`) // Pharmacy.
  await api.dispensed(visitId)
  await walk(patient, `/visit/${visitId}/complete`)
  await walk(patient, '/history') // With a row.
  await patient.context().close()

  const ravi = await api.patient(QID.ravi)
  const raviVisit = await api.newVisit(ravi.token)
  await api.say(ravi.token, raviVisit, RAVI_WORDS)
  const raviPage = await signIn(browser, baseURL as string, ravi.token)
  await walk(raviPage, `/visit/${raviVisit}/emergency`)
  await raviPage.context().close()

  const ahmed = await api.patient(QID.ahmed)
  const ahmedVisit = await api.newVisit(ahmed.token)
  await api.say(ahmed.token, ahmedVisit, AHMED_WORDS)
  const ahmedPage = await signIn(browser, baseURL as string, ahmed.token)
  await walk(ahmedPage, `/visit/${ahmedVisit}/refill`)
  await ahmedPage.context().close()
})

test('the design tokens are what the running app computes', async ({ page }) => {
  await page.goto('/')
  const ground = await page.evaluate(() => getComputedStyle(document.body).backgroundColor)
  expect(ground).toBe('rgb(242, 244, 247)')

  const primary = page.getByRole('link', { name: say('ar', 'welcome.login') })
  await expect(primary).toHaveCSS('background-color', 'rgb(10, 10, 10)')
  await expect(primary).toHaveCSS('box-shadow', 'none')
  await expect(page.locator('h1')).toHaveCSS('color', 'rgb(10, 10, 10)')

  await page.goto('/login')
  await page.getByTestId('chip-P001').click()
  await page.waitForURL('**/home')
  const card = page.locator('main div.rounded-panel').first()
  await expect(card).toHaveCSS('border-top-color', 'rgb(230, 230, 230)')
  await expect(card).toHaveCSS('border-top-left-radius', '8px')
  await expect(card).toHaveCSS('box-shadow', 'none')
})

test('the AI line goes when the server reports a real model', async ({ page }) => {
  await page.goto('/')
  await expect(page.getByTestId('footer-ai')).toBeVisible()

  await page.route('**/api/health', (route) =>
    route.fulfill({ json: { status: 'ok', ai_mode: 'real', simulate_load: true } }),
  )
  await page.reload()
  await expect(page.getByTestId('footer').locator('p').first()).toHaveText(FOOTER.ar)
  await expect.poll(() => page.getByTestId('footer').locator('p').count()).toBe(1)
  await expect(page.getByTestId('footer-ai')).toHaveCount(0)
  await expect(page.locator('body')).not.toContainText(AI_LINE.ar)
})

test('the login chips are exactly the three demo patients', async ({ page }) => {
  await page.goto('/login')
  const chips = page.getByTestId(/^chip-/)
  await expect(chips).toHaveCount(3)
  await expect(chips).toHaveText(['فاطمة التجريبية', 'أحمد التجريبي', 'رافي'])
  await page.getByTestId('language-toggle').click()
  await expect(chips).toHaveText(['Fatima Al-Demo', 'Ahmed Al-Demo', 'Ravi Demo'])
})

test('a refused login reads in Arabic', async ({ page }) => {
  await page.goto('/login')
  const qid = page.getByRole('textbox', { name: say('ar', 'login.qid') })
  const otp = page.getByRole('textbox', { name: say('ar', 'login.otp') })
  const submit = page.getByRole('button', { name: say('ar', 'login.submit'), exact: true })

  await qid.fill('DEMO-99999')
  await otp.fill('0000')
  await submit.click()
  await expect(page.getByText(say('ar', 'error.unknown_qid'))).toBeVisible()

  await qid.fill('DEMO-10001')
  await otp.fill('1234')
  await submit.click()
  await expect(page.getByText(say('ar', 'error.invalid_otp'))).toBeVisible()
  await expect(page).toHaveURL(/\/login$/)
  await expect(page.locator('body')).not.toContainText(/not correct|No demo patient/)
})

test('the record sets the language, and an explicit toggle holds until logout', async ({ page }) => {
  await page.goto('/login')
  await page.getByTestId('chip-P003').click()
  await page.waitForURL('**/home')
  await expect(page.locator('html')).toHaveAttribute('lang', 'en')
  await page.getByRole('button', { name: say('en', 'home.logout') }).click()
  await page.waitForURL('**/login')
  await expect(page.locator('html')).toHaveAttribute('lang', 'ar')

  await page.getByTestId('chip-P001').click()
  await page.waitForURL('**/home')
  await expect(page.locator('html')).toHaveAttribute('lang', 'ar')

  await page.getByTestId('language-toggle').click()
  await expect(page.locator('html')).toHaveAttribute('lang', 'en')
  await page.reload()
  await expect(page.getByRole('button', { name: say('en', 'home.start') })).toBeVisible()
  await expect(page.locator('html')).toHaveAttribute('lang', 'en')
  await expect(page.locator('html')).toHaveAttribute('dir', 'ltr')

  await page.getByRole('button', { name: say('en', 'home.logout') }).click()
  await page.waitForURL('**/login')
  await expect(page.locator('html')).toHaveAttribute('lang', 'ar')
  await page.getByTestId('chip-P001').click()
  await page.waitForURL('**/home')
  await expect(page.locator('html')).toHaveAttribute('lang', 'ar')
})
