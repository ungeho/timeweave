/**
 * Every decision the documentation screens make, as pure functions.
 *
 * WHY A MODULE AND NOT COMPONENT BODIES. vitest runs with
 * `environment: 'node'` and jsdom is deliberately not added, so a decision
 * taken inside a component cannot be exercised at all. The same arrangement
 * `languageState.ts` and `route.ts` already use: the judgement lives here and
 * the component holds markup.
 *
 * WHAT IS DECIDED HERE:
 *   which language the chrome speaks, and which language the body is in --
 *   they are NOT always the same, and the gap is the thing a reader must be
 *   told about;
 *   which document a URL names, and what to do when it names none that exist;
 *   where "previous" and "next" go;
 *   what URL to put in a link.
 */

import { DOCS, DOC_IDS, TRANSLATION, type Doc, type DocId } from '../../generated/docs';
import { t } from '../../i18n/t';
import type { MessageKey } from '../../i18n/ja';
import type { Language } from '../../i18n/types';
import type { Route } from '../../routing/route';

/**
 * The language the guide is written in, and the one every page falls back to.
 *
 * A LITERAL, not DEFAULT_LANGUAGE. It matches scripts/build-docs.mjs
 * SOURCE_LANG, which is what decides that DOCS.ja is total and DOCS.en
 * partial -- and the literal is what lets the compiler know the fallback
 * lookup below cannot come back undefined.
 */
export const SOURCE_LANGUAGE = 'ja' satisfies Language;

export function isDocIdKnown(value: string): value is DocId {
  return (DOC_IDS as readonly string[]).includes(value);
}

/** `/ja/docs` or `/ja/docs/<id>`. Always language-qualified, never bare. */
export function docsPath(lang: Language, id?: DocId): string {
  return id === undefined ? `/${lang}/docs` : `/${lang}/docs/${id}`;
}

/**
 * Which language to render in.
 *
 * THE URL WINS. A documentation link is shared, and the person who receives it
 * must see what the sender saw -- not whatever their own browser or a stored
 * preference would have chosen. A URL that names no language is a different
 * case: there the viewer's own resolution is the only signal there is.
 */
export function viewLanguage(route: Route, viewer: Language): Language {
  return 'lang' in route && route.lang !== null ? route.lang : viewer;
}

/**
 * Whether the URL left the language open.
 *
 * Such a URL is replaced with the resolved one, so that what the reader then
 * copies out of the address bar means the same thing to whoever they send it
 * to. A replace, never a push: it is not a place the reader asked to go.
 */
export function needsLanguageInUrl(route: Route): boolean {
  return 'lang' in route && route.lang === null;
}

/**
 * What a page screen should render.
 *
 * `missing` is its own case rather than an exception: an id can reach here
 * from a hand-typed URL, from an old link, or from a page that was renamed,
 * and all three want the same apology with a way back -- not a blank screen
 * and not the calendar.
 */
export type DocPageView =
  | {
      readonly kind: 'found';
      /** The language the chrome speaks: what the URL asked for. */
      readonly lang: Language;
      /** The document actually rendered, which may be in another language. */
      readonly doc: Doc;
      /**
       * Set when the body is NOT in `lang`.
       *
       * The reader is told, every time. A page that silently served Japanese
       * to someone who asked for English would read as a bug in the page
       * rather than as work not yet done, and a screen reader would announce
       * the whole article in the wrong voice -- which is why the element
       * carries this as its own `lang` attribute too.
       */
      readonly fallbackFrom: Language | null;
    }
  | { readonly kind: 'missing'; readonly lang: Language };

/**
 * Resolve one page.
 *
 * FALLS BACK TO THE SOURCE LANGUAGE, never to an empty page. A translation
 * that does not exist, and one that exists but is stale, are both unusable
 * for different reasons; `TRANSLATION` keeps them distinct for the translator,
 * and both land here as "show the source and say so".
 */
export function resolveDocPage(id: string, lang: Language): DocPageView {
  if (!isDocIdKnown(id)) return { kind: 'missing', lang };

  const wanted = DOCS[lang][id];
  if (wanted && TRANSLATION[id] === 'translated') {
    return { kind: 'found', lang, doc: wanted, fallbackFrom: null };
  }

  const source = DOCS[SOURCE_LANGUAGE][id];
  return {
    kind: 'found',
    lang,
    doc: source,
    fallbackFrom: lang === SOURCE_LANGUAGE ? null : SOURCE_LANGUAGE,
  };
}

/**
 * The reading order.
 *
 * NOT the generated order, which is alphabetical because it comes from a
 * directory listing. A guide is read front to back, and "previous" has to mean
 * the chapter before this one rather than the one whose id sorts earlier.
 * Keeping it here, as a list of ids, means a chapter cannot silently fall out
 * of the order: the test below asserts this covers DOC_IDS exactly.
 */
export const READING_ORDER: readonly DocId[] = [
  'getting-started',
  'managing-events',
  'recurring-events',
  'privacy-and-availability',
  'share-links',
  'what-viewers-see',
  'time-zones',
  'language',
  'faq',
];

