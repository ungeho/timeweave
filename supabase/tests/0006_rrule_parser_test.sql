-- TimeWeave Phase 5b-0 test suite for 0006_rrule_parser.sql.
--
-- NOT A MIGRATION. Run this by hand (Supabase SQL editor or psql) against a
-- DEVELOPMENT project after applying 0006. It is wrapped in a transaction and
-- ends with ROLLBACK, so it leaves no fixtures behind.
--
-- !! RUN THE WHOLE FILE, INCLUDING THE FINAL ROLLBACK. !!
--
-- A failing `assert` raises and aborts the transaction; every statement after it
-- reports "current transaction is aborted" until the final ROLLBACK. So read the
-- FIRST error message -- that is the real failure. Fix, then re-run from the top.
--
-- Section 4 needs a DEDICATED TEST USER that owns no events; see its header. It
-- never inserts into auth.users and never deletes or updates a row it did not
-- itself insert.
--
-- Preflight: 0006 assumes pgcrypto lives in the `extensions` schema (Supabase
-- default) and section 4 calls extensions.digest() directly. Confirm with:
--   select extnamespace::regnamespace from pg_extension where extname='pgcrypto';
-- If it reports `public`, replace `extensions.digest` with `public.digest` below.

begin;

-- ============================================================================
-- SECTION 1.0 -- rrule_parse CONTRACT: exactly one row, always.
--
-- rrule_parse is declared `returns table`, so a code path that forgets
-- `return next` would yield ZERO rows. Callers wrap it in
-- `coalesce((select ... from rrule_parse(...)), false)`, so an empty result
-- degrades safely to "cannot prove" -- but it would silently disable the
-- narrowing for a whole class of rules. This section pins the contract.
--
-- It also guards against someone later declaring the function STRICT as an
-- "optimisation": a STRICT function returns no rows for a NULL argument, which
-- 1.0.4 catches immediately.
-- ============================================================================
do $$
declare
  v_inputs constant text[] := array[
    -- ok
    'FREQ=DAILY', 'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE', 'FREQ=MONTHLY',
    'FREQ=DAILY;COUNT=5', 'FREQ=DAILY;UNTIL=20260805',
    'FREQ=DAILY;UNTIL=20260805T120000Z', '  freq=daily ; interval=3  ', 'FREQ=DAILY;;',
    -- malformed
    '', 'INTERVAL=2', 'FREQ', 'FREQ=DAILY;FREQ=WEEKLY', 'FREQ=DAILY;INTERVAL=0',
    'FREQ=DAILY;INTERVAL=abc', 'FREQ=WEEKLY;BYDAY=MO,MO', 'FREQ=WEEKLY;BYDAY=',
    'FREQ=DAILY;COUNT=2;UNTIL=20260101T000000Z', 'FREQ=DAILY;UNTIL=2026-08-05',
    'FREQ=DAILY;UNTIL=20260805T120000', 'FREQ=DAILY;UNTIL=20260231',
    'FREQ=DAILY;UNTIL=20261301', 'FREQ=DAILY;UNTIL=20260805T250000Z',
    -- unsupported
    'FREQ=YEARLY', 'FREQ=HOURLY', 'FREQ=MONTHLY;BYMONTHDAY=1', 'FREQ=DAILY;WKST=MO',
    'FREQ=DAILY;NOPE=1', 'FREQ=WEEKLY;BYDAY=2MO', 'FREQ=WEEKLY;BYDAY=-1FR',
    'FREQ=DAILY;BYDAY=MO',
    -- NULL (kept last so the label reads clearly)
    null
  ];
  v_in     text;
  v_n      bigint;
  v_st     text;
  v_reason text;
begin
  raise notice 'Section 1.0: rrule_parse contract';

  foreach v_in in array v_inputs
  loop
    select count(*) into v_n from public.rrule_parse(v_in);
    assert v_n = 1,
      '1.0.1 rrule_parse must return exactly one row for input: ' || coalesce(v_in, '<NULL>');

    select p.status, p.reason into v_st, v_reason from public.rrule_parse(v_in) p;

    assert v_st is not null,
      '1.0.2 status must never be NULL for input: ' || coalesce(v_in, '<NULL>');
    assert v_st in ('ok', 'unsupported', 'malformed'),
      '1.0.3 status must be one of ok/unsupported/malformed, got ' || v_st ||
      ' for input: ' || coalesce(v_in, '<NULL>');
    assert v_reason is not null,
      '1.0.3b reason must never be NULL for input: ' || coalesce(v_in, '<NULL>');
  end loop;

  -- Explicit NULL case, called out separately from the loop.
  select count(*) into v_n from public.rrule_parse(null);
  assert v_n = 1, '1.0.4 NULL input must still yield one row (function must NOT be STRICT)';

  select p.status, p.reason into v_st, v_reason from public.rrule_parse(null) p;
  assert v_st = 'malformed',        '1.0.5 NULL input status';
  assert v_reason = 'null_rrule',   '1.0.5b NULL input reason';

  raise notice 'Section 1.0 OK';
end $$;

