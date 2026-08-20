#!/usr/bin/env node
// patch-chat-adapter.mjs — post-transform hook for apps/<desktop|web>/src/app/chat/index.tsx
//
// Why: @assistant-ui/tap@>=0.9.13 (PR #5897) added a per-commit getSnapshot
// re-check that throws "Maximum update depth exceeded" when the
// `ExternalStoreAdapter` argument to `useIncrementalExternalStoreRuntime` is a
// fresh object literal on every render. ChatRuntimeBoundary in
// apps/desktop/src/app/chat/index.tsx has exactly that pattern. The fix is to
// memoize the adapter so its identity is stable across renders.
//
// Idempotent: a marker comment in the patched output (`Stable adapter
// reference.`) guards against re-running on already-patched files.
//
// Runs on every transform.sh invocation, so the fix survives weekly upstream
// syncs — see scripts/transform.sh and README.md.
//
// Refs:
//   NousResearch/hermes-agent           #90795
//   assistant-ui/assistant-ui           #6133
//   assistant-ui/assistant-ui#5897      (the upstream tap change that surfaced this)

import fs from 'node:fs';

const path = process.argv[2];
if (!path) {
  console.error('  patch-chat-adapter: missing file path argument');
  process.exit(0);
}
if (!fs.existsSync(path)) {
  console.error(`  patch-chat-adapter: ${path} not found`);
  process.exit(0);
}

let src = fs.readFileSync(path, 'utf8');

// Idempotency: already patched.
if (src.includes('Stable adapter reference.')) {
  process.exit(0);
}

// Match the exact upstream ChatRuntimeBoundary inline-literal block. Anchor
// on the surrounding `transcriptWindow = useMemo(...)` line so we don't
// collide with other useIncrementalExternalStoreRuntime call sites if any
// are added later (none today, but defensive).
const pattern =
  /const transcriptWindow = useMemo\(\(\) => \(\{ olderAvailable, expandWindow \}\), \[expandWindow, olderAvailable\]\)\s*\n\s*const runtime = useIncrementalExternalStoreRuntime<ThreadMessage>\(\{\s*\n\s*messageRepository: runtimeMessageRepository,\s*\n\s*isRunning: busy,\s*\n\s*setMessages: onThreadMessagesChange,\s*\n\s*onNew: async \(\) => \{\s*\n\s*\/\/ Submission is handled explicitly by ChatBar\.\s*\n\s*\/\/ Keeping this no-op avoids duplicate prompt\.submit calls\.\s*\n\s*\},\s*\n\s*onEdit,\s*\n\s*onCancel: async \(\) => onCancel\(\),\s*\n\s*onReload\s*\n\s*\}\)/;

if (!pattern.test(src)) {
  // Pattern moved or upstream renamed the surrounding code. Don't break the
  // sync — log and exit clean.
  console.error('  patch-chat-adapter: pattern not found, skipping (will re-check next sync)');
  process.exit(0);
}

const replacement = `const transcriptWindow = useMemo(() => ({ olderAvailable, expandWindow }), [expandWindow, olderAvailable])

  // Stable adapter reference. @assistant-ui/tap@>=0.9.13 enforces a per-commit
  // getSnapshot re-check; a fresh ExternalStoreAdapter object literal on every
  // render would re-trigger runtime.setAdapter via the effect below (line ~250
  // in incremental-external-store-runtime.ts), which mutates the store and
  // re-notifies subscribers — looping until React's 50-cycle guard throws
  // "Maximum update depth exceeded". Memoize the whole adapter so its
  // identity is stable across renders. See NousResearch/hermes-agent #90795
  // and assistant-ui/assistant-ui #6133.
  const noopAsync = useCallback(async () => {
    // Submission is handled explicitly by ChatBar.
    // Keeping this no-op avoids duplicate prompt.submit calls.
  }, [])

  const wrappedOnCancel = useCallback(async () => {
    await onCancel()
  }, [onCancel])

  const externalStoreAdapter = useMemo(
    () => ({
      messageRepository: runtimeMessageRepository,
      isRunning: busy,
      setMessages: onThreadMessagesChange,
      onNew: noopAsync,
      onEdit,
      onCancel: wrappedOnCancel,
      onReload
    }),
    [runtimeMessageRepository, busy, onThreadMessagesChange, noopAsync, onEdit, wrappedOnCancel, onReload]
  )

  const runtime = useIncrementalExternalStoreRuntime<ThreadMessage>(externalStoreAdapter)`;

src = src.replace(pattern, replacement);

// Ensure ExternalStoreAdapter is imported. useCallback is already imported in
// the upstream file today; be defensive if upstream drops it later.
if (!/import \{[^}]*\bExternalStoreAdapter\b[^}]*\} from '@assistant-ui\/react'/.test(src)) {
  src = src.replace(
    /import \{ (type AppendMessage, )?AssistantRuntimeProvider(, type ThreadMessage)? \} from '@assistant-ui\/react'/,
    "import { type AppendMessage, AssistantRuntimeProvider, type ExternalStoreAdapter, type ThreadMessage } from '@assistant-ui/react'"
  );
}

fs.writeFileSync(path, src);
console.log('  patch-chat-adapter: applied');
