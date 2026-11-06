import { describe, expect, it } from 'vitest'
import type { VitalsRow } from '../../../api/staffTypes'
import {
  emptyVitals,
  latinDigits,
  parseVital,
  parseVitals,
  vitalsFrom,
  vitalsGate,
  VITAL_RULES,
} from './vitals'

describe('latinDigits', () => {
  it.each([
    ['١٢٠', '120'],
    ['۹۸', '98'],
    ['٣٨٫٥', '38.5'],
    ['38,5', '38.5'],
    [' 1 2 ', '12'],
    ['‏١٢٠', '120'],
  ])('reads %s as %s', (raw, latin) => {
    expect(latinDigits(raw)).toBe(latin)
  })
})

describe('parseVital', () => {
  it('takes Arabic digits and the Arabic decimal mark', () => {
    expect(parseVital('bp_sys', '١١٨')).toEqual({ value: 118 })
    expect(parseVital('temp_c', '٣٨٫٢')).toEqual({ value: 38.2 })
    expect(parseVital('spo2', '۹۸')).toEqual({ value: 98 })
  })

  it('reads empty as null, because not measured is allowed', () => {
    expect(parseVital('hr', '')).toEqual({ value: null })
    expect(parseVital('hr', '   ')).toEqual({ value: null })
  })

  it('refuses text and a sign', () => {
    expect(parseVital('hr', 'fast')).toEqual({ error: 'number' })
    expect(parseVital('hr', '-90')).toEqual({ error: 'number' })
    expect(parseVital('hr', '1e2')).toEqual({ error: 'number' })
  })

  it('refuses a fraction where the server stores a whole number', () => {
    expect(parseVital('bp_sys', '118.5')).toEqual({ error: 'whole' })
    expect(parseVital('bp_sys', '118.0')).toEqual({ value: 118 })
    expect(parseVital('temp_c', '38.5')).toEqual({ value: 38.5 })
  })

  it.each(Object.entries(VITAL_RULES))('holds %s to the server range, ends included', (field, rule) => {
    const name = field as keyof typeof VITAL_RULES
    expect(parseVital(name, String(rule.min))).toEqual({ value: rule.min })
    expect(parseVital(name, String(rule.max))).toEqual({ value: rule.max })
    expect(parseVital(name, String(rule.max + 1))).toEqual({ error: 'range' })
    expect(parseVital(name, String(Math.max(rule.min - 1, 0)))).toEqual({ error: 'range' })
  })
})

describe('parseVitals', () => {
  it('sends null for what was left empty and numbers for the rest', () => {
    const { values, errors } = parseVitals({ ...emptyVitals(), bp_sys: '١٢٠', temp_c: '٣٧٫٥' })
    expect(errors).toEqual({})
    expect(values).toEqual({
      bp_sys: 120,
      bp_dia: null,
      hr: null,
      temp_c: 37.5,
      spo2: null,
      weight_kg: null,
    })
  })

  it('names each field that failed', () => {
    const { errors } = parseVitals({ ...emptyVitals(), bp_sys: '900', hr: 'x' })
    expect(errors).toEqual({ bp_sys: 'range', hr: 'number' })
  })
})

describe('vitalsFrom', () => {
  it('brings back the readings and never the urgency', () => {
    const row = { bp_sys: 118, bp_dia: null, temp_c: 38.2, urgency: 'urgent' } as VitalsRow
    const form = vitalsFrom(row)
    expect(form.bp_sys).toBe('118')
    expect(form.temp_c).toBe('38.2')
    expect(Object.keys(form)).not.toContain('urgency')
  })

  it('is empty with no readings', () => {
    expect(vitalsFrom(null)).toEqual(emptyVitals())
  })
})

describe('the urgency gate', () => {
  const ready = { inTriage: true, atCounter: true, urgency: null } as const

  it('stays shut until the nurse chooses', () => {
    expect(vitalsGate(ready)).toBe('no-urgency')
  })

  it.each(['routine', 'soon', 'urgent'] as const)('opens on %s', (urgency) => {
    expect(vitalsGate({ ...ready, urgency })).toBeNull()
  })

  it('never opens for a patient not yet called, whatever is chosen', () => {
    expect(vitalsGate({ ...ready, atCounter: false, urgency: 'routine' })).toBe('not-called')
  })

  it('never opens once the visit has left triage', () => {
    expect(vitalsGate({ ...ready, inTriage: false, urgency: 'routine' })).toBe('locked')
  })
})
