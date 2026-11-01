import { describe, expect, it } from 'vitest'
import { splitNumberedHeading } from './splitNumberedHeading'

describe('splitNumberedHeading', () => {
  it('separates the numbered title from the description', () => {
    expect(splitNumberedHeading('1. Slow query: The query is inefficient')).toEqual({
      heading: '1. Slow query:',
      rest: ' The query is inefficient',
    })
  })

  it('treats a numbered line without a colon as all heading', () => {
    expect(splitNumberedHeading('2. Title only')).toEqual({ heading: '2. Title only', rest: '' })
  })

  it('leaves other lines as plain text', () => {
    expect(splitNumberedHeading('triage: severidad = high')).toEqual({
      heading: '',
      rest: 'triage: severidad = high',
    })
  })
})
