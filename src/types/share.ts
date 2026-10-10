/**
 * Types for share links and anonymous Free/Busy (Phase 5a).
 *
 * A share link exposes ONLY availability, never event details. The RPC returns a
 * discriminated union of slots matching TimeWeave's two time models:
 *   - timed  : UTC ISO instants (start/end)
 *   - all-day: local calendar dates (startDate/endDate, end EXCLUSIVE), never
 *              timezone-converted.
 */

export interface ShareLink {
  id: string;
  label: string | null;
  includePrivate: boolean;
  expiresAt: string | null; // UTC ISO, null = no expiry
  revokedAt: string | null; // UTC ISO, null = active
  createdAt: string;
  /**
   * Whether this link may disclose the owner's AVAILABLE time as well as the
   * busy time it has always disclosed (migration 0022). Independent of
   * includePrivate: that one decides whether private events participate at all,
   * this one decides whether open time is shared. All four combinations are
   * legal.
   *
   * Since 0024 this is READ as well as stored: a link with it off answers
   * `available: { status: 'not_requested' }`, and one with it on gets the
   * computed result. It is still only an opt-in, never a promise that anything
   * was disclosed -- an opted-in link over a week with no available events
   * answers `complete` with an empty array.
   */
  shareAvailable: boolean;
}

/** Result of creating a link: the plaintext token is present exactly once. */
export interface CreatedShareLink extends ShareLink {
  /** Plaintext token for the share URL. Only ever returned at creation time. */
  token: string;
}

/** One opaque busy block. No title/id/category — availability only. */
export type FreeBusySlot =
  | { allDay: false; start: string; end: string }        // UTC ISO instants
  | { allDay: true; startDate: string; endDate: string }; // "YYYY-MM-DD", end exclusive

/**
 * What the anonymous API says about the link itself (migration 0023).
 *
 * `unavailable` is the ONE answer for every reason a link cannot be read --
 * expired, revoked, deleted, never existed, unknown or malformed token. The
 * reason is deliberately not disclosed and must never be reconstructed here or
 * shown to a viewer. `active` says only that the link can be read; it says
 * nothing about whether anything was disclosed for the requested window.
 */
export type PublicLinkState = 'active' | 'unavailable';

/**
 * What the link discloses about the owner's AVAILABLE time (migration 0024).
 *
 * THE THREE STATES ARE NOT THREE SHADES OF "FREE", and the middle one is the
 * reason this is a union rather than a nullable slot array:
 *
 *   not_requested  The link is not opted in (share_available off), so nothing
 *                  was computed and nothing is claimed. NOT "no free time" --
 *                  the question was never asked. Also what a pre-0024 backend's
 *                  silence is read as.
 *   indeterminate  The link IS opted in, but the window holds something 0024
 *                  cannot subtract exactly -- an unexpandable recurrence in
 *                  either the available or the busy set. The honest answer is
 *                  that open time cannot be stated, and NO slots come with it.
 *                  Rendering this as "no availability" would turn "we don't
 *                  know" into a factual claim about the owner's calendar.
 *   complete       An exact computation. `slots` is what it found, and an EMPTY
 *                  array is a real answer: no available time was disclosed for
 *                  this window.
 *
 * AVAILABLE IS NEVER THE COMPLEMENT OF BUSY. These slots come only from events
 * the owner explicitly marked available, with busy subtracted from them; the
 * gaps between busy blocks are not available time and must never be rendered as
 * such. That is the whole reason the backend computes this instead of letting
 * the client invert `slots`.
 */
export type AvailableResult =
  | { status: 'not_requested' }
  | { status: 'indeterminate' }
  | { status: 'complete'; slots: FreeBusySlot[] };

/**
 * Free/Busy over a window. `complete` is false when the owner has recurring
 * events the Phase 5a RPC cannot yet expand: the shown busy blocks are valid,
 * but times NOT shown must NOT be assumed free.
 *
 * `linkState` is REQUIRED even though the database may omit it: a response from
 * a pre-0023 backend is normalised to 'active' at the repository boundary, so
 * every value reaching the UI is one of the two states. See shareRepository.
 *
 * `complete` and `slots` remain BUSY-ONLY, exactly as they were before 0024.
 * Available travels in its own field with its own completeness, because the two
 * computations fail independently: a window can have exact busy and
 * indeterminate available, or the reverse. Folding them into one flag would
 * make either answer silently speak for the other.
 */
export interface FreeBusyResult {
  linkState: PublicLinkState;
  complete: boolean;
  slots: FreeBusySlot[];
  /**
   * REQUIRED, like linkState and for the same reason: a pre-0024 backend omits
   * the field entirely and the repository normalises that to `not_requested`,
   * so every value reaching the UI is one of the three states.
   */
  available: AvailableResult;
}
