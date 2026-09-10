-- TimeWeave Phase 5b-5B test suite for 0010_count_freebusy.sql.
--
-- NOT A MIGRATION. Run by hand (Supabase SQL editor or psql) against a
-- DEVELOPMENT project AFTER applying 0010 and AFTER its postflight passes.
-- Wrapped in a transaction that ends with ROLLBACK, so it leaves no fixtures
-- behind.
--
-- !! RUN THE WHOLE FILE, INCLUDING THE FINAL ROLLBACK. !!
--
-- A failing `assert` raises and aborts the transaction; every statement after it
-- reports "current transaction is aborted" until the final ROLLBACK. Read the
-- FIRST error message -- that is the real failure.
--
-- WHAT THIS SUITE IS ACTUALLY TESTING
--   COUNT is a bound on an occurrence's ORDINAL, not a tally kept while
--   walking. Section 2 is the heart of the file: it pins the SQL side against
--   the EXACT cases src/services/recurrence.test.ts A3-A12 pin on the
--   TypeScript side, because the two implementations must generate the same
--   sequence for the same RRULE. Every expected value in section 2 is copied
--   from that file, not re-derived here -- if they ever disagree, one of the two
--   is wrong and the suite says which case.
--
--     DAILY   ordinal(i)    = i
--     WEEKLY  ordinal(0, j) = j - (k - pw0)          <- week 0 is PARTIAL
--             ordinal(i, j) = pw0 + (i - 1) * k + j  <- i >= 1
--
--   where the BYDAY offsets are SORTED ASCENDING (0 = Monday .. 6 = Sunday), j
--   is the 0-based position in that sorted array, k is its length, and pw0 is
--   how many offsets fall at or after DTSTART's own weekday.
--
--   Section 2.4 (the A6 case) is the one that would have failed before Phase
--   5b-5A: with COUNT, the BYDAY order decides WHICH occurrences exist, not
--   merely the order they are reported in.
--
-- Sections 6 and 7 need a DEDICATED TEST USER that owns no events, exactly like
-- the 0006, 0007 and 0009 suites. It never inserts into auth.users and never
-- deletes or updates a row it did not itself insert.
--
-- TRIGGER HANDLING (section 8): one fixture cannot be created through the
-- normal path, because 0008 forbids it -- a master whose zone this server
-- cannot resolve. It is built by disabling events_validate_timezone for the
-- length of ONE insert and re-enabling it on the very next statement, inside
-- this transaction. ALTER TABLE ... DISABLE TRIGGER is transactional, so the
-- final ROLLBACK restores the trigger even if an assertion aborts the run
-- midway. Section 7 asserts the trigger is back to tgenabled='O' afterwards.
--
-- DST EXPECTATIONS: unchanged from 5b-3/5b-4 and re-pinned by the 0010
-- preflight, section C:
--   America/New_York EST = UTC-5, EDT = UTC-4;
--   spring transition 2026-03-08 07:00Z, autumn transition 2026-11-01 06:00Z;
--   a gap local time lands one hour later, an ambiguous local time resolves to
--   the LATER instant.
-- If the preflight passes and section 4 fails, the bug is in 0010, not tzdata.
--
-- Preflight: assumes pgcrypto lives in the `extensions` schema (Supabase
-- default), as 0005-0009 do.

begin;

-- ============================================================================
-- SECTION 1 -- the two GRAMMAR gates. 0010 removed exactly one test from each
-- (`count_n is null`) and nothing else, so this section is mostly a list of
-- things that must STILL be rejected.
-- ============================================================================
do $$
begin
  raise notice 'Section 1: rrule_sql_subset / rrule_timed_sql_subset with COUNT';

  -- 1.1 THE FLIP. Both of these were false before 0010.
  assert public.rrule_sql_subset('FREQ=DAILY;COUNT=5', true), '1.1 all-day DAILY COUNT';
  assert public.rrule_sql_subset('FREQ=WEEKLY;BYDAY=MO,WE;COUNT=4', true),
    '1.1 all-day WEEKLY BYDAY COUNT';
  assert public.rrule_sql_subset('FREQ=DAILY;INTERVAL=3;COUNT=5', true),
    '1.1 all-day INTERVAL + COUNT';
  assert public.rrule_sql_subset('FREQ=DAILY;COUNT=1', true), '1.1 COUNT=1 is a legal series';

  assert public.rrule_timed_sql_subset('FREQ=DAILY;COUNT=5', false), '1.2 timed DAILY COUNT';
  assert public.rrule_timed_sql_subset('FREQ=WEEKLY;BYDAY=TU,TH;COUNT=6', false),
    '1.2 timed WEEKLY BYDAY COUNT';
  assert public.rrule_timed_sql_subset('FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;COUNT=5', false),
    '1.2 timed INTERVAL + BYDAY + COUNT';

  -- 1.3 Everything that was already admitted must still be.
  assert public.rrule_sql_subset('FREQ=DAILY', true),                    '1.3 plain all-day DAILY';
  assert public.rrule_sql_subset('FREQ=WEEKLY;BYDAY=MO,WE', true),       '1.3 all-day WEEKLY';
  assert public.rrule_sql_subset('FREQ=DAILY;UNTIL=20261101', true),     '1.3 all-day DATE UNTIL';
  assert public.rrule_timed_sql_subset('FREQ=DAILY', false),             '1.3 plain timed DAILY';
  assert public.rrule_timed_sql_subset('FREQ=DAILY;UNTIL=20261101T060000Z', false),
    '1.3 timed instant UNTIL';

  -- 1.4 MONTHLY stays out, WITH COUNT AND WITHOUT. Only `count_n is null` was
  --     removed; `freq in (DAILY, WEEKLY)` remains in both gates.
  assert not public.rrule_sql_subset('FREQ=MONTHLY', true),              '1.4 all-day MONTHLY';
  assert not public.rrule_sql_subset('FREQ=MONTHLY;COUNT=4', true),      '1.4 all-day MONTHLY+COUNT';
  assert not public.rrule_timed_sql_subset('FREQ=MONTHLY', false),       '1.4 timed MONTHLY';
  assert not public.rrule_timed_sql_subset('FREQ=MONTHLY;COUNT=4', false),
    '1.4 timed MONTHLY+COUNT';
  assert not public.rrule_sql_subset('FREQ=YEARLY;COUNT=4', true),       '1.4 YEARLY+COUNT';

  -- 1.5 The two gates still partition on all_day, and COUNT does not blur it.
  assert not public.rrule_sql_subset('FREQ=DAILY;COUNT=5', false),
    '1.5 the all-day gate must still reject a timed row, COUNT or not';
  assert not public.rrule_timed_sql_subset('FREQ=DAILY;COUNT=5', true),
    '1.5 the timed gate must still reject an all-day row, COUNT or not';
  assert not public.rrule_sql_subset('FREQ=DAILY;COUNT=5', null),        '1.5 NULL all_day';
  assert not public.rrule_timed_sql_subset('FREQ=DAILY;COUNT=5', null),  '1.5 NULL all_day';

  -- 1.6 The UNTIL value type must still match all_day.
  assert not public.rrule_sql_subset('FREQ=DAILY;UNTIL=20261101T060000Z', true),
    '1.6 an instant UNTIL on an all-day row is still out';
  assert not public.rrule_timed_sql_subset('FREQ=DAILY;UNTIL=20261101', false),
    '1.6 a DATE UNTIL on a timed row is still out';

  -- 1.7 COUNT+UNTIL is malformed upstream. 0010 defines NO precedence between
  --     its two least() bounds and DEPENDS on never seeing both.
  assert not public.rrule_sql_subset('FREQ=DAILY;COUNT=5;UNTIL=20261101', true),
    '1.7 COUNT+UNTIL must stay malformed';
  assert not public.rrule_timed_sql_subset('FREQ=DAILY;COUNT=5;UNTIL=20261101T060000Z', false),
    '1.7 COUNT+UNTIL must stay malformed';

  -- 1.8 Nonsense COUNT values never reach the ordinal arithmetic, where
  --     `count_n - 1` would produce a bound of -1 or lower.
  assert not public.rrule_sql_subset('FREQ=DAILY;COUNT=0', true),        '1.8 COUNT=0';
  assert not public.rrule_sql_subset('FREQ=DAILY;COUNT=-3', true),       '1.8 negative COUNT';
  assert not public.rrule_sql_subset('FREQ=DAILY;COUNT=x', true),        '1.8 non-numeric COUNT';
  assert not public.rrule_sql_subset(null, true),                        '1.8 NULL rrule';
  assert not public.rrule_sql_subset('not an rrule', true),              '1.8 malformed';

  raise notice 'Section 1 OK';
