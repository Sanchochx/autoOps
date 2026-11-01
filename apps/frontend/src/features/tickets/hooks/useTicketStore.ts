import { create } from 'zustand'
import type { Ticket } from '../models/ticket'
import { listTickets } from '../services/ticketApi'

export type TicketsLoadStatus = 'loading' | 'ready' | 'error'

interface TicketState {
  tickets: Ticket[]
  status: TicketsLoadStatus
  error: string | null
  refresh: () => Promise<void>
}

let inFlight: AbortController | null = null

/** Shared list state so the form can trigger a refetch without knowing the list component. */
export const useTicketStore = create<TicketState>((set, get) => ({
  tickets: [],
  status: 'loading',
  error: null,
  refresh: async () => {
    inFlight?.abort()
    const controller = new AbortController()
    inFlight = controller
    try {
      const tickets = await listTickets(controller.signal)
      set({ tickets, status: 'ready', error: null })
    } catch (error: unknown) {
      if (controller.signal.aborted) return
      // Keep the last good data on a failed poll; only surface the error when there is none.
      set({
        status: get().tickets.length > 0 ? 'ready' : 'error',
        error: error instanceof Error ? error.message : 'No se pudieron cargar los tickets',
      })
    }
  },
}))
