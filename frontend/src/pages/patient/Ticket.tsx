import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import type { Ticket as TicketData, Visit } from '../../api/types'
import { PatientShell } from '../../components/PatientShell'
import { Card, Ltr } from '../../components/ui'
import { VisitGate } from '../../components/VisitGate'
import { Steps } from '../../features/ticket/Steps'
import '../../features/ticket/ticket.css'
import { Count, Dash, Minutes, Row, Rows } from '../../features/ticket/Values'
import { useI18n, type Lang } from '../../i18n'
import { centreName, nameOf } from '../../lib/format'
import { useSession } from '../../state/session'
import type { LiveMode } from '../../state/useVisit'

// The stream takes a moment to open on every mount, and that is not a slow connection.
const POLLING_NOTICE_DELAY_MS = 1_500

const ON_SCREEN: TicketData['state'][] = ['active', 'called', 'serving']

function clock(at: number, lang: Lang): string {
  return new Intl.DateTimeFormat(lang === 'ar' ? 'ar-QA-u-nu-latn' : 'en-GB', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
    timeZone: 'Asia/Qatar',
  }).format(at)
}

function usePollingSettled(live: LiveMode): boolean {
  const [settled, setSettled] = useState(false)

  useEffect(() => {
    setSettled(false)
    if (live !== 'polling') return
    const timer = setTimeout(() => setSettled(true), POLLING_NOTICE_DELAY_MS)
    return () => clearTimeout(timer)
  }, [live])

  return settled
}

function TicketNumber({ number }: { number: string }) {
  const { t } = useI18n()
  return (
    <div className="ticket-frame w-full" aria-live="polite" aria-atomic="true">
      <p className="sr-only">{t('ticket.numberLabel')}</p>
      {/* A new key restarts the change of state when the number moves on. */}
      <p
        key={number}
        data-testid="ticket-number"
        className="ticket-change ticket-number font-semibold text-data"
        style={{ '--ticket-chars': number.length } as React.CSSProperties}
      >
        <Ltr>{number}</Ltr>
      </p>
    </div>
  )
}

function Freshness({ live, updatedAt }: { live: LiveMode; updatedAt: number | null }) {
  const { t, lang } = useI18n()
  const slow = usePollingSettled(live)
  if (!slow) return null
  return (
    <p data-testid="freshness" className="text-center text-xs text-muted">
      {t('ticket.slower')}
      {updatedAt !== null && (
        <>
          {' '}
          {t('ticket.updatedAt')} <Ltr>{clock(updatedAt, lang)}</Ltr>
        </>
      )}
    </p>
  )
}

function TicketDetail({ visit, ticket }: { visit: Visit; ticket: TicketData }) {
  const { t, lang } = useI18n()
  const counter = visit.go_to && (lang === 'ar' ? visit.go_to.counter_ar : visit.go_to.counter)
  return (
    <>
      {/*
        In the page from the start, so the call is read out the moment it lands. Empty, it
        leaves the column's flow without being hidden, which would stop it being a live region.
      */}
      <div aria-live="assertive" aria-atomic="true" className="empty:absolute">
        {ticket.state === 'called' && (
          <p
            data-testid="ticket-called"
            className="ticket-change rounded-panel bg-ink p-4 text-center text-xl font-semibold text-white"
          >
            {t('ticket.goNow', { counter: counter ?? '' })}
          </p>
        )}
      </div>
      {ticket.state === 'serving' && (
        <Card
          data-testid="ticket-serving"
          className="ticket-change text-center text-base font-medium"
        >
          {t('ticket.withTeam')}
        </Card>
      )}
      {/* Once called, the block above already says where to go. */}
      {ticket.state !== 'called' && (
        <Card flush>
          <Rows>
            {ticket.state === 'active' && (
              <>
                <Row label={t('ticket.peopleAhead')}>
                  <span data-testid="people-ahead">
                    <Count value={ticket.people_ahead} />
                  </span>
                </Row>
                <Row label={t('ticket.estimatedWait')}>
                  <span data-testid="est-wait">
                    <Minutes value={ticket.est_wait_min} />
                  </span>
                </Row>
              </>
            )}
            <Row label={t('ticket.goTo')}>
              <span data-testid="go-to">{counter ?? <Dash />}</span>
            </Row>
          </Rows>
        </Card>
      )}
    </>
  )
}

function TicketScreen({
  visit,
  live,
  updatedAt,
}: {
  visit: Visit
  live: LiveMode
  updatedAt: number | null
}) {
  const { t, lang } = useI18n()
  const { me } = useSession()
  const dependent = me?.dependents.find((person) => person.id === visit.patient_id)
  const ticket =
    visit.ticket !== null && ON_SCREEN.includes(visit.ticket.state) ? visit.ticket : null

  return (
    <PatientShell title={visit.centre ? centreName(visit.centre, lang) : t('screen.ticket')}>
      {dependent && (
        <p data-testid="visit-for" className="text-sm text-muted">
          {t('ticket.forPerson', { name: nameOf(dependent, lang) })}
        </p>
      )}
      <Card
        data-testid="ticket-card"
        data-live={live}
        className="flex flex-col items-center gap-4 py-6 text-center"
      >
        {ticket?.number ? (
          <TicketNumber number={ticket.number} />
        ) : (
          <p data-testid="ticket-next" className="ticket-change text-xl font-semibold">
            {t('ticket.nextStep')}
          </p>
        )}
        <Steps stage={visit.stage} />
      </Card>
      {ticket !== null && <TicketDetail visit={visit} ticket={ticket} />}
      <Freshness live={live} updatedAt={updatedAt} />
    </PatientShell>
  )
}

export default function Ticket() {
  const { id = '' } = useParams()
  return (
    <VisitGate id={id} screen="ticket">
      {(visit, _refetch, live, updatedAt) => (
        <TicketScreen visit={visit} live={live} updatedAt={updatedAt} />
      )}
    </VisitGate>
  )
}