/** How the index groups the chapters. Labels are dictionary keys. */
export const DOC_GROUPS: readonly {
  readonly key: 'docs.group.events' | 'docs.group.sharing' | 'docs.group.settings' | 'docs.group.help';
  readonly ids: readonly DocId[];
}[] = [
  { key: 'docs.group.events', ids: ['getting-started', 'managing-events', 'recurring-events'] },
  {
    key: 'docs.group.sharing',
    ids: ['privacy-and-availability', 'share-links', 'what-viewers-see'],
  },
  { key: 'docs.group.settings', ids: ['time-zones', 'language'] },
  { key: 'docs.group.help', ids: ['faq'] },
];

/**
 * The summary each chapter shows in the index.
 *
 * WRITTEN OUT, not built as `docs.summary.${id}`. Two reasons, and the
 * second is the one that matters: a template literal means a missing
 * summary is discovered at runtime, as the key text printed on screen,
 * whereas this map makes it a compile error. It also keeps every key a
 * quoted literal, which is how the dictionary audit finds out that a key
 * is used -- a key it cannot see reads as dead and gets proposed for
 * deletion.
 */
export const DOC_SUMMARY: Readonly<Record<DocId, DocsKey>> = {
  'getting-started': 'docs.summary.getting-started',
  'managing-events': 'docs.summary.managing-events',
  'recurring-events': 'docs.summary.recurring-events',
  'privacy-and-availability': 'docs.summary.privacy-and-availability',
  'share-links': 'docs.summary.share-links',
  'what-viewers-see': 'docs.summary.what-viewers-see',
  'time-zones': 'docs.summary.time-zones',
  language: 'docs.summary.language',
  faq: 'docs.summary.faq',
};

/**
 * Where to find what each language calls itself.
 *
 * The strings are in the dictionary -- identical in both copies, which is
 * explained there -- because a string on screen belongs in the dictionary even
 * when it is the same in every language. This map is only the lookup.
 */
export const LANGUAGE_NAME: Readonly<Record<Language, DocsKey>> = {
  ja: 'docs.lang.ja',
  en: 'docs.lang.en',
};

/**
 * What to call a chapter in a list, in a given language.
 *
 * THE SAME FALLBACK THE BODY USES. `resolveDocPage` serves the source
 * language when a translation is missing or stale; a sidebar that showed an
 * English title for a chapter whose body is Japanese would be promising
 * something the page does not deliver, and the reader would find out only
 * after clicking.
 *
 * So this is derived from the same two facts -- that a translation exists,
 * and that it is current -- rather than from a second list that could
 * disagree with the first.
 */
export function docTitle(id: DocId, lang: Language): string {
  const translated = DOCS[lang][id];
  if (translated && TRANSLATION[id] === 'translated') return translated.title;
  return DOCS[SOURCE_LANGUAGE][id].title;
}

export interface Neighbours {
  readonly prev: DocId | null;
  readonly next: DocId | null;
}

export function neighbours(id: DocId): Neighbours {
  const i = READING_ORDER.indexOf(id);
  return {
    prev: i > 0 ? READING_ORDER[i - 1]! : null,
    next: i >= 0 && i < READING_ORDER.length - 1 ? READING_ORDER[i + 1]! : null,
  };
}

/**
 * The headings worth listing on the page.
 *
 * Level 2 only. The h1 is the page title, already on screen above, and level 3
 * would double the length of a list whose job is to fit in one glance -- the
 * FAQ alone has 34 of them.
 */
export function tocHeadings(doc: Doc): readonly { id: string; text: string }[] {
  return doc.headings.filter((h) => h.level === 2).map((h) => ({ id: h.id, text: h.text }));
}

/**
 * Where a language switch should land.
 *
 * The chapter is kept. Switching language is a statement about how to read
 * this page, not a request to go somewhere else, and dropping the reader on
 * the index every time would make the control unusable mid-article.
 */
export function switchLanguagePath(route: Route, to: Language): string {
  if (route.kind === 'docsPage' && isDocIdKnown(route.pageId)) {
    return docsPath(to, route.pageId);
  }
  return docsPath(to);
}

/**
 * Render one of the guide's own chrome strings.
 *
 * WHY THIS WRAPPER EXISTS. `t` reads the placeholder names off the key's
 * LITERAL type to decide what variables the call must supply, so a key held in
 * a variable widens to the whole MessageKey union and the compiler then
 * demands the widest variable set any message in the dictionary declares --
 * the same wall `recurrenceForm.ts` hit, where the fix was a switch over three
 * literals. A switch is not available here: the group labels and the per
 * chapter summaries are looked up BY id, and writing seventeen cases to
 * re-state a mapping that `DOC_GROUPS` and `READING_ORDER` already hold would
 * be a second source of truth for the sake of the type checker.
 *
 * So the cast is confined to this function, and it is sound because of the
 * type on the parameter: `DocsKey` admits only `docs.*`, and no message under
 * that prefix takes a variable. `t` looks the key up at runtime, so the
 * literal named in the cast is never actually used -- it only tells the
 * compiler "no variables needed", which is true of every key this accepts.
 */
export type DocsKey = Extract<MessageKey, `docs.${string}`>;

export function docsText(key: DocsKey, lang: Language): string {
  return t(key as 'docs.title', lang);
}
