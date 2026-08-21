#!/usr/bin/env node
// patch-runtime-repository.mjs — post-transform hook for apps/<desktop|web>/src/app/chat/runtime-repository.ts
//
// Why: useMessagesWhileVisible (apps/<desktop|web>/src/app/chat/index.tsx)
// subscribes to the $messages atom and `setMessages` always installs a new
// state value, but the atom's array entries are the SAME ChatMessage
// references until the gateway sends a new delta. A naive
// `useMemo(..., [messages])` produces a fresh `{ headId, messages: items }`
// on every flush, which drives useIncrementalExternalStoreRuntime's
// setAdapter effect to re-fire on every render and bumps the
// useSyncExternalStore commit-check depth counter until
// @assistant-ui/tap@>=0.9.13 throws "Maximum update depth exceeded".
// Returning the previous repo when the items match by identity is what makes
// streaming settle instead of loop.
//
// Idempotent: a marker comment (`itemsEqual(`) guards against re-running on
// already-patched files.
//
// Runs on every transform.sh invocation, so the fix survives future upstream
// syncs — see scripts/transform.sh and README.md.
//
// Refs:
//   NousResearch/hermes-agent           #90795
//   assistant-ui/assistant-ui           #6133
//   assistant-ui/assistant-ui#5897

import fs from 'node:fs';

const path = process.argv[2];
if (!path) {
  console.error('  patch-runtime-repository: missing file path argument');
  process.exit(0);
}
if (!fs.existsSync(path)) {
  console.error(`  patch-runtime-repository: ${path} not found`);
  process.exit(0);
}

let src = fs.readFileSync(path, 'utf8');

// Idempotency: already patched.
if (src.includes('function itemsEqual(')) {
  process.exit(0);
}

let modified = false;

// 1) Extend the React import to include ExportedMessageRepositoryItem.
//    MUST run before the itemsEqual insertion, which itself references the
//    type (otherwise the "already present" check would skip the import).
if (!/import \{ type ExportedMessageRepository, ExportedMessageRepositoryItem, ThreadMessage \}/.test(src)) {
  const importPattern = /import type \{ ExportedMessageRepository, ThreadMessage \} from '@assistant-ui\/react'/;
  if (importPattern.test(src)) {
    src = src.replace(
      importPattern,
      "import type { ExportedMessageRepository, ExportedMessageRepositoryItem, ThreadMessage } from '@assistant-ui/react'"
    );
    modified = true;
  }
}

// 2) Insert itemsEqual helper AFTER FALLBACK_STATUS, BEFORE the
//    function-level JSDoc block. Use a marker robust to whitespace.
const fallbackIdx = src.indexOf('FALLBACK_STATUS = getAutoStatus');
if (fallbackIdx !== -1 && src.indexOf('function itemsEqual(') === -1) {
  // find end of the const line (next newline)
  const lineEnd = src.indexOf('\n', fallbackIdx);
  const insertionPoint = lineEnd + 1;
  const insertion =
    '\nfunction itemsEqual(\n' +
    '  a: readonly ExportedMessageRepositoryItem[],\n' +
    '  b: readonly ExportedMessageRepositoryItem[]\n' +
    '): boolean {\n' +
    '  if (a.length !== b.length) return false\n' +
    '  for (let i = 0; i < a.length; i++) {\n' +
    '    const ai = a[i]\n' +
    '    const bi = b[i]\n' +
    '    if (ai.message !== bi.message || ai.parentId !== bi.parentId) return false\n' +
    '  }\n' +
    '  return true\n' +
    '}\n';
  src = src.slice(0, insertionPoint) + insertion + src.slice(insertionPoint);
  modified = true;
}

// 3) Add previousRef after the toolMergeCacheRef line.
if (!/previousRef/.test(src)) {
  const refPattern = /const toolMergeCacheRef = useRef\(createToolMergeCache\(\)\)/;
  if (refPattern.test(src)) {
    src = src.replace(
      refPattern,
      'const toolMergeCacheRef = useRef(createToolMergeCache())\n  const previousRef = useRef<ExportedMessageRepository | null>(null)'
    );
    modified = true;
  }
}

// 4) Replace the final `return { headId, messages: items }` with the
//    stable-reference memo result. Use string match for resilience.
const returnLine = '    return { headId, messages: items }';
if (src.includes(returnLine)) {
  const replacement =
    '    const previous = previousRef.current\n' +
    '    const next: ExportedMessageRepository = previous && previous.headId === headId && itemsEqual(previous.messages, items)\n' +
    '      ? previous\n' +
    '      : { headId, messages: items }\n\n' +
    '    previousRef.current = next\n' +
    '    return next';
  // Replace only the LAST occurrence (the one at the end of useMemo).
  const lastIdx = src.lastIndexOf(returnLine);
  if (lastIdx !== -1) {
    src = src.slice(0, lastIdx) + replacement + src.slice(lastIdx + returnLine.length);
    modified = true;
  }
}

if (modified) {
  fs.writeFileSync(path, src);
  console.log('  patch-runtime-repository: applied');
} else {
  console.error('  patch-runtime-repository: no patterns matched, leaving as-is (re-check next sync)');
}
