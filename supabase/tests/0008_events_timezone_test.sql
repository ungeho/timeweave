-- TimeWeave Phase 5b-2 test suite for 0008_events_timezone.sql.
--
-- NOT A MIGRATION. Run by hand against a DEVELOPMENT project after applying
-- 0008. Wrapped in a transaction ending in ROLLBACK, so it leaves nothing
-- behind -- including the legacy fixture it borrows.
--
-- !! RUN THE WHOLE FILE, INCLUDING THE FINAL ROLLBACK. !!
--
-- A failing assert aborts the transaction; every statement after it reports
-- "current transaction is aborted". Read the FIRST error -- that is the real
-- failure.
--
-- PREREQUISITE: the temporary legacy fixture from 0008_events_timezone_preflight.sql
-- (step B-4) must exist. It is the only M0 row obtainable once 0008 is applied,
-- because no transition leads into M0. Section 4 borrows it and mutates it
-- inside sub-transactions that are always undone; Section 6 deletes it BY ITS
-- FIXED ID inside the outer transaction so the Free/Busy checks start from an
-- empty owner. The final ROLLBACK restores it either way. Step E-2 verifies
-- that from outside, and only then does step E-3 delete it for good.
--
-- This suite never inserts into auth.users, and never deletes or updates a row
-- it did not itself insert -- with the single, deliberate exception of the B-4
-- fixture, whose id is fixed, known, and asserted before it is touched.
--
-- SECTION 5 SWITCHES ROLE to `authenticated`. It is a required part of this
-- suite, not an optional extra: it is the only place that proves the EXECUTE
-- grants in 0008 section 4 are sufficient on the path the application actually
-- takes. If role switching or JWT claims do not behave as expected, STOP and
-- diagnose. Do not substitute a browser walkthrough -- that comes afterwards,
-- as application integration confirmation, and verifies something else.
--
-- Preflight: assumes pgcrypto lives in the `extensions` schema (Supabase
-- default), as 0005-0007 do.

begin;

-- ============================================================================
-- SECTION 1 -- events_timezone_placement: WHICH rows may carry a time zone.
--
-- Ordering these tests depend on: BEFORE ROW triggers run before CHECK
-- constraints. A row that is both misplaced AND carries a bad value therefore
-- fails with TIMEWEAVE_TZ_INVALID, never with the constraint. Every fixture
-- here uses a VALID zone so that the placement CHECK is what actually rejects
-- it.
-- ============================================================================
do $$
declare
  v_owner  constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_id     uuid;
  v_failed boolean;
  v_state  text;
  v_constr text;
