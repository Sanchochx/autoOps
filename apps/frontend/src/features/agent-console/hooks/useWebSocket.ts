import { useEffect, useState } from 'react'
import type { ConnectionStatus } from '../models/agentMessage'
import { parsePayload } from '../services/parsePayload'
import { openReconnectingSocket } from '../services/reconnectingSocket'
import { resolveWsBaseUrl } from '../services/resolveWsBaseUrl'
import { useAiStore } from '../store/useAiStore'

/** Streaming channel path relative to VITE_WS_BASE_URL. */
const STREAM_PATH = '/stream'

/** Connects to the Gateway stream and dispatches messages to the store. */
export function useWebSocket(): ConnectionStatus {
  const addLog = useAiStore((state) => state.addLog)
  const baseUrl = import.meta.env.VITE_WS_BASE_URL
  const [status, setStatus] = useState<ConnectionStatus>(baseUrl ? 'connecting' : 'closed')

  useEffect(() => {
    if (!baseUrl) return undefined
    return openReconnectingSocket({
      url: `${resolveWsBaseUrl(baseUrl, window.location)}${STREAM_PATH}`,
      onMessage: (data) => addLog(parsePayload(data)),
      onStatusChange: setStatus,
    })
  }, [addLog, baseUrl])

  return status
}
