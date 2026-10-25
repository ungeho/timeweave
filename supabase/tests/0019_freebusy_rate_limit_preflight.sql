-- ============================================================================
-- TimeWeave -- PREFLIGHT for 0019_freebusy_rate_limit.sql (A2).
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run by hand, once, against the project
-- 0019 will be applied to, BEFORE applying it. Valid only for the frozen 0019:
--
--   sha256   7e244cc8845c6cc5718ffec33b13b00c5fab943b99937e20746819ed5a6359e8
--   git blob 42b64475705e72aa636f51991d5b555348468980   (42,213 bytes, 927 lines)
--
-- It expects 0018 applied and 0019 NOT applied.
--
-- READ-ONLY: SELECT and catalog inspection only. No DDL, no DML, no SET, no
-- temp table, no advisory lock, nothing that fires a trigger, and no call to
-- get_free_busy or any other RPC -- in particular nothing that could create or
-- consume rate state. One statement inside a read-only transaction that ends
-- in ROLLBACK. No timing or load measurement.
--
-- WHAT IT GATES
--
--   V. context     server, the role that will run the migration, and that   V01-V08
--                  it owns get_free_busy and timeweave_private (CREATE OR
--                  REPLACE and CREATE need that ownership)
--   F. rpc         get_free_busy as 0018 left it: one overload, signature,   F01-F13
--                  DEFINER, STABLE, search_path, ACL, 0018 body fingerprint,
--                  and the token predicate 0019 reuses verbatim
--   M. private     the two 0018 *_in_zones helpers the core will call:      M01-M06
--                  exact signatures, bodies, attributes, owner-only EXECUTE
--   Z. deps        helpers 0019 never touches: bodies, owner, ACLs          Z01-Z08
--   S. schema      timeweave_private: exists, same owner, nobody else has   S01-S04
--                  USAGE or CREATE
--   R. rate        the EXISTING private rate structures (0012, 0016) that   R01-R09
--                  0019 copies: RLS, policy count, ACL materialisation,
--                  fillfactor, FK shape. R04/R05 define the ACL string the
--                  postflight will expect for the two NEW tables.
--   C. collide     nothing 0019 creates exists yet, and get_free_busy is    C01-C07
--                  not already rewritten -- no prior or partial apply
--   A. advisory    which lock classes existing code actually takes, and     A01-A06
--                  that 811030-811039 is free
--   E. env         extensions, functions, types, operators, FK targets and  E01-E14
--                  privileges 0019 needs in order to apply at all
--   G. timeout     statement_timeout: what the catalog CAN determine, and   G01-G07
--                  what it CANNOT. G01-G06 are facts; G07 is the explicit
--                  statement that the value a PostgREST request runs with
--                  is NOT determinable from here.
--   P. privs       default privileges that would shape the new tables' and  P01-P04
--                  functions' ACLs beyond what 0019 revokes
--   D. data        counts and blockers only: nothing in events, share_links D01-D09
--                  or recurrence can block this apply, and no other backend
--                  is sitting on a lock the apply needs
--   X. baseline    fingerprints 0019 must NOT move                          X01-X05
--
-- BODY FINGERPRINTS are md5 of prosrc with CR removed (production has shown
-- CRLF bodies before). F10, M03, M04, Z01-Z05, Z07, Z08, F08, X01 and X02 are
-- the values the 0018 POSTFLIGHT already confirmed in production on
-- 2026-09-19, so a FAIL there means production moved after 0018, not that 0019
-- is wrong. Either way: STOP and investigate before applying.
--
-- X01 IS A PRODUCTION CONSTANT. Its expectation is the value production itself
-- reported (0018 preflight X01, re-confirmed by the 0018 postflight), i.e. a
-- fingerprint of THAT database's other functions. Run against any other
-- database -- a local rebuild, a staging copy -- X01 FAILs although nothing is
-- wrong. What must hold operationally is that the preflight X01 and the
-- postflight X01 are the same value: 0019 must not move it.
--
-- X03 and X04 have no hard-coded expectation (production-specific). Keep this
-- output: the postflight prints the same two values and they must be
-- character-for-character identical.
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
         regexp_replace(replace(p.prosrc, E'\r', ''), '--[^\n]*', '', 'g') as code,
         p.prosrc
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  join pg_catalog.pg_language l on l.oid = p.prolang
  where n.nspname not in ('pg_catalog', 'information_schema')
    and n.nspname not like 'pg\_%'
),
-- Bound to EXACT signatures: an extra overload is reported by F01/M01/M02
-- instead of breaking a scalar subquery; a missing signature yields NULL,
-- which FAILs every expectation below.
gfb as (select * from fn where oid = to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)')),
pc  as (select * from fn where oid = to_regprocedure('timeweave_private.rrule_timed_occurrence_count_in_zones(text, boolean, timestamptz, timestamptz, text, timestamptz, timestamptz, text[])')),
ps  as (select * from fn where oid = to_regprocedure('timeweave_private.rrule_timed_occurrence_starts_in_zones(text, boolean, timestamptz, timestamptz, text, timestamptz, timestamptz, text[])')),
dep as (select * from fn where nsp = 'public'
          and proname in ('timezone_is_resolvable', 'timezone_is_supported', 'rrule_timed_sql_subset',
                          'rrule_parse', 'rrule_timed_expansion_cap')),
