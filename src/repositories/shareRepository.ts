/**
 * Data access for share links and Free/Busy, via the Phase 5a SECURITY DEFINER
 * RPCs (see supabase/migrations/0005) plus delete_share_link (0015) and
 * set_share_available (0022). The UI never touches share_links or the events
 * table directly; anonymous viewers reach only get_free_busy.
 *
 * Only available in Supabase mode (sharing needs auth + the DB functions).
 */

import { requireSupabase } from '../lib/supabase';
import { mapFreeBusyError } from './freeBusyError';
import { mapShareLinkError } from './shareLinkError';
import type {
  CreatedShareLink,
  FreeBusyResult,
  FreeBusySlot,
  ShareLink,
} from '../types/share';

/** Row shape from list_share_links / create_share_link (snake_case). */
interface ShareLinkDbRow {
  id: string;
  label: string | null;
  include_private: boolean;
  expires_at: string | null;
  revoked_at?: string | null; // create_share_link does not return it (always null then)
  created_at: string;
  // 0022. Both functions return it once that migration is applied; optional here
  // for the same reason revoked_at is -- a row can arrive without it, in this
  // case from a database where 0022 has not run yet.
  share_available?: boolean | null;
}

function mapLink(row: ShareLinkDbRow): ShareLink {
  return {
    id: row.id,
    label: row.label,
    includePrivate: row.include_private,
    expiresAt: row.expires_at,
    revokedAt: row.revoked_at ?? null,
    createdAt: row.created_at,
    // Coerced, not passed through. 0022's column is NOT NULL, so a missing or
    // null value here means the RPC did not return it, and the safe reading of
    // "unknown" is NOT opted in: the alternative would have an old database
    // present every link as sharing available time.
    shareAvailable: row.share_available === true,
  };
}

export interface CreateShareLinkInput {
  label?: string | null;
  includePrivate?: boolean;
  expiresAt?: string | null;
  /**
   * Opt in to sharing available time (0022). Omitted means false, matching the
   * RPC parameter's own default, so an existing caller creates an opted-out link
   * without changing anything.
   */
  shareAvailable?: boolean;
}

/**
 * Failures go through mapShareLinkError, so 0016's two quota refusals and its
 * create-rate refusal reach the dialog as domain errors instead of the server's
 * message -- which formats the owner's UUID and the configured ceilings into
 * its text. Everything else still surfaces that message unchanged.
 *
 * Only this RPC needs it: 0016's quota trigger checks only owners whose count
 * RISES, so revoke (an UPDATE that lowers) and list cannot raise those refusals;
 * the create-rate trigger is INSERT-only; and delete fires no trigger at all.
 */
export async function createShareLink(input: CreateShareLinkInput = {}): Promise<CreatedShareLink> {
  const { data, error } = await requireSupabase().rpc('create_share_link', {
    p_label: input.label ?? null,
    p_include_private: input.includePrivate ?? true,
    p_expires_at: input.expiresAt ?? null,
    p_share_available: input.shareAvailable ?? false,
  });
  if (error) throw mapShareLinkError(error);
  // Returns a single-row table.
  const row = (Array.isArray(data) ? data[0] : data) as (ShareLinkDbRow & { token: string }) | undefined;
  if (!row) throw new Error('create_share_link returned no row');
  return { ...mapLink(row), token: row.token };
}

export async function listShareLinks(): Promise<ShareLink[]> {
  const { data, error } = await requireSupabase().rpc('list_share_links');
  if (error) throw new Error(error.message);
  return ((data ?? []) as ShareLinkDbRow[]).map(mapLink);
}

/**
 * Turn available-time sharing on or off for one of the caller's ACTIVE links
 * (migration 0022). The only way to change the setting after creation:
 * includePrivate, expiresAt and label remain creation-only, and there is no
 * generic link update.
 *
 * `false` is not a failure and must not be thrown -- it is 0022's uniform answer
 * for an id that does not exist, one owned by somebody else, one that is
 * revoked, and one that is expired, deliberately so the function cannot be used
 * to probe other owners' primary keys. It is also NOT "nothing changed": the RPC
 * is idempotent, so setting the value a link already holds returns true. The
 * caller decides what to say about false; here it is just the value.
 *
 * Only an unauthenticated call raises (28000). mapShareLinkError is NOT applied,
 * for revokeShareLink's reason: 0016's quota trigger selects only owners whose
 * count RISES and this UPDATE moves no count, and the create-rate trigger is
 * INSERT-only, so none of that module's refusals can reach here.
 */
