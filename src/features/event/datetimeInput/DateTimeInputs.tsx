import { useEffect, useId, useRef, useState, type KeyboardEvent } from 'react';
import { useLanguage, useTranslate } from '../../../i18n/useLanguage';
import { weekdayShort } from '../../../i18n/dateNames';
import { addDaysToDateString } from '../../../utils/datetime';
import { weekdayOfDayKey } from '../../../utils/timezone';
import { CalendarPicker } from './CalendarPicker';
import { ClockDialog, type ClockMode } from './ClockDialog';
import {
  DATE_TEMPLATES, TIME_TEMPLATES, parseDateText, parseTimeText, stepTime,
  type DateTextError, type TimeTextError,
} from './dateTimeText';
import { GuidedInput } from './GuidedInput';

/**
 * The two inputs the event form is built from (P8-b5.6b-2).
 *
 * CONTRACT, identical to the native controls they replace: `value` is the
 * committed "YYYY-MM-DD" / "HH:mm", and `onCommit` hands back a new committed
 * value of the same shape. Neither knows about instants, zones or DST.
 *
 * DRAFT VS COMMITTED. Typing changes only the draft. The draft is parsed on
 * blur or Enter; until then nothing in the form changes and nothing is
 * reformatted. Esc puts the committed value back. A draft that cannot be
 * parsed keeps the committed value untouched, turns the field red, says why,
 * and is reported through `onInvalid` so the dialog refuses to save a value
 * the owner can no longer see.
 *
 * LAYOUT ROLES. Desktop (`mobile` false): the text field is the main control
 * and the calendar / clock are helpers behind a button. Mobile layout: a tap
 * target opens the calendar sheet or the clock, each with a text mode inside.
 */

interface FieldProps {
  /** Accessible name, e.g. "開始 日付". */
  label: string;
  value: string;
  mobile: boolean;
  onCommit: (v: string) => void;
  /** The current draft's problem, or null when the draft is fine. */
  onInvalid: (reason: string | null) => void;
}

/** Remembered across openings so an owner who prefers typing is not sent back to the dial. */
let lastClockMode: ClockMode = 'dial';

export function DateInput({ label, value, mobile, onCommit, onInvalid }: FieldProps) {
  const { language } = useLanguage();
  const tr = useTranslate();
  const [draft, setDraft] = useState(value);
  // Snapshotted: the message must name what was refused, not what is being typed now.
  const [error, setError] = useState<{ reason: DateTextError; text: string } | null>(null);
  const [focused, setFocused] = useState(false);
  const [open, setOpen] = useState(false);
  const editing = useRef(false);
  const groupRef = useRef<HTMLDivElement>(null);
  const hintId = useId();

  // A change from outside (the calendar, a reset of the form) refreshes an idle draft.
  useEffect(() => {
    if (!editing.current) {
      setDraft(value);
      setError(null);
      onInvalid(null);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value]);

  const fallbackYear = Number(value.slice(0, 4)) || undefined;
  const weekday = (key: string) => (/^\d{4}-\d{2}-\d{2}$/.test(key) ? weekdayShort(language, weekdayOfDayKey(key)) : '');

  const commit = () => {
    const r = parseDateText(draft, fallbackYear);
    if (!r.ok) {
      setError({ reason: r.reason, text: draft });
      onInvalid(r.reason);
      return;
    }
    setError(null);
    onInvalid(null);
    setDraft(r.value);
    if (r.value !== value) onCommit(r.value);
  };

  const picker = open && (
    <CalendarPicker
      value={value}
      sheet={mobile}
      title={label}
      anchor={groupRef.current}
      onCancel={() => setOpen(false)}
      onSelect={(key) => {
        setOpen(false);
        editing.current = false;
        setDraft(key);
        setError(null);
        onInvalid(null);
        if (key !== value) onCommit(key);
      }}
    />
  );

  const message =
    error === null
      ? null
      : error.reason === 'empty'
        ? tr('event.error.dateRequired')
        : error.reason === 'nonexistent'
          ? tr('event.dt.date.nonexistent', { value: error.text })
          : tr('event.dt.date.format');

  if (mobile) {
    return (
      <div className="dt-field">
        <button
          type="button"
          className={`dt-tap${error ? ' is-invalid' : ''}`}
          aria-label={`${label} ${value}`}
          aria-haspopup="dialog"
          onClick={() => setOpen(true)}
        >
          <span className="dt-tap-value">{value || '----/--/--'}</span>
          <span className="dt-weekday">{weekday(value)}</span>
          <span aria-hidden="true">📅</span>
        </button>
        {picker}
      </div>
    );
  }

  const live = focused && draft !== '' ? parseDateText(draft, fallbackYear) : null;
  return (
    <div className="dt-field">
      <div ref={groupRef} className={`dt-group${error ? ' is-invalid' : ''}`}>
        <GuidedInput
          className="dt-date"
          templates={DATE_TEMPLATES}
          autoHyphen
          value={draft}
          aria-label={label}
          aria-invalid={error !== null}
          aria-describedby={hintId}
          title={tr('event.dt.dateHint')}
          onFocus={() => {
            editing.current = true;
            setFocused(true);
          }}
          onBlur={() => {
            editing.current = false;
            setFocused(false);
            commit();
          }}
          onValueChange={setDraft}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              commit();
            } else if (e.key === 'Escape' && draft !== value) {
              // Revert the draft, and keep this Escape from closing the dialog.
              e.preventDefault();
              e.nativeEvent.stopImmediatePropagation();
              setDraft(value);
              setError(null);
              onInvalid(null);
            } else if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
              const r = parseDateText(draft, fallbackYear);
              if (!r.ok) return;
              e.preventDefault();
              const next = addDaysToDateString(r.value, e.key === 'ArrowUp' ? 1 : -1);
              setDraft(next);
              setError(null);
              onInvalid(null);
              onCommit(next);
            }
          }}
        />
        <span className="dt-weekday" aria-hidden="true">{weekday(value)}</span>
        <button
          type="button"
          className="dt-icon-btn"
          aria-label={tr('event.dt.openCalendar')}
          aria-haspopup="dialog"
          title={tr('event.dt.openCalendar')}
          onClick={() => setOpen(true)}
        >
          📅
        </button>
      </div>
      <span id={hintId} className="dt-sr-only">{tr('event.dt.dateFormat')}</span>
      {live?.ok && live.value !== draft && (
        <p className="dt-live" aria-hidden="true">→ {live.value} ({weekday(live.value)})</p>
      )}
      {message && <p className="form-error">{message}</p>}
      {picker}
    </div>
  );
}

