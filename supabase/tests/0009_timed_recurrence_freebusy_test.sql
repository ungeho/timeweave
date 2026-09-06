-- TimeWeave Phase 5b-3 test suite for 0009_timed_recurrence_freebusy.sql.
--
-- NOT A MIGRATION. Run by hand (Supabase SQL editor or psql) against a
-- DEVELOPMENT project AFTER applying 0009. Wrapped in a transaction that ends
-- with ROLLBACK, so it leaves no fixtures behind.
--
-- !! RUN THE WHOLE FILE, INCLUDING THE FINAL ROLLBACK. !!
--
-- A failing `assert` raises and aborts the transaction; every statement after it
-- reports "current transaction is aborted" until the final ROLLBACK. Read the
-- FIRST error message -- that is the real failure.
--
-- Sections 6 and 7 need a DEDICATED TEST USER that owns no events, exactly like
-- the 0006 and 0007 suites. It never inserts into auth.users and never deletes
-- or updates a row it did not itself insert.
--
-- TRIGGER HANDLING (sections 6.9 and 6.10): two fixtures cannot be created
-- through the normal path, because 0008 forbids them -- a genuine M0 (timed
-- master, timezone IS NULL) and a master whose zone this server cannot resolve.
-- Each is built by disabling events_validate_timezone for the length of ONE
-- insert and re-enabling it on the very next statement, inside this
-- transaction. ALTER TABLE ... DISABLE TRIGGER is transactional, so the final
-- ROLLBACK restores the trigger even if an assertion aborts the run midway.
-- Section 6 asserts the trigger is back to tgenabled='O' after each window.
--
-- DST EXPECTATIONS: every instant below was derived from the semantics the 0009
-- preflight pins:
--   America/New_York EST = UTC-5, EDT = UTC-4;
--   spring transition 2026-03-08 07:00Z, autumn transition 2026-11-01 06:00Z;
--   a gap local time resolves with the standard offset and lands one hour
--   later; an ambiguous local time resolves to the LATER instant.
-- If the preflight passes and these fail, the bug is in 0009, not in tzdata.
--
-- Preflight: assumes pgcrypto lives in the `extensions` schema (Supabase
-- default), as 0005-0008 do.

begin;

-- ============================================================================
-- SECTION 1 -- rrule_timed_sql_subset: the GRAMMAR gate. Knows nothing about
-- time zones; those are section 2.
-- ============================================================================
do $$
begin
  raise notice 'Section 1: rrule_timed_sql_subset';

  assert public.rrule_timed_sql_subset('FREQ=DAILY', false), '1.1 DAILY';
  assert public.rrule_timed_sql_subset('FREQ=WEEKLY;BYDAY=MO,WE', false), '1.2 WEEKLY BYDAY';
  assert public.rrule_timed_sql_subset('FREQ=DAILY;INTERVAL=3', false), '1.3 INTERVAL';
  assert public.rrule_timed_sql_subset('FREQ=DAILY;UNTIL=20261101T060000Z', false),
    '1.4 UNTIL in INSTANT form';

  assert not public.rrule_timed_sql_subset('FREQ=MONTHLY', false), '1.5 MONTHLY is out';
  assert not public.rrule_timed_sql_subset('FREQ=DAILY;COUNT=5', false), '1.6 COUNT is out';
  assert not public.rrule_timed_sql_subset('FREQ=DAILY;UNTIL=20261101', false),
    '1.7 a DATE-form UNTIL on a timed row is out';
  assert not public.rrule_timed_sql_subset('FREQ=DAILY', true),
    '1.8 all-day rows go through rrule_sql_subset, not this one';
  assert not public.rrule_timed_sql_subset('FREQ=DAILY', null), '1.9 NULL all_day is out';
  assert not public.rrule_timed_sql_subset('FREQ=YEARLY', false), '1.10 unsupported FREQ';
  assert not public.rrule_timed_sql_subset('not an rrule', false), '1.11 malformed';
  assert not public.rrule_timed_sql_subset(null, false), '1.12 NULL rrule';

  -- The 0007 all-day gate must be unaffected by 0009.
  assert public.rrule_sql_subset('FREQ=DAILY', true), '1.13 all-day subset still true';
  assert not public.rrule_sql_subset('FREQ=DAILY', false), '1.14 all-day subset still rejects timed';

  raise notice 'Section 1 OK';
end $$;

-- ============================================================================
-- SECTION 2 -- timezone_is_resolvable: storage policy (0008) plus a live probe.
-- Nothing in 0009 may reach AT TIME ZONE without passing this.
-- ============================================================================
do $$
begin
  raise notice 'Section 2: timezone_is_resolvable';

  assert public.timezone_is_resolvable('America/New_York'), '2.1 New York';
  assert public.timezone_is_resolvable('Asia/Tokyo'),        '2.2 Tokyo';
  assert public.timezone_is_resolvable('Etc/GMT-9'),         '2.3 Etc/GMT-9';
  assert public.timezone_is_resolvable('UTC'),               '2.4 UTC';

  assert not public.timezone_is_resolvable(null),               '2.5 NULL';
  assert not public.timezone_is_resolvable('JST'),              '2.6 abbreviation';
  assert not public.timezone_is_resolvable('posix/Asia/Tokyo'), '2.7 posix/ spelling';
  assert not public.timezone_is_resolvable('Nowhere/Nothing'),  '2.8 nonexistent zone';
  assert not public.timezone_is_resolvable(''),                 '2.9 empty string';

  -- It must never be laxer than the storage policy it wraps.
  assert not public.timezone_is_resolvable('asia/tokyo'),
    '2.10 case-sensitive, exactly like timezone_is_supported';

  -- 0008 is untouched by 0009.
  assert public.timezone_is_supported('Asia/Tokyo'), '2.11 timezone_is_supported unchanged';
  assert not public.timezone_is_supported('JST'),    '2.12 timezone_is_supported unchanged';

  raise notice 'Section 2 OK';
end $$;

-- ============================================================================
-- SECTION 3 -- rrule_timed_occurrence_count: an UPPER BOUND on candidates, and
-- the cap it feeds. NULL means "cannot count", which callers must read as "over
-- cap", never as zero.
-- ============================================================================
do $$
declare
  v_ny   constant text := 'America/New_York';
  v_from constant timestamptz := timestamptz '2026-03-06 00:00:00+00';
  v_to   constant timestamptz := timestamptz '2026-03-11 00:00:00+00';
  v_s    constant timestamptz := timestamptz '2026-03-06 14:00:00+00';  -- 09:00 EST
  v_e    constant timestamptz := timestamptz '2026-03-06 15:00:00+00';
  v_n    bigint;
  v_real bigint;

  -- EXACT CAP BOUNDARY. The closed form is window-relative, so an ordinary
  -- daily series can never exceed the cap however old it is: lo tracks the
  -- window and the count stays ~9. The only shape whose count is NOT bounded by
  -- the window is a very long event repeating daily -- a duration of 5000 days
  -- pins lo at 0, and then the count is hi + 1, chosen by DTSTART alone.
  --   to_local = (p_to at America/New_York)::date + 1 = 2026-03-11
  --   count = (to_local - dtstart_local_date) + 1
  -- so DTSTART 4999 days before to_local gives exactly 5000, and 5000 days
  -- before gives 5001. Off by one in either direction moves these numbers.
  v_dur  constant interval    := make_interval(secs => 5000 * 86400);
  v_s50  constant timestamptz := ((date '2026-03-11' - 4999) + time '09:00:00')
                                   at time zone 'America/New_York';
  v_s51  constant timestamptz := ((date '2026-03-11' - 5000) + time '09:00:00')
                                   at time zone 'America/New_York';
