/**
 * Translate a Supabase write failure into a domain error the UI can present.
 *
 * THE DATABASE'S CONTRACT (migration 0008, and 0003 for the unique index):
 *
 *   Every timezone domain violation raises SQLSTATE 23514 (check_violation)
 *   with a stable machine-readable token in DETAIL, which PostgREST surfaces
 *   as `details`. The MESSAGE is written for humans and logs; its wording is
 *   free to change, so it is never parsed here. The constraint name is not used
 *   as the identifier either — PostgREST does not pass it through.
 *
 *   That is why the token, not the SQLSTATE, is the discriminator: 23514 is
 *   shared with the placement CHECK and with any future constraint.
 *
 * Anything unrecognised becomes a plain Error carrying the server's message, so
 * no failure is ever swallowed.
 */

import {
  DuplicateExceptionError,
  EventQuotaExceededError,
  ExceptionQuotaExceededError,
  InvalidTimezoneError,
  TimezoneClearedError,
  TimezoneRequiredError,
  WriteRateLimitedError,
} from '../errors';

/** The parts of a PostgrestError this mapping reads. */
export interface WriteErrorLike {
  code?: string | null;
  details?: string | null;
  hint?: string | null;
  message?: string | null;
}

/** Widest wait this module will believe, in seconds. See parseRetryAfterSeconds. */
const MAX_RETRY_AFTER_SECONDS = 3600;

/**
 * Read `retry_after_seconds=N` out of a PostgreSQL HINT.
 *
 * 0012 puts the backoff here rather than in a Retry-After header because a
 * header does not survive the RAISE -- measured, not assumed. HINT is prose
 * meant for humans, so this parser treats it as a best-effort source: a usable
 * number improves the message, and anything else simply falls back to generic
 * advice. It must never be the reason a save reports the wrong thing.
 *
 * ACCEPTED: a well-formed INTEGER token whose value is 1..3600 inclusive.
 *   * integer only. The database's contract emits ceil(...)::text, so a
 *     fractional value means the contract is not what this code thinks it is --
 *     `7.5` is rejected outright rather than read as 7, because silently
 *     truncating a value we do not understand is how a small mismatch becomes a
 *     wrong number on screen;
 *   * the key is a token of its own. `retry_after_seconds` must start the hint or
 *     follow a character that cannot continue a key (space, `;`, `,` ...), so
 *     `xretry_after_seconds=7` or `hint.retry_after_seconds=7` -- a different
 *     key that merely ends in this name -- is not read as this one;
 *   * the token ends where the digits end. The value must be followed by the end
 *     of the hint or by a character that cannot continue a token (space, `;`,
 *     `,` ...). `7abc` or `7s` is a value this contract does not produce, so it
 *     is rejected for the same reason as `7.5`, not read as 7;
 *   * at least 1. The database only raises when the wait is positive, so 0 is
 *     not a wait at all -- it is a hint that is not what this code expects, and
 *     it gets the same null as any other unusable value. That also keeps the
 *     parser's output in the shape retryAdvice treats as a real number;
 *   * at most 3600. tau is 120 seconds at the shipped parameters, so anything
 *     past an hour is not a longer wait, it is a broken value. Rejecting it is
 *     better than clamping: clamping would state "約60分後" with false
 *     confidence, while rejecting falls back to "しばらく待ってから", which is true.
 *
 * Surrounding text is allowed, so the hint may gain other fields later without
 * breaking this.
 */
export function parseRetryAfterSeconds(hint: string | null | undefined): number | null {
  if (!hint) return null;

  // Both boundaries use the same character class, so the key and the value are
  // delimited by the same rule.
  //
  // Left: the start of the hint, or a character that is neither a word character
  // nor a decimal point. This is written as a consumed group rather than a
  // lookbehind on purpose: Vite's default build target still includes Safari
  // releases without lookbehind, and esbuild does not rewrite regex syntax, so a
  // lookbehind here would be a parse error that takes the whole bundle down.
  //
  // Right: the negative lookahead. A word character (digit, letter, `_`) or a
  // decimal point immediately after the digits means the token is not the
  // integer this contract promises, so there is no match at all -- backtracking
  // to a shorter digit run cannot rescue it either, because the next character
  // is then a digit.
  const m = /(?:^|[^\w.])retry_after_seconds=(\d+)(?![\w.])/.exec(hint);
  if (!m) return null;

  const seconds = Number(m[1]);
  if (!Number.isSafeInteger(seconds)) return null;
  if (seconds < 1 || seconds > MAX_RETRY_AFTER_SECONDS) return null;
  return seconds;
}

export function mapEventWriteError(error: WriteErrorLike): Error {
  // Partial unique index on (recurrence_id, slot key): the occurrence already
  // has an override or cancellation.
  if (error.code === '23505') return new DuplicateExceptionError();

  switch (error.details) {
    case 'TIMEWEAVE_TZ_INVALID':
      return new InvalidTimezoneError();
    case 'TIMEWEAVE_TZ_REQUIRED':
      return new TimezoneRequiredError();
    case 'TIMEWEAVE_TZ_CLEARED':
      return new TimezoneClearedError();
    // 0012. The wait comes from HINT; a missing or malformed one costs the user
    // a precise number, never the correct error.
    case 'TIMEWEAVE_RATE_EVENTS':
      return new WriteRateLimitedError(parseRetryAfterSeconds(error.hint));
    // 0011. Both are recoverable by the user, because that migration's quotas
    // are delta rules: an account over a ceiling may still edit and delete.
    case 'TIMEWEAVE_QUOTA_EVENTS':
      return new EventQuotaExceededError();
    case 'TIMEWEAVE_QUOTA_EXCEPTIONS':
      return new ExceptionQuotaExceededError();
    default:
      return new Error(error.message ?? 'Unknown database error');
  }
}
