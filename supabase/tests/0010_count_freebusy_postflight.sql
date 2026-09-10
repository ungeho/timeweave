-- ============================================================================
-- TimeWeave Phase 5b-5B POSTFLIGHT for 0010_count_freebusy.sql.
--
-- READ ONLY. Contains no DDL, no DML and no SET. It reads pg_catalog and calls
-- the six replaced functions, all of which are STABLE and touch no table, so it
-- is safe to run any number of times and needs no transaction wrapper of its
-- own.
--
-- RUN THIS IMMEDIATELY AFTER APPLYING 0010, BEFORE the 0010 test suite and
-- before the 0006/0007/0008/0009 regressions.
--
-- LAYOUT
--   PART 1 -- a DO block of ASSERTs. Hard gate: the first violated invariant
--             raises and nothing after it runs. Read the FIRST error.
--   PART 2 -- a single SELECT that renders the full state as a table. It is the
--             LAST statement on purpose, so the Supabase SQL Editor displays it.
--             It never raises; every row carries its own PASS/FAIL.
--
-- If PART 1 raises, PART 2 will not render. Re-run PART 2 alone to see the
-- whole picture instead of just the first failure.
--
-- THE ONE FAILURE MODE THIS FILE EXISTS FOR:
--   0010 replaces six functions in place and creates nothing. If any argument
--   TYPE list had drifted, CREATE OR REPLACE would have created a second
--   OVERLOAD rather than replacing -- the migration would report success while
--   get_free_busy stayed bound to the old fail-closed body. P.1 counts the
--   overloads for exactly that reason, and it is the first thing checked.
--
-- CHECKS THAT NEED A BASELINE taken BEFORE the migration was applied:
--   * the proacl of each of the six  -- recorded by the 0010 preflight,
--     section E.
--   * get_free_busy proacl AND prosrc md5 -- recorded by the preflight,
--     section G. 0010 does not replace get_free_busy, so the BODY HASH must be
--     identical, not merely compatible.
--   PART 2 prints the values as they are now; the comparison itself is yours.
-- ============================================================================

-- ============================================================================
-- PART 1 -- HARD GATE.
-- ============================================================================
do $$
declare
  v_spec   record;
  v_cnt    integer;
  v_oids   oid[];
  v_types  text[];
  v_names  text[];
  v_result text;
  v_vol    "char";
  v_secdef boolean;
  v_cfg    text[];
  v_acl    text;
  v_anon   oid;
  v_auth   oid;
  v_has    boolean;
  v_name   text;
  v_n      bigint;
  v_dates  date[];
  v_stamps timestamptz[];
  v_tg     "char";
