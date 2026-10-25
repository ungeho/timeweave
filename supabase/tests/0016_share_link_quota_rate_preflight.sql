-- ============================================================================
-- TimeWeave -- PREFLIGHT for 0016_share_link_quota_and_create_rate.sql (M-D).
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run by hand, once, against the project
-- 0016 will be applied to, BEFORE applying it. It is valid only for the frozen
-- 0016 identity:
--
--   sha256   338b88359fe0db33e9b73043c043a2216824995b1ab1381b116a96f5b5d7502f
--   git blob d013031fd1f825e9a083d865d88cd365fb0e3754   (23,508 bytes, 511 lines)
--
-- READ-ONLY: SELECT and catalog inspection only. No DDL, no DML, no SET, no
-- temp table, no function call that writes, no RPC invocation, no advisory
-- lock, no rate-state access beyond existence and a row count. One statement
-- inside a read-only transaction that ends in ROLLBACK.
--
-- WHAT IT GATES
--
--   A. data     every owner fits both quotas today              -> A01-A15
--   S. schema   the columns, FK, index, RLS 0016 relies on      -> S01-S14
--   C. collide  nothing 0016 creates exists yet (no partial     -> C01-C10
--               or prior apply)
--   R. RPCs     baseline of the five share-link RPCs, which     -> R01-R07
--               0016 must leave untouched
--   E. events   baseline of the 0011/0012 event limiter, which  -> E01-E07
--               0016 must leave untouched
--   L. locks    811001/811002 are used exactly where 0011 put   -> L01-L04
--               them and nowhere else
--   P. privs    default privileges that could shape the ACLs    -> P01-P08
--               of the objects 0016 creates
--
-- "active" is the expression 0016 uses, character for character:
--     revoked_at is null and (expires_at is null or expires_at > now())
--
-- PRIVACY. Counts, types, catalog text and source hashes only. It never
-- returns a label, a token, a token_hash, a row id, an owner id or any row
-- timestamp.
--
-- READING THE OUTPUT. status is 'ok' / 'FAIL' where an expectation exists and
-- 'context' where the value is a measurement or a baseline to compare after
-- apply. P00 summarises. A FAIL in section C means 0016 (or part of it) is
-- already present: STOP, do not apply.
-- ============================================================================
begin transaction read only;

