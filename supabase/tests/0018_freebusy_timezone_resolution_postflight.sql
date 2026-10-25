-- ============================================================================
-- TimeWeave -- POSTFLIGHT for 0018_freebusy_timezone_resolution.sql (A1).
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run by hand, once, against the project
-- 0018 was applied to, AFTER the apply. Valid only for the frozen 0018:
--
--   sha256   e3ae8d5809efdaadb88c27f5b9512c9ba191ce30f9034addf2c4bb9a03762b62
--   git blob 0f39a813988d80c63df5a76044633ee8fdb1462d   (47,217 bytes, 1,088 lines)
--
-- Production-before baselines are the Attempt-3 preflight result (2026-09-19,
-- direct PostgreSQL via the session pooler, FAIL 0):
--   X01 9fe515f1ec7489df45c51960b90a9176   X02 35f508637a7c1a995ba65caf1ebb7d54
--   F11 (checked here as F08) / Z07 / Z08 / U03 as quoted in the expectations below.
--
-- READ-ONLY: catalog inspection plus a few calls of pure functions on literal
-- arguments. One statement inside a read-only transaction that ends in
-- ROLLBACK. No DDL, no DML, no SET, no temp table, no advisory lock, nothing
-- that fires a trigger, no get_free_busy call, no table other than the
-- catalogs and a count over public.events (D section).
--
-- WHAT IT GATES
--
--   V. context     server, role                                              V01-V03
--   M. private     the two *_in_zones helpers exist exactly as 0018 made    M01-M20
--                  them: schema, signature, result, INVOKER, STABLE,
--                  search_path, language, owner, owner-only EXECUTE, body
--   S. schema      timeweave_private: same owner, nobody else holds USAGE   S01-S04
--                  or CREATE
--   H. public      the two public timed helpers: compatible signature,      H01-H16
--                  result, attributes and ACL; 0018 wrapper body;
--                  still self-validating; delegating to the private helpers
--   F. rpc         get_free_busy: signature, result, DEFINER, STABLE,       F01-F14
--                  search_path, ACL identical to production-before; 0018
--                  body (v_tz_all, v_ok_tz, *_in_zones; no public helper call)
--   Z. deps        helpers 0018 relies on but never touched: bodies,        Z01-Z08
--                  owners and ACLs identical to production-before
--   U. callers     who references the timed helpers and the zone predicate U01-U03
--   B. behaviour   pure calls on literal arguments: private == public,      B01-B06
--                  fail-soft on an absent / unresolvable zone
--   T. semantics   the zone predicate still answers as before               T01-T04
--   X. unrelated   every other public/timeweave_private function and every  X01-X04
--                  events/share_links trigger identical to production-before
--   D. data        counts only (context)                                    D01-D02
--
-- Body fingerprints are md5 of prosrc with CR removed, compared with a clean
-- local 0001..0018 build of the frozen files.
--
-- PRIVACY. Counts, catalog text, ACLs and hashes only. No title, description,
-- label, token, row id or owner id is ever returned.
--
-- READING THE OUTPUT. status 'ok' / 'FAIL' where an expectation exists,
-- 'context' otherwise. P00 summarises.
-- ============================================================================
begin transaction read only;

