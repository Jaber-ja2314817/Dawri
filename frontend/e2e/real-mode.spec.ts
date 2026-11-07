import {
  agree,
  answerToSummary,
  confirmSummary,
  documentLoads,
  eventRows,
  expect,
  fakeMicrophone,
  FATIMA_WORDS,
  imHere,
  liveConsole,
  login,
  NURSE,
  queueRow,
  recordVoice,
  reserveHere,
  say,
  send,
  sql,
  startCheckIn,
  test,
  vitalsToDraft,
  visitIdOf,
  type Page,
} from './fixtures'

/*
 * The stand-in server: real mode with injected clients for chat and ASR, and no network.
 * Replaced here: the model, Whisper and the microphone. Real here: every route, the text
 * gate, the JSON checks, MediaRecorder, decodeAudioData, the resample and the WAV encoder.
 */

const MODEL_QUESTION = 'كم شدتها من 0 إلى 10؟'
const ANSWERS = ['5', 'لا', 'لا']
/** The stand-in's MODEL_DOWN: it fails the one turn whose message holds this. */
const MODEL_DOWN = 'standin-model-down'

async function voiceToSummary(page: Page) {
  await fakeMicrophone(page)
  await login(page, 'P001')
  await startCheckIn(page)
  await page.getByTestId('who-P001').click()
  await agree(page)

  const upload = page.waitForResponse('**/api/asr')
  await recordVoice(page)
  expect((await upload).status()).toBe(200)
  await expect(page.getByTestId('voice-transcript')).toHaveValue(FATIMA_WORDS)
  await expect(page.locator('[data-testid=bubble][data-role=user]')).toHaveCount(0)
  await page.getByTestId('voice-send').click()
  await expect(page.locator('[data-testid=bubble][data-role=user]')).toHaveText(FATIMA_WORDS)
  await expect(page.locator('[data-testid=bubble][data-role=assistant]').last()).toHaveText(
    MODEL_QUESTION,
  )
  for (const answer of ANSWERS) await send(page, answer)
  await expect(page.getByTestId('chat-summary')).toBeVisible()
}

test('A1 Arabic voice "عندي حرارة وكحة من ثلاث أيام" gives a GP intake and a ticket', async ({
  page,
  api,
}) => {
  const health = await api.request('GET', '/api/health')
  expect(health.ai_mode).toBe('real')

  await voiceToSummary(page)
  const visitId = visitIdOf(page)
  await expect(page.getByTestId('footer-ai')).toHaveCount(0)
  await confirmSummary(page)
  expect(sql("SELECT json_extract(json, '$.service') FROM intake WHERE visit_id = ?", visitId)).toEqual(
    [['gp']],
  )
  expect(sql('SELECT service FROM visit WHERE id = ?', visitId)).toEqual([['gp']])

  await reserveHere(page)
  await imHere(page)
  await expect(page.getByTestId('ticket-number')).toHaveText('T-014')
  await expect(page.getByTestId('footer')).toBeVisible()
  await expect(page.getByTestId('footer-ai')).toHaveCount(0)
  await expect(page.getByTestId('footer')).not.toContainText('AI: simulated')

  expect(eventRows(visitId, 'ai.fallback')).toBe(0)
  const turns = sql(
    "SELECT json_extract(payload, '$.source') FROM event WHERE visit_id = ? AND type = 'ai.turn'",
    visitId,
  ).map((row) => row[0])
  expect(turns).toEqual(['model', 'model', 'model', 'model'])
})

test('the same visit on T03 and T04 is labelled as the model, with no scripted note', async ({
  page,
  windows,
}) => {
  await voiceToSummary(page)
  const visitId = visitIdOf(page)
  await confirmSummary(page)
  await reserveHere(page)
  await imHere(page)

  const nurse = await windows.staff(NURSE)
  await liveConsole(nurse)
  const loads = documentLoads(nurse)
  await expect(nurse.getByTestId('ai-mode')).toHaveAttribute('data-mode', 'real')
  await expect(queueRow(nurse, 'T-014')).toContainText('Fatima Al-Demo')
  await nurse.getByTestId('call-next').click()
  await nurse.waitForURL(`**/staff/nurse/${visitId}`)
  await expect(nurse.getByTestId('ai-summary')).toContainText('Stand-in model summary')
  await expect(page.getByText('Stand-in model summary')).toHaveCount(0)
  const card = nurse.getByTestId('intake-card')
  await expect(card).toContainText(say('en', 'nurse.intake.reason'))
  await expect(card).toContainText(say('en', 'nurse.intake.summary'))
  await expect(card).not.toContainText(say('en', 'nurse.intake.summaryScripted'))

  await vitalsToDraft(nurse, visitId)
  await expect(nurse.getByTestId('handoff-source')).toHaveAttribute('data-source', 'model')
  await expect(nurse.getByTestId('handoff-text')).toHaveValue(/Allergies: penicillin\./)
  expect(eventRows(visitId, 'ai.fallback')).toBe(0)
  expect(loads()).toBe(0)
})

test('a model failure on the turn that built the intake reads as scripted on T03, under AI: model', async ({
  page,
  windows,
}) => {
  await login(page, 'P001')
  await startCheckIn(page)
  await page.getByTestId('who-P001').click()
  await agree(page)
  await answerToSummary(page, FATIMA_WORDS, ['5', 'لا', `لا ${MODEL_DOWN}`])
  const visitId = visitIdOf(page)
  await confirmSummary(page)
  await reserveHere(page)
  await imHere(page)

  const turns = sql(
    "SELECT json_extract(payload, '$.source') FROM event WHERE visit_id = ? AND type = 'ai.turn'",
    visitId,
  ).map((row) => row[0])
  expect(turns).toEqual(['model', 'model', 'model', 'simulated'])
  expect(eventRows(visitId, 'ai.fallback')).toBe(1)

  const nurse = await windows.staff(NURSE)
  await liveConsole(nurse)
  await expect(nurse.getByTestId('ai-mode')).toHaveAttribute('data-mode', 'real')
  await expect(queueRow(nurse, 'T-014')).toContainText('Fatima Al-Demo')
  await nurse.getByTestId('call-next').click()
  await nurse.waitForURL(`**/staff/nurse/${visitId}`)
  await expect(nurse.getByTestId('ai-mode')).toHaveAttribute('data-mode', 'real')

  const card = nurse.getByTestId('intake-card')
  for (const lang of ['en', 'ar'] as const) {
    await expect(nurse.locator('html')).toHaveAttribute('lang', lang)
    await expect(card).toContainText(say(lang, 'nurse.intake.reasonScripted'))
    await expect(card).toContainText(say(lang, 'nurse.intake.summaryScripted'))
    await expect(card).not.toContainText(say(lang, 'nurse.intake.reason'))
    await expect(card).not.toContainText(say(lang, 'nurse.intake.summary'))

    await nurse.getByTestId('intake-edit').click()
    await expect(nurse.getByLabel(say(lang, 'nurse.intake.reasonScripted'))).toBeVisible()
    await expect(nurse.getByLabel(say(lang, 'nurse.intake.summaryScripted'))).toBeVisible()
    await expect(card).not.toContainText(say(lang, 'nurse.intake.reason'))
    await expect(card).not.toContainText(say(lang, 'nurse.intake.summary'))
    await nurse.getByTestId('intake-cancel').click()

    if (lang === 'en') await nurse.getByTestId('language-toggle').click()
  }
})
