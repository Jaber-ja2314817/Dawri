import { describe, expect, it } from 'vitest'
import type { Visit, VisitStage, VisitStatus } from '../api/types'
import { pathFor, screensFor, type Screen } from './stages'

const STAGE: Record<VisitStatus, VisitStage> = {
  intake: 'intake',
  redirected_emergency: 'emergency',
  deflected_refill: 'refill',
  reserved: 'reserved',
  expired: 'expired',
  in_triage: 'triage',
  in_doctor: 'doctor',
  in_pharmacy: 'pharmacy',
  completed: 'completed',
  cancelled: 'cancelled',
}

const visit = (status: VisitStatus, confirmed = false): Pick<Visit, 'stage' | 'confirmed_by_patient'> => ({
  stage: STAGE[status],
  confirmed_by_patient: confirmed,
})

const expected: [VisitStatus, boolean, Screen[]][] = [
  ['intake', false, ['chat']],
  ['intake', true, ['centre']],
  ['redirected_emergency', false, ['emergency']],
  ['deflected_refill', false, ['refill']],
  ['reserved', true, ['reserved']],
  ['expired', true, ['reserved', 'centre']],
  ['in_triage', true, ['ticket']],
  ['in_doctor', true, ['ticket']],
  ['in_pharmacy', true, ['ticket']],
  ['completed', true, ['complete']],
  ['cancelled', false, ['home']],
]

describe('screensFor', () => {
  it.each(expected)('%s, confirmed %s', (status, confirmed, screens) => {
    expect(screensFor(visit(status, confirmed))).toEqual(screens)
  })

  it('covers all 10 statuses', () => {
    expect(new Set(expected.map(([status]) => status)).size).toBe(10)
    expect(Object.keys(STAGE)).toHaveLength(10)
  })

  it.each(Object.keys(STAGE).filter((status) => status !== 'intake') as VisitStatus[])(
    'never offers chat on %s, confirmed or not',
    (status) => {
      expect(screensFor(visit(status, true))).not.toContain('chat')
      expect(screensFor(visit(status, false))).not.toContain('chat')
    },
  )

  it('never offers chat on a confirmed intake', () => {
    expect(screensFor(visit('intake', true))).not.toContain('chat')
  })
})

describe('pathFor', () => {
  it('nests visit screens under the visit', () => {
    expect(pathFor('V1', 'ticket')).toBe('/visit/V1/ticket')
    expect(pathFor('V1', 'chat')).toBe('/visit/V1/chat')
  })

  it('sends home out of the visit', () => {
    expect(pathFor('V1', 'home')).toBe('/home')
  })
})
