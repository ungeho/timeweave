/**
 * The calendar, for a phone.
 *
 * Two modes rather than four. A 7-column week or day grid at 360px gives 47px
 * columns -- the P8-a audit measured chips collapsing to a single character --
 * so offering them would be offering something unreadable. The desktop keeps
 * all three; `mobileAgenda.ts` maps between the two sets when a viewport
 * crosses the boundary.
 *
 * IT OWNS NO EVENT STATE. The occurrences, the anchor and the handlers all
 * come from `CalendarPage`, which computes them once for whichever layout is
 * on screen. The selected day IS the anchor, so there is no second piece of
 * state to keep in step with it -- and that is what carries the date across a
 * resize.
 */

import type { EventOccurrence } from '../../../types/event';
import type { CalendarView } from '../../../hooks/useCalendarView';
import type { DayAgenda } from '../dayAgenda';
import type { DayCell } from '../weekGrid';
import { dayKeyTitle } from '../weekGrid';
import type { DayDensity } from '../mobileAgenda';
import { useLanguage, useTranslate } from '../../../i18n/useLanguage';
import { intlLocale } from '../../../i18n/resolveLanguage';
import { monthTitle } from '../monthGrid';
import { AgendaList } from '../AgendaList';
import { DateStrip } from './DateStrip';
import { CompactMonth } from './CompactMonth';
import { useHorizontalSwipe } from './swipe';
import { addDaysToDateString } from '../../../utils/datetime';

export function MobileCalendar({
  view,
  selectedDayKey,
  weekDays,
  density,
  agenda,
  onSelectDay,
  onOccurrenceClick,
  onCreateOnDay,
}: {
  view: CalendarView;
  selectedDayKey: string;
  /** Monday..Sunday of the week the anchor is in. Empty in month mode. */
  weekDays: DayCell[];
  density: Map<string, DayDensity>;
  agenda: DayAgenda;
  onSelectDay: (dayKey: string) => void;
  onOccurrenceClick: (occ: EventOccurrence) => void;
  onCreateOnDay: (dayKey: string) => void;
}) {
  const tr = useTranslate();
  const { language } = useLanguage();
  const locale = intlLocale(language);
  const isMonth = view.mode === 'month';
  /*
    SWIPE (P8-mobile-1). List: a DAY either way -- the same selection a tap on
    the strip makes, by calendar date, so the strip follows and no clock time
    is involved. Month: the month arrows' own step. The buttons stay.
  */
  const swipeRef = useHorizontalSwipe<HTMLDivElement>((dir) => {
    const d = dir === 'left' ? 1 : -1;
    if (isMonth) {
      if (d === 1) view.next();
      else view.prev();
    } else {
      onSelectDay(addDaysToDateString(selectedDayKey, d));
    }
  });

  return (
    <div className="mobile-calendar">
      <div className="mobile-bar">
        <button
          className="btn icon"
          aria-label={tr('calendar.prev')}
          onClick={view.prev}
        >
          ‹
        </button>
        <h2 className="mobile-bar-title">
          {isMonth ? monthTitle(view.anchor, locale) : dayKeyTitle(selectedDayKey, locale)}
        </h2>
        <button
          className="btn icon"
          aria-label={tr('calendar.next')}
          onClick={view.next}
        >
          ›
        </button>
      </div>

      <div className="mobile-bar mobile-bar-modes">
        <button className="btn" onClick={view.today}>
          {tr('calendar.today')}
        </button>
        {/*
          Two buttons rather than a toggle, so the one that is active is named
          as such for a screen reader. `aria-pressed` says which, which is what
          a toggle button needs -- the highlight alone is colour.
        */}
        <button
          className={`btn ${!isMonth ? 'active' : ''}`}
          aria-pressed={!isMonth}
          onClick={() => view.setMode('agenda')}
        >
          {tr('calendar.mobile.agenda')}
        </button>
        <button
          className={`btn ${isMonth ? 'active' : ''}`}
          aria-pressed={isMonth}
          onClick={() => view.setMode('month')}
        >
          {tr('calendar.view.month')}
        </button>
      </div>

      <div ref={swipeRef} className="mobile-swipe-area">
      {isMonth ? (
        <CompactMonth
          anchor={view.anchor}
          selectedDayKey={selectedDayKey}
          density={density}
          /*
            Picking a date here RETURNS TO THE AGENDA. The month is a map of
            where events are, not a place to read them -- its cells hold a
            number and a dot and nothing else -- so choosing a day is a request
            to see what is on it.
          */
          onSelect={(dayKey) => {
            onSelectDay(dayKey);
            view.setMode('agenda');
          }}
        />
      ) : (
        <>
          <DateStrip
            days={weekDays}
            selectedDayKey={selectedDayKey}
            density={density}
            onSelect={onSelectDay}
          />
          <div className="mobile-agenda">
            <AgendaList
              agenda={agenda}
              onOccurrenceClick={onOccurrenceClick}
              footer={
                <button
                  className="btn mobile-add"
                  onClick={() => onCreateOnDay(selectedDayKey)}
                >
                  {tr('calendar.mobile.addOnDay')}
                </button>
              }
            />
          </div>
        </>
      )}
      </div>
    </div>
  );
}
