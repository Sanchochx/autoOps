import { Check, Copy, X } from 'lucide-react'
import { useEffect, useId, useRef, useState } from 'react'
import { stripAsterisks } from '../../../shared/stripAsterisks'
import { AnalysisContent } from './AnalysisContent'

interface AnalysisDialogProps {
  open: boolean
  analysis: string
  onClose: () => void
}

const COPIED_FEEDBACK_MS = 2000

/** Modal on the native <dialog>: focus trap, Esc to close and aria-modal come for free. */
export function AnalysisDialog({ open, analysis, onClose }: AnalysisDialogProps): React.JSX.Element {
  const ref = useRef<HTMLDialogElement>(null)
  const titleId = useId()
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    const dialog = ref.current
    if (!dialog) return
    if (open && !dialog.open) dialog.showModal()
    if (!open && dialog.open) dialog.close()
  }, [open])

  useEffect(() => {
    if (!copied) return
    const timer = setTimeout(() => setCopied(false), COPIED_FEEDBACK_MS)
    return () => clearTimeout(timer)
  }, [copied])

  const handleCopy = async (): Promise<void> => {
    try {
      await navigator.clipboard.writeText(stripAsterisks(analysis))
      setCopied(true)
    } catch {
      // Clipboard unavailable (insecure context or denied); nothing to report.
    }
  }

  return (
    <dialog
      ref={ref}
      aria-labelledby={titleId}
      onClose={onClose}
      onClick={(event) => {
        if (event.target === event.currentTarget) onClose()
      }}
      className="m-auto w-[min(48rem,94vw)] overflow-hidden rounded-lg border border-slate-700 bg-surface p-0 text-slate-300 shadow-2xl backdrop:bg-black/60 backdrop:backdrop-blur-sm"
    >
      <div className="flex max-h-[85vh] flex-col">
        <header className="flex items-center justify-between gap-3 border-b border-slate-700 p-6">
          <div className="flex items-center gap-3">
            <h2 id={titleId} className="text-xl font-semibold text-slate-100">
              Analysis
            </h2>
            <span className="rounded-full border border-blue-500/40 bg-blue-500/10 px-2.5 py-0.5 text-xs font-medium text-blue-300">
              AI-generated
            </span>
          </div>
          <button
            type="button"
            aria-label="Close"
            onClick={onClose}
            className="rounded-md p-2 text-slate-400 transition-colors hover:bg-slate-700 hover:text-slate-100 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
          >
            <X aria-hidden="true" className="size-4" />
          </button>
        </header>
        <div className="overflow-y-auto px-6 py-4">
          <AnalysisContent analysis={analysis} />
        </div>
        <footer className="flex justify-end gap-3 border-t border-slate-700 bg-slate-900/50 p-4">
          <button
            type="button"
            onClick={() => void handleCopy()}
            className="flex items-center gap-2 rounded-lg border border-slate-600 px-3 py-2 text-sm font-medium text-slate-200 transition-colors hover:bg-slate-700 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
          >
            {copied ? <Check aria-hidden="true" className="size-4" /> : <Copy aria-hidden="true" className="size-4" />}
            {copied ? 'Copied' : 'Copy analysis'}
          </button>
          <button
            type="button"
            autoFocus
            onClick={onClose}
            className="rounded-lg bg-[#3b82f6] px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-blue-500 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
          >
            Close
          </button>
        </footer>
      </div>
    </dialog>
  )
}
