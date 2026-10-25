-- ============================================================================
-- TimeWeave -- PREFLIGHT for 0018_freebusy_timezone_resolution.sql (A1).
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run by hand, once, against the project
-- 0018 will be applied to, BEFORE applying it. Valid only for the frozen 0018:
--
--   sha256   e3ae8d5809efdaadb88c27f5b9512c9ba191ce30f9034addf2c4bb9a03762b62
--   git blob 0f39a813988d80c63df5a76044633ee8fdb1462d   (47,217 bytes, 1,088 lines)
--
-- READ-ONLY: SELECT and catalog inspection only. No DDL, no DML, no SET, no
-- temp table, no advisory lock, nothing that fires a trigger, and no call to
-- get_free_busy or any other RPC. The only functions it calls besides catalog
-- functions are public.timezone_is_resolvable (T and D sections) -- STABLE,
-- reads only its argument and pg_timezone_names. One statement inside a
-- read-only transaction that ends in ROLLBACK. No timing or load measurement.
--
-- WHAT IT GATES
--
--   V. context     server, role running the migration, and that it owns    V01-V04
--                  get_free_busy (CREATE OR REPLACE needs ownership)
--   F. rpc         get_free_busy: one overload, exact signature, DEFINER,  F01-F13
--                  STABLE, search_path, ACL, production-before body
--   H. helpers     the two public timed helpers: one each, signatures,     H01-H17
--                  INVOKER, STABLE, search_path, bodies -- and THE
--                  PRIVILEGE GATE (H11/H12): nobody but their owner may
--                  hold EXECUTE, because 0018's wrappers delegate into
--                  timeweave_private, which only the owner can reach
--   Z. deps        timezone_is_resolvable / timezone_is_supported and the  Z01-Z08
--                  helpers the new private functions call: bodies
--                  unchanged, same owner
--   S. schema      timeweave_private exists, same owner, nobody else has   S01-S04
--                  USAGE or CREATE
--   C. collide     nothing 0018 creates exists yet and no body is already  C01-C06
--                  rewritten -- no prior or partial apply
--   U. callers     exactly the expected functions reference the timed      U01-U03
--                  helpers and timezone_is_resolvable
--   T. semantics   the zone predicate still answers as 0009 specified      T01-T06
--   D. data        counts only: timed masters and their distinct zones     D01-D05
--   P. privs       default privileges that would shape the new functions'  P01-P02
--                  ACL beyond what 0018 revokes
--   X. baseline    fingerprints 0018 must NOT move (compare production-    X01-X02
--                  before to production-after)
--
-- BODY FINGERPRINTS are md5 of prosrc with CR removed (production has shown
-- CRLF bodies before), compared with a clean local 0001..0017 build. If a
-- strict fingerprint FAILs, its whitespace-collapsed companion (context row,
-- local value quoted in the metric) tells a whitespace-only difference from a
-- real one. Either way: STOP and investigate before applying.
--
-- PRIVACY. Counts, catalog text, ACLs and source hashes only. No title,
-- description, label, token, row id or owner id is ever returned.
--
-- READING THE OUTPUT. status 'ok' / 'FAIL' where an expectation exists,
-- 'context' otherwise. P00 summarises. Any FAIL: STOP, do not apply.
-- ============================================================================
begin transaction read only;

with
fn as (
  select n.nspname as nsp, p.proname, p.oid, p.proowner,
         pg_catalog.pg_get_function_identity_arguments(p.oid) as args,
         pg_catalog.pg_get_function_result(p.oid) as ret,
         p.prosecdef, p.provolatile, p.proconfig, p.proacl, l.lanname,
         md5(replace(p.prosrc, E'\r', '')) as h,
         md5(regexp_replace(p.prosrc, '\s+', ' ', 'g')) as hw,
         p.prosrc
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  join pg_catalog.pg_language l on l.oid = p.prolang
  where n.nspname not in ('pg_catalog', 'information_schema')
    and n.nspname not like 'pg\_%'
),
-- Bound to the EXACT signatures, so an extra overload is reported by F01/H01/H02
-- instead of breaking a scalar subquery; a missing or changed signature yields
-- NULLs, which FAIL every expectation below.
gfb as (select * from fn where oid = to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)')),
hc  as (select * from fn where oid = to_regprocedure('public.rrule_timed_occurrence_count(text, boolean, timestamptz, timestamptz, text, timestamptz, timestamptz)')),
hs  as (select * from fn where oid = to_regprocedure('public.rrule_timed_occurrence_starts(text, boolean, timestamptz, timestamptz, text, timestamptz, timestamptz)')),
dep as (select * from fn where nsp = 'public'
          and proname in ('timezone_is_resolvable', 'timezone_is_supported', 'rrule_timed_sql_subset',
                          'rrule_parse', 'rrule_timed_expansion_cap')),
