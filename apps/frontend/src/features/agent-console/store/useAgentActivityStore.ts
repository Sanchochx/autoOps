import { create } from 'zustand'
import type { AgentActivity, AgentEvent } from '../models/agentActivity'
import { toActivity } from '../services/parseAgentEvent'

interface AgentActivityState {
  byTicket: Record<string, AgentActivity>
  applyEvent: (event: AgentEvent) => void
}

export const useAgentActivityStore = create<AgentActivityState>((set) => ({
  byTicket: {},
  applyEvent: (event): void =>
    set((state) => {
      const next = toActivity(event, state.byTicket[event.ticketId])
      return next ? { byTicket: { ...state.byTicket, [event.ticketId]: next } } : state
    }),
}))

/** Activity of one ticket (re-renders only when that ticket changes). */
export function useAgentActivity(ticketId: string): AgentActivity | undefined {
  return useAgentActivityStore((state) => state.byTicket[ticketId])
}
