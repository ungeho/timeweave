-- TimeWeave Phase 5b-1 test suite for 0007_allday_recurrence_freebusy.sql.
--
-- NOT A MIGRATION. Run by hand (Supabase SQL editor or psql) against a
-- DEVELOPMENT project after applying 0007. Wrapped in a transaction that ends
-- with ROLLBACK, so it leaves no fixtures behind.
--
-- !! RUN THE WHOLE FILE, INCLUDING THE FINAL ROLLBACK. !!
--
-- A failing `assert` raises and aborts the transaction; every statement after it
-- reports "current transaction is aborted" until the final ROLLBACK. Read the
-- FIRST error message -- that is the real failure.
--
-- Section 3 needs a DEDICATED TEST USER that owns no events, exactly like the
-- 0006 suite. It never inserts into auth.users and never deletes or updates a
-- row it did not itself insert.
--
-- CASE NUMBERING: cases C1..C17 mirror src/services/allDayFreeBusy.test.ts one
-- for one, with the same fixtures and the same expected intervals, so the two
-- files can be reviewed side by side. Both implementations select occurrences
-- by OVERLAP with the window, so every case expects the same values on both
-- sides.
--
-- Preflight: assumes pgcrypto lives in the `extensions` schema (Supabase
-- default). If `select extnamespace::regnamespace from pg_extension where
-- extname='pgcrypto';` reports `public`, swap extensions.digest for public.digest.

begin;

-- ============================================================================
-- SECTION 1 -- rrule_allday_occurrence_count: closed-form candidate count.
--
-- Returns NULL (never 0) outside the all-day subset, so callers that write
-- coalesce(count, cap + 1) fail closed.
-- ============================================================================
do $$
declare
  F constant date := date '2026-09-01';
  T constant date := date '2026-09-08';
begin
  raise notice 'Section 1: rrule_allday_occurrence_count';

  -- Supported shapes return a number (an upper bound before exact filtering).
  assert public.rrule_allday_occurrence_count(
           'FREQ=DAILY', true, date '2026-08-01', date '2026-08-02', F, T) >= 7,
         '1.1 DAILY covers at least the 7 window days';
  assert public.rrule_allday_occurrence_count(
           'FREQ=WEEKLY;BYDAY=MO,WE,FR', true, date '2026-08-05', date '2026-08-06', F, T) >= 3,
         '1.2 WEEKLY with three BYDAY values counts three per active week';

  -- Outside the subset -> NULL, which callers turn into "over cap".
  assert public.rrule_allday_occurrence_count(
           'FREQ=MONTHLY', true, date '2026-08-01', date '2026-08-02', F, T) is null,
         '1.3 MONTHLY is not countable';
  assert public.rrule_allday_occurrence_count(
           'FREQ=DAILY;COUNT=5', true, date '2026-08-01', date '2026-08-02', F, T) is null,
         '1.4 COUNT is not countable';
  assert public.rrule_allday_occurrence_count(
           'FREQ=DAILY', false, null, null, F, T) is null,
         '1.5 timed rows are not countable';
  assert public.rrule_allday_occurrence_count(
           'FREQ=DAILY;UNTIL=20260903T000000Z', true, date '2026-08-01', date '2026-08-02', F, T) is null,
         '1.6 instant UNTIL on an all-day row is not countable';
  assert public.rrule_allday_occurrence_count(
           'FREQ=DAILY;NOPE=1', true, date '2026-08-01', date '2026-08-02', F, T) is null,
         '1.7 unknown key is not countable';
  assert public.rrule_allday_occurrence_count(
           null, true, date '2026-08-01', date '2026-08-02', F, T) is null,
         '1.8 NULL rrule is not countable (function must not be STRICT-skipped)';

  -- A series that starts AFTER the window must not produce a negative or
  -- inverted range. This is the case Postgres integer division would get wrong:
  -- truncation toward zero instead of floor would narrow the range and drop
  -- occurrences elsewhere, so the numeric/floor form is load bearing.
  assert public.rrule_allday_occurrence_count(
           'FREQ=DAILY', true, date '2027-01-01', date '2027-01-02', F, T) = 0,
         '1.9 a series starting after the window counts zero, never negative';

  -- UNTIL shrinks the range.
  assert public.rrule_allday_occurrence_count(
           'FREQ=DAILY;UNTIL=20260903', true, date '2026-08-01', date '2026-08-02', F, T)
         < public.rrule_allday_occurrence_count(
           'FREQ=DAILY', true, date '2026-08-01', date '2026-08-02', F, T),
         '1.10 UNTIL reduces the candidate count';

  raise notice 'Section 1 OK';
