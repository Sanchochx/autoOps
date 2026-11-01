export type AgentPhase = 'triage' | 'investigating' | 'saving' | 'done' | 'failed'

/** Latest known progress of the agents on one ticket, derived from the stream events. */
export interface AgentActivity {
  phase: AgentPhase
  /** Investigator analysis, once available. */
  note?: string
}

/** Structured `ai_event` sent by the Gateway for a ticket. */
export interface AgentEvent {
  ticketId: string
  node: string
  message: string
}
