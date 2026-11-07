import { beforeEach, describe, expect, it, vi } from 'vitest'
import { useSessionStore } from './useSessionStore'

beforeEach(() => useSessionStore.setState({ token: null, expired: false }))

describe('useSessionStore', () => {
  it('starts signed out', () => {
    expect(useSessionStore.getState()).toMatchObject({ token: null, expired: false })
  })

  it('signIn keeps the token and clears the expired notice', () => {
    useSessionStore.setState({ expired: true })
    useSessionStore.getState().signIn('abc')
    expect(useSessionStore.getState()).toMatchObject({ token: 'abc', expired: false })
  })

  it('signOut drops the token; reason "expired" is remembered for the login screen', () => {
    useSessionStore.getState().signIn('abc')
    useSessionStore.getState().signOut()
    expect(useSessionStore.getState()).toMatchObject({ token: null, expired: false })
    useSessionStore.getState().signIn('abc')
    useSessionStore.getState().signOut('expired')
    expect(useSessionStore.getState()).toMatchObject({ token: null, expired: true })
  })

  it('never persists the token in web storage', () => {
    const setItem = vi.fn()
    vi.stubGlobal('localStorage', { setItem })
    vi.stubGlobal('sessionStorage', { setItem })
    useSessionStore.getState().signIn('secret-token')
    expect(setItem).not.toHaveBeenCalled()
    vi.unstubAllGlobals()
  })
})
