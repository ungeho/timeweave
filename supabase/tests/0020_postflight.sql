-- ============================================================================
-- TimeWeave -- [STAGE 2 of 4] POSTFLIGHT for 0020_events_availability.sql
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run by hand, once, IMMEDIATELY AFTER
-- applying 0020 -- before 0021_preflight.sql and before ANY deploy. Valid only
-- for the frozen file:
--
--   sha256 ccecb6c475f3af586587d0f0a8948ff872eb79b025a48d0ffbf9d7ef084753cc
--                                              (11,939 bytes, 221 lines)
--
-- READ-ONLY: SELECT and catalog inspection only. No DDL, no DML, no SET, no
-- temp table, no advisory lock, no RPC call. The main check runs inside a
-- read-only transaction that ends in ROLLBACK.
--
-- RUNNING THIS AGAINST PRODUCTION NEEDS ITS OWN APPROVAL.
--
-- ----------------------------------------------------------------------------
-- HOW TO READ THE RESULT -- AND WHY P00 = 0 IS NOT ENOUGH
--
--   AUTOMATIC GATE    K01-K07, K10-K13, K15, R01-R04, U06, U07, U08.
--   MANUAL COMPARISON U01, U02, U03, U04, U05 carry NO expectation on purpose:
--                     they must equal, CHARACTER FOR CHARACTER, the values
--                     stage 1 printed as X01, X02, X03, X04 and S10. Nothing
--                     automates that comparison. Skipping it is skipping the
--                     check that 0020 moved nothing it should not have.
--   CONTEXT ONLY      K14 (record the rendering for future runs) and R05.
--
--   R05 IS NOT A GATE. The application is live between stage 1 and stage 2:
--   users insert, update and delete events, and deleting a recurrence master
--   cascades to its exception rows. A different row count from stage 1's D01
--   is NORMAL and is NOT a reason to stop. What 0020 cannot do is change an
--   existing row at all: the file contains no DML whatsoever, only ALTER TABLE
--   and COMMENT ON COLUMN. R01-R03 are the real data gates, and they are real
--   invariants -- with the correct ordering no deployed client can write
--   anything but 'busy'.
--
--   SO: GO means P00 = 0 AND U01-U05 match stage 1 AND the PostgREST probe
--   below came back clean. There is no arrangement in which running this file
--   alone decides anything.
--
-- SQL ERRORS ARE A STOP. Treat an error exactly as a FAIL.
--
-- NEXT STAGE: 0021_preflight.sql. Do NOT deploy the application yet -- 0021
-- must be applied and verified first, and a deploy on 0020 alone would let the
-- app write 'available' rows that the unpatched free_busy_core still discloses
-- as busy.
--
-- ----------------------------------------------------------------------------
-- POSTGREST SCHEMA CACHE -- SEPARATE, AND DELIBERATELY NARROW
--
-- Phase 1B writes `availability` in every insert payload, so PostgREST must
-- have the new column in its schema cache before the application is deployed.
-- The read-only probe for that is, as the owner, with limit=0 so that not one
-- row of anybody's calendar is returned:
--
--   GET /rest/v1/events?select=availability&limit=0
--
-- WHAT A SUCCESSFUL GET PROVES: the column name resolves in PostgREST's schema
-- cache. That is all, and it is exactly the one new failure mode 0020 creates.
--
-- WHAT IT DOES NOT PROVE, and must never be reported as proving:
--   * INSERT privilege -- a GET needs only SELECT
--   * RLS on write -- events_insert_own's WITH CHECK is never evaluated by a
--     read, and limit=0 evaluates no row policy at all
--   * the new CHECK constraint -- it fires only on write
--   * the ten triggers on public.events -- they fire only on INSERT/UPDATE
--   * that a write actually succeeds end to end
-- Those four layers are unchanged by 0020 (U01-U08 confirm it), but unchanged
-- is not the same as measured. A real INSERT is a separate, owner-performed
-- action needing its own approval; it is not part of this file.
--
-- MIGRATION HISTORY: this project has no supabase_migrations schema (README,
-- confirmed 2026-09-12), so "is 0020 recorded" cannot be asked here. The
-- record is this file's result plus an entry in README's applied-migration
-- table, in the format 0012 uses.
--
-- PRIVACY. Counts, catalog text, ACLs and hashes only.
-- ============================================================================


-- ============================================================================
-- (0) PRE-CHECK. Read this row FIRST. If any column is NULL, STOP.
-- ============================================================================
select to_regclass('public.events')                                as events,
       to_regprocedure('timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')
                                                                   as free_busy_core,
       (select count(*) from pg_catalog.pg_roles where rolname = 'anon')
                                                                   as anon_role_count;


-- ============================================================================
-- MAIN CHECK.
-- ============================================================================
begin transaction read only;

