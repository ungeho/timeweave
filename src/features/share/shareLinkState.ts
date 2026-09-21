/**
 * The lifecycle rules a share link is drawn and acted on by, as pure functions.
 *
 * WHY THIS IS A MODULE AND NOT THREE EXPRESSIONS IN THE DIALOG. One of these
 * rules is load-bearing and easy to get subtly wrong:
 *
 *   migration 0015's delete_share_link deletes only a row whose `revoked_at is
 *   not null`, and that condition lives inside the DELETE's own WHERE clause.
 *
 * So "may be deleted" is EXACTLY "revoked", and it is NOT "looks inactive in
 * the list". An EXPIRED link still has revoked_at = null: it is greyed out, its
 * URL no longer works, and the RPC would refuse to delete it -- silently, with
 * the same `false` it returns for a row that never existed. Offering a delete
 * button on such a row would be offering an action that quietly does nothing.
 * The rule is a named function with tests so that stays impossible, since this
 * project has no way to test the component that renders it (vitest runs with
 * environment: 'node'; there is no jsdom and none may be added).
 */

import type { ShareLink } from '../../types/share';

/** The three states a link can be in, in lifecycle order. */
export type ShareLinkStatus = 'active' | 'expired' | 'revoked';

/**
 * Revocation wins over expiry: a revoked link that also happens to be past its
 * expiry is revoked, because revoked is the state that decides what the owner
 * may do next. `now` is a parameter rather than a call to Date.now() so the
 * boundary is testable.
 *
 * An unparseable expires_at yields NaN and every comparison with it is false,
 * so such a row reads as 'active'. That is the behaviour this list has always
 * had, and it errs towards showing the owner a link they can still revoke
 * rather than hiding it as already dead.
 */
export function shareLinkStatus(link: ShareLink, now: number): ShareLinkStatus {
  if (link.revokedAt !== null) return 'revoked';
  if (link.expiresAt !== null && Date.parse(link.expiresAt) <= now) return 'expired';
  return 'active';
}

/**
 * Whether delete_share_link would actually remove this row.
 *
 * This mirrors the RPC's predicate and nothing else. It deliberately does not
 * consider expiry, because the database does not: active -> revoke -> delete is
 * the only order in which a row can leave share_links.
 */
export function canDeleteShareLink(link: ShareLink): boolean {
  return link.revokedAt !== null;
}

/**
 * The rows the list shows. `revokedOnly` is the owner's filter, applied to rows
 * already fetched -- list_share_links takes no arguments and orders by
 * created_at desc, so the revoked rows worth deleting sit at the bottom of a
 * list that may hold up to share_links_max_total_per_owner() of them.
 *
 * Returns the same array instance when the filter is off, so an unfiltered
 * render does not allocate.
 */
export function visibleShareLinks(links: ShareLink[], revokedOnly: boolean): ShareLink[] {
  return revokedOnly ? links.filter(canDeleteShareLink) : links;
}