begin
  raise notice 'Section 1: events_timezone_placement';

  -- 1.1 timed recurrence master WITH a zone: the one shape that may have one.
  v_id := gen_random_uuid();
  insert into public.events (id, owner_id, title, all_day, start_at, end_at, rrule, timezone)
  values (v_id, v_owner, '', false,
          timestamptz '2026-09-01 01:00:00+00', timestamptz '2026-09-01 02:00:00+00',
          'FREQ=DAILY', 'Asia/Tokyo');
  assert (select e.timezone from public.events e where e.id = v_id) = 'Asia/Tokyo',
    '1.1 timed master keeps its zone';
  delete from public.events where id = v_id;

  -- 1.2 all-day recurrence master WITH a zone -> rejected by the constraint.
  v_failed := false;
  begin
    insert into public.events (id, owner_id, title, all_day, start_date, end_date, rrule, timezone)
    values (gen_random_uuid(), v_owner, '', true,
            date '2026-09-01', date '2026-09-02', 'FREQ=DAILY', 'Asia/Tokyo');
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_constr = constraint_name;
    v_failed := true;
  end;
  assert v_failed, '1.2 all-day master must not carry a timezone';
  assert v_state = '23514', '1.2b sqlstate';
  assert v_constr = 'events_timezone_placement', '1.2c constraint name';

  -- 1.3 all-day one-off WITH a zone -> rejected.
  v_failed := false;
  begin
    insert into public.events (id, owner_id, title, all_day, start_date, end_date, timezone)
    values (gen_random_uuid(), v_owner, '', true,
            date '2026-09-01', date '2026-09-02', 'Asia/Tokyo');
  exception when others then
    get stacked diagnostics v_constr = constraint_name;
    v_failed := true;
  end;
  assert v_failed and v_constr = 'events_timezone_placement',
    '1.3 all-day one-off must not carry a timezone';

  -- 1.4 timed ONE-OFF with a zone -> rejected (no rrule, so not a master).
  v_failed := false;
  begin
    insert into public.events (id, owner_id, title, all_day, start_at, end_at, timezone)
    values (gen_random_uuid(), v_owner, '', false,
            timestamptz '2026-09-01 01:00:00+00', timestamptz '2026-09-01 02:00:00+00',
            'Asia/Tokyo');
  exception when others then
    get stacked diagnostics v_constr = constraint_name;
    v_failed := true;
  end;
  assert v_failed and v_constr = 'events_timezone_placement',
    '1.4 timed one-off must not carry a timezone';

  -- 1.5 exception row with a zone -> rejected. Needs a parent to point at.
  --     This is the case the recurrence_id IS NULL conjunct spells out: a time
  --     zone belongs to a master, never to an exception snapshot.
  v_id := gen_random_uuid();
  insert into public.events (id, owner_id, title, all_day, start_at, end_at, rrule, timezone)
  values (v_id, v_owner, '', false,
          timestamptz '2026-09-01 01:00:00+00', timestamptz '2026-09-01 02:00:00+00',
          'FREQ=DAILY', 'Asia/Tokyo');
  v_failed := false;
  begin
    insert into public.events (id, owner_id, title, all_day, start_at, end_at,
                               recurrence_id, recurrence_slot_start, timezone)
    values (gen_random_uuid(), v_owner, '', false,
            timestamptz '2026-09-02 01:00:00+00', timestamptz '2026-09-02 02:00:00+00',
            v_id, timestamptz '2026-09-02 01:00:00+00', 'Asia/Tokyo');
  exception when others then
    get stacked diagnostics v_constr = constraint_name;
    v_failed := true;
  end;
  assert v_failed and v_constr = 'events_timezone_placement',
    '1.5 exception rows must not carry a timezone';
  delete from public.events where id = v_id;

  -- 1.6 every shape with timezone NULL is accepted. The timed-master case is
  --     the legacy fixture, covered in Section 4.
  v_id := gen_random_uuid();
  insert into public.events (id, owner_id, title, all_day, start_date, end_date, rrule)
  values (v_id, v_owner, '', true, date '2026-09-01', date '2026-09-02', 'FREQ=DAILY');
  delete from public.events where id = v_id;

  v_id := gen_random_uuid();
  insert into public.events (id, owner_id, title, all_day, start_at, end_at)
  values (v_id, v_owner, '', false,
          timestamptz '2026-09-01 01:00:00+00', timestamptz '2026-09-01 02:00:00+00');
  delete from public.events where id = v_id;

  raise notice 'Section 1 OK';
end $$;

-- ============================================================================
-- SECTION 2 -- the VALUE: timezone_is_supported, and the TIMEWEAVE_TZ_INVALID
-- half of the error contract.
--
-- Value validation is concentrated in one function, so length, lexical shape,
-- forbidden names and catalog membership all surface through the SAME code
-- path with the SAME token. 2.5 and 2.5b pin exactly that.
--
-- Accepting Asia/Calcutta asserts a policy, not an oversight: it is a tzdata
-- link, and this suite pins the decision NOT to canonicalise. Accepting
-- Etc/GMT-9 pins the decision that a deliberately fixed offset is allowed.
-- Rejecting JST pins the reason catalog membership is required at all.
-- ============================================================================
do $$
declare
  v_owner  constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_id     uuid;
  v_tz     text;
  v_failed boolean;
  v_state  text;
  v_detail text;
