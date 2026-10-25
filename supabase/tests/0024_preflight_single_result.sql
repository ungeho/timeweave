-- ============================================================================
-- TimeWeave -- 0024 PREFLIGHT, SINGLE-RESULT-TABLE VARIANT.
--
-- PURPOSE. Convenience only. It evaluates THE SAME 36 CHECKS as the formal
-- preflight and emits them as ONE result table, so a Supabase SQL Editor
-- session needs one Run and one grid instead of three result sets.
--
-- IT IS NOT A REPLACEMENT FOR THE FORMAL PREFLIGHT AND IT LOOSENS NOTHING.
-- Every CTE, every row expression and every expected value is spliced verbatim
-- from:
--     supabase/tests/0024_preflight.sql
--     MD5 358bf8ea4f76ad680f650756c8eeabd1
-- Lines taken, unmodified:
--     fn / wrp / cor / sa / av    original 53-90
--     mr                          original 263-280  (`with mr as (` -> `mr as (`)
--     res   + its 28 rows         original 91-233
--     res2  + its 8 rows          original 281-368
--
-- THE TWO STATUS EXPRESSIONS ARE DELIBERATELY NOT UNIFIED. `res` carries a
-- `context` branch for NULL expectations; `res2` does not, because none of its
-- eight rows has a NULL expectation. Each block keeps its own expression, so
-- the verdict for every one of the 36 rows is computed exactly as the formal
-- preflight computes it.
--
-- THE ONLY ADDITIONS are a plain UNION ALL of the two already-scored blocks and
-- one extra summary row, ord 'ZZZ', carrying the FAIL count across ALL 36
-- checks. The formal preflight's own p00_fail_count covers only three of them,
-- which is why that row exists here.
--
-- READ-ONLY. One statement inside `begin transaction read only` ending in
-- ROLLBACK. Catalog reads and constant arithmetic only; no DDL, no DML, no DO
-- block, no SET, no temp object, and NO application function is ever invoked --
-- every function is named inside to_regprocedure / has_function_privilege.
--
-- GO REQUIRES: zero rows with status FAIL, including ord 'ZZZ' = 0.
-- A FAIL means STOP. Do not apply 0024.
-- ============================================================================

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
mr as (
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
),
all36 as (
  select ord, phase, metric, expected, value, status from res
  union all
  select ord, phase, metric, expected, value, status from res2
)
select ord, phase, metric, expected, value, status
from all36
union all
select 'ZZZ', 'summary', 'FAIL rows across ALL 36 checks (GO requires 0)', '0',
       (select count(*) filter (where status = 'FAIL') from all36)::text,
       case when (select count(*) filter (where status = 'FAIL') from all36) = 0
            then 'ok' else 'FAIL' end
order by ord;

rollback;
