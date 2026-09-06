-- TimeWeave Phase 5b-3 POSTFLIGHT for 0009_timed_recurrence_freebusy.sql.
--
-- READ ONLY. Contains no DDL, no DML and no SET. It reads pg_catalog,
-- pg_stat_user_tables and row counts only, so it is safe to run any number of
-- times, and it needs no transaction wrapper of its own.
--
-- RUN THIS IMMEDIATELY AFTER APPLYING 0009, BEFORE the 0009 test suite and
-- before the 0006/0007/0008 regressions.
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
-- TWO CHECKS NEED A BASELINE taken BEFORE the migration was applied:
--   * get_free_busy proacl -- recorded by the 0009 preflight (section E,
--     "get_free_busy proacl (record and compare after applying)").
--   * events / share_links row counts and write counters -- recorded by the
--     Step 0 snapshot in the apply procedure.
-- PART 2 prints the values as they are now; the comparison itself is yours.

-- ============================================================================
-- PART 1 -- HARD GATE.
-- ============================================================================
do $$
declare
  v_anon   oid;
  v_auth   oid;
  v_name     text;
  v_args     text;
  v_argnames text;
  v_result   text;
  v_vol    "char";
  v_secdef boolean;
  v_cfg    text[];
  v_acl    text;
  v_proacl aclitem[];
  v_has    boolean;
  v_n      integer;
  v_tg     "char";

  -- [1] proname
  -- [2] argument TYPES, comma joined, from pg_proc.proargtypes
  -- [3] argument NAMES, comma joined, from pg_proc.proargnames ('' when none)
  -- [4] result type
  -- [5] provolatile
  --
  -- Types and names are two separate columns because they are two separate
  -- catalog facts and must be asserted separately. Do NOT collapse them back
  -- into one string compared against pg_get_function_identity_arguments():
  -- that function renders NAMES alongside the types ("p_tz text", not "text"),
  -- so a bare type list can never match it. The 0009 preflight (E.2) carries
  -- the same warning for the same reason.
  v_expect constant text[][] := array[
    ['rrule_timed_expansion_cap',     '',                                    '',
       'integer',                                                            'i'],
    ['timezone_is_resolvable',        'text',                                'p_tz',
       'boolean',                                                            's'],
    ['rrule_timed_sql_subset',        'text, boolean',                       'p_rrule, p_all_day',
       'boolean',                                                            's'],
    ['rrule_timed_occurrence_count',
       'text, boolean, timestamp with time zone, timestamp with time zone, text, timestamp with time zone, timestamp with time zone',
       'p_rrule, p_all_day, p_start_at, p_end_at, p_timezone, p_from, p_to',
       'bigint',                                                             's'],
    ['rrule_timed_occurrence_starts',
       'text, boolean, timestamp with time zone, timestamp with time zone, text, timestamp with time zone, timestamp with time zone',
       'p_rrule, p_all_day, p_start_at, p_end_at, p_timezone, p_from, p_to',
       'SETOF timestamp with time zone',                                     's']
  ];
