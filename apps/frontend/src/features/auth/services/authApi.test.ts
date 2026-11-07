import { afterEach, describe, expect, it, vi } from 'vitest'
import { useSessionStore } from '../store/useSessionStore'
import { LoginError, login } from './authApi'

afterEach(() => vi.unstubAllGlobals())

describe('login', () => {
  it('posts the credentials and returns the token', async () => {
    const fetchFn = vi.fn().mockResolvedValue(Response.json({ access_token: 'tok', token_type: 'bearer', expires_in: 3600 }))
    vi.stubGlobal('fetch', fetchFn)
    await expect(login('admin', 'pw')).resolves.toBe('tok')
    const [url, init] = fetchFn.mock.calls[0] as [string, RequestInit]
    expect(url).toMatch(/\/api\/v1\/auth\/login$/)
    expect(JSON.parse(init.body as string)).toEqual({ username: 'admin', password: 'pw' })
  })

  it('surfaces the server message and does NOT end a session on 401 (wrong password)', async () => {
    useSessionStore.setState({ token: 'existing', expired: false })
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(Response.json({ detail: 'Invalid username or password' }, { status: 401 })))
    await expect(login('admin', 'bad')).rejects.toMatchObject({ status: 401, message: 'Invalid username or password' })
    expect(useSessionStore.getState().token).toBe('existing')
  })

  it('reports rate limiting and malformed responses', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(Response.json({ detail: 'Too many failed attempts. Try again later.' }, { status: 429 })))
    await expect(login('a', 'b')).rejects.toBeInstanceOf(LoginError)
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(Response.json({ nope: true })))
    await expect(login('a', 'b')).rejects.toMatchObject({ status: 502 })
  })
})
