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
import { useSession } from './state/session'

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

export const router = createBrowserRouter([
  {
    element: <Root />,
    children: [
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
          { path: '/staff/*', element: <NotFound /> },
          { path: '*', element: <NotFound /> },
        ],
      },
    ],
  },
])
