import { useEffect, useRef, useState } from 'react';
import { useIsMobile } from '../../hooks/useIsMobile';
import { useDialogChrome } from '../../hooks/useDialogChrome';
import type {
  Availability,
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
import { useLanguage, useTranslate } from '../../i18n/useLanguage';
import {
  contentLengthViolation,
  CATEGORY_MAX,
  DESCRIPTION_MAX,
  TITLE_MAX,
} from '../../services/contentLimits';
import { eventFormErrorText, type EventFormError } from './eventFormError';
import { editTimezoneIntent } from '../../services/timezoneRules';
import { AVAILABILITIES, availabilityLabel, isTitleRequired } from './availabilityField';
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
import { DateInput, TimeInput } from './datetimeInput/DateTimeInputs';
import { checkWallTime, foldInstant, storedFoldChoice, type FoldChoice } from './formInstant';
import { allDayOutOfRange, timedOutOfRange } from './eventDateBounds';
import { WallTimeNotice } from './WallTimeNotice';
import type { CreateTime } from '../calendar/createTimes';

/** The date/time inputs whose drafts can block a save. */
type DraftField = 'startDate' | 'startTime' | 'endDate' | 'endTime' | 'allDayStart' | 'allDayEnd' | 'until';
/** A fold choice belongs to the wall clock it was made for; editing the value drops it. */
type FoldPick = { local: string; choice: FoldChoice };

const splitLocal = (local: string): [string, string] => {
  const [date = '', time = ''] = local.split('T');
  return [date, time];
};
const joinLocal = (date: string, time: string): string => (date && time ? `${date}T${time}` : '');

export type DialogState =
  // The initial times come from createTimesAt: a wall clock per end, and its
  // instant only when that wall clock names exactly one (R1-P).
  | { mode: 'create'; start: CreateTime; end: CreateTime }
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

/**
 * The visibility control's options.
 *
 * Each option carries a MESSAGE KEY rather than a label, resolved during render
 * with the language the provider hands down. `as const` is load-bearing twice:
 * it keeps each key a literal type, so `tr(v.key)` type-checks as a message
 * with no variables instead of widening to the whole MessageKey union (which
 * would then demand a vars argument); and it keeps each `value` a literal, so
 * the assertion below can prove the list still offers every Visibility.
 *
 * The previous annotation could not make that second claim: it checked only
 * that each value WAS a Visibility, so a dropped option type-checked fine and
 * simply vanished from the select.
 */
const VISIBILITY_OPTIONS = [
  { value: 'private', key: 'event.visibility.private' },
  { value: 'busy_only', key: 'event.visibility.busyOnly' },
  { value: 'public', key: 'event.visibility.public' },
] as const;

type VisibilityValues = (typeof VISIBILITY_OPTIONS)[number]['value'];
const _visibilityParity: [
  Exclude<Visibility, VisibilityValues>,
  Exclude<VisibilityValues, Visibility>,
] extends [never, never]
  ? true
  : never = true;
void _visibilityParity;



/**
 * The two zone refusals are `event.tz.unresolved` (a save is refused, because
 * the browser reports no zone this app can store) and `event.tz.unavailable`
 * (the series panel, where nothing is being saved).
 *
 * NEITHER IS EVER RESOLVED BY FALLING BACK TO UTC: a timed recurrence repeats
 * at a wall-clock time, so a guessed zone silently changes which instants the
 * series occupies. Both dictionary entries carry that note, so a translation
 * cannot quietly start offering one.
 */

/** Trimmed display fields, shared by every input shape. */
interface ContentFields {
  title: string;
  description: string | null;
  category: string | null;
  visibility: Visibility;
  availability: Availability;
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
  const tr = useTranslate();
  // For the error line, which resolves its wording at RENDER rather than at
  // the moment the failure happened. `tr` still serves everything whose
  // wording is decided while drawing anyway.
  const { language } = useLanguage();
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
  // Reasons (not wording) from the date/time inputs whose draft did not parse.
  const [draftIssues, setDraftIssues] = useState<Partial<Record<DraftField, string>>>({});
  // Which side of a DST fold each timed field means. Seeded from the stored
  // instant on open (formInstant.storedFoldChoice), so an untouched save keeps it.
  const [foldPicks, setFoldPicks] = useState<{ start?: FoldPick; end?: FoldPick }>({});
  const [category, setCategory] = useState('');
  const [visibility, setVisibility] = useState<Visibility>('private');
  const [availability, setAvailability] = useState<Availability>('busy');
  const [scope, setScope] = useState<EditScope>('only');
  const [recurrenceForm, setRecurrenceForm] = useState<RecurrenceForm>(EMPTY_RECURRENCE_FORM);
  // NOT A SENTENCE. It used to be: eleven places filled this with text --
  // four catches from `e.message`, six validation failures from `tr(...)`,
  // and one from contentLengthError -- each deciding the wording at the moment
  // of the failure. A language change afterwards re-rendered every other
  // string in this dialog and left the error line in the old language.
  const [formError, setFormError] = useState<EventFormError | null>(null);
  /*
    SAVING AND DELETING ARE IN FLIGHT OR THEY ARE NOT.

    There was no such state before: both handlers awaited and the buttons
    stayed live, so a second tap started a second `create` and made two
    events. On a desktop that takes a deliberate double-click on a small
    button; on a phone, where P8-b3 makes these 44px and puts save under a
    thumb, it is one twitch. The ref is what actually guards -- state does not
    update in time to stop a second call in the same tick -- and the state is
    what the screen reads.
  */
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);
  const isMobile = useIsMobile();
  // P8-mobile-1 (M3). The notes field, and whether it is being edited.
  const memoRef = useRef<HTMLTextAreaElement>(null);
  const [memoFocused, setMemoFocused] = useState(false);
  const errorRef = useRef<HTMLParagraphElement>(null);
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
    seedFoldPicks(o.allDay ? null : o.start, o.allDay ? null : o.end);
    setStartDate(toDateInputValue(o.start));
    setEndDateInclusive(
      o.allDay ? addDaysToDateString(toDateInputValue(o.end), -1) : toDateInputValue(o.start),
    );
    setCategory(ev.category ?? '');
    setVisibility(ev.visibility);
    setAvailability(ev.availability);
  };

  // Recover which side of a fold a stored instant is on. Without this, the old
  // save took the 1st and moved an event stored at the 2nd by an hour even
  // when its time was never touched (docs/p8-datetime-contract.md, B1).
  const seedFoldPicks = (startIso: string | null, endIso: string | null) => {
    const pick = (iso: string | null): FoldPick | undefined => {
      if (!iso) return undefined;
      const choice = storedFoldChoice(iso, timeZone);
      return choice ? { local: toDatetimeLocalValue(iso), choice } : undefined;
    };
    setFoldPicks({ start: pick(startIso), end: pick(endIso) });
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
    setDraftIssues({});
    if (state.mode === 'create') {
      setTitle('');
      setDescription('');
      setAllDay(false);
      // The clicked wall clocks as they are. A side of a fold is seeded only
      // when the click identified it; a gap or an unidentified fold is left to
      // the form's notice instead of being resolved here.
      setStartLocal(state.start.local);
      setEndLocal(state.end.local);
      seedFoldPicks(state.start.at, state.end.at);
      setStartDate(state.start.local.slice(0, 10));
      setEndDateInclusive(state.start.local.slice(0, 10));
      setCategory('');
      setVisibility('private');
      // Reset with the rest of the form: a dialog reopened to create a second
      // event must not inherit the first one's choice.
      setAvailability('busy');
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

  // Each label is looked up once: the visible caption and the input's
  // accessible name are the same words (eventSheet.test counts the keys).
  const allDayStartLabel = tr('event.field.startDate');
  const allDayEndLabel = tr('event.field.endDate');
  const timedFieldLabel = (which: 'start' | 'end') => tr(which === 'start' ? 'event.field.start' : 'event.field.end');
  const foldPickFor = (field: 'start' | 'end', local: string): FoldChoice | null => {
    const p = foldPicks[field];
    return p && p.local === local ? p.choice : null;
  };
  const setDraftIssue = (field: DraftField, reason: string | null) =>
    setDraftIssues((prev) => (prev[field] === (reason ?? undefined) ? prev : { ...prev, [field]: reason ?? undefined }));

  /**
   * Validate the form into its parts, or null (with a message) when invalid.
   * `rrule` is undefined when this scope must not touch the series rule.
   */
  const readForm = (): {
    content: ContentFields;
    time: FormTime;
    rrule: string | null | undefined;
  } | null => {
    // Judged on the availability the form is about to SAVE, not the one the row
    // arrived with: turning an untitled available event back into a busy one has
    // to ask for the title a busy event needs.
    if (isTitleRequired(availability) && !title.trim()) {
      setFormError({ kind: 'validation', key: 'event.title.required' });
      return null;
    }
    const content: ContentFields = {
      title: title.trim(),
      description: description.trim() || null,
      category: category.trim() || null,
      visibility,
      availability,
    };

    // Checked on the trimmed values, so trailing whitespace never costs a
    // character. The inputs carry the same limits as maxLength, so typing cannot
    // reach here over the line; a paste into a field the browser truncated, or a
    // value loaded from a row that predates these limits, still can.
    // The RULE is still contentLimits', asked the same way and in the same
    // order (title, then category, then description). What is stored is WHICH
    // field and the ceiling it passed -- not the sentence -- so the refusal
    // follows the language. Snapshotting rather than re-deriving at render:
    // the owner is still editing the field, and re-measuring would make the
    // message vanish mid-keystroke, which is not when this dialog clears it.
    const tooLong = contentLengthViolation(content);
    if (tooLong) {
      setFormError({ kind: 'contentTooLong', violation: tooLong });
      return null;
    }

    // A date/time field still holding text that did not parse: the committed
    // value behind it is no longer what the owner sees, so it must not be saved.
    const draftFields: DraftField[] = [
      ...(allDay ? (['allDayStart', 'allDayEnd'] as const) : (['startDate', 'startTime', 'endDate', 'endTime'] as const)),
      // The series end date counts only where it is shown and editable.
      ...(recurrenceEditable && recurrenceForm.freq !== 'none' && recurrenceForm.endMode === 'until'
        ? (['until'] as const)
        : []),
    ];
    const blocked = draftFields.find((k) => draftIssues[k]);
    if (blocked) {
      setFormError({
        kind: 'datetime',
        issue: { problem: 'draft', part: blocked.endsWith('Time') ? 'time' : 'date', empty: draftIssues[blocked] === 'empty' },
      });
      return null;
    }

    let time: FormTime;
    let dtstartIso: string;
    if (allDay) {
      if (!startDate || !endDateInclusive) {
        setFormError({ kind: 'validation', key: 'event.error.dateRequired' });
        return null;
      }
      if (endDateInclusive < startDate) {
        setFormError({ kind: 'validation', key: 'event.error.endDateBeforeStart' });
        return null;
      }
      // K18: what the database stores ends at 9999-12-31 exclusive (0013),
      // judged on the exclusive end exactly as it will be stored below.
      if (allDayOutOfRange(startDate, addDaysToDateString(endDateInclusive, 1))) {
        setFormError({ kind: 'validation', key: 'event.error.allDayOutOfRange' });
        return null;
      }
      dtstartIso = isoFromDateString(startDate);
      time = {
        allDay: true,
        startDate,
        endDate: addDaysToDateString(endDateInclusive, 1), // store exclusive
      };
    } else {
      /*
        THE ALL-DAY BRANCH ABOVE CHECKS THIS AND THIS ONE DID NOT.

        An emptied datetime-local reads as '', and isoFromDatetimeLocalValue
        throws on it -- out of buildSaveResult, out of handleSave, into an
        unhandled rejection. Measured: clearing the start and pressing save
        left the dialog open with no message and "Invalid datetime-local
        value:" in the console. The owner pressed save and nothing happened.

        '' is also what a HALF-TYPED value reads as: the control reports an
        empty string for anything it cannot parse as a whole datetime, with
        validity.badInput set. Both cases are unusable at save time and both
        want the same sentence, so neither is special-cased -- what matters
        is that pressing save now says something.
      */
      if (!startLocal || !endLocal) {
        setFormError({ kind: 'validation', key: 'event.error.dateRequired' });
        return null;
      }
      /*
        DST (P8-b5.6b-2, docs/p8-datetime-contract.md). A wall clock that names
        one instant still goes through isoFromDatetimeLocalValue below,
        unchanged. A time that does not exist is refused instead of being saved
        an hour later, and a time that happens twice is saved as the instant
        the owner picked (or that the stored event already had).
      */
      const startWall = checkWallTime(startLocal, timeZone);
      const endWall = checkWallTime(endLocal, timeZone);
      if (startWall.kind === 'gap' || endWall.kind === 'gap') {
        setFormError({ kind: 'datetime', issue: { problem: 'gap' } });
        return null;
      }
      const startFold = startWall.kind === 'fold' ? foldInstant(startWall, foldPickFor('start', startLocal)) : undefined;
      const endFold = endWall.kind === 'fold' ? foldInstant(endWall, foldPickFor('end', endLocal)) : undefined;
      if (startFold === null || endFold === null) {
        setFormError({ kind: 'datetime', issue: { problem: 'foldUnchosen' } });
        return null;
      }
      const startAt = startFold ?? isoFromDatetimeLocalValue(startLocal);
      const endAt = endFold ?? isoFromDatetimeLocalValue(endLocal);
      if (new Date(endAt).getTime() < new Date(startAt).getTime()) {
        setFormError({ kind: 'validation', key: 'event.error.endBeforeStart' });
        return null;
      }
      // K18: the database stores instants before 10000-01-01 UTC (0013); the
      // same wall clock can be inside in one zone and outside in another.
      if (timedOutOfRange(startAt, endAt)) {
        setFormError({ kind: 'validation', key: 'event.error.timedOutOfRange' });
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
        setFormError({ kind: 'caught', cause: e });
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
        setFormError({ kind: 'validation', key: 'event.tz.unresolved' });
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
      setFormError({ kind: 'validation', key: 'event.tz.unresolved' });
      return null;
    }

    if (isRecurring && occ) return { kind: 'editOccurrence', occ, input, scope, intent };
    return { kind: 'updateOne', row: occ!.event, input, intent };
  };

  const handleSave = async () => {
    if (busyRef.current) return;
    /*
      INSIDE THE TRY. It was outside, so anything buildSaveResult threw --
      rather than reported -- escaped the handler as an unhandled rejection
      and the reader saw a save button that did nothing. The checks above
      are what SHOULD catch a bad value; this is what catches the one that
      was missed, and turns it into a message instead of silence.
    */
    let result: SaveResult | null;
    try {
      result = buildSaveResult();
    } catch (e) {
      setFormError({ kind: 'caught', cause: e });
      return;
    }
    // Nothing in flight: buildSaveResult has already set the form error.
    if (!result) return;
    busyRef.current = true;
    setBusy(true);
    try {
      await onSave(result);
      onClose();
    } catch (e) {
      setFormError({ kind: 'caught', cause: e });
      // Only on failure. On success the dialog closes, and clearing the flag
      // after that would be setting state on something unmounted.
      busyRef.current = false;
      setBusy(false);
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
      setFormError({ kind: 'caught', cause: e });
    } finally {
      setSeriesTimeZoneBusy(false);
    }
  };

  const handleDelete = async () => {
    if (!occ || busyRef.current) return;
    const result: DeleteResult = isRecurring
      ? { kind: 'deleteOccurrence', occ, scope }
      : { kind: 'deleteOne', id: occ.event.id };
    busyRef.current = true;
    setBusy(true);
    try {
      await onDelete(result);
      onClose();
    } catch (e) {
      setFormError({ kind: 'caught', cause: e });
      busyRef.current = false;
      setBusy(false);
    }
  };

  /*
    ESCAPE CLOSES IT, and the background does not scroll behind it.

    Both are things the backdrop click already implied and neither was
    actually there. The scroll lock matters more on a phone than a desktop: a
    full-height sheet over a scrollable page means a drag that misses the form
    scrolls the calendar underneath, and the reader loses their place without
    seeing it happen.
  */
  useDialogChrome(onClose, () => busyRef.current);

  /*
    A FAILED SAVE HAS TO BE SEEN.

    The message renders with the fields, which on a phone means it can be
    below the fold -- the save button is in the header, so a reader can press
    it without the end of the form ever being on screen, and then nothing
    appears to happen. Scrolling it into view is the only thing that makes the
    failure visible from where the press happened.

    role="alert" on the message covers a screen reader; this covers a sighted
    one. Desktop does not need it (the modal is as tall as its contents) but
    it is harmless there, so there is no second condition to keep in step.
  */
  useEffect(() => {
    if (formError) errorRef.current?.scrollIntoView({ block: 'nearest' });
  }, [formError]);

  /*
    P8-mobile-1 (M3): while the notes are being edited on a phone, keep them in
    view when the keyboard changes the visible area. With the viewport set to
    resize content (index.html) the sheet shrinks above the keyboard; this
    re-centres the field inside the scrolling body. Where visualViewport is
    missing nothing happens.
  */
  useEffect(() => {
    const v = typeof window === 'undefined' ? undefined : window.visualViewport;
    if (!isMobile || !memoFocused || !v) return;
    const keep = () => memoRef.current?.scrollIntoView({ block: 'nearest' });
    v.addEventListener('resize', keep);
    return () => v.removeEventListener('resize', keep);
  }, [isMobile, memoFocused]);

  const heading = occ ? tr('event.dialog.edit') : tr('event.dialog.create');

  /*
    ONE FIELD TREE, TWO SHELLS.

    The phone needs the save button where a thumb can reach it without
    scrolling to the end of nine inputs, and the desktop keeps the dialog it
    has. What must NOT differ is the fields: a second copy of them would be a
    second place for a validation, a label or an option list to be forgotten.
    So the shells below arrange this, and never restate it.
  */
  const fields = (
    <>
        {isRecurring && (
          <div className="field">
            <span>{tr('event.scope.label')}</span>
            <div className="scope-row">
              <label className="scope-option">
                <input type="radio" checked={scope === 'only'} onChange={() => changeScope('only')} />
                <span>{tr('event.scope.only')}</span>
              </label>
              <label className="scope-option">
                <input type="radio" checked={scope === 'all'} onChange={() => changeScope('all')} />
                <span>{tr('event.scope.all')}</span>
              </label>
            </div>
          </div>
        )}

        <label className="field">
          <span>{tr('event.field.title')}</span>
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
          <span>{tr('event.field.allDay')}</span>
        </label>

        {/*
          DATE AND TIME INPUTS (P8-b5.6b-2). Typed text is the main control on
          a desktop, the calendar and the clock are helpers; the mobile layout
          opens them first. Each input commits the same "YYYY-MM-DD" / "HH:mm"
          the native controls did, so everything from readForm on is
          unchanged. Emptying or mistyping a field no longer reads as '': the
          field keeps its last good value, turns red and says why, and
          readForm refuses to save while any field holds such a draft.
        */}
        {allDay ? (
          <div className="field-row">
            <div className="field">
              <span>{allDayStartLabel}</span>
              <DateInput
                label={allDayStartLabel}
                value={startDate}
                mobile={isMobile}
                onCommit={setStartDate}
                onInvalid={(r) => setDraftIssue('allDayStart', r)}
              />
            </div>
            <div className="field">
              <span>{allDayEndLabel}</span>
              <DateInput
                label={allDayEndLabel}
                value={endDateInclusive}
                mobile={isMobile}
                onCommit={setEndDateInclusive}
                onInvalid={(r) => setDraftIssue('allDayEnd', r)}
              />
            </div>
          </div>
        ) : (
          <>
            <div className="field-row">
              {(['start', 'end'] as const).map((which) => {
                const local = which === 'start' ? startLocal : endLocal;
                const setLocal = which === 'start' ? setStartLocal : setEndLocal;
                const [d, t] = splitLocal(local);
                const fieldLabel = timedFieldLabel(which);
                return (
                  <div key={which} className="field dt-pair" role="group" aria-label={fieldLabel}>
                    <span>{fieldLabel}</span>
                    <div className="dt-pair-inputs">
                      <DateInput
                        label={`${fieldLabel} ${tr('event.dt.date')}`}
                        value={d}
                        mobile={isMobile}
                        onCommit={(next) => setLocal(joinLocal(next, t))}
                        onInvalid={(r) => setDraftIssue(which === 'start' ? 'startDate' : 'endDate', r)}
                      />
                      <TimeInput
                        label={`${fieldLabel} ${tr('event.dt.time')}`}
                        value={t}
                        mobile={isMobile}
                        onCommit={(next) => setLocal(joinLocal(d, next))}
                        onInvalid={(r) => setDraftIssue(which === 'start' ? 'startTime' : 'endTime', r)}
                      />
                    </div>
                  </div>
                );
              })}
            </div>
            {(['start', 'end'] as const).map((which) => {
              const local = which === 'start' ? startLocal : endLocal;
              return (
                <WallTimeNotice
                  key={which}
                  name={`dt-fold-${which}`}
                  fieldLabel={timedFieldLabel(which)}
                  local={local}
                  check={checkWallTime(local, timeZone)}
                  choice={foldPickFor(which, local)}
                  onChoose={(choice) => setFoldPicks((p) => ({ ...p, [which]: { local, choice } }))}
                />
              );
            })}
          </>
        )}

        <label className="field">
          <span>{tr('event.field.description')}</span>
          <textarea
            ref={memoRef}
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            onFocus={() => setMemoFocused(true)}
            onBlur={() => setMemoFocused(false)}
            maxLength={DESCRIPTION_MAX}
            rows={3}
          />
        </label>
        {/*
          P8-mobile-1 (M3): on a phone, Enter in the notes is a new line, so
          the keyboard offers no way to finish. "Done" only takes the focus
          away -- the text stays, nothing is saved or closed, and the browser's
          back button is untouched. The mousedown is cancelled so pressing it
          does not blur the notes first and remove the button before its click.
        */}
        {isMobile && memoFocused && (
          <div className="memo-done-row">
            <button
              type="button"
              className="btn"
              aria-label={tr('event.memo.doneLabel')}
              onMouseDown={(e) => e.preventDefault()}
              onClick={() => memoRef.current?.blur()}
            >
              {tr('event.memo.done')}
            </button>
          </div>
        )}

        <div className="field-row">
          <label className="field">
            <span>{tr('event.field.category')}</span>
            <input
              value={category}
              onChange={(e) => setCategory(e.target.value)}
              maxLength={CATEGORY_MAX}
            />
          </label>
          <label className="field">
            <span>{tr('event.field.visibility')}</span>
            <select value={visibility} onChange={(e) => setVisibility(e.target.value as Visibility)}>
              {VISIBILITY_OPTIONS.map((v) => (
                <option key={v.value} value={v.value}>{tr(v.key)}</option>
              ))}
            </select>
          </label>
        </div>

        {/* Its own row rather than a third column beside the category and
            visibility fields in the row above: the modal is 460px at most and
            a third field pushed the select past the
            edge, leaving the dialog horizontally scrollable. A row of its own
            needs no CSS and keeps the tab order -- after everything a busy event
            fills in, before the save button -- so the usual flow of title then
            save still passes no new control. Defaulting to Busy is what makes
            leaving it alone the same as not seeing it. */}
        <div className="field-row">
          <label className="field">
            <span>{tr('event.field.availability')}</span>
            <select
              value={availability}
              onChange={(e) => setAvailability(e.target.value as Availability)}
            >
              {AVAILABILITIES.map((a) => (
                <option key={a} value={a}>{availabilityLabel(a, language)}</option>
              ))}
            </select>
          </label>
        </div>

        <RecurrenceEditor
          value={recurrenceForm}
          onChange={setRecurrenceForm}
          disabled={!recurrenceEditable}
          onUntilInvalid={(r) => setDraftIssue('until', r)}
          mobile={isMobile}
        />

        {timezoneField.kind === 'adopting' &&
          (timezoneField.timezone ? (
            <p className="form-hint">{tr('event.tz.recurrence', { timezone: timezoneField.timezone })}</p>
          ) : (
            <p className="form-error">{tr('event.tz.unresolved')}</p>
          ))}

        {timezoneField.kind === 'series-unset' && (
          <div className="field">
            <span>{tr('event.tz.label')}</span>
            <div className="tz-row">
              <span className="form-hint">{tr('event.tz.unset')}</span>
              <button
                className="btn"
                disabled={!timezoneField.canSet || seriesTimeZoneBusy}
                onClick={applySeriesTimeZone}
              >
                {storableTimeZone
                  ? tr('event.tz.setCurrent', { timezone: storableTimeZone })
                  : tr('event.tz.setCurrentUnknown')}
              </button>
            </div>
            {!timezoneField.canSet && <p className="form-error">{tr('event.tz.unavailable')}</p>}
          </div>
        )}

        {timezoneField.kind === 'series-set' && (
          <div className="field">
            <span>{tr('event.tz.label')}</span>
            <div className="tz-row">
              <span className="form-hint">{timezoneField.timezone}</span>
              {timezoneField.canChange && (
                <button className="btn" disabled={seriesTimeZoneBusy} onClick={applySeriesTimeZone}>
                  {tr('event.tz.changeToCurrent', { timezone: storableTimeZone ?? '' })}
                </button>
              )}
            </div>
          </div>
        )}

        {/*
          THE ERROR SITS WITH THE FIELDS, not in the shell, so it scrolls with
          them. On the phone the shell also scrolls it into view after a failed
          save -- see the effect above the shells -- because a sheet tall
          enough to need scrolling can put this below the fold.
        */}
        {formError && (
          <p className="form-error" ref={errorRef} role="alert">
            {eventFormErrorText(formError, language)}
          </p>
        )}
    </>
  );

  const deleteButton = occ ? (
    <button className="btn danger" disabled={busy} onClick={handleDelete}>
      {tr('common.delete')}
    </button>
  ) : null;

  if (isMobile) {
    return (
      <div className="sheet-backdrop">
        <div className="sheet" role="dialog" aria-modal="true" aria-label={heading}>
          {/*
            HEADER, BODY, FOOTER -- three boxes, and only the middle one
            scrolls. Save and cancel are in the header because the body is
            nine inputs tall: in the modal they sat at the end of it, so
            saving meant scrolling past everything first. A soft keyboard
            makes that worse, since it takes the bottom half of the screen.
          */}
          <div className="sheet-header">
            <button className="btn" disabled={busy} onClick={onClose}>
              {tr('common.cancel')}
            </button>
            <h2 className="sheet-title">{heading}</h2>
            <button className="btn primary" disabled={busy} onClick={handleSave}>
              {busy ? tr('common.saving') : tr('common.save')}
            </button>
          </div>

          <div className="sheet-body">{fields}</div>

          {deleteButton && <div className="sheet-footer">{deleteButton}</div>}
        </div>
      </div>
    );
  }

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()} role="dialog" aria-modal="true">
        <h3 className="modal-title">{heading}</h3>

        {fields}

        <div className="modal-actions">
          {deleteButton}
          <div className="spacer" />
          <button className="btn" disabled={busy} onClick={onClose}>{tr('common.cancel')}</button>
          <button className="btn primary" disabled={busy} onClick={handleSave}>
            {busy ? tr('common.saving') : tr('common.save')}
          </button>
        </div>
      </div>
    </div>
  );
}
