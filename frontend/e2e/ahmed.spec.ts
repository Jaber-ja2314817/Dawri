import {
  agree,
  AHMED_WORDS,
  eventRows,
  expect,
  login,
  send,
  startCheckIn,
  test,
  ticketRows,
  visitIdOf,
} from './fixtures'

test('Ahmed is sent to the refill route with no ticket, and can still ask for a visit', async ({
  page,
}) => {
  await login(page, 'P002')
  await startCheckIn(page)
  await agree(page)
  const visitId = visitIdOf(page)

  await send(page, AHMED_WORDS)
  await page.waitForURL('**/refill')
  await expect(page.getByTestId('refill-medicine')).toHaveText('amlodipine 5 mg once daily')
  expect(ticketRows(visitId)).toBe(0)

  await page.reload()
  await expect(page.getByTestId('refill-medicine')).toHaveText('amlodipine 5 mg once daily')
  expect(ticketRows(visitId)).toBe(0)

  await page.getByTestId('refill-visit').click()
  await page.waitForURL('**/centre')
  await page.getByTestId('view-list').click()
  await expect(page.getByTestId('centre-row').first()).toHaveAttribute('data-centre-id', 'C-RAYYAN')
  await expect(page.getByTestId('selected-centre')).toContainText('مركز الريان الصحي')
  expect(ticketRows(visitId)).toBe(0)
  expect(eventRows(visitId, 'consent.given')).toBe(1)
})