begin
  raise notice '0010 POSTFLIGHT part 1';

  select r.oid into v_anon from pg_catalog.pg_roles r where r.rolname = 'anon';
  select r.oid into v_auth from pg_catalog.pg_roles r where r.rolname = 'authenticated';
  assert v_anon is not null and v_auth is not null,
    'P.0 roles anon and authenticated must exist for these assertions to mean anything';

  -- ==========================================================================
  -- P.1 -- THE SIX REPLACED FUNCTIONS: exactly one of each, with exactly the
  -- signature 0010 declares, and with every attribute 0010 restated.
  --
  -- A count of 2 here is the overload described in the header: the migration
  -- "succeeded" and changed nothing that matters.
  -- ==========================================================================
  for v_spec in
    select * from (values
      ('rrule_sql_subset',
       array['text','boolean']::text[],
       array['p_rrule','p_all_day']::text[],
       'boolean'),
      ('rrule_timed_sql_subset',
       array['text','boolean']::text[],
       array['p_rrule','p_all_day']::text[],
       'boolean'),
      ('rrule_allday_occurrence_count',
       array['text','boolean','date','date','date','date']::text[],
       array['p_rrule','p_all_day','p_start_date','p_end_date','p_from_date','p_to_date']::text[],
       'bigint'),
      ('rrule_timed_occurrence_count',
       array['text','boolean','timestamp with time zone','timestamp with time zone',
             'text','timestamp with time zone','timestamp with time zone']::text[],
       array['p_rrule','p_all_day','p_start_at','p_end_at','p_timezone','p_from','p_to']::text[],
       'bigint'),
      ('rrule_allday_occurrence_starts',
       array['text','boolean','date','date','date','date']::text[],
       array['p_rrule','p_all_day','p_start_date','p_end_date','p_from_date','p_to_date']::text[],
       'date'),
      ('rrule_timed_occurrence_starts',
       array['text','boolean','timestamp with time zone','timestamp with time zone',
             'text','timestamp with time zone','timestamp with time zone']::text[],
       array['p_rrule','p_all_day','p_start_at','p_end_at','p_timezone','p_from','p_to']::text[],
       'timestamp with time zone')
    ) as t(fname, types, argnames, rettype)
  loop
    select count(*)
      into v_cnt
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_spec.fname;

    assert v_cnt = 1,
      format('P.1 expected exactly one public.%s, found %s. If this is 2, 0010 '
             'created an OVERLOAD instead of replacing, and the old body is '
             'still reachable. Drop the wrong one before going further.',
             v_spec.fname, v_cnt);

    select p.proargtypes::oid[], p.proargnames,
           pg_catalog.format_type(p.prorettype, null),
           p.provolatile, p.prosecdef, p.proconfig, p.proacl::text
      into v_oids, v_names, v_result, v_vol, v_secdef, v_cfg, v_acl
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_spec.fname;

    -- Types come from the catalog, NOT from
    -- pg_get_function_identity_arguments(): that renders argument names
    -- alongside the types, so it can never match a bare type list.
    select array(
             select pg_catalog.format_type(u.t, null)
             from unnest(v_oids) with ordinality as u(t, ord)
             order by u.ord
           )
      into v_types;

    assert v_types = v_spec.types,
      format('P.2 public.%s argument types are (%s), expected (%s)',
             v_spec.fname,
             coalesce(array_to_string(v_types, ', '), 'null'),
             array_to_string(v_spec.types, ', '));

    assert v_names = v_spec.argnames,
      format('P.3 public.%s argument names are (%s), expected (%s)',
             v_spec.fname,
             coalesce(array_to_string(v_names, ', '), 'null'),
             array_to_string(v_spec.argnames, ', '));

    assert v_result = v_spec.rettype,
      format('P.4 public.%s returns %s, expected %s',
             v_spec.fname, v_result, v_spec.rettype);

    -- CREATE OR REPLACE resets any attribute the new definition omits. 0010
    -- restates all three; these three assertions are what proves it did.
    assert v_vol = 's',
      format('P.5 public.%s is not STABLE (provolatile=%s). 0010 dropped an '
             'attribute and the function is now VOLATILE.', v_spec.fname, v_vol);
    assert v_secdef = false,
      format('P.6 public.%s is SECURITY DEFINER; it must stay SECURITY INVOKER',
             v_spec.fname);
    assert exists (select 1 from unnest(coalesce(v_cfg, array[]::text[])) c
                   where c like 'search_path=%'),
      format('P.7 public.%s no longer pins search_path, proconfig=%s',
             v_spec.fname,
             coalesce(array_to_string(v_cfg, ', '), 'null'));

    -- 0010 issues no GRANT and no REVOKE. CREATE OR REPLACE preserves
    -- privileges, so the 0006/0007/0009 REVOKEs must still hold. A NULL proacl
    -- means the default PUBLIC EXECUTE grant is back.
    assert v_acl is not null,
      format('P.8 public.%s has a NULL proacl, so the default PUBLIC EXECUTE '
             'grant is back. CREATE OR REPLACE did not preserve privileges.',
             v_spec.fname);

    select exists (
      select 1
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace,
      lateral pg_catalog.aclexplode(p.proacl) a
      where n.nspname = 'public' and p.proname = v_spec.fname
        and a.privilege_type = 'EXECUTE'
        and a.grantee in (0, v_anon, v_auth)      -- 0 = PUBLIC
    ) into v_has;

    -- ACLs are read through aclexplode rather than by matching the printed
    -- aclitem[] text: a substring search cannot tell EXECUTE from any other
    -- privilege, and it cannot see the PUBLIC grant at all, which is written as
    -- an entry with an empty grantee.
    assert not v_has,
      format('P.9 public.%s is reachable by PUBLIC, anon or authenticated: %s. '
             'These six are internal-only; only get_free_busy is exposed.',
             v_spec.fname, v_acl);
  end loop;

  -- ==========================================================================
  -- P.10 -- get_free_busy: 0010 does not replace it, so nothing about it may
  -- have moved. Its argument NAMES are the PostgREST wire contract.
  -- ==========================================================================
  select count(*)
    into v_cnt
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_free_busy';

  assert v_cnt = 1,
    format('P.10 expected exactly one public.get_free_busy, found %s', v_cnt);

  select p.proargtypes::oid[], p.proargnames, p.prosecdef, p.proconfig, p.proacl::text
    into v_oids, v_names, v_secdef, v_cfg, v_acl
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_free_busy';

  select array(
           select pg_catalog.format_type(u.t, null)
           from unnest(v_oids) with ordinality as u(t, ord)
           order by u.ord
         )
    into v_types;

  assert v_types = array['text', 'timestamp with time zone',
                         'timestamp with time zone', 'date', 'date']::text[],
    format('P.10 get_free_busy argument types changed: %s',
           coalesce(array_to_string(v_types, ', '), 'null'));
  assert v_names = array['p_token', 'p_from', 'p_to',
                         'p_from_date', 'p_to_date']::text[],
    format('P.10 get_free_busy argument names changed: %s',
           coalesce(array_to_string(v_names, ', '), 'null'));
  assert v_secdef, 'P.10 get_free_busy must stay SECURITY DEFINER';
  assert exists (select 1 from unnest(coalesce(v_cfg, array[]::text[])) c
                 where c like 'search_path=%'),
    'P.10 get_free_busy must keep its pinned search_path';
  assert v_acl is not null,
    'P.11 get_free_busy has a NULL proacl, so the default PUBLIC grant is back';

  select exists (
    select 1
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace,
    lateral pg_catalog.aclexplode(p.proacl) a
    where n.nspname = 'public' and p.proname = 'get_free_busy'
      and a.privilege_type = 'EXECUTE' and a.grantee = v_anon
  ) into v_has;
  assert v_has, format('P.11a anon must keep EXECUTE on get_free_busy: %s', v_acl);

  select exists (
    select 1
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace,
    lateral pg_catalog.aclexplode(p.proacl) a
    where n.nspname = 'public' and p.proname = 'get_free_busy'
      and a.privilege_type = 'EXECUTE' and a.grantee = v_auth
  ) into v_has;
  assert v_has, format('P.11b authenticated must keep EXECUTE on get_free_busy: %s', v_acl);

  select exists (
    select 1
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace,
    lateral pg_catalog.aclexplode(p.proacl) a
    where n.nspname = 'public' and p.proname = 'get_free_busy'
      and a.privilege_type = 'EXECUTE' and a.grantee = 0      -- 0 = PUBLIC
  ) into v_has;
  assert not v_has,
    format('P.11c PUBLIC must not have EXECUTE on get_free_busy: %s', v_acl);

  -- ==========================================================================
  -- P.12 -- the objects 0010 must NOT have touched at all.
  -- ==========================================================================
  foreach v_name in array array[
    'rrule_parse',
    'rrule_definitely_ends_before',
    'rrule_allday_expansion_cap',
    'rrule_timed_expansion_cap',
    'timezone_is_resolvable',
    'timezone_is_supported'
  ]
  loop
    select count(*) into v_cnt
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_name;
    assert v_cnt = 1, format('P.12 expected exactly one public.%s, found %s', v_name, v_cnt);

    select p.proacl::text into v_acl
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_name;
    assert v_acl is not null,
      format('P.12 public.%s has a NULL proacl; something re-created it', v_name);
  end loop;

  -- The caps still read what 0007 and 0009 set. COUNT can only LOWER a
  -- candidate count, so a changed cap here would not be 0010's doing.
  assert public.rrule_allday_expansion_cap() = 5000,
    format('P.13 rrule_allday_expansion_cap() = %s, expected 5000',
           public.rrule_allday_expansion_cap());
  assert public.rrule_timed_expansion_cap() = 5000,
    format('P.13 rrule_timed_expansion_cap() = %s, expected 5000',
           public.rrule_timed_expansion_cap());

  -- rrule_definitely_ends_before still cannot prove a COUNT series ends. 0010
  -- reaches COUNT by EXPANDING it, never by narrowing, and the two must not
  -- start overlapping.
  assert not public.rrule_definitely_ends_before(
           'FREQ=DAILY;COUNT=3', true,
           date '2020-01-01', date '2020-01-02', null, null,
           null, date '2026-01-01'),
    'P.14 rrule_definitely_ends_before now proves a COUNT series ends; 0010 did '
    'not intend to change it';

  -- ==========================================================================
  -- P.15 -- THE BEHAVIOUR FLIP. Every one of these was false or NULL before
  -- 0010, and is asserted in the opposite direction by the preflight's
  -- section F.
  -- ==========================================================================
  assert public.rrule_sql_subset('FREQ=DAILY;COUNT=5', true),
    'P.15 rrule_sql_subset still rejects an all-day COUNT rule; 0010 did not take';
  assert public.rrule_sql_subset('FREQ=WEEKLY;BYDAY=MO,WE;COUNT=4', true),
    'P.15 rrule_sql_subset still rejects an all-day WEEKLY COUNT rule';
  assert public.rrule_timed_sql_subset('FREQ=DAILY;COUNT=5', false),
    'P.15 rrule_timed_sql_subset still rejects a timed COUNT rule; 0010 did not take';
  assert public.rrule_timed_sql_subset('FREQ=WEEKLY;BYDAY=TU,TH;COUNT=6', false),
    'P.15 rrule_timed_sql_subset still rejects a timed WEEKLY COUNT rule';

  -- P.16 The all-day counter must now COUNT, not return NULL. This is the
  --      second, independent rejection the 0010 header is about: had only the
  --      subset been widened, this would still be NULL and every caller's
  --      coalesce(count, cap + 1) would read it as "over cap" -- inside the
  --      subset yet outside the expandable set, generating nothing and
  --      reporting nothing. A silent false-free.
  v_n := public.rrule_allday_occurrence_count(
           'FREQ=DAILY;COUNT=3', true,
           date '2026-03-02', date '2026-03-03',
           date '2026-03-01', date '2026-03-10');
  assert v_n is not null,
    'P.16 rrule_allday_occurrence_count still returns NULL for a COUNT master. '
    'The subset was widened but the helper''s own inline rejection was not.';
  assert v_n = 3,
    format('P.16 expected 3 all-day candidates, got %s', v_n);

  v_n := public.rrule_timed_occurrence_count(
           'FREQ=DAILY;COUNT=3', false,
           timestamptz '2026-03-02 00:00:00+00', timestamptz '2026-03-02 01:00:00+00',
           'Asia/Tokyo',
           timestamptz '2026-03-01 00:00:00+00', timestamptz '2026-03-10 00:00:00+00');
  assert v_n is not null,
    'P.17 rrule_timed_occurrence_count still returns NULL for a COUNT master';
  assert v_n = 3,
    format('P.17 expected 3 timed candidates, got %s', v_n);

  -- ==========================================================================
  -- P.18 -- THE ORDINAL CONTRACT, on the two arms that have one.
  -- Depth belongs to the test suite; these are the two shapes whose failure
  -- would mean the migration is wrong rather than incomplete.
  -- ==========================================================================

  -- DAILY: ordinal(i) = i, so COUNT=3 emits exactly the first three days.
  select array_agg(d order by d)
    into v_dates
  from public.rrule_allday_occurrence_starts(
         'FREQ=DAILY;COUNT=3', true,
         date '2026-03-02', date '2026-03-03',
         date '2026-03-01', date '2026-03-10') d;
  assert v_dates = array[date '2026-03-02', date '2026-03-03', date '2026-03-04'],
    format('P.18 DAILY COUNT=3 emitted %s', coalesce(v_dates::text, 'null'));

  -- WEEKLY, the case the whole ordinal formula exists for. BYDAY=MO,WE,FR from
  -- a WEDNESDAY: week 0 is PARTIAL, contributing only WE and FR, so pw0 = 2 and
  -- the 7th (last) occurrence lands on Wednesday 2026-03-18, not on the Friday
  -- a naive "3 per week" bound would pick.
  select array_agg(d order by d)
    into v_dates
  from public.rrule_allday_occurrence_starts(
         'FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=7', true,
         date '2026-03-04', date '2026-03-05',
         date '2026-03-01', date '2026-03-25') d;
  assert array_length(v_dates, 1) = 7,
    format('P.18 WEEKLY COUNT=7 emitted %s occurrences: %s',
           coalesce(array_length(v_dates, 1), 0), coalesce(v_dates::text, 'null'));
  assert v_dates = array[date '2026-03-04', date '2026-03-06', date '2026-03-09',
                         date '2026-03-11', date '2026-03-13', date '2026-03-16',
                         date '2026-03-18'],
    format('P.18 WEEKLY COUNT=7 from a Wednesday emitted %s; week 0 must be '
           'partial (pw0 = 2)', coalesce(v_dates::text, 'null'));

  -- The timed arm, in a constant-offset zone so the ordinal is isolated from
  -- DST. The DST interaction itself is the test suite's job.
  select array_agg(t order by t)
    into v_stamps
  from public.rrule_timed_occurrence_starts(
         'FREQ=DAILY;COUNT=3', false,
         timestamptz '2026-03-02 00:00:00+00', timestamptz '2026-03-02 01:00:00+00',
         'Asia/Tokyo',
         timestamptz '2026-03-01 00:00:00+00', timestamptz '2026-03-10 00:00:00+00') t;
  assert v_stamps = array[timestamptz '2026-03-02 00:00:00+00',
                          timestamptz '2026-03-03 00:00:00+00',
                          timestamptz '2026-03-04 00:00:00+00'],
    format('P.18 timed DAILY COUNT=3 emitted %s', coalesce(v_stamps::text, 'null'));

  -- P.19 A COUNT series that ENDED BEFORE THE WINDOW. This is the case
  --      rrule_definitely_ends_before could never prove, and it is now answered
  --      by expansion: the master IS expandable, the tightened hi falls below
  --      lo, and the count is a perfectly ordinary 0 -- complete=true, no
  --      slots. NULL here would mean "over cap" and force complete=false.
  v_n := public.rrule_allday_occurrence_count(
           'FREQ=DAILY;COUNT=3', true,
           date '2020-01-01', date '2020-01-02',
           date '2026-03-01', date '2026-03-10');
  assert v_n is not null,
    'P.19 a COUNT series that ended before the window must count 0, not NULL. '
    'NULL is read as "over cap" by every caller and forces complete=false.';
  assert v_n = 0,
    format('P.19 expected 0 candidates for an exhausted series, got %s', v_n);

  assert not exists (
    select 1 from public.rrule_allday_occurrence_starts(
      'FREQ=DAILY;COUNT=3', true,
      date '2020-01-01', date '2020-01-02',
      date '2026-03-01', date '2026-03-10')
  ), 'P.19 an exhausted COUNT series must emit no occurrences';

  -- ==========================================================================
  -- P.20 -- THE REGRESSIONS. 0010 removed exactly one test from each subset.
  -- Everything else those gates rejected must still be rejected.
  -- ==========================================================================
  assert public.rrule_sql_subset('FREQ=DAILY', true),          'P.20 plain all-day DAILY';
  assert public.rrule_timed_sql_subset('FREQ=DAILY', false),   'P.20 plain timed DAILY';
  assert not public.rrule_sql_subset('FREQ=DAILY', false),
    'P.20 the all-day subset must still reject a timed row';
  assert not public.rrule_timed_sql_subset('FREQ=DAILY', true),
    'P.20 the timed subset must still reject an all-day row';
  assert not public.rrule_sql_subset('FREQ=DAILY', null),      'P.20 NULL all_day';
  assert not public.rrule_timed_sql_subset('FREQ=DAILY', null),'P.20 NULL all_day';
  assert not public.rrule_sql_subset(null, true),              'P.20 NULL rrule';
  assert not public.rrule_timed_sql_subset(null, false),       'P.20 NULL rrule';

  -- MONTHLY stays out, WITH COUNT AND WITHOUT. Only `count_n is null` was
  -- removed; `freq in (DAILY, WEEKLY)` remains in both subsets and inline in
  -- rrule_allday_occurrence_count.
  assert not public.rrule_sql_subset('FREQ=MONTHLY', true),          'P.21 MONTHLY';
  assert not public.rrule_sql_subset('FREQ=MONTHLY;COUNT=4', true),  'P.21 MONTHLY+COUNT';
  assert not public.rrule_timed_sql_subset('FREQ=MONTHLY', false),   'P.21 MONTHLY';
  assert not public.rrule_timed_sql_subset('FREQ=MONTHLY;COUNT=4', false),
    'P.21 MONTHLY+COUNT';
  assert public.rrule_allday_occurrence_count(
           'FREQ=MONTHLY;COUNT=4', true,
           date '2026-03-02', date '2026-03-03',
           date '2026-03-01', date '2026-03-10') is null,
    'P.21 rrule_allday_occurrence_count must still return NULL for MONTHLY+COUNT; '
    'its inline freq test is the only thing rejecting it now';

  -- The UNTIL kind must still match all_day, and COUNT+UNTIL is still malformed
  -- upstream -- which is what lets 0010 define no precedence between them.
  assert not public.rrule_sql_subset('FREQ=DAILY;UNTIL=20261101T060000Z', true),
    'P.22 an instant UNTIL on an all-day row must still be rejected';
  assert not public.rrule_timed_sql_subset('FREQ=DAILY;UNTIL=20261101', false),
    'P.22 a DATE UNTIL on a timed row must still be rejected';
  assert not public.rrule_sql_subset('FREQ=DAILY;COUNT=5;UNTIL=20261101', true),
    'P.22 COUNT+UNTIL must still be malformed; 0010 defines no precedence '
    'between its two least() bounds and depends on this';

  -- The zone gate on the timed path is unchanged: NULL is fail-closed, and an
  -- unresolvable zone counts NULL rather than raising.
  assert public.rrule_timed_occurrence_count(
           'FREQ=DAILY;COUNT=3', false,
           timestamptz '2026-03-02 00:00:00+00', timestamptz '2026-03-02 01:00:00+00',
           null,
           timestamptz '2026-03-01 00:00:00+00', timestamptz '2026-03-10 00:00:00+00') is null,
    'P.23 a NULL zone must still count NULL, COUNT or not';
  assert public.rrule_timed_occurrence_count(
           'FREQ=DAILY;COUNT=3', false,
           timestamptz '2026-03-02 00:00:00+00', timestamptz '2026-03-02 01:00:00+00',
           'Nowhere/Nothing',
           timestamptz '2026-03-01 00:00:00+00', timestamptz '2026-03-10 00:00:00+00') is null,
    'P.23 an unresolvable zone must still count NULL, COUNT or not';

  -- ==========================================================================
  -- P.24 -- the schema 0010 must not have touched.
  -- ==========================================================================
  select t.tgenabled
    into v_tg
  from pg_catalog.pg_trigger t
  where t.tgrelid = 'public.events'::regclass
    and t.tgname = 'events_validate_timezone'
    and not t.tgisinternal;

  assert v_tg is not null, 'P.24 trigger events_validate_timezone is missing';
  assert v_tg = 'O',
    format('P.24 events_validate_timezone must be enabled, tgenabled=%s '
           '(O=enabled, D=disabled, R=replica, A=always). A previous suite run '
           'may have left it disabled.', v_tg);

  assert (select relrowsecurity from pg_catalog.pg_class
          where oid = 'public.events'::regclass),
    'P.24 RLS is no longer enabled on public.events';
  assert (select relrowsecurity from pg_catalog.pg_class
          where oid = 'public.share_links'::regclass),
    'P.24 RLS is no longer enabled on public.share_links';

  raise notice '0010 POSTFLIGHT part 1 OK -- every hard invariant holds.';
  raise notice 'Now read the PART 2 table, and compare the BASELINE rows by hand';
  raise notice 'against the values the preflight printed (sections E and G).';
