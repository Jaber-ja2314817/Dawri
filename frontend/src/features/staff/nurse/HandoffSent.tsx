import { useEffect, useState, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { errorText } from '../../../api/client'
import { demoStaff, fastForward } from '../../../api/staff'
import type { HandoffConfirmResponse, StaffVisit } from '../../../api/staffTypes'
import { Button, buttonClass, Card, ErrorBlock, Ltr } from '../../../components/ui'
import { useI18n } from '../../../i18n'
import { Dash, DASH, QUEUE_PATH, TWO_COLUMNS } from './parts'

/** The doctor's name, which a reload has only as an id. */
function useDoctorName(known: string | undefined, doctorId: string | null | undefined) {
  const [name, setName] = useState<string | null>(null)
  useEffect(() => {
    if (known !== undefined || !doctorId) return
    const controller = new AbortController()
    demoStaff({ signal: controller.signal })
      .then((people) => setName(people.find((one) => one.id === doctorId)?.name ?? null))
      .catch(() => undefined) // The name is a nicety here: the row prints a dash.
    return () => controller.abort()
  }, [known, doctorId])
  return known ?? name
}

function Fact({ label, testId, children }: { label: string; testId: string; children: ReactNode }) {
  return (
    <div className="grid grid-cols-[minmax(0,136px)_minmax(0,1fr)] gap-x-3 border-b border-rule py-2 last:border-b-0">
      <dt className="text-sm text-muted">{label}</dt>
      <dd data-testid={testId} className="min-w-0 text-sm">
        {children}
      </dd>
    </div>
  )
}

interface HandoffSentProps {
  visitId: string
  visit: StaffVisit
  confirmed: HandoffConfirmResponse | null
  refetch: () => Promise<void>
}

export function HandoffSent({ visitId, visit, confirmed, refetch }: HandoffSentProps) {
  const { t, lang } = useI18n()
  const [busy, setBusy] = useState(false)
  const [failed, setFailed] = useState<unknown>(null)
  const [skipped, setSkipped] = useState(false)
  const doctor = useDoctorName(confirmed?.doctor.name, visit.handoff?.chosen_doctor_id)

  const complete = skipped || visit.status === 'completed'
  const ticket = visit.ticket ?? confirmed?.ticket ?? null
  const room = ticket === null ? null : lang === 'ar' ? ticket.counter_ar : ticket.counter
  const atDoctor = visit.status !== 'in_pharmacy'
  const medicines = visit.medicines?.[lang] ?? []

  const skip = async () => {
    setBusy(true)
    setFailed(null)
    try {
      await fastForward(visitId)
      setSkipped(true)
      await refetch()
    } catch (cause) {
      setFailed(cause)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className={TWO_COLUMNS}>
      <Card as="section" data-testid="handoff-final" className="flex min-w-0 flex-col gap-3">
        <h2 className="text-base font-semibold">{t('nurse.sent.text')}</h2>
        <p
          data-testid="handoff-final-text"
          dir="ltr"
          className="text-sm break-words whitespace-pre-wrap"
        >
          {visit.handoff?.final_text ?? <Dash />}
        </p>
      </Card>

      {complete ? (
        <Card as="section" data-testid="visit-complete" className="flex min-w-0 flex-col gap-3">
          <h2 className="text-xl font-semibold">{t('nurse.sent.complete')}</h2>
          <p className="text-sm text-muted">{t('nurse.sent.completeBody')}</p>
          {medicines.length > 0 && (
            <div className="flex flex-col gap-1">
              <p className="text-sm font-medium">{t('nurse.sent.medicines')}</p>
              <ul className="flex flex-col gap-1">
                {medicines.map((medicine) => (
                  <li key={medicine.drug} dir="auto" className="text-sm">
                    {medicine.line}
                  </li>
                ))}
              </ul>
            </div>
          )}
          <Link to={QUEUE_PATH} data-testid="next-patient" className={buttonClass('primary', 'w-full')}>
            {t('nurse.sent.next')}
          </Link>
        </Card>
      ) : (
        <Card as="section" data-testid="handoff-sent" className="flex min-w-0 flex-col gap-3">
          <div className="flex flex-col gap-1">
            <h2 className="text-base font-semibold">{t('nurse.sent.title')}</h2>
            <p className="text-sm text-muted">{t('nurse.sent.number')}</p>
            <p data-testid="sent-number" className="text-2xl font-semibold text-data">
              <Ltr>{ticket?.number ?? DASH}</Ltr>
            </p>
          </div>
          <dl className="flex flex-col">
            <Fact label={t('nurse.sent.doctor')} testId="sent-doctor">
              {doctor ?? <Dash />}
            </Fact>
            <Fact label={t(atDoctor ? 'nurse.sent.room' : 'nurse.sent.now')} testId="sent-room">
              {room ?? <Dash />}
            </Fact>
          </dl>
          <Link to={QUEUE_PATH} data-testid="next-patient" className={buttonClass('primary', 'w-full')}>
            {t('nurse.sent.next')}
          </Link>
          <div className="flex flex-col gap-2 border-t border-rule pt-3">
            <Button
              variant="secondary"
              data-testid="fast-forward"
              loading={busy}
              className="w-full"
              onClick={() => void skip()}
            >
              {t('nurse.sent.fastForward')}
            </Button>
            <p className="text-sm text-muted">{t('nurse.sent.fastForwardNote')}</p>
            {failed !== null && <ErrorBlock message={errorText(failed, t, lang)} />}
          </div>
        </Card>
      )}
    </div>
  )
}
