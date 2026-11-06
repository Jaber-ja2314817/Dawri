import { act, cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../../api/client'
import Reserved from '../../pages/patient/Reserved'
import { answer, mount, ticketOf, visitOf } from './testVisit'

const useVisit = vi.hoisted(() => vi.fn())
const arrive = vi.hoisted(() => vi.fn())
vi.mock('../../state/useVisit', () => ({ useVisit }))
vi.mock('../../state/session', () => ({ useHealth: () => ({ aiMode: null }) }))
vi.mock('../../api/endpoints', () => ({ arrive }))

const inFortyMinutes = () => new Date(Date.now() + 40 * 60_000).toISOString()

const reservedVisit = (expiresAt: string | null = inFortyMinutes()) =>
  visitOf({
    status: 'reserved',
    stage: 'reserved',
    go_to: null,
    ticket: ticketOf({
      number: null,
      state: 'reserved',
      people_ahead: null,
      est_wait_min: null,
      expires_at: expiresAt,
    }),
  })

const open = () => mount('/visit/:id/reserved', '/visit/V1/reserved', <Reserved />)

function grantLocation(result: 'ok' | 'denied') {
  const getCurrentPosition = vi.fn(
    (ok: PositionCallback, fail: PositionErrorCallback, _options?: PositionOptions) => {
      if (result === 'ok') {
        ok({ coords: { latitude: 25.17, longitude: 51.59 } } as GeolocationPosition)
      } else {
        fail({ code: 1 } as GeolocationPositionError)
      }
    },
  )
  Object.defineProperty(navigator, 'geolocation', {
    configurable: true,
    value: { getCurrentPosition, watchPosition: vi.fn() },
  })
  return getCurrentPosition
}

beforeEach(() => {
  localStorage.setItem('dawri.lang', 'en')
  useVisit.mockReset()
  arrive.mockReset()
})
afterEach(() => {
  cleanup()
  vi.useRealTimers()
})

describe('S09 reserved', () => {
  it('shows the check-in text and the countdown, with no number or place', () => {
    useVisit.mockReturnValue(answer(reservedVisit()))
    open()
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('Al Wakra Health Centre')
    expect(screen.getByText('Check-in valid for 45 minutes')).toBeTruthy()
    expect(screen.getByText('Activates when you arrive')).toBeTruthy()
    expect(screen.getByTestId('countdown').textContent).toBe('40:00')
    const page = document.body.textContent ?? ''
    expect(page).not.toMatch(/T-\d/)
    expect(page).not.toContain('People ahead')
    expect(page.toLowerCase()).not.toContain('place')
    expect(screen.queryByTestId('ticket-number')).toBeNull()
  })

  it('reads the exact Arabic text', () => {
    localStorage.setItem('dawri.lang', 'ar')
    useVisit.mockReturnValue(answer(reservedVisit()))
    open()
    expect(screen.getByText('تسجيل الوصول صالح لمدة 45 دقيقة')).toBeTruthy()
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('مركز الوكرة الصحي')
  })

  it('keeps the countdown left to right', () => {
    localStorage.setItem('dawri.lang', 'ar')
    useVisit.mockReturnValue(answer(reservedVisit()))
    open()
    expect(screen.getByTestId('countdown').querySelector('bdi')?.getAttribute('dir')).toBe('ltr')
  })

  it('ticks down once a second', () => {
    vi.useFakeTimers()
    useVisit.mockReturnValue(answer(reservedVisit(new Date(Date.now() + 10_000).toISOString())))
    open()
    expect(screen.getByTestId('countdown').textContent).toBe('00:10')
    act(() => {
      vi.advanceTimersByTime(3000)
    })
    expect(screen.getByTestId('countdown').textContent).toBe('00:07')
  })

  it('asks the server again at 00:00, which is what runs the expiry', () => {
    vi.useFakeTimers()
    const reply = answer(reservedVisit(new Date(Date.now() + 2_000).toISOString()))
    useVisit.mockReturnValue(reply)
    open()
    expect(reply.refetch).not.toHaveBeenCalled()
    act(() => {
      vi.advanceTimersByTime(2000)
    })
    expect(screen.getByTestId('countdown').textContent).toBe('00:00')
    expect(reply.refetch).toHaveBeenCalledTimes(1)
  })

  it('goes to the ticket after I am here', async () => {
    arrive.mockResolvedValue({ ticket: ticketOf(), go_to: null })
    useVisit.mockReturnValue(answer(reservedVisit()))
    open()
    fireEvent.click(screen.getByTestId('im-here'))
    expect(arrive).toHaveBeenCalledWith('V1', { button: true })
    await waitFor(() => expect(screen.getByTestId('where').textContent).toBe('/visit/V1/ticket'))
  })

  it('sends one location reading, never watching', async () => {
    const getCurrentPosition = grantLocation('ok')
    arrive.mockResolvedValue({ ticket: ticketOf(), go_to: null })
    useVisit.mockReturnValue(answer(reservedVisit()))
    open()
    expect(getCurrentPosition).not.toHaveBeenCalled()
    fireEvent.click(screen.getByTestId('check-location'))
    await waitFor(() => expect(arrive).toHaveBeenCalledWith('V1', { lat: 25.17, lng: 51.59 }))
    expect(getCurrentPosition).toHaveBeenCalledTimes(1)
    expect(getCurrentPosition.mock.calls[0][2]).toEqual({ timeout: 10_000 })
    expect(navigator.geolocation.watchPosition).not.toHaveBeenCalled()
  })

  it('gives the distance and the limit when too far', async () => {
    grantLocation('ok')
    arrive.mockRejectedValue(new ApiError(409, 'too_far', 'Not yet', undefined, { distance_m: 212 }))
    useVisit.mockReturnValue(answer(reservedVisit()))
    open()
    fireEvent.click(screen.getByTestId('check-location'))
    expect(
      (await screen.findByText(/You are/)).textContent,
    ).toBe('You are 212 m from the centre, and check-in works within 150 m.')
  })

  it('points to I am here when location is refused, and that still works', async () => {
    grantLocation('denied')
    arrive.mockResolvedValue({ ticket: ticketOf(), go_to: null })
    useVisit.mockReturnValue(answer(reservedVisit()))
    open()
    fireEvent.click(screen.getByTestId('check-location'))
    expect(await screen.findByText(/use I'm here instead/)).toBeTruthy()
    expect(arrive).not.toHaveBeenCalled()
    fireEvent.click(screen.getByTestId('im-here'))
    await waitFor(() => expect(arrive).toHaveBeenCalledWith('V1', { button: true }))
  })

  it('refetches on ticket_expired', async () => {
    arrive.mockRejectedValue(new ApiError(410, 'ticket_expired', 'Expired'))
    const reply = answer(reservedVisit())
    useVisit.mockReturnValue(reply)
    open()
    fireEvent.click(screen.getByTestId('im-here'))
    await waitFor(() => expect(reply.refetch).toHaveBeenCalled())
  })

  it('moves to the emergency visit on emergency_today', async () => {
    arrive.mockRejectedValue(
      new ApiError(409, 'emergency_today', 'Staff', undefined, { visit_id: 'V9' }),
    )
    useVisit.mockReturnValue(answer(reservedVisit()))
    open()
    fireEvent.click(screen.getByTestId('im-here'))
    await waitFor(() => expect(screen.getByTestId('where').textContent).toBe('/visit/V9'))
  })

  it('offers the centre again once expired', () => {
    useVisit.mockReturnValue(answer(visitOf({ status: 'expired', stage: 'expired', ticket: null })))
    open()
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('Check-in expired')
    expect(screen.getByTestId('choose-again').getAttribute('href')).toBe('/visit/V1/centre')
    expect(screen.queryByTestId('countdown')).toBeNull()
  })
})
