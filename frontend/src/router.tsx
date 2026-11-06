import {
  createBrowserRouter,
  Navigate,
  Outlet,
  ScrollRestoration,
} from 'react-router-dom'
import Centre from './pages/patient/Centre'
import Chat from './pages/patient/Chat'
import Complete from './pages/patient/Complete'
import Consent from './pages/patient/Consent'
import Emergency from './pages/patient/Emergency'
import History from './pages/patient/History'
import Home from './pages/patient/Home'
import Login from './pages/patient/Login'
import NotFound from './pages/patient/NotFound'
import Refill from './pages/patient/Refill'
import Reserved from './pages/patient/Reserved'
import Ticket from './pages/patient/Ticket'
import VisitRedirect from './pages/patient/VisitRedirect'
import Welcome from './pages/patient/Welcome'
import Who from './pages/patient/Who'
import { RequireStaff, StaffIndex } from './components/staff/RequireStaff'
import Dashboard from './pages/staff/Dashboard'
import Desk from './pages/staff/Desk'
import Display from './pages/staff/Display'
import DoctorConsole from './pages/staff/DoctorConsole'
import StaffLogin from './pages/staff/Login'
import NurseHandoff from './pages/staff/NurseHandoff'
import NurseQueue from './pages/staff/NurseQueue'
import NurseVisit from './pages/staff/NurseVisit'
import PharmacyConsole from './pages/staff/PharmacyConsole'
import StaffNotFound from './pages/staff/StaffNotFound'
import { useSession } from './state/session'
import { StaffSessionProvider } from './state/staff/session'

function Root() {
  return (
    <>
      <ScrollRestoration />
      <Outlet />
    </>
  )
}

function RequireSession() {
  const { token } = useSession()
  return token === null ? <Navigate to="/login" replace /> : <Outlet />
}

function SignedOutOnly() {
  const { token } = useSession()
  return token === null ? <Outlet /> : <Navigate to="/home" replace />
}

/* Only the staff routes hold this provider, so a patient page never reads a staff session. */
function StaffRoot() {
  return (
    <StaffSessionProvider>
      <Outlet />
    </StaffSessionProvider>
  )
}

export const router = createBrowserRouter([
  {
    element: <Root />,
    children: [
      {
        path: '/staff',
        element: <StaffRoot />,
        children: [
          { index: true, element: <StaffIndex /> },
          { path: 'login', element: <StaffLogin /> },
          {
            element: <RequireStaff roles={['nurse']} />,
            children: [
              { path: 'nurse', element: <NurseQueue /> },
              { path: 'nurse/:visitId', element: <NurseVisit /> },
              { path: 'nurse/:visitId/handoff', element: <NurseHandoff /> },
            ],
          },
          {
            element: <RequireStaff roles={['doctor']} />,
            children: [{ path: 'doctor', element: <DoctorConsole /> }],
          },
          {
            element: <RequireStaff roles={['pharmacist']} />,
            children: [{ path: 'pharmacy', element: <PharmacyConsole /> }],
          },
          {
            element: <RequireStaff roles={['desk', 'nurse']} />,
            children: [{ path: 'desk', element: <Desk /> }],
          },
          {
            element: <RequireStaff />,
            children: [
              { path: 'display', element: <Display /> },
              { path: 'dashboard', element: <Dashboard /> },
            ],
          },
          { path: '*', element: <StaffNotFound /> },
        ],
      },
      {
        element: <SignedOutOnly />,
        children: [
          { path: '/', element: <Welcome /> },
          { path: '/login', element: <Login /> },
        ],
      },
      {
        element: <RequireSession />,
        children: [
          { path: '/home', element: <Home /> },
          { path: '/check-in/who', element: <Who /> },
          { path: '/check-in/consent', element: <Consent /> },
          { path: '/history', element: <History /> },
          { path: '/visit/:id', element: <VisitRedirect /> },
          { path: '/visit/:id/chat', element: <Chat /> },
          { path: '/visit/:id/emergency', element: <Emergency /> },
          { path: '/visit/:id/refill', element: <Refill /> },
          { path: '/visit/:id/centre', element: <Centre /> },
          { path: '/visit/:id/reserved', element: <Reserved /> },
          { path: '/visit/:id/ticket', element: <Ticket /> },
          { path: '/visit/:id/complete', element: <Complete /> },
          { path: '*', element: <NotFound /> },
        ],
      },
    ],
  },
])
