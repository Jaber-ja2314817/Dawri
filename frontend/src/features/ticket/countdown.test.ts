import { describe, expect, it } from 'vitest'
import { formatCountdown, secondsLeft } from './countdown'

const NOW = Date.parse('2026-11-06T10:00:00.000Z')

describe('formatCountdown', () => {
  it.each([
    [2700, '45:00'],
    [2699, '44:59'],
    [61, '01:01'],
    [60, '01:00'],
    [9, '00:09'],
    [0, '00:00'],
  ])('shows %i seconds as %s', (seconds, text) => {
    expect(formatCountdown(seconds)).toBe(text)
  })
})

describe('secondsLeft', () => {
  it('reads the microseconds the backend writes', () => {
    expect(secondsLeft('2026-11-06T10:45:00.000000+00:00', NOW)).toBe(2700)
    expect(secondsLeft('2026-11-06T10:44:59.123456+00:00', NOW)).toBe(2700)
  })

  it('stays at 0 for a past expires_at', () => {
    expect(secondsLeft('2026-11-06T09:00:00.000000+00:00', NOW)).toBe(0)
    expect(formatCountdown(secondsLeft('2026-11-06T09:00:00+00:00', NOW) as number)).toBe('00:00')
  })

  it('gives 0 at the exact moment of expiry', () => {
    expect(secondsLeft('2026-11-06T10:00:00.000000+00:00', NOW)).toBe(0)
  })

  it('gives null when there is no usable time', () => {
    expect(secondsLeft(null, NOW)).toBeNull()
    expect(secondsLeft('soon', NOW)).toBeNull()
  })
})
