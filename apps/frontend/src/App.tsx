import { lazy, Suspense } from 'react'
import { AgentConsole, useWebSocket } from './features/agent-console'
import { DashboardLayout } from './layouts/DashboardLayout'

const TicketForm = lazy(() =>
  import('./features/tickets/components/TicketForm').then((m) => ({ default: m.TicketForm })),
)
const TicketList = lazy(() =>
  import('./features/tickets/components/TicketList').then((m) => ({ default: m.TicketList })),
)

const LOADING = <p role="status" className="text-sm text-muted">Loading…</p>

export default function App(): React.JSX.Element {
  const status = useWebSocket()

  return (
    <DashboardLayout>
      <div className="flex flex-col gap-6">
        <div className="grid gap-6 xl:grid-cols-5 xl:items-start">
          <div className="min-w-0 xl:col-span-2">
            <Suspense fallback={LOADING}>
              <TicketForm />
            </Suspense>
          </div>
          <div className="min-w-0 xl:col-span-3">
            <AgentConsole status={status} />
          </div>
        </div>
        <Suspense fallback={LOADING}>
          <TicketList />
        </Suspense>
      </div>
    </DashboardLayout>
  )
}
