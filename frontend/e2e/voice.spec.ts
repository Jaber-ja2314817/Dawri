import {
  agree,
  expect,
  fakeMicrophone,
  FATIMA_WORDS,
  login,
  RAVI_WORDS,
  recordVoice,
  say,
  startCheckIn,
  test,
  ticketRows,
  visitIdOf,
  type Page,
} from './fixtures'

async function refuseMicrophone(page: Page) {
  await page.addInitScript(() => {
    navigator.mediaDevices.getUserMedia = async () => {
      throw new DOMException('Permission denied', 'NotAllowedError')
    }
  })
}

async function toChat(page: Page, chip: 'P001' | 'P003' = 'P001') {
  await login(page, chip)
  const lang = chip === 'P001' ? 'ar' : 'en'
  await startCheckIn(page, lang)
  if (chip === 'P001') await page.getByTestId('who-P001').click()
  await agree(page, lang)
}

function countChatPosts(page: Page): () => number {
  let posts = 0
  page.on('request', (request) => {
    if (request.method() === 'POST' && /\/api\/visits\/[^/]+\/chat$/.test(request.url())) posts += 1
  })
  return () => posts
}

/** Nothing about a recording may outlive it, in any browser store. */
async function expectNoAudioKept(page: Page) {
  const kept = await page.evaluate(async () => ({
    keys: Object.keys(localStorage),
    session: Object.keys(sessionStorage),
    databases: (await indexedDB.databases()).map((database) => database.name),
    caches: await caches.keys(),
  }))
  expect(kept.keys.filter((key) => !/^dawri\.(token|lang|lang\.chosen)$/.test(key))).toEqual([])
  expect(kept.session).toEqual([])
  expect(kept.databases).toEqual([])
  expect(kept.caches).toEqual([])
  const values = await page.evaluate(() => Object.values(localStorage).join(' '))
  expect(values).not.toMatch(/RIFF|audio/)
}

/** Field by field, from the bytes that left the browser. */
function parseWav(body: Buffer) {
  const headerEnd = body.indexOf('\r\n\r\n')
  expect(headerEnd).toBeGreaterThan(0)
  const header = body.subarray(0, headerEnd).toString('latin1')
  expect(header).toContain('name="audio"')
  expect(header).toContain('filename="audio.wav"')

  const file = body.subarray(headerEnd + 4)
  expect(file.toString('latin1', 0, 4)).toBe('RIFF')
  expect(file.toString('latin1', 8, 12)).toBe('WAVE')
  expect(file.toString('latin1', 12, 16)).toBe('fmt ')
  expect(file.toString('latin1', 36, 40)).toBe('data')
  return {
    format: file.readUInt16LE(20),
    channels: file.readUInt16LE(22),
    sampleRate: file.readUInt32LE(24),
    byteRate: file.readUInt32LE(28),
    blockAlign: file.readUInt16LE(32),
    bitsPerSample: file.readUInt16LE(34),
    dataBytes: file.readUInt32LE(40),
  }
}

test('the simulated server refuses voice: Arabic message, focus in the box, no transcript', async ({
  page,
}) => {
  await fakeMicrophone(page)
  await toChat(page)
  const chatPosts = countChatPosts(page)

  const answer = page.waitForResponse('**/api/asr')
  await recordVoice(page)
  const response = await answer
  expect(response.status()).toBe(503)
  const body = await response.json()
  expect(typeof body.message_ar).toBe('string')

  await expect(page.getByTestId('voice-error')).toHaveText(body.message_ar)
  await expect(page.getByTestId('chat-input')).toBeFocused()
  await expect(page.getByTestId('voice-transcript')).toHaveCount(0)
  await expect(page.getByTestId('voice-confirm')).toHaveCount(0)
  await expect(page.locator('[data-testid=bubble][data-role=user]')).toHaveCount(0)
  expect(chatPosts()).toBe(0)
  await expectNoAudioKept(page)
})

