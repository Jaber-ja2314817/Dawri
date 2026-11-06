import { useCallback, useEffect, useRef, useState } from 'react'
import { ApiError, errorText } from '../../../api/client'
import { confirmHandoff, draftHandoff } from '../../../api/staff'
import type {
  DoctorSuggestion,
  HandoffConfirmResponse,
  HandoffDraft as Draft,
} from '../../../api/staffTypes'
import { Button, Card, ErrorBlock, Ltr, Notice, Pill, Skeleton } from '../../../components/ui'
import { useI18n } from '../../../i18n'
import { useStaff } from '../../../state/staff/session'
import { CONTROL, TWO_COLUMNS } from './parts'

const TEXT_ROWS = 8
const TEXT_HEIGHT = 210 // Eight 24px lines, 8px padding each way and the 1px borders.
/* Grows with the text: on a phone the same draft wraps past eight lines, and the nurse signs all of it. */
const TEXT_FIT = 'min-h-[210px] [field-sizing:content]'
const TEXT_MAX = 4000

const isStale = (cause: unknown) =>
  cause instanceof ApiError && (cause.code === 'draft_required' || cause.code === 'draft_stale')

function DoctorOption({
  doctor,
  chosen,
  onPick,
}: {
  doctor: DoctorSuggestion
  chosen: boolean
  onPick: () => void
}) {
  const { t, lang } = useI18n()
  const { centreCounters } = useStaff()
  const counter = centreCounters.find((item) => item.id === doctor.counter_id)
  const room = lang === 'ar' && counter ? counter.label_ar : doctor.counter_label
  return (
    <label
      data-testid="doctor-option"
      data-doctor={doctor.doctor_id}
      className="flex min-h-11 cursor-pointer items-start gap-3 border-b border-rule py-3 last:border-b-0"
    >
      <input
        type="radio"
        name="doctor"
        data-testid={`doctor-${doctor.doctor_id}`}
        checked={chosen}
        className="mt-1 size-4 shrink-0 accent-ink"
        onChange={onPick}
      />
      <span className="flex min-w-0 flex-col gap-1">
        <span className="text-sm font-medium">{doctor.name}</span>
        <span className="text-sm text-muted">
          {room} · <Ltr>{doctor.waiting}</Ltr> {t('nurse.handoff.waiting')}
        </span>
        <span data-testid="doctor-reason" className="text-sm text-muted">
          {lang === 'ar' ? doctor.reason_ar : doctor.reason_en}
        </span>
      </span>
    </label>
  )
}

interface HandoffDraftFormProps {
  visitId: string
  onConfirmed: (result: HandoffConfirmResponse) => void
}

