import { useEffect, useState, type ReactNode } from 'react'
import { editIntake } from '../../../api/staff'
import { errorText } from '../../../api/client'
import type { StaffVisit } from '../../../api/staffTypes'
import type { Service } from '../../../api/types'
import { Button, Card, ErrorBlock, Field, Ltr, Pill } from '../../../components/ui'
import { useI18n } from '../../../i18n'
import { recordTerm } from '../../../i18n/record'
import { CONTROL, Dash, TextBox } from './parts'
import { hasUnsavedEdit, intakeChanges, intakeForm, SERVICES, type IntakeForm } from './intakeEdit'

const SUMMARY_MAX = 400
const COMPLAINT_MAX = 200

/**
 * Scripted text is never passed off as a model's. A real mode says nothing about this intake:
 * a turn can fall back to the script, and a walk-in is a template.
 */
const fromModel = ({ ai_mode: mode, intake_source: source }: StaffVisit) =>
  mode === 'real' && source === 'model'
const reasonLabel = (visit: StaffVisit) =>
  fromModel(visit) ? 'nurse.intake.reason' : 'nurse.intake.reasonScripted'
const summaryLabel = (visit: StaffVisit) =>
  fromModel(visit) ? 'nurse.intake.summary' : 'nurse.intake.summaryScripted'

function Row({ label, testId, children }: { label: string; testId?: string; children: ReactNode }) {
  return (
    <div className="grid grid-cols-[minmax(0,136px)_minmax(0,1fr)] gap-x-3 border-b border-rule py-2 last:border-b-0">
      <dt className="text-sm text-muted">{label}</dt>
      <dd data-testid={testId} className="min-w-0 text-sm break-words">
        {children}
      </dd>
    </div>
  )
}

function Text({ value }: { value: string | null | undefined }) {
  return value ? <span dir="auto">{value}</span> : <Dash />
}

function RedFlags({ visit }: { visit: StaffVisit }) {
  const { t, lang } = useI18n()
  if (visit.red_flags_raised.length > 0) {
    const labels = lang === 'ar' ? visit.red_flags_raised_ar : visit.red_flags_raised
    return (
      <span data-testid="flags-raised" className="flex flex-wrap gap-1">
        {labels.map((label) => (
          <Pill key={label} tone="negative">
            {label}
          </Pill>
        ))}
      </span>
    )
  }
  const denied = lang === 'ar' ? visit.denied_text_ar : visit.denied_text_en
  if (denied) return <span data-testid="denied">{denied}</span>
  return <span data-testid="no-flags">{t('nurse.intake.noneDetected')}</span>
}

function ReadView({ visit }: { visit: StaffVisit }) {
  const { t, lang } = useI18n()
  const { intake, patient } = visit
  const list = (values: string[] | undefined) =>
    values && values.length > 0 ? values.join(lang === 'ar' ? '، ' : ', ') : null
  const chronic = patient.chronic.map((term) => recordTerm(term, lang))
  const severity = intake?.severity_0_10 ?? null
  return (
    <dl className="flex flex-col">
      <Row label={t(reasonLabel(visit))} testId="intake-reason">
        <Text value={intake?.chief_complaint} />
      </Row>
      <Row label={t('nurse.intake.duration')} testId="intake-duration">
        <Text value={intake?.duration} />
      </Row>
      <Row label={t('nurse.intake.severity')} testId="intake-severity">
        {severity === null ? <Dash /> : <Ltr>{severity}/10</Ltr>}
      </Row>
      <Row label={t('nurse.intake.associated')}>
        <Text value={list(intake?.associated)} />
      </Row>
      <Row label={t('nurse.intake.medicines')}>
        <Text value={list(intake?.self_medication)} />
      </Row>
      <Row label={t('nurse.intake.allergies')} testId="intake-allergies">
        {patient.allergies.length === 0 ? (
          t('queue.noAllergies')
        ) : (
          <span className="flex flex-wrap gap-1">
            {patient.allergies.map((allergy) => (
              <span key={allergy} data-testid="allergy-flag" className="inline-flex">
                <Pill tone="negative">{recordTerm(allergy, lang)}</Pill>
              </span>
            ))}
          </span>
        )}
      </Row>
      <Row label={t('nurse.intake.chronic')}>
        <Text value={list(chronic)} />
      </Row>
      <Row label={t('nurse.intake.redFlags')} testId="intake-red-flags">
        <RedFlags visit={visit} />
      </Row>
      <Row label={t('nurse.intake.service')} testId="intake-service">
        {visit.service ? t(`service.${visit.service}`) : <Dash />}
      </Row>
      <Row label={t('nurse.intake.concerns')}>
        <Text value={intake?.patient_concerns} />
      </Row>
      <Row label={t(summaryLabel(visit))} testId="ai-summary">
        <Text value={intake?.summary_for_nurse} />
      </Row>
    </dl>
  )
}

interface EditViewProps {
  visitId: string
  visit: StaffVisit
  onCancel: () => void
  onSaved: (draftCleared: boolean) => void
  onUnsaved?: (unsaved: boolean) => void
}

