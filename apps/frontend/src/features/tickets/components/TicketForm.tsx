import { Send } from 'lucide-react'
import { useId, useState, type ChangeEvent, type SyntheticEvent } from 'react'
import { useCreateTicket } from '../hooks/useCreateTicket'

const FIELD_CLASS =
  'w-full rounded-md border border-line bg-canvas px-3.5 py-2.5 text-xs text-ink placeholder:text-[#64748b] transition-all duration-200 outline-none focus:border-primary focus:ring-2 focus:ring-primary/20 disabled:opacity-60'

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
    <section aria-labelledby="ticket-form-title" className="overflow-hidden rounded-lg border border-line bg-surface shadow-card">
      <div className="flex items-center gap-2.5 border-b border-line px-6 py-4">
        <span aria-hidden="true" className="size-2.5 rounded-full bg-primary" />
        <h2 id="ticket-form-title" className="text-lg font-semibold text-ink">
          New ticket
        </h2>
      </div>
      <form onSubmit={(event) => void handleSubmit(event)} className="flex flex-col gap-5 p-6">
        <div>
          <label htmlFor={titleId} className="mb-1.5 block text-xs font-medium tracking-wide text-muted uppercase">
            Title
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
          <label htmlFor={descriptionId} className="mb-1.5 block text-xs font-medium tracking-wide text-muted uppercase">
            Description
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
          className="flex items-center justify-center gap-2 rounded-lg bg-primary px-4 py-2.5 text-xs font-semibold tracking-wide text-white transition-all duration-200 hover:bg-blue-500 hover:shadow-md hover:shadow-primary/30 disabled:opacity-60 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        >
          <Send aria-hidden="true" className="size-4" />
          {pending ? 'Creating…' : 'Create ticket'}
        </button>
        {status === 'error' && error && (
          <p role="alert" className="rounded-lg border border-danger/50 bg-danger/10 px-3.5 py-2.5 text-xs font-medium text-red-300">
            {error}
          </p>
        )}
        {status === 'success' && (
          <p role="status" className="rounded-lg border border-success/50 bg-success/10 px-3.5 py-2.5 text-xs font-medium text-emerald-300">
            Ticket created. The triage agent is analyzing it.
          </p>
        )}
      </form>
    </section>
  )
}
