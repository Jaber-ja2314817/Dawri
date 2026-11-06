import {
  DESK,
  DOCTOR,
  DOCTOR_COUNTER,
  expect,
  expectNotReloaded,
  markThePage,
  NURSE,
  PHARMACIST,
  PHARMACY_COUNTER,
  QID,
  say,
  sql,
  staffLogin,
  test,
  TRIAGE_COUNTER,
  type BrowserContext,
  type Page,
} from './fixtures'

const DESKTOP = { width: 1440, height: 900 }
const STREAMS = '**/stream*'
const POLL_WITHIN_MS = 6_000
const PUSH_WITHIN_MS = 1_500
const REOPEN_WITHIN_MS = 18_000
const STATS_WITHIN_MS = 8_000
const BACKSTOP_WITHIN_MS = 25_000
const SALEM_QID = 'DEMO-10006'
const MARIAM_QID = 'DEMO-10005'
const COMPLAINT = 'sore throat since yesterday'
const TOKEN = 'dawri.token'
const STAFF_TOKEN = 'dawri.staff.token'
// Read by the patient provider and the health hook, which wrap the whole app.
const PATIENT_READS = ['/api/me', '/api/health']

test.use({ viewport: DESKTOP })

test.beforeEach(async ({ api }) => {
  await api.reset()
})

type Watched = Window & {
  __sources: EventSource[]
  __hidden: boolean
}

/** Keeps every EventSource a page makes, and lets a test say the tab went to the background. */
async function watchTabs(context: BrowserContext) {
  await context.addInitScript(() => {
    const watched = window as unknown as Watched
    watched.__sources = []
    watched.__hidden = false
    const Real = window.EventSource
    window.EventSource = class extends Real {
      constructor(url: string | URL, init?: EventSourceInit) {
        super(url, init)
        watched.__sources.push(this)
      }
    }
    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      get: () => (watched.__hidden ? 'hidden' : 'visible'),
    })
  })
}

async function setHidden(page: Page, hidden: boolean) {
  await page.evaluate((value) => {
    ;(window as unknown as Watched).__hidden = value
    document.dispatchEvent(new Event('visibilitychange'))
  }, hidden)
}

const dropOpenStreams = (page: Page) =>
  page.evaluate(() => {
    for (const source of (window as unknown as Watched).__sources) {
      source.dispatchEvent(new Event('error'))
    }
  })

const openStreams = (page: Page) =>
  page.evaluate(
    () =>
      (window as unknown as Watched).__sources.filter(
        (source) => source.readyState !== EventSource.CLOSED,
      ).length,
  )

const queueRow = (page: Page, number: string) =>
  page.locator(`[data-testid=queue-row][data-number="${number}"]`)

const displayNumber = (page: Page, counterId: string) =>
  page
    .locator(`[data-testid=display-counter][data-counter="${counterId}"]`)
    .getByTestId('display-number')

const figure = (page: Page, id: string) => page.getByTestId(`figure-${id}`)

const liveState = (page: Page) => page.getByTestId('live-state')

async function expectLive(page: Page) {
  await expect(liveState(page)).toHaveAttribute('data-live', 'live')
  await expect(liveState(page)).toHaveText(say('en', 'staff.live.live'))
}

async function expectReconnecting(page: Page) {
  await expect(liveState(page)).toHaveAttribute('data-live', 'polling')
  await expect(liveState(page)).toHaveText(say('en', 'staff.live.polling'))
}

/**
 * A tab of its own in a shared profile: whoever signed in last holds the stored token, so this
 * tab signs them out and signs in through the chip. A tab already open keeps its own session.
 */
async function signInTab(context: BrowserContext, staffId: string) {
  const tab = await context.newPage()
  await tab.goto('/staff')
  const chip = tab.getByTestId(`staff-chip-${staffId}`)
  const logout = tab.getByTestId('staff-logout')
  await expect(chip.or(logout)).toBeVisible()
  if ((await logout.count()) > 0) {
    await logout.click()
    await expect(chip).toBeVisible()
  }
  await chip.click()
  await expect(logout).toBeVisible()
  return tab
}

interface SixTabs {
  nurse: Page
  doctor: Page
  pharmacy: Page
  desk: Page
  display: Page
  dashboard: Page
}

