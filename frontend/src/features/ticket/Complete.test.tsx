import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../../api/client'
import type { Visit } from '../../api/types'
import Complete from '../../pages/patient/Complete'
import { answer, mount, ticketOf, visitOf } from './testVisit'

const useVisit = vi.hoisted(() => vi.fn())
const rateVisit = vi.hoisted(() => vi.fn())
vi.mock('../../state/useVisit', () => ({ useVisit }))
vi.mock('../../state/session', () => ({ useHealth: () => ({ aiMode: null }) }))
vi.mock('../../api/endpoints', () => ({ rateVisit }))

const MEDICINES = {
  en: [
    { drug: 'paracetamol', name: 'Paracetamol', line: 'Take 1 tablet after food, 3 times a day.' },
  ],
  ar: [{ drug: 'paracetamol', name: 'باراسيتامول', line: 'تناول قرصاً واحداً بعد الطعام.' }],
}

const completed = (partial: Partial<Visit> = {}) =>
  visitOf({
    status: 'completed',
    stage: 'completed',
    ticket: ticketOf({ number: 'P-031', state: 'done' }),
    go_to: null,
    medicines: MEDICINES,
    ...partial,
  })

const open = () => mount('/visit/:id/complete', '/visit/V1/complete', <Complete />)

beforeEach(() => {
  localStorage.setItem('dawri.lang', 'en')
  useVisit.mockReset()
  rateVisit.mockReset()
})
afterEach(cleanup)

describe('S11 visit complete', () => {
  it('shows an SVG check and no chat box', () => {
    useVisit.mockReturnValue(answer(completed()))
    open()
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('Visit complete')
    expect(screen.getByTestId('complete-check').tagName.toLowerCase()).toBe('svg')
    expect(screen.queryByRole('textbox')).toBeNull()
  })

  it('renders medicines in English, exactly as the server wrote them', () => {
    useVisit.mockReturnValue(answer(completed()))
    open()
    expect(screen.getByText('Paracetamol')).toBeTruthy()
    expect(screen.getByText('Take 1 tablet after food, 3 times a day.')).toBeTruthy()
    expect(screen.queryByText('باراسيتامول')).toBeNull()
  })

  it('renders medicines in Arabic with the Arabic title', () => {
    localStorage.setItem('dawri.lang', 'ar')
    useVisit.mockReturnValue(answer(completed()))
    open()
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('اكتملت الزيارة')
    expect(screen.getByText('باراسيتامول').getAttribute('dir')).toBe('auto')
    expect(screen.getByText('تناول قرصاً واحداً بعد الطعام.')).toBeTruthy()
    expect(screen.queryByText('Paracetamol')).toBeNull()
  })

  it('says so when nothing was prescribed', () => {
    useVisit.mockReturnValue(answer(completed({ medicines: { en: [], ar: [] } })))
    open()
    expect(screen.getByTestId('no-medicines').textContent).toBe('No medicines were prescribed')
    expect(screen.queryByTestId('medicine')).toBeNull()
  })

  it('carries the fixed follow-up line', () => {
    useVisit.mockReturnValue(answer(completed()))
    open()
    expect(
      screen.getByText(/Return to your centre/).textContent,
    ).toBe('Return to your centre if your symptoms get worse, and call 999 in an emergency.')
  })

  it('links back to Home and History and shows the last ticket quietly', () => {
    useVisit.mockReturnValue(answer(completed()))
    open()
    expect(screen.getByRole('link', { name: 'Home' }).getAttribute('href')).toBe('/home')
    expect(screen.getByRole('link', { name: 'History' }).getAttribute('href')).toBe('/history')
    expect(screen.getByTestId('final-ticket').textContent).toBe('Final ticket P-031')
  })

  it('offers five rating controls and sends the choice', async () => {
    rateVisit.mockResolvedValue({ rating: 4 })
    const reply = answer(completed())
    useVisit.mockReturnValue(reply)
    open()
    const stars = screen.getAllByTestId('rate-star')
    expect(stars).toHaveLength(5)
    for (const star of stars) expect(star.className).toContain('size-11')
    fireEvent.click(stars[3])
    expect(rateVisit).toHaveBeenCalledWith('V1', 4)
    expect((await screen.findByTestId('rating-read-only')).textContent).toContain('4/5')
    expect(reply.refetch).toHaveBeenCalled()
  })

  it('shows a rating already given as read-only, with thanks', () => {
    useVisit.mockReturnValue(answer(completed({ rating: 5 })))
    open()
    expect(screen.queryAllByTestId('rate-star')).toHaveLength(0)
    expect(screen.getByTestId('rating-read-only').textContent).toContain(
      'Thank you for rating your visit',
    )
  })

  it('refetches on already_rated', async () => {
    rateVisit.mockRejectedValue(new ApiError(409, 'already_rated', 'Rated'))
    const reply = answer(completed())
    useVisit.mockReturnValue(reply)
    open()
    fireEvent.click(screen.getAllByTestId('rate-star')[0])
    await waitFor(() => expect(reply.refetch).toHaveBeenCalled())
    expect(screen.queryByRole('alert')).toBeNull()
  })
})
