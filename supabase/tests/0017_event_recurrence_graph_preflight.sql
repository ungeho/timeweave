-- ============================================================================
-- TimeWeave -- PREFLIGHT for 0017_event_recurrence_graph.sql (M-B).
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run by hand, once, against the project
-- 0017 will be applied to, BEFORE applying it. Valid only for the frozen 0017:
--
--   sha256   692423399eafedfecf3689f0db4e504c02e4db54e5bbfee8e57c9c1d2554118c
--   git blob 46203271a6f2dfc2da561c6a904121a521abee95   (16,254 bytes, 342 lines)
--
-- READ-ONLY: SELECT and catalog inspection only. No DDL, no DML, no SET, no
-- temp table, no RPC, no advisory lock, nothing that fires a trigger. One
-- statement inside a read-only transaction that ends in ROLLBACK.
--
-- WHAT IT GATES
--
--   G. graph      today's data already satisfies the 0017 invariant   G01-G12
--   S. schema     the columns, FK, CHECKs and indexes 0017 relies on   S01-S13
--   C. collide    NOTHING 0017 creates exists yet -- no prior, partial C01-C07
--                 or old-name apply. 0017 re-applies silently (create
--                 or replace + drop trigger if exists), so a prior apply
--                 is caught HERE or not at all.
--   T. triggers   the 8 current events triggers, and the order 0017    T01-T05
--                 will produce
--   L. locks      where 811001 / 811002 / event_write_rate are used    L01-L05
--   F. baseline   fingerprints 0017 must leave untouched (compare      F01-F06
--                 production-before to production-after)
--   P. privs      default privileges that would shape 0017's ACL       P01-P05
--
-- The invariant tested in G is exactly 0017's: every row with a recurrence_id
-- has a parent with the same id and owner, rrule IS NOT NULL, same all_day.
--
-- PRIVACY. Counts, types, catalog text and source hashes only. No title,
-- description, label, row id or owner id is ever returned.
--
-- READING THE OUTPUT. status 'ok' / 'FAIL' where an expectation exists,
-- 'context' for measurements and baselines. P00 summarises. Any FAIL in C:
-- STOP, do not apply -- even if re-running 0017 "would make it consistent".
-- ============================================================================
begin transaction read only;