end $$;

-- ============================================================================
-- SECTION 2 -- THE ORDINAL CONTRACT, on the all-day path.
--
-- Every case here mirrors one in src/services/recurrence.test.ts, named in the
-- comment. The dates are IDENTICAL to the TypeScript expectations; only the
-- call shape differs. A disagreement means the two expanders have diverged.
--
-- All fixtures are one-day all-day events (end_date = start_date + 1), and the
-- window is 2026-05-01 .. 2026-08-01 unless a case needs otherwise -- the same
-- window the TypeScript cases use.
-- ============================================================================
do $$
declare
  v_fromd constant date := date '2026-05-01';
  v_tod   constant date := date '2026-08-01';
  v_got   date[];
begin
  raise notice 'Section 2: the ordinal contract (all-day)';

  -- 2.1 (TS A3) DAILY stops exactly at COUNT. ordinal(i) = i.
  select array_agg(d order by d) into v_got
  from public.rrule_allday_occurrence_starts(
    'FREQ=DAILY;COUNT=10', true,
    date '2026-06-01', date '2026-06-02', v_fromd, v_tod) d;
  assert v_got = array[
    date '2026-06-01', date '2026-06-02', date '2026-06-03', date '2026-06-04',
    date '2026-06-05', date '2026-06-06', date '2026-06-07', date '2026-06-08',
    date '2026-06-09', date '2026-06-10'],
    format('2.1 A3 DAILY COUNT=10 -> %s', coalesce(v_got::text, 'null'));

  -- 2.2 (TS A4) COUNT counts OCCURRENCES, not days. INTERVAL decides WHICH date
  --     a candidate falls on and never how many occurrences precede it.
  select array_agg(d order by d) into v_got
  from public.rrule_allday_occurrence_starts(
    'FREQ=DAILY;INTERVAL=3;COUNT=5', true,
    date '2026-06-01', date '2026-06-02', v_fromd, v_tod) d;
  assert v_got = array[date '2026-06-01', date '2026-06-04', date '2026-06-07',
                       date '2026-06-10', date '2026-06-13'],
    format('2.2 A4 DAILY INTERVAL=3 COUNT=5 -> %s', coalesce(v_got::text, 'null'));

  -- 2.3 (TS A5) WEEKLY BYDAY, DTSTART on a Monday that IS in BYDAY.
  --     2026-06-01 is a Monday; MO,FR with COUNT=3 -> Jun 1, Jun 5, Jun 8.
  --     Here pw0 = 2 (both offsets are at or after Monday), so week 0 is FULL.
  select array_agg(d order by d) into v_got
  from public.rrule_allday_occurrence_starts(
    'FREQ=WEEKLY;BYDAY=MO,FR;COUNT=3', true,
    date '2026-06-01', date '2026-06-02', v_fromd, v_tod) d;
  assert v_got = array[date '2026-06-01', date '2026-06-05', date '2026-06-08'],
    format('2.3 A5 WEEKLY MO,FR COUNT=3 -> %s', coalesce(v_got::text, 'null'));

  -- 2.4 (TS A6) BYDAY ORDER MUST NOT CHANGE WHICH OCCURRENCES EXIST.
  --     The SQL side has always sorted its offsets (array_agg(... order by
  --     o.idx)); TypeScript did not until 5b-5A, and with COUNT that returned a
  --     different SET. This is the assertion that keeps the two on one
  --     sequence, and it is why the WEEKLY inner loop in 0010 is INDEXED rather
  --     than a foreach: the ordinal needs j, and j is only meaningful because
  --     the array is sorted.
  select array_agg(d order by d) into v_got
  from public.rrule_allday_occurrence_starts(
    'FREQ=WEEKLY;BYDAY=FR,MO;COUNT=3', true,
    date '2026-06-01', date '2026-06-02', v_fromd, v_tod) d;
  assert v_got = array[date '2026-06-01', date '2026-06-05', date '2026-06-08'],
    format('2.4 A6 WEEKLY FR,MO COUNT=3 must equal the MO,FR sequence -> %s',
           coalesce(v_got::text, 'null'));

  -- 2.5 (TS A7) THE PARTIAL WEEK 0, with DTSTART inside BYDAY.
  --     DTSTART Wednesday 2026-06-03; MO,WE,FR. Week 0 contributes only WE and
  --     FR, so pw0 = 2 and the ordinals run
  --       week 0: WE=0 FR=1 | week 1: MO=2 WE=3 FR=4 | week 2: MO=5 WE=6
  --     A naive "3 per week" bound would have stopped a day late, on the Friday.
  select array_agg(d order by d) into v_got
  from public.rrule_allday_occurrence_starts(
    'FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=7', true,
    date '2026-06-03', date '2026-06-04', v_fromd, v_tod) d;
  assert v_got = array[date '2026-06-03', date '2026-06-05',
                       date '2026-06-08', date '2026-06-10', date '2026-06-12',
                       date '2026-06-15', date '2026-06-17'],
    format('2.5 A7 WEEKLY MO,WE,FR COUNT=7 from a Wednesday -> %s',
           coalesce(v_got::text, 'null'));

  -- 2.6 (TS A8) DTSTART's weekday is NOT in BYDAY.
  --     DTSTART Wednesday 2026-06-03; MO,FR. TimeWeave does not emit DTSTART
  --     itself when it does not match BYDAY -- the same on both sides -- so the
  --     first occurrence is the Friday and week 0 contributes exactly one
  --     (pw0 = 1). The Monday of week 0 gets ordinal -1 and is rejected by the
  --     `v_ord >= 0` half of the test, independently of the `>= DTSTART` half.
  select array_agg(d order by d) into v_got
  from public.rrule_allday_occurrence_starts(
    'FREQ=WEEKLY;BYDAY=MO,FR;COUNT=4', true,
    date '2026-06-03', date '2026-06-04', v_fromd, v_tod) d;
  assert v_got = array[date '2026-06-05', date '2026-06-08',
                       date '2026-06-12', date '2026-06-15'],
    format('2.6 A8 WEEKLY MO,FR COUNT=4 from a Wednesday -> %s',
           coalesce(v_got::text, 'null'));

  -- 2.7 (TS A9) INTERVAL > 1 with BYDAY and COUNT together.
  --     DTSTART Tuesday 2026-06-02, every 2nd week, TU+TH, 5 occurrences.
  --     INTERVAL changes the DATE of week i, never the ordinal of a candidate.
  select array_agg(d order by d) into v_got
  from public.rrule_allday_occurrence_starts(
    'FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;COUNT=5', true,
    date '2026-06-02', date '2026-06-03', v_fromd, v_tod) d;
  assert v_got = array[date '2026-06-02', date '2026-06-04',
                       date '2026-06-16', date '2026-06-18',
                       date '2026-06-30'],
    format('2.7 A9 WEEKLY INTERVAL=2 TU,TH COUNT=5 -> %s',
           coalesce(v_got::text, 'null'));

  -- 2.8 (TS A10) A window AFTER the series has ended. The tightened hi falls
  --     below lo, the loop body never runs, and the answer is an empty set --
  --     not an error, and not a NULL count.
  assert not exists (
    select 1 from public.rrule_allday_occurrence_starts(
      'FREQ=DAILY;COUNT=10', true,
      date '2026-06-01', date '2026-06-02',
      date '2027-01-01', date '2027-02-01')
  ), '2.8 A10 a DAILY COUNT series must emit nothing after it has ended';

  assert not exists (
    select 1 from public.rrule_allday_occurrence_starts(
      'FREQ=WEEKLY;BYDAY=MO,FR;COUNT=3', true,
      date '2026-06-01', date '2026-06-02',
      date '2027-01-01', date '2027-02-01')
  ), '2.8 A10 a WEEKLY COUNT series must emit nothing after it has ended';

  -- 2.9 (TS A11) A window entirely BEFORE DTSTART.
  assert not exists (
    select 1 from public.rrule_allday_occurrence_starts(
      'FREQ=DAILY;COUNT=10', true,
      date '2026-06-01', date '2026-06-02',
      date '2026-01-01', date '2026-02-01')
  ), '2.9 A11 nothing may be emitted before DTSTART';

  -- 2.10 COUNT=1: the degenerate series. On the WEEKLY arm this takes the
  --      `count_n <= pw0` branch, which pins hi at week 0.
  select array_agg(d order by d) into v_got
  from public.rrule_allday_occurrence_starts(
    'FREQ=DAILY;COUNT=1', true,
    date '2026-06-01', date '2026-06-02', v_fromd, v_tod) d;
  assert v_got = array[date '2026-06-01'],
    format('2.10 DAILY COUNT=1 -> %s', coalesce(v_got::text, 'null'));

  select array_agg(d order by d) into v_got
  from public.rrule_allday_occurrence_starts(
    'FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=1', true,
    date '2026-06-03', date '2026-06-04', v_fromd, v_tod) d;
  assert v_got = array[date '2026-06-03'],
    format('2.10 WEEKLY COUNT=1 from a Wednesday -> %s', coalesce(v_got::text, 'null'));

  -- 2.11 COUNT exactly equal to pw0: week 0 is the whole series, and the
  --      `count_n <= pw0` branch is the only thing that stops week 1.
  select array_agg(d order by d) into v_got
  from public.rrule_allday_occurrence_starts(
    'FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=2', true,
    date '2026-06-03', date '2026-06-04', v_fromd, v_tod) d;
  assert v_got = array[date '2026-06-03', date '2026-06-05'],
    format('2.11 WEEKLY COUNT=2 = pw0 from a Wednesday -> %s',
           coalesce(v_got::text, 'null'));

  -- 2.12 A window that STARTS INSIDE the series. The index range is derived
  --      from the window, so the occurrences before it are never generated --
  --      but their ordinals still count, which is what keeps the tail correct.
  select array_agg(d order by d) into v_got
  from public.rrule_allday_occurrence_starts(
    'FREQ=DAILY;COUNT=10', true,
    date '2026-06-01', date '2026-06-02',
    date '2026-06-07', date '2026-06-20') d;
  assert v_got = array[date '2026-06-07', date '2026-06-08', date '2026-06-09',
                       date '2026-06-10'],
    format('2.12 a window opening mid-series must still stop at ordinal 9 -> %s',
           coalesce(v_got::text, 'null'));

  -- 2.13 O(window), not O(distance from DTSTART): a COUNT series whose DTSTART
  --      is decades before the window must answer without walking to it.
  --      COUNT=40000 daily from 1970 is still running in 2026.
  select array_agg(d order by d) into v_got
  from public.rrule_allday_occurrence_starts(
    'FREQ=DAILY;COUNT=40000', true,
    date '1970-01-01', date '1970-01-02',
    date '2026-06-01', date '2026-06-05') d;
  assert v_got = array[date '2026-06-01', date '2026-06-02', date '2026-06-03',
                       date '2026-06-04'],
    format('2.13 a 1970 COUNT=40000 series viewed in 2026 -> %s',
           coalesce(v_got::text, 'null'));

  raise notice 'Section 2 OK';
