import { Dashboard } from './Dashboard'
import { LoginForm, useSessionStore } from './features/auth'

/** The session lives in memory: without a token (first visit, reload, 401) the login screen is shown. */
export default function App(): React.JSX.Element {
  const signedIn = useSessionStore((state) => state.token !== null)
  return signedIn ? <Dashboard /> : <LoginForm />
}