own as (select min(proowner::text)::oid as o, count(*) as n from gfb),
-- EXECUTE holders other than the function's owner (PUBLIC = grantee 0). A NULL
-- proacl means the built-in default, i.e. PUBLIC may execute: counted as 1.
xo as (
  select f.oid, f.nsp, f.proname,
         case when f.proacl is null then 1
              else (select count(*) from pg_catalog.aclexplode(f.proacl) a
                     where a.privilege_type = 'EXECUTE' and a.grantee <> f.proowner) end as n
  from fn f
),
tp as (
  select n.oid, n.nspowner, n.nspacl from pg_catalog.pg_namespace n where n.nspname = 'timeweave_private'
),
tm as (
  select e.owner_id, e.timezone
  from public.events e
  where e.rrule is not null and e.all_day = false
),
res as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL'
         end as status
  from (values

    -- V. context.
    ('V01', 'context', 'server version', null, (select pg_catalog.version())),
    ('V02', 'context', 'server_version_num', null, current_setting('server_version_num')),
    ('V03', 'context', 'role that will run the migration', null, current_user::text),
    ('V04', 'context', 'that role owns get_free_busy', 'true',
     (select (pg_catalog.pg_get_userbyid(proowner) = current_user)::text from gfb)),

    -- F. get_free_busy, production-before.
    ('F01', 'rpc', 'public.get_free_busy overloads', '1',
     (select count(*) from fn where nsp = 'public' and proname = 'get_free_busy')::text),
    ('F02', 'rpc', 'identity arguments', 'p_token text, p_from timestamp with time zone, p_to timestamp with time zone, p_from_date date, p_to_date date',
     (select args from gfb)),
    ('F03', 'rpc', 'result type', 'jsonb', (select ret from gfb)),
    ('F04', 'rpc', 'SECURITY DEFINER', 'true', (select prosecdef::text from gfb)),
    ('F05', 'rpc', 'volatility', 's', (select provolatile::text from gfb)),
    ('F06', 'rpc', 'proconfig', 'search_path=""', (select array_to_string(proconfig, ',') from gfb)),
    ('F07', 'rpc', 'language', 'plpgsql', (select lanname::text from gfb)),
    ('F08', 'rpc', 'PUBLIC holds EXECUTE (NULL acl counts as yes)', 'false',
     (select (proacl is null or exists (select 1 from pg_catalog.aclexplode(proacl) a
                                         where a.grantee = 0 and a.privilege_type = 'EXECUTE'))::text from gfb)),
    ('F09', 'rpc', 'anon may EXECUTE', 'true', (select pg_catalog.has_function_privilege('anon', oid, 'EXECUTE')::text from gfb)),
    ('F10', 'rpc', 'authenticated may EXECUTE', 'true', (select pg_catalog.has_function_privilege('authenticated', oid, 'EXECUTE')::text from gfb)),
    ('F11', 'rpc', 'full ACL (0018 must leave it identical)', null, (select coalesce(array_to_string(proacl, ' '), '(default)') from gfb)),
    ('F12', 'rpc', 'body md5, CR removed (0009 body)', 'b06c05a5a0c7f10af81887c0f8e8d985', (select h from gfb)),
    ('F13', 'rpc', 'body md5, whitespace collapsed (local 6ffd4878c4b42aa7072ed6b0f113d10b)', null, (select hw from gfb)),

    -- H. the two public timed helpers, production-before, and the privilege gate.
    ('H01', 'helpers', 'public.rrule_timed_occurrence_count overloads', '1',
     (select count(*) from fn where nsp = 'public' and proname = 'rrule_timed_occurrence_count')::text),
    ('H02', 'helpers', 'public.rrule_timed_occurrence_starts overloads', '1',
     (select count(*) from fn where nsp = 'public' and proname = 'rrule_timed_occurrence_starts')::text),
    ('H03', 'helpers', 'count identity arguments', 'p_rrule text, p_all_day boolean, p_start_at timestamp with time zone, p_end_at timestamp with time zone, p_timezone text, p_from timestamp with time zone, p_to timestamp with time zone',
     (select args from hc)),
    ('H04', 'helpers', 'starts identity arguments', 'p_rrule text, p_all_day boolean, p_start_at timestamp with time zone, p_end_at timestamp with time zone, p_timezone text, p_from timestamp with time zone, p_to timestamp with time zone',
     (select args from hs)),
    ('H05', 'helpers', 'count result', 'bigint', (select ret from hc)),
    ('H06', 'helpers', 'starts result', 'SETOF timestamp with time zone', (select ret from hs)),
    ('H07', 'helpers', 'count SECURITY DEFINER', 'false', (select prosecdef::text from hc)),
    ('H08', 'helpers', 'starts SECURITY DEFINER', 'false', (select prosecdef::text from hs)),
    ('H09', 'helpers', 'volatility count|starts', 's|s', (select (select provolatile::text from hc) || '|' || (select provolatile::text from hs))),
    ('H10', 'helpers', 'proconfig count|starts', 'search_path=""|search_path=""',
     (select (select array_to_string(proconfig, ',') from hc) || '|' || (select array_to_string(proconfig, ',') from hs))),
    ('H11', 'helpers', 'PRIVILEGE GATE: count EXECUTE holders besides owner', '0',
     (select n::text from xo where oid = (select oid from hc))),
    ('H12', 'helpers', 'PRIVILEGE GATE: starts EXECUTE holders besides owner', '0',
     (select n::text from xo where oid = (select oid from hs))),
    ('H13', 'helpers', 'count body md5, CR removed (0010 body)', 'cb90d8b627db0781da8bc87857eabfd3', (select h from hc)),
    ('H14', 'helpers', 'starts body md5, CR removed (0010 body)', '72f99639a5a5fca2ad30f908be59e58a', (select h from hs)),
    ('H15', 'helpers', 'count body md5, whitespace collapsed (local 9f5e13cb446dbc78c0e5b19ca85e4640)', null, (select hw from hc)),
    ('H16', 'helpers', 'starts body md5, whitespace collapsed (local 75eeeb0691fc554b0080cf9e179cfd9f)', null, (select hw from hs)),
    ('H17', 'helpers', 'both helpers owned by get_free_busy''s owner', 'true',
     (select (count(*) = 2 and bool_and(f.proowner = (select o from own)))::text
        from (select proowner from hc union all select proowner from hs) f)),

    -- Z. functions the new private helpers and get_free_busy rely on: unchanged, same owner.
    ('Z01', 'deps', 'timezone_is_resolvable body md5, CR removed', '28e6b9f4d8a83a274226745edef206dc',
     (select string_agg(h, ',') from dep where proname = 'timezone_is_resolvable')),
    ('Z02', 'deps', 'timezone_is_supported body md5, CR removed', 'd6d46c844ff9c154870f67b757dd3b4f',
     (select string_agg(h, ',') from dep where proname = 'timezone_is_supported')),
    ('Z03', 'deps', 'rrule_timed_sql_subset body md5, CR removed', 'd34812cfb2fe12e0d44054751cee3430',
     (select string_agg(h, ',') from dep where proname = 'rrule_timed_sql_subset')),
    ('Z04', 'deps', 'rrule_parse body md5, CR removed', '2e59e47964e4f403914c86249a2daaaa',
     (select string_agg(h, ',') from dep where proname = 'rrule_parse')),
    ('Z05', 'deps', 'rrule_timed_expansion_cap body md5, CR removed', 'c9bb9b6680f94aa14aa2083dfcd4bd23',
     (select string_agg(h, ',') from dep where proname = 'rrule_timed_expansion_cap')),
    ('Z06', 'deps', 'all five owned by get_free_busy''s owner', 'true',
     (select (count(*) = 5 and bool_and(proowner = (select o from own)))::text from dep)),
    ('Z07', 'deps', 'timezone_is_resolvable ACL', null,
     (select coalesce(array_to_string(proacl, ' '), '(default)') from dep where proname = 'timezone_is_resolvable')),
    ('Z08', 'deps', 'timezone_is_supported ACL (authenticated grant is intentional, 0008)', null,
     (select coalesce(array_to_string(proacl, ' '), '(default)') from dep where proname = 'timezone_is_supported')),

    -- S. timeweave_private.
    ('S01', 'schema', 'timeweave_private exists', '1', (select count(*) from tp)::text),
    ('S02', 'schema', 'owned by get_free_busy''s owner', 'true', (select (nspowner = (select o from own))::text from tp)),
    ('S03', 'schema', 'USAGE/CREATE holders besides owner (incl. PUBLIC)', '0',
     (select count(*) from tp, pg_catalog.aclexplode(coalesce(tp.nspacl, array[]::aclitem[])) a where a.grantee <> tp.nspowner)::text),
    ('S04', 'schema', 'USAGE for anon|authenticated|service_role|authenticator', 'false|false|false|false',
     (select pg_catalog.has_schema_privilege('anon', 'timeweave_private', 'USAGE')::text || '|'
          || pg_catalog.has_schema_privilege('authenticated', 'timeweave_private', 'USAGE')::text || '|'
          || pg_catalog.has_schema_privilege('service_role', 'timeweave_private', 'USAGE')::text || '|'
          || pg_catalog.has_schema_privilege('authenticator', 'timeweave_private', 'USAGE')::text)),

    -- C. collisions / prior or partial apply.
    ('C01', 'collide', 'any function named rrule_timed_occurrence_count_in_zones', '0',
     (select count(*) from fn where proname = 'rrule_timed_occurrence_count_in_zones')::text),
    ('C02', 'collide', 'any function named rrule_timed_occurrence_starts_in_zones', '0',
     (select count(*) from fn where proname = 'rrule_timed_occurrence_starts_in_zones')::text),
    ('C03', 'collide', 'any function whose name ends in _in_zones', '0',
     (select count(*) from fn where proname like '%\_in\_zones')::text),
    ('C04', 'collide', 'functions in timeweave_private', null,
     (select count(*) from fn where nsp = 'timeweave_private')::text),
    ('C05', 'collide', 'get_free_busy body already references timeweave_private / v_tz_all', '0',
     (select count(*) from gfb where prosrc ~ '(timeweave_private|v_tz_all|_in_zones)')::text),
    ('C06', 'collide', 'public timed helper bodies already reference timeweave_private', '0',
     (select count(*) from (select prosrc from hc union all select prosrc from hs) b where prosrc ~ 'timeweave_private')::text),

    -- U. callers.
    ('U01', 'callers', 'functions referencing rrule_timed_occurrence_(count|starts)',
     'public.get_free_busy,public.rrule_timed_occurrence_starts',
     (select string_agg(nsp || '.' || proname, ',' order by nsp || '.' || proname collate "C")
        from fn where prosrc ~ 'rrule_timed_occurrence_(count|starts)')),
    ('U02', 'callers', 'functions referencing timezone_is_resolvable',
     'public.get_free_busy,public.rrule_timed_occurrence_count,public.rrule_timed_occurrence_starts',
     (select string_agg(nsp || '.' || proname, ',' order by nsp || '.' || proname collate "C")
        from fn where prosrc ~ 'timezone_is_resolvable' and proname <> 'timezone_is_resolvable')),
    ('U03', 'callers', 'functions referencing timezone_is_supported', null,
     (select string_agg(nsp || '.' || proname, ',' order by nsp || '.' || proname collate "C")
        from fn where prosrc ~ 'timezone_is_supported' and proname <> 'timezone_is_supported')),

    -- T. zone semantics 0018 relies on (0009 section 2).
    ('T01', 'semantics', 'resolvable(UTC)', 'true', public.timezone_is_resolvable('UTC')::text),
    ('T02', 'semantics', 'resolvable(Asia/Tokyo)', 'true', public.timezone_is_resolvable('Asia/Tokyo')::text),
    ('T03', 'semantics', 'resolvable(America/New_York)', 'true', public.timezone_is_resolvable('America/New_York')::text),
    ('T04', 'semantics', 'resolvable(JST) -- abbreviation refused', 'false', public.timezone_is_resolvable('JST')::text),
    ('T05', 'semantics', 'resolvable(asia/tokyo) -- case variant refused', 'false', public.timezone_is_resolvable('asia/tokyo')::text),
    ('T06', 'semantics', 'resolvable(NULL)', 'false', public.timezone_is_resolvable(null)::text),

    -- D. data, counts only. D03 validates each distinct zone once (array, not a pushed-down filter).
    ('D01', 'data', 'timed recurring masters', null, (select count(*) from tm)::text),
    ('D02', 'data', 'distinct non-null zones among them', null, (select count(distinct timezone) from tm)::text),
    ('D03', 'data', 'of those, resolvable now', null,
     (select count(*) from unnest(array(select distinct timezone from tm where timezone is not null)) as z(tz)
       where public.timezone_is_resolvable(z.tz))::text),
    ('D04', 'data', 'timed recurring masters with NULL zone (legacy M0)', null, (select count(*) from tm where timezone is null)::text),
    ('D05', 'data', 'max distinct zones for one owner', null,
     (select coalesce(max(n), 0)::text from (select count(distinct timezone) as n from tm group by owner_id) q)),

    -- P. default privileges that could reach the two new functions.
    ('P01', 'privs', 'default FUNCTION ACLs for this role (timeweave_private or global)', null,
     (select coalesce(string_agg(coalesce(n.nspname, '*') || '=' || array_to_string(d.defaclacl, ' '), '; '), '(none)')
        from pg_catalog.pg_default_acl d
        left join pg_catalog.pg_namespace n on n.oid = d.defaclnamespace
       where d.defaclrole = current_user::regrole and d.defaclobjtype = 'f'
         and (n.nspname = 'timeweave_private' or d.defaclnamespace = 0))),
    ('P02', 'privs', 'those defaults grant EXECUTE beyond owner/PUBLIC/anon/authenticated/service_role', '0',
     (select count(*)
        from pg_catalog.pg_default_acl d
        left join pg_catalog.pg_namespace n on n.oid = d.defaclnamespace,
        pg_catalog.aclexplode(d.defaclacl) a
       where d.defaclrole = current_user::regrole and d.defaclobjtype = 'f'
         and (n.nspname = 'timeweave_private' or d.defaclnamespace = 0)
         and a.privilege_type = 'EXECUTE'
         and a.grantee <> 0
         and a.grantee not in (current_user::regrole::oid, 'anon'::regrole::oid,
                               'authenticated'::regrole::oid, 'service_role'::regrole::oid))::text),

    -- X. production-before fingerprints 0018 must NOT move.
    ('X01', 'baseline', 'md5 over every other public/timeweave_private function (sig|acl|cfg|secdef|body)', null,
     (select md5(string_agg(nsp || '.' || proname || '(' || args || ')|' || coalesce(array_to_string(proacl, ' '), '-') || '|'
                            || coalesce(array_to_string(proconfig, ','), '') || '|' || prosecdef::text || '|' || h,
                            ';' order by nsp || '.' || proname || '(' || args || ')' collate "C"))
        from fn where nsp in ('public', 'timeweave_private')
          and proname not in ('get_free_busy', 'rrule_timed_occurrence_count', 'rrule_timed_occurrence_starts',
                              'rrule_timed_occurrence_count_in_zones', 'rrule_timed_occurrence_starts_in_zones'))),
    ('X02', 'baseline', 'md5 over events + share_links trigger definitions', null,
     (select md5(string_agg(pg_catalog.pg_get_triggerdef(t.oid), ';' order by t.tgname collate "C"))
        from pg_catalog.pg_trigger t
       where t.tgrelid in ('public.events'::regclass, 'public.share_links'::regclass) and not t.tgisinternal))

  ) as v (ord, phase, metric, expected, value)
)
select ord, phase, metric, expected, value, status
from res
union all
select 'P00', 'summary', 'checks that FAIL', '0',
       count(*) filter (where status = 'FAIL')::text,
       case when count(*) filter (where status = 'FAIL') = 0 then 'ok' else 'FAIL' end
from res
order by 1;

rollback;
