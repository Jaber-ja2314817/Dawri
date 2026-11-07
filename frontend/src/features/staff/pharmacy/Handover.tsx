import { useCallback, useState } from 'react'
import { errorText } from '../../../api/client'
import { dispensed, visitDrugs } from '../../../api/staff'
import type {
  AllergyWarning,
  DispensedResponse,
  PrescriptionItem,
  StaffVisit,
} from '../../../api/staffTypes'
import { Button, Card, ErrorBlock, Ltr, Pill } from '../../../components/ui'
import { useI18n } from '../../../i18n'
import { useLive } from '../../../state/staff/useLive'

const DASH = '—'
const WARNINGS_POLL_MS = 20_000

function Amount({ item }: { item: PrescriptionItem }) {
  const { t } = useI18n()
  const days = item.days
  return (
    <span data-testid="rx-amount" className="text-sm text-muted">
      <Ltr>{[item.dose, item.frequency].filter(Boolean).join(' · ') || DASH}</Ltr>
      {' · '}
      <Ltr>{days ?? DASH}</Ltr> {t(days === 1 ? 'pharmacy.day' : 'pharmacy.days')}
    </span>
  )
}

/** Shown, never a gate: the doctor acknowledged this one, and the pharmacist should see it too. */
function RowWarning({ warning }: { warning: AllergyWarning }) {
  const { t, lang } = useI18n()
  return (
    <p data-testid="rx-warning" className="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm">
      <Pill tone="negative">{t('doctor.allergy.pill')}</Pill>
      <span dir="auto" className="min-w-0 text-negative">
        {lang === 'ar' ? warning.text_ar : warning.text_en}
      </span>
    </p>
  )
}

interface HandoverProps {
  visit: StaffVisit
  visitId: string
  onSending: (sending: boolean) => void
  onDone: (result: DispensedResponse) => void
}

/** The lines are the server's fixed templates, in the language of this console. */
export function Handover({ visit, visitId, onSending, onDone }: HandoverProps) {
  const { t, lang } = useI18n()
  const [sending, setSending] = useState(false)
  const [failure, setFailure] = useState<unknown>(null)
  const medicines = visit.medicines[lang]
  const load = useCallback((signal: AbortSignal) => visitDrugs(visitId, { signal }), [visitId])
  const drugs = useLive({
    key: `drugs:${visitId}`,
    load,
    stream: null,
    pollMs: WARNINGS_POLL_MS,
  })
  const warningFor = (drugId: string) =>
    drugs.data?.find((drug) => drug.id === drugId)?.allergy_warning ?? null
  const warningsUnread = drugs.state === 'error' && drugs.data === null

  const hand = async () => {
    if (sending) return
    setSending(true)
    setFailure(null)
    onSending(true)
    try {
      onDone(await dispensed(visitId))
      // Stays busy: the page changes as soon as the queue reads again.
    } catch (cause) {
      onSending(false)
      setSending(false)
      setFailure(cause)
    }
  }

  return (
    <Card flush data-testid="handover" className="flex flex-col">
      <h2 className="px-4 pt-4 pb-2 text-base font-semibold">{t('pharmacy.title.handOver')}</h2>
      {visit.prescription.length === 0 ? (
        <p data-testid="rx-none" className="px-4 pb-4 text-sm text-muted">
          {t('pharmacy.none')}
        </p>
      ) : (
        <ul className="border-t border-rule">
          {visit.prescription.map((item, index) => {
            const medicine = medicines[index]
            const warning = warningFor(item.drug)
            return (
              <li
                key={item.id}
                data-testid="rx-row"
                data-drug={item.drug}
                className="flex min-h-11 flex-col gap-1 border-b border-rule px-4 py-2 last:border-b-0"
              >
                <div className="flex flex-wrap items-baseline justify-between gap-x-3">
                  <span data-testid="medicine-name" dir="auto" className="text-base font-medium">
                    {medicine?.name ?? item.drug}
                  </span>
                  <Amount item={item} />
                </div>
                <p data-testid="medicine-line" dir="auto" className="text-sm">
                  {medicine?.line ?? DASH}
                </p>
                {warning !== null && <RowWarning warning={warning} />}
              </li>
            )
          })}
        </ul>
      )}
      {warningsUnread && (
        <p data-testid="rx-warnings-unread" role="status" className="px-4 pt-3 text-sm text-warning">
          {t('pharmacy.warningsUnread')}
        </p>
      )}
      <div className="flex flex-col gap-3 border-t border-border p-4">
        {failure !== null && <ErrorBlock message={errorText(failure, t, lang)} />}
        <Button
          data-testid="dispensed"
          className="self-start"
          loading={sending}
          onClick={() => void hand()}
        >
          {t('pharmacy.dispensed')}
        </Button>
      </div>
    </Card>
  )
}

export default Handover
