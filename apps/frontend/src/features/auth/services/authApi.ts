import { buildApiUrl } from '../../../shared/buildApiUrl'

const LOGIN_PATH = '/api/v1/auth/login'

/** The login request failed; `message` is safe to show to the user. */
export class LoginError extends Error {
  readonly status: number

  constructor(status: number, message: string) {
    super(message)
    this.name = 'LoginError'
    this.status = status
  }
}

function detailOf(body: unknown, fallback: string): string {
  if (typeof body === 'object' && body !== null && 'detail' in body && typeof body.detail === 'string') {
    return body.detail
  }
  return fallback
}

/** Exchanges the credentials for an access token. Plain `fetch`: a 401 here is a wrong password, not an expired session. */
export async function login(username: string, password: string, signal?: AbortSignal): Promise<string> {
  const response = await fetch(buildApiUrl(import.meta.env.VITE_API_BASE_URL, LOGIN_PATH), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username, password }),
    signal,
  })
  const body: unknown = await response.json().catch(() => null)
  if (!response.ok) throw new LoginError(response.status, detailOf(body, `Error ${response.status}`))
  if (typeof body !== 'object' || body === null || !('access_token' in body) || typeof body.access_token !== 'string') {
    throw new LoginError(502, 'Invalid response from the server')
  }
  return body.access_token
}
