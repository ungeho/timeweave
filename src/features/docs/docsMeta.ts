/**
 * What a documentation URL tells a browser and a crawler about itself.
 *
 * ALL OF IT IS DECIDED HERE, as pure functions over a route. The component
 * that applies these to the DOM holds no judgement of its own, which is what
 * lets every rule below be tested in this project's node environment.
 *
 * THE RULE THAT SHAPES EVERYTHING ELSE: nine chapters exist in Japanese and
 * none in English. `/en/docs/share-links` therefore renders the JAPANESE body
 * under English chrome, and must not claim otherwise -- not in a hreflang,
 * not in a canonical, and not by being indexable as an English page. Saying
 * "this is the English version" of a page that is Japanese is worse than
 * having no English version at all: it puts a page a reader cannot read into
 * results they searched in English.
 *
 * So the alternates come from `TRANSLATION`, which the generator writes, and
 * they switch themselves on when a translation actually lands. Nothing here
 * has to be remembered at that point.
 */

import { DOCS, TRANSLATION, type DocId } from '../../generated/docs';
import { LANGUAGES, type Language } from '../../i18n/types';
import type { Route } from '../../routing/route';
import {
  DOC_SUMMARY,
  SOURCE_LANGUAGE,
  docsPath,
  docsText,
  isDocIdKnown,
  resolveDocPage,
} from './docsView';

/** Appended to every documentation title. */
const SITE_NAME = 'TimeWeave';

/**
 * Hosts whose origin must never be published as a canonical URL.
 *
 * A canonical is an instruction to a crawler about where a page really lives.
 * `http://localhost:5204/ja/docs` is true of nobody's site, and a page saved
 * or proxied from a dev server would carry that instruction with it. When the
 * origin is one of these, the page says nothing rather than something false.
 */
function isLocalHost(hostname: string): boolean {
  return (
    hostname === 'localhost' ||
    hostname === '127.0.0.1' ||
    hostname === '[::1]' ||
    hostname === '::1' ||
    hostname.endsWith('.localhost') ||
    hostname.endsWith('.local') ||
    hostname.endsWith('.test')
  );
}

/**
 * The origin to build absolute URLs from, or null to emit none.
 *
 * `configured` is VITE_PUBLIC_ORIGIN. Setting it is what PINS the canonical to
 * one origin -- which matters on a host that serves the same build from
 * several hostnames, where self-canonicalising would tell a crawler each
 * preview deployment is its own site.
 *
 * Unset, the page canonicalises to wherever it is actually being served. That
 * is right for a single-origin deployment and is the only thing that can be
 * done without knowing the public URL, which this repository does not record.
 * Guessing one would be worse than omitting it.
 */
export function canonicalOrigin(
  configured: string | undefined,
  runtimeOrigin: string,
): string | null {
  const pick = (value: string): string | null => {
    let u: URL;
    try {
      u = new URL(value);
    } catch {
      return null;
    }
    if (u.protocol !== 'https:' && u.protocol !== 'http:') return null;
    if (isLocalHost(u.hostname)) return null;
    return u.origin;
  };

  const fromConfig = configured?.trim();
  if (fromConfig) {
    // A configured origin is a deliberate statement; if it is unusable that is
    // a misconfiguration to notice, not something to paper over with the
    // runtime one.
    return pick(fromConfig);
  }
  return pick(runtimeOrigin);
}

export interface Alternate {
  /** The hreflang value, e.g. "ja". */
  readonly hreflang: string;
  /** Root-relative; made absolute by the caller when an origin is known. */
  readonly path: string;
}

export interface DocMeta {
  /** For document.title. */
  readonly title: string;
  /** For <meta name="description">. */
  readonly description: string;
  /** For <html lang>. The CHROME's language. */
  readonly lang: Language;
  /** Root-relative canonical path, or null when there should be none. */
  readonly canonicalPath: string | null;
  /** Only languages whose translation really exists. Empty is the norm today. */
  readonly alternates: readonly Alternate[];
  /** A robots value, or null to say nothing. */
  readonly robots: string | null;
}

