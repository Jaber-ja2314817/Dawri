import { cleanup, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { Me, VisitRow, VisitStatus } from '../../api/types'
import { I18nProvider } from '../../i18n'
import Home from './Home'

const rows = vi.hoisted(() => ({ value: [] as VisitRow[] }))

const patient = {
  id: 'P1',
  full_name_en: 'Ravi Demo',
  full_name_ar: 'رافي',
  allergies: [],
  registered_centre: { id: 'C-WAKRA', name_en: 'Al Wakra', name_ar: 'الوكرة' },
}
const me = { patient, dependents: [] } as unknown as Me

vi.mock('../../state/useVisitList', () => ({
  useVisitList: () => ({ rows: rows.value, state: 'ready', error: null, retry: vi.fn() }),
}))
vi.mock('../../state/session', () => ({
  useHealth: () => ({ aiMode: null }),
  useSession: () => ({ me, meState: 'ready', meError: null, patient, reloadMe: vi.fn(), signOut: vi.fn() }),
}))

const NOW = new Date('2026-11-06T09:00:00.000Z')

const row = (status: VisitStatus, created_at = NOW.toISOString()): VisitRow => ({
  visit_id: 'V1',
  patient_id: 'P1',
  status,
  stage: 'emergency',
  service: null,
  centre_id: null,
  centre: null,
  created_at,
  completed_at: null,
  active: false,
})

const mount = () =>
  render(
    <I18nProvider>
      <MemoryRouter>
        <Home />
      </MemoryRouter>
    </I18nProvider>,
  )

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date'] })
  vi.setSystemTime(NOW)
  localStorage.setItem('dawri.lang', 'en')
})
afterEach(() => {
  cleanup()
  localStorage.clear()
  vi.useRealTimers()
})

describe('S03 and an emergency', () => {
  it("leads today's emergency to its visit, which goes on to S06", () => {
    rows.value = [row('redirected_emergency')]
    mount()
    const card = screen.getByTestId('open-visit')
    expect(card.getAttribute('href')).toBe('/visit/V1')
    expect(card.textContent).toContain('Sent to emergency')
  })

  it('counts the day in Doha: 22:00 UTC yesterday is already today there', () => {
    rows.value = [row('redirected_emergency', '2026-11-05T22:00:00.000Z')]
    mount()
    expect(screen.queryByTestId('open-visit')).not.toBeNull()
  })

  it('does not keep an older emergency open for ever', () => {
    rows.value = [row('redirected_emergency', '2026-11-04T09:00:00.000Z')]
    mount()
    expect(screen.queryByTestId('open-visit')).toBeNull()
  })

  it('still leaves finished visits off the list', () => {
    rows.value = [row('completed'), row('deflected_refill'), row('cancelled')]
    mount()
    expect(screen.queryByTestId('open-visit')).toBeNull()
  })
})