/** Nurse, doctor, pharmacy, desk, display and dashboard in one Chrome profile over plain http. */
async function openSixTabs(context: BrowserContext): Promise<SixTabs> {
  await watchTabs(context)
  const nurse = await signInTab(context, NURSE)
  const doctor = await signInTab(context, DOCTOR)
  const pharmacy = await signInTab(context, PHARMACIST)
  const desk = await signInTab(context, DESK)

  const display = await signInTab(context, DESK)
  await display.getByTestId('staff-nav-display').click()
  await expect(display.getByTestId('display-root')).toHaveAttribute('data-live', 'live')

  const dashboard = await signInTab(context, DESK)
  await dashboard.getByTestId('staff-nav-dashboard').click()
  await expect(figure(dashboard, 'waiting-total')).toHaveAttribute('data-value', /\d+/)

  await expectLive(nurse)
  await expectLive(doctor)
  await expectLive(pharmacy)
  expect(context.pages()).toHaveLength(6)
  return { nurse, doctor, pharmacy, desk, display, dashboard }
}

async function fillVitals(page: Page) {
  await page.getByTestId('vital-bp_sys').fill('118')
  await page.getByTestId('vital-bp_dia').fill('76')
  await page.getByTestId('vital-hr').fill('88')
  await page.getByTestId('vital-temp_c').fill('38.2')
  await page.getByTestId('vital-spo2').fill('98')
  await page.getByTestId('vital-weight_kg').fill('62')
}

async function nurseCallsAndHandsOver(nurse: Page, visitId: string) {
  await nurse.getByTestId('call-next').click()
  await nurse.waitForURL(`**/staff/nurse/${visitId}`)
  await fillVitals(nurse)
  await nurse.getByTestId('urgency-routine').check()
  await nurse.getByTestId('vitals-submit').click()
  await nurse.waitForURL(`**/staff/nurse/${visitId}/handoff`)
  await expect(nurse.getByTestId('handoff-text')).toBeVisible()
  await nurse.getByTestId(`doctor-${DOCTOR}`).check()
  await nurse.getByTestId('handoff-confirm').click()
  await expect(nurse.getByTestId('handoff-sent')).toBeVisible()
}

test.describe('stream down', () => {
  test('the queue updates by polling, live-state says so, and the stream comes back', async ({
    page,
    api,
  }) => {
    test.setTimeout(60_000)
    await watchTabs(page.context())
    await staffLogin(page, NURSE)
    await expectLive(page)
    await markThePage(page)

    // Abort every new attempt, then drop the open one the way the browser reports it.
    await page.route(STREAMS, (route) => route.abort())
    await dropOpenStreams(page)
    await expectReconnecting(page)

    const first = await api.arrivedVisit(QID.fatima)
    await expect(queueRow(page, first.number)).toBeVisible({ timeout: POLL_WITHIN_MS })
    await expectReconnecting(page)

    await page.unroute(STREAMS)
    await expect(liveState(page)).toHaveAttribute('data-live', 'live', {
      timeout: REOPEN_WITHIN_MS,
    })
    await expectLive(page)

    const second = await api.walkIn(SALEM_QID, COMPLAINT)
    await expect(queueRow(page, second.ticket.number)).toBeVisible({ timeout: PUSH_WITHIN_MS })
    await expectNotReloaded(page)
  })

  test('a stream that never opened still leaves a working console', async ({ page, api }) => {
    await page.route(STREAMS, (route) => route.abort())
    await staffLogin(page, NURSE)
    await expectReconnecting(page)
    const { number, visitId } = await api.arrivedVisit(QID.fatima)
    await expect(queueRow(page, number)).toBeVisible({ timeout: POLL_WITHIN_MS })
    await page.getByTestId('call-next').click()
    await page.waitForURL(`**/staff/nurse/${visitId}`)
    await expect(page.getByTestId('intake-card')).toBeVisible()
    await expectReconnecting(page)
  })
})

