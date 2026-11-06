import type { Lang } from '../i18n'

const DOHA = 'Asia/Qatar'

/** Latin digits in both languages, so dates match the numbers on tickets. */
export function formatDate(iso: string, lang: Lang): string {
  const locale = lang === 'ar' ? 'ar-QA-u-nu-latn-ca-gregory' : 'en-GB'
  return new Intl.DateTimeFormat(locale, {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    timeZone: DOHA,
  }).format(new Date(iso))
}

export function nameOf(
  who: { full_name_en: string; full_name_ar: string },
  lang: Lang,
): string {
  return lang === 'ar' ? who.full_name_ar : who.full_name_en
}

export function centreName(
  centre: { name_en: string; name_ar: string },
  lang: Lang,
): string {
  return lang === 'ar' ? centre.name_ar : centre.name_en
}
