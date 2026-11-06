export interface Point {
  lat: number
  lng: number
}

export const LOCATION_TIMEOUT_MS = 10_000

/** One reading, only ever on a tap, so no permission prompt can appear on its own. */
export function currentPosition(): Promise<Point> {
  return new Promise((resolve, reject) => {
    if (!('geolocation' in navigator)) {
      reject(new Error('geolocation is not available'))
      return
    }
    navigator.geolocation.getCurrentPosition(
      ({ coords }) => resolve({ lat: coords.latitude, lng: coords.longitude }),
      reject,
      { timeout: LOCATION_TIMEOUT_MS },
    )
  })
}
