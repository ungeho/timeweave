-- ============================================================================
-- 0023 POSTFLIGHT -- the database as it must look AFTER 0023 is applied
-- ============================================================================
-- READ THIS ROW FIRST: P00. GO requires P00 = 0.
--
-- SCOPE. This file is a CATALOG/STRUCTURAL gate only: signatures, grants,
-- volatility, search_path, body fingerprints and the presence or absence of
-- particular identifiers in the source text. It calls NO application function
-- and creates no fixture. The RUNTIME semantics -- what an active link actually
-- answers, what an unavailable link actually answers, whether the rate buckets
-- move -- are 0023_link_state_test.sql's job, and stating that boundary here
-- keeps this file runnable read-only against production.
--
-- SQL ERRORS ARE A STOP. Every object is reached through to_regprocedure /
-- to_regclass / to_regnamespace, so a missing one FAILs instead of aborting.
--
-- PRIVACY. Catalog text, counts, ACLs and hashes only.
--
-- ============================================================================
-- THE NEW WRAPPER FINGERPRINT
--
--   value       094c1439bc4f900cc1e1b6be1a014d83
--   source      supabase/migrations/0023_freebusy_link_state.sql
--   boundary    `as $fn$` on line 100, `$fn$;` on line 232
--   prosrc      the newline after `as $fn$`, lines 101-231, and the newline
--               before `$fn$;`. The CREATE FUNCTION header is NOT part of it.
--   size        5917 bytes, 132 newlines
--   recipe      { printf '\n'; sed -n '101,231p' 0023_freebusy_link_state.sql; } | md5sum
--
--   This literal was DERIVED from the migration source after the body existed,
--   with the identical recipe that reproduces the pre-0023 wrapper hash
--   (162c218d890630c6478c6e26638c2ca9 from 0019 lines 785-910, 5558 bytes) and
--   the core hash (a9b4097e4b390cee1229709945475d2b from 0021 lines 216-763,
--   24263 bytes). It was not guessed and not copied from any earlier file.
--
-- ============================================================================
-- THE EXACT-THREE-KEY ASSERTION IS A PHASE BOUNDARY, NOT A TIMELESS INVARIANT
--
-- W10/W11/W12 below, and the key-count assertions in the runtime suite, pin
-- that the anonymous answer carries exactly link_state, complete and slots.
-- That is U2's boundary: it is how we prove no Available work leaked in early.
-- A LATER MIGRATION (U3) IS EXPECTED TO SUPERSEDE IT DELIBERATELY by adding an
-- Available key to ACTIVE answers. When that happens these rows become
-- historical evidence in exactly the way 0022's B04 did -- they are not to be
-- weakened now, and not to be treated as permanent later.
--
-- HISTORICAL ASSERTIONS 0023 SUPERSEDES (recorded, NOT repaired):
--   0021_freebusy_busy_only_test.sql R8 P1/P2, R11, R17, R18 A/B -- required
--       wrapper JSONB = core JSONB; the wrapper now returns
--       core || {"link_state":"active"}. R18.A additionally required an
--       all-available calendar to answer exactly as an expired or unknown token
--       does, which is the identity U2 exists to remove.
--   0022_postflight.sql B04 -- required the wrapper body to mention neither
--       share_available nor link_state; the share_available half is re-gated
--       here as W11.
--   0022_share_available_test.sql 8.5 -- required no link_state key.
-- Those files remain byte-for-byte frozen and must not be re-run as
-- current-state gates.
--
-- THIS FILE CHANGES NOTHING.
-- ============================================================================

select to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)')
                                                                    as wrapper,
       to_regprocedure('timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')
                                                                    as core,
       to_regclass('public.share_links')                            as share_links,
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
cre as (select * from fn where oid = to_regprocedure(
          'public.create_share_link(text, boolean, timestamptz, boolean)')),
sav as (select * from fn where oid = to_regprocedure(
          'public.set_share_available(uuid, boolean)')),
