/**
 * Presentational editor for a RecurrenceForm. No persistence and no rule
 * building — the parent owns the RecurrenceForm state and converts it via
 * formToRule on save. `disabled` renders the current rule read-only (used for
 * the "this occurrence only" scope, where the series rule can't change).
 */

import { useEffect, useRef, useState } from 'react';
import { useLanguage, useTranslate } from '../../i18n/useLanguage';
import { weekdayNamesShort } from '../../i18n/dateNames';
import { parseCountInput, parseIntervalInput } from './recurrenceForm';
import { MAX_COUNT, MAX_INTERVAL } from '../../services/recurrence';
import type { RecurrenceForm, FormFreq, EndMode } from './recurrenceForm';
import type { Weekday } from '../../types/recurrence';
import { WEEKDAYS } from '../../types/recurrence';
import { DateInput } from './datetimeInput/DateTimeInputs';

interface Props {
  value: RecurrenceForm;
  onChange: (form: RecurrenceForm) => void;
  disabled?: boolean;
  /**
   * The end date's draft problem (P8-b5.6b-2), or null. The date input keeps
   * its last good value while the owner's text does not parse, so the parent
   * must refuse to save rather than save a date the owner no longer sees.
   */
  onUntilInvalid?: (reason: string | null) => void;
  /** The screen's layout, decided by the dialog (a leaf does not ask the viewport). */
  mobile?: boolean;
}

/**
 * The option lists now carry a MESSAGE KEY instead of a label, so the wording
 * is resolved during render with the language the provider hands down.
 *
 * `as const` is load-bearing twice over. It keeps each key a literal type, so
 * `tr(o.key)` type-checks as a no-variable message rather than widening to the
 * whole MessageKey union (which would then demand a vars argument). And it
 * keeps each `value` a literal, which is what lets the parity assertion below
 * prove the list still covers the union exactly.
 */
const FREQ_OPTIONS = [
  { value: 'none', key: 'recurrence.freq.none' },
  { value: 'daily', key: 'recurrence.freq.daily' },
  { value: 'weekly', key: 'recurrence.freq.weekly' },
  { value: 'monthly', key: 'recurrence.freq.monthly' },
] as const;

const END_OPTIONS = [
  { value: 'never', key: 'recurrence.end.never' },
  { value: 'count', key: 'recurrence.end.count' },
  { value: 'until', key: 'recurrence.end.until' },
] as const;

/**
 * The lists must offer every member of their union and nothing else.
 *
 * The previous `{ value: FormFreq; label: string }[]` annotation checked only
 * that each value WAS a FormFreq -- a dropped option, or a new member of the
 * union, type-checked fine and silently disappeared from the control. These
 * assertions are the stronger statement, and they cost nothing at runtime.
 */
type FreqValues = (typeof FREQ_OPTIONS)[number]['value'];
type EndValues = (typeof END_OPTIONS)[number]['value'];
const _freqParity: [Exclude<FormFreq, FreqValues>, Exclude<FreqValues, FormFreq>] extends
  [never, never] ? true : never = true;
const _endParity: [Exclude<EndMode, EndValues>, Exclude<EndValues, EndMode>] extends
  [never, never] ? true : never = true;
void _freqParity;
void _endParity;

