import type { Lang } from './index'

/* Arabic for what the seed record holds. The record itself stays in English. */
const ARABIC: Record<string, string> = {
  penicillin: 'البنسلين',
  hypertension: 'ارتفاع ضغط الدم',
  'type 2 diabetes': 'السكري من النوع الثاني',
  'amlodipine 5 mg once daily': 'أملوديبين 5 ملغ مرة واحدة يومياً',
  'metformin 500 mg twice daily': 'ميتفورمين 500 ملغ مرتين يومياً',
}

/** Unknown values come back as stored: never guess a clinical term. */
export function recordTerm(value: string, lang: Lang): string {
  if (lang !== 'ar') return value
  return ARABIC[value.trim().toLowerCase()] ?? value
}
