import { Loader2 } from 'lucide-react'
import { useAgentActivity, type AgentPhase } from '../../agent-console'

const PHASE_LABEL: Record<AgentPhase, string> = {
  triage: 'Triaje en curso…',
  investigating: 'Investigando…',
  saving: 'Guardando resultado…',
  done: 'Investigación completada',
  failed: 'El agente falló',
}

const IN_PROGRESS: readonly AgentPhase[] = ['triage', 'investigating', 'saving']

interface AgentActivityCellProps {
  ticketId: string
}

/** Agent progress for one ticket, fed by the live stream; the analysis expands on demand. */
export function AgentActivityCell({ ticketId }: AgentActivityCellProps): React.JSX.Element {
  const activity = useAgentActivity(ticketId)
  if (!activity) return <span className="text-slate-600">—</span>

  const failed = activity.phase === 'failed'
  return (
    <div className="max-w-xs">
      <p className={`flex items-center gap-1 ${failed ? 'text-red-700' : 'text-slate-900'}`}>
        {IN_PROGRESS.includes(activity.phase) && (
          <Loader2 aria-hidden="true" className="size-3.5 animate-spin motion-reduce:animate-none" />
        )}
        {PHASE_LABEL[activity.phase]}
      </p>
      {activity.note && (
        <details className="mt-1">
          <summary className="cursor-pointer text-xs text-sky-800 focus-visible:outline-2 focus-visible:outline-sky-600">
            Ver análisis
          </summary>
          <p className="mt-1 text-xs whitespace-pre-wrap text-slate-800">{activity.note}</p>
        </details>
      )}
    </div>
  )
}
