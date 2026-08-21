#!/usr/bin/env bash
# transform.sh — Extract hermes-ui from the hermes-agent monorepo.
#
# Usage: ./scripts/transform.sh <monorepo-path>
#
# Copies apps/desktop (renderer) and apps/shared (protocol client) from the
# monorepo, strips all Electron machinery, and injects the web bridge so the
# renderer runs in a browser instead of Electron.
#
# Idempotent — safe to run repeatedly. Source directories (app/src, shared/src,
# app/public) are fully replaced. Preserved files (configs, web-bridge) are
# re-applied from preserved/ on every run.

set -euo pipefail

MONOREPO="${1:?Usage: $0 <path-to-hermes-agent-monorepo>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DESKTOP="$MONOREPO/apps/desktop"
SHARED="$MONOREPO/apps/shared"

for d in "$DESKTOP" "$SHARED"; do
  if [ ! -d "$d" ]; then
    echo "error: $d not found — is this a hermes-agent checkout?" >&2
    exit 1
  fi
done

echo "=== Extracting from monorepo at $MONOREPO ==="

# ── app/src (renderer) ──────────────────────────────────────────────────────
echo "  app/src …"
rm -rf "$ROOT/app/src"
cp -a "$DESKTOP/src" "$ROOT/app/src"

# ── shared (protocol client) ────────────────────────────────────────────────
echo "  shared …"
rm -rf "$ROOT/shared"
cp -a "$SHARED" "$ROOT/shared"

# ── public assets ───────────────────────────────────────────────────────────
echo "  app/public …"
rm -rf "$ROOT/app/public"
if [ -d "$DESKTOP/public" ]; then
  cp -a "$DESKTOP/public" "$ROOT/app/public"
else
  mkdir -p "$ROOT/app/public"
fi

# ── Strip Electron-specific files from the renderer source ──────────────────
echo "  stripping Electron artifacts …"
find "$ROOT/app/src" -type f \( \
  -name '*.electron.ts' -o -name '*.electron.tsx' \
\) -delete 2>/dev/null || true

# ── Stabilize ExternalStoreAdapter in ChatRuntimeBoundary ────────────────────
# @assistant-ui/tap@>=0.9.13 (PR #5897) enforces a per-commit getSnapshot
# re-check that throws "Maximum update depth exceeded" when the
# `ExternalStoreAdapter` argument to `useIncrementalExternalStoreRuntime` is a
# fresh object literal on every render — the inline-literal pattern in
# apps/desktop/src/app/chat/index.tsx (ChatRuntimeBoundary) is the upstream
# trigger. Memoize the adapter and hoist the no-op async handler so its
# identity is stable across renders. The Node patcher lives in
# preserved/scripts/ so it ships with the fork and runs on every sync. See:
#   NousResearch/hermes-agent #90795
#   assistant-ui/assistant-ui #6133
if [ -f "$ROOT/preserved/scripts/patch-chat-adapter.mjs" ]; then
  echo "  patching ChatRuntimeBoundary adapter memoization …"
  node "$ROOT/preserved/scripts/patch-chat-adapter.mjs" \
    "$ROOT/app/src/app/chat/index.tsx" || true
fi

# ── Stabilize runtimeMessageRepository across streaming deltas ───────────────
# useMessagesWhileVisible subscribes to the $messages atom and `setMessages`
# always installs a new state value, but the atom's array entries are the
# SAME ChatMessage references until the gateway sends a new delta. A naive
# `useMemo(..., [messages])` produces a fresh `{ headId, messages: items }`
# on every flush, which drives useIncrementalExternalStoreRuntime's setAdapter
# effect to re-fire on every render and bumps the useSyncExternalStore
# commit-check depth counter until @assistant-ui/tap@>=0.9.13 throws
# "Maximum update depth exceeded". Returning the previous repo when the items
# match by identity is what makes streaming settle instead of loop. See
# NousResearch/hermes-agent #90795.
if [ -f "$ROOT/preserved/scripts/patch-runtime-repository.mjs" ]; then
  echo "  patching runtime-repository stable-reference …"
  node "$ROOT/preserved/scripts/patch-runtime-repository.mjs" \
    "$ROOT/app/src/app/chat/runtime-repository.ts" || true
