import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useSessionStore } from '../store/useSessionStore'
import { authFetch } from './authFetch'

function mockFetch(response: Response): ReturnType<typeof vi.fn> {
  const fn = vi.fn().mockResolvedValue(response)
  vi.stubGlobal('fetch', fn)
  return fn
}

function sentHeaders(fn: ReturnType<typeof vi.fn>): Headers {
  const [, init] = fn.mock.calls[0] as [string, RequestInit]
  return new Headers(init.headers)
}

beforeEach(() => useSessionStore.setState({ token: null, expired: false }))
afterEach(() => vi.unstubAllGlobals())

describe('authFetch', () => {
  it('adds the Bearer header and keeps the caller headers and options', async () => {
    useSessionStore.getState().signIn('tok')
    const fetchFn = mockFetch(Response.json([]))
    await authFetch('/api/v1/tickets', { method: 'POST', headers: { 'Content-Type': 'application/json' } })
    const headers = sentHeaders(fetchFn)
    expect(headers.get('Authorization')).toBe('Bearer tok')
    expect(headers.get('Content-Type')).toBe('application/json')
    expect((fetchFn.mock.calls[0] as [string, RequestInit])[1].method).toBe('POST')
  })

  it('sends no Authorization header when signed out', async () => {
    const fetchFn = mockFetch(Response.json([]))
    await authFetch('/api/v1/tickets')
    expect(sentHeaders(fetchFn).has('Authorization')).toBe(false)
  })

  it('a 401 to an authenticated request signs out and flags the session as expired', async () => {
    useSessionStore.getState().signIn('tok')
    mockFetch(Response.json({ detail: 'Invalid or expired token' }, { status: 401 }))
    const response = await authFetch('/api/v1/tickets')
    expect(response.status).toBe(401)
    expect(useSessionStore.getState()).toMatchObject({ token: null, expired: true })
  })

  it('other errors do not end the session', async () => {
    useSessionStore.getState().signIn('tok')
    mockFetch(Response.json({ detail: 'Boom' }, { status: 500 }))
    await authFetch('/api/v1/tickets')
    expect(useSessionStore.getState().token).toBe('tok')
  })

  it('a late 401 for an old token does not sign out a newer session', async () => {
    useSessionStore.getState().signIn('old')
    vi.stubGlobal(
      'fetch',
      vi.fn().mockImplementation(async () => {
        useSessionStore.getState().signIn('new')
        return Response.json({}, { status: 401 })
      }),
    )
    await authFetch('/api/v1/tickets')
    expect(useSessionStore.getState().token).toBe('new')
  })

  it('a 401 without a token (not signed in) changes nothing', async () => {
    mockFetch(Response.json({}, { status: 401 }))
    await authFetch('/api/v1/tickets')
    expect(useSessionStore.getState()).toMatchObject({ token: null, expired: false })
  })
})