begin
  raise notice '0009 POSTFLIGHT -- part 1 (hard gate)';

  select r.oid into v_anon from pg_catalog.pg_roles r where r.rolname = 'anon';
  select r.oid into v_auth from pg_catalog.pg_roles r where r.rolname = 'authenticated';
  assert v_anon is not null and v_auth is not null,
    'P.0 roles anon and authenticated must both exist, or none of the ACL '
    'assertions below mean anything';

  -- --------------------------------------------------------------------------
  -- P.1 The five 0009 helpers: exist exactly once, with the intended signature,
  --     result type, volatility, SECURITY INVOKER and a pinned search_path.
  -- --------------------------------------------------------------------------
  for i in 1 .. array_length(v_expect, 1) loop
    v_name := v_expect[i][1];

    select count(*) into v_n
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_name;
    assert v_n = 1,
      format('P.1 expected exactly one public.%s, found %s', v_name, v_n);

    select coalesce((select string_agg(pg_catalog.format_type(u.t, null), ', ' order by u.ord)
                     from unnest(p.proargtypes::oid[]) with ordinality as u(t, ord)), ''),
           coalesce(array_to_string(p.proargnames, ', '), ''),
           pg_catalog.pg_get_function_result(p.oid),
           p.provolatile, p.prosecdef, p.proconfig, p.proacl::text, p.proacl
      into v_args, v_argnames, v_result, v_vol, v_secdef, v_cfg, v_acl, v_proacl
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_name;

    assert v_args = v_expect[i][2],
      format('P.1 public.%s argument TYPES are "%s", expected "%s"',
             v_name, v_args, v_expect[i][2]);
    -- Names are a separate catalog fact. They are not a wire contract for
    -- these five (get_free_busy calls them positionally), but a rename is
    -- still drift worth failing on, and it is the only way an in-place
    -- `create or replace` can be rejected later.
    assert v_argnames = v_expect[i][3],
      format('P.1 public.%s argument NAMES are "%s", expected "%s"',
             v_name, v_argnames, v_expect[i][3]);
    assert v_result = v_expect[i][4],
      format('P.1 public.%s returns %s, expected %s', v_name, v_result, v_expect[i][4]);
    assert v_vol = v_expect[i][5]::"char",
      format('P.1 public.%s volatility is %s, expected %s',
             v_name, v_vol, v_expect[i][5]);
    assert v_secdef = false,
      format('P.1 public.%s must be SECURITY INVOKER, not DEFINER', v_name);
    assert exists (select 1 from unnest(coalesce(v_cfg, array[]::text[])) c
                   where c like 'search_path=%'),
      format('P.1 public.%s must pin search_path, proconfig=%s',
             v_name, coalesce(array_to_string(v_cfg, ', '), 'null'));

    -- P.2 internal-only. A NULL proacl means the implicit default is back and
    --     PUBLIC can execute, so it must be checked BEFORE aclexplode, which
    --     returns no rows for NULL and would let a NULL pass as "no grants".
    assert v_acl is not null,
      format('P.2 public.%s has a NULL proacl: the default PUBLIC EXECUTE grant '
             'is in place and the REVOKE did not run', v_name);

    select exists (
      select 1 from pg_catalog.aclexplode(v_proacl) a
      where a.privilege_type = 'EXECUTE'
        and (a.grantee = 0 or a.grantee = v_anon or a.grantee = v_auth)
    ) into v_has;
    assert not v_has,
      format('P.2 public.%s must be internal-only, but PUBLIC, anon or '
             'authenticated holds EXECUTE: %s', v_name, v_acl);
  end loop;

  -- --------------------------------------------------------------------------
  -- P.3 get_free_busy: still exactly ONE. A `create or replace` whose argument
  --     TYPES drifted would have created a second overload silently, and
  --     PostgREST would then resolve calls by argument names to either one.
  -- --------------------------------------------------------------------------
  select count(*) into v_n
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_free_busy';
  assert v_n = 1, format('P.3 expected exactly one public.get_free_busy, found %s', v_n);

  select coalesce((select string_agg(pg_catalog.format_type(u.t, null), ', ' order by u.ord)
                   from unnest(p.proargtypes::oid[]) with ordinality as u(t, ord)), ''),
         pg_catalog.pg_get_function_result(p.oid),
         p.provolatile, p.prosecdef, p.proconfig, p.proacl::text, p.proacl
    into v_args, v_result, v_vol, v_secdef, v_cfg, v_acl, v_proacl
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_free_busy';

  assert v_args = 'text, timestamp with time zone, timestamp with time zone, date, date',
    format('P.4 get_free_busy argument TYPES are "%s"', v_args);
  assert v_result = 'jsonb', format('P.4 get_free_busy returns %s, expected jsonb', v_result);

  -- P.5 Argument NAMES. PostgREST passes arguments by name, so these are part
  --     of the wire contract exactly as much as the types are.
  assert (select p.proargnames
          from pg_catalog.pg_proc p
          join pg_catalog.pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname = 'get_free_busy')
         = array['p_token', 'p_from', 'p_to', 'p_from_date', 'p_to_date']::text[],
    format('P.5 get_free_busy argument names changed: %s',
           (select coalesce(array_to_string(p.proargnames, ', '), 'null')
            from pg_catalog.pg_proc p
            join pg_catalog.pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'get_free_busy'));

  assert v_secdef, 'P.6 get_free_busy must stay SECURITY DEFINER';
  assert v_vol = 's', format('P.6 get_free_busy must stay STABLE, provolatile=%s', v_vol);
  assert exists (select 1 from unnest(coalesce(v_cfg, array[]::text[])) c
                 where c like 'search_path=%'),
    format('P.6 get_free_busy must pin search_path, proconfig=%s',
           coalesce(array_to_string(v_cfg, ', '), 'null'));

  -- P.7 The grants 0005 made must have survived `create or replace`.
  assert v_acl is not null,
    'P.7 get_free_busy has a NULL proacl, so the anon/authenticated grants are '
    'gone AND the default PUBLIC grant is back';

  select exists (select 1 from pg_catalog.aclexplode(v_proacl) a
                 where a.privilege_type = 'EXECUTE' and a.grantee = v_anon) into v_has;
  assert v_has, format('P.7a anon lost EXECUTE on get_free_busy: %s', v_acl);

  select exists (select 1 from pg_catalog.aclexplode(v_proacl) a
                 where a.privilege_type = 'EXECUTE' and a.grantee = v_auth) into v_has;
  assert v_has, format('P.7b authenticated lost EXECUTE on get_free_busy: %s', v_acl);

  select exists (select 1 from pg_catalog.aclexplode(v_proacl) a
                 where a.privilege_type = 'EXECUTE' and a.grantee = 0) into v_has;
  assert not v_has,
    format('P.7c PUBLIC must not hold EXECUTE on get_free_busy: %s', v_acl);

  -- --------------------------------------------------------------------------
  -- P.8 0008 untouched: timezone_is_supported keeps the grant the write path
  --     depends on, and still is not public.
  -- --------------------------------------------------------------------------
  select p.proacl::text, p.proacl into v_acl, v_proacl
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'timezone_is_supported';
  assert v_acl is not null,
    'P.8 timezone_is_supported has a NULL proacl; 0008 grants are gone';

  select exists (select 1 from pg_catalog.aclexplode(v_proacl) a
                 where a.privilege_type = 'EXECUTE' and a.grantee = v_auth) into v_has;
  assert v_has,
    format('P.8a timezone_is_supported must stay executable by authenticated, '
           'or the write path breaks: %s', v_acl);

  select exists (select 1 from pg_catalog.aclexplode(v_proacl) a
                 where a.privilege_type = 'EXECUTE' and a.grantee = 0) into v_has;
  assert not v_has,
    format('P.8b PUBLIC must not hold EXECUTE on timezone_is_supported: %s', v_acl);

  -- --------------------------------------------------------------------------
  -- P.9 The 0006/0007 helpers are still internal-only. 0009 rewrote the
  --     function that calls them, so this is the cheapest place to notice a
  --     grant that came back.
  -- --------------------------------------------------------------------------
  foreach v_name in array array[
    'rrule_parse', 'rrule_sql_subset', 'rrule_definitely_ends_before',
    'rrule_allday_expansion_cap', 'rrule_allday_occurrence_count',
    'rrule_allday_occurrence_starts'
  ]
  loop
    select p.proacl::text, p.proacl into v_acl, v_proacl
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_name;
    assert v_acl is not null,
      format('P.9 public.%s has a NULL proacl, so PUBLIC can execute it', v_name);

    select exists (
      select 1 from pg_catalog.aclexplode(v_proacl) a
      where a.privilege_type = 'EXECUTE'
        and (a.grantee = 0 or a.grantee = v_anon or a.grantee = v_auth)
    ) into v_has;
    assert not v_has,
      format('P.9 public.%s must stay internal-only: %s', v_name, v_acl);
  end loop;

  -- --------------------------------------------------------------------------
  -- P.10 The 0008 write-path trigger is still armed. 0009 never touches it, but
  --      the 0009 SUITE disables it around two inserts, so a suite that aborted
  --      midway on an earlier run is the thing this catches.
  -- --------------------------------------------------------------------------
  select t.tgenabled into v_tg
  from pg_catalog.pg_trigger t
  where t.tgrelid = 'public.events'::regclass
    and t.tgname = 'events_validate_timezone'
    and not t.tgisinternal;
  assert v_tg is not null, 'P.10 trigger events_validate_timezone is missing from public.events';
  assert v_tg = 'O',
    format('P.10 events_validate_timezone must be enabled, tgenabled=%s '
           '(O=enabled, D=disabled, R=replica, A=always)', v_tg);

  raise notice '0009 POSTFLIGHT part 1 OK -- every hard invariant holds.';
  raise notice 'Now read the PART 2 table, and compare the two BASELINE groups by hand.';
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
    ('rrule_timed_expansion_cap',     '',              '(none)',
     'integer', 'IMMUTABLE', 'INVOKER'),
    ('timezone_is_resolvable',        'text',          'p_tz',
     'boolean', 'STABLE',    'INVOKER'),
    ('rrule_timed_sql_subset',        'text, boolean', 'p_rrule, p_all_day',
     'boolean', 'STABLE',    'INVOKER'),
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
--  1. the five new helpers + get_free_busy: shape, volatility, security
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
--  2. the five new helpers must be reachable by nobody
select 2, 'B. internal-only', x.name,
       case when x.acl_is_null then 'FAIL'
            when x.reachable_by_clients then 'FAIL'
            else 'PASS' end,
       (select acl from f where f.name = x.name),
       'no EXECUTE for PUBLIC / anon / authenticated, proacl NOT NULL'
