import { Activity, LayoutDashboard, LogOut } from 'lucide-react'

interface SidebarProps {
  onSignOut: () => void
}

export function Sidebar({ onSignOut }: SidebarProps): React.JSX.Element {
  return (
    <nav
      aria-label="Main navigation"
      className="border-b border-surface bg-field text-ink shadow-card md:border-r md:border-b-0"
    >
      <p className="flex h-16 items-center gap-3 border-b border-surface px-5 text-base font-bold tracking-tight text-ink">
        <span className="flex size-9 items-center justify-center rounded-lg bg-primary">
          <Activity aria-hidden="true" className="size-5 text-white" />
        </span>
        AutoOps
      </p>
      <ul className="p-3">
        <li>
          <a
            href="#dashboard"
            aria-current="page"
            className="flex items-center gap-3 rounded-r-lg border-l-2 border-primary bg-primary/10 px-3 py-2.5 text-sm font-medium text-primary transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
          >
            <LayoutDashboard aria-hidden="true" className="size-4" />
            Dashboard
          </a>
        </li>
        <li className="mt-1">
          <button
            type="button"
            onClick={onSignOut}
            className="flex w-full items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium text-muted transition-colors hover:text-ink focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
          >
            <LogOut aria-hidden="true" className="size-4" />
            Sign out
          </button>
        </li>
      </ul>
    </nav>
  )
}
