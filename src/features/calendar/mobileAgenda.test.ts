/**
 * What the mobile calendar decides.
 *
 * The screens cannot be rendered here -- vitest runs with
 * `environment: 'node'` and jsdom is deliberately not added -- so the
 * judgements live in `mobileAgenda.ts` and are asserted here, with a few
 * structural checks over the component sources for the properties that only
 * exist in markup.
 */

import { describe, expect, it } from 'vitest';
import type { EventOccurrence } from '../../types/event';
import type { EventRow } from '../../types/event';
import {
  DENSITY_FEW_MAX,
  MOBILE_MODES,
  countsByDay,
  densitiesByDay,
  densityFor,
  isMobileMode,
  toDesktopMode,
  toMobileMode,
} from './mobileAgenda';
import { buildDayAgenda } from './dayAgenda';
import { isoFromDateString } from '../../utils/datetime';

const SOURCES = import.meta.glob('/src/**/*.{ts,tsx}', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

const code = (t: string) =>
  t.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

const TZ = 'Asia/Tokyo';

function row(over: Partial<EventRow> = {}): EventRow {
  return {
    id: 'e1',
    ownerId: 'o',
    title: 't',
    description: null,
    category: null,
    visibility: 'private',
    availability: 'busy',
    allDay: false,
    startAt: null,
    endAt: null,
    startDate: null,
    endDate: null,
    rrule: null,
    recurrenceId: null,
    recurrenceSlotStart: null,
    recurrenceSlotDate: null,
    isCancelled: false,
    timezone: null,
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
    ...over,
  };
}

/** A timed occurrence starting at a JST wall clock time. */
function timed(id: string, startUtc: string, endUtc: string): EventOccurrence {
  return {
    event: row({ id, startAt: startUtc, endAt: endUtc }),
    start: startUtc,
    end: endUtc,
    allDay: false,
    occurrenceKey: startUtc,
    isException: false,
  };
}

/** An all-day occurrence covering [startDate, endDateExcl). */
function allDay(id: string, startDate: string, endDateExcl: string): EventOccurrence {
  return {
    event: row({ id, allDay: true, startDate, endDate: endDateExcl }),
    // Local midnights, exactly as services/occurrences.ts builds them. These
    // were UTC midnights, which buildDayAgenda reads back (localDayKey) as the
    // previous date wherever the OS zone is west of UTC (P8-c1.1).
    start: isoFromDateString(startDate),
    end: isoFromDateString(endDateExcl),
    allDay: true,
    occurrenceKey: startDate,
    isException: false,
  };
}

describe('the modes a phone offers', () => {
  it('is two, not four', () => {
    // A 7-column week or day grid at 360px gives 47px columns -- measured in
    // the P8-a audit, where chips collapsed to a single character. Offering
    // them would be offering something unreadable.
    expect([...MOBILE_MODES]).toEqual(['agenda', 'month']);
  });

  it('recognises its own', () => {
    expect(isMobileMode('agenda')).toBe(true);
    expect(isMobileMode('month')).toBe(true);
    expect(isMobileMode('week')).toBe(false);
    expect(isMobileMode('day')).toBe(false);
  });
});

describe('crossing the width boundary keeps the reader where they were', () => {
  it('a narrow viewport maps rather than resets', () => {
    // Resizing is not a request to go somewhere else. Week and day both show
    // dates, and the agenda shows one of those dates in full.
    expect(toMobileMode('week')).toBe('agenda');
    expect(toMobileMode('day')).toBe('agenda');
    expect(toMobileMode('agenda')).toBe('agenda');
    // A phone has a month of its own, so month survives as month.
    expect(toMobileMode('month')).toBe('month');
  });

  it('a wide viewport lands on the closest desktop view', () => {
    // `agenda` has no desktop equivalent; `day` is one date with everything on
    // it. `month` would throw away the day that was selected.
    expect(toDesktopMode('agenda')).toBe('day');
    expect(toDesktopMode('month')).toBe('month');
    expect(toDesktopMode('week')).toBe('week');
    expect(toDesktopMode('day')).toBe('day');
  });

  it('every mapping lands somewhere the target layout can render', () => {
    for (const m of ['month', 'week', 'day', 'agenda'] as const) {
      expect(isMobileMode(toMobileMode(m)), m).toBe(true);
      expect(toDesktopMode(m), m).not.toBe('agenda');
    }
  });

  it('a round trip through the narrow layout does not change month', () => {
    // The one mode both layouts have. Anything else is allowed to land
    // somewhere else on the way back -- there is no day view on a phone to
    // return to -- but month must survive a rotation unchanged.
    expect(toDesktopMode(toMobileMode('month'))).toBe('month');
  });
});

describe('how full a day looks', () => {
  it('nothing, a few, or many', () => {
    expect(densityFor(0)).toBe('none');
    expect(densityFor(1)).toBe('few');
    expect(densityFor(DENSITY_FEW_MAX)).toBe('few');
    expect(densityFor(DENSITY_FEW_MAX + 1)).toBe('many');
    expect(densityFor(99)).toBe('many');
  });

  it('a negative count is still nothing', () => {
    expect(densityFor(-1)).toBe('none');
  });
});

describe('the counts agree with the list a reader opens', () => {
  // 2026-10-13 is a Tuesday. 00:00Z is 09:00 JST.
  const occurrences = [
    timed('a', '2026-10-13T00:00:00.000Z', '2026-10-13T00:30:00.000Z'),
    timed('b', '2026-10-13T05:00:00.000Z', '2026-10-13T06:00:00.000Z'),
    timed('c', '2026-10-14T02:00:00.000Z', '2026-10-14T02:30:00.000Z'),
    allDay('d', '2026-10-16', '2026-10-19'),
  ];
  const days = ['2026-10-12', '2026-10-13', '2026-10-14', '2026-10-15', '2026-10-16', '2026-10-17', '2026-10-18'];

  it('counts what buildDayAgenda would list, day for day', () => {
    // THE PROPERTY THAT MATTERS. A day marked busy that opens to an empty
    // list -- or the reverse -- is a disagreement a reader cannot explain, and
    // it is exactly what a second filter written for the strip would produce.
    const counts = countsByDay(days, occurrences, TZ);
    for (const key of days) {
      const agenda = buildDayAgenda(key, occurrences, TZ);
      expect(counts.get(key), key).toBe(agenda.allDay.length + agenda.timed.length);
    }
  });

  it('an all-day event is counted on every day it covers', () => {
    const counts = countsByDay(days, occurrences, TZ);
    // [16, 19) is three days.
    expect(counts.get('2026-10-16')).toBe(1);
    expect(counts.get('2026-10-17')).toBe(1);
    expect(counts.get('2026-10-18')).toBe(1);
    expect(counts.get('2026-10-15')).toBe(0);
  });

  it('a timed event is counted only on the day it starts, in the owner zone', () => {
    const counts = countsByDay(days, occurrences, TZ);
    expect(counts.get('2026-10-13')).toBe(2);
    expect(counts.get('2026-10-14')).toBe(1);
    expect(counts.get('2026-10-12')).toBe(0);
  });

  it('densities follow the same counts', () => {
    const counts = countsByDay(days, occurrences, TZ);
    const densities = densitiesByDay(days, occurrences, TZ);
    for (const key of days) {
      expect(densities.get(key), key).toBe(densityFor(counts.get(key) ?? 0));
    }
  });

  it('answers for every day asked about, including empty ones', () => {
    const densities = densitiesByDay(days, occurrences, TZ);
    expect([...densities.keys()].sort()).toEqual([...days].sort());
    expect(densities.get('2026-10-12')).toBe('none');
  });
});

describe('the mobile screens stay thin', () => {
  const sources = Object.entries(SOURCES).filter(([p]) =>
    p.startsWith('/src/features/calendar/mobile/'),
  );

  it('there are mobile sources to check', () => {
    // 4 since P8-mobile-1 added swipe.ts, which the checks below now cover too.
    expect(sources.length).toBe(4);
  });

  it('none of them fetches or counts anything itself', () => {
    // The occurrences, the anchor and the handlers all come from CalendarPage,
    // which computes them once for whichever layout is on screen. A second
    // computation here would be a second answer.
    for (const [path, text] of sources) {
      const c = code(text);
      expect(c, `${path} must not load events`).not.toContain('useEvents');
      expect(c, `${path} must not expand occurrences`).not.toContain('occurrencesIn');
      expect(c, `${path} must not count days itself`).not.toContain('buildDayAgenda');
    }
  });

  it('the day labels come from a day key, never a Date built here', () => {
    // weekGrid formats UTC noon in UTC, so no zone conversion can shift a
    // date by a day. Building a Date from a day key here would reintroduce
    // exactly that hazard.
    for (const [path, text] of sources) {
      if (!text.includes('dayKey')) continue;
      expect(code(text), `${path} must not construct a date from a key`).not.toMatch(
        /new Date\(`?\$?\{?dayKey/,
      );
    }
  });

  it('a density is announced in words as well as drawn', () => {
    // The dot has no text. Without an accessible name a screen reader gets
    // the day number alone, which says nothing about whether anything is on
    // it -- and the dot is the only thing that does.
    for (const [path, text] of sources) {
      if (!text.includes('data-density')) continue;
      expect(text, path).toContain('aria-label');
      expect(text, path).toContain('calendar.mobile.hasEvents');
      expect(text, path).toContain('calendar.mobile.noEvents');
      expect(text, path).toContain('aria-hidden="true"');
    }
  });

  it('the selected day is marked for assistive technology', () => {
    // Keyed on `data-density`, which is what a day CELL draws. MobileCalendar
    // passes the selected key through without rendering a cell of its own, so
    // a looser test demanded an attribute it has nothing to put it on.
    const cells = sources.filter(([, t]) => t.includes("data-density"));
    expect(cells.length).toBe(2);
    for (const [path, text] of cells) {
      expect(text, path).toContain("aria-current={selected ? 'date' : undefined}");
    }
  });
});

describe('the branch is in one place', () => {
  it('only these screens ask how wide the window is', () => {
    /*
      AN ALLOWLIST, NOT A CEILING OF ONE. The rule is that each SCREEN decides
      its own shell once, so the two layouts cannot disagree within a screen
      and the desktop path grows no conditions. It is not that the app may
      only ever ask once -- P8-b3 adds a second screen with a shell of its
      own, and threading the answer down to it as a prop would mean a prop
      that exists only to carry a value a hook already gives.

      What this still catches is the thing worth catching: a LEAF component
      -- a chip, a strip, a field -- reaching for the viewport instead of
      being told what to draw. Those are the ones that make two layouts drift.
    */
    const askers = Object.entries(SOURCES)
      .filter(([p]) => !p.startsWith('/src/hooks/'))
      .filter(([, t]) => code(t).includes('useIsMobile('))
      .map(([p]) => p)
      .sort();
    expect(askers).toEqual([
      // P8-b5.5: the app shell, which chooses between a row of word-labelled
      // buttons and a brand plus two icons. HeaderMenu itself does NOT ask --
      // it is handed its items and renders them, which is what keeps the two
      // arrangements from disagreeing about what exists.
      '/src/App.tsx',
      // P8-b2: the calendar chooses between the desktop grid and the agenda.
      '/src/features/calendar/CalendarPage.tsx',
      // P8-b3: the event form chooses between the modal and the full-height
      // sheet. Same field tree either way -- only the shell differs.
      '/src/features/event/EventDialog.tsx',
      // P8-b4: the share dialog, for the same reason -- a create form above
      // a list with no bound. The settings dialog is deliberately NOT here:
      // two fields do not need a sheet, so it stays a modal and is styled
      // for narrow widths instead.
      '/src/features/share/ShareDialog.tsx',
    ]);
  });

  it('the desktop toolbar is not rendered on a phone', () => {
    // It offers month, week and day -- none of which a phone renders -- and
    // MobileCalendar carries its own period bar and its own two modes.
    const page = code(SOURCES['/src/features/calendar/CalendarPage.tsx'] ?? '');
    expect(page).toContain('!isMobile && <CalendarToolbar');
  });

  it('both layouts read the same occurrences', () => {
    // One range, one expansion, handed to whichever layout is on screen.
    const page = code(SOURCES['/src/features/calendar/CalendarPage.tsx'] ?? '');
    expect((page.match(/events\.occurrencesIn\(/g) ?? []).length).toBe(1);
  });
});