end $$;

-- ============================================================================
-- SECTION 3 -- rrule_allday_occurrence_count: an UPPER BOUND on candidates, and
-- the cap it feeds.
--
-- The contract callers depend on: NULL means "cannot count", which every caller
-- turns into "over cap" via coalesce(count, cap + 1) and hence complete=false.
-- ZERO means "expandable, contributes nothing" -- an ordinary answer. Confusing
-- the two is the false-free this whole migration is built to avoid.
-- ============================================================================
do $$
declare
  v_fromd constant date := date '2026-05-01';
  v_tod   constant date := date '2026-08-01';
  v_n      bigint;
  v_real   bigint;
  v_raised boolean;
  v_msg    text;
begin
  raise notice 'Section 3: rrule_allday_occurrence_count';

  -- 3.1 It is an UPPER BOUND, never an undercount. Checked against what
  --     _starts actually emits, for every section 2 case.
  for v_n, v_real in
    select c.n, c.real from (
      select
        public.rrule_allday_occurrence_count(r.rule, true, r.s, r.e, v_fromd, v_tod) as n,
        (select count(*) from public.rrule_allday_occurrence_starts(
           r.rule, true, r.s, r.e, v_fromd, v_tod))                                  as real
      from (values
        ('FREQ=DAILY;COUNT=10',                        date '2026-06-01', date '2026-06-02'),
        ('FREQ=DAILY;INTERVAL=3;COUNT=5',              date '2026-06-01', date '2026-06-02'),
        ('FREQ=WEEKLY;BYDAY=MO,FR;COUNT=3',            date '2026-06-01', date '2026-06-02'),
        ('FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=7',         date '2026-06-03', date '2026-06-04'),
        ('FREQ=WEEKLY;BYDAY=MO,FR;COUNT=4',            date '2026-06-03', date '2026-06-04'),
        ('FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;COUNT=5', date '2026-06-02', date '2026-06-03'),
        ('FREQ=DAILY;COUNT=1',                         date '2026-06-01', date '2026-06-02'),
        ('FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=2',         date '2026-06-03', date '2026-06-04')
      ) as r(rule, s, e)
    ) c
  loop
    assert v_n is not null, '3.1 a COUNT master inside the subset must never count NULL';
    assert v_n >= v_real,
      format('3.1 the count (%s) UNDERCOUNTS the %s occurrences actually emitted; '
             'the caller would then cap-check against a number that is too small',
             v_n, v_real);
  end loop;

  -- 3.2 A COUNT master no longer counts NULL. This is the second, independent
  --     rejection the migration header is about: widening the subset alone
  --     would have left this NULL, and a NULL count is read as "over cap" by
  --     every caller -- inside the subset yet outside the expandable set,
  --     generating nothing and reporting nothing. A silent false-free.
  v_n := public.rrule_allday_occurrence_count(
           'FREQ=DAILY;COUNT=3', true,
           date '2026-06-01', date '2026-06-02',
           date '2026-06-01', date '2026-06-10');
  assert v_n = 3, format('3.2 expected 3, got %s', coalesce(v_n::text, 'null'));

  -- 3.3 ZERO, not NULL, for a series that ENDED BEFORE the window. This is the
  --     case rrule_definitely_ends_before could never prove for COUNT, and it
  --     is now handled by expansion instead of by narrowing.
  v_n := public.rrule_allday_occurrence_count(
           'FREQ=DAILY;COUNT=3', true,
           date '2020-01-01', date '2020-01-02',
           date '2026-06-01', date '2026-06-10');
  assert v_n is not null,
    '3.3 an exhausted COUNT series must count 0, not NULL. NULL is read as '
    '"over cap" and would force complete=false for a series that cannot '
    'possibly contribute.';
  assert v_n = 0, format('3.3 expected 0, got %s', v_n);

  -- 3.4 ZERO for a window entirely before DTSTART, too.
  v_n := public.rrule_allday_occurrence_count(
           'FREQ=DAILY;COUNT=10', true,
           date '2026-06-01', date '2026-06-02',
           date '2026-01-01', date '2026-02-01');
  assert v_n = 0, format('3.4 expected 0 before DTSTART, got %s', coalesce(v_n::text, 'null'));

  -- 3.5 COUNT can only LOWER the bound, so it can never push a master over the
  --     cap. Monotonic in COUNT, for a window that outlives the series.
  assert public.rrule_allday_occurrence_count(
           'FREQ=DAILY;COUNT=5', true, date '2026-06-01', date '2026-06-02', v_fromd, v_tod)
         <= public.rrule_allday_occurrence_count(
           'FREQ=DAILY;COUNT=50', true, date '2026-06-01', date '2026-06-02', v_fromd, v_tod),
    '3.5 the count must be non-decreasing in COUNT';
  assert public.rrule_allday_occurrence_count(
           'FREQ=DAILY;COUNT=50', true, date '2026-06-01', date '2026-06-02', v_fromd, v_tod)
         <= public.rrule_allday_occurrence_count(
           'FREQ=DAILY', true, date '2026-06-01', date '2026-06-02', v_fromd, v_tod),
    '3.5 a COUNT series can never count MORE than the same rule without COUNT';

  -- 3.6 NULL outside the subset, never 0, so coalesce(count, cap + 1) keeps
  --     failing closed.
  assert public.rrule_allday_occurrence_count(
           'FREQ=MONTHLY;COUNT=4', true, date '2026-06-01', date '2026-06-02',
           v_fromd, v_tod) is null,
    '3.6 MONTHLY+COUNT must count NULL; its inline freq test is the only thing '
    'rejecting it now that the count_n test is gone';
  assert public.rrule_allday_occurrence_count(
           'FREQ=DAILY;COUNT=5', false, date '2026-06-01', date '2026-06-02',
           v_fromd, v_tod) is null,
    '3.6 a timed row must count NULL on the all-day helper';
  assert public.rrule_allday_occurrence_count(
           'FREQ=DAILY;COUNT=5', null, date '2026-06-01', date '2026-06-02',
           v_fromd, v_tod) is null,
    '3.6 NULL all_day must reach the body and return NULL by decision';
  assert public.rrule_allday_occurrence_count(
           'FREQ=DAILY;COUNT=5', true, null, date '2026-06-02',
           v_fromd, v_tod) is null,
    '3.6 a NULL date must count NULL, not raise';
  assert public.rrule_allday_occurrence_count(
           'FREQ=DAILY;COUNT=5;UNTIL=20261101', true, date '2026-06-01', date '2026-06-02',
           v_fromd, v_tod) is null,
    '3.6 COUNT+UNTIL is malformed and must count NULL';

  -- 3.7 The precondition on _starts is a LOUD failure, not an empty set: an
  --     empty set would be indistinguishable from "no busy here".
  --     `when assert_failure then raise` first, so a failing assertion inside
  --     the block is never swallowed by the `when others` that follows it.
  v_raised := false;
  begin
    perform public.rrule_allday_occurrence_starts(
      'FREQ=MONTHLY;COUNT=4', true, date '2026-06-01', date '2026-06-02', v_fromd, v_tod);
  exception when assert_failure then raise;
           when others then v_raised := true; v_msg := sqlerrm;
  end;
  assert v_raised, '3.7 _starts must RAISE outside the subset, not return rows';
  assert v_msg like '%precondition violated%',
    format('3.7 expected a precondition violation, got: %s', v_msg);

  -- A COUNT rule that IS in the subset must not raise -- the same call shape,
  -- proving 3.7 tested the subset and not the call itself.
  v_raised := false;
  begin
    perform public.rrule_allday_occurrence_starts(
      'FREQ=DAILY;COUNT=5', true, date '2026-06-01', date '2026-06-02', v_fromd, v_tod);
  exception when assert_failure then raise;
           when others then v_raised := true; v_msg := sqlerrm;
  end;
  assert not v_raised,
    format('3.7 an all-day COUNT rule must no longer raise, got: %s', v_msg);

  raise notice 'Section 3 OK';
