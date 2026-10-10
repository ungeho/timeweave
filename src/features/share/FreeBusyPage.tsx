/**
 * Anonymous, read-only Free/Busy view for a share token (route /s/:token).
 * Rendered OUTSIDE AuthGate. No clicks, no editing, no event details.
 *
 * Safety: on any fetch error (the RPC's 92-day 22023, and 0019's rate-limit and
 * busy refusals, included) the page shows a failure state — it NEVER falls back
 * to an empty "all free" grid. The wording comes from freeBusyErrorBanner, which
 * keeps the "this is not 'no events'" note on every branch. When the RPC reports
 * complete=false, a prominent warning states that unshown times must not be
 * assumed free.
 *
 * An empty grid is never left to speak for itself either: `get_free_busy` answers
 * `{ complete: true, slots: [] }` for a revoked, expired or unknown token exactly
 * as it does for a free owner — identical bytes, so that the RPC cannot be used as
 * an existence oracle — so a note covering both readings accompanies that case.
 *
 * Slots are re-merged client-side with mergeFreeBusySlots before display. The RPC
 * already merges server-side; running the same algorithm here means a future RPC
 * change (or an unmerged fallback) can never leak event count or boundaries
 * through adjacent/overlapping blocks rendered separately.
 */

import { useEffect, useMemo, useState } from 'react';
import { isSupabaseConfigured } from '../../lib/supabase';
import { getFreeBusy } from '../../repositories/shareRepository';
import { mergeFreeBusySlots } from '../../services/mergeIntervals';
import type { FreeBusyResult } from '../../types/share';
import { getUserTimeZone } from '../../utils/timezone';
import { addDaysToDateString, formatTime } from '../../utils/datetime';
import { useCalendarView } from '../../hooks/useCalendarView';
import { buildWeekDays, weekRange, weekTitle } from '../calendar/weekGrid';
import { busyForDay, hasNoDisclosedBusy } from './freeBusyLayout';
import { freeBusyErrorBanner } from './freeBusyBanner';
import {
  ACTIVE_EMPTY_MESSAGE,
  UNAVAILABLE_MESSAGE,
  freeBusyPresentation,
} from './freeBusyPresentation';
import {
  AVAILABLE_EMPTY_MESSAGE,
  AVAILABLE_INDETERMINATE_MESSAGE,
  availablePresentation,
  availableSlots,
  hasDisclosedAvailable,
} from './availablePresentation';

type Load =
  | { status: 'loading' }
  // The banner text is resolved once, at the moment of failure, so the render
  // path stays free of error-shape knowledge.
  | { status: 'error'; message: string }
  | { status: 'ok'; result: FreeBusyResult };

const WEEKDAY_LABELS = ['月', '火', '水', '木', '金', '土', '日'];

