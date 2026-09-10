-- ============================================================================
-- TimeWeave Phase 5b-5B -- PREFLIGHT for 0010_count_freebusy.sql
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run BEFORE applying 0010, by hand,
-- against the project 0010 will be applied to. READ-ONLY: no DDL, no DML, no
-- SET. Wrapped in a transaction ending in ROLLBACK as a belt-and-braces
-- guarantee that nothing can persist.
--
-- WHAT MAKES THIS DIFFERENT FROM THE 0009 PREFLIGHT:
--   0009 created new names, so its section E asserted they did NOT exist. 0010
--   creates nothing: all six functions it writes ALREADY EXIST, and it replaces
--   them in place. Section E therefore asserts the OPPOSITE -- every one of the
--   six is present, exactly once, with exactly the argument names, argument
--   types and return type 0010 restates.
--
--   That check is not ceremony. CREATE OR REPLACE FUNCTION matches on the
--   argument TYPE list: a drifted type list does not replace, it creates a
--   second OVERLOAD, and get_free_busy is then bound to whichever the resolver
--   picks -- silently keeping the old fail-closed body on the path that
--   matters. A drifted argument NAME fails outright instead ("cannot change
--   name of input parameter"). Section E catches both before anything is
--   written.
--
--   Section F pins the PRE-migration behaviour: COUNT is currently fail-closed
--   on both paths. Every assertion in it is inverted by 0010, so RE-RUNNING
--   THIS FILE AFTER APPLYING 0010 FAILS SECTION F BY DESIGN. That is how you
--   tell "not yet applied" from "already applied".
--
-- WHY THE DST SECTION IS REPEATED FROM 0009:
--   0010 reproduces the timed conversion path verbatim -- `v_cl at time zone
--   p_timezone`, the DTSTART exact-anchor, the absolute-seconds duration -- and
--   the 0010 test suite therefore states the same instants the 0009 suite does.
--   If the server or its tzdata has moved since 0009 was applied, that must
--   fail HERE, before 0010, instead of being read as a COUNT bug.
--
-- A failing assert aborts the transaction; later statements then report
-- "current transaction is aborted" until the ROLLBACK. Read the FIRST error.
-- RUN THE WHOLE FILE, INCLUDING THE FINAL ROLLBACK.
-- ============================================================================

begin;

-- ============================================================================
-- SECTION A -- environment, recorded so later output can be interpreted.
-- The session TimeZone is printed, never asserted: every expression in this
-- file and in 0010 names its zone explicitly, so none depends on the GUC. It
-- matters only because the editor renders timestamptz values in it.
-- ============================================================================
do $$
declare
  v_pgcrypto text;
begin
  raise notice 'Section A: environment';
  raise notice '  version          : %', version();
  raise notice '  session TimeZone : %', current_setting('TimeZone');
  raise notice '  tz names         : %', (select count(*) from pg_catalog.pg_timezone_names);

  select n.nspname
    into v_pgcrypto
  from pg_catalog.pg_extension e
  join pg_catalog.pg_namespace n on n.oid = e.extnamespace
  where e.extname = 'pgcrypto';

  raise notice '  pgcrypto schema  : %', coalesce(v_pgcrypto, 'not installed');

  assert v_pgcrypto = 'extensions',
    'A.1 pgcrypto is not in the extensions schema; the 0010 suite builds its '
    'share_links fixtures with extensions.digest(), as 0005-0009 do';
end
$$;

-- ============================================================================
-- SECTION B -- rrule_parse already understands COUNT, and already excludes
-- COUNT+UNTIL.
--
-- 0010 DEPENDS on both. It defines NO precedence between COUNT and UNTIL -- its
-- two `least()` bounds are written as if they can never both apply -- precisely
-- because rrule_parse reports `count_and_until` when they co-occur, which makes
-- status <> 'ok' and fails every subset test upstream.
--
-- If B.4 ever fails, both bounds could apply to one rule and the tighter one
-- would silently win. Do not apply 0010 in that state.
-- ============================================================================
do $$
declare
  p record;
begin
  raise notice 'Section B: rrule_parse COUNT vocabulary';

  select * into p from public.rrule_parse('FREQ=DAILY;COUNT=5');
  assert p.status = 'ok',
    format('B.1 FREQ=DAILY;COUNT=5 must parse ok, got %s/%s',
           p.status, coalesce(p.reason, 'null'));
  assert p.count_n = 5,
    format('B.1 count_n must be 5, got %s', coalesce(p.count_n::text, 'null'));
  assert p.freq = 'DAILY' and p.interval_n = 1,
    'B.1 FREQ/INTERVAL misparsed alongside COUNT';

  select * into p from public.rrule_parse('FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=7');
  assert p.status = 'ok',
    format('B.2 WEEKLY BYDAY COUNT must parse ok, got %s/%s',
           p.status, coalesce(p.reason, 'null'));
  assert p.count_n = 7, 'B.2 count_n must be 7';
  assert p.byday is not null and array_length(p.byday, 1) = 3,
    'B.2 BYDAY must survive alongside COUNT';

  -- COUNT=1 is a legal one-shot series. 0010 turns it into "ordinal 0 only",
  -- which on the WEEKLY arm takes the `count_n <= pw0` branch.
  select * into p from public.rrule_parse('FREQ=DAILY;COUNT=1');
  assert p.status = 'ok' and p.count_n = 1, 'B.3 COUNT=1 must parse ok';

  -- THE EXCLUSION 0010 RELIES ON.
  select * into p from public.rrule_parse('FREQ=DAILY;COUNT=5;UNTIL=20261101');
  assert p.status <> 'ok',
    'B.4 COUNT and UNTIL together now parse as ok. 0010 assumes they are '
    'mutually exclusive and defines NO precedence between its two least() '
    'bounds. DO NOT APPLY 0010 until this is resolved.';
  assert p.reason = 'count_and_until',
    format('B.4 expected reason count_and_until, got %s', coalesce(p.reason, 'null'));

  select * into p from public.rrule_parse('FREQ=DAILY;UNTIL=20261101T060000Z;COUNT=5');
  assert p.status <> 'ok' and p.reason = 'count_and_until',
    'B.4 the exclusion must not depend on which of COUNT/UNTIL is written first';

  -- COUNT=0 and a negative COUNT must never reach the ordinal arithmetic, where
  -- `count_n - 1` would give a bound of -1 or lower. Rejected upstream, so 0010
  -- deliberately carries no guard of its own.
  select * into p from public.rrule_parse('FREQ=DAILY;COUNT=0');
  assert p.status <> 'ok',
    format('B.5 COUNT=0 must not parse as ok (0010 computes count_n - 1), got %s/%s',
           p.status, coalesce(p.reason, 'null'));

  select * into p from public.rrule_parse('FREQ=DAILY;COUNT=-3');
  assert p.status <> 'ok',
    'B.6 a negative COUNT must not parse as ok';

  -- MONTHLY+COUNT parses ok. It is excluded by the FREQ test, not by the COUNT
  -- test -- which is exactly why 0010 keeps `freq in (DAILY, WEEKLY)` in both
  -- subsets AND inline in rrule_allday_occurrence_count.
  select * into p from public.rrule_parse('FREQ=MONTHLY;COUNT=4');
  assert p.status = 'ok' and p.freq = 'MONTHLY',
    'B.7 FREQ=MONTHLY;COUNT=4 no longer parses as ok; the 0010 MONTHLY '
    'exclusion tests would then be vacuous rather than meaningful';

  raise notice '  rrule_parse COUNT vocabulary OK';
end
$$;

-- ============================================================================
-- SECTION C -- DST resolution, pinned to the values measured for 0009 on
-- 2026-09-04. 0010 reproduces the timed conversion verbatim, so these are still
-- the specification. A failure here means the SERVER moved, not that COUNT is
-- wrong.
--   gap  (local time that does not exist) -> lands one hour LATER.
--   fold (local time that happens twice)  -> the LATER of the two instants.
-- ============================================================================
do $$
begin
  raise notice 'Section C: DST resolution (America/New_York, 2026)';

  assert (timestamp '2026-03-08 02:30:00' at time zone 'America/New_York')
         = timestamptz '2026-03-08 07:30:00+00',
    'C.1 gap 2026-03-08 02:30 no longer resolves to 07:30Z -- STOP';

  assert ((timestamp '2026-03-08 02:30:00' at time zone 'America/New_York')
           at time zone 'America/New_York')
         = timestamp '2026-03-08 03:30:00',
    'C.2 the gap no longer shifts forward to 03:30 local -- STOP';

  assert (timestamp '2026-11-01 01:30:00' at time zone 'America/New_York')
         = timestamptz '2026-11-01 06:30:00+00',
    'C.3 fold 2026-11-01 01:30 no longer resolves to the LATER instant 06:30Z -- STOP';

  assert ((timestamp '2026-11-01 01:30:00' at time zone 'America/New_York')
           at time zone 'America/New_York')
         = timestamp '2026-11-01 01:30:00',
    'C.4 the fold no longer round-trips to the same local time -- STOP';

  -- The transition instants the 0010 suite hardcodes.
  assert (timestamptz '2026-03-08 07:00:00+00' at time zone 'America/New_York')
         = timestamp '2026-03-08 03:00:00',
    'C.5 the spring transition is not at 07:00Z as the 0010 suite assumes -- STOP';

  assert (timestamptz '2026-11-01 06:00:00+00' at time zone 'America/New_York')
         = timestamp '2026-11-01 01:00:00',
    'C.6 the autumn transition is not at 06:00Z as the 0010 suite assumes -- STOP';

  -- Constant-offset controls, so a COUNT test can isolate the ordinal from DST.
  assert (timestamp '2026-03-08 09:00:00' at time zone 'Asia/Tokyo')
         = timestamptz '2026-03-08 00:00:00+00',
    'C.7 Asia/Tokyo is no longer a constant UTC+9 control (spring day) -- STOP';

  assert (timestamp '2026-11-01 09:00:00' at time zone 'Asia/Tokyo')
         = timestamptz '2026-11-01 00:00:00+00',
    'C.7 Asia/Tokyo is no longer a constant UTC+9 control (autumn day) -- STOP';

  raise notice '  gap  02:30 -> % UTC',
    (timestamp '2026-03-08 02:30:00' at time zone 'America/New_York') at time zone 'UTC';
  raise notice '  fold 01:30 -> % UTC',
    (timestamp '2026-11-01 01:30:00' at time zone 'America/New_York') at time zone 'UTC';
end
$$;

-- ============================================================================
-- SECTION D -- the dependencies 0010 calls but does NOT replace.
-- If any is missing, apply 0005 to 0009 first.
-- ============================================================================
do $$
declare
  v_name text;
  v_cap  integer;
begin
  raise notice 'Section D: dependencies 0010 does not touch';

  foreach v_name in array array[
    'rrule_parse',
    'rrule_definitely_ends_before',
    'rrule_allday_expansion_cap',
    'rrule_timed_expansion_cap',
    'timezone_is_resolvable',
    'timezone_is_supported',
    'get_free_busy'
  ]
  loop
    assert exists (
      select 1
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname = v_name
    ), format('D.1 public.%s is missing; apply 0005 to 0009 first', v_name);
  end loop;

  -- The caps bound the loops 0010 rewrites. COUNT can only LOWER a candidate
  -- count, so it can never push a master over a cap -- but the cap must exist
  -- and be positive for the defence-in-depth probe inside the two _starts
  -- helpers to mean anything.
  v_cap := public.rrule_allday_expansion_cap();
  assert v_cap is not null and v_cap > 0,
    format('D.2 rrule_allday_expansion_cap() = %s', coalesce(v_cap::text, 'null'));
  raise notice '  rrule_allday_expansion_cap : %', v_cap;

  v_cap := public.rrule_timed_expansion_cap();
  assert v_cap is not null and v_cap > 0,
    format('D.3 rrule_timed_expansion_cap() = %s', coalesce(v_cap::text, 'null'));
  raise notice '  rrule_timed_expansion_cap  : %', v_cap;

  -- timezone_is_resolvable gates every AT TIME ZONE call on the timed path and
  -- is reproduced unchanged in both timed helpers.
  assert public.timezone_is_resolvable('America/New_York'), 'D.4 New York must resolve';
  assert public.timezone_is_resolvable('Asia/Tokyo'),        'D.4 Tokyo must resolve';
  assert not public.timezone_is_resolvable(null),            'D.5 NULL must not resolve';
  assert not public.timezone_is_resolvable('JST'),           'D.5 an abbreviation must not resolve';

  -- rrule_definitely_ends_before is NOT changed by 0010, and still cannot prove
  -- a COUNT series ends: it tests until_date / until_ts is not null. 0010
  -- handles the COUNT case by EXPANDING it instead of by narrowing. Asserted so
  -- a future change to 0006 cannot silently overlap with this migration.
  assert not public.rrule_definitely_ends_before(
           'FREQ=DAILY;COUNT=3', true,
           date '2020-01-01', date '2020-01-02', null, null,
           null, date '2026-01-01'),
    'D.6 rrule_definitely_ends_before now proves a COUNT series ends. 0010 '
    'assumes it does not, and reaches COUNT only through expansion.';
end
$$;

-- ============================================================================
-- SECTION E -- THE SIX FUNCTIONS 0010 REPLACES.
--
-- Each must exist EXACTLY ONCE with exactly the argument names, argument types
-- and return type 0010 restates. See the header for why an overload is the
-- worst outcome here.
--
-- The current proacl of each is PRINTED. CREATE OR REPLACE preserves
-- privileges, and 0010 issues no GRANT and no REVOKE, so after applying, the
-- postflight must see these unchanged. RECORD THIS OUTPUT.
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
begin
  raise notice 'Section E: the six functions 0010 replaces';

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

    -- Exactly one. Zero means 0006/0007/0009 are not all applied; two or more
    -- means an overload already exists and CREATE OR REPLACE would update only
    -- one of them, leaving the other reachable.
    assert v_cnt = 1,
      format('E.1 expected exactly one public.%s, found %s. 0010 replaces in '
             'place and cannot disambiguate an overload.', v_spec.fname, v_cnt);

    select p.proargtypes::oid[], p.proargnames,
           pg_catalog.format_type(p.prorettype, null),
           p.provolatile, p.prosecdef, p.proconfig, p.proacl::text
      into v_oids, v_names, v_result, v_vol, v_secdef, v_cfg, v_acl
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_spec.fname;

    -- Types come from the catalog, not from
    -- pg_get_function_identity_arguments(): that renders argument NAMES
    -- alongside the types, so comparing it against a bare type list can never
    -- match. Types and names are checked separately, and both matter.
    select array(
             select pg_catalog.format_type(u.t, null)
             from unnest(v_oids) with ordinality as u(t, ord)
             order by u.ord
           )
      into v_types;

    assert v_types = v_spec.types,
      format('E.2 public.%s argument types are (%s); 0010 declares (%s). It '
             'would CREATE AN OVERLOAD instead of replacing.',
             v_spec.fname,
             coalesce(array_to_string(v_types, ', '), 'null'),
             array_to_string(v_spec.types, ', '));

    assert v_names = v_spec.argnames,
      format('E.3 public.%s argument names are (%s); 0010 declares (%s). '
             'CREATE OR REPLACE cannot rename an input parameter and will fail.',
             v_spec.fname,
             coalesce(array_to_string(v_names, ', '), 'null'),
             array_to_string(v_spec.argnames, ', '));

    -- The two _starts functions RETURN SETOF; format_type reports the element
    -- type either way, which is what is compared here. CREATE OR REPLACE cannot
    -- change a return type at all, so a mismatch is a hard stop.
    assert v_result = v_spec.rettype,
      format('E.4 public.%s returns %s; 0010 declares %s. CREATE OR REPLACE '
             'cannot change a return type.', v_spec.fname, v_result, v_spec.rettype);

    -- Attribute baseline. 0010 restates all three because CREATE OR REPLACE
    -- resets any attribute the new definition omits; the postflight asserts
    -- they are unchanged afterwards.
    assert v_vol = 's',
      format('E.5 public.%s is not STABLE (provolatile=%s)', v_spec.fname, v_vol);
    assert v_secdef = false,
      format('E.6 public.%s is SECURITY DEFINER; 0010 declares SECURITY INVOKER',
             v_spec.fname);
    assert exists (select 1 from unnest(coalesce(v_cfg, array[]::text[])) c
                   where c like 'search_path=%'),
      format('E.7 public.%s does not pin search_path', v_spec.fname);

    -- 0010 issues no GRANT and no REVOKE, relying on CREATE OR REPLACE
    -- preserving privileges. A NULL proacl here would mean the 0006/0007/0009
    -- REVOKEs are already gone, and 0010 would faithfully preserve that hole
    -- rather than close it.
    assert v_acl is not null,
      format('E.8 public.%s has a NULL proacl, so the default PUBLIC EXECUTE '
             'grant is in place. 0010 issues no REVOKE and would preserve it. '
             'Fix this before applying.', v_spec.fname);

    raise notice '  % proacl = %', rpad(v_spec.fname || ':', 33), v_acl;
  end loop;

  raise notice '  RECORD THE proacl VALUES ABOVE; the postflight compares them.';
end
$$;

-- ============================================================================
-- SECTION F -- THE PRE-MIGRATION BEHAVIOUR 0010 CHANGES.
--
-- Every assertion here states the CURRENT, fail-closed behaviour, and every one
-- of them is inverted by 0010. RE-RUNNING THIS FILE AFTER APPLYING 0010 FAILS
-- SECTION F BY DESIGN.
--
-- F.2 is the one worth reading twice. rrule_allday_occurrence_count carries its
-- OWN `count_n is not null` rejection, independent of rrule_sql_subset, because
-- it inlines the subset tests rather than calling the function. Widening the
-- subset alone would have left this helper returning NULL, which every caller's
-- coalesce(count, cap + 1) rule reads as "over cap" -- inside the subset yet
-- outside the expandable set, generating nothing and reporting nothing. A
-- silent false-free. Both had to change; both are pinned here.
-- ============================================================================
do $$
declare
  v_n bigint;
begin
  raise notice 'Section F: current (pre-0010) COUNT behaviour -- fails after applying';

  -- F.1 Both grammar gates currently reject COUNT.
  assert not public.rrule_sql_subset('FREQ=DAILY;COUNT=5', true),
    'F.1 rrule_sql_subset already admits COUNT -- 0010 appears to be APPLIED ALREADY';
  assert not public.rrule_timed_sql_subset('FREQ=DAILY;COUNT=5', false),
    'F.1 rrule_timed_sql_subset already admits COUNT -- 0010 appears to be APPLIED ALREADY';

  -- F.2 The all-day counter currently returns NULL for a COUNT master, through
  --     its own inline rejection.
  v_n := public.rrule_allday_occurrence_count(
           'FREQ=DAILY;COUNT=5', true,
           date '2026-03-02', date '2026-03-03',
           date '2026-03-02', date '2026-03-09');
  assert v_n is null,
    format('F.2 rrule_allday_occurrence_count already counts a COUNT master '
           '(returned %s) -- 0010 appears to be APPLIED ALREADY', v_n);

  -- F.3 The timed counter returns NULL too, but by delegating to the subset.
  v_n := public.rrule_timed_occurrence_count(
           'FREQ=DAILY;COUNT=5', false,
           timestamptz '2026-03-06 14:00:00+00', timestamptz '2026-03-06 15:00:00+00',
           'America/New_York',
           timestamptz '2026-03-06 00:00:00+00', timestamptz '2026-03-11 00:00:00+00');
  assert v_n is null,
    format('F.3 rrule_timed_occurrence_count already counts a COUNT master '
           '(returned %s) -- 0010 appears to be APPLIED ALREADY', v_n);

  -- F.4 Everything 0010 must NOT change is already true, so the postflight
  --     comparison has a before-value that was actually verified.
  assert public.rrule_sql_subset('FREQ=DAILY', true),
    'F.4 the all-day subset already rejects a plain DAILY rule; 0006/0007 are broken';
  assert public.rrule_timed_sql_subset('FREQ=WEEKLY;BYDAY=MO,WE', false),
    'F.4 the timed subset already rejects a plain WEEKLY rule; 0009 is broken';
  assert not public.rrule_sql_subset('FREQ=DAILY', false),
    'F.4 the all-day subset already admits a timed row';
  assert not public.rrule_timed_sql_subset('FREQ=DAILY', true),
    'F.4 the timed subset already admits an all-day row';

  -- F.5 MONTHLY is out, with COUNT and without. 0010 does not change this, and
  --     the 0010 suite would be testing nothing if it were already admitted.
  assert not public.rrule_sql_subset('FREQ=MONTHLY', true),
    'F.5 MONTHLY is already admitted by the all-day subset';
  assert not public.rrule_timed_sql_subset('FREQ=MONTHLY', false),
    'F.5 MONTHLY is already admitted by the timed subset';
  assert not public.rrule_sql_subset('FREQ=MONTHLY;COUNT=4', true),
    'F.5 MONTHLY+COUNT is already admitted by the all-day subset';

  raise notice '  COUNT is fail-closed on both paths; 0010 has not been applied';
end
$$;

-- ============================================================================
-- SECTION G -- get_free_busy, the function 0010 deliberately does NOT replace.
--
-- It never reads count_n; it reaches COUNT only through the six helpers, all of
-- which keep their exact signatures. That is why 0010 does not restate it, and
-- why its SECURITY DEFINER marker and anon grant are never put at risk of a
-- transcription slip.
--
-- Its signature, argument names, proacl and BODY HASH are recorded so the
-- postflight can prove 0010 left it entirely alone. RECORD THE LAST TWO LINES.
-- ============================================================================
do $$
declare
  v_count   integer;
  v_oids    oid[];
  v_types   text[];
  v_names   text[];
  v_acl     text;
  v_secdef  boolean;
  v_src_md5 text;
begin
  raise notice 'Section G: get_free_busy baseline (0010 must not touch it)';

  select count(*)
    into v_count
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_free_busy';

  assert v_count = 1,
    format('G.1 expected exactly one public.get_free_busy, found %s', v_count);

  select p.proargtypes::oid[], p.proargnames, p.proacl::text, p.prosecdef,
         md5(p.prosrc)
    into v_oids, v_names, v_acl, v_secdef, v_src_md5
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
    format('G.2 get_free_busy argument types changed: %s',
           coalesce(array_to_string(v_types, ', '), 'null'));

  -- Argument NAMES matter as much as the types: PostgREST passes by name.
  assert v_names = array['p_token', 'p_from', 'p_to',
                         'p_from_date', 'p_to_date']::text[],
    format('G.3 get_free_busy argument names changed: %s',
           coalesce(array_to_string(v_names, ', '), 'null'));

  assert v_secdef, 'G.4 get_free_busy must be SECURITY DEFINER before 0010 too';
  assert v_acl is not null,
    'G.5 get_free_busy has a NULL proacl; the anon/authenticated grant is gone';

  -- RECORD BOTH LINES. 0010 does not replace this function, so the postflight
  -- must see the SAME body hash and the SAME acl. A changed body hash after
  -- applying 0010 means something replaced get_free_busy unexpectedly.
  raise notice '  get_free_busy proacl     (record): %', v_acl;
  raise notice '  get_free_busy prosrc md5 (record): %', v_src_md5;
end
$$;

-- ============================================================================
-- SECTION H -- prerequisites of the 0010 TEST SUITE.
--
-- The suite needs a DEDICATED TEST USER owning no events, exactly like the
-- 0006/0007/0009 suites. It also builds one fixture the 0008 trigger forbids --
-- a master whose zone this server cannot resolve, to prove COUNT does not
-- change the fail-closed path -- by disabling events_validate_timezone for the
-- length of ONE insert inside its own transaction, re-enabling on the very next
-- statement, and ending in ROLLBACK.
--
-- EDIT v_owner if this project uses a different development test user.
-- ============================================================================
do $$
declare
  v_owner    constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';  -- <<< EDIT per project
  v_events   integer;
  v_enabled  "char";
  v_tblowner name;
  v_super    boolean;
  v_notnull  boolean;
begin
  raise notice 'Section H: prerequisites of the 0010 test suite';

  assert exists (select 1 from auth.users u where u.id = v_owner),
    'H.1 the dedicated test user does not exist; edit v_owner here and in the suite';

  select count(*)
    into v_events
  from public.events e
  where e.owner_id = v_owner;

  assert v_events = 0,
    format('H.2 the test owner holds %s events; the 0010 suite requires zero. '
           'Point v_owner at a dedicated test user; do NOT delete events to '
           'satisfy this assertion.', v_events);

  select t.tgenabled
    into v_enabled
  from pg_catalog.pg_trigger t
  where t.tgrelid = 'public.events'::regclass
    and t.tgname = 'events_validate_timezone'
    and not t.tgisinternal;

  assert v_enabled is not null,
    'H.3 trigger events_validate_timezone is missing; apply 0008 first';
  assert v_enabled = 'O',
    format('H.3 trigger events_validate_timezone is not enabled (tgenabled=%s). '
           'A previous run may have left it disabled; fix that first', v_enabled);

  select r.rolname
    into v_tblowner
  from pg_catalog.pg_class c
  join pg_catalog.pg_roles r on r.oid = c.relowner
  where c.oid = 'public.events'::regclass;

  select r.rolsuper
    into v_super
  from pg_catalog.pg_roles r
  where r.rolname = current_user;

  raise notice '  current_user = %, public.events owner = %, superuser = %',
    current_user, v_tblowner, coalesce(v_super, false);

  -- ALTER TABLE ... DISABLE TRIGGER requires table ownership or superuser.
  -- Required literally: current_user must BE the owner, or be a superuser.
  assert current_user = v_tblowner or coalesce(v_super, false),
    format('H.4 role %s is neither the owner of public.events (%s) nor a '
           'superuser, so it cannot disable and re-enable the trigger. Run the '
           '0010 suite as the table owner', current_user, v_tblowner);

  select a.attnotnull
    into v_notnull
  from pg_catalog.pg_attribute a
  where a.attrelid = 'public.events'::regclass
    and a.attname = 'timezone'
    and not a.attisdropped;

  assert v_notnull is not null,
    'H.5 column public.events.timezone is missing; apply 0008 first';
  assert v_notnull = false,
    'H.5 public.events.timezone is NOT NULL; the unresolvable-zone fixture can '
    'no longer be built and the 0010 fail-closed tests must be redesigned';

  -- The suite writes masters carrying a COUNT rrule through the NORMAL path. If
  -- a CHECK constraint rejected COUNT at write time, 0010 would be unreachable
  -- from the application and the suite could not build its fixtures at all.
  assert exists (
    select 1
    from pg_catalog.pg_constraint c
    where c.conrelid = 'public.events'::regclass
      and c.conname = 'events_time_shape'
  ), 'H.6 constraint events_time_shape is missing; apply 0001 first';

  raise notice '  test-suite prerequisites OK';
end
$$;

-- ============================================================================
-- SECTION I -- OBSERVATION ONLY. No assertions: this section records the
-- ordinal arithmetic 0010 is about to implement, computed here in plain SQL,
-- and does not gate the migration. A SQL error here is still a preflight
-- failure, as everywhere else.
--
-- The case is the one src/services/recurrence.test.ts pins on the TypeScript
-- side, so a disagreement after applying is read against a value that was
-- computed BEFORE the migration existed.
--
--   WEEKLY;BYDAY=MO,WE,FR;COUNT=7 from Wednesday 2026-03-04:
--     sorted offsets are MO=0, WE=2, FR=4, so k = 3
--     week 0 keeps the offsets >= DTSTART's weekday (WE=2): {WE, FR}, so pw0 = 2
--     ordinals  WE=0 FR=1 | MO=2 WE=3 FR=4 | MO=5 WE=6 FR=7(excluded by COUNT)
--     the 7th and last occurrence is therefore Wednesday 2026-03-18.
-- ============================================================================
do $$
declare
  v_s     constant date    := date '2026-03-04';   -- a Wednesday
  v_k     constant integer := 3;                   -- MO, WE, FR
  v_pw0   constant integer := 2;                   -- WE, FR survive week 0
  v_cnt   constant integer := 7;
  v_w0    date;
  v_hi    integer;
begin
  raise notice 'Section I: ordinal-contract observation (no assertions)';
  raise notice '  DTSTART %, isodow % (1 = Monday)', v_s, extract(isodow from v_s);

  v_w0 := v_s - (extract(isodow from v_s)::integer - 1);

  if v_cnt <= v_pw0 then
    v_hi := 0;
  else
    v_hi := 1 + floor((v_cnt - 1 - v_pw0)::numeric / v_k);
  end if;

  raise notice '  k = %, pw0 = %, COUNT = %  ->  last week index hi = %',
    v_k, v_pw0, v_cnt, v_hi;
  raise notice '  Monday anchor of week 0 : %', v_w0;
  raise notice '  last occurrence (anchor + hi*7 + WE offset 2) : %',
    v_w0 + (v_hi * 7 + 2);
end
$$;

do $$
begin
  raise notice 'PREFLIGHT PASSED -- 0010 may be applied';
end
$$;

rollback;
