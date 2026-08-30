/**
 * Presentational editor for a RecurrenceForm. No persistence and no rule
 * building — the parent owns the RecurrenceForm state and converts it via
 * formToRule on save. `disabled` renders the current rule read-only (used for
 * the "this occurrence only" scope, where the series rule can't change).
 */

import { useEffect, useState } from 'react';
import { parsePositiveIntInput } from './recurrenceForm';
import type { RecurrenceForm, FormFreq, EndMode } from './recurrenceForm';
import type { Weekday } from '../../types/recurrence';
import { WEEKDAYS } from '../../types/recurrence';

interface Props {
  value: RecurrenceForm;
  onChange: (form: RecurrenceForm) => void;
  disabled?: boolean;
}

const FREQ_OPTIONS: { value: FormFreq; label: string }[] = [
  { value: 'none', label: '繰り返さない' },
  { value: 'daily', label: '毎日' },
  { value: 'weekly', label: '毎週' },
  { value: 'monthly', label: '毎月' },
];

const END_OPTIONS: { value: EndMode; label: string }[] = [
  { value: 'never', label: '終わりなし' },
  { value: 'count', label: '回数' },
  { value: 'until', label: '終了日' },
];

const WEEKDAY_LABELS: Record<Weekday, string> = {
  MO: '月', TU: '火', WE: '水', TH: '木', FR: '金', SA: '土', SU: '日',
};

export function RecurrenceEditor({ value, onChange, disabled = false }: Props) {
  const set = (patch: Partial<RecurrenceForm>) => onChange({ ...value, ...patch });

  // Local display strings for the numeric fields so mid-edit states (empty, a
  // just-typed leading zero) don't get coerced to a number on every keystroke.
  // Committed to the numeric form only when a valid positive integer; re-synced
  // when the form value changes elsewhere (e.g. reseed on scope switch).
  const [intervalStr, setIntervalStr] = useState(String(value.interval));
  const [countStr, setCountStr] = useState(String(value.count));
  useEffect(() => setIntervalStr(String(value.interval)), [value.interval]);
  useEffect(() => setCountStr(String(value.count)), [value.count]);

  const changeInterval = (raw: string) => {
    const { display, value: n } = parsePositiveIntInput(raw);
    setIntervalStr(display);
    if (n !== null) set({ interval: n });
  };
  const changeCount = (raw: string) => {
    const { display, value: n } = parsePositiveIntInput(raw);
    setCountStr(display);
    if (n !== null) set({ count: n });
  };

  const toggleWeekday = (day: Weekday) => {
    const has = value.weekdays.includes(day);
    set({
      weekdays: has ? value.weekdays.filter((d) => d !== day) : [...value.weekdays, day],
    });
  };

  return (
    <fieldset className="recurrence-editor" disabled={disabled}>
      <legend>繰り返し</legend>

      <label className="field">
        <span>頻度</span>
        <select value={value.freq} onChange={(e) => set({ freq: e.target.value as FormFreq })}>
          {FREQ_OPTIONS.map((o) => (
            <option key={o.value} value={o.value}>{o.label}</option>
          ))}
        </select>
      </label>

      {value.freq !== 'none' && (
        <>
          <label className="field">
            <span>間隔</span>
            <input
              type="number"
              min={1}
              value={intervalStr}
              onChange={(e) => changeInterval(e.target.value)}
              onBlur={() => setIntervalStr(String(value.interval))}
            />
          </label>

          {value.freq === 'weekly' && (
            <div className="field">
              <span>曜日</span>
              <div className="weekday-row">
                {WEEKDAYS.map((day) => (
                  <label key={day} className="weekday-chip">
                    <input
                      type="checkbox"
                      checked={value.weekdays.includes(day)}
                      onChange={() => toggleWeekday(day)}
                    />
                    <span>{WEEKDAY_LABELS[day]}</span>
                  </label>
                ))}
              </div>
            </div>
          )}

          <label className="field">
            <span>終了</span>
            <select value={value.endMode} onChange={(e) => set({ endMode: e.target.value as EndMode })}>
              {END_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>{o.label}</option>
              ))}
            </select>
          </label>

          {value.endMode === 'count' && (
            <label className="field">
              <span>回数</span>
              <input
                type="number"
                min={1}
                value={countStr}
                onChange={(e) => changeCount(e.target.value)}
                onBlur={() => setCountStr(String(value.count))}
              />
            </label>
          )}

          {value.endMode === 'until' && (
            <label className="field">
              <span>終了日</span>
              <input
                type="date"
                value={value.untilDate}
                onChange={(e) => set({ untilDate: e.target.value })}
              />
            </label>
          )}
        </>
      )}
    </fieldset>
  );
}
