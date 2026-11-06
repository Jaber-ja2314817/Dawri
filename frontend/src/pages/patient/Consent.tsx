import { useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { ApiError, errorText } from '../../api/client'
import { createVisit } from '../../api/endpoints'
import { PatientShell } from '../../components/PatientShell'
import { Button, Card, ErrorBlock } from '../../components/ui'
import { useI18n } from '../../i18n'
import { nameOf } from '../../lib/format'
import { useSession } from '../../state/session'

const POINTS = ['consent.why', 'consent.limits', 'consent.privacy', 'consent.demo']

export default function Consent() {
  const { t, lang } = useI18n()
  const navigate = useNavigate()
  const [params] = useSearchParams()
  const { patient, me } = useSession()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<unknown>(null)

  const patientId = params.get('for') ?? patient?.id
  const dependent = me?.dependents.find((person) => person.id === patientId)
  const back = me && me.dependents.length > 0 ? '/check-in/who' : '/home'

  const agree = async () => {
    setBusy(true)
    setError(null)
    try {
      const { visit_id } = await createVisit({ patient_id: patientId, consent: true })
      navigate(`/visit/${visit_id}/chat`, { replace: true })
    } catch (cause) {
      const visitId = cause instanceof ApiError ? cause.extra.visit_id : undefined
      if (cause instanceof ApiError && typeof visitId === 'string') {
        // Never a new chat: the emergency stands for today, and one visit is enough.
        if (cause.code === 'emergency_today') {
          navigate(`/visit/${visitId}/emergency`, { replace: true })
          return
        }
        if (cause.code === 'active_visit') {
          navigate(`/visit/${visitId}`, { replace: true })
          return
        }
      }
      setError(cause)
      setBusy(false)
    }
  }

  return (
    <PatientShell title={t('consent.title')} back={back}>
      {dependent && (
        <p className="text-base text-muted">
          {t('consent.forPerson', { name: nameOf(dependent, lang) })}
        </p>
      )}
      <Card as="ul" className="flex flex-col gap-3 text-base">
        {POINTS.map((key) => (
          <li key={key}>{t(key)}</li>
        ))}
      </Card>
      {error !== null && (
        <ErrorBlock message={errorText(error, t, lang)} onRetry={() => void agree()} />
      )}
      <Button className="w-full" loading={busy} onClick={() => void agree()}>
        {t('consent.agree')}
      </Button>
    </PatientShell>
  )
}
