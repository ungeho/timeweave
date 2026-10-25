import { useEffect, useMemo, useState } from 'react';
import type { EventOccurrence } from '../../types/event';
import { useCalendarView } from '../../hooks/useCalendarView';
import { useEvents } from '../../hooks/useEvents';
import { rowPatchFromEdit } from '../../services/exceptionEdit';
import { isSupabaseConfigured } from '../../lib/supabase';
import { getUserTimeZone, zonedDayKey } from '../../utils/timezone';
import { useLanguage, useTranslate } from '../../i18n/useLanguage';
import { ShareDialog } from '../share/ShareDialog';
import { CalendarToolbar } from './CalendarToolbar';
import { MonthView, monthSlotsStyle, useMonthSlots } from './MonthView';
import { useIsMobile } from '../../hooks/useIsMobile';
import { MobileCalendar } from './mobile/MobileCalendar';
import { densitiesByDay, toDesktopMode, toMobileMode } from './mobileAgenda';
import { DayAgendaDialog } from './DayAgendaDialog';
import { TimeGridView } from './TimeGridView';
import { caughtErrorText } from '../../i18n/errorText';
import { isAwaitingRows } from './loadState';
import { buildMonthGrid, monthGridRange } from './monthGrid';
import { buildDayCell, buildWeekDays, dayRange, weekRange } from './weekGrid';
import { buildDayAgenda } from './dayAgenda';
import { createTimesAt } from './createTimes';
import {
  EventDialog,
  type DialogState,
  type DeleteResult,
  type SaveResult,
} from '../event/EventDialog';

/**
 * Top-level calendar screen: toolbar + month/week/day view + add/edit dialog.
 *
 * The grid is withheld until the first rows arrive (`isAwaitingRows`): an empty
 * month would otherwise be read as "no events" while the fetch is still running.
 * A reload triggered by a save keeps the rows it already has, so the calendar
 * stays on screen and only a genuine first load shows the placeholder. A failed
 * load is reported by the error banner, which is independent of this.
 */
