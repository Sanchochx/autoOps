import { afterEach, describe, expect, it, vi } from 'vitest'
import { ApiError, createTicket, deleteAllTickets, listTickets, toTicket } from './ticketApi'

const RAW = {
  id: '3f2b8c1e-0000-4000-8000-000000000001',
  title: 'DB down',
  description: 'Connection refused',
  severity: 'high',
  status: 'open',
  analysis: null,
  created_at: '2026-11-01T10:00:00Z',
  updated_at: '2026-11-01T10:00:00Z',
}

function mockFetch(response: Response): ReturnType<typeof vi.fn> {
  const fn = vi.fn().mockResolvedValue(response)
  vi.stubGlobal('fetch', fn)
  return fn
}

afterEach(() => vi.unstubAllGlobals())

describe('toTicket', () => {
  it('maps a valid payload', () => {
    expect(toTicket(RAW)).toMatchObject({ id: RAW.id, createdAt: RAW.created_at })
  })
  it('keeps a persisted analysis and the escalated status', () => {
    const ticket = toTicket({ ...RAW, status: 'escalated', analysis: 'Pool saturado' })
    expect(ticket).toMatchObject({ status: 'escalated', analysis: 'Pool saturado' })
  })
  it('treats a missing analysis as null and rejects a non-string one', () => {
    const { analysis: _omitted, ...legacy } = RAW
    expect(toTicket(legacy)?.analysis).toBeNull()
    expect(toTicket({ ...RAW, analysis: 42 })).toBeNull()
  })
  it('rejects malformed payloads', () => {
    expect(toTicket({ ...RAW, severity: 'urgent' })).toBeNull()
    expect(toTicket(null)).toBeNull()
  })
})

describe('createTicket', () => {
  it('posts to the relative path injecting severity medium', async () => {
    const fetchFn = mockFetch(Response.json({ ...RAW, severity: 'medium' }, { status: 201 }))
    await createTicket({ title: 'a', description: 'b' })
    const [url, init] = fetchFn.mock.calls[0] as [string, RequestInit]
    expect(url).toMatch(/\/api\/v1\/tickets$/)
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({
      title: 'a',
      description: 'b',
      severity: 'medium',
    })
  })

  it('raises ApiError with the gateway detail', async () => {
    mockFetch(Response.json({ detail: 'Boom' }, { status: 500 }))
    await expect(createTicket({ title: 'a', description: 'b' })).rejects.toMatchObject({
      status: 500,
      message: 'Boom',
    })
  })
})

describe('listTickets', () => {
  it('returns validated tickets', async () => {
    mockFetch(Response.json([RAW]))
    expect(await listTickets()).toHaveLength(1)
  })
  it('rejects an invalid body', async () => {
    mockFetch(Response.json({ nope: true }))
    await expect(listTickets()).rejects.toBeInstanceOf(ApiError)
  })
})

describe('deleteAllTickets', () => {
  it('sends DELETE to the collection path', async () => {
    const fetchFn = mockFetch(new Response(null, { status: 204 }))
    await deleteAllTickets()
    const [url, init] = fetchFn.mock.calls[0] as [string, RequestInit]
    expect(url).toMatch(/\/api\/v1\/tickets$/)
    expect(init.method).toBe('DELETE')
  })
  it('raises ApiError on failure', async () => {
    mockFetch(Response.json({ detail: 'No' }, { status: 500 }))
    await expect(deleteAllTickets()).rejects.toMatchObject({ status: 500 })
  })
})
