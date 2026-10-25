/**
 * What the documentation screens decide.
 *
 * The screens themselves cannot be rendered here -- vitest runs with
 * `environment: 'node'` and jsdom is deliberately not added -- so everything
 * worth asserting was put in a pure module and is asserted here, plus a set of
 * structural checks over the component source for the properties that only
 * exist in the markup.
 */

import { describe, expect, it } from 'vitest';
import { DOCS, DOC_IDS, TRANSLATION, type DocId } from '../../generated/docs';
import { LANGUAGES } from '../../i18n/types';
import { parseRoute } from '../../routing/route';
import {
  DOC_GROUPS,
  READING_ORDER,
  SOURCE_LANGUAGE,
  docsPath,
  docsText,
  isDocIdKnown,
  needsLanguageInUrl,
  neighbours,
  resolveDocPage,
  switchLanguagePath,
  tocHeadings,
  viewLanguage,
  docTitle,
} from './docsView';

/** Every source file, for the structural checks. */
const SOURCES = import.meta.glob('/src/**/*.{ts,tsx}', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

/** Comments stripped, so a check never matches prose about the thing. */
const code = (t: string) =>
  t.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

describe('the reading order covers the guide exactly', () => {
  it('lists every chapter once', () => {
    // A chapter missing here has no previous/next and never appears in the
    // sidebar, which is invisible until someone looks for it.
    expect([...READING_ORDER].sort()).toEqual([...DOC_IDS].sort());
    expect(new Set(READING_ORDER).size).toBe(READING_ORDER.length);
  });

  it('the groups cover every chapter once, in reading order', () => {
    const grouped = DOC_GROUPS.flatMap((g) => g.ids);
    expect(grouped).toEqual([...READING_ORDER]);
  });

  it('starts at getting-started', () => {
    expect(READING_ORDER[0]).toBe('getting-started');
  });
});

describe('previous and next', () => {
  it('the first chapter has no previous and the last no next', () => {
    expect(neighbours(READING_ORDER[0]!).prev).toBeNull();
    expect(neighbours(READING_ORDER[READING_ORDER.length - 1]!).next).toBeNull();
  });

  it('walking next from the first reaches every chapter in order', () => {
    const walked: DocId[] = [READING_ORDER[0]!];
    let cur = neighbours(READING_ORDER[0]!).next;
    while (cur) {
      walked.push(cur);
      cur = neighbours(cur).next;
    }
    expect(walked).toEqual([...READING_ORDER]);
  });

  it('previous undoes next', () => {
    for (const id of READING_ORDER) {
      const n = neighbours(id).next;
      if (n) expect(neighbours(n).prev).toBe(id);
    }
  });
});

describe('which language a page is read in', () => {
  it('the URL wins over the viewer', () => {
    // A documentation link is shared, and the person who receives it has to
    // see what the sender saw.
    expect(viewLanguage(parseRoute('/en/docs/faq'), 'ja')).toBe('en');
    expect(viewLanguage(parseRoute('/ja/docs/faq'), 'en')).toBe('ja');
  });

  it('a URL with no language uses the viewer', () => {
    expect(viewLanguage(parseRoute('/docs/faq'), 'en')).toBe('en');
    expect(viewLanguage(parseRoute('/docs'), 'ja')).toBe('ja');
  });

  it('such a URL is flagged for replacement, and a qualified one is not', () => {
    expect(needsLanguageInUrl(parseRoute('/docs/faq'))).toBe(true);
    expect(needsLanguageInUrl(parseRoute('/docs'))).toBe(true);
    expect(needsLanguageInUrl(parseRoute('/ja/docs/faq'))).toBe(false);
    expect(needsLanguageInUrl(parseRoute('/en/docs'))).toBe(false);
  });

  it('an unknown two-letter language is not found, not a silent default', () => {
    const r = parseRoute('/zz/docs/faq');
    expect(r.kind).toBe('docsNotFound');
  });
});

describe('resolving one page', () => {
  it('serves the Japanese chapter for a Japanese URL, with no notice', () => {
    const v = resolveDocPage('faq', 'ja');
    expect(v.kind).toBe('found');
    if (v.kind !== 'found') return;
    expect(v.doc.lang).toBe('ja');
    expect(v.fallbackFrom).toBeNull();
  });

  it('falls back to the source language rather than showing nothing', () => {
    // Every chapter is currently untranslated, so this is the live path.
    for (const id of DOC_IDS) {
      const v = resolveDocPage(id, 'en');
      expect(v.kind, id).toBe('found');
      if (v.kind !== 'found') continue;
      expect(v.doc.html.length, id).toBeGreaterThan(0);
    }
  });

  it('says so whenever the body is not in the language asked for', () => {
    // The notice and the body language are the same fact. A page that served
    // Japanese silently would read as a broken page rather than as work not
    // yet done.
    for (const id of DOC_IDS) {
      const v = resolveDocPage(id, 'en');
      if (v.kind !== 'found') continue;
      const translated = TRANSLATION[id] === 'translated';
      expect(v.fallbackFrom === null, id).toBe(translated);
      if (v.fallbackFrom !== null) expect(v.doc.lang, id).toBe(SOURCE_LANGUAGE);
    }
  });

  it('anything not translated falls back, stale as well as missing', () => {
    // Stale and missing are unusable for different reasons -- they differ for
    // the translator, not for the reader -- so both take the same path.
    //
    // STATED OVER EVERY CHAPTER rather than over a list that must be
    // non-empty: with all nine translated there is nothing in that list, and a
    // test that demanded one would have to be deleted the day the guide was
    // finished. This form keeps working in both directions.
    for (const id of DOC_IDS) {
      const v = resolveDocPage(id, 'en');
      if (v.kind !== 'found') continue;
      if (TRANSLATION[id] === 'translated') {
        expect(v.fallbackFrom, id).toBeNull();
        expect(v.doc.lang, id).toBe('en');
      } else {
        expect(v.fallbackFrom, id).toBe(SOURCE_LANGUAGE);
        expect(v.doc.lang, id).toBe(SOURCE_LANGUAGE);
      }
    }
  });

  it('an unknown id is missing, not a crash and not a blank page', () => {
    for (const bad of ['nope', 'getting-started-x', 'faq2', '']) {
      expect(resolveDocPage(bad, 'ja').kind, bad).toBe('missing');
    }
  });

  it('isDocIdKnown rejects anything not generated', () => {
    expect(isDocIdKnown('faq')).toBe(true);
    expect(isDocIdKnown('../secrets')).toBe(false);
    expect(isDocIdKnown('manifest')).toBe(false);
  });
});

describe('the URLs the screens build', () => {
  it('are always language-qualified', () => {
    // A link that dropped the language would send the reader to a URL the
    // screen then rewrites, putting a redirect in the middle of every click.
    for (const lang of LANGUAGES) {
      expect(docsPath(lang)).toBe(`/${lang}/docs`);
      for (const id of DOC_IDS) expect(docsPath(lang, id)).toBe(`/${lang}/docs/${id}`);
    }
  });

  it('round-trip through the parser to the same place', () => {
    for (const lang of LANGUAGES) {
      for (const id of DOC_IDS) {
        const r = parseRoute(docsPath(lang, id));
        expect(r).toEqual({ kind: 'docsPage', lang, pageId: id });
      }
      expect(parseRoute(docsPath(lang))).toEqual({ kind: 'docsIndex', lang });
    }
  });

  it('switching language keeps the chapter', () => {
    // Switching language says how to read THIS page; dropping the reader on
    // the index every time would make the control unusable mid-article.
    for (const id of DOC_IDS) {
      expect(switchLanguagePath(parseRoute(`/ja/docs/${id}`), 'en')).toBe(`/en/docs/${id}`);
      expect(switchLanguagePath(parseRoute(`/en/docs/${id}`), 'ja')).toBe(`/ja/docs/${id}`);
    }
  });

  it('switching from the index or an unknown page lands on the index', () => {
    expect(switchLanguagePath(parseRoute('/ja/docs'), 'en')).toBe('/en/docs');
    expect(switchLanguagePath(parseRoute('/ja/docs/nope'), 'en')).toBe('/en/docs');
  });
});

describe('the in-page contents list', () => {
  it('lists the level-2 headings and not the title', () => {
    const toc = tocHeadings(DOCS.ja['share-links']);
    expect(toc.length).toBeGreaterThan(2);
    for (const h of toc) expect(h.text.length).toBeGreaterThan(0);
    // The h1 repeats the title already on screen above.
    expect(toc.map((h) => h.text)).not.toContain(DOCS.ja['share-links'].title);
  });

  it('every entry addresses a heading the body actually carries', () => {
    // A fragment that matches nothing scrolls nowhere, and nothing in a build
    // would otherwise notice.
    for (const id of DOC_IDS) {
      const doc = DOCS.ja[id];
      for (const h of tocHeadings(doc)) {
        expect(doc.html, `${id}#${h.id}`).toContain(`id="${h.id}"`);
      }
    }
  });
});

describe('the chrome strings exist in both languages', () => {
  it('every key the screens render resolves, and differs between languages', () => {
    const keys = [
      'docs.indexTitle',
      'docs.backToApp',
      'docs.backToIndex',
      'docs.onThisPage',
      'docs.prev',
      'docs.next',
      'docs.chapters',
      'docs.fallbackNotice',
      'docs.notFound',
      'docs.langSwitch',
    ] as const;
    for (const k of keys) {
      for (const lang of LANGUAGES) {
        const s = docsText(k, lang);
        expect(s, `${k}/${lang}`).not.toBe(k);
        expect(s.trim(), `${k}/${lang}`).not.toBe('');
      }
      // Untranslated chrome would be the one thing an English reader could
      // not get past.
      expect(docsText(k, 'ja'), k).not.toBe(docsText(k, 'en'));
    }
  });

  it('every chapter has a summary and a group label in both languages', () => {
    for (const id of DOC_IDS) {
      for (const lang of LANGUAGES) {
        const s = docsText(`docs.summary.${id}`, lang);
        expect(s, `${id}/${lang}`).not.toBe(`docs.summary.${id}`);
      }
    }
    for (const g of DOC_GROUPS) {
      for (const lang of LANGUAGES) {
        expect(docsText(g.key, lang), `${g.key}/${lang}`).not.toBe(g.key);
      }
    }
  });
});

/**
 * The properties that live in the markup.
 *
 * These are read off the source text because the components cannot be
 * rendered here. Each one guards something whose absence is silent: an unsafe
 * insertion, a fetch on a public route, or a link that stops being a link.
 */
describe('the documentation screens stay public and safe', () => {
  const docsSources = Object.entries(SOURCES).filter(([p]) => p.startsWith('/src/features/docs/'));

  it('there are documentation sources to check', () => {
    expect(docsSources.length).toBeGreaterThanOrEqual(3);
  });

  it('only one place in the whole app inserts HTML, and it reads the generated module', () => {
    // The generated HTML is the ONLY trusted string: build-docs.mjs renders it
    // with html:false, a validateLink allow list and a self-check that fails
    // the build on a handler attribute or a dangerous URL. A second insertion
    // site would be a way in that none of that covers.
    const sites = Object.entries(SOURCES).filter(([, t]) =>
      code(t).includes('dangerouslySetInnerHTML'),
    );
    expect(sites.map(([p]) => p)).toEqual(['/src/features/docs/DocsPage.tsx']);
    const body = code(sites[0]![1]);
    // Its input is a field of a resolved doc, never a prop or a fetch.
    expect(body).toContain('__html: doc.html');
  });

  it('nothing in the documentation screens reads an account', () => {
    // The route is public: no session, no owner_settings, no events. The
    // cheapest way for that to regress is an innocent-looking import.
    for (const [path, text] of docsSources) {
      const c = code(text);
      for (const forbidden of ['supabase', 'useAuth', 'ownerSettings', 'useEvents', 'fetch(']) {
        expect(c, `${path} must not reference ${forbidden}`).not.toContain(forbidden);
      }
    }
  });

  it('chapter links are real anchors with a real href', () => {
    // So they can be middle-clicked, copied and opened in a new tab, and are
    // announced as links. A div with an onClick is none of those.
    const chrome = code(SOURCES['/src/features/docs/DocsChrome.tsx']!);
    expect(chrome).toContain('<a');
    expect(chrome).toContain('href={to}');
    // A modified click is the reader asking for a new tab; it is handed back.
    expect(chrome).toContain('isPlainLeftClick');
    expect(chrome).toContain('e.preventDefault()');
  });

  it('the current chapter is marked for assistive technology', () => {
    // The attribute itself is on the shared link; the screens decide WHEN to
    // set it. Both halves have to be there for a screen reader to announce
    // which chapter is open.
    const chrome = code(SOURCES['/src/features/docs/DocsChrome.tsx']!);
    expect(chrome).toContain('aria-current={ariaCurrent}');
    const page = code(SOURCES['/src/features/docs/DocsPage.tsx']!);
    expect(page).toContain("ariaCurrent={id === current ? 'page' : undefined}");
  });

  it('the body carries its own lang when it is a fallback', () => {
    // So a screen reader switches voice for the article and back for the
    // navigation around it.
    const page = code(SOURCES['/src/features/docs/DocsPage.tsx']!);
    expect(page).toContain('lang={doc.lang}');
  });

  it('the screens use semantic landmarks', () => {
    const chrome = code(SOURCES['/src/features/docs/DocsChrome.tsx']!);
    const page = code(SOURCES['/src/features/docs/DocsPage.tsx']!);
    expect(chrome).toContain('<main');
    expect(chrome).toContain('<header');
    expect(page).toContain('<nav');
    expect(page).toContain('<article');
    // Every nav is named, or a screen reader announces several identical ones.
    const navs = page.match(/<nav\b/g) ?? [];
    const labels = page.match(/aria-label=/g) ?? [];
    expect(labels.length).toBeGreaterThanOrEqual(navs.length);
  });

  it('navigate only accepts a root-relative path', () => {
    // Otherwise in-app navigation becomes a way to send a reader elsewhere:
    // a protocol-relative "//evil.test/x" is an absolute URL that merely
    // looks like a path, which is why it is rejected separately.
    //
    // READ RAW, not comment-stripped: the guard's own string literal contains
    // a double slash, and the stripper would take it for a line comment and
    // eat the rest of the line.
    const nav = SOURCES['/src/routing/navigate.ts']!;
    expect(nav).toContain("path.startsWith('/')");
    expect(nav).toContain("path.startsWith('//')");
    expect(nav).toContain('replaceState');
  });

  it('a push notifies the location store, or the screen would not move', () => {
    // pushState does not emit popstate for its own caller. This is the bug
    // useRoute was written to fix, reachable again from the other side.
    const nav = code(SOURCES['/src/routing/navigate.ts']!);
    expect(nav).toContain('pushState');
    expect(nav).toContain('notify()');
    const useRoute = code(SOURCES['/src/routing/useRoute.ts']!);
    expect(useRoute).toContain('subscribeToLocation');
  });
});

/**
 * The heading outline.
 *
 * A reader moving by heading gets the document's structure and nothing else,
 * so an outline that opens at level 2, or jumps a level, is a page they
 * cannot navigate -- and it looks identical in a browser. The body half is
 * generated, so it can be checked here exactly; the chrome half is asserted
 * structurally below and was confirmed in a browser.
 */
/**
 * What a chapter is called in a list.
 *
 * A sidebar showing an English title beside a body that is Japanese would
 * promise something the page does not deliver, and the reader would find out
 * only after clicking. So the title follows the same fallback the body does,
 * and these assert the two agree -- which is a property of the rule, not of
 * how many chapters happen to be translated this week.
 */
describe('chapter titles follow the body, not the chrome', () => {
  it('Japanese always shows the Japanese title', () => {
    for (const id of DOC_IDS) {
      expect(docTitle(id, 'ja'), id).toBe(DOCS.ja[id].title);
    }
  });

  it('English shows the English title only where the body is English', () => {
    for (const id of DOC_IDS) {
      const view = resolveDocPage(id, 'en');
      if (view.kind !== 'found') continue;
      expect(docTitle(id, 'en'), id).toBe(view.doc.title);
    }
  });

  it('a chapter that falls back keeps the source title', () => {
    for (const id of DOC_IDS) {
      if (TRANSLATION[id] === 'translated') continue;
      expect(docTitle(id, 'en'), id).toBe(DOCS.ja[id].title);
    }
  });

  it('a translated chapter really is titled differently', () => {
    // Without this the tests above could pass on a docTitle that always
    // returned the Japanese one.
    const translated = DOC_IDS.filter((id) => TRANSLATION[id] === 'translated');
    expect(translated.length, 'the guide has translations to check').toBeGreaterThan(0);
    for (const id of translated) {
      expect(docTitle(id, 'en'), id).not.toBe(DOCS.ja[id].title);
      expect(docTitle(id, 'en').trim(), id).not.toBe('');
    }
  });

  it('the guide is fully translated, and says so consistently', () => {
    // P7-g Phase 2 finished the English. The three facts that have to move
    // together are the generated state, the presence of an English document,
    // and what the chrome calls each chapter -- a mismatch between them is
    // what an unfinished or half-reverted translation would look like.
    for (const id of DOC_IDS) {
      expect(TRANSLATION[id], id).toBe('translated');
      expect(DOCS.en[id], id).toBeDefined();
      expect(docTitle(id, 'en'), id).toBe(DOCS.en[id]?.title);
      expect(docTitle(id, 'ja'), id).toBe(DOCS.ja[id].title);
    }
  });
});

/**
 * A translation has to be the same document.
 *
 * Not the same words -- that is the point of translating -- but the same
 * SHAPE: the same sections, the same tables, the same pictures in the same
 * places, and links that stay inside the language they were written for. A
 * section quietly dropped in translation is a specification the English
 * reader never sees, and nothing else here would notice.
 */
describe('each translated chapter matches its source', () => {
  const translated = DOC_IDS.filter((id) => TRANSLATION[id] === 'translated');

  it('there are translations to compare', () => {
    expect(translated.length).toBeGreaterThan(0);
  });

  const count = (html: string, re: RegExp) => (html.match(re) ?? []).length;

  it('the same number of headings, at the same levels', () => {
    for (const id of translated) {
      const ja = [...DOCS.ja[id].html.matchAll(/<h([1-6])\b/g)].map((m) => m[1]);
      const en = [...(DOCS.en[id]?.html ?? '').matchAll(/<h([1-6])\b/g)].map((m) => m[1]);
      expect(en, id).toEqual(ja);
    }
  });

  it('the same number of tables, and the same number of rows in them', () => {
    for (const id of translated) {
      const en = DOCS.en[id]?.html ?? '';
      expect(count(en, /<table>/g), `${id}: tables`).toBe(count(DOCS.ja[id].html, /<table>/g));
      expect(count(en, /<tr>/g), `${id}: rows`).toBe(count(DOCS.ja[id].html, /<tr>/g));
    }
  });

  it('the same pictures, in the same order, from the English set', () => {
    for (const id of translated) {
      const srcs = (html: string) =>
        [...html.matchAll(/<img src="\/content\/images\/([a-z]{2})\/([a-z0-9-]+)\.png"/g)].map(
          (m) => ({ lang: m[1], id: m[2] }),
        );
      const ja = srcs(DOCS.ja[id].html);
      const en = srcs(DOCS.en[id]?.html ?? '');
      expect(en.map((x) => x.id), `${id}: picture order`).toEqual(ja.map((x) => x.id));
      // And from the English directory, which the generator also enforces.
      for (const x of en) expect(x.lang, id).toBe('en');
    }
  });

  it('every picture still has alt text', () => {
    for (const id of translated) {
      for (const tag of (DOCS.en[id]?.html ?? '').match(/<img\s[^>]*>/g) ?? []) {
        expect(tag, id).toMatch(/alt="[^"]{10,}"/);
      }
    }
  });

  it('every internal link stays in English, and names a real chapter', () => {
    // A link to /ja/docs/... inside an English page would drop the reader
    // into the other language mid-sentence. An untranslated target is fine:
    // that URL falls back and says so.
    for (const id of translated) {
      const links = [...(DOCS.en[id]?.html ?? '').matchAll(/href="\/([a-z]{2})\/docs\/([^"#]+)"/g)];
      expect(links.length, `${id}: has internal links`).toBeGreaterThan(0);
      for (const m of links) {
        expect(m[1], `${id} -> /${m[1]}/docs/${m[2]}`).toBe('en');
        expect(DOC_IDS, `${id} -> ${m[2]}`).toContain(m[2]);
      }
    }
  });

  it('the English body is not still Japanese', () => {
    // The shape checks above would all pass on a copied file.
    for (const id of translated) {
      const en = DOCS.en[id]?.html ?? '';
      const jp = (en.match(/[\u3040-\u30ff\u4e00-\u9faf]/g) ?? []).length;
      // Not zero: the guide quotes Japanese UI values in a few places is NOT
      // the case here, but a stray character should not fail the build --
      // what matters is that the page is overwhelmingly English.
      expect(jp / en.length, `${id}: too much Japanese left`).toBeLessThan(0.02);
    }
  });
});

describe('the heading outline', () => {
  it('every chapter body opens at h1, exactly once', () => {
    for (const id of DOC_IDS) {
      const levels = [...DOCS.ja[id].html.matchAll(/<h([1-6])\b/g)].map((m) => Number(m[1]));
      expect(levels.length, id).toBeGreaterThan(1);
      expect(levels[0], id).toBe(1);
      expect(levels.filter((l) => l === 1).length, `${id} has more than one h1`).toBe(1);
    }
  });

  it('no chapter body skips a level', () => {
    for (const id of DOC_IDS) {
      const levels = [...DOCS.ja[id].html.matchAll(/<h([1-6])\b/g)].map((m) => Number(m[1]));
      for (let i = 1; i < levels.length; i++) {
        expect(levels[i]!, `${id}: h${levels[i - 1]} -> h${levels[i]}`).toBeLessThanOrEqual(
          levels[i - 1]! + 1,
        );
      }
    }
  });

  it('the article is rendered before the sidebar', () => {
    // Source order decides the outline. Nav-first put five chapter-group
    // headings and the contents heading -- all h2 -- ahead of the page's own
    // h1; CSS then moves the sidebar back to the left, so the arrangement on
    // screen is unchanged and only the outline differs.
    const chrome = code(SOURCES['/src/features/docs/DocsChrome.tsx']!);
    const layout = chrome.slice(chrome.indexOf('docs-layout'));
    const children = layout.indexOf('{children}');
    const nav = layout.indexOf('{nav}');
    expect(children).toBeGreaterThan(-1);
    expect(nav).toBeGreaterThan(-1);
    expect(children, 'the article must come first in the DOM').toBeLessThan(nav);
  });

  it('the contents list is not itself a heading', () => {
    // It sits above the body, so a heading there would be the first on the
    // page and the article's own h1 the second.
    const page = code(SOURCES['/src/features/docs/DocsPage.tsx']!);
    expect(page).toContain('<div className="docs-toc-heading">');
    expect(page).not.toContain('<h2 className="docs-toc-heading">');
  });
});

/**
 * Keyboard reading.
 *
 * Both of these were confirmed in a browser; these pin the decisions so they
 * cannot be undone silently.
 */
describe('the guide can be read without a mouse', () => {
  it('a skip link is the first thing in the frame', () => {
    // Otherwise a keyboard reader passes the whole chapter list before the
    // prose, on every page.
    const chrome = code(SOURCES['/src/features/docs/DocsChrome.tsx']!);
    const skip = chrome.indexOf('docs-skip');
    const header = chrome.indexOf('<header');
    expect(skip).toBeGreaterThan(-1);
    expect(skip, 'the skip link must precede the header').toBeLessThan(header);
    expect(chrome).toContain('href="#docs-main"');
    expect(chrome).toContain("id=\"docs-main\"");
  });

  it('focus moves to the new page after an in-app navigation', () => {
    // A push replaces the content and leaves focus on the link that was
    // clicked, inside a sidebar that now describes a different page: nothing
    // is announced and the next Tab continues from the old position.
    const chrome = code(SOURCES['/src/features/docs/DocsChrome.tsx']!);
    expect(chrome).toContain('focusKey');
    expect(chrome).toContain('main.current?.focus()');
    // ...but NOT on the first render, which would steal focus from wherever
    // the browser put it on an ordinary page load.
    expect(chrome).toContain('first.current');
    // The target must be focusable from script without entering the Tab order.
    expect(chrome).toContain('tabIndex={-1}');
  });

  it('every documentation screen supplies a focus key', () => {
    // One screen without it is one screen whose navigation is silent.
    const page = code(SOURCES['/src/features/docs/DocsPage.tsx']!);
    const frames = (page.match(/<DocsChrome\b/g) ?? []).length;
    const keys = (page.match(/focusKey=/g) ?? []).length;
    expect(frames).toBeGreaterThan(0);
    expect(keys).toBe(frames);
  });
});

describe('the generated HTML is shaped for a reader', () => {
  it('every table can scroll inside its own box', () => {
    // A wide comparison table would otherwise widen the article and push the
    // prose off a phone. Counted by the wrapper's class rather than by the
    // whole opening tag, which gained attributes the moment the box had to be
    // reachable by keyboard.
    for (const id of DOC_IDS) {
      const html = DOCS.ja[id].html;
      const tables = (html.match(/<table>/g) ?? []).length;
      const wrapped = (html.match(/<div class="doc-table"[^>]*><table>/g) ?? []).length;
      expect(wrapped, id).toBe(tables);
    }
  });

  it('a table box can be reached and read without a mouse', () => {
    // A scroll container that is not focusable cannot be scrolled from the
    // keyboard at all, and a focusable div with no name is announced as
    // nothing when focus lands on it.
    for (const id of DOC_IDS) {
      for (const tag of DOCS.ja[id].html.match(/<div class="doc-table"[^>]*>/g) ?? []) {
        expect(tag, id).toContain('tabindex="0"');
        expect(tag, id).toContain('role="region"');
        expect(tag, id).toMatch(/aria-label="[^"]+"/);
      }
    }
  });

  it('the table box is named in the language of the page it is on', () => {
    // The label is markup the generator writes, not copy from the dictionary,
    // so this is the only thing that would notice it being left in English on
    // a Japanese page.
    for (const id of DOC_IDS) {
      for (const m of DOCS.ja[id].html.matchAll(/<div class="doc-table"[^>]*aria-label="([^"]+)"/g)) {
        expect(m[1], id).toBe('表');
      }
    }
  });

  it('every image declares its size and defers its load', () => {
    // The size reserves the box, so a screenshot does not shove the next
    // paragraph down when it arrives -- and it is what lets one CSS rule keep
    // a 402px shot at 402px while a 1008px one shrinks to fit.
    for (const id of DOC_IDS) {
      for (const tag of DOCS.ja[id].html.match(/<img\s[^>]*>/g) ?? []) {
        expect(tag, id).toMatch(/\swidth="\d+"/);
        expect(tag, id).toMatch(/\sheight="\d+"/);
        expect(tag, id).toContain('loading="lazy"');
        expect(tag, id).toContain('alt="');
      }
    }
  });

  it('every image can be opened at full size', () => {
    for (const id of DOC_IDS) {
      const html = DOCS.ja[id].html;
      const imgs = (html.match(/<img\s/g) ?? []).length;
      const figures = (html.match(/<a class="doc-figure" href="/g) ?? []).length;
      expect(figures, id).toBe(imgs);
    }
  });

  it('the figure link points at the image it wraps, and nowhere off-site', () => {
    for (const id of DOC_IDS) {
      for (const m of DOCS.ja[id].html.matchAll(
        /<a class="doc-figure" href="([^"]+)"><img src="([^"]+)"/g,
      )) {
        expect(m[1], id).toBe(m[2]);
        expect(m[1], id).toMatch(/^\/content\/images\/(ja|en)\/[a-z0-9-]+\.png$/);
      }
    }
  });
});
