import {
  AHMED_WORDS,
  DESK,
  DOCTOR_COUNTER,
  expect,
  expectNotReloaded,
  markThePage,
  NURSE,
  PHARMACIST,
  PHARMACY_COUNTER,
  QID,
  RAVI_WORDS,
  say,
  sql,
  staffLogin,
  test,
  ticketRows,
  TRIAGE_COUNTER,
  type Page,
} from './fixtures'

const DESKTOP = { width: 1440, height: 900 }
const TV = { width: 1920, height: 1080 }
const PHONE = { width: 390, height: 844 }

const SALEM = { id: 'P006', qid: 'DEMO-10006', en: 'Salem Al-Demo', ar: 'سالم التجريبي' }
const RAVI = { id: 'P003', qid: QID.ravi }
// Registered at Al Wakra with an active medicine, so her refill counts on this dashboard.
const MARIAM_QID = 'DEMO-10005'
const FATIMA = { en: 'Fatima Al-Demo', ar: 'فاطمة التجريبية' }
const COMPLAINT = 'sore throat since yesterday'
const CENTRE = 'C-WAKRA'
const TICKET_NUMBER = /\b(?:T|P|D-[A-Z]+)-\d{3}\b/
const DISPLAY_ORDER: [string, string, string][] = [
  [TRIAGE_COUNTER, 'Triage 1', 'الفرز 1'],
  ['C-WAKRA-D3', 'Room 3', 'غرفة 3'],
  [DOCTOR_COUNTER, 'Room 4', 'غرفة 4'],
  ['C-WAKRA-DEN1', 'Dental', 'الأسنان'],
  ['C-WAKRA-WH1', "Women's Health", 'صحة المرأة'],
  [PHARMACY_COUNTER, 'Pharmacy', 'الصيدلية'],
]
const INTAKE_SERVICES = [
  'gp',
  'dental',
  'refill',
  'vaccination',
  'lab_only',
  'womens_health',
  'mental_health',
  'other',
]

test.use({ viewport: DESKTOP })

test.beforeEach(async ({ api }) => {
  await api.reset()
})

const visitsOf = (patientId: string) =>
  sql('SELECT id FROM visit WHERE patient_id = ? ORDER BY created_at', patientId).map(
    (row) => row[0] as string,
  )

async function expectNoSideScroll(page: Page, where: string) {
  const widths = await page.evaluate(() => ({
    content: document.documentElement.scrollWidth,
    screen: window.innerWidth,
  }))
  expect(widths.content, where).toBeLessThanOrEqual(widths.screen)
}

/** Sign in first: the nurse's own console holds a stream, and that one is allowed. */
function watchStreams(page: Page): string[] {
  const streams: string[] = []
  page.on('request', (request) => {
    if (request.resourceType() === 'eventsource') streams.push(request.url())
  })
  return streams
}

async function openDesk(page: Page, staffId = DESK) {
  await staffLogin(page, staffId)
  await page.goto('/staff/desk')
  await expect(page.getByTestId('queue-table')).toBeVisible()
  await expect(page.getByTestId('desk-chips')).toBeVisible()
}

/** Chip, complaint, Enter: the three steps a clerk takes. */
async function registerByChip(page: Page, patientId: string, complaint: string) {
  await page.getByTestId(`desk-chip-${patientId}`).click()
  await page.getByTestId('desk-complaint').fill(complaint)
  await page.getByTestId('desk-complaint').press('Enter')
}

const queueNumbers = (page: Page) =>
  page
    .getByTestId('queue-row')
    .evaluateAll((rows) => rows.map((row) => row.getAttribute('data-number')))

async function openDisplay(page: Page) {
  await staffLogin(page, NURSE)
  await page.goto('/staff/display')
  await expect(page.getByTestId('display-root')).toHaveAttribute('data-live', 'live')
  await expect(page.getByTestId('display-counter')).toHaveCount(DISPLAY_ORDER.length)
}

const cell = (page: Page, counterId: string) =>
  page.locator(`[data-testid=display-counter][data-counter="${counterId}"]`)

