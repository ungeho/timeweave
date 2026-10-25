/**
 * Publish the user guide's screenshots with the production build.
 *
 * WHY THIS IS NEEDED. `content/images/` is neither `public/` nor reachable
 * from the app's module graph, so `vite build` emits none of it. The guide's
 * `<img src="/content/images/ja/...png">` then resolves, in production, to the
 * SPA fallback: status 200, `Content-Type: text/html`, 529 bytes of
 * `index.html`. A check that only looked at the status code would call that a
 * success, which is why the tests beside this assert the bytes.
 *
 * WHY NOT `publicDir`. Pointing it at `content/` would publish the Markdown
 * sources too. Pointing it at `content/images/` would serve the files at
 * `/ja/<id>.png` and `/en/<id>.png`, putting screenshots in the same namespace
 * as `/ja/docs/<id>` -- a namespace the router already owns.
 *
 * WHY NOT A COPY IN THE REPOSITORY. There would then be two of every image and
 * nothing to keep them equal.
 *
 * THE MANIFEST IS THE ALLOW LIST. This emits exactly the files
 * `content/images/manifest.json` names, and nothing else -- not the Markdown
 * beside them, not `docs/`, not a stray file someone drops in the directory.
 * A screenshot has to be recorded before it can be published, which is the
 * same discipline `scripts/build-docs.mjs` already enforces on references.
 */

import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const MANIFEST = join('content', 'images', 'manifest.json');

/** Every file the manifest publishes, as `content/images/<lang>/<id>.png`. */
export function publishedImagePaths() {
  const manifest = JSON.parse(readFileSync(MANIFEST, 'utf8'));
  const out = [];
  for (const [id, entry] of Object.entries(manifest.images ?? {})) {
    for (const lang of entry.langs ?? []) {
      out.push(`content/images/${lang}/${id}.png`);
    }
  }
  return out.sort();
}

export function guideImages() {
  return {
    name: 'timeweave-guide-images',
    // Build only. The dev server already serves the project root, so the same
    // URLs work there without help -- which is exactly why the gap showed up
    // only in a production build.
    apply: 'build',
    generateBundle() {
      for (const rel of publishedImagePaths()) {
        this.emitFile({
          type: 'asset',
          // Emitted at the path the Markdown already references, so the URL in
          // the generated HTML needs no rewriting and no second source of truth.
          fileName: rel,
          source: readFileSync(rel),
        });
      }
    },
  };
}
