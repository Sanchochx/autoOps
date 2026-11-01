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
        className="flex items-center gap-1 rounded border border-red-300 px-2 py-1 text-xs font-medium text-red-800 hover:bg-red-50 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-red-700"
      >
        <Trash2 aria-hidden="true" className="size-3.5" />
        Limpiar Tickets
      </button>
      <ConfirmDialog
        open={open}
        title="¿Limpiar todos los tickets?"
        confirmLabel="Sí, limpiar"
        busy={clearing}
        error={error}
        onConfirm={() => void handleConfirm()}
        onCancel={() => setOpen(false)}
      >
        <p>
          Se eliminarán de forma permanente todos los tickets y su estado. Esta acción no se
          puede deshacer. ¿Seguro que quieres continuar?
        </p>
      </ConfirmDialog>
    </>
  )
}