end $$;

-- ============================================================================
-- PART 2 -- FULL STATE REPORT. Never raises; read status per row.
-- Last statement on purpose: this is what the SQL Editor renders.
-- ============================================================================
with
r as (
  select (select oid from pg_catalog.pg_roles where rolname = 'anon')          as anon_oid,
         (select oid from pg_catalog.pg_roles where rolname = 'authenticated') as auth_oid
),
f as (
  select p.proname                                                 as name,
         -- Types from the catalog, NOT from
         -- pg_get_function_identity_arguments(): that renders argument names
         -- alongside the types, so it can never match a bare type list.
         coalesce((select string_agg(pg_catalog.format_type(u.t, null), ', ' order by u.ord)
                   from unnest(p.proargtypes::oid[]) with ordinality as u(t, ord)),
                  '')                                              as ident_args,
         pg_catalog.pg_get_function_result(p.oid)                  as result_type,
         case p.provolatile when 'i' then 'IMMUTABLE'
                            when 's' then 'STABLE'
                            else 'VOLATILE' end                    as volatility,
         case when p.prosecdef then 'DEFINER' else 'INVOKER' end   as security,
         coalesce(array_to_string(p.proconfig, ', '), '(none)')    as config,
         coalesce(p.proacl::text, 'NULL <-- default PUBLIC grant') as acl,
         coalesce(array_to_string(p.proargnames, ', '), '(none)')  as argnames,
         md5(p.prosrc)                                             as src_md5,
         p.proacl                                                  as raw_acl
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
),
exposed as (
  select f.name,
         f.raw_acl is null as acl_is_null,
         exists (
           select 1 from pg_catalog.aclexplode(f.raw_acl) a, r
           where a.privilege_type = 'EXECUTE'
             and (a.grantee = 0 or a.grantee = r.anon_oid or a.grantee = r.auth_oid)
         ) as reachable_by_clients,
         exists (select 1 from pg_catalog.aclexplode(f.raw_acl) a, r
                 where a.privilege_type = 'EXECUTE' and a.grantee = r.anon_oid) as anon_exec,
         exists (select 1 from pg_catalog.aclexplode(f.raw_acl) a, r
                 where a.privilege_type = 'EXECUTE' and a.grantee = r.auth_oid) as auth_exec,
         exists (select 1 from pg_catalog.aclexplode(f.raw_acl) a
                 where a.privilege_type = 'EXECUTE' and a.grantee = 0)          as public_exec
  from f
),
-- ident_args holds argument TYPES only; argnames holds the NAMES. Two columns,
-- because they are two catalog facts -- see the note in the f CTE above.
expected(name, ident_args, argnames, result_type, volatility, security) as (
  values
    ('rrule_sql_subset',              'text, boolean', 'p_rrule, p_all_day',
     'boolean', 'STABLE', 'INVOKER'),
    ('rrule_timed_sql_subset',        'text, boolean', 'p_rrule, p_all_day',
     'boolean', 'STABLE', 'INVOKER'),
    ('rrule_allday_occurrence_count',
     'text, boolean, date, date, date, date',
     'p_rrule, p_all_day, p_start_date, p_end_date, p_from_date, p_to_date',
     'bigint', 'STABLE', 'INVOKER'),
    ('rrule_allday_occurrence_starts',
     'text, boolean, date, date, date, date',
     'p_rrule, p_all_day, p_start_date, p_end_date, p_from_date, p_to_date',
     'SETOF date', 'STABLE', 'INVOKER'),
    ('rrule_timed_occurrence_count',
     'text, boolean, timestamp with time zone, timestamp with time zone, text, timestamp with time zone, timestamp with time zone',
     'p_rrule, p_all_day, p_start_at, p_end_at, p_timezone, p_from, p_to',
     'bigint', 'STABLE', 'INVOKER'),
    ('rrule_timed_occurrence_starts',
     'text, boolean, timestamp with time zone, timestamp with time zone, text, timestamp with time zone, timestamp with time zone',
     'p_rrule, p_all_day, p_start_at, p_end_at, p_timezone, p_from, p_to',
     'SETOF timestamp with time zone', 'STABLE', 'INVOKER'),
    ('get_free_busy',
     'text, timestamp with time zone, timestamp with time zone, date, date',
     'p_token, p_from, p_to, p_from_date, p_to_date',
     'jsonb', 'STABLE', 'DEFINER')
)
--  1. the six replaced functions + get_free_busy: shape, volatility, security
select 1 as seq,
       'A. signature' as area,
       e.name         as item,
       case when f.name is null then 'MISSING'
            when f.ident_args  = e.ident_args
             and f.argnames    = e.argnames
             and f.result_type = e.result_type
             and f.volatility  = e.volatility
             and f.security    = e.security
             and f.config like '%search_path=%' then 'PASS'
            else 'FAIL' end as status,
       format('types(%s) names(%s) -> %s | %s | %s | %s',
              coalesce(nullif(f.ident_args, ''), '-'), f.argnames, f.result_type,
              f.volatility, f.security, f.config) as actual,
       format('types(%s) names(%s) -> %s | %s | %s | search_path pinned',
              coalesce(nullif(e.ident_args, ''), '-'), e.argnames, e.result_type,
              e.volatility, e.security) as expected
