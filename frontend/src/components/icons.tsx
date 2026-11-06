import type { ReactNode, SVGProps } from 'react'
import { cx } from '../lib/cx'

/* One outline set, drawn on a 24 grid at 1.5. Default size 16, for use at 14-20. */

export type IconName =
  | 'check'
  | 'mic'
  | 'stop'
  | 'send'
  | 'chevron'
  | 'pin'
  | 'phone'
  | 'list'
  | 'map'

export interface IconProps extends Omit<SVGProps<SVGSVGElement>, 'name'> {
  size?: number
}

const PATHS: Record<IconName, ReactNode> = {
  check: <path d="m5 12.5 4.5 4.5L19 7.5" />,
  mic: (
    <>
      <rect x="9" y="3" width="6" height="11" rx="3" />
      <path d="M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3" />
    </>
  ),
  stop: <rect x="6" y="6" width="12" height="12" rx="1.5" />,
  send: <path d="M4 12h15M13 6l6 6-6 6" />,
  chevron: <path d="m9.5 6 6 6-6 6" />,
  pin: (
    <>
      <path d="M12 21s7-6.1 7-11.5a7 7 0 1 0-14 0C5 14.9 12 21 12 21Z" />
      <circle cx="12" cy="9.5" r="2.5" />
    </>
  ),
  phone: (
    <path d="M6.6 3.5h2.2c.5 0 1 .3 1.1.8l.9 3.3c.1.4 0 .9-.4 1.2L9 10.1c1 2.1 2.8 3.9 4.9 4.9l1.3-1.4c.3-.4.8-.5 1.2-.4l3.3.9c.5.1.8.6.8 1.1v2.2c0 1.2-1 2.2-2.2 2.1C10.2 19.1 4.9 13.8 4.5 5.7c-.1-1.2.9-2.2 2.1-2.2Z" />
  ),
  list: <path d="M8.5 6.5H20M8.5 12H20M8.5 17.5H20M4 6.5h.5M4 12h.5M4 17.5h.5" />,
  map: <path d="m9 4.5-5 2v13l5-2 6 2 5-2v-13l-5 2-6-2ZM9 4.5v13M15 6.5v13" />,
}

// What points along the reading direction mirrors with it.
const DIRECTIONAL: Partial<Record<IconName, string>> = {
  chevron: 'rtl:-scale-x-100',
  send: 'rtl:-scale-x-100',
}

export function Icon({ name, size = 16, className, ...rest }: IconProps & { name: IconName }) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      className={cx('shrink-0', DIRECTIONAL[name], className)}
      {...rest}
    >
      {PATHS[name]}
    </svg>
  )
}

const named = (name: IconName) => (props: IconProps) => <Icon name={name} {...props} />

export const CheckIcon = named('check')
export const MicIcon = named('mic')
export const StopIcon = named('stop')
export const SendIcon = named('send')
export const PinIcon = named('pin')
export const PhoneIcon = named('phone')
export const ListIcon = named('list')
export const MapIcon = named('map')

/** Points forward along the reading direction. `back` turns it round, for a back control. */
export function ChevronIcon({ back, className, ...rest }: IconProps & { back?: boolean }) {
  return <Icon name="chevron" className={cx(back && '-scale-x-100 rtl:scale-x-100', className)} {...rest} />
}
