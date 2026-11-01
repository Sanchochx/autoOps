import { Trash2 } from 'lucide-react'
import { useState } from 'react'
import { useClearTickets } from '../hooks/useClearTickets'
import { ConfirmDialog } from './ConfirmDialog'

interface ClearTicketsButtonProps {
  disabled: boolean
}

export function ClearTicketsButton({ disabled }: ClearTicketsButtonProps): React.JSX.Element {
  const [open, setOpen] = useState(false)
  const { clearing, error, clear } = useClearTickets()

  const handleConfirm = async (): Promise<void> => {
    if (await clear()) setOpen(false)
  }

  return (
    <>
      <button
        type="button"
        disabled={disabled}
        onClick={() => setOpen(true)}
        className="flex items-center gap-1.5 rounded-lg border border-danger/50 bg-transparent px-3 py-1.5 text-xs font-semibold text-danger transition-colors hover:bg-danger/10 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-danger"
      >
        <Trash2 aria-hidden="true" className="size-3.5" />
        Clear Tickets
      </button>
      <ConfirmDialog
        open={open}
        title="Clear all tickets?"
        confirmLabel="Yes, clear"
        busy={clearing}
        error={error}
        onConfirm={() => void handleConfirm()}
        onCancel={() => setOpen(false)}
      >
        <p>
          All tickets and their state will be permanently deleted. This action cannot be undone.
          Are you sure you want to continue?
        </p>
      </ConfirmDialog>
    </>
  )
}
