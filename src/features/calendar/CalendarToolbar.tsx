import type { CalendarView, ViewMode } from '../../hooks/useCalendarView';
import { useLanguage, useTranslate } from '../../i18n/useLanguage';
import { intlLocale } from '../../i18n/resolveLanguage';
import { monthTitle } from './monthGrid';
import { dayTitle, weekTitle } from './weekGrid';

interface Props {
  view: CalendarView;
  timeZone: string;
}

/**
 * The three view buttons, carrying a MESSAGE KEY rather than a label.
 *
 * `as const` keeps each key a literal type, so `tr(m.key)` type-checks as a
 * message with no variables instead of widening to the whole MessageKey union
 * (which would then demand a vars argument), and it keeps each `value` a
 * literal, so the assertion below can prove the row still offers every
 * ViewMode. The previous annotation only checked that each value WAS a
 * ViewMode: a dropped button type-checked fine and simply disappeared.
 */
const MODES = [
  { value: 'month', key: 'calendar.view.month' },
  { value: 'week', key: 'calendar.view.week' },
  { value: 'day', key: 'calendar.view.day' },
] as const;

type ModeValues = (typeof MODES)[number]['value'];

/**
 * The toolbar offers every DESKTOP mode, and only real modes.
 *
 * It used to compare against the whole `ViewMode` union, which was right while
 * every mode belonged here. P8-b2 adds `'agenda'`, which is mobile-only and
 * deliberately absent from this toolbar -- so the first half now excludes it
 * by name. Naming it is the point: a mode that is skipped has to be skipped on
 * purpose, in writing, rather than by a check that was relaxed until it passed.
 *
 * The second half is unchanged and still catches the original hazard -- a
 * button for a mode that does not exist, which type-checked fine and simply
 * disappeared.
 */
type DesktopMode = Exclude<ViewMode, 'agenda'>;
const _modeParity: [Exclude<DesktopMode, ModeValues>, Exclude<ModeValues, ViewMode>] extends
  [never, never] ? true : never = true;
void _modeParity;

/** Prev / next / today, period title, and view-mode switch. */
export function CalendarToolbar({ view, timeZone }: Props) {
  const tr = useTranslate();
  // The three period titles are DATE FORMATS, so they take a locale rather
  // than a dictionary key. All three get the SAME one, from the same
  // resolved language -- switching view must not switch date convention.
  const { language } = useLanguage();
  const locale = intlLocale(language);
  const title =
    view.mode === 'month'
      ? monthTitle(view.anchor, locale)
      : view.mode === 'week'
        ? weekTitle(view.anchor, timeZone, locale)
        : dayTitle(view.anchor, timeZone, locale);

  return (
    <div className="toolbar">
      <div className="toolbar-nav">
        <button className="btn" onClick={view.today}>{tr('calendar.today')}</button>
        {/* ‹ and › are the only visible content, so the aria-label IS the
            button's name for a screen reader. It is translated for that
            reason, not for decoration. */}
        <button className="btn icon" aria-label={tr('calendar.prev')} onClick={view.prev}>‹</button>
        <button className="btn icon" aria-label={tr('calendar.next')} onClick={view.next}>›</button>
        <h2 className="toolbar-title">{title}</h2>
      </div>
      <div className="toolbar-modes">
        {MODES.map((m) => (
          <button
            key={m.value}
            className={`btn ${view.mode === m.value ? 'active' : ''}`}
            onClick={() => view.setMode(m.value)}
          >
            {tr(m.key)}
          </button>
        ))}
      </div>
    </div>
  );
}