-- ============================================================================
-- SECTION 1 -- rrule_parse: SYNTAX ONLY, no event context.
-- ============================================================================
do $$
declare r record;
begin
  raise notice 'Section 1: rrule_parse';

  ---------------------------------------------------------------- ok
  select * into r from public.rrule_parse('FREQ=DAILY');
  assert r.status = 'ok',        '1.1 FREQ=DAILY status';
  assert r.freq = 'DAILY',       '1.1 freq';
  assert r.interval_n = 1,       '1.1 INTERVAL defaults to 1';
  assert r.byday is null,        '1.1 byday null';
  assert r.count_n is null,      '1.1 count null';
  assert r.until_date is null,   '1.1 until_date null';
  assert r.until_ts is null,     '1.1 until_ts null';

  select * into r from public.rrule_parse('FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE');
  assert r.status = 'ok',            '1.2 status';
  assert r.freq = 'WEEKLY',          '1.2 freq';
  assert r.interval_n = 2,           '1.2 interval';
  assert r.byday = array['MO','WE'], '1.2 byday order preserved';

  -- Case-insensitive keys/values and surrounding whitespace, as in the TS parser.
  select * into r from public.rrule_parse('  freq=daily ; interval=3  ');
  assert r.status = 'ok',    '1.3 lowercase + whitespace status';
  assert r.freq = 'DAILY',   '1.3 freq upper-cased';
  assert r.interval_n = 3,   '1.3 interval';

  -- Empty segments are ignored (TS: .filter(p => p.length > 0)).
  select * into r from public.rrule_parse('FREQ=DAILY;;');
  assert r.status = 'ok', '1.4 empty segment ignored';

  ------------------------------------- MONTHLY / COUNT are IN the vocabulary
  -- These parse ok and are structured. Excluding them is a SUBSET decision
  -- made downstream by rrule_sql_subset, not a parsing failure.
  select * into r from public.rrule_parse('FREQ=MONTHLY');
  assert r.status = 'ok',    '1.5 MONTHLY parses ok (vocabulary, not subset)';
  assert r.freq = 'MONTHLY', '1.5 freq';

  select * into r from public.rrule_parse('FREQ=DAILY;COUNT=5');
  assert r.status = 'ok', '1.6 COUNT parses ok (vocabulary, not subset)';
  assert r.count_n = 5,   '1.6 count_n';

  ---------------------------------------------------------- UNTIL: DATE form
  select * into r from public.rrule_parse('FREQ=DAILY;UNTIL=20260805');
  assert r.status = 'ok',                   '1.7 DATE UNTIL status';
  assert r.until_date = date '2026-08-05',  '1.7 until_date';
  assert r.until_ts is null,                '1.7 until_ts stays null';

  ------------------------------------------------------- UNTIL: instant form
  select * into r from public.rrule_parse('FREQ=DAILY;UNTIL=20260805T120000Z');
  assert r.status = 'ok',                                    '1.8 instant UNTIL status';
  assert r.until_ts = timestamptz '2026-08-05 12:00:00+00',  '1.8 until_ts';
  assert r.until_date is null,                               '1.8 until_date stays null';

  ---------------------------------------------------------------- malformed
  select * into r from public.rrule_parse(null);
  assert r.status = 'malformed' and r.reason = 'null_rrule', '1.9 null input';

  select * into r from public.rrule_parse('');
  assert r.status = 'malformed' and r.reason = 'missing_freq', '1.10 empty string';

  select * into r from public.rrule_parse('INTERVAL=2');
  assert r.status = 'malformed' and r.reason = 'missing_freq', '1.11 no FREQ';

  select * into r from public.rrule_parse('FREQ');
  assert r.status = 'malformed' and r.reason = 'segment_without_eq', '1.12 segment without =';

  select * into r from public.rrule_parse('FREQ=DAILY;FREQ=WEEKLY');
  assert r.status = 'malformed' and r.reason = 'duplicate_key:FREQ', '1.13 duplicate key';

  select * into r from public.rrule_parse('FREQ=DAILY;INTERVAL=0');
  assert r.status = 'malformed' and r.reason = 'invalid_interval', '1.14 INTERVAL=0';

  select * into r from public.rrule_parse('FREQ=DAILY;INTERVAL=abc');
  assert r.status = 'malformed' and r.reason = 'invalid_interval', '1.15 non-numeric INTERVAL';

  -- duplicate BYDAY token: STRICTER THAN TS on purpose (TS would emit twice).
  select * into r from public.rrule_parse('FREQ=WEEKLY;BYDAY=MO,MO');
  assert r.status = 'malformed' and r.reason = 'duplicate_byday:MO', '1.16 duplicate BYDAY';

  select * into r from public.rrule_parse('FREQ=WEEKLY;BYDAY=');
  assert r.status = 'malformed' and r.reason = 'empty_byday', '1.17 empty BYDAY';

  -- COUNT + UNTIL together. Mirrors services/recurrence.ts:96 (TS throws too).
  select * into r from public.rrule_parse('FREQ=DAILY;COUNT=2;UNTIL=20260101T000000Z');
  assert r.status = 'malformed' and r.reason = 'count_and_until', '1.18 COUNT + UNTIL';

  select * into r from public.rrule_parse('FREQ=DAILY;UNTIL=2026-08-05');
  assert r.status = 'malformed' and r.reason = 'invalid_until_format', '1.19 dashed UNTIL';

  -- Floating date-time (no trailing Z) is rejected, as in TS parseUntil.
  select * into r from public.rrule_parse('FREQ=DAILY;UNTIL=20260805T120000');
  assert r.status = 'malformed' and r.reason = 'invalid_until_format', '1.20 UNTIL without Z';

  ----------------------------------------------------- invalid calendar date
  -- to_date() would silently roll 20260231 forward into March, pushing UNTIL
  -- LATER than written. The explicit ISO cast raises, so we reject instead.
  select * into r from public.rrule_parse('FREQ=DAILY;UNTIL=20260231');
  assert r.status = 'malformed' and r.reason = 'invalid_until_date', '1.21 Feb 31';

  select * into r from public.rrule_parse('FREQ=DAILY;UNTIL=20260229');
  assert r.status = 'malformed' and r.reason = 'invalid_until_date', '1.22 Feb 29 common year';

  select * into r from public.rrule_parse('FREQ=DAILY;UNTIL=20240229');
  assert r.status = 'ok' and r.until_date = date '2024-02-29', '1.23 Feb 29 leap year is valid';

  select * into r from public.rrule_parse('FREQ=DAILY;UNTIL=20261301');
  assert r.status = 'malformed' and r.reason = 'invalid_until_date', '1.24 month 13';

  select * into r from public.rrule_parse('FREQ=DAILY;UNTIL=20260805T250000Z');
  assert r.status = 'malformed' and r.reason = 'invalid_until_instant', '1.25 hour 25';

  --------------------------------------------------------------- unsupported
  select * into r from public.rrule_parse('FREQ=YEARLY');
  assert r.status = 'unsupported' and r.reason = 'unsupported_freq:YEARLY', '1.26 YEARLY';

  select * into r from public.rrule_parse('FREQ=HOURLY');
  assert r.status = 'unsupported', '1.27 HOURLY';

  -- unknown key: a real RFC key we do not support, and a typo, behave the same.
  select * into r from public.rrule_parse('FREQ=MONTHLY;BYMONTHDAY=1');
  assert r.status = 'unsupported' and r.reason = 'unknown_key:BYMONTHDAY', '1.28 BYMONTHDAY';

  select * into r from public.rrule_parse('FREQ=DAILY;WKST=MO');
  assert r.status = 'unsupported' and r.reason = 'unknown_key:WKST', '1.29 WKST';

  select * into r from public.rrule_parse('FREQ=DAILY;NOPE=1');
  assert r.status = 'unsupported' and r.reason = 'unknown_key:NOPE', '1.30 garbage key';

  select * into r from public.rrule_parse('FREQ=WEEKLY;BYDAY=2MO');
  assert r.status = 'unsupported' and r.reason = 'unsupported_byday:2MO', '1.31 ordinal BYDAY';

  select * into r from public.rrule_parse('FREQ=WEEKLY;BYDAY=-1FR');
  assert r.status = 'unsupported', '1.32 negative ordinal BYDAY';

  select * into r from public.rrule_parse('FREQ=DAILY;BYDAY=MO');
  assert r.status = 'unsupported' and r.reason = 'byday_requires_weekly', '1.33 BYDAY with DAILY';

  select * into r from public.rrule_parse('FREQ=MONTHLY;BYDAY=MO');
  assert r.status = 'unsupported' and r.reason = 'byday_requires_weekly', '1.34 BYDAY with MONTHLY';

  raise notice 'Section 1 OK';
