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
  }
' "$DESKTOP/package.json" > "$ROOT/app/package.json"

# ── Restore preserved config files ──────────────────────────────────────────
echo "  restoring preserved configs …"
cp "$ROOT/preserved/vite.config.ts"  "$ROOT/app/vite.config.ts"
cp "$ROOT/preserved/tsconfig.json"   "$ROOT/app/tsconfig.json"
cp "$ROOT/preserved/index.html"      "$ROOT/app/index.html"

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
