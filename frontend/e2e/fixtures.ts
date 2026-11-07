import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  test as base,
  expect,
  type BrowserContext,
  type Page,
  type Route,
  type ViewportSize,
} from '@playwright/test'
import { DemoApi, FATIMA_ANSWERS, FATIMA_WORDS } from '../scripts/lib/demo-api.mjs'

export { expect }
export type { BrowserContext, Page, Route }
export * from '../scripts/lib/demo-api.mjs'

const ROOT = process.env.DAWRI_E2E_ROOT as string
const CONTAINER = process.env.DAWRI_E2E_CONTAINER

/* The app's own strings. Mandated wording is spelled out in the specs instead. */
function dictionary(lang: 'ar' | 'en'): Record<string, string> {
  return Object.assign(
    {},
    ...['', 'chat.', 'visit.', 'staff.', 'staff.nurse.', 'staff.clinic.', 'staff.floor.'].map((part) =>
      JSON.parse(readFileSync(join(ROOT, 'frontend/src/i18n', `${part}${lang}.json`), 'utf8')),
    ),
  )
}
const STRINGS = { ar: dictionary('ar'), en: dictionary('en') }

export function say(lang: 'ar' | 'en', key: string): string {
  const text = STRINGS[lang][key]
  if (text === undefined) throw new Error(`no string ${key}`)
  return text
}

/* 1x1 grey PNG, so every map test owns its tiles and none needs the network. */
export const TILE_PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  'base64',
)
export const TILES = 'https://tile.openstreetmap.org/**'

export async function serveTiles(page: Page) {
  await page.route(TILES, (route) =>
    route.fulfill({ status: 200, contentType: 'image/png', body: TILE_PNG }),
  )
}

/** One read or write on the server's own database, for facts no route exposes. */
export function sql(statement: string, ...params: string[]): unknown[][] {
  const script = [
    'import json, sqlite3, sys',
    'conn = sqlite3.connect(sys.argv[1])',
    'rows = conn.execute(sys.argv[2], sys.argv[3:]).fetchall()',
    'conn.commit()',
    'print(json.dumps(rows))',
  ].join('\n')
  const db = base.info().project.metadata.db as string
  const output =
    CONTAINER === undefined
      ? execFileSync(join(ROOT, '.venv/bin/python'), ['-c', script, db, statement, ...params], {
          encoding: 'utf8',
        })
      : execFileSync(
          'docker',
          ['exec', CONTAINER, 'python', '-c', script, db, statement, ...params],
          { encoding: 'utf8' },
        )
  return JSON.parse(output)
}

export const ticketRows = (visitId: string) =>
  Number(sql('SELECT COUNT(*) FROM ticket WHERE visit_id = ?', visitId)[0][0])

export const eventRows = (visitId: string, type: string) =>
  Number(sql('SELECT COUNT(*) FROM event WHERE visit_id = ? AND type = ?', visitId, type)[0][0])

/** Puts the reservation past its 45 minutes, as if the patient had never come. */
export function backdateReservation(visitId: string) {
  const past = new Date(Date.now() - 46 * 60_000).toISOString().replace('Z', '+00:00')
  sql("UPDATE ticket SET reserved_at = ? WHERE visit_id = ? AND state = 'reserved'", past, visitId)
}

export function visitIdOf(page: Page): string {
  const match = /\/visit\/([^/]+)/.exec(new URL(page.url()).pathname)
  if (match === null) throw new Error(`not on a visit: ${page.url()}`)
  return match[1]
}

/* Steps a patient takes, each through the screen itself. */

export async function login(page: Page, chip: 'P001' | 'P002' | 'P003') {
  await page.goto('/login')
  await page.getByTestId(`chip-${chip}`).click()
  await page.waitForURL('**/home')
}

/** A staff member signs in through their chip on T01, at the default centre unless told. */
export async function staffLogin(page: Page, staffId: string, centreId?: string) {
  await page.goto('/staff/login')
  if (centreId !== undefined) await page.getByTestId('staff-centre').selectOption(centreId)
  await page.getByTestId(`staff-chip-${staffId}`).click()
  await page.waitForURL((url) => url.pathname !== '/staff/login')
  await expect(page.getByTestId('staff-logout').or(page.getByTestId('staff-menu'))).toBeVisible()
}

