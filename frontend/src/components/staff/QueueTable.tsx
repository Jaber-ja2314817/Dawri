import type { ReactNode } from 'react'
import type { QueueTicket } from '../../api/staffTypes'
import { useI18n } from '../../i18n'
import { cx } from '../../lib/cx'
import { Card, Ltr, Pill } from '../ui'

const DASH = '—'
const HEAD = 'px-3 py-2 text-xs font-normal text-muted'

/* One table at every width: below 640 px the same cells fold into two-line rows. */
const CELL = {
  place: 'text-end tabular-nums max-sm:col-start-1 max-sm:row-start-2 max-sm:text-start',
  number: 'max-sm:col-start-1 max-sm:row-start-1',
  patient: 'max-sm:col-span-2 max-sm:col-start-2 max-sm:row-start-1',
  ageSex: 'max-sm:col-start-2 max-sm:row-start-2',
  complaint: 'max-sm:col-span-2 max-sm:col-start-3 max-sm:row-start-2',
  waiting: 'max-sm:col-start-4 max-sm:row-start-1',
  action: 'max-sm:col-span-4 max-sm:col-start-1 max-sm:row-start-3',
}
const BASE = 'h-11 px-3 align-middle max-sm:h-auto max-sm:p-0'

interface QueueTableProps {
  tickets: QueueTicket[]
  /** One trailing action per row, such as opening a patient. */
  rowAction?: (ticket: QueueTicket) => ReactNode
  'aria-label'?: string
}

function Row({
  ticket,
  rowAction,
}: {
  ticket: QueueTicket
  rowAction?: QueueTableProps['rowAction']
}) {
  const { t, lang } = useI18n()
  const { patient, simulated } = ticket
  const atCounter = ticket.state !== 'active'
  const grey = simulated ? 'text-muted' : 'text-ink'
  return (
    <tr
      data-testid="queue-row"
      data-number={ticket.number}
      data-simulated={simulated}
      data-state={ticket.state}
      className="border-b border-rule last:border-b-0 max-sm:grid max-sm:grid-cols-[auto_auto_minmax(0,1fr)_auto] max-sm:gap-x-3 max-sm:gap-y-1 max-sm:px-3 max-sm:py-2"
    >
      <td className={cx(BASE, CELL.place, 'text-sm whitespace-nowrap text-muted')}>
        {atCounter ? t(`queue.state.${ticket.state}`) : <Ltr>{ticket.position ?? DASH}</Ltr>}
      </td>
      <td className={cx(BASE, CELL.number, 'text-sm font-medium whitespace-nowrap', grey)}>
        <Ltr className={atCounter && !simulated ? 'text-data' : undefined}>{ticket.number}</Ltr>
      </td>
      <td className={cx(BASE, CELL.patient, 'min-w-0 text-sm', grey)}>
        {simulated ? (
          <Pill>{t('queue.simulated')}</Pill>
        ) : (
          <span className="block truncate font-medium">
            {patient ? (lang === 'ar' ? patient.name_ar : patient.name_en) : DASH}
          </span>
        )}
      </td>
      <td className={cx(BASE, CELL.ageSex, 'text-sm whitespace-nowrap text-muted')}>
        {patient ? (
          <>
            <Ltr>{patient.age}</Ltr> · {t(`queue.sex.${patient.sex}`)}
          </>
        ) : (
          DASH
        )}
      </td>
      <td
        className={cx(
          BASE,
          CELL.complaint,
          'w-full max-w-0 min-w-0 text-sm text-muted max-sm:w-auto max-sm:max-w-none',
        )}
      >
        <span dir="auto" className="block truncate">
          {ticket.complaint || DASH}
        </span>
      </td>
      <td
        className={cx(
          BASE,
          CELL.waiting,
          'text-end text-sm font-medium whitespace-nowrap tabular-nums',
          grey,
        )}
      >
        <Ltr>{ticket.waiting_min}</Ltr>
        <span className="ms-1 font-normal text-muted sm:hidden">{t('queue.minutes')}</span>
      </td>
      {rowAction && (
        <td className={cx(BASE, CELL.action, 'whitespace-nowrap')}>{rowAction(ticket)}</td>
      )}
    </tr>
  )
}

export function QueueTable({ tickets, rowAction, ...rest }: QueueTableProps) {
  const { t } = useI18n()
  const columns = rowAction ? 7 : 6
  return (
    <Card flush data-testid="queue-table" className="overflow-hidden">
      <table className="w-full border-collapse max-sm:block" aria-label={rest['aria-label']}>
        <thead className="max-sm:sr-only">
          <tr className="border-b border-border">
            <th scope="col" className={cx(HEAD, 'text-end')}>{t('queue.place')}</th>
            <th scope="col" className={cx(HEAD, 'text-start')}>{t('queue.number')}</th>
            <th scope="col" className={cx(HEAD, 'text-start')}>{t('queue.patient')}</th>
            <th scope="col" className={cx(HEAD, 'text-start whitespace-nowrap')}>{t('queue.ageSex')}</th>
            <th scope="col" className={cx(HEAD, 'text-start')}>{t('queue.complaint')}</th>
            <th scope="col" className={cx(HEAD, 'text-end whitespace-nowrap')}>{t('queue.waiting')}</th>
            {rowAction && <td />}
          </tr>
        </thead>
        <tbody className="max-sm:block">
          {tickets.length === 0 ? (
            <tr className="max-sm:block">
              <td
                colSpan={columns}
                data-testid="queue-empty"
                className="px-3 py-6 text-center text-sm text-muted max-sm:block"
              >
                {t('queue.empty')}
              </td>
            </tr>
          ) : (
            tickets.map((ticket) => (
              <Row key={ticket.ticket_id} ticket={ticket} rowAction={rowAction} />
            ))
          )}
        </tbody>
      </table>
    </Card>
  )
}

export default QueueTable
