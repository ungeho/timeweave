import { useMemo, useState } from 'react';
import type { EventOccurrence } from '../../types/event';
import { useCalendarView } from '../../hooks/useCalendarView';
import { useEvents } from '../../hooks/useEvents';
import { rowPatchFromEdit } from '../../services/exceptionEdit';
import { isSupabaseConfigured } from '../../lib/supabase';
import { getUserTimeZone, instantFromZonedDayMinutes } from '../../utils/timezone';
import { ShareDialog } from '../share/ShareDialog';
import { CalendarToolbar } from './CalendarToolbar';
import { MonthView } from './MonthView';
import { TimeGridView } from './TimeGridView';
import { isAwaitingRows } from './loadState';
import { monthGridRange } from './monthGrid';
import { buildDayCell, buildWeekDays, dayRange, weekRange } from './weekGrid';
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
  const view = useCalendarView('month');
  const events = useEvents();
  const [dialog, setDialog] = useState<DialogState | null>(null);
  const [shareOpen, setShareOpen] = useState(false);
  const timeZone = useMemo(() => getUserTimeZone(), []);

  const range = useMemo(() => {
    if (view.mode === 'month') return monthGridRange(view.anchor);
    if (view.mode === 'week') return weekRange(view.anchor, timeZone);
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

  // Month day click: default a 1-hour slot at 09:00 local on the clicked day.
  const openCreateForDay = (dayKey: string) => {
    setDialog({
      mode: 'create',
      startAt: instantFromZonedDayMinutes(dayKey, 9 * 60, timeZone),
      endAt: instantFromZonedDayMinutes(dayKey, 10 * 60, timeZone),
    });
  };

  // Week/day time-slot click: 1-hour slot starting at the clicked time.
  const openCreateForSlot = (dayKey: string, minutes: number) => {
    setDialog({
      mode: 'create',
      startAt: instantFromZonedDayMinutes(dayKey, minutes, timeZone),
      endAt: instantFromZonedDayMinutes(dayKey, minutes + 60, timeZone),
    });
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
        <CalendarToolbar view={view} timeZone={timeZone} />
        {isSupabaseConfigured && (
          <button className="btn" onClick={() => setShareOpen(true)}>共有</button>
        )}
      </div>

      {events.error && <p className="banner error">読み込みエラー: {events.error}</p>}

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
        >
          読み込み中…
        </div>
      ) : view.mode === 'month' ? (
        <MonthView
          anchor={view.anchor}
          timeZone={timeZone}
          occurrences={occurrences}
          onDayClick={openCreateForDay}
          onOccurrenceClick={openEdit}
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

      {shareOpen && <ShareDialog onClose={() => setShareOpen(false)} />}
    </div>
  );
}