function EditView({ visitId, visit, onCancel, onSaved, onUnsaved }: EditViewProps) {
  const { t, lang } = useI18n()
  const [before] = useState(() => intakeForm(visit.intake!, visit.service))
  const [form, setForm] = useState<IntakeForm>(before)
  const [busy, setBusy] = useState(false)
  const [failed, setFailed] = useState<unknown>(null)
  const [severityError, setSeverityError] = useState(false)
  const unsaved = hasUnsavedEdit(before, form)

  useEffect(() => {
    onUnsaved?.(unsaved)
    return () => onUnsaved?.(false)
  }, [unsaved, onUnsaved])

  const set = <K extends keyof IntakeForm>(key: K, value: IntakeForm[K]) =>
    setForm((current) => ({ ...current, [key]: value }))

  const save = async () => {
    setFailed(null)
    const changes = intakeChanges(before, form)
    setSeverityError(changes === undefined)
    if (changes === undefined) return
    if (Object.keys(changes).length === 0) {
      onCancel()
      return
    }
    setBusy(true)
    try {
      const result = await editIntake(visitId, changes)
      onSaved(result.draft_cleared)
    } catch (cause) {
      setFailed(cause)
      setBusy(false)
    }
  }

  return (
    <form
      data-testid="intake-form"
      className="flex flex-col gap-3"
      onSubmit={(event) => {
        event.preventDefault()
        void save()
      }}
    >
      <Field
        data-testid="edit-chief_complaint"
        label={t(reasonLabel(visit))}
        dir="auto"
        maxLength={COMPLAINT_MAX}
        value={form.chief_complaint}
        onChange={(event) => set('chief_complaint', event.target.value)}
      />
      <div className="grid grid-cols-2 gap-3">
        <Field
          data-testid="edit-duration"
          label={t('nurse.intake.duration')}
          dir="auto"
          value={form.duration}
          onChange={(event) => set('duration', event.target.value)}
        />
        <Field
          data-testid="edit-severity_0_10"
          label={t('nurse.intake.severityInput')}
          dir="ltr"
          inputMode="numeric"
          value={form.severity_0_10}
          error={severityError ? t('nurse.intake.severityError') : null}
          onChange={(event) => set('severity_0_10', event.target.value)}
        />
      </div>
      <Field
        data-testid="edit-associated"
        label={t('nurse.intake.associated')}
        hint={t('nurse.intake.listHint')}
        dir="auto"
        value={form.associated}
        onChange={(event) => set('associated', event.target.value)}
      />
      <Field
        data-testid="edit-self_medication"
        label={t('nurse.intake.medicines')}
        hint={t('nurse.intake.listHint')}
        dir="auto"
        value={form.self_medication}
        onChange={(event) => set('self_medication', event.target.value)}
      />
      <label className="flex flex-col gap-2">
        <span className="text-sm font-medium">{t('nurse.intake.service')}</span>
        <select
          data-testid="edit-service"
          value={form.service}
          onChange={(event) => set('service', event.target.value as Service)}
          className={CONTROL}
        >
          {SERVICES.map((service) => (
            <option key={service} value={service}>
              {t(`service.${service}`)}
            </option>
          ))}
        </select>
      </label>
      <TextBox
        data-testid="edit-summary_for_nurse"
        label={t(summaryLabel(visit))}
        dir="auto"
        rows={3}
        maxLength={SUMMARY_MAX}
        value={form.summary_for_nurse}
        onChange={(event) => set('summary_for_nurse', event.target.value)}
      />
      <TextBox
        data-testid="edit-patient_concerns"
        label={t('nurse.intake.concerns')}
        dir="auto"
        rows={2}
        value={form.patient_concerns}
        onChange={(event) => set('patient_concerns', event.target.value)}
      />
      {failed !== null && <ErrorBlock message={errorText(failed, t, lang)} />}
      <div className="flex flex-wrap items-center justify-end gap-2">
        <Button variant="quiet" disabled={busy} data-testid="intake-cancel" onClick={onCancel}>
          {t('nurse.intake.cancel')}
        </Button>
        <Button type="submit" variant="secondary" loading={busy} data-testid="intake-save">
          {t('nurse.intake.save')}
        </Button>
      </div>
    </form>
  )
}

interface IntakeCardProps {
  visitId: string
  visit: StaffVisit
  editable: boolean
  refetch: () => Promise<void>
  /** Told while the edit form holds changes that are not saved. */
  onUnsaved?: (unsaved: boolean) => void
}

/** Every AI output shown to staff can be edited, and the nurse confirms it at the next step. */
export function IntakeCard({ visitId, visit, editable, refetch, onUnsaved }: IntakeCardProps) {
  const { t } = useI18n()
  const [editing, setEditing] = useState(false)
  const [draftCleared, setDraftCleared] = useState(false)
  const canEdit = editable && visit.intake !== null
  return (
    <Card as="section" data-testid="intake-card" className="flex min-w-0 flex-col gap-2">
      <div className="flex min-h-11 flex-wrap items-center gap-x-3 gap-y-1">
        <h2 className="text-base font-semibold">{t('nurse.intake.title')}</h2>
        {visit.edited && (
          <span data-testid="edited-pill" className="inline-flex">
            <Pill>{t('nurse.intake.edited')}</Pill>
          </span>
        )}
        <span className="flex-1" />
        {canEdit && !editing && (
          <Button
            variant="secondary"
            data-testid="intake-edit"
            className="px-3 text-sm"
            onClick={() => {
              setDraftCleared(false)
              setEditing(true)
            }}
          >
            {t('nurse.intake.edit')}
          </Button>
        )}
      </div>
      {draftCleared && (
        <p data-testid="draft-cleared" role="status" className="text-sm text-muted">
          {t('nurse.intake.draftCleared')}
        </p>
      )}
      {editing && canEdit ? (
        <EditView
          visitId={visitId}
          visit={visit}
          onCancel={() => setEditing(false)}
          onUnsaved={onUnsaved}
          onSaved={(cleared) => {
            setDraftCleared(cleared)
            setEditing(false)
            void refetch()
          }}
        />
      ) : (
        <ReadView visit={visit} />
      )}
      {!editing && visit.intake === null && (
        <p className="text-sm text-muted">{t('nurse.intake.none')}</p>
      )}
    </Card>
  )
}

