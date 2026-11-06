import { useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { ApiError, errorText } from '../../api/client'
import { continueRefill } from '../../api/endpoints'
import type { Visit } from '../../api/types'
import { PatientShell } from '../../components/PatientShell'
import { Button, Card, ErrorBlock, Notice } from '../../components/ui'
import { VisitGate } from '../../components/VisitGate'
import { useI18n } from '../../i18n'
import { pathFor } from '../../lib/stages'

function RefillScreen({ visit, refetch }: { visit: Visit; refetch: () => Promise<void> }) {
  const { t, lang } = useI18n()
  const navigate = useNavigate()
  const [noticed, setNoticed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<unknown>(null)
  const id = visit.visit_id

  const wantVisit = async () => {
    setBusy(true)
    setError(null)
    try {
      await continueRefill(id)
      await refetch()
      navigate(pathFor(id, 'centre'), { replace: true })
    } catch (cause) {
      // A first try that landed comes back as this: the gate then moves on.
      if (cause instanceof ApiError && cause.code === 'visit_not_deflected') await refetch()
      setError(cause)
      setBusy(false)
    }
  }

  return (
    <>
      <Card className="flex flex-col gap-1">
        <h2 className="text-sm text-muted">{t('refill.medicine')}</h2>
        <p className="text-start text-base font-semibold">
          {/* Stored in English: it sits on the screen's own side and keeps its own order. */}
          <bdi dir="auto" data-testid="refill-medicine">
            {visit.refill?.medicine ?? t('refill.usualMedicine')}
          </bdi>
        </p>
      </Card>
      <p className="text-base">{t('refill.body')}</p>
      <Button data-testid="refill-message" className="w-full" onClick={() => setNoticed(true)}>
        {t('refill.message')}
      </Button>
      {noticed && <Notice>{t('refill.notice')}</Notice>}
      {error !== null && (
        <ErrorBlock message={errorText(error, t, lang)} onRetry={() => void wantVisit()} />
      )}
      <Button
        data-testid="refill-visit"
        variant="secondary"
        className="w-full"
        loading={busy}
        onClick={() => void wantVisit()}
      >
        {t('refill.visit')}
      </Button>
    </>
  )
}

export default function Refill() {
  const { id = '' } = useParams()
  const { t } = useI18n()
  return (
    <VisitGate id={id} screen="refill">
      {(visit, refetch) => (
        <PatientShell title={t('refill.title')} back="/home">
          <RefillScreen visit={visit} refetch={refetch} />
        </PatientShell>
      )}
    </VisitGate>
  )
}
