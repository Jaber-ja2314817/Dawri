import { describe, expect, it } from 'vitest'
import type { VisitDrug } from '../../../api/staffTypes'
import { conflictsFrom, consultBody, doneGate, lineFrom, parseDays, warnedKey, type RxLine } from './gate'

const line = (over: Partial<RxLine> = {}): RxLine => ({
  drugId: 'DR-PARA',
  dose: '500 mg',
  frequency: 'every 6 hours as needed',
  days: '3',
  notes: '',
  ...over,
})
const amoxicillin = line({ drugId: 'DR-AMOX', frequency: 'three times daily', days: '5' })
const base = { warned: [] as string[], acknowledged: false, emptyConfirmed: false }

describe('the Done gate', () => {
  it('lets a safe medicine go', () => {
    expect(doneGate({ ...base, lines: [line()] })).toEqual({
      canSend: true,
      needsAck: false,
      blockedBy: null,
    })
  })

  it('stops a warned medicine until the box is ticked', () => {
    expect(doneGate({ ...base, lines: [amoxicillin], warned: ['DR-AMOX'] })).toEqual({
      canSend: false,
      needsAck: true,
      blockedBy: 'allergy',
    })
  })

  it('lets a warned medicine go once the box is ticked', () => {
    const gate = doneGate({ ...base, lines: [amoxicillin], warned: ['DR-AMOX'], acknowledged: true })
    expect(gate).toEqual({ canSend: true, needsAck: true, blockedBy: null })
  })

  it('closes again when the box is unticked', () => {
    const lines = [amoxicillin]
    expect(doneGate({ ...base, lines, warned: ['DR-AMOX'], acknowledged: true }).canSend).toBe(true)
    expect(doneGate({ ...base, lines, warned: ['DR-AMOX'], acknowledged: false }).canSend).toBe(false)
  })

  it('holds a warned medicine beside a safe one all the same', () => {
    const gate = doneGate({ ...base, lines: [line(), amoxicillin], warned: ['DR-AMOX'] })
    expect(gate.canSend).toBe(false)
    expect(gate.blockedBy).toBe('allergy')
  })

  it('asks for a second tap when nothing is selected', () => {
    expect(doneGate({ ...base, lines: [] })).toEqual({
      canSend: false,
      needsAck: false,
      blockedBy: 'second-tap',
    })
    expect(doneGate({ ...base, lines: [], emptyConfirmed: true })).toEqual({
      canSend: true,
      needsAck: false,
      blockedBy: null,
    })
  })

  it('gives the second tap no say once a medicine is chosen', () => {
    const gate = doneGate({
      ...base,
      lines: [amoxicillin],
      warned: ['DR-AMOX'],
      emptyConfirmed: true,
    })
    expect(gate.canSend).toBe(false)
  })

  it.each([
    ['days', { days: '0' }],
    ['days', { days: '366' }],
    ['days', { days: '2.5' }],
    ['days', { days: '' }],
    ['dose', { dose: '  ' }],
    ['frequency', { frequency: '' }],
  ])('refuses a line with a bad %s', (_field, over) => {
    expect(doneGate({ ...base, lines: [line(over)] })).toEqual({
      canSend: false,
      needsAck: false,
      blockedBy: 'details',
    })
  })
})

describe('days', () => {
  it.each([
    ['1', 1],
    ['365', 365],
    [' 7 ', 7],
    ['٥', 5],
    ['١٤', 14],
    ['007', 7],
  ])('reads %s', (text, days) => expect(parseDays(text)).toBe(days))

  it.each(['0', '366', '1000', '-1', '1.5', '1e2', 'five', ''])('refuses %s', (text) =>
    expect(parseDays(text)).toBeNull(),
  )
})

describe('what is sent', () => {
  it('passes the box through and never decides it', () => {
    expect(consultBody([line()], false).acknowledge_allergy).toBe(false)
    expect(consultBody([amoxicillin], true).acknowledge_allergy).toBe(true)
  })

  it('sends the five fields, trimmed, with days as a number', () => {
    const body = consultBody(
      [line({ dose: ' 250 mg ', frequency: ' twice daily ', days: '٧', notes: ' with food ' })],
      false,
    )
    expect(body.prescription).toEqual([
      {
        drug_id: 'DR-PARA',
        dose: '250 mg',
        frequency: 'twice daily',
        days: 7,
        notes: 'with food',
      },
    ])
  })

  it('sends no notes as null, and no medicine as an empty list', () => {
    expect(consultBody([line()], false).prescription[0].notes).toBeNull()
    expect(consultBody([], false)).toEqual({ prescription: [], acknowledge_allergy: false })
  })
})

describe('the rest of the picker', () => {
  const drug: VisitDrug = {
    id: 'DR-AMOX',
    name_en: 'amoxicillin',
    name_ar: 'أموكسيسيلين',
    form: 'capsule',
    default_dose: '500 mg',
    default_frequency: 'three times daily',
    default_days: 5,
    demo_default: 1,
    allergy_warning: null,
  }

  it('prefills from the defaults', () => {
    expect(lineFrom(drug)).toEqual({
      drugId: 'DR-AMOX',
      dose: '500 mg',
      frequency: 'three times daily',
      days: '5',
      notes: '',
    })
  })

  it('leaves a missing default blank, for the doctor to fill', () => {
    const blank = { ...drug, default_dose: null, default_frequency: null, default_days: null }
    expect(lineFrom(blank)).toMatchObject({ dose: '', frequency: '', days: '' })
  })

  it('reads conflicts only when they are a list', () => {
    const conflict = { drug_id: 'DR-AMOX' }
    expect(conflictsFrom({ conflicts: [conflict] })).toEqual([conflict])
    expect(conflictsFrom({})).toEqual([])
    expect(conflictsFrom({ conflicts: 'none' })).toEqual([])
  })

  it('keys the warned set whatever the order', () => {
    expect(warnedKey(['DR-AUGM', 'DR-AMOX'])).toBe(warnedKey(['DR-AMOX', 'DR-AUGM']))
    expect(warnedKey(['DR-AMOX'])).not.toBe(warnedKey(['DR-AMOX', 'DR-AUGM']))
  })
})
