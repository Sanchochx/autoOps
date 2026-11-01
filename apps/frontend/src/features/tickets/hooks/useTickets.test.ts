import { describe, expect, it } from 'vitest'
import { resolvePollInterval } from './useTickets'

describe('resolvePollInterval', () => {
  it.each([
    [undefined, 5000],
    ['', 5000],
    ['2000', 2000],
    ['0', 0],
    ['abc', 5000],
    ['-1', 5000],
  ])('%j -> %i', (raw, expected) => {
    expect(resolvePollInterval(raw)).toBe(expected)
  })
})
