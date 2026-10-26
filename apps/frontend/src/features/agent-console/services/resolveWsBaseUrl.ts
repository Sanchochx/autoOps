/**
 * Resolves the configured Gateway WebSocket base URL.
 * An absolute URL (development, e.g. `ws://localhost:8000/ws`) is used as is. A path (`/ws`,
 * same-origin behind the reverse proxy) is resolved against the page origin, using `wss`
 * when the page is served over HTTPS so the browser does not block it as mixed content.
 */
export function resolveWsBaseUrl(
  base: string,
  location: Pick<Location, 'protocol' | 'host'>,
): string {
  if (!base.startsWith('/')) return base
  const scheme = location.protocol === 'https:' ? 'wss' : 'ws'
  return `${scheme}://${location.host}${base}`
}
