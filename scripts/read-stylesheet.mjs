/**
 * The application stylesheet, as text, for tests that check it.
 *
 * WHY THIS IS NOT `import.meta.glob`. Everywhere else in this project a test
 * that needs a file's text reads it with `import.meta.glob(..., '?raw')`, and
 * that works for .ts and .tsx. It does NOT work for a stylesheet: vitest runs
 * in `environment: 'node'`, where Vite resolves CSS through its own pipeline
 * and hands back an empty string for both `?raw` and `?inline`. Measured, not
 * assumed -- the keys come back correct and the values are length 0.
 *
 * So the one test that has to read CSS reads it here instead. Plain JavaScript
 * because it uses `node:fs` and this project carries no @types/node; the typed
 * side is read-stylesheet.d.mts. The same arrangement guide-images.mjs uses.
 */

import { readFileSync } from 'node:fs';
import { join } from 'node:path';

export function readStylesheet() {
  return readFileSync(join('src', 'styles', 'global.css'), 'utf8');
}
