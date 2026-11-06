import type { Me } from '../api/types'

/** Start check-in: straight to consent when there is nobody else to choose. */
export function checkInPath(me: Me): string {
  if (me.dependents.length > 0) return '/check-in/who'
  return `/check-in/consent?for=${encodeURIComponent(me.patient.id)}`
}
