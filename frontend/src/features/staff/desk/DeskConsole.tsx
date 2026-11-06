import { useCallback, useEffect, useRef } from 'react'
import type { CounterRef } from '../../../api/staffTypes'
import { useCounterQueue } from '../../../state/staff/hooks'
import { DeskQueue } from './DeskQueue'
import { useWalkIn } from './useWalkIn'
import { WalkInForm } from './WalkInForm'
import { WalkInEmergency, WalkInTicket } from './WalkInResult'

export function DeskConsole({ counter }: { counter: CounterRef }) {
  // Poll only: a desk tab beside the nurse and the display must not hold a connection of its own.
  const queue = useCounterQueue(counter.id, { stream: false })
  const { refetch, data } = queue
  const refresh = useCallback(() => void refetch(), [refetch])
  const walkIn = useWalkIn(refresh)
  const { result, clear } = walkIn
  const ticket = result?.emergency === false ? result.ticket : null
  const emergency = result?.emergency === true ? result : null

  // The slip is done once its ticket has left the queue, called and finished or wiped by a reset.
  const seen = useRef<string | null>(null)
  useEffect(() => {
    if (ticket === null || data === null) return
    const inQueue = data.tickets.some((row) => row.ticket_id === ticket.id)
    if (inQueue) seen.current = ticket.id
    else if (seen.current === ticket.id) clear()
  }, [ticket, data, clear])

  return (
    <div className="grid items-start gap-3 lg:grid-cols-[minmax(0,380px)_minmax(0,1fr)]">
      <div className="flex min-w-0 flex-col gap-3">
        <WalkInForm walkIn={walkIn} />
        {ticket !== null && <WalkInTicket ticket={ticket} />}
      </div>
      {/* The queue steps aside: no ticket number may sit next to "No ticket issued". */}
      {emergency === null ? (
        <DeskQueue counter={counter} queue={queue} />
      ) : (
        <WalkInEmergency reply={emergency.reply} onNext={clear} />
      )}
    </div>
  )
}
