import { describe, expect, it } from 'vitest'
import { parseAnalysis } from './parseAnalysis'

describe('parseAnalysis', () => {
  it('splits headings, hypotheses and bullets', () => {
    const text = [
      '### Most likely root cause hypotheses:',
      '1. **Slow query**: Missing index on `orders`.',
      '',
      '### Technical information to check:',
      '- **Nginx logs** for `/api/v1/auth`',
      '* Execution plan',
    ].join('\n')

    expect(parseAnalysis(text)).toEqual([
      { kind: 'heading', text: 'Most likely root cause hypotheses' },
      { kind: 'hypothesis', index: '1', title: 'Slow query', body: 'Missing index on `orders`.' },
      { kind: 'heading', text: 'Technical information to check' },
      { kind: 'bullet', text: 'Nginx logs for `/api/v1/auth`' },
      { kind: 'bullet', text: 'Execution plan' },
    ])
  })

  it('does not split a hypothesis on a colon inside backticks', () => {
    expect(parseAnalysis('2. Check `host:5432` now')).toEqual([
      { kind: 'hypothesis', index: '2', title: 'Check `host:5432` now', body: '' },
    ])
  })

  it('keeps plain lines as paragraphs without asterisks', () => {
    expect(parseAnalysis('Text **important**')).toEqual([{ kind: 'paragraph', text: 'Text important' }])
  })
})
