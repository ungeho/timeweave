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
import { expandEvents } from '../services/occurrences';
import {
  editOccurrence as editOccurrenceOp,
  deleteOccurrence as deleteOccurrenceOp,
  setSeriesTimezone as setSeriesTimezoneOp,
} from '../services/recurrenceOps';

export interface UseEvents {
  loading: boolean;
  error: string | null;
  rows: EventRow[];
  /** Occurrences expanded for [rangeStartIso, rangeEndIso). */
  occurrencesIn: (rangeStartIso: string, rangeEndIso: string) => EventOccurrence[];
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
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      setRows(await repo.list());
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
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

  return {
    loading,
    error,
    rows,
    occurrencesIn,
    create,
    update,
    remove,
    editOccurrence,
    deleteOccurrence,
    setSeriesTimezone,
    reload,
  };
}
