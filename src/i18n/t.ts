/**
 * `t()` -- look a message up and fill its placeholders.
 *
 * A PURE FUNCTION TAKING THE LANGUAGE AS AN ARGUMENT, not a hook reading a
 * context. That shape is chosen for this repository specifically: vitest runs
 * with `environment: 'node'` and jsdom is not added, so a hook-based API would
 * put every message beyond the reach of the test suite -- which is the exact
 * problem the existing "pure module holds the copy" convention was invented to
 * avoid (see features/share/freeBusyPresentation.ts). The React layer will wrap
 * this in P2; the wrapper will be thin precisely because this is not.
 */

import { dictionaries, type MessageKey } from './dictionaries';
import { ja } from './ja';
import { DEFAULT_LANGUAGE, isLanguage, type ExtractVars, type Language, type VarValue } from './types';

/** The placeholder names a given key needs, read off the Japanese literal. */
export type MessageVars<K extends MessageKey> = ExtractVars<(typeof ja)[K]>;

/**
 * The argument list for a key: nothing at all when the message has no
 * placeholders, and exactly the required names when it does.
 *
 * `[Vars] extends [never]` rather than `Vars extends never`, because a bare
 * conditional over `never` DISTRIBUTES and collapses to `never`, which would
 * make every call accept zero arguments and defeat the whole mechanism.
 */
type VarArgs<K extends MessageKey> =
  [MessageVars<K>] extends [never]
    ? []
    : [vars: Record<MessageVars<K>, VarValue>];

/**
 * Fill `{name}` placeholders.
 *
 * Unknown placeholders are left verbatim rather than blanked. A stray `{x}` on
 * screen is a visible bug that gets reported; an empty gap reads as intended
 * copy and survives for months. The typed call signature means this can only
 * be reached through an untyped boundary anyway.
 */
function interpolate(message: string, vars: Record<string, VarValue> | undefined): string {
  if (!vars) return message;
  return message.replace(/\{(\w+)\}/g, (whole, name: string) =>
    Object.prototype.hasOwnProperty.call(vars, name) ? String(vars[name]) : whole,
  );
}

/**
 * The message for `key` in `lang`.
 *
 * `lang` is typed as `Language`, but it is also checked at runtime: the value
 * can arrive from `owner_settings` or from `navigator.languages`, and a build
 * that trusted the type would render `undefined` for a row written by a newer
 * version of the app. An unrecognised language falls back to Japanese, the
 * same rule `resolveLanguage` applies.
 *
 * A key missing from the chosen dictionary cannot happen -- the parity checks
 * in en.ts and dictionaries.ts make it a compile error -- but if one ever
 * does, the key itself is returned. It is searchable, it is obviously wrong,
 * and it is not a blank.
 */
export function t<K extends MessageKey>(key: K, lang: Language, ...args: VarArgs<K>): string {
  const dict = dictionaries[isLanguage(lang) ? lang : DEFAULT_LANGUAGE];
  const message: string | undefined = dict[key];
  if (message === undefined) return key;
  return interpolate(message, args[0] as Record<string, VarValue> | undefined);
}

/**
 * A `t` bound to one language, for a render pass that has already resolved it.
 *
 * Returned as a plain closure rather than an object so call sites read
 * `tr('common.save')` -- the shape P3 will use in components once P2 provides
 * the language.
 */
export function translator(lang: Language) {
  return <K extends MessageKey>(key: K, ...args: VarArgs<K>): string =>
    t(key, lang, ...args);
}
