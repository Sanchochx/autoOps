import { Trash2 } from 'lucide-react'
import { useState } from 'react'
import { useDeleteTicket } from '../hooks/useDeleteTicket'
import { ConfirmDialog } from './ConfirmDialog'

interface DeleteTicketButtonProps {
  id: string
  title: string
}

export function DeleteTicketButton({ id, title }: DeleteTicketButtonProps): React.JSX.Element {
  const [open, setOpen] = useState(false)
  const { deleting, error, remove } = useDeleteTicket(id)

  const handleConfirm = async (): Promise<void> => {
    if (await remove()) setOpen(false)
  }

  return (
    <>
      <button
        type="button"
        aria-label={`Delete ticket ${title}`}
        title="Delete ticket"
        onClick={() => setOpen(true)}
        className="rounded-lg border border-danger/50 bg-transparent p-1.5 text-danger transition-colors hover:bg-danger/10 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-danger"
      >
        <Trash2 aria-hidden="true" className="size-3.5" />
      </button>
      <ConfirmDialog
        open={open}
        title="Delete this ticket?"
        confirmLabel="Yes, delete"
        busy={deleting}
        error={error}
        onConfirm={() => void handleConfirm()}
        onCancel={() => setOpen(false)}
      >
        <p>This ticket will be permanently deleted. This action cannot be undone.</p>
      </ConfirmDialog>
    </>
  )
}
