export type TicketSeverity = 'low' | 'medium' | 'high' | 'critical'
export type TicketStatus = 'open' | 'investigating' | 'pending_approval' | 'escalated' | 'resolved'

/** Ticket as returned by the Gateway (`TicketRead`). */
export interface Ticket {
  id: string
  title: string
  description: string
  severity: TicketSeverity
  status: TicketStatus
  /** Root-cause analysis persisted by the Investigator; null until the agents finish. */
  analysis: string | null
  createdAt: string
  updatedAt: string
}

/** What the user types; severity is injected by the client. */
export interface NewTicketInput {
  title: string
  description: string
}