begin
  raise notice 'Section 2: timezone_is_supported and the TZ_INVALID contract';

  -- 2.1 accepted names.
  foreach v_tz in array array[
    'Asia/Tokyo', 'America/New_York', 'Europe/London', 'Pacific/Auckland',
    'UTC', 'Etc/GMT-9', 'Asia/Calcutta', 'America/Argentina/Buenos_Aires'
  ] loop
    assert public.timezone_is_supported(v_tz),
      format('2.1 %s must be supported', v_tz);
  end loop;

  -- 2.2 refused names, covering every reason the function knows.
  foreach v_tz in array array[
    'Mars/Phobos',            -- not in the catalog
    '',                       -- empty
    'localtime',              -- server-configuration dependent
    'posix/Asia/Tokyo',       -- duplicate spelling
    'right/UTC',              -- leap-second counting
    'JST',                    -- abbreviation: fixed offset, ambiguous
    '<+09>-9',                -- raw POSIX specification
    'asia/tokyo',             -- wrong case
    'Asia/Tokyo ',            -- trailing space
    '/Asia/Tokyo',            -- leading separator
    'Asia Tokyo',             -- space instead of separator
    'Asia/Tokyo/Extra/Deep',  -- too many segments
    repeat('A', 65)           -- over the length cap
  ] loop
    assert not public.timezone_is_supported(v_tz),
      format('2.2 %s must be refused', v_tz);
  end loop;

  assert not public.timezone_is_supported(null), '2.3 NULL is not supported';

  -- 2.4 accepted names survive a real INSERT, byte for byte.
  foreach v_tz in array array['Asia/Tokyo', 'UTC', 'Etc/GMT-9', 'Asia/Calcutta'] loop
    v_id := gen_random_uuid();
    insert into public.events (id, owner_id, title, all_day, start_at, end_at, rrule, timezone)
    values (v_id, v_owner, '', false,
            timestamptz '2026-09-01 01:00:00+00', timestamptz '2026-09-01 02:00:00+00',
            'FREQ=DAILY', v_tz);
    assert (select e.timezone from public.events e where e.id = v_id) = v_tz,
      format('2.4 %s stored verbatim, not canonicalised', v_tz);
    delete from public.events where id = v_id;
  end loop;

  -- 2.5 an unknown name: 23514 + TIMEWEAVE_TZ_INVALID.
  v_failed := false;
  begin
    insert into public.events (id, owner_id, title, all_day, start_at, end_at, rrule, timezone)
    values (gen_random_uuid(), v_owner, '', false,
            timestamptz '2026-09-01 01:00:00+00', timestamptz '2026-09-01 02:00:00+00',
            'FREQ=DAILY', 'Mars/Phobos');
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
    v_failed := true;
  end;
  assert v_failed, '2.5 unknown zone must be rejected';
  assert v_state = '23514', '2.5b sqlstate is 23514';
  assert v_detail = 'TIMEWEAVE_TZ_INVALID', '2.5c detail token';

  -- 2.5b length and lexical failures reach the SAME contract. This is the
  --      assertion that would break if a separate format CHECK were added back.
  foreach v_tz in array array[repeat('A', 65), 'Asia Tokyo', 'Asia/Tokyo/Extra/Deep'] loop
    v_failed := false;
    begin
      insert into public.events (id, owner_id, title, all_day, start_at, end_at, rrule, timezone)
      values (gen_random_uuid(), v_owner, '', false,
              timestamptz '2026-09-01 01:00:00+00', timestamptz '2026-09-01 02:00:00+00',
              'FREQ=DAILY', v_tz);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
      v_failed := true;
    end;
    assert v_failed, format('2.5b %s must be rejected', v_tz);
    assert v_state = '23514' and v_detail = 'TIMEWEAVE_TZ_INVALID',
      format('2.5b %s uses the single TZ_INVALID contract', v_tz);
  end loop;

  -- 2.6 the same contract on the UPDATE path.
  v_id := gen_random_uuid();
  insert into public.events (id, owner_id, title, all_day, start_at, end_at, rrule, timezone)
  values (v_id, v_owner, '', false,
          timestamptz '2026-09-01 01:00:00+00', timestamptz '2026-09-01 02:00:00+00',
          'FREQ=DAILY', 'Asia/Tokyo');
  v_failed := false;
  begin
    update public.events set timezone = 'localtime' where id = v_id;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
    v_failed := true;
  end;
  assert v_failed and v_state = '23514' and v_detail = 'TIMEWEAVE_TZ_INVALID',
    '2.6 UPDATE rejects localtime with the same contract';
  delete from public.events where id = v_id;

  raise notice 'Section 2 OK';
end $$;

