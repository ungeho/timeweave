/**
 * Resolves the display language once and hands it to the tree.
 *
 * LIVE SINCE THE END OF P6. It was built in P2 and read by nobody for four
 * phases: the switch pinned what it handed out to Japanese while ~196 strings,
 * every date format, eleven pure modules and four error-display paths were
 * migrated behind it. That ordering is what let the resolution, the fetch, the
 * leak guard and the save race all be built and tested while the screen was
 * guaranteed not to move.
 *
 * Every decision this file makes is delegated to i18n/languageState.ts, which
 * is testable in this project's node environment. What remains here is state,
 * one effect, and a context.
 */

import { createContext, useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { getOwnerSettings } from '../repositories/ownerSettingsRepository';
import { useAuth } from '../auth/useAuth';
import { browserLanguages } from './browserLanguages';
import {
  needsFetch,
  retainStored,
  shouldApplyFetchResult,
  shouldLoadStoredLanguage,
} from './languageState';
import { resolveLanguage } from './resolveLanguage';
import { syncDocumentLang } from './documentLang';
import { DEFAULT_LANGUAGE, LANGUAGE_SWITCH_ENABLED, isLanguage, type Language } from './types';

export interface LanguageContextValue {
  /**
   * The language components RENDER in.
   *
   * Equal to `resolvedLanguage` now that LANGUAGE_SWITCH_ENABLED is true. The
   * constant is kept rather than deleted: it is the one line that reverts the
   * whole feature if a translation turns out to be wrong in production, and it
   * costs nothing to leave in place.
   */
  language: Language;
  /**
   * What resolution produced, switch or no switch.
   *
   * Kept separate from `language` so the switch stays meaningful -- with it
   * off these two differ, and the tests that prove the resolution works do not
   * have to be rewritten to flip it. Components read `language`.
   */
  resolvedLanguage: Language;
  /**
   * Push a newly saved preference in without a reload.
   *
   * SettingsDialog calls this after `saveOwnerSettings` returns, so the value
   * held is the one the server confirmed rather than the one the form
   * submitted. Passing the SERVER's value is why this takes an argument
   * instead of re-fetching: a re-fetch would be a second round trip to learn
   * something the save already reported.
   */
  setStoredLanguage: (lang: Language | null) => void;
}

export const LanguageContext = createContext<LanguageContextValue | null>(null);

export function LanguageProvider({
  children,
  isPublicRoute = false,
  ownsDocumentLang = true,
}: {
  children: ReactNode;
  /**
   * True on /s/:token. Set by App, not inferred here, so the one place that
   * decides what route this is stays the one place.
   */
  isPublicRoute?: boolean;
  /**
   * Whether this provider keeps `<html lang>` in step with its language
   * (P8-finish-1, documentLang.ts). False only for the guide, whose screen
   * sets the chapter's own language. Set by App, like isPublicRoute.
   */
  ownsDocumentLang?: boolean;
}) {
  const { user, authEnabled } = useAuth();
  const userId = user?.id ?? null;

  const [stored, setStored] = useState<Language | null>(null);
  const [loadedFor, setLoadedFor] = useState<string | null>(null);

  // Read once per mount: the browser's preference list does not change while
  // the page is open, and re-reading it on every render would make `language` a new
  // value each time for no reason.
  const browser = useMemo(() => browserLanguages(), []);

  const shouldLoad = shouldLoadStoredLanguage({ isPublicRoute, authEnabled, userId });

  /** The user the in-flight request was issued for. */
  const requestFor = useRef<string | null>(null);
  /**
   * Monotonic count of saves pushed in through setStoredLanguage.
   *
   * A response issued BEFORE a save must not overwrite it. The effect's
   * dependency array happens to make React cancel such a request today, but
   * that is an accident of scheduling rather than a stated rule; this counter
   * states it. See shouldApplyFetchResult.
   */
  const writeSeq = useRef(0);

  useEffect(() => {
    if (!needsFetch({ shouldLoad, userId, loadedFor })) return;

    let cancelled = false;
    requestFor.current = userId;
    const seqAtRequest = writeSeq.current;

    const applicable = () =>
      shouldApplyFetchResult({
        cancelled,
        requestedFor: userId,
        currentUserId: requestFor.current,
        writeSeqAtRequest: seqAtRequest,
        writeSeqNow: writeSeq.current,
      });

    void (async () => {
      try {
        const s = await getOwnerSettings();
        if (!applicable()) return;
        setStored(isLanguage(s.language) ? s.language : null);
      } catch {
        // A failed read is not a broken page. Leaving `stored` null means
        // resolveLanguage falls back to the browser, which is exactly what an
        // owner who has set nothing already gets.
        if (!applicable()) return;
        setStored(null);
      } finally {
        // Marked loaded either way, so a failure does not retry on every auth
        // event. Skipped when the response is stale, so a save that landed
        // first keeps ownership of both fields.
        if (applicable()) setLoadedFor(userId);
      }
    })();

    return () => { cancelled = true; };
  }, [shouldLoad, userId, loadedFor]);

  // The leak guard, applied at READ time rather than in an effect: a value
  // belonging to a different id is never handed out, not even for the render
  // between sign-out and the effect that would have cleared it.
  const effectiveStored = retainStored({ stored, loadedFor, userId });

  const resolvedLanguage = resolveLanguage({ stored: effectiveStored, browser });
  const language = LANGUAGE_SWITCH_ENABLED ? resolvedLanguage : DEFAULT_LANGUAGE;

  const setStoredLanguage = useCallback((lang: Language | null) => {
    writeSeq.current += 1;
    setStored(lang);
    setLoadedFor(userId);
  }, [userId]);

  // <html lang> follows the language the screen is in (documentLang.ts).
  useEffect(() => {
    if (ownsDocumentLang) syncDocumentLang(typeof document === 'undefined' ? undefined : document, language);
  }, [ownsDocumentLang, language]);

  const value = useMemo<LanguageContextValue>(
    () => ({ language, resolvedLanguage, setStoredLanguage }),
    [language, resolvedLanguage, setStoredLanguage],
  );

  return <LanguageContext.Provider value={value}>{children}</LanguageContext.Provider>;
}
