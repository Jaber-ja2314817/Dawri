import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { createMemoryRouter, RouterProvider } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../../api/client'
import type { EmergencyCard, Visit } from '../../api/types'
import { I18nProvider } from '../../i18n'
import Emergency from '../../pages/patient/Emergency'
import Refill from '../../pages/patient/Refill'
import { ID, visitWith } from './fixtures'

const mocks = vi.hoisted(() => ({
  emergencyOverride: vi.fn(),
  continueRefill: vi.fn(),
  useVisit: vi.fn(),
}))

vi.mock('../../api/endpoints', () => ({
  emergencyOverride: mocks.emergencyOverride,
  continueRefill: mocks.continueRefill,
}))
vi.mock('../../state/useVisit', () => ({ useVisit: mocks.useVisit }))
vi.mock('../../state/session', () => ({ useHealth: () => ({ aiMode: 'simulated' }) }))

const refetch = vi.fn(async () => {})

const hospital = {
  id: 'H-WAKRA',
  name_en: 'Al Wakra Hospital',
  name_ar: 'مستشفى الوكرة',
  lat: 25.1675,
  lng: 51.58742,
  distance_km: 1,
}

const card = (partial: Partial<EmergencyCard> = {}): EmergencyCard => ({
  reply: 'هذا يحتاج رعاية عاجلة. توجه الآن إلى أقرب قسم طوارئ، أو اتصل على 999.',
  self_harm: false,
  nearest_ed: hospital,
  ...partial,
})

const atEmergency = (partial: Partial<EmergencyCard> = {}) =>
  visitWith({ status: 'redirected_emergency', stage: 'emergency', emergency: card(partial) })

const atRefill = (medicine = 'amlodipine 5 mg once daily') =>
  visitWith({ status: 'deflected_refill', stage: 'refill', refill: { medicine } })

function mount(visit: Visit, path: string) {
  mocks.useVisit.mockReturnValue({
    visit,
    state: 'ready',
    error: null,
    refetch,
    live: 'live',
    updatedAt: 1,
  })
  const router = createMemoryRouter(
    [
      { path: '/visit/:id/emergency', element: <Emergency /> },
      { path: '/visit/:id/refill', element: <Refill /> },
      { path: '*', element: <p data-testid="elsewhere">elsewhere</p> },
    ],
    { initialEntries: ['/home', `/visit/${ID}/${path}`], initialIndex: 1 },
  )
  render(
    <I18nProvider>
      <RouterProvider router={router} />
    </I18nProvider>,
  )
  return router
}

beforeEach(() => {
  vi.clearAllMocks()
  window.localStorage.clear()
})
afterEach(cleanup)

