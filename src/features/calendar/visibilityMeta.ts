/**
 * Presentation metadata for event visibility. Kept separate so labels/aria are
 * defined once. Icons are rendered as inline SVG in the UI (not emoji) to avoid
 * cross-OS rendering differences, and text labels ensure the distinction never
 * relies on color alone.
 *
 * P6 STEP 1 TURNED THE RECORD INTO A FUNCTION. It used to be a module-level
 * `Record<Visibility, VisibilityMeta>` whose six strings were resolved with
 * DEFAULT_LANGUAGE at import time, which meant they could never follow the
 * display language: a chip in an English UI would have read
 * "Standup (非公開)", because the chip's own wording follows the language and
 * the label interpolated into it did not.
 *
 * It is a pure function, not a hook. The language arrives as an argument from
 * the three components that render a visibility, so this module stays testable
 * in `environment: 'node'` -- the reason every decision in this codebase lives
 * outside JSX in the first place.
 */

import { t } from '../../i18n/t';
import { DEFAULT_LANGUAGE, isLanguage, type Language } from '../../i18n/types';
import type { Visibility } from '../../types/event';

export interface VisibilityMeta {
  /** Full label, e.g. for menus/aria. */
  label: string;
  /** Short label for compact chips. */
  short: string;
}

/**
 * Every Visibility, in presentation order: least disclosed first.
 *
 * Exported because callers used to read `Object.keys(visibilityMeta)` to get
 * this list, and key order is a weak place to keep a contract. The event
 * dialog's option list is checked against it.
 */
export const VISIBILITIES: readonly Visibility[] = ['private', 'busy_only', 'public'];

/**
 * One table per language, built on first use.
 *
 * A month grid can draw a hundred chips, and each asks for one visibility, so
 * resolving six strings per chip would be six hundred dictionary lookups per
 * render. The cache also keeps object identity stable across renders for a
 * given language, which React prefers. The dictionaries are static, so a
 * cached table can never go stale.
 */
const CACHE = new Map<Language, Record<Visibility, VisibilityMeta>>();

function tableFor(lang: Language): Record<Visibility, VisibilityMeta> {
  const hit = CACHE.get(lang);
  if (hit) return hit;
  const built: Record<Visibility, VisibilityMeta> = {
    private: {
      label: t('calendar.visibility.private', lang),
      short: t('calendar.visibility.privateShort', lang),
    },
    busy_only: {
      label: t('calendar.visibility.busyOnly', lang),
      short: t('calendar.visibility.busyOnlyShort', lang),
    },
    public: {
      label: t('calendar.visibility.public', lang),
      short: t('calendar.visibility.publicShort', lang),
    },
  };
  CACHE.set(lang, built);
  return built;
}

/**
 * The label and short label for one visibility, in `lang`.
 *
 * `lang` DEFAULTS TO THE DEFAULT LANGUAGE, the same shape contentLengthError
 * and labelLengthError use. Every rendering caller passes the resolved
 * language; the default is for tests and for any future non-React caller, and
 * it is what keeps this change invisible until the switch flips.
 *
 * Checked at runtime as well as in the type, for the reason `t()` checks it:
 * the value can arrive from `owner_settings`, so a row written by a newer
 * version of the app must not render `undefined`.
 *
 * WHAT THIS DOES NOT TOUCH. The three values are the stored enum, and nothing
 * here decides what is disclosed: `private` still means the details are the
 * owner's alone, `busy_only` still means an anonymous viewer learns only that
 * an event exists, and `public` still means the contents may be shared. Those
 * rules live in the database and in the share RPC; this names them.
 */
export function visibilityMeta(
  visibility: Visibility,
  lang: Language = DEFAULT_LANGUAGE,
): VisibilityMeta {
  return tableFor(isLanguage(lang) ? lang : DEFAULT_LANGUAGE)[visibility];
}
