import { useCallback, useState } from 'react'
import { login } from '../services/authApi'
import { useSessionStore } from '../store/useSessionStore'

interface UseLogin {
  pending: boolean
  error: string | null
  submit: (username: string, password: string) => Promise<void>
}

export function useLogin(): UseLogin {
  const signIn = useSessionStore((state) => state.signIn)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const submit = useCallback(
    async (username: string, password: string): Promise<void> => {
      setPending(true)
      setError(null)
      try {
        signIn(await login(username, password))
      } catch (err: unknown) {
        setError(err instanceof Error ? err.message : 'Could not sign in')
        setPending(false)
      }
    },
    [signIn],
  )

  return { pending, error, submit }
}