end $$;

-- ============================================================================
-- SECTION 2 -- rrule_sql_subset: POLICY + row context (all_day).
-- Parsing ok does NOT imply expandable.
-- ============================================================================
do $$
begin
  raise notice 'Section 2: rrule_sql_subset';

  ---------------------------------------------- all-day DAILY/WEEKLY = true
  assert public.rrule_sql_subset('FREQ=DAILY', true),                      '2.1 all-day DAILY';
  assert public.rrule_sql_subset('FREQ=WEEKLY;BYDAY=MO,WE', true),         '2.2 all-day WEEKLY BYDAY';
  assert public.rrule_sql_subset('FREQ=WEEKLY;INTERVAL=2;BYDAY=TU', true), '2.3 INTERVAL';
  assert public.rrule_sql_subset('FREQ=DAILY;UNTIL=20261231', true),       '2.4 DATE UNTIL matches all-day';

  ------------------------------------- parse=ok but OUT of the 5b subset
  assert (select p.status from public.rrule_parse('FREQ=MONTHLY') p) = 'ok', '2.5 precondition';
  assert not public.rrule_sql_subset('FREQ=MONTHLY', true),
         '2.5 MONTHLY parses ok but is NOT in the SQL subset';

  assert (select p.status from public.rrule_parse('FREQ=DAILY;COUNT=5') p) = 'ok', '2.6 precondition';
  assert not public.rrule_sql_subset('FREQ=DAILY;COUNT=5', true),
         '2.6 COUNT parses ok but is NOT in the SQL subset';

  ------------------------------------------------------------ timed = false
  assert not public.rrule_sql_subset('FREQ=DAILY', false),
         '2.7 timed excluded until events.timezone exists (5b-2/5b-3)';
  assert not public.rrule_sql_subset('FREQ=WEEKLY;BYDAY=MO', false), '2.8 timed weekly excluded';

  ------------------------------------------------- UNTIL kind / all_day mismatch
  assert not public.rrule_sql_subset('FREQ=DAILY;UNTIL=20261231T000000Z', true),
         '2.9 all-day master carrying an instant UNTIL is not in the subset';

  ------------------------------------------------------------------ rejects
  assert not public.rrule_sql_subset('FREQ=YEARLY', true),        '2.10 unsupported freq';
  assert not public.rrule_sql_subset('FREQ=DAILY;NOPE=1', true),  '2.11 unknown key';
  assert not public.rrule_sql_subset('', true),                   '2.12 malformed';
  assert not public.rrule_sql_subset(null, true),                 '2.13 null rrule';
  assert not public.rrule_sql_subset('FREQ=DAILY', null),         '2.14 null all_day';

  raise notice 'Section 2 OK';
