import { useEffect, useMemo, useState } from 'react'
import { Navigate } from 'react-router-dom'
import { errorText } from '../../api/client'
import { demoStaff } from '../../api/staff'
import type { DemoStaff } from '../../api/staffTypes'
import { StaffShell } from '../../components/staff/StaffShell'
import { Button, ErrorBlock, Skeleton } from '../../components/ui'
import { useI18n } from '../../i18n'
import { ROLE_ORDER, roleHome } from '../../state/staff/roles'
import { useStaff } from '../../state/staff/session'

const DEFAULT_CENTRE = 'C-WAKRA'

export default function Login() {
  const { t, lang } = useI18n()
  const { token, staff, state, error, signIn, reload } = useStaff()
  const [people, setPeople] = useState<DemoStaff[] | null>(null)
  const [loadFailed, setLoadFailed] = useState<unknown>(null)
  const [attempt, setAttempt] = useState(0)
  const [centreId, setCentreId] = useState(DEFAULT_CENTRE)
  const [busy, setBusy] = useState<string | null>(null)
  const [refused, setRefused] = useState<unknown>(null)

  useEffect(() => {
    const controller = new AbortController()
    setLoadFailed(null)
    demoStaff({ signal: controller.signal })
      .then(setPeople)
      .catch((cause: unknown) => {
        if (!controller.signal.aborted) setLoadFailed(cause)
      })
    return () => controller.abort()
  }, [attempt])

  const centres = useMemo(() => {
    const seen = new Map<string, { id: string; name: string }>()
    for (const person of people ?? []) {
      seen.set(person.centre_id, {
        id: person.centre_id,
        name: lang === 'ar' ? person.centre_name_ar : person.centre_name_en,
      })
    }
    return [...seen.values()]
  }, [people, lang])

  if (token !== null && staff !== null) return <Navigate to={roleHome(staff.role)} replace />

  const here = (people ?? []).filter((person) => person.centre_id === centreId)
  const groups = ROLE_ORDER.map((role) => ({
    role,
    members: here.filter((person) => person.role === role),
  })).filter((group) => group.members.length > 0)

  const pick = async (id: string) => {
    setBusy(id)
    setRefused(null)
    try {
      await signIn(id)
      // The redirect above moves on to the console.
    } catch (cause) {
      setRefused(cause)
    } finally {
      setBusy(null)
    }
  }

  const failure = refused ?? (state === 'error' ? error : null)

  return (
    <StaffShell title={t('staff.login.title')} subtitle={t('staff.login.subtitle')}>
      {failure !== null && (
        <ErrorBlock
          message={errorText(failure, t, lang)}
          onRetry={state === 'error' ? () => void reload() : undefined}
        />
      )}
      {loadFailed !== null ? (
        <ErrorBlock
          message={errorText(loadFailed, t, lang)}
          onRetry={() => setAttempt((count) => count + 1)}
        />
      ) : people === null ? (
        <div data-testid="staff-loading" className="flex flex-col gap-3">
          <Skeleton height={44} width={320} />
          <Skeleton height={44} />
          <Skeleton height={44} />
        </div>
      ) : (
        <>
          <label className="flex max-w-[320px] flex-col gap-2">
            <span className="text-sm font-medium">{t('staff.login.centre')}</span>
            <select
              data-testid="staff-centre"
              value={centreId}
              onChange={(event) => setCentreId(event.target.value)}
              className="min-h-11 w-full rounded-control border border-control bg-surface px-3 text-base text-ink"
            >
              {centres.map((centre) => (
                <option key={centre.id} value={centre.id}>
                  {centre.name}
                </option>
              ))}
            </select>
          </label>
          {groups.length === 0 ? (
            <p data-testid="staff-empty" className="text-sm text-muted">
              {t('staff.login.empty')}
            </p>
          ) : (
            groups.map((group) => (
              <section
                key={group.role}
                aria-labelledby={`role-${group.role}`}
                data-testid={`staff-group-${group.role}`}
                className="flex flex-col gap-2"
              >
                <h2 id={`role-${group.role}`} className="text-sm font-medium">
                  {t(`staff.role.${group.role}`)}
                </h2>
                <div className="flex flex-wrap gap-2">
                  {group.members.map((person) => (
                    <Button
                      key={person.id}
                      variant="secondary"
                      data-testid={`staff-chip-${person.id}`}
                      loading={busy === person.id}
                      disabled={busy !== null}
                      className="px-3 text-sm"
                      onClick={() => void pick(person.id)}
                    >
                      <span>{person.name}</span>
                      {person.counters.map((counter) => (
                        <span key={counter.id} className="text-xs font-normal text-muted">
                          {lang === 'ar' ? counter.label_ar : counter.label}
                        </span>
                      ))}
                    </Button>
                  ))}
                </div>
                {group.role === 'doctor' && centreId === DEFAULT_CENTRE && (
                  <p data-testid="noor-note" className="text-xs text-muted">
                    {t('staff.login.noorNote')}
                  </p>
                )}
              </section>
            ))
          )}
        </>
      )}
    </StaffShell>
  )
}
