/**
 * `parseRoute` -- which screen a URL asks for.
 *
 * This function decides whether a request reaches the authenticated calendar,
 * the anonymous share page or the public documentation, and those three have
 * different disclosure rules. It was a regular expression inline in a
 * component until P7-a, so none of it could be tested; the tests that matter
 * most are the ones that say what must NOT be claimed.
 */

import { describe, expect, it } from 'vitest';
import { isDocId, isPublicRoute, parseRoute, type Route } from './route';

// ---------------------------------------------------------------------------

describe('the share route is unchanged', () => {
  it('reads the token from /s/:token', () => {
    expect(parseRoute('/s/abc123')).toEqual({ kind: 'share', token: 'abc123' });
  });

  it('tolerates a trailing slash', () => {
    expect(parseRoute('/s/abc123/')).toEqual({ kind: 'share', token: 'abc123' });
  });

  it('decodes a percent-escaped token', () => {
    expect(parseRoute('/s/a%2Bb')).toEqual({ kind: 'share', token: 'a+b' });
  });

  it('accepts whatever shape a token has', () => {
    // The token is opaque: the server decides, and an unknown one deliberately
    // answers the same as a revoked one. Validating it here could only reject
    // something the database would have accepted.
    for (const token of ['UPPER', 'with-dash', 'with_underscore', 'a.b', '0', 'x'.repeat(200)]) {
      expect(parseRoute(`/s/${token}`), token).toEqual({ kind: 'share', token });
    }
  });

  it('is not claimed by any documentation rule', () => {
    // The share links already in circulation are outside anyone's control, so
    // this is the invariant no later routing change may break.
    for (const p of ['/s/docs', '/s/ja', '/s/en', '/s/getting-started']) {
      expect(parseRoute(p).kind, p).toBe('share');
    }
  });

  it('needs exactly two segments', () => {
    expect(parseRoute('/s').kind).toBe('app');
    expect(parseRoute('/s/').kind).toBe('app');
    expect(parseRoute('/s/a/b').kind).toBe('app');
  });
});

describe('documentation URLs', () => {
  it('names a language and a page', () => {
    expect(parseRoute('/ja/docs/getting-started')).toEqual({
      kind: 'docsPage',
      lang: 'ja',
      pageId: 'getting-started',
    });
    expect(parseRoute('/en/docs/share-links')).toEqual({
      kind: 'docsPage',
      lang: 'en',
      pageId: 'share-links',
    });
  });

  it('names a language and the index', () => {
    expect(parseRoute('/ja/docs')).toEqual({ kind: 'docsIndex', lang: 'ja' });
    expect(parseRoute('/en/docs/')).toEqual({ kind: 'docsIndex', lang: 'en' });
  });

  it('omits the language, leaving it for the viewer to resolve', () => {
    // null is NOT "the default": it means nobody has said, so the viewer's own
    // resolution decides and the page then replaces the URL with the resolved
    // one so the link can be shared unambiguously.
    expect(parseRoute('/docs')).toEqual({ kind: 'docsIndex', lang: null });
    expect(parseRoute('/docs/getting-started')).toEqual({
      kind: 'docsPage',
      lang: null,
      pageId: 'getting-started',
    });
  });

  it('tolerates a trailing slash on a page', () => {
    expect(parseRoute('/ja/docs/getting-started/')).toEqual({
      kind: 'docsPage',
      lang: 'ja',
      pageId: 'getting-started',
    });
  });
});

describe('an unknown language', () => {
  it('is a documentation URL this build cannot serve, not the calendar', () => {
    // `jp` for `ja` is the typo that actually happens. Sending that reader to
    // the calendar would be baffling; the documentation's own apology, in
    // whatever language they resolve to, is the useful answer.
    expect(parseRoute('/jp/docs/getting-started')).toEqual({ kind: 'docsNotFound', lang: null });
    expect(parseRoute('/jp/docs')).toEqual({ kind: 'docsNotFound', lang: null });
    expect(parseRoute('/fr/docs/x')).toEqual({ kind: 'docsNotFound', lang: null });
  });

  it('carries no language, so the chrome falls back to the viewer', () => {
    const r = parseRoute('/de/docs');
    expect(r.kind).toBe('docsNotFound');
    expect(r.kind === 'docsNotFound' && r.lang).toBeNull();
  });

  it('only a two-letter prefix claims the namespace', () => {
    // Keeps the claim narrow: an app path that happens to end in /docs stays
    // an app path, today and after any later language is added.
    for (const p of ['/account/docs', '/settings/docs', '/a/docs', '/abc/docs', '/JA/docs']) {
      expect(parseRoute(p).kind, p).toBe('app');
    }
  });
});