export async function setShareAvailable(id: string, enabled: boolean): Promise<boolean> {
  const { data, error } = await requireSupabase().rpc('set_share_available', {
    p_id: id,
    p_enabled: enabled,
  });
  if (error) throw new Error(error.message);
  return Boolean(data);
}

export async function revokeShareLink(id: string): Promise<boolean> {
  const { data, error } = await requireSupabase().rpc('revoke_share_link', { p_id: id });
  if (error) throw new Error(error.message);
  return Boolean(data);
}

/**
 * Physically remove one of the caller's REVOKED links (migration 0015).
 *
 * `false` is not a failure and must not be thrown: 0015 returns it, uniformly,
 * for an id that does not exist, one owned by somebody else, and one that is
 * still active -- deliberately, so the function cannot be used to probe other
 * owners' primary keys. The caller decides what to say about it; here it is
 * just the value. Only an unauthenticated call raises (28000), and that
 * propagates exactly as revokeShareLink's does.
 *
 * mapShareLinkError is NOT applied. 0016 hangs its quota trigger on INSERT and
 * UPDATE and its create-rate trigger on INSERT; DELETE has no trigger at all,
 * so none of that module's three markers can reach this call, and routing
 * through it would only invite the belief that they can.
 */
export async function deleteShareLink(id: string): Promise<boolean> {
  const { data, error } = await requireSupabase().rpc('delete_share_link', { p_id: id });
  if (error) throw new Error(error.message);
  return Boolean(data);
}

/** Raw slot shape from get_free_busy's jsonb (snake_case, discriminated on all_day). */
type FreeBusySlotDb =
  | { all_day: false; start: string; end: string }
  | { all_day: true; start_date: string; end_date: string };

/**
 * Raw shape from get_free_busy (snake_case). `link_state` is typed as a plain
 * string, NOT as PublicLinkState: it arrives from the wire, a pre-0023 backend
 * omits it entirely, and a later backend could send a value this build has
 * never heard of. Narrowing happens once, in getFreeBusy, rather than being
 * asserted here.
 */
interface FreeBusyDbResult {
  link_state?: string | null;
  complete?: boolean;
  slots?: FreeBusySlotDb[];
}

function mapSlot(s: FreeBusySlotDb): FreeBusySlot {
  return s.all_day
    ? { allDay: true, startDate: s.start_date, endDate: s.end_date }
    : { allDay: false, start: s.start, end: s.end };
}

/**
 * Anonymous Free/Busy for a share token over a window. Timed events use the
 * instant window (from/to, UTC ISO); all-day events use the date window
 * (fromDate/toDate, "YYYY-MM-DD", half-open) with no timezone conversion. The
 * caller must keep the window within 92 days (the RPC rejects longer).
 *
 * Failures go through mapFreeBusyError, so 0019's two rate-limit refusals reach
 * the page as FreeBusyRateLimitedError instead of a bare message. Everything
 * else -- the 92-day 22023 included -- still surfaces the server's message
 * unchanged. The other RPCs in this module keep their plain mapping; their
 * markers (0011's and 0016's share-link quotas and rate) are a separate change.
 */
export async function getFreeBusy(
  token: string,
  from: string,
  to: string,
  fromDate: string,
  toDate: string,
): Promise<FreeBusyResult> {
  const { data, error } = await requireSupabase().rpc('get_free_busy', {
    p_token: token,
    p_from: from,
    p_to: to,
    p_from_date: fromDate,
    p_to_date: toDate,
  });
  if (error) throw mapFreeBusyError(error);
  const result = (data ?? {}) as FreeBusyDbResult;
  return {
    // 0023. ONLY the exact string 'unavailable' hides content. Missing, null
    // and any unrecognised value all read as 'active', and the asymmetry is the
    // point: a pre-0023 backend sends no link_state at all, and treating that
    // as unavailable would hide a genuinely active owner's busy times behind an
    // error-looking page. The opposite mistake is harmless -- an unavailable
    // answer carries complete=true and slots=[], so reading it as active just
    // reproduces what the page did before 0023 existed.
    linkState: result.link_state === 'unavailable' ? 'unavailable' : 'active',
    complete: Boolean(result.complete),
    slots: (result.slots ?? []).map(mapSlot),
  };
}
