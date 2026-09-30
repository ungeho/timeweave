-- ============================================================================
-- 0023 PREFLIGHT -- the database as it must look BEFORE 0023 is applied
-- ============================================================================
-- READ THIS ROW FIRST: P00. GO requires P00 = 0.
--
--   GATE rows      expected is non-null; ok or FAIL, never skipped.
--   CONTEXT rows   expected is null; recorded, never judged.
--
-- SQL ERRORS ARE A STOP. Treat an error exactly as a FAIL. Every object is
-- reached through to_regclass / to_regprocedure / to_regnamespace rather than a
-- bare ::regclass cast, so a MISSING object yields NULL -> FAIL instead of
-- aborting the statement and destroying the evidence in every other row.
--
-- PRIVACY. Catalog text, counts, ACLs and hashes only. No token, token_hash,
-- label, owner id or event content is selected anywhere.
--
-- THIS FILE DOES NOT DEPEND ON 0022's VALIDATION ARTIFACTS. 0022_preflight and
-- 0022_postflight are frozen U1 point-in-time evidence; some of their
-- assertions are intentionally superseded by 0023 (see the supersession note
-- below). Everything this file needs, it measures itself.
--
-- ============================================================================
-- THE CANONICAL PRE-0023 WRAPPER FINGERPRINT
--
--   value       162c218d890630c6478c6e26638c2ca9
--   source      supabase/migrations/0019_freebusy_rate_limit.sql
--               (get_free_busy was last defined in 0019, NOT in 0021 -- 0021
--               replaced only the private core and says so in its header)
--   boundary    `as $fn$` on line 784, `$fn$;` on line 911; that is the only
--               dollar-quoted body in the wrapper's CREATE statement
--   prosrc      exactly what lies BETWEEN the two delimiters: the newline that
--               follows `as $fn$`, lines 785-910, and the newline before
--               `$fn$;`. The CREATE FUNCTION header is NOT part of it.
--   size        5558 bytes, 127 newlines
--   recipe      { printf '\n'; sed -n '785,910p' 0019_freebusy_rate_limit.sql; } | md5sum
--
-- The same recipe applied to 0021_freebusy_busy_only.sql lines 216-763 yields
-- 24263 bytes / 549 newlines / a9b4097e4b390cee1229709945475d2b, the documented
-- core fingerprint -- which is how the recipe itself was verified rather than
-- assumed. Do NOT edit an expectation to agree with the database: refusing a
-- changed body is the whole point of these two rows.
--
-- ============================================================================
-- HISTORICAL ASSERTIONS 0023 SUPERSEDES (recorded here, NOT repaired)
--
--   0021_freebusy_busy_only_test.sql  R8 P1/P2, R11, R17, R18 A/B
--       required wrapper JSONB = core JSONB. U2 makes the wrapper answer
--       core || {"link_state":"active"}.
--   0022_postflight.sql  B04
--       required the wrapper body to mention neither share_available nor
--       link_state. The share_available half survives and is gated below.
--   0022_share_available_test.sql  assertion 8.5
--       required the anonymous answer to carry no link_state key.
--
-- Those files stay byte-for-byte frozen. They are historical evidence, not
-- current-state gates, and must not be re-run as if they were.
--
-- THIS FILE APPLIES NOTHING.
-- ============================================================================

-- ============================================================================
-- (0) PRE-CHECK. Read this row FIRST. A NULL column names a missing object.
-- ============================================================================
select to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)')
                                                                    as wrapper,
       to_regprocedure('timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')
                                                                    as core,
       to_regclass('public.share_links')                            as share_links,
       to_regclass('public.events')                                 as events,
       to_regnamespace('timeweave_private')                         as private_schema;


-- ============================================================================
-- MAIN CHECK.
-- ============================================================================
begin transaction read only;

