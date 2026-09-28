-- ============================================================================
-- TimeWeave -- [STAGE 1 of 4] PREFLIGHT for 0020_events_availability.sql
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run by hand, once, against the project
-- 0020 will be applied to, BEFORE applying it. Valid only for the frozen file:
--
--   sha256 ccecb6c475f3af586587d0f0a8948ff872eb79b025a48d0ffbf9d7ef084753cc
--                                              (11,939 bytes, 221 lines)
--
-- Expects migrations 0001-0019 applied and 0020 NOT applied.
--
-- READ-ONLY: SELECT and catalog inspection only. No DDL, no DML, no SET, no
-- temp table, no advisory lock, no RPC call. The main check runs inside a
-- read-only transaction that ends in ROLLBACK.
--
-- RUNNING THIS AGAINST PRODUCTION NEEDS ITS OWN APPROVAL. Writing the file is
-- not permission to run it.
--
-- ----------------------------------------------------------------------------
-- HOW TO READ THE RESULT -- AND WHY P00 = 0 IS NOT ENOUGH
--
--   status 'ok' / 'FAIL' where an expectation exists, 'context' otherwise.
--   P00 counts the FAILs. It counts NOTHING ELSE.
--
--   AUTOMATIC GATE   every row whose `expected` is not null. P00 = 0 means all
--                    of them passed.
--   CONTEXT ONLY     every row whose `expected` is null. These are RECORDED,
--                    not judged: V01 V02 V04, C07-C10, S04c, S10, D01 D02 D04,
--                    X01-X04. Recording them is part of the work; a value that
--                    drifts here is not by itself a reason to stop.
--   MANUAL COMPARISON this stage has none of its own, but S10 and X01-X04 MUST
--                    be written down: stage 2 compares its U01-U05 against them
--                    character for character, and that comparison is not
--                    automated anywhere.
--
--   SO: GO means P00 = 0 AND S10 and X01-X04 have been recorded. There is no
--   arrangement in which running this file alone decides anything.
--
-- SQL ERRORS ARE A STOP. If this file raises an error instead of returning
-- rows, treat it exactly as a FAIL. A missing table or role fails at PARSE
-- time -- '...'::regclass is folded to a constant before any row exists -- and
-- that is deliberate: an error is a clearer signal than one FAIL row among
-- forty, and routing every catalog reference through OID variables to avoid it
-- would be complexity that is itself a source of bugs. The (0) pre-check below
-- is what makes that case rare.
--
-- NEXT STAGE: apply 0020, then run 0020_postflight.sql. Do NOT deploy the
-- application on 0020 alone -- 0021 must be applied and verified first.
--
-- ----------------------------------------------------------------------------
-- MIGRATION HISTORY: this project has no supabase_migrations schema (README,
-- confirmed 2026-09-12 by pg_catalog), so "is 0019 recorded" cannot be asked.
-- A01-A06 stand in for it: the objects 0001-0019 created, and the body
-- fingerprint that the 0019 POSTFLIGHT confirmed in production on 2026-09-20.
--
-- PRIVACY. Counts, catalog text, ACLs and hashes only. No title, description,
-- label, token, row id or owner id is ever returned.
-- ============================================================================


-- ============================================================================
-- (0) PRE-CHECK. Read this row FIRST. If any column is NULL, STOP: do not read
--     the main result, and do not apply 0020. to_regclass / to_regprocedure
--     return NULL instead of raising, which is exactly why they are used here.
-- ============================================================================
select to_regclass('public.events')                                as events,
       to_regprocedure('timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')
                                                                   as free_busy_core,
       (select count(*) from pg_catalog.pg_roles where rolname = 'anon')
                                                                   as anon_role_count;