-- ============================================================================
-- SECTION 3 -- events_timezone_transition_error: every transition, with no
-- table, no fixture, no lock and no privilege involved.
--
-- This is the exhaustive coverage. Section 4 then proves the trigger actually
-- routes through it.
--
-- Argument order:
--   (is_insert, old_all_day, old_rrule, old_tz, new_all_day, new_rrule, new_tz)
-- ============================================================================
do $$
declare
  f  constant text := 'FREQ=DAILY';
  tz constant text := 'Asia/Tokyo';
begin
  raise notice 'Section 3: transition function, all paths';

  -- INSERT
  assert public.events_timezone_transition_error(
    true, null, null, null, false, null, null) is null,            '3.1  INSERT -> N (timed one-off)';
  assert public.events_timezone_transition_error(
    true, null, null, null, true, null, null) is null,             '3.2  INSERT -> N (all-day one-off)';
  assert public.events_timezone_transition_error(
    true, null, null, null, true, f, null) is null,                '3.3  INSERT -> N (all-day master)';
  assert public.events_timezone_transition_error(
    true, null, null, null, false, f, null) = 'TIMEWEAVE_TZ_REQUIRED',
                                                                   '3.4  INSERT -> M0 REJECTED';
  assert public.events_timezone_transition_error(
    true, null, null, null, false, f, tz) is null,                 '3.5  INSERT -> M1';

  -- UPDATE from N
  assert public.events_timezone_transition_error(
    false, false, null, null, false, null, null) is null,          '3.6  N -> N';
  assert public.events_timezone_transition_error(
    false, false, null, null, false, f, null) = 'TIMEWEAVE_TZ_REQUIRED',
                                                                   '3.7  N -> M0 REJECTED';
  assert public.events_timezone_transition_error(
    false, false, null, null, false, f, tz) is null,               '3.8  N -> M1';
  assert public.events_timezone_transition_error(
    false, true, f, null, false, f, null) = 'TIMEWEAVE_TZ_REQUIRED',
                                                                   '3.9  all-day master -> M0 REJECTED';

  -- UPDATE from M0
  assert public.events_timezone_transition_error(
    false, false, f, null, false, null, null) is null,             '3.10 M0 -> N';
  assert public.events_timezone_transition_error(
    false, false, f, null, false, f, null) is null,                '3.11 M0 -> M0 GRANDFATHERED';
  assert public.events_timezone_transition_error(
    false, false, f, null, false, 'FREQ=WEEKLY', null) is null,    '3.12 M0 -> M0 with a new rrule';
  assert public.events_timezone_transition_error(
    false, false, f, null, false, f, tz) is null,                  '3.13 M0 -> M1';

  -- UPDATE from M1
  assert public.events_timezone_transition_error(
    false, false, f, tz, false, null, null) is null,               '3.14 M1 -> N';
  assert public.events_timezone_transition_error(
    false, false, f, tz, false, f, null) = 'TIMEWEAVE_TZ_CLEARED', '3.15 M1 -> M0 REJECTED';
  assert public.events_timezone_transition_error(
    false, false, f, tz, false, f, tz) is null,                    '3.16 M1 -> M1 unchanged';
  assert public.events_timezone_transition_error(
    false, false, f, tz, false, f, 'Europe/London') is null,       '3.17 M1 -> M1'' rezoned';

  raise notice 'Section 3 OK';
end $$;

-- ============================================================================
-- SECTION 4 -- the real trigger path on the real table, including the three
-- M0-origin transitions that only the B-4 legacy fixture can reach.
--
-- Each M0-origin case that would consume the M0 state runs inside a
-- sub-transaction undone by a sentinel exception, so the next case starts from
-- M0 again. The sentinel carries its own SQLSTATE so that an assert failure
-- inside the block (P0004) still propagates instead of being swallowed.
-- ============================================================================
do $$
declare
  v_owner  constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_legacy constant uuid := '5b2f1c7e-0000-4000-8000-000000000001';
  v_id     uuid;
  v_failed boolean;
  v_state  text;
  v_detail text;