end $$;

-- ============================================================================
-- SECTION 4 -- the TIMED path: the same ordinal contract, plus the DST
-- semantics 0010 reproduces verbatim.
--
-- COUNT bounds an ordinal; it says nothing about which instant a wall clock
-- names. 4.1-4.3 isolate the ordinal in a constant-offset zone; 4.4-4.6 put it
-- back together with the gap, the fold and the DTSTART exact-anchor.
-- ============================================================================
do $$
declare
  v_ny     constant text := 'America/New_York';
  v_got    timestamptz[];
  v_raised boolean;
  v_msg    text;
begin
  raise notice 'Section 4: the ordinal contract and DST (timed)';

  -- 4.1 (TS A3, timed) DAILY COUNT=10 in UTC, where no offset ever moves.
  select array_agg(t order by t) into v_got
  from public.rrule_timed_occurrence_starts(
    'FREQ=DAILY;COUNT=10', false,
    timestamptz '2026-06-01 09:00:00+00', timestamptz '2026-06-01 10:00:00+00',
    'UTC',
    timestamptz '2026-06-01 00:00:00+00', timestamptz '2026-07-01 00:00:00+00') t;
  assert array_length(v_got, 1) = 10,
    format('4.1 expected 10 occurrences, got %s', coalesce(array_length(v_got, 1), 0));
  assert v_got[1]  = timestamptz '2026-06-01 09:00:00+00', '4.1 first occurrence';
  assert v_got[10] = timestamptz '2026-06-10 09:00:00+00', '4.1 tenth and last occurrence';

  -- 4.2 (TS A7, timed) The PARTIAL week 0 on the timed arm. DTSTART's weekday
  --     is read IN THE MASTER ZONE, like every other calendar field there.
  select array_agg(t order by t) into v_got
  from public.rrule_timed_occurrence_starts(
    'FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=7', false,
    timestamptz '2026-06-03 09:00:00+00', timestamptz '2026-06-03 10:00:00+00',
    'UTC',
    timestamptz '2026-05-01 00:00:00+00', timestamptz '2026-08-01 00:00:00+00') t;
  assert v_got = array[
    timestamptz '2026-06-03 09:00:00+00', timestamptz '2026-06-05 09:00:00+00',
    timestamptz '2026-06-08 09:00:00+00', timestamptz '2026-06-10 09:00:00+00',
    timestamptz '2026-06-12 09:00:00+00', timestamptz '2026-06-15 09:00:00+00',
    timestamptz '2026-06-17 09:00:00+00'],
    format('4.2 A7 timed WEEKLY MO,WE,FR COUNT=7 -> %s', coalesce(v_got::text, 'null'));

  -- 4.3 (TS A9, timed) INTERVAL, BYDAY and COUNT together.
  select array_agg(t order by t) into v_got
  from public.rrule_timed_occurrence_starts(
    'FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;COUNT=5', false,
    timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 10:00:00+00',
    'UTC',
    timestamptz '2026-05-01 00:00:00+00', timestamptz '2026-08-01 00:00:00+00') t;
  assert v_got = array[
    timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-04 09:00:00+00',
    timestamptz '2026-06-16 09:00:00+00', timestamptz '2026-06-18 09:00:00+00',
    timestamptz '2026-06-30 09:00:00+00'],
    format('4.3 A9 timed WEEKLY INTERVAL=2 TU,TH COUNT=5 -> %s',
           coalesce(v_got::text, 'null'));

  -- 4.4 (TS A12) THE FOLD, WITH COUNT. DTSTART 2026-10-30 01:30 New York (EDT)
  --     = 05:30Z, five occurrences. The third lands on the ambiguous 01:30 of
  --     2026-11-01 and must resolve to the LATER instant, 06:30Z -- and the
  --     FIRST must come back as the STORED instant, not a reconstruction.
  --     COUNT adds an ordinal bound and changes no instant.
  select array_agg(t order by t) into v_got
  from public.rrule_timed_occurrence_starts(
    'FREQ=DAILY;COUNT=5', false,
    timestamptz '2026-10-30 05:30:00+00', timestamptz '2026-10-30 06:30:00+00',
    v_ny,
    timestamptz '2026-10-01 00:00:00+00', timestamptz '2026-12-01 00:00:00+00') t;
  assert v_got = array[
    timestamptz '2026-10-30 05:30:00+00',   -- DTSTART, emitted verbatim
    timestamptz '2026-10-31 05:30:00+00',   -- still EDT
    timestamptz '2026-11-01 06:30:00+00',   -- the fold -> the LATER 01:30
    timestamptz '2026-11-02 06:30:00+00',   -- EST
    timestamptz '2026-11-03 06:30:00+00'],
    format('4.4 A12 fold + COUNT -> %s', coalesce(v_got::text, 'null'));

  -- 4.5 THE GAP, WITH COUNT. 02:30 on 2026-03-08 does not exist in New York and
  --     lands one hour later, at 07:30Z. COUNT must not drop or duplicate it:
  --     the ordinal is decided by the candidate INDEX, and a shifted instant is
  --     still candidate i.
  select array_agg(t order by t) into v_got
  from public.rrule_timed_occurrence_starts(
    'FREQ=DAILY;COUNT=4', false,
    timestamptz '2026-03-07 07:30:00+00', timestamptz '2026-03-07 08:30:00+00',
    v_ny,
    timestamptz '2026-03-01 00:00:00+00', timestamptz '2026-04-01 00:00:00+00') t;
  assert v_got = array[
    timestamptz '2026-03-07 07:30:00+00',   -- 02:30 EST, DTSTART verbatim
    timestamptz '2026-03-08 07:30:00+00',   -- the gap: shifted forward, not dropped
    timestamptz '2026-03-09 06:30:00+00',   -- 02:30 EDT
    timestamptz '2026-03-10 06:30:00+00'],
    format('4.5 gap + COUNT -> %s', coalesce(v_got::text, 'null'));

  -- 4.6 EARLY-FOLD DTSTART with COUNT. The stored 05:30Z must survive; a
  --     reconstruction would report 06:30Z and silently move the whole series
  --     by an hour. The exact-anchor is `if v_cl = v_dtl then p_start_at`, and
  --     COUNT does not touch it.
  select array_agg(t order by t) into v_got
  from public.rrule_timed_occurrence_starts(
    'FREQ=DAILY;COUNT=3', false,
    timestamptz '2026-11-01 05:30:00+00', timestamptz '2026-11-01 06:30:00+00',
    v_ny,
    timestamptz '2026-10-01 00:00:00+00', timestamptz '2026-12-01 00:00:00+00') t;
  assert v_got[1] = timestamptz '2026-11-01 05:30:00+00',
    format('4.6 a DTSTART on the EARLY side of a fold must be emitted verbatim, got %s',
           coalesce(v_got[1]::text, 'null'));
  assert v_got = array[
    timestamptz '2026-11-01 05:30:00+00',
    timestamptz '2026-11-02 06:30:00+00',
    timestamptz '2026-11-03 06:30:00+00'],
    format('4.6 early-fold DTSTART + COUNT -> %s', coalesce(v_got::text, 'null'));

  -- 4.7 A window after the series has ended, and one before DTSTART.
  assert not exists (
    select 1 from public.rrule_timed_occurrence_starts(
      'FREQ=DAILY;COUNT=5', false,
      timestamptz '2026-06-01 09:00:00+00', timestamptz '2026-06-01 10:00:00+00',
      'UTC',
      timestamptz '2027-01-01 00:00:00+00', timestamptz '2027-02-01 00:00:00+00')
  ), '4.7 nothing may be emitted after a timed COUNT series has ended';

  assert not exists (
    select 1 from public.rrule_timed_occurrence_starts(
      'FREQ=DAILY;COUNT=5', false,
      timestamptz '2026-06-01 09:00:00+00', timestamptz '2026-06-01 10:00:00+00',
      'UTC',
      timestamptz '2026-01-01 00:00:00+00', timestamptz '2026-02-01 00:00:00+00')
  ), '4.7 nothing may be emitted before DTSTART';

  -- 4.8 Zone drift and M0 stay fail-closed, and stay QUIET: an unresolvable
  --     zone or a NULL one returns NO ROWS rather than raising, because neither
  --     may take the anonymous Free/Busy RPC down. COUNT changes nothing here.
  assert not exists (
    select 1 from public.rrule_timed_occurrence_starts(
      'FREQ=DAILY;COUNT=5', false,
      timestamptz '2026-06-01 09:00:00+00', timestamptz '2026-06-01 10:00:00+00',
      null,
      timestamptz '2026-06-01 00:00:00+00', timestamptz '2026-07-01 00:00:00+00')
  ), '4.8 a NULL zone (M0) must return no rows, not raise';

  assert not exists (
    select 1 from public.rrule_timed_occurrence_starts(
      'FREQ=DAILY;COUNT=5', false,
      timestamptz '2026-06-01 09:00:00+00', timestamptz '2026-06-01 10:00:00+00',
      'Nowhere/Nothing',
      timestamptz '2026-06-01 00:00:00+00', timestamptz '2026-07-01 00:00:00+00')
  ), '4.8 an unresolvable zone must return no rows, not raise';

  -- 4.9 Caller wiring stays a LOUD failure -- and only caller wiring. Zone
  --     drift (4.8) is quiet, because it is data, not a programming fault.
  --     `when assert_failure then raise` first, so a failing assertion inside
  --     the block is never swallowed by the `when others` that follows it.
  v_raised := false;
  begin
    perform public.rrule_timed_occurrence_starts(
      'FREQ=MONTHLY;COUNT=4', false,
      timestamptz '2026-06-01 09:00:00+00', timestamptz '2026-06-01 10:00:00+00',
      'UTC',
      timestamptz '2026-06-01 00:00:00+00', timestamptz '2026-07-01 00:00:00+00');
  exception when assert_failure then raise;
           when others then v_raised := true; v_msg := sqlerrm;
  end;
  assert v_raised, '4.9 _starts must RAISE outside the timed subset';
  assert v_msg like '%precondition violated%',
    format('4.9 expected a precondition violation, got: %s', v_msg);

  -- A timed COUNT rule must no longer raise: it is in the subset now.
  v_raised := false;
  begin
    perform public.rrule_timed_occurrence_starts(
      'FREQ=DAILY;COUNT=5', false,
      timestamptz '2026-06-01 09:00:00+00', timestamptz '2026-06-01 10:00:00+00',
      'UTC',
      timestamptz '2026-06-01 00:00:00+00', timestamptz '2026-07-01 00:00:00+00');
  exception when assert_failure then raise;
           when others then v_raised := true; v_msg := sqlerrm;
  end;
  assert not v_raised,
    format('4.9 a timed COUNT rule must no longer raise, got: %s', v_msg);

  raise notice 'Section 4 OK';
