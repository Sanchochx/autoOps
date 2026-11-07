import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { openReconnectingSocket, WS_UNAUTHORIZED } from './reconnectingSocket'

class FakeSocket {
  static instances: FakeSocket[] = []
  onopen: (() => void) | null = null
  onmessage: ((event: MessageEvent<unknown>) => void) | null = null
  onclose: ((event: CloseEvent) => void) | null = null
  sent: string[] = []
  closed = false
  readonly url: string
  constructor(url: string) {
    this.url = url
    FakeSocket.instances.push(this)
  }
  send(data: string): void {
    this.sent.push(data)
  }
  close(): void {
    this.closed = true
    this.onclose?.({ code: 1000 } as CloseEvent)
  }
}

function open(
  overrides: Partial<Parameters<typeof openReconnectingSocket>[0]> = {},
): { stop: () => void; onUnauthorized: ReturnType<typeof vi.fn>; statuses: string[] } {
  const onUnauthorized = vi.fn()
  const statuses: string[] = []
  const stop = openReconnectingSocket({
    url: 'wss://example.test/ws/stream',
    token: 'tok',
    onMessage: () => undefined,
    onStatusChange: (s) => statuses.push(s),
    onUnauthorized,
    ...overrides,
  })
  return { stop, onUnauthorized, statuses }
}

beforeEach(() => {
  FakeSocket.instances = []
  vi.useFakeTimers()
  vi.stubGlobal('WebSocket', FakeSocket)
})
afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe('openReconnectingSocket', () => {
  it('sends the token as the first message and keeps it out of the URL', () => {
    open()
    const socket = FakeSocket.instances[0]
    socket.onopen?.()
    expect(socket.sent).toEqual([JSON.stringify({ type: 'auth', token: 'tok' })])
    expect(socket.url).not.toContain('tok')
  })

  it('on close 4401 it reports unauthorized and never reconnects', () => {
    const { onUnauthorized } = open()
    FakeSocket.instances[0].onclose?.({ code: WS_UNAUTHORIZED } as CloseEvent)
    vi.advanceTimersByTime(120_000)
    expect(onUnauthorized).toHaveBeenCalledOnce()
    expect(FakeSocket.instances).toHaveLength(1)
  })

  it('reconnects with backoff after an ordinary drop and re-authenticates', () => {
    open()
    FakeSocket.instances[0].onclose?.({ code: 1006 } as CloseEvent)
    vi.advanceTimersByTime(1_000)
    expect(FakeSocket.instances).toHaveLength(2)
    FakeSocket.instances[1].onopen?.()
    expect(FakeSocket.instances[1].sent[0]).toContain('"type":"auth"')
  })

  it('the returned stop function closes the socket and cancels pending retries', () => {
    const { stop } = open()
    FakeSocket.instances[0].onclose?.({ code: 1006 } as CloseEvent)
    stop()
    vi.advanceTimersByTime(120_000)
    expect(FakeSocket.instances).toHaveLength(1)
    const second = open()
    second.stop()
    expect(FakeSocket.instances[1].closed).toBe(true)
  })
})
