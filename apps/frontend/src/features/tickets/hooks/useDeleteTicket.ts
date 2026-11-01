import { useCallback, useState } from 'react'
import { deleteTicket } from '../services/ticketApi'
import { useTicketStore } from './useTicketStore'

interface UseDeleteTicket {
  deleting: boolean
  error: string | null
  /** Resolves `true` when the ticket was deleted. */
  remove: () => Promise<boolean>
}

export function useDeleteTicket(id: string): UseDeleteTicket {
  const refresh = useTicketStore((state) => state.refresh)
  const [deleting, setDeleting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const remove = useCallback(async (): Promise<boolean> => {
    setDeleting(true)
    setError(null)
    try {
      await deleteTicket(id)
      await refresh()
      return true
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Could not delete the ticket')
      return false
    } finally {
      setDeleting(false)
    }
  }, [id, refresh])

  return { deleting, error, remove }
}
