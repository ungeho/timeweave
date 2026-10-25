/**
 * The documentation screens: the index, one chapter, and the apology.
 *
 * THE HTML IS INSERTED, NOT PARSED. `DOCS[...].html` was rendered at build
 * time by scripts/build-docs.mjs with `html: false` -- raw HTML in a source
 * file is inert -- a `validateLink` allow list for URL schemes, and a
 * self-check that fails the build on an event-handler attribute or a
 * dangerous URL. That is the contract this screen relies on, and it is the
 * reason no Markdown parser reaches the browser at all. The single
 * `dangerouslySetInnerHTML` below is the only one in the app, and its input
 * is always a field of that generated module -- never a prop, a fetch, or
 * anything a reader can influence. A test asserts both halves.
 */

import { useEffect } from 'react';
import { LANGUAGES, type Language } from '../../i18n/types';
import { useLanguage } from '../../i18n/useLanguage';
import type { Route } from '../../routing/route';
import { isPlainLeftClick, navigate } from '../../routing/navigate';

/**
 * An in-app guide link, as written in the Markdown.
 *
 * Deliberately narrow: a language-qualified documentation path and nothing
 * else. An external link, a mailto, an image link and a `#fragment` all fall
 * through to the browser, which is what each of them wants. Anchored at both
 * ends so a lookalike host cannot match -- `parseRoute` validates the id
 * again on arrival regardless.
 */
const INTERNAL_DOC_LINK = /^\/(?:ja|en)\/docs(?:\/[a-z0-9-]+)?$/;
import { DocLink, DocsChrome } from './DocsChrome';
import { canonicalOrigin, docMeta } from './docsMeta';
import { useDocMeta } from './useDocMeta';
import {
  DOC_GROUPS,
  DOC_SUMMARY,
  docTitle,
  LANGUAGE_NAME,
  docsText,
  type DocsKey,
  docsPath,
  needsLanguageInUrl,
  neighbours,
  resolveDocPage,
  switchLanguagePath,
  tocHeadings,
  viewLanguage,
} from './docsView';
import type { DocId } from '../../generated/docs';

/** The chapter list, shared by the index and every page's sidebar. */
function ChapterNav({
  lang,
  current,
}: {
  lang: Language;
  current?: DocId;
}) {
  const tr = (k: DocsKey) => docsText(k, lang);
  return (
    <nav className="docs-nav" aria-label={tr('docs.chapters')}>
      <DocLink to={docsPath(lang)} className="docs-nav-home">
        {tr('docs.backToIndex')}
      </DocLink>
      {DOC_GROUPS.map((g) => (
        <div className="docs-nav-group" key={g.key}>
          <h2 className="docs-nav-heading">{tr(g.key)}</h2>
          <ul>
            {g.ids.map((id) => (
              <li key={id}>
                <DocLink
                  to={docsPath(lang, id)}
                  className={id === current ? 'docs-nav-link current' : 'docs-nav-link'}
                  // Marks the chapter being read for a screen reader. The
                  // visual mark is a left bar plus a weight change, never
                  // colour alone.
                  ariaCurrent={id === current ? 'page' : undefined}
                >
                  {docTitle(id, lang)}
                </DocLink>
              </li>
            ))}
          </ul>
        </div>
      ))}
    </nav>
  );
}

function LanguageSwitch({ route, lang }: { route: Route; lang: Language }) {
  const tr = (k: DocsKey) => docsText(k, lang);
  return (
    <div className="docs-langswitch">
      <span className="docs-langswitch-label">{tr('docs.langSwitch')}</span>
      {LANGUAGES.map((l) => (
        <DocLink
          key={l}
          to={switchLanguagePath(route, l)}
          className={l === lang ? 'docs-lang current' : 'docs-lang'}
          ariaCurrent={l === lang ? true : undefined}
        >
          {tr(LANGUAGE_NAME[l])}
        </DocLink>
      ))}
    </div>
  );
}

function DocsIndex({ route, lang }: { route: Route; lang: Language }) {
  const tr = (k: DocsKey) => docsText(k, lang);
  return (
    <DocsChrome lang={lang} focusKey={`index:${lang}`}>
      <article className="docs-article docs-index">
        <h1>{tr('docs.indexTitle')}</h1>
        <p className="docs-lead">{tr('docs.indexLead')}</p>
        <LanguageSwitch route={route} lang={lang} />
        {DOC_GROUPS.map((g) => (
          <section className="docs-index-group" key={g.key}>
            <h2>{tr(g.key)}</h2>
            <ul className="docs-index-list">
              {g.ids.map((id) => (
                <li key={id}>
                  <DocLink to={docsPath(lang, id)} className="docs-index-link">
                    <span className="docs-index-title">{docTitle(id, lang)}</span>
                    <span className="docs-index-summary">
                      {tr(DOC_SUMMARY[id])}
                    </span>
                  </DocLink>
                </li>
              ))}
            </ul>
          </section>
        ))}
      </article>
    </DocsChrome>
  );
}

