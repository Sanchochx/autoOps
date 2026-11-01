import { Loader2 } from 'lucide-react'
import { useState } from 'react'
import { useAgentActivity, type AgentPhase } from '../../agent-console'
import type { Ticket } from '../models/ticket'
import { AnalysisDialog } from './AnalysisDialog'

const PHASE_LABEL: Record<AgentPhase, string> = {
  triage: 'Triage in progress…',
  investigating: 'Investigating…',
  saving: 'Saving result…',
  done: 'Investigation completed',
  failed: 'The agent failed',
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
  if (ticket.analysis || live?.phase === 'done') return { label: 'Investigation completed', spinning: false, failed: false }
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
  const [showAnalysis, setShowAnalysis] = useState(false)
  if (!progress) return <span className="text-muted">—</span>

  return (
    <div className="max-w-xs">
      <p className={`flex items-center gap-1 ${progress.failed ? 'text-red-300' : 'text-ink'}`}>
        {progress.spinning && (
          <Loader2 aria-hidden="true" className="size-3.5 animate-spin motion-reduce:animate-none" />
        )}
        {progress.label}
      </p>
      {ticket.analysis && (
        <>
          <button
            type="button"
            onClick={() => setShowAnalysis(true)}
            className="mt-1 cursor-pointer text-[11px] font-semibold text-primary hover:text-blue-300 focus-visible:outline-2 focus-visible:outline-primary"
          >
            View analysis
          </button>
          <AnalysisDialog
            open={showAnalysis}
            analysis={ticket.analysis}
            onClose={() => setShowAnalysis(false)}
          />
        </>
      )}
    </div>
  )
}
