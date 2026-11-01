import type { ReactNode } from 'react'
import { parseAnalysis, type AnalysisBlock } from '../services/parseAnalysis'

/** Renders `code` spans in monospace; everything else in the regular font. */
function Inline({ text }: { text: string }): React.JSX.Element {
  const parts = text.split(/(`[^`]+`)/)
  return (
    <>
      {parts.map((part, index): ReactNode =>
        part.startsWith('`') && part.endsWith('`') && part.length > 2 ? (
          <code key={index} className="rounded bg-slate-800 px-1.5 py-0.5 font-mono text-sm text-blue-300">
            {part.slice(1, -1)}
          </code>
        ) : (
          part
        ),
      )}
    </>
  )
}

function Block({ block }: { block: AnalysisBlock }): React.JSX.Element {
  switch (block.kind) {
    case 'heading':
      return (
        <h3 className="mt-6 mb-3 text-sm font-semibold tracking-wider text-slate-400 uppercase first:mt-0">
          {block.text}
        </h3>
      )
    case 'hypothesis':
      return (
        <div className="rounded-lg bg-blue-950/60 p-4">
          <p className="font-semibold text-slate-100">
            <span className="mr-2 text-blue-400">{block.index}.</span>
            <Inline text={block.title} />
          </p>
          {block.body && (
            <p className="mt-1.5 leading-7 text-slate-300">
              <Inline text={block.body} />
            </p>
          )}
        </div>
      )
    case 'bullet':
      return (
        <li className="flex gap-3 leading-7 text-slate-300">
          <span aria-hidden="true" className="mt-3 size-1.5 shrink-0 rounded-full bg-blue-400" />
          <span>
            <Inline text={block.text} />
          </span>
        </li>
      )
    case 'paragraph':
      return (
        <p className="leading-7 text-slate-300">
          <Inline text={block.text} />
        </p>
      )
  }
}

interface AnalysisContentProps {
  analysis: string
}

/** Groups consecutive hypotheses into a spaced stack and bullets into a list. */
export function AnalysisContent({ analysis }: AnalysisContentProps): React.JSX.Element {
  const blocks = parseAnalysis(analysis)
  const groups: AnalysisBlock[][] = []
  for (const block of blocks) {
    const last = groups[groups.length - 1]
    if (last && last[0].kind === block.kind && (block.kind === 'hypothesis' || block.kind === 'bullet')) {
      last.push(block)
    } else {
      groups.push([block])
    }
  }

  return (
    <div className="text-sm">
      {groups.map((group, index) => {
        const kind = group[0].kind
        if (kind === 'hypothesis') {
          return (
            <div key={index} className="space-y-4">
              {group.map((block, i) => <Block key={i} block={block} />)}
            </div>
          )
        }
        if (kind === 'bullet') {
          return (
            <ul key={index} className="space-y-1.5">
              {group.map((block, i) => <Block key={i} block={block} />)}
            </ul>
          )
        }
        return <Block key={index} block={group[0]} />
      })}
    </div>
  )
}