export async function startCheckIn(page: Page, lang: 'ar' | 'en' = 'ar') {
  await page.getByRole('button', { name: say(lang, 'home.start') }).click()
}

export async function agree(page: Page, lang: 'ar' | 'en' = 'ar') {
  await page.getByRole('button', { name: say(lang, 'consent.agree') }).click()
  await page.waitForURL(/\/visit\/[^/]+\/(chat|emergency)$/)
}

/** Sends one message and waits for whatever it leads to. */
export async function send(page: Page, text: string) {
  const replies = await page.locator('[data-testid=bubble][data-role=assistant]').count()
  const closed = page.getByTestId('chat-summary-text')
  const before = (await closed.count()) > 0 ? await closed.textContent() : null
  await page.getByTestId('chat-input').fill(text)
  await page.getByTestId('chat-send').click()
  await expect
    .poll(
      async () => {
        if (!/\/chat$/.test(page.url())) return true
        const shown = await page.locator('[data-testid=bubble][data-role=assistant]').count()
        if (before === null) return shown > replies || (await closed.count()) > 0
        return (await closed.count()) === 0 || (await closed.textContent()) !== before
      },
      { timeout: 10_000 },
    )
    .toBe(true)
}

export async function answerToSummary(
  page: Page,
  words = FATIMA_WORDS,
  answers: string[] = FATIMA_ANSWERS,
) {
  await send(page, words)
  for (const answer of answers) {
    if ((await page.getByTestId('chat-summary').count()) > 0) break
    await send(page, answer)
  }
  await expect(page.getByTestId('chat-summary')).toBeVisible()
}

export async function confirmSummary(page: Page) {
  await page.getByTestId('chat-summary-yes').click()
  await page.waitForURL('**/centre')
  await expect(page.getByTestId('selected-centre')).toBeVisible()
}

export async function fatimaToCentre(page: Page) {
  await login(page, 'P001')
  await startCheckIn(page)
  await page.getByTestId('who-P001').click()
  await agree(page)
  await answerToSummary(page)
  await confirmSummary(page)
}

export async function reserveHere(page: Page) {
  await page.getByTestId('check-in-here').click()
  await page.waitForURL('**/reserved')
  await expect(page.getByTestId('countdown')).toBeVisible()
}

export async function imHere(page: Page) {
  await page.getByTestId('im-here').click()
  await page.waitForURL('**/ticket')
  await expect(page.getByTestId('ticket-number')).toBeVisible()
}

/** Resolves once the screen holds an open stream, so a push cannot arrive before it. */
export async function streamOpen(page: Page) {
  await expect(page.getByTestId('ticket-card')).toHaveAttribute('data-live', 'live')
}

/** A throwaway mark that an actual reload would wipe. */
export async function markThePage(page: Page) {
  await page.evaluate(() => {
    ;(window as unknown as { __notReloaded: boolean }).__notReloaded = true
  })
}

export async function expectNotReloaded(page: Page) {
  const mark = await page.evaluate(
    () => (window as unknown as { __notReloaded?: boolean }).__notReloaded,
  )
  expect(mark).toBe(true)
}

/** Page errors, console errors and any refused /api/ call, in one list a test can assert empty. */
export function watchForFaults(faults: string[], ...pages: Page[]) {
  for (const page of pages) {
    page.on('pageerror', (error) => faults.push(`page error on ${page.url()}: ${error.message}`))
    page.on('console', (message) => {
      if (message.type() === 'error') faults.push(`console on ${page.url()}: ${message.text()}`)
    })
    page.on('response', (response) => {
      const path = new URL(response.url()).pathname
      if (path.startsWith('/api/') && response.status() >= 400) {
        faults.push(`${response.request().method()} ${path} gave ${response.status()}`)
      }
    })
  }
}