begin
  raise notice 'Section 4: trigger path, including legacy M0';

  -- --------------------------------------------------------- PRECONDITIONS
  assert exists (select 1 from public.events e where e.id = v_legacy),
    '4.0.1 the B-4 legacy fixture is missing. Create it BEFORE applying 0008; '
    'it cannot be created afterwards.';
  assert (select e.owner_id from public.events e where e.id = v_legacy) = v_owner,
    '4.0.2 legacy fixture belongs to the test owner';
  assert (select e.all_day = false and e.rrule is not null and e.timezone is null
          from public.events e where e.id = v_legacy),
    '4.0.3 legacy fixture must be M0 (timed master, no timezone)';

  -- ------------------------------------------------------------ INSERT paths
  -- 4.1 INSERT -> M0 rejected.
  v_failed := false;
  begin
    insert into public.events (id, owner_id, title, all_day, start_at, end_at, rrule)
    values (gen_random_uuid(), v_owner, '', false,
            timestamptz '2026-09-01 01:00:00+00', timestamptz '2026-09-01 02:00:00+00',
            'FREQ=DAILY');
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
    v_failed := true;
  end;
  assert v_failed and v_state = '23514' and v_detail = 'TIMEWEAVE_TZ_REQUIRED',
    '4.1 INSERT of a zone-less timed master is rejected';

  -- 4.2 INSERT -> M1 accepted.
  v_id := gen_random_uuid();
  insert into public.events (id, owner_id, title, all_day, start_at, end_at, rrule, timezone)
  values (v_id, v_owner, '', false,
          timestamptz '2026-09-01 01:00:00+00', timestamptz '2026-09-01 02:00:00+00',
          'FREQ=DAILY', 'Asia/Tokyo');
  assert (select e.timezone from public.events e where e.id = v_id) = 'Asia/Tokyo',
    '4.2 INSERT -> M1';

  -- 4.3 M1 -> M0 rejected.
  v_failed := false;
  begin
    update public.events set timezone = null where id = v_id;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
    v_failed := true;
  end;
  assert v_failed and v_state = '23514' and v_detail = 'TIMEWEAVE_TZ_CLEARED',
    '4.3 clearing the zone of a timed master is rejected';

  -- 4.4 M1 -> M1' accepted (the DB allows rezoning; the app blocks it when the
  --     series has exceptions -- see services/seriesGuards.ts).
  update public.events set timezone = 'Europe/London' where id = v_id;
  assert (select e.timezone from public.events e where e.id = v_id) = 'Europe/London',
    '4.4 rezoning a master is allowed at the DB level';

  -- 4.5 M1 -> N accepted when rrule and timezone are cleared together.
  update public.events set rrule = null, timezone = null where id = v_id;
  assert (select e.rrule is null and e.timezone is null
          from public.events e where e.id = v_id),
    '4.5 M1 -> N';

  -- 4.6 N -> M0 rejected: a one-off promoted to a series is a NEW recurrence.
  v_failed := false;
  begin
    update public.events set rrule = 'FREQ=DAILY' where id = v_id;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
    v_failed := true;
  end;
  assert v_failed and v_state = '23514' and v_detail = 'TIMEWEAVE_TZ_REQUIRED',
    '4.6 promoting a one-off to a series without a zone is rejected';

  -- 4.7 N -> M1 accepted.
  update public.events set rrule = 'FREQ=DAILY', timezone = 'Asia/Tokyo' where id = v_id;
  assert (select e.timezone from public.events e where e.id = v_id) = 'Asia/Tokyo',
    '4.7 N -> M1';
  delete from public.events where id = v_id;

  -- ------------------------------------------- M0-origin paths (legacy row)
  -- 4.8 M0 -> M0: edits unrelated to time. The grandfather clause.
  update public.events set title = 'TW5B2-LEGACY edited'       where id = v_legacy;
  update public.events set visibility = 'busy_only'            where id = v_legacy;
  update public.events set description = 'd', category = 'c'   where id = v_legacy;
  assert (select e.timezone is null from public.events e where e.id = v_legacy),
    '4.8 legacy master survives ordinary edits with timezone still NULL';

  -- 4.9 M0 -> M0: even schedule edits. The "lenient" decision -- a legacy
  --     series may be rescheduled without being forced to guess its zone.
  update public.events
     set start_at = timestamptz '2030-02-04 03:00:00+00',
         end_at   = timestamptz '2030-02-04 04:00:00+00',
         rrule    = 'FREQ=WEEKLY;BYDAY=TU'
   where id = v_legacy;
  assert (select e.timezone is null from public.events e where e.id = v_legacy),
    '4.9 legacy master may change its schedule without declaring a zone';

  -- 4.10 M0 -> M1: the one intended migration path. Undone afterwards.
  begin
    update public.events set timezone = 'Asia/Tokyo' where id = v_legacy;
    assert (select e.timezone from public.events e where e.id = v_legacy) = 'Asia/Tokyo',
      '4.10 legacy master accepts a zone when its owner sets one';
    raise exception 'undo' using errcode = 'TW000';
  exception when sqlstate 'TW000' then null;
  end;
  assert (select e.timezone is null from public.events e where e.id = v_legacy),
    '4.10b sub-transaction restored the legacy row to M0';

  -- 4.11 M0 -> N: dropping the rrule. Undone afterwards.
  begin
    update public.events set rrule = null where id = v_legacy;
    assert (select e.rrule is null and e.timezone is null
            from public.events e where e.id = v_legacy),
      '4.11 legacy master may stop being a recurrence';
    raise exception 'undo' using errcode = 'TW000';
  exception when sqlstate 'TW000' then null;
  end;
  assert (select e.rrule is not null and e.timezone is null
          from public.events e where e.id = v_legacy),
    '4.11b sub-transaction restored the legacy row to M0';

  raise notice 'Section 4 OK';
