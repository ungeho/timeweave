import { useEffect, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react';
import { useLanguage, useTranslate } from '../../../i18n/useLanguage';
import { weekdayNamesShort, weekdayShort } from '../../../i18n/dateNames';
import { intlLocale } from '../../../i18n/resolveLanguage';
import { addDaysToDateString } from '../../../utils/datetime';
import { weekdayOfDayKey } from '../../../utils/timezone';
import { addMonthsClamped, dayKeyOf, monthGrid, parseDayKey, todayDayKey } from './calendarMonth';
import { DATE_TEMPLATES, parseDateText } from './dateTimeText';
import { GuidedInput } from './GuidedInput';
import { overlayKeyHandler, useReturnFocus, useVisualViewportBox } from './overlayHooks';

interface Props {
  /** committed "YYYY-MM-DD", or '' */
  value: string;
  /** bottom sheet (mobile layout) instead of a popover */
  sheet: boolean;
  /** accessible name of the dialog, e.g. "開始 日付" */
  title: string;
  /** desktop: the element the popover hangs from */
  anchor: HTMLElement | null;
  onSelect: (dayKey: string) => void;
  onCancel: () => void;
}

type View = 'days' | 'months' | 'years';

/**
 * Month calendar for the date fields (P8-b5.6b-2, from the approved
 * prototype). Monday first, month and year views behind the header, a Today
 * jump, keyboard navigation, no "clear" button.
 *
 * COMMITS ONLY ON A DATE. Browsing months, Today, the month/year views and
 * keyboard focus change nothing outside; only a click, tap or Enter on a day
 * calls onSelect. Esc, Cancel and a click outside call onCancel. Clearing a
 * date is done in the text field, where validation reports it.
 */
export function CalendarPicker({ value, sheet, title, anchor, onSelect, onCancel }: Props) {
  const { language } = useLanguage();
  const tr = useTranslate();
  const today = todayDayKey();
  const [focusKey, setFocusKey] = useState(parseDayKey(value) ? value : today);
  const [view, setView] = useState<View>('days');
  const [textMode, setTextMode] = useState(false);
  const [text, setText] = useState(value);
  const [textError, setTextError] = useState<{ reason: 'empty' | 'format' | 'nonexistent'; text: string } | null>(null);
  const panelRef = useRef<HTMLDivElement>(null);
  const gridRef = useRef<HTMLDivElement>(null);
  const moveFocus = useRef(true);
  const [pos, setPos] = useState<{ top: number; left: number } | null>(null);
  const vv = useVisualViewportBox(sheet);
  useReturnFocus();

  const f = parseDayKey(focusKey)!;
  const grid = useMemo(() => monthGrid(f.y, f.m), [f.y, f.m]);
  const locale = intlLocale(language);
  const utc = (key: string) => {
    const p = parseDayKey(key)!;
    return new Date(Date.UTC(p.y, p.m - 1, p.d));
  };
  const fmtMonth = new Intl.DateTimeFormat(locale, { year: 'numeric', month: 'long', timeZone: 'UTC' });
  const fmtMonthShort = new Intl.DateTimeFormat(locale, { month: 'short', timeZone: 'UTC' });
  const fmtFull = new Intl.DateTimeFormat(locale, { dateStyle: 'full', timeZone: 'UTC' });

  // Desktop: below the field if it fits, else above, else pinned inside the
  // viewport even if it covers the field (MEASURED in the prototype at
  // 720x700: neither side fitted) -- never cut off at an edge.
  useLayoutEffect(() => {
    if (sheet || !anchor || !panelRef.current) return;
    const a = anchor.getBoundingClientRect();
    const p = panelRef.current.getBoundingClientRect();
    const below = a.bottom + 4;
    const above = a.top - p.height - 4;
    let top = below;
    if (below + p.height > window.innerHeight - 8) {
      top = above >= 8 ? above : Math.max(8, window.innerHeight - p.height - 8);
    }
    const left = Math.max(8, Math.min(a.left, window.innerWidth - p.width - 8));
    setPos({ top, left });
  }, [sheet, anchor, view, textMode]);

  // Roving focus on the focused day. `pos` is a dependency on purpose: the
  // popover is visibility:hidden until positioned, a hidden button cannot take
  // focus, and in the prototype the first focus silently failed without it.
  useEffect(() => {
    if (view !== 'days' || textMode || !moveFocus.current) return;
    if (!sheet && !pos) return;
    gridRef.current?.querySelector<HTMLButtonElement>(`[data-day="${focusKey}"]`)?.focus();
  }, [focusKey, view, textMode, pos, sheet]);

  /** Move the focused day. Only keyboard navigation drags DOM focus along; the nav buttons keep it. */
  const go = (key: string, withFocus = false) => {
    moveFocus.current = withFocus;
    setFocusKey(key);
  };

  const onGridKey = (e: KeyboardEvent) => {
    const steps: Record<string, () => string> = {
      ArrowLeft: () => addDaysToDateString(focusKey, -1),
      ArrowRight: () => addDaysToDateString(focusKey, 1),
      ArrowUp: () => addDaysToDateString(focusKey, -7),
      ArrowDown: () => addDaysToDateString(focusKey, 7),
      Home: () => addDaysToDateString(focusKey, -weekdayOfDayKey(focusKey)),
      End: () => addDaysToDateString(focusKey, 6 - weekdayOfDayKey(focusKey)),
      PageUp: () => addMonthsClamped(focusKey, e.shiftKey ? -12 : -1),
      PageDown: () => addMonthsClamped(focusKey, e.shiftKey ? 12 : 1),
    };
    const step = steps[e.key];
    if (step) {
      e.preventDefault();
      go(step(), true);
    }
  };

  // Esc from the month/year views goes back to the days; from the days it cancels.
  const onPanelKey = overlayKeyHandler(panelRef, () => (view !== 'days' ? setView('days') : onCancel()));

  const commitText = () => {
    const r = parseDateText(text, f.y);
    if (!r.ok) {
      setTextError({ reason: r.reason, text });
      return;
    }
    onSelect(r.value);
  };

  const navLabel =
    view === 'days'
      ? ([tr('event.dt.cal.prevMonth'), tr('event.dt.cal.nextMonth')] as const)
      : view === 'months'
        ? ([tr('event.dt.cal.prevYear'), tr('event.dt.cal.nextYear')] as const)
        : ([tr('event.dt.cal.prevYears'), tr('event.dt.cal.nextYears')] as const);
  const navStep = view === 'days' ? 1 : view === 'months' ? 12 : 144;

  const header = (
    <div className="dt-cal-header">
      <button type="button" className="dt-cal-nav" aria-label={navLabel[0]} onClick={() => go(addMonthsClamped(focusKey, -navStep))}>
        ‹
      </button>
      <button
        type="button"
        className="dt-cal-title"
        aria-expanded={view !== 'days'}
        onClick={() => setView(view === 'days' ? 'months' : view === 'months' ? 'years' : 'days')}
      >
        {view === 'days' ? fmtMonth.format(utc(dayKeyOf(f.y, f.m, 1))) : view === 'months' ? `${f.y}` : `${f.y - 5} – ${f.y + 6}`}
        <span aria-hidden="true"> ▾</span>
      </button>
      <button type="button" className="dt-cal-nav" aria-label={navLabel[1]} onClick={() => go(addMonthsClamped(focusKey, navStep))}>
        ›
      </button>
    </div>
  );

  const textErrorMessage =
    textError === null
      ? null
      : textError.reason === 'empty'
        ? tr('event.error.dateRequired')
        : textError.reason === 'nonexistent'
          ? tr('event.dt.date.nonexistent', { value: textError.text })
          : tr('event.dt.date.format');

  const body = textMode ? (
    <div className="dt-cal-text">
      <div className={`dt-group ${textError ? 'is-invalid' : ''}`}>
        <GuidedInput
          autoFocus
          inputMode="numeric"
          aria-label={title}
          aria-invalid={textError !== null}
          templates={DATE_TEMPLATES}
          autoHyphen
          value={text}
          // Opened with the committed value: select it, so typing replaces it.
          onFocus={(e) => e.currentTarget.select()}
          onValueChange={(v) => {
            setText(v);
            setTextError(null);
          }}
          onKeyDown={(e) => {
            // preventDefault: MEASURED in the prototype, the same Enter otherwise
            // reached the tap target focus returns to and reopened the sheet.
            if (e.key === 'Enter') {
              e.preventDefault();
              commitText();
            }
          }}
        />
      </div>
      <p className="form-hint">{tr('event.dt.cal.digitsHint')}</p>
      {textErrorMessage && <p className="form-error" role="alert">{textErrorMessage}</p>}
    </div>
  ) : view === 'days' ? (
    <div ref={gridRef} className="dt-cal-grid" role="grid" aria-label={fmtMonth.format(utc(dayKeyOf(f.y, f.m, 1)))} onKeyDown={onGridKey}>
      <div className="dt-cal-row" role="row">
        {weekdayNamesShort(language).map((w, i) => (
          <span key={i} role="columnheader" className={`dt-cal-wd ${i >= 5 ? 'is-weekend' : ''}`}>{w}</span>
        ))}
      </div>
      {Array.from({ length: 6 }, (_, r) => (
        <div className="dt-cal-row" role="row" key={r}>
          {grid.slice(r * 7, r * 7 + 7).map(({ key, inMonth }) => {
            const selected = key === value;
            return (
              <span role="gridcell" key={key} aria-selected={selected}>
                <button
                  type="button"
                  data-day={key}
                  tabIndex={key === focusKey ? 0 : -1}
                  className={`dt-cal-day${inMonth ? '' : ' is-outside'}${selected ? ' is-selected' : ''}${key === today ? ' is-today' : ''}`}
                  aria-label={fmtFull.format(utc(key))}
                  aria-current={key === today ? 'date' : undefined}
                  onClick={() => onSelect(key)}
                >
                  {parseDayKey(key)!.d}
                </button>
              </span>
            );
          })}
        </div>
      ))}
    </div>
  ) : view === 'months' ? (
    <div className="dt-cal-picks">
      {Array.from({ length: 12 }, (_, i) => (
        <button
          key={i}
          type="button"
          className={`dt-cal-pick${i + 1 === f.m ? ' is-selected' : ''}`}
          onClick={() => {
            moveFocus.current = true;
            setFocusKey(addMonthsClamped(focusKey, i + 1 - f.m));
            setView('days');
          }}
        >
          {fmtMonthShort.format(utc(dayKeyOf(2024, i + 1, 1)))}
        </button>
      ))}
    </div>
  ) : (
    <div className="dt-cal-picks">
      {Array.from({ length: 12 }, (_, i) => {
        const y = f.y - 5 + i;
        return (
          <button
            key={y}
            type="button"
            className={`dt-cal-pick${y === f.y ? ' is-selected' : ''}`}
            onClick={() => {
              moveFocus.current = false;
              setFocusKey(addMonthsClamped(focusKey, (y - f.y) * 12));
              setView('months');
            }}
          >
            {y}
          </button>
        );
      })}
    </div>
  );

  return (
    <div
      className={`dt-overlay ${sheet ? 'is-sheet' : 'is-popover'}${textMode ? ' is-text' : ''}`}
      style={sheet && vv ? { top: vv.top, height: vv.height, bottom: 'auto' } : undefined}
      onPointerDown={(e) => {
        if (e.target === e.currentTarget) onCancel();
      }}
    >
      <div
        ref={panelRef}
        className={`dt-cal ${sheet ? 'is-sheet' : 'is-popover'}`}
        role="dialog"
        aria-modal={sheet}
        aria-label={title}
        style={!sheet ? (pos ? { top: pos.top, left: pos.left } : { visibility: 'hidden' }) : undefined}
        onKeyDown={onPanelKey}
      >
        {sheet && (
          <div className="dt-sheet-head">
            <span className="form-hint">{title}</span>
            <span className="dt-sheet-value">
              {value ? `${value} (${weekdayShort(language, weekdayOfDayKey(value))})` : '—'}
            </span>
          </div>
        )}
        {!textMode && header}
        {body}
        <div className="dt-actions">
          {!textMode && (
            <button type="button" className="btn dt-quiet" onClick={() => go(today, true)}>
              {tr('event.dt.cal.today')}
            </button>
          )}
          {sheet && (
            <button
              type="button"
              className="btn dt-quiet"
              onClick={() => {
                setTextMode(!textMode);
                setTextError(null);
              }}
            >
              {textMode ? tr('event.dt.toCalendar') : tr('event.dt.toText')}
            </button>
          )}
          <span className="dt-spacer" />
          <button type="button" className="btn" onClick={onCancel}>{tr('common.cancel')}</button>
          {textMode && (
            <button type="button" className="btn primary" onClick={commitText}>{tr('event.dt.confirm')}</button>
          )}
        </div>
      </div>
    </div>
  );
}
