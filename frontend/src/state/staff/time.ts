const DOHA_TIME = new Intl.DateTimeFormat('en-GB', {
  hour: '2-digit',
  minute: '2-digit',
  hour12: false,
  timeZone: 'Asia/Qatar',
})

/** A wall clock in Doha, in Latin digits in both languages to match the ticket numbers. */
export function dohaTime(iso: string): string {
  return DOHA_TIME.format(new Date(iso))
}

export function minutesSince(iso: string, now = Date.now()): number {
  return Math.max(Math.floor((now - new Date(iso).getTime()) / 60_000), 0)
}