begin
  raise notice 'Section 3: rrule_timed_occurrence_count and the cap';

  assert public.rrule_timed_expansion_cap() = 5000, '3.1 timed cap is 5000';
  assert public.rrule_allday_expansion_cap() = 5000, '3.2 all-day cap unchanged';

  -- The bound must never be lower than the number actually generated.
  v_n := public.rrule_timed_occurrence_count('FREQ=DAILY', false, v_s, v_e, v_ny, v_from, v_to);
  select count(*) into v_real
  from public.rrule_timed_occurrence_starts('FREQ=DAILY', false, v_s, v_e, v_ny, v_from, v_to);
  assert v_n is not null, '3.3 DAILY is countable';
  assert v_n >= v_real, format('3.3 bound %s must be >= generated %s', v_n, v_real);
  assert v_real = 5, format('3.4 five daily occurrences in the window, got %s', v_real);

  v_n := public.rrule_timed_occurrence_count('FREQ=WEEKLY;BYDAY=FR,SU', false, v_s, v_e, v_ny, v_from, v_to);
  select count(*) into v_real
  from public.rrule_timed_occurrence_starts('FREQ=WEEKLY;BYDAY=FR,SU', false, v_s, v_e, v_ny, v_from, v_to);
  assert v_n >= v_real, format('3.5 weekly bound %s >= generated %s', v_n, v_real);

  -- NULL cases: every one of these must be read as "over cap" by the caller.
  assert public.rrule_timed_occurrence_count('FREQ=MONTHLY', false, v_s, v_e, v_ny, v_from, v_to) is null,
    '3.6 MONTHLY is not countable';
  assert public.rrule_timed_occurrence_count('FREQ=DAILY;COUNT=5', false, v_s, v_e, v_ny, v_from, v_to) is null,
    '3.7 COUNT is not countable';
  assert public.rrule_timed_occurrence_count('FREQ=DAILY;UNTIL=20260308', false, v_s, v_e, v_ny, v_from, v_to) is null,
    '3.8 a DATE-form UNTIL on a timed row is not countable';
  assert public.rrule_timed_occurrence_count('FREQ=DAILY', true, v_s, v_e, v_ny, v_from, v_to) is null,
    '3.9 all-day rows are not this helper business';
  assert public.rrule_timed_occurrence_count('FREQ=DAILY', false, v_s, v_e, null, v_from, v_to) is null,
    '3.10 NULL timezone (M0) is not countable';
  assert public.rrule_timed_occurrence_count('FREQ=DAILY', false, v_s, v_e, 'Nowhere/Nothing', v_from, v_to) is null,
    '3.11 an unresolvable timezone is not countable';
  assert public.rrule_timed_occurrence_count('FREQ=DAILY', false, null, v_e, v_ny, v_from, v_to) is null,
    '3.12 NULL start is not countable';

  -- 3.13 An ordinary long-running daily series is NOT over the cap: the index
  --      range is derived from the window, not from how old the series is.
  v_n := public.rrule_timed_occurrence_count(
           'FREQ=DAILY', false,
           timestamptz '2000-01-01 14:00:00+00', timestamptz '2000-01-01 15:00:00+00',
           v_ny, v_from, v_to);
  assert v_n <= public.rrule_timed_expansion_cap(),
    format('3.13 a 26-year daily series is still window-bounded, got %s', v_n);

  -- 3.14 EXACTLY at the cap. This must remain expandable: the rule is
  --      count <= cap, and an off-by-one here would silently drop a series.
  v_n := public.rrule_timed_occurrence_count(
           'FREQ=DAILY', false, v_s50, v_s50 + v_dur, v_ny, v_from, v_to);
  assert v_n = 5000, format('3.14 expected exactly 5000 candidates, got %s', v_n);
  assert v_n <= public.rrule_timed_expansion_cap(), '3.14 5000 is within the cap';

  select count(*) into v_real
  from public.rrule_timed_occurrence_starts(
    'FREQ=DAILY', false, v_s50, v_s50 + v_dur, v_ny, v_from, v_to);
  assert v_real > 0, '3.14 a series exactly at the cap still expands';
  assert v_real <= v_n, format('3.14 generated %s must not exceed the bound %s', v_real, v_n);

  -- 3.15 ONE over the cap. Nothing here raises: counting is always safe.
  v_n := public.rrule_timed_occurrence_count(
           'FREQ=DAILY', false, v_s51, v_s51 + v_dur, v_ny, v_from, v_to);
  assert v_n = 5001, format('3.15 expected exactly 5001 candidates, got %s', v_n);
  assert v_n > public.rrule_timed_expansion_cap(), '3.15 5001 is over the cap';

  raise notice 'Section 3 OK';
end $$;

-- ============================================================================
-- SECTION 4 -- rrule_timed_occurrence_starts: the instants themselves.
--
-- This is where the DST semantics live. Every expected value is an absolute
-- instant, so nothing here depends on the session TimeZone.
-- ============================================================================
do $$
declare
  v_ny  constant text := 'America/New_York';
  v_got timestamptz[];
