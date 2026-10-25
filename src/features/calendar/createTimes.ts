import { addDaysToDateString } from '../../utils/datetime';
import {
  classifyZonedWallClock,
  dayStartInstantIso,
  zonedDayKey,
  zonedWallClockOf,
} from '../../utils/timezone';

/**
 * One end of a new event's initial time: the wall clock the form shows
 * ("YYYY-MM-DDTHH:mm") and the instant it stands for -- or null when that wall
 * clock does not name exactly one instant and the owner has to settle it in
 * the form (its DST notice says why; docs/p8-datetime-contract.md §3).
 */
export interface CreateTime {
  local: string;
  at: string | null;
}

export interface CreateTimes {
  start: CreateTime;
  end: CreateTime;
}

/** A new event lasts one hour of elapsed time. */
const DEFAULT_DURATION_MS = 60 * 60 * 1000;

const pad = (n: number, w = 2) => String(n).padStart(w, '0');

function localOfInstant(ms: number, timeZone: string): string {
  const w = zonedWallClockOf(ms, timeZone);
  return `${pad(w.year, 4)}-${pad(w.month)}-${pad(w.day)}T${pad(w.hour)}:${pad(w.minute)}`;
}

/** The wall clock `minutes` after the start of `dayKey`; 1470 is 00:30 the next date. */
function wallAt(dayKey: string, minutes: number) {
  const day = addDaysToDateString(dayKey, Math.floor(minutes / 1440));
  const m = ((minutes % 1440) + 1440) % 1440;
  const [y, mo, d] = day.split('-').map(Number) as [number, number, number];
  return {
    local: `${day}T${pad(Math.floor(m / 60))}:${pad(m % 60)}`,
    wall: { year: y, month: mo, day: d, hour: Math.floor(m / 60), minute: m % 60, second: 0, ms: 0 },
  };
}

/**
 * The initial start and end for an event created from a click on `dayKey` at
 * `minutes` past midnight (a week/day time slot, or the month cell's and the
 * mobile button's 09:00). R1-P, docs/p8-datetime-contract.md §10.
 *
 * The click names a WALL CLOCK on a DATE -- the grid is a 24-hour wall axis --
 * so the date is never changed and a time is never moved silently:
 *   - names one instant: that instant (what it always was)
 *   - does not exist, and nothing on that date comes before it (the date
 *     itself starts late, e.g. America/Havana 2026-03-08 begins at 01:00):
 *     the date's first instant. The old code took the previous evening.
 *   - does not exist in mid-day, happens twice, or the whole date never
 *     happened: the clicked wall clock with no instant; the form explains a
 *     gap and asks which of two, as it does for typed times
 * The end is one elapsed hour after a resolved start (it was the wall clock an
 * hour later, which made the 23:30 slot end at 00:30 of the same date), else
 * the wall clock an hour later, checked the same way.
 */
export function createTimesAt(dayKey: string, minutes: number, timeZone: string): CreateTimes {
  const clicked = wallAt(dayKey, minutes);
  const c = classifyZonedWallClock(clicked.wall, timeZone);

  let startMs: number | null = null;
  if (c.kind === 'normal') {
    startMs = c.instantMs;
  } else if (
    c.kind === 'gap'
    && Date.parse(dayStartInstantIso(dayKey, timeZone)) === c.firstAfterMs
    && zonedDayKey(new Date(c.firstAfterMs).toISOString(), timeZone) === dayKey
  ) {
    startMs = c.firstAfterMs;
  }

  if (startMs !== null) {
    const endMs = startMs + DEFAULT_DURATION_MS;
    return {
      start: { local: localOfInstant(startMs, timeZone), at: new Date(startMs).toISOString() },
      end: { local: localOfInstant(endMs, timeZone), at: new Date(endMs).toISOString() },
    };
  }

  const end = wallAt(dayKey, minutes + 60);
  const ce = classifyZonedWallClock(end.wall, timeZone);
  return {
    start: { local: clicked.local, at: null },
    end: { local: end.local, at: ce.kind === 'normal' ? new Date(ce.instantMs).toISOString() : null },
  };
}
