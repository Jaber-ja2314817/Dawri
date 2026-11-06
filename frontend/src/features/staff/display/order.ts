import type { DisplayCounter, Stage } from '../../../api/staffTypes'

const STAGE_ORDER: Record<Stage, number> = { triage: 0, doctor: 1, pharmacy: 2 }

/** A patient's path through the centre. The API's id order would start at the doctor rooms. */
export function displayOrder(counters: DisplayCounter[]): DisplayCounter[] {
  return counters.toSorted((a, b) => STAGE_ORDER[a.stage] - STAGE_ORDER[b.stage])
}
