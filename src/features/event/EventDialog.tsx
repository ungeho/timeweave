import { useEffect, useState } from 'react';
import type {
  EditScope,
  EventEditInput,
  EventOccurrence,
  EventRow,
  NewEvent,
  TimezoneIntent,
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
  contentLengthError,
  CATEGORY_MAX,
  DESCRIPTION_MAX,
  TITLE_MAX,
} from '../../services/contentLimits';
import { editTimezoneIntent } from '../../services/timezoneRules';
import { resolveStorableTimeZone } from '../../utils/timezone';
import {
  EMPTY_RECURRENCE_FORM,
  formSeedForScope,
  formToRule,
  ruleToForm,
  type RecurrenceForm,
} from './recurrenceForm';
import { RecurrenceEditor } from './RecurrenceEditor';
import { timezoneFieldView } from './timezoneField';

export type DialogState =
  | { mode: 'create'; startAt: string; endAt: string }
  | { mode: 'edit'; occurrence: EventOccurrence; master: EventRow | null };

/**
 * What the dialog asks the parent to persist on save.
 *
 * Creating and editing carry DIFFERENT inputs. `NewEvent` must declare a zone
 * for a timed recurrence; `EventEditInput` cannot express one at all, so an
 * ordinary edit can never rewrite it by accident. When an edit turns a row into
 * a timed master for the first time, the zone travels beside the input as
 * `intent`, to be written in the same patch as the rrule.
 */
export type SaveResult =
  | { kind: 'create'; input: NewEvent }
  | { kind: 'updateOne'; row: EventRow; input: EventEditInput; intent: TimezoneIntent }
  | {
      kind: 'editOccurrence';
      occ: EventOccurrence;
      input: EventEditInput;
      scope: EditScope;
      intent: TimezoneIntent;
    };

/** What the dialog asks the parent to persist on delete. */
export type DeleteResult =
  | { kind: 'deleteOne'; id: string }
  | { kind: 'deleteOccurrence'; occ: EventOccurrence; scope: EditScope };

interface Props {
  state: DialogState;
  timeZone: string;
  onSave: (result: SaveResult) => Promise<void>;
  onDelete: (result: DeleteResult) => Promise<void>;
  /**
   * Set/change the zone of an existing timed recurrence master. Deliberately NOT
   * part of onSave: a series' zone is not form state, and moving it moves every
   * occurrence, so it is its own explicit action.
   */
  onSetSeriesTimezone: (masterId: string, timezone: string) => Promise<void>;
  onClose: () => void;
}

const VISIBILITIES: { value: Visibility; label: string }[] = [
  { value: 'private', label: '非公開 (private)' },
  { value: 'busy_only', label: '予定ありのみ (busy_only)' },
  { value: 'public', label: '公開 (public)' },
];

const errorMessage = (e: unknown) => (e instanceof Error ? e.message : String(e));

/**
 * Shown when the browser reports no zone this app can store. NEVER resolved by
 * falling back to UTC: a timed recurrence repeats at a wall-clock time, so a
 * guessed zone silently changes which instants the series occupies.
 */
const TZ_UNRESOLVED_MESSAGE =
  'タイムゾーンを判定できないため、時刻ありの繰り返し予定は保存できません。ブラウザの日付と時刻の設定をご確認ください';

/** The same cause, for the series panel, where nothing is being saved. */
const TZ_UNAVAILABLE_MESSAGE =
  'ブラウザからタイムゾーンを取得できないため、設定できません。ブラウザの日付と時刻の設定をご確認ください';

/** Trimmed display fields, shared by every input shape. */
interface ContentFields {
  title: string;
  description: string | null;
  category: string | null;
  visibility: Visibility;
}

/** The validated time representation the form currently describes. */
type FormTime =
  | { allDay: true; startDate: string; endDate: string }
  | { allDay: false; startAt: string; endAt: string };

/**
 * Assemble an edit input in ONE construction: the union arm is chosen up front
 * from `time`, so no later statement mutates the result. `rrule === undefined`
 * means this scope must not touch the series rule, and the key is omitted.
 */
function toEditInput(
  content: ContentFields,
  time: FormTime,
  rrule: string | null | undefined,
): EventEditInput {
  if (time.allDay) {
    const base = {
      ...content,
      allDay: true as const,
      startDate: time.startDate,
      endDate: time.endDate,
    };
    return rrule === undefined ? base : { ...base, rrule };
  }
  const base = { ...content, allDay: false as const, startAt: time.startAt, endAt: time.endAt };
  return rrule === undefined ? base : { ...base, rrule };
}

