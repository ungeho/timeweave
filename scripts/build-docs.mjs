/**
 * Convert the public guide's Markdown to HTML, at build time.
 *
 * WHY BUILD TIME. The alternative is shipping a Markdown parser to every
 * visitor. The app's bundle already sits above Vite's 500 kB warning, and a
 * parser would be 35-150 kB of it for content that never changes between
 * deploys. Converting here costs the reader nothing: `markdown-it` is a
 * devDependency and no part of it reaches the browser.
 *
 * WHY markdown-it. Three properties the alternatives do not all have:
 *   * `html: false` is its DEFAULT -- raw HTML in a source file is escaped
 *     rather than passed through. `marked` has no equivalent and documents
 *     post-sanitising with DOMPurify instead, which would be a second
 *     dependency doing a job this one can simply not create.
 *   * GFM tables are built in, and the guide's whole explanation of
 *     visibility and sharing is tables.
 *   * `validateLink` is a documented, replaceable hook, so rejecting URL
 *     schemes is configuration rather than post-processing of HTML.
 *
 * WHAT IS NOT WRITTEN HERE. No Markdown parser and no HTML sanitiser: both are
 * places where a subtle bug becomes a security hole, and neither is worth
 * re-deriving. The front-matter reader below is a STRICT VALIDATOR for a fixed
 * four-key schema, not a YAML parser -- it accepts exactly what the schema
 * allows and fails the build on anything else, so its worst failure is a loud
 * rejection of a valid file rather than a quiet acceptance of a bad one.
 *
 * Usage:
 *   node scripts/build-docs.mjs            write src/generated/docs.ts
 *   node scripts/build-docs.mjs --check    verify it is current; exit 1 if not
 */

import { createHash } from 'node:crypto';
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  writeFileSync,
} from 'node:fs';
import { join, resolve, sep } from 'node:path';
import MarkdownIt from 'markdown-it';

const ROOT = resolve(process.cwd());
const CONTENT = join(ROOT, 'content');
const OUT = join(ROOT, 'src', 'generated', 'docs.ts');

/**
 * The only languages, and the only directories read.
 *
 * An ALLOW LIST, not a scan. `docs/` holds internal design material --
 * production measurements, migration procedure, the RLS boundary -- and the
 * one thing this script must never do is publish it. The boundary is therefore
 * stated as "these two directories", not "everything except...".
 */
const LANGS = ['ja', 'en'];
/** Japanese is the source of truth; English is a translation of it. */
const SOURCE_LANG = 'ja';

const DOC_ID = /^[a-z0-9](?:[a-z0-9]|-(?=[a-z0-9])){0,63}$/;

/** Where screenshots live, and the manifest that describes them. */
const IMAGES_DIR = join(CONTENT, 'images');
const MANIFEST = join(IMAGES_DIR, 'manifest.json');

/**
 * The only shape an image reference may take.
 *
 * Root-relative, inside content/images, a known language, a manifest id and
 * a .png. Anything else -- an absolute URL, a traversal, a file type the
 * guide has no use for -- stops the build rather than being rendered and
 * explained later.
 */
const IMAGE_SRC = /^\/content\/images\/(ja|en)\/([a-z0-9-]+)\.png$/;

/** Front-matter keys, and which are required per language. */
const FIELDS = ['id', 'lang', 'title', 'sourceHash'];
const REQUIRED = { ja: ['id', 'lang', 'title'], en: ['id', 'lang', 'title', 'sourceHash'] };

class ContentError extends Error {}

function fail(file, message) {
  throw new ContentError(`${file}: ${message}`);
}

// ---------------------------------------------------------------- reading

/**
 * The `.md` files directly inside one language directory.
 *
 * Deliberately NOT recursive, and every entry is checked with `lstat` so a
 * symbolic link is refused rather than followed: a link in `content/ja`
 * pointing at `docs/0025_crossmodel_design.md` would otherwise publish it, and
 * nothing else in this script would notice. The extension check is exact, so a
 * `.md.bak` or a `.MD` does not slip in either.
 */
function listMarkdown(lang) {
  const dir = join(CONTENT, lang);
  const out = [];
  for (const name of readdirSync(dir).sort()) {
    const full = join(dir, name);
    const st = lstatSync(full);
    if (st.isSymbolicLink()) fail(`${lang}/${name}`, 'symbolic links are not read');
    if (!st.isFile()) continue;
    if (!name.endsWith('.md')) continue;
    // Belt and braces: the resolved path must still be inside the language
    // directory. readdir cannot return `..`, but this costs nothing and states
    // the invariant where a reader will look for it.
    const real = resolve(full);
    if (!real.startsWith(resolve(dir) + sep)) fail(`${lang}/${name}`, 'escapes the content directory');
    out.push({ name, full, slug: name.slice(0, -3) });
  }
  return out;
}

