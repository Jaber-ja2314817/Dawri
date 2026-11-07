import { useState } from 'react'
import { Navigate, useLocation, useNavigate, useParams } from 'react-router-dom'
import { errorText } from '../../api/client'
import { PatientBanner } from '../../components/staff/PatientBanner'
import { StaffShell } from '../../components/staff/StaffShell'
import { Button, Card, ErrorBlock, Ltr, Skeleton } from '../../components/ui'
import { IntakeCard } from '../../features/staff/nurse/IntakeCard'
import { QUEUE_PATH, QuietLink } from '../../features/staff/nurse/parts'
import { PatientWords } from '../../features/staff/nurse/PatientWords'
import { EmergencyResult, VitalsForm } from '../../features/staff/nurse/VitalsForm'
import { useI18n } from '../../i18n'
import { useStaffVisit } from '../../state/staff/hooks'
import { useStaff } from '../../state/staff/session'
import { useCounterActions } from '../../state/staff/useCounterActions'

/*
 * 1440 x 900: the shell's content is 1168 px wide (1200 less 16 + 16 gutters).
 * 452 intake + 12 gap + 372 words + 12 gap + 320 vitals = 1168.
 * Each block starts near y = 280, so its header and first rows show without scrolling.
 * Below 1100 px the three stack, and at 390 that is one column with no sideways scroll.
 * Heights stay their own: a transcript is never padded or clipped, and stretching the row
 * only moves the difference into the cards as a blank band (241 px measured).
 */
const BLOCKS =
  'grid min-w-0 grid-cols-1 items-start gap-3 ' +
  'min-[1100px]:grid-cols-[minmax(0,452fr)_minmax(0,372fr)_minmax(0,320fr)]'

function Handled({ numbers }: { numbers: string[] }) {
  const { t } = useI18n()
  return (
    <p data-testid="auto-completed" role="status" className="text-sm text-muted">
      <Ltr>{numbers.join(', ')}</Ltr> {t('nurse.queue.handled')}
    </p>
  )
}

function Loading() {
  const { t } = useI18n()
  return (
    <div data-testid="visit-loading" aria-busy="true" aria-label={t('nurse.visit.loading')} className="flex flex-col gap-3">
      <Skeleton height={86} />
      <div className={BLOCKS}>
        <Card>
          <Skeleton height={420} />
        </Card>
        <Card>
          <Skeleton height={420} />
        </Card>
        <Card>
          <Skeleton height={420} />
        </Card>
      </div>
    </div>
  )
}

function Visit({ visitId }: { visitId: string }) {
  const { t, lang } = useI18n()
  const { counters } = useStaff()
  const navigate = useNavigate()
  const { state: routed } = useLocation()
  const live = useStaffVisit(visitId)
  const actions = useCounterActions(counters[0]?.id ?? '', live.refetch)
  const [escalated, setEscalated] = useState(false)
  const [unsavedEdit, setUnsavedEdit] = useState(false)
  const handled = (routed as { autoCompleted?: string[] } | null)?.autoCompleted ?? []
  const visit = live.data
  const back = <QuietLink to={QUEUE_PATH} testId="back-to-queue">{t('nurse.visit.back')}</QuietLink>

  if (live.state === 'gone') {
    return <Navigate to={QUEUE_PATH} replace state={{ staffNotice: 'nurse.visit.gone' }} />
  }

  if (visit === null) {
    return (
      <StaffShell title={t('staff.title.visit')} live={live.live} actions={back}>
        {live.state === 'error' ? (
          <ErrorBlock message={errorText(live.error, t, lang)} onRetry={() => void live.refetch()} />
        ) : (
          <Loading />
        )}
      </StaffShell>
    )
  }

  const { ticket } = visit
  const called = ticket?.state === 'called' ? ticket : null
  const inTriage = visit.status === 'in_triage' && !escalated
  const emergency = escalated || visit.status === 'redirected_emergency'

  const notHere = async (ticketId: string) => {
    const back = await actions.notHere(ticketId)
    if (back !== null) navigate(QUEUE_PATH)
  }

  return (
    <StaffShell title={t('staff.title.visit')} live={live.live} actions={back}>
      {handled.length > 0 && <Handled numbers={handled} />}
      <div className="flex min-w-0 flex-wrap items-stretch gap-3">
        <div className="min-w-0 flex-[1_1_480px]">
          <PatientBanner
            number={ticket?.number ?? null}
            patient={visit.patient}
            arrivedAt={visit.arrived_at}
          />
        </div>
        {inTriage && called !== null && (
          <div className="flex flex-wrap items-center gap-2">
            <Button
              variant="secondary"
              data-testid="not-here"
              disabled={actions.busy}
              onClick={() => void notHere(called.id)}
            >
              {t('queue.notHere')}
            </Button>
            <Button
              variant="secondary"
              data-testid="patient-here"
              loading={actions.busy}
              onClick={() => void actions.serve(called.id)}
            >
              {t('queue.patientHere')}
            </Button>
          </div>
        )}
      </div>
      {actions.error !== null && <ErrorBlock message={errorText(actions.error, t, lang)} />}
      <div className={BLOCKS}>
        <IntakeCard
          visitId={visitId}
          visit={visit}
          editable={inTriage}
          refetch={live.refetch}
          onUnsaved={setUnsavedEdit}
        />
        <PatientWords turns={visit.turns} />
        {emergency ? (
          <EmergencyResult />
        ) : (
          <VitalsForm
            key={visitId}
            visitId={visitId}
            visit={visit}
            unsavedEdit={unsavedEdit}
            onEscalated={() => {
              setEscalated(true)
              void live.refetch()
            }}
          />
        )}
      </div>
    </StaffShell>
  )
}

export default function NurseVisit() {
  const { visitId = '' } = useParams()
  return <Visit key={visitId} visitId={visitId} />
}
