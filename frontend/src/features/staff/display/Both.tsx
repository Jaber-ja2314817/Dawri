import { translate, type Vars } from '../../../i18n'

/** This screen never follows the viewer's language: everyone in the room reads it. */
export function Both({
  name,
  vars,
  className,
}: {
  name: string
  vars?: Vars
  className?: string
}) {
  return (
    <span className={className}>
      <span lang="en" dir="ltr">
        {translate('en', name, vars)}
      </span>
      {' / '}
      <span lang="ar" dir="rtl">
        {translate('ar', name, vars)}
      </span>
    </span>
  )
}
