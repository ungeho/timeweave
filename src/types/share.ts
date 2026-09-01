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
 * Free/Busy over a window. `complete` is false when the owner has recurring
 * events the Phase 5a RPC cannot yet expand: the shown busy blocks are valid,
 * but times NOT shown must NOT be assumed free.
 */
export interface FreeBusyResult {
  complete: boolean;
  slots: FreeBusySlot[];
}