with
fn as (
  select n.nspname as nsp, p.proname, p.oid, p.proowner,
         pg_catalog.pg_get_function_identity_arguments(p.oid) as args,
         pg_catalog.pg_get_function_result(p.oid) as ret,
         p.prosecdef, p.provolatile, p.proconfig, p.proacl, l.lanname,
         md5(replace(p.prosrc, E'\r', '')) as h,
         regexp_replace(replace(p.prosrc, E'\r', ''), '--[^\n]*', '', 'g') as code,
         p.prosrc
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  join pg_catalog.pg_language l on l.oid = p.prolang
  where n.nspname not in ('pg_catalog', 'information_schema')
    and n.nspname not like 'pg\_%'
),
gfb as (select * from fn where oid = to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)')),
hc  as (select * from fn where oid = to_regprocedure('public.rrule_timed_occurrence_count(text, boolean, timestamptz, timestamptz, text, timestamptz, timestamptz)')),
hs  as (select * from fn where oid = to_regprocedure('public.rrule_timed_occurrence_starts(text, boolean, timestamptz, timestamptz, text, timestamptz, timestamptz)')),
pc  as (select * from fn where oid = to_regprocedure('timeweave_private.rrule_timed_occurrence_count_in_zones(text, boolean, timestamptz, timestamptz, text, timestamptz, timestamptz, text[])')),
ps  as (select * from fn where oid = to_regprocedure('timeweave_private.rrule_timed_occurrence_starts_in_zones(text, boolean, timestamptz, timestamptz, text, timestamptz, timestamptz, text[])')),
dep as (select * from fn where nsp = 'public'
          and proname in ('timezone_is_resolvable', 'timezone_is_supported', 'rrule_timed_sql_subset',
                          'rrule_parse', 'rrule_timed_expansion_cap')),
