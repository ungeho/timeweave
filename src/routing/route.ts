/**
 * Which screen a URL asks for, as a pure function.
 *
 * WHY THIS IS A MODULE. The decision used to be a regular expression inline in
 * `App.tsx`, untested -- vitest runs with `environment: 'node'` and jsdom is
 * not added, so anything living inside a component cannot be exercised at all.
 * The same reasoning that put every i18n decision in a pure module applies
 * here, and more sharply: this function decides whether a request reaches the
 * authenticated app, the anonymous share page, or the public documentation,
 * and those three have different disclosure rules.
 *
 * IT TAKES A PATHNAME, not `window.location`. That is what makes it testable,
 * and it also means the caller owns the question of WHEN to re-read the
 * location -- see `useRoute`, which subscribes to popstate so the back and
 * forward buttons work.
 *
 * WHAT IT DELIBERATELY DOES NOT DO: resolve a language, look anything up, or
 * decide what exists. A route is what the URL asked for; whether that document
 * exists is P7-b's question, and which language to render chrome in is the
 * provider's.
 */

import { isLanguage, type Language } from '../i18n/types';

/**
 * A documentation id, as it appears in the URL.
 *
 * Narrowed to a slug at parse time rather than trusted: this string will later
 * index a generated map and may be echoed into a link, and an id that arrived
 * with a slash, a dot or a percent-escape in it has no legitimate reading. A
 * malformed one becomes `docsNotFound` and the raw text is dropped entirely
 * rather than carried along for somebody downstream to sanitise.
 *
 * Lowercase letters, digits and single hyphens; must begin and end
 * alphanumeric; 1-64 characters. `getting-started` passes; `../secrets`,
 * `a..b` and `A_B` do not.
 */
const DOC_ID = /^[a-z0-9](?:[a-z0-9]|-(?=[a-z0-9])){0,63}$/;

export function isDocId(value: string): boolean {
  return DOC_ID.test(value);
}

/**
 * What the URL asked for.
 *
 * `lang` is null when the URL named no language (`/docs/...`). That is not the
 * same as "the default": it means the viewer's own resolution should decide,
 * and the page should then replace the URL with the resolved one so the link
 * can be shared unambiguously. A URL that DOES name a language wins over any
 * stored preference -- a shared documentation link must show the reader what
 * the sender saw -- and it is never written back to `owner_settings`.
 */
export type Route =
  /** `/s/:token` -- anonymous, read-only Free/Busy. */
  | { readonly kind: 'share'; readonly token: string }
  /** `/ja/docs`, `/docs` -- the documentation index. */
  | { readonly kind: 'docsIndex'; readonly lang: Language | null }
  /** `/ja/docs/getting-started` -- one page, id already validated. */
  | { readonly kind: 'docsPage'; readonly lang: Language | null; readonly pageId: string }
  /** A documentation URL this build cannot serve: unknown language, or a malformed id. */
  | { readonly kind: 'docsNotFound'; readonly lang: Language | null }
  /** Everything else: the calendar, behind AuthGate. */
  | { readonly kind: 'app' };

/** Split a pathname into decoded, non-empty segments. */
function segments(pathname: string): string[] | null {
  const raw = pathname.split('/').filter((s) => s.length > 0);
  try {
    return raw.map((s) => decodeURIComponent(s));
  } catch {
    // A malformed percent-escape. Not a route this app defines, and not
    // something to guess at.
    return null;
  }
}

/**
 * Whether a segment is shaped like a language tag.
 *
 * Only a two-letter lowercase code claims the documentation namespace. That
 * keeps the claim narrow -- `/account/docs` stays an app URL, and always will
 * -- while still catching the typo that actually happens: `/jp/docs/...` for
 * `/ja/docs/...`. A reader who mistypes the language gets the documentation's
 * own "not found", with a way back, rather than the calendar.
 */
const LANG_SHAPED = /^[a-z]{2}$/;

/**
 * Parse a pathname.
 *
 * ORDER MATTERS: the share route is matched first and on its own shape, so no
 * change to the documentation rules below can ever capture a `/s/:token` URL.
 * Those links are already in circulation and outside anyone's control.
 */
export function parseRoute(pathname: string): Route {
  const segs = segments(pathname);
  if (segs === null) return { kind: 'app' };

  // ---- /s/:token ---------------------------------------------------------
  // Exactly two segments. A token is opaque and may contain anything that
  // survives a URL, so it is NOT validated here -- the server decides, and an
  // unknown token deliberately answers the same as a revoked one.
  if (segs.length === 2 && segs[0] === 's') {
    const token = segs[1]!;
    return token.length > 0 ? { kind: 'share', token } : { kind: 'app' };
  }

  // ---- /<lang>/docs[/<id>] ----------------------------------------------
  if (segs.length >= 2 && segs[1] === 'docs' && LANG_SHAPED.test(segs[0]!)) {
    const prefix = segs[0]!;
    // An unknown two-letter code is a documentation URL this build cannot
    // serve. `lang: null` lets the chrome fall back to the viewer's own
    // language, which is the only sensible one to apologise in.
    if (!isLanguage(prefix)) return { kind: 'docsNotFound', lang: null };
    return docsTarget(prefix, segs.slice(2));
  }

  // ---- /docs[/<id>] ------------------------------------------------------
  if (segs.length >= 1 && segs[0] === 'docs') {
    return docsTarget(null, segs.slice(1));
  }

  return { kind: 'app' };
}

/** The part after `docs`: nothing (the index), one valid id, or anything else. */
function docsTarget(lang: Language | null, rest: string[]): Route {
  if (rest.length === 0) return { kind: 'docsIndex', lang };
  if (rest.length === 1 && isDocId(rest[0]!)) {
    return { kind: 'docsPage', lang, pageId: rest[0]! };
  }
  return { kind: 'docsNotFound', lang };
}

/**
 * Whether a route is public: served without a session, and without reading
 * anything that belongs to an account.
 *
 * THIS IS WHAT DECIDES NOT TO FETCH `owner_settings`. Both public routes must
 * resolve the viewer's language from their own browser: the anonymous share
 * page because the owner's preference is the wrong answer for a stranger, and
 * the documentation because there is no owner in the picture at all. Asking
 * anyway would also spend a request to earn a 42501 -- `anon` holds no
 * privilege on that table (0025/0026).
 */
export function isPublicRoute(route: Route): boolean {
  return route.kind !== 'app';
}
