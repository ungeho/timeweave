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
import { useLanguage, useTranslate } from '../../i18n/useLanguage';
import { weekdayShort } from '../../i18n/dateNames';
import { mergeFreeBusySlots } from '../../services/mergeIntervals';
import type { FreeBusyResult } from '../../types/share';
import { getUserTimeZone } from '../../utils/timezone';
import { addDaysToDateString, formatTime } from '../../utils/datetime';
import { intlLocale } from '../../i18n/resolveLanguage';
import { useCalendarView } from '../../hooks/useCalendarView';
import { buildWeekDays, weekRange, weekTitle } from '../calendar/weekGrid';
import { busyForDay, hasNoDisclosedBusy } from './freeBusyLayout';
import { freeBusyErrorBanner } from './freeBusyBanner';
import { freeBusyLegend } from './freeBusyLegend';
import {
  activeEmptyMessage,
  blockAccessibleName,
  unavailableMessage,
  freeBusyPresentation,
} from './freeBusyPresentation';
import {
  availableEmptyMessage,
  availableIndeterminateMessage,
  availablePresentation,
  availableSlots,
  hasDisclosedAvailable,
} from './availablePresentation';

type Load =
  | { status: 'loading' }
  // THE CAUSE, NOT THE SENTENCE. This used to hold the resolved banner text,
  // built at the moment of failure. That pinned the wording to whatever
  // language was current when the fetch rejected, so a later language change
  // re-rendered every other string on the page and left this one behind.
  // Keeping the cause moves the wording into the render pass, where the
  // viewer's language is known; freeBusyErrorBanner still owns all knowledge
  // of error shapes, so the JSX below learns none of it.
  | { status: 'error'; cause: unknown }
  | { status: 'ok'; result: FreeBusyResult };