own as (select min(proowner::text)::oid as o, count(*) as n from gfb),
-- EXECUTE holders other than the function's owner (PUBLIC = grantee 0). A NULL
-- proacl means the built-in default, i.e. PUBLIC may execute: counted as 1.
xo as (
  select f.oid,
         case when f.proacl is null then 1
              else (select count(*) from pg_catalog.aclexplode(f.proacl) a
                     where a.privilege_type = 'EXECUTE' and a.grantee <> f.proowner) end as n
  from fn f
),
tp as (
  select n.oid, n.nspowner, n.nspacl from pg_catalog.pg_namespace n where n.nspname = 'timeweave_private'
),
rel as (
  select n.nspname as nsp, c.relname, c.oid, c.relkind, c.relrowsecurity, c.relacl, c.relowner, c.reloptions
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public', 'timeweave_private')
),
-- Advisory lock classes that existing CODE (comments stripped) actually names.
cls as (
  select distinct m.arr[1] as c
  from fn f, lateral regexp_matches(f.code, '(81[0-9]{4})', 'g') as m(arr)
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
    ('V04', 'context', 'that role owns get_free_busy (CREATE OR REPLACE needs it)', 'true',
     (select (pg_catalog.pg_get_userbyid(proowner) = current_user)::text from gfb)),
    ('V05', 'context', 'that role owns timeweave_private', 'true',
     (select (pg_catalog.pg_get_userbyid(nspowner) = current_user)::text from tp)),
    ('V06', 'context', 'that role may CREATE in timeweave_private', 'true',
     pg_catalog.has_schema_privilege(current_user, 'timeweave_private', 'CREATE')::text),
    ('V07', 'context', 'role attributes superuser|bypassrls|createrole', null,
     (select r.rolsuper::text || '|' || r.rolbypassrls::text || '|' || r.rolcreaterole::text
        from pg_catalog.pg_roles r where r.rolname = current_user)),
    ('V08', 'context', 'this transaction is read only', 'on', current_setting('transaction_read_only')),

    -- F. get_free_busy exactly as 0018 left it (production-confirmed 2026-09-19).
    ('F01', 'rpc', 'public.get_free_busy overloads', '1',
     (select count(*) from fn where nsp = 'public' and proname = 'get_free_busy')::text),
    ('F02', 'rpc', 'identity arguments', 'p_token text, p_from timestamp with time zone, p_to timestamp with time zone, p_from_date date, p_to_date date',
     (select args from gfb)),
    ('F03', 'rpc', 'result type', 'jsonb', (select ret from gfb)),
    ('F04', 'rpc', 'SECURITY DEFINER', 'true', (select prosecdef::text from gfb)),
    ('F05', 'rpc', 'volatility BEFORE 0019 (STABLE; 0019 makes it VOLATILE)', 's', (select provolatile::text from gfb)),
    ('F06', 'rpc', 'proconfig', 'search_path=""', (select array_to_string(proconfig, ',') from gfb)),
    ('F07', 'rpc', 'language', 'plpgsql', (select lanname::text from gfb)),
    ('F08', 'rpc', 'full ACL (0019 must preserve it)', 'postgres=X/postgres anon=X/postgres authenticated=X/postgres',
     (select coalesce(array_to_string(proacl, ' '), '(default)') from gfb)),
    ('F09', 'rpc', 'anon|authenticated may EXECUTE, PUBLIC may not', 'true|true|false',
     (select pg_catalog.has_function_privilege('anon', oid, 'EXECUTE')::text || '|'
          || pg_catalog.has_function_privilege('authenticated', oid, 'EXECUTE')::text || '|'
          || (proacl is null or exists (select 1 from pg_catalog.aclexplode(proacl) a
                                         where a.grantee = 0 and a.privilege_type = 'EXECUTE'))::text from gfb)),
    ('F10', 'rpc', 'body md5, CR removed (0018 body, production-confirmed)', '17f05831c60abd63a652c0a9d691b94c',
     (select h from gfb)),
    ('F11', 'rpc', 'occurrences of the token predicate 0019 reuses verbatim', '1',
     (select count(*) from regexp_matches((select replace(prosrc, E'\r', '') from gfb),
        'where s\.token_hash = encode\(extensions\.digest\(p_token, ''sha256''\), ''hex''\)', 'g'))::text),
    ('F12', 'rpc', 'owned by the role running this preflight', 'true',
     (select (proowner = current_user::regrole::oid)::text from gfb)),
    ('F13', 'rpc', 'body does NOT already mention the 0019 objects', '0',
     (select count(*) from gfb where prosrc ~ '(freebusy_|free_busy_core|advisory)')::text),

    -- M. the two 0018 private helpers the core will call (production-confirmed).
    ('M01', 'private', 'count_in_zones at the exact 8-argument signature', '1', (select count(*) from pc)::text),
    ('M02', 'private', 'starts_in_zones at the exact 8-argument signature', '1', (select count(*) from ps)::text),
    ('M03', 'private', 'count_in_zones body md5, CR removed (0018)', '7023e51dc8675be1338e3a5b5b2f9d1b', (select h from pc)),
    ('M04', 'private', 'starts_in_zones body md5, CR removed (0018)', 'f4a394632a1b26903554df766116912f', (select h from ps)),
    ('M05', 'private', 'DEFINER count|starts, volatility count|starts', 'false|false|s|s',
     (select (select prosecdef::text from pc) || '|' || (select prosecdef::text from ps) || '|'
          || (select provolatile::text from pc) || '|' || (select provolatile::text from ps))),
    ('M06', 'private', 'EXECUTE holders besides owner, count|starts', '0|0',
     (select (select n::text from xo where oid = (select oid from pc)) || '|'
          || (select n::text from xo where oid = (select oid from ps)))),

    -- Z. dependencies 0019 never touches (production-confirmed).
    ('Z01', 'deps', 'timezone_is_resolvable body md5', '28e6b9f4d8a83a274226745edef206dc',
     (select string_agg(h, ',') from dep where proname = 'timezone_is_resolvable')),
    ('Z02', 'deps', 'timezone_is_supported body md5', 'd6d46c844ff9c154870f67b757dd3b4f',
     (select string_agg(h, ',') from dep where proname = 'timezone_is_supported')),
    ('Z03', 'deps', 'rrule_timed_sql_subset body md5', 'd34812cfb2fe12e0d44054751cee3430',
     (select string_agg(h, ',') from dep where proname = 'rrule_timed_sql_subset')),
    ('Z04', 'deps', 'rrule_parse body md5', '2e59e47964e4f403914c86249a2daaaa',
     (select string_agg(h, ',') from dep where proname = 'rrule_parse')),
    ('Z05', 'deps', 'rrule_timed_expansion_cap body md5', 'c9bb9b6680f94aa14aa2083dfcd4bd23',
     (select string_agg(h, ',') from dep where proname = 'rrule_timed_expansion_cap')),
    ('Z06', 'deps', 'all five owned by get_free_busy''s owner', 'true',
     (select (count(*) = 5 and bool_and(proowner = (select o from own)))::text from dep)),
    ('Z07', 'deps', 'timezone_is_resolvable ACL == production-before', 'postgres=X/postgres',
     (select coalesce(array_to_string(proacl, ' '), '(default)') from dep where proname = 'timezone_is_resolvable')),
    ('Z08', 'deps', 'timezone_is_supported ACL == production-before', 'postgres=X/postgres authenticated=X/postgres',
     (select coalesce(array_to_string(proacl, ' '), '(default)') from dep where proname = 'timezone_is_supported')),

    -- S. timeweave_private.
    ('S01', 'schema', 'timeweave_private exists', '1', (select count(*) from tp)::text),
    ('S02', 'schema', 'owned by get_free_busy''s owner', 'true', (select (nspowner = (select o from own))::text from tp)),
    ('S03', 'schema', 'USAGE/CREATE holders besides owner (incl. PUBLIC)', '0',
     (select count(*) from tp, pg_catalog.aclexplode(tp.nspacl) a
       where a.grantee <> tp.nspowner)::text),
    ('S04', 'schema', 'USAGE for anon|authenticated|service_role|authenticator', 'false|false|false|false',
     (select pg_catalog.has_schema_privilege('anon', 'timeweave_private', 'USAGE')::text || '|'
          || pg_catalog.has_schema_privilege('authenticated', 'timeweave_private', 'USAGE')::text || '|'
          || pg_catalog.has_schema_privilege('service_role', 'timeweave_private', 'USAGE')::text || '|'
          || pg_catalog.has_schema_privilege('authenticator', 'timeweave_private', 'USAGE')::text)),

    -- R. the existing private rate structures 0019 copies. R04/R05 are the ACL
    --    string the postflight expects for freebusy_owner_rate / _link_rate.
    ('R01', 'rate', 'relations in timeweave_private (0012 + 0016 + their pkeys)',
     'event_write_rate,event_write_rate_pkey,share_link_create_rate,share_link_create_rate_pkey',
     (select string_agg(relname, ',' order by relname collate "C") from rel where nsp = 'timeweave_private')),
    ('R02', 'rate', 'RLS enabled: event_write_rate|share_link_create_rate', 'true|true',
     (select (select relrowsecurity::text from rel where nsp = 'timeweave_private' and relname = 'event_write_rate') || '|'
          || (select relrowsecurity::text from rel where nsp = 'timeweave_private' and relname = 'share_link_create_rate'))),
    ('R03', 'rate', 'RLS policies on those two tables (RLS with no policy = deny all)', '0',
     (select count(*) from pg_catalog.pg_policy p
       where p.polrelid in (select oid from rel where nsp = 'timeweave_private' and relkind::text = 'r'))::text),
    ('R04', 'rate', 'event_write_rate ACL after revoke all (shape the new tables must match)', 'postgres=arwdDxtm/postgres',
     (select coalesce(array_to_string(relacl, ' '), '(default)') from rel
       where nsp = 'timeweave_private' and relname = 'event_write_rate')),
    ('R05', 'rate', 'share_link_create_rate ACL after revoke all', 'postgres=arwdDxtm/postgres',
     (select coalesce(array_to_string(relacl, ' '), '(default)') from rel
       where nsp = 'timeweave_private' and relname = 'share_link_create_rate')),
    ('R06', 'rate', 'reloptions: event_write_rate|share_link_create_rate', '{fillfactor=70}|{fillfactor=70}',
     (select (select coalesce(reloptions::text, '(none)') from rel where nsp = 'timeweave_private' and relname = 'event_write_rate') || '|'
          || (select coalesce(reloptions::text, '(none)') from rel where nsp = 'timeweave_private' and relname = 'share_link_create_rate'))),
    ('R07', 'rate', 'FK definitions on those two tables (the shape 0019 repeats)',
     'FOREIGN KEY (owner_id) REFERENCES auth.users(id) ON DELETE CASCADE;FOREIGN KEY (owner_id) REFERENCES auth.users(id) ON DELETE CASCADE',
     (select string_agg(pg_catalog.pg_get_constraintdef(k.oid), ';' order by k.conname collate "C")
        from pg_catalog.pg_constraint k
       where k.contype = 'f'
         and k.conrelid in (select oid from rel where nsp = 'timeweave_private' and relkind::text = 'r'))),
    ('R08', 'rate', 'privileges held on them by anon|authenticated|service_role', '0',
     (select count(*) from rel r, pg_catalog.aclexplode(r.relacl) a
       where r.nsp = 'timeweave_private' and r.relkind::text = 'r'
         and a.grantee in ('anon'::regrole::oid, 'authenticated'::regrole::oid, 'service_role'::regrole::oid))::text),
    ('R09', 'rate', 'relation count in timeweave_private (0019 adds 2 tables + 2 pkeys)', '4',
     (select count(*) from rel where nsp = 'timeweave_private')::text),

    -- C. collisions / prior or partial apply.
    ('C01', 'collide', 'any relation named freebusy_owner_rate', '0',
     (select count(*) from pg_catalog.pg_class c where c.relname = 'freebusy_owner_rate')::text),
    ('C02', 'collide', 'any relation named freebusy_link_rate', '0',
     (select count(*) from pg_catalog.pg_class c where c.relname = 'freebusy_link_rate')::text),
    ('C03', 'collide', 'any function named free_busy_core', '0',
     (select count(*) from fn where proname = 'free_busy_core')::text),
    ('C04', 'collide', 'any of the five parameter functions', '0',
     (select count(*) from fn where proname in ('freebusy_link_rate_interval', 'freebusy_link_rate_burst',
        'freebusy_owner_rate_interval', 'freebusy_owner_rate_burst', 'freebusy_concurrency_slots'))::text),
    ('C05', 'collide', 'any object (relation or function) whose name starts with freebusy', '0',
     ((select count(*) from pg_catalog.pg_class c where c.relname like 'freebusy%')
      + (select count(*) from fn where proname like 'freebusy%'))::text),
    ('C06', 'collide', 'any function body already referencing the 0019 rate tables', '0',
     (select count(*) from fn where prosrc ~ 'freebusy_(owner|link)_rate')::text),
    ('C07', 'collide', 'any function body already calling pg_try_advisory_xact_lock', '0',
     (select count(*) from fn where code ~ 'pg_try_advisory_xact_lock')::text),

    -- A. advisory lock classes.
    ('A01', 'advisory', 'functions whose code takes class 811001',
     'public.events_enforce_owner_quota,public.events_enforce_recurrence_graph,public.share_links_enforce_quota',
     (select string_agg(nsp || '.' || proname, ',' order by nsp || '.' || proname collate "C")
        from fn where code ~ '811001')),
    ('A02', 'advisory', 'functions whose code takes class 811002', 'public.events_enforce_exception_quota',
     (select string_agg(nsp || '.' || proname, ',' order by nsp || '.' || proname collate "C")
        from fn where code ~ '811002')),
    ('A03', 'advisory', 'functions whose code names any class in 811030-811039', '0',
     (select count(*) from fn where code ~ '81103[0-9]')::text),
    ('A04', 'advisory', 'distinct advisory classes named in existing code', '811001,811002',
     (select string_agg(c, ',' order by c collate "C") from cls)),
    ('A05', 'advisory', '811031 or 811032 among them', 'false',
     (select (count(*) > 0)::text from cls where c in ('811031', '811032'))),
    ('A06', 'advisory', 'advisory locks currently held in classes 811030-811039', '0',
     (select count(*) from pg_catalog.pg_locks l
       where l.locktype = 'advisory' and l.classid between 811030 and 811039)::text),

    -- E. what 0019 needs in order to apply at all.
    ('E01', 'env', 'extensions.digest(text, text) exists (wrapper token predicate)', 'true',
     (to_regprocedure('extensions.digest(text, text)') is not null)::text),
    ('E02', 'env', 'pgcrypto extension and its schema', null,
     (select coalesce(string_agg(e.extname || '@' || n.nspname, ','), '(none)')
        from pg_catalog.pg_extension e join pg_catalog.pg_namespace n on n.oid = e.extnamespace
       where e.extname = 'pgcrypto')),
    ('E03', 'env', 'pg_catalog.pg_try_advisory_xact_lock(integer, integer) exists', 'true',
     (to_regprocedure('pg_catalog.pg_try_advisory_xact_lock(integer, integer)') is not null)::text),
    ('E04', 'env', 'pg_catalog.hashtext(text) exists', 'true',
     (to_regprocedure('pg_catalog.hashtext(text)') is not null)::text),
    ('E05', 'env', 'pg_catalog.statement_timestamp() exists', 'true',
     (to_regprocedure('pg_catalog.statement_timestamp()') is not null)::text),
    ('E06', 'env', 'link tau: 15 * interval ''2 seconds''', '00:00:30', (15 * interval '2 seconds')::text),
    ('E07', 'env', 'owner tau: 40 * interval ''1 second''', '00:00:40', (40 * interval '1 second')::text),
    ('E08', 'env', 'auth.users has a single-column primary key on (id)', 'true',
     (select (count(*) = 1)::text from pg_catalog.pg_constraint k
       where k.conrelid = to_regclass('auth.users') and k.contype = 'p'
         and k.conkey = array[(select a.attnum from pg_catalog.pg_attribute a
                                where a.attrelid = to_regclass('auth.users') and a.attname = 'id')])),
    ('E09', 'env', 'public.share_links has a single-column primary key on (id)', 'true',
     (select (count(*) = 1)::text from pg_catalog.pg_constraint k
       where k.conrelid = to_regclass('public.share_links') and k.contype = 'p'
         and k.conkey = array[(select a.attnum from pg_catalog.pg_attribute a
                                where a.attrelid = to_regclass('public.share_links') and a.attname = 'id')])),
    ('E10', 'env', 'REFERENCES on auth.users for this role (needed by the owner FK)', 'true',
     pg_catalog.has_table_privilege(current_user, 'auth.users', 'REFERENCES')::text),
    ('E11', 'env', 'REFERENCES on public.share_links for this role (needed by the link FK)', 'true',
     pg_catalog.has_table_privilege(current_user, 'public.share_links', 'REFERENCES')::text),
    ('E12', 'env', 'auth.users owner (need not be this role; REFERENCES is what matters)', null,
     (select pg_catalog.pg_get_userbyid(c.relowner) from pg_catalog.pg_class c where c.oid = to_regclass('auth.users'))),
    ('E13', 'env', 'uuid and timestamptz types resolve', 'true',
     ((to_regtype('uuid') is not null) and (to_regtype('timestamptz') is not null))::text),
    ('E14', 'env', 'views or matviews depending on get_free_busy', '0',
     (select count(*) from pg_catalog.pg_depend d
       where d.refobjid = (select oid from gfb) and d.classid = 'pg_rewrite'::regclass)::text),

    -- G. statement_timeout. G01-G06 are what the catalog determines; G07 is what
    --    it does NOT. 0019 relies on the gate, not on a timeout, so none of
    --    these blocks the apply -- they are recorded to interpret 57014 later.
    ('G01', 'timeout', 'DETERMINABLE: role settings for anon (pg_db_role_setting)', null,
     (select coalesce(string_agg(array_to_string(s.setconfig, ' '), ' | '), '(none)')
        from pg_catalog.pg_db_role_setting s where s.setrole = 'anon'::regrole::oid)),
    ('G02', 'timeout', 'DETERMINABLE: role settings for authenticated', null,
     (select coalesce(string_agg(array_to_string(s.setconfig, ' '), ' | '), '(none)')
        from pg_catalog.pg_db_role_setting s where s.setrole = 'authenticated'::regrole::oid)),
    ('G03', 'timeout', 'DETERMINABLE: role settings for authenticator', null,
     (select coalesce(string_agg(array_to_string(s.setconfig, ' '), ' | '), '(none)')
        from pg_catalog.pg_db_role_setting s where s.setrole = 'authenticator'::regrole::oid)),
    ('G04', 'timeout', 'DETERMINABLE: settings attached to this database (all roles)', null,
     (select coalesce(string_agg(coalesce(pg_catalog.pg_get_userbyid(nullif(s.setrole, 0)), '(all roles)')
                                 || '=' || array_to_string(s.setconfig, ' '), ' | '), '(none)')
        from pg_catalog.pg_db_role_setting s
       where s.setdatabase = (select oid from pg_catalog.pg_database where datname = current_database()))),
    ('G05', 'timeout', 'DETERMINABLE: cluster statement_timeout (setting/source/reset_val)', null,
     (select s.setting || '/' || s.source || '/' || s.reset_val from pg_catalog.pg_settings s where s.name = 'statement_timeout')),
    ('G06', 'timeout', 'DETERMINABLE: statement_timeout in THIS session (the migration role, not the API role)', null,
     current_setting('statement_timeout')),
    ('G07', 'timeout', 'NOT DETERMINABLE FROM THE CATALOG: the statement_timeout a PostgREST anon request actually runs with. PostgREST may set it per request (db-pre-request, pgrst.* settings applied through the pooler) and a gateway may cut the request earlier still. Verify that from the application side, not here.', null,
     'not determinable from the catalog'),

    -- P. default privileges that could reach the new objects.
    ('P01', 'privs', 'default TABLE ACLs for this role (timeweave_private or global)', null,
     (select coalesce(string_agg(coalesce(n.nspname, '*') || '=' || array_to_string(d.defaclacl, ' '), '; '), '(none)')
        from pg_catalog.pg_default_acl d
        left join pg_catalog.pg_namespace n on n.oid = d.defaclnamespace
       where d.defaclrole = current_user::regrole and d.defaclobjtype::text = 'r'
         and (n.nspname = 'timeweave_private' or d.defaclnamespace = 0))),
    ('P02', 'privs', 'default FUNCTION ACLs for this role (timeweave_private or global)', null,
     (select coalesce(string_agg(coalesce(n.nspname, '*') || '=' || array_to_string(d.defaclacl, ' '), '; '), '(none)')
        from pg_catalog.pg_default_acl d
        left join pg_catalog.pg_namespace n on n.oid = d.defaclnamespace
       where d.defaclrole = current_user::regrole and d.defaclobjtype::text = 'f'
         and (n.nspname = 'timeweave_private' or d.defaclnamespace = 0))),
    ('P03', 'privs', 'those TABLE defaults grant to a role 0019 does not revoke', '0',
     (select count(*)
        from pg_catalog.pg_default_acl d
        left join pg_catalog.pg_namespace n on n.oid = d.defaclnamespace,
        pg_catalog.aclexplode(d.defaclacl) a
       where d.defaclrole = current_user::regrole and d.defaclobjtype::text = 'r'
         and (n.nspname = 'timeweave_private' or d.defaclnamespace = 0)
         and a.grantee <> 0
         and a.grantee not in (current_user::regrole::oid, 'anon'::regrole::oid,
                               'authenticated'::regrole::oid, 'service_role'::regrole::oid))::text),
    ('P04', 'privs', 'those FUNCTION defaults grant EXECUTE to a role 0019 does not revoke', '0',
     (select count(*)
        from pg_catalog.pg_default_acl d
        left join pg_catalog.pg_namespace n on n.oid = d.defaclnamespace,
        pg_catalog.aclexplode(d.defaclacl) a
       where d.defaclrole = current_user::regrole and d.defaclobjtype::text = 'f'
         and (n.nspname = 'timeweave_private' or d.defaclnamespace = 0)
         and a.privilege_type = 'EXECUTE'
         and a.grantee <> 0
         and a.grantee not in (current_user::regrole::oid, 'anon'::regrole::oid,
                               'authenticated'::regrole::oid, 'service_role'::regrole::oid))::text),

    -- D. data and blockers. Counts only.
    ('D01', 'data', 'rows in auth.users', null, (select count(*) from auth.users)::text),
    ('D02', 'data', 'rows in public.share_links', null, (select count(*) from public.share_links)::text),
    ('D03', 'data', 'active share links (not revoked, not expired)', null,
     (select count(*) from public.share_links s
       where s.revoked_at is null and (s.expires_at is null or s.expires_at > now()))::text),
    ('D04', 'data', 'share_links whose owner is absent from auth.users', '0',
     (select count(*) from public.share_links s
       where not exists (select 1 from auth.users u where u.id = s.owner_id))::text),
    ('D05', 'data', 'rows in public.events', null, (select count(*) from public.events)::text),
    ('D06', 'data', 'timed recurring masters (the work 0019 gates; 0019 does not change it)', null,
     (select count(*) from public.events e where e.rrule is not null and e.all_day = false)::text),
    ('D07', 'data', 'other backends idle in transaction in this database', null,
     (select count(*) from pg_catalog.pg_stat_activity a
       where a.datname = current_database() and a.pid <> pg_catalog.pg_backend_pid()
         and a.state in ('idle in transaction', 'idle in transaction (aborted)'))::text),
    ('D08', 'data', 'locks held by other backends on share_links / auth.users (the apply needs both)', null,
     (select count(*) from pg_catalog.pg_locks l
       where l.pid <> pg_catalog.pg_backend_pid()
         and l.relation in (to_regclass('public.share_links'), to_regclass('auth.users')))::text),
    ('D09', 'data', 'the two new tables are created empty, so their FKs validate no existing row', null,
     'no existing row is validated by CREATE TABLE ... REFERENCES on an empty table'),

    -- X. fingerprints 0019 must NOT move. X01/X02 are production-confirmed
    --    (0018 postflight, 2026-09-19); the exclusion list already covers every
    --    name 0019 creates, so the same value must hold after the apply.
    ('X01', 'baseline', 'md5 over every other public/timeweave_private function == production-before',
     '9fe515f1ec7489df45c51960b90a9176',
     (select md5(string_agg(nsp || '.' || proname || '(' || args || ')|' || coalesce(array_to_string(proacl, ' '), '-') || '|'
                            || coalesce(array_to_string(proconfig, ','), '') || '|' || prosecdef::text || '|' || h,
                            ';' order by nsp || '.' || proname || '(' || args || ')' collate "C"))
        from fn where nsp in ('public', 'timeweave_private')
          and proname not in ('get_free_busy', 'rrule_timed_occurrence_count', 'rrule_timed_occurrence_starts',
                              'rrule_timed_occurrence_count_in_zones', 'rrule_timed_occurrence_starts_in_zones',
                              'free_busy_core', 'freebusy_link_rate_interval', 'freebusy_link_rate_burst',
                              'freebusy_owner_rate_interval', 'freebusy_owner_rate_burst', 'freebusy_concurrency_slots'))),
    ('X02', 'baseline', 'md5 over events + share_links trigger definitions == production-before',
     '35f508637a7c1a995ba65caf1ebb7d54',
     (select md5(string_agg(pg_catalog.pg_get_triggerdef(t.oid), ';' order by t.tgname collate "C"))
        from pg_catalog.pg_trigger t
       where t.tgrelid in ('public.events'::regclass, 'public.share_links'::regclass) and not t.tgisinternal)),
    ('X03', 'baseline', 'md5 over every RLS policy on public tables (compare with the postflight by hand)', null,
     (select md5(coalesce(string_agg(p.polrelid::regclass::text || '.' || p.polname || '|' || p.polcmd::text || '|'
                            || coalesce(pg_catalog.pg_get_expr(p.polqual, p.polrelid), '-') || '|'
                            || coalesce(pg_catalog.pg_get_expr(p.polwithcheck, p.polrelid), '-'),
                            ';' order by p.polrelid::regclass::text || '.' || p.polname collate "C"), ''))
        from pg_catalog.pg_policy p
       where p.polrelid in (select oid from rel where nsp = 'public'))),
    ('X04', 'baseline', 'md5 over table ACLs and RLS flags, excluding the two new tables (compare by hand)', null,
     (select md5(string_agg(nsp || '.' || relname || '|' || coalesce(array_to_string(relacl, ' '), '-') || '|' || relrowsecurity::text,
                            ';' order by nsp || '.' || relname collate "C"))
        from rel where relkind::text in ('r', 'p')
          and relname not in ('freebusy_owner_rate', 'freebusy_link_rate'))),
    ('X05', 'baseline', 'functions in timeweave_private (0019 adds 6)', '2',
     (select count(*) from fn where nsp = 'timeweave_private')::text)

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
