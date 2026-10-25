import { isoFromDatetimeLocalValue } from '../../utils/datetime';
import { checkWallTime, foldInstant, type FoldChoice, type WallTimeCheck } from '../event/formInstant';

/**
 * What the share-link expiry field means, before it is sent to
 * create_share_link (P8-c3 / P8-c3.1, docs/p8-datetime-contract.md §13-§14).
 *
 *   none          the field is empty: the link does not expire (unchanged)
 *   instant       the instant to store in share_links.expires_at
 *   gap           the wall clock does not exist in the browser's zone --
 *                 REFUSED (P8-c3). `new Date(value)` used to move it an hour
 *                 LATER, so the link outlived what was typed.
 *   foldUnchosen  the wall clock happens twice and the owner has not said which
 *                 -- REFUSED until they do (E1, P8-c3.1). It used to take the
 *                 1st silently.
 *   past          the chosen instant is not in the future -- REFUSED before the
 *                 RPC (E3). The database CHECK (expires_at > created_at) stays
 *                 the real boundary; this only spares the owner a generic error,
 *                 and is re-run with a fresh `now` when Create is pressed.
 *
 * `fold` rides along on instant / past when the wall clock is a fold, so the
 * dialog can keep showing the choice that produced the instant.
 *
 * THE ZONE is the browser's (getUserTimeZone), as it always was (E2): the
 * field is a native datetime-local, the list shows the same zone, and the
 * server compares only instants. A pick is bound to the wall clock AND the zone
 * it was made for, so it never carries over to an edited value or to a zone
 * the device has moved to since: either change asks again.
 */
type GapCheck = Extract<WallTimeCheck, { kind: 'gap' }>;
type FoldCheck = Extract<WallTimeCheck, { kind: 'fold' }>;

export interface ShareExpiryPick {
  local: string;
  timeZone: string;
  choice: FoldChoice;
}

export type ShareExpiry =
  | { kind: 'none' }
  | { kind: 'instant'; iso: string; fold?: { check: FoldCheck; choice: FoldChoice } }
  | { kind: 'gap'; check: GapCheck }
  | { kind: 'foldUnchosen'; check: FoldCheck }
  | { kind: 'past'; iso: string; fold?: { check: FoldCheck; choice: FoldChoice } };

export function shareExpiryFromLocal(
  local: string,
  timeZone: string,
  pick: ShareExpiryPick | null = null,
  nowMs: number = Date.now(),
): ShareExpiry {
  if (!local) return { kind: 'none' };
  const check = checkWallTime(local, timeZone);
  if (check.kind === 'gap') return { kind: 'gap', check };

  let iso: string;
  let fold: { check: FoldCheck; choice: FoldChoice } | undefined;
  if (check.kind === 'fold') {
    const choice = pick && pick.local === local && pick.timeZone === timeZone ? pick.choice : null;
    const chosen = foldInstant(check, choice);
    if (chosen === null || choice === null) return { kind: 'foldUnchosen', check };
    iso = chosen;
    fold = { check, choice };
  } else {
    iso = isoFromDatetimeLocalValue(local);
  }

  if (Date.parse(iso) <= nowMs) return fold ? { kind: 'past', iso, fold } : { kind: 'past', iso };
  return fold ? { kind: 'instant', iso, fold } : { kind: 'instant', iso };
}

/** The fold the field is on, chosen or not, so its choice can be shown. */
export function shareExpiryFold(e: ShareExpiry): FoldCheck | null {
  if (e.kind === 'foldUnchosen') return e.check;
  if ((e.kind === 'instant' || e.kind === 'past') && e.fold) return e.fold.check;
  return null;
}
