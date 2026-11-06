import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../api/client'
import type { Visit, VisitStage } from '../api/types'
import { I18nProvider } from '../i18n'
import type { Screen } from '../lib/stages'
import type { UseVisit } from '../state/useVisit'
import { VisitGate } from './VisitGate'

const useVisit = vi.hoisted(() => vi.fn())
vi.mock('../state/useVisit', () => ({ useVisit }))
vi.mock('../state/session', () => ({ useHealth: () => ({ aiMode: null }) }))

const answer = (partial: Partial<UseVisit>): UseVisit => ({
  visit: null,
  state: 'ready',
  error: null,
  refetch: vi.fn(),
  live: 'live',
  updatedAt: 1,
  ...partial,
})

const visitAt = (stage: VisitStage, confirmed = false) =>
  ({ visit_id: 'V1', stage, confirmed_by_patient: confirmed }) as Visit

function Where() {
  const location = useLocation()
  return (
    <p>
      at {location.pathname}
      {(location.state as { demoReset?: boolean } | null)?.demoReset ? ' reset' : ''}
    </p>
  )
}

function mount(
  screenName: Screen | undefined,
  start: string | { pathname: string; state: unknown } = '/gate',
) {
  render(
    <I18nProvider>
      <MemoryRouter initialEntries={[start]}>
        <Routes>
          <Route
            path="/gate"
            element={
              <VisitGate id="V1" screen={screenName}>
                {() => <textarea aria-label="chat box" />}
              </VisitGate>
            }
          />
          <Route path="*" element={<Where />} />
        </Routes>
      </MemoryRouter>
    </I18nProvider>,
  )
}

beforeEach(() => {
  useVisit.mockReset()
})
afterEach(cleanup)

describe('VisitGate', () => {
  it('shows the screen the visit is on', () => {
    useVisit.mockReturnValue(answer({ visit: visitAt('intake') }))
    mount('chat')
    expect(screen.getByLabelText('chat box')).toBeTruthy()
  })

  it.each<[VisitStage, boolean, string]>([
    ['completed', true, '/visit/V1/complete'],
    ['emergency', false, '/visit/V1/emergency'],
    ['refill', false, '/visit/V1/refill'],
    ['reserved', true, '/visit/V1/reserved'],
    ['expired', true, '/visit/V1/reserved'],
    ['triage', true, '/visit/V1/ticket'],
    ['doctor', true, '/visit/V1/ticket'],
    ['pharmacy', true, '/visit/V1/ticket'],
    ['cancelled', false, '/home'],
    ['intake', true, '/visit/V1/centre'],
  ])('keeps chat off a visit at %s', (stage, confirmed, path) => {
    useVisit.mockReturnValue(answer({ visit: visitAt(stage, confirmed) }))
    mount('chat')
    expect(screen.queryByLabelText('chat box')).toBeNull()
    expect(screen.getByText(`at ${path}`)).toBeTruthy()
  })

  it('lets an expired visit choose a centre again', () => {
    useVisit.mockReturnValue(answer({ visit: visitAt('expired', true) }))
    mount('centre')
    expect(screen.getByLabelText('chat box')).toBeTruthy()
  })

  it('sends a bare visit to its canonical screen', () => {
    useVisit.mockReturnValue(answer({ visit: visitAt('completed', true) }))
    mount(undefined)
    expect(screen.getByText('at /visit/V1/complete')).toBeTruthy()
  })

  it('shows the skeleton in the shell while loading', () => {
    useVisit.mockReturnValue(answer({ state: 'loading' }))
    mount('chat')
    expect(screen.getByTestId('visit-loading')).toBeTruthy()
    expect(screen.getByRole('heading', { level: 1 })).toBeTruthy()
    expect(screen.getByTestId('footer')).toBeTruthy()
    expect(screen.queryByLabelText('chat box')).toBeNull()
  })

  it('shows the error in a block with a retry', () => {
    useVisit.mockReturnValue(
      answer({ state: 'error', error: new ApiError(0, 'network', 'Down') }),
    )
    mount('chat')
    expect(screen.getByRole('alert').textContent).toContain('إعادة المحاولة')
    expect(screen.getByRole('heading', { level: 1 })).toBeTruthy()
  })

  const fromChat = { pathname: '/gate', state: { redFlag: true } }

  it.each<[string, Partial<Parameters<typeof answer>[0]>]>([
    ['loading', { state: 'loading' }],
    ['failed', { state: 'error', error: new ApiError(0, 'network', 'Down') }],
  ])('shows 999 straight after a red flag while the visit has %s', (_name, overrides) => {
    useVisit.mockReturnValue(answer(overrides))
    mount('emergency', fromChat)
    expect(screen.getByTestId('emergency-call').getAttribute('href')).toBe('tel:999')
    expect(screen.getByRole('heading', { level: 1 })).toBeTruthy()
    expect(screen.queryByTestId('visit-loading')).toBeNull()
  })

  it('never shows 999 for a plain link to a visit that has not loaded', () => {
    useVisit.mockReturnValue(answer({ state: 'loading' }))
    mount('emergency')
    expect(screen.queryByTestId('emergency-call')).toBeNull()
    expect(screen.getByTestId('visit-loading')).toBeTruthy()
  })

  it('goes home with the reset notice when the visit is gone', async () => {
    useVisit.mockReturnValue(answer({ state: 'gone' }))
    mount('ticket')
    await waitFor(() => expect(screen.getByText('at /home reset')).toBeTruthy())
  })
})