begin
  raise notice 'Section 4: rrule_timed_occurrence_starts';

  -- 4.1 DAILY across the SPRING transition. 09:00 local: 14:00Z while EST,
  --     13:00Z once EDT starts on 03-08.
  select array_agg(t order by t) into v_got
  from public.rrule_timed_occurrence_starts(
    'FREQ=DAILY', false,
    timestamptz '2026-03-06 14:00:00+00', timestamptz '2026-03-06 15:00:00+00',
    v_ny, timestamptz '2026-03-06 00:00:00+00', timestamptz '2026-03-11 00:00:00+00') as s(t);
  assert v_got = array[
    timestamptz '2026-03-06 14:00:00+00',
    timestamptz '2026-03-07 14:00:00+00',
    timestamptz '2026-03-08 13:00:00+00',
    timestamptz '2026-03-09 13:00:00+00',
    timestamptz '2026-03-10 13:00:00+00'], '4.1 DAILY 09:00 across spring forward';

  -- 4.2 DAILY across the AUTUMN transition. 13:00Z while EDT, 14:00Z once EST
  --     resumes on 11-01.
  select array_agg(t order by t) into v_got
  from public.rrule_timed_occurrence_starts(
    'FREQ=DAILY', false,
    timestamptz '2026-10-30 13:00:00+00', timestamptz '2026-10-30 14:00:00+00',
    v_ny, timestamptz '2026-10-30 00:00:00+00', timestamptz '2026-11-04 00:00:00+00') as s(t);
  assert v_got = array[
    timestamptz '2026-10-30 13:00:00+00',
    timestamptz '2026-10-31 13:00:00+00',
    timestamptz '2026-11-01 14:00:00+00',
    timestamptz '2026-11-02 14:00:00+00',
    timestamptz '2026-11-03 14:00:00+00'], '4.2 DAILY 09:00 across fall back';

  -- 4.3 THE GAP. 02:30 does not exist on 03-08; it resolves with the standard
  --     offset and lands at 07:30Z, the same instant as 03:30 EDT.
  select array_agg(t order by t) into v_got
  from public.rrule_timed_occurrence_starts(
    'FREQ=DAILY', false,
    timestamptz '2026-03-07 07:30:00+00', timestamptz '2026-03-07 08:30:00+00',
    v_ny, timestamptz '2026-03-06 00:00:00+00', timestamptz '2026-03-11 00:00:00+00') as s(t);
  assert v_got = array[
    timestamptz '2026-03-07 07:30:00+00',
    timestamptz '2026-03-08 07:30:00+00',
    timestamptz '2026-03-09 06:30:00+00',
    timestamptz '2026-03-10 06:30:00+00'], '4.3 DAILY 02:30 through the spring gap';

  -- 4.4 THE FOLD, with DTSTART on the EARLY side (01:30 EDT = 05:30Z).
  --     THIS IS THE DTSTART SPECIAL CASE: reconstructing DTSTART from its wall
  --     clock would yield 06:30Z and move the stored occurrence by an hour.
  --     The first element must be the STORED instant.
  select array_agg(t order by t) into v_got
  from public.rrule_timed_occurrence_starts(
    'FREQ=DAILY', false,
    timestamptz '2026-11-01 05:30:00+00', timestamptz '2026-11-01 06:30:00+00',
    v_ny, timestamptz '2026-11-01 00:00:00+00', timestamptz '2026-11-04 00:00:00+00') as s(t);
  assert v_got[1] = timestamptz '2026-11-01 05:30:00+00',
    format('4.4 early-fold DTSTART must survive verbatim, got %s', v_got[1]);
  assert v_got = array[
    timestamptz '2026-11-01 05:30:00+00',
    timestamptz '2026-11-02 06:30:00+00',
    timestamptz '2026-11-03 06:30:00+00'], '4.4 later occurrences use the standard offset';

  -- 4.5 THE FOLD, with DTSTART on the LATE side (01:30 EST = 06:30Z). Here the
  --     stored instant and the reconstruction agree; the result must not shift.
  select array_agg(t order by t) into v_got
  from public.rrule_timed_occurrence_starts(
    'FREQ=DAILY', false,
    timestamptz '2026-11-01 06:30:00+00', timestamptz '2026-11-01 07:30:00+00',
    v_ny, timestamptz '2026-11-01 00:00:00+00', timestamptz '2026-11-04 00:00:00+00') as s(t);
  assert v_got = array[
    timestamptz '2026-11-01 06:30:00+00',
    timestamptz '2026-11-02 06:30:00+00',
    timestamptz '2026-11-03 06:30:00+00'], '4.5 late-fold DTSTART';

  -- 4.6 WEEKLY with BYDAY, across the spring transition. DTSTART is Friday
  --     2026-03-06 09:00 EST; Sunday 03-08 09:00 is already EDT.
  select array_agg(t order by t) into v_got
  from public.rrule_timed_occurrence_starts(
    'FREQ=WEEKLY;BYDAY=FR,SU', false,
    timestamptz '2026-03-06 14:00:00+00', timestamptz '2026-03-06 15:00:00+00',
    v_ny, timestamptz '2026-03-06 00:00:00+00', timestamptz '2026-03-11 00:00:00+00') as s(t);
  assert v_got = array[
    timestamptz '2026-03-06 14:00:00+00',
    timestamptz '2026-03-08 13:00:00+00'], '4.6 WEEKLY BYDAY across spring forward';

  -- 4.7 WEEKLY without BYDAY repeats DTSTART weekday only.
  select array_agg(t order by t) into v_got
  from public.rrule_timed_occurrence_starts(
    'FREQ=WEEKLY', false,
    timestamptz '2026-03-06 14:00:00+00', timestamptz '2026-03-06 15:00:00+00',
    v_ny, timestamptz '2026-03-06 00:00:00+00', timestamptz '2026-03-20 00:00:00+00') as s(t);
  assert v_got = array[
    timestamptz '2026-03-06 14:00:00+00',
    timestamptz '2026-03-13 13:00:00+00'], '4.7 WEEKLY without BYDAY';

  raise notice 'Section 4 OK';
end $$;

-- ============================================================================
-- SECTION 5 -- UNTIL, fixed-offset controls, absolute duration, and the two
-- classes of refusal (RAISE for caller wiring, no rows for data drift).
-- ============================================================================
do $$
declare
  v_ny    constant text := 'America/New_York';
  v_tk    constant text := 'Asia/Tokyo';
  v_g9    constant text := 'Etc/GMT-9';
  v_from  constant timestamptz := timestamptz '2026-03-06 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-03-11 00:00:00+00';
  v_s     constant timestamptz := timestamptz '2026-03-06 14:00:00+00';
  v_e     constant timestamptz := timestamptz '2026-03-06 15:00:00+00';
  v_got   timestamptz[];
  v_n     bigint;
  v_raised boolean;
  -- One past the cap; see section 3 for how these numbers are derived.
  v_dur   constant interval    := make_interval(secs => 5000 * 86400);
  v_s51   constant timestamptz := ((date '2026-03-11' - 5000) + time '09:00:00')
                                    at time zone 'America/New_York';
