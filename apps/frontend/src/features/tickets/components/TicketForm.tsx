import { Send } from 'lucide-react'
import { useId, useState, type ChangeEvent, type SyntheticEvent } from 'react'
import { useCreateTicket } from '../hooks/useCreateTicket'

const FIELD_CLASS =
  'w-full rounded border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-sky-600 disabled:bg-slate-100'

export function TicketForm(): React.JSX.Element {
  const titleId = useId()
  const descriptionId = useId()
  const { status, error, submit } = useCreateTicket()
  const [title, setTitle] = useState('')
  const [description, setDescription] = useState('')
  const pending = status === 'pending'

  const handleSubmit = async (event: SyntheticEvent<HTMLFormElement>): Promise<void> => {
    event.preventDefault()
    if (await submit({ title: title.trim(), description: description.trim() })) {
      setTitle('')
      setDescription('')
    }
  }

  return (
    <section aria-labelledby="ticket-form-title" className="rounded-lg bg-white p-4 shadow-sm">
      <h2 id="ticket-form-title" className="mb-3 text-sm font-semibold text-slate-900">
        Nuevo ticket
      </h2>
      <form onSubmit={(event) => void handleSubmit(event)} className="flex flex-col gap-3">
        <div>
          <label htmlFor={titleId} className="mb-1 block text-sm font-medium text-slate-700">
            Título
          </label>
          <input
            id={titleId}
            type="text"
            required
            maxLength={255}
            value={title}
            disabled={pending}
            onChange={(e: ChangeEvent<HTMLInputElement>) => setTitle(e.target.value)}
            className={FIELD_CLASS}
          />
        </div>
        <div>
          <label htmlFor={descriptionId} className="mb-1 block text-sm font-medium text-slate-700">
            Descripción
          </label>
          <textarea
            id={descriptionId}
            required
            rows={4}
            value={description}
            disabled={pending}
            onChange={(e: ChangeEvent<HTMLTextAreaElement>) => setDescription(e.target.value)}
            className={FIELD_CLASS}
          />
        </div>
        <button
          type="submit"
          disabled={pending}
          className="flex items-center justify-center gap-2 rounded bg-sky-700 px-3 py-2 text-sm font-medium text-white hover:bg-sky-800 disabled:opacity-60 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-sky-600"
        >
          <Send aria-hidden="true" className="size-4" />
          {pending ? 'Creando…' : 'Crear ticket'}
        </button>
        {status === 'error' && error && (
          <p role="alert" className="text-sm text-red-700">
            {error}
          </p>
        )}
        {status === 'success' && (
          <p role="status" className="text-sm text-emerald-800">
            Ticket creado. El agente de triaje lo está analizando.
          </p>
        )}
      </form>
    </section>
  )
}
