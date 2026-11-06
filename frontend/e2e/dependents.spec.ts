import { agree, answerToSummary, confirmSummary, expect, imHere, login, reserveHere, startCheckIn, test } from './fixtures'

test('Fatima books for Layla, and the ticket and Home both name her', async ({ page, api }) => {
  await login(page, 'P001')
  await startCheckIn(page)

  // S04: Fatima herself and her two dependents.
  await expect(page.getByTestId(/^who-/)).toHaveCount(3)
  await expect(page.getByTestId('who-P004')).toBeVisible()
  await expect(page.getByTestId('who-P005')).toBeVisible()
  await expect(page.getByTestId('who-P004')).toContainText('ليلى')

  await page.getByTestId('who-P004').click()
  await expect(page.locator('main')).toContainText('ليلى')
  await agree(page)
  await answerToSummary(page, 'عندها حرارة وكحة من ثلاث أيام')
  await confirmSummary(page)
  await reserveHere(page)
  await imHere(page)

  await expect(page.getByTestId('visit-for')).toContainText('ليلى')
  await expect(page.getByTestId('ticket-number')).toHaveText('T-014')

  await page.goto('/home')
  const card = page.getByTestId('open-visit')
  await expect(card).toHaveCount(1)
  await expect(card).toContainText('ليلى')
  await expect(card).toContainText('الفرز')

  // Booked by Fatima: it stays hers to open.
  await card.click()
  await page.waitForURL('**/ticket')
  await expect(page.getByTestId('visit-for')).toContainText('ليلى')
  await api.callNext()
  await expect(page.getByTestId('ticket-called')).toBeVisible()
})