begin
  raise notice 'Section 5: UNTIL, controls, duration, refusals';

  -- 5.1 UNTIL is INCLUSIVE and caps the occurrence START. 20260308T130000Z is
  --     exactly the third occurrence, so it must be kept.
  select array_agg(t order by t) into v_got
  from public.rrule_timed_occurrence_starts(
    'FREQ=DAILY;UNTIL=20260308T130000Z', false, v_s, v_e, v_ny, v_from, v_to) as s(t);
  assert v_got = array[
    timestamptz '2026-03-06 14:00:00+00',
    timestamptz '2026-03-07 14:00:00+00',
    timestamptz '2026-03-08 13:00:00+00'], '5.1 UNTIL includes the occurrence it names';

  -- 5.2 One second earlier and that occurrence is gone.
  select array_agg(t order by t) into v_got
  from public.rrule_timed_occurrence_starts(
    'FREQ=DAILY;UNTIL=20260308T125959Z', false, v_s, v_e, v_ny, v_from, v_to) as s(t);
  assert v_got = array[
    timestamptz '2026-03-06 14:00:00+00',
    timestamptz '2026-03-07 14:00:00+00'], '5.2 UNTIL one second before excludes it';

  -- 5.3 Asia/Tokyo has no DST: the instant never moves.
  select array_agg(t order by t) into v_got
  from public.rrule_timed_occurrence_starts(
    'FREQ=DAILY', false,
    timestamptz '2026-03-06 00:00:00+00', timestamptz '2026-03-06 01:00:00+00',
    v_tk, timestamptz '2026-03-06 00:00:00+00', timestamptz '2026-03-10 00:00:00+00') as s(t);
  assert v_got = array[
    timestamptz '2026-03-06 00:00:00+00',
    timestamptz '2026-03-07 00:00:00+00',
    timestamptz '2026-03-08 00:00:00+00',
    timestamptz '2026-03-09 00:00:00+00'], '5.3 Asia/Tokyo control is constant';

  -- 5.4 Etc/GMT-9 is UTC+9 too, and is NOT canonicalised into Asia/Tokyo: same
  --     instants, different stored string.
  select array_agg(t order by t) into v_got
  from public.rrule_timed_occurrence_starts(
    'FREQ=DAILY', false,
    timestamptz '2026-03-06 00:00:00+00', timestamptz '2026-03-06 01:00:00+00',
    v_g9, timestamptz '2026-03-06 00:00:00+00', timestamptz '2026-03-10 00:00:00+00') as s(t);
  assert v_got = array[
    timestamptz '2026-03-06 00:00:00+00',
    timestamptz '2026-03-07 00:00:00+00',
    timestamptz '2026-03-08 00:00:00+00',
    timestamptz '2026-03-09 00:00:00+00'], '5.4 Etc/GMT-9 control is constant';

  -- 5.5 A 24-hour master crossing the spring transition. This helper returns
  --     STARTS only, so it can pin where the occurrence begins; whether its END
  --     is start + 86400 seconds (absolute) rather than "the same wall clock the
  --     next day" (calendar) is a property of the slot get_free_busy builds, and
  --     is asserted end to end in section 6.13.
  select array_agg(t order by t) into v_got
  from public.rrule_timed_occurrence_starts(
    'FREQ=DAILY;UNTIL=20260307T140000Z', false,
    timestamptz '2026-03-07 14:00:00+00', timestamptz '2026-03-08 14:00:00+00',
    v_ny, v_from, v_to) as s(t);
  assert v_got = array[timestamptz '2026-03-07 14:00:00+00'], '5.5 the 24h occurrence starts';

  -- 5.6 CLASS 1 -- caller wiring fails LOUDLY.
  v_raised := false;
  begin
    perform public.rrule_timed_occurrence_starts('FREQ=MONTHLY', false, v_s, v_e, v_ny, v_from, v_to);
  exception when assert_failure then raise;
            when others then v_raised := true;
  end;
  assert v_raised, '5.6 MONTHLY must raise (outside the subset)';

  v_raised := false;
  begin
    perform public.rrule_timed_occurrence_starts('FREQ=DAILY;COUNT=5', false, v_s, v_e, v_ny, v_from, v_to);
  exception when assert_failure then raise;
            when others then v_raised := true;
  end;
  assert v_raised, '5.7 COUNT must raise';

  v_raised := false;
  begin
    perform public.rrule_timed_occurrence_starts('FREQ=DAILY;UNTIL=20260308', false, v_s, v_e, v_ny, v_from, v_to);
  exception when assert_failure then raise;
            when others then v_raised := true;
  end;
  assert v_raised, '5.8 a DATE-form UNTIL on a timed row must raise';

  v_raised := false;
  begin
    perform public.rrule_timed_occurrence_starts('FREQ=DAILY', true, v_s, v_e, v_ny, v_from, v_to);
  exception when assert_failure then raise;
            when others then v_raised := true;
  end;
  assert v_raised, '5.9 an all-day row must raise';

  -- 5.10 Over the cap raises. The fixture is the 5001-candidate one from
  --      section 3: an ordinary old series is window-bounded and would NOT
  --      exceed the cap, so it could not test this.
  v_raised := false;
  begin
    perform public.rrule_timed_occurrence_starts(
      'FREQ=DAILY', false, v_s51, v_s51 + v_dur, v_ny, v_from, v_to);
  exception when assert_failure then raise;
            when others then v_raised := true;
  end;
  assert v_raised, '5.10 exceeding the cap must raise';

  -- 5.10b ...and exactly AT the cap does not.
  v_raised := false;
  begin
    perform public.rrule_timed_occurrence_starts(
      'FREQ=DAILY', false,
      ((date '2026-03-11' - 4999) + time '09:00:00') at time zone v_ny,
      (((date '2026-03-11' - 4999) + time '09:00:00') at time zone v_ny) + v_dur,
      v_ny, v_from, v_to);
  exception when assert_failure then raise;
            when others then v_raised := true;
  end;
  assert not v_raised, '5.10b a series exactly at the cap must still expand';

  -- 5.11 CLASS 2 -- data drift returns NO ROWS and never raises, paired with a
  --      NULL count. This pairing is what makes an empty result unambiguous.
  select count(*) into v_n
  from public.rrule_timed_occurrence_starts('FREQ=DAILY', false, v_s, v_e, null, v_from, v_to);
  assert v_n = 0, '5.11 a NULL zone (M0) yields no rows';
  assert public.rrule_timed_occurrence_count('FREQ=DAILY', false, v_s, v_e, null, v_from, v_to) is null,
    '5.11 and a NULL count';

  select count(*) into v_n
  from public.rrule_timed_occurrence_starts('FREQ=DAILY', false, v_s, v_e, 'Nowhere/Nothing', v_from, v_to);
  assert v_n = 0, '5.12 an unresolvable zone yields no rows';
  assert public.rrule_timed_occurrence_count('FREQ=DAILY', false, v_s, v_e, 'Nowhere/Nothing', v_from, v_to) is null,
    '5.12 and a NULL count';

  select count(*) into v_n
  from public.rrule_timed_occurrence_starts('FREQ=DAILY', false, v_s, v_e, 'JST', v_from, v_to);
  assert v_n = 0, '5.13 an abbreviation yields no rows';
  assert public.rrule_timed_occurrence_count('FREQ=DAILY', false, v_s, v_e, 'JST', v_from, v_to) is null,
    '5.13 and a NULL count';

  raise notice 'Section 5 OK';
end $$;

-- ============================================================================
-- SECTION 6 -- get_free_busy end to end.
--
-- SETUP: create the test user through the normal Supabase Auth path, then paste
-- its id below (select id, email from auth.users order by created_at).
-- ============================================================================
do $$
declare
  ------------------------------------------------------------------ SET THIS
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';  -- <<< EDIT per project
  --------------------------------------------------------------------------
  v_ny constant text := 'America/New_York';

  -- Spring window: 2026-03-06 .. 2026-03-11, containing the 07:00Z transition.
  v_sf  constant timestamptz := timestamptz '2026-03-06 00:00:00+00';
  v_st  constant timestamptz := timestamptz '2026-03-11 00:00:00+00';
  v_sfd constant date := date '2026-03-06';
  v_std constant date := date '2026-03-11';

  -- Autumn window: 2026-10-30 .. 2026-11-04, containing the 06:00Z transition.
  v_af  constant timestamptz := timestamptz '2026-10-30 00:00:00+00';
  v_at  constant timestamptz := timestamptz '2026-11-04 00:00:00+00';
  v_afd constant date := date '2026-10-30';
  v_atd constant date := date '2026-11-04';

  v_run      constant text := gen_random_uuid()::text;
  v_tok_ok   constant text := 'tw5b3-test-active-'    || v_run;
  v_tok_priv constant text := 'tw5b3-test-noprivate-' || v_run;
  v_link_ok   constant uuid := gen_random_uuid();
  v_link_priv constant uuid := gen_random_uuid();

  v_m  constant uuid := gen_random_uuid();   -- master fixture
  v_x  constant uuid := gen_random_uuid();   -- exception fixture
  v_res    jsonb;
  v_exists boolean;
  v_tg     "char";