/** Add / edit / delete form. Presentation only — persistence is the caller's job. */
export function EventDialog({
  state,
  timeZone,
  onSave,
  onDelete,
  onSetSeriesTimezone,
  onClose,
}: Props) {
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
  // The zone a timed recurrence would be stored with, resolved ONCE when the
  // dialog opens. The same value is displayed and saved, so what the user was
  // shown is what gets written; saving never re-reads the environment.
  const [storableTimeZone] = useState<string | null>(resolveStorableTimeZone);
  // The master's stored zone as this dialog currently knows it. Seeded from the
  // row and updated only by the explicit action below, so the panel reflects
  // what was actually written without waiting for the dialog to be reopened.
  const [seriesTimeZone, setSeriesTimeZone] = useState<string | null>(master?.timezone ?? null);
  const [seriesTimeZoneBusy, setSeriesTimeZoneBusy] = useState(false);

  // Recurrence is editable when creating, editing a one-off, or editing the
  // whole series; for "this occurrence only" the series rule is read-only.
  const recurrenceEditable = !isRecurring || scope === 'all';
  // Per-occurrence edits can't flip all-day-ness (slot key type is fixed).
  const allDayLocked = isRecurring && scope === 'only';

  // The row a save would land on: the master for a whole-series edit, otherwise
  // the row behind the occurrence. null while creating.
  const editTargetRow: EventRow | null =
    state.mode === 'create' ? null : isRecurring && scope === 'all' ? master : occ!.event;

  const timezoneField = timezoneFieldView({
    target:
      editTargetRow === null
        ? null
        : {
            allDay: editTargetRow.allDay,
            rrule: editTargetRow.rrule,
            // The master's zone may have just been set through the panel below.
            timezone: isRecurring && scope === 'all' ? seriesTimeZone : editTargetRow.timezone,
          },
    isRecurring,
    scope,
    formIsTimedRecurrence: !allDay && recurrenceEditable && recurrenceForm.freq !== 'none',
    browserTimeZone: storableTimeZone,
  });

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
    setSeriesTimeZoneBusy(false);
    // Read the master's zone; never fill one in. A legacy master (M0) must stay
    // zone-less until someone explicitly asks for one.
    setSeriesTimeZone(state.mode === 'edit' ? (state.master?.timezone ?? null) : null);
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

  /**
   * Validate the form into its parts, or null (with a message) when invalid.
   * `rrule` is undefined when this scope must not touch the series rule.
   */
  const readForm = (): {
    content: ContentFields;
    time: FormTime;
    rrule: string | null | undefined;
  } | null => {
    if (!title.trim()) {
      setFormError('タイトルを入力してください');
      return null;
    }
    const content: ContentFields = {
      title: title.trim(),
      description: description.trim() || null,
      category: category.trim() || null,
      visibility,
    };

    // Checked on the trimmed values, so trailing whitespace never costs a
    // character. The inputs carry the same limits as maxLength, so typing cannot
    // reach here over the line; a paste into a field the browser truncated, or a
    // value loaded from a row that predates these limits, still can.
    const tooLong = contentLengthError(content);
    if (tooLong) {
      setFormError(tooLong);
      return null;
    }

    let time: FormTime;
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
      time = {
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
      time = { allDay: false, startAt, endAt };
    }

    // Only a rule the user can actually edit contributes; a per-occurrence edit
    // keeps the series rule untouched (undefined = "omit the key entirely").
    let rrule: string | null | undefined;
    if (recurrenceEditable) {
      try {
        const rule = formToRule(recurrenceForm, dtstartIso, timeZone, allDay);
        rrule = rule ? formatRRule(rule) : null;
      } catch (e) {
        setFormError(errorMessage(e));
        return null;
      }
    }
    return { content, time, rrule };
  };

  /**
   * Turn the validated form into exactly one persistence request. Every union
   * arm is built in a single expression — nothing is patched in afterwards — so
   * a timed recurrence can only be constructed together with its zone.
   */
  const buildSaveResult = (): SaveResult | null => {
    const form = readForm();
    if (!form) return null;
    const { content, time, rrule } = form;

    if (state.mode === 'create') {
      if (time.allDay) {
        return {
          kind: 'create',
          input: {
            ...content,
            allDay: true,
            startDate: time.startDate,
            endDate: time.endDate,
            rrule: rrule ?? null,
          },
        };
      }
      if (rrule == null) {
        return {
          kind: 'create',
          input: {
            ...content,
            allDay: false,
            startAt: time.startAt,
            endAt: time.endAt,
            rrule: null,
          },
        };
      }
      // A NEW timed recurrence. Its zone is part of the rule, so with none to
      // store there is nothing defensible to save, and the save is refused.
      if (!storableTimeZone) {
        setFormError(TZ_UNRESOLVED_MESSAGE);
        return null;
      }
      return {
        kind: 'create',
        input: {
          ...content,
          allDay: false,
          startAt: time.startAt,
          endAt: time.endAt,
          rrule,
          timezone: storableTimeZone,
        },
      };
    }

    // An edit. The row the patch lands on decides the intent: a row BECOMING a
    // timed master adopts a zone in the same patch as its rrule; one that is
    // already a master keeps the zone it has (only setSeriesTimezone changes
    // it); one that stops being a master has it cleared by rowPatchFromEdit.
    const target = editTargetRow;
    if (!target) return null; // unreachable: create mode returned above
    const input = toEditInput(content, time, rrule);

    const intent = editTimezoneIntent(target, { allDay: time.allDay, rrule }, storableTimeZone);
    if (!intent) {
      setFormError(TZ_UNRESOLVED_MESSAGE);
      return null;
    }

    if (isRecurring && occ) return { kind: 'editOccurrence', occ, input, scope, intent };
    return { kind: 'updateOne', row: occ!.event, input, intent };
  };

  const handleSave = async () => {
    const result = buildSaveResult();
    if (!result) return;
    try {
      await onSave(result);
      onClose();
    } catch (e) {
      setFormError(errorMessage(e));
    }
  };

  /**
   * The ONLY way this dialog writes a series' zone. It calls setSeriesTimezone
   * and nothing else — no form values ride along — and it is never triggered by
   * saving, so a legacy master keeps its null until someone asks here.
   */
  const applySeriesTimeZone = async () => {
    if (!master || !storableTimeZone) return;
    setFormError(null);
    setSeriesTimeZoneBusy(true);
    try {
      await onSetSeriesTimezone(master.id, storableTimeZone);
      setSeriesTimeZone(storableTimeZone);
    } catch (e) {
      // Notably SeriesEditBlockedError when the series has exceptions: shown
      // inline, and the stored zone is left exactly as it was.
      setFormError(errorMessage(e));
    } finally {
      setSeriesTimeZoneBusy(false);
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
          <input
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            maxLength={TITLE_MAX}
            autoFocus
          />
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
          <textarea
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            maxLength={DESCRIPTION_MAX}
            rows={3}
          />
        </label>

        <div className="field-row">
          <label className="field">
            <span>カテゴリ</span>
            <input
              value={category}
              onChange={(e) => setCategory(e.target.value)}
              maxLength={CATEGORY_MAX}
            />
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

        {timezoneField.kind === 'adopting' &&
          (timezoneField.timezone ? (
            <p className="form-hint">繰り返しのタイムゾーン: {timezoneField.timezone}</p>
          ) : (
            <p className="form-error">{TZ_UNRESOLVED_MESSAGE}</p>
          ))}

        {timezoneField.kind === 'series-unset' && (
          <div className="field">
            <span>タイムゾーン</span>
            <div className="tz-row">
              <span className="form-hint">未設定</span>
              <button
                className="btn"
                disabled={!timezoneField.canSet || seriesTimeZoneBusy}
                onClick={applySeriesTimeZone}
              >
                {storableTimeZone
                  ? `現在のタイムゾーン (${storableTimeZone}) を設定`
                  : '現在のタイムゾーンを設定'}
              </button>
            </div>
            {!timezoneField.canSet && <p className="form-error">{TZ_UNAVAILABLE_MESSAGE}</p>}
          </div>
        )}

        {timezoneField.kind === 'series-set' && (
          <div className="field">
            <span>タイムゾーン</span>
            <div className="tz-row">
              <span className="form-hint">{timezoneField.timezone}</span>
              {timezoneField.canChange && (
                <button className="btn" disabled={seriesTimeZoneBusy} onClick={applySeriesTimeZone}>
                  現在のタイムゾーン ({storableTimeZone}) に変更
                </button>
              )}
            </div>
          </div>
        )}

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