/**
 * Split front matter from body and validate the fields.
 *
 * A fixed schema of four scalar keys. Unknown keys, repeated keys, missing
 * required keys and values that do not match their shape all stop the build.
 */
function parseFrontMatter(file, text) {
  const normalised = text.replace(/\r\n/g, '\n');
  if (!normalised.startsWith('---\n')) fail(file, 'must start with a --- front-matter block');
  const end = normalised.indexOf('\n---\n', 3);
  if (end === -1) fail(file, 'front-matter block is not closed');

  const head = normalised.slice(4, end + 1);
  const body = normalised.slice(end + 5);

  const data = {};
  for (const line of head.split('\n')) {
    if (line.trim() === '') continue;
    const m = /^([a-zA-Z][a-zA-Z0-9]*):[ \t]*(.*)$/.exec(line);
    if (!m) fail(file, `front-matter line is not "key: value": ${JSON.stringify(line)}`);
    const [, key, rawValue] = m;
    if (!FIELDS.includes(key)) fail(file, `unknown front-matter key: ${key}`);
    if (key in data) fail(file, `repeated front-matter key: ${key}`);
    const value = rawValue.trim();
    if (value === '') fail(file, `front-matter key has no value: ${key}`);
    if (/^['"]|['"]$/.test(value)) fail(file, `do not quote front-matter values: ${key}`);
    data[key] = value;
  }
  return { data, body };
}

// ------------------------------------------------------------- rendering

/**
 * Only these schemes, plus same-document and same-origin references.
 *
 * An allow list. `javascript:`, `data:`, `vbscript:` and anything else a
 * future reader has not thought of are refused by not being named.
 */
const SAFE_LINK = /^(?:https?:\/\/|mailto:|\/|\.\/|\.\.\/|#)/i;

/** The accessible name of a scrollable table box, per page language. */
const TABLE_LABEL = { ja: '表', en: 'Table' };

function createRenderer(manifest = { images: {} }) {
  // Set per file before rendering, so the generated name matches the page.
  let docLang = SOURCE_LANG;

  const md = new MarkdownIt({
    // Stated explicitly even though it is the default: this is the line that
    // makes raw HTML in a source file inert, and it should be impossible to
    // remove by accident while believing nothing changed.
    html: false,
    linkify: false,
    typographer: false,
    breaks: false,
  });

  md.validateLink = (url) => SAFE_LINK.test(String(url).trim());

  // Heading anchors, so a table of contents and a #fragment can address them.
  const slugs = new Map();
  md.renderer.rules.heading_open = (tokens, idx, options, _env, self) => {
    const inline = tokens[idx + 1];
    const text = inline && inline.type === 'inline' ? inline.content : '';
    let slug = slugify(text);
    const seen = slugs.get(slug) ?? 0;
    slugs.set(slug, seen + 1);
    if (seen > 0) slug = `${slug}-${seen}`;
    tokens[idx].attrSet('id', slug);
    return self.renderToken(tokens, idx, options);
  };

  // External links open elsewhere and must not hand the opener over. The
  // Referrer-Policy header already covers the referrer for the whole site;
  // this covers window.opener, which a header cannot.
  const defaultLinkOpen =
    md.renderer.rules.link_open ??
    ((tokens, idx, options, _env, self) => self.renderToken(tokens, idx, options));
  md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
    const href = tokens[idx].attrGet('href') ?? '';
    if (/^https?:\/\//i.test(href)) {
      tokens[idx].attrSet('target', '_blank');
      tokens[idx].attrSet('rel', 'noopener noreferrer');
    }
    return defaultLinkOpen(tokens, idx, options, env, self);
  };

  // A table that does not fit scrolls sideways INSIDE its own box, rather
  // than widening the article and pushing the prose off a phone. The wrapper
  // has to exist in the HTML because the reader never re-parses it, and it is
  // generated here for the same reason the anchors are: so the browser gets a
  // document that already behaves, with no runtime step to go wrong.
  // tabindex AND a named role: a box that scrolls must be reachable by
  // keyboard, or a table wider than the column cannot be read without a
  // mouse -- and a focusable div with no name is announced as nothing when
  // focus lands on it.
  //
  // The name is in the PAGE's language. It is markup the generator produces
  // rather than copy an author wrote, so it is not in the app dictionary;
  // TABLE_LABEL is the whole of it.
  md.renderer.rules.table_open = () =>
    '<div class="doc-table" tabindex="0" role="region" aria-label="' +
    md.utils.escapeHtml(TABLE_LABEL[docLang] ?? TABLE_LABEL[SOURCE_LANG]) +
    '"><table>';
  md.renderer.rules.table_close = () => '</table></div>';

  // Images carry their own size and loading behaviour.
  //
  // WHY THE DIMENSIONS. Without width and height the browser cannot reserve
  // the box, so every screenshot shoves the paragraph below it down when it
  // arrives. They also let CSS keep a 402px dialog shot at 402px instead of
  // stretching it across a desktop column, while a 1008px calendar still
  // shrinks to fit -- one rule, `max-width:100%;height:auto`, covers both
  // once the intrinsic size is known.
  //
  // WHY THE LINK. A 1008px screenshot on a phone is legible only enlarged.
  // Wrapping it in a plain link to the same file gives that for free: it
  // keyboard-focuses, it middle-clicks, the browser's own viewer handles
  // zoom and closing, and there is no dialog to trap focus in.
  const defaultImage =
    md.renderer.rules.image ??
    ((tokens, idx, options, _env, self) => self.renderToken(tokens, idx, options));
  md.renderer.rules.image = (tokens, idx, options, env, self) => {
    const token = tokens[idx];
    const src = token.attrGet('src') ?? '';
    const m = IMAGE_SRC.exec(src);
    const entry = m ? manifest.images?.[m[2]] : undefined;
    if (entry) {
      token.attrSet('width', String(entry.width));
      token.attrSet('height', String(entry.height));
    }
    token.attrSet('loading', 'lazy');
    token.attrSet('decoding', 'async');
    const img = defaultImage(tokens, idx, options, env, self);
    // Same-origin, so no target or rel: this is the site's own asset, and
    // opening it in place keeps the back button meaningful.
    return `<a class="doc-figure" href="${md.utils.escapeHtml(src)}">${img}</a>`;
  };

  return {
    md,
    resetSlugs: () => slugs.clear(),
    setLang: (l) => {
      docLang = l;
    },
  };
}

/** Keep letters and digits in any script, so Japanese headings keep an anchor. */
function slugify(text) {
  const s = text
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, '-')
    .replace(/^-+|-+$/g, '');
  return s === '' ? 'section' : s;
}

/** Every heading, for a future table of contents. */
function collectHeadings(md, body) {
  const out = [];
  const tokens = md.parse(body, {});
  const slugs = new Map();
  for (let i = 0; i < tokens.length; i += 1) {
    const t = tokens[i];
    if (t.type !== 'heading_open') continue;
    const inline = tokens[i + 1];
    const text = inline && inline.type === 'inline' ? inline.content : '';
    let slug = slugify(text);
    const seen = slugs.get(slug) ?? 0;
    slugs.set(slug, seen + 1);
    if (seen > 0) slug = `${slug}-${seen}`;
    out.push({ id: slug, level: Number(t.tag.slice(1)), text });
  }
  return out;
}

/**
 * Every image must carry alt text, point at a file that exists, and be
 * described in the manifest.
 *
 * ALL THREE AT BUILD TIME. Each is invisible to whoever adds the picture:
 * a missing alt reads fine to the author, a typo in the path renders as a
 * broken icon only in a browser, and an image nobody recorded cannot be
 * re-shot when the screen changes. A build that stops is the cheapest place
 * to find all three.
 *
 * The language in the path must match the document being built, so a
 * Japanese page cannot quietly ship an English screenshot.
 */
function assertImages(file, lang, md, body, manifest) {
  const walk = (tokens) => {
    for (const t of tokens) {
      if (t.type === 'image') {
        const src = t.attrGet('src') ?? '';
        const alt = (t.content ?? '').trim();
        if (alt === '') fail(file, `image has no alt text: ${src}`);

        const m = IMAGE_SRC.exec(src);
        if (!m) fail(file, `image src is not /content/images/<lang>/<id>.png: ${src}`);
        const [, srcLang, id] = m;

        if (srcLang !== lang) {
          fail(file, `image is ${srcLang} but the page is ${lang}: ${src}`);
        }
        if (!manifest.images[id]) {
          fail(file, `image is not in content/images/manifest.json: ${id}`);
        }
        if (!manifest.images[id].langs.includes(lang)) {
          fail(file, `manifest does not list ${lang} for image: ${id}`);
        }
        if (!existsSync(join(IMAGES_DIR, srcLang, `${id}.png`))) {
          fail(file, `image file does not exist: ${src}`);
        }
      }
      if (t.children) walk(t.children);
    }
  };
  walk(md.parse(body, {}));
}

/**
 * The manifest, checked against what is actually on disk.
 *
 * An entry whose file is missing would otherwise be found only when a page
 * started using it.
 */
function readManifest() {
  let raw;
  try {
    raw = readFileSync(MANIFEST, 'utf8');
  } catch {
    fail('content/images/manifest.json', 'is missing');
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    fail('content/images/manifest.json', `is not valid JSON: ${e.message}`);
  }
  const images = parsed.images ?? {};
  for (const [id, entry] of Object.entries(images)) {
    if (!DOC_ID.test(id)) fail(MANIFEST, `image id is not a slug: ${id}`);
    if (!Array.isArray(entry.langs) || entry.langs.length === 0) {
      fail(MANIFEST, `image lists no languages: ${id}`);
    }
    for (const l of entry.langs) {
      if (!LANGS.includes(l)) fail(MANIFEST, `image lists an unknown language: ${id} -> ${l}`);
      if (!existsSync(join(IMAGES_DIR, l, `${id}.png`))) {
        fail(MANIFEST, `manifest lists ${l}/${id}.png but the file is missing`);
      }
      const alt = entry.alt?.[l] ?? '';
      if (String(alt).trim() === '') fail(MANIFEST, `image has no ${l} alt text: ${id}`);
    }
  }
  return { ...parsed, images };
}

/** The hash an English translation declares it was made from. */
function hashBody(body) {
  return createHash('sha256').update(body.trim(), 'utf8').digest('hex').slice(0, 16);
}

// ------------------------------------------------------------- self check

/**
 * The renderer must refuse these, every time it runs.
 *
 * ALWAYS ON, not a separate test command. The properties below are the whole
 * reason this script is allowed to write HTML that a browser will execute, and
 * a configuration change that quietly removed one of them -- flipping
 * `html`, dropping the validateLink override -- would otherwise be noticed by
 * nobody until something was already published. It costs a millisecond.
 */
/**
 * An event handler sitting inside a REAL tag.
 *
 * Not a bare /onclick=/: escaped source text renders as
 * `&lt;div onclick=&quot;x&quot;&gt;`, which contains those characters and is
 * exactly the safe outcome. What must never appear is an attribute inside a
 * tag the browser will act on -- so the pattern requires an unescaped `<`.
 */
const HANDLER_ATTR = /<[^>]+\son\w+\s*=/i;

/**
 * A dangerous scheme that actually became a URL attribute.
 *
 * Not a bare /javascript:/: a link markdown-it REFUSES is left as its own
 * source text, so the output contains the characters `[x](javascript:...)`
 * in a paragraph. That is the safe outcome, and matching on the scheme alone
 * would flag it. What must never appear is href or src actually carrying one.
 */
const DANGEROUS_URL = /(?:href|src)\s*=\s*["']?\s*(?:javascript|data|vbscript|file):/i;

const SELF_CHECK = [
  {
    name: 'raw HTML is escaped, not passed through',
    md: '<script>alert(1)</script>\n\n<div onclick="x">y</div>',
    reject: [/<script/i, /<div/i, HANDLER_ATTR],
  },
  {
    name: 'an iframe or object cannot be written either',
    md: '<iframe src="https://e.test"></iframe>\n\n<object data="x"></object>',
    reject: [/<iframe/i, /<object/i],
  },
  {
    name: 'javascript: never becomes a URL',
    md: '[x](javascript:alert(1))\n\n[y](JaVaScRiPt:alert(1))',
    reject: [DANGEROUS_URL],
  },
  {
    name: 'data: never becomes a URL, for links or images',
    md: '[x](data:text/html;base64,PHNjcmlwdD4=)\n\n![a](data:image/svg+xml;base64,PHN2Zz4=)',
    reject: [DANGEROUS_URL],
  },
  {
    name: 'vbscript: and file: never become URLs',
    md: '[x](vbscript:msgbox)\n\n[y](file:///etc/passwd)',
    reject: [DANGEROUS_URL],
  },
  {
    name: 'an event handler cannot be smuggled through a link title',
    md: '[x](https://e.test "a\" onerror=\"alert(1)")',
    reject: [HANDLER_ATTR],
  },
  {
    name: 'the safe shapes still render',
    md: '[a](https://e.test) [b](/ja/docs/x) [c](#h) ![d](/content/images/ja/x.png)',
    reject: [DANGEROUS_URL, HANDLER_ATTR],
    require: [/href="https:\/\/e\.test"/, /href="\/ja\/docs\/x"/, /src="\/content/],
  },
  {
    // The formats the guide is allowed to rely on. Checked here rather
    // than against a page, so a chapter that happens not to use one
    // today cannot quietly remove the guarantee for tomorrow.
    name: 'the formats the guide relies on all render',
    md: [
      '# H1',
      '',
      '| a | b |',
      '| --- | --- |',
      '| 1 | 2 |',
      '',
      '```text',
      'code',
      '```',
      '',
      '- item',
      '',
      '> quote',
    ].join('\n'),
    reject: [DANGEROUS_URL, HANDLER_ATTR],
    require: [
      /<h1 id="[^"]+">/,
      /<table>/,
      /<thead>/,
      /<th>/,
      /<pre><code class="language-text">/,
      /<ul>/,
      /<blockquote>/,
    ],
  },
];
function runSelfCheck() {
  const { md } = createRenderer();
  for (const c of SELF_CHECK) {
    const html = md.render(c.md);
    for (const bad of c.reject) {
      if (bad.test(html)) {
        console.error(
          `renderer self-check FAILED (${c.name}): output matched ${bad}\n${html}`,
        );
        process.exit(1);
      }
    }
    for (const good of c.require ?? []) {
      if (!good.test(html)) {
        console.error(
          `renderer self-check FAILED (${c.name}): output did not match ${good}\n${html}`,
        );
        process.exit(1);
      }
    }
  }
}

// ------------------------------------------------------------- generation

function readAll() {
  const manifest = readManifest();
  const { md, resetSlugs, setLang } = createRenderer(manifest);
  const byLang = {};

  for (const lang of LANGS) {
    byLang[lang] = new Map();
    for (const { name, full, slug } of listMarkdown(lang)) {
      const file = `content/${lang}/${name}`;
      const { data, body } = parseFrontMatter(file, readFileSync(full, 'utf8'));

      for (const key of REQUIRED[lang]) {
        if (!(key in data)) fail(file, `missing front-matter key: ${key}`);
      }
      if (lang === SOURCE_LANG && 'sourceHash' in data) {
        fail(file, 'the source language carries no sourceHash');
      }
      if (!DOC_ID.test(data.id)) fail(file, `id is not a valid slug: ${data.id}`);
      if (data.id !== slug) fail(file, `id "${data.id}" does not match the file name`);
      if (data.lang !== lang) fail(file, `lang "${data.lang}" does not match the directory`);
      if ('sourceHash' in data && !/^[0-9a-f]{16}$|^PENDING$/.test(data.sourceHash)) {
        fail(file, `sourceHash is not a 16-hex digest or PENDING: ${data.sourceHash}`);
      }

      assertImages(file, lang, md, body, manifest);
      resetSlugs();
      setLang(lang);
      const html = md.render(body);
      const headings = collectHeadings(md, body);

      byLang[lang].set(data.id, {
        id: data.id,
        lang,
        title: data.title,
        html,
        headings,
        bodyHash: hashBody(body),
        declaredSourceHash: data.sourceHash ?? null,
      });
    }
  }

  // English may only translate a page that exists in the source language.
  for (const id of byLang.en.keys()) {
    if (!byLang[SOURCE_LANG].has(id)) {
      fail(`content/en/${id}.md`, `has no ${SOURCE_LANG} source`);
    }
  }
  return byLang;
}

/**
 * Three states, kept apart on purpose.
 *
 *   translated  the English exists and was made from the current Japanese.
 *   stale       the English exists but the Japanese has changed since.
 *   missing     there is no English at all.
 *
 * `stale` and `missing` need different words on screen -- "this page has not
 * been translated yet" and "this page may be out of date" are different
 * promises -- and different work from a translator.
 */
function translationState(source, translation) {
  if (!translation) return 'missing';
  if (translation.declaredSourceHash !== source.bodyHash) return 'stale';
  return 'translated';
}

const lit = (s) => JSON.stringify(s);

function emit(byLang) {
  const ids = [...byLang[SOURCE_LANG].keys()].sort();
  const docLines = (lang) =>
    ids
      .filter((id) => byLang[lang].has(id))
      .map((id) => {
        const d = byLang[lang].get(id);
        const headings = d.headings
          .map((h) => `      { id: ${lit(h.id)}, level: ${h.level}, text: ${lit(h.text)} },`)
          .join('\n');
        return [
          `  ${lit(id)}: {`,
          `    id: ${lit(id)},`,
          `    lang: '${lang}',`,
          `    title: ${lit(d.title)},`,
          `    sourceHash: ${lit(d.bodyHash)},`,
          `    headings: [`,
          headings,
          `    ],`,
          `    html: ${lit(d.html)},`,
          `  },`,
        ]
          .filter((l) => l !== '')
          .join('\n');
      })
      .join('\n');

  const states = ids
    .map((id) => {
      const state = translationState(byLang[SOURCE_LANG].get(id), byLang.en.get(id));
      return `  ${lit(id)}: '${state}',`;
    })
    .join('\n');

  return `/**
 * GENERATED by scripts/build-docs.mjs -- do not edit.
 *
 * Source: content/{${LANGS.join(',')}}/<id>.md. Run \`npm run docs\` to rebuild,
 * \`npm run docs:check\` to verify this file is current.
 *
 * The Markdown parser is a devDependency and does NOT reach the browser: this
 * module is plain data, so the guide costs a reader no parser bytes at all.
 */

import type { Language } from '../i18n/types';

/** Every page the guide has, in the source language. */
export type DocId =
${ids.map((id) => `  | ${lit(id)}`).join('\n') || '  never'};

export interface DocHeading {
  readonly id: string;
  readonly level: number;
  readonly text: string;
}

export interface Doc {
  readonly id: DocId;
  readonly lang: Language;
  readonly title: string;
  /** Of the body this document was rendered from. */
  readonly sourceHash: string;
  readonly headings: readonly DocHeading[];
  /** Rendered at build time with raw HTML disabled. */
  readonly html: string;
}

/**
 * Whether the English version is usable, and if not, why not.
 *
 * 'stale' and 'missing' are different things to tell a reader, and different
 * work for a translator, so they are not collapsed.
 */
export type TranslationState = 'translated' | 'stale' | 'missing';

export const DOC_IDS: readonly DocId[] = [
${ids.map((id) => `  ${lit(id)},`).join('\n')}
];

/**
 * Japanese is total; English is partial.
 *
 * The types say so, which is what lets a caller fall back to the source
 * language without a runtime check for the common case.
 */
export const DOCS: {
  readonly ja: Readonly<Record<DocId, Doc>>;
  readonly en: Readonly<Partial<Record<DocId, Doc>>>;
} = {
  ja: {
${docLines('ja')}
  },
  en: {
${docLines('en')}
  },
};

export const TRANSLATION: Readonly<Record<DocId, TranslationState>> = {
${states}
};
`;
}

// ------------------------------------------------------------------ main

function main() {
  const check = process.argv.includes('--check');
  runSelfCheck();
  let byLang;
  try {
    byLang = readAll();
  } catch (e) {
    if (e instanceof ContentError) {
      console.error(`content error -- ${e.message}`);
      process.exit(1);
    }
    throw e;
  }

  const next = emit(byLang);
  const ids = [...byLang[SOURCE_LANG].keys()].sort();

  if (check) {
    let current = null;
    try {
      current = readFileSync(OUT, 'utf8');
    } catch {
      console.error('src/generated/docs.ts is missing. Run: npm run docs');
      process.exit(1);
    }
    if (current !== next) {
      console.error('src/generated/docs.ts is out of date. Run: npm run docs');
      process.exit(1);
    }
    const stale = ids.filter((id) => translationState(byLang.ja.get(id), byLang.en.get(id)) === 'stale');
    const missing = ids.filter((id) => !byLang.en.has(id));
    console.log(`docs: ${ids.length} page(s), ${missing.length} untranslated, ${stale.length} stale`);
    for (const id of missing) console.log(`  missing  en/${id}.md`);
    for (const id of stale) {
      console.log(`  stale    en/${id}.md  (ja is now ${byLang.ja.get(id).bodyHash})`);
    }
    return;
  }

  mkdirSync(join(ROOT, 'src', 'generated'), { recursive: true });
  writeFileSync(OUT, next);
  console.log(`docs: wrote ${ids.length} page(s) to src/generated/docs.ts`);
}

main();
