# hermes-ui

A thin, cross-platform browser UI for the [Hermes Agent](https://github.com/NousResearch/hermes-agent) gateway — the official Hermes desktop renderer, repackaged as a plain Vite web app with PWA support.

## What this is

This is a fork of [przbadu/hermes-ui](https://github.com/przbadu/hermes-ui) with **automated upstream sync**. Every week, a GitHub Action:

1. Checks out the latest [hermes-agent monorepo](https://github.com/NousResearch/hermes-agent)
2. Extracts `apps/desktop` (renderer) and `apps/shared` (protocol client)
3. Strips Electron, injects the web bridge, applies config rewrites
4. If anything changed: commits the extracted source, builds a multi-arch Docker image, and pushes it to GHCR

**No manual maintenance required.** If upstream changes break the extraction, the CI fails — no merge conflicts, no stale code.

## Docker image

Pre-built multi-arch images (linux/amd64, linux/arm64) are published to:

```
ghcr.io/jakobbjelver/hermes-ui:latest
```

## Usage

```yaml
# compose.yaml
services:
  hermes-ui:
    image: ghcr.io/jakobbjelver/hermes-ui:latest
    restart: unless-stopped
    depends_on:
      - hermes
```

The nginx config proxies `/api`, `/auth`, `/login`, and `/health` to `http://hermes:9119` (the Hermes dashboard). Make sure the `hermes` container is reachable by that hostname.

## Upstream sync

The transformation is handled by `scripts/transform.sh`. It copies `apps/desktop/src` and `apps/shared/` from the monorepo, then applies our preserved modifications:

- `preserved/web-bridge/` — browser implementation of `window.hermesDesktop`
- `preserved/vite.config.ts` — de-Electron-ified Vite config with dev proxy
- `preserved/index.html` — modified HTML shell
- `app/package.json` — rewritten for plain Vite (no Electron deps)
- `app/tsconfig.json` — dropped Electron project reference

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2025 Nous Research.
