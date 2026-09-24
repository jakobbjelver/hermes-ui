/// <reference types="vite/client" />

// Build-time constants inlined by vite's `define` (see vite.config.ts).
// tsc reads these declarations; vite's transformer skips .d.ts files and
// substitutes the bare identifier wherever it appears in real source.
declare const __HERMES_VERSION__: string

// @novnc/novnc ships no typings (its export is core/rfb.js); the surface the Bot Screen pane uses.
// Mirrored from upstream apps/desktop/src/vite-env.d.ts — the fork overwrites that file with this
// preserved copy, so any upstream ambient shims added there must be ported here on sync.
declare module '@novnc/novnc' {
  export default class RFB {
    constructor(
      target: HTMLElement,
      urlOrChannel: string | WebSocket | RTCDataChannel,
      options?: Record<string, unknown>
    )
    viewOnly: boolean
    scaleViewport: boolean
    resizeSession: boolean
    focusOnClick: boolean
    background: string
    qualityLevel: number
    compressionLevel: number
    addEventListener(type: string, listener: (event: CustomEvent) => void): void
    removeEventListener(type: string, listener: (event: CustomEvent) => void): void
    disconnect(): void
    focus(): void
    blur(): void
    clipboardPasteFrom(text: string): void
  }
}
