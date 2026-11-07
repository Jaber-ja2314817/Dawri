import {
  agree,
  answerToSummary,
  confirmSummary,
  DOCTOR,
  documentLoads,
  expect,
  expectNotReloaded,
  FATIMA_ANSWERS,
  imHere,
  liveConsole,
  markThePage,
  NURSE,
  PHARMACIST,
  queueRow,
  reserveHere,
  say,
  send,
  startCheckIn,
  streamOpen,
  test,
  ticketRows,
  vitalsToDraft,
  visitIdOf,
  watchForFaults,
  type Page,
  type Windows,
} from './fixtures'

/*
 * Each demo patient in Arabic and in English, on the production build. Patient and staff sit
 * in separate browser contexts, and the toggle sets the language on the phone and every console.
 */

type Lang = 'ar' | 'en'

const LANGS: Lang[] = ['ar', 'en']
const LIVE_MS = 2_000
const DASHBOARD_POLL_MS = 8_000
const AIRPORT = 'C-AIRPORT'
const AIRPORT_NURSE = 'S-AIR-NURSE1'
const RAYYAN = 'C-RAYYAN'
const RAYYAN_NURSE = 'S-RAY-NURSE1'
const ARABIC = /[؀-ۿ]/
const LATIN = /[A-Za-z]/

const FATIMA = {
  ar: { words: 'عندي حرارة وكحة من ثلاث أيام', answers: FATIMA_ANSWERS },
  en: { words: 'I have a fever and a cough for three days', answers: ['5', 'no', 'no'] },
}
const AHMED = {
  ar: { words: 'أحتاج حبوب الضغط المعتادة', medicine: 'أملوديبين 5 ملغ مرة واحدة يومياً' },
  en: { words: 'I need my usual blood pressure tablets', medicine: 'amlodipine 5 mg once daily' },
}
const RAVI = {
  ar: {
    words: 'ألم في صدري ينتشر إلى ذراعي',
    hospital: 'مستشفى حمد العام',
    route: 'تحدث إلى أحد الموظفين في المركز، أو اتصل بـ 999',
  },
  en: {
    words: 'Chest pain going to my left arm',
    hospital: 'Hamad General Hospital',
    route: 'Speak to a member of staff at the centre, or call 999',
  },
}
const ALLERGEN = { ar: 'البنسلين', en: 'penicillin' }
const MEDICINE = {
  ar: { name: 'باراسيتامول', schedule: 'كل 6 ساعات' },
  en: { name: 'Paracetamol', schedule: 'every 6 hours' },
}

async function expectLanguage(page: Page, lang: Lang) {
  await expect(page.locator('html')).toHaveAttribute('lang', lang)
  await expect(page.locator('html')).toHaveAttribute('dir', lang === 'ar' ? 'rtl' : 'ltr')
}

/** Always by a tap: only that makes it a choice, and a choice outlasts the record's language. */
async function setLanguage(page: Page, lang: Lang) {
  const html = page.locator('html')
  const toggle = page.getByTestId('language-toggle')
  await expect(toggle).toBeVisible()
  if ((await html.getAttribute('lang')) === lang) {
    await toggle.click()
    await expect(html).not.toHaveAttribute('lang', lang)
  }
  await toggle.click()
  await expectLanguage(page, lang)
}

async function patientSignsIn(page: Page, chip: string, lang: Lang) {
  await page.goto('/login')
  await setLanguage(page, lang)
  await page.getByTestId(`chip-${chip}`).click()
  await page.waitForURL('**/home')
  await expectLanguage(page, lang)
}

async function consoleIn(
  windows: Windows,
  faults: string[],
  lang: Lang,
  staffId: string,
  centreId?: string,
) {
  const page = await windows.staff(staffId, centreId)
  watchForFaults(faults, page)
  await setLanguage(page, lang)
  await liveConsole(page)
  return page
}