end $$;

-- ============================================================================
-- SECTION 2 -- rrule_allday_occurrence_starts: the expansion itself.
--
-- Case numbers match src/services/allDayFreeBusy.test.ts.
-- ============================================================================
do $$
declare
  F  constant date := date '2026-09-01';   -- Tuesday
  T  constant date := date '2026-09-08';   -- exclusive
  W  constant date := date '2026-08-05';   -- Wednesday; its Monday is 2026-08-03
  got date[];
begin
  raise notice 'Section 2: rrule_allday_occurrence_starts';

  ---------------------------------------------------------------------- DAILY
  select array_agg(d order by d) into got from public.rrule_allday_occurrence_starts(
    'FREQ=DAILY', true, date '2026-08-01', date '2026-08-02', F, T) as s(d);
  assert got = array[date '2026-09-01', date '2026-09-02', date '2026-09-03',
                     date '2026-09-04', date '2026-09-05', date '2026-09-06',
                     date '2026-09-07'],
         'C1 DAILY covers every window day';

  select array_agg(d order by d) into got from public.rrule_allday_occurrence_starts(
    'FREQ=DAILY;INTERVAL=3', true, date '2026-08-01', date '2026-08-02', F, T) as s(d);
  assert got = array[date '2026-09-03', date '2026-09-06'], 'C2 DAILY INTERVAL=3';

  -- UNTIL is inclusive on the occurrence START.
  select array_agg(d order by d) into got from public.rrule_allday_occurrence_starts(
    'FREQ=DAILY;UNTIL=20260903', true, date '2026-08-01', date '2026-08-02', F, T) as s(d);
  assert got = array[date '2026-09-01', date '2026-09-02', date '2026-09-03'],
         'C8 DATE UNTIL inclusive';

  select array_agg(d order by d) into got from public.rrule_allday_occurrence_starts(
    'FREQ=DAILY;UNTIL=20260901', true, date '2026-08-01', date '2026-08-02', F, T) as s(d);
  assert got = array[date '2026-09-01'], 'C8b an occurrence exactly ON the UNTIL date is kept';

  -- Multi-day duration, overlapping occurrences.
  select array_agg(d order by d) into got from public.rrule_allday_occurrence_starts(
    'FREQ=DAILY;INTERVAL=2', true, date '2026-09-01', date '2026-09-04', F, T) as s(d);
  assert got = array[date '2026-09-01', date '2026-09-03', date '2026-09-05', date '2026-09-07'],
         'C10 multi-day duration, every other day';

  -- C12: an occurrence may START before the window and still belong to it.
  -- The 2026-08-30 occurrence spans [08-30, 09-02) and overlaps the window, so
  -- it is emitted. Selecting by START instead of by OVERLAP would report free
  -- time where the owner is busy; services/occurrences.ts applies the same
  -- overlap test, so C12 expects the same values on both sides.
  select array_agg(d order by d) into got from public.rrule_allday_occurrence_starts(
    'FREQ=DAILY;INTERVAL=7', true, date '2026-08-30', date '2026-09-02', F, T) as s(d);
  assert got = array[date '2026-08-30', date '2026-09-06'],
         'C12 an occurrence starting BEFORE the window but overlapping it is emitted';

  --------------------------------------------------------------------- WEEKLY
  select array_agg(d order by d) into got from public.rrule_allday_occurrence_starts(
    'FREQ=WEEKLY;BYDAY=WE', true, W, date '2026-08-06', F, T) as s(d);
  assert got = array[date '2026-09-02'], 'C3 WEEKLY BYDAY=WE';

  select array_agg(d order by d) into got from public.rrule_allday_occurrence_starts(
    'FREQ=WEEKLY;BYDAY=MO,WE,FR', true, W, date '2026-08-06', F, T) as s(d);
  assert got = array[date '2026-09-02', date '2026-09-04', date '2026-09-07'],
         'C4 WEEKLY BYDAY=MO,WE,FR';

  -- Active weeks are counted from the Monday of the DTSTART week (WKST=MO):
  -- 08-03, 08-17, 08-31, 09-14 -> Wednesdays 08-05, 08-19, 09-02, 09-16.
  select array_agg(d order by d) into got from public.rrule_allday_occurrence_starts(
    'FREQ=WEEKLY;INTERVAL=2;BYDAY=WE', true, W, date '2026-08-06', F, date '2026-09-22') as s(d);
  assert got = array[date '2026-09-02', date '2026-09-16'], 'C5 WEEKLY INTERVAL=2 active weeks';

  select array_agg(d order by d) into got from public.rrule_allday_occurrence_starts(
    'FREQ=WEEKLY;BYDAY=WE', true, W, date '2026-08-06', F, date '2026-09-22') as s(d);
  assert got = array[date '2026-09-02', date '2026-09-09', date '2026-09-16'],
         'C5b the same rule with INTERVAL=1 fires every week';

  -- BYDAY omitted -> the weekday of DTSTART (Wednesday).
  select array_agg(d order by d) into got from public.rrule_allday_occurrence_starts(
    'FREQ=WEEKLY', true, W, date '2026-08-06', F, T) as s(d);
  assert got = array[date '2026-09-02'], 'C6 BYDAY omitted falls back to the DTSTART weekday';

  -- In the DTSTART week, BYDAY days before DTSTART are skipped: Monday 08-03 is
  -- not emitted, but the following Monday 08-10 is.
  select array_agg(d order by d) into got from public.rrule_allday_occurrence_starts(
    'FREQ=WEEKLY;BYDAY=MO,WE', true, W, date '2026-08-06',
    date '2026-08-03', date '2026-08-12') as s(d);
  assert got = array[date '2026-08-05', date '2026-08-10'],
         'C7 the DTSTART week skips BYDAY days before DTSTART';

  ------------------------------------------------------- nothing in the window
  select array_agg(d order by d) into got from public.rrule_allday_occurrence_starts(
    'FREQ=DAILY;UNTIL=20260131', true, date '2026-01-01', date '2026-01-02', F, T) as s(d);
  assert got is null, 'C17 a series that ended long ago emits nothing';

  raise notice 'Section 2 OK';