/** Mounts only for a visit that is ready, so a reload after confirm never draws a draft. */
export function HandoffDraftForm({ visitId, onConfirmed }: HandoffDraftFormProps) {
  const { t, lang } = useI18n()
  const [draft, setDraft] = useState<Draft | null>(null)
  const [drafting, setDrafting] = useState(true)
  const [text, setText] = useState('')
  const [doctorId, setDoctorId] = useState<string | null>(null)
  const [sending, setSending] = useState(false)
  const [failed, setFailed] = useState<unknown>(null)
  const [redrafted, setRedrafted] = useState(false)
  const [kept, setKept] = useState<string | null>(null)
  const asked = useRef(false)

  const write = useCallback(async () => {
    setDrafting(true)
    setFailed(null)
    try {
      const next = await draftHandoff(visitId).catch((cause: unknown) => {
        if (!isStale(cause)) throw cause
        setRedrafted(true)
        return draftHandoff(visitId) // An edit landed while the draft was being written.
      })
      setDraft(next)
      setText(next.text)
      setDoctorId((current) =>
        next.suggestions.some((doctor) => doctor.doctor_id === current)
          ? current
          : (next.suggestions[0]?.doctor_id ?? null),
      )
    } catch (cause) {
      setFailed(cause)
    } finally {
      setDrafting(false)
    }
  }, [visitId])

  useEffect(() => {
    if (asked.current) return
    asked.current = true
    void write()
  }, [write])

  const send = async () => {
    if (doctorId === null || sending) return
    setSending(true)
    setFailed(null)
    try {
      onConfirmed(await confirmHandoff(visitId, text, doctorId))
    } catch (cause) {
      if (isStale(cause)) {
        // Never a silent send: the nurse reads the new draft and confirms again.
        setKept(text)
        setRedrafted(true)
        await write()
      } else {
        setFailed(cause)
      }
      setSending(false)
    }
  }

  const blank = text.trim() === ''
  const suggestions = draft?.suggestions ?? []
  const fallback = suggestions.some((doctor) => doctor.clinic_fallback)
  const ready = draft !== null && !drafting

  return (
    <div className={TWO_COLUMNS}>
      <Card as="section" data-testid="handoff-draft" className="flex min-w-0 flex-col gap-3">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h2 className="text-base font-semibold">{t('nurse.handoff.text')}</h2>
          {ready && (
            <span
              data-testid="handoff-source"
              data-source={draft.source}
              className="inline-flex"
            >
              <Pill>{t(`nurse.handoff.source.${draft.source}`)}</Pill>
            </span>
          )}
        </div>
        {redrafted && <Notice data-testid="handoff-redrafted">{t('nurse.handoff.redrafted')}</Notice>}
        {drafting ? (
          <div data-testid="handoff-skeleton" aria-busy="true" className="flex flex-col gap-2">
            <Skeleton height={TEXT_HEIGHT} />
            <p role="status" className="text-sm text-muted">
              {t('nurse.handoff.drafting')}
            </p>
          </div>
        ) : (
          draft !== null && (
            <textarea
              data-testid="handoff-text"
              aria-label={t('nurse.handoff.text')}
              dir="ltr"
              rows={TEXT_ROWS}
              maxLength={TEXT_MAX}
              value={text}
              disabled={sending}
              onChange={(event) => setText(event.target.value)}
              className={`${CONTROL} py-2 ${TEXT_FIT}`}
            />
          )
        )}
        {kept !== null && (
          <div data-testid="handoff-kept" className="flex flex-col gap-1">
            <p className="text-sm font-medium">{t('nurse.handoff.kept')}</p>
            <p dir="ltr" className="text-sm break-words whitespace-pre-wrap text-muted">
              {kept}
            </p>
            <Button
              variant="secondary"
              data-testid="use-kept"
              disabled={drafting}
              className="self-start px-3 text-sm"
              onClick={() => setText(kept)}
            >
              {t('nurse.handoff.useKept')}
            </Button>
          </div>
        )}
        {ready && (
          <details data-testid="handoff-arabic" className="text-sm">
            <summary className="cursor-pointer py-3 font-medium">
              {t('nurse.handoff.arabic')}
            </summary>
            <div className="flex flex-col gap-2 pb-2">
              <p className="text-sm text-muted">{t('nurse.handoff.arabicNote')}</p>
              <p
                data-testid="handoff-text-ar"
                dir="rtl"
                lang="ar"
                className="break-words whitespace-pre-wrap"
              >
                {draft.text_ar}
              </p>
            </div>
          </details>
        )}
        {failed !== null && draft === null && (
          <ErrorBlock message={errorText(failed, t, lang)} onRetry={() => void write()} />
        )}
      </Card>

      <Card as="section" data-testid="handoff-doctors" className="flex min-w-0 flex-col gap-3">
        <h2 className="text-base font-semibold">{t('nurse.handoff.doctors')}</h2>
        {drafting ? (
          <div className="flex flex-col gap-3">
            <Skeleton height={68} />
            <Skeleton height={68} />
          </div>
        ) : (
          draft !== null && (
            <>
              {fallback && (
                <Notice data-testid="clinic-fallback">{t('nurse.handoff.fallback')}</Notice>
              )}
              {suggestions.length === 0 ? (
                <p data-testid="no-doctors" className="text-sm text-muted">
                  {t('nurse.handoff.noDoctors')}
                </p>
              ) : (
                <div role="radiogroup" aria-label={t('nurse.handoff.doctors')} className="flex flex-col">
                  {suggestions.map((doctor) => (
                    <DoctorOption
                      key={doctor.doctor_id}
                      doctor={doctor}
                      chosen={doctor.doctor_id === doctorId}
                      onPick={() => setDoctorId(doctor.doctor_id)}
                    />
                  ))}
                </div>
              )}
            </>
          )
        )}
        {failed !== null && draft !== null && <ErrorBlock message={errorText(failed, t, lang)} />}
        <Button
          data-testid="handoff-confirm"
          disabled={!ready || blank || doctorId === null}
          loading={sending}
          className="w-full"
          onClick={() => void send()}
        >
          {t('nurse.handoff.confirm')}
        </Button>
        <p data-testid="handoff-unsent" className="text-sm text-muted">
          {t(blank && ready ? 'nurse.handoff.emptyText' : 'nurse.handoff.unsent')}
        </p>
      </Card>
    </div>
  )
}
