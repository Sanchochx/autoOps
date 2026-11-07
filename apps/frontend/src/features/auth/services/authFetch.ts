import { useSessionStore } from '../store/useSessionStore'

/**
 * `fetch` for the protected API: adds the Bearer token and, when the server answers 401 to a request
 * that carried it, ends the session (the dashboard then shows the login screen and closes the stream).
 */
export async function authFetch(input: RequestInfo | URL, init: RequestInit = {}): Promise<Response> {
  const token = useSessionStore.getState().token
  const headers = new Headers(init.headers)
  if (token) headers.set('Authorization', `Bearer ${token}`)

  const response = await fetch(input, { ...init, headers })

  // Only act if that same token is still the session's: a late 401 must not sign out a newer login.
  if (response.status === 401 && token && useSessionStore.getState().token === token) {
    useSessionStore.getState().signOut('expired')
  }
  return response
}