end $$;

-- ============================================================================
-- SECTION 2b -- preconditions RAISE rather than returning an empty set.
--
-- An empty set is indistinguishable from "no busy here", so a miswired caller
-- must fail loudly instead of silently producing free time.
-- ============================================================================
do $$
declare
  n int;
begin
  raise notice 'Section 2b: rrule_allday_occurrence_starts preconditions';

  -- N8: outside the SQL subset.
  begin
    select count(*) into n from public.rrule_allday_occurrence_starts(
      'FREQ=MONTHLY', true, date '2026-08-01', date '2026-08-02',
      date '2026-09-01', date '2026-09-08') as s(d);
    assert false, 'N8 a non-subset rule must RAISE, not return rows';
  exception when assert_failure then raise;
           when others then null;  -- expected
  end;

  begin
    select count(*) into n from public.rrule_allday_occurrence_starts(
      'FREQ=DAILY;COUNT=3', true, date '2026-08-01', date '2026-08-02',
      date '2026-09-01', date '2026-09-08') as s(d);
    assert false, 'N8b COUNT must RAISE';
  exception when assert_failure then raise;
           when others then null;
  end;

  begin
    select count(*) into n from public.rrule_allday_occurrence_starts(
      'FREQ=DAILY', false, null, null, date '2026-09-01', date '2026-09-08') as s(d);
    assert false, 'N8c a timed row must RAISE';
  exception when assert_failure then raise;
           when others then null;
  end;

  -- N9: NULL arguments must reach the body and RAISE, not be skipped by STRICT.
  begin
    select count(*) into n from public.rrule_allday_occurrence_starts(
      null, true, date '2026-08-01', date '2026-08-02',
      date '2026-09-01', date '2026-09-08') as s(d);
    assert false, 'N9 NULL rrule must RAISE (function must not be STRICT)';
  exception when assert_failure then raise;
           when others then null;
  end;

  -- N6a: over the runtime cap. A 30-year all-day event repeating daily produces
  -- far more than 5000 candidates for a 92-day window.
  begin
    select count(*) into n from public.rrule_allday_occurrence_starts(
      'FREQ=DAILY', true, date '1996-01-01', date '2026-01-01',
      date '2026-09-01', date '2026-11-01') as s(d);
    assert false, 'N6a exceeding the expansion cap must RAISE, not truncate';
  exception when assert_failure then raise;
           when others then null;
  end;

  -- The cap itself is a single named constant.
  assert public.rrule_allday_expansion_cap() = 5000, 'N6b cap value';

  raise notice 'Section 2b OK';
end $$;

