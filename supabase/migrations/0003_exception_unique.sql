-- TimeWeave Phase 4: enforce ONE exception row per (master occurrence).
--
-- Recurrence exceptions live in the same `events` table (recurrence_id -> master),
-- keyed type-safely by EITHER recurrence_slot_start (timed master) OR
-- recurrence_slot_date (all-day master). Without a uniqueness guarantee, a race
-- or a bug could create two exception rows for the same occurrence, and occurrence
-- expansion would then apply an arbitrary one. Uniqueness MUST be enforced in the
-- DB (not only in the client) so it holds under concurrency and across sessions.
--
-- Two PARTIAL unique indexes (one per slot-key type). Partial `where ... is not
-- null` so ordinary rows (one-off events and masters, whose slot keys are both
-- null) are never constrained and can coexist freely.
--
-- A violation raises SQLSTATE 23505 (unique_violation); the app maps it to a
-- DuplicateExceptionError.

create unique index events_excl_timed_uidx
  on public.events (recurrence_id, recurrence_slot_start)
  where recurrence_slot_start is not null;

create unique index events_excl_allday_uidx
  on public.events (recurrence_id, recurrence_slot_date)
  where recurrence_slot_date is not null;