from expected e
left join f on f.name = e.name

union all
--  2. NO OVERLOADS. 0010 replaces in place; a count of 2 means it created a
--     second function and the old fail-closed body is still reachable.
select 2, 'B. overloads', e.name,
       case when (select count(*) from f where f.name = e.name) = 1
            then 'PASS' else 'FAIL' end,
       (select count(*) from f where f.name = e.name)::text,
       'exactly 1 -- an overload means CREATE OR REPLACE did not replace'
from expected e

union all
--  3. the six replaced helpers must still be reachable by nobody
select 3, 'C. internal-only', x.name,
       case when x.acl_is_null then 'FAIL'
            when x.reachable_by_clients then 'FAIL'
            else 'PASS' end,
       (select acl from f where f.name = x.name),
       'no EXECUTE for PUBLIC / anon / authenticated, proacl NOT NULL'
from exposed x
where x.name in ('rrule_sql_subset', 'rrule_timed_sql_subset',
                 'rrule_allday_occurrence_count', 'rrule_allday_occurrence_starts',
                 'rrule_timed_occurrence_count', 'rrule_timed_occurrence_starts')

union all
--  4. the helpers 0010 did not replace must have stayed that way
select 4, 'D. untouched helpers', x.name,
       case when x.acl_is_null or x.reachable_by_clients then 'FAIL' else 'PASS' end,
       (select acl from f where f.name = x.name),
       'unchanged by 0010'
