import { beforeEach, describe, expect, it, vi } from 'vitest'

const KEY = 'dawri.staff.token'

/** The module caches the token, so a fresh import stands for a reload. */
const reload = async () => {
  vi.resetModules()
  return import('./staffToken')
}

beforeEach(() => {
  localStorage.clear()
  sessionStorage.clear()
})

describe('staff token', () => {
  it('survives a reload', async () => {
    const before = await reload()
    before.setStaffToken('nurse')
    const after = await reload()
    expect(after.getStaffToken()).toBe('nurse')
  })

  it('keeps this tab its own person when another tab signs in as someone else', async () => {
    const tab = await reload()
    tab.setStaffToken('nurse')
    localStorage.setItem(KEY, 'doctor')
    const after = await reload()
    expect(after.getStaffToken()).toBe('nurse')
  })

  it('opens a new tab as the last person to sign in', async () => {
    localStorage.setItem(KEY, 'doctor')
    const tab = await reload()
    expect(tab.getStaffToken()).toBe('doctor')
  })

  it('clears both places, and tells the listeners', async () => {
    const tab = await reload()
    tab.setStaffToken('nurse')
    const heard: (string | null)[] = []
    tab.onStaffTokenChange((next) => heard.push(next))
    tab.clearStaffToken()
    expect(localStorage.getItem(KEY)).toBeNull()
    expect(sessionStorage.getItem(KEY)).toBeNull()
    expect(heard).toEqual([null])
    expect((await reload()).getStaffToken()).toBeNull()
  })
})