end $$;

-- ============================================================================
-- SECTION 5 -- the path the application actually takes: role `authenticated`,
-- RLS on, EXECUTE privileges as granted by 0008 section 4.
--
-- REQUIRED, not optional. Reasoning about PostgreSQL's privilege model is not
-- the same as proving it: if EXECUTE on either helper were missing, every write
-- from the app would fail here with 42501 rather than in production. If role
-- switching or claims do not take effect, STOP and find out why. A browser
-- walkthrough is not a substitute -- it verifies application integration, and
-- comes after this suite passes.
--
-- PL/pgSQL has no SET statement, so set_config(..., is_local => true) is used;
-- everything reverts at transaction end regardless.
-- ============================================================================
do $$
declare
  v_owner  constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_id     constant uuid := gen_random_uuid();
  v_failed boolean;
  v_state  text;
  v_detail text;
begin
  raise notice 'Section 5: authenticated role path';

  -- 5.0.1-5.0.4 the grants themselves, checked before switching role.
  assert has_function_privilege('authenticated',
           'public.timezone_is_supported(text)', 'execute'),
    '5.0.1 authenticated may execute timezone_is_supported';
  assert has_function_privilege('authenticated',
           'public.events_timezone_transition_error(boolean,boolean,text,text,boolean,text,text)',
           'execute'),
    '5.0.2 authenticated may execute the transition helper';
  assert not has_function_privilege('anon',
           'public.timezone_is_supported(text)', 'execute'),
    '5.0.3 anon may NOT execute timezone_is_supported';
  assert not has_function_privilege('anon',
           'public.events_timezone_transition_error(boolean,boolean,text,text,boolean,text,text)',
           'execute'),
    '5.0.4 anon may NOT execute the transition helper';

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_owner::text, 'role', 'authenticated')::text,
                     true);
  perform set_config('role', 'authenticated', true);

  -- 5.0.5-5.0.6 prove the switch took effect BEFORE any DML, so that a setup
  --             failure surfaces as itself rather than as a confusing RLS error.
  assert current_user = 'authenticated',
    '5.0.5 role switch did not take effect -- stop and diagnose, do not skip';
  assert auth.uid() = v_owner,
    '5.0.6 auth.uid() does not resolve to the test owner -- stop and diagnose';

  -- 5.1 a valid timed recurrence goes in. owner_id comes from auth.uid().
  insert into public.events (id, title, all_day, start_at, end_at, rrule, timezone)
  values (v_id, 'tz-app', false,
          timestamptz '2026-09-01 01:00:00+00', timestamptz '2026-09-01 02:00:00+00',
          'FREQ=DAILY', 'Asia/Tokyo');
  assert (select e.owner_id from public.events e where e.id = v_id) = v_owner,
    '5.1 insert as authenticated succeeded; the helpers were callable';

  -- 5.2 the value contract holds for this role -- 23514, not 42501.
  v_failed := false;
  begin
    update public.events set timezone = 'Mars/Phobos' where id = v_id;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
    v_failed := true;
  end;
  assert v_failed, '5.2 invalid zone must be rejected for authenticated too';
  assert v_state = '23514' and v_detail = 'TIMEWEAVE_TZ_INVALID',
    '5.2b authenticated sees the same error contract (42501 here would mean a '
    'missing EXECUTE grant)';

  -- 5.3 and so does the transition contract.
  v_failed := false;
  begin
    update public.events set timezone = null where id = v_id;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
    v_failed := true;
  end;
  assert v_failed and v_state = '23514' and v_detail = 'TIMEWEAVE_TZ_CLEARED',
    '5.3 authenticated cannot clear a zone either';

  -- 5.4 DELETE fires no validation. Step E-3 depends on this.
  delete from public.events where id = v_id;
  assert not exists (select 1 from public.events e where e.id = v_id),
    '5.4 DELETE needs no timezone and triggers no validation';

  perform set_config('role', 'none', true);
  raise notice 'Section 5 OK';
