import { useEffect, useRef, useState, type FormEvent } from 'react'
import { errorText } from '../../../api/client'
import { demoPatients } from '../../../api/endpoints'
import type { DemoPatient } from '../../../api/types'
import { Button, Card, ErrorBlock, Field, Skeleton } from '../../../components/ui'
import { useI18n } from '../../../i18n'
import { nameOf } from '../../../lib/format'
import { cx } from '../../../lib/cx'
import { deskChips } from './chips'
import type { WalkInState } from './useWalkIn'

const COMPLAINT_MAX = 200

function useChips() {
  const [patients, setPatients] = useState<DemoPatient[] | null>(null)
  const [failed, setFailed] = useState(false)
  useEffect(() => {
    const controller = new AbortController()
    demoPatients({ signal: controller.signal })
      .then((list) => setPatients(deskChips(list)))
      .catch(() => {
        if (!controller.signal.aborted) setFailed(true)
      })
    return () => controller.abort()
  }, [])
  return { patients, failed }
}

/** Typed text stays in the fields on a refusal, so the clerk can correct one thing and resend. */
export function WalkInForm({ walkIn }: { walkIn: WalkInState }) {
  const { t, lang } = useI18n()
  const { patients, failed } = useChips()
  const [qid, setQid] = useState('')
  const [complaint, setComplaint] = useState('')
  const form = useRef<HTMLFormElement>(null)
  const ready = qid.trim() !== '' && complaint.trim() !== ''

  const pick = (patient: DemoPatient) => {
    setQid(patient.qid_demo)
    form.current?.querySelector<HTMLInputElement>('[name=complaint]')?.focus()
  }

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (!ready) return
    if (await walkIn.submit(qid.trim(), complaint.trim())) {
      setQid('')
      setComplaint('')
    }
  }

  return (
    <Card as="section" aria-labelledby="walk-in-title" className="flex flex-col gap-3">
      <h2 id="walk-in-title" className="text-base font-medium">
        {t('desk.form.title')}
      </h2>
      <div className="flex flex-col gap-2">
        <p className="text-sm font-medium">{t('desk.chips')}</p>
        {patients === null && !failed && <Skeleton height={44} />}
        {failed && (
          <p data-testid="desk-chips-failed" className="text-sm text-muted">
            {t('desk.chipsFailed')}
          </p>
        )}
        {patients !== null && (
          <div data-testid="desk-chips" className="flex flex-wrap gap-2">
            {patients.map((patient) => (
              <Button
                key={patient.id}
                variant="secondary"
                data-testid={`desk-chip-${patient.id}`}
                aria-pressed={qid === patient.qid_demo}
                disabled={walkIn.busy}
                className={cx('px-3 text-sm', qid === patient.qid_demo && 'border-ink')}
                onClick={() => pick(patient)}
              >
                {nameOf(patient, lang)}
              </Button>
            ))}
          </div>
        )}
      </div>
      <form ref={form} onSubmit={(event) => void submit(event)} noValidate className="flex flex-col gap-3">
        <Field
          label={t('desk.qid')}
          name="qid"
          dir="ltr"
          data-testid="desk-qid"
          autoCapitalize="characters"
          autoComplete="off"
          spellCheck={false}
          value={qid}
          onChange={(event) => setQid(event.target.value)}
        />
        <Field
          label={t('desk.complaint')}
          hint={t('desk.complaintHint')}
          name="complaint"
          dir="auto"
          data-testid="desk-complaint"
          autoComplete="off"
          maxLength={COMPLAINT_MAX}
          value={complaint}
          onChange={(event) => setComplaint(event.target.value)}
        />
        {walkIn.error !== null && (
          <div data-testid="desk-error">
            <ErrorBlock message={errorText(walkIn.error, t, lang)} />
          </div>
        )}
        <Button
          type="submit"
          data-testid="desk-submit"
          loading={walkIn.busy}
          disabled={!ready}
          className="self-start"
        >
          {t('desk.submit')}
        </Button>
      </form>
    </Card>
  )
}