test.describe('one profile, many tabs', () => {
  test('six role tabs all load and act, and only four hold a stream', async ({ windows, api }) => {
    test.setTimeout(120_000)
    const context = await windows.context()
    const tabs = await openSixTabs(context)
    const { nurse, doctor, pharmacy, desk, display, dashboard } = tabs
    const errors: string[] = []
    for (const tab of Object.values(tabs)) {
      tab.on('pageerror', (error) => errors.push(error.message))
    }

    expect(await openStreams(nurse)).toBe(1)
    expect(await openStreams(doctor)).toBe(1)
    expect(await openStreams(pharmacy)).toBe(1)
    expect(await openStreams(display)).toBe(1)
    expect(await openStreams(desk)).toBe(0)
    expect(await openStreams(dashboard)).toBe(0)

    const fatima = await api.arrivedVisit(QID.fatima)
    await expect(queueRow(nurse, 'T-014')).toBeVisible({ timeout: PUSH_WITHIN_MS })
    await expect(queueRow(desk, 'T-014')).toBeVisible({ timeout: POLL_WITHIN_MS })
    await expect(figure(dashboard, 'waiting-triage')).toHaveText('1', { timeout: STATS_WITHIN_MS })

    // The desk acts in its tab, and the nurse's stream reports it.
    await desk.getByTestId('desk-chip-P006').click()
    await desk.getByTestId('desk-complaint').fill(COMPLAINT)
    await desk.getByTestId('desk-complaint').press('Enter')
    await expect(desk.getByTestId('walkin-number')).toHaveText('T-015')
    await expect(queueRow(nurse, 'T-015')).toBeVisible({ timeout: PUSH_WITHIN_MS })

    await nurseCallsAndHandsOver(nurse, fatima.visitId)
    await expect(displayNumber(display, TRIAGE_COUNTER)).toHaveText('—')
    await expect(queueRow(doctor, 'D-GP-023')).toBeVisible({ timeout: PUSH_WITHIN_MS })

    await doctor.getByTestId('call-next').click()
    await expect(doctor.getByTestId('prescription')).toBeVisible()
    await expect(displayNumber(display, DOCTOR_COUNTER)).toHaveText('D-GP-023')
    await doctor.getByTestId('drug-DR-PARA').check()
    await doctor.getByTestId('consult-done').click()
    await expect(doctor.getByTestId('moved-number')).toHaveText('P-031')

    await expect(queueRow(pharmacy, 'P-031')).toBeVisible({ timeout: PUSH_WITHIN_MS })
    await pharmacy.getByTestId('call-next').click()
    await expect(displayNumber(display, PHARMACY_COUNTER)).toHaveText('P-031')
    await pharmacy.getByTestId('dispensed').click()
    await expect(pharmacy.getByTestId('dispensed-outcome')).toBeVisible()

    await expect(figure(dashboard, 'completed')).toHaveText('1', { timeout: STATS_WITHIN_MS })
    await expect(figure(dashboard, 'walk-ins')).toHaveText('1')
    await expect(display.getByTestId('display-root')).toHaveAttribute('data-chimes', '3')
    expect(await openStreams(desk)).toBe(0)
    expect(await openStreams(dashboard)).toBe(0)
    expect(errors).toEqual([])
  })

  test('a hidden tab closes its stream, polls, and reopens it when shown', async ({
    page,
    api,
  }) => {
    test.setTimeout(60_000)
    await watchTabs(page.context())
    await staffLogin(page, NURSE)
    await expectLive(page)
    expect(await openStreams(page)).toBe(1)

    await setHidden(page, true)
    await expect.poll(() => openStreams(page)).toBe(0)
    await expectReconnecting(page)

    const { number } = await api.arrivedVisit(QID.fatima)
    await expect(queueRow(page, number)).toBeVisible({ timeout: POLL_WITHIN_MS })

    await setHidden(page, false)
    await expect.poll(() => openStreams(page)).toBe(1)
    await expectLive(page)

    const walkIn = await api.walkIn(SALEM_QID, COMPLAINT)
    await expect(queueRow(page, walkIn.ticket.number)).toBeVisible({ timeout: PUSH_WITHIN_MS })
  })

  test('eight stream tabs in one profile leave the last one working once the rest are hidden', async ({
    windows,
    api,
  }) => {
    test.setTimeout(120_000)
    const context = await windows.context()
    await watchTabs(context)
    const tabs: Page[] = []
    for (let opened = 0; opened < 8; opened += 1) {
      const tab = await context.newPage()
      if (opened === 0) await staffLogin(tab, NURSE)
      else await tab.goto('/staff/nurse')
      await expectLive(tab)
      await setHidden(tab, opened < 7)
      tabs.push(tab)
    }
    const counts = await Promise.all(tabs.map(openStreams))
    expect(counts).toEqual([0, 0, 0, 0, 0, 0, 0, 1])

    const front = tabs[7]
    const { number, visitId } = await api.arrivedVisit(QID.fatima)
    await expect(queueRow(front, number)).toBeVisible({ timeout: PUSH_WITHIN_MS })
    await front.getByTestId('call-next').click()
    await front.waitForURL(`**/staff/nurse/${visitId}`)
    await expect(front.getByTestId('intake-card')).toBeVisible()
  })

  test('a reset under all six tabs takes each back, and T-014 is reachable again', async ({
    windows,
    api,
  }) => {
    test.setTimeout(120_000)
    const context = await windows.context()
    const { nurse, doctor, pharmacy, desk, display, dashboard } = await openSixTabs(context)
    const errors: string[] = []
    for (const tab of [nurse, doctor, pharmacy, desk, display, dashboard]) {
      tab.on('pageerror', (error) => errors.push(error.message))
      await markThePage(tab)
    }

    const seeded = {
      triage: (await api.asStaff(NURSE, 'GET', `/api/counters/${TRIAGE_COUNTER}/queue`)).tickets
        .length,
      doctor: (await api.asStaff(DOCTOR, 'GET', `/api/counters/${DOCTOR_COUNTER}/queue`)).tickets
        .length,
      pharmacy: (await api.asStaff(PHARMACIST, 'GET', `/api/counters/${PHARMACY_COUNTER}/queue`))
        .tickets.length,
    }

    // One patient at each station, so every console has something to lose.
    const atPharmacy = await api.walkIn(SALEM_QID, COMPLAINT)
    await api.callNext()
    await api.vitals(atPharmacy.visit_id)
    await api.handoff(atPharmacy.visit_id)
    await api.consultDone(atPharmacy.visit_id)
    await pharmacy.getByTestId('call-next').click()
    await expect(pharmacy.getByTestId('handover')).toBeVisible()

    const atDoctor = await api.walkIn(MARIAM_QID, COMPLAINT)
    await api.callNext()
    await api.vitals(atDoctor.visit_id)
    await api.handoff(atDoctor.visit_id)
    await doctor.getByTestId('call-next').click()
    await expect(doctor.getByTestId('prescription')).toBeVisible()

    const fatima = await api.arrivedVisit(QID.fatima)
    const phone = await windows.phone()
    await phone.goto('/login')
    await phone.evaluate(([key, value]) => localStorage.setItem(key, value), [TOKEN, fatima.token])
    await phone.goto(`/visit/${fatima.visitId}/ticket`)
    await expect(phone.getByTestId('ticket-card')).toHaveAttribute('data-live', 'live')

    await nurse.getByTestId('call-next').click()
    await nurse.waitForURL(`**/staff/nurse/${fatima.visitId}`)
    await expect(nurse.getByTestId('intake-card')).toBeVisible()
    await expect(figure(dashboard, 'waiting-total')).toHaveAttribute('data-value', /\d+/)
    await expect(figure(dashboard, 'walk-ins')).toHaveText('2', { timeout: STATS_WITHIN_MS })
    await expect(display.getByTestId('display-root')).not.toHaveAttribute('data-chimes', '0')
    const chimes = await display.getByTestId('display-root').getAttribute('data-chimes')

    await desk.getByTestId('reset-demo').click()
    await desk.getByTestId('reset-confirm').click()
    await expect(desk.getByTestId('staff-notice')).toHaveText(say('en', 'staff.reset.done'))

    // Nurse: an open T03 goes to the queue with a notice.
    await nurse.waitForURL('**/staff/nurse', { timeout: POLL_WITHIN_MS })
    await expect(nurse.getByTestId('staff-notice')).toHaveText(say('en', 'nurse.visit.gone'))
    await expect(nurse.getByTestId('queue-row')).toHaveCount(seeded.triage)
    await expect(nurse.getByTestId('call-next')).toBeVisible()

    // Doctor and pharmacy: the patient has gone, and the desk is empty.
    await expect(doctor.getByTestId('doctor-empty')).toBeVisible({ timeout: POLL_WITHIN_MS })
    await expect(doctor.getByTestId('at-counter')).toHaveCount(0)
    await expect(doctor.getByTestId('queue-row')).toHaveCount(seeded.doctor)
    await expect(pharmacy.getByTestId('pharmacy-empty')).toBeVisible({ timeout: POLL_WITHIN_MS })
    await expect(pharmacy.getByTestId('at-counter')).toHaveCount(0)
    await expect(pharmacy.getByTestId('queue-row')).toHaveCount(seeded.pharmacy)

    await expect(desk.getByTestId('queue-row')).toHaveCount(seeded.triage)

    for (const counterId of [TRIAGE_COUNTER, DOCTOR_COUNTER, PHARMACY_COUNTER]) {
      await expect(displayNumber(display, counterId)).toHaveText('—')
    }
    await expect(display.getByTestId('display-root')).toHaveAttribute('data-chimes', chimes as string)

    await expect(figure(dashboard, 'waiting-total')).toHaveText('0', { timeout: STATS_WITHIN_MS })
    await expect(figure(dashboard, 'walk-ins')).toHaveText('0')
    await expect(figure(dashboard, 'completed')).toHaveText('0')

    for (const tab of [nurse, doctor, pharmacy, desk, display, dashboard]) {
      await expectNotReloaded(tab)
    }
    await phone.waitForURL('**/home', { timeout: POLL_WITHIN_MS })
    await expect(phone.getByRole('status').filter({ hasText: say('ar', 'home.demoReset') })).toBeVisible()
    expect(errors).toEqual([])

    const again = await api.arrivedVisit(QID.fatima)
    expect(again.number).toBe('T-014')
    await expect(queueRow(nurse, 'T-014')).toBeVisible({ timeout: PUSH_WITHIN_MS })
  })

  test('two tabs of the nurse console stay in step', async ({ page, api }) => {
    await staffLogin(page, NURSE)
    await expectLive(page)
    const second = await page.context().newPage()
    await second.goto('/staff/nurse')
    await expectLive(second)
    await markThePage(page)
    await markThePage(second)

    const { number, visitId } = await api.arrivedVisit(QID.fatima)
    await expect(queueRow(page, number)).toBeVisible({ timeout: PUSH_WITHIN_MS })
    await expect(queueRow(second, number)).toBeVisible({ timeout: PUSH_WITHIN_MS })

    // A call in one tab: the other shows the same patient at the counter, not a second button.
    await page.getByTestId('call-next').click()
    await page.waitForURL(`**/staff/nurse/${visitId}`)
    await expect(second.getByTestId('at-counter')).toHaveAttribute('data-number', number, {
      timeout: PUSH_WITHIN_MS,
    })
    await expect(second.getByTestId('call-next')).toHaveCount(0)
    await expect(queueRow(second, 'T-011')).toHaveCount(0)

    await second.getByTestId('open-intake').click()
    await second.waitForURL(`**/staff/nurse/${visitId}`)
    await expect(second.getByTestId('intake-card')).toBeVisible()
    await expect(second.getByTestId('vitals-form')).toBeVisible()

    // An intake edit publishes no event, so the other tab reads it at its next backstop.
    await page.getByTestId('intake-edit').click()
    await page.getByTestId('edit-chief_complaint').fill('Fever and dry cough, worse at night')
    await page.getByTestId('intake-save').click()
    await expect(second.getByTestId('intake-reason')).toHaveText(
      'Fever and dry cough, worse at night',
      { timeout: BACKSTOP_WITHIN_MS },
    )

    await fillVitals(page)
    await page.getByTestId('urgency-routine').check()
    await page.getByTestId('vitals-submit').click()
    await page.waitForURL(`**/staff/nurse/${visitId}/handoff`)
    await expect(page.getByTestId('handoff-text')).toBeVisible()
    await expect(second.getByTestId('urgency-earlier')).toBeVisible({ timeout: PUSH_WITHIN_MS })

    await page.getByTestId(`doctor-${DOCTOR}`).check()
    await page.getByTestId('handoff-confirm').click()
    await expect(page.getByTestId('handoff-sent')).toBeVisible()
    await expect(second.getByTestId('visit-locked')).toBeVisible({ timeout: PUSH_WITHIN_MS })
    await expectNotReloaded(page)
    await expectNotReloaded(second)
  })
})

