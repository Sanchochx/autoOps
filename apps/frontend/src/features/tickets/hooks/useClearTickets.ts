import { useCallback, useState } from 'react'
import { deleteAllTickets } from '../services/ticketApi'
import { useTicketStore } from './useTicketStore'

interface UseClearTickets {
  clearing: boolean
  error: string | null
  /** Resolves `true` when every ticket was deleted. */
  clear: () => Promise<boolean>
}

export function useClearTickets(): UseClearTickets {
  const refresh = useTicketStore((state) => state.refresh)
  const [clearing, setClearing] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const clear = useCallback(async (): Promise<boolean> => {
    setClearing(true)
    setError(null)
    try {
      await deleteAllTickets()
      await refresh()
      return true
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Could not clear the tickets')
      return false
    } finally {
      setClearing(false)
    }
  }, [refresh])

  return { clearing, error, clear }
}
