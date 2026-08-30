/**
 * Expand a set of stored event rows into concrete occurrences within a range.
 *
 * Row kinds handled uniformly:
 *  - one-off   (rrule === null, recurrenceId === null)
 *  - master    (rrule !== null)  -> expanded via services/recurrence
 *  - exception (recurrenceId !== null) -> overrides/cancels one master slot
 *
 * Timed rows use startAt/endAt; all-day rows use startDate/endDate (end
 * exclusive, converted to local-midnight instants for uniform sorting/grouping).
 *
 * An exception identifies the master slot it replaces via a type-safe slot key
 * (recurrenceSlotStart for timed, recurrenceSlotDate for all-day). Matching
 * generated occurrences are dropped; non-cancelled exceptions are then emitted
 * at their own time. Cancelled exceptions only detach a slot (a deletion).
 *
 * Pure logic — no React/DB dependency, so it is directly unit-testable.
 */

import type { EventOccurrence, EventRow } from '../types/event';
import { fromIso, isoFromDateString, localDayKey, toIso } from '../utils/datetime';
import { expandRule } from './recurrence';

/** Resolve a row's concrete time span to UTC ISO instants, regardless of all-day. */
function rowSpan(row: EventRow): { start: string; end: string } {
  if (row.allDay) {
    return { start: isoFromDateString(row.startDate!), end: isoFromDateString(row.endDate!) };
  }
  return { start: row.startAt!, end: row.endAt! };
}

/** The slot key an exception row points at (identifies a master occurrence). */
function exceptionSlotKey(ex: EventRow): string | null {
  return ex.allDay ? ex.recurrenceSlotDate : ex.recurrenceSlotStart;
}

/** The slot key of a generated master occurrence starting at `startIso`. */
function occurrenceSlotKey(startIso: string, allDay: boolean): string {
  return allDay ? localDayKey(startIso) : startIso;
}

/**
 * The single comparison key both the exception side and the generated side pass
 * through before matching. Timed keys are normalized to their instant value so
 * that different ISO textual forms of the same moment still match — notably a
 * `timestamptz` DB round-trip ("2026-09-14T00:00:00+00:00", milliseconds
 * dropped) vs. the expander's `toISOString()` ("2026-09-14T00:00:00.000Z").
 * All-day keys compare verbatim as "YYYY-MM-DD". Returns null for a missing or
 * unparseable timed value, so a bad key never silently collides with another.
 */
export function normalizedSlotKey(value: string | null, allDay: boolean): string | null {
  if (value === null) return null;
  if (allDay) return value;
  const t = new Date(value).getTime();
  return Number.isNaN(t) ? null : String(t);
}

/**
 * @param events all rows that could be relevant to the range
 * @param rangeStartIso inclusive UTC ISO
 * @param rangeEndIso exclusive UTC ISO
 */
export function expandEvents(
  events: EventRow[],
  rangeStartIso: string,
  rangeEndIso: string,
): EventOccurrence[] {
  const rangeStart = fromIso(rangeStartIso).getTime();
  const rangeEnd = fromIso(rangeEndIso).getTime();

  const exceptionsByMaster = new Map<string, EventRow[]>();
  for (const ev of events) {
    if (ev.recurrenceId) {
      const list = exceptionsByMaster.get(ev.recurrenceId) ?? [];
      list.push(ev);
      exceptionsByMaster.set(ev.recurrenceId, list);
    }
  }

  const overlapsRange = (start: string, end: string): boolean =>
    fromIso(end).getTime() > rangeStart && fromIso(start).getTime() < rangeEnd;

  const out: EventOccurrence[] = [];

  for (const ev of events) {
    if (ev.recurrenceId) continue; // exceptions are emitted alongside their master

    const span = rowSpan(ev);

    if (!ev.rrule) {
      if (overlapsRange(span.start, span.end)) {
        out.push({
          event: ev,
          start: span.start,
          end: span.end,
          allDay: ev.allDay,
          occurrenceKey: occurrenceSlotKey(span.start, ev.allDay),
          isException: false,
        });
      }
      continue;
    }

    // Recurring master.
    const durationMs = fromIso(span.end).getTime() - fromIso(span.start).getTime();
    const exceptions = exceptionsByMaster.get(ev.id) ?? [];
    const detached = new Set<string>();
    for (const ex of exceptions) {
      const norm = normalizedSlotKey(exceptionSlotKey(ex), ex.allDay);
      if (norm) detached.add(norm);
    }

    const starts = expandRule(ev.rrule, span.start, rangeStartIso, rangeEndIso);
    for (const startIso of starts) {
      const key = occurrenceSlotKey(startIso, ev.allDay);
      const norm = normalizedSlotKey(key, ev.allDay);
      if (norm !== null && detached.has(norm)) continue; // deleted or replaced slot
      out.push({
        event: ev,
        start: startIso,
        end: toIso(new Date(fromIso(startIso).getTime() + durationMs)),
        allDay: ev.allDay,
        occurrenceKey: key,
        isException: false,
      });
    }

    // Emit modified (non-cancelled) exceptions that land in the range.
    for (const ex of exceptions) {
      if (ex.isCancelled) continue;
      const exSpan = rowSpan(ex);
      if (overlapsRange(exSpan.start, exSpan.end)) {
        const slotKey = exceptionSlotKey(ex);
        out.push({
          event: ex,
          start: exSpan.start,
          end: exSpan.end,
          allDay: ex.allDay,
          occurrenceKey: slotKey ?? occurrenceSlotKey(exSpan.start, ex.allDay),
          isException: true,
        });
      }
    }
  }

  out.sort((a, b) => a.start.localeCompare(b.start));
  return out;
}
