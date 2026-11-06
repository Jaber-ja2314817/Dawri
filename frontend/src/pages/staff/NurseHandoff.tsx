import { useState } from 'react'
import { Navigate, useParams } from 'react-router-dom'
import { errorText } from '../../api/client'
import type { HandoffConfirmResponse } from '../../api/staffTypes'
import { PatientBanner } from '../../components/staff/PatientBanner'
import { StaffShell } from '../../components/staff/StaffShell'
import { Card, ErrorBlock, Notice, Skeleton } from '../../components/ui'
import { HandoffDraftForm } from '../../features/staff/nurse/HandoffDraft'
import { HandoffSent } from '../../features/staff/nurse/HandoffSent'
import {
  QUEUE_PATH,
  QuietLink,
  TWO_COLUMNS,
  visitPath,
} from '../../features/staff/nurse/parts'
import { useI18n } from '../../i18n'
import { useStaffVisit } from '../../state/staff/hooks'

function Loading() {
  const { t } = useI18n()
  return (
    <div data-testid="visit-loading" aria-busy="true" aria-label={t('nurse.visit.loading')} className="flex flex-col gap-3">
      <Skeleton height={86} />
      <div className={TWO_COLUMNS}>
        <Card>
          <Skeleton height={300} />
        </Card>
        <Card>
          <Skeleton height={300} />
        </Card>
      </div>
    </div>
  )
}

function Handoff({ visitId }: { visitId: string }) {
  const { t, lang } = useI18n()
  const live = useStaffVisit(visitId)
  const [confirmed, setConfirmed] = useState<HandoffConfirmResponse | null>(null)
  const visit = live.data
  const title = t('staff.title.handoff')

  if (live.state === 'gone') {
    return <Navigate to={QUEUE_PATH} replace state={{ staffNotice: 'nurse.visit.gone' }} />
  }

  if (visit === null) {
    return (
      <StaffShell title={title} live={live.live}>
        {live.state === 'error' ? (
          <ErrorBlock message={errorText(live.error, t, lang)} onRetry={() => void live.refetch()} />
        ) : (
          <Loading />
        )}
      </StaffShell>
    )
  }

  const sent = confirmed !== null || Boolean(visit.handoff?.confirmed_by)
  const inTriage = visit.status === 'in_triage'
  const back = !sent && (
    <QuietLink to={visitPath(visitId)} testId="back-to-intake">
      {t('nurse.handoff.back')}
    </QuietLink>
  )

  return (
    <StaffShell title={title} live={live.live} actions={back}>
      <PatientBanner
        number={visit.ticket?.number ?? null}
        patient={visit.patient}
        arrivedAt={visit.arrived_at}
      />
      {sent ? (
        <HandoffSent visitId={visitId} visit={visit} confirmed={confirmed} refetch={live.refetch} />
      ) : !inTriage ? (
        <div data-testid="visit-locked" className="flex flex-col gap-1">
          <Notice>{t('nurse.handoff.locked')}</Notice>
          <QuietLink to={QUEUE_PATH}>{t('nurse.visit.back')}</QuietLink>
        </div>
      ) : visit.vitals === null ? (
        <div data-testid="vitals-first" className="flex flex-col gap-1">
          <Notice>{t('nurse.handoff.vitalsFirst')}</Notice>
          <QuietLink to={visitPath(visitId)}>{t('nurse.handoff.toVitals')}</QuietLink>
        </div>
      ) : (
        <HandoffDraftForm
          visitId={visitId}
          onConfirmed={(result) => {
            setConfirmed(result)
            void live.refetch()
          }}
        />
      )}
    </StaffShell>
  )
}

export default function NurseHandoff() {
  const { visitId = '' } = useParams()
  return <Handoff key={visitId} visitId={visitId} />
}