-- ============================================================================
-- SECTION 3 -- get_free_busy integration.
--
-- ISOLATION: requires a DEDICATED TEST USER owning no events, for the reasons
-- documented in supabase/tests/0006_rrule_parser_test.sql. This suite refuses to
-- run otherwise and never clears anybody's calendar.
--
-- SETUP: create the user through the normal Supabase Auth path, then paste its
-- id below (select id, email from auth.users order by created_at).
-- ============================================================================
do $$
declare
  ------------------------------------------------------------------ SET THIS
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';  -- <<< EDIT per project
  --------------------------------------------------------------------------

  v_from  constant timestamptz := timestamptz '2026-09-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-09-08 00:00:00+00';
  v_fromd constant date        := date '2026-09-01';
  v_tod   constant date        := date '2026-09-08';

  v_run      constant text := gen_random_uuid()::text;
  v_tok_ok   constant text := 'tw5b1-test-active-'    || v_run;
  v_tok_priv constant text := 'tw5b1-test-noprivate-' || v_run;

  v_link_ok   constant uuid := gen_random_uuid();
  v_link_priv constant uuid := gen_random_uuid();

  v_m      constant uuid := gen_random_uuid();   -- master fixture
  v_x      constant uuid := gen_random_uuid();   -- exception fixture
  v_s      constant uuid := gen_random_uuid();   -- single-event fixture

  v_res    jsonb;
  v_exists boolean;
