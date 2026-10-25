/**
 * What the share dialog is showing in its error line, and how it reads.
 *
 * THE STATE HOLDS A CAUSE OR A FACT, NEVER A SENTENCE. Before P6 step 6 the
 * dialog kept `error: string | null`, filled either from `e.message` at a
 * catch or from `tr(...)` at a validation failure. Both froze the wording at
 * the moment of the failure, so a language change afterwards re-rendered every
 * other string in the dialog and left this one behind -- the same defect step 2
 * found on the share page and step 5 found in `useEvents`.
 *
 * TWO VARIANTS, because the two sources are genuinely different and only one
 * of them has a cause to keep:
 *
 *   'caught'        something was thrown. The value is kept as-is and read
 *                   through caughtErrorText, which is shared with the
 *                   calendar's banner.
 *   'labelTooLong'  the dialog itself refused the input. There is no thrown
 *                   value, so what is kept is the FACT plus the number the
 *                   sentence interpolates. Keeping `max` rather than
 *                   re-measuring the label at render is deliberate: the owner
 *                   is still editing that field, and re-deriving would make
 *                   the message vanish mid-keystroke, which is not when this
 *                   dialog has ever cleared it.
 *
 * A module rather than a ternary in JSX because the project has no
 * component-test environment (vitest runs with `environment: 'node'`), so a
 * decision that lives here is a decision that can be tested -- the same reason
 * shareLinkState.ts and shareLinkLabel.ts sit beside it.
 */

import { caughtErrorText } from '../../i18n/errorText';
import { DEFAULT_LANGUAGE, type Language } from '../../i18n/types';
import { labelTooLongMessage } from './shareLinkLabel';

/** An error the dialog is showing. */
export type ShareDialogError =
  | { readonly kind: 'caught'; readonly cause: unknown }
  | { readonly kind: 'labelTooLong'; readonly max: number };

/**
 * A non-failure outcome worth telling the owner about, as a KEY.
 *
 * The two notices are plain sentences with no variables, so the key alone is
 * the whole state. They were stored as `tr(...)` output, which froze them for
 * the same reason the errors were frozen -- and a notice is more likely than
 * an error to still be on screen later, because nothing went wrong.
 *
 * Typed as a union of literals, not as MessageKey: `t` reads a message's
 * placeholders off the key's literal type, so a widened key would make the
 * render site owe it the widest variable set in the dictionary.
 */
export type ShareDialogNotice = 'shareDialog.deleteRefused' | 'shareDialog.availableRefused';

/**
 * The error line's text, resolved at render.
 *
 * `lang` defaults to the default language so a call with no argument answers in
 * the Japanese this dialog has always shown.
 */
export function shareDialogErrorText(
  error: ShareDialogError,
  lang: Language = DEFAULT_LANGUAGE,
): string {
  return error.kind === 'caught'
    ? caughtErrorText(error.cause, lang)
    : labelTooLongMessage(error.max, lang);
}
