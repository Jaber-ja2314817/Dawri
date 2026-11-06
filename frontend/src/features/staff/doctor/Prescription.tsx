import { useCallback, useState } from 'react'
import { ApiError, errorText } from '../../../api/client'
import { consultDone, visitDrugs } from '../../../api/staff'
import type { ConsultDoneResponse, VisitDrug } from '../../../api/staffTypes'
import { Button, Card, ErrorBlock, Field, Pill, Skeleton } from '../../../components/ui'
import { useI18n } from '../../../i18n'
import { useLive } from '../../../state/staff/useLive'
import {
  conflictsFrom,
  consultBody,
  doneGate,
  lineFrom,
  MAX_DAYS,
  MIN_DAYS,
  parseDays,
  warnedKey,
  type AllergyConflict,
  type RxLine,
} from './gate'

const DRUG_ROWS = 9
const DRUGS_POLL_MS = 60_000
const DOSE_MAX = 100
const NOTES_MAX = 500
const BOX = 'size-5 shrink-0 cursor-pointer accent-ink'

const capitalised = (name: string) => name.charAt(0).toUpperCase() + name.slice(1)

function LineFields({
  drugId,
  line,
  onChange,
}: {
  drugId: string
  line: RxLine
  onChange: (next: RxLine) => void
}) {
  const { t } = useI18n()
  const badDays = parseDays(line.days) === null
  return (
    <div className="grid grid-cols-2 gap-3 px-4 pb-4 sm:grid-cols-[minmax(0,1fr)_112px_minmax(0,1.6fr)]">
      <Field
        label={t('doctor.rx.dose')}
        data-testid={`rx-dose-${drugId}`}
        dir="ltr"
        maxLength={DOSE_MAX}
        value={line.dose}
        error={line.dose.trim() === '' ? t('doctor.rx.required') : null}
        onChange={(event) => onChange({ ...line, dose: event.target.value })}
      />
      <Field
        label={t('doctor.rx.days')}
        data-testid={`rx-days-${drugId}`}
        dir="ltr"
        inputMode="numeric"
        maxLength={3}
        value={line.days}
        error={badDays ? t('doctor.rx.badDays', { min: MIN_DAYS, max: MAX_DAYS }) : null}
        onChange={(event) => onChange({ ...line, days: event.target.value })}
      />
      <Field
        label={t('doctor.rx.frequency')}
        data-testid={`rx-frequency-${drugId}`}
        dir="ltr"
        className="max-sm:col-span-2"
        maxLength={DOSE_MAX}
        value={line.frequency}
        error={line.frequency.trim() === '' ? t('doctor.rx.required') : null}
        onChange={(event) => onChange({ ...line, frequency: event.target.value })}
      />
      <Field
        label={t('doctor.rx.notes')}
        data-testid={`rx-notes-${drugId}`}
        dir="auto"
        className="col-span-full"
        maxLength={NOTES_MAX}
        value={line.notes}
        onChange={(event) => onChange({ ...line, notes: event.target.value })}
      />
    </div>
  )
}

function DrugRow({
  drug,
  line,
  onToggle,
  onChange,
}: {
  drug: VisitDrug
  line: RxLine | undefined
  onToggle: () => void
  onChange: (next: RxLine) => void
}) {
  const { t, lang } = useI18n()
  const warning = drug.allergy_warning
  const form = t(`doctor.form.${drug.form}`)
  return (
    <li
      data-testid={`drug-row-${drug.id}`}
      data-selected={line !== undefined}
      className="border-b border-rule last:border-b-0"
    >
      <label className="flex min-h-11 cursor-pointer items-center gap-3 px-4 py-2">
        <input
          type="checkbox"
          data-testid={`drug-${drug.id}`}
          checked={line !== undefined}
          onChange={onToggle}
          className={BOX}
        />
        <span className="min-w-0 flex-1 text-sm font-medium [overflow-wrap:anywhere]">
          {lang === 'ar' ? drug.name_ar : capitalised(drug.name_en)}
        </span>
        <span className="shrink-0 text-sm text-muted">
          {form === `doctor.form.${drug.form}` ? drug.form : form}
        </span>
      </label>
      {warning !== null && (
        <p
          data-testid={`allergy-warning-${drug.id}`}
          className="flex flex-wrap items-center gap-x-2 gap-y-1 px-4 pb-2 text-sm"
        >
          <Pill tone="negative">{t('doctor.allergy.pill')}</Pill>
          <span className="min-w-0 text-negative">
            {lang === 'ar' ? warning.text_ar : warning.text_en}
          </span>
        </p>
      )}
      {line !== undefined && <LineFields drugId={drug.id} line={line} onChange={onChange} />}
    </li>
  )
}

interface PrescriptionProps {
  visitId: string
  /** True before the request leaves, and false again if it failed. */
  onSending: (sending: boolean) => void
  onDone: (result: ConsultDoneResponse) => void
}

