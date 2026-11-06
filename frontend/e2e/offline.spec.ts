import {
  expect,
  expectNotReloaded,
  fatimaToCentre,
  imHere,
  markThePage,
  reserveHere,
  streamOpen,
  test,
  TRIAGE_COUNTER,
  visitIdOf,
} from './fixtures'

test('the whole Fatima flow asks for nothing but its own origin and map tiles', async ({
  page,
  api,
  baseURL,
}) => {
  const requests: string[] = []
  page.on('request', (request) => requests.push(request.url()))

  await fatimaToCentre(page)
  await reserveHere(page)
  await imHere(page)
  const visitId = visitIdOf(page)
  await streamOpen(page)
  await markThePage(page)
  await api.callNext(TRIAGE_COUNTER)
  await api.vitals(visitId)
  await api.handoff(visitId)
  await api.consultDone(visitId)
  await api.dispensed(visitId)
  await page.waitForURL('**/complete')
  await expectNotReloaded(page)
  await page.evaluate(() => document.fonts.ready)

  const own = new URL(baseURL as string).origin
  const foreign = requests
    .filter((url) => !url.startsWith('data:') && !url.startsWith('blob:'))
    .map((url) => new URL(url))
    .filter((url) => url.origin !== own && url.hostname !== 'tile.openstreetmap.org')
    .map((url) => url.href)
  expect(foreign).toEqual([])

  expect(requests.some((url) => url.startsWith(`${own}/assets/`) && /\.woff2?$/.test(url))).toBe(true)
  expect(requests.some((url) => url.includes('tile.openstreetmap.org'))).toBe(true)
})
