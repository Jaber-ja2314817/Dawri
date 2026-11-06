import { act, cleanup, screen, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { Visit } from '../../api/types'
import TicketPage from '../../pages/patient/Ticket'
import { answer, mount, ticketOf, visitOf } from './testVisit'

const useVisit = vi.hoisted(() => vi.fn())
const useSession = vi.hoisted(() => vi.fn())
vi.mock('../../state/useVisit', () => ({ useVisit }))
vi.mock('../../state/session', () => ({ useHealth: () => ({ aiMode: null }), useSession }))

const open = () => mount('/visit/:id/ticket', '/visit/V1/ticket', <TicketPage />)
const show = (visit: Visit, extra = {}) => useVisit.mockReturnValue(answer(visit, extra))

beforeEach(() => {
  localStorage.setItem('dawri.lang', 'en')
  useVisit.mockReset()
  useSession.mockReset()
  useSession.mockReturnValue({ me: null })
})
afterEach(() => {
  cleanup()
  vi.useRealTimers()
})

describe('S10 live ticket', () => {
  it('shows an active ticket with the wait', () => {
    show(visitOf())
    open()
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('Al Wakra Health Centre')
    expect(screen.getByTestId('ticket-number').textContent).toBe('T-014')
    expect(screen.getByTestId('people-ahead').textContent).toBe('3')
    expect(screen.getByTestId('est-wait').textContent).toBe('12 min')
    expect(screen.getByTestId('go-to').textContent).toBe('Triage 1')
    expect(screen.queryByTestId('ticket-called')).toBeNull()
    expect(screen.queryByRole('textbox')).toBeNull()
  })

  it('keeps the number left to right in Arabic', () => {
    localStorage.setItem('dawri.lang', 'ar')
    show(visitOf())
    open()
    const number = screen.getByTestId('ticket-number')
    expect(number.querySelector('bdi')?.getAttribute('dir')).toBe('ltr')
    expect(screen.getByTestId('go-to').textContent).toBe('الفرز 1')
  })

  it('tells a called patient where to go, in a live region', () => {
    show(visitOf({ ticket: ticketOf({ state: 'called', people_ahead: 0, est_wait_min: 0 }) }))
    open()
    const line = screen.getByTestId('ticket-called')
    expect(line.textContent).toBe('Go to Triage 1 now')
    expect(line.parentElement?.getAttribute('aria-live')).toBe('assertive')
  })

  it('says a serving patient is with the team', () => {
    show(visitOf({ ticket: ticketOf({ state: 'serving', people_ahead: 0, est_wait_min: 0 }) }))
    open()
    expect(screen.getByTestId('ticket-serving').textContent).toBe('You are with the team')
    expect(screen.queryByTestId('ticket-called')).toBeNull()
  })

  it.each(['done', 'released', 'expired', 'reserved'] as const)(
    'never leaves a blank screen for a %s ticket',
    (state) => {
      show(visitOf({ ticket: ticketOf({ state }) }))
      open()
      expect(screen.getByTestId('ticket-next').textContent).toBe('Next step coming')
    },
  )

  it('prints 0 people ahead as 0', () => {
    show(visitOf({ ticket: ticketOf({ people_ahead: 0, est_wait_min: 0 }) }))
    open()
    expect(screen.getByTestId('people-ahead').textContent).toBe('0')
    expect(screen.getByTestId('est-wait').textContent).toBe('0 min')
    expect(screen.queryByTestId('dash')).toBeNull()
  })

  it('prints a grey dash for an unknown wait', () => {
    show(visitOf({ ticket: ticketOf({ est_wait_min: null }) }))
    open()
    const dash = within(screen.getByTestId('est-wait')).getByTestId('dash')
    expect(dash.className).toContain('text-muted')
    expect(dash.textContent).toBe('–')
  })

  it('keeps the steps drawn between stages, when there is no ticket', () => {
    show(visitOf({ status: 'in_doctor', stage: 'doctor', ticket: null, go_to: null }))
    open()
    expect(screen.getByTestId('ticket-next').textContent).toBe('Next step coming')
    expect(screen.getByTestId('step-triage')).toBeTruthy()
    expect(screen.getByTestId('step-doctor').getAttribute('aria-current')).toBe('step')
    expect(screen.getByTestId('step-pharmacy').getAttribute('aria-current')).toBeNull()
    expect(screen.queryByTestId('ticket-number')).toBeNull()
  })

  it.each([
    ['triage', 'D-GP-023'],
    ['doctor', 'D-GP-023'],
    ['pharmacy', 'P-031'],
  ] as const)('marks the %s step as current', (stage, number) => {
    show(visitOf({ stage, ticket: ticketOf({ number }) }))
    open()
    expect(screen.getByRole('list', { name: 'Steps of your visit' })).toBeTruthy()
    expect(screen.getByTestId(`step-${stage}`).getAttribute('aria-current')).toBe('step')
    expect(screen.getByTestId('ticket-number').textContent).toBe(number)
  })

  it('moves to the new number with no reload', () => {
    show(visitOf())
    const view = open()
    expect(screen.getByTestId('ticket-number').textContent).toBe('T-014')
    show(
      visitOf({
        status: 'in_doctor',
        stage: 'doctor',
        ticket: ticketOf({ number: 'D-GP-023', counter: 'Room 4', counter_ar: 'غرفة 4' }),
        go_to: { counter: 'Room 4', counter_ar: 'غرفة 4' },
      }),
    )
    view.refresh()
    const number = screen.getByTestId('ticket-number')
    expect(number.textContent).toBe('D-GP-023')
    expect(number.className).toContain('ticket-change')
    expect(screen.getByTestId('go-to').textContent).toBe('Room 4')
    expect(screen.getByTestId('step-doctor').getAttribute('aria-current')).toBe('step')
  })

  it('stays quiet while live', () => {
    vi.useFakeTimers()
    show(visitOf(), { live: 'live' })
    open()
    act(() => {
      vi.advanceTimersByTime(5000)
    })
    expect(screen.queryByTestId('freshness')).toBeNull()
  })

  it('says when updates are slower, and when it last updated', () => {
    vi.useFakeTimers()
    show(visitOf(), { live: 'polling', updatedAt: Date.parse('2026-11-06T07:42:03Z') })
    open()
    expect(screen.queryByTestId('freshness')).toBeNull()
    act(() => {
      vi.advanceTimersByTime(1600)
    })
    expect(screen.getByTestId('freshness').textContent).toBe(
      'Updates may be slower. Last updated 10:42:03',
    )
  })

  it('names a dependent', () => {
    useSession.mockReturnValue({
      me: {
        dependents: [{ id: 'P004', full_name_en: 'Mariam Al-Demo', full_name_ar: 'مريم التجريبية' }],
      },
    })
    show(visitOf({ patient_id: 'P004' }))
    open()
    expect(screen.getByTestId('visit-for').textContent).toBe('Visit for Mariam Al-Demo')
  })

  it('names nobody on the patient own visit', () => {
    useSession.mockReturnValue({ me: { dependents: [{ id: 'P004' }] } })
    show(visitOf())
    open()
    expect(screen.queryByTestId('visit-for')).toBeNull()
  })
})
