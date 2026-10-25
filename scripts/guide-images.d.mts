/**
 * Types for guide-images.mjs.
 *
 * The implementation is plain JavaScript because it uses `node:fs`, and this
 * project carries no @types/node -- a stance it has held since the structural
 * tests chose `import.meta.glob` over reading files. Declaring the two exports
 * here keeps `vite.config.ts` type-checked without adding that dependency.
 */
import type { Plugin } from 'vite';

/** Every file the manifest publishes, as `content/images/<lang>/<id>.png`. */
export function publishedImagePaths(): string[];

/** Emits those files into the build output, and nothing else. */
export function guideImages(): Plugin;