/** Judged on the visit patient's own record, by the server. Nothing here starts selected. */
export function Prescription({ visitId, onSending, onDone }: PrescriptionProps) {
  const { t, lang } = useI18n()
  const load = useCallback((signal: AbortSignal) => visitDrugs(visitId, { signal }), [visitId])
  const drugs = useLive({
    key: `drugs:${visitId}`,
    load,
    stream: null,
    pollMs: DRUGS_POLL_MS,
  })

  const [chosen, setChosen] = useState<Record<string, RxLine>>({})
  const [ackedFor, setAckedFor] = useState<string | null>(null)
  const [emptyArmed, setEmptyArmed] = useState(false)
  const [conflicts, setConflicts] = useState<AllergyConflict[]>([])
  const [sending, setSending] = useState(false)
  const [failure, setFailure] = useState<unknown>(null)

  const list = drugs.data ?? []
  const lines = Object.values(chosen)
  const live = conflicts.filter((conflict) => chosen[conflict.drug_id] !== undefined)
  const warned = lines
    .filter(
      (line) =>
        list.find((drug) => drug.id === line.drugId)?.allergy_warning ||
        live.some((conflict) => conflict.drug_id === line.drugId),
    )
    .map((line) => line.drugId)
  // The tick covers these medicines only, so a change of them asks the doctor again.
  const key = warnedKey(warned)
  const acknowledged = warned.length > 0 && ackedFor === key
  const gate = doneGate({ lines, warned, acknowledged, emptyConfirmed: emptyArmed })
  const ready = drugs.data !== null

  const toggle = (drug: VisitDrug) => {
    setFailure(null)
    setEmptyArmed(false)
    setChosen((current) => {
      const { [drug.id]: removed, ...rest } = current
      return removed === undefined ? { ...current, [drug.id]: lineFrom(drug) } : rest
    })
  }

  const send = async () => {
    if (!gate.canSend || sending) return
    setSending(true)
    setFailure(null)
    onSending(true)
    try {
      onDone(await consultDone(visitId, consultBody(lines, acknowledged)))
      // Stays busy: the page changes as soon as the queue reads again.
    } catch (cause) {
      onSending(false)
      setSending(false)
      setEmptyArmed(false)
      setFailure(cause)
      if (cause instanceof ApiError && cause.code === 'allergy_conflict') {
        setConflicts(conflictsFrom(cause.extra))
      }
    }
  }

  return (
    <Card flush data-testid="prescription" className="flex flex-col">
      <div className="px-4 pt-4 pb-2">
        <h2 className="text-base font-semibold">{t('doctor.rx.title')}</h2>
        <p className="text-sm text-muted">{t('doctor.rx.help')}</p>
      </div>

      {drugs.state === 'error' && drugs.data === null && (
        <div className="px-4 pb-4">
          <ErrorBlock
            message={errorText(drugs.error, t, lang)}
            onRetry={() => void drugs.refetch()}
          />
        </div>
      )}
      {drugs.state === 'loading' && (
        <div className="flex flex-col gap-1 px-4 pb-4" data-testid="drugs-loading">
          {Array.from({ length: DRUG_ROWS }, (_, index) => (
            <Skeleton key={index} height={40} />
          ))}
        </div>
      )}
      {ready && (
        <ul className="border-t border-rule">
          {list.map((drug) => (
            <DrugRow
              key={drug.id}
              drug={drug}
              line={chosen[drug.id]}
              onToggle={() => toggle(drug)}
              onChange={(next) => setChosen((current) => ({ ...current, [drug.id]: next }))}
            />
          ))}
        </ul>
      )}

      {ready && (
        <div className="flex flex-col gap-3 border-t border-border p-4">
          {failure !== null && <ErrorBlock message={errorText(failure, t, lang)} />}
          {live.length > 0 && (
            <ul data-testid="allergy-conflicts" className="flex flex-col gap-1 text-sm">
              {live.map((conflict) => (
                <li key={conflict.drug_id} className="text-negative">
                  {lang === 'ar' ? conflict.text_ar : conflict.text_en}
                </li>
              ))}
            </ul>
          )}
          {gate.needsAck && (
            <label className="flex min-h-11 cursor-pointer items-center gap-3 text-sm font-medium">
              <input
                type="checkbox"
                data-testid="ack-allergy"
                checked={acknowledged}
                onChange={(event) => setAckedFor(event.target.checked ? key : null)}
                className={BOX}
              />
              {t('doctor.ack')}
            </label>
          )}
          {gate.blockedBy === 'details' && (
            <p data-testid="done-why" className="text-sm text-muted">
              {t('doctor.done.details')}
            </p>
          )}
          {gate.blockedBy === 'allergy' && (
            <p data-testid="done-why" className="text-sm text-muted">
              {t('doctor.done.allergy')}
            </p>
          )}

          {lines.length === 0 && emptyArmed ? (
            <>
              <p data-testid="done-empty-note" role="status" className="text-sm font-medium">
                {t('doctor.done.emptyNote')}
              </p>
              <div className="flex flex-wrap gap-2">
                <Button
                  variant="secondary"
                  data-testid="done-empty-cancel"
                  disabled={sending}
                  onClick={() => setEmptyArmed(false)}
                >
                  {t('doctor.done.keepPrescribing')}
                </Button>
                <Button
                  data-testid="done-empty-confirm"
                  loading={sending}
                  onClick={() => void send()}
                >
                  {t('doctor.done.emptyConfirm')}
                </Button>
              </div>
            </>
          ) : (
            <Button
              data-testid="consult-done"
              className="self-start"
              loading={sending}
              disabled={lines.length > 0 && !gate.canSend}
              onClick={() => (lines.length === 0 ? setEmptyArmed(true) : void send())}
            >
              {t(lines.length === 0 ? 'doctor.done.empty' : 'doctor.done')}
            </Button>
          )}
        </div>
      )}
    </Card>
  )
}

export default Prescription