begin
  raise notice 'Section 6: get_free_busy';

  assert v_owner <> '00000000-0000-0000-0000-000000000000'::uuid,
    '6.0.0 set v_owner to a dedicated test user id first';
  select exists(select 1 from auth.users u where u.id = v_owner) into v_exists;
  assert v_exists,
    '6.0.1 v_owner does not exist in auth.users. Create the test user through '
    'the normal Auth path; this suite never inserts into auth.users.';
  assert not exists (select 1 from public.events e where e.owner_id = v_owner),
    '6.0.2 test owner must have no pre-existing events. Point v_owner at a '
    'dedicated test user. Do NOT delete events to satisfy this assertion.';

  insert into public.share_links (id, owner_id, token_hash, label, include_private, expires_at, revoked_at)
  values
    (v_link_ok,   v_owner, encode(extensions.digest(v_tok_ok,  'sha256'),'hex'),
     'tw5b3 active', true,  null, null),
    (v_link_priv, v_owner, encode(extensions.digest(v_tok_priv,'sha256'),'hex'),
     'tw5b3 no private', false, null, null);

  v_res := public.get_free_busy(v_tok_ok, v_sf, v_st, v_sfd, v_std);
  assert v_res = '{"complete": true, "slots": []}'::jsonb,
    '6.0.3 empty test owner baseline, got ' || v_res::text;

  -- =====================================================================
  -- 6.1 A timed DAILY master is EXPANDED. This is the assertion 0007 held in
  --     the opposite direction; 5b-3 is the step that flips it.
  -- =====================================================================
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at, rrule, timezone)
  values (v_m, v_owner, '', 'busy_only', false,
          timestamptz '2026-03-06 14:00:00+00', timestamptz '2026-03-06 15:00:00+00',
          'FREQ=DAILY', v_ny);

  v_res := public.get_free_busy(v_tok_ok, v_sf, v_st, v_sfd, v_std);
  assert (v_res->>'complete')::boolean = true, '6.1 a supported timed recurrence is complete';
  assert jsonb_array_length(v_res->'slots') = 5,
    format('6.1 five daily occurrences, got %s', jsonb_array_length(v_res->'slots'));
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-03-06 14:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-03-06 15:00:00+00')), '6.1 first slot is EST';
  assert v_res->'slots'->2 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-03-08 13:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-03-08 14:00:00+00')),
    '6.1 the transition-day slot has moved to EDT';
  assert v_res->'slots'->4 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-03-10 13:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-03-10 14:00:00+00')), '6.1 last slot is EDT';

  -- 6.2 THE GAP, end to end. 02:30 on 03-08 does not exist and lands at 07:30Z.
  update public.events
     set start_at = timestamptz '2026-03-07 07:30:00+00',
         end_at   = timestamptz '2026-03-07 08:30:00+00'
   where id = v_m;
  v_res := public.get_free_busy(v_tok_ok, v_sf, v_st, v_sfd, v_std);
  assert (v_res->>'complete')::boolean = true, '6.2 gap series is complete';
  assert jsonb_array_length(v_res->'slots') = 4,
    format('6.2 four occurrences, got %s', jsonb_array_length(v_res->'slots'));
  assert v_res->'slots'->1 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-03-08 07:30:00+00'),
           'end',   to_jsonb(timestamptz '2026-03-08 08:30:00+00')),
    '6.2 the gap occurrence is shifted forward, not dropped';

  delete from public.events where id = v_m;

  -- =====================================================================
  -- 6.3 The AUTUMN transition, end to end.
  -- =====================================================================
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at, rrule, timezone)
  values (v_m, v_owner, '', 'busy_only', false,
          timestamptz '2026-10-30 13:00:00+00', timestamptz '2026-10-30 14:00:00+00',
          'FREQ=DAILY', v_ny);

  v_res := public.get_free_busy(v_tok_ok, v_af, v_at, v_afd, v_atd);
  assert (v_res->>'complete')::boolean = true, '6.3 complete';
  assert jsonb_array_length(v_res->'slots') = 5, '6.3 five occurrences';
  assert v_res->'slots'->1 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-10-31 13:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-10-31 14:00:00+00')), '6.3 still EDT';
  assert v_res->'slots'->2 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-11-01 14:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-11-01 15:00:00+00')), '6.3 EST resumes';

  -- 6.4 EARLY-FOLD DTSTART. The stored 05:30Z must survive; reconstructing it
  --     would report 06:30Z and silently move the series.
  update public.events
     set start_at = timestamptz '2026-11-01 05:30:00+00',
         end_at   = timestamptz '2026-11-01 06:30:00+00'
   where id = v_m;
  v_res := public.get_free_busy(v_tok_ok, v_af, v_at, v_afd, v_atd);
  assert (v_res->>'complete')::boolean = true, '6.4 complete';
  assert jsonb_array_length(v_res->'slots') = 3, '6.4 three occurrences';
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-11-01 05:30:00+00'),
           'end',   to_jsonb(timestamptz '2026-11-01 06:30:00+00')),
    '6.4 the stored early-fold DTSTART is reported verbatim';
  assert v_res->'slots'->1 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-11-02 06:30:00+00'),
           'end',   to_jsonb(timestamptz '2026-11-02 07:30:00+00')),
    '6.4 later occurrences use the standard offset';

  -- 6.5 LATE-FOLD DTSTART: stored value and reconstruction agree.
  update public.events
     set start_at = timestamptz '2026-11-01 06:30:00+00',
         end_at   = timestamptz '2026-11-01 07:30:00+00'
   where id = v_m;
  v_res := public.get_free_busy(v_tok_ok, v_af, v_at, v_afd, v_atd);
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-11-01 06:30:00+00'),
           'end',   to_jsonb(timestamptz '2026-11-01 07:30:00+00')), '6.5 late-fold DTSTART';

  delete from public.events where id = v_m;

  -- =====================================================================
  -- 6.6 EXCEPTIONS. The series below starts BEFORE the fold, so its 11-01
  --     occurrence is reconstructed at 06:30Z (the standard offset).
  -- =====================================================================
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at, rrule, timezone)
  values (v_m, v_owner, '', 'busy_only', false,
          timestamptz '2026-10-30 05:30:00+00', timestamptz '2026-10-30 06:30:00+00',
          'FREQ=DAILY', v_ny);

  v_res := public.get_free_busy(v_tok_ok, v_af, v_at, v_afd, v_atd);
  assert jsonb_array_length(v_res->'slots') = 5, '6.6.0 five occurrences before any exception';
  assert v_res->'slots'->2 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-11-01 06:30:00+00'),
           'end',   to_jsonb(timestamptz '2026-11-01 07:30:00+00')),
    '6.6.0 the fold occurrence sits at the LATER instant';

  -- 6.6a A cancellation keyed on the SQL-generated slot detaches it.
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             recurrence_id, recurrence_slot_start, is_cancelled)
  values (v_x, v_owner, '', 'busy_only', false,
          timestamptz '2026-11-01 06:30:00+00', timestamptz '2026-11-01 07:30:00+00',
          v_m, timestamptz '2026-11-01 06:30:00+00', true);

  v_res := public.get_free_busy(v_tok_ok, v_af, v_at, v_afd, v_atd);
  assert (v_res->>'complete')::boolean = true, '6.6a a matched slot keeps the window complete';
  assert jsonb_array_length(v_res->'slots') = 4, '6.6a the cancelled occurrence is gone';

  -- 6.6b A MOVED exception: the original slot goes, the snapshot appears.
  update public.events
     set is_cancelled = false,
         start_at = timestamptz '2026-11-01 20:00:00+00',
         end_at   = timestamptz '2026-11-01 21:00:00+00'
   where id = v_x;
  v_res := public.get_free_busy(v_tok_ok, v_af, v_at, v_afd, v_atd);
  assert (v_res->>'complete')::boolean = true, '6.6b complete';
  assert jsonb_array_length(v_res->'slots') = 5,
    '6.6b five slots: four generated plus the moved snapshot, sorted by start';
  assert v_res->'slots'->2 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-11-01 20:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-11-01 21:00:00+00')), '6.6b the moved snapshot';

  -- 6.6c A PRIVATE exception still detaches, but is not disclosed.
  update public.events set visibility = 'private' where id = v_x;
  v_res := public.get_free_busy(v_tok_priv, v_af, v_at, v_afd, v_atd);
  assert (v_res->>'complete')::boolean = true, '6.6c complete';
  assert jsonb_array_length(v_res->'slots') = 4,
    '6.6c detaching is structural; the private snapshot is withheld';
  update public.events set visibility = 'busy_only' where id = v_x;

  -- =====================================================================
  -- 6.7 A slot this server does not generate. The TypeScript expander resolves
  --     the ambiguous 01:30 to the EARLIER instant (05:30Z), so a slot written
  --     by it does not match the 06:30Z this server produces. That is a real
  --     disagreement about where the occurrence is, and the window must be
  --     reported INCOMPLETE. No claim is made about which side is right, or
  --     about the direction of the error; Phase 5b-4 resolves the divergence.
  -- =====================================================================
  update public.events
     set recurrence_slot_start = timestamptz '2026-11-01 05:30:00+00',
         is_cancelled = true
   where id = v_x;
  v_res := public.get_free_busy(v_tok_ok, v_af, v_at, v_afd, v_atd);
  assert (v_res->>'complete')::boolean = false,
    '6.7 an unmatched exception slot must make the window incomplete';

  delete from public.events where id in (v_m, v_x);

  -- =====================================================================
  -- 6.8 A GAP occurrence can be detached like any other.
  -- =====================================================================
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at, rrule, timezone)
  values (v_m, v_owner, '', 'busy_only', false,
          timestamptz '2026-03-07 07:30:00+00', timestamptz '2026-03-07 08:30:00+00',
          'FREQ=DAILY', v_ny);
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             recurrence_id, recurrence_slot_start, is_cancelled)
  values (v_x, v_owner, '', 'busy_only', false,
          timestamptz '2026-03-08 07:30:00+00', timestamptz '2026-03-08 08:30:00+00',
          v_m, timestamptz '2026-03-08 07:30:00+00', true);

  v_res := public.get_free_busy(v_tok_ok, v_sf, v_st, v_sfd, v_std);
  assert (v_res->>'complete')::boolean = true, '6.8 the gap slot matches';
  assert jsonb_array_length(v_res->'slots') = 3, '6.8 the gap occurrence is detached';
  delete from public.events where id in (v_m, v_x);

  -- =====================================================================
  -- 6.9 A GENUINE M0 (timed master, timezone IS NULL). The 0008 trigger has no
  --     transition into this state, so the fixture is built with the trigger
  --     disabled for exactly one insert. The RPC must not raise, must expand
  --     nothing, and must report the window incomplete.
  -- =====================================================================
  alter table public.events disable trigger events_validate_timezone;
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at, rrule, timezone)
  values (v_m, v_owner, '', 'busy_only', false,
          timestamptz '2026-10-30 13:00:00+00', timestamptz '2026-10-30 14:00:00+00',
          'FREQ=DAILY', null);
  alter table public.events enable trigger events_validate_timezone;

  select t.tgenabled into v_tg
  from pg_catalog.pg_trigger t
  where t.tgrelid = 'public.events'::regclass
    and t.tgname = 'events_validate_timezone' and not t.tgisinternal;
  assert v_tg = 'O', format('6.9 the trigger must be re-enabled immediately, tgenabled=%s', v_tg);
  assert exists (select 1 from public.events e where e.id = v_m and e.timezone is null),
    '6.9 the M0 fixture was not created';

  v_res := public.get_free_busy(v_tok_ok, v_af, v_at, v_afd, v_atd);
  assert (v_res->>'complete')::boolean = false, '6.9 M0 forces complete=false';
  assert jsonb_array_length(v_res->'slots') = 0, '6.9 M0 contributes no slots';

  -- 6.10 The same, for a zone this server cannot resolve.
  update public.events set timezone = 'America/New_York' where id = v_m;  -- through the trigger
  alter table public.events disable trigger events_validate_timezone;
  update public.events set timezone = 'Nowhere/Nothing' where id = v_m;
  alter table public.events enable trigger events_validate_timezone;

  select t.tgenabled into v_tg
  from pg_catalog.pg_trigger t
  where t.tgrelid = 'public.events'::regclass
    and t.tgname = 'events_validate_timezone' and not t.tgisinternal;
  assert v_tg = 'O', format('6.10 the trigger must be re-enabled immediately, tgenabled=%s', v_tg);

  v_res := public.get_free_busy(v_tok_ok, v_af, v_at, v_afd, v_atd);
  assert (v_res->>'complete')::boolean = false, '6.10 an unresolvable zone forces complete=false';
  assert jsonb_array_length(v_res->'slots') = 0, '6.10 and contributes no slots';

  delete from public.events where id = v_m;

  -- =====================================================================
  -- 6.11 Grammar still outside the subset stays fail-closed.
  -- =====================================================================
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at, rrule, timezone)
  values (v_m, v_owner, '', 'busy_only', false,
          timestamptz '2026-10-30 13:00:00+00', timestamptz '2026-10-30 14:00:00+00',
          'FREQ=MONTHLY', v_ny);
  v_res := public.get_free_busy(v_tok_ok, v_af, v_at, v_afd, v_atd);
  assert (v_res->>'complete')::boolean = false, '6.11a MONTHLY is incomplete';
  assert jsonb_array_length(v_res->'slots') = 0, '6.11a MONTHLY contributes no slots';

  update public.events set rrule = 'FREQ=DAILY;COUNT=5' where id = v_m;
  v_res := public.get_free_busy(v_tok_ok, v_af, v_at, v_afd, v_atd);
  assert (v_res->>'complete')::boolean = false, '6.11b COUNT is incomplete';
  assert jsonb_array_length(v_res->'slots') = 0, '6.11b COUNT contributes no slots';

  update public.events set rrule = 'FREQ=DAILY;UNTIL=20261103' where id = v_m;
  v_res := public.get_free_busy(v_tok_ok, v_af, v_at, v_afd, v_atd);
  assert (v_res->>'complete')::boolean = false, '6.11c a DATE-form UNTIL is incomplete';
  assert jsonb_array_length(v_res->'slots') = 0, '6.11c and contributes no slots';

  -- 6.11d A series that provably ended before the window stays COMPLETE: the
  --       0006 narrowing must survive 5b-3.
  update public.events set rrule = 'FREQ=DAILY;UNTIL=20260101T000000Z' where id = v_m;
  v_res := public.get_free_busy(v_tok_ok, v_af, v_at, v_afd, v_atd);
  assert (v_res->>'complete')::boolean = true, '6.11d a finished series is still narrowed away';
  assert jsonb_array_length(v_res->'slots') = 0, '6.11d and contributes nothing';

  delete from public.events where id = v_m;

  -- =====================================================================
  -- 6.12 THE CAP, on its exact boundary. Both fixtures are long events
  --      repeating daily, the only shape whose candidate count is not bounded
  --      by the window (section 3 derives the numbers). 5000 must expand and
  --      5001 must not; an off-by-one on either side is visible here.
  -- =====================================================================
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at, rrule, timezone)
  values (v_m, v_owner, '', 'busy_only', false,
          ((date '2026-03-11' - 4999) + time '09:00:00') at time zone v_ny,
          (((date '2026-03-11' - 4999) + time '09:00:00') at time zone v_ny)
            + make_interval(secs => 5000 * 86400),
          'FREQ=DAILY', v_ny);

  v_res := public.get_free_busy(v_tok_ok, v_sf, v_st, v_sfd, v_std);
  assert (v_res->>'complete')::boolean = true,
    '6.12a exactly 5000 candidates is within the cap and must expand';
  assert jsonb_array_length(v_res->'slots') = 1,
    format('6.12a the overlapping occurrences merge into one span, got %s',
           jsonb_array_length(v_res->'slots'));
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', false, 'start', to_jsonb(v_sf), 'end', to_jsonb(v_st)),
    '6.12a the merged span is clipped to the window';

  update public.events
     set start_at = ((date '2026-03-11' - 5000) + time '09:00:00') at time zone v_ny,
         end_at   = (((date '2026-03-11' - 5000) + time '09:00:00') at time zone v_ny)
                      + make_interval(secs => 5000 * 86400)
   where id = v_m;
  v_res := public.get_free_busy(v_tok_ok, v_sf, v_st, v_sfd, v_std);
  assert (v_res->>'complete')::boolean = false, '6.12b 5001 candidates is over the cap';
  assert jsonb_array_length(v_res->'slots') = 0, '6.12b over the cap contributes no slots';
  delete from public.events where id = v_m;

  -- =====================================================================
  -- 6.13 DURATION IS ABSOLUTE, end to end. A 24-hour occurrence that spans the
  --      spring transition still lasts exactly 86400 seconds, so its local wall
  --      clock ends an hour LATER than it began (09:00 -> 10:00). Calendar
  --      arithmetic would have produced 09:00 again, i.e. a 23-hour slot.
  --      INTERVAL=3 keeps the two occurrences from touching and merging.
  -- =====================================================================
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at, rrule, timezone)
  values (v_m, v_owner, '', 'busy_only', false,
          timestamptz '2026-03-07 14:00:00+00',            -- 09:00 EST
          timestamptz '2026-03-08 14:00:00+00',            -- exactly 24h later
          'FREQ=DAILY;INTERVAL=3', v_ny);

  v_res := public.get_free_busy(v_tok_ok, v_sf,
                                timestamptz '2026-03-12 00:00:00+00',
                                v_sfd, date '2026-03-12');
  assert (v_res->>'complete')::boolean = true, '6.13 complete';
  assert jsonb_array_length(v_res->'slots') = 2,
    format('6.13 two disjoint 24h occurrences, got %s', jsonb_array_length(v_res->'slots'));

  -- The occurrence that crosses the transition.
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-03-07 14:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-03-08 14:00:00+00')),
    '6.13 the DST-crossing occurrence keeps its absolute length';
  -- The next one, three local days later, already in EDT.
  assert v_res->'slots'->1 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-03-10 13:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-03-11 13:00:00+00')),
    '6.13 the second occurrence starts an hour earlier in UTC, same length';

  assert extract(epoch from (((v_res->'slots'->0->>'end')::timestamptz)
                           - ((v_res->'slots'->0->>'start')::timestamptz))) = 86400,
    '6.13 slot 0 lasts exactly 86400 seconds across the transition';
  assert extract(epoch from (((v_res->'slots'->1->>'end')::timestamptz)
                           - ((v_res->'slots'->1->>'start')::timestamptz))) = 86400,
    '6.13 slot 1 lasts exactly 86400 seconds';

  delete from public.events where id = v_m;

  -- ------------------------------------------------------------- CLEANUP
  delete from public.share_links where id in (v_link_ok, v_link_priv);
  assert not exists (select 1 from public.events e where e.owner_id = v_owner),
    '6.14 fixtures leaked: test owner should be back to zero events';

  select t.tgenabled into v_tg
  from pg_catalog.pg_trigger t
  where t.tgrelid = 'public.events'::regclass
    and t.tgname = 'events_validate_timezone' and not t.tgisinternal;
  assert v_tg = 'O', format('6.14 the trigger must end enabled, tgenabled=%s', v_tg);

  raise notice 'Section 6 OK';
