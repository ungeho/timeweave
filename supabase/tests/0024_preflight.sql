-- ============================================================================
-- 0024 PREFLIGHT -- the database as it must look BEFORE 0024 is applied
-- ============================================================================
-- READ THESE ROWS FIRST: P00 and R01. GO requires P00 = 0 AND every R01 gate ok.
--
-- SCOPE. CATALOG/STRUCTURAL and read-only. It calls no application function,
-- creates no fixture and writes nothing, so it is safe against production. The
-- runtime semantics are 0024_available_test.sql's job, in an isolated database.
--
-- SQL ERRORS ARE A STOP. Every object is reached through to_regprocedure /
-- to_regclass / to_regnamespace / to_regtype, so a missing one FAILs its row
-- instead of aborting the file.
--
-- PRIVACY. Catalog text, counts, ACLs and hashes only. No row data, no tokens,
-- no user ids, no event content.
--
-- ============================================================================
-- R01 IS A HARD PRECONDITION, NOT AN ALGORITHM SELECTOR
--
-- 0024 requires native multiranges and ships NO fallback implementation. If any
-- R01 gate FAILs the correct outcome is:
--
--   PRECONDITION FAILURE -> STOP -> DO NOT APPLY 0024
--
-- and the matter returns to a planning gate. Do not substitute another
-- subtraction algorithm, and do not apply the migration "to see".
--
-- ============================================================================
-- THE TWO FROZEN FINGERPRINTS
--
--   core    a9b4097e4b390cee1229709945475d2b   0021 lines 216-763, 24263 bytes
--   wrapper 094c1439bc4f900cc1e1b6be1a014d83   0023 lines 101-231,  5917 bytes
--
--   recipe  { printf '\n'; sed -n '<first>,<last>p' <file>; } | md5sum
--           over the lines strictly between `as $fn$` and `$fn$;`.
--
-- E01 is the one that matters most across BOTH flight files: 0024 must not
-- disturb the core, and the preflight establishes what the postflight will
-- re-assert unchanged.
-- ============================================================================

select to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)')
                                                                    as wrapper,
       to_regprocedure('timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')
                                                                    as core,
       to_regclass('public.share_links')                            as share_links,
       to_regclass('public.events')                                 as events,
       to_regnamespace('timeweave_private')                         as private_schema;

begin transaction read only;

with
fn as (
  select p.oid,
         n.nspname                                              as nsp,
         p.proname,
         pg_catalog.pg_get_function_identity_arguments(p.oid)   as args,
         pg_catalog.pg_get_function_result(p.oid)               as ret,
         l.lanname                                              as lang,
         p.provolatile::text                                    as vol,
         p.prosecdef                                            as secdef,
         pg_catalog.array_to_string(p.proconfig, ',')           as cfg,
         p.prosrc                                               as body,
         pg_catalog.md5(pg_catalog.replace(p.prosrc, E'\r', '')) as h
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  join pg_catalog.pg_language  l on l.oid = p.prolang
),
wrp as (select * from fn where oid = to_regprocedure(
          'public.get_free_busy(text, timestamptz, timestamptz, date, date)')),
cor as (select * from fn where oid = to_regprocedure(
          'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')),