/** Whole-document loads from now on. Moving between screens in the app is not one. */
export function documentLoads(page: Page): () => number {
  let loads = 0
  page.on('request', (request) => {
    if (request.isNavigationRequest() && request.frame() === page.mainFrame()) loads += 1
  })
  return () => loads
}

export const queueRow = (page: Page, number: string) =>
  page.locator(`[data-testid=queue-row][data-number="${number}"]`)

export const queueNumbers = (page: Page) =>
  page
    .getByTestId('queue-row')
    .evaluateAll((rows) => rows.map((row) => row.getAttribute('data-number')))

export async function liveConsole(page: Page) {
  await expect(page.getByTestId('live-state')).toHaveAttribute('data-live', 'live')
}

export async function fillVitals(page: Page) {
  await page.getByTestId('vital-bp_sys').fill('118')
  await page.getByTestId('vital-bp_dia').fill('76')
  await page.getByTestId('vital-hr').fill('88')
  await page.getByTestId('vital-temp_c').fill('38.2')
  await page.getByTestId('vital-spo2').fill('98')
  await page.getByTestId('vital-weight_kg').fill('62')
}

/** T03 to T04: vitals, the nurse's own urgency, and the draft on screen. */
export async function vitalsToDraft(page: Page, visitId: string) {
  await fillVitals(page)
  await page.getByTestId('urgency-routine').check()
  await page.getByTestId('vitals-submit').click()
  await page.waitForURL(`**/staff/nurse/${visitId}/handoff`)
  await expect(page.getByTestId('handoff-text')).toBeVisible()
}

/*
 * getUserMedia hangs under automation on this machine even with Chrome's fake device, so the
 * microphone alone is replaced: an oscillator through a real MediaStream. MediaRecorder,
 * decodeAudioData, the resample and the WAV encoder are the app's own and all run for real.
 */
export async function fakeMicrophone(page: Page) {
  await page.addInitScript(() => {
    navigator.mediaDevices.getUserMedia = async () => {
      const audio = new AudioContext()
      const oscillator = audio.createOscillator()
      const destination = audio.createMediaStreamDestination()
      oscillator.frequency.value = 220
      oscillator.connect(destination)
      oscillator.start()
      await audio.resume()
      return destination.stream
    }
  })
}

export async function recordVoice(page: Page) {
  await page.getByTestId('chat-mic').click()
  await expect(page.getByTestId('voice-stop')).toBeVisible()
  await page.waitForTimeout(1_100)
  await page.getByTestId('voice-stop').click()
}

/** A separate browser profile per call: its own storage, and its own six connections. */
export interface Windows {
  context: (viewport?: ViewportSize) => Promise<BrowserContext>
  phone: () => Promise<Page>
  staff: (staffId: string, centreId?: string) => Promise<Page>
}

export const PHONE_SIZE: ViewportSize = { width: 390, height: 844 }
export const DESK_SIZE: ViewportSize = { width: 1440, height: 900 }

export const test = base.extend<{ api: DemoApi; freshDemo: void; windows: Windows }>({
  api: async ({ baseURL }, use) => {
    await use(new DemoApi(baseURL as string))
  },
  windows: async ({ browser, baseURL }, use) => {
    const opened: BrowserContext[] = []
    const context: Windows['context'] = async (viewport = DESK_SIZE) => {
      const made = await browser.newContext({
        baseURL,
        viewport,
        locale: 'en-GB',
        timezoneId: 'Asia/Qatar',
      })
      opened.push(made)
      return made
    }
    await use({
      context,
      phone: async () => {
        const page = await (await context(PHONE_SIZE)).newPage()
        await serveTiles(page)
        return page
      },
      staff: async (staffId, centreId) => {
        const page = await (await context()).newPage()
        await staffLogin(page, staffId, centreId)
        return page
      },
    })
    // A context left open would hold its streams against the server until the run ends.
    await Promise.all(opened.map((made) => made.close()))
  },
  freshDemo: [
    async ({ api, page }, use) => {
      await api.reset()
      await serveTiles(page)
      await use()
    },
    { auto: true },
  ],
})
