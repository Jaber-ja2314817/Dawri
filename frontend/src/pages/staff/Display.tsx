import { DisplayScreen } from '../../features/staff/display/DisplayScreen'
import { useStaff } from '../../state/staff/session'

/* No StaffShell: this runs on a TV in the waiting room. The guard above has the session. */
export default function Display() {
  const { centre } = useStaff()
  return centre === null ? null : <DisplayScreen centre={centre} />
}
