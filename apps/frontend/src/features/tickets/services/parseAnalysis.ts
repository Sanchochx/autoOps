import { stripAsterisks } from '../../../shared/stripAsterisks'

export type AnalysisBlock =
  | { kind: 'heading'; text: string }
  | { kind: 'hypothesis'; index: string; title: string; body: string }
  | { kind: 'bullet'; text: string }
  | { kind: 'paragraph'; text: string }

const HEADING = /^#{1,6}\s+(.*)$/
const NUMBERED = /^\s*(\d+)[.)]\s+(.*)$/
const BULLET = /^\s*[-*•]\s+(.*)$/

function splitTitle(text: string): { title: string; body: string } {
  const clean = stripAsterisks(text).trim()
  // Backticks may contain colons (paths, URLs); only split on a colon outside them.
  const colon = clean.replace(/`[^`]*`/g, (m) => ' '.repeat(m.length)).indexOf(':')
  if (colon === -1) return { title: clean, body: '' }
  return { title: clean.slice(0, colon).trim(), body: clean.slice(colon + 1).trim() }
}

/** Turns the agent's Markdown-ish analysis into blocks the dialog can lay out. */
export function parseAnalysis(text: string): AnalysisBlock[] {
  const blocks: AnalysisBlock[] = []
  for (const line of text.split('\n')) {
    if (line.trim() === '') continue
    const heading = HEADING.exec(line)
    if (heading) {
      blocks.push({ kind: 'heading', text: stripAsterisks(heading[1]).trim().replace(/:$/, '') })
      continue
    }
    const numbered = NUMBERED.exec(line)
    if (numbered) {
      blocks.push({ kind: 'hypothesis', index: numbered[1], ...splitTitle(numbered[2]) })
      continue
    }
    const bullet = BULLET.exec(line)
    if (bullet) {
      blocks.push({ kind: 'bullet', text: stripAsterisks(bullet[1]).trim() })
      continue
    }
    blocks.push({ kind: 'paragraph', text: stripAsterisks(line).trim() })
  }
  return blocks
}
