import {
  createContext,
  useCallback,
  useContext,
  useLayoutEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react'
import { readStored, removeStored, writeStored } from '../lib/storage'
import ar from './ar.json'
import chatAr from './chat.ar.json'
import chatEn from './chat.en.json'
import en from './en.json'
import visitAr from './visit.ar.json'
import visitEn from './visit.en.json'

export type Lang = 'ar' | 'en'
export type Dir = 'rtl' | 'ltr'
export type Vars = Record<string, string | number>
export type Translate = (key: string, vars?: Vars) => string

const LANG_KEY = 'dawri.lang'
const CHOSEN_KEY = 'dawri.lang.chosen'

// Inspector builds only, like the session branch: replaced at build time, gone from a normal build.
if (import.meta.env.VITE_INSPECT) {
  const asked = new URLSearchParams(window.location.search).get('lang')
  if (asked === 'ar' || asked === 'en') {
    writeStored(LANG_KEY, asked)
    writeStored(CHOSEN_KEY, '1')
  }
}

const dictionaries: Record<Lang, Record<string, string>> = {
  ar: { ...ar, ...chatAr, ...visitAr },
  en: { ...en, ...chatEn, ...visitEn },
}

function storedLang(): Lang {
  const stored = readStored(LANG_KEY)
  return stored === 'en' || stored === 'ar' ? stored : 'ar'
}

export function translate(lang: Lang, key: string, vars?: Vars): string {
  const text = dictionaries[lang][key]
  if (text === undefined) return key
  if (!vars) return text
  return text.replace(/\{(\w+)\}/g, (whole, name: string) =>
    name in vars ? String(vars[name]) : whole,
  )
}

export function dirOf(lang: Lang): Dir {
  return lang === 'ar' ? 'rtl' : 'ltr'
}

interface I18nValue {
  lang: Lang
  /** The viewer's own choice. It outranks the record until logout. */
  setLang: (lang: Lang) => void
  t: Translate
  dir: Dir
  /** On login: the record's language, unless the viewer already chose one. */
  applyPreferred: (lang: string) => void
  /** On logout: back to the default, with the viewer's choice forgotten. */
  resetLang: () => void
}

const I18nContext = createContext<I18nValue | null>(null)

export function I18nProvider({ children }: { children: ReactNode }) {
  const [lang, setLangState] = useState<Lang>(storedLang)
  const [chosen, setChosen] = useState(() => readStored(CHOSEN_KEY) === '1')

  useLayoutEffect(() => {
    document.documentElement.lang = lang
    document.documentElement.dir = dirOf(lang)
  }, [lang])

  const setLang = useCallback((next: Lang) => {
    setLangState(next)
    setChosen(true)
    writeStored(LANG_KEY, next)
    writeStored(CHOSEN_KEY, '1')
  }, [])

  const applyPreferred = useCallback(
    (preferred: string) => {
      if (chosen) return
      const next: Lang = preferred === 'en' ? 'en' : 'ar'
      setLangState(next)
      writeStored(LANG_KEY, next)
    },
    [chosen],
  )

  const resetLang = useCallback(() => {
    setLangState('ar')
    setChosen(false)
    removeStored(LANG_KEY)
    removeStored(CHOSEN_KEY)
  }, [])

  const value = useMemo<I18nValue>(
    () => ({
      lang,
      setLang,
      dir: dirOf(lang),
      t: (key, vars) => translate(lang, key, vars),
      applyPreferred,
      resetLang,
    }),
    [lang, setLang, applyPreferred, resetLang],
  )

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>
}

export function useI18n(): I18nValue {
  const value = useContext(I18nContext)
  if (value === null) throw new Error('useI18n needs an I18nProvider above it')
  return value
}
