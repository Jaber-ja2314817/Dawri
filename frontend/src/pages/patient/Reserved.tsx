import { useEffect, useState, type ReactNode } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { ApiError, errorText } from '../../api/client'
import { arrive } from '../../api/endpoints'
import type { ArriveBody, Visit } from '../../api/types'
import { PatientShell } from '../../components/PatientShell'
import { Button, buttonClass, Card, ErrorBlock, Ltr, Notice } from '../../components/ui'
import { VisitGate } from '../../components/VisitGate'
import { currentPosition } from '../../features/map/location'
import { formatCountdown, useCountdown } from '../../features/ticket/countdown'
import { Dash, Filled } from '../../features/ticket/Values'
import { useI18n } from '../../i18n'
import { centreName } from '../../lib/format'

const GEOFENCE_M = 150
const EXPIRY_RETRY_MS = 5_000

type Busy = 'button' | 'location' | null

function Waiting({ visit, refetch }: { visit: Visit; refetch: () => Promise<void> }) {
  const { t, lang } = useI18n()
  const navigate = useNavigate()
  const seconds = useCountdown(visit.ticket?.expires_at ?? null)
  const [busy, setBusy] = useState<Busy>(null)
  const [notice, setNotice] = useState<ReactNode>(null)
  const [failure, setFailure] = useState<string | null>(null)
  const id = visit.visit_id
  const ranOut = seconds === 0

  // GET runs the expiry. The retry covers a phone clock slightly ahead of the server's.
  useEffect(() => {
    if (!ranOut) return
    void refetch()
    const retry = setInterval(() => void refetch(), EXPIRY_RETRY_MS)
    return () => clearInterval(retry)
  }, [ranOut, refetch])

  const send = async (body: ArriveBody) => {
    try {
      await arrive(id, body)
      navigate(`/visit/${id}/ticket`, { replace: true })
    } catch (cause) {
      if (!(cause instanceof ApiError)) {
        setFailure(errorText(cause, t, lang))
      } else if (cause.code === 'ticket_expired') {
        await refetch()
      } else if (cause.code === 'emergency_today' && typeof cause.extra.visit_id === 'string') {
        navigate(`/visit/${cause.extra.visit_id}`, { replace: true })
      } else if (cause.code === 'too_far' && typeof cause.extra.distance_m === 'number') {
        setNotice(
          <Filled
            text={t('reserved.tooFar')}
            vars={{ distance: cause.extra.distance_m, limit: GEOFENCE_M }}
          />,
        )
      } else {
        setFailure(errorText(cause, t, lang))
      }
    }
  }

  const clear = () => {
    setNotice(null)
    setFailure(null)
  }

  const hereByButton = async () => {
    clear()
    setBusy('button')
    await send({ button: true })
    setBusy(null)
  }

  const hereByLocation = async () => {
    clear()
    setBusy('location')
    try {
      await send(await currentPosition())
    } catch {
      setNotice(t('reserved.locationFailed'))
    }
    setBusy(null)
  }

  return (
    <PatientShell
      title={visit.centre ? centreName(visit.centre, lang) : t('screen.reserved')}
      back="/home"
    >
      <Card className="flex flex-col items-center gap-2 py-6 text-center">
        <p className="text-base font-medium">{t('reserved.valid')}</p>
        <p
          role="timer"
          aria-label={t('reserved.timeLeft')}
          data-testid="countdown"
          className="text-2xl font-semibold tabular-nums"
        >
          {seconds === null ? <Dash /> : <Ltr>{formatCountdown(seconds)}</Ltr>}
        </p>
        <p className="text-sm text-muted">{t('reserved.activates')}</p>
      </Card>

      {notice !== null && <Notice>{notice}</Notice>}
      {failure !== null && <ErrorBlock message={failure} />}

      <Button
        className="w-full"
        loading={busy === 'button'}
        disabled={busy !== null}
        data-testid="im-here"
        onClick={() => void hereByButton()}
      >
        {t('reserved.here')}
      </Button>
      <Button
        variant="secondary"
        className="w-full"
        loading={busy === 'location'}
        disabled={busy !== null}
        data-testid="check-location"
        onClick={() => void hereByLocation()}
      >
        {t('reserved.useLocation')}
      </Button>
    </PatientShell>
  )
}

function Expired({ id }: { id: string }) {
  const { t } = useI18n()
  return (
    <PatientShell title={t('reserved.expiredTitle')} back="/home">
      <p className="text-base">{t('reserved.expiredBody')}</p>
      <Link
        to={`/visit/${id}/centre`}
        data-testid="choose-again"
        className={buttonClass('primary', 'w-full')}
      >
        {t('reserved.chooseAgain')}
      </Link>
    </PatientShell>
  )
}

export default function Reserved() {
  const { id = '' } = useParams()
  return (
    <VisitGate id={id} screen="reserved">
      {(visit, refetch) =>
        visit.stage === 'expired' ? (
          <Expired id={id} />
        ) : (
          <Waiting visit={visit} refetch={refetch} />
        )
      }
    </VisitGate>
  )
}