export function FreeBusyPage({ token }: { token: string }) {
  const view = useCalendarView('week');
  const timeZone = useMemo(() => getUserTimeZone(), []);
  const [load, setLoad] = useState<Load>({ status: 'loading' });

  const days = useMemo(() => buildWeekDays(view.anchor, timeZone), [view.anchor, timeZone]);

  useEffect(() => {
    if (!isSupabaseConfigured) return;
    let cancelled = false;
    setLoad({ status: 'loading' });

    const { startIso, endIso } = weekRange(view.anchor, timeZone);
    const fromDate = days[0]!.dayKey;
    const toDate = addDaysToDateString(days[days.length - 1]!.dayKey, 1); // exclusive

    getFreeBusy(token, startIso, endIso, fromDate, toDate)
      .then((result) => {
        // Defensive re-merge: collapse any overlapping/adjacent blocks the RPC
        // did not already merge, so the grid shows availability only.
        //
        // Applied to the available set too, and for the identical reason: two
        // adjacent open blocks rendered separately would disclose that the
        // owner has two available events there rather than one, which is a
        // count this page must never leak. Only the 'complete' state is
        // rewritten -- the other two carry no slots, so there is nothing to
        // merge and nothing to invent.
        if (!cancelled) {
          setLoad({
            status: 'ok',
            result: {
              ...result,
              slots: mergeFreeBusySlots(result.slots),
              available:
                result.available.status === 'complete'
                  ? { status: 'complete', slots: mergeFreeBusySlots(result.available.slots) }
                  : result.available,
            },
          });
        }
      })
      .catch((cause: unknown) => {
        // Includes 0019's two rate-limit refusals, 22023 and network errors.
        // Do NOT show an empty grid as free -- freeBusyErrorBanner keeps that
        // note on every branch.
        if (!cancelled) setLoad({ status: 'error', message: freeBusyErrorBanner(cause) });
      });

    return () => {
      cancelled = true;
    };
  }, [token, view.anchor, timeZone, days]);

  if (!isSupabaseConfigured) {
    return (
      <div className="freebusy-page">
        <p className="banner error">共有機能は利用できません。</p>
      </div>
    );
  }

  // 0023. An unavailable link is a SUCCESSFUL answer, not a fetch failure, so it
  // is decided here rather than in the error branch. Everything that belongs to
  // a readable calendar is withheld: the week navigation (which would refetch
  // per week for a link that can never answer), the grid (which must not be left
  // showing a previously rendered week), the completeness warning, the empty-
  // period notice and the busy-semantics footer. Header plus one generic line.
  if (freeBusyPresentation(load) === 'unavailable') {
    return (
      <div className="freebusy-page">
        <header className="freebusy-header">
          <div className="brand">TimeWeave</div>
          <span className="freebusy-subtitle">空き時間（読み取り専用）</span>
        </header>
        <p className="banner warn" role="alert">{UNAVAILABLE_MESSAGE}</p>
      </div>
    );
  }

  return (
    <div className="freebusy-page">
      <header className="freebusy-header">
        <div className="brand">TimeWeave</div>
        <span className="freebusy-subtitle">空き時間（読み取り専用）</span>
      </header>

      <div className="toolbar">
        <div className="toolbar-nav">
          <button className="btn" onClick={view.today}>今週</button>
          <button className="btn icon" aria-label="前の週" onClick={view.prev}>‹</button>
          <button className="btn icon" aria-label="次の週" onClick={view.next}>›</button>
          <h2 className="toolbar-title">{weekTitle(view.anchor, timeZone)}</h2>
        </div>
      </div>

      {load.status === 'ok' && !load.result.complete && (
        <p className="banner warn" role="alert">
          この期間には未対応の繰り返し予定が含まれています。表示されていない時間も空いているとは限りません。
        </p>
      )}

      {/* hasNoDisclosedBusy reads the BUSY set alone, which was the whole answer
          before 0024. It no longer is: a week with available events and no busy
          ones satisfies it while open time is drawn below, and the notice would
          then say nothing is shared directly above the blocks being shared. */}
      {load.status === 'ok' &&
        hasNoDisclosedBusy(load.result) &&
        !hasDisclosedAvailable(load.result.available) && (
          <p className="banner info">{ACTIVE_EMPTY_MESSAGE}</p>
        )}

      {/* Its own banner, never folded into the busy completeness warning above.
          The two computations fail independently -- busy can be exact while
          available is not -- and a single combined sentence would make either
          one speak for the other. role="alert" matches the busy warning: both
          say that what is on screen is not the whole picture. */}
      {load.status === 'ok' && availablePresentation(load.result.available) === 'indeterminate' && (
        <p className="banner warn" role="alert">{AVAILABLE_INDETERMINATE_MESSAGE}</p>
      )}

      {/* Only for an opted-in link that computed an exact, empty answer. An
          opted-out link ('hidden') says nothing here, because it was never
          asked -- "no open time is shared" would be a claim about a question
          nobody put. */}
      {load.status === 'ok' &&
        availablePresentation(load.result.available) === 'slots' &&
        availableSlots(load.result.available).length === 0 && (
          <p className="banner info">{AVAILABLE_EMPTY_MESSAGE}</p>
        )}

      {load.status === 'error' && (
        <p className="banner error" role="alert">{load.message}</p>
      )}

      {load.status === 'loading' && <p className="freebusy-loading">読み込み中…</p>}

      {load.status === 'ok' && (
        <div className="freebusy-week">
          {days.map((cell) => {
            const busy = busyForDay(cell.dayKey, timeZone, load.result.slots);
            const hasBusy = busy.allDayCount > 0 || busy.timed.length > 0;
            // The SAME day-intersection helper as busy: available slots arrive
            // in the identical wire shape, so clipping them to the day and
            // matching all-day ones by date is the same problem, already
            // tested. availableSlots yields [] for every state but 'complete',
            // so an indeterminate answer cannot produce blocks here.
            const open = busyForDay(cell.dayKey, timeZone, availableSlots(load.result.available));
            const hasOpen = open.allDayCount > 0 || open.timed.length > 0;
            return (
              <div key={cell.dayKey} className={`freebusy-day${cell.isToday ? ' today' : ''}`}>
                <div className="freebusy-day-head">
                  <span className="freebusy-dow">{WEEKDAY_LABELS[cell.weekdayIndex]}</span>
                  <span className="freebusy-dom">{cell.dayOfMonth}</span>
                </div>
                <div className="freebusy-day-body">
                  {busy.allDayCount > 0 && (
                    <div className="freebusy-block allday" aria-label="終日 予定あり">終日 予定あり</div>
                  )}
                  {busy.timed.map((t) => (
                    <div key={t.start} className="freebusy-block" aria-label="予定あり">
                      {formatTime(t.start)}–{formatTime(t.end)}
                    </div>
                  ))}
                  {/* Available blocks come AFTER the busy ones and carry their
                      own class and aria-label, so the two are distinguishable
                      without colour alone. The keys are prefixed because an
                      available block may legitimately start at the same instant
                      a busy one does. */}
                  {open.allDayCount > 0 && (
                    <div className="freebusy-block allday available" aria-label="終日 空き時間">終日 空き時間</div>
                  )}
                  {open.timed.map((t) => (
                    <div key={`a-${t.start}`} className="freebusy-block available" aria-label="空き時間">
                      {formatTime(t.start)}–{formatTime(t.end)}
                    </div>
                  ))}
                  {/* The dash means "nothing disclosed for this day", so it
                      belongs only where neither set put anything. It never
                      means free -- the footer and the banners carry that. */}
                  {!hasBusy && !hasOpen && <div className="freebusy-free">—</div>}
                </div>
              </div>
            );
          })}
        </div>
      )}

      {/* The footer has to change when open time is on screen, because the old
          sentence ("only whether there is an event") stops being true the
          moment an available block is drawn. It is keyed on the presentation
          rather than on whether any slot happened to land in this week, so a
          viewer of an opted-in link gets the same explanation on a week that
          shows nothing as on one that shows blocks. */}
      <p className="freebusy-note">
        {load.status === 'ok' && availablePresentation(load.result.available) === 'slots'
          ? '表示されるのは予定の有無（busy）と、共有者が明示した空き時間（available）だけで、内容は共有されません。空き時間として表示されていない時間が空いているとは限りません。'
          : '表示されるのは予定の有無（busy）のみで、内容は共有されません。'}
      </p>
    </div>
  );
}
