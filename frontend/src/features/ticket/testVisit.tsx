import { render } from '@testing-library/react'
import type { ReactElement } from 'react'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { vi } from 'vitest'
import type { Ticket, Visit } from '../../api/types'
import { I18nProvider } from '../../i18n'
import type { UseVisit } from '../../state/useVisit'

export const ticketOf = (partial: Partial<Ticket> = {}): Ticket => ({
  id: 'K1',
  visit_id: 'V1',
  number: 'T-014',
  state: 'active',
  centre_id: 'C-WAKRA',
  counter_id: 'C-WAKRA-T1',
  counter: 'Triage 1',
  counter_ar: 'الفرز 1',
  people_ahead: 3,
  est_wait_min: 12,
  expires_at: null,
  ...partial,
})

export const visitOf = (partial: Partial<Visit> = {}): Visit =>
  ({
    visit_id: 'V1',
    patient_id: 'P001',
    booked_by: 'P001',
    status: 'in_triage',
    stage: 'triage',
    service: 'gp',
    centre: { id: 'C-WAKRA', name_en: 'Al Wakra Health Centre', name_ar: 'مركز الوكرة الصحي' },
    ticket: ticketOf(),
    confirmed_by_patient: true,
    medicines: { en: [], ar: [] },
    go_to: { counter: 'Triage 1', counter_ar: 'الفرز 1' },
    rating: null,
    ...partial,
  }) as Visit

export const answer = (visit: Visit, partial: Partial<UseVisit> = {}): UseVisit => ({
  visit,
  state: 'ready',
  error: null,
  refetch: vi.fn(async () => {}),
  live: 'live',
  updatedAt: 1,
  ...partial,
})

function Where() {
  return <p data-testid="where">{useLocation().pathname}</p>
}

/** The page on its real route, with anywhere else it goes shown as text. */
export function mount(path: string, start: string, page: ReactElement) {
  const tree = () => (
    <I18nProvider>
      <MemoryRouter initialEntries={[start]}>
        <Routes>
          <Route path={path} element={page} />
          <Route path="*" element={<Where />} />
        </Routes>
      </MemoryRouter>
    </I18nProvider>
  )
  const view = render(tree())
  return { refresh: () => view.rerender(tree()) }
}
