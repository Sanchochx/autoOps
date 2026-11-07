import { lazy, Suspense, useEffect } from 'react'
import { AgentConsole, useAgentActivityStore, useAiStore, useWebSocket } from './features/agent-console'
import { useSessionStore } from './features/auth'
import { useTicketStore } from './features/tickets/hooks/useTicketStore'
import { DashboardLayout } from './layouts/DashboardLayout'

const TicketForm = lazy(() =>
  import('./features/tickets/components/TicketForm').then((m) => ({ default: m.TicketForm })),
)
const TicketList = lazy(() =>
  import('./features/tickets/components/TicketList').then((m) => ({ default: m.TicketList })),
)

const LOADING = <p role="status" className="text-sm text-muted">Loading…</p>

/** Signed-in view. Leaving it (sign out or 401) closes the stream and drops what the session had loaded. */
export function Dashboard(): React.JSX.Element {
  const status = useWebSocket()
  const signOut = useSessionStore((state) => state.signOut)

  useEffect(
    () => () => {
      useTicketStore.getState().reset()
      useAgentActivityStore.getState().reset()
      useAiStore.getState().clearLogs()
    },
    [],
  )

  return (
    <DashboardLayout onSignOut={() => signOut()}>
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
