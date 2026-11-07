import { useEffect, useState } from 'react'
import { Link, useBlocker, useParams } from 'react-router-dom'
import { ApiError, errorText } from '../../api/client'
import { emergencyOverride } from '../../api/endpoints'
import type { NearestEd, OverrideResponse, Visit } from '../../api/types'
import { EmergencyCall, EmergencyTitle } from '../../components/EmergencyCall'
import { PinIcon } from '../../components/icons'
import { PatientShell } from '../../components/PatientShell'
import { Button, buttonClass, Card, ErrorBlock } from '../../components/ui'
import { VisitGate } from '../../components/VisitGate'
import { useI18n } from '../../i18n'
import { cx } from '../../lib/cx'
import { centreName } from '../../lib/format'

const mapUrl = ({ lat, lng }: NearestEd) =>
  `https://www.openstreetmap.org/?mlat=${lat}&mlon=${lng}#map=16/${lat}/${lng}`

function NearestDepartment({ place }: { place: NearestEd }) {
  const { t, lang } = useI18n()
  return (
    <Card data-testid="emergency-nearest" className="flex flex-col gap-1">
      <h2 className="text-sm text-muted">{t('emergency.nearest')}</h2>
      <p className="text-base font-semibold">{centreName(place, lang)}</p>
      <p className="text-sm">{t('emergency.distance', { km: place.distance_km })}</p>
      <a
        data-testid="emergency-map"
        href={mapUrl(place)}
        target="_blank"
        rel="noreferrer"
        className="inline-flex min-h-11 items-center gap-2 self-start text-base font-medium underline underline-offset-4"
      >
        <PinIcon />
        {t('emergency.map')}
      </a>
    </Card>
  )
}

function EmergencyScreen({ visit, refetch }: { visit: Visit; refetch: () => Promise<void> }) {
  const { t, lang } = useI18n()
  const card = visit.emergency
  const reply = (lang === 'ar' ? card?.reply_ar : card?.reply_en) ?? card?.reply
  const [route, setRoute] = useState<OverrideResponse | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<unknown>(null)

  // Back has nowhere safe to go: the chat is closed and this visit can take no ticket.
  const blocker = useBlocker(({ historyAction }) => historyAction === 'POP')
  useEffect(() => {
    if (blocker.state === 'blocked') blocker.reset()
  }, [blocker])

  const override = async () => {
    setBusy(true)
    setError(null)
    try {
      setRoute(await emergencyOverride(visit.visit_id))
    } catch (cause) {
      if (cause instanceof ApiError && cause.code === 'not_emergency') await refetch()
      setError(cause)
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <EmergencyTitle />
      <p
        dir="auto"
        data-testid="emergency-reply"
        className={cx(
          'text-start whitespace-pre-line',
          card?.self_harm ? 'text-xl font-medium' : 'text-base',
        )}
      >
        {reply ?? t('emergency.title')}
      </p>
      <EmergencyCall />
      {card?.nearest_ed && <NearestDepartment place={card.nearest_ed} />}
      {error !== null && (
        <ErrorBlock message={errorText(error, t, lang)} onRetry={() => void override()} />
      )}
      {route === null ? (
        <Button
          data-testid="emergency-override"
          variant="quiet"
          className="w-full"
          loading={busy}
          onClick={() => void override()}
        >
          {t('emergency.override')}
        </Button>
      ) : (
        <div className="flex flex-col gap-1">
          <p role="status" dir="auto" data-testid="emergency-route" className="text-start text-base font-medium">
            {lang === 'ar' ? route.message_ar : route.message}
          </p>
          <Link
            to="/home"
            data-testid="emergency-home"
            className={buttonClass('quiet', '-ms-4 self-start underline')}
          >
            {t('emergency.home')}
          </Link>
        </div>
      )}
    </>
  )
}

export default function Emergency() {
  const { id = '' } = useParams()
  return (
    <VisitGate id={id} screen="emergency">
      {(visit, refetch) => (
        <PatientShell tone="emergency">
          <EmergencyScreen visit={visit} refetch={refetch} />
        </PatientShell>
      )}
    </VisitGate>
  )
}
