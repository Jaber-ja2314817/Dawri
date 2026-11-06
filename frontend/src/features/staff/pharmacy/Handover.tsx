import { useState } from 'react'
import { errorText } from '../../../api/client'
import { dispensed } from '../../../api/staff'
import type { DispensedResponse, PrescriptionItem, StaffVisit } from '../../../api/staffTypes'
import { Button, Card, ErrorBlock, Ltr } from '../../../components/ui'
import { useI18n } from '../../../i18n'

const DASH = '—'

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
              </li>
            )
          })}
        </ul>
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
