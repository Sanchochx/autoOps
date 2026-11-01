import type { AgentActivity, AgentEvent } from '../models/agentActivity'

const NOTE_PREFIX = 'investigator: '

/** Parses a raw frame into an `AgentEvent`; `null` if it is not a ticket-scoped `ai_event`. */
export function parseAgentEvent(raw: string): AgentEvent | null {
  let value: unknown
  try {
    value = JSON.parse(raw)
  } catch {
    return null
  }
  if (typeof value !== 'object' || value === null) return null
  const { type, ticket_id, node, message } = value as Record<string, unknown>
  if (
    type !== 'ai_event' ||
    typeof ticket_id !== 'string' ||
    typeof node !== 'string' ||
    typeof message !== 'string'
  ) {
    return null
  }
  return { ticketId: ticket_id, node, message }
}

/** Maps a graph node event to the ticket's activity; `null` for unknown nodes. */
export function toActivity(event: AgentEvent, previous?: AgentActivity): AgentActivity | null {
  switch (event.node) {
    case 'gateway':
      return { phase: 'triage' }
    case 'triage_node':
      return { phase: 'investigating' }
    case 'investigator_node':
      return {
        phase: 'saving',
        note: event.message.startsWith(NOTE_PREFIX)
          ? event.message.slice(NOTE_PREFIX.length)
          : event.message,
      }
    case 'database':
      return { phase: 'done', note: previous?.note }
    case 'error':
      return { phase: 'failed', note: previous?.note }
    default:
      return null
  }
}