from exposed x
where x.name in ('rrule_parse', 'rrule_definitely_ends_before',
                 'rrule_allday_expansion_cap', 'rrule_timed_expansion_cap',
                 'timezone_is_resolvable')

union all
--  4b. timezone_is_supported is NOT an internal-only helper, so the rule above
--      does not apply to it. The 0008 write-path trigger events_validate_timezone
--      runs as INVOKER and calls it on every write to public.events, so
--      authenticated MUST hold EXECUTE. That is an EXISTING grant made by
--      migration 0008 (revoke from PUBLIC, grant to authenticated), and 0010
--      issues no GRANT and no REVOKE at all -- so 0010 does not change it and
--      this row must read exactly as it did before 0010 was applied.
select 4, 'D. untouched helpers', 'timezone_is_supported EXECUTE',
       case when x.acl_is_null then 'FAIL'
            when x.auth_exec and not x.anon_exec and not x.public_exec
            then 'PASS' else 'FAIL' end,
       format('anon=%s authenticated=%s PUBLIC=%s | %s',
              x.anon_exec, x.auth_exec, x.public_exec,
              (select acl from f where f.name = 'timezone_is_supported')),
       'authenticated=true anon=false PUBLIC=false, proacl NOT NULL '
       '(0008 write-path grant, unchanged by 0010)'
