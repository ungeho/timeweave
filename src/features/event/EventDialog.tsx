import { useEffect, useState } from 'react';
import type {
  EditScope,
  EventOccurrence,
  EventRow,
  NewEvent,
  Visibility,
} from '../../types/event';
import {
  addDaysToDateString,
  isoFromDateString,
  isoFromDatetimeLocalValue,
  toDateInputValue,
  toDatetimeLocalValue,
} from '../../utils/datetime';
import { formatRRule, parseRRule } from '../../services/recurrence';
import {
  EMPTY_RECURRENCE_FORM,
  formSeedForScope,
  formToRule,
  ruleToForm,
  type RecurrenceForm,
} from './recurrenceForm';
import { RecurrenceEditor } from './RecurrenceEditor';

export type DialogState =
  | { mode: 'create'; startAt: string; endAt: string }
  | { mode: 'edit'; occurrence: EventOccurrence; master: EventRow | null };

/** What the dialog asks the parent to persist on save. */
export type SaveResult =
  | { kind: 'create'; input: NewEvent }
  | { kind: 'updateOne'; id: string; input: NewEvent }
  | { kind: 'editOccurrence'; occ: EventOccurrence; input: NewEvent; scope: EditScope };

/** What the dialog asks the parent to persist on delete. */
export type DeleteResult =
  | { kind: 'deleteOne'; id: string }
  | { kind: 'deleteOccurrence'; occ: EventOccurrence; scope: EditScope };

interface Props {
  state: DialogState;
  timeZone: string;
  onSave: (result: SaveResult) => Promise<void>;
  onDelete: (result: DeleteResult) => Promise<void>;
  onClose: () => void;
}

const VISIBILITIES: { value: Visibility; label: string }[] = [
  { value: 'private', label: '非公開 (private)' },
  { value: 'busy_only', label: '予定ありのみ (busy_only)' },
  { value: 'public', label: '公開 (public)' },
];

const errorMessage = (e: unknown) => (e instanceof Error ? e.message : String(e));