export function TimeInput({ label, value, mobile, onCommit, onInvalid }: FieldProps) {
  const tr = useTranslate();
  const [draft, setDraft] = useState(value);
  const [error, setError] = useState<{ reason: TimeTextError; text: string } | null>(null);
  const [focused, setFocused] = useState(false);
  const [open, setOpen] = useState(false);
  const editing = useRef(false);
  const hintId = useId();

  useEffect(() => {
    if (!editing.current) {
      setDraft(value);
      setError(null);
      onInvalid(null);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value]);

  const commit = () => {
    const r = parseTimeText(draft);
    if (!r.ok) {
      setError({ reason: r.reason, text: draft });
      onInvalid(r.reason);
      return;
    }
    setError(null);
    onInvalid(null);
    setDraft(r.value);
    if (r.value !== value) onCommit(r.value);
  };

  const onKey = (e: KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      commit();
    } else if (e.key === 'Escape' && draft !== value) {
      e.preventDefault();
      e.nativeEvent.stopImmediatePropagation();
      setDraft(value);
      setError(null);
      onInvalid(null);
    } else if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
      const base = parseTimeText(draft);
      if (!base.ok) return;
      e.preventDefault();
      const caret = e.currentTarget.selectionStart ?? 0;
      const part = caret <= 2 ? 'hour' : 'minute';
      const next = stepTime(base.value, part, (e.key === 'ArrowUp' ? 1 : -1) * (e.shiftKey && part === 'minute' ? 5 : 1));
      setDraft(next);
      setError(null);
      onInvalid(null);
      onCommit(next);
      const el = e.currentTarget;
      requestAnimationFrame(() => el.setSelectionRange(part === 'hour' ? 0 : 3, part === 'hour' ? 2 : 5));
    }
  };

  const clock = open && (
    <ClockDialog
      value={parseTimeText(value).ok ? value : '00:00'}
      title={label}
      initialMode={lastClockMode}
      onCancel={(mode) => {
        lastClockMode = mode;
        setOpen(false);
      }}
      onConfirm={(v, mode) => {
        lastClockMode = mode;
        setOpen(false);
        editing.current = false;
        setDraft(v);
        setError(null);
        onInvalid(null);
        if (v !== value) onCommit(v);
      }}
    />
  );

  const message =
    error === null
      ? null
      : error.reason === 'empty'
        ? tr('event.dt.time.empty')
        : error.reason === 'hourRange'
          ? tr('event.dt.time.hourRange', { value: error.text })
          : error.reason === 'minuteRange'
            ? tr('event.dt.time.minuteRange', { value: error.text })
            : error.reason === 'ambiguous'
              ? tr('event.dt.time.ambiguous', { value: error.text })
              : tr('event.dt.time.format');

  if (mobile) {
    return (
      <div className="dt-field">
        <button
          type="button"
          className={`dt-tap${error ? ' is-invalid' : ''}`}
          aria-label={`${label} ${value}`}
          aria-haspopup="dialog"
          onClick={() => setOpen(true)}
        >
          <span className="dt-tap-value">{value || '--:--'}</span>
          <span aria-hidden="true">🕒</span>
        </button>
        {clock}
      </div>
    );
  }

  const live = focused && draft !== '' ? parseTimeText(draft) : null;
  return (
    <div className="dt-field">
      <div className={`dt-group${error ? ' is-invalid' : ''}`}>
        <GuidedInput
          className="dt-time"
          templates={TIME_TEMPLATES}
          value={draft}
          inputMode="numeric"
          aria-label={label}
          aria-invalid={error !== null}
          aria-describedby={hintId}
          title={tr('event.dt.timeHint')}
          onFocus={() => {
            editing.current = true;
            setFocused(true);
          }}
          onBlur={() => {
            editing.current = false;
            setFocused(false);
            commit();
          }}
          onValueChange={setDraft}
          onKeyDown={onKey}
        />
        <button
          type="button"
          className="dt-icon-btn"
          aria-label={tr('event.dt.openClock')}
          aria-haspopup="dialog"
          title={tr('event.dt.openClock')}
          onClick={() => setOpen(true)}
        >
          🕒
        </button>
      </div>
      <span id={hintId} className="dt-sr-only">{tr('event.dt.timeFormat')}</span>
      {live?.ok && live.value !== draft && <p className="dt-live" aria-hidden="true">→ {live.value}</p>}
      {message && <p className="form-error">{message}</p>}
      {clock}
    </div>
  );
}