end $$;

-- ============================================================================
-- SECTION 3 -- rrule_definitely_ends_before: the only narrowing 5b-0 acts on.
--
-- Boundary contract: spans are [start, end) and UNTIL is INCLUSIVE, so the
-- latest possible END is until + duration, and the window is untouched exactly
-- when latest_end <= window_start. EQUALITY COUNTS AS ENDED.
-- ============================================================================
do $$
declare
  -- all-day window starts 2026-09-01; timed window starts 2026-09-01T00:00Z.
  d_from constant date        := date '2026-09-01';
  t_from constant timestamptz := timestamptz '2026-09-01 00:00:00+00';

  -- all-day master spanning ONE day (start 01-01, end 01-02 exclusive).
  ad1_s constant date := date '2026-01-01';
  ad1_e constant date := date '2026-01-02';

  -- all-day master spanning THREE days (start 01-01, end 01-04 exclusive).
  ad3_s constant date := date '2026-01-01';
  ad3_e constant date := date '2026-01-04';

  -- timed master lasting exactly one hour.
  t1_s constant timestamptz := timestamptz '2026-01-01 09:00:00+00';
  t1_e constant timestamptz := timestamptz '2026-01-01 10:00:00+00';
begin
  raise notice 'Section 3: rrule_definitely_ends_before';

  ---------------------------------------- all-day, 1-day duration: < / = / >
  -- UNTIL 08-30 -> latest end 08-31 < 09-01  => ended
  assert public.rrule_definitely_ends_before(
           'FREQ=DAILY;UNTIL=20260830', true, ad1_s, ad1_e, null, null, t_from, d_from),
         '3.1 latest_end strictly before window start => ended';

  -- UNTIL 08-31 -> latest end 09-01 = 09-01  => ended (half-open: no overlap)
  assert public.rrule_definitely_ends_before(
           'FREQ=DAILY;UNTIL=20260831', true, ad1_s, ad1_e, null, null, t_from, d_from),
         '3.2 latest_end EXACTLY equals window start => ended (exclusive end)';

  -- UNTIL 09-01 -> latest end 09-02 > 09-01  => cannot prove
  assert not public.rrule_definitely_ends_before(
           'FREQ=DAILY;UNTIL=20260901', true, ad1_s, ad1_e, null, null, t_from, d_from),
         '3.3 latest_end after window start => NOT ended';

  ----------------------------------------------- all-day, multi-day duration
  -- duration 3 days. UNTIL 08-29 -> latest end 09-01 = window start => ended
  assert public.rrule_definitely_ends_before(
           'FREQ=WEEKLY;BYDAY=MO;UNTIL=20260829', true, ad3_s, ad3_e, null, null, t_from, d_from),
         '3.4 multi-day duration, boundary equality => ended';

  -- UNTIL 08-30 -> latest end 09-02 > 09-01 => not ended.
  -- This is the case a duration-blind implementation would get WRONG (false-free).
  assert not public.rrule_definitely_ends_before(
           'FREQ=WEEKLY;BYDAY=MO;UNTIL=20260830', true, ad3_s, ad3_e, null, null, t_from, d_from),
         '3.5 multi-day duration pushes the end INTO the window => NOT ended';

  ------------------------------------------------------- timed, 1h duration
  -- UNTIL 08-31T22:00Z -> latest end 23:00Z < 00:00Z => ended
  assert public.rrule_definitely_ends_before(
           'FREQ=DAILY;UNTIL=20260831T220000Z', false, null, null, t1_s, t1_e, t_from, d_from),
         '3.6 timed, strictly before => ended';

  -- UNTIL 08-31T23:00Z -> latest end 09-01T00:00Z = window start => ended
  assert public.rrule_definitely_ends_before(
           'FREQ=DAILY;UNTIL=20260831T230000Z', false, null, null, t1_s, t1_e, t_from, d_from),
         '3.7 timed, latest_end EXACTLY equals window start => ended';

  -- UNTIL 08-31T23:00:01Z -> latest end 00:00:01Z > window start => not ended
  assert not public.rrule_definitely_ends_before(
           'FREQ=DAILY;UNTIL=20260831T230001Z', false, null, null, t1_s, t1_e, t_from, d_from),
         '3.8 timed, one second into the window => NOT ended';

  --------------------------- a finished series outside the subset still counts
  -- MONTHLY is not expandable by SQL, but a finished MONTHLY series still
  -- contributes nothing. Narrowing is independent of rrule_sql_subset.
  assert not public.rrule_sql_subset('FREQ=MONTHLY;UNTIL=20260830', true), '3.9 precondition';
  assert public.rrule_definitely_ends_before(
           'FREQ=MONTHLY;UNTIL=20260830', true, ad1_s, ad1_e, null, null, t_from, d_from),
         '3.9 finished MONTHLY series is provably ended even though not expandable';

  ------------------------------------- anything unprovable must return false
  -- COUNT: the end is unknown without expanding from DTSTART.
  assert not public.rrule_definitely_ends_before(
           'FREQ=DAILY;COUNT=3', true, ad1_s, ad1_e, null, null, t_from, d_from),
         '3.10 COUNT cannot prove an end';

  -- No COUNT and no UNTIL: infinite series.
  assert not public.rrule_definitely_ends_before(
           'FREQ=DAILY', true, ad1_s, ad1_e, null, null, t_from, d_from),
         '3.11 infinite series cannot prove an end';

  -- malformed / unsupported must never prove anything.
  assert not public.rrule_definitely_ends_before(
           'FREQ=DAILY;UNTIL=20260231', true, ad1_s, ad1_e, null, null, t_from, d_from),
         '3.12 malformed UNTIL proves nothing';
  assert not public.rrule_definitely_ends_before(
           'FREQ=DAILY;NOPE=1', true, ad1_s, ad1_e, null, null, t_from, d_from),
         '3.13 unknown key proves nothing';
  assert not public.rrule_definitely_ends_before(
           null, true, ad1_s, ad1_e, null, null, t_from, d_from),
         '3.14 null rrule proves nothing';

  ------------------------------------------- UNTIL kind vs all_day mismatch
  -- all-day row carrying an instant UNTIL: the TS expander would compare it in
  -- local-date space, which is timezone-dependent. Refuse to reason about it.
  assert not public.rrule_definitely_ends_before(
           'FREQ=DAILY;UNTIL=20200101T000000Z', true, ad1_s, ad1_e, null, null, t_from, d_from),
         '3.15 all-day row + instant UNTIL proves nothing (even though long past)';

  -- timed row carrying a DATE UNTIL: same reasoning, mirrored.
  assert not public.rrule_definitely_ends_before(
           'FREQ=DAILY;UNTIL=20200101', false, null, null, t1_s, t1_e, t_from, d_from),
         '3.16 timed row + DATE UNTIL proves nothing (even though long past)';

  ------------------------------------------------- NULL inputs prove nothing
  assert not public.rrule_definitely_ends_before(
           'FREQ=DAILY;UNTIL=20260830', null, ad1_s, ad1_e, t1_s, t1_e, t_from, d_from),
         '3.17 null all_day proves nothing';
  assert not public.rrule_definitely_ends_before(
           'FREQ=DAILY;UNTIL=20260830', true, null, null, null, null, t_from, d_from),
         '3.18 missing date columns prove nothing';

  raise notice 'Section 3 OK';
