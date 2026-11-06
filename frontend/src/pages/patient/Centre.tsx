import { lazy, Suspense, useCallback, useEffect, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { ApiError, errorText } from '../../api/client'
import { listCentres, reserve } from '../../api/endpoints'
import type { CentreList as CentreData, CentreOption } from '../../api/types'
import { ListIcon, MapIcon, PinIcon } from '../../components/icons'
import { PatientShell } from '../../components/PatientShell'
import {
  Button,
  buttonClass,
  Card,
  ErrorBlock,
  Notice,
  Pill,
  Skeleton,
} from '../../components/ui'
import { VisitGate } from '../../components/VisitGate'
import { CentreList } from '../../features/map/CentreList'
import { currentPosition, type Point } from '../../features/map/location'
import { MapBoundary } from '../../features/map/MapBoundary'
import type { MapFailure } from '../../features/map/tiles'
import { useWide } from '../../features/map/useWide'
import { Count, Kilometres, Minutes } from '../../features/ticket/Values'
import { useI18n } from '../../i18n'
import { cx } from '../../lib/cx'
import { centreName } from '../../lib/format'

// Leaflet stays out of the main bundle, and the list never waits for it.
const CentreMap = lazy(() => import('../../features/map/CentreMap'))

type View = 'map' | 'list'

function useCentres(visitId: string, service: string) {
  const [list, setList] = useState<CentreData | null>(null)
  const [error, setError] = useState<unknown>(null)
  const [point, setPoint] = useState<Point | null>(null)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    const controller = new AbortController()
    setError(null)
    listCentres({ service, visit_id: visitId, ...point }, { signal: controller.signal })
      .then(setList)
      .catch((cause: unknown) => {
        if (!controller.signal.aborted) setError(cause)
      })
    return () => controller.abort()
  }, [visitId, service, point, attempt])

  const retry = useCallback(() => setAttempt((count) => count + 1), [])
  return { list, error, retry, setPoint }
}

function ViewToggle({ view, onChange }: { view: View; onChange: (view: View) => void }) {
  const { t } = useI18n()
  const options = [
    { value: 'map', label: t('centre.viewMap'), Icon: MapIcon },
    { value: 'list', label: t('centre.viewList'), Icon: ListIcon },
  ] as const
  return (
    <div
      role="group"
      aria-label={t('centre.view')}
      className="flex overflow-hidden rounded-control border border-control bg-surface"
    >
      {options.map(({ value, label, Icon }) => (
        <button
          key={value}
          type="button"
          aria-pressed={view === value}
          data-testid={`view-${value}`}
          onClick={() => onChange(value)}
          className={cx(
            'flex min-h-11 cursor-pointer items-center gap-2 px-3 text-sm transition-colors',
            view === value ? 'bg-raised font-medium' : 'text-muted hover:bg-ground',
          )}
        >
          <Icon />
          {label}
        </button>
      ))}
    </div>
  )
}

function Figure({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <dt className="text-sm text-muted">{label}</dt>
      <dd className="text-base font-medium">{children}</dd>
    </div>
  )
}

interface SelectedPanelProps {
  centre: CentreOption | null
  busy: boolean
  failure: string | null
  onCheckIn: () => void
}

function SelectedPanel({ centre, busy, failure, onCheckIn }: SelectedPanelProps) {
  const { t, lang } = useI18n()
  if (centre === null) {
    return (
      <Card data-testid="selected-centre">
        <p className="text-sm text-muted">{t('centre.choosePrompt')}</p>
      </Card>
    )
  }
  return (
    <Card data-testid="selected-centre" className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center gap-2">
        <h2 className="text-base font-semibold">{centreName(centre, lang)}</h2>
        {centre.registered && <Pill>{t('centre.yourCentre')}</Pill>}
      </div>
      <dl className="grid grid-cols-3 gap-3">
        <Figure label={t('centre.wait')}>
          <Minutes value={centre.wait_min} />
        </Figure>
        <Figure label={t('centre.peopleAhead')}>
          <Count value={centre.people_ahead} />
        </Figure>
        {centre.distance_km !== null && (
          <Figure label={t('centre.distance')}>
            <Kilometres value={centre.distance_km} />
          </Figure>
        )}
      </dl>
      {failure !== null && <ErrorBlock message={failure} />}
      <Button className="w-full" loading={busy} data-testid="check-in-here" onClick={onCheckIn}>
        {t('centre.checkIn')}
      </Button>
    </Card>
  )
}

function Suggestion({
  reason,
  showAction,
  onChoose,
}: {
  reason: string
  showAction: boolean
  onChoose: () => void
}) {
  const { t } = useI18n()
  return (
    <Card data-testid="centre-suggestion" className="flex flex-col items-start gap-2">
      <Pill>{t('centre.suggestion')}</Pill>
      <p dir="auto" className="text-sm">
        {reason}
      </p>
      {showAction && (
        <Button variant="secondary" data-testid="choose-suggested" onClick={onChoose}>
          {t('centre.chooseSuggested')}
        </Button>
      )}
    </Card>
  )
}

function MapBlock({
  centres,
  selectedId,
  onSelect,
  onFail,
}: {
  centres: CentreOption[]
  selectedId: string | null
  onSelect: (id: string) => void
  onFail: (reason: MapFailure) => void
}) {
  return (
    <div className="isolate h-72 overflow-hidden rounded-panel border border-border md:h-full md:min-h-96">
      <MapBoundary onFail={onFail}>
        <Suspense fallback={<Skeleton height="100%" className="rounded-none" />}>
          <CentreMap
            centres={centres}
            selectedId={selectedId}
            onSelect={onSelect}
            onFail={onFail}
          />
        </Suspense>
      </MapBoundary>
    </div>
  )
}

