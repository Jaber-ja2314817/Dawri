import type { ConsultDoneBody, VisitDrug } from '../../../api/staffTypes'

/* The picker's rules, with no screen in them. Medicines come from the doctor, never the app. */

export const MIN_DAYS = 1
export const MAX_DAYS = 365

/** One chosen medicine as typed. Days stay text until they are sent. */
export interface RxLine {
  drugId: string
  dose: string
  frequency: string
  days: string
  notes: string
}

/** Prefilled from the drug's defaults. `demo_default` plays no part in this screen. */
export function lineFrom(drug: VisitDrug): RxLine {
  return {
    drugId: drug.id,
    dose: drug.default_dose ?? '',
    frequency: drug.default_frequency ?? '',
    days: drug.default_days === null ? '' : String(drug.default_days),
    notes: '',
  }
}

const ARABIC_ZERO = 0x0660

/** A whole number from 1 to 365, or null. Arabic digits count, since a doctor may type them. */
export function parseDays(text: string): number | null {
  const digits = text
    .trim()
    .replace(/[٠-٩]/g, (digit) => String(digit.charCodeAt(0) - ARABIC_ZERO))
  if (!/^\d{1,3}$/.test(digits)) return null
  const days = Number(digits)
  return days >= MIN_DAYS && days <= MAX_DAYS ? days : null
}

/* The server fills a blank dose with the default, which would not be what the screen showed. */
const lineComplete = (line: RxLine) =>
  line.dose.trim() !== '' && line.frequency.trim() !== '' && parseDays(line.days) !== null

export type DoneBlock = 'details' | 'allergy' | 'second-tap'

export interface DoneGate {
  /** Whether a tap may send the consultation. */
  canSend: boolean
  /** A chosen medicine carries an allergy warning, so the acknowledge box shows. */
  needsAck: boolean
  /** What still stands in the way, for the sentence under the button. */
  blockedBy: DoneBlock | null
}

export interface DoneGateInput {
  lines: RxLine[]
  /** Ids of the chosen medicines that carry a warning. */
  warned: string[]
  /** The acknowledge box, for the medicines warned now. */
  acknowledged: boolean
  /** No medicine chosen, and the doctor gave the second tap. */
  emptyConfirmed: boolean
}

export function doneGate({ lines, warned, acknowledged, emptyConfirmed }: DoneGateInput): DoneGate {
  if (lines.length === 0) {
    return {
      canSend: emptyConfirmed,
      needsAck: false,
      blockedBy: emptyConfirmed ? null : 'second-tap',
    }
  }
  const needsAck = warned.length > 0
  if (!lines.every(lineComplete)) return { canSend: false, needsAck, blockedBy: 'details' }
  if (needsAck && !acknowledged) return { canSend: false, needsAck, blockedBy: 'allergy' }
  return { canSend: true, needsAck, blockedBy: null }
}

/** `acknowledged` is the box itself, passed straight through. */
export function consultBody(lines: RxLine[], acknowledged: boolean): ConsultDoneBody {
  return {
    prescription: lines.map((line) => ({
      drug_id: line.drugId,
      dose: line.dose.trim(),
      frequency: line.frequency.trim(),
      days: parseDays(line.days),
      notes: line.notes.trim() || null,
    })),
    acknowledge_allergy: acknowledged,
  }
}

export interface AllergyConflict {
  drug_id: string
  name_en: string
  allergen: string
  text_en: string
  text_ar: string
}

/** The conflicts from a 409. Anything else in that slot reads as none. */
export function conflictsFrom(extra: Record<string, unknown>): AllergyConflict[] {
  return Array.isArray(extra.conflicts) ? (extra.conflicts as AllergyConflict[]) : []
}

export const warnedKey = (warned: string[]) => [...warned].sort().join(' ')
