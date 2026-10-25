import { describe, expect, it } from 'vitest';
import { t } from './t';
import { ja } from './ja';
import { en } from './en';
import { visibilityMeta } from '../features/calendar/visibilityMeta';
import { eventDisplayTitle } from '../features/calendar/eventTitle';

/**
 * P3-b step 4 moved the CALENDAR DISPLAY's wording into the dictionary:
 * MonthView, TimeGridView, AllDayLane, DayAgendaDialog, EventChip and
 * CalendarPage.
 *
 * As in every earlier step the claim is that NOTHING THE USER SEES CHANGED, so
 * the Japanese below is written out literally rather than read back from `ja`.
 *
 * None of these can be rendered here -- vitest runs `environment: 'node'` and
 * jsdom is deliberately not added -- so what is checked is the dictionary they
 * now read, the composed names rebuilt from their parts, and the source
 * structure of the ordering, overlap and click paths the step must not have
 * touched.
 */

const JP = /[ぁ-んァ-ヶ一-龯]/;

const MODULES = import.meta.glob('/src/**/*.{ts,tsx}', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

const source = (path: string) => (MODULES['/src/' + path] ?? '') as string;

/** The six components this step migrated. */
const MIGRATED = [
  'features/calendar/MonthView.tsx',
  'features/calendar/TimeGridView.tsx',
  'features/calendar/AllDayLane.tsx',
  'features/calendar/DayAgendaDialog.tsx',
  'features/calendar/EventChip.tsx',
  'features/calendar/CalendarPage.tsx',
];

describe('the calendar display renders the same Japanese as before', () => {
  it('the row headings', () => {
    expect(ja['calendar.allDay']).toBe('終日');
    expect(ja['calendar.timed']).toBe('時刻あり');
  });

  it('the day agenda', () => {
    expect(ja['calendar.agenda.empty']).toBe('この日の予定はありません。');
    expect(ja['common.close']).toBe('閉じる');
  });

  it('the page chrome', () => {
    expect(ja['calendar.share']).toBe('共有');
    expect(ja['common.loading']).toBe('読み込み中…');
  });

  it('the load error, with the message interpolated exactly as the old text node', () => {
    // It was `読み込みエラー: {events.error}` -- a text node ending in a space
    // followed by an expression. The colon-space has to survive.
    expect(ja['calendar.loadError']).toBe('読み込みエラー: {message}');
    expect(t('calendar.loadError', 'ja', { message: 'boom' })).toBe('読み込みエラー: boom');
  });

  it('the two overflow buttons', () => {
    expect(ja['calendar.more.events']).toBe('他 {count} 件の予定を表示');
    expect(ja['calendar.more.allDay']).toBe('他 {count} 件の終日予定を表示');
    expect(t('calendar.more.events', 'ja', { count: 3 })).toBe('他 3 件の予定を表示');
    expect(t('calendar.more.allDay', 'ja', { count: 1 })).toBe('他 1 件の終日予定を表示');
  });
});

/**
 * THE COMPOSED NAMES.
 *
 * Three components draw an event -- EventChip, AllDayLane's bands and
 * MonthView's MonthBand -- and all three built the tooltip and the accessible
 * name with the same two template literals. The punctuation is what made them
 * keys: Japanese wraps the visibility in full-width parentheses and English
 * cannot.
 */
describe('the chip title and accessible name rebuild the old strings', () => {
  it('the Japanese tooltip is byte-identical for every visibility', () => {
    for (const v of ['private', 'busy_only', 'public'] as const) {
      const label = visibilityMeta(v).label;
      expect(t('calendar.chip.title', 'ja', { title: '会議', visibility: label })).toBe(
        `会議（${label}）`,
      );
    }
  });

  it('the Japanese accessible name is byte-identical for every visibility', () => {
    for (const v of ['private', 'busy_only', 'public'] as const) {
      const label = visibilityMeta(v).label;
      expect(t('calendar.chip.ariaLabel', 'ja', { title: '会議', visibility: label })).toBe(
        `会議, ${label}`,
      );
    }
  });

  it('an untitled event still announces its fallback, never a bare comma', () => {
    // eventDisplayTitle supplies the words, which is why the chip passes ONE
    // value to the visible text, the tooltip and the name.
    const busy = eventDisplayTitle({ title: '', availability: 'busy' });
    const open = eventDisplayTitle({ title: '', availability: 'available' });
    expect(busy).toBe('(無題)');
    expect(open).toBe('空き時間');
    expect(t('calendar.chip.ariaLabel', 'ja', { title: busy, visibility: '非公開' })).toBe(
      '(無題), 非公開',
    );
    expect(t('calendar.chip.ariaLabel', 'ja', { title: open, visibility: '非公開' })).not.toMatch(
      /^,/,
    );
  });

  it('English uses ordinary parentheses with a space, not the full-width pair', () => {
    expect(t('calendar.chip.title', 'en', { title: 'Standup', visibility: 'Private' })).toBe(
      'Standup (Private)',
    );
    expect(en['calendar.chip.title']).not.toContain('（');
    expect(en['calendar.chip.title']).not.toContain('）');
  });

  it('the accessible name keeps the comma in BOTH languages', () => {
    // A screen reader pauses on a comma and announces nothing for a
    // parenthesis, so this one does not follow the tooltip's punctuation.
    expect(ja['calendar.chip.ariaLabel']).toContain(',');
    expect(en['calendar.chip.ariaLabel']).toContain(',');
    expect(en['calendar.chip.ariaLabel']).not.toContain('(');
  });

  it('all three drawing components use the same two keys', () => {
    // Three copies of a template literal is how a band ends up announcing
    // something different from the chip for the same event.
    for (const p of [
      'features/calendar/EventChip.tsx',
      'features/calendar/AllDayLane.tsx',
      'features/calendar/MonthView.tsx',
    ]) {
      expect(source(p), p).toMatch(/tr\('calendar\.chip\.title'/);
      expect(source(p), p).toMatch(/tr\('calendar\.chip\.ariaLabel'/);
    }
  });

  it('no component is left composing a name with a template literal', () => {
    for (const p of MIGRATED) {
      expect(source(p), p).not.toMatch(/vis\.label\}\）/);
      expect(source(p), p).not.toMatch(/\$\{shownTitle\}/);
    }
  });
});

describe('the English calendar copy is complete and clean', () => {
  it('every calendar key has a non-empty English value with no Japanese in it', () => {
    const keys = (Object.keys(ja) as (keyof typeof ja)[]).filter((k) =>
      String(k).startsWith('calendar.'),
    );
    expect(keys.length).toBeGreaterThan(20);
    for (const k of keys) {
      expect(en[k].trim(), String(k)).not.toBe('');
      expect(en[k], String(k)).not.toMatch(JP);
    }
  });

  it('no English calendar string leaks an uninterpolated placeholder', () => {
    const keys = (Object.keys(ja) as (keyof typeof ja)[]).filter((k) =>
      String(k).startsWith('calendar.'),
    );
    for (const k of keys) {
      if (/\{\w+\}/.test(ja[k])) continue; // intentionally interpolated
      expect(en[k], String(k)).not.toMatch(/\{\w+\}/);
    }
  });

  it('the all-day and timed group headings stay distinct', () => {
    for (const d of [ja, en]) {
      expect(d['calendar.allDay']).not.toBe(d['calendar.timed']);
    }
  });

  it('the row heading is a separate key from the event form checkbox', () => {
    // Same Japanese word, two unrelated controls. One key would mean a change
    // for the form silently rewriting the time grid's gutter.
    expect(ja['calendar.allDay']).toBe(ja['event.field.allDay']);
    const gutter = source('features/calendar/TimeGridView.tsx');
    expect(gutter).toMatch(/tr\('calendar\.allDay'\)/);
    expect(gutter).not.toMatch(/event\.field\.allDay/);
  });

  it('the two overflow labels are grammatical at a count of one', () => {
    // `{count}` is 1 or more and this layer has no plural rules, so the
    // English omits the noun rather than shipping "Show 1 more events".
    // Proper plural handling is a P5 question; this pins the workaround.
    for (const k of ['calendar.more.events', 'calendar.more.allDay'] as const) {
      const one = t(k, 'en', { count: 1 });
      expect(one, k).not.toMatch(/\b1 more \w+s\b/);
      expect(one, k).toContain('1');
    }
    expect(t('calendar.more.events', 'en', { count: 1 })).toBe('Show 1 more');
    expect(t('calendar.more.allDay', 'en', { count: 1 })).toBe(
      'Show 1 more in the all-day row',
    );
  });

  it('the two overflow labels still say which overflow they are', () => {
    // The Japanese distinguishes 予定 from 終日予定. The English keeps the
    // distinction even though it dropped the noun.
    expect(ja['calendar.more.events']).not.toBe(ja['calendar.more.allDay']);
    expect(en['calendar.more.events']).not.toBe(en['calendar.more.allDay']);
    expect(en['calendar.more.allDay']).toMatch(/all-day/i);
  });

  it('the load error does not try to translate the message it carries', () => {
    // `events.error` is already a localised DomainError message or a raw
    // string. The label travels around it, so the two cannot drift.
    expect(ja['calendar.loadError']).toMatch(/\{message\}/);
    expect(en['calendar.loadError']).toMatch(/\{message\}/);
    expect(en['calendar.loadError']).toBe('Could not load: {message}');
  });
});

/**
 * WHAT THE DISPLAY MUST STILL DO. Wording was the only thing this step was
 * allowed to change, and these are the properties underneath it.
 */
describe('event ordering, overlap and placement are unchanged', () => {
  it('the month layout still comes from the pure helpers', () => {
    const src = source('features/calendar/MonthView.tsx');
    expect(src).toMatch(/buildMonthWeekLayout\(week\.map\(\(c\) => c\.dayKey\), groups, slots\)/);
    expect(src).toMatch(/groupMonthOccurrences\(occurrences, timeZone\)/);
    expect(src).toMatch(/monthSlotCount\(useMediaQuery\(COMPACT_MONTH_QUERY\)\)/);
  });

  it('the month grid rows are still derived the same way', () => {
    // Row 1 is the date label, so item row r is grid row r + 2. An off-by-one
    // here moves every chip.
    const src = source('features/calendar/MonthView.tsx');
    expect(src).toMatch(/gridRow: day\.bandRows \+ k \+ 2/);
    expect(src).toMatch(/gridRow: day\.moreRow \+ 2/);
    expect(src).toMatch(/gridRow: band\.lane \+ 2/);
  });

  it('the all-day bands still come from buildAllDayBands with its lane cap', () => {
    const src = source('features/calendar/AllDayLane.tsx');
    expect(src).toMatch(/buildAllDayBands\(occurrences, dayKeys, maxLanes\)/);
    expect(src).toMatch(/maxLanes = MAX_ALL_DAY_LANES/);
    expect(src).toMatch(/gridRow: band\.lane \+ 1/);
  });

  it('the overflow column-to-date join still lives in overflowEntries', () => {
    // Getting it wrong opens the wrong day while still showing the right
    // number, which no screenshot would catch.
    const src = source('features/calendar/AllDayLane.tsx');
    expect(src).toMatch(/overflowEntries\(dayKeys, overflow\)/);
    expect(src).toMatch(/onOverflowClick\(dayKey\)/);
  });

  it('the time grid still lays out its columns with layoutDayColumn', () => {
    const src = source('features/calendar/TimeGridView.tsx');
    expect(src).toMatch(/layoutDayColumn\(occurrences, day\.dayKey, timeZone\)/);
    expect(src).toMatch(/initialScrollMinutes\(occurrences, timeZone\)/);
    // The 30-minute snap on a column click.
    expect(src).toMatch(/Math\.round\(raw \/ 30\) \* 30/);
  });

  it('the day agenda still takes its order from buildDayAgenda', () => {
    expect(source('features/calendar/CalendarPage.tsx')).toMatch(
      /buildDayAgenda\(agendaDay, occurrences, timeZone\)/,
    );
    // THE LIST MOVED to AgendaList in P8-b2, so that the phone's agenda and
    // this dialog cannot disagree about grouping or order. The property is
    // unchanged and is now asserted once, where the list actually is.
    const list = source('features/calendar/AgendaList.tsx');
    expect(list).toMatch(/agenda\.allDay\.map/);
    expect(list).toMatch(/agenda\.timed\.map/);
    // All-day first, then timed: the group order the heading labels describe.
    expect(list.indexOf('agenda.allDay.map')).toBeLessThan(list.indexOf('agenda.timed.map'));
    // And the dialog still shows that list rather than one of its own.
    expect(source('features/calendar/DayAgendaDialog.tsx')).toMatch(/<AgendaList/);
  });

  it('every click still reaches the same handler with the same argument', () => {
    expect(source('features/calendar/MonthView.tsx')).toMatch(/onOccurrenceClick\(occ\)/);
    expect(source('features/calendar/AllDayLane.tsx')).toMatch(
      /onOccurrenceClick\(band\.occurrence\)/,
    );
    expect(source('features/calendar/TimeGridView.tsx')).toMatch(
      /onOccurrenceClick\(p\.occurrence\)/,
    );
    const page = source('features/calendar/CalendarPage.tsx');
    expect(page).toMatch(/onOccurrenceClick=\{openEdit\}/);
    expect(page).toMatch(/onDayClick=\{openCreateForDay\}/);
    expect(page).toMatch(/onSlotClick=\{openCreateForSlot\}/);
  });

  it('the chip and band clicks still stop propagating to the day cell', () => {
    // Without this, opening an event also opens the create dialog for the day
    // underneath it.
    for (const p of [
      'features/calendar/MonthView.tsx',
      'features/calendar/TimeGridView.tsx',
      'features/calendar/AllDayLane.tsx',
    ]) {
      expect(source(p), p).toMatch(/e\.stopPropagation\(\)/);
    }
  });

  it('the grid is still withheld until the first rows arrive', () => {
    // An empty month during the first fetch reads as "no events", which is the
    // one thing the placeholder exists to prevent.
    const page = source('features/calendar/CalendarPage.tsx');
    expect(page).toMatch(/isAwaitingRows\(\{ loading: events\.loading, rowCount: events\.rows\.length \}\)/);
    expect(page).toMatch(/calendar-placeholder/);
  });
});

describe('all-day handling and time zones are unchanged', () => {
  it('the time zone still reaches every layout call that needs it', () => {
    const page = source('features/calendar/CalendarPage.tsx');
    expect(page).toMatch(/const timeZone = useMemo\(\(\) => getUserTimeZone\(\), \[\]\)/);
    // P8-c1.1 (R1-P): the slot instant moved into createTimesAt; the zone
    // still has to reach it for both kinds of click.
    expect(page).toMatch(/createTimesAt\(dayKey, 9 \* 60, timeZone\)/);
    expect(page).toMatch(/createTimesAt\(dayKey, minutes, timeZone\)/);
  });

  it('the agenda heading still renders a date that cannot drift by a day', () => {
    // This step built it from a LOCAL-midnight instant, because formatting a
    // plain date string directly would show the wrong weekday on one side of
    // the day boundary. P4 step 2 moved it to weekGrid's dayKeyTitle, which
    // uses UTC noon with timeZone: 'UTC' -- the same guarantee, one argument
    // further from being broken, and shared with the day-view title.
    const dlg = source('features/calendar/DayAgendaDialog.tsx');
    expect(dlg).toMatch(/dayKeyTitle\(agenda\.dayKey, intlLocale\(language\)\)/);
    expect(source('features/calendar/weekGrid.ts')).toMatch(/T12:00:00Z/);
  });

  it('the all-day flag still decides whether a chip shows a time', () => {
    expect(source('features/calendar/EventChip.tsx')).toMatch(/!occurrence\.allDay && \(/);
    expect(source('features/calendar/EventChip.tsx')).toMatch(
      /<span className="event-chip-time">/,
    );
  });
});

describe('Busy and Available stay visually distinguishable', () => {
  it('all three drawing components still emit data-availability', () => {
    // The attribute the availability hatch hangs off in CSS. Losing it on one
    // of the three makes open time look like busy time in that view only.
    for (const p of [
      'features/calendar/EventChip.tsx',
      'features/calendar/AllDayLane.tsx',
      'features/calendar/MonthView.tsx',
    ]) {
      expect(source(p), p).toMatch(/data-availability=\{/);
    }
  });

  it('an untitled open event is still named rather than left blank', () => {
    // The fallback comes from eventTitle.ts, which pins it to the default
    // language (it takes no `lang` parameter -- the P3 step 2 shape). The
    // English wording is already in the dictionary, waiting for P6.
    expect(eventDisplayTitle({ title: '', availability: 'available' })).toBe('空き時間');
    expect(eventDisplayTitle({ title: '', availability: 'busy' })).toBe('(無題)');
    expect(en['calendar.availableTitle']).toBe('Open time');
    expect(en['calendar.untitled']).toBe('(untitled)');
  });

  it('no calendar key describes open time as "not busy"', () => {
    const keys = (Object.keys(ja) as (keyof typeof ja)[]).filter((k) =>
      String(k).startsWith('calendar.'),
    );
    for (const k of keys) {
      expect(en[k], String(k)).not.toMatch(/not busy|no events|free time/i);
    }
  });
});

describe('visibility is still shown by icon plus label, never by colour alone', () => {
  it('the icon is rendered beside every title', () => {
    for (const p of [
      'features/calendar/EventChip.tsx',
      'features/calendar/AllDayLane.tsx',
      'features/calendar/MonthView.tsx',
    ]) {
      expect(source(p), p).toMatch(/<VisibilityIcon visibility=\{/);
    }
  });

  it('the visibility comes from visibilityMeta, which P6 step 1 made a function', () => {
    // This step rendered a module CONSTANT pinned to DEFAULT_LANGUAGE. P6
    // step 1 replaced it with a pure function taking the language, so the
    // label can follow the UI. Still not a hook: the module has to stay
    // testable in environment: 'node'.
    const meta = source('features/calendar/visibilityMeta.ts');
    expect(meta).toMatch(/lang: Language = DEFAULT_LANGUAGE/);
    expect(meta).not.toMatch(/useTranslate|useLanguage/);
    // Called with no language, it still answers in Japanese.
    expect(visibilityMeta('private').label).toBe('非公開');
    expect(visibilityMeta('busy_only').label).toBe('予定あり（詳細非公開）');
    expect(visibilityMeta('public').label).toBe('公開');
  });

  it('busy_only still says the details are hidden, in both languages', () => {
    expect(visibilityMeta('busy_only').label).toContain('詳細非公開');
    expect(en['calendar.visibility.busyOnly']).toMatch(/hidden/i);
  });
});

describe('none of these components is reachable by an anonymous viewer', () => {
  it('the share route renders FreeBusyPage and none of them', () => {
    // They live inside AuthGate. The anonymous page has its own component and
    // its own vocabulary precisely so a private title can never reach it.
    const page = source('features/share/FreeBusyPage.tsx');
    for (const name of [
      'EventChip',
      'MonthView',
      'TimeGridView',
      'AllDayLane',
      'DayAgendaDialog',
      'CalendarPage',
    ]) {
      expect(page, name).not.toContain(name);
    }
  });

  it('none of them imports the anonymous share repository call', () => {
    for (const p of MIGRATED) {
      expect(source(p), p).not.toMatch(/getFreeBusy/);
    }
  });

  it('none of them reads owner_settings', () => {
    for (const p of MIGRATED) {
      expect(source(p), p).not.toMatch(/owner_settings|getOwnerSettings/);
    }
  });
});

describe('what this step deliberately did not do', () => {
  it('the weekday arrays went to the formatter in P4 step 1, not to the dictionary', () => {
    // This step left them hardcoded in both grids. P4 step 1 replaced both
    // with i18n/dateNames.ts. What has not changed, and must not, is that the
    // seven names are a DATE FORMAT and so never became dictionary keys.
    expect(source('features/calendar/MonthView.tsx')).toMatch(/weekdayNamesShort\(language\)/);
    expect(source('features/calendar/TimeGridView.tsx')).toMatch(/weekdayShort\(language,/);
    for (const p of ['features/calendar/MonthView.tsx', 'features/calendar/TimeGridView.tsx']) {
      expect(source(p), p).not.toContain('const WEEKDAY_LABELS = [');
    }
    const dateKeys = (Object.keys(ja) as string[]).filter(
      (k) => k.startsWith('weekday.') || k.startsWith('month.') || k.startsWith('date.'),
    );
    expect(dateKeys).toEqual([]);
  });

  it('the hour ladder is still a raw 24-hour format, and no longer alone in being one', () => {
    // 00:00..23:00 from padStart. P4 step 2 deliberately LEFT IT so, and
    // pinned every other clock to h23 to match it -- an English viewer reading
    // "9:00 AM" on a chip against a "09:00" axis was the failure to avoid.
    expect(source('features/calendar/TimeGridView.tsx')).toMatch(
      /String\(h\)\.padStart\(2, '0'\)/,
    );
    // The agenda heading no longer reads the browser's locale; P4 step 2 gave
    // it the resolved one. Comments stripped, because the file now EXPLAINS
    // the call it used to make -- matching raw text would flag the
    // explanation and push the next reader to delete it.
    const dlg = source('features/calendar/DayAgendaDialog.tsx')
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/(^|[^:])\/\/.*$/gm, '$1');
    expect(dlg).not.toMatch(/toLocaleDateString\(undefined/);
    expect(dlg).toMatch(/intlLocale\(language\)/);
  });

  it('no legend UI was added to the calendar', () => {
    for (const p of MIGRATED) {
      expect(source(p), p).not.toMatch(/tr\('legend\./);
    }
  });

  it('no category autocomplete and no visibility default change', () => {
    for (const p of MIGRATED) {
      expect(source(p), p).not.toMatch(/datalist/);
    }
    // The default still lives in EventDialog and is still private.
    expect(source('features/event/EventDialog.tsx')).toMatch(/useState<Visibility>\('private'\)/);
  });

  it('every migrated component reads the language but still renders the default', () => {
    // LANGUAGE_SWITCH_ENABLED pins what the provider hands out until P6. The
    // flag itself is asserted in wiring.test.ts.
    for (const p of MIGRATED) {
      expect(source(p), p).toMatch(/useTranslate\(\)/);
    }
  });
});