with
fn as (   -- every function of interest, with \r-normalised bodies
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
cre as (select * from fn where oid = to_regprocedure(
          'public.create_share_link(text, boolean, timestamptz, boolean)')),
sav as (select * from fn where oid = to_regprocedure(
          'public.set_share_available(uuid, boolean)')),
lst as (select * from fn where oid = to_regprocedure('public.list_share_links()')),
sa as (   -- share_links.share_available
  select a.attname, a.attnotnull,
         pg_catalog.format_type(a.atttypid, a.atttypmod) as typ,
         pg_catalog.pg_get_expr(d.adbin, d.adrelid)      as dflt
  from pg_catalog.pg_attribute a
  left join pg_catalog.pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
  where a.attrelid = to_regclass('public.share_links') and a.attname = 'share_available'
    and a.attnum > 0 and not a.attisdropped
),
prt as (  -- timeweave_private rate-state tables
  select c.relname::text as relname
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'timeweave_private' and c.relkind = 'r'
),
res as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL'
         end as status
  from (values

    -- W. the public wrapper, as 0019 left it ---------------------------------
    ('W01','wrapper','GATE: identity arguments',
      'p_token text, p_from timestamp with time zone, p_to timestamp with time zone, p_from_date date, p_to_date date',
      (select args from wrp)),
    ('W02','wrapper','GATE: exactly one get_free_busy overload','1',
      (select count(*) from fn where nsp='public' and proname='get_free_busy')::text),
    ('W03','wrapper','GATE: result|language|volatility|security|search_path',
      'jsonb|plpgsql|v|DEFINER|search_path=""',
      (select ret ||'|'|| lang ||'|'|| vol ||'|'||
              (case when secdef then 'DEFINER' else 'INVOKER' end) ||'|'|| coalesce(cfg,'-')
         from wrp)),
    ('W04','wrapper','GATE: anon EXECUTE | authenticated EXECUTE','true|true',
      pg_catalog.has_function_privilege('anon',
        'public.get_free_busy(text, timestamptz, timestamptz, date, date)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('authenticated',
        'public.get_free_busy(text, timestamptz, timestamptz, date, date)','EXECUTE')::text),
    ('W05','wrapper','CONTEXT: PUBLIC EXECUTE (postflight must match this)', null::text,
      pg_catalog.has_function_privilege('public',
        'public.get_free_busy(text, timestamptz, timestamptz, date, date)','EXECUTE')::text),
    ('W06','wrapper','GATE: body md5 == the canonical 0019 wrapper body',
      '162c218d890630c6478c6e26638c2ca9',(select h from wrp)),
    ('W07','wrapper','GATE: body does NOT yet mention link_state','0',
      (select count(*) from pg_catalog.regexp_matches((select body from wrp),'link_state','g'))::text),
    ('W08','wrapper','GATE: body does not mention share_available','0',
      (select count(*) from pg_catalog.regexp_matches((select body from wrp),'share_available','g'))::text),
    ('W09','wrapper','CONTEXT: owner', null::text,
      (select pg_catalog.pg_get_userbyid(p.proowner) from pg_catalog.pg_proc p
        where p.oid = to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)'))),

    -- C. the private core, which 0023 must NOT touch --------------------------
    ('C01','core','GATE: identity arguments',
      'p_link_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_from_date date, p_to_date date',
      (select args from cor)),
    ('C02','core','GATE: exactly one free_busy_core overload','1',
      (select count(*) from fn where nsp='timeweave_private' and proname='free_busy_core')::text),
    ('C03','core','GATE: body md5 == the canonical 0021 core body',
      'a9b4097e4b390cee1229709945475d2b',(select h from cor)),
    ('C04','core','GATE: result|language|volatility|security|search_path',
      'jsonb|plpgsql|s|INVOKER|search_path=""',
      (select ret ||'|'|| lang ||'|'|| vol ||'|'||
              (case when secdef then 'DEFINER' else 'INVOKER' end) ||'|'|| coalesce(cfg,'-')
         from cor)),
    ('C05','core','GATE: NOT executable by public|anon|authenticated','false|false|false',
      pg_catalog.has_function_privilege('public',
        'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('anon',
        'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('authenticated',
        'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)','EXECUTE')::text),
    ('C06','core','GATE: core body does not mention share_available','0',
      (select count(*) from pg_catalog.regexp_matches((select body from cor),'share_available','g'))::text),

    -- R. the rate-limit infrastructure 0023 must leave alone -------------------
    ('R01','rate','GATE: timeweave_private schema present','1',
      (case when to_regnamespace('timeweave_private') is null then '0' else '1' end)),
    ('R02','rate','GATE: the four expected rate-state tables are present','4',
      (select count(*) from prt
        where relname in ('event_write_rate','freebusy_link_rate',
                          'freebusy_owner_rate','share_link_create_rate'))::text),
    ('R03','rate','GATE: freebusy link interval|burst','00:00:02|15',
      (select timeweave_private.freebusy_link_rate_interval()::text ||'|'||
              timeweave_private.freebusy_link_rate_burst()::text)),
    ('R04','rate','GATE: freebusy owner interval|burst','00:00:01|40',
      (select timeweave_private.freebusy_owner_rate_interval()::text ||'|'||
              timeweave_private.freebusy_owner_rate_burst()::text)),
    ('R05','rate','GATE: concurrency slots','2',
      (select timeweave_private.freebusy_concurrency_slots()::text)),

    -- U. the U1/0022 surface, which 0023 must leave intact ---------------------
    ('U01','u1','GATE: share_links.share_available type|NOT NULL|default',
      'boolean|true|false',
      (select typ ||'|'|| attnotnull::text ||'|'|| coalesce(dflt,'-') from sa)),
    ('U02','u1','GATE: create_share_link identity arguments',
      'p_label text, p_include_private boolean, p_expires_at timestamp with time zone, p_share_available boolean',
      (select args from cre)),
    ('U03','u1','GATE: old 3-arg create_share_link is still absent','0',
      (select count(*) from fn where oid = to_regprocedure(
        'public.create_share_link(text, boolean, timestamptz)'))::text),
    ('U04','u1','GATE: set_share_available(uuid, boolean) present and returns boolean',
      'boolean',(select ret from sav)),
    ('U05','u1','GATE: list_share_links result includes share_available','1',
      (select count(*) from pg_catalog.regexp_matches((select ret from lst),'share_available','g'))::text),
    ('U06','u1','GATE: share_links RLS enabled','true',
      (select c.relrowsecurity::text from pg_catalog.pg_class c
        where c.oid = to_regclass('public.share_links'))),

    -- X. context only ----------------------------------------------------------
    ('X01','context','CONTEXT: current_database / server version', null::text,
      (select pg_catalog.current_database() ||' | '|| pg_catalog.substring(version(), 1, 22))),
    ('X02','context','CONTEXT: total ordinary tables in timeweave_private', null::text,
      (select count(*)::text from prt))

  ) as v (ord, phase, metric, expected, value)
)
select ord, phase, metric, expected, value, status from res
union all
select 'P00','summary','GATE: checks that FAIL (GO requires 0)','0',
       count(*) filter (where status = 'FAIL')::text,
       case when count(*) filter (where status = 'FAIL') = 0 then 'ok' else 'FAIL' end
from res
order by 1;

rollback;
