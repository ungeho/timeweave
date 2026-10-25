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
 * The zone a master's expansion is anchored to: the row's own for a timed
 * master (events.timezone, null for a legacy M0), none for an all-day one.
 */
function expansionZone(master: EventRow): string | null {
  return master.allDay ? null : master.timezone;
}

/**
 * Masters whose rule this client cannot expand (K12, P8-finish-3a): a rule the
 * parser rejects (FREQ=YEARLY, COUNT with UNTIL, a malformed segment, an
 * unknown BYDAY ...) or a zone the expander rejects. The app never writes one
 * (the dialog builds every rule with formatRRule), but the database accepts any
 * text, so a row written another way can carry one.
 *
 * Independent of any range: `expandRule` parses the rule and reads DTSTART in
 * its zone before it looks at the window, so an empty window at DTSTART runs
 * exactly the steps that can fail and generates nothing.
 */
export function unexpandableMasters(events: EventRow[]): EventRow[] {
  const out: EventRow[] = [];
  for (const ev of events) {
    if (ev.recurrenceId || !ev.rrule) continue;
    const { start } = rowSpan(ev);
    try {
      expandRule(ev.rrule, start, start, start, expansionZone(ev));
    } catch {
      out.push(ev);
    }
  }
  return out;
}

export interface ExpandedEvents {
  occurrences: EventOccurrence[];
  /**
   * Masters left out because their rule could not be expanded, in row order.
   * Each is left out WITH every exception that points at it -- the series is
   * one unit: an exception opened on its own would load the master's rule into
   * the form, which cannot read it.
   */
  unexpandable: EventRow[];
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
  return expandEventsWithIssues(events, rangeStartIso, rangeEndIso).occurrences;
}

/**
 * expandEvents, plus the series it had to leave out. One series whose rule
 * cannot be expanded used to throw out of here and take the whole calendar
 * with it (K12); now that series is skipped and reported, and every other row
 * is expanded exactly as before. The share page does not use this: its
 * Busy/Available are the server's, which answers "incomplete" for such a row.
 */
export function expandEventsWithIssues(
  events: EventRow[],
  rangeStartIso: string,
  rangeEndIso: string,
): ExpandedEvents {
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
  const unexpandable: EventRow[] = [];

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

    // An occurrence is a SPAN, not a point: one that starts before the range can
    // still reach into it, which matters for multi-day events. `expandRule`
    // deliberately knows nothing about duration -- it answers "which starts fall
    // in this window" -- so the span logic belongs here, where durationMs lives.
    //
    // Ask the expander for a window widened left by the duration (the earliest
    // start that could still overlap), then apply the SAME half-open overlap test
    // one-off rows and exceptions already get. Widening only changes which starts
    // are collected: expansion always iterates from DTSTART, so COUNT, UNTIL and
    // the loop's break conditions are unaffected.
    // The zone a timed master's wall clock is anchored to travels with the ROW
    // (events.timezone), not with the view, so it is read here rather than
    // threaded down from the calendar. All-day masters pass null explicitly:
    // they are pure date arithmetic and a zone would be meaningless. A legacy
    // M0 master (timezone null) also passes null and keeps expanding in the
    // runtime's local zone, exactly as before Phase 5b-4.
    let starts: string[];
    try {
      starts = expandRule(
        ev.rrule,
        span.start,
        toIso(new Date(rangeStart - durationMs)),
        rangeEndIso,
        expansionZone(ev),
      );
    } catch {
      // The series is left out whole -- the exceptions are emitted below, after
      // this, so `continue` skips them too -- and reported to the caller.
      unexpandable.push(ev);
      continue;
    }
    for (const startIso of starts) {
      const endIso = toIso(new Date(fromIso(startIso).getTime() + durationMs));
      if (!overlapsRange(startIso, endIso)) continue;
      const key = occurrenceSlotKey(startIso, ev.allDay);
      const norm = normalizedSlotKey(key, ev.allDay);
      if (norm !== null && detached.has(norm)) continue; // deleted or replaced slot
      out.push({
        event: ev,
        start: startIso,
        end: endIso,
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
  return { occurrences: out, unexpandable };
}