sa as (
  select a.attname, a.attnotnull,
         pg_catalog.format_type(a.atttypid, a.atttypmod) as typ,
         pg_catalog.pg_get_expr(d.adbin, d.adrelid)      as dflt
  from pg_catalog.pg_attribute a
  left join pg_catalog.pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
  where a.attrelid = to_regclass('public.share_links') and a.attname = 'share_available'
    and a.attnum > 0 and not a.attisdropped
),
av as (
  select a.attname, a.attnotnull,
         pg_catalog.format_type(a.atttypid, a.atttypmod) as typ,
         pg_catalog.pg_get_expr(d.adbin, d.adrelid)      as dflt
  from pg_catalog.pg_attribute a
  left join pg_catalog.pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
  where a.attrelid = to_regclass('public.events') and a.attname = 'availability'
    and a.attnum > 0 and not a.attisdropped
),
res as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL'
         end as status
  from (values

    -- P. no residue from an earlier attempt ----------------------------------
    ('P00','residue','GATE: the exact six-arg helper does NOT already exist','true',
      (to_regprocedure('timeweave_private.free_busy_available(uuid, timestamptz, timestamptz, date, date, jsonb)')
        is null)::text),
    ('P01','residue','GATE: ZERO functions named free_busy_available in timeweave_private','0',
      (select count(*) from fn where nsp='timeweave_private' and proname='free_busy_available')::text),

    -- E. the frozen core -- 0024 must not disturb it -------------------------
    ('E01','core','GATE: FROZEN body md5 (0021 lines 216-763)',
      'a9b4097e4b390cee1229709945475d2b', (select h from cor)),
    ('E02','core','GATE: identity arguments',
      'p_link_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_from_date date, p_to_date date',
      (select args from cor)),
    ('E03','core','GATE: result|language|volatility|security|search_path',
      'jsonb|plpgsql|s|INVOKER|search_path=""',
      (select ret ||'|'|| lang ||'|'|| vol ||'|'||
              (case when secdef then 'DEFINER' else 'INVOKER' end) ||'|'|| coalesce(cfg,'-')
         from cor)),
    ('E04','core','GATE: not executable by public|anon|authenticated|service_role',
      'false|false|false|false',
      pg_catalog.has_function_privilege('public',
        'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('anon',
        'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('authenticated',
        'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('service_role',
        'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)','EXECUTE')::text),

    -- W. the pre-0024 wrapper ------------------------------------------------
    ('W01','wrapper','GATE: PRE-0024 body md5 (0023 lines 101-231)',
      '094c1439bc4f900cc1e1b6be1a014d83', (select h from wrp)),
    ('W02','wrapper','GATE: identity arguments',
      'p_token text, p_from timestamp with time zone, p_to timestamp with time zone, p_from_date date, p_to_date date',
      (select args from wrp)),
    ('W03','wrapper','GATE: exactly one get_free_busy overload','1',
      (select count(*) from fn where nsp='public' and proname='get_free_busy')::text),
    ('W04','wrapper','GATE: result|language|volatility|security|search_path',
      'jsonb|plpgsql|v|DEFINER|search_path=""',
      (select ret ||'|'|| lang ||'|'|| vol ||'|'||
              (case when secdef then 'DEFINER' else 'INVOKER' end) ||'|'|| coalesce(cfg,'-')
         from wrp)),
    ('W05','wrapper','GATE: anon EXECUTE | authenticated EXECUTE','true|true',
      pg_catalog.has_function_privilege('anon',
        'public.get_free_busy(text, timestamptz, timestamptz, date, date)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('authenticated',
        'public.get_free_busy(text, timestamptz, timestamptz, date, date)','EXECUTE')::text),
    ('W06','wrapper','CONTEXT: PUBLIC EXECUTE -- the postflight must match THIS value',
      null::text,
      pg_catalog.has_function_privilege('public',
        'public.get_free_busy(text, timestamptz, timestamptz, date, date)','EXECUTE')::text),
    ('W07','wrapper','GATE: pre-0024 body mentions neither share_available nor available-status','0|0',
      (select count(*) from pg_catalog.regexp_matches((select body from wrp),
        'share_available','g'))::text ||'|'||
      (select count(*) from pg_catalog.regexp_matches((select body from wrp),
        'not_requested','g'))::text),

    -- S. schema prerequisites -------------------------------------------------
    ('S01','schema','GATE: share_links.share_available type|notnull|default',
      'boolean|true|false',
      (select typ ||'|'|| attnotnull::text ||'|'|| coalesce(dflt,'-') from sa)),
    ('S02','schema','GATE: events.availability type|notnull|default',
      'text|true|''busy''::text',
      (select typ ||'|'|| attnotnull::text ||'|'|| coalesce(dflt,'-') from av)),
    ('S03','schema','GATE: events_availability_values CHECK present','true',
      (select exists (select 1 from pg_catalog.pg_constraint c
                      where c.conrelid = to_regclass('public.events')
                        and c.conname = 'events_availability_values'))::text),
    ('S04','schema','GATE: time-shape | exception-slot | master-not-exception CHECKs present',
      'true|true|true',
      (select exists (select 1 from pg_catalog.pg_constraint c
         where c.conrelid=to_regclass('public.events') and c.conname='events_time_shape'))::text ||'|'||
      (select exists (select 1 from pg_catalog.pg_constraint c
         where c.conrelid=to_regclass('public.events') and c.conname='events_exception_slot'))::text ||'|'||
      (select exists (select 1 from pg_catalog.pg_constraint c
         where c.conrelid=to_regclass('public.events') and c.conname='events_master_not_exception'))::text),

    -- H. every helper 0024 reuses. A second recurrence engine is NOT written,
    --    so each of these must exist with the exact signature 0024 calls.
    ('H01','helpers','GATE: all-day recurrence helpers present','true|true|true',
      (to_regprocedure('public.rrule_allday_occurrence_starts(text, boolean, date, date, date, date)')
        is not null)::text ||'|'||
      (to_regprocedure('public.rrule_allday_occurrence_count(text, boolean, date, date, date, date)')
        is not null)::text ||'|'||
      (to_regprocedure('public.rrule_sql_subset(text, boolean)') is not null)::text),
    ('H02','helpers','GATE: timed in-zones helpers present','true|true',
      (to_regprocedure('timeweave_private.rrule_timed_occurrence_starts_in_zones(text, boolean, timestamptz, timestamptz, text, timestamptz, timestamptz, text[])')
        is not null)::text ||'|'||
      (to_regprocedure('timeweave_private.rrule_timed_occurrence_count_in_zones(text, boolean, timestamptz, timestamptz, text, timestamptz, timestamptz, text[])')
        is not null)::text),
    ('H03','helpers','GATE: timed subset | definitely-ends-before | zone probe','true|true|true',
      (to_regprocedure('public.rrule_timed_sql_subset(text, boolean)') is not null)::text ||'|'||
      (to_regprocedure('public.rrule_definitely_ends_before(text, boolean, date, date, timestamptz, timestamptz, timestamptz, date)')
        is not null)::text ||'|'||
      (to_regprocedure('public.timezone_is_resolvable(text)') is not null)::text),
    ('H04','helpers','GATE: both expansion caps present','true|true',
      (to_regprocedure('public.rrule_allday_expansion_cap()') is not null)::text ||'|'||
      (to_regprocedure('public.rrule_timed_expansion_cap()') is not null)::text),

    -- R02. the wrapper's own dependencies, unchanged by 0024 -------------------
    ('R02','rate','GATE: both rate tables present','true|true',
      (to_regclass('timeweave_private.freebusy_owner_rate') is not null)::text ||'|'||
      (to_regclass('timeweave_private.freebusy_link_rate')  is not null)::text),
    ('R03','rate','GATE: all five tuning functions present','5',
      (select count(*) from fn where nsp='timeweave_private'
         and proname in ('freebusy_link_rate_interval','freebusy_link_rate_burst',
                         'freebusy_owner_rate_interval','freebusy_owner_rate_burst',
                         'freebusy_concurrency_slots'))::text),

    -- R01. HARD PRECONDITION: native multirange support ----------------------
    --      A FAIL here means STOP. Do not apply 0024. Do not pick another
    --      algorithm -- 0024 contains only the multirange implementation.
    ('R01a','multirange','GATE: tstzmultirange | datemultirange types exist','true|true',
      (to_regtype('tstzmultirange') is not null)::text ||'|'||
      (to_regtype('datemultirange') is not null)::text),
    ('R01b','multirange','GATE: range_agg aggregate exists','true',
      (select exists (select 1 from pg_catalog.pg_proc p
                      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                      where n.nspname='pg_catalog' and p.proname='range_agg'
                        and p.prokind='a'))::text),
    --      R01c/R01d/R01e are NOT in this table. They EXERCISE the operations
    --      on constant inputs and therefore cannot be expressed as catalog
    --      lookups; they run as their own statement below, after this table has
    --      rendered, so a precondition failure never costs you the E/W context.

    -- Z. context --------------------------------------------------------------
    ('Z01','context','CONTEXT: server version', null::text,
      pg_catalog.current_setting('server_version')),
    ('Z02','context','CONTEXT: current database', null::text,
      pg_catalog.current_database()::text),
    ('Z03','context','CONTEXT: core body bytes', null::text,
      (select pg_catalog.length((select body from cor)))::text)

  ) as v(ord, phase, metric, expected, value)
)
select ord, phase, metric, expected, value, status
from res
order by ord;

