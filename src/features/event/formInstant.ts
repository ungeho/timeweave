/**
 * The event form's wall clock -> instant step, with the DST cases the old
 * single call could not see (P8-b5.6b-2, docs/p8-datetime-contract.md).
 *
 * WHAT DOES NOT CHANGE. A wall clock that names exactly one instant is still
 * converted by `isoFromDatetimeLocalValue` -- the same call, the same result,
 * byte for byte. This module only steps in where that call silently decides:
 *
 *   gap  -- the time does not exist (clocks jumped forward). `new Date` used to
 *           save it an hour later without a word. Now: refused.
 *   fold -- the time happens twice (clocks went back). `new Date` always took
 *           the 1st, so re-saving an event stored at the 2nd moved it an hour
 *           even when the owner never touched the time. Now: the owner picks,
 *           and an existing event's pick is recovered from its stored instant.
 *
 * TWO WITNESSES, OR NO INTERVENTION. The class comes from Intl in the zone the
 * calendar renders in (`timeZone`, which is getUserTimeZone()); the save comes
 * from `Date`, which reads the runtime's local zone. They are the same zone on
 * every normal setup, but a runtime can report one name to Intl and resolve
 * Date with another. So a gap is acted on only when Date ALSO moves the wall
 * clock, and a fold only when Date ALSO shows both candidates as this wall
 * clock. Otherwise the old conversion runs unchanged: a wrong refusal would
 * block a save, which is worse than the old silent behaviour.
 */
import { isoFromDatetimeLocalValue, toDatetimeLocalValue } from '../../utils/datetime';
import { classifyZonedWallClock, zoneAbbreviation, zoneOffsetMinutesAt } from '../../utils/timezone';

export type FoldChoice = 'earlier' | 'later';

/** One side of a fold, ready to show: "01:30 EDT (UTC−04:00)". */
export interface FoldOption {
  choice: FoldChoice;
  iso: string;
  offsetMinutes: number;
  abbreviation: string;
}

export type WallTimeCheck =
  | { kind: 'normal' }
  | { kind: 'gap'; lastBefore: string; firstAfter: string; gapMinutes: number }
  | { kind: 'fold'; options: [FoldOption, FoldOption] };

const LOCAL_RE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/;

function option(choice: FoldChoice, ms: number, timeZone: string): FoldOption {
  return {
    choice,
    iso: new Date(ms).toISOString(),
    offsetMinutes: zoneOffsetMinutesAt(ms, timeZone),
    abbreviation: zoneAbbreviation(ms, timeZone),
  };
}

/** Classify a "YYYY-MM-DDTHH:mm" wall clock. Anything unparseable is 'normal' (the old checks handle it). */
export function checkWallTime(local: string, timeZone: string): WallTimeCheck {
  const m = LOCAL_RE.exec(local);
  if (!m) return { kind: 'normal' };
  const [, y, mo, d, h, mi] = m.map(Number) as number[];
  let c;
  try {
    c = classifyZonedWallClock({ year: y!, month: mo!, day: d!, hour: h!, minute: mi!, second: 0, ms: 0 }, timeZone);
  } catch {
    return { kind: 'normal' };
  }
  if (c.kind === 'normal') return { kind: 'normal' };

  if (c.kind === 'gap') {
    // Witness 2: Date must also fail to keep this wall clock.
    let dateKeeps = true;
    try {
      dateKeeps = toDatetimeLocalValue(isoFromDatetimeLocalValue(local)) === local;
    } catch {
      return { kind: 'normal' };
    }
    if (dateKeeps) return { kind: 'normal' };
    return {
      kind: 'gap',
      lastBefore: toDatetimeLocalValue(new Date(c.lastBeforeMs).toISOString()),
      firstAfter: toDatetimeLocalValue(new Date(c.firstAfterMs).toISOString()),
      gapMinutes: c.gapMinutes,
    };
  }

  // Witness 2: both candidates must read back as this wall clock through Date.
  const earlierIso = new Date(c.earlierMs).toISOString();
  const laterIso = new Date(c.laterMs).toISOString();
  if (toDatetimeLocalValue(earlierIso) !== local || toDatetimeLocalValue(laterIso) !== local) {
    return { kind: 'normal' };
  }
  return { kind: 'fold', options: [option('earlier', c.earlierMs, timeZone), option('later', c.laterMs, timeZone)] };
}

export type FormInstant =
  | { ok: true; iso: string }
  | { ok: false; reason: 'gap' | 'foldUnchosen' };

/**
 * The instant to save for a wall clock. 'normal' is EXACTLY the old
 * conversion. Throws (like isoFromDatetimeLocalValue) on an unparseable value,
 * which the dialog's empty check rules out first.
 */
export function formInstant(local: string, timeZone: string, choice: FoldChoice | null): FormInstant {
  const check = checkWallTime(local, timeZone);
  if (check.kind === 'gap') return { ok: false, reason: 'gap' };
  if (check.kind === 'fold') {
    const iso = foldInstant(check, choice);
    return iso === null ? { ok: false, reason: 'foldUnchosen' } : { ok: true, iso };
  }
  return { ok: true, iso: isoFromDatetimeLocalValue(local) };
}

/** The instant a fold choice names, or null while unchosen. Shared with the dialog. */
export function foldInstant(check: Extract<WallTimeCheck, { kind: 'fold' }>, choice: FoldChoice | null): string | null {
  if (!choice) return null;
  return check.options[choice === 'earlier' ? 0 : 1].iso;
}

/**
 * Which side of a fold a STORED instant is, so reopening an event restores the
 * owner's earlier choice instead of asking again (and instead of the old
 * behaviour of silently taking the 1st). null when the instant's wall clock is
 * not a fold.
 */
export function storedFoldChoice(iso: string, timeZone: string): FoldChoice | null {
  const local = toDatetimeLocalValue(iso);
  const check = checkWallTime(local, timeZone);
  if (check.kind !== 'fold') return null;
  const ms = Date.parse(iso);
  if (Date.parse(check.options[0].iso) === ms) return 'earlier';
  if (Date.parse(check.options[1].iso) === ms) return 'later';
  return null;
}

/** "UTC−04:00" */
export function formatUtcOffset(minutes: number): string {
  const sign = minutes < 0 ? '−' : '+';
  const a = Math.abs(minutes);
  return `UTC${sign}${String(Math.floor(a / 60)).padStart(2, '0')}:${String(a % 60).padStart(2, '0')}`;
}
