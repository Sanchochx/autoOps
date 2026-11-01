import type { TicketSeverity, TicketStatus } from '../models/ticket'

const SEVERITY: Record<TicketSeverity, { label: string; className: string }> = {
  low: { label: 'Low', className: 'border border-[#f59e0b] bg-[#f59e0b]/10 text-amber-300' },
  medium: { label: 'Medium', className: 'border border-yellow-500 bg-yellow-500/10 text-yellow-300' },
  high: { label: 'High', className: 'border border-orange-500 bg-orange-500/10 text-orange-300' },
  critical: { label: 'Critical', className: 'border border-danger bg-danger/10 text-red-300' },
}

const STATUS: Record<TicketStatus, { label: string; className: string }> = {
  open: { label: 'Open', className: 'border border-primary bg-primary/10 text-blue-300' },
  investigating: { label: 'Investigating', className: 'border border-cyan-500 bg-cyan-500/10 text-cyan-300' },
  pending_approval: { label: 'Pending approval', className: 'border border-[#f59e0b] bg-[#f59e0b]/10 text-amber-300' },
  escalated: { label: 'Escalated', className: 'border border-[#a855f7] bg-[#a855f7]/10 text-purple-300' },
  resolved: { label: 'Resolved', className: 'border border-success bg-success/10 text-emerald-300' },
}

const BASE = 'inline-block rounded-full px-2.5 py-0.5 text-[11px] font-semibold whitespace-nowrap'

/** Text labels carry the meaning; color is only reinforcement. */
export function SeverityBadge({ severity }: { severity: TicketSeverity }): React.JSX.Element {
  const { label, className } = SEVERITY[severity]
  return <span className={`${BASE} ${className}`}>{label}</span>
}

export function StatusBadge({ status }: { status: TicketStatus }): React.JSX.Element {
  const { label, className } = STATUS[status]
  return <span className={`${BASE} ${className}`}>{label}</span>
}