end $$;

-- ============================================================================
-- SECTION 4 -- get_free_busy integration.
--
-- ISOLATION: this section requires a DEDICATED TEST USER that owns no events.
--
-- get_free_busy computes `complete` over ALL of the owner's events, so a real
-- calendar would contaminate every assertion here: an unbounded recurring
-- master (no COUNT/UNTIL) satisfies `start_date < p_to_date` for ANY window,
-- which would force complete=false throughout. Moving the window cannot escape
-- that, so isolation must come from the owner, not from the dates.
--
-- This suite therefore REFUSES TO RUN unless the owner starts with zero events.
-- It never deletes or updates a row it did not itself insert: if the
-- precondition fails, fix it by pointing v_owner at a clean test user -- not by
-- clearing anybody's calendar.
--
-- SETUP (once, on a development project):
--   1. Create a test user through the normal Supabase Auth path (the app's
--      login, or Dashboard > Authentication > Add user). Do NOT insert into
--      auth.users from SQL.
--   2. select id, email from auth.users order by created_at;
--   3. Paste that id into v_owner below.
--   4. Never create calendar events with that account.
-- ============================================================================
do $$
declare
  ------------------------------------------------------------------ SET THIS
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';  -- <<< EDIT per project
  --------------------------------------------------------------------------

  -- Window. Ordinary dates are fine: isolation comes from the empty test owner.
  v_from  constant timestamptz := timestamptz '2026-09-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-09-08 00:00:00+00';
  v_fromd constant date        := date '2026-09-01';
  v_tod   constant date        := date '2026-09-08';

  -- Per-run suffix makes every test token unique, so a token_hash can never
  -- collide with a real share link (nor with a previous run of this file).
  v_run      constant text := gen_random_uuid()::text;
  v_tok_ok   constant text := 'tw5b0-test-active-'    || v_run;
  v_tok_rev  constant text := 'tw5b0-test-revoked-'   || v_run;
  v_tok_exp  constant text := 'tw5b0-test-expired-'   || v_run;
  v_tok_priv constant text := 'tw5b0-test-noprivate-' || v_run;
  v_tok_none constant text := 'tw5b0-test-unknown-'   || v_run;  -- never registered

  -- Fixture ids. Every DELETE below targets these ids and nothing else, so this
  -- suite can never touch a row it did not create -- in events OR share_links.
  v_ev     constant uuid := gen_random_uuid();
  v_ex     constant uuid := gen_random_uuid();
  v_single constant uuid := gen_random_uuid();

  v_link_ok   constant uuid := gen_random_uuid();
  v_link_rev  constant uuid := gen_random_uuid();
  v_link_exp  constant uuid := gen_random_uuid();
  v_link_priv constant uuid := gen_random_uuid();

  v_res      jsonb;
  v_sqlstate text;
  v_exists   boolean;