export function FreeBusyPage({ token }: { token: string }) {
  // The ANONYMOUS viewer's language, resolved from their own browser. The
  // owner's preference is never fetched on this route -- anon holds no
  // privilege on owner_settings, and showing a stranger the owner's language
  // would be the wrong answer even if it did.
  const tr = useTranslate();
  // The same resolved language the copy above uses -- the ANONYMOUS
  // viewer's, from their own browser. Reading it here starts no fetch: the
  // provider on this route carries isPublicRoute, so owner_settings is
  // never asked for.
  const { language } = useLanguage();
  const view = useCalendarView('week');
  // The ANONYMOUS viewer’s locale, from the language their own browser
  // resolved -- never the owner’s. The ZONE below is a separate concern and
  // stays the viewer’s too; the language decides only how a time reads.
  const locale = intlLocale(language);
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
        if (!cancelled) setLoad({ status: 'error', cause });
      });

    return () => {
      cancelled = true;
    };
  }, [token, view.anchor, timeZone, days]);

  if (!isSupabaseConfigured) {
    return (
      <div className="freebusy-page" lang={language}>
        <p className="banner error">{tr('sharePage.disabled')}</p>
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
      <div className="freebusy-page" lang={language}>
        <header className="freebusy-header">
          <div className="brand">TimeWeave</div>
          <span className="freebusy-subtitle">{tr('sharePage.subtitle')}</span>
        </header>
        <p className="banner warn" role="alert">{unavailableMessage(language)}</p>
      </div>
    );
  }

  return (
    <div className="freebusy-page" lang={language}>
      <header className="freebusy-header">
        <div className="brand">TimeWeave</div>
        <span className="freebusy-subtitle">{tr('sharePage.subtitle')}</span>
      </header>

      <div className="toolbar">
        <div className="toolbar-nav">
          <button className="btn" onClick={view.today}>{tr('sharePage.thisWeek')}</button>
          <button className="btn icon" aria-label={tr('sharePage.prevWeek')} onClick={view.prev}>‹</button>
          <button className="btn icon" aria-label={tr('sharePage.nextWeek')} onClick={view.next}>›</button>
          <h2 className="toolbar-title">{weekTitle(view.anchor, timeZone, locale)}</h2>
        </div>
      </div>

      {/* P8-mobile-2: what the blocks mean, in words, before any of them. It
          names only what can be drawn for THIS link (freeBusyLegend.ts) and
          always ends with the caveat that empty time is not necessarily free.
          The swatches repeat the blocks' own fill / outline-and-hatch, and are
          decorative: the words carry the meaning. */}
      {load.status === 'ok' && (() => {
        const legend = freeBusyLegend(load.result.available);
        return (
          <section className="freebusy-legend" aria-labelledby="freebusy-legend-title">
            <h3 id="freebusy-legend-title" className="freebusy-legend-title">{tr(legend.headingKey)}</h3>
            <ul className="freebusy-legend-items">
              <li>
                <span className="freebusy-swatch" aria-hidden="true" />
                <span>{tr('legend.busy')}</span>
              </li>
              {legend.available && (
                <li>
                  <span className="freebusy-swatch available" aria-hidden="true" />
                  <span>{tr('legend.available')}</span>
                </li>
              )}
            </ul>
            <p className="freebusy-legend-note">{tr(legend.noteKey)}</p>
          </section>
        );
      })()}

      {load.status === 'ok' && !load.result.complete && (
        <p className="banner warn" role="alert">
          {tr('sharePage.incompleteWarning')}
        </p>
      )}

      {/* hasNoDisclosedBusy reads the BUSY set alone, which was the whole answer
          before 0024. It no longer is: a week with available events and no busy
          ones satisfies it while open time is drawn below, and the notice would
          then say nothing is shared directly above the blocks being shared. */}
      {load.status === 'ok' &&
        hasNoDisclosedBusy(load.result) &&
        !hasDisclosedAvailable(load.result.available) && (
          <p className="banner info">{activeEmptyMessage(language)}</p>
        )}

      {/* Its own banner, never folded into the busy completeness warning above.
          The two computations fail independently -- busy can be exact while
          available is not -- and a single combined sentence would make either
          one speak for the other. role="alert" matches the busy warning: both
          say that what is on screen is not the whole picture. */}
      {load.status === 'ok' && availablePresentation(load.result.available) === 'indeterminate' && (
        <p className="banner warn" role="alert">{availableIndeterminateMessage(language)}</p>
      )}

      {/* Only for an opted-in link that computed an exact, empty answer. An
          opted-out link ('hidden') says nothing here, because it was never
          asked -- "no open time is shared" would be a claim about a question
          nobody put. */}
      {load.status === 'ok' &&
        availablePresentation(load.result.available) === 'slots' &&
        availableSlots(load.result.available).length === 0 && (
          <p className="banner info">{availableEmptyMessage(language)}</p>
        )}

      {load.status === 'error' && (
        <p className="banner error" role="alert">{freeBusyErrorBanner(load.cause, language)}</p>
      )}

      {load.status === 'loading' && <p className="freebusy-loading">{tr('sharePage.loading')}</p>}

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
                  <span className="freebusy-dow">{weekdayShort(language, cell.weekdayIndex)}</span>
                  <span className="freebusy-dom">{cell.dayOfMonth}</span>
                </div>
                <div className="freebusy-day-body">
                  {busy.allDayCount > 0 && (
                    <div className="freebusy-block allday" aria-label={tr('sharePage.block.busyAllDay')}>{tr('sharePage.block.busyAllDay')}</div>
                  )}
                  {/* The accessible name repeats the RANGE as well as the
                      state: aria-label replaces the element's contents, so a
                      label of "Busy" alone meant the time was never read out.
                      Both halves are built from the same two strings that are
                      rendered, so they cannot disagree. */}
                  {busy.timed.map((t) => {
                    const start = formatTime(t.start, locale);
                    const end = formatTime(t.end, locale);
                    return (
                      <div
                        key={t.start}
                        className="freebusy-block"
                        aria-label={blockAccessibleName('busy', start, end, language)}
                      >
                        <span className="freebusy-block-state">{tr('sharePage.block.busy')}</span>{' '}
                        <span className="freebusy-block-time">{start}–{end}</span>
                      </div>
                    );
                  })}
                  {/* Available blocks come AFTER the busy ones and carry their
                      own class and aria-label, so the two are distinguishable
                      without colour alone. The keys are prefixed because an
                      available block may legitimately start at the same instant
                      a busy one does. */}
                  {open.allDayCount > 0 && (
                    <div className="freebusy-block allday available" aria-label={tr('sharePage.block.availableAllDay')}>{tr('sharePage.block.availableAllDay')}</div>
                  )}
                  {open.timed.map((t) => {
                    const start = formatTime(t.start, locale);
                    const end = formatTime(t.end, locale);
                    return (
                      <div
                        key={`a-${t.start}`}
                        className="freebusy-block available"
                        aria-label={blockAccessibleName('available', start, end, language)}
                      >
                        <span className="freebusy-block-state">{tr('sharePage.block.available')}</span>{' '}
                        <span className="freebusy-block-time">{start}–{end}</span>
                      </div>
                    );
                  })}
                  {/* The dash means "nothing disclosed for this day", so it
                      belongs only where neither set put anything. It never
                      means free -- the footer and the banners carry that. */}
                  {!hasBusy && !hasOpen && (
                    <div className="freebusy-free">
                      <span aria-hidden="true">—</span>
                      <span className="freebusy-sr-only">{tr('sharePage.day.nothing')}</span>
                    </div>
                  )}
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
          ? tr('sharePage.footer.withAvailable')
          : tr('sharePage.footer.busyOnly')}
      </p>
    </div>
  );
}