const expectChimes = (page: Page, count: number) =>
  expect(page.getByTestId('display-root')).toHaveAttribute('data-chimes', String(count))

const expectAllDashes = async (page: Page) => {
  for (const [counterId] of DISPLAY_ORDER) {
    await expect(cell(page, counterId).getByTestId('display-number')).toHaveText('—')
  }
}

/** What a dropped stream coming back does: reopen, and read the same data again. */
async function reconnect(page: Page) {
  const reread = page.waitForResponse(
    (response) => new URL(response.url()).pathname === `/api/display/${CENTRE}`,
  )
  await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')))
  await reread
}

test.describe('T07 front desk', () => {
  test('Salem by chip gets a number in arrival order, beside the app patients', async ({
    page,
    api,
  }) => {
    const before = await api.arrivedVisit(QID.fatima)
    await openDesk(page)
    await expect(page.getByTestId('desk-chips').getByRole('button').first()).toHaveAttribute(
      'data-testid',
      `desk-chip-${SALEM.id}`,
    )

    await markThePage(page)
    await registerByChip(page, SALEM.id, COMPLAINT)

    const slip = page.getByTestId('walkin-ticket')
    await expect(slip).toBeVisible()
    const number = await page.getByTestId('walkin-number').textContent()
    expect(number).toMatch(/^T-\d{3}$/)
    expect(Number(number?.slice(2))).toBe(Number(before.number.slice(2)) + 1)
    await expect(slip).toContainText(say('en', 'desk.ticket.ahead'))
    await expect(page.getByTestId('walkin-counter')).toHaveText('Triage 1')

    const row = page.locator(`[data-testid=queue-row][data-number="${number}"]`)
    await expect(row).toContainText(SALEM.en)
    await expect(row).toContainText(COMPLAINT)

    // A patient who arrives after him stands after him, whichever door they came through.
    const after = await api.arrivedVisit(QID.ravi)
    await expect.poll(() => queueNumbers(page), { timeout: 8_000 }).toContain(after.number)
    const numbers = await queueNumbers(page)
    expect(numbers.indexOf(before.number)).toBeLessThan(numbers.indexOf(number))
    expect(numbers.indexOf(number)).toBeLessThan(numbers.indexOf(after.number))
    const ahead = numbers.indexOf(number)
    await expect(slip).toContainText(String(ahead))
    await expectNotReloaded(page)

    const [visitId] = visitsOf(SALEM.id)
    const visit = await api.asStaff(NURSE, 'GET', `/api/staff/visits/${visitId}`)
    expect(visit.intake.chief_complaint).toBe(COMPLAINT)
    expect(visit.intake.chief_complaint_patient_words).toBe(COMPLAINT)
    expect(['ar-gulf', 'ar-msa', 'en']).toContain(visit.intake.language)
    expect(INTAKE_SERVICES).toContain(visit.intake.service)
    expect(typeof visit.intake.summary_for_nurse).toBe('string')
    expect(visit.intake.denied_red_flags).toEqual([])
    expect(visit.turns).toContainEqual({ role: 'patient', text: COMPLAINT })
    expect(visit.patient_words).toEqual([COMPLAINT])
  })

  test('a second walk-in for him is refused, in the form, with his words kept', async ({
    page,
  }) => {
    await openDesk(page)
    await registerByChip(page, SALEM.id, COMPLAINT)
    await expect(page.getByTestId('walkin-ticket')).toBeVisible()

    await registerByChip(page, SALEM.id, 'dizzy as well')
    await expect(page.getByTestId('desk-error')).toHaveText(say('en', 'error.active_visit'))
    await expect(page.getByTestId('desk-qid')).toHaveValue(SALEM.qid)
    await expect(page.getByTestId('desk-complaint')).toHaveValue('dizzy as well')
    await expect(page.getByTestId('walkin-ticket')).toHaveCount(0)
    expect(visitsOf(SALEM.id)).toHaveLength(1)
    expect(ticketRows(visitsOf(SALEM.id)[0])).toBe(1)
  })

  test('an unknown QID is refused in the form', async ({ page }) => {
    await openDesk(page)
    await page.getByTestId('desk-qid').fill('DEMO-99999')
    await page.getByTestId('desk-complaint').fill(COMPLAINT)
    await page.getByTestId('desk-submit').click()
    await expect(page.getByTestId('desk-error')).toHaveText(say('en', 'error.unknown_qid'))
    await expect(page.getByTestId('desk-qid')).toHaveValue('DEMO-99999')
  })

  test('Enter and a click on top of it register once', async ({ page }) => {
    let posts = 0
    await page.route('**/api/desk/walk-in', async (route) => {
      posts += 1
      await new Promise((resolve) => setTimeout(resolve, 400))
      await route.continue()
    })
    await openDesk(page)
    await page.getByTestId(`desk-chip-${SALEM.id}`).click()
    await page.getByTestId('desk-complaint').fill(COMPLAINT)
    await page.getByTestId('desk-complaint').press('Enter')
    await page.getByTestId('desk-complaint').press('Enter')
    await page.evaluate(() => document.querySelector('form')?.requestSubmit())
    await expect(page.getByTestId('walkin-ticket')).toBeVisible()
    expect(posts).toBe(1)
    expect(ticketRows(visitsOf(SALEM.id)[0])).toBe(1)
  })

  test('chest pain at the desk gives the emergency panel, no ticket and no number', async ({
    page,
  }) => {
    await openDesk(page)
    await registerByChip(page, RAVI.id, 'chest pain going to my left arm')

    const panel = page.getByTestId('walkin-emergency')
    await expect(panel).toBeVisible()
    await expect(panel).toContainText('No ticket issued')
    await expect(page.getByTestId('walkin-reply')).not.toBeEmpty()
    await expect(page.getByTestId('walkin-call')).toHaveText('Call 999')
    await expect(page.getByTestId('walkin-call')).toHaveAttribute('href', 'tel:999')

    await expect(page.getByTestId('walkin-ticket')).toHaveCount(0)
    expect(await page.locator('#root').innerHTML()).not.toMatch(TICKET_NUMBER)
    const [visitId] = visitsOf(RAVI.id)
    expect(ticketRows(visitId)).toBe(0)

    // The queue steps back in once the clerk moves on.
    await page.getByTestId('walkin-next').click()
    await expect(page.getByTestId('walkin-emergency')).toHaveCount(0)
    await expect(page.getByTestId('queue-table')).toBeVisible()

    // Ravi's QID after his emergency is refused, however he words it.
    await registerByChip(page, RAVI.id, 'I feel better now')
    await expect(page.getByTestId('desk-error')).toHaveText(say('en', 'error.active_visit'))
    await expect(page.getByTestId('walkin-ticket')).toHaveCount(0)
    expect(visitsOf(RAVI.id)).toEqual([visitId])
    expect(ticketRows(visitId)).toBe(0)
  })

  test('an emergency in the patient app also stops the desk', async ({
    page,
    api,
  }) => {
    const { token } = await api.patient(QID.ravi)
    const appVisit = await api.newVisit(token)
    await api.say(token, appVisit, RAVI_WORDS)
    await openDesk(page)
    await registerByChip(page, RAVI.id, 'my arm feels fine, I want a ticket')
    await expect(page.getByTestId('desk-error')).toBeVisible()
    await expect(page.getByTestId('walkin-ticket')).toHaveCount(0)
    expect(ticketRows(appVisit)).toBe(0)
  })

  test('a nurse has the desk too, and it holds no stream at any width', async ({ page }) => {
    await staffLogin(page, NURSE)
    const streams = watchStreams(page)
    await page.goto('/staff/desk')
    await expect(page.getByTestId('queue-table')).toBeVisible()
    expect(await page.getByTestId('desk-queue').textContent()).not.toMatch(/no-show|nobody skips/i)
    await page.setViewportSize(PHONE)
    await expectNoSideScroll(page, 'desk at 390')
    // Both in one frame: the header folds on its own render, and shifts everything under it.
    const gap = await page.evaluate(() => {
      const box = (id: string) =>
        document.querySelector(`[data-testid=${id}]`)?.getBoundingClientRect()
      return (box('desk-queue')?.top ?? 0) - (box('desk-submit')?.bottom ?? 0)
    })
    expect(gap).toBeGreaterThan(-1)
    await page.setViewportSize(DESKTOP)
    const wide = await page.getByTestId('desk-queue').boundingBox()
    const field = await page.getByTestId('desk-qid').boundingBox()
    expect(wide?.x).toBeGreaterThan((field?.x ?? 0) + (field?.width ?? 0))
    expect(streams).toEqual([])
  })

  test('a pharmacist is sent to their own console', async ({ page }) => {
    await staffLogin(page, PHARMACIST)
    await page.goto('/staff/desk')
    await expect(page).toHaveURL(/\/staff\/pharmacy$/)
  })

  test('the slip goes when a reset wipes the ticket it names', async ({ page, api }) => {
    await openDesk(page)
    await registerByChip(page, SALEM.id, COMPLAINT)
    await expect(page.getByTestId('walkin-ticket')).toBeVisible()
    await api.reset()
    await expect(page.getByTestId('walkin-ticket')).toHaveCount(0)
  })
})