-- ============================================================================
-- MAIN CHECK.
--
-- WHY THERE IS NO "what values are already in the column" ROW HERE. It cannot
-- be written. PostgreSQL resolves column names during PARSE ANALYSIS for the
-- whole statement, so `select availability from public.events` fails before any
-- row exists whenever the column is absent -- which is the NORMAL case for this
-- preflight. A CASE or a WHERE around it does not help: both arms are still
-- parsed. C07-C10 already describe an unexpected pre-existing column from the
-- catalog alone. If C01 is not 0, run the diagnostic at the bottom of this file
-- BY HAND, separately, and read it before deciding anything.
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
av  as (select * from col where attname = 'availability'),
cor as (
  select p.oid, md5(replace(p.prosrc, E'\r','')) as h
  from pg_catalog.pg_proc p
  where p.oid = to_regprocedure(
    'timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')
),
res as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL'
         end as status
  from (values

    -- V. context ------------------------------------------------------------
    ('V01','context','server_version', null::text, current_setting('server_version')),
    ('V02','context','server_version_num', null, current_setting('server_version_num')),
    ('V03','context','>= 11: a constant DEFAULT does not rewrite the table','true',
      (current_setting('server_version_num')::int >= 110000)::text),
    ('V04','context','role that will run the migration', null, current_user::text),
    ('V05','context','that role owns public.events (ALTER TABLE needs it)','true',
      (select (pg_catalog.pg_get_userbyid(relowner) = current_user)::text
         from pg_catalog.pg_class where oid = 'public.events'::regclass)),
    ('V06','context','this transaction is read only','on',
      current_setting('transaction_read_only')),

    -- A. 0001-0019 are applied (there is no history table to ask) ------------
    ('A01','prior','public.events is an ordinary table','r',
      (select relkind::text from pg_catalog.pg_class where oid='public.events'::regclass)),
    ('A02','prior','timeweave_private schema exists','1',
      (select count(*) from pg_catalog.pg_namespace where nspname='timeweave_private')::text),
    ('A03','prior','the 0012/0016/0019 private rate tables exist','4',
      (select count(*) from pg_catalog.pg_class c
         join pg_catalog.pg_namespace n on n.oid=c.relnamespace
        where n.nspname='timeweave_private'
          and c.relname in ('event_write_rate','share_link_create_rate',
                            'freebusy_owner_rate','freebusy_link_rate'))::text),
    ('A04','prior','0015 delete_share_link exists','1',
      (select count(*) from pg_catalog.pg_proc
        where oid = to_regprocedure('public.delete_share_link(uuid)'))::text),
    ('A05','prior','0019 free_busy_core at the exact signature','1',
      (select count(*) from cor)::text),
    ('A06','prior','core body md5, CR removed (the 0019 POSTFLIGHT confirmed this value)',
      'a7558dfa02a4ce6444d538e370eb631d',(select h from cor)),

    -- C. collide: nothing 0020 creates may exist yet -------------------------
    ('C01','collide','public.events.availability does NOT exist','0',
      (select count(*) from av)::text),
    ('C02','collide','no constraint named events_availability_values','0',
      (select count(*) from con where conname='events_availability_values')::text),
    ('C03','collide','no OTHER constraint mentions availability','0',
      (select count(*) from con where def ~ 'availability')::text),
    ('C04','collide','no index mentions availability','0',
      (select count(*) from pg_catalog.pg_indexes
        where schemaname='public' and tablename='events' and indexdef ~ 'availability')::text),
    ('C05','collide','no trigger function on events mentions availability','0',
      (select count(*) from pg_catalog.pg_trigger t
         join pg_catalog.pg_proc p on p.oid=t.tgfoid
        where t.tgrelid='public.events'::regclass and not t.tgisinternal
          and p.prosrc ~ 'availability')::text),
    ('C06','collide','free_busy_core does NOT mention availability yet','0',
      (select count(*) from pg_catalog.pg_proc p, cor c
        where p.oid=c.oid and p.prosrc ~ 'availability')::text),

    -- C07-C10 are ONLY meaningful if C01 failed. Read them before deciding.
    -- They are catalog-only on purpose; see the header on why no row here can
    -- read the column's VALUES.
    ('C07','collide','IF the column exists: its type', null,(select typ from av)),
    ('C08','collide','IF the column exists: NOT NULL', null,(select attnotnull::text from av)),
    ('C09','collide','IF the column exists: DEFAULT', null,(select coalesce(dflt,'(none)') from av)),
    ('C10','collide','IF the column exists: constraints mentioning it', null,
      (select coalesce(string_agg(conname||' => '||def,' ; ' order by conname collate "C"),'(none)')
         from con where def ~ 'availability')),

    -- S. the table as 0001/0008/0011/0013 left it ----------------------------
    ('S01','schema','column count before 0020','19',(select count(*) from col)::text),
    ('S02','schema','column names in attnum order',
      'id,owner_id,title,description,category,visibility,all_day,start_at,end_at,start_date,end_date,rrule,recurrence_id,recurrence_slot_start,recurrence_slot_date,is_cancelled,created_at,updated_at,timezone',
      (select string_agg(attname, ',' order by attnum) from col)),
    -- 13 = the 12 explicitly named ones plus the ONE auto-named column CHECK
    -- that 0001:25-26 creates for `visibility` (PostgreSQL names such a
    -- constraint <table>_<column>_check). 0011's events_id_owner_key is UNIQUE
    -- and events_recurrence_owner_fkey is a FOREIGN KEY; neither is contype 'c'.
    ('S03','schema','CHECK constraints','13',
      (select count(*) from con where contype='c')::text),
    ('S04','schema','the 12 EXPLICITLY NAMED CHECK constraints',
      'events_allday_range,events_cancel_only_on_exception,events_category_len,events_description_len,events_exception_slot,events_master_not_exception,events_recurrence_not_self,events_rrule_len,events_time_shape,events_timed_range,events_timezone_placement,events_title_len',
      (select string_agg(conname, ',' order by conname collate "C") from con
        where contype='c' and conname ~ '^events_(allday_range|cancel_only_on_exception|category_len|description_len|exception_slot|master_not_exception|recurrence_not_self|rrule_len|time_shape|timed_range|timezone_placement|title_len)$')),
    -- The auto-generated name is PostgreSQL's, not ours, so it is not asserted
    -- literally. What IS asserted is that there is exactly one such constraint.
    ('S04b','schema','CHECK constraints NOT among those 12 (the auto-named visibility one)','1',
      (select count(*) from con where contype='c'
         and conname !~ '^events_(allday_range|cancel_only_on_exception|category_len|description_len|exception_slot|master_not_exception|recurrence_not_self|rrule_len|time_shape|timed_range|timezone_placement|title_len)$')::text),
    ('S04c','schema','its actual name and definition', null,
      (select coalesce(string_agg(conname||' => '||def,' ; '),'(none)') from con
        where contype='c'
          and conname !~ '^events_(allday_range|cancel_only_on_exception|category_len|description_len|exception_slot|master_not_exception|recurrence_not_self|rrule_len|time_shape|timed_range|timezone_placement|title_len)$')),
    ('S05','schema','every CHECK is validated','13',
      (select count(*) from con where contype='c' and convalidated)::text),
    -- 10, not 9: 0001 x1, 0008 x1, 0011 x4, 0012 x2, 0017 x2. Every
    -- `drop trigger if exists` in those files is immediately followed by
    -- re-creating the same trigger, so none is permanently removed. 0016's
    -- three triggers are on public.share_links, not here.
    ('S06','schema','triggers (not internal)','10',
      (select count(*) from pg_catalog.pg_trigger
        where tgrelid='public.events'::regclass and not tgisinternal)::text),
    ('S07','schema','trigger names',
      'events_quota_exception_ai,events_quota_exception_au,events_quota_graph_ai,events_quota_graph_au,events_quota_owner_ai,events_quota_owner_au,events_rate_ai,events_rate_au,events_set_updated_at,events_validate_timezone',
      (select string_agg(tgname, ',' order by tgname collate "C") from pg_catalog.pg_trigger
        where tgrelid='public.events'::regclass and not tgisinternal)),
    ('S08','schema','RLS enabled','true',
      (select relrowsecurity::text from pg_catalog.pg_class where oid='public.events'::regclass)),
    ('S09','schema','RLS policies','4',
      (select count(*) from pg_catalog.pg_policy where polrelid='public.events'::regclass)::text),
    ('S10','schema','RECORD THIS: table ACL (stage 2 U05 must match it)', null,
      (select coalesce(array_to_string(relacl,' '),'(default)') from pg_catalog.pg_class
        where oid='public.events'::regclass)),
    ('S11','schema','anon has no SELECT on events','false',
      pg_catalog.has_table_privilege('anon','public.events','SELECT')::text),

    -- W. the Phase 1B write payload -------------------------------------------
    --    eventToInsert / exceptionToInsert send 16 keys; 15 of them must
    --    already exist, and availability is the one 0020 adds (C01 proves it
    --    is absent).
    ('W01','payload','15 of the 16 payload columns already exist','15',
      (select count(*) from col where attname in
        ('title','description','category','visibility','all_day','start_at','end_at',
         'start_date','end_date','rrule','recurrence_id','recurrence_slot_start',
         'recurrence_slot_date','is_cancelled','timezone'))::text),
    ('W02','payload','columns the app never sends (DB defaults)','4',
      (select count(*) from col where attname in ('id','owner_id','created_at','updated_at'))::text),

    -- D. size, cost and locks --------------------------------------------------
    --    ALTER TABLE ADD COLUMN and ADD CONSTRAINT both take ACCESS EXCLUSIVE
    --    on public.events for the length of the migration: every access,
    --    including the anonymous share path, waits behind it.
    ('D01','cost','RECORD THIS: row count in public.events', null,
      (select count(*) from public.events)::text),
    ('D02','cost','table size', null,
      pg_catalog.pg_size_pretty(pg_catalog.pg_total_relation_size('public.events'))),
    ('D03','cost','other backends holding a lock on public.events','0',
      (select count(*) from pg_catalog.pg_locks
        where relation='public.events'::regclass and pid <> pg_backend_pid())::text),
    ('D04','cost','longest running other backend (seconds)', null,
      (select coalesce(max(extract(epoch from (now()-xact_start)))::int,0)::text
         from pg_catalog.pg_stat_activity
        where pid <> pg_backend_pid() and state <> 'idle' and xact_start is not null)),

    -- X. baselines 0020 must NOT move. RECORD ALL FOUR: stage 2 prints the
    --    same values as U01-U04 and they must match character for character.
    ('X01','baseline','RECORD THIS: md5 over every trigger definition on public.events', null,
      (select md5(string_agg(pg_catalog.pg_get_triggerdef(t.oid), ';' order by t.tgname collate "C"))
         from pg_catalog.pg_trigger t
        where t.tgrelid='public.events'::regclass and not t.tgisinternal)),
    ('X02','baseline','RECORD THIS: md5 over every RLS policy on public.events', null,
      (select md5(string_agg(p.polname||'|'||p.polcmd::text||'|'
                    ||coalesce(pg_catalog.pg_get_expr(p.polqual,p.polrelid),'-')||'|'
                    ||coalesce(pg_catalog.pg_get_expr(p.polwithcheck,p.polrelid),'-'),
                    ';' order by p.polname collate "C"))
         from pg_catalog.pg_policy p where p.polrelid='public.events'::regclass)),
    ('X03','baseline','RECORD THIS: md5 over the 13 pre-existing CHECK definitions', null,
      (select md5(string_agg(conname||'|'||def, ';' order by conname collate "C"))
         from con where contype='c')),
    ('X04','baseline','RECORD THIS: md5 over the 19 pre-existing column definitions', null,
      (select md5(string_agg(attname||'|'||typ||'|'||attnotnull::text||'|'||coalesce(dflt,'-'),
                    ';' order by attnum)) from col))

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


-- ============================================================================
-- DIAGNOSTIC ONLY. Do not run as part of this preflight.
-- Run separately, by hand, ONLY if C01 reports that availability already
-- exists -- and only after reading C07-C10. It is left commented out because
-- it cannot be part of the statement above: with the column absent it would
-- fail during parse analysis and no row of the main check would be returned.
--
-- select availability, count(*) as rows
-- from public.events
-- group by availability
-- order by availability;
-- ============================================================================
