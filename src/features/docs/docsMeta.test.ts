/**
 * What a documentation URL tells a browser and a crawler.
 *
 * THE RULE UNDER TEST, in one sentence: nine chapters exist in Japanese and
 * none in English, so no English URL may be advertised as English content.
 * Every assertion below is a way that could go wrong -- a hreflang, a
 * self-canonical, an indexable fallback -- and each of them would be invisible
 * in the browser, because the page looks fine either way.
 */

import { describe, expect, it } from 'vitest';
import { DOCS, DOC_IDS, TRANSLATION } from '../../generated/docs';
import { LANGUAGES } from '../../i18n/types';
import { parseRoute } from '../../routing/route';
import {
  canonicalOrigin,
  docMeta,
  hasTranslation,
  indexHasTranslation,
  absolute,
} from './docsMeta';
import {
  DOC_SUMMARY,
  SOURCE_LANGUAGE,
  docsPath,
  docsText,
  resolveDocPage,
} from './docsView';

describe('the origin canonical URLs are built from', () => {
  it('prefers a configured origin', () => {
    expect(canonicalOrigin('https://example.com', 'https://other.test')).toBe(
      'https://example.com',
    );
    // Normalised to an origin: a path or a trailing slash in the setting must
    // not end up doubled in every canonical on the site.
    expect(canonicalOrigin('https://example.com/', 'https://other.invalid')).toBe(
      'https://example.com',
    );
    expect(canonicalOrigin('https://example.com/guide', 'https://other.invalid')).toBe(
      'https://example.com',
    );
  });

  it('falls back to where the page is actually served', () => {
    expect(canonicalOrigin(undefined, 'https://example.com')).toBe('https://example.com');
    expect(canonicalOrigin('', 'https://example.com')).toBe('https://example.com');
    expect(canonicalOrigin('   ', 'https://example.com')).toBe('https://example.com');
  });

  it('never publishes a local address as the canonical home of a page', () => {
    // A canonical is an instruction about where a page really lives, and a
    // dev server is true of nobody's site. Saying nothing is correct here.
    for (const local of [
      'http://localhost:5204',
      'http://127.0.0.1:4173',
      'https://app.localhost',
      'http://my-box.local',
      'http://thing.test',
    ]) {
      expect(canonicalOrigin(undefined, local), local).toBeNull();
      expect(canonicalOrigin(local, 'https://example.com'), local).toBeNull();
    }
  });

  it('rejects anything that is not an http origin', () => {
    for (const bad of ['notaurl', 'javascript:alert(1)', 'file:///etc', 'ftp://x.example']) {
      expect(canonicalOrigin(bad, 'https://example.com'), bad).toBeNull();
      expect(canonicalOrigin(undefined, bad), bad).toBeNull();
    }
  });

  it('absolute() stays null when there is no origin', () => {
    expect(absolute(null, '/ja/docs')).toBeNull();
    expect(absolute('https://example.com', '/ja/docs')).toBe('https://example.com/ja/docs');
  });
});

describe('what counts as a translation', () => {
  it('the source language always counts', () => {
    for (const id of DOC_IDS) expect(hasTranslation(id, SOURCE_LANGUAGE), id).toBe(true);
    expect(indexHasTranslation(SOURCE_LANGUAGE)).toBe(true);
  });

  it('a missing or stale English chapter does not count', () => {
    // This is the live state: every chapter is 'missing'.
    for (const id of DOC_IDS) {
      const expected = TRANSLATION[id] === 'translated' && DOCS.en[id] !== undefined;
      expect(hasTranslation(id, 'en'), id).toBe(expected);
    }
  });

  it('the index needs every chapter, not just one', () => {
    // An English index listing mostly Japanese chapters would send a reader
    // into exactly the pages this module refuses to advertise.
    const all = DOC_IDS.every((id) => hasTranslation(id, 'en'));
    expect(indexHasTranslation('en')).toBe(all);
  });
});