export function RecurrenceEditor({ value, onChange, disabled = false, onUntilInvalid, mobile = false }: Props) {
  const tr = useTranslate();
  // The chips are a DATE FORMAT. WEEKDAYS is Monday-first and so is
  // weekdayNamesShort, so the two line up by position -- which is why the
  // map below indexes by `i` instead of looking the RFC 5545 code up. The
  // value SAVED is still `day`, the code itself.
  const { language } = useLanguage();
  const weekdays = weekdayNamesShort(language);
  const set = (patch: Partial<RecurrenceForm>) => onChange({ ...value, ...patch });

  // Local display strings for the numeric fields so mid-edit states (empty, a
  // just-typed leading zero) don't get coerced to a number on every keystroke.
  // Committed to the numeric form only when a valid positive integer; re-synced
  // when the form value changes elsewhere (e.g. reseed on scope switch).
  const [intervalStr, setIntervalStr] = useState(String(value.interval));
  const [countStr, setCountStr] = useState(String(value.count));
  // K13: an invalid interval is committed (so the save is refused) but its
  // text stays as typed. The sync below must not then rewrite the field from
  // the committed number ("100000000000000000000000" -> "1e+23", "abc" ->
  // "NaN"); it re-syncs only for a value that did not come from typing here
  // (a reseed). Object.is so NaN matches itself.
  const typedInterval = useRef<number | null>(null);
  useEffect(() => {
    if (typedInterval.current !== null && Object.is(typedInterval.current, value.interval)) return;
    setIntervalStr(String(value.interval));
  }, [value.interval]);
  // K14: the count field works the same way.
  const typedCount = useRef<number | null>(null);
  useEffect(() => {
    if (typedCount.current !== null && Object.is(typedCount.current, value.count)) return;
    setCountStr(String(value.count));
  }, [value.count]);

  const changeInterval = (raw: string, badInput: boolean) => {
    const { display, commit } = parseIntervalInput(raw, badInput);
    setIntervalStr(display);
    if (commit !== null) {
      typedInterval.current = commit;
      set({ interval: commit });
    }
  };
  const intervalValid = Number.isInteger(value.interval) && value.interval >= 1 && value.interval <= MAX_INTERVAL;
  const changeCount = (raw: string, badInput: boolean) => {
    const { display, commit } = parseCountInput(raw, badInput);
    setCountStr(display);
    if (commit !== null) {
      typedCount.current = commit;
      set({ count: commit });
    }
  };
  const countValid = Number.isInteger(value.count) && value.count >= 1 && value.count <= MAX_COUNT;

  const toggleWeekday = (day: Weekday) => {
    const has = value.weekdays.includes(day);
    set({
      weekdays: has ? value.weekdays.filter((d) => d !== day) : [...value.weekdays, day],
    });
  };

  return (
    <fieldset className="recurrence-editor" disabled={disabled}>
      <legend>{tr('recurrence.legend')}</legend>

      <label className="field">
        <span>{tr('recurrence.freq.label')}</span>
        <select value={value.freq} onChange={(e) => set({ freq: e.target.value as FormFreq })}>
          {FREQ_OPTIONS.map((o) => (
            <option key={o.value} value={o.value}>{tr(o.key)}</option>
          ))}
        </select>
      </label>

      {value.freq !== 'none' && (
        <>
          <label className="field">
            <span>{tr('recurrence.interval.label')}</span>
            <input
              type="number"
              min={1}
              max={MAX_INTERVAL}
              step={1}
              value={intervalStr}
              aria-invalid={intervalValid ? undefined : true}
              onChange={(e) => changeInterval(e.target.value, e.target.validity.badInput)}
              // Normalise on blur only when valid: an invalid entry stays as
              // typed, next to the error the save will show.
              onBlur={() => { if (intervalValid) setIntervalStr(String(value.interval)); }}
            />
          </label>

          {value.freq === 'weekly' && (
            <div className="field">
              <span>{tr('recurrence.weekdays.label')}</span>
              <div className="weekday-row">
                {WEEKDAYS.map((day, i) => (
                  <label key={day} className="weekday-chip">
                    <input
                      type="checkbox"
                      checked={value.weekdays.includes(day)}
                      onChange={() => toggleWeekday(day)}
                    />
                    <span>{weekdays[i]}</span>
                  </label>
                ))}
              </div>
            </div>
          )}

          <label className="field">
            <span>{tr('recurrence.end.label')}</span>
            <select value={value.endMode} onChange={(e) => set({ endMode: e.target.value as EndMode })}>
              {END_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>{tr(o.key)}</option>
              ))}
            </select>
          </label>

          {value.endMode === 'count' && (
            <label className="field">
              <span>{tr('recurrence.count.label')}</span>
              <input
                type="number"
                min={1}
                max={MAX_COUNT}
                step={1}
                value={countStr}
                aria-invalid={countValid ? undefined : true}
                onChange={(e) => changeCount(e.target.value, e.target.validity.badInput)}
                onBlur={() => { if (countValid) setCountStr(String(value.count)); }}
              />
            </label>
          )}

          {value.endMode === 'until' && (
            <div className="field">
              <span>{tr('recurrence.until.label')}</span>
              {/*
                Only rendered in "until" mode, and in that mode it IS required:
                formToRule refuses an empty one with "enter an end date" (still
                the refusal for an end date never filled in). The date input
                (P8-b5.6b-2) marks a mistyped or emptied draft red at once and
                reports it through onUntilInvalid. Inside a disabled fieldset
                its text box and calendar button are disabled with it.
              */}
              <DateInput
                label={tr('recurrence.until.label')}
                value={value.untilDate}
                mobile={mobile}
                onCommit={(untilDate) => set({ untilDate })}
                onInvalid={(reason) => onUntilInvalid?.(reason)}
              />
            </div>
          )}
        </>
      )}
    </fieldset>
  );
}