end $$;

-- ============================================================================
-- SECTION 7 -- regressions 0009 must not cause: the 5b-1 all-day behaviour, and
-- the token / window contract that has held since 0005.
-- ============================================================================
do $$
declare
  ------------------------------------------------------------------ SET THIS
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';  -- <<< EDIT per project
  --------------------------------------------------------------------------
  v_from  constant timestamptz := timestamptz '2026-09-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-09-08 00:00:00+00';
  v_fromd constant date := date '2026-09-01';
  v_tod   constant date := date '2026-09-08';

  v_run    constant text := gen_random_uuid()::text;
  v_tok    constant text := 'tw5b3-regress-'  || v_run;
  v_tok_rv constant text := 'tw5b3-revoked-'  || v_run;
  v_tok_ex constant text := 'tw5b3-expired-'  || v_run;
  v_link    constant uuid := gen_random_uuid();
  v_link_rv constant uuid := gen_random_uuid();
  v_link_ex constant uuid := gen_random_uuid();

  v_m constant uuid := gen_random_uuid();
  v_res    jsonb;
  v_raised boolean;
begin
  raise notice 'Section 7: all-day and RPC-contract regressions';

  assert not exists (select 1 from public.events e where e.owner_id = v_owner),
    '7.0 test owner must start with zero events';

  insert into public.share_links (id, owner_id, token_hash, label, include_private, expires_at, revoked_at)
  values
    (v_link,    v_owner, encode(extensions.digest(v_tok,   'sha256'),'hex'), 'tw5b3 ok',      true, null, null),
    (v_link_rv, v_owner, encode(extensions.digest(v_tok_rv,'sha256'),'hex'), 'tw5b3 revoked', true, null, now()),
    (v_link_ex, v_owner, encode(extensions.digest(v_tok_ex,'sha256'),'hex'), 'tw5b3 expired', true,
     now() - interval '1 day', null);

  -- 7.1 The 0007 case: an all-day DAILY;INTERVAL=3 master expands to two slots.
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date, rrule)
  values (v_m, v_owner, '', 'busy_only', true, date '2026-08-01', date '2026-08-02',
          'FREQ=DAILY;INTERVAL=3');
  v_res := public.get_free_busy(v_tok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true, '7.1 all-day recurrence still complete';
  assert jsonb_array_length(v_res->'slots') = 2, '7.1 two all-day slots';
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', true, 'start_date', to_jsonb(date '2026-09-03'),
           'end_date', to_jsonb(date '2026-09-04')), '7.1 first all-day slot';
  assert v_res->'slots'->1 = jsonb_build_object(
           'all_day', true, 'start_date', to_jsonb(date '2026-09-06'),
           'end_date', to_jsonb(date '2026-09-07')), '7.1 second all-day slot';

  -- 7.2 An all-day series merges into one span when it repeats every day.
  update public.events set rrule = 'FREQ=DAILY' where id = v_m;
  v_res := public.get_free_busy(v_tok, v_from, v_to, v_fromd, v_tod);
  assert jsonb_array_length(v_res->'slots') = 1, '7.2 merges into one span';
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', true, 'start_date', to_jsonb(date '2026-09-01'),
           'end_date', to_jsonb(date '2026-09-08')), '7.2 span covers the window';

  -- 7.3 An all-day MONTHLY master is still fail-closed.
  update public.events set rrule = 'FREQ=MONTHLY' where id = v_m;
  v_res := public.get_free_busy(v_tok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = false, '7.3 all-day MONTHLY still incomplete';
  assert jsonb_array_length(v_res->'slots') = 0, '7.3 and contributes no slots';
  delete from public.events where id = v_m;

  -- 7.4 Token behaviour: unknown, revoked and expired all look identical and
  --     leak nothing.
  v_res := public.get_free_busy('no-such-token-' || v_run, v_from, v_to, v_fromd, v_tod);
  assert v_res = '{"complete": true, "slots": []}'::jsonb, '7.4a unknown token';
  v_res := public.get_free_busy(v_tok_rv, v_from, v_to, v_fromd, v_tod);
  assert v_res = '{"complete": true, "slots": []}'::jsonb, '7.4b revoked token';
  v_res := public.get_free_busy(v_tok_ex, v_from, v_to, v_fromd, v_tod);
  assert v_res = '{"complete": true, "slots": []}'::jsonb, '7.4c expired token';

  -- 7.5 Window validation is unchanged: reversed and over-long windows RAISE.
  v_raised := false;
  begin
    perform public.get_free_busy(v_tok, v_to, v_from, v_fromd, v_tod);
  exception when assert_failure then raise;
            when others then v_raised := true;
  end;
  assert v_raised, '7.5a a reversed instant window must raise';

  v_raised := false;
  begin
    perform public.get_free_busy(v_tok, v_from, v_from + interval '93 days', v_fromd, v_fromd + 93);
  exception when assert_failure then raise;
            when others then v_raised := true;
  end;
  assert v_raised, '7.5b a 93-day window must raise';

  v_raised := false;
  begin
    perform public.get_free_busy(v_tok, v_from, v_to, v_tod, v_fromd);
  exception when assert_failure then raise;
            when others then v_raised := true;
  end;
  assert v_raised, '7.5c a reversed date window must raise';

  -- 7.6 A 92-day window is still accepted.
  v_res := public.get_free_busy(v_tok, v_from, v_from + interval '92 days', v_fromd, v_fromd + 92);
  assert v_res is not null, '7.6 92 days is still the limit, not 91';

  delete from public.share_links where id in (v_link, v_link_rv, v_link_ex);
  assert not exists (select 1 from public.events e where e.owner_id = v_owner),
    '7.7 fixtures leaked';

  raise notice 'Section 7 OK';
end $$;

-- ============================================================================
-- SECTION 8 -- catalog: signature, argument names, security attributes, ACLs.
--
-- get_free_busy is the only function anon may reach. Its five parameter NAMES
-- matter as much as its types, because PostgREST passes arguments by name.
-- ============================================================================
do $$
declare
  v_oids   oid[];
  v_types  text[];
  v_names  text[];
  v_secdef boolean;
  v_cfg    text[];
  v_acl    text;
  v_name   text;
  v_anon   oid;
  v_auth   oid;
  v_has    boolean;
begin
  raise notice 'Section 8: catalog, security and ACLs';

  -- ACLs are read through aclexplode rather than by matching the printed
  -- aclitem[] text: a substring search cannot tell EXECUTE from any other
  -- privilege, and it cannot see the PUBLIC grant at all, which is written as
  -- an entry with an empty grantee (oid 0) and is exactly what "internal-only"
  -- has to exclude.
  select r.oid into v_anon from pg_catalog.pg_roles r where r.rolname = 'anon';
  select r.oid into v_auth from pg_catalog.pg_roles r where r.rolname = 'authenticated';
  assert v_anon is not null and v_auth is not null,
    '8.0 roles anon and authenticated must exist for these assertions to mean anything';

  -- 8.1 Exactly one get_free_busy, with the 0005 signature and names.
  assert (select count(*) from pg_catalog.pg_proc p
          join pg_catalog.pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname = 'get_free_busy') = 1,
    '8.1 there must be exactly one public.get_free_busy';

  select p.proargtypes::oid[], p.proargnames, p.prosecdef, p.proconfig, p.proacl::text
    into v_oids, v_names, v_secdef, v_cfg, v_acl
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_free_busy';

  select array(select pg_catalog.format_type(u.t, null)
               from unnest(v_oids) with ordinality as u(t, ord)
               order by u.ord)
    into v_types;
  assert v_types = array['text', 'timestamp with time zone',
                         'timestamp with time zone', 'date', 'date']::text[],
    format('8.2 get_free_busy argument types changed: %s', array_to_string(v_types, ', '));
  assert v_names = array['p_token', 'p_from', 'p_to', 'p_from_date', 'p_to_date']::text[],
    format('8.3 get_free_busy argument names changed: %s',
           coalesce(array_to_string(v_names, ', '), 'null'));
  assert v_secdef, '8.4 get_free_busy must stay SECURITY DEFINER';
  assert exists (select 1 from unnest(coalesce(v_cfg, array[]::text[])) c
                 where c like 'search_path=%'),
    format('8.5 get_free_busy must pin search_path, proconfig=%s',
           coalesce(array_to_string(v_cfg, ','), 'null'));

  -- 8.6 get_free_busy: anon and authenticated keep EXECUTE (create or replace
  --     preserved 0005 grants), and PUBLIC has none.
  assert v_acl is not null,
    '8.6 get_free_busy has a NULL proacl, so the default PUBLIC grant is back';

  select exists (
    select 1
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace,
    lateral pg_catalog.aclexplode(p.proacl) a
    where n.nspname = 'public' and p.proname = 'get_free_busy'
      and a.privilege_type = 'EXECUTE' and a.grantee = v_anon
  ) into v_has;
  assert v_has, format('8.6a anon must keep EXECUTE on get_free_busy: %s', v_acl);

  select exists (
    select 1
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace,
    lateral pg_catalog.aclexplode(p.proacl) a
    where n.nspname = 'public' and p.proname = 'get_free_busy'
      and a.privilege_type = 'EXECUTE' and a.grantee = v_auth
  ) into v_has;
  assert v_has, format('8.6b authenticated must keep EXECUTE on get_free_busy: %s', v_acl);

  select exists (
    select 1
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace,
    lateral pg_catalog.aclexplode(p.proacl) a
    where n.nspname = 'public' and p.proname = 'get_free_busy'
      and a.privilege_type = 'EXECUTE' and a.grantee = 0      -- 0 = PUBLIC
  ) into v_has;
  assert not v_has,
    format('8.6c PUBLIC must not have EXECUTE on get_free_busy: %s', v_acl);

  -- 8.7 Every 0009 helper: present, SECURITY INVOKER, search_path pinned, and
  --     reachable by nobody but the owner.
  foreach v_name in array array[
    'timezone_is_resolvable',
    'rrule_timed_expansion_cap',
    'rrule_timed_sql_subset',
    'rrule_timed_occurrence_count',
    'rrule_timed_occurrence_starts'
  ]
  loop
    select p.prosecdef, p.proconfig, p.proacl::text
      into v_secdef, v_cfg, v_acl
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_name;

    assert v_secdef is not null, format('8.7 public.%s is missing', v_name);
    assert v_secdef = false, format('8.7 public.%s must be SECURITY INVOKER', v_name);
    assert exists (select 1 from unnest(coalesce(v_cfg, array[]::text[])) c
                   where c like 'search_path=%'),
      format('8.7 public.%s must pin search_path', v_name);
    assert v_acl is not null,
      format('8.7 public.%s has a NULL proacl, so the default PUBLIC grant is '
             'still in place; the REVOKE did not run', v_name);

    select exists (
      select 1
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace,
      lateral pg_catalog.aclexplode(p.proacl) a
      where n.nspname = 'public' and p.proname = v_name
        and a.privilege_type = 'EXECUTE'
        and (a.grantee = 0 or a.grantee = v_anon or a.grantee = v_auth)
    ) into v_has;
    assert not v_has,
      format('8.7 public.%s must be internal-only, but PUBLIC, anon or '
             'authenticated holds EXECUTE: %s', v_name, v_acl);
  end loop;

  -- 8.8 0008 is untouched: timezone_is_supported keeps its own grants, which the
  --     write path depends on.
  select p.proacl::text into v_acl
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'timezone_is_supported';
  assert v_acl is not null, '8.8 timezone_is_supported proacl is NULL';

  select exists (
    select 1
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace,
    lateral pg_catalog.aclexplode(p.proacl) a
    where n.nspname = 'public' and p.proname = 'timezone_is_supported'
      and a.privilege_type = 'EXECUTE' and a.grantee = v_auth
  ) into v_has;
  assert v_has,
    format('8.8a timezone_is_supported must still be executable by authenticated: %s', v_acl);

  select exists (
    select 1
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace,
    lateral pg_catalog.aclexplode(p.proacl) a
    where n.nspname = 'public' and p.proname = 'timezone_is_supported'
      and a.privilege_type = 'EXECUTE' and a.grantee = 0
  ) into v_has;
  assert not v_has,
    format('8.8b PUBLIC must not have EXECUTE on timezone_is_supported: %s', v_acl);

  -- 8.9 The 0006/0007 helpers are still there and still internal-only.
  foreach v_name in array array[
    'rrule_parse', 'rrule_sql_subset', 'rrule_definitely_ends_before',
    'rrule_allday_expansion_cap', 'rrule_allday_occurrence_count',
    'rrule_allday_occurrence_starts'
  ]
  loop
    select p.proacl::text into v_acl
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_name;
    assert v_acl is not null,
      format('8.9 public.%s has a NULL proacl, so PUBLIC can execute it', v_name);

    select exists (
      select 1
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace,
      lateral pg_catalog.aclexplode(p.proacl) a
      where n.nspname = 'public' and p.proname = v_name
        and a.privilege_type = 'EXECUTE'
        and (a.grantee = 0 or a.grantee = v_anon or a.grantee = v_auth)
    ) into v_has;
    assert not v_has,
      format('8.9 public.%s must stay internal-only, but PUBLIC, anon or '
             'authenticated holds EXECUTE: %s', v_name, v_acl);
  end loop;

  raise notice 'Section 8 OK';
end $$;

-- ============================================================================
-- Leave no fixtures behind.
-- ============================================================================
rollback;
