import { lazy, Suspense } from 'react'
import { AgentConsole, useWebSocket } from './features/agent-console'
import { DashboardLayout } from './layouts/DashboardLayout'

const TicketsPanel = lazy(() => import('./features/tickets/components/TicketsPanel'))

export default function App(): React.JSX.Element {
  const status = useWebSocket()

  return (
    <DashboardLayout>
      <div className="grid gap-4 lg:grid-cols-2 lg:items-start">
        <Suspense fallback={<p role="status" className="text-sm text-slate-700">Cargando…</p>}>
          <TicketsPanel />
        </Suspense>
        <div className="min-w-0 lg:sticky lg:top-6">
          <AgentConsole status={status} />
        </div>
      </div>
    </DashboardLayout>
  )
}
