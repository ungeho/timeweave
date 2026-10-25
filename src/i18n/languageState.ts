/**
 * The provider's decisions, as pure functions.
 *
 * The component in LanguageProvider.tsx does three things -- hold state, run
 * an effect, render a context -- and none of them can be tested here: vitest
 * runs with `environment: 'node'` and jsdom is not added. So every judgement
 * the provider makes lives in this file instead, which is the same split the
 * rest of the project uses (features/share/freeBusyPresentation.ts explains
 * the reasoning at length).
 *
 * What is left in the component is wiring with no decisions in it.
 */

import type { Language } from './types';

/**
 * Whether the stored preference should be fetched at all, and for whom.
 *
 * ANONYMOUS NEVER FETCHES. A viewer on /s/:token has no session, the table is
 * closed to `anon` by both RLS and table privileges (0025/0026), and asking
 * anyway would spend a request to earn a 42501. More importantly it would be
 * the wrong question: an anonymous viewer must get THEIR OWN browser language,
 * never the owner's preference, which is the mirror of the time-zone rule
 * where the owner's value is the right one.
 *
 * Local mode (`authEnabled: false`) has no owner row either.
 */
export function shouldLoadStoredLanguage(input: {
  isPublicRoute: boolean;
  authEnabled: boolean;
  userId: string | null;
}): boolean {
  if (input.isPublicRoute) return false;
  if (!input.authEnabled) return false;
  return input.userId !== null;
}

/**
 * One fetch per user, and a fetch again when the user changes.
 *
 * `loadedFor` is the user id the current stored value belongs to. Comparing it
 * with the signed-in id answers both questions the provider has: "do I need to
 * ask?" and, by its absence, "is what I hold still mine?".
 *
 * Returning false when ids match is what keeps this to a single query per
 * session -- the effect re-runs on every auth state change Supabase emits,
 * including token refreshes, and those must not each cost a round trip.
 */
export function needsFetch(input: {
  shouldLoad: boolean;
  userId: string | null;
  loadedFor: string | null;
}): boolean {
  if (!input.shouldLoad) return false;
  return input.userId !== input.loadedFor;
}

/**
 * Whether a settings response that has just arrived may be applied.
 *
 * THE RACE THIS CLOSES. The provider starts one fetch when a user signs in.
 * If the owner opens settings and SAVES a language before that fetch returns,
 * the response carries the value from before the save and would overwrite the
 * newer one -- the owner picks English, the page keeps resolving Japanese, and
 * nothing on screen explains why.
 *
 * Today the provider survives this by accident: `loadedFor` is in the effect's
 * dependency array, a save changes it, React therefore re-runs the effect and
 * its cleanup flips the old `cancelled` flag. That is a real mechanism but a
 * fragile one -- `loadedFor` looks derivable, and anyone who removes it from
 * the deps reopens the race with no test failing. A monotonic write counter
 * states the invariant directly instead of leaning on React's scheduling.
 *
 * `writeSeqNow > writeSeqAtRequest` means at least one save landed while the
 * request was in flight, so the response is stale by definition.
 */
export function shouldApplyFetchResult(input: {
  cancelled: boolean;
  /** The user the request was issued for. */
  requestedFor: string | null;
  /** The user signed in now. */
  currentUserId: string | null;
  /** The write counter when the request was issued. */
  writeSeqAtRequest: number;
  /** The write counter now. */
  writeSeqNow: number;
}): boolean {
  if (input.cancelled) return false;
  if (input.requestedFor !== input.currentUserId) return false;
  if (input.writeSeqNow !== input.writeSeqAtRequest) return false;
  return true;
}

/**
 * The stored value to hold, given who is signed in now.
 *
 * THIS IS THE LEAK GUARD. A stored preference belongs to one account, and the
 * moment the signed-in id stops matching the id it was loaded for -- sign-out,
 * or a switch to another account -- it must be dropped rather than kept until
 * the replacement arrives. Keeping it would show the next person, or an
 * anonymous visitor on the same tab, the previous owner's language.
 *
 * Dropping to null does not blank the UI: resolveLanguage falls back to the
 * browser, which is the correct answer for "nobody is signed in".
 */
export function retainStored(input: {
  stored: Language | null;
  loadedFor: string | null;
  userId: string | null;
}): Language | null {
  if (input.userId === null) return null;
  if (input.loadedFor !== input.userId) return null;
  return input.stored;
}
