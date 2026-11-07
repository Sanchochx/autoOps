import { create } from 'zustand'

interface SessionState {
  /** Access token. Kept in memory only: no localStorage or sessionStorage, so a reload asks to sign in again. */
  token: string | null
  /** True when the last sign-out was forced by a 401, so the login screen can explain it. */
  expired: boolean
  signIn: (token: string) => void
  signOut: (reason?: 'expired') => void
}

export const useSessionStore = create<SessionState>((set) => ({
  token: null,
  expired: false,
  signIn: (token: string): void => set({ token, expired: false }),
  signOut: (reason?: 'expired'): void => set({ token: null, expired: reason === 'expired' }),
}))
