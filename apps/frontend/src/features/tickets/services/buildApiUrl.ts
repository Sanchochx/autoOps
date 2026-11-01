/**
 * Joins the configured API base with an absolute path. An empty base or `/` (same-origin behind
 * the reverse proxy) yields the path itself; an absolute base (development) is prefixed to it.
 */
export function buildApiUrl(base: string | undefined, path: string): string {
  const cleanBase = (base ?? '').replace(/\/+$/, '')
  const cleanPath = `/${path.replace(/^\/+/, '')}`
  return `${cleanBase}${cleanPath}`
}
