/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_API_BASE_URL?: string
  readonly VITE_WS_BASE_URL?: string
  readonly VITE_TICKETS_POLL_INTERVAL_MS?: string
  readonly VITE_DEV_SERVER_PORT?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
