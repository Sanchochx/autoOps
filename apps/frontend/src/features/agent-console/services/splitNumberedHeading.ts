export interface HeadingSplit {
  /** Numbered title ("1. Exceso de conexiones:"), or empty when the line is not a numbered item. */
  heading: string
  rest: string
}

const NUMBERED = /^(\s*\d+[.)]\s[^:]*:?)(.*)$/

/** Splits "1. Title: description" so the title can be highlighted in the console. */
export function splitNumberedHeading(line: string): HeadingSplit {
  const match = NUMBERED.exec(line)
  return match ? { heading: match[1], rest: match[2] } : { heading: '', rest: line }
}