from exposed x
where x.name in ('rrule_timed_expansion_cap', 'timezone_is_resolvable',
                 'rrule_timed_sql_subset', 'rrule_timed_occurrence_count',
                 'rrule_timed_occurrence_starts')

union all
--  3. the 0006/0007 helpers must have stayed that way
select 3, 'C. 0006/0007 internal-only', x.name,
       case when x.acl_is_null or x.reachable_by_clients then 'FAIL' else 'PASS' end,
       (select acl from f where f.name = x.name),
       'unchanged by 0009'
from exposed x
where x.name in ('rrule_parse', 'rrule_sql_subset', 'rrule_definitely_ends_before',
                 'rrule_allday_expansion_cap', 'rrule_allday_occurrence_count',
                 'rrule_allday_occurrence_starts')

union all
--  4. exactly one get_free_busy
select 4, 'D. get_free_busy', 'overload count',
       case when count(*) = 1 then 'PASS' else 'FAIL' end,
       count(*)::text, 'exactly 1'
from f where f.name = 'get_free_busy'

union all
--  5. its argument names -- the PostgREST wire contract
select 5, 'D. get_free_busy', 'argument names',
       case when f.argnames = 'p_token, p_from, p_to, p_from_date, p_to_date'
            then 'PASS' else 'FAIL' end,
       f.argnames, 'p_token, p_from, p_to, p_from_date, p_to_date'
