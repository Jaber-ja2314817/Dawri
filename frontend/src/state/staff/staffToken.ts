import type { TokenSource } from '../../api/client'
import { readStored, removeStored, writeStored } from '../../lib/storage'

/*
 * The staff session, apart from the patient's: one browser can hold both.
 *
 * On the demo laptop one Chrome profile can hold a nurse tab and a doctor tab, so sessionStorage
 * keeps each tab its own person through a reload. localStorage only says who a new tab opens as.
 */

const TOKEN_KEY = 'dawri.staff.token'

type Listener = (token: string | null) => void

let token: string | null | undefined
const listeners = new Set<Listener>()

function readTab(): string | null {
  try {
    return window.sessionStorage.getItem(TOKEN_KEY)
  } catch {
    return null
  }
}

function writeTab(next: string | null): void {
  try {
    if (next === null) window.sessionStorage.removeItem(TOKEN_KEY)
    else window.sessionStorage.setItem(TOKEN_KEY, next)
  } catch {
    // The caller keeps its own copy in memory.
  }
}

export function getStaffToken(): string | null {
  if (token === undefined) token = readTab() ?? readStored(TOKEN_KEY)
  return token
}

export function setStaffToken(next: string): void {
  token = next
  writeStored(TOKEN_KEY, next)
  writeTab(next)
  listeners.forEach((listener) => listener(next))
}

export function clearStaffToken(): void {
  token = null
  removeStored(TOKEN_KEY)
  writeTab(null)
  listeners.forEach((listener) => listener(null))
}

export function onStaffTokenChange(listener: Listener): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

export const staffSource: TokenSource = { get: getStaffToken, clear: clearStaffToken }

// Inspector builds only, as in session.tsx: replaced at build time and gone from a normal build.
if (import.meta.env.VITE_INSPECT) {
  const inspectToken = new URLSearchParams(window.location.search).get('inspect_staff_token')
  if (inspectToken) setStaffToken(inspectToken)
}