with
ev as (
  select e.id, e.owner_id, e.recurrence_id, e.rrule, e.all_day, e.is_cancelled
  from public.events as e
),
ch as (
  select c.id, c.owner_id, c.recurrence_id, c.all_day,
         p.id is not null        as has_parent,
         p.rrule is not null     as parent_is_master,
         p.recurrence_id is not null as parent_is_child,
         p.all_day = c.all_day   as same_kind
  from ev c
  left join ev p on p.id = c.recurrence_id and p.owner_id = c.owner_id
  where c.recurrence_id is not null
),
trg as (
  select t.tgname,
         t.tgname || ':' || case when t.tgtype & 2 = 2 then 'before' else 'after' end || ':'
           || concat_ws('+', case when t.tgtype & 4 = 4 then 'insert' end,
                             case when t.tgtype & 16 = 16 then 'update' end,
                             case when t.tgtype & 8 = 8 then 'delete' end) || ':'
           || case when t.tgtype & 1 = 1 then 'row' else 'statement' end || ':'
           || t.tgenabled::text || ':'
           || coalesce(t.tgoldtable, '-') || '/' || coalesce(t.tgnewtable, '-') as d,
         t.tgtype
  from pg_catalog.pg_trigger t
  where t.tgrelid = 'public.events'::regclass and not t.tgisinternal
),
fn as (
  select p.proname,
         p.proname || '|' || pg_catalog.pg_get_function_identity_arguments(p.oid) || '|'
           || pg_catalog.pg_get_function_result(p.oid) || '|' || p.prosecdef::text || '|'
           || coalesce(array_to_string(p.proconfig, ','), '') || '|'
           || coalesce(array_to_string(p.proacl, ' '), '(default)') || '|' || md5(p.prosrc) as f
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('events_enforce_owner_quota', 'events_enforce_exception_quota',
                      'events_enforce_write_rate', 'events_max_per_owner',
                      'events_max_exceptions_per_master', 'events_rate_interval',
                      'events_rate_burst', 'events_validate_timezone',
                      'events_timezone_transition_error', 'timezone_is_supported',
                      'set_updated_at')
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

    -- G. today's data against the 0017 invariant.
    ('G01', 'graph', 'events rows', null, (select count(*) from ev)::text),
    ('G02', 'graph', 'exception rows (recurrence_id set)', null, (select count(*) from ch)::text),
    ('G03', 'graph', 'master rows (rrule set)', null, (select count(*) from ev where rrule is not null)::text),
    ('G04', 'graph', 'distinct owners', null, (select count(distinct owner_id) from ev)::text),
    ('G05', 'graph', 'exceptions with no same-owner parent (FK territory)', '0',
     (select count(*) from ch where not has_parent)::text),
    ('G06', 'graph', 'exceptions whose parent is not a master', '0',
     (select count(*) from ch where has_parent and not parent_is_master)::text),
    ('G07', 'graph', 'exceptions whose parent is itself an exception (chain)', '0',
     (select count(*) from ch where has_parent and parent_is_child)::text),
    ('G08', 'graph', 'exceptions of a different all_day kind than the parent', '0',
     (select count(*) from ch where has_parent and not same_kind)::text),
    ('G09', 'graph', 'self-parent rows', '0',
     (select count(*) from ev where recurrence_id = id)::text),
    ('G10', 'graph', 'TOTAL rows violating the exact 0017 predicate', '0',
     (select count(*) from ch where not (has_parent and parent_is_master and same_kind))::text),
    ('G11', 'graph', 'masters that have exceptions / largest exception count', null,
     (select count(*) || ' / ' || coalesce(max(n), 0)
        from (select recurrence_id, count(*) n from ch group by recurrence_id) x)::text),
    ('G12', 'graph', 'cancelled exceptions', null,
     (select count(*) from ev where is_cancelled)::text),

    -- S. the schema 0017 was written and verified against.
    ('S01', 'schema', 'recurrence-related columns: type / nullability',
     'all_day boolean NOT NULL, id uuid NOT NULL, is_cancelled boolean NOT NULL, owner_id uuid NOT NULL, recurrence_id uuid NULL, recurrence_slot_date date NULL, recurrence_slot_start timestamp with time zone NULL, rrule text NULL, timezone text NULL',
     (select string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod)
                        || case when a.attnotnull then ' NOT NULL' else ' NULL' end, ', ' order by a.attname)
        from pg_catalog.pg_attribute a
       where a.attrelid = 'public.events'::regclass and a.attnum > 0 and not a.attisdropped
         and a.attname in ('id', 'owner_id', 'rrule', 'recurrence_id', 'all_day',
                           'recurrence_slot_start', 'recurrence_slot_date', 'is_cancelled', 'timezone'))),
    ('S02', 'schema', 'composite recurrence FK definition',
     'FOREIGN KEY (recurrence_id, owner_id) REFERENCES events(id, owner_id) ON DELETE CASCADE',
     (select pg_get_constraintdef(oid) from pg_catalog.pg_constraint
       where conrelid = 'public.events'::regclass and conname = 'events_recurrence_owner_fkey')),
    ('S03', 'schema', 'FK on delete / on update / match  (c = cascade, a = no action, s = simple)', 'cas',
     (select confdeltype::text || confupdtype::text || confmatchtype::text from pg_catalog.pg_constraint
       where conrelid = 'public.events'::regclass and conname = 'events_recurrence_owner_fkey')),
    ('S04', 'schema', 'FKs on events that involve recurrence_id (legacy single-column FK gone)', '1',
     (select count(*) from pg_catalog.pg_constraint c
       where c.conrelid = 'public.events'::regclass and c.contype = 'f'
         and (select a.attnum from pg_catalog.pg_attribute a
               where a.attrelid = 'public.events'::regclass and a.attname = 'recurrence_id') = any(c.conkey))::text),
    ('S05', 'schema', 'events_id_owner_key', 'UNIQUE (id, owner_id)',
     (select pg_get_constraintdef(oid) from pg_catalog.pg_constraint
       where conrelid = 'public.events'::regclass and conname = 'events_id_owner_key')),
    ('S06', 'schema', 'events_master_not_exception',
     'CHECK ((NOT ((rrule IS NOT NULL) AND (recurrence_id IS NOT NULL))))',
     (select pg_get_constraintdef(oid) from pg_catalog.pg_constraint
       where conrelid = 'public.events'::regclass and conname = 'events_master_not_exception')),
    ('S07', 'schema', 'events_recurrence_not_self',
     'CHECK (((recurrence_id IS NULL) OR (recurrence_id <> id)))',
     (select pg_get_constraintdef(oid) from pg_catalog.pg_constraint
       where conrelid = 'public.events'::regclass and conname = 'events_recurrence_not_self')),
    ('S08', 'schema', 'events_exception_slot',
     'CHECK ((((recurrence_id IS NULL) AND (recurrence_slot_start IS NULL) AND (recurrence_slot_date IS NULL)) OR ((recurrence_id IS NOT NULL) AND (all_day = false) AND (recurrence_slot_start IS NOT NULL) AND (recurrence_slot_date IS NULL)) OR ((recurrence_id IS NOT NULL) AND (all_day = true) AND (recurrence_slot_date IS NOT NULL) AND (recurrence_slot_start IS NULL))))',
     (select pg_get_constraintdef(oid) from pg_catalog.pg_constraint
       where conrelid = 'public.events'::regclass and conname = 'events_exception_slot')),
    ('S09', 'schema', 'events_cancel_only_on_exception',
     'CHECK (((is_cancelled = false) OR (recurrence_id IS NOT NULL)))',
     (select pg_get_constraintdef(oid) from pg_catalog.pg_constraint
       where conrelid = 'public.events'::regclass and conname = 'events_cancel_only_on_exception')),
    ('S10', 'schema', 'CHECK constraints on events (0013 postflight: 13), all validated', '13/13',
     (select count(*) || '/' || count(*) filter (where convalidated) from pg_catalog.pg_constraint
       where conrelid = 'public.events'::regclass and contype = 'c')::text),
    ('S11', 'schema', 'events_recurrence_owner_idx',
     'CREATE INDEX events_recurrence_owner_idx ON public.events USING btree (recurrence_id, owner_id) WHERE (recurrence_id IS NOT NULL)',
     (select indexdef from pg_catalog.pg_indexes where schemaname = 'public' and indexname = 'events_recurrence_owner_idx')),
    ('S12', 'schema', 'events_excl_timed_uidx',
     'CREATE UNIQUE INDEX events_excl_timed_uidx ON public.events USING btree (recurrence_id, recurrence_slot_start) WHERE (recurrence_slot_start IS NOT NULL)',
     (select indexdef from pg_catalog.pg_indexes where schemaname = 'public' and indexname = 'events_excl_timed_uidx')),
    ('S13', 'schema', 'events_excl_allday_uidx',
     'CREATE UNIQUE INDEX events_excl_allday_uidx ON public.events USING btree (recurrence_id, recurrence_slot_date) WHERE (recurrence_slot_date IS NOT NULL)',
     (select indexdef from pg_catalog.pg_indexes where schemaname = 'public' and indexname = 'events_excl_allday_uidx')),

    -- C. prior / partial / old-name apply. Any FAIL here: STOP.
    ('C01', 'collide', 'public.events_enforce_recurrence_graph() exists', '0',
     (case when to_regprocedure('public.events_enforce_recurrence_graph()') is null then '0' else '1' end)),
    ('C02', 'collide', 'ANY function named events_enforce_recurrence_graph (any schema / signature)', '0',
     (select count(*) from pg_catalog.pg_proc where proname = 'events_enforce_recurrence_graph')::text),
    ('C03', 'collide', 'trigger events_quota_graph_ai on ANY table', '0',
     (select count(*) from pg_catalog.pg_trigger where tgname = 'events_quota_graph_ai')::text),
    ('C04', 'collide', 'trigger events_quota_graph_au on ANY table', '0',
     (select count(*) from pg_catalog.pg_trigger where tgname = 'events_quota_graph_au')::text),
    ('C05', 'collide', 'OLD design name events_recurrence_graph_ai / _au on ANY table', '0',
     (select count(*) from pg_catalog.pg_trigger
       where tgname in ('events_recurrence_graph_ai', 'events_recurrence_graph_au'))::text),
    ('C06', 'collide', 'ANY trigger named like %recurrence_graph% or events_quota_graph%', '0',
     (select count(*) from pg_catalog.pg_trigger
       where tgname like '%recurrence\_graph%' or tgname like 'events\_quota\_graph%')::text),
    ('C07', 'collide', 'ANY function named like %recurrence_graph%', '0',
     (select count(*) from pg_catalog.pg_proc where proname like '%recurrence\_graph%')::text),

    -- T. current triggers on public.events (the production-before baseline).
    ('T01', 'triggers', 'user triggers on public.events', '8', (select count(*) from trg)::text),
    ('T02', 'triggers', 'descriptors name:timing:event:level:enabled:transition, name order',
     'events_quota_exception_ai:after:insert:statement:O:-/new_rows,events_quota_exception_au:after:update:statement:O:old_rows/new_rows,events_quota_owner_ai:after:insert:statement:O:-/new_rows,events_quota_owner_au:after:update:statement:O:old_rows/new_rows,events_rate_ai:after:insert:statement:O:-/new_rows,events_rate_au:after:update:statement:O:-/new_rows,events_set_updated_at:before:update:row:O:-/-,events_validate_timezone:before:insert+update:row:O:-/-',
     (select string_agg(d, ',' order by tgname collate "C") from trg)),
    ('T03', 'triggers', 'DELETE triggers on public.events (0017 adds none)', '0',
     (select count(*) from trg where tgtype & 8 = 8)::text),
    ('T04', 'triggers', 'projected AFTER STATEMENT INSERT order once 0017 exists',
     'events_quota_exception_ai > events_quota_graph_ai > events_quota_owner_ai > events_rate_ai',
     (select string_agg(n, ' > ' order by n collate "C") from (
        select tgname as n from trg where tgtype & 2 = 0 and tgtype & 1 = 0 and tgtype & 4 = 4
        union all select 'events_quota_graph_ai') x)),
    ('T05', 'triggers', 'projected AFTER STATEMENT UPDATE order once 0017 exists',
     'events_quota_exception_au > events_quota_graph_au > events_quota_owner_au > events_rate_au',
     (select string_agg(n, ' > ' order by n collate "C") from (
        select tgname as n from trg where tgtype & 2 = 0 and tgtype & 1 = 0 and tgtype & 16 = 16
        union all select 'events_quota_graph_au') x)),

    -- L. where the lock classes and the event rate state are used today.
    ('L01', 'locks', 'function bodies mentioning 811001',
     'public.events_enforce_owner_quota,public.share_links_enforce_quota',
     (select string_agg(fq, ',' order by fq) from user_fn where prosrc like '%811001%')),
    ('L02', 'locks', 'function bodies mentioning 811002', 'public.events_enforce_exception_quota',
     (select string_agg(fq, ',' order by fq) from user_fn where prosrc like '%811002%')),
    ('L03', 'locks', 'function bodies mentioning any OTHER 811xxx class', '0',
     (select count(*) from user_fn where regexp_replace(prosrc, '81100[12]', '', 'g') ~ '811[0-9]{3}')::text),
    ('L04', 'locks', 'function bodies writing event_write_rate', 'public.events_enforce_write_rate',
     (select string_agg(fq, ',' order by fq) from user_fn where prosrc like '%event_write_rate%')),
    ('L05', 'locks', 'events trigger -> function (quota / rate)', null,
     (select string_agg(t.tgname || '=' || t.tgfoid::regproc::text, ', ' order by t.tgname collate "C")
        from pg_catalog.pg_trigger t
       where t.tgrelid = 'public.events'::regclass and not t.tgisinternal
         and (t.tgname like 'events\_quota\_%' or t.tgname like 'events\_rate\_%'))),

    -- F. production-before fingerprints 0017 must not move.
    ('F01', 'baseline', 'events_enforce_owner_quota', null, (select f from fn where proname = 'events_enforce_owner_quota')),
    ('F02', 'baseline', 'events_enforce_exception_quota', null, (select f from fn where proname = 'events_enforce_exception_quota')),
    ('F03', 'baseline', 'events_enforce_write_rate', null, (select f from fn where proname = 'events_enforce_write_rate')),
    ('F04', 'baseline', 'the 11 events functions present', '11', (select count(*) from fn)::text),
    ('F05', 'baseline', 'md5 over all 11 function fingerprints', null,
     (select md5(string_agg(f, ';' order by proname)) from fn)),
    ('F06', 'baseline', 'md5 over the 8 trigger descriptors', null,
     (select md5(string_agg(d, ',' order by tgname collate "C")) from trg)),

    -- P. what default privileges would give the new function.
    ('P01', 'privs', 'role that will run the migration', null, current_user::text),
    ('P02', 'privs', 'default FUNCTION ACL for this role in public or global', null,
     (select coalesce(string_agg(coalesce(n.nspname, '*') || '=' || array_to_string(d.defaclacl, ' '), '; '), '(none)')
        from pg_catalog.pg_default_acl d
        left join pg_catalog.pg_namespace n on n.oid = d.defaclnamespace
       where d.defaclrole = current_user::regrole and d.defaclobjtype = 'f'
         and (n.nspname = 'public' or d.defaclnamespace = 0))),
    ('P03', 'privs', 'those defaults grant EXECUTE to anyone but the owner', '0',
     (select count(*)
        from pg_catalog.pg_default_acl d
        left join pg_catalog.pg_namespace n on n.oid = d.defaclnamespace,
        unnest(d.defaclacl) a
       where d.defaclrole = current_user::regrole and d.defaclobjtype = 'f'
         and (n.nspname = 'public' or d.defaclnamespace = 0)
         and a::text not like (current_user || '=%'))::text),
    ('P04', 'privs', 'precedent: 0011 enforce fn ACL', null,
     (select coalesce(array_to_string(p.proacl, ' '), '(default)') from pg_catalog.pg_proc p
       where p.oid = to_regprocedure('public.events_enforce_owner_quota()'))),
    ('P05', 'privs', 'precedent: 0016 enforce fn ACL', null,
     (select coalesce(array_to_string(p.proacl, ' '), '(default)') from pg_catalog.pg_proc p
       where p.oid = to_regprocedure('public.share_links_enforce_quota()')))

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