from f where f.name = 'get_free_busy'

union all
--  6. its grants
select 6, 'D. get_free_busy', 'EXECUTE grants',
       case when x.acl_is_null then 'FAIL'
            when x.anon_exec and x.auth_exec and not x.public_exec then 'PASS'
            else 'FAIL' end,
       format('anon=%s authenticated=%s PUBLIC=%s | %s',
              x.anon_exec, x.auth_exec, x.public_exec,
              (select acl from f where f.name = 'get_free_busy')),
       'anon=true authenticated=true PUBLIC=false'
from exposed x where x.name = 'get_free_busy'

union all
--  7. 0008 must be untouched
select 7, 'E. 0008', 'timezone_is_supported EXECUTE',
       case when x.acl_is_null then 'FAIL'
            when x.auth_exec and not x.public_exec then 'PASS'
            else 'FAIL' end,
       format('anon=%s authenticated=%s PUBLIC=%s | %s',
              x.anon_exec, x.auth_exec, x.public_exec,
              (select acl from f where f.name = 'timezone_is_supported')),
       'authenticated=true PUBLIC=false'
from exposed x where x.name = 'timezone_is_supported'

union all
--  8. the 0008 write-path trigger
select 8, 'E. 0008', 'events_validate_timezone',
       case when t.tgenabled = 'O' then 'PASS' else 'FAIL' end,
       format('tgenabled=%s', t.tgenabled),
       'tgenabled=O (enabled)'
from pg_catalog.pg_trigger t
where t.tgrelid = 'public.events'::regclass
  and t.tgname = 'events_validate_timezone'
  and not t.tgisinternal

union all
--  9. BASELINE: compare this against the line the 0009 PREFLIGHT printed.
select 9, 'F. baseline (compare by hand)', 'get_free_busy proacl',
       'COMPARE',
       (select acl from f where f.name = 'get_free_busy'),
       'must equal the proacl the 0009 preflight recorded (section E)'

union all
-- 10. BASELINE: row counts. An additional post-apply sanity check against the
--     Step 0 snapshot.
select 10, 'F. baseline (compare by hand)',
       format('%s row count', c.rel),
       'COMPARE', c.n::text, 'must equal the Step 0 snapshot'
from (
  select 'public.events'::text      as rel, (select count(*) from public.events)      as n
  union all
  select 'public.share_links'::text,        (select count(*) from public.share_links)
) c

union all
-- 11. BASELINE: cumulative PostgreSQL statistics. Informational only:
--     compare these with the Step 0 baseline as an additional signal.
--     They are not a hard proof that 0009 itself performed, or did not
--     perform, DML.
select 11, 'F. baseline (compare by hand)',
       format('%s writes (ins/upd/del)', s.relname),
       'COMPARE',
       format('%s / %s / %s', s.n_tup_ins, s.n_tup_upd, s.n_tup_del),
       'must equal the Step 0 snapshot'
from pg_catalog.pg_stat_user_tables s
where s.schemaname = 'public' and s.relname in ('events', 'share_links')

order by seq, item;