end $$;

-- ============================================================================
-- SECTION 5 -- rrule_timed_occurrence_count. Same contract as section 3, on the
-- timed path: NULL means "cannot count", 0 means "expandable, contributes
-- nothing".
-- ============================================================================
do $$
declare
  v_from constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to   constant timestamptz := timestamptz '2026-07-01 00:00:00+00';
  v_s    constant timestamptz := timestamptz '2026-06-01 09:00:00+00';
  v_e    constant timestamptz := timestamptz '2026-06-01 10:00:00+00';
  v_n    bigint;
  v_real bigint;
begin
  raise notice 'Section 5: rrule_timed_occurrence_count';

  -- 5.1 An upper bound, never an undercount.
  for v_n, v_real in
    select c.n, c.real from (
      select
        public.rrule_timed_occurrence_count(r.rule, false, v_s, v_e, 'UTC', v_from, v_to) as n,
        (select count(*) from public.rrule_timed_occurrence_starts(
           r.rule, false, v_s, v_e, 'UTC', v_from, v_to))                                 as real
      from (values
        ('FREQ=DAILY;COUNT=10'),
        ('FREQ=DAILY;INTERVAL=3;COUNT=5'),
        ('FREQ=WEEKLY;BYDAY=MO,FR;COUNT=3'),
        ('FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;COUNT=5'),
        ('FREQ=DAILY;COUNT=1')
      ) as r(rule)
    ) c
  loop
    assert v_n is not null, '5.1 a timed COUNT master in the subset must never count NULL';
    assert v_n >= v_real,
      format('5.1 the count (%s) UNDERCOUNTS the %s occurrences emitted', v_n, v_real);
  end loop;

  -- 5.2 The flip: no longer NULL.
  v_n := public.rrule_timed_occurrence_count(
           'FREQ=DAILY;COUNT=3', false, v_s, v_e, 'UTC', v_from, v_to);
  assert v_n = 3, format('5.2 expected 3, got %s', coalesce(v_n::text, 'null'));

  -- 5.3 ZERO for a series exhausted before the window.
  v_n := public.rrule_timed_occurrence_count(
           'FREQ=DAILY;COUNT=3', false,
           timestamptz '2020-01-01 09:00:00+00', timestamptz '2020-01-01 10:00:00+00',
           'UTC', v_from, v_to);
  assert v_n is not null,
    '5.3 an exhausted timed COUNT series must count 0, not NULL';
  assert v_n = 0, format('5.3 expected 0, got %s', v_n);

  -- 5.4 Monotonic in COUNT: it can only lower the bound, so it can never push a
  --     master over the cap.
  assert public.rrule_timed_occurrence_count(
           'FREQ=DAILY;COUNT=5', false, v_s, v_e, 'UTC', v_from, v_to)
         <= public.rrule_timed_occurrence_count(
           'FREQ=DAILY', false, v_s, v_e, 'UTC', v_from, v_to),
    '5.4 a COUNT series can never count more than the same rule without COUNT';

  -- 5.5 NULL outside the subset, and NULL on zone drift -- never 0.
  assert public.rrule_timed_occurrence_count(
           'FREQ=MONTHLY;COUNT=4', false, v_s, v_e, 'UTC', v_from, v_to) is null,
    '5.5 MONTHLY+COUNT must count NULL';
  assert public.rrule_timed_occurrence_count(
           'FREQ=DAILY;COUNT=5', true, v_s, v_e, 'UTC', v_from, v_to) is null,
    '5.5 an all-day row must count NULL on the timed helper';
  assert public.rrule_timed_occurrence_count(
           'FREQ=DAILY;COUNT=5', false, v_s, v_e, null, v_from, v_to) is null,
    '5.5 a NULL zone must count NULL (M0 stays fail-closed)';
  assert public.rrule_timed_occurrence_count(
           'FREQ=DAILY;COUNT=5', false, v_s, v_e, 'Nowhere/Nothing', v_from, v_to) is null,
    '5.5 an unresolvable zone must count NULL';
  assert public.rrule_timed_occurrence_count(
           'FREQ=DAILY;COUNT=5', false, null, v_e, 'UTC', v_from, v_to) is null,
    '5.5 a NULL instant must count NULL, not raise';

  -- 5.6 The zone is read for the CALENDAR, so a COUNT series anchored near
  --     midnight lands on different local days in different zones -- and the
  --     ordinal follows the local day, not UTC. 2026-06-01 22:00Z is already
  --     2026-06-02 07:00 in Tokyo, a Tuesday.
  assert (select count(*) from public.rrule_timed_occurrence_starts(
            'FREQ=WEEKLY;BYDAY=TU;COUNT=3', false,
            timestamptz '2026-06-01 22:00:00+00', timestamptz '2026-06-01 23:00:00+00',
            'Asia/Tokyo',
            timestamptz '2026-06-01 00:00:00+00', timestamptz '2026-07-01 00:00:00+00')) = 3,
    '5.6 BYDAY=TU must match the Tokyo weekday of a 22:00Z DTSTART';

  raise notice 'Section 5 OK';
