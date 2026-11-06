import { describe, expect, it } from 'vitest'
import ar from './ar.json'
import chatAr from './chat.ar.json'
import chatEn from './chat.en.json'
import en from './en.json'
import { translate } from './index'
import { recordTerm } from './record'
import visitAr from './visit.ar.json'
import visitEn from './visit.en.json'

type Dictionary = Record<string, string>

const PAIRS: [string, Dictionary, Dictionary][] = [
  ['main', ar, en],
  ['chat', chatAr, chatEn],
  ['visit', visitAr, visitEn],
]
const BANNED = ['place held', 'held for', 'no-show', 'nobody skips', 'skip the queue', 'مكانك محجوز']
const ERROR_CODES = `unauthorized forbidden unknown_qid invalid_otp consent_required active_visit
  emergency_today visit_not_found invalid_text visit_not_in_intake no_intake unknown_service
  intake_not_confirmed service_not_offered unknown_centre no_reservation too_far wrong_door
  arrival_method_required ticket_expired visit_not_eligible visit_has_live_ticket invalid_transition
  asr_unavailable bad_audio asr_failed audio_too_large not_emergency visit_not_deflected
  visit_not_completed already_rated internal_error network`.split(/\s+/)

const hasPrefix = (key: string, prefixes: string[]) =>
  prefixes.some((prefix) => key.startsWith(prefix))

describe.each(PAIRS)('%s dictionaries', (_name, arabic, english) => {
  it('have the same keys', () => {
    expect(Object.keys(arabic).sort()).toEqual(Object.keys(english).sort())
  })

  it('have no blank value', () => {
    for (const value of [...Object.values(arabic), ...Object.values(english)]) {
      expect(typeof value).toBe('string')
      expect(value.trim()).not.toBe('')
    }
  })

  it('use no banned phrase', () => {
    for (const value of [...Object.values(arabic), ...Object.values(english)]) {
      for (const phrase of BANNED) expect(value.toLowerCase()).not.toContain(phrase)
    }
  })
})

describe('ownership of the wave files', () => {
  it('chat files hold only their prefixes', () => {
    const prefixes = ['chat.', 'voice.', 'emergency.', 'refill.']
    for (const key of [...Object.keys(chatAr), ...Object.keys(chatEn)]) {
      expect(hasPrefix(key, prefixes), key).toBe(true)
    }
  })

  it('visit files hold only their prefixes', () => {
    const prefixes = ['centre.', 'reserved.', 'ticket.', 'complete.']
    for (const key of [...Object.keys(visitAr), ...Object.keys(visitEn)]) {
      expect(hasPrefix(key, prefixes), key).toBe(true)
    }
  })
})

describe('the footer', () => {
  it('reads exactly as the build decisions say', () => {
    expect(en['footer.demo']).toBe('Demo — synthetic data, not connected to PHCC/HMC systems.')
    expect(ar['footer.demo']).toBe('تجريبي — بيانات اصطناعية، غير متصل بأنظمة PHCC/HMC.')
    expect(en['footer.ai']).toBe('AI: simulated')
    expect(ar['footer.ai']).toBe('الذكاء الاصطناعي: محاكاة')
  })
})

describe('error keys', () => {
  it.each(ERROR_CODES)('exist for %s', (code) => {
    expect(ar).toHaveProperty([`error.${code}`])
    expect(en).toHaveProperty([`error.${code}`])
  })
})

describe('translate', () => {
  it('fills {name} values', () => {
    expect(translate('en', 'who.age', { age: 34 })).toBe('34 years')
    expect(translate('ar', 'who.age', { age: 34 })).toBe('العمر 34')
  })

  it('leaves a value it was not given in place', () => {
    expect(translate('en', 'who.age', {})).toBe('{age} years')
  })

  it('returns the key when nothing matches', () => {
    expect(translate('en', 'nothing.here')).toBe('nothing.here')
  })
})

describe('recordTerm', () => {
  it.each([
    ['penicillin', 'البنسلين'],
    ['hypertension', 'ارتفاع ضغط الدم'],
    ['type 2 diabetes', 'السكري من النوع الثاني'],
    ['amlodipine 5 mg once daily', 'أملوديبين 5 ملغ مرة واحدة يومياً'],
    ['metformin 500 mg twice daily', 'ميتفورمين 500 ملغ مرتين يومياً'],
  ])('gives Arabic for %s', (value, arabic) => {
    expect(recordTerm(value, 'ar')).toBe(arabic)
    expect(recordTerm(value, 'en')).toBe(value)
  })

  it('returns an unknown value as stored', () => {
    expect(recordTerm('Latex', 'ar')).toBe('Latex')
  })
})
