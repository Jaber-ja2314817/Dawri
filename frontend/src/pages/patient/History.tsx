import { Link, useNavigate } from 'react-router-dom'
import { errorText } from '../../api/client'
import type { VisitRow, VisitStatus } from '../../api/types'
import { ChevronIcon } from '../../components/icons'
import { PatientShell } from '../../components/PatientShell'
import { Button, Card, ErrorBlock, Pill, Skeleton, type PillTone } from '../../components/ui'
import { useI18n } from '../../i18n'
import { checkInPath } from '../../lib/checkin'
import { centreName, formatDate, nameOf } from '../../lib/format'
import { useSession } from '../../state/session'
import { useVisitList } from '../../state/useVisitList'

const NOT_LINKS: VisitStatus[] = ['redirected_emergency', 'deflected_refill', 'expired', 'cancelled']

const TONES: Partial<Record<VisitStatus, PillTone>> = {
  completed: 'positive',
  redirected_emergency: 'negative',
  expired: 'warning',
}

function hrefOf(row: VisitRow): string | null {
  if (NOT_LINKS.includes(row.status)) return null
  if (row.status === 'completed') return `/visit/${row.visit_id}/complete`
  return `/visit/${row.visit_id}`
}

function Row({ row }: { row: VisitRow }) {
  const { t, lang } = useI18n()
  const { me } = useSession()
  const href = hrefOf(row)
  const dependent = me?.dependents.find((person) => person.id === row.patient_id)
  const details = [
    row.service ? t(`service.${row.service}`) : null,
    dependent ? nameOf(dependent, lang) : null,
  ].filter(Boolean)
  const content = (
    <>
      <span className="min-w-0 flex-1">
        <span className="block text-sm font-medium">
          {row.centre ? centreName(row.centre, lang) : t('history.noCentre')}
        </span>
        <span className="block text-sm text-muted">
          {[formatDate(row.created_at, lang), ...details].join(' · ')}
        </span>
      </span>
      <Pill tone={TONES[row.status]}>{t(`status.${row.status}`)}</Pill>
      {href && <ChevronIcon className="text-muted" />}
    </>
  )
  const rowClass = 'flex min-h-14 items-center gap-3 px-4 py-2'
  return (
    <li data-testid="history-row" className="border-t border-rule first:border-t-0">
      {href ? (
        <Link to={href} className={rowClass}>
          {content}
        </Link>
      ) : (
        <div className={rowClass}>{content}</div>
      )}
    </li>
  )
}

export default function History() {
  const { t, lang } = useI18n()
  const navigate = useNavigate()
  const { me } = useSession()
  const { rows, state, error, retry } = useVisitList()

  return (
    <PatientShell title={t('history.title')} back="/home">
      {state === 'loading' && <Skeleton height={168} className="rounded-panel" />}
      {state === 'error' && (
        <ErrorBlock message={errorText(error, t, lang)} onRetry={() => void retry()} />
      )}
      {state === 'ready' && rows.length > 0 && (
        <Card as="ul" flush>
          {rows.map((row) => (
            <Row key={row.visit_id} row={row} />
          ))}
        </Card>
      )}
      {state === 'ready' && rows.length === 0 && (
        <>
          <p className="text-base text-muted">{t('history.empty')}</p>
          <Button
            className="w-full"
            disabled={me === null}
            onClick={() => me && navigate(checkInPath(me))}
          >
            {t('home.start')}
          </Button>
        </>
      )}
    </PatientShell>
  )
}