describe('a Japanese chapter page', () => {
  it('canonicalises to itself', () => {
    for (const id of DOC_IDS) {
      const m = docMeta(parseRoute(docsPath('ja', id)), 'ja');
      expect(m.canonicalPath, id).toBe(docsPath('ja', id));
    }
  });

  it('is indexable', () => {
    for (const id of DOC_IDS) {
      expect(docMeta(parseRoute(docsPath('ja', id)), 'ja').robots, id).toBeNull();
    }
  });

  it('carries the chapter title and a description', () => {
    for (const id of DOC_IDS) {
      const m = docMeta(parseRoute(docsPath('ja', id)), 'ja');
      expect(m.title, id).toContain(DOCS.ja[id].title);
      expect(m.title, id).toContain('TimeWeave');
      expect(m.description.trim(), id).not.toBe('');
      // Not the key, which is what an unresolved lookup would leave behind.
      expect(m.description, id).not.toContain('docs.summary');
    }
  });

  it('declares the language it is written in', () => {
    expect(docMeta(parseRoute('/ja/docs/faq'), 'ja').lang).toBe('ja');
  });
});

describe('an English chapter URL with no translation behind it', () => {
  it('canonicalises to the Japanese page it is actually showing', () => {
    // The strongest of the three signals: it tells a crawler which URL holds
    // this content, and it is already correct for the day a translation
    // lands, when it becomes a self-canonical on its own.
    for (const id of DOC_IDS) {
      if (hasTranslation(id, 'en')) continue;
      const m = docMeta(parseRoute(docsPath('en', id)), 'en');
      expect(m.canonicalPath, id).toBe(docsPath('ja', id));
    }
  });

  it('is not offered to an index as English content', () => {
    for (const id of DOC_IDS) {
      if (hasTranslation(id, 'en')) continue;
      expect(docMeta(parseRoute(docsPath('en', id)), 'en').robots, id).toBe('noindex, follow');
    }
  });

  it('emits NO hreflang at all', () => {
    // The failure this prevents: `hreflang="en"` on a page whose body is
    // Japanese puts an unreadable page into results someone searched in
    // English. A set of one is not a set of alternatives either, so the
    // Japanese side of an untranslated chapter emits none for that reason.
    for (const id of DOC_IDS) {
      if (hasTranslation(id, 'en')) continue;
      expect(docMeta(parseRoute(docsPath('en', id)), 'en').alternates, id).toEqual([]);
      expect(docMeta(parseRoute(docsPath('ja', id)), 'ja').alternates, id).toEqual([]);
    }
  });

  it('describes the body, in the body language', () => {
    // An English sentence introducing a Japanese article promises a page that
    // is not there -- and an English sentence introducing an English one is
    // simply right. So the rule is not "always Japanese" (which held only
    // while nothing was translated): the description follows whichever
    // language the BODY turned out to be in.
    for (const id of DOC_IDS) {
      for (const lang of LANGUAGES) {
        const view = resolveDocPage(id, lang);
        if (view.kind !== 'found') continue;
        const m = docMeta(parseRoute(docsPath(lang, id)), lang);
        expect(m.description, `${lang}/${id}`).toBe(
          docsText(DOC_SUMMARY[id], view.doc.lang),
        );
      }
    }
  });

  it('still says the CHROME is English', () => {
    // The body carries its own lang; this is the page shell.
    expect(docMeta(parseRoute('/en/docs/faq'), 'en').lang).toBe('en');
  });
});

