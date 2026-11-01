import { RefreshCw, Ticket } from 'lucide-react'
import { useTickets } from '../hooks/useTickets'
import { ClearTicketsButton } from './ClearTicketsButton'
import { DeleteTicketButton } from './DeleteTicketButton'
import { AgentActivityCell } from './AgentActivityCell'
import { SeverityBadge, StatusBadge } from './TicketBadges'

const TH = 'px-6 py-3 text-left text-xs font-medium'

export function TicketList(): React.JSX.Element {
  const { tickets, status, error, retry } = useTickets()

  return (
    <section aria-labelledby="ticket-list-title" className="overflow-hidden rounded-lg border border-line bg-surface shadow-card">
      <div className="flex items-center justify-between gap-3 border-b border-line px-6 py-4">
        <h2 id="ticket-list-title" className="text-lg font-semibold text-ink">
          Tickets
        </h2>
        <ClearTicketsButton disabled={tickets.length === 0} />
      </div>
      {status === 'loading' && (
        <p role="status" className="p-5 text-sm text-muted">
          Loading tickets…
        </p>
      )}
      {status === 'error' && (
        <div role="alert" className="flex items-center gap-3 p-5 text-sm text-red-300">
          <span>{error}</span>
          <button
            type="button"
            onClick={retry}
            className="flex items-center gap-1 rounded border border-danger/50 px-2 py-1 hover:bg-danger/10 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-danger"
          >
            <RefreshCw aria-hidden="true" className="size-3.5" />
            Retry
          </button>
        </div>
      )}
      {status === 'ready' && tickets.length === 0 && (
        <div className="flex flex-col items-center justify-center gap-3 px-6 py-16 text-center">
          <Ticket aria-hidden="true" className="size-12 text-slate-600" strokeWidth={1.5} />
          <p className="text-sm text-slate-300">
            <span className="block font-medium text-ink">No tickets yet.</span>
            Create the first one.
          </p>
        </div>
      )}
      {status === 'ready' && tickets.length > 0 && (
        <div
          role="region"
          aria-label="Tickets table"
          tabIndex={0}
          className="overflow-x-auto focus-visible:outline-2 focus-visible:outline-primary"
        >
          <table className="w-full border-collapse text-xs text-ink">
            <thead className="border-b border-line bg-field text-muted">
              <tr>
                <th scope="col" className={TH}>ID</th>
                <th scope="col" className={TH}>Title</th>
                <th scope="col" className={TH}>Status</th>
                <th scope="col" className={TH}>Severity</th>
                <th scope="col" className={TH}>Agent</th>
                <th scope="col" className={TH}>Created</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-line">
              {tickets.map((ticket) => (
                <tr key={ticket.id} className="transition-colors hover:bg-slate-800/50">
                  <td className="px-6 py-4 font-mono text-xs font-medium text-ink" title={ticket.id}>
                    {ticket.id.slice(0, 8)}
                  </td>
                  <td className="px-6 py-4 font-medium text-ink">{ticket.title}</td>
                  <td className="px-6 py-4"><StatusBadge status={ticket.status} /></td>
                  <td className="px-6 py-4"><SeverityBadge severity={ticket.severity} /></td>
                  <td className="px-6 py-4"><AgentActivityCell ticket={ticket} /></td>
                  <td className="px-6 py-4 font-mono text-[11px] whitespace-nowrap text-muted">
                    <div className="flex items-center gap-3">
                      <time dateTime={ticket.createdAt}>
                        {new Date(ticket.createdAt).toLocaleString()}
                      </time>
                      <DeleteTicketButton id={ticket.id} title={ticket.title} />
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}
