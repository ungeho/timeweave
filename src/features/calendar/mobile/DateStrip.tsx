/**
 * Seven days, one row, pick one.
 *
 * WHY THIS AND NOT THE MONTH GRID. A 7-column month at 360px gives 46px cells,
 * and the P8-a audit measured what that does to an event title: it collapses
 * to a single character. A strip has the same seven columns but puts only a
 * weekday, a number and a dot in each, which 41px can hold -- and the day's
 * contents go underneath, at full width, where they are readable.
 *
 * NO STATE OF ITS OWN. The selected day is the view's anchor, so there is
 * nothing here to keep in step with it, and a viewport that crosses the mobile
 * boundary carries the date across because both layouts read the same anchor.
 *
 * EVERY LABEL COMES FROM A DAY KEY, never from a Date built here. `dayKeyTitle`
 * and `dayKeyWeekday` format UTC noon in UTC, so no zone conversion can shift
 * a date by a day -- the hazard weekGrid.ts documents.
 */

import type { DayCell } from '../weekGrid';
import { dayKeyTitle, dayKeyWeekday } from '../weekGrid';
import type { DayDensity } from '../mobileAgenda';
import { useLanguage, useTranslate } from '../../../i18n/useLanguage';
import { intlLocale } from '../../../i18n/resolveLanguage';

export function DateStrip({
  days,
  selectedDayKey,
  density,
  onSelect,
}: {
  /** Monday to Sunday, from buildWeekDays -- the same week the grid would use. */
  days: DayCell[];
  selectedDayKey: string;
  density: Map<string, DayDensity>;
  onSelect: (dayKey: string) => void;
}) {
  const tr = useTranslate();
  const { language } = useLanguage();
  const locale = intlLocale(language);

  return (
    <div className="date-strip" role="group" aria-label={tr('calendar.mobile.week')}>
      {days.map((day) => {
        const d = density.get(day.dayKey) ?? 'none';
        const selected = day.dayKey === selectedDayKey;
        return (
          <button
            key={day.dayKey}
            type="button"
            className={['date-strip-day', selected ? 'selected' : '', day.isToday ? 'today' : '']
              .filter(Boolean)
              .join(' ')}
            /*
              The visible content is a weekday initial, a number and a dot, so
              the button's name has to carry the rest: which date it is, and
              whether anything is on it. A reader moving by Tab hears the day
              rather than "13".
            */
            aria-label={tr('calendar.mobile.dayLabel', {
              date: dayKeyTitle(day.dayKey, locale),
              events:
                d === 'none' ? tr('calendar.mobile.noEvents') : tr('calendar.mobile.hasEvents'),
            })}
            aria-current={selected ? 'date' : undefined}
            onClick={() => onSelect(day.dayKey)}
          >
            <span className="date-strip-weekday">{dayKeyWeekday(day.dayKey, locale)}</span>
            <span className="date-strip-number">{day.dayOfMonth}</span>
            {/*
              Density, not a count. The desktop month cell does not print how
              many events a day holds either, and putting the number here would
              disclose more on a phone than on a desktop for no reason.

              `data-density` rather than a colour class: the dot's size changes
              with it as well as its shade, so the distinction survives
              greyscale. The accessible name above says the same thing in words.
            */}
            <span className="date-strip-density" data-density={d} aria-hidden="true" />
          </button>
        );
      })}
    </div>
  );
}
