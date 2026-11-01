import { describe, expect, it } from 'vitest'
import { parseAgentEvent, toActivity } from './parseAgentEvent'

const frame = (node: string, message: string): string =>
  JSON.stringify({ type: 'ai_event', ticket_id: 't1', node, message })

describe('parseAgentEvent', () => {
  it('parses an ai_event', () => {
    expect(parseAgentEvent(frame('gateway', 'x'))).toEqual({
      ticketId: 't1',
      node: 'gateway',
      message: 'x',
    })
  })
  it.each(['not json', '{"message":"hi"}', '{"type":"ai_event","node":"a","message":"b"}', 'null'])(
    'ignores %s',
    (raw) => expect(parseAgentEvent(raw)).toBeNull(),
  )
})

describe('toActivity', () => {
  it('walks the phases and keeps the investigator note', () => {
    const ev = (node: string, message = ''): NonNullable<ReturnType<typeof parseAgentEvent>> => ({
      ticketId: 't1',
      node,
      message,
    })
    expect(toActivity(ev('gateway'))?.phase).toBe('triage')
    expect(toActivity(ev('triage_node'))?.phase).toBe('investigating')
    const saving = toActivity(ev('investigator_node', 'investigator: Possible saturation'))
    expect(saving).toEqual({ phase: 'saving', note: 'Possible saturation' })
    expect(toActivity(ev('database'), saving ?? undefined)).toEqual({
      phase: 'done',
      note: 'Possible saturation',
    })
    expect(toActivity(ev('error'))?.phase).toBe('failed')
    expect(toActivity(ev('other'))).toBeNull()
  })
})