begin
  raise notice 'Section 4: get_free_busy';

  -- ------------------------------------------------------------ PRECONDITIONS
  assert v_owner <> '00000000-0000-0000-0000-000000000000'::uuid,
    '4.0.0 set v_owner to a dedicated test user id first '
    '(select id, email from auth.users order by created_at)';

  select exists(select 1 from auth.users u where u.id = v_owner) into v_exists;
  assert v_exists,
    '4.0.1 v_owner does not exist in auth.users. Create the test user through '
    'the normal Auth path; this suite never inserts into auth.users.';

  -- THE isolation guard. Fail loudly; never clean up somebody's calendar.
  assert not exists (
    select 1 from public.events e where e.owner_id = v_owner
  ),
    '4.0.2 test owner must have no pre-existing events. Point v_owner at a '
    'dedicated test user. Do NOT delete events to satisfy this assertion.';

  -- Token uniqueness: with a per-run uuid a collision is already impossible,
  -- but assert it rather than assume it.
  assert not exists (
    select 1 from public.share_links s
    where s.token_hash in (
      encode(extensions.digest(v_tok_ok,   'sha256'), 'hex'),
      encode(extensions.digest(v_tok_rev,  'sha256'), 'hex'),
      encode(extensions.digest(v_tok_exp,  'sha256'), 'hex'),
      encode(extensions.digest(v_tok_priv, 'sha256'), 'hex'),
      encode(extensions.digest(v_tok_none, 'sha256'), 'hex')
    )
  ), '4.0.3 test token hash already exists; re-run to get a fresh suffix';

  -- Test-only share links. Existing links of this owner are left untouched.
  insert into public.share_links (id, owner_id, token_hash, label, include_private, expires_at, revoked_at)
  values
    (v_link_ok,   v_owner, encode(extensions.digest(v_tok_ok,  'sha256'),'hex'),
     'TW5B0-TEST active',    true,  null, null),
    (v_link_rev,  v_owner, encode(extensions.digest(v_tok_rev, 'sha256'),'hex'),
     'TW5B0-TEST revoked',   true,  null, now()),
    (v_link_exp,  v_owner, encode(extensions.digest(v_tok_exp, 'sha256'),'hex'),
     'TW5B0-TEST expired',   true,  now() - interval '1 day', null),
    (v_link_priv, v_owner, encode(extensions.digest(v_tok_priv,'sha256'),'hex'),
     'TW5B0-TEST noprivate', false, null, null);

  -- 4.0.4 Baseline: an empty owner reads as complete with no slots. Also proves
  -- the token wiring works before any behavioural assertion depends on it.
  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert v_res = '{"complete": true, "slots": []}'::jsonb,
    '4.0.4 empty test owner must yield complete=true with no slots, got ' || v_res::text;

  -- ---------------------------------------------------------------------
  -- 4.1 An in-subset all-day recurrence is EXPANDED (Phase 5b-1).
  --
  --     Until 5b-1 this asserted the opposite -- that a supported rule still
  --     reported complete=false, because 5b-0 shipped the parser without the
  --     expansion and must never relax completeness ahead of it. 0007 adds the
  --     expansion, so the guard flips: the subset is now genuinely handled.
  --     Rules OUTSIDE the subset are still fail-closed, asserted at 4.2c/4.2d.
  -- ---------------------------------------------------------------------
  assert public.rrule_sql_subset('FREQ=DAILY', true), '4.1 precondition: rule IS in the subset';

  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date, rrule)
  values (v_ev, v_owner, '', 'busy_only', true, date '2026-08-01', date '2026-08-02', 'FREQ=DAILY');

  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true,
    '4.1 an in-subset all-day recurrence is expanded and complete (5b-1)';
  assert jsonb_array_length(v_res->'slots') = 1,
    '4.1 daily occurrences merge into a single span';
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', true, 'start_date', to_jsonb(date '2026-09-01'),
           'end_date', to_jsonb(date '2026-09-08')),
    '4.1 the span covers the whole window';

  delete from public.events where id = v_ev;

  -- ---------------------------------------------------------------------
  -- 4.2 A series that provably ended before the window no longer forces
  --     incomplete. The one behavioural gain of 5b-0.
  --     duration = 1 day, UNTIL 2026-08-31 -> latest end 2026-09-01 = window start.
  -- ---------------------------------------------------------------------
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date, rrule)
  values (v_ev, v_owner, '', 'busy_only', true, date '2026-01-01', date '2026-01-02',
          'FREQ=DAILY;UNTIL=20260831');

  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true,
    '4.2 finished series must narrow complete to true (boundary equality)';
  assert v_res->'slots' = '[]'::jsonb, '4.2 still no slots';

  -- One day later and it is no longer provably finished. In 5b-0 that alone
  -- forced complete=false; since 5b-1 the same rule is inside the all-day
  -- subset, so it is expanded instead and the single surviving occurrence
  -- (2026-09-01, capped by UNTIL) shows up as busy.
  update public.events set rrule = 'FREQ=DAILY;UNTIL=20260901' where id = v_ev;
  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true,
    '4.2b a series reaching into the window is now expanded (5b-1)';
  assert jsonb_array_length(v_res->'slots') = 1, '4.2b one occurrence survives UNTIL';
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', true, 'start_date', to_jsonb(date '2026-09-01'),
           'end_date', to_jsonb(date '2026-09-02')),
    '4.2b the occurrence on the UNTIL date itself';

  -- COUNT cannot prove an end, even for a series that obviously stopped.
  update public.events set rrule = 'FREQ=DAILY;COUNT=3' where id = v_ev;
  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = false, '4.2c COUNT keeps complete=false';

  -- A malformed rule must never be narrowed away.
  update public.events set rrule = 'FREQ=DAILY;UNTIL=20260231' where id = v_ev;  -- Feb 31
  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = false, '4.2d malformed rule keeps complete=false';

  -- MONTHLY is outside the SQL subset, yet a finished MONTHLY series is still
  -- provably gone: narrowing is independent of expandability.
  assert not public.rrule_sql_subset('FREQ=MONTHLY;UNTIL=20260831', true), '4.2e precondition';
  update public.events set rrule = 'FREQ=MONTHLY;UNTIL=20260831' where id = v_ev;
  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true,
    '4.2e finished MONTHLY narrows even though SQL cannot expand it';

  delete from public.events where id = v_ev;

  -- ---------------------------------------------------------------------
  -- 4.3 Exception rows are resolved exactly (Phase 5b-1), so their mere
  --     existence no longer forces incomplete.
  --
  --     Until 5b-1 both asserts below expected complete=false, because 0005/0006
  --     could not reason about exceptions at all. 0007 detaches the replaced
  --     slot and emits the snapshot, so the answer is exact -- and the snapshot
  --     appears in the busy set.
  -- ---------------------------------------------------------------------
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date, rrule)
  values (v_ev, v_owner, '', 'busy_only', true, date '2026-01-01', date '2026-01-02',
          'FREQ=DAILY;UNTIL=20260831');

  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true, '4.3 precondition: master alone is complete';

  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             recurrence_id, recurrence_slot_date, is_cancelled)
  values (v_ex, v_owner, '', 'busy_only', true, date '2026-09-03', date '2026-09-04',
          v_ev, date '2026-09-03', false);

  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true,
    '4.3 a non-cancelled exception is now resolved exactly (5b-1)';
  assert jsonb_array_length(v_res->'slots') = 1, '4.3 the exception snapshot is disclosed';
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', true, 'start_date', to_jsonb(date '2026-09-03'),
           'end_date', to_jsonb(date '2026-09-04')),
    '4.3 the snapshot lands on its own date';

  -- A cancellation detaches its slot and adds nothing. The parent series ended
  -- before the window, so there was no occurrence to remove and the result is
  -- empty -- but still complete.
  update public.events set is_cancelled = true where id = v_ex;
  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true,
    '4.3b cancellations are resolved exactly too (5b-1)';
  assert v_res->'slots' = '[]'::jsonb, '4.3b a cancellation adds no busy';

  delete from public.events where id = v_ex;
  delete from public.events where id = v_ev;

  -- ---------------------------------------------------------------------
  -- 4.4 include_private regression: the visibility filter must apply to the
  --     completeness predicate, not only to the busy set.
  --
  --     The fixture uses an UNSUPPORTED rule on purpose. Before 5b-1 any
  --     recurrence forced incomplete, so FREQ=DAILY made the point; now that
  --     0007 expands the all-day subset, only a rule OUTSIDE it still exercises
  --     "visible-but-unaccountable", which is what these two asserts are about.
  --     The supported-rule behaviour under both link kinds is covered by the
  --     0007 suite (visibility matrix and N2).
  -- ---------------------------------------------------------------------
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date, rrule)
  values (v_ev, v_owner, '', 'private', true, date '2026-08-01', date '2026-08-02', 'FREQ=MONTHLY');

  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = false,
    '4.4 include_private=true link sees the private recurrence => incomplete';

  v_res := public.get_free_busy(v_tok_priv, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true,
    '4.4b include_private=false link excludes it => complete';

  delete from public.events where id = v_ev;

  -- ---------------------------------------------------------------------
  -- 4.5 Single events still produce busy exactly as in 0005, and leak nothing.
  -- ---------------------------------------------------------------------
  insert into public.events (id, owner_id, title, description, category, visibility,
                             all_day, start_at, end_at)
  values (v_single, v_owner, 'TW5B0-SECRET-TITLE', 'secret desc', 'secret cat', 'busy_only',
          false, timestamptz '2026-09-02 01:00:00+00', timestamptz '2026-09-02 02:00:00+00');

  v_res := public.get_free_busy(v_tok_ok, v_from, v_to, v_fromd, v_tod);
  assert (v_res->>'complete')::boolean = true, '4.5 single events keep complete=true';
  assert jsonb_array_length(v_res->'slots') = 1, '4.5 one busy slot';
  assert (v_res->'slots'->0->>'all_day')::boolean = false, '4.5 slot is timed';
  assert (v_res->'slots'->0) ? 'start' and (v_res->'slots'->0) ? 'end', '4.5 slot shape';
  assert not ((v_res->'slots'->0) ? 'title'), '4.5 no title key';
  assert not ((v_res->'slots'->0) ? 'id'),    '4.5 no id key';
  assert v_res::text not like '%TW5B0-SECRET-TITLE%', '4.5 title value never appears';
  assert v_res::text not like '%secret%',             '4.5 no description/category leaks';

  -- ---------------------------------------------------------------------
  -- 4.6 Token regressions: invalid / revoked / expired all return an EMPTY
  --     result with complete=true and never an error (no existence oracle).
  --     The busy fixture from 4.5 is still present, so an empty result here
  --     proves the token gate rather than an empty calendar.
  -- ---------------------------------------------------------------------
  v_res := public.get_free_busy(v_tok_none, v_from, v_to, v_fromd, v_tod);
  assert v_res = '{"complete": true, "slots": []}'::jsonb, '4.6 invalid token';

  v_res := public.get_free_busy(v_tok_rev, v_from, v_to, v_fromd, v_tod);
  assert v_res = '{"complete": true, "slots": []}'::jsonb, '4.6b revoked token';

  v_res := public.get_free_busy(v_tok_exp, v_from, v_to, v_fromd, v_tod);
  assert v_res = '{"complete": true, "slots": []}'::jsonb, '4.6c expired token';

  -- ---------------------------------------------------------------------
  -- 4.7 Window validation regressions: 22023, never a truncated answer.
  -- ---------------------------------------------------------------------
  begin
    perform public.get_free_busy(v_tok_ok, v_from, v_from + interval '93 days',
                                 v_fromd, v_fromd + 93);
    assert false, '4.7 93-day window should have raised';
  exception when others then
    get stacked diagnostics v_sqlstate = returned_sqlstate;
    assert v_sqlstate = '22023', '4.7 93-day window must raise 22023, got ' || v_sqlstate;
  end;

  begin
    perform public.get_free_busy(v_tok_ok, v_to, v_from, v_fromd, v_tod);   -- from >= to
    assert false, '4.7b inverted time window should have raised';
  exception when others then
    get stacked diagnostics v_sqlstate = returned_sqlstate;
    assert v_sqlstate = '22023', '4.7b inverted window must raise 22023, got ' || v_sqlstate;
  end;

  begin
    perform public.get_free_busy(v_tok_ok, v_from, v_to, v_tod, v_fromd);   -- from_date >= to_date
    assert false, '4.7c inverted date window should have raised';
  exception when others then
    get stacked diagnostics v_sqlstate = returned_sqlstate;
    assert v_sqlstate = '22023', '4.7c inverted date window must raise 22023, got ' || v_sqlstate;
  end;

  -- Exactly 92 days is still accepted (the cap is inclusive).
  v_res := public.get_free_busy(v_tok_ok, v_from, v_from + interval '92 days',
                                v_fromd, v_fromd + 92);
  assert v_res ? 'complete', '4.7d exactly 92 days must be accepted';

  -- ------------------------------------------------------------- CLEANUP
  delete from public.events where id = v_single;
  delete from public.share_links
   where id in (v_link_ok, v_link_rev, v_link_exp, v_link_priv);

  -- Closing invariant: we inserted fixtures and removed exactly those. The
  -- owner is back to the zero-event state 4.0.2 demanded. A failure here means
  -- a fixture leaked (or, worse, that this suite touched a row it did not own).
  assert not exists (select 1 from public.events e where e.owner_id = v_owner),
    '4.8 fixtures leaked: test owner should be back to zero events';

  raise notice 'Section 4 OK';
end $$;

-- ============================================================================
-- Leave no fixtures behind.
-- ============================================================================
rollback;
