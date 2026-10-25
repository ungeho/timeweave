/**
 * A month as a map, not as a list of events.
 *
 * WHAT IT DELIBERATELY DOES NOT DO: put event titles in a 46px cell. The P8-a
 * audit measured that at every phone width and found titles cut to a single
 * character -- `定`, `レ` -- which tells a reader nothing except that
 * something is there. So this says exactly that much, in a form a narrow cell
 * can hold, and picking a day opens that day's own list, where the titles are
 * readable at full width.
 *
 * The grid is `buildMonthGrid`'s, unchanged: the same 42 cells, the same
 * Monday start, the same leading and trailing days from the neighbouring
 * months. It comes back flat and is chunked into rows here purely for layout.
 */

import { useMemo } from 'react';
import { buildMonthGrid, type MonthGridCell } from '../monthGrid';
import { dayKeyTitle, dayKeyWeekday } from '../weekGrid';
import type { DayDensity } from '../mobileAgenda';
import { useLanguage, useTranslate } from '../../../i18n/useLanguage';
import { intlLocale } from '../../../i18n/resolveLanguage';

/** The flat 42 cells, in rows of seven. */
function toWeeks(cells: MonthGridCell[]): MonthGridCell[][] {
  const weeks: MonthGridCell[][] = [];
  for (let i = 0; i < cells.length; i += 7) weeks.push(cells.slice(i, i + 7));
  return weeks;
}

export function CompactMonth({
  anchor,
  selectedDayKey,
  density,
  onSelect,
}: {
  anchor: Date;
  selectedDayKey: string;
  density: Map<string, DayDensity>;
  onSelect: (dayKey: string) => void;
}) {
  const tr = useTranslate();
  const { language } = useLanguage();
  const locale = intlLocale(language);

  const weeks = useMemo(() => toWeeks(buildMonthGrid(anchor)), [anchor]);

  // The weekday row is taken from the first week rather than a hard-coded
  // list, so it starts on whatever day the grid starts on.
  const headerRow = weeks[0] ?? [];

  return (
    <div className="compact-month">
      <div className="compact-month-weekdays" aria-hidden="true">
        {headerRow.map((cell) => (
          <span key={cell.dayKey}>{dayKeyWeekday(cell.dayKey, locale, 'narrow')}</span>
        ))}
      </div>

      <div className="compact-month-grid">
        {weeks.map((week, i) => (
          <div className="compact-month-week" key={week[0]?.dayKey ?? i}>
            {week.map((cell) => {
              const d = density.get(cell.dayKey) ?? 'none';
              const selected = cell.dayKey === selectedDayKey;
              return (
                <button
                  key={cell.dayKey}
                  type="button"
                  className={[
                    'compact-month-cell',
                    selected ? 'selected' : '',
                    cell.isToday ? 'today' : '',
                    cell.inCurrentMonth ? '' : 'muted',
                  ]
                    .filter(Boolean)
                    .join(' ')}
                  aria-label={tr('calendar.mobile.dayLabel', {
                    date: dayKeyTitle(cell.dayKey, locale),
                    events:
                      d === 'none'
                        ? tr('calendar.mobile.noEvents')
                        : tr('calendar.mobile.hasEvents'),
                  })}
                  aria-current={selected ? 'date' : undefined}
                  onClick={() => onSelect(cell.dayKey)}
                >
                  <span className="compact-month-number">{cell.dayOfMonth}</span>
                  <span className="compact-month-density" data-density={d} aria-hidden="true" />
                </button>
              );
            })}
          </div>
        ))}
      </div>
    </div>
  );
}
