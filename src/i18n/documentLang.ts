/**
 * `<html lang>` follows the language the screen is in (P8-finish-1).
 *
 * index.html is served as `<html lang="ja">`, and only the guide ever changed
 * it (useDocMeta). An English calendar, login page or share page therefore
 * told a screen reader its text was Japanese. The LanguageProvider now writes
 * the language it resolves, on mount and whenever it changes:
 *
 *   signed-in app / login   the owner's stored language, else the browser's
 *   anonymous share page    the VIEWER's browser language -- that provider is
 *                           public and never reads the owner's settings, so
 *                           nothing of the owner's choice reaches the page
 *   the guide               NOT written here: useDocMeta sets the language of
 *                           the chapter being read (a URL may name one), and
 *                           React runs a child's effect before its provider's,
 *                           so a provider write would overwrite it. App passes
 *                           ownsDocumentLang={false} on that one route.
 *
 * Pure apart from the one assignment, so it is testable without a DOM.
 */
import type { Language } from './types';

export function syncDocumentLang(doc: { documentElement: { lang: string } } | undefined, language: Language): void {
  if (!doc) return;
  if (doc.documentElement.lang !== language) doc.documentElement.lang = language;
}