function DocsNotFound({ lang }: { lang: Language }) {
  const tr = (k: DocsKey) => docsText(k, lang);
  return (
    <DocsChrome lang={lang} nav={<ChapterNav lang={lang} />} focusKey={`missing:${lang}`}>
      <article className="docs-article">
        <h1>{tr('docs.notFound')}</h1>
        <p>{tr('docs.notFoundHint')}</p>
        <p>
          <DocLink to={docsPath(lang)} className="btn">
            {tr('docs.backToIndex')}
          </DocLink>
        </p>
      </article>
    </DocsChrome>
  );
}

function DocsChapter({ route, lang, id }: { route: Route; lang: Language; id: string }) {
  const view = resolveDocPage(id, lang);
  const tr = (k: DocsKey) => docsText(k, lang);

  if (view.kind === 'missing') return <DocsNotFound lang={lang} />;

  const { doc, fallbackFrom } = view;
  const toc = tocHeadings(doc);
  const { prev, next } = neighbours(doc.id);

  return (
    <DocsChrome lang={lang} nav={<ChapterNav lang={lang} current={doc.id} />} focusKey={`${lang}:${doc.id}`}>
      <article className="docs-article">
        <LanguageSwitch route={route} lang={lang} />
        {fallbackFrom !== null && (
          <p className="banner info docs-fallback" role="status">
            {tr('docs.fallbackNotice')}
          </p>
        )}

        {toc.length > 1 && (
          <nav className="docs-toc" aria-label={tr('docs.onThisPage')}>
            {/* NOT a heading. It sits above the body, so an h2 here would be
                the first heading on the page and the article own h1 the
                second -- an outline that opens at level 2. The <nav> around
                it already carries the same text as its accessible name, so
                nothing is lost by making the visible copy a plain element. */}
            <div className="docs-toc-heading">{tr('docs.onThisPage')}</div>
            <ul>
              {toc.map((h) => (
                <li key={h.id}>
                  {/* A fragment on the current page: the browser's own anchor
                      handling is exactly right here, so no click handler. */}
                  <a href={`#${h.id}`}>{h.text}</a>
                </li>
              ))}
            </ul>
          </nav>
        )}

        {/*
          The body. `lang` is the document's own, which is NOT the chrome's
          when a translation is missing -- so a screen reader switches voice
          for the article and back for the navigation around it.

          See this file's header for why inserting this string is safe.
        */}
        <div
          className="docs-body"
          lang={doc.lang}
          // The chapter links inside the prose are plain anchors in the
          // generated HTML -- React never saw them, so they cannot carry a
          // handler of their own. Without this they still WORK, as a full page
          // load; delegation here makes them behave like every other link on
          // the screen instead.
          //
          // This reads the event, not the HTML: no parsing, no rewriting, and
          // an anchor that is not an in-app guide link is left entirely alone.
          onClick={(e) => {
            if (!isPlainLeftClick(e)) return;
            const a = (e.target as HTMLElement).closest('a');
            if (!a) return;
            const href = a.getAttribute('href') ?? '';
            if (!INTERNAL_DOC_LINK.test(href)) return;
            e.preventDefault();
            navigate(href);
            window.scrollTo(0, 0);
          }}
          dangerouslySetInnerHTML={{ __html: doc.html }}
        />

        <nav className="docs-pager" aria-label={tr('docs.chapters')}>
          {prev ? (
            <DocLink to={docsPath(lang, prev)} className="docs-pager-link prev">
              <span className="docs-pager-label">{tr('docs.prev')}</span>
              <span className="docs-pager-title">{docTitle(prev, lang)}</span>
            </DocLink>
          ) : (
            <span />
          )}
          {next && (
            <DocLink to={docsPath(lang, next)} className="docs-pager-link next">
              <span className="docs-pager-label">{tr('docs.next')}</span>
              <span className="docs-pager-title">{docTitle(next, lang)}</span>
            </DocLink>
          )}
        </nav>
      </article>
    </DocsChrome>
  );
}

/**
 * The entry point App renders for every documentation route.
 *
 * The viewer's own language comes from the provider, which on a public route
 * resolves it from the browser and asks the server for nothing. The URL wins
 * over it when it names one.
 */
export function DocsScreen({ route }: { route: Route }) {
  const { language: viewer } = useLanguage();
  const lang = viewLanguage(route, viewer);

  // Title, description, canonical and hreflang. Every rule is in docsMeta.ts;
  // this reads the two things only the running page knows -- the configured
  // public origin and the one it is actually being served from.
  useDocMeta(
    docMeta(route, lang),
    canonicalOrigin(import.meta.env.VITE_PUBLIC_ORIGIN, window.location.origin),
  );

  // A URL that named no language is replaced with the resolved one, so what
  // the reader copies out of the address bar means the same to whoever they
  // send it to. Replace, not push: this is not a place they asked to go, and
  // pushing would put a step in the history for the back button to undo.
  useEffect(() => {
    if (!needsLanguageInUrl(route)) return;
    const to =
      route.kind === 'docsPage' ? `/${lang}/docs/${route.pageId}` : docsPath(lang);
    navigate(to, { replace: true });
  }, [route, lang]);

  if (route.kind === 'docsIndex') return <DocsIndex route={route} lang={lang} />;
  if (route.kind === 'docsPage') {
    return <DocsChapter route={route} lang={lang} id={route.pageId} />;
  }
  return <DocsNotFound lang={lang} />;
}