test.describe('T08 waiting-room display', () => {
  test('the AI pill reads in both languages whatever the viewer chose', async ({ page }) => {
    const both = 'AI: simulated / الذكاء الاصطناعي: محاكاة'
    await openDisplay(page)
    const pill = page.getByTestId('ai-mode')
    await expect(pill).toHaveText(both)
    await expect(pill).toHaveAttribute('data-mode', 'simulated')
    await expect(pill).toBeInViewport()

    await page.goto('/staff/nurse')
    await page.getByTestId('language-toggle').click()
    await expect(page.locator('html')).toHaveAttribute('lang', 'ar')
    await expect(pill).toHaveText(say('ar', 'footer.ai'))
    await page.goto('/staff/display')
    await expect(pill).toHaveText(both)

    await page.setViewportSize({ width: 390, height: 844 })
    await expect(pill).toBeInViewport()
    const widths = await page.evaluate(() => ({
      content: document.documentElement.scrollWidth,
      screen: window.innerWidth,
    }))
    expect(widths.content).toBeLessThanOrEqual(widths.screen)
  })

  test('shows Arabic and English at once, in triage, room, pharmacy order', async ({ page }) => {
    await openDisplay(page)
    await expect(page.locator('h1')).toHaveText('Now serving / الآن')
    await expect(page.getByTestId('sound-toggle')).toHaveText('Turn on sound / تشغيل الصوت')
    await expect(page.getByTestId('sound-toggle')).toHaveAttribute('data-sound', 'off')
    await expect(page.getByTestId('ai-mode')).toBeVisible()
    await expect(page.getByTestId('footer')).toContainText(say('en', 'footer.demo'))
    await expect(page.getByTestId('footer')).toContainText(say('ar', 'footer.demo'))
    await expect(page.getByTestId('centre-name')).toContainText('Al Wakra Health Centre')
    await expect(page.getByTestId('centre-name')).toContainText('مركز الوكرة الصحي')
    await expect(page.getByTestId('display-clock')).toHaveText(/^\d{2}:\d{2}$/)
    await expect(page.getByTestId('language-toggle')).toHaveCount(0)
    await expect(page.getByTestId('reset-demo')).toHaveCount(0)

    const cells = page.getByTestId('display-counter')
    await expect(cells).toHaveCount(DISPLAY_ORDER.length)
    for (const [index, [counterId, english, arabic]] of DISPLAY_ORDER.entries()) {
      const row = cells.nth(index)
      await expect(row).toHaveAttribute('data-counter', counterId)
      await expect(row.getByTestId('display-label-en')).toHaveText(english)
      await expect(row.getByTestId('display-label-ar')).toHaveText(arabic)
      await expect(row.getByTestId('display-number')).toHaveText('—')
      await expect(row).toContainText('Waiting')
      await expect(row).toContainText('في الانتظار')
    }

    await page.getByTestId('display-dashboard').click()
    await expect(page).toHaveURL(/\/staff\/dashboard$/)
  })

  test('ignores the viewer language: the same screen in an Arabic console', async ({ page }) => {
    await staffLogin(page, NURSE)
    await page.getByTestId('language-toggle').click()
    await expect(page.locator('html')).toHaveAttribute('dir', 'rtl')
    await page.goto('/staff/display')
    await expect(page.locator('html')).toHaveAttribute('dir', 'rtl')
    await expect(page.getByTestId('display-root')).toHaveAttribute('dir', 'ltr')
    await expect(page.locator('h1')).toHaveText('Now serving / الآن')
    await expect(page.getByTestId('display-counter').first()).toHaveAttribute(
      'data-counter',
      TRIAGE_COUNTER,
    )
    await expect(page.getByTestId('display-label-en').first()).toHaveText('Triage 1')
  })

  test('a call updates the number with no reload, and chimes once per change', async ({
    page,
    api,
  }) => {
    const errors: string[] = []
    page.on('pageerror', (error) => errors.push(error.message))
    const { number } = await api.arrivedVisit(QID.fatima)
    await openDisplay(page)
    await expectChimes(page, 0)
    await markThePage(page)

    await api.callNext()
    const triage = cell(page, TRIAGE_COUNTER)
    await expect(triage.getByTestId('display-number')).toHaveText(number)
    await expectChimes(page, 1)
    await expect(triage).toHaveAttribute('data-marked', 'true')
    await expect(cell(page, DOCTOR_COUNTER)).toHaveAttribute('data-marked', 'false')
    const colour = await triage
      .getByTestId('display-number')
      .locator('bdi')
      .evaluate((element) => getComputedStyle(element).color)
    expect(colour).toBe('rgb(29, 95, 191)')
    await expect
      .poll(() => triage.evaluate((element) => getComputedStyle(element).borderTopColor))
      .toBe('rgb(10, 10, 10)')

    // A second identical snapshot, as a reconnect gives.
    await reconnect(page)
    await expect(page.getByTestId('display-root')).toHaveAttribute('data-live', 'live')
    await reconnect(page)
    await expectChimes(page, 1)

    // The mark lasts about six seconds, and the number stays.
    await expect(triage).toHaveAttribute('data-marked', 'false', { timeout: 9_000 })
    await expect(triage.getByTestId('display-number')).toHaveText(number)
    await expectNotReloaded(page)
    expect(errors).toEqual([])
  })

  test('the first snapshot chimes nothing, even with a number already up', async ({
    page,
    api,
  }) => {
    const { number } = await api.arrivedVisit(QID.fatima)
    await api.callNext()
    await openDisplay(page)
    await expect(cell(page, TRIAGE_COUNTER).getByTestId('display-number')).toHaveText(number)
    await expectChimes(page, 0)
  })

  test('a reset clears to dashes with no chime and no reload', async ({ page, api }) => {
    const { number } = await api.arrivedVisit(QID.fatima)
    await openDisplay(page)
    await api.callNext()
    await expect(cell(page, TRIAGE_COUNTER).getByTestId('display-number')).toHaveText(number)
    await expectChimes(page, 1)
    await markThePage(page)

    await api.reset()
    await expectAllDashes(page)
    await expectChimes(page, 1)
    await expect(cell(page, TRIAGE_COUNTER)).toHaveAttribute('data-marked', 'false')
    await reconnect(page)
    await expectChimes(page, 1)
    await expectNotReloaded(page)

    // The next real call after a reset still rings.
    const again = await api.arrivedVisit(QID.fatima)
    await api.callNext()
    await expect(cell(page, TRIAGE_COUNTER).getByTestId('display-number')).toHaveText(again.number)
    await expectChimes(page, 2)
  })

  test('counts a change with sound off, plays two tones with it on, and can be turned off', async ({
    page,
    api,
  }) => {
    await page.addInitScript(() => {
      const audio = window as unknown as {
        AudioContext: typeof AudioContext
        contexts: number
        oscillators: number
      }
      audio.contexts = 0
      audio.oscillators = 0
      audio.AudioContext = class extends audio.AudioContext {
        constructor() {
          super()
          audio.contexts += 1
        }

        createOscillator() {
          audio.oscillators += 1
          return super.createOscillator()
        }
      }
    })
    const counts = () =>
      page.evaluate(() => {
        const { contexts, oscillators } = window as unknown as Record<string, number>
        return { contexts, oscillators }
      })

    const fatima = await api.arrivedVisit(QID.fatima)
    await api.walkIn(SALEM.qid, COMPLAINT)
    const errors: string[] = []
    page.on('pageerror', (error) => errors.push(error.message))
    await openDisplay(page)

    await api.callNext()
    await expectChimes(page, 1)
    expect(await counts()).toEqual({ contexts: 0, oscillators: 0 })

    const toggle = page.getByTestId('sound-toggle')
    await toggle.click()
    await expect(toggle).toHaveAttribute('data-sound', 'on')
    await expect(toggle).toHaveText('Sound is on / الصوت يعمل')
    await expect.poll(counts).toEqual({ contexts: 1, oscillators: 2 })
    await expectChimes(page, 1)

    await api.vitals(fatima.visitId)
    await api.handoff(fatima.visitId)
    await api.callNext()
    await expectChimes(page, 2)
    await api.callNext(DOCTOR_COUNTER, 'S-WAK-DOC2')
    await expectChimes(page, 3)
    await expect.poll(counts).toEqual({ contexts: 1, oscillators: 6 })

    await toggle.click()
    await expect(toggle).toHaveAttribute('data-sound', 'off')
    expect(errors).toEqual([])
  })

  test('never holds a patient name or a visit id, in the page or on the wire', async ({
    page,
    api,
  }) => {
    const walkedIn = await api.walkIn(SALEM.qid, COMPLAINT)
    const fatima = await api.arrivedVisit(QID.fatima)

    const urls: string[] = []
    const bodies: Promise<string>[] = []
    page.on('request', (request) => urls.push(request.url()))
    page.on('response', (response) => {
      if (new URL(response.url()).pathname === `/api/display/${CENTRE}`) {
        bodies.push(response.text())
      }
    })
    await openDisplay(page)
    const token = await api.staffToken(NURSE)
    const base = process.env.DAWRI_E2E_BASE as string
    const watcher = new AbortController()
    const stream = await fetch(`${base}/api/display/${CENTRE}/stream?token=${token}`, {
      signal: watcher.signal,
    })
    const reader = (stream.body as ReadableStream<Uint8Array>).getReader()

    await api.callNext()
    await expect(cell(page, TRIAGE_COUNTER).getByTestId('display-number')).toHaveText(/^T-/)
    let pushed = ''
    while (!pushed.includes('data:')) {
      const { value } = await reader.read()
      pushed += new TextDecoder().decode(value)
    }
    watcher.abort()

    const html = await page.content()
    const secrets = [
      SALEM.en,
      SALEM.ar,
      FATIMA.en,
      FATIMA.ar,
      walkedIn.visit_id,
      fatima.visitId,
      COMPLAINT,
    ]
    const wire = (await Promise.all(bodies)).join('\n')
    for (const secret of secrets) {
      expect(html, secret).not.toContain(secret)
      expect(wire, secret).not.toContain(secret)
      expect(urls.join('\n'), secret).not.toContain(secret)
      expect(pushed, secret).not.toContain(secret)
    }
    expect(wire).not.toContain('visit_id')
    expect(pushed).not.toContain('visit_id')
  })

  for (const [name, size, fontSize] of [
    ['1920', TV, '112px'],
    ['1440', DESKTOP, '100.8px'],
    ['390', PHONE, '48px'],
  ] as const) {
    test(`stays readable with no sideways scroll at ${name}`, async ({ page, api }) => {
      const { number, visitId } = await api.arrivedVisit(QID.fatima)
      await api.callNext()
      await api.vitals(visitId)
      await api.handoff(visitId)
      await page.setViewportSize(size)
      await openDisplay(page)
      await markThePage(page)

      await api.callNext(DOCTOR_COUNTER, 'S-WAK-DOC2')
      const room = cell(page, DOCTOR_COUNTER).getByTestId('display-number')
      await expect(room).toHaveText(/^D-GP-\d{3}$/)
      await expectChimes(page, 1)
      await expect(room).toHaveCSS('font-size', fontSize)
      await expect(cell(page, TRIAGE_COUNTER).getByTestId('display-number')).not.toHaveText(number)
      await expectNoSideScroll(page, `display at ${name}`)
      const clipped = await page
        .getByTestId('display-number')
        .evaluateAll((cells) => cells.some((one) => one.scrollWidth > one.clientWidth))
      expect(clipped).toBe(false)
      await expectNotReloaded(page)
    })
  }
})