-- ============================================================================
-- R01c / R01d / R01e -- THE MULTIRANGE OPERATIONS, EXERCISED.
--
-- WHY THESE ARE NOT CATALOG LOOKUPS. PostgreSQL declares every one of these
-- POLYMORPHICALLY -- range_agg(anyrange), unnest(anymultirange) and
-- `anymultirange - anymultirange`. to_regprocedure and a pg_operator lookup
-- both match DECLARED argument types with no polymorphic resolution, so asking
-- for range_agg(tstzrange) or an operator whose oprleft is tstzmultirange finds
-- nothing EVEN ON A SERVER THAT SUPPORTS ALL OF IT. A name-based gate here
-- would fail in the wrong direction: it would block a perfectly capable
-- environment while looking like a genuine shortfall.
--
-- So these gates run the exact operations 0024 performs, on constants, inside
-- this read-only transaction. They write nothing and leave no state.
--
-- A STRONGER ASSERTION THAN "IT RESOLVES": the subtraction gates check that
-- removing an interior range SPLITS the outer one into the two expected
-- fragments. That is the behaviour the helper depends on, not merely the
-- existence of an operator spelled '-'.
--
-- IF ANY ROW BELOW IS 'FAIL', OR IF THIS STATEMENT RAISES (which is what an
-- absent multirange TYPE will do, since the expressions cannot even parse):
--   PRECONDITION FAILURE -> STOP -> DO NOT APPLY 0024.
-- There is no subtraction fallback and no second algorithm to select.
-- ============================================================================
with mr as (
  select
    pg_catalog.tstzmultirange(
      tstzrange(timestamptz '2026-06-01 00:00:00+00',
                timestamptz '2026-06-05 00:00:00+00', '[)')) as ta,
    pg_catalog.tstzmultirange(
      tstzrange(timestamptz '2026-06-02 00:00:00+00',
                timestamptz '2026-06-03 00:00:00+00', '[)')) as tb,
    pg_catalog.tstzmultirange(
      tstzrange(timestamptz '2026-06-01 00:00:00+00',
                timestamptz '2026-06-02 00:00:00+00', '[)'),
      tstzrange(timestamptz '2026-06-03 00:00:00+00',
                timestamptz '2026-06-05 00:00:00+00', '[)')) as t_expected,
    pg_catalog.datemultirange(daterange(date '2026-06-01', date '2026-06-05', '[)')) as da,
    pg_catalog.datemultirange(daterange(date '2026-06-02', date '2026-06-03', '[)')) as db,
    pg_catalog.datemultirange(daterange(date '2026-06-01', date '2026-06-02', '[)'),
                              daterange(date '2026-06-03', date '2026-06-05', '[)')) as d_expected
),
res2 as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.value is not distinct from v.expected then 'ok' else 'FAIL' end as status
  from (values

    -- R01c. range_agg over a CONCRETE range of each model resolves, and the
    --       result's type is the multirange type the helper declares.
    ('R01c','multirange','GATE: range_agg(tstzrange)|range_agg(daterange) result types',
      'tstzmultirange|datemultirange',
      (select pg_catalog.pg_typeof(pg_catalog.range_agg(v.r))::text
         from (values (tstzrange(timestamptz '2026-06-01 00:00:00+00',
                                 timestamptz '2026-06-02 00:00:00+00','[)'))) as v(r))
      ||'|'||
      (select pg_catalog.pg_typeof(pg_catalog.range_agg(v.r))::text
         from (values (daterange(date '2026-06-01', date '2026-06-02','[)'))) as v(r))),

    -- R01c2. range_agg over ZERO rows yields NULL, which is what the helper's
    --        coalesce to an empty multirange depends on.
    ('R01c2','multirange','GATE: range_agg over zero rows is NULL (the coalesce premise)',
      'true|true',
      (select pg_catalog.range_agg(v.r) is null
         from (values (tstzrange(timestamptz '2026-06-01 00:00:00+00',
                                 timestamptz '2026-06-02 00:00:00+00','[)'))) as v(r)
        where false)::text
      ||'|'||
      (select pg_catalog.range_agg(v.r) is null
         from (values (daterange(date '2026-06-01', date '2026-06-02','[)'))) as v(r)
        where false)::text),

    -- R01d. Subtraction resolves AND splits correctly, for both models.
    ('R01d','multirange','GATE: multirange subtraction SPLITS as the helper requires',
      'true|true',
      (select (ta - tb) = t_expected from mr)::text ||'|'||
      (select (da - db) = d_expected from mr)::text),

    -- R01d2. The empty-operand cases the helper reaches whenever one side has
    --        no ranges at all.
    ('R01d2','multirange','GATE: empty-operand subtraction resolves',
      'true|true|true|true',
      (('{}'::tstzmultirange - '{}'::tstzmultirange) = '{}'::tstzmultirange)::text ||'|'||
      (('{}'::datemultirange - '{}'::datemultirange) = '{}'::datemultirange)::text ||'|'||
      ((select (ta - '{}'::tstzmultirange) = ta from mr))::text ||'|'||
      ((select ('{}'::tstzmultirange - ta) = '{}'::tstzmultirange from mr))::text),

    -- R01e. unnest over each multirange type yields the element count and the
    --       bounds the emission step reads with lower()/upper().
    ('R01e','multirange','GATE: unnest(tstzmultirange) element count | bounds',
      '2|true',
      (select pg_catalog.count(*) from mr, pg_catalog.unnest(mr.ta - mr.tb) as r)::text ||'|'||
      (select (pg_catalog.min(lower(r)) = timestamptz '2026-06-01 00:00:00+00'
           and pg_catalog.max(upper(r)) = timestamptz '2026-06-05 00:00:00+00')
         from mr, pg_catalog.unnest(mr.ta - mr.tb) as r)::text),
    ('R01e2','multirange','GATE: unnest(datemultirange) element count | bounds',
      '2|true',
      (select pg_catalog.count(*) from mr, pg_catalog.unnest(mr.da - mr.db) as r)::text ||'|'||
      (select (pg_catalog.min(lower(r)) = date '2026-06-01'
           and pg_catalog.max(upper(r)) = date '2026-06-05')
         from mr, pg_catalog.unnest(mr.da - mr.db) as r)::text),

    -- R01e3. lower()/upper() return the element types the emission step casts
    --        to jsonb. A wrong type here would silently change the wire shape.
    ('R01e3','multirange','GATE: lower()/upper() element types',
      'timestamp with time zone|date',
      (select pg_catalog.pg_typeof(lower(r))::text
         from mr, pg_catalog.unnest(mr.ta) as r limit 1) ||'|'||
      (select pg_catalog.pg_typeof(lower(r))::text
         from mr, pg_catalog.unnest(mr.da) as r limit 1)),

    -- R01f. range_agg NORMALISES touching ranges, which is what makes the
    --       helper's adjacency behaviour match the frozen Busy core's.
    ('R01f','multirange','GATE: range_agg merges touching ranges into one',
      '1|1',
      (select pg_catalog.count(*)
         from pg_catalog.unnest((select pg_catalog.range_agg(v.r)
           from (values
             (tstzrange(timestamptz '2026-06-01 00:00:00+00',
                        timestamptz '2026-06-02 00:00:00+00','[)')),
             (tstzrange(timestamptz '2026-06-02 00:00:00+00',
                        timestamptz '2026-06-03 00:00:00+00','[)'))) as v(r))) as r)::text
      ||'|'||
      (select pg_catalog.count(*)
         from pg_catalog.unnest((select pg_catalog.range_agg(v.r)
           from (values
             (daterange(date '2026-06-01', date '2026-06-02','[)')),
             (daterange(date '2026-06-02', date '2026-06-03','[)'))) as v(r))) as r)::text)

  ) as v(ord, phase, metric, expected, value)
)
select ord, phase, metric, expected, value, status
from res2
order by ord;

-- P00 again as a single number: GO requires 0.
select count(*) filter (where status = 'FAIL') as p00_fail_count
from (
  select case when to_regprocedure(
                 'timeweave_private.free_busy_available(uuid, timestamptz, timestamptz, date, date, jsonb)'
               ) is null then 'ok' else 'FAIL' end as status
  union all
  select case when pg_catalog.md5(pg_catalog.replace(
                 (select prosrc from pg_catalog.pg_proc
                  where oid = to_regprocedure(
                    'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')),
                 E'\r','')) = 'a9b4097e4b390cee1229709945475d2b'
              then 'ok' else 'FAIL' end
  union all
  select case when to_regtype('tstzmultirange') is not null
               and to_regtype('datemultirange') is not null
              then 'ok' else 'FAIL' end
) s;

rollback;
