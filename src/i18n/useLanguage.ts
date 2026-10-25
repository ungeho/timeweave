/**
 * Read the resolved language, and the bound `t` that goes with it.
 *
 * Two hooks rather than one because they have different audiences. P3 will
 * call `useTranslate()` in roughly every component; `useLanguage()` is for the
 * handful of places that need the language itself -- date formatting in P4,
 * and the settings dialog pushing a saved value back in.
 */

import { useContext, useMemo } from 'react';
import { LanguageContext, type LanguageContextValue } from './LanguageProvider';
import { translator } from './t';
import { DEFAULT_LANGUAGE } from './types';

/**
 * The language context.
 *
 * Throws outside a provider rather than defaulting, matching useAuth. A
 * component rendering in the wrong place is a wiring bug, and silently
 * serving Japanese would hide it until a translated build shipped.
 */
export function useLanguage(): LanguageContextValue {
  const ctx = useContext(LanguageContext);
  if (!ctx) {
    throw new Error('useLanguage must be used within a LanguageProvider');
  }
  return ctx;
}

/**
 * A `t` bound to the current language.
 *
 * Memoised on the language so a render that changes nothing else does not
 * hand every child a new function identity.
 *
 * NOT USED BY ANYTHING IN P2. It exists so P3 can move strings one file at a
 * time without also designing an API under deadline.
 */
export function useTranslate() {
  const { language } = useLanguage();
  return useMemo(() => translator(language), [language]);
}

/**
 * The language, for code that may run outside a provider.
 *
 * Only for the narrow case of a module-level default; prefer `useLanguage`.
 */
export const FALLBACK_LANGUAGE = DEFAULT_LANGUAGE;