test.describe('T09 dashboard', () => {
  /** The screen's figures, worked out from the database by another route than the API's. */
  function figuresFromRows() {
    const one = (statement: string, ...params: string[]) =>
      sql(statement, ...params)[0][0] as number | null
    const waiting = (stage: string) =>
      Number(
        one(
          `SELECT COUNT(*) FROM ticket JOIN counter ON counter.id = ticket.counter_id
           WHERE ticket.centre_id = ? AND ticket.simulated = 0 AND ticket.state = 'active'
           AND counter.stage = ?`,
          CENTRE,
          stage,
        ),
      )
    const status = (value: string) =>
      Number(
        one(
          `SELECT COUNT(*) FROM visit JOIN patient ON patient.id = visit.patient_id
           WHERE COALESCE(visit.centre_id, patient.registered_centre_id) = ?
           AND visit.status = ?`,
          CENTRE,
          value,
        ),
      )
    const triage = waiting('triage')
    const doctor = waiting('doctor')
    const pharmacy = waiting('pharmacy')
    return {
      triage,
      doctor,
      pharmacy,
      total: triage + doctor + pharmacy,
      completed: status('completed'),
      deflections: status('deflected_refill'),
      emergencies: status('redirected_emergency'),
      walkIns: Number(one("SELECT COUNT(*) FROM event WHERE type = 'walk_in.registered'")),
      avgWait: one(
        `SELECT AVG((julianday(called_at) - julianday(activated_at)) * 1440) FROM ticket
         WHERE centre_id = ? AND simulated = 0 AND called_at IS NOT NULL AND state <> 'active'`,
        CENTRE,
      ),
    }
  }

  const figure = (page: Page, id: string) => page.getByTestId(`figure-${id}`)

  async function expectScreenMatchesRows(page: Page) {
    const rows = figuresFromRows()
    const expected: [string, number][] = [
      ['waiting-triage', rows.triage],
      ['waiting-doctor', rows.doctor],
      ['waiting-pharmacy', rows.pharmacy],
      ['waiting-total', rows.total],
      ['completed', rows.completed],
      ['deflections', rows.deflections],
      ['emergencies', rows.emergencies],
      ['walk-ins', rows.walkIns],
    ]
    for (const [id, value] of expected) {
      await expect(figure(page, id), `${id} in ${JSON.stringify(rows)}`).toHaveText(String(value))
    }
    if (rows.avgWait === null) {
      await expect(page.getByTestId('no-wait')).toHaveText('—')
    } else {
      await expect(page.getByTestId('no-wait')).toHaveCount(0)
      const shown = Number(await figure(page, 'avg-wait').getAttribute('data-value'))
      expect(Math.abs(shown - rows.avgWait)).toBeLessThanOrEqual(0.06)
    }
    return rows
  }

  async function openDashboard(page: Page) {
    await staffLogin(page, NURSE)
    await page.goto('/staff/dashboard')
    await expect(page.getByTestId('stats-card')).toBeVisible()
    await expect(figure(page, 'waiting-total')).toHaveAttribute('data-value', /\d+/)
  }

  test('zero prints as 0, a null wait as a dash, and simulated tickets stay out', async ({
    page,
  }) => {
    const simulated = sql('SELECT COUNT(*) FROM ticket WHERE simulated = 1')[0][0]
    expect(Number(simulated)).toBeGreaterThan(0)
    await openDashboard(page)
    const rows = await expectScreenMatchesRows(page)
    expect(rows).toMatchObject({ total: 0, completed: 0, walkIns: 0, avgWait: null })
    await expect(figure(page, 'waiting-total')).toHaveText('0')
    await expect(figure(page, 'avg-wait')).toContainText('no calls yet')
    await expect(page.getByTestId('real-only')).toHaveText(say('en', 'dashboard.realOnly'))
    await expect(page.getByTestId('ai-mode')).toBeVisible()
    const text = await page.locator('body').innerText()
    expect(text).not.toMatch(/no-show|no show/i)
  })

  test('each figure equals the rows, before and after a walk-in and a completed visit', async ({
    page,
    api,
  }) => {
    await openDashboard(page)
    const streams = watchStreams(page)
    await expectScreenMatchesRows(page)

    const walkIn = await api.walkIn(SALEM.qid, COMPLAINT)
    await expect(figure(page, 'walk-ins')).toHaveText('1', { timeout: 8_000 })
    let rows = await expectScreenMatchesRows(page)
    expect(rows).toMatchObject({ triage: 1, total: 1, walkIns: 1 })

    await api.callNext()
    await expect(figure(page, 'waiting-total')).toHaveText('0', { timeout: 8_000 })
    await api.vitals(walkIn.visit_id)
    await api.handoff(walkIn.visit_id)
    await expect(figure(page, 'waiting-doctor')).toHaveText('1', { timeout: 8_000 })
    rows = await expectScreenMatchesRows(page)
    expect(rows).toMatchObject({ doctor: 1, total: 1 })
    expect(rows.avgWait).not.toBeNull()

    await api.consultDone(walkIn.visit_id)
    await expect(figure(page, 'waiting-pharmacy')).toHaveText('1', { timeout: 8_000 })
    await api.dispensed(walkIn.visit_id)
    await expect(figure(page, 'completed')).toHaveText('1', { timeout: 8_000 })
    rows = await expectScreenMatchesRows(page)
    expect(rows).toMatchObject({ total: 0, completed: 1, walkIns: 1 })

    await api.walkIn(RAVI.qid, 'chest pain going to my left arm')
    await expect(figure(page, 'emergencies')).toHaveText('1', { timeout: 8_000 })
    rows = await expectScreenMatchesRows(page)
    expect(rows).toMatchObject({ emergencies: 1, walkIns: 2, total: 0 })

    const mariam = await api.patient(MARIAM_QID)
    await api.say(mariam.token, await api.newVisit(mariam.token), AHMED_WORDS)
    await expect(figure(page, 'deflections')).toHaveText('1', { timeout: 8_000 })
    rows = await expectScreenMatchesRows(page)
    expect(rows).toMatchObject({ deflections: 1, total: 0 })

    expect(streams).toEqual([])
    expect(await page.locator('body').innerText()).not.toMatch(/no-show|no show/i)
  })

  test('goes back to zero after a reset', async ({ page, api }) => {
    await api.walkIn(SALEM.qid, COMPLAINT)
    await openDashboard(page)
    await expect(figure(page, 'waiting-total')).toHaveText('1')
    await api.reset()
    await expect(figure(page, 'waiting-total')).toHaveText('0', { timeout: 8_000 })
    await expectScreenMatchesRows(page)
  })

  test('reads at 390 in Arabic with no sideways scroll', async ({ page }) => {
    await page.setViewportSize(PHONE)
    await staffLogin(page, NURSE)
    await page.goto('/staff/dashboard')
    await expect(page.getByTestId('stats-card')).toBeVisible()
    await page.getByTestId('staff-menu').click()
    await page.getByTestId('language-toggle').click()
    await page.getByTestId('staff-menu').click()
    await expect(page.locator('html')).toHaveAttribute('dir', 'rtl')
    await expect(page.locator('h1')).toHaveText(say('ar', 'dashboard.title'))
    await expect(figure(page, 'avg-wait')).toContainText(say('ar', 'dashboard.noCalls'))
    await expectNoSideScroll(page, 'dashboard at 390')
  })
})