own as (select min(proowner::text)::oid as o from gfb),
xo as (
  select f.oid,
         case when f.proacl is null then 1
              else (select count(*) from pg_catalog.aclexplode(f.proacl) a
                     where a.privilege_type = 'EXECUTE' and a.grantee <> f.proowner) end as n
  from fn f
),
tp as (select n.oid, n.nspowner, n.nspacl from pg_catalog.pg_namespace n where n.nspname = 'timeweave_private'),
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
    ('V03', 'context', 'role running the postflight', null, current_user::text),

    -- M. the private helpers.
    ('M01', 'private', 'functions named rrule_timed_occurrence_count_in_zones (any schema)', '1',
     (select count(*) from fn where proname = 'rrule_timed_occurrence_count_in_zones')::text),
    ('M02', 'private', 'functions named rrule_timed_occurrence_starts_in_zones (any schema)', '1',
     (select count(*) from fn where proname = 'rrule_timed_occurrence_starts_in_zones')::text),
    ('M03', 'private', 'count_in_zones at the exact 8-argument signature in timeweave_private', '1', (select count(*) from pc)::text),
    ('M04', 'private', 'starts_in_zones at the exact 8-argument signature in timeweave_private', '1', (select count(*) from ps)::text),
    ('M05', 'private', 'count_in_zones identity arguments',
     'p_rrule text, p_all_day boolean, p_start_at timestamp with time zone, p_end_at timestamp with time zone, p_timezone text, p_from timestamp with time zone, p_to timestamp with time zone, p_resolvable_zones text[]',
     (select args from pc)),
    ('M06', 'private', 'starts_in_zones identity arguments',
     'p_rrule text, p_all_day boolean, p_start_at timestamp with time zone, p_end_at timestamp with time zone, p_timezone text, p_from timestamp with time zone, p_to timestamp with time zone, p_resolvable_zones text[]',
     (select args from ps)),
    ('M07', 'private', 'count_in_zones result', 'bigint', (select ret from pc)),
    ('M08', 'private', 'starts_in_zones result', 'SETOF timestamp with time zone', (select ret from ps)),
    ('M09', 'private', 'SECURITY DEFINER count|starts', 'false|false', (select (select prosecdef::text from pc) || '|' || (select prosecdef::text from ps))),
    ('M10', 'private', 'volatility count|starts', 's|s', (select (select provolatile::text from pc) || '|' || (select provolatile::text from ps))),
    ('M11', 'private', 'proconfig count|starts', 'search_path=""|search_path=""',
     (select (select array_to_string(proconfig, ',') from pc) || '|' || (select array_to_string(proconfig, ',') from ps))),
    ('M12', 'private', 'language count|starts', 'plpgsql|plpgsql', (select (select lanname::text from pc) || '|' || (select lanname::text from ps))),
    ('M13', 'private', 'owned by get_free_busy''s owner', 'true',
     (select (count(*) = 2 and bool_and(proowner = (select o from own)))::text from (select proowner from pc union all select proowner from ps) f)),
    ('M14', 'private', 'count_in_zones EXECUTE holders besides owner (NULL acl counts as PUBLIC)', '0', (select n::text from xo where oid = (select oid from pc))),
    ('M15', 'private', 'starts_in_zones EXECUTE holders besides owner (NULL acl counts as PUBLIC)', '0', (select n::text from xo where oid = (select oid from ps))),
    ('M16', 'private', 'anon|authenticated|service_role may EXECUTE count_in_zones', 'false|false|false',
     (select pg_catalog.has_function_privilege('anon', oid, 'EXECUTE')::text || '|' || pg_catalog.has_function_privilege('authenticated', oid, 'EXECUTE')::text
             || '|' || pg_catalog.has_function_privilege('service_role', oid, 'EXECUTE')::text from pc)),
    ('M17', 'private', 'anon|authenticated|service_role may EXECUTE starts_in_zones', 'false|false|false',
     (select pg_catalog.has_function_privilege('anon', oid, 'EXECUTE')::text || '|' || pg_catalog.has_function_privilege('authenticated', oid, 'EXECUTE')::text
             || '|' || pg_catalog.has_function_privilege('service_role', oid, 'EXECUTE')::text from ps)),
    ('M18', 'private', 'count_in_zones body md5, CR removed (0018)', '7023e51dc8675be1338e3a5b5b2f9d1b', (select h from pc)),
    ('M19', 'private', 'starts_in_zones body md5, CR removed (0018)', 'f4a394632a1b26903554df766116912f', (select h from ps)),
    ('M20', 'private', 'private bodies (code, comments stripped) never call the zone predicates', 'false',
     (select bool_or(code ~ '(timezone_is_resolvable|timezone_is_supported|pg_timezone_names)')::text from (select code from pc union all select code from ps) b)),

    -- S. timeweave_private.
    ('S01', 'schema', 'timeweave_private owned by get_free_busy''s owner', 'true', (select (nspowner = (select o from own))::text from tp)),
    ('S02', 'schema', 'USAGE/CREATE holders besides owner (incl. PUBLIC)', '0',
     (select count(*) from tp, pg_catalog.aclexplode(coalesce(tp.nspacl, array[]::aclitem[])) a where a.grantee <> tp.nspowner)::text),
    ('S03', 'schema', 'USAGE for anon|authenticated|service_role|authenticator', 'false|false|false|false',
     (select pg_catalog.has_schema_privilege('anon', 'timeweave_private', 'USAGE')::text || '|'
          || pg_catalog.has_schema_privilege('authenticated', 'timeweave_private', 'USAGE')::text || '|'
          || pg_catalog.has_schema_privilege('service_role', 'timeweave_private', 'USAGE')::text || '|'
          || pg_catalog.has_schema_privilege('authenticator', 'timeweave_private', 'USAGE')::text)),
    ('S04', 'schema', 'CREATE for anon|authenticated|service_role|authenticator', 'false|false|false|false',
     (select pg_catalog.has_schema_privilege('anon', 'timeweave_private', 'CREATE')::text || '|'
          || pg_catalog.has_schema_privilege('authenticated', 'timeweave_private', 'CREATE')::text || '|'
          || pg_catalog.has_schema_privilege('service_role', 'timeweave_private', 'CREATE')::text || '|'
          || pg_catalog.has_schema_privilege('authenticator', 'timeweave_private', 'CREATE')::text)),

    -- H. the public timed helpers (compatible with production-before, now wrappers).
    ('H01', 'public', 'public.rrule_timed_occurrence_count overloads', '1',
     (select count(*) from fn where nsp = 'public' and proname = 'rrule_timed_occurrence_count')::text),
    ('H02', 'public', 'public.rrule_timed_occurrence_starts overloads', '1',
     (select count(*) from fn where nsp = 'public' and proname = 'rrule_timed_occurrence_starts')::text),
    ('H03', 'public', 'count identity arguments (unchanged)', 'p_rrule text, p_all_day boolean, p_start_at timestamp with time zone, p_end_at timestamp with time zone, p_timezone text, p_from timestamp with time zone, p_to timestamp with time zone',
     (select args from hc)),
    ('H04', 'public', 'starts identity arguments (unchanged)', 'p_rrule text, p_all_day boolean, p_start_at timestamp with time zone, p_end_at timestamp with time zone, p_timezone text, p_from timestamp with time zone, p_to timestamp with time zone',
     (select args from hs)),
    ('H05', 'public', 'results count|starts (unchanged)', 'bigint|SETOF timestamp with time zone', (select (select ret from hc) || '|' || (select ret from hs))),
    ('H06', 'public', 'SECURITY DEFINER count|starts (unchanged)', 'false|false', (select (select prosecdef::text from hc) || '|' || (select prosecdef::text from hs))),
    ('H07', 'public', 'volatility count|starts (unchanged)', 's|s', (select (select provolatile::text from hc) || '|' || (select provolatile::text from hs))),
    ('H08', 'public', 'proconfig count|starts (unchanged)', 'search_path=""|search_path=""',
     (select (select array_to_string(proconfig, ',') from hc) || '|' || (select array_to_string(proconfig, ',') from hs))),
    ('H09', 'public', 'count EXECUTE holders besides owner (unchanged: 0)', '0', (select n::text from xo where oid = (select oid from hc))),
    ('H10', 'public', 'starts EXECUTE holders besides owner (unchanged: 0)', '0', (select n::text from xo where oid = (select oid from hs))),
    ('H11', 'public', 'both owned by get_free_busy''s owner', 'true',
     (select (count(*) = 2 and bool_and(proowner = (select o from own)))::text from (select proowner from hc union all select proowner from hs) f)),
    ('H12', 'public', 'count body md5, CR removed (0018 wrapper)', 'e875b3a84404ef138e31df2225d3992c', (select h from hc)),
    ('H13', 'public', 'starts body md5, CR removed (0018 wrapper)', 'e44592ad252a02462ecab7b69cc88eb2', (select h from hs)),
    ('H14', 'public', 'count delegates to timeweave_private.rrule_timed_occurrence_count_in_zones', 'true',
     (select (code ~ 'timeweave_private\.rrule_timed_occurrence_count_in_zones\(')::text from hc)),
    ('H15', 'public', 'starts delegates to timeweave_private.rrule_timed_occurrence_starts_in_zones', 'true',
     (select (code ~ 'timeweave_private\.rrule_timed_occurrence_starts_in_zones\(')::text from hs)),
    ('H16', 'public', 'both still self-validate with public.timezone_is_resolvable', 'true|true',
     (select (select (code ~ 'public\.timezone_is_resolvable\(p_timezone\)')::text from hc) || '|' || (select (code ~ 'public\.timezone_is_resolvable\(p_timezone\)')::text from hs))),

    -- F. get_free_busy.
    ('F01', 'rpc', 'public.get_free_busy overloads', '1', (select count(*) from fn where nsp = 'public' and proname = 'get_free_busy')::text),
    ('F02', 'rpc', 'identity arguments (unchanged)', 'p_token text, p_from timestamp with time zone, p_to timestamp with time zone, p_from_date date, p_to_date date',
     (select args from gfb)),
    ('F03', 'rpc', 'result type (unchanged)', 'jsonb', (select ret from gfb)),
    ('F04', 'rpc', 'SECURITY DEFINER (unchanged)', 'true', (select prosecdef::text from gfb)),
    ('F05', 'rpc', 'volatility (unchanged)', 's', (select provolatile::text from gfb)),
    ('F06', 'rpc', 'proconfig (unchanged)', 'search_path=""', (select array_to_string(proconfig, ',') from gfb)),
    ('F07', 'rpc', 'language (unchanged)', 'plpgsql', (select lanname::text from gfb)),
    ('F08', 'rpc', 'full ACL == production-before (Attempt 3 F11)', 'postgres=X/postgres anon=X/postgres authenticated=X/postgres',
     (select coalesce(array_to_string(proacl, ' '), '(default)') from gfb)),
    ('F09', 'rpc', 'anon|authenticated may EXECUTE, PUBLIC may not', 'true|true|false',
     (select pg_catalog.has_function_privilege('anon', oid, 'EXECUTE')::text || '|' || pg_catalog.has_function_privilege('authenticated', oid, 'EXECUTE')::text
             || '|' || (proacl is null or exists (select 1 from pg_catalog.aclexplode(proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'))::text from gfb)),
    ('F10', 'rpc', 'body md5, CR removed (0018)', '17f05831c60abd63a652c0a9d691b94c', (select h from gfb)),
    ('F11', 'rpc', 'code declares and fills v_tz_all and v_ok_tz (step 2b, two statements)', 'true',
     (select (code ~ 'v_tz_all\s+text\[\]' and code ~ 'into v_tz_all' and code ~ 'into v_ok_tz' and code ~ 'unnest\(v_tz_all\)')::text from gfb)),
    ('F12', 'rpc', 'code calls count_in_zones 4x and starts_in_zones 2x, each with v_ok_tz', '4|2',
     (select (select count(*) from regexp_matches(code, 'timeweave_private\.rrule_timed_occurrence_count_in_zones\([^()]*v_ok_tz\)', 'g'))::text || '|'
          || (select count(*) from regexp_matches(code, 'timeweave_private\.rrule_timed_occurrence_starts_in_zones\([^()]*v_ok_tz\)', 'g'))::text from gfb)),
    ('F13', 'rpc', 'code calls no public timed helper any more', '0',
     (select count(*) from regexp_matches((select code from gfb), 'public\.rrule_timed_occurrence_(count|starts)\(', 'g'))::text),
    ('F14', 'rpc', 'code evaluates timezone_is_resolvable exactly once (step 2b)', '1',
     (select count(*) from regexp_matches((select code from gfb), 'timezone_is_resolvable', 'g'))::text),

    -- Z. untouched dependencies: bodies (same expectations as the preflight), owners, ACLs == production-before.
    ('Z01', 'deps', 'timezone_is_resolvable body md5 (unchanged)', '28e6b9f4d8a83a274226745edef206dc', (select string_agg(h, ',') from dep where proname = 'timezone_is_resolvable')),
    ('Z02', 'deps', 'timezone_is_supported body md5 (unchanged)', 'd6d46c844ff9c154870f67b757dd3b4f', (select string_agg(h, ',') from dep where proname = 'timezone_is_supported')),
    ('Z03', 'deps', 'rrule_timed_sql_subset body md5 (unchanged)', 'd34812cfb2fe12e0d44054751cee3430', (select string_agg(h, ',') from dep where proname = 'rrule_timed_sql_subset')),
    ('Z04', 'deps', 'rrule_parse body md5 (unchanged)', '2e59e47964e4f403914c86249a2daaaa', (select string_agg(h, ',') from dep where proname = 'rrule_parse')),
    ('Z05', 'deps', 'rrule_timed_expansion_cap body md5 (unchanged)', 'c9bb9b6680f94aa14aa2083dfcd4bd23', (select string_agg(h, ',') from dep where proname = 'rrule_timed_expansion_cap')),
    ('Z06', 'deps', 'all five owned by get_free_busy''s owner', 'true', (select (count(*) = 5 and bool_and(proowner = (select o from own)))::text from dep)),
    ('Z07', 'deps', 'timezone_is_resolvable ACL == production-before', 'postgres=X/postgres',
     (select coalesce(array_to_string(proacl, ' '), '(default)') from dep where proname = 'timezone_is_resolvable')),
    ('Z08', 'deps', 'timezone_is_supported ACL == production-before', 'postgres=X/postgres authenticated=X/postgres',
     (select coalesce(array_to_string(proacl, ' '), '(default)') from dep where proname = 'timezone_is_supported')),

    -- U. callers.
    ('U01', 'callers', 'functions referencing rrule_timed_occurrence_(count|starts)',
     'public.get_free_busy,public.rrule_timed_occurrence_count,public.rrule_timed_occurrence_starts,timeweave_private.rrule_timed_occurrence_starts_in_zones',
     (select string_agg(nsp || '.' || proname, ',' order by nsp || '.' || proname collate "C") from fn where prosrc ~ 'rrule_timed_occurrence_(count|starts)')),
    -- U02 inspects code with comments stripped: the 0018 private helpers MENTION the predicate in comments only.
    ('U02', 'callers', 'functions whose code (comments stripped) calls timezone_is_resolvable',
     'public.get_free_busy,public.rrule_timed_occurrence_count,public.rrule_timed_occurrence_starts',
     (select string_agg(nsp || '.' || proname, ',' order by nsp || '.' || proname collate "C") from fn where code ~ 'timezone_is_resolvable' and proname <> 'timezone_is_resolvable')),
    ('U03', 'callers', 'functions referencing timezone_is_supported == production-before', 'public.events_validate_timezone,public.timezone_is_resolvable',
     (select string_agg(nsp || '.' || proname, ',' order by nsp || '.' || proname collate "C") from fn where prosrc ~ 'timezone_is_supported' and proname <> 'timezone_is_supported')),

    -- B. behaviour: pure functions on literal arguments (no table is read).
    ('B01', 'behaviour', 'private count (upper bound on candidates), UTC in list, DAILY one week', '9',
     timeweave_private.rrule_timed_occurrence_count_in_zones('FREQ=DAILY', false, timestamptz '2026-10-01 09:00+00', timestamptz '2026-10-01 10:00+00', 'UTC',
       timestamptz '2026-10-01 00:00+00', timestamptz '2026-10-08 00:00+00', array['UTC'])::text),
    ('B02', 'behaviour', 'public count == private count for the same arguments', 'true',
     (public.rrule_timed_occurrence_count('FREQ=DAILY', false, timestamptz '2026-10-01 09:00+00', timestamptz '2026-10-01 10:00+00', 'UTC',
       timestamptz '2026-10-01 00:00+00', timestamptz '2026-10-08 00:00+00')
      is not distinct from
      timeweave_private.rrule_timed_occurrence_count_in_zones('FREQ=DAILY', false, timestamptz '2026-10-01 09:00+00', timestamptz '2026-10-01 10:00+00', 'UTC',
       timestamptz '2026-10-01 00:00+00', timestamptz '2026-10-08 00:00+00', array['UTC']))::text),
    ('B03', 'behaviour', 'public starts == private starts (same instants, same order)', 'true',
     ((select array_agg(t) from public.rrule_timed_occurrence_starts('FREQ=WEEKLY;BYDAY=MO,WE,FR', false, timestamptz '2026-10-01 09:00+00', timestamptz '2026-10-01 10:00+00',
        'America/New_York', timestamptz '2026-10-15 00:00+00', timestamptz '2026-11-15 00:00+00') t)
      is not distinct from
      (select array_agg(t) from timeweave_private.rrule_timed_occurrence_starts_in_zones('FREQ=WEEKLY;BYDAY=MO,WE,FR', false, timestamptz '2026-10-01 09:00+00', timestamptz '2026-10-01 10:00+00',
        'America/New_York', timestamptz '2026-10-15 00:00+00', timestamptz '2026-11-15 00:00+00', array['America/New_York']) t))::text),
    ('B04', 'behaviour', 'private count, zone absent from list -> NULL (fail-soft)', 'null',
     coalesce(timeweave_private.rrule_timed_occurrence_count_in_zones('FREQ=DAILY', false, timestamptz '2026-10-01 09:00+00', timestamptz '2026-10-01 10:00+00', 'UTC',
       timestamptz '2026-10-01 00:00+00', timestamptz '2026-10-08 00:00+00', array['Asia/Tokyo'])::text, 'null')),
    ('B05', 'behaviour', 'private starts, unresolvable zone absent from list -> no rows, no error', '0',
     (select count(*) from timeweave_private.rrule_timed_occurrence_starts_in_zones('FREQ=DAILY', false, timestamptz '2026-10-01 09:00+00', timestamptz '2026-10-01 10:00+00',
        'Nowhere/Nothing', timestamptz '2026-10-01 00:00+00', timestamptz '2026-10-08 00:00+00', array['UTC']))::text),
    ('B06', 'behaviour', 'public count, unresolvable zone -> NULL (still self-validating)', 'null',
     coalesce(public.rrule_timed_occurrence_count('FREQ=DAILY', false, timestamptz '2026-10-01 09:00+00', timestamptz '2026-10-01 10:00+00', 'Nowhere/Nothing',
       timestamptz '2026-10-01 00:00+00', timestamptz '2026-10-08 00:00+00')::text, 'null')),

    -- T. zone semantics.
    ('T01', 'semantics', 'resolvable(UTC)', 'true', public.timezone_is_resolvable('UTC')::text),
    ('T02', 'semantics', 'resolvable(America/New_York)', 'true', public.timezone_is_resolvable('America/New_York')::text),
    ('T03', 'semantics', 'resolvable(JST) -- abbreviation refused', 'false', public.timezone_is_resolvable('JST')::text),
    ('T04', 'semantics', 'resolvable(asia/tokyo) -- case variant refused', 'false', public.timezone_is_resolvable('asia/tokyo')::text),

    -- X. everything 0018 must not have moved: SAME expressions as the preflight's X01/X02.
    ('X01', 'unrelated', 'md5 over every other public/timeweave_private function == production-before',
     '9fe515f1ec7489df45c51960b90a9176',
     (select md5(string_agg(nsp || '.' || proname || '(' || args || ')|' || coalesce(array_to_string(proacl, ' '), '-') || '|'
                            || coalesce(array_to_string(proconfig, ','), '') || '|' || prosecdef::text || '|' || h,
                            ';' order by nsp || '.' || proname || '(' || args || ')' collate "C"))
        from fn where nsp in ('public', 'timeweave_private')
          and proname not in ('get_free_busy', 'rrule_timed_occurrence_count', 'rrule_timed_occurrence_starts',
                              'rrule_timed_occurrence_count_in_zones', 'rrule_timed_occurrence_starts_in_zones'))),
    ('X02', 'unrelated', 'md5 over events + share_links trigger definitions == production-before',
     '35f508637a7c1a995ba65caf1ebb7d54',
     (select md5(string_agg(pg_catalog.pg_get_triggerdef(t.oid), ';' order by t.tgname collate "C"))
        from pg_catalog.pg_trigger t
       where t.tgrelid in ('public.events'::regclass, 'public.share_links'::regclass) and not t.tgisinternal)),
    ('X03', 'unrelated', 'functions in timeweave_private (production-before 0, 0018 adds 2)', '2',
     (select count(*) from fn where nsp = 'timeweave_private')::text),
    ('X04', 'unrelated', 'events + share_links triggers that are NOT enabled (tgenabled <> O)', '0',
     (select count(*) from pg_catalog.pg_trigger t
       where t.tgrelid in ('public.events'::regclass, 'public.share_links'::regclass) and not t.tgisinternal and t.tgenabled <> 'O')::text),

    -- D. data, counts only.
    ('D01', 'data', 'timed recurring masters', null, (select count(*) from public.events e where e.rrule is not null and e.all_day = false)::text),
    ('D02', 'data', 'distinct non-null zones among them', null,
     (select count(distinct e.timezone) from public.events e where e.rrule is not null and e.all_day = false)::text)

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