describe('hreflang switches itself on when a translation lands', () => {
  it('the alternates are a function of TRANSLATION, not a hard-coded list', () => {
    // Proven by behaviour rather than by reading the source: with nothing
    // translated the set is empty, and the only input that could change it is
    // the generated state.
    const translated = DOC_IDS.filter((id) => hasTranslation(id, 'en'));
    const withAlternates = DOC_IDS.filter(
      (id) => docMeta(parseRoute(docsPath('ja', id)), 'ja').alternates.length > 0,
    );
    expect(withAlternates).toEqual(translated);
  });

  it('when it does switch on, it is a full set with x-default', () => {
    const translated = DOC_IDS.filter((id) => hasTranslation(id, 'en'));
    expect(
      translated.length,
      'P7-g Phase 1 translated three chapters; this is now the live path',
    ).toBeGreaterThan(0);
    for (const id of translated) {
      for (const lang of LANGUAGES) {
        const m = docMeta(parseRoute(docsPath(lang, id)), lang);
        expect(m.alternates.map((a) => a.hreflang).sort(), `${lang}/${id}`).toEqual(
          [...LANGUAGES, 'x-default'].sort(),
        );
        // x-default points at the source language, which is the version to
        // serve a reader whose language is neither of ours.
        const xd = m.alternates.find((a) => a.hreflang === 'x-default');
        expect(xd?.path, id).toBe(docsPath(SOURCE_LANGUAGE, id));
        // Each language's alternate points at that language's own URL.
        for (const l of LANGUAGES) {
          expect(m.alternates.find((a) => a.hreflang === l)?.path, `${id}/${l}`).toBe(
            docsPath(l, id),
          );
        }
      }
    }
  });

  it('a translated English chapter stands on its own', () => {
    for (const id of DOC_IDS) {
      if (!hasTranslation(id, 'en')) continue;
      const m = docMeta(parseRoute(docsPath('en', id)), 'en');
      // Self-canonical, not pointed back at the Japanese.
      expect(m.canonicalPath, id).toBe(docsPath('en', id));
      // Indexable.
      expect(m.robots, id).toBeNull();
      // Titled and described in English.
      expect(m.title, id).toContain(DOCS.en[id]?.title as string);
    }
  });
});

describe('the index', () => {
  it('is indexable in Japanese and not in English', () => {
    expect(docMeta(parseRoute('/ja/docs'), 'ja').robots).toBeNull();
    expect(docMeta(parseRoute('/en/docs'), 'en').robots).toBe(
      indexHasTranslation('en') ? null : 'noindex, follow',
    );
  });

  it('the English index canonicalises to the Japanese one', () => {
    if (indexHasTranslation('en')) return;
    expect(docMeta(parseRoute('/en/docs'), 'en').canonicalPath).toBe('/ja/docs');
  });

  it('has its own title and description, not a chapter one', () => {
    const m = docMeta(parseRoute('/ja/docs'), 'ja');
    expect(m.title).toContain('TimeWeave');
    for (const id of DOC_IDS) expect(m.title).not.toContain(DOCS.ja[id].title);
    expect(m.description.trim()).not.toBe('');
  });
});

describe('a URL that names no document', () => {
  it('is not indexed and canonicalises to nothing', () => {
    for (const path of ['/ja/docs/nope', '/zz/docs', '/ja/docs/a/b']) {
      const m = docMeta(parseRoute(path), 'ja');
      expect(m.robots, path).toBe('noindex, follow');
      expect(m.canonicalPath, path).toBeNull();
      expect(m.alternates, path).toEqual([]);
    }
  });

  it('still has a title, so the tab is not blank', () => {
    const m = docMeta(parseRoute('/ja/docs/nope'), 'ja');
    expect(m.title.trim()).not.toBe('');
    expect(m.title).toContain('TimeWeave');
  });
});

describe('every documentation route produces usable metadata', () => {
  it('no title or description is empty, in either language', () => {
    const routes = [
      '/ja/docs',
      '/en/docs',
      '/ja/docs/nope',
      ...DOC_IDS.flatMap((id) => [docsPath('ja', id), docsPath('en', id)]),
    ];
    for (const path of routes) {
      for (const lang of LANGUAGES) {
        const m = docMeta(parseRoute(path), lang);
        expect(m.title.trim(), `${path}/${lang}`).not.toBe('');
        expect(m.description.trim(), `${path}/${lang}`).not.toBe('');
        // A key that failed to resolve renders as the key itself.
        expect(m.title, `${path}/${lang}`).not.toMatch(/^docs\./);
        expect(m.description, `${path}/${lang}`).not.toMatch(/^docs\./);
      }
    }
  });

  it('a canonical path, when present, is one the router accepts', () => {
    for (const id of DOC_IDS) {
      for (const lang of LANGUAGES) {
        const p = docMeta(parseRoute(docsPath(lang, id)), lang).canonicalPath;
        expect(p, `${lang}/${id}`).not.toBeNull();
        const r = parseRoute(p as string);
        expect(r.kind, p as string).toBe('docsPage');
      }
    }
  });
});
