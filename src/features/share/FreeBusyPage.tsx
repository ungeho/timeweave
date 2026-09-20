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
        if (!cancelled) {
          setLoad({
            status: 'ok',
            result: { ...result, slots: mergeFreeBusySlots(result.slots) },
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

      {load.status === 'ok' && hasNoDisclosedBusy(load.result) && (
        <p className="banner info">
          この期間に共有されている予定はありません。共有リンクが失効または期限切れの場合も同じ表示になります。
        </p>
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
                  {!hasBusy && <div className="freebusy-free">—</div>}
                </div>
              </div>
            );
          })}
        </div>
      )}

      <p className="freebusy-note">
        表示されるのは予定の有無（busy）のみで、内容は共有されません。
      </p>
    </div>
  );
}