fi

# ── Inject web bridge from preserved/ ───────────────────────────────────────
echo "  injecting web-bridge …"
mkdir -p "$ROOT/app/src/web-bridge"
cp "$ROOT/preserved/web-bridge/"*.ts "$ROOT/app/src/web-bridge/"

# ── Patch main.tsx: prepend web-bridge import as the FIRST line ─────────────
echo "  patching main.tsx …"
MAIN="$ROOT/app/src/main.tsx"
if ! head -1 "$MAIN" | grep -q "web-bridge/install"; then
  # Works with both GNU sed (Linux/GitHub Actions) and BSD sed (macOS)
  if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "1i\\import './web-bridge/install'" "$MAIN"
  else
    sed -i '' "1i\\
import './web-bridge/install'
" "$MAIN"
  fi
fi

# ── Transform package.json (derive from monorepo, remove Electron) ──────────
echo "  transforming package.json …"
jq '
  .name = "hermes-ui" |
  .description = "Browser web app for Hermes Agent, extracted from the official desktop renderer." |
  # Remove Electron-specific dependencies from the monorepo package
  del(.dependencies["node-pty"]) |
  del(.dependencies["simple-git"]) |
  del(.devDependencies["electron"]) |
  del(.devDependencies["electron-builder"]) |
  del(.devDependencies["@electron/rebuild"]) |
  # Replace all scripts with web-only versions (bun-based)
  .scripts = {
    "dev": "vite --port 5174",
    "build": "tsc -p . --noEmit && vite build",
    "typecheck": "tsc -p . --noEmit",
    "lint": "eslint src/",
    "lint:fix": "eslint src/ --fix",
    "fmt": "prettier --write \"src/**/*.{ts,tsx}\" \"vite.config.ts\"",
    "test:ui": "vitest run --environment jsdom",
    "preview": "vite preview --port 4174"
  } |
  .devDependencies["vite-plugin-pwa"] = "^1.3.0" |
  # Pin @babel/core to v7. Babel 8 (8.0.1) became npm `latest` — a fresh
  # `bun install` (no lockfile) hoists it to the top of node_modules, and
  # workbox-build@7.4.1 (vite-plugin-pwa's SW generator) requires ^7.24.4,
  # crashing with "Requires Babel ^7.0.0-0, but was loaded with 8.0.1".
  # A top-level v7 pin makes bun hoist 7.x and nest 8.x only where a package
  # strictly requires it.
  .devDependencies["@babel/core"] = "^7.29.7"
' "$DESKTOP/package.json" > "$ROOT/app/package.json"

# ── Restore preserved config files ──────────────────────────────────────────
echo "  restoring preserved configs …"
cp "$ROOT/preserved/vite.config.ts"  "$ROOT/app/vite.config.ts"
cp "$ROOT/preserved/tsconfig.json"   "$ROOT/app/tsconfig.json"
cp "$ROOT/preserved/index.html"      "$ROOT/app/index.html"
# vite-env.d.ts is preserved verbatim — upstream's version is a one-line
# `/// <reference types="vite/client" />`, and the fork needs `declare const`
# lines for the build-time `define` constants from vite.config.ts.
cp "$ROOT/preserved/vite-env.d.ts"   "$ROOT/app/src/vite-env.d.ts"