/** Whether a chapter has a usable translation in `lang`. */
export function hasTranslation(id: DocId, lang: Language): boolean {
  if (lang === SOURCE_LANGUAGE) return true;
  return TRANSLATION[id] === 'translated' && DOCS[lang][id] !== undefined;
}

/**
 * Whether the INDEX may be offered as an alternate in `lang`.
 *
 * Every chapter, not just one. The index is a list of chapters, so an index
 * offered as English while most of what it links to is Japanese sends a
 * reader into exactly the pages this module refuses to advertise.
 */
export function indexHasTranslation(lang: Language): boolean {
  if (lang === SOURCE_LANGUAGE) return true;
  return (Object.keys(TRANSLATION) as DocId[]).every((id) => hasTranslation(id, lang));
}

/**
 * Alternates for a page, including the self-reference.
 *
 * Omitted ENTIRELY when only the source language exists: a set of one is not
 * a set of alternatives, and `x-default` pointing at the only version there is
 * says nothing a crawler did not already know.
 */
function alternatesFor(has: (lang: Language) => boolean, path: (lang: Language) => string): readonly Alternate[] {
  const available = LANGUAGES.filter(has);
  if (available.length < 2) return [];
  return [
    ...available.map((l) => ({ hreflang: l, path: path(l) })),
    // The version to serve a reader whose language is none of ours.
    { hreflang: 'x-default', path: path(SOURCE_LANGUAGE) },
  ];
}

/**
 * The metadata for one route.
 *
 * `lang` is the chrome's language, already resolved by `viewLanguage` -- the
 * URL's when it names one, the viewer's otherwise.
 */
export function docMeta(route: Route, lang: Language): DocMeta {
  if (route.kind === 'docsIndex') {
    return {
      title: `${docsText('docs.indexTitle', lang)} — ${SITE_NAME}`,
      description: docsText('docs.indexLead', lang),
      lang,
      canonicalPath: indexHasTranslation(lang) ? docsPath(lang) : docsPath(SOURCE_LANGUAGE),
      alternates: alternatesFor(indexHasTranslation, (l) => docsPath(l)),
      // An index that lists Japanese chapters under English chrome is not an
      // English page. It stays reachable and its links stay followed; it just
      // does not go in an index as something it is not.
      robots: indexHasTranslation(lang) ? null : 'noindex, follow',
    };
  }

  if (route.kind === 'docsPage' && isDocIdKnown(route.pageId)) {
    const id = route.pageId;
    const view = resolveDocPage(id, lang);
    const translated = hasTranslation(id, lang);
    // The TITLE follows the chrome where it can, but there is no English title
    // for an untranslated chapter -- the generator never produced one -- so it
    // is the source title, which is also what the body will be in.
    const doc = view.kind === 'found' ? view.doc : DOCS[SOURCE_LANGUAGE][id];
    return {
      title: `${doc.title} — ${docsText('docs.indexTitle', lang)} — ${SITE_NAME}`,
      // The description describes the BODY, so it is in the body's language.
      // An English sentence introducing a Japanese article would promise a
      // page that is not there.
      description: docsText(DOC_SUMMARY[id], doc.lang),
      lang,
      canonicalPath: translated ? docsPath(lang, id) : docsPath(SOURCE_LANGUAGE, id),
      alternates: alternatesFor(
        (l) => hasTranslation(id, l),
        (l) => docsPath(l, id),
      ),
      robots: translated ? null : 'noindex, follow',
    };
  }

  // Not found, or a language this build does not serve. Nothing to index, and
  // nothing to canonicalise to -- the URL names no document.
  return {
    title: `${docsText('docs.notFound', lang)} — ${SITE_NAME}`,
    description: docsText('docs.notFoundHint', lang),
    lang,
    canonicalPath: null,
    alternates: [],
    robots: 'noindex, follow',
  };
}

/** Make a root-relative path absolute, when an origin is known. */
export function absolute(origin: string | null, path: string): string | null {
  return origin === null ? null : origin + path;
}
