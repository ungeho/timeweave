/**
 * Bridges the repository (data) and services (schedule logic) for the UI.
 * Components call these methods and read `occurrences`; they never touch
 * localStorage or the expansion logic directly.
 */

import { useCallback, useEffect, useMemo, useState } from 'react';
import type {
  EditScope,
  EventEditInput,
  EventOccurrence,
  EventRow,
  NewEvent,
  TimezoneIntent,
} from '../types/event';
import { getEventRepository } from '../repositories/eventRepository';
import { expandEvents, unexpandableMasters } from '../services/occurrences';
import {
  editOccurrence as editOccurrenceOp,
  deleteOccurrence as deleteOccurrenceOp,
  setSeriesTimezone as setSeriesTimezoneOp,
} from '../services/recurrenceOps';

/**
 * A failed load, holding the CAUSE rather than a sentence.
 *
 * A TAGGED OBJECT, NOT A BARE `unknown`. The consumer's failure test is
 * `events.error !== null`, and `unknown` includes null and undefined -- so a
 * `throw null` (or a rejected promise with no reason) would have set the state
 * to a value indistinguishable from "no error", and the banner would silently
 * not appear for a load that genuinely failed. The wrapper means the FACT of
 * the failure is carried by the object's existence and the cause is just a
 * field, which can hold anything at all.
 *
 * The cause is not rendered here. `features/calendar/loadErrorText` turns it
 * into words, at the moment the banner is drawn, in the language the owner is
 * reading -- which is the whole point of keeping it.
 */
export interface EventsLoadError {
  readonly kind: 'error';
  /** Whatever the promise rejected with: an Error, a string, anything. */
  readonly cause: unknown;
}

export interface UseEvents {
  loading: boolean;
  /**
   * The failed load, or null. WAS `string | null`, resolved at the moment of
   * failure -- which pinned the wording to the language that happened to be
   * current when the fetch rejected, so a later language change re-rendered
   * every other string on screen and left this one in Japanese.
   */
  error: EventsLoadError | null;
  rows: EventRow[];
  /** Occurrences expanded for [rangeStartIso, rangeEndIso). */
  occurrencesIn: (rangeStartIso: string, rangeEndIso: string) => EventOccurrence[];
  /**
   * Recurring masters whose rule this client cannot expand (K12). occurrencesIn
   * leaves each such series out instead of failing; the calendar says so.
   * Independent of the range on screen.
   */
  unexpandableSeries: EventRow[];
  create: (input: NewEvent) => Promise<void>;
  update: (id: string, patch: Partial<EventRow>) => Promise<void>;
  remove: (id: string) => Promise<void>;
  /**
   * Edit a recurring occurrence. scope 'only' overrides just this occurrence (an
   * exception row, or an in-place update if it's already one); scope 'all' edits
   * the master — blocked with SeriesEditBlockedError if the series has exceptions.
   *
   * `intent` carries the zone only when a scope-'all' edit turns an all-day
   * series timed; every other edit leaves `timezone` alone ('keep').
   */
  editOccurrence: (
    occ: EventOccurrence,
    edited: EventEditInput,
    scope: EditScope,
    intent?: TimezoneIntent,
  ) => Promise<void>;
  /**
   * Delete a recurring occurrence. scope 'only' cancels just this occurrence (a
   * tombstone, or flips an existing exception to cancelled); scope 'all' deletes
   * the master and cascades to all its exceptions.
   */
  deleteOccurrence: (occ: EventOccurrence, scope: EditScope) => Promise<void>;
  /**
   * Set or change the zone of an existing timed recurrence master. Deliberately
   * separate from every save path: an ordinary edit must never move a series,
   * and this one is blocked with SeriesEditBlockedError when the series has
   * exceptions (their slot keys would go stale).
   */
  setSeriesTimezone: (masterId: string, timezone: string) => Promise<void>;
  reload: () => Promise<void>;
}

export function useEvents(): UseEvents {
  const repo = useMemo(() => getEventRepository(), []);
  const [rows, setRows] = useState<EventRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<EventsLoadError | null>(null);

  const reload = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      setRows(await repo.list());
    } catch (e) {
      // The cause, untouched. Nothing here decides what it says -- this hook
      // imports no dictionary and knows no language, which is also why a
      // language change can never reach `reload` and re-run the fetch.
      setError({ kind: 'error', cause: e });
    } finally {
      setLoading(false);
    }
  }, [repo]);

  useEffect(() => {
    void reload();
  }, [reload]);

  const create = useCallback(
    async (input: NewEvent) => {
      await repo.create(input);
      await reload();
    },
    [repo, reload],
  );

  const update = useCallback(
    async (id: string, patch: Partial<EventRow>) => {
      await repo.update(id, patch);
      await reload();
    },
    [repo, reload],
  );

  const remove = useCallback(
    async (id: string) => {
      await repo.remove(id);
      await reload();
    },
    [repo, reload],
  );

  const editOccurrence = useCallback(
    async (
      occ: EventOccurrence,
      edited: EventEditInput,
      scope: EditScope,
      intent: TimezoneIntent = { kind: 'keep' },
    ) => {
      await editOccurrenceOp(repo, rows, occ, edited, scope, intent);
      await reload();
    },
    [repo, reload, rows],
  );

  const deleteOccurrence = useCallback(
    async (occ: EventOccurrence, scope: EditScope) => {
      await deleteOccurrenceOp(repo, occ, scope);
      await reload();
    },
    [repo, reload],
  );

  const setSeriesTimezone = useCallback(
    async (masterId: string, timezone: string) => {
      await setSeriesTimezoneOp(repo, rows, masterId, timezone);
      await reload();
    },
    [repo, reload, rows],
  );

  const occurrencesIn = useCallback(
    (rangeStartIso: string, rangeEndIso: string) =>
      expandEvents(rows, rangeStartIso, rangeEndIso),
    [rows],
  );

  const unexpandableSeries = useMemo(() => unexpandableMasters(rows), [rows]);

  return {
    loading,
    error,
    rows,
    occurrencesIn,
    unexpandableSeries,
    create,
    update,
    remove,
    editOccurrence,
    deleteOccurrence,
    setSeriesTimezone,
    reload,
  };
}
