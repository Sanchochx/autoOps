export type TicketSeverity = 'low' | 'medium' | 'high' | 'critical'
export type TicketStatus = 'open' | 'investigating' | 'pending_approval' | 'resolved'

/** Ticket as returned by the Gateway (`TicketRead`). */
export interface Ticket {
  id: string
  title: string
  description: string
  severity: TicketSeverity
  status: TicketStatus
  createdAt: string
  updatedAt: string
}

/** What the user types; severity is injected by the client. */
export interface NewTicketInput {
  title: string
  description: string
}
