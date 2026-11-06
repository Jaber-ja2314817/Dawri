import { act, cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../../api/client'
import type { CentreList, CentreOption } from '../../api/types'
import Centre from '../../pages/patient/Centre'
import { answer, mount, visitOf } from '../ticket/testVisit'

const useVisit = vi.hoisted(() => vi.fn())
const listCentres = vi.hoisted(() => vi.fn())
const reserve = vi.hoisted(() => vi.fn())
const leaflet = vi.hoisted(() => {
  const tileHandlers = new Map<string, () => void>()
  const tiles = {
    on: (name: string, handler: () => void) => tileHandlers.set(name, handler),
    off: (name: string) => tileHandlers.delete(name),
    addTo: () => tiles,
  }
  const markers: { element: HTMLElement; click: () => void }[] = []
  const api = {
    tileHandlers,
    markers,
    tileUrl: '',
    tileOptions: {} as Record<string, unknown>,
    icons: [] as Record<string, unknown>[],
    hasView: false,
    fit: vi.fn(() => {
      api.hasView = true
    }),
    map: () => ({
      attributionControl: { setPrefix: () => {} },
      fitBounds: api.fit,
      invalidateSize: () => {},
      remove: () => {},
    }),
    tileLayer: (url: string, options: Record<string, unknown>) => {
      api.tileUrl = url
      api.tileOptions = options
      return tiles
    },
    divIcon: (options: Record<string, unknown>) => {
      api.icons.push(options)
      return options
    },
    latLngBounds: (points: unknown) => points,
    marker: () => {
      const element = document.createElement('div')
      const pin = { element, click: () => {} }
      markers.push(pin)
      const ready = api.hasView
      const marker = {
        addTo: () => marker,
        on: (_name: string, handler: () => void) => {
          pin.click = handler
          return marker
        },
        // As in Leaflet: a marker on a map with no view has no element yet.
        getElement: () => (ready ? element : undefined),
        setZIndexOffset: () => marker,
        remove: () => {},
      }
      return marker
    },
  }
  return api
})

vi.mock('leaflet', () => ({ default: leaflet }))
vi.mock('../../state/useVisit', () => ({ useVisit }))
vi.mock('../../state/session', () => ({ useHealth: () => ({ aiMode: null }) }))
vi.mock('../../api/endpoints', () => ({ listCentres, reserve }))

const centre = (id: string, partial: Partial<CentreOption> = {}): CentreOption => ({
  id,
  name_en: `${id} Health Centre`,
  name_ar: `مركز ${id}`,
  operator: 'PHCC',
  lat: 25.2,
  lng: 51.5,
  wait_min: 36,
  people_ahead: 9,
  distance_km: null,
  registered: false,
  ...partial,
})

const WAKRA = centre('Wakra', { registered: true, wait_min: 12, people_ahead: 3 })
const AIRPORT = centre('Airport')

const listing = (partial: Partial<CentreList> = {}): CentreList => ({
  service: 'gp',
  effective_service: 'gp',
  service_fallback: false,
  default_centre_id: 'Wakra',
  centres: [WAKRA, AIRPORT],
  suggestion: null,
  ...partial,
})

const SUGGESTION = { centre_id: 'Airport', reason_en: 'Airport is close by.', reason_ar: 'المطار قريب.' }

const open = () => mount('/visit/:id/centre', '/visit/V1/centre', <Centre />)
const panel = () => screen.getByTestId('selected-centre')
const row = (id: string) =>
  screen.getAllByTestId('centre-row').find((item) => item.dataset.centreId === id) as HTMLElement

async function failTiles() {
  await screen.findByTestId('centre-map')
  await waitFor(() => expect(leaflet.tileHandlers.size).toBeGreaterThan(0))
  act(() => {
    for (let count = 0; count < 3; count += 1) leaflet.tileHandlers.get('tileerror')?.()
  })
  // The grace for a good tile runs out, in real time.
  await screen.findByTestId('map-failed', {}, { timeout: 2_000 })
}

function setOnline(value: boolean) {
  Object.defineProperty(navigator, 'onLine', { configurable: true, value })
}

beforeEach(() => {
  localStorage.setItem('dawri.lang', 'en')
  useVisit.mockReset()
  useVisit.mockReturnValue(
    answer(visitOf({ status: 'intake', stage: 'intake', ticket: null, go_to: null })),
  )
  listCentres.mockReset()
  listCentres.mockResolvedValue(listing())
  reserve.mockReset()
  leaflet.tileHandlers.clear()
  leaflet.markers.length = 0
  leaflet.icons.length = 0
  leaflet.fit.mockClear()
  leaflet.hasView = false
  setOnline(true)
})
afterEach(() => {
  cleanup()
  Reflect.deleteProperty(navigator, 'geolocation')
  setOnline(true)
})

describe('S08 data', () => {
  it('asks for the visit service and shows a loading layout under the title', async () => {
    let finish: (value: CentreList) => void = () => {}
    listCentres.mockReturnValue(new Promise((resolve) => (finish = resolve)))
    open()
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('Choose a centre')
    expect(screen.getByTestId('centre-loading')).toBeTruthy()
    expect(listCentres.mock.calls[0][0]).toEqual({ service: 'gp', visit_id: 'V1' })
    await act(async () => finish(listing()))
    expect(screen.queryByTestId('centre-loading')).toBeNull()
  })

  it('preselects the registered centre', async () => {
    open()
    await waitFor(() => expect(within(panel()).getByText('Wakra Health Centre')).toBeTruthy())
    expect(within(panel()).getByText('Your centre')).toBeTruthy()
    expect(panel().textContent).toContain('12 min')
    expect(panel().textContent).toContain('3')
  })

  it('preselects nothing when the registered centre lacks the service', async () => {
    listCentres.mockResolvedValue(
      listing({ default_centre_id: null, centres: [AIRPORT, centre('West', { wait_min: 20 })] }),
    )
    open()
    expect(await screen.findByText('Choose a centre to check in.')).toBeTruthy()
    expect(screen.queryByTestId('check-in-here')).toBeNull()
  })

  it('keeps the title when no centre offers the service', async () => {
    listCentres.mockResolvedValue(listing({ default_centre_id: null, centres: [] }))
    open()
    expect(await screen.findByText('No centre offers this service right now.')).toBeTruthy()
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('Choose a centre')
    expect(screen.getByRole('link', { name: 'Home' }).getAttribute('href')).toBe('/home')
  })

  it('shows an error in the block and retries', async () => {
    listCentres.mockRejectedValueOnce(new ApiError(0, 'network', 'down'))
    open()
    fireEvent.click(await screen.findByRole('button', { name: 'Retry' }))
    await waitFor(() => expect(panel()).toBeTruthy())
    expect(listCentres).toHaveBeenCalledTimes(2)
  })

  it('notes when a GP sees this first', async () => {
    listCentres.mockResolvedValue(listing({ service_fallback: true }))
    open()
    expect(await screen.findByText('A GP sees this first.')).toBeTruthy()
  })
})

describe('S08 views', () => {
  it('opens on the map on a phone, and the list has the registered centre first', async () => {
    open()
    expect(await screen.findByTestId('centre-map')).toBeTruthy()
    expect(screen.getByTestId('centre-map').getAttribute('dir')).toBe('ltr')
    expect(screen.queryAllByTestId('centre-row')).toHaveLength(0)
    fireEvent.click(screen.getByTestId('view-list'))
    const rows = screen.getAllByTestId('centre-row')
    expect(rows[0].dataset.centreId).toBe('Wakra')
    expect(within(rows[0]).getByText('Your centre')).toBeTruthy()
    expect(rows[0].textContent).toContain('12 min')
    expect(rows[1].textContent).toContain('36 min')
  })

  it('draws pins with the wait and no marker images, on the OSM tiles', async () => {
    open()
    await screen.findByTestId('centre-map')
    await waitFor(() => expect(leaflet.icons).toHaveLength(2))
    expect(leaflet.tileUrl).toBe('https://tile.openstreetmap.org/{z}/{x}/{y}.png')
    expect(leaflet.tileOptions.attribution).toContain('OpenStreetMap')
    expect(leaflet.icons[0].html).toContain('>12</bdi> min')
    expect(leaflet.fit).toHaveBeenCalled()
  })

  it('labels each pin for a screen reader and for tests', async () => {
    open()
    await screen.findByTestId('centre-map')
    await waitFor(() => expect(leaflet.markers).toHaveLength(2))
    const { element } = leaflet.markers[0]
    expect(element.dataset.centreId).toBe('Wakra')
    expect(element.getAttribute('aria-label')).toBe('Wakra Health Centre, wait 12 min')
    expect(element.getAttribute('aria-pressed')).toBe('true')
  })

  it('selects a pin from the keyboard', async () => {
    open()
    await screen.findByTestId('centre-map')
    await waitFor(() => expect(leaflet.markers).toHaveLength(2))
    fireEvent.keyDown(leaflet.markers[1].element, { key: 'Enter' })
    expect(within(panel()).getByText('Airport Health Centre')).toBeTruthy()
  })

  it('selects the centre of a tapped pin and marks only that pin', async () => {
    open()
    await screen.findByTestId('centre-map')
    await waitFor(() => expect(leaflet.markers).toHaveLength(2))
    expect(leaflet.markers[0].element.classList.contains('is-selected')).toBe(true)
    act(() => leaflet.markers[1].click())
    expect(within(panel()).getByText('Airport Health Centre')).toBeTruthy()
    expect(leaflet.markers[0].element.classList.contains('is-selected')).toBe(false)
    expect(leaflet.markers[1].element.classList.contains('is-selected')).toBe(true)
  })
})

describe('S08 with no tiles', () => {
  it('falls to the list after tile errors, with one notice and the selection kept', async () => {
    open()
    await screen.findByTestId('centre-map')
    await waitFor(() => expect(leaflet.markers).toHaveLength(2))
    act(() => leaflet.markers[1].click())
    await failTiles()
    expect(screen.queryByTestId('centre-map')).toBeNull()
    expect(screen.getAllByTestId('centre-row')).toHaveLength(2)
    expect(screen.getAllByText('The map could not load, so centres are shown as a list.')).toHaveLength(1)
    expect(screen.queryByTestId('view-map')).toBeNull()
    expect(within(panel()).getByText('Airport Health Centre')).toBeTruthy()
    expect(row('Airport').getAttribute('aria-pressed')).toBe('true')
  })

  it('falls to the list soon when offline', async () => {
    setOnline(false)
    open()
    expect(
      await screen.findByText(
        'The map could not load, so centres are shown as a list.',
        {},
        { timeout: 2_000 },
      ),
    ).toBeTruthy()
    expect(screen.getAllByTestId('centre-row')).toHaveLength(2)
  })

  it('still completes a reservation from the list', async () => {
    reserve.mockResolvedValue({})
    open()
    await failTiles()
    fireEvent.click(row('Airport'))
    fireEvent.click(screen.getByTestId('check-in-here'))
    expect(reserve).toHaveBeenCalledWith('V1', 'Airport')
    await waitFor(() => expect(screen.getByTestId('where').textContent).toBe('/visit/V1/reserved'))
  })
})

describe('S08 suggestion', () => {
  it('does not change the preselected centre, and is labelled a suggestion', async () => {
    listCentres.mockResolvedValue(listing({ suggestion: SUGGESTION }))
    open()
    const card = await screen.findByTestId('centre-suggestion')
    expect(within(card).getByText('Suggestion')).toBeTruthy()
    expect(within(card).getByText('Airport is close by.')).toBeTruthy()
    expect(card.textContent).not.toMatch(/\bAI\b/)
    expect(within(panel()).getByText('Wakra Health Centre')).toBeTruthy()
  })

  it('moves the selection only when the patient chooses it', async () => {
    listCentres.mockResolvedValue(listing({ suggestion: SUGGESTION }))
    open()
    fireEvent.click(await screen.findByTestId('choose-suggested'))
    expect(within(panel()).getByText('Airport Health Centre')).toBeTruthy()
    expect(screen.queryByTestId('choose-suggested')).toBeNull()
    expect(reserve).not.toHaveBeenCalled()
  })

  it('uses the Arabic reason in Arabic', async () => {
    localStorage.setItem('dawri.lang', 'ar')
    listCentres.mockResolvedValue(listing({ suggestion: SUGGESTION }))
    open()
    expect(await screen.findByText('المطار قريب.')).toBeTruthy()
  })
})

describe('S08 location', () => {
  function grant(result: 'ok' | 'denied') {
    const getCurrentPosition = vi.fn((ok: PositionCallback, fail: PositionErrorCallback) => {
      if (result === 'ok') {
        ok({ coords: { latitude: 25.17, longitude: 51.59 } } as GeolocationPosition)
      } else {
        fail({ code: 1 } as GeolocationPositionError)
      }
    })
    Object.defineProperty(navigator, 'geolocation', {
      configurable: true,
      value: { getCurrentPosition },
    })
    return getCurrentPosition
  }

  it('never asks at load, then refetches with the point and shows the distance', async () => {
    const getCurrentPosition = grant('ok')
    open()
    await waitFor(() => expect(panel()).toBeTruthy())
    expect(getCurrentPosition).not.toHaveBeenCalled()
    listCentres.mockResolvedValue(
      listing({ centres: [{ ...WAKRA, distance_km: 2.4 }, AIRPORT] }),
    )
    fireEvent.click(screen.getByTestId('use-location'))
    await waitFor(() => expect(panel().textContent).toContain('2.4 km'))
    expect(listCentres.mock.lastCall?.[0]).toEqual({
      service: 'gp',
      visit_id: 'V1',
      lat: 25.17,
      lng: 51.59,
    })
  })

  it('keeps everything working after a denial', async () => {
    grant('denied')
    open()
    await waitFor(() => expect(panel()).toBeTruthy())
    fireEvent.click(screen.getByTestId('use-location'))
    expect(
      await screen.findByText('We could not read your location. The list still works.'),
    ).toBeTruthy()
    expect(screen.getByTestId('check-in-here')).toBeTruthy()
    expect(listCentres).toHaveBeenCalledTimes(1)
  })
})

describe('S08 reserve', () => {
  it('goes to the reserved screen', async () => {
    reserve.mockResolvedValue({})
    open()
    fireEvent.click(await screen.findByTestId('check-in-here'))
    expect(reserve).toHaveBeenCalledWith('V1', 'Wakra')
    await waitFor(() => expect(screen.getByTestId('where').textContent).toBe('/visit/V1/reserved'))
  })

  it.each(['active_visit', 'emergency_today'])('follows %s to the other visit', async (code) => {
    reserve.mockRejectedValue(new ApiError(409, code, 'No', undefined, { visit_id: 'V7' }))
    open()
    fireEvent.click(await screen.findByTestId('check-in-here'))
    await waitFor(() => expect(screen.getByTestId('where').textContent).toBe('/visit/V7'))
  })

  it('shows any other error in the panel and lets the patient try again', async () => {
    reserve.mockRejectedValue(new ApiError(409, 'service_not_offered', 'Not here'))
    open()
    fireEvent.click(await screen.findByTestId('check-in-here'))
    expect(await within(panel()).findByRole('alert')).toBeTruthy()
    expect((screen.getByTestId('check-in-here') as HTMLButtonElement).disabled).toBe(false)
  })
})
