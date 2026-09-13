-- ============================================================================
-- TimeWeave -- PREFLIGHT for 0012_event_write_rate_limit.sql.
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run BEFORE applying 0012, by hand,
-- against the database 0012 will be applied to.
--
-- READ-ONLY: no DDL, no DML, no SET. Wrapped in a transaction ending in
-- ROLLBACK as a belt-and-braces guarantee -- there is nothing in here that
-- could persist, but the wrapper means a reader does not have to take that on
-- trust. Same shape as 0008's and 0011's preflights.
--
-- PRIVACY: counts and ids only. Never selects title, category or description.
--
-- ============================================================================
-- WHAT IT ANSWERS
--
--   A  Would 0012 collide with something already there? It creates a SCHEMA and
--      a TABLE, neither of which is idempotent, so a second application must
--      fail -- and it should fail here, cheaply, rather than half way through
--      a transaction that holds a lock on public.events. Checks 10-16.
--
--   B  Is 0011 actually in place? 0012's deadlock argument is "my row lock is
--      always taken after 0011's two advisory locks, because triggers of equal
--      timing fire in name order and 'q' < 'r'". That argument presumes those
--      triggers exist with those names. Checks 20-23.
--
--   C  Can the FK be created? owner_id references auth.users(id). Check 30.
--
--   D  Does the server support what the trigger needs? Transition tables are
--      PostgreSQL 10+. Check 31.
--
--   E  What is the blast radius? 0012 takes SHARE ROW EXCLUSIVE on public.events
--      to add two triggers -- that blocks writes, briefly, but not reads. Checks
--      40-43 report how much data and how many owners are behind that lock, and
--      whether any owner is currently writing at a rate the new limit would have
--      refused (it cannot be known retroactively -- created_at is client
--      writable -- so 42 is reported as context, never as a gate).
--
-- THE ONE THING THIS FILE CANNOT ANSWER: whether timeweave_private is absent
-- from PostgREST's exposed schemas. That is project configuration, not database
-- state. It is verified after the fact, over REST, by the postflight's manual
-- section.
--
-- ============================================================================
-- HOW TO READ THE OUTPUT
--   verdict 'ok'    -> proceed
--   verdict 'FAIL'  -> do not apply. The `got` column says what is in the way.
--   verdict 'context' -> information, never a gate.
-- ============================================================================

begin;

with
-- ---------------------------------------------------------------- A: collisions
a as (
  select
    (to_regnamespace('timeweave_private') is not null)                    as schema_exists,
    (to_regclass('timeweave_private.event_write_rate') is not null)       as table_exists,
    (to_regproc('public.events_enforce_write_rate') is not null)          as fn_enforce_exists,
    (to_regproc('public.events_rate_interval') is not null)               as fn_interval_exists,
    (to_regproc('public.events_rate_burst') is not null)                  as fn_burst_exists,
    (select count(*) from pg_trigger t
      where t.tgrelid = 'public.events'::regclass
        and not t.tgisinternal
        and t.tgname in ('events_rate_ai', 'events_rate_au'))             as rate_triggers,
    (select count(*) from pg_class c
      where c.relname = 'event_write_rate')                               as tables_named_anywhere
),
-- ---------------------------------------------------------------- B: 0011
b as (
  select
    (select count(*) from pg_trigger t
      where t.tgrelid = 'public.events'::regclass
        and not t.tgisinternal
        and t.tgname like 'events_quota_%')                               as quota_triggers,
    (select count(*) from pg_trigger t
      where t.tgrelid = 'public.events'::regclass
        and not t.tgisinternal)                                          as all_triggers,
    (select string_agg(t.tgname, ', ' order by t.tgname) from pg_trigger t
      where t.tgrelid = 'public.events'::regclass and not t.tgisinternal) as trigger_names,
    -- The ordering argument, checked rather than asserted in prose: every
    -- existing AFTER-STATEMENT trigger name must sort before 'events_rate_ai'.
    (select coalesce(bool_and(t.tgname < 'events_rate_ai'), true)
       from pg_trigger t
      where t.tgrelid = 'public.events'::regclass
        and not t.tgisinternal
        and (t.tgtype & 1) = 0)                                           as names_sort_before
),
-- ---------------------------------------------------------------- C/D: server
c as (
  select
    (to_regclass('auth.users') is not null)                               as auth_users_exists,
    has_table_privilege(current_user, 'auth.users', 'REFERENCES')         as can_reference,
    current_setting('server_version_num')::int                            as server_version_num
),
-- ---------------------------------------------------------------- E: blast radius
e as (
  select
    (select count(*) from public.events)                                  as event_rows,
    (select count(distinct owner_id) from public.events)                  as owners,
    (select coalesce(max(n), 0) from (
        select count(*) as n from public.events group by owner_id) x)     as max_rows_one_owner,
    (select count(*) from public.events
      where created_at > now() - interval '1 minute')                     as rows_claiming_last_minute
)
select ord, name, got, want,
       case when want = '(context)' then 'context'
            when got is not distinct from want then 'ok'
            else 'FAIL' end as verdict
from (
  -- A -------------------------------------------------------------------
  select 10 as ord, 'schema timeweave_private does not exist yet' as name,
         (select schema_exists::text from a) as got, 'false' as want
  union all
  select 11, 'table timeweave_private.event_write_rate does not exist yet',
         (select table_exists::text from a), 'false'
  union all
  select 12, 'function events_enforce_write_rate does not exist yet',
         (select fn_enforce_exists::text from a), 'false'
  union all
  select 13, 'function events_rate_interval does not exist yet',
         (select fn_interval_exists::text from a), 'false'
  union all
  select 14, 'function events_rate_burst does not exist yet',
         (select fn_burst_exists::text from a), 'false'
  union all
  select 15, 'triggers events_rate_ai / events_rate_au do not exist yet',
         (select rate_triggers::text from a), '0'
  union all
  select 16, 'no table named event_write_rate in ANY schema',
         (select tables_named_anywhere::text from a), '0'
  -- B -------------------------------------------------------------------
  union all
  select 20, '0011 quota triggers present (the lock-order argument needs them)',
         (select quota_triggers::text from b), '4'
  union all
  select 21, 'public.events currently carries exactly six triggers',
         (select all_triggers::text from b), '6'
  union all
  select 22, 'every existing statement trigger name sorts before events_rate_ai',
         (select names_sort_before::text from b), 'true'
  union all
  select 23, 'the six trigger names',
         (select trigger_names from b), '(context)'
  -- C / D ---------------------------------------------------------------
  union all
  select 30, 'auth.users exists (FK target)',
         (select auth_users_exists::text from c), 'true'
  union all
  select 31, 'current role may create a FK to auth.users',
         (select can_reference::text from c), 'true'
  union all
  select 32, 'server supports transition tables (>= 10)',
         (select (server_version_num >= 100000)::text from c), 'true'
  union all
  select 33, 'server_version_num',
         (select server_version_num::text from c), '(context)'
  -- E -------------------------------------------------------------------
  union all
  select 40, 'rows in public.events (behind the SHARE ROW EXCLUSIVE lock)',
         (select event_rows::text from e), '(context)'
  union all
  select 41, 'distinct owners',
         (select owners::text from e), '(context)'
  union all
  select 42, 'largest single owner, in rows',
         (select max_rows_one_owner::text from e), '(context)'
  union all
  select 43, 'rows CLAIMING a created_at in the last minute -- NOT evidence of '
             'a write rate: created_at is client-writable (measured)',
         (select rows_claiming_last_minute::text from e), '(context)'
) s
order by ord;

rollback;