async function dashboardIn(
  windows: Windows,
  faults: string[],
  lang: Lang,
  staffId: string,
  centreId: string,
) {
  const page = await consoleIn(windows, faults, lang, staffId, centreId)
  await page.getByTestId('staff-nav-dashboard').click()
  await page.waitForURL('**/staff/dashboard')
  await expect(page.getByTestId('stats-card')).toBeVisible()
  await expectLanguage(page, lang)
  return page
}

const figure = (page: Page, id: string) => page.getByTestId(`figure-${id}`)

for (const lang of LANGS) {
  test(`Fatima in ${lang}: login to S11 through nurse, doctor and pharmacy`, async ({
    page: phone,
    windows,
  }) => {
    test.setTimeout(120_000)
    const faults: string[] = []
    watchForFaults(faults, phone)
    const nurse = await consoleIn(windows, faults, lang, NURSE)
    const doctor = await consoleIn(windows, faults, lang, DOCTOR)
    const pharmacy = await consoleIn(windows, faults, lang, PHARMACIST)

    // T08 opens beside the nurse. It holds both languages whatever the console's.
    const display = await nurse.context().newPage()
    watchForFaults(faults, display)
    await display.goto('/staff/display')
    await expect(display.getByTestId('display-root')).toHaveAttribute('data-live', 'live')
    await expect(display.getByTestId('display-root')).toHaveAttribute('dir', 'ltr')
    await expect(display.getByTestId('display-root')).toContainText('Triage 1')
    await expect(display.getByTestId('display-root')).toContainText('الفرز 1')

    await patientSignsIn(phone, 'P001', lang)
    await startCheckIn(phone, lang)
    await phone.getByTestId('who-P001').click()
    await agree(phone, lang)
    const visitId = visitIdOf(phone)
    await expectLanguage(phone, lang)

    await answerToSummary(phone, FATIMA[lang].words, FATIMA[lang].answers)
    await expect(phone.getByTestId('chat-summary-text')).toContainText(
      lang === 'ar' ? '3 أيام' : '3 days',
    )
    await confirmSummary(phone)
    await reserveHere(phone)
    await expect(phone.locator('main')).toContainText(say(lang, 'reserved.valid'))
    await imHere(phone)
    await expect(phone.getByTestId('ticket-number')).toHaveText('T-014')
    await streamOpen(phone)
    await expectLanguage(phone, lang)

    for (const page of [phone, nurse, doctor, pharmacy, display]) await markThePage(page)
    const loads = [phone, nurse, doctor, pharmacy, display].map((page) => documentLoads(page))

    await expect(queueRow(nurse, 'T-014')).toBeVisible()
    await nurse.getByTestId('call-next').click()
    await nurse.waitForURL(`**/staff/nurse/${visitId}`)
    await expect(phone.getByTestId('ticket-called')).toBeVisible({ timeout: LIVE_MS })
    await expect(nurse.getByTestId('banner-number')).toHaveText('T-014')
    await expect(nurse.getByTestId('allergy-flag').first()).toHaveText(ALLERGEN[lang])
    await expect(display.getByTestId('display-number').first()).toHaveText('T-014')
    await expectLanguage(nurse, lang)

    await vitalsToDraft(nurse, visitId)
    await nurse.getByTestId('handoff-confirm').click()
    await expect(nurse.getByTestId('sent-number')).toHaveText('D-GP-023')
    await expect(phone.getByTestId('ticket-number')).toHaveText('D-GP-023', { timeout: LIVE_MS })

    await expect(queueRow(doctor, 'D-GP-023')).toBeVisible()
    await doctor.getByTestId('call-next').click()
    await expect(doctor.getByTestId('at-counter')).toHaveAttribute('data-number', 'D-GP-023')
    const warning = doctor.getByTestId('allergy-warning-DR-AMOX')
    await expect(warning).toContainText(ALLERGEN[lang])
    await expect(warning).not.toContainText(ALLERGEN[lang === 'ar' ? 'en' : 'ar'])
    await doctor.getByTestId('drug-DR-PARA').check()
    await doctor.getByTestId('consult-done').click()
    await expect(doctor.getByTestId('moved-number')).toHaveText('P-031')
    await expect(phone.getByTestId('ticket-number')).toHaveText('P-031', { timeout: LIVE_MS })
    await expectLanguage(doctor, lang)

    await expect(queueRow(pharmacy, 'P-031')).toBeVisible()
    await pharmacy.getByTestId('call-next').click()
    await expect(pharmacy.getByTestId('at-counter')).toHaveAttribute('data-number', 'P-031')
    await pharmacy.getByTestId('dispensed').click()
    await expect(pharmacy.getByTestId('dispensed-outcome')).toContainText('P-031')
    await expectLanguage(pharmacy, lang)

    await phone.waitForURL('**/complete', { timeout: LIVE_MS })
    await expectLanguage(phone, lang)
    const medicine = phone.getByTestId('medicine').first()
    await expect(medicine).toContainText(MEDICINE[lang].name)
    await expect(medicine).toContainText(MEDICINE[lang].schedule)
    await expect(medicine).not.toContainText(lang === 'ar' ? LATIN : ARABIC)

    for (const page of [phone, nurse, doctor, pharmacy, display]) await expectNotReloaded(page)
    expect(loads.map((count) => count())).toEqual([0, 0, 0, 0, 0])
    expect(faults).toEqual([])
  })

  test(`Ahmed in ${lang}: S07, no ticket, one deflection on the Rayyan dashboard`, async ({
    page: phone,
    windows,
  }) => {
    const faults: string[] = []
    watchForFaults(faults, phone)
    const board = await dashboardIn(windows, faults, lang, RAYYAN_NURSE, RAYYAN)
    await expect(figure(board, 'deflections')).toHaveText('0')
    await markThePage(board)

    await patientSignsIn(phone, 'P002', lang)
    await startCheckIn(phone, lang)
    await agree(phone, lang)
    const visitId = visitIdOf(phone)
    await send(phone, AHMED[lang].words)
    await phone.waitForURL('**/refill')
    await expectLanguage(phone, lang)
    await expect(phone.getByTestId('refill-medicine')).toHaveText(AHMED[lang].medicine)
    await expect(phone.getByTestId('refill-message')).toHaveText(say(lang, 'refill.message'))
    await expect(phone.getByTestId('ticket-number')).toHaveCount(0)
    expect(ticketRows(visitId)).toBe(0)

    await expect(figure(board, 'deflections')).toHaveText('1', { timeout: DASHBOARD_POLL_MS })
    await expectNotReloaded(board)
    await expectLanguage(board, lang)
    expect(faults).toEqual([])
  })

  test(`Ravi in ${lang}: S06, no ticket, the staff route, and the Airport count moves`, async ({
    page: phone,
    windows,
  }) => {
    const faults: string[] = []
    watchForFaults(faults, phone)
    const board = await dashboardIn(windows, faults, lang, AIRPORT_NURSE, AIRPORT)
    await expect(figure(board, 'emergencies')).toHaveText('0')
    await markThePage(board)

    await patientSignsIn(phone, 'P003', lang)
    await startCheckIn(phone, lang)
    await agree(phone, lang)
    const visitId = visitIdOf(phone)
    await send(phone, RAVI[lang].words)
    await phone.waitForURL('**/emergency')
    await expectLanguage(phone, lang)
    await expect(phone.getByText(say(lang, 'emergency.title'))).toBeVisible()
    await expect(phone.getByTestId('emergency-call')).toHaveAttribute('href', 'tel:999')
    await expect(phone.getByTestId('emergency-nearest')).toContainText(RAVI[lang].hospital)
    await expect(phone.getByTestId('ticket-number')).toHaveCount(0)
    expect(ticketRows(visitId)).toBe(0)

    await phone.getByTestId('emergency-override').click()
    await expect(phone.getByTestId('emergency-route')).toContainText(RAVI[lang].route)
    expect(ticketRows(visitId)).toBe(0)

    await expect(figure(board, 'emergencies')).toHaveText('1', { timeout: DASHBOARD_POLL_MS })
    await expectNotReloaded(board)
    await expectLanguage(board, lang)
    expect(faults).toEqual([])
  })
}
