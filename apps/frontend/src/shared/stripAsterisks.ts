/** Removes Markdown emphasis asterisks (`**bold**`, `*item*`) from AI-generated text. */
export function stripAsterisks(text: string): string {
  return text.replace(/\*/g, '')
}
