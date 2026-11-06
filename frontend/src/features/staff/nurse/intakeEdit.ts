import type { StaffIntake } from '../../../api/staffTypes'
import type { Service } from '../../../api/types'
import { latinDigits } from './vitals'

export const SERVICES: Service[] = [
  'gp',
  'dental',
  'refill',
  'vaccination',
  'lab_only',
  'womens_health',
  'mental_health',
  'other',
]

export interface IntakeForm {
  chief_complaint: string
  duration: string
  severity_0_10: string
  associated: string
  self_medication: string
  service: Service
  summary_for_nurse: string
  patient_concerns: string
}

const toLine = (values: string[]) => values.join(', ')
const toList = (text: string) =>
  text
    .split(/[,،\n]/)
    .map((item) => item.trim())
    .filter((item) => item !== '')

export function intakeForm(intake: StaffIntake, shownService: Service | null): IntakeForm {
  return {
    chief_complaint: intake.chief_complaint,
    duration: intake.duration ?? '',
    severity_0_10: intake.severity_0_10 === null ? '' : String(intake.severity_0_10),
    associated: toLine(intake.associated),
    self_medication: toLine(intake.self_medication),
    service: shownService ?? intake.service,
    summary_for_nurse: intake.summary_for_nurse,
    patient_concerns: intake.patient_concerns ?? '',
  }
}

/** A whole number from 0 to 10, in either script. Empty is null. Undefined is not valid. */
export function parseSeverity(raw: string): number | null | undefined {
  const text = latinDigits(raw)
  if (text === '') return null
  if (!/^\d+$/.test(text)) return undefined
  const value = Number(text)
  return value <= 10 ? value : undefined
}

export type IntakeChanges = Record<string, unknown>

/** Only what the nurse changed, as the server's own types. Undefined when severity is invalid. */
export function intakeChanges(before: IntakeForm, after: IntakeForm): IntakeChanges | undefined {
  const fields: IntakeChanges = {}
  const moved = (key: keyof IntakeForm) => before[key].trim() !== after[key].trim()

  if (moved('chief_complaint')) fields.chief_complaint = after.chief_complaint.trim()
  if (moved('summary_for_nurse')) fields.summary_for_nurse = after.summary_for_nurse.trim()
  if (moved('duration')) fields.duration = after.duration.trim() || null
  if (moved('patient_concerns')) fields.patient_concerns = after.patient_concerns.trim() || null
  if (moved('associated')) fields.associated = toList(after.associated)
  if (moved('self_medication')) fields.self_medication = toList(after.self_medication)
  if (moved('service')) fields.service = after.service
  if (moved('severity_0_10')) {
    const severity = parseSeverity(after.severity_0_10)
    if (severity === undefined) return undefined
    fields.severity_0_10 = severity
  }
  return fields
}
