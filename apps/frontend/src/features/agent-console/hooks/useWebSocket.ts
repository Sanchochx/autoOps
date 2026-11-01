import { useEffect, useState } from 'react'
import type { ConnectionStatus } from '../models/agentMessage'
import { parseAgentEvent } from '../services/parseAgentEvent'
import { parsePayload } from '../services/parsePayload'
import { openReconnectingSocket } from '../services/reconnectingSocket'
import { resolveWsBaseUrl } from '../services/resolveWsBaseUrl'
import { useAgentActivityStore } from '../store/useAgentActivityStore'
import { useAiStore } from '../store/useAiStore'

/** Streaming channel path relative to VITE_WS_BASE_URL. */
const STREAM_PATH = '/stream'

/** Connects to the Gateway stream and dispatches messages to the store. */
export function useWebSocket(): ConnectionStatus {
  const addLog = useAiStore((state) => state.addLog)
  const applyEvent = useAgentActivityStore((state) => state.applyEvent)
  const baseUrl = import.meta.env.VITE_WS_BASE_URL
  const [status, setStatus] = useState<ConnectionStatus>(baseUrl ? 'connecting' : 'closed')

  useEffect(() => {
    if (!baseUrl) return undefined
    return openReconnectingSocket({
      url: `${resolveWsBaseUrl(baseUrl, window.location)}${STREAM_PATH}`,
      onMessage: (data) => {
        addLog(parsePayload(data))
        const event = parseAgentEvent(data)
        if (event) applyEvent(event)
      },
      onStatusChange: setStatus,
    })
  }, [addLog, applyEvent, baseUrl])

  return status
}
