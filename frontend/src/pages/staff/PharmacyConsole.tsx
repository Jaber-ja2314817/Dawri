import { useEffect } from 'react'
import { errorText } from '../../api/client'
import type { OwnCounter, QueueTicket } from '../../api/staffTypes'
import { PatientBanner } from '../../components/staff/PatientBanner'
import { StaffShell } from '../../components/staff/StaffShell'
import { Card, ErrorBlock, Ltr, Notice, Skeleton } from '../../components/ui'
import {
  DeskRegions,
  EmptyPanel,
  useBrief,
  useCounterDesk,
  useRefetchWith,
  type CounterDesk,
} from '../../features/staff/doctor/desk'
import { Handover } from '../../features/staff/pharmacy/Handover'
import { useI18n } from '../../i18n'
import { useStaffVisit } from '../../state/staff/hooks'
import { useStaff } from '../../state/staff/session'

const OUTCOME_MS = 8_000

function Empty() {
  const { t } = useI18n()
  return (
    <EmptyPanel
      testId="pharmacy-empty"
      title={t('pharmacy.title.handOver')}
      body={t('pharmacy.empty')}
    >
      <p className="text-sm text-muted">{t('pharmacy.emptyNext')}</p>
    </EmptyPanel>
  )
}

function AtWindow({
  ticket,
  visitId,
  desk,
  onDone,
}: {
  ticket: QueueTicket
  visitId: string
  desk: CounterDesk
  onDone: (number: string) => void
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
        <Skeleton height={160} />
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
      <Handover
        visit={visit.data}
        visitId={visitId}
        onSending={(sending) => desk.expectLeaving(sending ? ticket.ticket_id : null)}
        onDone={() => onDone(ticket.number)}
      />
    </>
  )
}

function PharmacyDesk({ counter }: { counter: OwnCounter }) {
  const { t } = useI18n()
  const desk = useCounterDesk(counter.id)
  const [handed, showHanded] = useBrief<string>(OUTCOME_MS)
  const { current } = desk

  const finish = (number: string) => {
    showHanded(number)
    void desk.queue.refetch()
  }

  return (
    <StaffShell title={t('pharmacy.title')} live={desk.queue.live}>
      <DeskRegions name="pharmacy" desk={desk}>
        {desk.gone && <Notice data-testid="patient-gone">{t('pharmacy.gone')}</Notice>}
        {current === null && handed !== null && (
          <Card data-testid="dispensed-outcome" role="status" className="text-base">
            {t('pharmacy.handed')}{' '}
            <Ltr className="font-semibold text-data">{handed}</Ltr>
          </Card>
        )}
        {current?.visit_id ? (
          <AtWindow
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

export default function PharmacyConsole() {
  const { t } = useI18n()
  const { counters } = useStaff()
  const counter = counters[0]
  if (counter === undefined) {
    return (
      <StaffShell title={t('pharmacy.title')}>
        <EmptyPanel testId="no-counter" title={t('pharmacy.title')} body={t('pharmacy.noCounter')} />
      </StaffShell>
    )
  }
  return <PharmacyDesk key={counter.id} counter={counter} />
}
