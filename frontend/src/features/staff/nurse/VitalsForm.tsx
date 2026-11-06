import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { errorText } from '../../../api/client'
import { recordVitals } from '../../../api/staff'
import type { StaffVisit, Urgency } from '../../../api/staffTypes'
import { Button, Card, ErrorBlock, Field, Notice } from '../../../components/ui'
import { useI18n } from '../../../i18n'
import { handoffPath, QUEUE_PATH, QuietLink } from './parts'
import {
  parseVitals,
  VITAL_FIELDS,
  VITAL_RULES,
  vitalsFrom,
  vitalsGate,
  type VitalError,
  type VitalField,
  type VitalValues,
} from './vitals'

const URGENCIES: Urgency[] = ['routine', 'soon', 'urgent']

interface VitalsFormProps {
  visitId: string
  visit: StaffVisit
  onEscalated: () => void
}

export function VitalsForm({ visitId, visit, onEscalated }: VitalsFormProps) {
  const { t, lang } = useI18n()
  const navigate = useNavigate()
  const [values, setValues] = useState<VitalValues>(() => vitalsFrom(visit.vitals))
  const [urgency, setUrgency] = useState<Urgency | null>(null)
  const [touched, setTouched] = useState<Partial<Record<VitalField, boolean>>>({})
  const [armed, setArmed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [failed, setFailed] = useState<unknown>(null)

  const inTriage = visit.status === 'in_triage'
  const atCounter = visit.ticket?.state === 'called' || visit.ticket?.state === 'serving'
  const gate = vitalsGate({ inTriage, atCounter, urgency })
  const open = inTriage && atCounter
  const { values: readings, errors } = parseVitals(values)

  const message = (field: VitalField, error: VitalError | undefined) => {
    if (error === undefined || !touched[field]) return null
    const { min, max } = VITAL_RULES[field]
    return t(`nurse.vitals.error.${error}`, { min, max })
  }

  const submit = async () => {
    if (gate !== null || urgency === null || busy) return
    if (Object.keys(errors).length > 0) {
      setTouched(Object.fromEntries(VITAL_FIELDS.map((field) => [field, true])))
      setArmed(false)
      return
    }
    if (urgency === 'urgent' && !armed) {
      setArmed(true)
      return
    }
    setBusy(true)
    setFailed(null)
    try {
      const result = await recordVitals(visitId, { ...readings, urgency })
      if (result.escalated) {
        onEscalated()
      } else {
        navigate(handoffPath(visitId))
      }
    } catch (cause) {
      setFailed(cause)
      setArmed(false)
      setBusy(false)
    }
  }

  const primary =
    urgency !== 'urgent'
      ? t('nurse.vitals.confirm')
      : armed
        ? t('nurse.vitals.sendEdAgain')
        : t('nurse.vitals.sendEd')

  return (
    <Card as="section" data-testid="vitals-card" className="flex min-w-0 flex-col gap-3">
      <h2 className="flex min-h-11 items-center text-base font-semibold">
        {t('nurse.vitals.title')}
      </h2>
      {gate === 'locked' && (
        <div data-testid="visit-locked" className="flex flex-col gap-1">
          <Notice>{t('nurse.visit.locked')}</Notice>
          <QuietLink to={QUEUE_PATH}>{t('nurse.visit.back')}</QuietLink>
        </div>
      )}
      {gate === 'not-called' && (
        <div data-testid="not-called" className="flex flex-col gap-1">
          <Notice>
            <strong className="font-medium">{t('nurse.visit.callFirst')}</strong>{' '}
            {t('nurse.visit.callFirstBody')}
          </Notice>
          <QuietLink to={QUEUE_PATH}>{t('nurse.visit.back')}</QuietLink>
        </div>
      )}
      <form
        data-testid="vitals-form"
        className="flex flex-col gap-3"
        onSubmit={(event) => {
          event.preventDefault()
          void submit()
        }}
      >
        <fieldset disabled={!open || busy} className="contents">
          <div className="grid grid-cols-2 gap-3">
            {VITAL_FIELDS.map((field) => (
              <Field
                key={field}
                data-testid={`vital-${field}`}
                label={t(`nurse.vitals.${field}`)}
                dir="ltr"
                inputMode={VITAL_RULES[field].whole ? 'numeric' : 'decimal'}
                autoComplete="off"
                value={values[field]}
                error={message(field, errors[field])}
                onBlur={() => setTouched((current) => ({ ...current, [field]: true }))}
                onChange={(event) =>
                  setValues((current) => ({ ...current, [field]: event.target.value }))
                }
              />
            ))}
          </div>
          <div role="radiogroup" aria-labelledby="urgency-label" className="flex flex-col gap-1">
            <span id="urgency-label" className="text-sm font-medium">
              {t('nurse.vitals.urgency')}
            </span>
            <div className="flex flex-wrap gap-x-4">
              {URGENCIES.map((option) => (
                <label
                  key={option}
                  className="flex min-h-11 cursor-pointer items-center gap-2 text-sm whitespace-nowrap"
                >
                  <input
                    type="radio"
                    name="urgency"
                    value={option}
                    data-testid={`urgency-${option}`}
                    checked={urgency === option}
                    className="size-4 accent-ink"
                    onChange={() => {
                      setUrgency(option)
                      setArmed(false)
                    }}
                  />
                  {t(`nurse.vitals.urgency.${option}`)}
                </label>
              ))}
            </div>
            {visit.vitals !== null && (
              <p data-testid="urgency-earlier" className="text-sm text-muted">
                {t('nurse.vitals.earlier')} {t(`nurse.vitals.urgency.${visit.vitals.urgency}`)}
              </p>
            )}
          </div>
          {armed && (
            <p data-testid="ed-warning" role="status" className="text-sm text-warning">
              {t('nurse.vitals.sendEdWarning')}
            </p>
          )}
          {failed !== null && <ErrorBlock message={errorText(failed, t, lang)} />}
          <div className="flex flex-col gap-2">
            <Button
              type="submit"
              data-testid="vitals-submit"
              data-armed={armed}
              disabled={gate !== null}
              loading={busy}
              className="w-full"
            >
              {primary}
            </Button>
            {armed && (
              <Button
                variant="secondary"
                data-testid="ed-cancel"
                className="w-full"
                onClick={() => setArmed(false)}
              >
                {t('nurse.vitals.keep')}
              </Button>
            )}
            {gate === 'no-urgency' && (
              <p data-testid="urgency-hint" className="text-sm text-muted">
                {t('nurse.vitals.chooseUrgency')}
              </p>
            )}
          </div>
        </fieldset>
      </form>
      {open && visit.vitals !== null && (
        <QuietLink to={handoffPath(visitId)} testId="to-handoff">
          {t('nurse.visit.toHandoff')}
        </QuietLink>
      )}
    </Card>
  )
}

export function EmergencyResult() {
  const { t } = useI18n()
  return (
    <Card as="section" data-testid="sent-to-ed" className="flex min-w-0 flex-col gap-2">
      <h2 className="text-base font-semibold">{t('nurse.ed.title')}</h2>
      <p className="text-sm">{t('nurse.ed.body')}</p>
      <QuietLink to={QUEUE_PATH} testId="ed-back">
        {t('nurse.visit.back')}
      </QuietLink>
    </Card>
  )
}

