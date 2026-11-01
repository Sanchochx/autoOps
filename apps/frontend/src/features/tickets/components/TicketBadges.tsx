import type { TicketSeverity, TicketStatus } from '../models/ticket'

const SEVERITY: Record<TicketSeverity, { label: string; className: string }> = {
  low: { label: 'Baja', className: 'bg-slate-200 text-slate-900' },
  medium: { label: 'Media', className: 'bg-amber-100 text-amber-950' },
  high: { label: 'Alta', className: 'bg-orange-200 text-orange-950' },
  critical: { label: 'Crítica', className: 'bg-red-700 text-white' },
}

const STATUS: Record<TicketStatus, { label: string; className: string }> = {
  open: { label: 'Abierto', className: 'bg-sky-100 text-sky-950' },
  investigating: { label: 'Investigando', className: 'bg-violet-100 text-violet-950' },
  pending_approval: { label: 'Pendiente de aprobación', className: 'bg-amber-100 text-amber-950' },
  escalated: { label: 'Escalado', className: 'bg-indigo-100 text-indigo-950' },
  resolved: { label: 'Resuelto', className: 'bg-emerald-100 text-emerald-950' },
}

const BASE = 'inline-block rounded px-2 py-0.5 text-xs font-medium whitespace-nowrap'

/** Text labels carry the meaning; color is only reinforcement. */
export function SeverityBadge({ severity }: { severity: TicketSeverity }): React.JSX.Element {
  const { label, className } = SEVERITY[severity]
  return <span className={`${BASE} ${className}`}>{label}</span>
}

export function StatusBadge({ status }: { status: TicketStatus }): React.JSX.Element {
  const { label, className } = STATUS[status]
  return <span className={`${BASE} ${className}`}>{label}</span>
}
