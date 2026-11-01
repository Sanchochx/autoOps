import { stripAsterisks } from '../../../shared/stripAsterisks'
import { splitNumberedHeading } from '../services/splitNumberedHeading'

interface LogTextProps {
  text: string
}

const AGENT_PREFIX = /^(\w+:)(.*)$/s
const SEVERITY_WORD = /(\[(?:SUCCESS|INFO|WARN|ERROR)\]|\b(?:low|medium|high|critical)\b)/gi

const SEVERITY_COLOR: Record<string, string> = {
  low: 'text-emerald-400',
  medium: 'text-yellow-300',
  high: 'text-orange-400',
  critical: 'text-red-400',
  '[success]': 'text-emerald-400',
  '[info]': 'text-sky-300',
  '[warn]': 'text-yellow-300',
  '[error]': 'text-red-400',
}

/** Colors severity words (low, high, …) so the triage result stands out. */
function highlightSeverity(text: string): React.ReactNode[] {
  return text.split(SEVERITY_WORD).map((part, index) => {
    const color = SEVERITY_COLOR[part.toLowerCase()]
    // split() with a capture group puts the matched words at odd indexes.
    return index % 2 === 1 && color ? (
      <span key={index} className={`font-semibold ${color}`}>
        {part}
      </span>
    ) : (
      part
    )
  })
}

function Line({ line }: { line: string }): React.JSX.Element {
  const { heading, rest } = splitNumberedHeading(line)
  if (heading) {
    return (
      <>
        <span className="font-semibold text-sky-300">{heading}</span>
        {rest}
      </>
    )
  }
  const agent = AGENT_PREFIX.exec(line)
  if (agent) {
    return (
      <>
        <span className="font-medium text-violet-300">{agent[1]}</span>
        {highlightSeverity(agent[2])}
      </>
    )
  }
  return <>{highlightSeverity(line)}</>
}

/** Renders AI text line by line: numbered titles in light blue, agent names and severities tinted. */
export function LogText({ text }: LogTextProps): React.JSX.Element {
  const lines = stripAsterisks(text).split('\n')
  return (
    <>
      {lines.map((line, index) => (
        // Lines are positional and never reordered.
        <span key={index}>
          {index > 0 && '\n'}
          <Line line={line} />
        </span>
      ))}
    </>
  )
}
