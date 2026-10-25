-- ============================================================================
-- P8 RELEASE PREFLIGHT, STAGE A1a -- CATALOG ONLY. READ ONLY.
-- ============================================================================
-- Run in the Supabase SQL Editor as the role that would apply the migrations
-- (postgres), with the user's approval for A1a. It is separate from A1b (data
-- counts: P8_preflight_A1b_data.sql), A1c (timings: P8_preflight_A1c_timing.sql),
-- A1d (rrule text: P8_preflight_A1d_rrule_text.sql) and from applying 0027 /
-- 0028 / 0029.
--
-- WHAT THIS STAGE READS. Catalogs, settings and statistics only: it scans no
-- application table and calls no application function. Its cost does not grow
-- with the data (measured on the isolated database: well under 10 ms).
--
-- HOW TO RUN -- one execution of the whole file, never statement by statement:
--   SQL Editor: run all.   psql: psql -X -1 -v ON_ERROR_STOP=1 -f <this file>
-- READ ONLY -- WHAT IS GUARANTEED AND WHAT IS NOT
--   * Lines 1-2 make the transaction read-only with a time limit, for the whole
--     run, WHEN the run is one transaction: one query string (PostgreSQL then
--     runs it as one implicit transaction) or psql -1. Measured on the isolated
--     database: writes after them were refused.
--   * Statement 3 (the gate) stops the run with an error naming the setting
--     unless both are in effect; then nothing after it runs (measured: one
--     string, psql -1, and psql -f with ON_ERROR_STOP; plain psql -f without
--     ON_ERROR_STOP would go on -- never run it that way).
--   * Whether the SQL Editor sends the file as one string is NOT verified. A1a
--     is the probe: it is cheap and reads only catalogs, so if the editor did
--     not send one string, the worst case is a harmless catalog read and the
--     gate error. A1b, A1c, A1d are run in the editor ONLY if A1a passed its
--     gate there (R00 = on, R01 = 10s): that shows the editor sends one string.
--   * Independently of all that, this file calls only catalog functions.
--
-- OUTPUT. Rows of (id, area, item, value, verdict): settings, role / function /
-- constraint names, counts from the catalog and planner statistics. No event
-- title, description, category, owner id, token, link label or rrule text.
-- GATE-OK / GATE-FAIL decide whether a step may go ahead as planned; INFO is
-- context; WARN asks for a decision.
-- ============================================================================
set transaction read only;
set local statement_timeout = '10s';
-- GATE: stops the run here, with the reason, unless BOTH lines above are in
-- effect. When the file runs as one execution, an error ends it: nothing below
-- runs. (Measured on the isolated database for every way of sending it.)
select case when current_setting('transaction_read_only') = 'on' and current_setting('statement_timeout') = '10s'
            then 'gate: read only, 10s'
            else ('STOPPED: read_only=' || current_setting('transaction_read_only') || ', statement_timeout=' || current_setting('statement_timeout'))::int::text end as gate;
