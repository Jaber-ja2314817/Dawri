import { useEffect } from 'react'
import { PatientBanner } from '../../components/staff/PatientBanner'
import { StaffShell } from '../../components/staff/StaffShell'
import { Card, ErrorBlock, Ltr, Notice, Skeleton } from '../../components/ui'
import { errorText } from '../../api/client'
import type { ConsultDoneResponse, OwnCounter, QueueTicket } from '../../api/staffTypes'
import {
  DeskRegions,
  EmptyPanel,
  useBrief,
  useCounterDesk,
  useRefetchWith,
  type CounterDesk,
} from '../../features/staff/doctor/desk'
import { HandoffCard } from '../../features/staff/doctor/HandoffCard'
import { Prescription } from '../../features/staff/doctor/Prescription'
import { useI18n } from '../../i18n'
import { useStaffVisit } from '../../state/staff/hooks'
import { useStaff } from '../../state/staff/session'

const OUTCOME_MS = 8_000

function Empty() {
  const { t } = useI18n()
  return (
    <>
      <EmptyPanel
        testId="doctor-empty"
        title={t('doctor.handoff.title')}
        body={t('doctor.empty')}
      >
        <p className="text-sm text-muted">{t('doctor.emptyNext')}</p>
      </EmptyPanel>
      <EmptyPanel
        testId="doctor-rx-empty"
        title={t('doctor.rx.title')}
        body={t('doctor.rx.empty')}
      />
    </>
  )
}

function WithDoctor({
  ticket,
  visitId,
  desk,
  onDone,
}: {
  ticket: QueueTicket
  visitId: string
  desk: CounterDesk
  onDone: (result: ConsultDoneResponse) => void
}) {
  const { t, lang } = useI18n()
  const visit = useStaffVisit(visitId, { stream: false })
  const { refetch, state } = visit
  const { visitGone } = desk
  useRefetchWith(desk.queue.updatedAt, refetch)
  useEffect(() => {
    if (state === 'gone') visitGone()
  }, [state, visitGone])

  if (state === 'gone') return <Empty />
  if (state === 'error') {
    return <ErrorBlock message={errorText(visit.error, t, lang)} onRetry={() => void refetch()} />
  }
  if (visit.data === null) {
    return (
      <div data-testid="patient-loading" className="flex flex-col gap-3">
        <Skeleton height={88} />
        <Skeleton height={240} />
      </div>
    )
  }
  return (
    <>
      <PatientBanner
        number={ticket.number}
        patient={visit.data.patient}
        arrivedAt={visit.data.arrived_at}
      />
      <HandoffCard visit={visit.data} />
      <Prescription
        visitId={visitId}
        onSending={(sending) => desk.expectLeaving(sending ? ticket.ticket_id : null)}
        onDone={onDone}
      />
    </>
  )
}

function Outcome({ result }: { result: ConsultDoneResponse }) {
  const { t } = useI18n()
  const finished = result.status === 'completed'
  return (
    <Card data-testid="consult-outcome" role="status" className="text-base">
      {finished ? (
        <span data-testid="visit-finished">{t('doctor.finished')}</span>
      ) : (
        <>
          {t('doctor.moved')}{' '}
          <Ltr className="font-semibold text-data">
            <span data-testid="moved-number">{result.ticket.number}</span>
          </Ltr>
        </>
      )}
    </Card>
  )
}

function DoctorDesk({ counter }: { counter: OwnCounter }) {
  const { t, lang } = useI18n()
  const desk = useCounterDesk(counter.id)
  const [outcome, showOutcome] = useBrief<ConsultDoneResponse>(OUTCOME_MS)
  const { current } = desk

  const finish = (result: ConsultDoneResponse) => {
    showOutcome(result)
    void desk.queue.refetch()
  }

  return (
    <StaffShell
      title={t('doctor.title')}
      subtitle={lang === 'ar' ? counter.label_ar : counter.label}
      live={desk.queue.live}
    >
      <DeskRegions name="doctor" desk={desk}>
        {desk.gone && <Notice data-testid="patient-gone">{t('doctor.gone')}</Notice>}
        {current === null && outcome !== null && <Outcome result={outcome} />}
        {current?.visit_id ? (
          <WithDoctor
            key={current.ticket_id}
            ticket={current}
            visitId={current.visit_id}
            desk={desk}
            onDone={finish}
          />
        ) : (
          <Empty />
        )}
      </DeskRegions>
    </StaffShell>
  )
}

export default function DoctorConsole() {
  const { t } = useI18n()
  const { counters } = useStaff()
  const counter = counters[0]
  if (counter === undefined) {
    return (
      <StaffShell title={t('doctor.title')}>
        <EmptyPanel testId="no-counter" title={t('doctor.title')} body={t('doctor.noCounter')} />
      </StaffShell>
    )
  }
  return <DoctorDesk key={counter.id} counter={counter} />
}
