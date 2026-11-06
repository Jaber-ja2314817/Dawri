import { readStored, removeStored, writeStored } from '../lib/storage'

/* The session token. Memory is the truth, so a blocked localStorage still works. */

const TOKEN_KEY = 'dawri.token'

type Listener = (token: string | null) => void

let token: string | null | undefined
const listeners = new Set<Listener>()

export function getToken(): string | null {
  if (token === undefined) token = readStored(TOKEN_KEY)
  return token
}

export function setToken(next: string): void {
  token = next
  writeStored(TOKEN_KEY, next)
  listeners.forEach((listener) => listener(next))
}

export function clearToken(): void {
  token = null
  removeStored(TOKEN_KEY)
  listeners.forEach((listener) => listener(null))
}

export function onTokenChange(listener: Listener): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}