end $$;

-- ============================================================================
-- SECTION 6 -- timezone NON-DISCLOSURE and Free/Busy payload shape.
--
-- What get_free_busy chooses to EXPAND is deliberately out of scope here. That
-- contract moves with each phase -- 5b-3 made timed DAILY/WEEKLY expandable --
-- and belongs to the suite of the phase that owns it. This section asserts only
-- that the column 0008 adds never reaches the public payload, and that the
-- answer's shape is unchanged.
--
-- Starts by removing the B-4 legacy fixture BY ITS FIXED ID: it is a timed
-- master, and its presence inside a window would flip complete to false. Every
-- other row belongs to earlier sections, which clean up after themselves, so
-- the owner must hold exactly that one row at this point -- asserted before
-- anything is deleted. No owner-wide DELETE is used anywhere in this suite.
--
-- The outer ROLLBACK brings the fixture back; step E-2 verifies that before
-- step E-3 removes it deliberately.
-- ============================================================================
do $$
declare
  v_owner   constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_legacy  constant uuid := '5b2f1c7e-0000-4000-8000-000000000001';
  v_from    constant timestamptz := timestamptz '2026-09-01 00:00:00+00';
  v_to      constant timestamptz := timestamptz '2026-09-08 00:00:00+00';
  v_fromd   constant date := date '2026-09-01';
  v_tod     constant date := date '2026-09-08';
  v_run     constant text := gen_random_uuid()::text;
  v_tok     constant text := 'tw5b2-test-' || v_run;
  v_link    constant uuid := gen_random_uuid();
  v_m       constant uuid := gen_random_uuid();
  v_tz      constant uuid := gen_random_uuid();
  v_deleted bigint;
  v_res     jsonb;
  v_keys    text[];