with
sl as (
  select s.owner_id,
         (s.revoked_at is null
            and (s.expires_at is null or s.expires_at > now())) as is_active,
         s.revoked_at is not null as is_revoked,
         (s.revoked_at is null and s.expires_at is not null
            and s.expires_at <= now()) as is_expired
  from public.share_links as s
),
per_owner as (
  select owner_id,
         count(*) as n_total,
         count(*) filter (where is_active) as n_active
  from sl
  group by owner_id
),
rpc as (
  select p.proname,
         p.oid::regprocedure::text as sig,
         pg_catalog.pg_get_function_result(p.oid) as res,
         p.prosecdef,
         coalesce(array_to_string(p.proconfig, ','), '(none)') as cfg,
         coalesce(array_to_string(p.proacl, ' '), '(default)') as acl,
         md5(p.prosrc) as src
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('create_share_link', 'list_share_links', 'revoke_share_link',
                      'delete_share_link', 'get_free_busy')
),
ev_fn as (
  select p.proname,
         coalesce(array_to_string(p.proacl, ' '), '(default)') as acl,
         md5(p.prosrc) as src,
         p.prosrc
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('events_enforce_owner_quota', 'events_enforce_exception_quota',
                      'events_enforce_write_rate', 'events_max_per_owner',
                      'events_max_exceptions_per_master', 'events_rate_interval',
                      'events_rate_burst')
),
user_fn as (
  select n.nspname || '.' || p.proname as fq, p.prosrc
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname not in ('pg_catalog', 'information_schema')
    and n.nspname not like 'pg\_%'
),
res as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL'
         end as status
  from (values

    -- A. production data against the two quotas.
    ('A01', 'data', 'share_links rows', null,
     (select count(*) from sl)::text),
    ('A02', 'data', 'active rows (0016 expression)', null,
     (select count(*) from sl where is_active)::text),
    ('A03', 'data', 'revoked rows', null,
     (select count(*) from sl where is_revoked)::text),
    ('A04', 'data', 'expired-but-unrevoked rows (total yes, active no)', null,
     (select count(*) from sl where is_expired)::text),
    ('A05', 'data', 'distinct owners', null,
     (select count(*) from per_owner)::text),
    ('A06', 'data', 'largest TOTAL held by one owner', null,
     (select coalesce(max(n_total), 0) from per_owner)::text),
    ('A07', 'data', 'largest ACTIVE held by one owner', null,
     (select coalesce(max(n_active), 0) from per_owner)::text),
    ('A08', 'data', 'owners over the TOTAL quota of 200', '0',
     (select count(*) from per_owner where n_total > 200)::text),
    ('A09', 'data', 'owners over the ACTIVE quota of 25', '0',
     (select count(*) from per_owner where n_active > 25)::text),
    ('A10', 'data', 'owners past 160 total (80%)', null,
     (select count(*) from per_owner where n_total > 160)::text),
    ('A11', 'data', 'owners past 20 active (80%)', null,
     (select count(*) from per_owner where n_active > 20)::text),
    ('A12', 'data', 'headroom: 200 minus largest total', null,
     (select 200 - coalesce(max(n_total), 0) from per_owner)::text),
    ('A13', 'data', 'headroom: 25 minus largest active', null,
     (select 25 - coalesce(max(n_active), 0) from per_owner)::text),
    ('A14', 'data', 'rows with owner_id NULL', '0',
     (select count(*) from sl where owner_id is null)::text),
    ('A15', 'data', 'rows whose owner_id has no auth.users row', '0',
     (select count(*) from sl
       where not exists (select 1 from auth.users u where u.id = sl.owner_id))::text),

    -- S. the schema 0016 is written against.
    ('S01', 'schema', 'public.share_links exists', '1',
     (case when to_regclass('public.share_links') is null then '0' else '1' end)),
    ('S02', 'schema', 'id type/nullability', 'uuid NOT NULL',
     (select format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' NOT NULL' else ' NULL' end
        from pg_catalog.pg_attribute a
       where a.attrelid = 'public.share_links'::regclass and a.attname = 'id' and not a.attisdropped)),
    ('S03', 'schema', 'owner_id type/nullability', 'uuid NOT NULL',
     (select format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' NOT NULL' else ' NULL' end
        from pg_catalog.pg_attribute a
       where a.attrelid = 'public.share_links'::regclass and a.attname = 'owner_id' and not a.attisdropped)),
    ('S04', 'schema', 'expires_at type/nullability', 'timestamp with time zone NULL',
     (select format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' NOT NULL' else ' NULL' end
        from pg_catalog.pg_attribute a
       where a.attrelid = 'public.share_links'::regclass and a.attname = 'expires_at' and not a.attisdropped)),
    ('S05', 'schema', 'revoked_at type/nullability', 'timestamp with time zone NULL',
     (select format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' NOT NULL' else ' NULL' end
        from pg_catalog.pg_attribute a
       where a.attrelid = 'public.share_links'::regclass and a.attname = 'revoked_at' and not a.attisdropped)),
    ('S06', 'schema', 'created_at type/nullability', 'timestamp with time zone NOT NULL',
     (select format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' NOT NULL' else ' NULL' end
        from pg_catalog.pg_attribute a
       where a.attrelid = 'public.share_links'::regclass and a.attname = 'created_at' and not a.attisdropped)),
    ('S07', 'schema', 'owner_id FK -> auth.users(id) ON DELETE CASCADE', '1',
     (select count(*) from pg_catalog.pg_constraint c
       where c.conrelid = 'public.share_links'::regclass and c.contype = 'f'
         and c.confrelid = to_regclass('auth.users') and c.confdeltype = 'c'
         and c.conkey = array[(select a.attnum from pg_catalog.pg_attribute a
                                where a.attrelid = 'public.share_links'::regclass
                                  and a.attname = 'owner_id')])::text),
    ('S08', 'schema', 'an index leading on owner_id', null,
     (select string_agg(i.indexrelid::regclass::text, ',' order by 1)
        from pg_catalog.pg_index i
       where i.indrelid = 'public.share_links'::regclass
         and i.indkey[0] = (select a.attnum from pg_catalog.pg_attribute a
                             where a.attrelid = 'public.share_links'::regclass
                               and a.attname = 'owner_id'))),
    ('S09', 'schema', 'share_links_owner_idx present', '1',
     (case when to_regclass('public.share_links_owner_idx') is null then '0' else '1' end)),
    ('S10', 'schema', 'row level security enabled', 'true',
     (select c.relrowsecurity::text from pg_catalog.pg_class c
       where c.oid = 'public.share_links'::regclass)),
    ('S11', 'schema', 'policies (name cmd roles)', null,
     (select string_agg(policyname || ' ' || cmd || ' ' || array_to_string(roles, ','), '; ' order by policyname)
        from pg_catalog.pg_policies where schemaname = 'public' and tablename = 'share_links')),
    ('S12', 'schema', 'user triggers on public.share_links (before 0016)', '0',
     (select count(*) from pg_catalog.pg_trigger
       where tgrelid = 'public.share_links'::regclass and not tgisinternal)::text),
    ('S13', 'schema', 'share_links relacl unchanged since M-E postflight',
     'postgres=arwdDxtm/postgres service_role=Dxtm/postgres',
     (select coalesce(array_to_string(c.relacl, ' '), '(null)') from pg_catalog.pg_class c
       where c.oid = 'public.share_links'::regclass)),
    ('S14', 'schema', 'anon/authenticated hold any table privilege', 'false',
     (has_table_privilege('anon', 'public.share_links', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
      or has_table_privilege('authenticated', 'public.share_links', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))::text),

    -- C. nothing 0016 creates may exist yet. Any FAIL here: STOP.
    ('C01', 'collide', 'timeweave_private schema exists (0016 needs it)', '1',
     (select count(*) from pg_catalog.pg_namespace where nspname = 'timeweave_private')::text),
    ('C02', 'collide', 'timeweave_private.share_link_create_rate exists', '0',
     (case when to_regclass('timeweave_private.share_link_create_rate') is null then '0' else '1' end)),
    ('C03', 'collide', 'relation named share_link_create_rate in ANY schema', '0',
     (select count(*) from pg_catalog.pg_class where relname = 'share_link_create_rate')::text),
    ('C04', 'collide', 'share_links_max_active_per_owner()', '0',
     (case when to_regprocedure('public.share_links_max_active_per_owner()') is null then '0' else '1' end)),
    ('C05', 'collide', 'share_links_max_total_per_owner()', '0',
     (case when to_regprocedure('public.share_links_max_total_per_owner()') is null then '0' else '1' end)),
    ('C06', 'collide', 'share_links_rate_interval()', '0',
     (case when to_regprocedure('public.share_links_rate_interval()') is null then '0' else '1' end)),
    ('C07', 'collide', 'share_links_rate_burst()', '0',
     (case when to_regprocedure('public.share_links_rate_burst()') is null then '0' else '1' end)),
    ('C08', 'collide', 'enforce_quota / enforce_create_rate functions', '0',
     ((case when to_regprocedure('public.share_links_enforce_quota()') is null then 0 else 1 end)
      + (case when to_regprocedure('public.share_links_enforce_create_rate()') is null then 0 else 1 end))::text),
    ('C09', 'collide', 'ANY function named share_links_% in ANY schema (any signature)', '0',
     (select count(*) from pg_catalog.pg_proc where proname like 'share\_links\_%')::text),
    ('C10', 'collide', 'triggers named share_links_quota_ai/_au/rate_ai on ANY table', '0',
     (select count(*) from pg_catalog.pg_trigger
       where tgname in ('share_links_quota_ai', 'share_links_quota_au', 'share_links_rate_ai'))::text),

    -- R. the five share-link RPCs, as a baseline 0016 must not move.
    ('R01', 'rpc', 'the five RPCs, one definition each (names/defs)', '5/5',
     (select count(distinct proname) || '/' || count(*) from rpc)::text),
    ('R02', 'rpc', 'of them DEFINER with search_path=""', '5',
     (select count(*) from rpc where prosecdef and cfg = 'search_path=""')::text),
    ('R03', 'rpc', 'create_share_link sig | result | acl | src', null,
     (select sig || ' | ' || res || ' | ' || acl || ' | ' || src from rpc where proname = 'create_share_link')),
    ('R04', 'rpc', 'list_share_links sig | result | acl | src', null,
     (select sig || ' | ' || res || ' | ' || acl || ' | ' || src from rpc where proname = 'list_share_links')),
    ('R05', 'rpc', 'revoke_share_link sig | result | acl | src', null,
     (select sig || ' | ' || res || ' | ' || acl || ' | ' || src from rpc where proname = 'revoke_share_link')),
    ('R06', 'rpc', 'delete_share_link sig | result | acl | src', null,
     (select sig || ' | ' || res || ' | ' || acl || ' | ' || src from rpc where proname = 'delete_share_link')),
    ('R07', 'rpc', 'get_free_busy sig | result | acl | src', null,
     (select sig || ' | ' || res || ' | ' || acl || ' | ' || src from rpc where proname = 'get_free_busy')),

    -- E. the event limiter, as a baseline 0016 must not move.
    ('E01', 'events', 'timeweave_private.event_write_rate exists', '1',
     (case when to_regclass('timeweave_private.event_write_rate') is null then '0' else '1' end)),
    ('E02', 'events', 'timeweave_private schema ACL', null,
     (select coalesce(array_to_string(nspacl, ' '), '(null)') from pg_catalog.pg_namespace
       where nspname = 'timeweave_private')),
    ('E03', 'events', 'event_write_rate relacl', null,
     (select coalesce(array_to_string(relacl, ' '), '(null)') from pg_catalog.pg_class
       where oid = to_regclass('timeweave_private.event_write_rate'))),
    ('E04', 'events', 'client roles can reach event_write_rate', 'false',
     (has_schema_privilege('anon', 'timeweave_private', 'USAGE')
      or has_schema_privilege('authenticated', 'timeweave_private', 'USAGE')
      or has_schema_privilege('service_role', 'timeweave_private', 'USAGE'))::text),
    ('E05', 'events', 'user triggers on public.events, in firing order',
     'events_quota_exception_ai,events_quota_exception_au,events_quota_owner_ai,events_quota_owner_au,events_rate_ai,events_rate_au,events_set_updated_at,events_validate_timezone',
     (select string_agg(tgname, ',' order by tgname) from pg_catalog.pg_trigger
       where tgrelid = 'public.events'::regclass and not tgisinternal)),
    ('E06', 'events', '0011/0012 functions present', '7',
     (select count(*) from ev_fn)::text),
    ('E07', 'events', '0011/0012 function fingerprint (md5 of name|acl|src)', null,
     (select md5(string_agg(proname || '|' || acl || '|' || src, ';' order by proname)) from ev_fn)),

    -- L. advisory-lock classes: where they are used today.
    ('L01', 'locks', 'functions whose body mentions 811001', 'public.events_enforce_owner_quota',
     (select string_agg(fq, ',' order by fq) from user_fn where prosrc like '%811001%')),
    ('L02', 'locks', 'functions whose body mentions 811002', 'public.events_enforce_exception_quota',
     (select string_agg(fq, ',' order by fq) from user_fn where prosrc like '%811002%')),
    ('L03', 'locks', 'functions whose body mentions any OTHER 811xxx class', '0',
     (select count(*) from user_fn
       where prosrc ~ '811[0-9]{3}'
         and regexp_replace(prosrc, '81100[12]', '', 'g') ~ '811[0-9]{3}')::text),
    ('L04', 'locks', 'exception_quota < owner_quota < rate trigger names all present', '6',
     (select count(*) from pg_catalog.pg_trigger
       where tgrelid = 'public.events'::regclass
         and tgname in ('events_quota_exception_ai', 'events_quota_exception_au',
                        'events_quota_owner_ai', 'events_quota_owner_au',
                        'events_rate_ai', 'events_rate_au'))::text),

    -- P. privileges that could shape what 0016 creates.
    ('P01', 'privs', 'role that will run the migration (current_user)', null,
     current_user::text),
    ('P02', 'privs', 'ALL default ACL entries: role/schema/type=acl', null,
     (select coalesce(string_agg(d.defaclrole::regrole::text || '/'
                                 || coalesce(n.nspname, '*') || '/' || d.defaclobjtype::text
                                 || '=' || array_to_string(d.defaclacl, ' '),
                                 '; ' order by 1), '(none)')
        from pg_catalog.pg_default_acl d
        left join pg_catalog.pg_namespace n on n.oid = d.defaclnamespace)),
    ('P03', 'privs', 'default FUNCTION grants for current_user in public or global', null,
     (select coalesce(string_agg(coalesce(n.nspname, '*') || '=' || array_to_string(d.defaclacl, ' '), '; '), '(none)')
        from pg_catalog.pg_default_acl d
        left join pg_catalog.pg_namespace n on n.oid = d.defaclnamespace
       where d.defaclrole = current_user::regrole and d.defaclobjtype = 'f'
         and (n.nspname = 'public' or d.defaclnamespace = 0))),
    ('P04', 'privs', 'default TABLE grants for current_user in timeweave_private or global', null,
     (select coalesce(string_agg(coalesce(n.nspname, '*') || '=' || array_to_string(d.defaclacl, ' '), '; '), '(none)')
        from pg_catalog.pg_default_acl d
        left join pg_catalog.pg_namespace n on n.oid = d.defaclnamespace
       where d.defaclrole = current_user::regrole and d.defaclobjtype = 'r'
         and (n.nspname = 'timeweave_private' or d.defaclnamespace = 0))),
    ('P05', 'privs', 'delete_share_link proacl (a function created in public by 0015)', null,
     (select acl from rpc where proname = 'delete_share_link')),
    ('P06', 'privs', 'events_rate_burst proacl (a getter created in public by 0012)', null,
     (select acl from ev_fn where proname = 'events_rate_burst')),
    ('P07', 'privs', 'events_enforce_write_rate proacl (an enforce fn from 0012)', null,
     (select acl from ev_fn where proname = 'events_enforce_write_rate')),
    ('P08', 'privs', 'client roles hold USAGE on timeweave_private', 'false',
     (has_schema_privilege('anon', 'timeweave_private', 'USAGE')
      or has_schema_privilege('authenticated', 'timeweave_private', 'USAGE'))::text)

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
