import type { Visit } from '../api/types'

export type Screen =
  | 'chat'
  | 'emergency'
  | 'refill'
  | 'centre'
  | 'reserved'
  | 'ticket'
  | 'complete'
  | 'home'

/**
 * The screens a visit may show, canonical one first. This is the whole of the rule that a
 * chat box never appears once chat is over: chat is listed for an open intake and nothing else.
 */
export function screensFor(visit: Pick<Visit, 'stage' | 'confirmed_by_patient'>): Screen[] {
  switch (visit.stage) {
    case 'emergency':
      return ['emergency']
    case 'refill':
      return ['refill']
    case 'completed':
      return ['complete']
    case 'reserved':
      return ['reserved']
    case 'expired':
      return ['reserved', 'centre']
    case 'triage':
    case 'doctor':
    case 'pharmacy':
      return ['ticket']
    case 'cancelled':
      return ['home']
    case 'intake':
      return visit.confirmed_by_patient ? ['centre'] : ['chat']
  }
}

export function pathFor(id: string, screen: Screen): string {
  return screen === 'home' ? '/home' : `/visit/${id}/${screen}`
}
