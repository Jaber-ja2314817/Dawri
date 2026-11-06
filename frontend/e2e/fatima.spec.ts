import {
  agree,
  answerToSummary,
  confirmSummary,
  eventRows,
  expect,
  expectNotReloaded,
  imHere,
  login,
  markThePage,
  NURSE,
  QID,
  reserveHere,
  send,
  startCheckIn,
  streamOpen,
  test,
  TRIAGE_COUNTER,
  visitIdOf,
} from './fixtures'

test('Fatima goes from chip login to a rated visit in Arabic, live and with no reload', async ({
  page,
  api,
}) => {
  await login(page, 'P001')
  await expect(page.locator('html')).toHaveAttribute('dir', 'rtl')
  await expect(page.locator('html')).toHaveAttribute('lang', 'ar')

  const main = page.locator('main')
  await expect(main).toContainText('مركز الوكرة الصحي')
  await expect(main).toContainText('البنسلين')

  await startCheckIn(page)
  await page.getByTestId('who-P001').click()
  await agree(page)
  const visitId = visitIdOf(page)

  await answerToSummary(page)
  const summary = page.getByTestId('chat-summary-text')
  await expect(summary).toContainText('3 أيام')

  // A correction changes the card the patient is about to confirm.
  await page.getByTestId('chat-summary-change').click()
  await expect(page.getByTestId('chat-input')).toBeFocused()
  await send(page, 'لا، من يومين مو ثلاث')
  await expect(summary).toContainText('يومين')
  await expect(summary).not.toContainText('3 أيام')
  await confirmSummary(page)

  // S08: the registered centre leads, and the alternative is visibly slower.
  await page.getByTestId('view-list').click()
  const rows = page.getByTestId('centre-row')
  await expect(rows.first()).toHaveAttribute('data-centre-id', 'C-WAKRA')
  await expect(rows.first()).toContainText('مركز الوكرة الصحي')
  await expect(rows.first()).toContainText('12')
  const airport = rows.filter({ hasText: 'مركز المطار الصحي' })
  const airportWait = Number(
    (await airport.locator('span.font-semibold').textContent())?.match(/\d+/)?.[0],
  )
  expect(airportWait).toBeGreaterThanOrEqual(32)
  expect(airportWait).toBeLessThanOrEqual(38)

  // S09: the mandated words, a clock that runs, and no number of any kind.
  await reserveHere(page)
  await expect(main).toContainText('تسجيل الوصول صالح لمدة 45 دقيقة')
  const countdown = page.getByTestId('countdown')
  await expect(countdown).toHaveText(/^44:\d\d$/)
  const firstReading = await countdown.textContent()
  await expect(countdown).not.toHaveText(firstReading as string, { timeout: 3_000 })
  await expect(countdown.locator('bdi')).toHaveCSS('direction', 'ltr')
  await expect(page.getByTestId('ticket-number')).toHaveCount(0)
  await expect(page.getByTestId('people-ahead')).toHaveCount(0)
  await expect(main).not.toContainText(/[TDP]-(GP-)?\d{3}/)

  // S10: the number exists only now.
  await imHere(page)
  await expect(page.getByTestId('ticket-number')).toHaveText('T-014')
  await expect(page.getByTestId('people-ahead')).toHaveText('3')
  await expect(page.getByTestId('est-wait')).toContainText('12')
  const box = await page.getByTestId('ticket-number').locator('bdi').evaluate((node) => ({
    dir: getComputedStyle(node).direction,
  }))
  expect(box.dir).toBe('ltr')

  await streamOpen(page)
  await markThePage(page)

  const called = await api.callNext(TRIAGE_COUNTER)
  expect(called.called.number).toBe('T-014')
  await expect(page.getByTestId('ticket-called')).toBeVisible({ timeout: 2_000 })
  await expect(page.getByTestId('ticket-called')).toContainText('الفرز 1')

  await api.vitals(visitId)
  await expect(page.getByTestId('ticket-serving')).toBeVisible({ timeout: 2_000 })

  await api.handoff(visitId)
  await expect(page.getByTestId('ticket-number')).toHaveText('D-GP-023', { timeout: 2_000 })
  await expect(page.getByTestId('step-doctor')).toHaveAttribute('aria-current', 'step')

  await api.consultDone(visitId)
  await expect(page.getByTestId('ticket-number')).toHaveText('P-031', { timeout: 2_000 })
  await expect(page.getByTestId('step-pharmacy')).toHaveAttribute('aria-current', 'step')

  await api.dispensed(visitId)
  await page.waitForURL('**/complete', { timeout: 2_000 })
  await expectNotReloaded(page)

  // S11: the medicine reads in Arabic, on the screen's own side.
  const medicine = page.getByTestId('medicine').first()
  await expect(medicine).toContainText('ديكستروميثورفان')
  await expect(medicine).toContainText('كل 8 ساعات')

  const stats = () => api.asStaff(NURSE, 'GET', '/api/stats/C-WAKRA')
  const statsBefore = await stats()
  await page.getByTestId('rate-star').nth(3).click()
  await expect(page.getByTestId('rating-read-only')).toContainText('4/5')
  expect(eventRows(visitId, 'visit.rated')).toBe(1)
  expect(await stats()).toEqual(statsBefore)
  await page.reload()
  await expect(page.getByTestId('rating-read-only')).toContainText('4/5')
  await expect(page.getByTestId('rate-star')).toHaveCount(0)

  const fatima = await api.patient(QID.fatima)
  const second = api.request('POST', `/api/visits/${visitId}/rating`, {
    token: fatima.token,
    body: { stars: 1 },
  })
  await expect(second).rejects.toMatchObject({ status: 409 })
  expect(eventRows(visitId, 'visit.rated')).toBe(1)

  await page.getByRole('link', { name: 'السجل' }).click()
  await page.waitForURL('**/history')
  const row = page.getByTestId('history-row')
  await expect(row).toHaveCount(1)
  await expect(row).toContainText('مركز الوكرة الصحي')
  await expect(row).toContainText('مكتملة')
})