with
me as (select current_user::text as u),
-- --------------------------------------------------------------- read-only and limits of THIS run
guard as (
  select 'R00'::text as id, 'this run'::text as area, 'transaction_read_only (must be on)'::text as item,
         current_setting('transaction_read_only') as value,
         case when current_setting('transaction_read_only') = 'on' then 'GATE-OK' else 'GATE-FAIL' end::text as verdict
  union all select 'R01', 'this run', 'statement_timeout in effect (must be 10s)', current_setting('statement_timeout'),
         case when current_setting('statement_timeout') = '10s' then 'GATE-OK' else 'GATE-FAIL' end
),
-- --------------------------------------------------------------- environment
env as (
  select 'V01'::text as id, 'environment'::text as area, 'server_version'::text as item, current_setting('server_version') as value, 'INFO'::text as verdict
  union all select 'V02', 'environment', 'server_version_num (17xxxx expected)', current_setting('server_version_num'),
    case when current_setting('server_version_num')::int between 170000 and 179999 then 'GATE-OK' else 'WARN' end
  union all select 'V03', 'environment', 'TimeZone / log_timezone', current_setting('TimeZone') || ' / ' || current_setting('log_timezone'), 'INFO'
  union all select 'V04', 'environment', 'current_user / session_user', current_user::text || ' / ' || session_user::text, 'INFO'
  union all select 'V05', 'environment', 'tzdata: Havana 2026-11-01 has two midnights (0027 premise)',
    ((timestamptz '2026-11-01 04:30Z' at time zone 'America/Havana') = timestamp '2026-11-01 00:30'
     and (timestamptz '2026-11-01 05:30Z' at time zone 'America/Havana') = timestamp '2026-11-01 00:30')::text,
    case when (timestamptz '2026-11-01 04:30Z' at time zone 'America/Havana') = timestamp '2026-11-01 00:30'
          and (timestamptz '2026-11-01 05:30Z' at time zone 'America/Havana') = timestamp '2026-11-01 00:30' then 'GATE-OK' else 'WARN' end
  union all select 'V06', 'environment', 'statement_timeout set per role (anon / authenticated / authenticator / service_role)',
    (select string_agg(r.rolname || '=' || coalesce((select split_part(c, '=', 2) from unnest(r.rolconfig) c where c like 'statement_timeout=%'), '(none)'), ', ' order by r.rolname)
       from pg_catalog.pg_roles r where r.rolname in ('anon', 'authenticated', 'authenticator', 'service_role')), 'INFO'
  union all select 'V07', 'monitoring', 'pg_stat_statements installed',
    exists (select 1 from pg_catalog.pg_extension where extname = 'pg_stat_statements')::text, 'INFO'
),
-- --------------------------------------------------------------- applied migrations (by their objects)
mig as (
  select 'M01'::text as id, 'migrations'::text as area, item, value, verdict from (values
    ('0006 rrule_parse',                    (to_regprocedure('public.rrule_parse(text)') is not null)::text, 'expect true'),
    ('0008 timezone_is_supported',          (to_regprocedure('public.timezone_is_supported(text)') is not null)::text, 'expect true'),
    ('0013 events_rrule_len',               exists (select 1 from pg_catalog.pg_constraint where conname = 'events_rrule_len')::text, 'expect true'),
    ('0013 events_allday_range / timed_range', (select count(*)::text from pg_catalog.pg_constraint where conname in ('events_allday_range', 'events_timed_range')), 'expect 2'),
    ('0012 events_rate_ai',                 exists (select 1 from pg_catalog.pg_trigger where tgname = 'events_rate_ai')::text, 'expect true'),
    ('0017 events_quota_graph_ai',          exists (select 1 from pg_catalog.pg_trigger where tgname = 'events_quota_graph_ai')::text, 'expect true'),
    ('0018 timezone_is_resolvable',         (to_regprocedure('public.timezone_is_resolvable(text)') is not null)::text, 'expect true'),
    ('0019 freebusy_link_rate',             (to_regclass('timeweave_private.freebusy_link_rate') is not null)::text, 'expect true'),
    ('0020 events.availability',            exists (select 1 from pg_catalog.pg_attribute where attrelid = 'public.events'::regclass and attname = 'availability' and not attisdropped)::text, 'expect true'),
    ('0022 share_links.share_available',    exists (select 1 from pg_catalog.pg_attribute where attrelid = 'public.share_links'::regclass and attname = 'share_available' and not attisdropped)::text, 'expect true'),
    ('0024 free_busy_available',            (to_regprocedure('timeweave_private.free_busy_available(uuid, timestamptz, timestamptz, date, date, jsonb)') is not null)::text, 'expect true'),
    ('0025 owner_settings',                 (to_regclass('public.owner_settings') is not null)::text, 'expect true'),
    ('0026 owner_settings: authenticated has no TRUNCATE', (not has_table_privilege('authenticated', 'public.owner_settings', 'TRUNCATE'))::text, 'expect true'),
    ('0027 zoned_day_start (absent before 0027)',          (to_regprocedure('timeweave_private.zoned_day_start(date, text)') is not null)::text, 'expect false'),
    ('0028 timezone_name_listed (absent before 0028)',     (to_regprocedure('public.timezone_name_listed(text)') is not null)::text, 'expect false'),
    ('0029 trigger events_validate_rrule (absent before 0029)', exists (select 1 from pg_catalog.pg_trigger where tgname = 'events_validate_rrule')::text, 'expect false'),
    -- 0029 uses CREATE OR REPLACE for its two functions: an existing function of
    -- the same signature (unknown origin) would be silently replaced. Require absence.
    ('0029 function events_validate_rrule() (absent before 0029)', (to_regprocedure('public.events_validate_rrule()') is not null)::text, 'expect false'),
    ('0029 function rrule_is_writable(text, boolean) (absent before 0029)', (to_regprocedure('public.rrule_is_writable(text, boolean)') is not null)::text, 'expect false')
  ) v(item, value, verdict)
  union all
  select 'M02', 'migrations', 'supabase_migrations.schema_migrations present (migrations here were applied in the SQL Editor; may be absent)',
    (to_regclass('supabase_migrations.schema_migrations') is not null)::text, 'INFO'
),
mig_v as (
  select id, area, item, value,
         case when verdict = 'expect true'  then case when value = 'true'  then 'GATE-OK' else 'GATE-FAIL' end
              when verdict = 'expect false' then case when value = 'false' then 'GATE-OK' else 'GATE-FAIL' end
              when verdict = 'expect 2'     then case when value = '2'     then 'GATE-OK' else 'GATE-FAIL' end
              else verdict end as verdict
  from mig
),
-- --------------------------------------------------------------- function bodies the later stages call or replace
-- md5 of prosrc with CRLF turned into LF (0018 / 0027 checks do the same): a
-- body created from a file with Windows line endings (SQL Editor) and one created
-- by psql (LF) are the same code and must give the same fingerprint, while any
-- other change still changes it. Fingerprints = the repository's migrations
-- (same on three isolated databases; production A1a's raw md5s matched the
-- CRLF form of the same files). A1b calls rrule_parse and timezone_is_supported, A1c calls
-- timezone_is_supported, and 0028's rollback restores 0008's body of
-- timezone_is_supported: they must be the code that was reviewed.
fp as (
  select 'F01'::text as id, 'function bodies'::text as area, 'rrule_parse = 0006 body (A1b calls it; md5 after CRLF->LF)'::text as item,
         coalesce(md5(replace(p.prosrc, E'\r\n', E'\n')), '(missing)') as value,
         case when md5(replace(p.prosrc, E'\r\n', E'\n')) = '2e59e47964e4f403914c86249a2daaaa' then 'GATE-OK' else 'GATE-FAIL' end::text as verdict
  from (select 1) x left join pg_catalog.pg_proc p on p.oid = to_regprocedure('public.rrule_parse(text)')
  union all
  select 'F02', 'function bodies', 'timezone_is_supported = 0008 body (A1b/A1c call it; 0028 replaces it; md5 after CRLF->LF)',
         coalesce(md5(replace(p.prosrc, E'\r\n', E'\n')), '(missing)'),
         case when md5(replace(p.prosrc, E'\r\n', E'\n')) = 'd6d46c844ff9c154870f67b757dd3b4f' then 'GATE-OK' else 'GATE-FAIL' end
  from (select 1) x left join pg_catalog.pg_proc p on p.oid = to_regprocedure('public.timezone_is_supported(text)')
  union all
  select 'F03', 'function bodies', 'rrule_parse / timezone_is_supported are STABLE, SECURITY INVOKER, search_path pinned',
         string_agg(p.proname || ':' || p.provolatile::text || ':' || case when p.prosecdef then 'definer' else 'invoker' end || ':' || coalesce(array_to_string(p.proconfig, ','), '-'), ' ' order by p.proname),
         -- coalesce: with no proconfig, @> is NULL and bool_and would skip that row
         case when count(*) = 2 and bool_and(coalesce(p.provolatile = 's' and not p.prosecdef and p.proconfig @> array['search_path=""'], false)) then 'GATE-OK' else 'GATE-FAIL' end
  from pg_catalog.pg_proc p where p.oid in (to_regprocedure('public.rrule_parse(text)'), to_regprocedure('public.timezone_is_supported(text)'))
),
-- --------------------------------------------------------------- owners, roles, grants
own as (
  select 'O01'::text as id, 'owners'::text as area, 'owner of public.events (0029 must be applied as this role)'::text as item,
    pg_catalog.pg_get_userbyid(c.relowner)::text as value, case when pg_catalog.pg_get_userbyid(c.relowner) = (select u from me) then 'GATE-OK' else 'GATE-FAIL' end::text as verdict
  from pg_catalog.pg_class c where c.oid = 'public.events'::regclass
  union all
  select 'O02', 'owners', 'owner of timezone_is_supported (0028 must be applied as this role)',
    pg_catalog.pg_get_userbyid(p.proowner), case when pg_catalog.pg_get_userbyid(p.proowner) = (select u from me) then 'GATE-OK' else 'GATE-FAIL' end
  from pg_catalog.pg_proc p where p.oid = to_regprocedure('public.timezone_is_supported(text)')
  union all
  select 'O03', 'owners', 'owner of free_busy_available (0027 must be applied as this role)',
    pg_catalog.pg_get_userbyid(p.proowner), case when pg_catalog.pg_get_userbyid(p.proowner) = (select u from me) then 'GATE-OK' else 'GATE-FAIL' end
  from pg_catalog.pg_proc p where p.oid = to_regprocedure('timeweave_private.free_busy_available(uuid, timestamptz, timestamptz, date, date, jsonb)')
  union all
  select 'O04', 'owners', 'owner of get_free_busy = owner of free_busy_available (0024 A14 / 0027 coupling)',
    (select pg_catalog.pg_get_userbyid(proowner) from pg_catalog.pg_proc where oid = to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)')),
    case when (select proowner from pg_catalog.pg_proc where oid = to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)'))
            = (select proowner from pg_catalog.pg_proc where oid = to_regprocedure('timeweave_private.free_busy_available(uuid, timestamptz, timestamptz, date, date, jsonb)'))
         then 'GATE-OK' else 'GATE-FAIL' end
  union all select 'O05', 'privileges', 'current_user may CREATE in public (0028, 0029)', has_schema_privilege('public', 'CREATE')::text,
    case when has_schema_privilege('public', 'CREATE') then 'GATE-OK' else 'GATE-FAIL' end
  union all select 'O06', 'privileges', 'current_user may CREATE in timeweave_private (0027)', has_schema_privilege('timeweave_private', 'CREATE')::text,
    case when has_schema_privilege('timeweave_private', 'CREATE') then 'GATE-OK' else 'GATE-FAIL' end
  union all
  -- The ACL 0028 will copy onto timezone_name_listed, entry for entry (PUBLIC included).
  select 'O07', 'privileges', 'ACL of timezone_is_supported (0028 copies it exactly)',
    coalesce((select proacl::text from pg_catalog.pg_proc where oid = to_regprocedure('public.timezone_is_supported(text)')), '(default: PUBLIC may execute)'), 'INFO'
  union all
  select 'O08', 'privileges', 'public functions anon can EXECUTE (expect get_free_busy, and trigger functions only)',
    coalesce(string_agg(p.proname, ', ' order by p.proname), '(none)'),
    case when bool_and(p.proname = 'get_free_busy' or p.prorettype = 'pg_catalog.trigger'::regtype) then 'GATE-OK' else 'WARN' end
  from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE')
  union all
  -- How anon reaches get_free_busy: a direct grant (what the emergency stop removes), PUBLIC, or a role anon belongs to.
  select 'O09', 'privileges', 'anon reaches get_free_busy through: direct | PUBLIC | membership',
    exists (select 1 from pg_catalog.pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)')
            and a.grantee = (select oid from pg_catalog.pg_roles where rolname = 'anon') and a.privilege_type = 'EXECUTE')::text || ' | ' ||
    exists (select 1 from pg_catalog.pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where p.oid = to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)')
            and a.grantee = 0 and a.privilege_type = 'EXECUTE')::text || ' | ' ||
    exists (select 1 from pg_catalog.pg_auth_members m join pg_catalog.pg_roles r on r.oid = m.roleid
            where m.member = (select oid from pg_catalog.pg_roles where rolname = 'anon')
              and has_function_privilege(r.oid, to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)'), 'EXECUTE'))::text,
    'INFO'
  union all select 'O10', 'privileges', 'anon has USAGE on timeweave_private (expect false)', has_schema_privilege('anon', 'timeweave_private', 'USAGE')::text,
    case when has_schema_privilege('anon', 'timeweave_private', 'USAGE') then 'GATE-FAIL' else 'GATE-OK' end
  union all select 'O11', 'privileges', 'anon privileges on public.events (expect none)',
    (has_table_privilege('anon', 'public.events', 'SELECT') or has_table_privilege('anon', 'public.events', 'INSERT')
     or has_table_privilege('anon', 'public.events', 'UPDATE') or has_table_privilege('anon', 'public.events', 'DELETE'))::text,
    case when has_table_privilege('anon', 'public.events', 'SELECT') or has_table_privilege('anon', 'public.events', 'INSERT')
           or has_table_privilege('anon', 'public.events', 'UPDATE') or has_table_privilege('anon', 'public.events', 'DELETE') then 'GATE-FAIL' else 'GATE-OK' end
  union all select 'O12', 'privileges', 'RLS enabled on events / share_links',
    (select relrowsecurity::text from pg_catalog.pg_class where oid = 'public.events'::regclass) || ' / ' || (select relrowsecurity::text from pg_catalog.pg_class where oid = 'public.share_links'::regclass),
    case when (select relrowsecurity from pg_catalog.pg_class where oid = 'public.events'::regclass)
          and (select relrowsecurity from pg_catalog.pg_class where oid = 'public.share_links'::regclass) then 'GATE-OK' else 'GATE-FAIL' end
),
-- --------------------------------------------------------------- size, from planner statistics (no scan)
size as (
  select 'S01'::text as id, 'size'::text as area, 'events: estimated rows | live rows (stats) | table size'::text as item,
    c.reltuples::bigint::text || ' | ' || coalesce(s.n_live_tup, 0)::text || ' | ' || pg_catalog.pg_size_pretty(pg_catalog.pg_total_relation_size(c.oid)) as value,
    case when greatest(c.reltuples, coalesce(s.n_live_tup, 0)) > 1000000 then 'WARN' else 'INFO' end::text as verdict
  from pg_catalog.pg_class c left join pg_catalog.pg_stat_user_tables s on s.relid = c.oid where c.oid = 'public.events'::regclass
  union all
  select 'S02', 'size', 'owner_settings: estimated rows | live rows (stats)',
    c.reltuples::bigint::text || ' | ' || coalesce(s.n_live_tup, 0)::text, 'INFO'
  from pg_catalog.pg_class c left join pg_catalog.pg_stat_user_tables s on s.relid = c.oid where c.oid = 'public.owner_settings'::regclass
),
-- --------------------------------------------------------------- the whole answer
allrows as (
  select * from guard
  union all select * from env
  union all select * from mig_v
  union all select * from fp
  union all select * from own
  union all select * from size
)
select id, area, item, value, verdict from allrows
union all
select 'ZZZ', 'summary', 'GATE-FAIL rows (0 before any apply)', count(*) filter (where verdict = 'GATE-FAIL')::text,
       case when count(*) filter (where verdict = 'GATE-FAIL') = 0 then 'GATE-OK' else 'GATE-FAIL' end
from allrows
order by 1;
