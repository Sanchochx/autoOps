import type { ReactNode } from 'react'
import { Sidebar } from './Sidebar'

interface DashboardLayoutProps {
  children: ReactNode
  onSignOut: () => void
}

export function DashboardLayout({ children, onSignOut }: DashboardLayoutProps): React.JSX.Element {
  return (
    <div className="grid min-h-screen grid-rows-[auto_1fr] bg-canvas md:grid-cols-[16rem_1fr] md:grid-rows-1">
      <Sidebar onSignOut={onSignOut} />
      <main id="dashboard" className="min-w-0 p-4 md:p-6">
        {children}
      </main>
    </div>
  )
}
