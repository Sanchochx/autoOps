import { TicketForm } from './TicketForm'
import { TicketList } from './TicketList'

/** Form + list; default export so the feature can be lazy-loaded. */
export default function TicketsPanel(): React.JSX.Element {
  return (
    <div className="flex min-w-0 flex-col gap-4">
      <TicketForm />
      <TicketList />
    </div>
  )
}
