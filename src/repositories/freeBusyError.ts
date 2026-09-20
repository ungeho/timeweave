/**
 * Translate a get_free_busy failure into a domain error the share page can present.
 *
 * THE DATABASE'S CONTRACT (migration 0019):
 *
 *   The anonymous Free/Busy RPC refuses in three places, with SQLSTATE PT429 and
 *   a stable machine-readable token in DETAIL, which PostgREST surfaces as
 *   `details`:
 *
 *     owner budget spent  DETAIL TIMEWEAVE_RATE_FREEBUSY       HINT retry_after_seconds=N
 *     link budget spent   DETAIL TIMEWEAVE_RATE_FREEBUSY       HINT retry_after_seconds=N
 *     no free slot        DETAIL TIMEWEAVE_RATE_FREEBUSY_BUSY  HINT retry_after_seconds=1
 *
 *   The MESSAGE is written for humans and logs -- it is the ONLY thing that
 *   separates the owner refusal from the link refusal -- and this module never
 *   parses it, exactly as mapEventWriteError does not. The two therefore map to
 *   one kind; see FreeBusyRateLimitedError for why that is deliberate rather
 *   than a shortcut.
 *
 *   0019 puts the backoff in HINT because an aborted transaction cannot set a
 *   Retry-After header (measured for 0012). There is no HTTP header to read.
 *
 * THE TOKEN, NOT THE SQLSTATE, IS THE DISCRIMINATOR. PT429 is a code this
 * project could use for any future limiter, so an unrecognised DETAIL is never
 * assumed to be one of these two refusals -- not even when the code says PT429.
 * Anything unrecognised becomes a plain Error carrying the server's message, so
 * no failure is ever swallowed and the page still refuses to show an empty grid.
 */

import { FreeBusyRateLimitedError } from '../errors';
// The same PostgrestError subset the write mapping reads, and the same HINT
// parser (0012's contract and 0019's are the same `retry_after_seconds=N`).
// Re-using both keeps one implementation of each rather than a second copy.
import { parseRetryAfterSeconds, type WriteErrorLike } from './eventWriteError';

export function mapFreeBusyError(error: WriteErrorLike): Error {
  switch (error.details) {
    // Owner OR link budget. A missing or malformed hint costs the viewer a
    // precise number, never the correct error.
    case 'TIMEWEAVE_RATE_FREEBUSY':
      return new FreeBusyRateLimitedError('rate', parseRetryAfterSeconds(error.hint));
    // Both concurrency slots for this calendar were busy. 0019 always hints 1 s.
    case 'TIMEWEAVE_RATE_FREEBUSY_BUSY':
      return new FreeBusyRateLimitedError('busy', parseRetryAfterSeconds(error.hint));
    default:
      return new Error(error.message ?? 'Unknown database error');
  }
}