end $$;

-- ============================================================================
-- SECTION 6 -- get_free_busy end to end. This is where COUNT stops being an
-- arithmetic exercise and becomes an answer the share link actually returns.
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

  -- June window, for the ordinal cases. Both the date pair and the instant pair
  -- are required by get_free_busy, whichever path a fixture uses.
  v_jf  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_jt  constant timestamptz := timestamptz '2026-06-20 00:00:00+00';
  v_jfd constant date := date '2026-06-01';
  v_jtd constant date := date '2026-06-20';

  -- Autumn window, containing the 2026-11-01 06:00Z transition.
  v_af  constant timestamptz := timestamptz '2026-10-29 00:00:00+00';
  v_at  constant timestamptz := timestamptz '2026-11-05 00:00:00+00';
  v_afd constant date := date '2026-10-29';
  v_atd constant date := date '2026-11-05';

  v_run     constant text := gen_random_uuid()::text;
  v_tok_ok  constant text := 'tw5b5b-test-active-' || v_run;
  v_link_ok constant uuid := gen_random_uuid();

  v_m constant uuid := gen_random_uuid();   -- master fixture
  v_x constant uuid := gen_random_uuid();   -- exception fixture
  v_res    jsonb;
  v_exists boolean;
begin
  raise notice 'Section 6: get_free_busy with COUNT';

  assert v_owner <> '00000000-0000-0000-0000-000000000000'::uuid,
    '6.0.0 set v_owner to a dedicated test user id first';
  select exists(select 1 from auth.users u where u.id = v_owner) into v_exists;
  assert v_exists,
    '6.0.1 v_owner does not exist in auth.users. Create the test user through '
    'the normal Auth path; this suite never inserts into auth.users.';
  assert not exists (select 1 from public.events e where e.owner_id = v_owner),
    '6.0.2 test owner must have no pre-existing events. Point v_owner at a '
    'dedicated test user. Do NOT delete events to satisfy this assertion.';

  insert into public.share_links (id, owner_id, token_hash, label, include_private,
                                  expires_at, revoked_at)
  values (v_link_ok, v_owner,
          encode(extensions.digest(v_tok_ok, 'sha256'), 'hex'),
          'tw5b5b active', true, null, null);

  v_res := public.get_free_busy(v_tok_ok, v_jf, v_jt, v_jfd, v_jtd);
  assert v_res = '{"complete": true, "slots": []}'::jsonb,
    '6.0.3 empty test owner baseline, got ' || v_res::text;

  -- =====================================================================
  -- 6.1 AN ALL-DAY COUNT MASTER IS EXPANDED. Before 0010 this reported
  --     complete=false with no slots; 5b-5B is the step that flips it.
  --     Three consecutive one-day occurrences merge into a single span, which
  --     also proves the series STOPS: the span ends on 06-04, not at the far
  --     edge of the window.
  -- =====================================================================
  insert into public.events (id, owner_id, title, visibility, all_day,
                             start_date, end_date, rrule)
  values (v_m, v_owner, '', 'busy_only', true,
          date '2026-06-01', date '2026-06-02', 'FREQ=DAILY;COUNT=3');

  v_res := public.get_free_busy(v_tok_ok, v_jf, v_jt, v_jfd, v_jtd);
  assert (v_res->>'complete')::boolean = true,
    '6.1 an all-day COUNT master must now be complete, got ' || v_res::text;
  assert jsonb_array_length(v_res->'slots') = 1,
    format('6.1 three adjacent all-day occurrences merge into one span, got %s',
           jsonb_array_length(v_res->'slots'));
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', true,
           'start_date', to_jsonb(date '2026-06-01'),
           'end_date',   to_jsonb(date '2026-06-04')),
    '6.1 the merged span must END at 2026-06-04; a series that did not stop '
    'would run to the window edge. Got ' || (v_res->'slots'->0)::text;

  -- =====================================================================
  -- 6.2 THE PARTIAL WEEK 0, end to end. BYDAY=MO,WE,FR;COUNT=7 from a
  --     Wednesday -- the section 2.5 / TS A7 case, now through the RPC.
  --     None of the seven one-day occurrences are adjacent, so none merge.
  -- =====================================================================
  update public.events
     set start_date = date '2026-06-03',
         end_date   = date '2026-06-04',
         rrule      = 'FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=7'
   where id = v_m;

  v_res := public.get_free_busy(v_tok_ok, v_jf, v_jt, v_jfd, v_jtd);
  assert (v_res->>'complete')::boolean = true, '6.2 complete';
  assert jsonb_array_length(v_res->'slots') = 7,
    format('6.2 expected 7 slots, got %s -- a full week 0 would give 8 and stop '
           'on the Friday', jsonb_array_length(v_res->'slots'));
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', true,
           'start_date', to_jsonb(date '2026-06-03'),
           'end_date',   to_jsonb(date '2026-06-04')), '6.2 first slot is the Wednesday';
  assert v_res->'slots'->6 = jsonb_build_object(
           'all_day', true,
           'start_date', to_jsonb(date '2026-06-17'),
           'end_date',   to_jsonb(date '2026-06-18')),
    '6.2 the 7th and last occurrence is Wednesday 2026-06-17, not the Friday';

  -- =====================================================================
  -- 6.3 AN EXCEPTION STILL DETACHES A COUNT-GENERATED OCCURRENCE. The slot
  --     key is a date either way; COUNT changes which slots exist, not how
  --     they are addressed. The anti-join has no visibility filter, so a
  --     cancelled exception removes the occurrence outright.
  -- =====================================================================
  insert into public.events (id, owner_id, title, visibility, all_day,
                             start_date, end_date,
                             recurrence_id, recurrence_slot_date, is_cancelled)
  values (v_x, v_owner, '', 'busy_only', true,
          date '2026-06-10', date '2026-06-11',
          v_m, date '2026-06-10', true);

  v_res := public.get_free_busy(v_tok_ok, v_jf, v_jt, v_jfd, v_jtd);
  assert (v_res->>'complete')::boolean = true,
    '6.3 a cancelled exception on a COUNT series must not force incomplete';
  assert jsonb_array_length(v_res->'slots') = 6,
    format('6.3 the 2026-06-10 occurrence must be detached, leaving 6, got %s',
           jsonb_array_length(v_res->'slots'));
  assert not exists (
    select 1 from jsonb_array_elements(v_res->'slots') s
    where s->>'start_date' = '2026-06-10'
  ), '6.3 the cancelled slot must be gone';

  delete from public.events where id = v_x;

  -- =====================================================================
  -- 6.4 A COUNT SERIES THAT ENDED LONG BEFORE THE WINDOW.
  --
  --     THIS IS THE HEADLINE RESULT OF 5b-5B. rrule_definitely_ends_before
  --     cannot prove a COUNT series ends -- it tests until_date/until_ts --
  --     so before 0010 this master reached branch (A), failed the subset,
  --     and forced complete=false for a series that could not possibly
  --     contribute. Now it is EXPANDED, the tightened hi falls below lo, the
  --     count is an ordinary 0, and the answer is complete with no slots.
  -- =====================================================================
  update public.events
     set start_date = date '2020-01-01',
         end_date   = date '2020-01-02',
         rrule      = 'FREQ=DAILY;COUNT=3'
   where id = v_m;

  v_res := public.get_free_busy(v_tok_ok, v_jf, v_jt, v_jfd, v_jtd);
  assert v_res = '{"complete": true, "slots": []}'::jsonb,
    '6.4 an exhausted COUNT series must report complete=true with no slots, got '
    || v_res::text;

  delete from public.events where id = v_m;

  -- =====================================================================
  -- 6.5 A TIMED COUNT MASTER, ACROSS THE AUTUMN FOLD. The section 4.4 /
  --     TS A12 case, through the RPC. Five occurrences, one of which lands on
  --     the ambiguous 01:30 and resolves to the LATER instant.
  -- =====================================================================
  insert into public.events (id, owner_id, title, visibility, all_day,
                             start_at, end_at, rrule, timezone)
  values (v_m, v_owner, '', 'busy_only', false,
          timestamptz '2026-10-30 05:30:00+00', timestamptz '2026-10-30 06:30:00+00',
          'FREQ=DAILY;COUNT=5', v_ny);

  v_res := public.get_free_busy(v_tok_ok, v_af, v_at, v_afd, v_atd);
  assert (v_res->>'complete')::boolean = true,
    '6.5 a timed COUNT master must now be complete, got ' || v_res::text;
  assert jsonb_array_length(v_res->'slots') = 5,
    format('6.5 expected 5 slots, got %s', jsonb_array_length(v_res->'slots'));
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-10-30 05:30:00+00'),
           'end',   to_jsonb(timestamptz '2026-10-30 06:30:00+00')),
    '6.5 DTSTART is emitted verbatim, not reconstructed';
  assert v_res->'slots'->2 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-11-01 06:30:00+00'),
           'end',   to_jsonb(timestamptz '2026-11-01 07:30:00+00')),
    '6.5 the fold occurrence resolves to the LATER instant';
  assert v_res->'slots'->4 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-11-03 06:30:00+00'),
           'end',   to_jsonb(timestamptz '2026-11-03 07:30:00+00')),
    '6.5 the 5th occurrence is the last; a 6th would mean COUNT was ignored';

  -- 6.6 The same master viewed AFTER its series ends: complete, no slots.
  v_res := public.get_free_busy(
             v_tok_ok,
             timestamptz '2027-01-01 00:00:00+00', timestamptz '2027-02-01 00:00:00+00',
             date '2027-01-01', date '2027-02-01');
  assert v_res = '{"complete": true, "slots": []}'::jsonb,
    '6.6 a timed COUNT series is complete and empty after it ends, got ' || v_res::text;

  -- =====================================================================
  -- 6.7 MONTHLY WITH COUNT STILL FORCES complete=false. 0010 removed only
  --     `count_n is null`; the freq test is untouched, so MONTHLY is exactly
  --     as unsupported as it was, with COUNT and without.
  -- =====================================================================
  update public.events set rrule = 'FREQ=MONTHLY;COUNT=4' where id = v_m;
  v_res := public.get_free_busy(v_tok_ok, v_af, v_at, v_afd, v_atd);
  assert (v_res->>'complete')::boolean = false,
    '6.7 MONTHLY+COUNT must still force complete=false, got ' || v_res::text;

  update public.events set rrule = 'FREQ=MONTHLY' where id = v_m;
  v_res := public.get_free_busy(v_tok_ok, v_af, v_at, v_afd, v_atd);
  assert (v_res->>'complete')::boolean = false,
    '6.7 plain MONTHLY must still force complete=false';

  delete from public.events where id = v_m;

  v_res := public.get_free_busy(v_tok_ok, v_jf, v_jt, v_jfd, v_jtd);
  assert v_res = '{"complete": true, "slots": []}'::jsonb,
    '6.8 the owner is empty again at the end of section 6, got ' || v_res::text;

  raise notice 'Section 6 OK';
