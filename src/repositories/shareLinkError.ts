/**
 * Translate a share-link write failure into a domain error the dialog can show.
 *
 * THE DATABASE'S CONTRACT (migration 0016):
 *
 *   Three refusals, each with a stable machine-readable token in DETAIL, which
 *   PostgREST surfaces as `details`:
 *
 *     active quota  SQLSTATE 23514  TIMEWEAVE_QUOTA_SHARE_LINKS_ACTIVE  HINT: prose
 *     total quota   SQLSTATE 23514  TIMEWEAVE_QUOTA_SHARE_LINKS_TOTAL   HINT: prose
 *     create rate   SQLSTATE PT429  TIMEWEAVE_RATE_SHARE_LINKS          HINT: retry_after_seconds=N
 *
 *   ONLY THE RATE HINT IS MACHINE-READABLE. The two quota hints are English
 *   sentences for a human reading a log; they are never parsed here, and the
 *   Japanese advice comes from the error classes instead.
 *
 *   THE MESSAGE IS NEVER READ EITHER, and here that is not only a convention:
 *   0016 formats the owner's UUID and the configured ceilings into it
 *   ('share link quota exceeded: owner % would hold % active links, limit is %'),
 *   so surfacing it would put an internal identifier on screen. Mapping is what
 *   keeps it out.
 *
 * THE TOKEN, NOT THE SQLSTATE, IS THE DISCRIMINATOR. 23514 is shared with every
 * other CHECK in this schema and PT429 with every other limiter, so an
 * unrecognised DETAIL is never assumed to be one of these three -- not even
 * when the code matches. Anything unrecognised becomes a plain Error carrying
 * the server's message, so no failure is swallowed.
 *
 * WHERE IT IS USED. create_share_link only. 0016's quota trigger also runs on
 * UPDATE, but its delta rule checks only owners whose active or total count
 * RISES (`where d.d_active > 0 or d.d_total > 0`), and the only UPDATE this app
 * issues is revoke_share_link, which lowers the active count. DELETE has no
 * trigger at all. So revoke and list cannot raise any of these three.
 */

import {
  ShareLinkActiveQuotaExceededError,
  ShareLinkRateLimitedError,
  ShareLinkTotalQuotaExceededError,
} from '../errors';
// The same PostgrestError subset and the same HINT parser the write mapping
// uses: 0012's, 0016's and 0019's backoff contracts are the identical
// `retry_after_seconds=N`, so there is one implementation of it, not three.
import { parseRetryAfterSeconds, type WriteErrorLike } from './eventWriteError';

export function mapShareLinkError(error: WriteErrorLike): Error {
  switch (error.details) {
    // 0016. Revoking frees an active slot, and the UI offers it.
    case 'TIMEWEAVE_QUOTA_SHARE_LINKS_ACTIVE':
      return new ShareLinkActiveQuotaExceededError();
    // 0016. Revoked rows still count; only deleting frees capacity, and this
    // app has no delete action, so the class says what will not work instead.
    case 'TIMEWEAVE_QUOTA_SHARE_LINKS_TOTAL':
      return new ShareLinkTotalQuotaExceededError();
    // 0016. The wait comes from HINT; a missing or malformed one costs the
    // owner a precise number, never the correct error.
    case 'TIMEWEAVE_RATE_SHARE_LINKS':
      return new ShareLinkRateLimitedError(parseRetryAfterSeconds(error.hint));
    default:
      return new Error(error.message ?? 'Unknown database error');
  }
}
