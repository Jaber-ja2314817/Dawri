import { Link, useLocation, useNavigate } from 'react-router-dom'
import { errorText } from '../../api/client'
import type { Me, VisitRow } from '../../api/types'
import { ChevronIcon } from '../../components/icons'
import { PatientShell } from '../../components/PatientShell'
import {
  Button,
  buttonClass,
  Card,
  ErrorBlock,
  Notice,
  Pill,
  Skeleton,
  Title,
  type PillTone,
} from '../../components/ui'
import { useI18n } from '../../i18n'
import { recordTerm } from '../../i18n/record'
import { checkInPath } from '../../lib/checkin'
import { centreName, nameOf } from '../../lib/format'
import { useSession } from '../../state/session'
import { useVisitList } from '../../state/useVisitList'

const FLAGGED_ALLERGY = 'penicillin'

const dohaDay = (when: string | number) =>
  new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Qatar' }).format(new Date(when))

/** The same day the server refuses a new check-in, so an old emergency does not stay open. */
function isEmergencyToday(row: VisitRow): boolean {
  return row.status === 'redirected_emergency' && dohaDay(row.created_at) === dohaDay(Date.now())
}

function isOpen(row: VisitRow): boolean {
  return row.active || row.status === 'intake' || row.status === 'expired' || isEmergencyToday(row)
}

function toneOf(row: VisitRow): PillTone {
  if (row.status === 'redirected_emergency') return 'negative'
  return row.status === 'expired' ? 'warning' : 'neutral'
}

function OpenVisit({ row, me }: { row: VisitRow; me: Me }) {
  const { t, lang } = useI18n()
  const people = [me.patient, ...me.dependents]
  const person = people.find((candidate) => candidate.id === row.patient_id)
  return (
    <Card as="li" flush>
      <Link
        to={`/visit/${row.visit_id}`}
        data-testid="open-visit"
        className="flex min-h-11 items-center gap-3 p-4"
      >
        <span className="min-w-0 flex-1">
          <span className="block text-base font-medium">{person ? nameOf(person, lang) : ''}</span>
          {row.centre && (
            <span className="block text-sm text-muted">{centreName(row.centre, lang)}</span>
          )}
        </span>
        <Pill tone={toneOf(row)}>{t(`status.${row.status}`)}</Pill>
        <ChevronIcon className="text-muted" />
      </Link>
    </Card>
  )
}

function Record({ me }: { me: Me }) {
  const { t, lang } = useI18n()
  const { patient } = me
  return (
    <Card flush className="flex flex-col px-4 py-1">
      <div className="flex min-h-11 items-center justify-between gap-3 py-2">
        <span className="text-sm text-muted">{t('home.registeredCentre')}</span>
        <span className="text-end text-sm font-medium">
          {centreName(patient.registered_centre, lang)}
        </span>
      </div>
      <div className="flex min-h-11 items-center justify-between gap-3 border-t border-rule py-2">
        <span className="text-sm text-muted">{t('home.allergies')}</span>
        {patient.allergies.length === 0 ? (
          <span className="text-sm text-muted">{t('home.noAllergies')}</span>
        ) : (
          <span className="flex flex-wrap justify-end gap-1">
            {patient.allergies.map((allergy) => (
              <Pill
                key={allergy}
                tone={allergy.toLowerCase() === FLAGGED_ALLERGY ? 'warning' : 'neutral'}
              >
                <span className="inline-block first-letter:uppercase">
                  {recordTerm(allergy, lang)}
                </span>
              </Pill>
            ))}
          </span>
        )}
      </div>
    </Card>
  )
}

export default function Home() {
  const { t, lang } = useI18n()
  const navigate = useNavigate()
  const location = useLocation()
  const { me, meState, meError, reloadMe, signOut, patient } = useSession()
  const visits = useVisitList()
  const demoReset = (location.state as { demoReset?: boolean } | null)?.demoReset === true
  const open = visits.rows.filter(isOpen)
  const showOpen = visits.state === 'ready' && open.length > 0

  return (
    <PatientShell>
      <div className="flex items-center justify-between gap-3">
        {patient ? (
          <Title>{nameOf(patient, lang)}</Title>
        ) : (
          <Title>
            <Skeleton width={180} height={24} className="my-1" />
          </Title>
        )}
        <Pill>{t('home.demoData')}</Pill>
      </div>

      {demoReset && <Notice>{t('home.demoReset')}</Notice>}

      {showOpen && me && (
        <section aria-labelledby="open-visits" className="flex flex-col gap-2">
          <h2 id="open-visits" className="text-sm font-medium">
            {t('home.openVisits')}
          </h2>
          <ul className="flex flex-col gap-3">
            {open.map((row) => (
              <OpenVisit key={row.visit_id} row={row} me={me} />
            ))}
          </ul>
        </section>
      )}

      {meState === 'error' ? (
        <ErrorBlock message={errorText(meError, t, lang)} onRetry={() => void reloadMe()} />
      ) : me ? (
        <Record me={me} />
      ) : (
        <Skeleton height={90} className="rounded-panel" />
      )}

      <Button
        className="w-full"
        variant={showOpen ? 'secondary' : 'primary'}
        disabled={me === null}
        onClick={() => me && navigate(checkInPath(me))}
      >
        {t('home.start')}
      </Button>

      {visits.state === 'error' && (
        <ErrorBlock
          message={errorText(visits.error, t, lang)}
          onRetry={() => void visits.retry()}
        />
      )}

      <div className="mt-3 flex items-center justify-between gap-3">
        <Link to="/history" className={buttonClass('quiet', '-ms-4')}>
          {t('home.history')}
        </Link>
        <Button variant="quiet" className="-me-4" onClick={signOut}>
          {t('home.logout')}
        </Button>
      </div>
    </PatientShell>
  )
}
