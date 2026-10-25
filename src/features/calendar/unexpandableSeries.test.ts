import { describe, expect, it } from 'vitest';
import { ja } from '../../i18n/ja';
import { en } from '../../i18n/en';

/*
  K12 (P8-finish-3a) wiring. The isolation rule itself is pinned in
  src/services/occurrencesMalformed.test.ts; this file pins how it reaches the
  screen, and that the share page is untouched by it.
*/

const SOURCES = import.meta.glob('/src/**/*.{ts,tsx}', { query: '?raw', import: 'default', eager: true }) as Record<string, string>;
const code = (path: string) =>
  (SOURCES[path] ?? '').replace(/\/\*[\s\S]*?\*\//g, '').replace(/\{\/\*[\s\S]*?\*\/\}/g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

describe('K12: the owner is told, the rest of the calendar is drawn', () => {
  const page = code('/src/features/calendar/CalendarPage.tsx');
  const hook = code('/src/hooks/useEvents.ts');

  it('the hook reports the series it cannot expand, over ALL rows (not the range on screen)', () => {
    expect(hook).toMatch(/const unexpandableSeries = useMemo\(\(\) => unexpandableMasters\(rows\), \[rows\]\);/);
    expect(hook).toMatch(/expandEvents\(rows, rangeStartIso, rangeEndIso\)/);
  });

  it('the calendar shows a warning with the count, and only the count', () => {
    expect(page).toMatch(
      /\{events\.unexpandableSeries\.length > 0 && \(\s*<p className="banner warn" role="status">\s*\{tr\('calendar\.unexpandableSeries', \{ count: String\(events\.unexpandableSeries\.length\) \}\)\}\s*<\/p>\s*\)\}/,
    );
    // no title, rule or id of the hidden rows is put on screen
    expect(page).not.toMatch(/unexpandableSeries\.map|unexpandableSeries\[/);
  });

  it('both languages say it, with the count', () => {
    for (const dict of [ja, en] as Array<Record<string, string>>) {
      const text = dict['calendar.unexpandableSeries'];
      expect(text).toBeTypeOf('string');
      expect(text).toContain('{count}');
    }
  });
});

describe('K12: the share page does not use the client expansion at all', () => {
  it('FreeBusyPage takes its Busy/Available from the server only', () => {
    const share = code('/src/features/share/FreeBusyPage.tsx');
    expect(share).toMatch(/import \{ getFreeBusy \} from '\.\.\/\.\.\/repositories\/shareRepository';/);
    expect(share).not.toMatch(/services\/occurrences|hooks\/useEvents|services\/recurrence'/);
  });
});
