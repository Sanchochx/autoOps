import { describe, expect, it } from 'vitest'
import { buildApiUrl } from './buildApiUrl'

describe('buildApiUrl', () => {
  it.each([
    ['/', '/api/v1/tickets', '/api/v1/tickets'],
    ['', '/api/v1/tickets', '/api/v1/tickets'],
    [undefined, '/api/v1/tickets', '/api/v1/tickets'],
    ['http://localhost:8000', '/api/v1/tickets', 'http://localhost:8000/api/v1/tickets'],
    ['http://localhost:8000/', '/api/v1/tickets', 'http://localhost:8000/api/v1/tickets'],
    ['/', 'api/v1/tickets', '/api/v1/tickets'],
  ])('joins %j and %j', (base, path, expected) => {
    expect(buildApiUrl(base, path)).toBe(expected)
  })
})
