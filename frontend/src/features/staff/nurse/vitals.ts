import type { Urgency, VitalsBody, VitalsRow } from '../../../api/staffTypes'

export const VITAL_FIELDS = ['bp_sys', 'bp_dia', 'hr', 'temp_c', 'spo2', 'weight_kg'] as const
export type VitalField = (typeof VITAL_FIELDS)[number]
export type VitalValues = Record<VitalField, string>
export type VitalError = 'number' | 'whole' | 'range'

interface VitalRule {
  min: number
  max: number
  whole: boolean
}

/* The server's own ranges (class Vitals in backend/routers/staff.py). */
export const VITAL_RULES: Record<VitalField, VitalRule> = {
  bp_sys: { min: 40, max: 300, whole: true },
  bp_dia: { min: 20, max: 200, whole: true },
  hr: { min: 20, max: 300, whole: true },
  temp_c: { min: 25, max: 45, whole: false },
  spo2: { min: 40, max: 100, whole: true },
  weight_kg: { min: 0.5, max: 400, whole: false },
}

const ARABIC_ZERO = 0x0660
const PERSIAN_ZERO = 0x06f0

/** Arabic and Persian digits become Latin, the decimal mark a point. Marks of direction go. */
export function latinDigits(text: string): string {
  return text
    .replace(/[٠-٩]/g, (digit) => String(digit.charCodeAt(0) - ARABIC_ZERO))
    .replace(/[۰-۹]/g, (digit) => String(digit.charCodeAt(0) - PERSIAN_ZERO))
    .replace(/[٫,]/g, '.')
    .replace(/[‎‏؜\s]/g, '')
}

export type Parsed = { value: number | null; error?: undefined } | { error: VitalError }

/** Empty means not measured, which is null and allowed. */
export function parseVital(field: VitalField, raw: string): Parsed {
  const text = latinDigits(raw)
  if (text === '') return { value: null }
  if (!/^\d+\.?\d*$/.test(text)) return { error: 'number' }
  const value = Number(text)
  const rule = VITAL_RULES[field]
  if (rule.whole && !Number.isInteger(value)) return { error: 'whole' }
  if (value < rule.min || value > rule.max) return { error: 'range' }
  return { value }
}

export interface ParsedVitals {
  values: Omit<VitalsBody, 'urgency'>
  errors: Partial<Record<VitalField, VitalError>>
}

export function parseVitals(form: VitalValues): ParsedVitals {
  const values: Omit<VitalsBody, 'urgency'> = {}
  const errors: ParsedVitals['errors'] = {}
  for (const field of VITAL_FIELDS) {
    const parsed = parseVital(field, form[field])
    if (parsed.error === undefined) values[field] = parsed.value
    else errors[field] = parsed.error
  }
  return { values, errors }
}

export function emptyVitals(): VitalValues {
  return { bp_sys: '', bp_dia: '', hr: '', temp_c: '', spo2: '', weight_kg: '' }
}

/** The readings already taken, for a nurse coming back. Urgency is not one of them. */
export function vitalsFrom(row: VitalsRow | null): VitalValues {
  const form = emptyVitals()
  if (row === null) return form
  for (const field of VITAL_FIELDS) {
    const value = row[field]
    form[field] = value === null ? '' : String(value)
  }
  return form
}

export type GateReason = 'locked' | 'not-called' | 'no-urgency' | null

/** Why the primary action cannot run yet. The nurse decides urgency: nothing defaults it. */
export function vitalsGate({
  inTriage,
  atCounter,
  urgency,
}: {
  inTriage: boolean
  atCounter: boolean
  urgency: Urgency | null
}): GateReason {
  if (!inTriage) return 'locked'
  if (!atCounter) return 'not-called'
  if (urgency === null) return 'no-urgency'
  return null
}
