import type { DisplaySnapshot } from '../../../api/staffTypes'

export interface ServingChange {
  counterId: string
  number: string
}

/**
 * The counters that have just called a number. A counter must have been on the last snapshot to
 * change, so a first load, a reconnect and a move to another centre are all silent. A counter
 * going to null called nobody, which is also all a demo reset does.
 */
export function servingChanges(
  prev: DisplaySnapshot | null,
  next: DisplaySnapshot,
): ServingChange[] {
  if (prev === null || prev.centre.id !== next.centre.id) return []
  const before = new Map(prev.counters.map((counter) => [counter.id, counter.now_serving]))
  return next.counters.flatMap(({ id, now_serving: number }) =>
    number !== null && before.has(id) && before.get(id) !== number
      ? [{ counterId: id, number }]
      : [],
  )
}
