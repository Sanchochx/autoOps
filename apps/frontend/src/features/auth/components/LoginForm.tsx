import { Activity, LogIn } from 'lucide-react'
import { useId, useState, type ChangeEvent, type SyntheticEvent } from 'react'
import { useLogin } from '../hooks/useLogin'
import { useSessionStore } from '../store/useSessionStore'

const FIELD_CLASS =
  'w-full rounded-md border border-line bg-canvas px-3.5 py-2.5 text-sm text-ink transition-all duration-200 outline-none focus:border-primary focus:ring-2 focus:ring-primary/20 disabled:opacity-60'
const LABEL_CLASS = 'mb-1.5 block text-xs font-medium tracking-wide text-muted uppercase'

export function LoginForm(): React.JSX.Element {
  const usernameId = useId()
  const passwordId = useId()
  const { pending, error, submit } = useLogin()
  const expired = useSessionStore((state) => state.expired)
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')

  const handleSubmit = (event: SyntheticEvent<HTMLFormElement>): void => {
    event.preventDefault()
    void submit(username.trim(), password)
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-canvas p-4">
      <section aria-labelledby="login-title" className="w-full max-w-sm overflow-hidden rounded-lg border border-line bg-surface shadow-card">
        <div className="flex items-center gap-3 border-b border-line px-6 py-4">
          <span className="flex size-9 items-center justify-center rounded-lg bg-primary">
            <Activity aria-hidden="true" className="size-5 text-white" />
          </span>
          <h1 id="login-title" className="text-lg font-semibold text-ink">
            Sign in to AutoOps
          </h1>
        </div>
        <form onSubmit={handleSubmit} className="flex flex-col gap-5 p-6">
          {expired && !error && (
            <p role="status" className="rounded-lg border border-line bg-field px-3.5 py-2.5 text-xs font-medium text-ink">
              Your session has expired. Sign in again.
            </p>
          )}
          <div>
            <label htmlFor={usernameId} className={LABEL_CLASS}>
              Username
            </label>
            <input
              id={usernameId}
              type="text"
              autoComplete="username"
              required
              maxLength={64}
              value={username}
              disabled={pending}
              onChange={(e: ChangeEvent<HTMLInputElement>) => setUsername(e.target.value)}
              className={FIELD_CLASS}
            />
          </div>
          <div>
            <label htmlFor={passwordId} className={LABEL_CLASS}>
              Password
            </label>
            <input
              id={passwordId}
              type="password"
              autoComplete="current-password"
              required
              maxLength={256}
              value={password}
              disabled={pending}
              onChange={(e: ChangeEvent<HTMLInputElement>) => setPassword(e.target.value)}
              className={FIELD_CLASS}
            />
          </div>
          <button
            type="submit"
            disabled={pending}
            className="flex items-center justify-center gap-2 rounded-lg bg-primary px-4 py-2.5 text-xs font-semibold tracking-wide text-white transition-all duration-200 hover:bg-blue-500 disabled:opacity-60 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
          >
            <LogIn aria-hidden="true" className="size-4" />
            {pending ? 'Signing in…' : 'Sign in'}
          </button>
          {error && (
            <p role="alert" className="rounded-lg border border-danger/50 bg-danger/10 px-3.5 py-2.5 text-xs font-medium text-red-300">
              {error}
            </p>
          )}
        </form>
      </section>
    </main>
  )
}