from exposed x where x.name = 'timezone_is_supported'

union all
--  5. get_free_busy grants -- the only function anon may reach
select 5, 'E. get_free_busy', 'EXECUTE grants',
       case when x.acl_is_null then 'FAIL'
            when x.anon_exec and x.auth_exec and not x.public_exec then 'PASS'
            else 'FAIL' end,
       format('anon=%s authenticated=%s PUBLIC=%s | %s',
              x.anon_exec, x.auth_exec, x.public_exec,
              (select acl from f where f.name = 'get_free_busy')),
       'anon=true authenticated=true PUBLIC=false'
from exposed x where x.name = 'get_free_busy'

union all
--  6. BASELINE. 0010 does not replace get_free_busy, so its BODY HASH must be
--     byte-identical to the one the preflight printed. Compare by hand.
select 6, 'F. BASELINE (compare by hand)', 'get_free_busy prosrc md5',
       'INFO', f.src_md5,
       'must equal the md5 printed by the preflight, section G'
from f where f.name = 'get_free_busy'

union all
--  7. BASELINE. Each replaced function keeps the proacl the preflight printed.
select 7, 'F. BASELINE (compare by hand)', 'proacl ' || e.name,
       'INFO',
       (select acl from f where f.name = e.name),
       'must equal the proacl printed by the preflight, section E'