/** Add / edit / delete form. Presentation only — persistence is the caller's job. */
export function EventDialog({ state, timeZone, onSave, onDelete, onClose }: Props) {
  const occ = state.mode === 'edit' ? state.occurrence : null;
  const master = state.mode === 'edit' ? state.master : null;
  // "Recurring edit" = the occurrence belongs to a series (its master is known).
  const isRecurring = occ != null && master != null;

  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [allDay, setAllDay] = useState(false);
  const [startLocal, setStartLocal] = useState('');
  const [endLocal, setEndLocal] = useState('');
  const [startDate, setStartDate] = useState('');
  const [endDateInclusive, setEndDateInclusive] = useState('');
  const [category, setCategory] = useState('');
  const [visibility, setVisibility] = useState<Visibility>('private');
  const [scope, setScope] = useState<EditScope>('only');
  const [recurrenceForm, setRecurrenceForm] = useState<RecurrenceForm>(EMPTY_RECURRENCE_FORM);
  const [formError, setFormError] = useState<string | null>(null);

  // Recurrence is editable when creating, editing a one-off, or editing the
  // whole series; for "this occurrence only" the series rule is read-only.
  const recurrenceEditable = !isRecurring || scope === 'all';
  // Per-occurrence edits can't flip all-day-ness (slot key type is fixed).
  const allDayLocked = isRecurring && scope === 'only';

  const seedFieldsFromOccurrence = (o: EventOccurrence) => {
    const ev = o.event;
    setTitle(ev.title);
    setDescription(ev.description ?? '');
    setAllDay(o.allDay);
    setStartLocal(toDatetimeLocalValue(o.start));
    setEndLocal(toDatetimeLocalValue(o.end));
    setStartDate(toDateInputValue(o.start));
    setEndDateInclusive(
      o.allDay ? addDaysToDateString(toDateInputValue(o.end), -1) : toDateInputValue(o.start),
    );
    setCategory(ev.category ?? '');
    setVisibility(ev.visibility);
  };

  const seedRecurrence = (rrule: string | null) => {
    setRecurrenceForm(rrule ? ruleToForm(parseRRule(rrule), timeZone) : EMPTY_RECURRENCE_FORM);
  };

  useEffect(() => {
    setFormError(null);
    setScope('only');
    if (state.mode === 'create') {
      setTitle('');
      setDescription('');
      setAllDay(false);
      setStartLocal(toDatetimeLocalValue(state.startAt));
      setEndLocal(toDatetimeLocalValue(state.endAt));
      setStartDate(toDateInputValue(state.startAt));
      setEndDateInclusive(toDateInputValue(state.startAt));
      setCategory('');
      setVisibility('private');
      seedRecurrence(null);
      return;
    }
    seedFieldsFromOccurrence(state.occurrence);
    seedRecurrence(state.master?.rrule ?? null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state, timeZone]);

  // Switching scope re-seeds the form: 'all' from the master's content, 'only'
  // from the occurrence's own content.
  const changeScope = (next: EditScope) => {
    setScope(next);
    setFormError(null);
    if (occ && master) {
      const seed = formSeedForScope(occ, master, next);
      seedFieldsFromOccurrence(seed.occurrence);
      seedRecurrence(master.rrule);
    }
  };

  const buildInput = (): NewEvent | null => {
    if (!title.trim()) {
      setFormError('タイトルを入力してください');
      return null;
    }
    const common = {
      title: title.trim(),
      description: description.trim() || null,
      category: category.trim() || null,
      visibility,
    };

    let timeFields: NewEvent;
    let dtstartIso: string;
    if (allDay) {
      if (!startDate || !endDateInclusive) {
        setFormError('日付を入力してください');
        return null;
      }
      if (endDateInclusive < startDate) {
        setFormError('終了日は開始日以降にしてください');
        return null;
      }
      dtstartIso = isoFromDateString(startDate);
      timeFields = {
        ...common,
        allDay: true,
        startDate,
        endDate: addDaysToDateString(endDateInclusive, 1), // store exclusive
      };
    } else {
      const startAt = isoFromDatetimeLocalValue(startLocal);
      const endAt = isoFromDatetimeLocalValue(endLocal);
      if (new Date(endAt).getTime() < new Date(startAt).getTime()) {
        setFormError('終了日時は開始日時以降にしてください');
        return null;
      }
      dtstartIso = startAt;
      timeFields = { ...common, allDay: false, startAt, endAt };
    }

    // Only a rule the user can actually edit contributes; a per-occurrence edit
    // keeps the series rule untouched (editOccurrence ignores rrule anyway).
    if (recurrenceEditable) {
      try {
        const rule = formToRule(recurrenceForm, dtstartIso, timeZone, allDay);
        timeFields.rrule = rule ? formatRRule(rule) : null;
      } catch (e) {
        setFormError(errorMessage(e));
        return null;
      }
    }
    return timeFields;
  };

  const handleSave = async () => {
    const input = buildInput();
    if (!input) return;

    let result: SaveResult;
    if (state.mode === 'create') {
      result = { kind: 'create', input };
    } else if (isRecurring && occ) {
      result = { kind: 'editOccurrence', occ, input, scope };
    } else {
      result = { kind: 'updateOne', id: occ!.event.id, input };
    }

    try {
      await onSave(result);
      onClose();
    } catch (e) {
      setFormError(errorMessage(e));
    }
  };

  const handleDelete = async () => {
    if (!occ) return;
    const result: DeleteResult = isRecurring
      ? { kind: 'deleteOccurrence', occ, scope }
      : { kind: 'deleteOne', id: occ.event.id };
    try {
      await onDelete(result);
      onClose();
    } catch (e) {
      setFormError(errorMessage(e));
    }
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()} role="dialog" aria-modal="true">
        <h3 className="modal-title">{occ ? '予定を編集' : '予定を追加'}</h3>

        {isRecurring && (
          <div className="field">
            <span>対象</span>
            <div className="scope-row">
              <label className="scope-option">
                <input type="radio" checked={scope === 'only'} onChange={() => changeScope('only')} />
                <span>この回のみ</span>
              </label>
              <label className="scope-option">
                <input type="radio" checked={scope === 'all'} onChange={() => changeScope('all')} />
                <span>すべての回</span>
              </label>
            </div>
          </div>
        )}

        <label className="field">
          <span>タイトル</span>
          <input value={title} onChange={(e) => setTitle(e.target.value)} autoFocus />
        </label>

        <label className="field checkbox">
          <input
            type="checkbox"
            checked={allDay}
            disabled={allDayLocked}
            onChange={(e) => setAllDay(e.target.checked)}
          />
          <span>終日</span>
        </label>

        {allDay ? (
          <div className="field-row">
            <label className="field">
              <span>開始日</span>
              <input type="date" value={startDate} onChange={(e) => setStartDate(e.target.value)} />
            </label>
            <label className="field">
              <span>終了日</span>
              <input
                type="date"
                value={endDateInclusive}
                onChange={(e) => setEndDateInclusive(e.target.value)}
              />
            </label>
          </div>
        ) : (
          <div className="field-row">
            <label className="field">
              <span>開始</span>
              <input
                type="datetime-local"
                value={startLocal}
                onChange={(e) => setStartLocal(e.target.value)}
              />
            </label>
            <label className="field">
              <span>終了</span>
              <input
                type="datetime-local"
                value={endLocal}
                onChange={(e) => setEndLocal(e.target.value)}
              />
            </label>
          </div>
        )}

        <label className="field">
          <span>メモ</span>
          <textarea value={description} onChange={(e) => setDescription(e.target.value)} rows={3} />
        </label>

        <div className="field-row">
          <label className="field">
            <span>カテゴリ</span>
            <input value={category} onChange={(e) => setCategory(e.target.value)} />
          </label>
          <label className="field">
            <span>公開範囲</span>
            <select value={visibility} onChange={(e) => setVisibility(e.target.value as Visibility)}>
              {VISIBILITIES.map((v) => (
                <option key={v.value} value={v.value}>{v.label}</option>
              ))}
            </select>
          </label>
        </div>

        <RecurrenceEditor
          value={recurrenceForm}
          onChange={setRecurrenceForm}
          disabled={!recurrenceEditable}
        />

        {formError && <p className="form-error">{formError}</p>}

        <div className="modal-actions">
          {occ && (
            <button className="btn danger" onClick={handleDelete}>削除</button>
          )}
          <div className="spacer" />
          <button className="btn" onClick={onClose}>キャンセル</button>
          <button className="btn primary" onClick={handleSave}>保存</button>
        </div>
      </div>
    </div>
  );
}
