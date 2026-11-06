import type { StaffRole } from '../../api/staffTypes'

export const ROLE_ORDER: StaffRole[] = ['nurse', 'doctor', 'pharmacist', 'desk']

const HOME: Record<StaffRole, string> = {
  nurse: '/staff/nurse',
  doctor: '/staff/doctor',
  pharmacist: '/staff/pharmacy',
  desk: '/staff/desk',
}

export function roleHome(role: StaffRole): string {
  return HOME[role]
}