from expected e
where e.name <> 'get_free_busy'

union all
--  8. THE BEHAVIOUR FLIP, rendered rather than asserted.
select 8, 'G. COUNT admitted', t.item,
       case when t.got = t.want then 'PASS' else 'FAIL' end,
       t.got::text, t.want::text
from (values
  ('rrule_sql_subset(DAILY;COUNT=5, all_day)',
   public.rrule_sql_subset('FREQ=DAILY;COUNT=5', true), true),
  ('rrule_sql_subset(WEEKLY;BYDAY;COUNT=4, all_day)',
   public.rrule_sql_subset('FREQ=WEEKLY;BYDAY=MO,WE;COUNT=4', true), true),
  ('rrule_timed_sql_subset(DAILY;COUNT=5, timed)',
   public.rrule_timed_sql_subset('FREQ=DAILY;COUNT=5', false), true),
  ('rrule_timed_sql_subset(WEEKLY;BYDAY;COUNT=6, timed)',
   public.rrule_timed_sql_subset('FREQ=WEEKLY;BYDAY=TU,TH;COUNT=6', false), true),
  ('MONTHLY still out (all-day)',
   public.rrule_sql_subset('FREQ=MONTHLY;COUNT=4', true), false),
  ('MONTHLY still out (timed)',
   public.rrule_timed_sql_subset('FREQ=MONTHLY;COUNT=4', false), false),
  ('COUNT+UNTIL still malformed',
   public.rrule_sql_subset('FREQ=DAILY;COUNT=5;UNTIL=20261101', true), false)
) as t(item, got, want)

