import { describe, expect, it } from 'vitest'
import { stripAsterisks } from './stripAsterisks'

describe('stripAsterisks', () => {
  it('removes bold and italic markers', () => {
    expect(stripAsterisks('1. **Slow query**: *fast*')).toBe('1. Slow query: fast')
  })

  it('leaves text without asterisks untouched', () => {
    expect(stripAsterisks('no marks')).toBe('no marks')
  })
})
