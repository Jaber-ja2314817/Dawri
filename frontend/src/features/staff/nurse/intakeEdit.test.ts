import { describe, expect, it } from 'vitest'
import type { StaffIntake } from '../../../api/staffTypes'
import {
  hasUnsavedEdit,
  intakeChanges,
  intakeForm,
  parseSeverity,
  SERVICES,
} from './intakeEdit'

const intake = {
  chief_complaint: 'fever and cough',
  duration: '3 days',
  severity_0_10: 5,
  associated: ['fever', 'cough'],
  self_medication: [],
  service: 'gp',
  summary_for_nurse: 'Fever for 3 days.',
  patient_concerns: null,
} as unknown as StaffIntake

const before = intakeForm(intake, 'gp')

describe('intakeForm', () => {
  it('prints lists on one line and null as empty', () => {
    expect(before.associated).toBe('fever, cough')
    expect(before.self_medication).toBe('')
    expect(before.patient_concerns).toBe('')
  })

  it('starts from the service on show, which the nurse may have changed', () => {
    expect(intakeForm(intake, 'dental').service).toBe('dental')
    expect(intakeForm(intake, null).service).toBe('gp')
  })

  it('offers the 8 services', () => {
    expect(SERVICES).toHaveLength(8)
  })
})

describe('parseSeverity', () => {
  it.each([
    ['', null],
    ['0', 0],
    ['١٠', 10],
    ['٧', 7],
  ])('reads %s', (raw, value) => {
    expect(parseSeverity(raw)).toBe(value)
  })

  it.each(['11', '٦٫٥', '6.5', 'bad'])('refuses %s', (raw) => {
    expect(parseSeverity(raw)).toBeUndefined()
  })
})

describe('intakeChanges', () => {
  it('sends nothing when nothing moved', () => {
    expect(intakeChanges(before, { ...before })).toEqual({})
  })

  it('sends only the field the nurse changed', () => {
    expect(intakeChanges(before, { ...before, chief_complaint: 'productive cough' })).toEqual({
      chief_complaint: 'productive cough',
    })
  })

  it('ignores space around a value', () => {
    expect(intakeChanges(before, { ...before, duration: ' 3 days ' })).toEqual({})
  })

  it('turns a cleared optional into null', () => {
    expect(intakeChanges(before, { ...before, duration: '  ' })).toEqual({ duration: null })
    expect(intakeChanges(before, { ...before, severity_0_10: '' })).toEqual({ severity_0_10: null })
  })

  it('sends a list back as a list, split on either comma', () => {
    expect(intakeChanges(before, { ...before, self_medication: 'بنادول، فيتامين, zinc' })).toEqual({
      self_medication: ['بنادول', 'فيتامين', 'zinc'],
    })
  })

  it('keeps severity a number, in either script', () => {
    expect(intakeChanges(before, { ...before, severity_0_10: '٨' })).toEqual({ severity_0_10: 8 })
  })

  it('refuses an invalid severity instead of sending it', () => {
    expect(intakeChanges(before, { ...before, severity_0_10: '12' })).toBeUndefined()
  })

  it('sends a blank complaint, for the server to refuse', () => {
    expect(intakeChanges(before, { ...before, chief_complaint: ' ' })).toEqual({
      chief_complaint: '',
    })
  })

  it('leaves a stored value with a comma alone when untouched', () => {
    const stored = { ...intake, associated: ['pain, sharp'] } as StaffIntake
    const form = intakeForm(stored, 'gp')
    expect(intakeChanges(form, { ...form })).toEqual({})
  })
})

describe('hasUnsavedEdit', () => {
  it('is false until something real changed', () => {
    expect(hasUnsavedEdit(before, before)).toBe(false)
    expect(hasUnsavedEdit(before, { ...before, duration: ' 3 days ' })).toBe(false)
  })

  it('is true for any changed field', () => {
    expect(hasUnsavedEdit(before, { ...before, chief_complaint: 'cough' })).toBe(true)
    expect(hasUnsavedEdit(before, { ...before, service: 'dental' })).toBe(true)
  })

  it('counts a severity that would not save', () => {
    expect(hasUnsavedEdit(before, { ...before, severity_0_10: 'twelve' })).toBe(true)
  })
})
