import { describe, expect, it } from 'vitest'
import { waitingTotal } from './figures'

describe('waitingTotal', () => {
  it('adds up the three stages', () => {
    expect(waitingTotal({ triage: 3, doctor: 2, pharmacy: 1 })).toBe(6)
  })

  it('is 0 when nobody is waiting', () => {
    expect(waitingTotal({ triage: 0, doctor: 0, pharmacy: 0 })).toBe(0)
  })
})
