import { useCallback, useState } from 'react'
import type { NewTicketInput } from '../models/ticket'
import { createTicket } from '../services/ticketApi'
import { useTicketStore } from './useTicketStore'

export type CreateStatus = 'idle' | 'pending' | 'success' | 'error'

interface UseCreateTicket {
  status: CreateStatus
  error: string | null
  /** Resolves `true` when the ticket was created. */
  submit: (input: NewTicketInput) => Promise<boolean>
}

export function useCreateTicket(): UseCreateTicket {
  const refresh = useTicketStore((state) => state.refresh)
  const [status, setStatus] = useState<CreateStatus>('idle')
  const [error, setError] = useState<string | null>(null)

  const submit = useCallback(
    async (input: NewTicketInput): Promise<boolean> => {
      setStatus('pending')
      setError(null)
      try {
        await createTicket(input)
        setStatus('success')
        void refresh()
        return true
      } catch (err: unknown) {
        setStatus('error')
        setError(err instanceof Error ? err.message : 'No se pudo crear el ticket')
        return false
      }
    },
    [refresh],
  )

  return { status, error, submit }
}
