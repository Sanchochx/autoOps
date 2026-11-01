import { Loader2 } from 'lucide-react'
import { useAgentActivity, type AgentPhase } from '../../agent-console'
import type { Ticket } from '../models/ticket'

const PHASE_LABEL: Record<AgentPhase, string> = {
  triage: 'Triaje en curso…',
  investigating: 'Investigando…',
  saving: 'Guardando resultado…',
  done: 'Investigación completada',
  failed: 'El agente falló',
}

const IN_PROGRESS: readonly AgentPhase[] = ['triage', 'investigating', 'saving']

interface Progress {
  label: string
  spinning: boolean
  failed: boolean
}

/**
 * The API is the source of truth: a persisted analysis or a final status wins. The live stream
 * only describes work that is still in flight (or that failed before anything was persisted).
 */
function resolveProgress(ticket: Ticket, live: ReturnType<typeof useAgentActivity>): Progress | null {
  if (ticket.analysis || live?.phase === 'done') return { label: 'Investigación completada', spinning: false, failed: false }
  if (live?.phase === 'failed') return { label: PHASE_LABEL.failed, spinning: false, failed: true }
  if (live && IN_PROGRESS.includes(live.phase)) {
    return { label: PHASE_LABEL[live.phase], spinning: true, failed: false }
  }
  if (ticket.status === 'investigating') {
    return { label: PHASE_LABEL.investigating, spinning: true, failed: false }
  }
  return null
}

interface AgentActivityCellProps {
  ticket: Ticket
}

export function AgentActivityCell({ ticket }: AgentActivityCellProps): React.JSX.Element {
  const live = useAgentActivity(ticket.id)
  const progress = resolveProgress(ticket, live)
  if (!progress) return <span className="text-slate-600">—</span>

  return (
    <div className="max-w-xs">
      <p className={`flex items-center gap-1 ${progress.failed ? 'text-red-700' : 'text-slate-900'}`}>
        {progress.spinning && (
          <Loader2 aria-hidden="true" className="size-3.5 animate-spin motion-reduce:animate-none" />
        )}
        {progress.label}
      </p>
      {ticket.analysis && (
        <details className="mt-1">
          <summary className="cursor-pointer text-xs text-sky-800 focus-visible:outline-2 focus-visible:outline-sky-600">
            Ver análisis
          </summary>
          <p className="mt-1 text-xs whitespace-pre-wrap text-slate-800">{ticket.analysis}</p>
        </details>
      )}
    </div>
  )
}
