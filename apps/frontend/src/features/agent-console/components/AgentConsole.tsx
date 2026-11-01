import { Terminal, Trash2 } from 'lucide-react'
import { LogText } from './LogText'
import { useAutoScroll } from '../hooks/useAutoScroll'
import type { ConnectionStatus } from '../models/agentMessage'
import { useAiStore } from '../store/useAiStore'

const STATUS_LABEL: Record<ConnectionStatus, string> = {
  connecting: 'Connecting…',
  open: 'Connected',
  closed: 'Disconnected',
}

const STATUS_COLOR: Record<ConnectionStatus, string> = {
  connecting: 'border-amber-500 bg-amber-500 text-black',
  open: 'border-success bg-success text-white',
  closed: 'border-danger bg-danger text-white',
}

interface AgentConsoleProps {
  status: ConnectionStatus
}

export function AgentConsole({ status }: AgentConsoleProps): React.JSX.Element {
  const logs = useAiStore((state) => state.logs)
  const clearLogs = useAiStore((state) => state.clearLogs)
  const scrollRef = useAutoScroll(logs)

  return (
    <section
      aria-labelledby="agent-console-title"
      className="flex h-full min-h-[60vh] flex-col overflow-hidden rounded-lg border border-line bg-terminal text-ink shadow-card"
    >
      <header className="flex items-center justify-between border-b border-line bg-terminal px-4 py-3">
        <div className="flex items-center gap-3">
          <span aria-hidden="true" className="flex items-center gap-1.5">
            <span className="size-2.5 rounded-full bg-danger/80" />
            <span className="size-2.5 rounded-full bg-amber-500/80" />
            <span className="size-2.5 rounded-full bg-emerald-500/80" />
          </span>
          <h2 id="agent-console-title" className="flex items-center gap-2 text-lg font-semibold text-ink">
            <Terminal aria-hidden="true" className="size-5 text-primary" />
            Agent console
          </h2>
        </div>
        <div className="flex items-center gap-3 text-xs">
          <span className={`rounded-md border px-2 py-0.5 text-[11px] font-medium ${STATUS_COLOR[status]}`}>{STATUS_LABEL[status]}</span>
          <button
            type="button"
            onClick={clearLogs}
            className="flex items-center gap-1 rounded-md border border-line bg-transparent px-2 py-0.5 text-[11px] text-muted transition-colors hover:bg-surface hover:text-ink focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
          >
            <Trash2 aria-hidden="true" className="size-3.5" />
            Clear
          </button>
        </div>
      </header>
      <div
        ref={scrollRef}
        role="log"
        aria-live="polite"
        aria-label="AI engine messages"
        tabIndex={0}
        className="flex-1 overflow-y-auto p-4 font-mono text-[12px] leading-relaxed text-slate-300 focus-visible:outline-2 focus-visible:outline-primary"
      >
        {logs.length === 0 ? (
          <p>
            <span className="font-medium text-sky-300">[INFO]</span>{' '}
            <span className="text-muted">Waiting for AI engine messages…</span>
          </p>
        ) : (
          logs.map((log) => (
            <p key={log.id} className="mb-2 whitespace-pre-wrap break-words">
              <span className="text-muted">
                {new Date(log.receivedAt).toLocaleTimeString()}{' '}
              </span>
              <LogText text={log.text} />
            </p>
          ))
        )}
        <span aria-hidden="true" className="blink-cursor text-primary">
          _
        </span>
      </div>
    </section>
  )
}