end $$;

-- ============================================================================
-- SECTION 7 -- regressions 0010 must not cause, and the fail-closed paths COUNT
-- must not open.
--
-- 7.4 builds a master whose zone this server cannot resolve, which the 0008
-- trigger forbids. events_validate_timezone is disabled for the length of ONE
-- insert and re-enabled on the very next statement. ALTER TABLE ... DISABLE
-- TRIGGER is transactional, so the final ROLLBACK restores it even if an
-- assertion aborts the run midway.
-- ============================================================================
do $$
declare
  v_fromd constant date := date '2026-05-01';
  v_tod   constant date := date '2026-08-01';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-07-01 00:00:00+00';
  v_s     constant timestamptz := timestamptz '2026-06-01 09:00:00+00';
  v_e     constant timestamptz := timestamptz '2026-06-01 10:00:00+00';
  v_got   date[];
  v_gott  timestamptz[];
begin
  raise notice 'Section 7: regressions';

  -- 7.1 The 5b-1 all-day behaviour, with no COUNT anywhere. Identical to what
  --     0007 produced.
  select array_agg(d order by d) into v_got
  from public.rrule_allday_occurrence_starts(
    'FREQ=WEEKLY;BYDAY=MO,WE,FR', true,
    date '2026-06-03', date '2026-06-04',
    date '2026-06-01', date '2026-06-15') d;
  assert v_got = array[date '2026-06-03', date '2026-06-05',
                       date '2026-06-08', date '2026-06-10', date '2026-06-12'],
    format('7.1 a WEEKLY series without COUNT must be unchanged -> %s',
           coalesce(v_got::text, 'null'));

  -- 7.2 UNTIL still works, and is still INCLUSIVE on the occurrence start. The
  --     COUNT bound sits beside the UNTIL bound and neither may disturb the
  --     other -- they can never both apply, because COUNT+UNTIL is malformed.
  select array_agg(d order by d) into v_got
  from public.rrule_allday_occurrence_starts(
    'FREQ=DAILY;UNTIL=20260605', true,
    date '2026-06-01', date '2026-06-02', v_fromd, v_tod) d;
  assert v_got = array[date '2026-06-01', date '2026-06-02', date '2026-06-03',
                       date '2026-06-04', date '2026-06-05'],
    format('7.2 all-day UNTIL is inclusive -> %s', coalesce(v_got::text, 'null'));

  -- (TS A16) the timed side of the same.
  select array_agg(t order by t) into v_gott
  from public.rrule_timed_occurrence_starts(
    'FREQ=DAILY;UNTIL=20260605T235959Z', false, v_s, v_e, 'UTC', v_from, v_to) t;
  assert array_length(v_gott, 1) = 5,
    format('7.2 A16 timed UNTIL expected 5, got %s',
           coalesce(array_length(v_gott, 1), 0));
  assert v_gott[5] = timestamptz '2026-06-05 09:00:00+00', '7.2 A16 last occurrence';

  -- 7.3 An infinite series is still infinite. COUNT must not have leaked a
  --     bound into rules that do not carry one.
  assert (select count(*) from public.rrule_allday_occurrence_starts(
            'FREQ=DAILY', true, date '2026-06-01', date '2026-06-02',
            date '2026-06-01', date '2026-06-11')) = 10,
    '7.3 a rule without COUNT must fill the whole window';
  assert (select count(*) from public.rrule_allday_occurrence_starts(
            'FREQ=DAILY', true, date '2026-06-01', date '2026-06-02',
            date '2030-06-01', date '2030-06-11')) = 10,
    '7.3 and must still do so years later';

  -- 7.4 0006/0007/0009 helpers 0010 did not replace are untouched.
  assert public.rrule_allday_expansion_cap() = 5000, '7.4 all-day cap unchanged';
  assert public.rrule_timed_expansion_cap() = 5000,  '7.4 timed cap unchanged';
  assert public.timezone_is_supported('Asia/Tokyo'),  '7.4 timezone_is_supported unchanged';
  assert not public.timezone_is_supported('JST'),     '7.4 timezone_is_supported unchanged';
  assert public.timezone_is_resolvable('UTC'),        '7.4 timezone_is_resolvable unchanged';
  assert not public.timezone_is_resolvable('posix/Asia/Tokyo'),
    '7.4 timezone_is_resolvable unchanged';

  -- rrule_definitely_ends_before still cannot prove a COUNT series ends. 0010
  -- reaches COUNT by EXPANDING it, and the two must not start overlapping.
  assert not public.rrule_definitely_ends_before(
           'FREQ=DAILY;COUNT=3', true,
           date '2020-01-01', date '2020-01-02', null, null,
           null, date '2026-01-01'),
    '7.4 rrule_definitely_ends_before must still not prove a COUNT series ends';
  assert public.rrule_definitely_ends_before(
           'FREQ=DAILY;UNTIL=20200105', true,
           date '2020-01-01', date '2020-01-02', null, null,
           null, date '2026-01-01'),
    '7.4 rrule_definitely_ends_before must still prove an UNTIL series ends';

  raise notice 'Section 7 OK';
end $$;

-- ============================================================================
-- SECTION 8 -- the fail-closed fixture the 0008 trigger forbids.
--
-- A timed COUNT master whose zone this server cannot resolve. COUNT must not
-- turn an unusable zone into an expandable series: the answer stays
-- complete=false with no slots, and nothing raises.
-- ============================================================================
do $$
declare
  ------------------------------------------------------------------ SET THIS
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';  -- <<< EDIT per project
  --------------------------------------------------------------------------
  v_run     constant text := gen_random_uuid()::text;
  v_tok     constant text := 'tw5b5b-test-badzone-' || v_run;
  v_link    constant uuid := gen_random_uuid();
  v_m       constant uuid := gen_random_uuid();
  v_from constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to   constant timestamptz := timestamptz '2026-07-01 00:00:00+00';
  v_res  jsonb;
  v_tg   "char";