begin
  raise notice 'Section 6: get_free_busy unaffected, no timezone leak';

  -- ------------------------------------------- targeted fixture removal only
  assert (select count(*) from public.events e where e.owner_id = v_owner) = 1,
    '6.0.1 only the legacy fixture may remain at this point -- an earlier '
    'section left a row behind, or an unexpected row exists. Do NOT delete it.';
  assert exists (select 1 from public.events e
                 where e.id = v_legacy and e.owner_id = v_owner),
    '6.0.2 the single remaining row is the B-4 fixture';
  assert (select e.all_day = false and e.rrule is not null and e.timezone is null
          from public.events e where e.id = v_legacy),
    '6.0.3 the fixture is still M0 after Section 4';

  delete from public.events where id = v_legacy;
  get diagnostics v_deleted = row_count;
  assert v_deleted = 1, '6.0.4 exactly one row deleted, by fixed id';

  assert not exists (select 1 from public.events e where e.owner_id = v_owner),
    '6.0.5 owner is empty before the Free/Busy checks';

  insert into public.share_links (id, owner_id, token_hash, label, include_private,
                                  expires_at, revoked_at)
  values (v_link, v_owner, encode(extensions.digest(v_tok, 'sha256'), 'hex'),
          'TW5B2-TEST', true, null, null);

  -- 6.1 an all-day DAILY master still expands exactly as it did in 5b-1.
  insert into public.events (id, owner_id, title, visibility, all_day,
                             start_date, end_date, rrule)
  values (v_m, v_owner, '', 'busy_only', true,
          date '2026-08-01', date '2026-08-02', 'FREQ=DAILY');
  v_res := public.get_free_busy(v_tok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true, '6.1 complete';
  assert jsonb_array_length(v_res->'slots') = 1, '6.1b one merged span';
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', true, 'start_date', to_jsonb(date '2026-09-01'),
           'end_date', to_jsonb(date '2026-09-08')), '6.1c unchanged span';

  -- 6.2 the answer's SHAPE: nothing but complete and slots.
  select array_agg(k order by k) into v_keys from jsonb_object_keys(v_res) k;
  assert v_keys = array['complete', 'slots'], '6.2 top-level keys unchanged';
  select array_agg(distinct k order by k) into v_keys
  from jsonb_array_elements(v_res->'slots') s, jsonb_object_keys(s) k;
  assert v_keys <@ array['all_day', 'start', 'end', 'start_date', 'end_date'],
    '6.2b slot keys unchanged';

  -- 6.3 A timed master WITH a zone, inside the window.
  --     Free/Busy expansion semantics belong to later phases; this section only
  --     asserts that the stored timezone name never leaks into the public
  --     payload. Since 5b-3 may expand this series, the leak checks now
  --     exercise a non-empty timed payload as well.
  insert into public.events (id, owner_id, title, visibility, all_day,
                             start_at, end_at, rrule, timezone)
  values (v_tz, v_owner, '', 'busy_only', false,
          timestamptz '2026-09-02 01:00:00+00', timestamptz '2026-09-02 02:00:00+00',
          'FREQ=DAILY', 'Asia/Tokyo');
  v_res := public.get_free_busy(v_tok, v_from, v_to, v_fromd, v_tod);
  assert v_res::text not like '%Asia/Tokyo%', '6.3b the zone never reaches the payload';
  assert v_res::text not like '%timezone%',   '6.3c the word timezone never appears';

  -- 6.4 out-of-window timed masters change nothing, zone or no zone.
  update public.events
     set start_at = timestamptz '2030-09-02 01:00:00+00',
         end_at   = timestamptz '2030-09-02 02:00:00+00'
   where id = v_tz;
  v_res := public.get_free_busy(v_tok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true,
    '6.4 a timed master starting after the window is irrelevant';

  delete from public.events where id in (v_m, v_tz);
  delete from public.share_links where id = v_link;
  raise notice 'Section 6 OK';
end $$;

-- ============================================================================
-- SECTION 7 -- RLS and table privileges did not regress.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_other constant uuid := gen_random_uuid();
  v_id    constant uuid := gen_random_uuid();
  v_seen  bigint;
begin
  raise notice 'Section 7: RLS and GRANT non-regression';

  assert has_table_privilege('authenticated', 'public.events', 'select')
     and has_table_privilege('authenticated', 'public.events', 'insert')
     and has_table_privilege('authenticated', 'public.events', 'update')
     and has_table_privilege('authenticated', 'public.events', 'delete'),
    '7.1 authenticated keeps table-level DML (the new column is covered by it)';
  assert not has_table_privilege('anon', 'public.events', 'select'),
    '7.2 anon still has no direct table access';

  insert into public.events (id, owner_id, title, all_day, start_at, end_at, rrule, timezone)
  values (v_id, v_owner, 'secret', false,
          timestamptz '2026-09-01 01:00:00+00', timestamptz '2026-09-01 02:00:00+00',
          'FREQ=DAILY', 'Asia/Tokyo');

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_other::text, 'role', 'authenticated')::text,
                     true);
  perform set_config('role', 'authenticated', true);
  select count(*) into v_seen from public.events e where e.id = v_id;
  perform set_config('role', 'none', true);

  assert v_seen = 0, '7.3 another user sees neither the row nor its timezone';

  delete from public.events where id = v_id;
  raise notice 'Section 7 OK';
end $$;

-- ============================================================================
-- Leave no fixtures behind. This also restores the B-4 legacy row, which
-- Section 4 mutated and Section 6 deleted by id. Step E-2 checks that it came
-- back as M0 before step E-3 removes it for good.
-- ============================================================================
rollback;
