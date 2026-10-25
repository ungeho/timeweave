/**
 * The frame every documentation screen sits in, and the link that moves
 * between them.
 *
 * WHY THE LINK IS A COMPONENT. A documentation link has to be a real `<a>`
 * with a real `href` -- so it can be middle-clicked, copied, opened in a new
 * tab and read out as a link -- while a plain left click navigates without a
 * reload. Those two are only compatible if the same element does both, which
 * is what this is. `isPlainLeftClick` decides which clicks are the app's to
 * take; everything else is handed back to the browser untouched.
 *
 * NOTHING HERE READS AN ACCOUNT. The documentation is public: no session, no
 * owner_settings, no events. The language it speaks comes from the URL, or
 * from the viewer's own browser when the URL leaves it open.
 */

import { useEffect, useRef, type ReactNode } from 'react';
import type { Language } from '../../i18n/types';
import { isPlainLeftClick, navigate } from '../../routing/navigate';
import { docsText } from './docsView';

export function DocLink({
  to,
  children,
  className,
  ariaCurrent,
}: {
  to: string;
  children: ReactNode;
  className?: string;
  ariaCurrent?: 'page' | true;
}) {
  return (
    <a
      href={to}
      className={className}
      aria-current={ariaCurrent}
      onClick={(e) => {
        if (!isPlainLeftClick(e)) return;
        e.preventDefault();
        navigate(to);
        // A new document starts at its own beginning. Without this the reader
        // lands halfway down the next chapter, at whatever offset the last one
        // was left at.
        window.scrollTo(0, 0);
      }}
    >
      {children}
    </a>
  );
}

/**
 * Header, main landmark and footer.
 *
 * `lang` is set on the whole frame so a screen reader reads the chrome in the
 * language it is written in. The article inside sets its own when the body
 * falls back to another one -- the two really can differ, and saying so is
 * the point of the notice beside it.
 */
export function DocsChrome({
  lang,
  children,
  nav,
  /**
   * Changes when the reader moves to another page.
   *
   * WHY FOCUS HAS TO MOVE. A push navigation replaces the content but leaves
   * focus on the link that was clicked -- which is then inside a sidebar that
   * now describes a different page. A screen reader announces nothing, and the
   * next Tab continues from the old position. Moving focus to the top of the
   * new article makes the change audible and puts Tab back at the beginning.
   *
   * Undefined on the first render, so an ordinary page load does NOT steal
   * focus from where the browser put it.
   */
  focusKey,
}: {
  lang: Language;
  children: ReactNode;
  nav?: ReactNode;
  focusKey?: string;
}) {
  const tr = (k: Parameters<typeof docsText>[0]) => docsText(k, lang);
  const main = useRef<HTMLElement>(null);
  const first = useRef(true);

  useEffect(() => {
    if (focusKey === undefined) return;
    if (first.current) {
      first.current = false;
      return;
    }
    main.current?.focus();
  }, [focusKey]);

  return (
    <div className="app docs" lang={lang}>
      {/* Nine chapter links sit between the top of the page and the prose. A
          keyboard reader should not have to pass them on every chapter. */}
      <a className="docs-skip" href="#docs-main">
        {tr('docs.skipToContent')}
      </a>
      <header className="app-header">
        <DocLink to={`/${lang}/docs`} className="brand docs-brand">
          TimeWeave
        </DocLink>
        <div className="app-header-actions">
          {/* A plain anchor, not a DocLink: this leaves the documentation for
              the application, which is a different shell entirely. Letting the
              browser do a full navigation is both simpler and correct. */}
          <a className="btn" href="/">
            {tr('docs.backToApp')}
          </a>
        </div>
      </header>
      {/* tabIndex -1 makes this focusable from script without putting it in
          the Tab order. */}
      <main className="app-main docs-main" id="docs-main" ref={main} tabIndex={-1}>
        {/*
          THE ARTICLE COMES FIRST IN THE DOM, and CSS moves the sidebar to the
          left of it on a wide screen.

          Source order was nav-first, which put the five chapter-group headings
          and the contents heading -- all h2 -- ahead of the page's own h1. A
          document whose outline opens at level 2 and reaches level 1 sixth is
          wrong for anyone reading by heading, and it is not visible in a
          browser. The skip link above already covers the thing nav-first was
          for, so nothing is lost by reading order either.
        */}
        <div className="docs-layout">
          {children}
          {nav}
        </div>
      </main>
    </div>
  );
}