describe('an unknown or malformed page id', () => {
  it('is reported as not found rather than passed along', () => {
    expect(parseRoute('/ja/docs/Getting-Started')).toEqual({ kind: 'docsNotFound', lang: 'ja' });
    expect(parseRoute('/ja/docs/a_b')).toEqual({ kind: 'docsNotFound', lang: 'ja' });
    expect(parseRoute('/ja/docs/-leading')).toEqual({ kind: 'docsNotFound', lang: 'ja' });
    expect(parseRoute('/ja/docs/trailing-')).toEqual({ kind: 'docsNotFound', lang: 'ja' });
    expect(parseRoute('/ja/docs/double--dash')).toEqual({ kind: 'docsNotFound', lang: 'ja' });
  });

  it('keeps the language, so the apology is in the language asked for', () => {
    const r = parseRoute('/en/docs/NOPE');
    expect(r).toEqual({ kind: 'docsNotFound', lang: 'en' });
  });

  it('drops the offending text entirely', () => {
    // It would otherwise be a string of unknown shape that later code indexes
    // a map with, or echoes into a link. Nothing downstream should have to
    // sanitise it, so it does not travel.
    for (const bad of ['../secret', 'a/b', 'x'.repeat(100), 'a.b', '%2e%2e']) {
      const r = parseRoute(`/ja/docs/${bad}`);
      expect(r.kind, bad).toBe('docsNotFound');
      expect(JSON.stringify(r), bad).not.toContain('secret');
      expect(Object.keys(r).sort(), bad).toEqual(['kind', 'lang']);
    }
  });

  it('a nested path under docs is not a page', () => {
    expect(parseRoute('/ja/docs/a/b').kind).toBe('docsNotFound');
    expect(parseRoute('/docs/a/b').kind).toBe('docsNotFound');
  });

  it('a traversal attempt cannot escape the namespace', () => {
    // Browsers normalise most of these before they ever reach the client, but
    // parseRoute takes a string and must not depend on that.
    for (const p of ['/ja/docs/../../etc/passwd', '/ja/docs/..', '/ja/docs/../en/docs/x']) {
      const r = parseRoute(p);
      expect(['docsNotFound', 'app'], p).toContain(r.kind);
      expect(JSON.stringify(r), p).not.toContain('passwd');
    }
  });

  it('accepts the ids a real guide would use', () => {
    for (const id of ['getting-started', 'share-links', 'faq', 'a', 'a1', 'time-zone-2']) {
      expect(isDocId(id), id).toBe(true);
      expect(parseRoute(`/ja/docs/${id}`), id).toEqual({
        kind: 'docsPage',
        lang: 'ja',
        pageId: id,
      });
    }
  });

  it('rejects the ids that have no legitimate reading', () => {
    for (const id of ['', 'A', 'a_b', 'a.b', 'a b', 'a/b', '-a', 'a-', 'a--b', '../x', 'x'.repeat(65)]) {
      expect(isDocId(id), JSON.stringify(id)).toBe(false);
    }
  });
});

describe('everything else is the app', () => {
  it.each(['/', '', '/calendar', '/settings', '/anything/at/all', '/ja', '/en', '/docsx', '/sdocs'])(
    '%s',
    (p) => {
      expect(parseRoute(p).kind).toBe('app');
    },
  );

  it('a malformed percent-escape is not guessed at', () => {
    expect(parseRoute('/%E0%A4%A').kind).toBe('app');
    expect(parseRoute('/ja/docs/%').kind).toBe('app');
  });

  it('repeated and empty segments do not change the answer', () => {
    expect(parseRoute('//s//abc123//')).toEqual({ kind: 'share', token: 'abc123' });
    expect(parseRoute('//ja//docs//')).toEqual({ kind: 'docsIndex', lang: 'ja' });
  });
});

describe('isPublicRoute marks the routes that must not read an account', () => {
  it('is true for the share page and for every documentation route', () => {
    const publicOnes: Route[] = [
      { kind: 'share', token: 't' },
      { kind: 'docsIndex', lang: 'ja' },
      { kind: 'docsPage', lang: 'en', pageId: 'faq' },
      { kind: 'docsNotFound', lang: null },
    ];
    for (const r of publicOnes) expect(isPublicRoute(r), r.kind).toBe(true);
  });

  it('is false for the app', () => {
    expect(isPublicRoute({ kind: 'app' })).toBe(false);
  });

  it('agrees with what parseRoute returns for real URLs', () => {
    for (const p of ['/s/t', '/ja/docs', '/en/docs/faq', '/jp/docs', '/docs']) {
      expect(isPublicRoute(parseRoute(p)), p).toBe(true);
    }
    for (const p of ['/', '/calendar', '/account/docs']) {
      expect(isPublicRoute(parseRoute(p)), p).toBe(false);
    }
  });
});

describe('the function stays pure', () => {
  it('reads no global location', () => {
    const MODULES = import.meta.glob('./route.ts', {
      query: '?raw',
      import: 'default',
      eager: true,
    }) as Record<string, string>;
    const mod = (MODULES['./route.ts'] ?? '')
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/(^|[^:])\/\/.*$/gm, '$1');
    expect(mod).toBeTypeOf('string');
    expect(mod).not.toMatch(/window|location|document|navigator/);
    // And it decides nothing about language beyond recognising the prefix.
    expect(mod).not.toMatch(/resolveLanguage|browserLanguages|owner_settings/);
  });

  it('the same path always gives the same answer', () => {
    for (const p of ['/s/t', '/ja/docs/faq', '/jp/docs', '/']) {
      expect(parseRoute(p)).toEqual(parseRoute(p));
    }
  });
});