begin
  raise notice 'Section 3: get_free_busy';

  -- ------------------------------------------------------------ PRECONDITIONS
  assert v_owner <> '00000000-0000-0000-0000-000000000000'::uuid,
    '3.0.0 set v_owner to a dedicated test user id first';

  select exists(select 1 from auth.users u where u.id = v_owner) into v_exists;
  assert v_exists,
    '3.0.1 v_owner does not exist in auth.users. Create the test user through '
    'the normal Auth path; this suite never inserts into auth.users.';

  assert not exists (select 1 from public.events e where e.owner_id = v_owner),
    '3.0.2 test owner must have no pre-existing events. Point v_owner at a '
    'dedicated test user. Do NOT delete events to satisfy this assertion.';

  insert into public.share_links (id, owner_id, token_hash, label, include_private, expires_at, revoked_at)
  values
    (v_link_ok,   v_owner, encode(extensions.digest(v_tok_ok,  'sha256'),'hex'),
     'TW5B1-TEST active',    true,  null, null),
    (v_link_priv, v_owner, encode(extensions.digest(v_tok_priv,'sha256'),'hex'),
     'TW5B1-TEST noprivate', false, null, null);

  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert v_res = '{"complete": true, "slots": []}'::jsonb,
    '3.0.3 empty test owner baseline, got ' || v_res::text;

  -- =====================================================================
  -- 3.1 A supported all-day recurrence is now EXPANDED and complete.
  --     This is the assertion that 0006 test 4.1 held in the opposite
  --     direction; 5b-1 is exactly the step that flips it.
  -- =====================================================================
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date, rrule)
  values (v_m, v_owner, '', 'busy_only', true, date '2026-08-01', date '2026-08-02',
          'FREQ=DAILY;INTERVAL=3');

  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true, '3.1 supported all-day recurrence is complete';
  assert jsonb_array_length(v_res->'slots') = 2, '3.1 two occurrence slots (C2)';
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', true, 'start_date', to_jsonb(date '2026-09-03'),
           'end_date', to_jsonb(date '2026-09-04')), '3.1 first slot';
  assert v_res->'slots'->1 = jsonb_build_object(
           'all_day', true, 'start_date', to_jsonb(date '2026-09-06'),
           'end_date', to_jsonb(date '2026-09-07')), '3.1 second slot';

  -- C1: daily every day merges into a single span covering the window.
  update public.events set rrule = 'FREQ=DAILY' where id = v_m;
  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert jsonb_array_length(v_res->'slots') = 1, 'C1 merges into one span';
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', true, 'start_date', to_jsonb(date '2026-09-01'),
           'end_date', to_jsonb(date '2026-09-08')), 'C1 span covers the window';

  delete from public.events where id = v_m;

  -- =====================================================================
  -- 3.2 Exceptions no longer force incomplete, and detach works both ways.
  -- =====================================================================
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date, rrule)
  values (v_m, v_owner, '', 'busy_only', true, date '2026-08-01', date '2026-08-02',
          'FREQ=DAILY;INTERVAL=3');   -- 09-03, 09-06

  -- C13: slot moved OUT of the window -> that day becomes free.
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             recurrence_id, recurrence_slot_date, is_cancelled)
  values (v_x, v_owner, '', 'busy_only', true, date '2026-10-01', date '2026-10-02',
          v_m, date '2026-09-03', false);

  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true, 'C13 an exception no longer forces incomplete';
  assert jsonb_array_length(v_res->'slots') = 1, 'C13 only the 09-06 occurrence remains';
  assert v_res->'slots'->0->>'start_date' = '2026-09-06', 'C13 remaining slot';

  -- C14: a cancellation detaches and adds nothing.
  update public.events set is_cancelled = true, start_date = date '2026-09-03',
                           end_date = date '2026-09-04' where id = v_x;
  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true, 'C14 cancellations no longer force incomplete';
  assert jsonb_array_length(v_res->'slots') = 1, 'C14 cancelled slot contributes nothing';
  assert v_res->'slots'->0->>'start_date' = '2026-09-06', 'C14 remaining slot';

  -- C11: a moved exception detaches its slot and lands on its new date.
  update public.events set is_cancelled = false, start_date = date '2026-09-04',
                           end_date = date '2026-09-05' where id = v_x;
  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert jsonb_array_length(v_res->'slots') = 2, 'C11 moved snapshot plus the untouched slot';
  assert v_res->'slots'->0->>'start_date' = '2026-09-04', 'C11 moved snapshot first';
  assert v_res->'slots'->1->>'start_date' = '2026-09-06', 'C11 untouched occurrence second';

  delete from public.events where id = v_x;
  delete from public.events where id = v_m;

  -- =====================================================================
  -- 3.3 N10 / N12 / N12b -- multi-day parents and slots outside the window.
  -- =====================================================================
  -- N12b: supported multi-day parent, slot BEFORE the window whose occurrence
  -- reaches into it. Detaching must free 09-01 and leave only 09-06..09-08.
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date, rrule)
  values (v_m, v_owner, '', 'busy_only', true, date '2026-08-30', date '2026-09-02',
          'FREQ=DAILY;INTERVAL=7');   -- occurrences 08-30 (overlaps) and 09-06

  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert jsonb_array_length(v_res->'slots') = 2, 'C12 both occurrences before detach';
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', true, 'start_date', to_jsonb(date '2026-09-01'),
           'end_date', to_jsonb(date '2026-09-02')),
         'C12 the pre-window occurrence is clipped into the window (TS drops this; SQL must not)';
  assert v_res->'slots'->1->>'start_date' = '2026-09-06', 'C12 second occurrence';

  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             recurrence_id, recurrence_slot_date, is_cancelled)
  values (v_x, v_owner, '', 'busy_only', true, date '2026-11-01', date '2026-11-04',
          v_m, date '2026-08-30', false);

  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true, 'N12b supported parent stays complete';
  assert jsonb_array_length(v_res->'slots') = 1, 'N12b the pre-window slot is detached';
  assert v_res->'slots'->0->>'start_date' = '2026-09-06', 'N12b remaining occurrence';

  -- N12: same shape but the parent is private AND unsupported. The slot sits
  -- before the window, and its snapshot is outside the window, so only the
  -- PARENT-DURATION test in (C-2) can catch it.
  update public.events set visibility = 'private', rrule = 'FREQ=MONTHLY' where id = v_m;
  v_res := public.get_free_busy(v_tok_priv, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = false,
    'N12 a pre-window multi-day slot of an unsupported private parent forces incomplete';

  delete from public.events where id = v_x;
  delete from public.events where id = v_m;

  -- N10: supported parent, slot INSIDE the window, snapshot OUTSIDE it.
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date, rrule)
  values (v_m, v_owner, '', 'busy_only', true, date '2026-08-01', date '2026-08-02',
          'FREQ=DAILY;INTERVAL=3');
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             recurrence_id, recurrence_slot_date, is_cancelled)
  values (v_x, v_owner, '', 'busy_only', true, date '2026-12-01', date '2026-12-02',
          v_m, date '2026-09-03', false);

  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true, 'N10 supported parent stays complete';
  assert jsonb_array_length(v_res->'slots') = 1, 'N10 in-window slot detached, snapshot elsewhere';
  assert v_res->'slots'->0->>'start_date' = '2026-09-06', 'N10 remaining occurrence';

  -- N11: the same in-window slot / out-of-window snapshot, but the parent is
  -- private AND unsupported. Nothing is disclosed in the window, yet the series
  -- cannot be accounted for, so completeness must fail.
  update public.events set visibility = 'private', rrule = 'FREQ=MONTHLY' where id = v_m;
  v_res := public.get_free_busy(v_tok_priv, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = false,
    'N11 in-window slot of an unsupported private parent forces incomplete';
  assert v_res->'slots' = '[]'::jsonb, 'N11 nothing disclosable in the window';

  delete from public.events where id = v_x;
  delete from public.events where id = v_m;

  -- =====================================================================
  -- 3.4 N1 / N2 -- a visible exception under a private parent.
  -- =====================================================================
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date, rrule)
  values (v_m, v_owner, '', 'private', true, date '2026-08-01', date '2026-08-02', 'FREQ=MONTHLY');
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             recurrence_id, recurrence_slot_date, is_cancelled)
  values (v_x, v_owner, '', 'busy_only', true, date '2026-09-04', date '2026-09-05',
          v_m, date '2026-09-04', false);

  v_res := public.get_free_busy(v_tok_priv, v_from, v_to, v_fromd, v_tod);
  assert jsonb_array_length(v_res->'slots') = 1, 'N1 the visible exception is still disclosed';
  assert v_res->'slots'->0->>'start_date' = '2026-09-04', 'N1 exception snapshot';
  assert (v_res->>'complete')::boolean = false,
    'N1 an unsupported private parent forces incomplete even though it is hidden';

  -- N2: same, but the parent IS in the subset -> exception only, and complete.
  update public.events set rrule = 'FREQ=DAILY' where id = v_m;
  v_res := public.get_free_busy(v_tok_priv, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true, 'N2 a supported private parent is accountable';
  assert jsonb_array_length(v_res->'slots') = 1, 'N2 only the visible exception is disclosed';
  assert v_res->'slots'->0->>'start_date' = '2026-09-04', 'N2 exception snapshot';

  delete from public.events where id = v_x;
  delete from public.events where id = v_m;

  -- =====================================================================
  -- 3.5 Visibility matrix (cases 17-20), include_private = false.
  --     Detach is structural; visibility only gates the snapshot.
  -- =====================================================================
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date, rrule)
  values (v_m, v_owner, '', 'busy_only', true, date '2026-08-01', date '2026-08-02',
          'FREQ=DAILY;INTERVAL=3');   -- 09-03, 09-06

  -- 17: visible master + visible moved exception.
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             recurrence_id, recurrence_slot_date, is_cancelled)
  values (v_x, v_owner, '', 'busy_only', true, date '2026-09-05', date '2026-09-06',
          v_m, date '2026-09-03', false);
  v_res := public.get_free_busy(v_tok_priv, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true, '17 complete';
  assert jsonb_array_length(v_res->'slots') = 1, '17 moved snapshot is adjacent to 09-06 and merges';
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', true, 'start_date', to_jsonb(date '2026-09-05'),
           'end_date', to_jsonb(date '2026-09-07')), '17 merged span';

  -- 18: visible master + PRIVATE moved exception -> slot detached, snapshot
  -- withheld, so BOTH dates read free. Intended: the owner chose not to
  -- disclose that occurrence.
  update public.events set visibility = 'private' where id = v_x;
  v_res := public.get_free_busy(v_tok_priv, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true, '18 complete';
  assert jsonb_array_length(v_res->'slots') = 1, '18 only the untouched 09-06 occurrence';
  assert v_res->'slots'->0->>'start_date' = '2026-09-06', '18 detach happened despite private';

  -- 18b: visible master + PRIVATE cancellation -> detach, nothing added.
  update public.events set is_cancelled = true, start_date = date '2026-09-03',
                           end_date = date '2026-09-04' where id = v_x;
  v_res := public.get_free_busy(v_tok_priv, v_from, v_to, v_fromd, v_tod);
  assert jsonb_array_length(v_res->'slots') = 1, '18b private cancellation still detaches';
  assert v_res->'slots'->0->>'start_date' = '2026-09-06', '18b remaining occurrence';

  -- 20: private master + private exception -> nothing at all.
  update public.events set visibility = 'private' where id = v_m;
  v_res := public.get_free_busy(v_tok_priv, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true, '20 complete';
  assert v_res->'slots' = '[]'::jsonb, '20 nothing disclosed';

  -- 20b: the SAME fixture over an include_private = true link expands fully.
  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true, '20b complete';
  assert jsonb_array_length(v_res->'slots') = 1, '20b private cancellation detaches here too';
  assert v_res->'slots'->0->>'start_date' = '2026-09-06', '20b remaining occurrence';

  delete from public.events where id = v_x;
  delete from public.events where id = v_m;

  -- =====================================================================
  -- 3.6 N5 -- exception all_day disagrees with its master. Three shapes:
  --     N5  snapshot INSIDE the window
  --     N5b snapshot OUTSIDE, but the SLOT still touches the window
  --     N5c both outside -> the guard must NOT fire
  -- =====================================================================
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date, rrule)
  values (v_m, v_owner, '', 'busy_only', true, date '2026-08-01', date '2026-08-02', 'FREQ=DAILY');
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             recurrence_id, recurrence_slot_start, is_cancelled)
  values (v_x, v_owner, '', 'busy_only', false,
          timestamptz '2026-09-03 01:00:00+00', timestamptz '2026-09-03 02:00:00+00',
          v_m, timestamptz '2026-09-03 00:00:00+00', false);

  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = false,
    'N5 an exception whose all_day disagrees with its master forces incomplete';

  -- N5b: the SAME mismatch, but the snapshot is moved far past the window.
  -- The parent is a supported all-day DAILY master, so neither (A) nor (C)
  -- fires; only (B)'s slot test can catch it. The slot still sits inside the
  -- window, so the mismatch changes what this window should contain.
  update public.events
     set start_at = timestamptz '2026-10-05 01:00:00+00',
         end_at   = timestamptz '2026-10-05 02:00:00+00'
   where id = v_x;

  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = false,
    'N5b a mismatched exception whose SLOT touches the window forces incomplete even when its snapshot lies outside';

  -- N5c: move the slot out of the window too. Now the mismatch cannot affect
  -- this window at all, so the guard must stay quiet -- proof that N5b is
  -- caught by the slot test and not by an unconditional mismatch veto.
  update public.events
     set recurrence_slot_start = timestamptz '2026-10-05 00:00:00+00'
   where id = v_x;

  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true,
    'N5c a mismatched exception entirely outside the window does not force incomplete';
  assert jsonb_array_length(v_res->'slots') = 1,
    'N5c the supported all-day DAILY master still expands across the window';
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', true, 'start_date', to_jsonb(date '2026-09-01'),
           'end_date', to_jsonb(date '2026-09-08')), 'N5c merged full-window span';

  delete from public.events where id = v_x;
  delete from public.events where id = v_m;

  -- =====================================================================
  -- 3.7 N13 -- a disclosed TIMED exception is never silently dropped.
  --     5b-1 adds no timed exception busy, so its parent (necessarily timed)
  --     must force incomplete via branch (C).
  -- =====================================================================
  -- timezone is required since 0008: any NEW timed master is M1. Adding UTC does
  -- not change this test -- rrule_sql_subset rejects every timed rule whatever
  -- the zone, so the series stays unsupported here.
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at, rrule,
                             timezone)
  values (v_m, v_owner, '', 'private', false,
          timestamptz '2026-08-01 01:00:00+00', timestamptz '2026-08-01 02:00:00+00', 'FREQ=DAILY',
          'UTC');
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             recurrence_id, recurrence_slot_start, is_cancelled)
  values (v_x, v_owner, '', 'busy_only', false,
          timestamptz '2026-09-03 01:00:00+00', timestamptz '2026-09-03 02:00:00+00',
          v_m, timestamptz '2026-09-03 01:00:00+00', false);

  v_res := public.get_free_busy(v_tok_priv, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = false,
    'N13 a visible timed exception under a hidden timed parent forces incomplete';

  delete from public.events where id = v_x;
  delete from public.events where id = v_m;

  -- =====================================================================
  -- 3.8 Still fail-closed: COUNT, MONTHLY, timed, malformed.
  -- =====================================================================
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date, rrule)
  values (v_m, v_owner, '', 'busy_only', true, date '2026-08-01', date '2026-08-02',
          'FREQ=DAILY;COUNT=5');
  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = false, '3.8 COUNT still incomplete';
  assert v_res->'slots' = '[]'::jsonb, '3.8 COUNT contributes no slots';

  update public.events set rrule = 'FREQ=MONTHLY' where id = v_m;
  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = false, '3.8b MONTHLY still incomplete';

  update public.events set rrule = 'FREQ=DAILY;UNTIL=20260231' where id = v_m;
  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = false, '3.8c malformed still incomplete';

  update public.events set rrule = 'FREQ=DAILY;UNTIL=20260810' where id = v_m;
  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true, '3.8d a finished series stays complete (5b-0)';
  assert v_res->'slots' = '[]'::jsonb, '3.8d and contributes nothing';

  delete from public.events where id = v_m;

  -- timed recurrence. Since 0008 a new timed master must carry a timezone (M1);
  -- UTC does not affect the assertion below, which is about the rule not being
  -- in the SQL subset.
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at, rrule,
                             timezone)
  values (
    v_m,
    v_owner,
    '',
    'busy_only',
    false,
    timestamptz '2026-08-01 01:00:00+00',
    timestamptz '2026-08-01 02:00:00+00',
    'FREQ=DAILY',
    'UTC'
  );
  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = false, '3.8e timed recurrence still incomplete';
  assert v_res->'slots' = '[]'::jsonb, '3.8e timed recurrence contributes no slots';
  delete from public.events where id = v_m;

  -- =====================================================================
  -- 3.9 N6 / N7 -- the runtime cap is window dependent, never truncating.
  -- =====================================================================
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date, rrule)
  values (v_m, v_owner, '', 'busy_only', true, date '1996-01-01', date '2026-01-01', 'FREQ=DAILY');

  assert public.rrule_sql_subset('FREQ=DAILY', true),
    'N6 the grammar is supported; only the runtime expansion is too large';
  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = false, 'N6 over-cap expansion forces incomplete';
  assert v_res->'slots' = '[]'::jsonb, 'N6 nothing is truncated into the result';

  -- N7 is covered by rrule_allday_occurrence_count in section 1: the same rule
  -- with a shorter window yields fewer candidates. Here we simply record that
  -- the cap is not a property of the rule alone.
  assert public.rrule_allday_occurrence_count(
           'FREQ=DAILY', true, date '1996-01-01', date '2026-01-01', v_fromd, v_tod)
         > public.rrule_allday_expansion_cap(),
    'N7 the same rule is over cap for this window';

  delete from public.events where id = v_m;

  -- =====================================================================
  -- 3.10 C15 / C16 -- merging with single events, and timed staying separate.
  -- =====================================================================
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date, rrule)
  values (v_m, v_owner, '', 'busy_only', true, date '2026-08-01', date '2026-08-02',
          'FREQ=DAILY;INTERVAL=3');                       -- 09-03, 09-06
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date)
  values (v_s, v_owner, '', 'busy_only', true, date '2026-09-04', date '2026-09-06');

  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert jsonb_array_length(v_res->'slots') = 1, 'C15 adjacent ranges merge into one span';
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', true, 'start_date', to_jsonb(date '2026-09-03'),
           'end_date', to_jsonb(date '2026-09-07')), 'C15 merged span';

  delete from public.events where id = v_s;

  insert into public.events (id, owner_id, title, description, category, visibility,
                             all_day, start_at, end_at)
  values (v_s, v_owner, 'TW5B1-SECRET-TITLE', 'secret desc', 'secret cat', 'busy_only', false,
          timestamptz '2026-09-02 01:00:00+00', timestamptz '2026-09-02 02:00:00+00');

  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert jsonb_array_length(v_res->'slots') = 3, 'C16 two all-day slots plus one timed slot';
  assert (v_res->'slots'->0->>'all_day')::boolean = true,  'C16 all-day sorts first';
  assert (v_res->'slots'->1->>'all_day')::boolean = true,  'C16 all-day sorts first';
  assert (v_res->'slots'->2->>'all_day')::boolean = false, 'C16 timed sorts last';
  assert v_res::text not like '%TW5B1-SECRET-TITLE%', 'C16 no title leaks';
  assert v_res::text not like '%secret%',             'C16 no description/category leaks';

  delete from public.events where id = v_s;
  delete from public.events where id = v_m;

  -- =====================================================================
  -- 3.11 Regressions from 0005/0006 that must not move.
  -- =====================================================================
  v_res := public.get_free_busy('tw5b1-no-such-token-' || v_run, v_from, v_to, v_fromd, v_tod);
  assert v_res = '{"complete": true, "slots": []}'::jsonb, '3.11 invalid token';

  begin
    perform public.get_free_busy(v_tok_ok, v_from, v_from + interval '93 days',
                                 v_fromd, v_fromd + 93);
    assert false, '3.11b 93-day window should have raised';
  exception when assert_failure then raise;
           when others then null;
  end;

  -- ------------------------------------------------------------- CLEANUP
  delete from public.share_links where id in (v_link_ok, v_link_priv);

  assert not exists (select 1 from public.events e where e.owner_id = v_owner),
    '3.12 fixtures leaked: test owner should be back to zero events';

  raise notice 'Section 3 OK';
end $$;

-- ============================================================================
-- Leave no fixtures behind.
-- ============================================================================
rollback;
