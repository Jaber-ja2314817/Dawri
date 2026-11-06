import type { Stage, Stats } from '../../../api/staffTypes'

export const STAGES: Stage[] = ['triage', 'doctor', 'pharmacy']

/** Added up here, so the total cannot disagree with the three figures beside it. */
export function waitingTotal(waiting: Stats['waiting']): number {
  return STAGES.reduce((total, stage) => total + waiting[stage], 0)
}
