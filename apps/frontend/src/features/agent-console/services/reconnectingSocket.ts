import type { ConnectionStatus } from '../models/agentMessage'

const INITIAL_DELAY_MS = 1_000
const MAX_DELAY_MS = 30_000
/** Close code the Gateway uses when the token is missing, invalid or expired (apps/api_gateway/routers/ws.py). */
export const WS_UNAUTHORIZED = 4401

interface SocketOptions {
  url: string
  /** Sent as the first message; it never goes in the URL because the proxy logs URLs. */
  token: string
  /** The Gateway rejected the token (4401): the socket stops for good and does not retry. */
  onUnauthorized: () => void
  onMessage: (data: string) => void
  onStatusChange: (status: ConnectionStatus) => void
}

/**
 * Opens a WebSocket and reconnects it with growing (capped) backoff if it drops.
 * Returns a function that closes the connection and cancels retries.
 */
export function openReconnectingSocket(options: SocketOptions): () => void {
  let socket: WebSocket | null = null
  let retryTimer: ReturnType<typeof setTimeout> | undefined
  let delay = INITIAL_DELAY_MS
  let stopped = false

  const connect = (): void => {
    options.onStatusChange('connecting')
    socket = new WebSocket(options.url)

    socket.onopen = (): void => {
      socket?.send(JSON.stringify({ type: 'auth', token: options.token }))
      delay = INITIAL_DELAY_MS
      options.onStatusChange('open')
    }
    socket.onmessage = (event: MessageEvent<unknown>): void => {
      if (typeof event.data === 'string') options.onMessage(event.data)
    }
    socket.onclose = (event: CloseEvent): void => {
      options.onStatusChange('closed')
      if (stopped) return
      if (event.code === WS_UNAUTHORIZED) {
        stopped = true
        options.onUnauthorized()
        return
      }
      retryTimer = setTimeout(connect, delay)
      delay = Math.min(delay * 2, MAX_DELAY_MS)
    }
  }

  connect()

  return (): void => {
    stopped = true
    clearTimeout(retryTimer)
    socket?.close()
  }
}
