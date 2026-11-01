import { RefreshCw } from 'lucide-react'
import { useTickets } from '../hooks/useTickets'
import { AgentActivityCell } from './AgentActivityCell'
import { SeverityBadge, StatusBadge } from './TicketBadges'

const TH = 'px-3 py-2 text-left font-medium'

export function TicketList(): React.JSX.Element {
  const { tickets, status, error, retry } = useTickets()

  return (
    <section aria-labelledby="ticket-list-title" className="rounded-lg bg-white p-4 shadow-sm">
      <h2 id="ticket-list-title" className="mb-3 text-sm font-semibold text-slate-900">
        Tickets
      </h2>
      {status === 'loading' && (
        <p role="status" className="text-sm text-slate-700">
          Cargando tickets…
        </p>
      )}
      {status === 'error' && (
        <div role="alert" className="flex items-center gap-3 text-sm text-red-700">
          <span>{error}</span>
          <button
            type="button"
            onClick={retry}
            className="flex items-center gap-1 rounded border border-red-300 px-2 py-1 hover:bg-red-50 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-red-700"
          >
            <RefreshCw aria-hidden="true" className="size-3.5" />
            Reintentar
          </button>
        </div>
      )}
      {status === 'ready' && tickets.length === 0 && (
        <p className="text-sm text-slate-700">Aún no hay tickets. Crea el primero.</p>
      )}
      {status === 'ready' && tickets.length > 0 && (
        <div
          role="region"
          aria-label="Tabla de tickets"
          tabIndex={0}
          className="overflow-x-auto focus-visible:outline-2 focus-visible:outline-sky-600"
        >
          <table className="w-full text-sm text-slate-900">
            <thead className="bg-slate-100 text-slate-700">
              <tr>
                <th scope="col" className={TH}>ID</th>
                <th scope="col" className={TH}>Título</th>
                <th scope="col" className={TH}>Estado</th>
                <th scope="col" className={TH}>Severidad</th>
                <th scope="col" className={TH}>Agente</th>
                <th scope="col" className={TH}>Creado</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-200">
              {tickets.map((ticket) => (
                <tr key={ticket.id}>
                  <td className="px-3 py-2 font-mono text-xs" title={ticket.id}>
                    {ticket.id.slice(0, 8)}
                  </td>
                  <td className="px-3 py-2">{ticket.title}</td>
                  <td className="px-3 py-2"><StatusBadge status={ticket.status} /></td>
                  <td className="px-3 py-2"><SeverityBadge severity={ticket.severity} /></td>
                  <td className="px-3 py-2"><AgentActivityCell ticketId={ticket.id} /></td>
                  <td className="px-3 py-2 whitespace-nowrap">
                    <time dateTime={ticket.createdAt}>
                      {new Date(ticket.createdAt).toLocaleString()}
                    </time>
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