lst as (select * from fn where oid = to_regprocedure('public.list_share_links()')),
sa as (
  select a.attname, a.attnotnull,
         pg_catalog.format_type(a.atttypid, a.atttypmod) as typ,
         pg_catalog.pg_get_expr(d.adbin, d.adrelid)      as dflt
  from pg_catalog.pg_attribute a
  left join pg_catalog.pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
  where a.attrelid = to_regclass('public.share_links') and a.attname = 'share_available'
    and a.attnum > 0 and not a.attisdropped
),
prt as (
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

    -- W. the wrapper: same shell, new body -----------------------------------
    ('W01','wrapper','GATE: identity arguments UNCHANGED',
      'p_token text, p_from timestamp with time zone, p_to timestamp with time zone, p_from_date date, p_to_date date',
      (select args from wrp)),
    ('W02','wrapper','GATE: still exactly one get_free_busy overload','1',
      (select count(*) from fn where nsp='public' and proname='get_free_busy')::text),
    ('W03','wrapper','GATE: result|language|volatility|security|search_path UNCHANGED',
      'jsonb|plpgsql|v|DEFINER|search_path=""',
      (select ret ||'|'|| lang ||'|'|| vol ||'|'||
              (case when secdef then 'DEFINER' else 'INVOKER' end) ||'|'|| coalesce(cfg,'-')
         from wrp)),
    ('W04','wrapper','GATE: anon EXECUTE | authenticated EXECUTE preserved','true|true',
      pg_catalog.has_function_privilege('anon',
        'public.get_free_busy(text, timestamptz, timestamptz, date, date)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('authenticated',
        'public.get_free_busy(text, timestamptz, timestamptz, date, date)','EXECUTE')::text),
    ('W05','wrapper','CONTEXT: PUBLIC EXECUTE -- must equal the preflight W05 value', null::text,
      pg_catalog.has_function_privilege('public',
        'public.get_free_busy(text, timestamptz, timestamptz, date, date)','EXECUTE')::text),
    ('W06','wrapper','GATE: body md5 == the new 0023 wrapper body',
      '094c1439bc4f900cc1e1b6be1a014d83',(select h from wrp)),
    ('W07','wrapper','GATE: body md5 is NO LONGER the 0019 body','false',
      (select (h = '162c218d890630c6478c6e26638c2ca9')::text from wrp)),
    ('W08','wrapper','GATE: link_state is emitted as a literal exactly twice','2',
      (select count(*) from pg_catalog.regexp_matches((select body from wrp),
        '''link_state''','g'))::text),
    -- W09 matches the CONSTRUCTION, not the bare word. A plain count of
    -- ''unavailable'' reads 2, because the step-2 comment 0023 added names the
    -- state in prose -- and a gate that a factual comment can break is a gate
    -- nobody will trust. jsonb_build_object never appears in a comment in this
    -- body (verified: zero comment lines contain it), so anchoring on the call
    -- distinguishes executable construction from prose.
    --
    -- \s* between the tokens makes this stable against re-indentation or a line
    -- break inserted between the arguments; the body is frozen in any case, so
    -- the only thing that could move is layout, which \s* absorbs.
    ('W09','wrapper','GATE: each link_state value is CONSTRUCTED exactly once','1|1',
      (select count(*) from pg_catalog.regexp_matches((select body from wrp),
        'jsonb_build_object\(\s*''link_state'',\s*''unavailable''','g'))::text ||'|'||
      (select count(*) from pg_catalog.regexp_matches((select body from wrp),
        'jsonb_build_object\(\s*''link_state'',\s*''active''\s*\)','g'))::text),
    ('W10','wrapper','GATE: U2 BOUNDARY -- no ''available'' key construction','0',
      (select count(*) from pg_catalog.regexp_matches((select body from wrp),
        '''available''\s*,','g'))::text),
    ('W11','wrapper','GATE: U2 BOUNDARY -- share_available absent from the wrapper','0',
      (select count(*) from pg_catalog.regexp_matches((select body from wrp),'share_available','g'))::text),
    ('W12','wrapper','GATE: U2 BOUNDARY -- no reason/status key construction','0',
      (select count(*) from pg_catalog.regexp_matches((select body from wrp),
        '''(reason|status)''','g'))::text),
    -- W13 asserts presence, so the value is a boolean and the expectation says
    -- so. It previously read '1|1|1|1' against (count(*) > 0)::text, which can
    -- only ever produce 'true' or 'false' -- the gate could not pass even on a
    -- perfectly correct database.
    ('W13','wrapper','GATE: the rate/concurrency machinery is still in the body',
      'true|true|true|true',
      (select (count(*) > 0)::text from pg_catalog.regexp_matches((select body from wrp),'freebusy_owner_rate','g'))
        ||'|'|| (select (count(*) > 0)::text from pg_catalog.regexp_matches((select body from wrp),'freebusy_link_rate','g'))
        ||'|'|| (select (count(*) > 0)::text from pg_catalog.regexp_matches((select body from wrp),'pg_try_advisory_xact_lock','g'))
        ||'|'|| (select (count(*) > 0)::text from pg_catalog.regexp_matches((select body from wrp),'free_busy_core','g'))),
    -- W14 checks the two range GUARDS structurally rather than counting the
    -- string "92 days", which occurs three times (the interval and both raise
    -- messages) and would change if anyone reworded an error message without
    -- touching the logic. These two predicates ARE the contract: one bounds the
    -- instant window, the other the date window.
    --
    -- SOURCE-PROVENANCE HEURISTIC, NOT RUNTIME PROOF. It establishes that the
    -- guards are still written in the body; that they still FIRE is proved at
    -- runtime by 0023_link_state_test.sql section 11.1/11.2.
    ('W14','wrapper','GATE: both 92-day range guards are still in the body','1|1',
      (select count(*) from pg_catalog.regexp_matches((select body from wrp),
        'p_to > p_from \+ interval ''92 days''','g'))::text ||'|'||
      (select count(*) from pg_catalog.regexp_matches((select body from wrp),
        'p_to_date - p_from_date > 92','g'))::text),
    ('W15','wrapper','CONTEXT: owner', null::text,
      (select pg_catalog.pg_get_userbyid(p.proowner) from pg_catalog.pg_proc p
        where p.oid = to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)'))),

    -- C. the core: FROZEN. This is the most important group in the file. -------
    ('C01','core','GATE: core body md5 STILL the canonical 0021 body',
      'a9b4097e4b390cee1229709945475d2b',(select h from cor)),
    ('C02','core','GATE: identity arguments unchanged',
      'p_link_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_from_date date, p_to_date date',
      (select args from cor)),
    ('C03','core','GATE: still exactly one free_busy_core overload','1',
      (select count(*) from fn where nsp='timeweave_private' and proname='free_busy_core')::text),
    ('C04','core','GATE: result|language|volatility|security|search_path unchanged',
      'jsonb|plpgsql|s|INVOKER|search_path=""',
      (select ret ||'|'|| lang ||'|'|| vol ||'|'||
              (case when secdef then 'DEFINER' else 'INVOKER' end) ||'|'|| coalesce(cfg,'-')
         from cor)),
    ('C05','core','GATE: still NOT executable by public|anon|authenticated','false|false|false',
      pg_catalog.has_function_privilege('public',
        'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('anon',
        'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)','EXECUTE')::text ||'|'||
      pg_catalog.has_function_privilege('authenticated',
        'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)','EXECUTE')::text),
    ('C06','core','GATE: core body mentions neither share_available nor link_state','0|0',
      (select count(*) from pg_catalog.regexp_matches((select body from cor),'share_available','g'))::text ||'|'||
      (select count(*) from pg_catalog.regexp_matches((select body from cor),'link_state','g'))::text),

    -- R. rate-limit infrastructure preserved ----------------------------------
    ('R01','rate','GATE: the four expected rate-state tables are still present','4',
      (select count(*) from prt
        where relname in ('event_write_rate','freebusy_link_rate',
                          'freebusy_owner_rate','share_link_create_rate'))::text),
    ('R02','rate','GATE: freebusy link interval|burst unchanged','00:00:02|15',
      (select timeweave_private.freebusy_link_rate_interval()::text ||'|'||
              timeweave_private.freebusy_link_rate_burst()::text)),
    ('R03','rate','GATE: freebusy owner interval|burst unchanged','00:00:01|40',
      (select timeweave_private.freebusy_owner_rate_interval()::text ||'|'||
              timeweave_private.freebusy_owner_rate_burst()::text)),
    ('R04','rate','GATE: concurrency slots unchanged','2',
      (select timeweave_private.freebusy_concurrency_slots()::text)),

    -- U. the U1/0022 surface, untouched by 0023 --------------------------------
    ('U01','u1','GATE: share_links.share_available type|NOT NULL|default',
      'boolean|true|false',
      (select typ ||'|'|| attnotnull::text ||'|'|| coalesce(dflt,'-') from sa)),
    ('U02','u1','GATE: create_share_link identity arguments',
      'p_label text, p_include_private boolean, p_expires_at timestamp with time zone, p_share_available boolean',
      (select args from cre)),
    ('U03','u1','GATE: set_share_available returns boolean','boolean',(select ret from sav)),
    ('U04','u1','GATE: list_share_links result includes share_available','1',
      (select count(*) from pg_catalog.regexp_matches((select ret from lst),'share_available','g'))::text),
    ('U05','u1','GATE: share_links RLS still enabled','true',
      (select c.relrowsecurity::text from pg_catalog.pg_class c
        where c.oid = to_regclass('public.share_links'))),

    -- X. context ----------------------------------------------------------------
    ('X01','context','CONTEXT: current_database / server version', null::text,
      (select pg_catalog.current_database() ||' | '|| pg_catalog.substring(version(), 1, 22)))

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
