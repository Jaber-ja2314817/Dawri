import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { useEffect, useRef } from 'react'
import type { CentreOption } from '../../api/types'
import { useI18n, type Dir } from '../../i18n'
import { centreName } from '../../lib/format'
import './map.css'
import { watchTiles, type MapFailure } from './tiles'

const TILES = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'
const ATTRIBUTION =
  '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
const MAX_ZOOM = 19
const FIT = { padding: [48, 48] as [number, number], maxZoom: 13, animate: false }
const PIN_SIZE: [number, number] = [64, 44]
const PIN_ANCHOR: [number, number] = [32, 22]

interface CentreMapProps {
  centres: CentreOption[]
  selectedId: string | null
  onSelect: (id: string) => void
  onFail: (reason: MapFailure) => void
}

function pinHtml(wait: number | null, unit: string, dir: Dir): string {
  const value = wait === null ? '–' : `<bdi dir="ltr">${Number(wait)}</bdi> ${unit}`
  return `<span class="dawri-pin-badge" dir="${dir}">${value}</span>`
}

export default function CentreMap({ centres, selectedId, onSelect, onFail }: CentreMapProps) {
  const { t, lang, dir } = useI18n()
  const holder = useRef<HTMLDivElement>(null)
  const map = useRef<L.Map | null>(null)
  const pins = useRef(new Map<string, L.Marker>())
  const handlers = useRef({ onSelect, onFail })

  useEffect(() => {
    handlers.current = { onSelect, onFail }
  })

  useEffect(() => {
    const created = L.map(holder.current as HTMLDivElement, { zoomControl: false })
    created.attributionControl.setPrefix(false)
    const tiles = L.tileLayer(TILES, { attribution: ATTRIBUTION, maxZoom: MAX_ZOOM })
    // Before anything sets the view: that is when the first tiles are requested.
    const stopWatching = watchTiles(tiles, (reason) => handlers.current.onFail(reason))
    tiles.addTo(created)
    map.current = created

    const resize =
      typeof ResizeObserver === 'undefined'
        ? null
        : new ResizeObserver(() => created.invalidateSize())
    resize?.observe(holder.current as HTMLDivElement)

    return () => {
      stopWatching()
      resize?.disconnect()
      map.current = null
      created.remove()
    }
  }, [])

  useEffect(() => {
    const current = map.current
    if (current === null) return
    const placed = new Map<string, L.Marker>()

    // First: a marker added to a map with no view has no element yet.
    current.fitBounds(
      L.latLngBounds(centres.map((centre): [number, number] => [centre.lat, centre.lng])),
      FIT,
    )

    for (const centre of centres) {
      const name = centreName(centre, lang)
      const marker = L.marker([centre.lat, centre.lng], {
        title: name,
        icon: L.divIcon({
          className: 'dawri-pin',
          html: pinHtml(centre.wait_min, t('centre.unitMin'), dir),
          iconSize: PIN_SIZE,
          iconAnchor: PIN_ANCHOR,
        }),
      }).addTo(current)
      const choose = () => handlers.current.onSelect(centre.id)
      marker.on('click', choose)

      const element = marker.getElement()
      element?.setAttribute('data-testid', 'centre-pin')
      element?.setAttribute('data-centre-id', centre.id)
      element?.setAttribute(
        'aria-label',
        t('centre.pinLabel', {
          name,
          wait: centre.wait_min ?? '-',
          unit: t('centre.unitMin'),
        }),
      )
      element?.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault()
          choose()
        }
      })
      placed.set(centre.id, marker)
    }

    pins.current = placed
    return () => {
      placed.forEach((marker) => marker.remove())
      pins.current = new Map()
    }
  }, [centres, lang, dir, t])

  // A class on the same element, so a pin reached by keyboard keeps its focus.
  useEffect(() => {
    pins.current.forEach((marker, id) => {
      const chosen = id === selectedId
      const element = marker.getElement()
      element?.classList.toggle('is-selected', chosen)
      element?.setAttribute('aria-pressed', String(chosen))
      marker.setZIndexOffset(chosen ? 1000 : 0)
    })
  }, [centres, lang, dir, t, selectedId])

  return (
    <div
      ref={holder}
      dir="ltr"
      role="group"
      aria-label={t('centre.mapLabel')}
      data-testid="centre-map"
      className="dawri-map size-full"
    />
  )
}