test.describe('sessions', () => {
  test('patient and staff tabs in one profile never send each other’s token', async ({
    page,
    api,
  }) => {
    const record = (tab: Page) => {
      const sent: { path: string; token: string }[] = []
      tab.on('request', (request) => {
        const url = new URL(request.url())
        if (!url.pathname.startsWith('/api/')) return
        const header = request.headers().authorization?.replace('Bearer ', '')
        const token = header ?? url.searchParams.get('token')
        if (token) sent.push({ path: url.pathname, token })
      })
      return sent
    }

    const { token, visitId } = await api.arrivedVisit(QID.fatima)
    await page.goto('/login')
    await page.evaluate(([key, value]) => localStorage.setItem(key, value), [TOKEN, token])
    const fromPatient = record(page)
    await page.goto(`/visit/${visitId}/ticket`)
    await expect(page.getByTestId('ticket-number')).toHaveText('T-014')
    await expect(page.getByTestId('ticket-card')).toHaveAttribute('data-live', 'live')

    const staff = await page.context().newPage()
    const fromStaff = record(staff)
    await staffLogin(staff, NURSE)
    await expectLive(staff)
    const staffToken = await staff.evaluate((key) => localStorage.getItem(key), STAFF_TOKEN)
    expect(staffToken).not.toBeNull()
    expect(staffToken).not.toBe(token)

    // Both act and both read, each on its own stream.
    await staff.getByTestId('call-next').click()
    await staff.waitForURL(`**/staff/nurse/${visitId}`)
    await expect(page.getByTestId('ticket-called')).toBeVisible({ timeout: PUSH_WITHIN_MS })
    await staff.reload()
    await page.reload()
    await expect(page.getByTestId('ticket-called')).toBeVisible()
    await expect(staff.getByTestId('intake-card')).toBeVisible()

    expect(fromPatient.length).toBeGreaterThan(0)
    for (const { path, token: used } of fromPatient) expect(used, path).toBe(token)

    const staffOnly = fromStaff.filter(({ path }) => !PATIENT_READS.includes(path))
    expect(staffOnly.length).toBeGreaterThan(0)
    for (const { path, token: used } of staffOnly) expect(used, path).toBe(staffToken)
    for (const { path, token: used } of fromStaff) {
      if (path === '/api/me') expect(used, path).toBe(token)
    }
    expect(await page.evaluate((key) => localStorage.getItem(key), TOKEN)).toBe(token)
  })

  test('a reload keeps each tab in the role it signed in as', async ({ windows }) => {
    const context = await windows.context()
    const nurse = await signInTab(context, NURSE)
    const doctor = await signInTab(context, DOCTOR)

    await nurse.reload()
    await expect(nurse.getByTestId('staff-name')).toContainText('Amal Al-Demo')
    await expect(nurse).toHaveURL(/\/staff\/nurse$/)
    await doctor.reload()
    await expect(doctor.getByTestId('staff-name')).toContainText('Dr. Noor Al-Demo')
    await expect(doctor).toHaveURL(/\/staff\/doctor$/)

    // Logging out one tab ends that tab, and a new tab opens as the last one to sign in.
    await doctor.getByTestId('staff-logout').click()
    await doctor.waitForURL('**/staff/login')
    await nurse.reload()
    await expect(nurse.getByTestId('staff-name')).toContainText('Amal Al-Demo')
  })

  test('a wiped server session sends every open console to the login, not to a blank page', async ({
    windows,
    api,
  }) => {
    test.setTimeout(60_000)
    await api.arrivedVisit(QID.fatima)
    const context = await windows.context()
    const queue = await context.newPage()
    await staffLogin(queue, NURSE)
    await expectLive(queue)
    const display = await context.newPage()
    await display.goto('/staff/display')
    await expect(display.getByTestId('display-root')).toHaveAttribute('data-live', 'live')
    const dashboard = await context.newPage()
    await dashboard.goto('/staff/dashboard')
    await expect(figure(dashboard, 'waiting-total')).toHaveAttribute('data-value', /\d+/)

    sql('DELETE FROM session')

    const expectLogin = async (tab: Page, timeout: number) => {
      await tab.waitForURL('**/staff/login', { timeout })
      await expect(tab.locator('h1')).toHaveText(say('en', 'staff.login.title'))
      await expect(tab.getByTestId(`staff-chip-${NURSE}`)).toBeVisible()
      await expect(tab.getByTestId('footer')).toBeVisible()
    }

    // The next action, the next poll, and with an open stream the next backstop read.
    await queue.getByTestId('call-next').click()
    await expectLogin(queue, POLL_WITHIN_MS)
    await expectLogin(dashboard, STATS_WITHIN_MS)
    await expectLogin(display, BACKSTOP_WITHIN_MS)

    await queue.reload()
    await expect(queue.getByTestId(`staff-chip-${NURSE}`)).toBeVisible()
    await staffLogin(queue, NURSE)
    await expectLive(queue)
  })

  test('a reload with a dead session also lands on the login', async ({ page }) => {
    await staffLogin(page, NURSE)
    sql('DELETE FROM session')
    await page.reload()
    await page.waitForURL('**/staff/login')
    await expect(page.locator('h1')).toHaveText(say('en', 'staff.login.title'))
  })
})