begin
  raise notice 'Section 8: an unresolvable zone stays fail-closed with COUNT';

  assert not exists (select 1 from public.events e where e.owner_id = v_owner),
    '8.0 section 6 must have cleaned up after itself';

  insert into public.share_links (id, owner_id, token_hash, label, include_private,
                                  expires_at, revoked_at)
  values (v_link, v_owner, encode(extensions.digest(v_tok, 'sha256'), 'hex'),
          'tw5b5b badzone', true, null, null);

  -- The trigger window: ONE insert, re-enabled on the very next statement.
  alter table public.events disable trigger events_validate_timezone;

  insert into public.events (id, owner_id, title, visibility, all_day,
                             start_at, end_at, rrule, timezone)
  values (v_m, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-01 09:00:00+00', timestamptz '2026-06-01 10:00:00+00',
          'FREQ=DAILY;COUNT=5', 'Nowhere/Nothing');

  alter table public.events enable trigger events_validate_timezone;

  select t.tgenabled into v_tg
  from pg_catalog.pg_trigger t
  where t.tgrelid = 'public.events'::regclass
    and t.tgname = 'events_validate_timezone'
    and not t.tgisinternal;
  assert v_tg = 'O',
    format('8.1 the trigger must be re-enabled immediately, tgenabled=%s', v_tg);

  -- The RPC must not raise, must not expand, and must say so.
  v_res := public.get_free_busy(v_tok, v_from, v_to, date '2026-06-01', date '2026-07-01');
  assert (v_res->>'complete')::boolean = false,
    '8.2 an unresolvable zone must force complete=false even with COUNT, got '
    || v_res::text;
  assert jsonb_array_length(v_res->'slots') = 0,
    format('8.2 and must contribute no slots, got %s',
           jsonb_array_length(v_res->'slots'));

  -- A legacy M0 master (timezone IS NULL) is the same story.
  alter table public.events disable trigger events_validate_timezone;
  update public.events set timezone = null where id = v_m;
  alter table public.events enable trigger events_validate_timezone;

  select t.tgenabled into v_tg
  from pg_catalog.pg_trigger t
  where t.tgrelid = 'public.events'::regclass
    and t.tgname = 'events_validate_timezone'
    and not t.tgisinternal;
  assert v_tg = 'O',
    format('8.3 the trigger must be re-enabled immediately, tgenabled=%s', v_tg);

  v_res := public.get_free_busy(v_tok, v_from, v_to, date '2026-06-01', date '2026-07-01');
  assert (v_res->>'complete')::boolean = false,
    '8.4 a legacy M0 master must still force complete=false with COUNT, got '
    || v_res::text;
  assert jsonb_array_length(v_res->'slots') = 0,
    '8.4 and must contribute no slots';

  delete from public.events where id = v_m;

  raise notice 'Section 8 OK';
end $$;

-- ============================================================================
-- SECTION 9 -- catalog: signatures, argument names, security attributes, ACLs.
--
-- 0010 replaces six functions in place and creates nothing. The check that
-- matters most is the OVERLOAD COUNT: a drifted argument type list would have
-- made CREATE OR REPLACE create a second function rather than replace, leaving
-- get_free_busy bound to the old fail-closed body while the migration reported
-- success.
--
-- The postflight covers the same ground; it is repeated here so the suite is
-- self-contained and so a later migration cannot quietly undo it.
-- ============================================================================
do $$
declare
  v_name   text;
  v_cnt    integer;
  v_secdef boolean;
  v_vol    "char";
  v_cfg    text[];
  v_acl    text;
  v_names  text[];
  v_anon   oid;
  v_auth   oid;
  v_has    boolean;
begin
  raise notice 'Section 9: catalog, security and ACLs';

  -- ACLs are read through aclexplode rather than by matching the printed
  -- aclitem[] text: a substring search cannot tell EXECUTE from any other
  -- privilege, and it cannot see the PUBLIC grant at all, which is written as
  -- an entry with an empty grantee (oid 0).
  select r.oid into v_anon from pg_catalog.pg_roles r where r.rolname = 'anon';
  select r.oid into v_auth from pg_catalog.pg_roles r where r.rolname = 'authenticated';
  assert v_anon is not null and v_auth is not null,
    '9.0 roles anon and authenticated must exist for these assertions to mean anything';

  foreach v_name in array array[
    'rrule_sql_subset',
    'rrule_timed_sql_subset',
    'rrule_allday_occurrence_count',
    'rrule_timed_occurrence_count',
    'rrule_allday_occurrence_starts',
    'rrule_timed_occurrence_starts'
  ]
  loop
    select count(*) into v_cnt
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_name;

    assert v_cnt = 1,
      format('9.1 expected exactly one public.%s, found %s. If this is 2, 0010 '
             'created an OVERLOAD and the old body is still reachable.',
             v_name, v_cnt);

    select p.prosecdef, p.provolatile, p.proconfig, p.proacl::text
      into v_secdef, v_vol, v_cfg, v_acl
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_name;

    -- CREATE OR REPLACE resets any attribute the new definition omits. 0010
    -- restates all three; these assertions are what proves it did.
    assert v_vol = 's',
      format('9.2 public.%s must stay STABLE, provolatile=%s', v_name, v_vol);
    assert v_secdef = false,
      format('9.3 public.%s must stay SECURITY INVOKER', v_name);
    assert exists (select 1 from unnest(coalesce(v_cfg, array[]::text[])) c
                   where c like 'search_path=%'),
      format('9.4 public.%s must pin search_path, proconfig=%s',
             v_name, coalesce(array_to_string(v_cfg, ', '), 'null'));

    -- 0010 issues no GRANT and no REVOKE; CREATE OR REPLACE preserves
    -- privileges, so the 0006/0007/0009 REVOKEs must still hold.
    assert v_acl is not null,
      format('9.5 public.%s has a NULL proacl, so the default PUBLIC grant is '
             'back; CREATE OR REPLACE did not preserve privileges', v_name);

    select exists (
      select 1
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace,
      lateral pg_catalog.aclexplode(p.proacl) a
      where n.nspname = 'public' and p.proname = v_name
        and a.privilege_type = 'EXECUTE'
        and a.grantee in (0, v_anon, v_auth)      -- 0 = PUBLIC
    ) into v_has;
    assert not v_has,
      format('9.6 public.%s must stay internal-only, acl = %s', v_name, v_acl);
  end loop;

  -- 9.7 get_free_busy is untouched, and is still the only function anon reaches.
  select count(*) into v_cnt
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_free_busy';
  assert v_cnt = 1, format('9.7 expected exactly one get_free_busy, found %s', v_cnt);

  select p.proargnames, p.prosecdef, p.proconfig, p.proacl::text
    into v_names, v_secdef, v_cfg, v_acl
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_free_busy';

  -- Argument NAMES are the PostgREST wire contract.
  assert v_names = array['p_token', 'p_from', 'p_to',
                         'p_from_date', 'p_to_date']::text[],
    format('9.7 get_free_busy argument names changed: %s',
           coalesce(array_to_string(v_names, ', '), 'null'));
  assert v_secdef, '9.7 get_free_busy must stay SECURITY DEFINER';
  assert exists (select 1 from unnest(coalesce(v_cfg, array[]::text[])) c
                 where c like 'search_path=%'),
    '9.7 get_free_busy must keep its pinned search_path';

  select exists (
    select 1
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace,
    lateral pg_catalog.aclexplode(p.proacl) a
    where n.nspname = 'public' and p.proname = 'get_free_busy'
      and a.privilege_type = 'EXECUTE' and a.grantee = v_anon
  ) into v_has;
  assert v_has, format('9.8 anon must keep EXECUTE on get_free_busy: %s', v_acl);

  select exists (
    select 1
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace,
    lateral pg_catalog.aclexplode(p.proacl) a
    where n.nspname = 'public' and p.proname = 'get_free_busy'
      and a.privilege_type = 'EXECUTE' and a.grantee = 0      -- 0 = PUBLIC
  ) into v_has;
  assert not v_has,
    format('9.9 PUBLIC must not have EXECUTE on get_free_busy: %s', v_acl);

  raise notice 'Section 9 OK';
end $$;

do $$
begin
  raise notice '0010 TEST SUITE PASSED -- rolling back, no fixtures remain.';
end $$;

rollback;
