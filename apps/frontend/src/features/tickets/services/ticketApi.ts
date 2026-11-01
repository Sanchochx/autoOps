import type { NewTicketInput, Ticket, TicketSeverity, TicketStatus } from '../models/ticket'
import { buildApiUrl } from './buildApiUrl'

const TICKETS_PATH = '/api/v1/tickets'
const DEFAULT_SEVERITY: TicketSeverity = 'medium'
const SEVERITIES: readonly string[] = ['low', 'medium', 'high', 'critical']
const STATUSES: readonly string[] = ['open', 'investigating', 'pending_approval', 'escalated', 'resolved']

/** Non-2xx response from the Gateway. */
export class ApiError extends Error {
  readonly status: number

  constructor(status: number, message: string) {
    super(message)
    this.name = 'ApiError'
    this.status = status
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

function isString(value: unknown): value is string {
  return typeof value === 'string'
}

/** Validates one `TicketRead` and maps it to the `Ticket` model; `null` if malformed. */
export function toTicket(value: unknown): Ticket | null {
  if (!isRecord(value)) return null
  const { id, title, description, severity, status, analysis, created_at, updated_at } = value
  if (
    !isString(id) || !isString(title) || !isString(description) ||
    !isString(severity) || !SEVERITIES.includes(severity) ||
    !isString(status) || !STATUSES.includes(status) ||
    (analysis !== undefined && analysis !== null && !isString(analysis)) ||
    !isString(created_at) || !isString(updated_at)
  ) {
    return null
  }
  return {
    id,
    title,
    description,
    severity: severity as TicketSeverity,
    status: status as TicketStatus,
    analysis: isString(analysis) ? analysis : null,
    createdAt: created_at,
    updatedAt: updated_at,
  }
}

async function errorFrom(response: Response): Promise<ApiError> {
  let detail = `Error ${response.status}`
  try {
    const body: unknown = await response.json()
    if (isRecord(body) && isString(body.detail)) detail = body.detail
  } catch {
    // Body is not JSON; keep the generic message.
  }
  return new ApiError(response.status, detail)
}

function ticketsUrl(): string {
  return buildApiUrl(import.meta.env.VITE_API_BASE_URL, TICKETS_PATH)
}

function requireTicket(value: unknown): Ticket {
  const ticket = toTicket(value)
  if (!ticket) throw new ApiError(502, 'Respuesta inválida del servidor')
  return ticket
}

export async function createTicket(input: NewTicketInput, signal?: AbortSignal): Promise<Ticket> {
  const response = await fetch(ticketsUrl(), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...input, severity: DEFAULT_SEVERITY }),
    signal,
  })
  if (!response.ok) throw await errorFrom(response)
  return requireTicket(await response.json())
}

/** Deletes every ticket (irreversible). */
export async function deleteAllTickets(signal?: AbortSignal): Promise<void> {
  const response = await fetch(ticketsUrl(), { method: 'DELETE', signal })
  if (!response.ok) throw await errorFrom(response)
}

export async function listTickets(signal?: AbortSignal): Promise<Ticket[]> {
  const response = await fetch(ticketsUrl(), { signal })
  if (!response.ok) throw await errorFrom(response)
  const body: unknown = await response.json()
  if (!Array.isArray(body)) throw new ApiError(502, 'Respuesta inválida del servidor')
  return body.map(requireTicket)
}
