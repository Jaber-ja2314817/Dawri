import { Link, Navigate } from 'react-router-dom'
import { errorText } from '../../api/client'
import type { Patient } from '../../api/types'
import { ChevronIcon } from '../../components/icons'
import { PatientShell } from '../../components/PatientShell'
import { Card, ErrorBlock, Skeleton } from '../../components/ui'
import { useI18n } from '../../i18n'
import { checkInPath } from '../../lib/checkin'
import { nameOf } from '../../lib/format'
import { useSession } from '../../state/session'

function Person({ person, self }: { person: Patient; self: boolean }) {
  const { t, lang } = useI18n()
  return (
    <li className="border-t border-rule first:border-t-0">
      <Link
        to={`/check-in/consent?for=${encodeURIComponent(person.id)}`}
        data-testid={`who-${person.id}`}
        className="flex min-h-14 items-center gap-3 px-4 py-2"
      >
        <span className="min-w-0 flex-1">
          <span className="block text-base font-medium">
            {self ? t('who.me') : nameOf(person, lang)}
          </span>
          <span className="block text-sm text-muted">
            {self ? nameOf(person, lang) + ' · ' : ''}
            {t('who.age', { age: person.age })}
          </span>
        </span>
        <ChevronIcon className="text-muted" />
      </Link>
    </li>
  )
}

export default function Who() {
  const { t, lang } = useI18n()
  const { me, meState, meError, reloadMe } = useSession()

  if (me && me.dependents.length === 0) return <Navigate to={checkInPath(me)} replace />

  return (
    <PatientShell title={t('who.title')} back="/home">
      {meState === 'error' && !me ? (
        <ErrorBlock message={errorText(meError, t, lang)} onRetry={() => void reloadMe()} />
      ) : me ? (
        <Card as="ul" flush>
          <Person person={me.patient} self />
          {me.dependents.map((dependent) => (
            <Person key={dependent.id} person={dependent} self={false} />
          ))}
        </Card>
      ) : (
        <Skeleton height={168} className="rounded-panel" />
      )}
    </PatientShell>
  )
}
