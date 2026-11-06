import { act, cleanup, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider, useI18n } from './index'

let i18n: ReturnType<typeof useI18n>

function Probe() {
  i18n = useI18n()
  return <p>{i18n.t('home.start')}</p>
}

const mount = () =>
  render(
    <I18nProvider>
      <Probe />
    </I18nProvider>,
  )

beforeEach(() => localStorage.clear())
afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('language', () => {
  it('defaults to Arabic, right to left, on html', () => {
    mount()
    expect(document.documentElement.lang).toBe('ar')
    expect(document.documentElement.dir).toBe('rtl')
    expect(screen.getByText('بدء تسجيل الوصول')).toBeTruthy()
  })

  it('follows the record on login', () => {
    mount()
    act(() => i18n.applyPreferred('en'))
    expect(i18n.lang).toBe('en')
    expect(i18n.dir).toBe('ltr')
    expect(document.documentElement.lang).toBe('en')
    expect(document.documentElement.dir).toBe('ltr')
  })

  it('keeps a tapped choice over the record until logout', () => {
    mount()
    act(() => i18n.setLang('en'))
    act(() => i18n.applyPreferred('ar'))
    expect(i18n.lang).toBe('en')
    act(() => i18n.resetLang())
    expect(i18n.lang).toBe('ar')
    act(() => i18n.applyPreferred('en'))
    expect(i18n.lang).toBe('en')
  })

  it('keeps a tapped choice across a reload', () => {
    const first = mount()
    act(() => i18n.setLang('en'))
    first.unmount()
    mount()
    expect(i18n.lang).toBe('en')
    act(() => i18n.applyPreferred('ar'))
    expect(i18n.lang).toBe('en')
  })

  it('renders when localStorage throws', () => {
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
      throw new Error('blocked')
    })
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new Error('blocked')
    })
    mount()
    act(() => i18n.setLang('en'))
    expect(i18n.lang).toBe('en')
  })
})
