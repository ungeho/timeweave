/**
 * Data access for share links and Free/Busy, via the Phase 5a SECURITY DEFINER
 * RPCs (see supabase/migrations/0005). The UI never touches share_links or the
 * events table directly; anonymous viewers reach only get_free_busy.
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
}

function mapLink(row: ShareLinkDbRow): ShareLink {
  return {
    id: row.id,
    label: row.label,
    includePrivate: row.include_private,
    expiresAt: row.expires_at,
    revokedAt: row.revoked_at ?? null,
    createdAt: row.created_at,
  };
}

export interface CreateShareLinkInput {
  label?: string | null;
  includePrivate?: boolean;
  expiresAt?: string | null;
}

/**
 * Failures go through mapShareLinkError, so 0016's two quota refusals and its
 * create-rate refusal reach the dialog as domain errors instead of the server's
 * message -- which formats the owner's UUID and the configured ceilings into
 * its text. Everything else still surfaces that message unchanged.
 *
 * Only this RPC needs it: 0016's quota trigger checks only owners whose count
 * RISES, so revoke (an UPDATE that lowers) and list cannot raise those refusals,
 * and the create-rate trigger is INSERT-only.
 */
export async function createShareLink(input: CreateShareLinkInput = {}): Promise<CreatedShareLink> {
  const { data, error } = await requireSupabase().rpc('create_share_link', {
    p_label: input.label ?? null,
    p_include_private: input.includePrivate ?? true,
    p_expires_at: input.expiresAt ?? null,
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

export async function revokeShareLink(id: string): Promise<boolean> {
  const { data, error } = await requireSupabase().rpc('revoke_share_link', { p_id: id });
  if (error) throw new Error(error.message);
  return Boolean(data);
}

/** Raw slot shape from get_free_busy's jsonb (snake_case, discriminated on all_day). */
type FreeBusySlotDb =
  | { all_day: false; start: string; end: string }
  | { all_day: true; start_date: string; end_date: string };

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
  const result = (data ?? {}) as { complete?: boolean; slots?: FreeBusySlotDb[] };
  return {
    complete: Boolean(result.complete),
    slots: (result.slots ?? []).map(mapSlot),
  };
}