describe('S06 emergency', () => {
  it('interrupts with the heading, the reply and a tel link', () => {
    mount(atEmergency(), 'emergency')
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('توجه إلى الطوارئ الآن')
    expect(screen.getByTestId('emergency-reply').getAttribute('dir')).toBe('auto')
    const call = screen.getByTestId('emergency-call')
    expect(call.getAttribute('href')).toBe('tel:999')
    expect(call.textContent).toBe('اتصل على 999')
    expect(screen.getByTestId('footer').textContent).toContain('تجريبي')
    expect(screen.getByTestId('language-toggle')).toBeTruthy()
  })

  it('names the nearest department and links to it on OpenStreetMap', () => {
    mount(atEmergency(), 'emergency')
    const nearest = screen.getByTestId('emergency-nearest')
    expect(nearest.textContent).toContain('مستشفى الوكرة')
    expect(nearest.textContent).toContain('1 كم')
    const href = screen.getByTestId('emergency-map').getAttribute('href') ?? ''
    expect(new URL(href).hostname).toBe('www.openstreetmap.org')
    expect(href).toContain('25.1675')
  })

  it('renames it with the toggle', () => {
    mount(atEmergency(), 'emergency')
    fireEvent.click(screen.getByTestId('language-toggle'))
    expect(screen.getByTestId('emergency-nearest').textContent).toContain('Al Wakra Hospital')
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('Go to Emergency now')
    expect(screen.getByTestId('emergency-call').textContent).toBe('Call 999')
  })

  it('makes a supportive message the largest thing after the heading', () => {
    mount(atEmergency({ self_harm: true, reply: 'أنت لست وحدك.' }), 'emergency')
    expect(screen.getByTestId('emergency-reply').className).toContain('text-xl')
    expect(screen.getByTestId('emergency-reply').textContent).toContain('أنت لست وحدك')
  })

  it('shows the server route on an override, with 999 still there and no ticket', async () => {
    mocks.emergencyOverride.mockResolvedValue({
      status: 'redirected_emergency',
      ticket: null,
      message: 'Speak to a member of staff at the centre, or call 999',
      message_ar: 'تحدث إلى أحد الموظفين في المركز، أو اتصل بـ 999',
    })
    mount(atEmergency(), 'emergency')
    fireEvent.click(screen.getByTestId('emergency-override'))
    const route = await screen.findByTestId('emergency-route')
    expect(route.textContent).toBe('تحدث إلى أحد الموظفين في المركز، أو اتصل بـ 999')
    expect(mocks.emergencyOverride).toHaveBeenCalledOnce()
    expect(mocks.emergencyOverride).toHaveBeenCalledWith(ID)
    expect(screen.getByTestId('emergency-call').getAttribute('href')).toBe('tel:999')
    expect(screen.getByTestId('emergency-home').getAttribute('href')).toBe('/home')
    expect(screen.queryByTestId('emergency-override')).toBeNull()

    fireEvent.click(screen.getByTestId('language-toggle'))
    expect(screen.getByTestId('emergency-route').textContent).toBe(
      'Speak to a member of staff at the centre, or call 999',
    )
  })

  it('shows no chat box, ticket or centre picker in any state', async () => {
    mocks.emergencyOverride.mockResolvedValue({
      status: 'redirected_emergency',
      ticket: null,
      message: 'm',
      message_ar: 'م',
    })
    mount(atEmergency(), 'emergency')
    expect(screen.queryByRole('textbox')).toBeNull()
    fireEvent.click(screen.getByTestId('emergency-override'))
    await screen.findByTestId('emergency-route')
    expect(screen.queryByRole('textbox')).toBeNull()
    expect(document.body.textContent).not.toMatch(/T-\d|D-GP|تذكرة/)
  })

  it('keeps a failed override on the screen with a retry', async () => {
    mocks.emergencyOverride.mockRejectedValue(new ApiError(0, 'network', 'Down'))
    mount(atEmergency(), 'emergency')
    fireEvent.click(screen.getByTestId('emergency-override'))
    expect((await screen.findByRole('alert')).textContent).toContain('إعادة المحاولة')
    expect(screen.getByTestId('emergency-call')).toBeTruthy()
  })

  it('stays put on Back', async () => {
    const router = mount(atEmergency(), 'emergency')
    await act(async () => {
      await router.navigate(-1)
    })
    await waitFor(() => expect(router.state.location.pathname).toBe(`/visit/${ID}/emergency`))
    expect(screen.queryByTestId('elsewhere')).toBeNull()
    expect(screen.getByTestId('emergency-call')).toBeTruthy()
  })
})

describe('S07 refill', () => {
  it('shows the medicine in Arabic on an Arabic screen', () => {
    mount(atRefill(), 'refill')
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe(
      'يمكنك الحصول على دوائك دون زيارة',
    )
    const medicine = screen.getByTestId('refill-medicine')
    expect(medicine.textContent).toBe('أملوديبين 5 ملغ مرة واحدة يومياً')
    expect(medicine.getAttribute('dir')).toBe('auto')
  })

  it('shows the medicine as stored on an English screen', () => {
    window.localStorage.setItem('dawri.lang', 'en')
    mount(atRefill(), 'refill')
    expect(screen.getByTestId('refill-medicine').textContent).toBe('amlodipine 5 mg once daily')
  })

  it('keeps a medicine it has no Arabic for exactly as stored', () => {
    mount(atRefill('lisinopril 10 mg once daily'), 'refill')
    expect(screen.getByTestId('refill-medicine').textContent).toBe('lisinopril 10 mg once daily')
  })

  it('says the refill line is a demo and invents no number', () => {
    mount(atRefill(), 'refill')
    expect(screen.queryByRole('status')).toBeNull()
    fireEvent.click(screen.getByTestId('refill-message'))
    const notice = screen.getByRole('status').textContent ?? ''
    expect(notice).toContain('غير متصل بأي جهة حقيقية')
    expect(document.querySelector('a[href^="tel:"], a[href*="wa.me"]')).toBeNull()
    expect(notice).not.toMatch(/\d/)
  })

  it('continues to the centre on request', async () => {
    mocks.continueRefill.mockResolvedValue({ status: 'intake', service: 'gp', intake: null })
    const router = mount(atRefill(), 'refill')
    fireEvent.click(screen.getByTestId('refill-visit'))
    await waitFor(() => expect(router.state.location.pathname).toBe(`/visit/${ID}/centre`))
    expect(mocks.continueRefill).toHaveBeenCalledWith(ID)
    expect(refetch).toHaveBeenCalled()
  })

  it('shows a failure in place', async () => {
    mocks.continueRefill.mockRejectedValue(new ApiError(0, 'network', 'Down'))
    mount(atRefill(), 'refill')
    fireEvent.click(screen.getByTestId('refill-visit'))
    expect((await screen.findByRole('alert')).textContent).toContain('تعذر الوصول')
  })
})
