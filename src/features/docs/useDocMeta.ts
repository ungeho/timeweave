/**
 * Put the computed metadata into the document head.
 *
 * NO DECISIONS HERE. Everything this writes comes from `docMeta`, which is
 * pure and tested; this file is the DOM write and the cleanup, and that split
 * is why the rules can be tested at all in a project with no jsdom.
 *
 * WHY IT CLEANS UP. The guide shares one HTML document with the calendar, so
 * a tag left behind after the reader navigates away would describe the wrong
 * screen. Every tag this adds is marked as the guide's own and removed with
 * the guide; the title and `<html lang>` go back to what the document was
 * SERVED with, captured once on mount rather than re-read on each navigation
 * -- otherwise the value restored at the end would be the previous chapter's,
 * not the document's own.
 */

import { useEffect, useRef } from 'react';
import { absolute, type DocMeta } from './docsMeta';

/** Marks the tags this module owns, so cleanup removes those and only those. */
const OWNED = 'data-docs-meta';

function meta(name: string, content: string): void {
  const el = document.createElement('meta');
  el.setAttribute('name', name);
  el.setAttribute('content', content);
  el.setAttribute(OWNED, '');
  document.head.appendChild(el);
}

function link(rel: string, href: string, hreflang?: string): void {
  const el = document.createElement('link');
  el.setAttribute('rel', rel);
  el.setAttribute('href', href);
  if (hreflang !== undefined) el.setAttribute('hreflang', hreflang);
  el.setAttribute(OWNED, '');
  document.head.appendChild(el);
}

export function useDocMeta(m: DocMeta, origin: string | null): void {
  // What the document was served with, kept across navigations.
  const served = useRef<{ title: string; lang: string } | null>(null);
  if (served.current === null) {
    served.current = { title: document.title, lang: document.documentElement.lang };
  }

  // The alternates are rebuilt on every render, so they are compared by value
  // -- a reference check would rewrite the head on each one.
  const altKey = m.alternates.map((a) => `${a.hreflang} ${a.path}`).join('|');
  const { title, description, lang, canonicalPath, robots } = m;

  useEffect(() => {
    document.title = title;
    // The CHROME's language. The article sets its own when the body falls back
    // to another one; that is a different element and is left alone.
    document.documentElement.lang = lang;

    meta('description', description);
    if (robots !== null) meta('robots', robots);

    const canonical = canonicalPath === null ? null : absolute(origin, canonicalPath);
    if (canonical !== null) link('canonical', canonical);

    // hreflang is absolute-only by specification, so with no known origin the
    // honest thing is to emit none rather than a value a crawler must guess
    // the host for.
    if (origin !== null) {
      for (const a of m.alternates) link('alternate', origin + a.path, a.hreflang);
    }

    return () => {
      for (const el of document.head.querySelectorAll(`[${OWNED}]`)) el.remove();
      const s = served.current;
      if (s) {
        document.title = s.title;
        document.documentElement.lang = s.lang;
      }
    };
    // `m.alternates` is covered by altKey, which is its value.
  }, [title, description, lang, canonicalPath, robots, altKey, origin, m.alternates]);
}