union all
--  9. THE ORDINAL CONTRACT, rendered. The WEEKLY row is the one that matters:
--     BYDAY=MO,WE,FR;COUNT=7 from a WEDNESDAY has a PARTIAL week 0 (pw0 = 2),
--     so the last occurrence is Wednesday 2026-03-18.
select 9, 'H. ordinal contract', t.item,
       case when t.got = t.want then 'PASS' else 'FAIL' end,
       coalesce(t.got, '(null)'), t.want
from (values
  ('all-day DAILY;COUNT=3 from 2026-03-02',
   (select array_agg(d order by d)::text
    from public.rrule_allday_occurrence_starts(
           'FREQ=DAILY;COUNT=3', true,
           date '2026-03-02', date '2026-03-03',
           date '2026-03-01', date '2026-03-10') d),
   '{2026-03-02,2026-03-03,2026-03-04}'),
  ('all-day WEEKLY;BYDAY=MO,WE,FR;COUNT=7 from Wed 2026-03-04',
   (select array_agg(d order by d)::text
    from public.rrule_allday_occurrence_starts(
           'FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=7', true,
           date '2026-03-04', date '2026-03-05',
           date '2026-03-01', date '2026-03-25') d),
   '{2026-03-04,2026-03-06,2026-03-09,2026-03-11,2026-03-13,2026-03-16,2026-03-18}'),
  ('all-day count, series exhausted before the window',
   public.rrule_allday_occurrence_count(
     'FREQ=DAILY;COUNT=3', true,
     date '2020-01-01', date '2020-01-02',
     date '2026-03-01', date '2026-03-10')::text,
   '0')
) as t(item, got, want)

order by seq, item;
