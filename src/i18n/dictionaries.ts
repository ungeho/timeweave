/**
 * The dictionaries, keyed by language, plus the compile-time parity checks
 * that keep them honest.
 *
 * KEY PARITY is asserted in en.ts, where the keys are declared. PLACEHOLDER
 * PARITY is asserted here, because it needs both literal types in scope: a
 * translation that writes `{total}` where the source said `{max}` would
 * otherwise type-check, interpolate nothing, and ship `{total}` to the screen
 * in one language only.
 */

import type { ExtractVars } from './types';
import { ja, type MessageKey } from './ja';
import { en } from './en';

export const dictionaries = { ja, en } as const;

/**
 * Per-key placeholder comparison.
 *
 * Yields `true` when both messages declare the same set of `{names}`, and the
 * offending KEY otherwise -- so the compiler error names the entry to fix
 * rather than just saying a boolean was expected.
 *
 * The comparison is mutual inclusion rather than equality because the two
 * unions are built in different orders and `extends` on unions is the only
 * structural test available.
 */
type VarsAgree<K extends MessageKey> =
  [ExtractVars<(typeof ja)[K]>] extends [ExtractVars<(typeof en)[K]>]
    ? [ExtractVars<(typeof en)[K]>] extends [ExtractVars<(typeof ja)[K]>]
      ? true
      : K
    : K;

/** Every key whose placeholders disagree. `never` when the dictionaries match. */
type KeysWithDisagreeingVars = Exclude<{ [K in MessageKey]: VarsAgree<K> }[MessageKey], true>;

const _varParity: [KeysWithDisagreeingVars] extends [never] ? true : never = true;
void _varParity;

export type { MessageKey };
