import { describe, expect, it } from 'vitest'
import type { DisplayCounter, DisplaySnapshot } from '../../../api/staffTypes'
import { servingChanges } from './changes'

const TRIAGE = 'C-WAKRA-T1'
const ROOM = 'C-WAKRA-D4'

function counter(id: string, nowServing: string | null): DisplayCounter {
  return { id, label: id, label_ar: id, stage: 'triage', now_serving: nowServing, waiting: 0 }
}

function snapshot(triage: string | null, room: string | null, centre = 'C-WAKRA'): DisplaySnapshot {
  return {
    centre: { id: centre, name_en: centre, name_ar: centre } as DisplaySnapshot['centre'],
    counters: [counter(TRIAGE, triage), counter(ROOM, room)],
  }
}

describe('servingChanges', () => {
  it('gives none on the first snapshot, whatever it holds', () => {
    expect(servingChanges(null, snapshot('T-014', 'D-GP-023'))).toEqual([])
    expect(servingChanges(null, snapshot(null, null))).toEqual([])
  })

  it('gives the counter that called its first number', () => {
    expect(servingChanges(snapshot(null, null), snapshot('T-014', null))).toEqual([
      { counterId: TRIAGE, number: 'T-014' },
    ])
  })

  it('gives the counter that moved to a new number', () => {
    expect(servingChanges(snapshot('T-014', null), snapshot('T-015', null))).toEqual([
      { counterId: TRIAGE, number: 'T-015' },
    ])
  })

  it('gives each counter that changed in one snapshot', () => {
    expect(servingChanges(snapshot('T-014', null), snapshot('T-015', 'D-GP-023'))).toEqual([
      { counterId: TRIAGE, number: 'T-015' },
      { counterId: ROOM, number: 'D-GP-023' },
    ])
  })

  it('gives none when a counter goes to null', () => {
    expect(servingChanges(snapshot('T-014', null), snapshot(null, null))).toEqual([])
  })

  it('gives none on a reconnect that returns the same data', () => {
    const before = snapshot('T-014', 'D-GP-023')
    const after = structuredClone(before)
    expect(after).not.toBe(before)
    expect(servingChanges(before, after)).toEqual([])
  })

  it('gives none through a reset, and hears the next call after it', () => {
    const busy = snapshot('T-014', 'D-GP-023')
    const cleared = snapshot(null, null)
    expect(servingChanges(busy, cleared)).toEqual([])
    expect(servingChanges(cleared, cleared)).toEqual([])
    expect(servingChanges(cleared, snapshot('T-014', null))).toEqual([
      { counterId: TRIAGE, number: 'T-014' },
    ])
  })

  it('hears a number called again after it left the counter', () => {
    const called = snapshot('T-014', null)
    const notThere = snapshot(null, null)
    expect(servingChanges(called, notThere)).toEqual([])
    expect(servingChanges(notThere, called)).toHaveLength(1)
  })

  it('gives none for a counter the last snapshot never had', () => {
    const before = { ...snapshot('T-014', null), counters: [counter(TRIAGE, 'T-014')] }
    expect(servingChanges(before, snapshot('T-014', 'D-GP-023'))).toEqual([])
  })

  it('gives none on a move to another centre', () => {
    expect(servingChanges(snapshot('T-014', null), snapshot('T-099', null, 'C-RAYYAN'))).toEqual([])
  })
})