with
col as (
  select a.attname, a.attnum, a.attnotnull,
         pg_catalog.format_type(a.atttypid, a.atttypmod) as typ,
         pg_catalog.pg_get_expr(d.adbin, d.adrelid) as dflt
  from pg_catalog.pg_attribute a
  left join pg_catalog.pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
  where a.attrelid = 'public.events'::regclass and a.attnum > 0 and not a.attisdropped
),
con as (
  select c.conname, c.contype, c.convalidated,
         pg_catalog.pg_get_constraintdef(c.oid) as def
  from pg_catalog.pg_constraint c where c.conrelid = 'public.events'::regclass
),
av as (select * from col where attname='availability'),
ck as (select * from con where conname='events_availability_values'),
res as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL'
         end as status
  from (values

    -- K. the column exactly as 0020 declares it -------------------------------
    ('K01','column','availability exists exactly once','1',(select count(*) from av)::text),
    ('K02','column','type is text','text',(select typ from av)),
    ('K03','column','NOT NULL','true',(select attnotnull::text from av)),
    ('K04','column','DEFAULT','''busy''::text',(select dflt from av)),
    ('K05','column','it is the last column (nothing was reordered)','true',
      (select (attnum = (select max(attnum) from col))::text from av)),
    ('K06','column','column count is now 20','20',(select count(*) from col)::text),
    ('K07','column','the column comment is present','true',
      (select (pg_catalog.col_description('public.events'::regclass, attnum) is not null)::text
         from av)),

    -- K1x. the CHECK -----------------------------------------------------------
    ('K10','check','events_availability_values exists as a CHECK','1',
      (select count(*) from ck where contype='c')::text),
    ('K11','check','it is VALIDATED (not NOT VALID)','true',(select convalidated::text from ck)),
    -- Robust to the rendering: PostgreSQL normalises IN (...) to = ANY (ARRAY[...]),
    -- so the literals are counted instead of the definition being matched.
    ('K12','check','literal count | busy+available count','2|2',
      (select (select count(*) from regexp_matches((select def from ck),'''[a-z_]+''::text','g'))::text
           ||'|'||
              (select count(*) from regexp_matches((select def from ck),'''(busy|available)''::text','g'))::text)),
    ('K13','check','it constrains the availability column only','true',
      (select (def ~ 'availability'
          and def !~ '(visibility|title|rrule|start_|end_|is_cancelled|timezone)')::text from ck)),
    ('K14','check','RECORD THIS: exact definition as PostgreSQL renders it', null::text,
      (select def from ck)),
    -- 14 = the 13 that existed before 0020 (stage 1 S03) plus this one.
    ('K15','check','total CHECK constraints is now 14','14',
      (select count(*) from con where contype='c')::text),

    -- R. every existing row reads as busy ---------------------------------------
    ('R01','rows','rows with availability IS NULL','0',
      (select count(*) from public.events where availability is null)::text),
    ('R02','rows','rows outside the two allowed values','0',
      (select count(*) from public.events where availability not in ('busy','available'))::text),
    ('R03','rows','rows that are NOT busy','0',
      (select count(*) from public.events where availability <> 'busy')::text),
    -- An empty events table yields {} and that is a normal, passing case.
    ('R04','rows','distinct values present are {busy} (or {} on an empty table)','true',
      (select (coalesce(array_agg(distinct availability order by availability)::text,'{}')
               in ('{busy}','{}'))::text from public.events)),
    -- CONTEXT ONLY. See the header: drift from stage 1's D01 is normal on a
    -- live application and is NOT a stop condition.
    ('R05','rows','CONTEXT: total rows (drift from stage 1 D01 is normal)', null::text,
      (select count(*) from public.events)::text),

    -- U. nothing else moved. U01-U05 must be compared BY HAND with stage 1. -----
    ('U01','baseline','MANUAL: md5 over trigger definitions -- must equal stage 1 X01', null::text,
      (select md5(string_agg(pg_catalog.pg_get_triggerdef(t.oid), ';' order by t.tgname collate "C"))
         from pg_catalog.pg_trigger t
        where t.tgrelid='public.events'::regclass and not t.tgisinternal)),
    ('U02','baseline','MANUAL: md5 over RLS policies -- must equal stage 1 X02', null::text,
      (select md5(string_agg(p.polname||'|'||p.polcmd::text||'|'
                    ||coalesce(pg_catalog.pg_get_expr(p.polqual,p.polrelid),'-')||'|'
                    ||coalesce(pg_catalog.pg_get_expr(p.polwithcheck,p.polrelid),'-'),
                    ';' order by p.polname collate "C"))
         from pg_catalog.pg_policy p where p.polrelid='public.events'::regclass)),
    ('U03','baseline','MANUAL: md5 over the 13 PRE-EXISTING CHECKs -- must equal stage 1 X03', null::text,
      (select md5(string_agg(conname||'|'||def, ';' order by conname collate "C"))
         from con where contype='c' and conname <> 'events_availability_values')),
    ('U04','baseline','MANUAL: md5 over the 19 PRE-EXISTING columns -- must equal stage 1 X04', null::text,
      (select md5(string_agg(attname||'|'||typ||'|'||attnotnull::text||'|'||coalesce(dflt,'-'),
                    ';' order by attnum)) from col where attname <> 'availability')),
    ('U05','baseline','MANUAL: table ACL -- must equal stage 1 S10', null::text,
      (select coalesce(array_to_string(relacl,' '),'(default)') from pg_catalog.pg_class
        where oid='public.events'::regclass)),
    ('U06','baseline','RLS still enabled','true',
      (select relrowsecurity::text from pg_catalog.pg_class where oid='public.events'::regclass)),
    ('U07','baseline','anon still has nothing on events','false',
      pg_catalog.has_table_privilege('anon','public.events','SELECT')::text),
    ('U08','baseline','free_busy_core is STILL the 0019 body (0020 must not touch it)',
      'a7558dfa02a4ce6444d538e370eb631d',
      (select md5(replace(p.prosrc, E'\r','')) from pg_catalog.pg_proc p
        where p.oid = to_regprocedure(
          'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')))

  ) as v (ord, phase, metric, expected, value)
)
select ord, phase, metric, expected, value, status from res
union all
select 'P00','summary','checks that FAIL (necessary for GO, not sufficient -- see header)','0',
       count(*) filter (where status='FAIL')::text,
       case when count(*) filter (where status='FAIL')=0 then 'ok' else 'FAIL' end
from res
order by 1;

rollback;