# ── Capture the published hermes-agent release version ─────────────────────
# The product version users actually see (e.g. "v0.20.4") is in the upstream
# GitHub release's NAME field, not in any monorepo package.json (the root
# stays at "1.0.0", apps/desktop stays at "0.17.0"). Bake it into the build
# so the About panel / status bar / command palette show the real version.
#
# Anonymous GitHub API works (60 req/hr per IP, fine for weekly sync). On any
# failure we keep the previously-captured value so the build still ships.
HERMES_VERSION_FILE="$ROOT/app/HERMES_VERSION"
PREV_VERSION=""
if [ -f "$HERMES_VERSION_FILE" ]; then
  PREV_VERSION="$(cat "$HERMES_VERSION_FILE")"
fi
NEW_VERSION=""
if command -v curl >/dev/null 2>&1; then
  RELEASE_JSON="$(curl -fsSL --max-time 15 \
    "https://api.github.com/repos/NousResearch/hermes-agent/releases/latest" \
    2>/dev/null || true)"
  if [ -n "$RELEASE_JSON" ] && command -v jq >/dev/null 2>&1; then
    # Prefer the version embedded in the release name ("Hermes Agent v0.20.4
    # (2026.8.18)"). Fall back to the tag. Fall back to the previous value.
    NEW_VERSION="$(echo "$RELEASE_JSON" | jq -r \
      '(.name | capture("v(?<v>[0-9]+\\.[0-9]+\\.[0-9]+)") | .v) // (.tag_name | capture("v(?<v>[0-9]+\\.[0-9]+\\.[0-9]+)") | .v) // empty' \
      2>/dev/null || true)"
  fi
fi
if [ -z "$NEW_VERSION" ]; then
  if [ -n "$PREV_VERSION" ]; then
    echo "  hermes version: $PREV_VERSION (kept previous; API unavailable)"
    NEW_VERSION="$PREV_VERSION"
  else
    # Last-resort fallback so the file always exists and the build never
    # crashes on a missing HERMES_VERSION.
    echo "  hermes version: unknown (API unavailable, no previous value)"
    NEW_VERSION="0.0.0-unknown"
  fi
else
  echo "  hermes version: $NEW_VERSION"
fi
printf '%s\n' "$NEW_VERSION" > "$HERMES_VERSION_FILE"

# ── Record upstream commit ──────────────────────────────────────────────────
UPSTREAM_SHA=$(cd "$MONOREPO" && git rev-parse HEAD)
UPSTREAM_DATE=$(cd "$MONOREPO" && git log -1 --format=%cs HEAD)
echo "  upstream commit: $UPSTREAM_SHA ($UPSTREAM_DATE)"

cat > "$ROOT/UPSTREAM.md" << UPEOF
# Provenance

\`app/\` and \`shared/\` are extracted from the Hermes Agent monorepo
(MIT licensed, Copyright (c) 2025 Nous Research; see \`LICENSE\`).

- Upstream: \`hermes-agent\` repository, \`apps/desktop\` and \`apps/shared\`.
- Extracted at upstream commit: \`$UPSTREAM_SHA\` ($UPSTREAM_DATE).
- Extraction date: $(date +%Y-%m-%d).

## What was changed from upstream

- Removed everything Electron: \`electron/\`, \`scripts/\`, \`packaging/\`,
  \`tsconfig.electron.json\`, electron/electron-builder deps and scripts,
  native deps (\`node-pty\`, \`simple-git\`).
- \`package.json\` rewritten for a plain Vite web app (renamed \`hermes-ui\`).
- \`vite.config.ts\`: removed monorepo-root react aliases and worktree fs.allow
  hack; added a dev proxy for \`/api\`, \`/auth\`, \`/login\` to a local gateway
  (\`HERMES_GATEWAY_URL\`, default \`http://127.0.0.1:9119\`).
- \`tsconfig.json\`: dropped the Electron project reference.
- Added a web implementation of the \`window.hermesDesktop\` preload bridge
  (see \`app/src/web-bridge/\`); web-capable methods are real, Electron-only
  methods are stubbed behind a capability flag.

## Automation

This file is regenerated by \`scripts/transform.sh\` on every sync.
Do not edit manually.
UPEOF

echo "=== Done ==="
echo "Next: cd app && bun install && bun run build"
