-- ============================================================================
-- TimeWeave Phase 5b-2 / step B-4 -- TEMPORARY legacy fixture.
--
-- THIS IS NOT A MIGRATION AND NOT A TEST. It is a one-shot, hand-run statement
-- that writes ONE row and leaves it behind on purpose. It lives beside the test
-- suites because those are hand-run too, but it must never be folded into
-- 0008_events_timezone.sql (a migration must not create fixtures) nor into
-- 0008_events_timezone_test.sql (that file rolls everything back, which is
-- exactly what this row must survive).
--
-- ---------------------------------------------------------------------------
-- RUN THIS BEFORE APPLYING 0008.
-- ---------------------------------------------------------------------------
--
-- Today this is an ordinary timed recurrence master. Once 0008 adds the
-- timezone column it becomes a genuine legacy M0 row (a timed master with
-- timezone IS NULL) -- and that is the ONLY way to obtain one, because the
-- state machine 0008 installs has no transition leading into M0. Sections 4 and
-- 6 of the 0008 suite need such a row to verify M0 -> M0, M0 -> M1 and M0 -> N
-- against the real trigger, without ever disabling or weakening it.
--
-- start_at sits in 2030 so the row cannot overlap any test window even while it
-- exists. The 0008 suite additionally removes it, by this exact id, inside its
-- own transaction before it touches get_free_busy.
--
-- ---------------------------------------------------------------------------
-- STEP B-5 -- verify, right after running this file:
--
--   select id, owner_id, all_day, rrule, start_at, end_at, visibility, title
--   from public.events
--   where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
--
--   Expect exactly ONE row, id 5b2f1c7e-0000-4000-8000-000000000001,
--   all_day = false, rrule = 'FREQ=WEEKLY;BYDAY=MO'.
--
-- ---------------------------------------------------------------------------
-- STEP E-3 -- delete it again, AFTER the 0008 suite has passed and step E-2 has
-- confirmed the suite's ROLLBACK restored it as M0:
--
--   delete from public.events where id = '5b2f1c7e-0000-4000-8000-000000000001';
--
--   Expect DELETE 1. After this point an M0 row can no longer be created on an
--   0008-applied database; recreating one means rolling 0008 back, running this
--   file again, and re-applying 0008.
-- ---------------------------------------------------------------------------
--
-- The owner id below is the dedicated development test user, the same one
-- 0006 and 0007 use. Those suites require it to hold ZERO events when they
-- start, which is why this fixture is removed again at step E-3 -- before they
-- are re-run.
-- ============================================================================
insert into public.events (
  id,
  owner_id,
  title,
  description,
  category,
  visibility,
  all_day,
  start_at,
  end_at,
  start_date,
  end_date,
  rrule,
  recurrence_id,
  recurrence_slot_start,
  recurrence_slot_date,
  is_cancelled
) values (
  '5b2f1c7e-0000-4000-8000-000000000001',
  '5e86935f-7661-4741-868f-0f51c4cf1727',
  'TW5B2-LEGACY (temporary test fixture)',
  null,
  null,
  'private',
  false,
  timestamptz '2030-01-07 01:00:00+00',
  timestamptz '2030-01-07 02:00:00+00',
  null,
  null,
  'FREQ=WEEKLY;BYDAY=MO',
  null,
  null,
  null,
  false
);