export function CalendarPage() {
  const tr = useTranslate();
  // For the load-error banner, which resolves its wording at RENDER rather
  // than at the moment the fetch failed. Nothing else on this page needs the
  // language value itself.
  const { language } = useLanguage();
  const isMobile = useIsMobile();
  /*
    A PHONE OPENS ON THE DAY, a desktop on the month. Only the FIRST render
    reads this -- useCalendarView keeps the mode in state from then on -- so a
    reader who picks the month view on a phone keeps it, and a later resize
    goes through toMobileMode/toDesktopMode below rather than back through
    here.
  */
  const view = useCalendarView(isMobile ? 'agenda' : 'month');
  const events = useEvents();
  const [dialog, setDialog] = useState<DialogState | null>(null);
  const [shareOpen, setShareOpen] = useState(false);
  // Which day's full listing is open, or null. A date rather than the agenda
  // itself, so the list re-derives from the live occurrences: saving an edit
  // from inside the dialog is reflected the moment it reopens.
  const [agendaDay, setAgendaDay] = useState<string | null>(null);
  const timeZone = useMemo(() => getUserTimeZone(), []);

  /*
    THE ONE BRANCH. Everything below derives from `view.mode`, so keeping the
    mode itself valid for the current layout is enough -- no component has to
    ask how wide the window is, and the desktop path gains no conditions.

    Resizing is not a request to go somewhere else, so the mode is MAPPED
    rather than reset, and the anchor is left alone. A reader on the week view
    who rotates their phone keeps the date and gets the agenda, which shows one
    of those days in full.
  */
  useEffect(() => {
    const wanted = isMobile ? toMobileMode(view.mode) : toDesktopMode(view.mode);
    if (wanted !== view.mode) view.setMode(wanted);
  }, [isMobile, view]);
  // Only for the month placeholder's height: MonthView reads the same hook, so
  // the box reserved while loading has the row count the grid will render with.
  const monthSlots = useMonthSlots();

  const range = useMemo(() => {
    if (view.mode === 'month') return monthGridRange(view.anchor);
    // `agenda` fetches the whole WEEK, not the selected day: the strip above
    // the list marks which of the seven days hold anything, and it cannot do
    // that from one day's occurrences. One range serves both.
    if (view.mode === 'week' || view.mode === 'agenda') return weekRange(view.anchor, timeZone);
    return dayRange(view.anchor, timeZone);
  }, [view.mode, view.anchor, timeZone]);

  const occurrences = useMemo(
    () => events.occurrencesIn(range.startIso, range.endIso),
    [events, range],
  );

  const days = useMemo(() => {
    if (view.mode === 'week') return buildWeekDays(view.anchor, timeZone);
    if (view.mode === 'day') return [buildDayCell(view.anchor, timeZone)];
    return [];
  }, [view.mode, view.anchor, timeZone]);

  const agenda = useMemo(
    () => (agendaDay ? buildDayAgenda(agendaDay, occurrences, timeZone) : null),
    [agendaDay, occurrences, timeZone],
  );

  /*
    THE SELECTED DAY IS THE ANCHOR. Not a second piece of state beside it:
    two would have to be kept in step, and the one that carries a date across
    a width change is the anchor, because both layouts already read it.
  */
  const selectedDayKey = useMemo(
    () => zonedDayKey(view.anchor.toISOString(), timeZone),
    [view.anchor, timeZone],
  );

  const weekDays = useMemo(
    () => (isMobile && view.mode === 'agenda' ? buildWeekDays(view.anchor, timeZone) : []),
    [isMobile, view.mode, view.anchor, timeZone],
  );

  /*
    Which days to mark. The strip needs its seven; the compact month needs the
    42 cells of its grid. Counted through `buildDayAgenda` -- see
    mobileAgenda.ts for why a second filter would be free to disagree with the
    list a reader opens.
  */
  const densityDays = useMemo(() => {
    if (!isMobile) return [];
    if (view.mode === 'month') return buildMonthGrid(view.anchor).map((c) => c.dayKey);
    return weekDays.map((d) => d.dayKey);
  }, [isMobile, view.mode, view.anchor, weekDays]);

  const density = useMemo(
    () => densitiesByDay(densityDays, occurrences, timeZone),
    [densityDays, occurrences, timeZone],
  );

  const selectedAgenda = useMemo(
    () => buildDayAgenda(selectedDayKey, occurrences, timeZone),
    [selectedDayKey, occurrences, timeZone],
  );

  // Month day click: default a 1-hour slot at 09:00 local on the clicked day.
  // A click names a wall clock on a date; createTimesAt keeps the date and
  // never moves a time that does not exist (R1-P, docs/p8-datetime-contract.md §10).
  const openCreateForDay = (dayKey: string) => {
    setDialog({ mode: 'create', ...createTimesAt(dayKey, 9 * 60, timeZone) });
  };

  // Week/day time-slot click: 1-hour slot starting at the clicked time.
  const openCreateForSlot = (dayKey: string, minutes: number) => {
    setDialog({ mode: 'create', ...createTimesAt(dayKey, minutes, timeZone) });
  };

  const openEdit = (occ: EventOccurrence) => {
    // Resolve the series master (if any) so the dialog can offer edit scope.
    const masterId = occ.isException
      ? occ.event.recurrenceId
      : occ.event.rrule
        ? occ.event.id
        : null;
    const master = masterId ? events.rows.find((r) => r.id === masterId) ?? null : null;
    setDialog({ mode: 'edit', occurrence: occ, master });
  };

  // The dialog closes itself on success; these persist and rethrow on failure so
  // the dialog can surface SeriesEditBlockedError / DuplicateExceptionError inline.
  const handleSave = async (result: SaveResult) => {
    if (result.kind === 'create') {
      await events.create(result.input);
    } else if (result.kind === 'updateOne') {
      // rowPatchFromEdit is the single place an edit decides anything about
      // `timezone`; editOccurrence routes through it too for scope 'all'.
      await events.update(result.row.id, rowPatchFromEdit(result.row, result.input, result.intent));
    } else {
      await events.editOccurrence(result.occ, result.input, result.scope, result.intent);
    }
  };

  const handleDelete = async (result: DeleteResult) => {
    if (result.kind === 'deleteOne') await events.remove(result.id);
    else await events.deleteOccurrence(result.occ, result.scope);
  };

  return (
    <div className="calendar-page">
      <div className="calendar-topbar">
        {/* The desktop toolbar offers month/week/day, none of which a phone
            renders. MobileCalendar carries its own period bar and its own two
            modes, so showing this one as well would be two sets of controls
            for the same thing. */}
        {!isMobile && <CalendarToolbar view={view} timeZone={timeZone} />}
        {isSupabaseConfigured && (
          <button className="btn" onClick={() => setShareOpen(true)}>{tr('calendar.share')}</button>
        )}
      </div>

      {/* Both halves of this sentence come from the same resolved language:
          the wrapper through tr(), the detail through caughtErrorText. Reading
          `events.error.cause` here -- rather than a string the hook built --
          is what lets a language change update the banner. */}
      {events.error && (
        <p className="banner error">
          {tr('calendar.loadError', { message: caughtErrorText(events.error.cause, language) })}
        </p>
      )}

      {/* K12: a series whose rule cannot be expanded is left off the calendar
          (the rest is drawn as usual) -- said here, not silently. A count only:
          this is the owner's own screen, but naming rows is not needed to act. */}
      {events.unexpandableSeries.length > 0 && (
        <p className="banner warn" role="status">
          {tr('calendar.unexpandableSeries', { count: String(events.unexpandableSeries.length) })}
        </p>
      )}

      {isAwaitingRows({ loading: events.loading, rowCount: events.rows.length }) ? (
        // Nothing has arrived yet: an empty grid here would read as "no events".
        // The placeholder reserves the box the incoming view will occupy — sized
        // from the same tokens that view uses — so the grid's arrival does not
        // shove the page down. Which box depends on the mode we are about to
        // render, hence the same month/other split as the branches below.
        <div
          className={`app-loading calendar-placeholder calendar-placeholder--${
            view.mode === 'month' ? 'month' : 'timegrid'
          }`}
          style={view.mode === 'month' ? monthSlotsStyle(monthSlots) : undefined}
        >
          {tr('common.loading')}
        </div>
      ) : isMobile ? (
        <MobileCalendar
          view={view}
          selectedDayKey={selectedDayKey}
          weekDays={weekDays}
          density={density}
          agenda={selectedAgenda}
          onSelectDay={(dayKey) => view.goTo(new Date(`${dayKey}T12:00:00`))}
          onOccurrenceClick={openEdit}
          onCreateOnDay={openCreateForDay}
        />
      ) : view.mode === 'month' ? (
        <MonthView
          anchor={view.anchor}
          timeZone={timeZone}
          occurrences={occurrences}
          onDayClick={openCreateForDay}
          onOccurrenceClick={openEdit}
          onDayAgendaOpen={setAgendaDay}
        />
      ) : (
        <TimeGridView
          days={days}
          occurrences={occurrences}
          timeZone={timeZone}
          onSlotClick={openCreateForSlot}
          onOccurrenceClick={openEdit}
        />
      )}

      {dialog && (
        <EventDialog
          state={dialog}
          timeZone={timeZone}
          onSave={handleSave}
          onDelete={handleDelete}
          onSetSeriesTimezone={events.setSeriesTimezone}
          onClose={() => setDialog(null)}
        />
      )}

      {/* Rendered before EventDialog would be, but they never coexist: opening an
          entry closes the agenda in the same click. */}
      {agenda && (
        <DayAgendaDialog
          agenda={agenda}
          onOccurrenceClick={openEdit}
          onClose={() => setAgendaDay(null)}
        />
      )}

      {shareOpen && <ShareDialog onClose={() => setShareOpen(false)} />}
    </div>
  );
}