function LoadingLayout() {
  return (
    <div data-testid="centre-loading" aria-busy="true" className="flex flex-col gap-3">
      <Skeleton height={44} width={180} />
      <div className="grid gap-3 md:grid-cols-[minmax(0,5fr)_minmax(0,6fr)]">
        <Skeleton height={288} className="rounded-panel" />
        <Skeleton height={160} className="rounded-panel md:h-72" />
      </div>
    </div>
  )
}

function CentreScreen({ id, service }: { id: string; service: string }) {
  const { t, lang } = useI18n()
  const navigate = useNavigate()
  const wide = useWide()
  const { list, error, retry, setPoint } = useCentres(id, service)
  const [picked, setPicked] = useState<string | null>(null)
  const [view, setView] = useState<View>('map')
  const [mapFailure, setMapFailure] = useState<MapFailure | null>(null)
  const [locating, setLocating] = useState(false)
  const [locationFailed, setLocationFailed] = useState(false)
  const [reserving, setReserving] = useState(false)
  const [failure, setFailure] = useState<string | null>(null)

  const onMapFail = useCallback((reason: MapFailure) => setMapFailure(reason), [])
  const mapFailed = mapFailure !== null

  const pick = useCallback((centreId: string) => {
    setPicked(centreId)
    setFailure(null)
  }, [])

  const locate = async () => {
    setLocating(true)
    setLocationFailed(false)
    try {
      setPoint(await currentPosition())
    } catch {
      setLocationFailed(true)
    } finally {
      setLocating(false)
    }
  }

  const checkIn = async (centreId: string) => {
    setReserving(true)
    setFailure(null)
    try {
      await reserve(id, centreId)
      navigate(`/visit/${id}/reserved`, { replace: true })
    } catch (cause) {
      const elsewhere = cause instanceof ApiError ? cause.extra.visit_id : undefined
      if (
        cause instanceof ApiError &&
        (cause.code === 'active_visit' || cause.code === 'emergency_today') &&
        typeof elsewhere === 'string'
      ) {
        navigate(`/visit/${elsewhere}`, { replace: true })
        return
      }
      setFailure(errorText(cause, t, lang))
      setReserving(false)
    }
  }

  const shell = (children: React.ReactNode) => (
    <PatientShell wide title={t('screen.centre')} back="/home">
      {children}
    </PatientShell>
  )

  if (list === null) {
    return shell(
      error !== null ? (
        <ErrorBlock message={errorText(error, t, lang)} onRetry={retry} />
      ) : (
        <LoadingLayout />
      ),
    )
  }

  if (list.centres.length === 0) {
    return shell(
      <>
        <p className="text-base">{t('centre.empty')}</p>
        <Link to="/home" className={buttonClass('secondary', 'self-start')}>
          {t('centre.home')}
        </Link>
      </>,
    )
  }

  const selectedId = picked ?? list.default_centre_id
  const selected = list.centres.find((centre) => centre.id === selectedId) ?? null
  const showMap = !mapFailed
  const showList = mapFailed || wide || view === 'list'
  const mapBlock = showMap && (
    <MapBlock
      centres={list.centres}
      selectedId={selectedId}
      onSelect={pick}
      onFail={onMapFail}
    />
  )

  return shell(
    <>
      {list.service_fallback && <p className="text-sm text-muted">{t('centre.gpFirst')}</p>}
      {mapFailure !== null && (
        <Notice data-testid="map-failed" data-reason={mapFailure}>
          {t('centre.mapFailed')}
        </Notice>
      )}
      {error !== null && <ErrorBlock message={errorText(error, t, lang)} onRetry={retry} />}

      <div className="flex flex-wrap items-center justify-between gap-2">
        {!mapFailed && !wide && <ViewToggle view={view} onChange={setView} />}
        <Button
          variant="quiet"
          className={cx('text-sm', (mapFailed || wide) && '-ms-4')}
          loading={locating}
          data-testid="use-location"
          onClick={() => void locate()}
        >
          {!locating && <PinIcon />}
          {t('centre.useLocation')}
        </Button>
      </div>
      {locationFailed && <p className="text-sm text-muted">{t('centre.locationFailed')}</p>}

      <div
        className={cx(
          'grid gap-3',
          wide && !mapFailed && 'grid-cols-[minmax(0,5fr)_minmax(0,6fr)]',
        )}
      >
        <div className="flex min-w-0 flex-col gap-3">
          {showList ? (
            <CentreList centres={list.centres} selectedId={selectedId} onSelect={pick} />
          ) : (
            mapBlock
          )}
          <SelectedPanel
            centre={selected}
            busy={reserving}
            failure={failure}
            onCheckIn={() => selected && void checkIn(selected.id)}
          />
          {list.suggestion !== null && (
            <Suggestion
              reason={lang === 'ar' ? list.suggestion.reason_ar : list.suggestion.reason_en}
              showAction={list.suggestion.centre_id !== selectedId}
              onChoose={() => list.suggestion && pick(list.suggestion.centre_id)}
            />
          )}
        </div>
        {wide && mapBlock}
      </div>
    </>,
  )
}

export default function Centre() {
  const { id = '' } = useParams()
  return (
    <VisitGate id={id} screen="centre">
      {(visit) => <CentreScreen id={id} service={visit.service ?? 'gp'} />}
    </VisitGate>
  )
}