test('the upload is 16 kHz mono PCM WAV, and nothing is sent until the patient says so', async ({
  page,
}) => {
  await fakeMicrophone(page)
  await toChat(page)
  const chatPosts = countChatPosts(page)

  let wav: ReturnType<typeof parseWav> | null = null
  await page.route('**/api/asr', async (route) => {
    wav = parseWav(route.request().postDataBuffer() as Buffer)
    await route.fulfill({ json: { text: FATIMA_WORDS } })
  })

  await recordVoice(page)
  const transcript = page.getByTestId('voice-transcript')
  await expect(transcript).toHaveValue(FATIMA_WORDS)
  await expect(page.getByTestId('voice-confirm')).toContainText(say('ar', 'voice.confirm.check'))

  const fields = wav as unknown as ReturnType<typeof parseWav>
  expect(fields.format).toBe(1)
  expect(fields.channels).toBe(1)
  expect(fields.sampleRate).toBe(16000)
  expect(fields.bitsPerSample).toBe(16)
  expect(fields.byteRate).toBe(32000)
  expect(fields.blockAlign).toBe(2)
  expect(fields.dataBytes).toBeGreaterThan(16000) // Over half a second of 16-bit samples.

  // The transcript sits there until the patient acts on it.
  await page.waitForTimeout(600)
  expect(chatPosts()).toBe(0)
  await expect(page.locator('[data-testid=bubble][data-role=user]')).toHaveCount(0)

  await page.getByTestId('voice-send').click()
  await expect(page.locator('[data-testid=bubble][data-role=user]')).toHaveText(FATIMA_WORDS)
  await expect.poll(chatPosts).toBe(1)
  await expect(page.locator('[data-testid=bubble][data-role=assistant]')).toHaveCount(2)
  await expectNoAudioKept(page)
})

test('a confirmed spoken red flag reaches S06 with no ticket', async ({ page }) => {
  await fakeMicrophone(page)
  await toChat(page, 'P003')
  const visitId = visitIdOf(page)
  await page.route('**/api/asr', (route) => route.fulfill({ json: { text: RAVI_WORDS } }))

  await recordVoice(page)
  await expect(page.getByTestId('voice-transcript')).toHaveValue(RAVI_WORDS)
  expect(new URL(page.url()).pathname).toMatch(/\/chat$/)

  await page.getByTestId('voice-send').click()
  await page.waitForURL('**/emergency')
  await expect(page.getByTestId('emergency-call')).toHaveAttribute('href', 'tel:999')
  expect(ticketRows(visitId)).toBe(0)
})

/* The two chat states the inspector cannot reach: it has no way to hold a screen mid-action. */
test.describe('the states only a running flow can show', () => {
  const shots = `${process.env.DAWRI_E2E_ROOT}/.taste-skill/inspect/playwright`

  for (const lang of ['ar', 'en'] as const) {
    test(`listening and thinking, in ${lang}`, async ({ page }) => {
      await fakeMicrophone(page)
      await toChat(page)
      if (lang === 'en') await page.getByTestId('language-toggle').click()

      await page.getByTestId('chat-mic').click()
      await expect(page.getByTestId('voice-stop')).toBeVisible()
      await expect(page.getByTestId('voice-timer')).toHaveText(/^0:0\d$/)
      await page.screenshot({ path: `${shots}/s05-listening-${lang}-390.png` })
      await page.setViewportSize({ width: 1440, height: 900 })
      await page.screenshot({ path: `${shots}/s05-listening-${lang}-1440.png` })
      await page.setViewportSize({ width: 390, height: 844 })

      await page.route('**/api/asr', (route) => route.fulfill({ json: { text: FATIMA_WORDS } }))
      // A recording under about 150 ms cannot be decoded, so it would never reach the transcript.
      await page.waitForTimeout(1_100)
      await page.getByTestId('voice-stop').click()
      await expect(page.getByTestId('voice-transcript')).toHaveValue(FATIMA_WORDS)
      await page.screenshot({ path: `${shots}/s05-confirm-${lang}-390.png` })

      let release = () => {}
      const held = new Promise<void>((resolve) => {
        release = resolve
      })
      await page.route('**/api/visits/*/chat', async (route) => {
        await held
        await route.continue()
      })
      await page.getByTestId('voice-send').click()
      await expect(page.getByTestId('chat-thinking')).toHaveText(say(lang, 'chat.thinking'))
      await expect(page.getByTestId('chat-input')).not.toBeEditable()
      await page.screenshot({ path: `${shots}/s05-thinking-${lang}-390.png` })
      await page.setViewportSize({ width: 1440, height: 900 })
      await page.screenshot({ path: `${shots}/s05-thinking-${lang}-1440.png` })
      await page.setViewportSize({ width: 390, height: 844 })

      release()
      await expect(page.getByTestId('chat-thinking')).toHaveCount(0)
      await expect(page.locator('[data-testid=bubble][data-role=assistant]')).toHaveCount(2)
    })
  }
})

test('a blocked microphone tells the patient to type, and typing works', async ({ page }) => {
  await refuseMicrophone(page)
  await toChat(page)

  await page.getByTestId('chat-mic').click()
  await expect(page.getByTestId('voice-error')).toHaveText(say('ar', 'voice.error.denied'))
  await expect(page.getByTestId('chat-input')).toBeFocused()

  await page.getByTestId('chat-input').fill(FATIMA_WORDS)
  await expect(page.getByTestId('voice-error')).toHaveCount(0)
  await page.getByTestId('chat-send').click()
  await expect(page.locator('[data-testid=bubble][data-role=user]')).toHaveText(FATIMA_WORDS)
  await expectNoAudioKept(page)
})
