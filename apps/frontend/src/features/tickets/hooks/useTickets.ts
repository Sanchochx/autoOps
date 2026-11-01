import { useEffect } from 'react'
import { useTicketStore, type TicketsLoadStatus } from './useTicketStore'
import type { Ticket } from '../models/ticket'

const DEFAULT_POLL_INTERVAL_MS = 5000

/** Poll interval from VITE_TICKETS_POLL_INTERVAL_MS; `0` disables polling. */
export function resolvePollInterval(raw: string | undefined): number {
  if (raw === undefined || raw.trim() === '') return DEFAULT_POLL_INTERVAL_MS
  const value = Number(raw)
  return Number.isFinite(value) && value >= 0 ? value : DEFAULT_POLL_INTERVAL_MS
}

interface UseTickets {
  tickets: Ticket[]
  status: TicketsLoadStatus
  error: string | null
  retry: () => void
}

/** Loads the tickets and keeps them fresh; polling pauses while the tab is hidden. */
export function useTickets(): UseTickets {
  const tickets = useTicketStore((state) => state.tickets)
  const status = useTicketStore((state) => state.status)
  const error = useTicketStore((state) => state.error)
  const refresh = useTicketStore((state) => state.refresh)

  useEffect(() => {
    const intervalMs = resolvePollInterval(import.meta.env.VITE_TICKETS_POLL_INTERVAL_MS)
    let timer: ReturnType<typeof setInterval> | undefined

    const stop = (): void => {
      if (timer !== undefined) clearInterval(timer)
      timer = undefined
    }
    const start = (): void => {
      stop()
      if (intervalMs > 0) timer = setInterval(() => void refresh(), intervalMs)
    }
    const onVisibility = (): void => {
      if (document.hidden) {
        stop()
      } else {
        void refresh()
        start()
      }
    }

    void refresh()
    if (!document.hidden) start()
    document.addEventListener('visibilitychange', onVisibility)
    return () => {
      stop()
      document.removeEventListener('visibilitychange', onVisibility)
    }
  }, [refresh])

  return { tickets, status, error, retry: () => void refresh() }
}
