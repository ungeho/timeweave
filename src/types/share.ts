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
   * NOTHING READS IT YET. The anonymous Free/Busy response is unchanged whatever
   * this is set to, so `true` currently means only "the owner has opted in",
   * never "open time is being shown".
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
 * Free/Busy over a window. `complete` is false when the owner has recurring
 * events the Phase 5a RPC cannot yet expand: the shown busy blocks are valid,
 * but times NOT shown must NOT be assumed free.
 *
 * `linkState` is REQUIRED even though the database may omit it: a response from
 * a pre-0023 backend is normalised to 'active' at the repository boundary, so
 * every value reaching the UI is one of the two states. See shareRepository.
 */
export interface FreeBusyResult {
  linkState: PublicLinkState;
  complete: boolean;
  slots: FreeBusySlot[];
}
