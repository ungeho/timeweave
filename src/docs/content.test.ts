/**
 * The public guide's content boundary, and the safety of what is generated
 * from it.
 *
 * NOT A GENERATED FILE, despite testing one. It asserts on
 * `src/generated/docs.ts`, which `scripts/build-docs.mjs` writes from
 * `content/{ja,en}/*.md`.
 *
 * THE FIRST GROUP IS THE ONE THAT MATTERS MOST. `docs/` holds internal design
 * material -- production measurements, migration procedure, the RLS boundary,
 * the share-token scheme -- and `content/` holds everything a stranger may
 * read. Those two must never be confused, and the moment to pin that is now,
 * while `content/` holds one sample page and the mistake would be cheap.
 *
 * The renderer's own guarantees are checked where they are produced: the
 * generator runs a self-check on every invocation and fails the build if raw
 * HTML stops being escaped or a dangerous scheme reaches an attribute. What
 * these tests add is the same questions asked of the REAL output, which is
 * what actually ships.
 */

import { describe, expect, it } from 'vitest';
import { DOCS, DOC_IDS, TRANSLATION, type DocId } from '../generated/docs';

/** Every Markdown file under content/, raw. */
const CONTENT = import.meta.glob('/content/**/*.md', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

/** Every screenshot on disk. `?url` keeps the bytes out of the test bundle. */
const IMAGE_FILES = import.meta.glob('/content/images/**/*.png', {
  query: '?url',
  import: 'default',
  eager: true,
}) as Record<string, string>;

/**
 * What the build actually publishes.
 *
 * Imported from the plugin rather than recomputed here, so the test and the
 * build cannot disagree about the answer.
 */
import { publishedImagePaths } from '../../scripts/guide-images.mjs';

const PUBLISHED = publishedImagePaths();

/** The manifest, as data. */
import MANIFEST_JSON from '../../content/images/manifest.json';

const MANIFEST = MANIFEST_JSON as unknown as {
  capturedWith: Record<string, string>;
  images: Record<
    string,
    { langs: string[]; alt: Record<string, string>; width: number; height: number }
  >;
};

/** The languages a screenshot may be shot in. */
const LANGS = ['ja', 'en'] as const;

/** Everything under src/, for the "nothing imports the parser" checks. */
const SOURCES = import.meta.glob('/src/**/*.{ts,tsx}', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

const generated = SOURCES['/src/generated/docs.ts'] ?? '';
const allHtml = DOC_IDS.flatMap((id) => {
  const out = [DOCS.ja[id].html];
  const en = DOCS.en[id];
  if (en) out.push(en.html);
  return out;
});

/** A handler attribute inside a real tag -- escaped source text is not one. */
const HANDLER_ATTR = /<[^>]+\son\w+\s*=/i;
/** A dangerous scheme that actually became a URL attribute. */
const DANGEROUS_URL = /(?:href|src)\s*=\s*["']?\s*(?:javascript|data|vbscript|file):/i;

// ---------------------------------------------------------------------------

describe('internal material cannot become public content', () => {
  it('only content/ja and content/en feed the generator', () => {
    const dirs = new Set(
      Object.keys(CONTENT)
        .map((p) => p.replace(/^\/content\//, '').split('/')[0])
        .filter((d): d is string => d !== undefined),
    );
    // README.md sits at the top of content/ as a note to whoever adds a page;
    // it has no language directory and so is never read as a document.
    for (const d of dirs) {
      expect(['ja', 'en', 'README.md'], d).toContain(d);
    }
  });

  it('no file under docs/ is reachable as content', () => {
    for (const p of Object.keys(CONTENT)) {
      expect(p, p).not.toMatch(/^\/docs\//);
    }
  });

  it('the generated module carries nothing from the internal design docs', () => {
    // Sentences that exist only in docs/ and in README's security section. If
    // one of them ever appears here, something widened the input.
    for (const leak of [
      'SECURITY DEFINER',
      'token_hash',
      'search_path',
      'RLS',
      'timeweave_private',
      'migration 0025',
      'TIMEWEAVE_TZ_INVALID',
      'service_role',
    ]) {
      expect(generated, leak).not.toContain(leak);
    }
  });

  it('the generator reads an allow list of directories, not a scan', () => {
    const script = (
      import.meta.glob('/scripts/build-docs.mjs', {
        query: '?raw',
        import: 'default',
        eager: true,
      }) as Record<string, string>
    )['/scripts/build-docs.mjs'];
    expect(script).toBeTypeOf('string');
    expect(script).toContain("const LANGS = ['ja', 'en']");
    // And it refuses the three ways a file could arrive from outside.
    expect(script).toMatch(/isSymbolicLink/);
    expect(script).toMatch(/escapes the content directory/);
    expect(script).toMatch(/name\.endsWith\('\.md'\)/);
    // It never names the internal directory.
    expect(script).not.toMatch(/['"`]docs['"`]\s*[,)\]]/);
  });
});

describe('the generated HTML is safe to put in a page', () => {
  it('contains no script, iframe or object element', () => {
    for (const html of allHtml) {
      expect(html).not.toMatch(/<script/i);
      expect(html).not.toMatch(/<iframe/i);
      expect(html).not.toMatch(/<object/i);
      expect(html).not.toMatch(/<embed/i);
    }
  });

  it('contains no event-handler attribute', () => {
    for (const html of allHtml) {
      expect(html).not.toMatch(HANDLER_ATTR);
    }
  });

  it('contains no dangerous URL in an href or src', () => {
    for (const html of allHtml) {
      expect(html).not.toMatch(DANGEROUS_URL);
    }
  });

  it('every external link gives away neither opener nor referrer', () => {
    for (const html of allHtml) {
      const externals = [...html.matchAll(/<a\s+href="https?:\/\/[^"]*"[^>]*>/gi)];
      for (const [tag] of externals) {
        expect(tag).toContain('rel="noopener noreferrer"');
        expect(tag).toContain('target="_blank"');
      }
    }
  });

  it('raw HTML is disabled at the converter, not filtered afterwards', () => {
    // The guarantee is the renderer setting, which holds for every page
    // whatever it contains -- so it is asserted on the generator rather
    // than on prose that happened to mention it. The generator also
    // refuses to run if that setting ever stops working.
    const script = (
      import.meta.glob('/scripts/build-docs.mjs', {
        query: '?raw',
        import: 'default',
        eager: true,
      }) as Record<string, string>
    )['/scripts/build-docs.mjs'];
    expect(script).toMatch(/html: false,/);
    expect(script).toMatch(/runSelfCheck\(\);/);
    expect(script).toContain('raw HTML is escaped, not passed through');
  });
});

describe('the formats the guide needs all render', () => {
  const ja = DOCS.ja['getting-started'].html;

  it('GFM tables', () => {
    // The whole explanation of visibility and sharing is tables, so this is
    // not a nicety.
    expect(ja).toContain('<table>');
    expect(ja).toContain('<thead>');
    expect(ja).toContain('<th>');
    expect(ja).toContain('<tbody>');
  });

  it('the renderer still supports every format the guide may use', () => {
    // Capability, not usage: a chapter that uses no code block today must
    // not be able to remove the guarantee. The generator checks the
    // formats on every run and fails the build if one stops rendering.
    const script = (
      import.meta.glob('/scripts/build-docs.mjs', {
        query: '?raw',
        import: 'default',
        eager: true,
      }) as Record<string, string>
    )['/scripts/build-docs.mjs'];
    expect(script).toContain('the formats the guide relies on all render');
    expect(script).toMatch(/<pre><code class="language-text">/);
    expect(script).toMatch(/<blockquote>/);
  });

  it('headings carry an id, including Japanese ones', () => {
    expect(ja).toMatch(/<h1 id="[^"]+">/);
    expect(ja).toMatch(/<h2 id="[^"]+">/);
    const headings = DOCS.ja['getting-started'].headings;
    expect(headings.length).toBeGreaterThan(3);
    for (const h of headings) {
      expect(h.id, h.text).not.toBe('');
      expect(h.level, h.text).toBeGreaterThanOrEqual(1);
    }
  });

  it('heading ids are unique within a page', () => {
    for (const id of DOC_IDS) {
      for (const doc of [DOCS.ja[id], DOCS.en[id]]) {
        if (!doc) continue;
        const ids = doc.headings.map((h) => h.id);
        expect(new Set(ids).size, `${doc.lang}/${id}`).toBe(ids.length);
      }
    }
  });

  it('a same-page anchor resolves to a heading that exists', () => {
    for (const id of DOC_IDS) {
      for (const doc of [DOCS.ja[id], DOCS.en[id]]) {
        if (!doc) continue;
        const known = new Set(doc.headings.map((h) => h.id));
        const anchors = [...doc.html.matchAll(/href="#([^"]+)"/g)].map((m) =>
          decodeURIComponent(m[1] ?? ''),
        );
        for (const a of anchors) {
          expect(known, `${doc.lang}/${id} -> #${a}`).toContain(a);
        }
      }
    }
  });
});

/**
 * Screenshots.
 *
 * The guide explains screens with pictures, and three things about a picture
 * are invisible to whoever adds it: a missing alt reads fine to the author, a
 * mistyped path renders as a broken icon only in a browser, and an image
 * nobody recorded cannot be re-shot when the screen changes. The generator
 * refuses to build when any of the three is wrong; these assert the same
 * properties of what it produced.
 */
describe('every screenshot the guide shows is real, described and recorded', () => {
  const images = DOC_IDS.flatMap((id) => {
    const doc = DOCS.ja[id];
    return [...doc.html.matchAll(/<img\s+src="([^"]+)"\s+alt="([^"]*)"/g)].map((m) => ({
      page: id,
      src: m[1] ?? '',
      alt: m[2] ?? '',
    }));
  });

  it('the guide actually shows some', () => {
    // Otherwise everything below passes by having nothing to check.
    expect(images.length).toBeGreaterThanOrEqual(3);
  });

  it('every src is a root-relative png under content/images', () => {
    // No absolute URL, no traversal, no other file type. The renderer would
    // also refuse a dangerous scheme, but an image that merely points
    // somewhere else on the internet is a privacy question of its own: a
    // reader opening the guide would fetch it from a third party.
    for (const img of images) {
      expect(img.src, img.src).toMatch(/^\/content\/images\/(ja|en)\/[a-z0-9-]+\.png$/);
    }
  });

  it('a Japanese page shows only Japanese screenshots', () => {
    // An English screenshot on a Japanese page is the mistake this catches,
    // and it would look entirely plausible in a diff.
    for (const img of images) {
      expect(img.src, `${img.page}: ${img.src}`).toMatch(/^\/content\/images\/ja\//);
    }
  });

  it('every image carries alt text that says something', () => {
    for (const img of images) {
      expect(img.alt.trim(), img.src).not.toBe('');
      // Not just the file name restated.
      expect(img.alt.length, img.src).toBeGreaterThan(10);
    }
  });

  it('every image file exists, in both languages', () => {
    // Both: the English screenshots are shot now and used when the guide is
    // translated, so a missing one would be found only at translation time.
    for (const img of images) {
      const id = /\/([a-z0-9-]+)\.png$/.exec(img.src)?.[1];
      expect(id, img.src).toBeTypeOf('string');
      for (const lang of LANGS) {
        expect(
          IMAGE_FILES[`/content/images/${lang}/${id}.png`],
          `${lang}/${id}.png`,
        ).toBeTypeOf('string');
      }
    }
  });

  it('every image is in the manifest, with alt text for both languages', () => {
    for (const img of images) {
      const id = /\/([a-z0-9-]+)\.png$/.exec(img.src)?.[1] as string;
      const entry = MANIFEST.images[id];
      if (!entry) {
        expect.fail(`image is not in the manifest: ${id}`);
        return;
      }
      expect([...entry.langs].sort(), id).toEqual([...LANGS].sort());
      for (const lang of LANGS) {
        expect(String(entry.alt?.[lang] ?? '').trim(), `${id}:${lang}`).not.toBe('');
      }
      expect(entry.width, id).toBeGreaterThan(0);
      expect(entry.height, id).toBeGreaterThan(0);
    }
  });

  it('the manifest lists nothing that is not on disk', () => {
    for (const [id, entry] of Object.entries(MANIFEST.images)) {
      for (const lang of entry.langs) {
        expect(
          IMAGE_FILES[`/content/images/${lang}/${id}.png`],
          `${lang}/${id}.png`,
        ).toBeTypeOf('string');
      }
    }
  });

  it('the manifest records the isolated environment the shots came from', () => {
    // So a reader can tell that no production data could have reached them.
    const c = MANIFEST.capturedWith;
    expect(c.api).toContain('127.0.0.1');
    expect(c.session).toContain('.test');
  });

  it('no explanation is burned into a picture', () => {
    // The numbers and the steps live in the prose beside the image, so the
    // translator edits text rather than re-rendering artwork, and a screen
    // reader gets the steps at all. What this can check is that the prose is
    // there: every image is followed by a paragraph or a table.
    for (const id of DOC_IDS) {
      const html = DOCS.ja[id].html;
      for (const m of html.matchAll(/<img\s[^>]*>/g)) {
        const after = html.slice((m.index ?? 0) + m[0].length, (m.index ?? 0) + m[0].length + 400);
        expect(after, `${id}: nothing explains the image`).toMatch(/<p>|<table>/);
      }
    }
  });
});

/**
 * The delivery path.
 *
 * THE BUG THIS EXISTS FOR. `content/images/` is neither `public/` nor
 * reachable from the app's module graph, so `vite build` emitted none of it.
 * Every screenshot URL then resolved, in production, to the SPA fallback:
 * status 200, Content-Type text/html, 529 bytes of index.html. The files were
 * on disk and the Markdown referenced them correctly; what was missing was
 * the build step that puts them where a browser can fetch them.
 *
 * A check that only read the status code would have called that a success,
 * which is why the manual verification compared bytes and why these tests
 * assert the PUBLISHED SET rather than the presence of files.
 */
describe('every screenshot the guide shows is actually published', () => {
  it('the manifest is the allow list, and the plugin emits exactly it', () => {
    // A file dropped into content/images without a manifest entry is NOT
    // published. Registering a screenshot is therefore the act that
    // publishes it, which is the same discipline build-docs.mjs enforces on
    // references.
    const expected = Object.entries(MANIFEST.images)
      .flatMap(([id, entry]) => entry.langs.map((l) => `content/images/${l}/${id}.png`))
      .sort();
    expect(PUBLISHED).toEqual(expected);
  });

  it('publishes both languages of every screenshot', () => {
    // Counted against the manifest rather than against a literal, which went
    // stale the first time the guide gained a screenshot. What matters is
    // that the two languages stay in step: an English shot is taken now and
    // used when the guide is translated, so a missing one would surface only
    // at translation time.
    const ids = Object.keys(MANIFEST.images);
    expect(ids.length).toBeGreaterThan(0);
    expect(PUBLISHED).toHaveLength(ids.length * LANGS.length);
    for (const lang of LANGS) {
      expect(
        PUBLISHED.filter((p) => p.startsWith(`content/images/${lang}/`)),
        lang,
      ).toHaveLength(ids.length);
    }
  });

  it('every URL the guide renders is one of the published files', () => {
    // The two halves have to agree: a reference the build does not publish is
    // the production 404 all over again.
    const referenced = DOC_IDS.flatMap((id) =>
      [...DOCS.ja[id].html.matchAll(/<img\s+src="([^"]+)"/g)].map((m) => (m[1] ?? '').slice(1)),
    );
    expect(referenced.length).toBeGreaterThan(0);
    for (const r of referenced) {
      expect(PUBLISHED, r).toContain(r);
    }
  });

  it('publishes nothing but png files under content/images', () => {
    // Not the Markdown sources beside them, not the manifest, not docs/.
    for (const p of PUBLISHED) {
      expect(p, p).toMatch(/^content\/images\/(ja|en)\/[a-z0-9-]+\.png$/);
    }
  });

  it('the build is wired to the plugin', () => {
    // Without this line in vite.config the images silently stop shipping,
    // and nothing else in the suite would notice: the files, the manifest
    // and the references would all still be correct.
    const cfg = (
      import.meta.glob('/vite.config.ts', {
        query: '?raw',
        import: 'default',
        eager: true,
      }) as Record<string, string>
    )['/vite.config.ts'];
    expect(cfg).toContain('guideImages()');
    expect(cfg).toContain("from './scripts/guide-images.mjs'");
  });

  it('does not publish the capture tooling or the internal notes', () => {
    // The mock API moved into the repository in P7-d stage 2 so a shot could
    // be reproduced from another machine. That removed the thing which had
    // kept it out of the build -- being outside the repository -- so the
    // boundary now has to be asserted rather than assumed.
    //
    // It is dev tooling under scripts/, nothing in src/ imports it, and the
    // only plugin that copies files into the build emits manifest-listed
    // PNGs. Both halves are checked here.
    for (const p of PUBLISHED) {
      expect(p, p).not.toContain('mock-supabase');
      expect(p, p).not.toMatch(/^(scripts|docs)\//);
      expect(p, p).not.toMatch(/\.(mjs|js|ts|json|md)$/);
    }

    // And no app module pulls the mock in, which would put it in the graph.
    const sources = import.meta.glob('/src/**/*.{ts,tsx}', {
      query: '?raw',
      import: 'default',
      eager: true,
    }) as Record<string, string>;
    for (const [path, text] of Object.entries(sources)) {
      expect(text, path).not.toContain('mock-supabase');
    }
  });

  it('the emitted path is the URL the Markdown already uses', () => {
    // So there is no second source of truth to rewrite, and no mapping step
    // that could drift from the references.
    for (const p of PUBLISHED) {
      expect(IMAGE_FILES[`/${p}`], p).toBeTypeOf('string');
    }
  });
});

/**
 * Links between chapters.
 *
 * WHY THESE ARE WORTH PINNING. There is no documentation screen yet, so a
 * `/ja/docs/typo` link is read by nobody and clicked by nobody: it would ship
 * and sit there until the screen lands. The guide crossed into nine chapters
 * with dozens of links between them, which is more than a reader of a diff
 * can keep in their head.
 *
 * The language segment is checked too. A Japanese chapter linking to
 * `/en/docs/...` would send the reader to a page that does not exist yet, and
 * it is exactly the slip a copy-paste between languages produces.
 */
describe('the chapters link to each other and to nothing else', () => {
  /** Every internal doc link in the generated HTML, per page. */
  const links = DOC_IDS.flatMap((id) =>
    [...DOCS.ja[id].html.matchAll(/href="\/([a-z]{2})\/docs\/([^"#]+)"/g)].map((m) => ({
      from: id,
      lang: m[1] ?? '',
      to: m[2] ?? '',
    })),
  );

  it('the chapters do link to each other', () => {
    // Otherwise everything below passes by having nothing to check.
    expect(links.length).toBeGreaterThanOrEqual(9);
  });

  it('every link names a chapter that exists', () => {
    for (const l of links) {
      expect(DOC_IDS, `${l.from} -> ${l.to}`).toContain(l.to);
    }
  });

  it('a Japanese chapter links to Japanese chapters', () => {
    for (const l of links) {
      expect(l.lang, `${l.from} -> /${l.lang}/docs/${l.to}`).toBe('ja');
    }
  });

  it('no chapter links to itself', () => {
    // A self-link is always a copy-paste leftover, never intent.
    for (const l of links) {
      expect(l.to, `${l.from} links to itself`).not.toBe(l.from);
    }
  });

  it('every chapter can be reached from the first one', () => {
    // A chapter nothing links to is one a reader never finds. getting-started
    // carries the table of contents, so reachability is measured from there.
    const seen = new Set<string>(['getting-started']);
    const queue = ['getting-started'];
    while (queue.length > 0) {
      const here = queue.shift() as string;
      for (const l of links.filter((x) => x.from === here)) {
        if (!seen.has(l.to)) {
          seen.add(l.to);
          queue.push(l.to);
        }
      }
    }
    for (const id of DOC_IDS) {
      expect(seen, `${id} is unreachable from getting-started`).toContain(id);
    }
  });
});

/**
 * What an English file says it was translated from.
 *
 * Read out of the source file rather than the generated module, because the
 * generated module does not carry it: a `Doc` holds the hash of its OWN
 * body, and `TRANSLATION` holds only the verdict. The declared value is the
 * thing a translator could fake to make `stale` go away, so it is worth
 * looking at directly.
 */
function declaredSourceHash(id: string): string | null {
  const text = CONTENT[`/content/en/${id}.md`];
  if (text === undefined) return null;
  const m = /^sourceHash:\s*(\S+)\s*$/m.exec(text);
  return m?.[1] ?? null;
}

describe('ids, languages and translation state', () => {
  it('Japanese is the source of truth and is total', () => {
    for (const id of DOC_IDS) {
      expect(DOCS.ja[id], id).toBeDefined();
      expect(DOCS.ja[id].lang, id).toBe('ja');
      expect(DOCS.ja[id].id, id).toBe(id);
      expect(DOCS.ja[id].title, id).not.toBe('');
    }
  });

  it('English is a translation of the same id, never a new page', () => {
    for (const id of Object.keys(DOCS.en) as DocId[]) {
      expect(DOC_IDS, id).toContain(id);
      expect(DOCS.en[id]?.lang, id).toBe('en');
      expect(DOCS.en[id]?.id, id).toBe(id);
    }
  });

  it('every id has a translation state, and only the three', () => {
    for (const id of DOC_IDS) {
      expect(['translated', 'stale', 'missing'], id).toContain(TRANSLATION[id]);
    }
    expect(Object.keys(TRANSLATION).sort()).toEqual([...DOC_IDS].sort());
  });

  it('missing and stale mean different things', () => {
    // A page with no English at all, and one whose English was written against
    // an older Japanese, need different words on screen and different work
    // from a translator. Collapsing them would lose that.
    for (const id of DOC_IDS) {
      if (!DOCS.en[id]) expect(TRANSLATION[id], id).toBe('missing');
      else expect(['translated', 'stale'], id).toContain(TRANSLATION[id]);
    }
  });

  it('a translated page declares the hash of the Japanese it was made from', () => {
    for (const id of DOC_IDS) {
      if (TRANSLATION[id] !== 'translated') continue;
      expect(DOCS.ja[id].sourceHash, id).toMatch(/^[0-9a-f]{16}$/);
    }
  });

  it('no English page claims a translation it does not have', () => {
    // WAS "every page is missing", which stopped being true the moment P7-g
    // Phase 1 landed three translations. The property worth keeping is not
    // the count -- that moves every phase -- but the agreement between the
    // three facts: a page reads as translated exactly when the English
    // exists AND declares the Japanese body it was made from.
    //
    // A sourceHash copied across to silence `stale` would break this, which
    // is the dishonest shortcut it exists to catch: an honest `stale` or
    // `missing` is what lets the reader be told, instead of being handed an
    // out-of-date page silently.
    for (const id of DOC_IDS) {
      expect(DOCS.ja[id].title, id).not.toBe('');
      const english = DOCS.en[id];
      if (TRANSLATION[id] === 'translated') {
        expect(english, id).toBeDefined();
        expect(english?.lang, id).toBe('en');
        expect(english?.title.trim(), id).not.toBe('');
        // `Doc.sourceHash` is the hash of THAT document's own body, so the
        // English one is the English text and the two are never equal. What
        // has to agree is the hash the English file DECLARES it was made
        // from, which is in its front matter, and the Japanese body's hash.
        expect(declaredSourceHash(id), id).toBe(DOCS.ja[id].sourceHash);
      } else if (TRANSLATION[id] === 'stale') {
        expect(english, id).toBeDefined();
        expect(declaredSourceHash(id), id).not.toBe(DOCS.ja[id].sourceHash);
      } else {
        expect(english, id).toBeUndefined();
      }
    }
  });

  it('an English page exists only where the generator says it is translated', () => {
    // The two directions of the same fact, so neither can drift alone.
    const present = DOC_IDS.filter((id) => DOCS.en[id] !== undefined).sort();
    const claimed = DOC_IDS.filter((id) => TRANSLATION[id] !== 'missing').sort();
    expect(present).toEqual(claimed);
  });
});

describe('the generated module is current and costs the reader nothing', () => {
  it('every content file has an entry', () => {
    // Catches the obvious mistake: a page added to content/ without running
    // the generator. The exhaustive version is `npm run docs:check`, which
    // compares the whole file and runs in prebuild.
    for (const path of Object.keys(CONTENT)) {
      const m = /^\/content\/(ja|en)\/(.+)\.md$/.exec(path);
      if (!m) continue;
      const [, lang, id] = m;
      const doc = lang === 'ja' ? DOCS.ja[id as DocId] : DOCS.en[id as DocId];
      expect(doc, path).toBeDefined();
    }
  });

  it('every entry has a content file', () => {
    for (const id of DOC_IDS) {
      expect(CONTENT[`/content/ja/${id}.md`], id).toBeTypeOf('string');
    }
  });

  it('no Markdown parser reaches the browser', () => {
    // The whole reason for converting at build time. The generated module is
    // plain data with a single type-only import.
    expect(generated).not.toMatch(/from ['"]markdown-it['"]/);
    expect(generated).toMatch(/^import type \{ Language \}/m);
    for (const [path, text] of Object.entries(SOURCES)) {
      expect(text, path).not.toMatch(/from ['"]markdown-it['"]/);
    }
  });

  it('it is marked as generated, so nobody edits it by hand', () => {
    expect(generated).toMatch(/GENERATED by scripts\/build-docs\.mjs -- do not edit/);
  });
});
