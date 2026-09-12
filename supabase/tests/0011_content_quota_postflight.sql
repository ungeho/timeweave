-- ============================================================================
-- TimeWeave -- POSTFLIGHT for 0011_content_and_quota_limits.sql.
-- PRODUCTION-SAFE EDITION. Run AFTER applying 0011, on the production database.
--
-- ############################################################################
-- SAFETY CLASSIFICATION -- read this before running anything.
--
--   read-only?                 NO. It writes, deliberately: a trigger that is
--                              never fired is a trigger that was never tested.
--
--   temporary writes?          YES, and ONLY these:
--                                * ~20 rows in public.events, every one of
--                                  them owned by the documented TEST USER
--                                * 2 function bodies REPLACED in place
--                                  (events_max_per_owner,
--                                   events_max_exceptions_per_master)
--                              NOTHING ELSE. No row belonging to a real
--                              account is read into a fixture, written,
--                              updated or deleted. No constraint, trigger,
--                              index, policy or grant is touched.
--
--   writes to auth.users?      NONE. Not one statement. This file follows the
--                              rule 0006 states and 0007-0010 repeat: "Create
--                              a test user through the normal Supabase Auth
--                              path. Do NOT insert into auth.users from SQL."
--                              Section 3 asserts the user exists; it never
--                              creates one.
--
--   fully reverted by ROLLBACK? YES, all of it. Row changes and DDL alike --
--                              in PostgreSQL a function body lives in a
--                              pg_proc row and CREATE OR REPLACE is an
--                              ordinary transactional UPDATE of it.
--
--   residue in production?     NONE. There is no COMMIT anywhere in this file.
--                              The rolled-back rows leave dead tuples that
--                              autovacuum reclaims; at ~20 rows that is noise.
--
--   what does it persist?      NOTHING. This file applies no migration and
--                              leaves no object. 0011 itself is what persists,
--                              and it must already be applied before this runs.
-- ############################################################################
--
-- ============================================================================
-- THE ONE ACCOUNT THIS FILE TOUCHES
--
--   5e86935f-7661-4741-868f-0f51c4cf1727
--
-- the dedicated test user named in 0006, 0007, 0008, 0009 and 0010, and
-- carrying their standing instruction "Never create calendar events with that
-- account". Section 3 refuses to continue unless it exists AND owns zero
-- events, so the fixtures always start from a known-empty account.
--
-- No other account appears anywhere in this file, by uuid or by lookup. The
-- accounts that hold the live 16 rows are never named, never written, never
-- counted into a fixture, and never become the key of an advisory lock.
--
-- ============================================================================
-- WHY THERE IS NO CROSS-OWNER INSERT TEST
--
-- Proving "an exception may not belong to a different owner than its master"
-- by attempting it needs a SECOND owner. The repository documents exactly one
-- test account, and a survey of auth.users found no second one that could be
-- adopted without borrowing a real person's id -- which would mean writing
-- junk into their account and holding an advisory lock on their key for the
-- duration of this transaction.
--
-- Neither price is worth paying, because the risk actually being guarded
-- against is NOT "does PostgreSQL enforce foreign keys". It is "did 0011
-- create the foreign key it intended to". That question is answered
-- completely, and with more precision than an INSERT could offer, by reading
-- the catalog: checks 40-47 verify the constraint's referencing columns IN
-- ORDER, its referenced columns IN ORDER, its referenced table, its delete
-- action, its update action, its match type, and that it is validated.
--
-- An INSERT would have demonstrated one refusal. The catalog demonstrates that
-- the rule is the intended rule in all eight of its dimensions -- including
-- MATCH SIMPLE, which is what makes ordinary non-exception rows exempt and
-- which no single INSERT could have shown at all.
--
-- The behavioural half that CAN be done with one owner is still done: check 48
-- inserts a same-owner exception and expects it to be accepted, and check 49
-- deletes the master and expects the cascade to remove it.
--
-- ============================================================================
-- WHY THE CEILINGS ARE LOWERED INSTEAD OF FILLED TO
--
-- Reaching the real ceiling would mean 4999 rows. On a 16-row table that is
-- 300x the live data in dead tuples, for a number that was never the thing
-- under test. So the two limit functions are replaced INSIDE this transaction
-- with small values (20 and 5). What is being verified is that the trigger
-- fires, counts correctly, refuses at the boundary and refuses a multi-row
-- burst -- none of which is a property of the number 5000.
--
-- No other session can ever observe the small values: an uncommitted pg_proc
-- update is invisible outside this transaction, and this transaction does not
-- commit.
--
-- 0011's delta rule is what makes the lowering harmless to everyone else. A
-- quota is consulted only for owners whose row count THIS STATEMENT increased,
-- so while the ceiling is 20 in here, an existing owner with 10 rows is not
-- re-evaluated and could not be refused even if they had 10,000.
--
-- ============================================================================
-- HOW THE NEGATIVE CASES ARE WRITTEN
--
-- Every "this must be refused" test sits in its own BEGIN/EXCEPTION block -- a
-- subtransaction. The failed statement rolls back to that savepoint and the
-- script carries on. Without it the first expected 23514 would abort everything
-- after it and the file could only ever report its first result.
--
-- Handlers match on SQLSTATE and on the DETAIL token, never on message text.
-- 0011 states that MESSAGE wording is free to change and that clients must
-- branch on DETAIL; this file holds itself to the rule it documents.
--
-- ============================================================================
-- ON THE CHECK NUMBERS
--
-- Numbers are grouped by section (10s objects, 20s fixture, 30s content, 40s
-- foreign key, 50s exception quota, 60s owner quota, 70s delta rule, 80s blast
-- radius, 85+ locks), so the gaps BETWEEN groups are deliberate spare room,
-- not missing tests.
--
-- What a gap could hide -- a section that silently skipped -- is caught
-- directly instead: check 95 counts the rows in the log and asserts the total.
-- If any DO block returns early or is never reached, the count comes up short
-- and 95 reports MISMATCH naming the shortfall.
--
-- ============================================================================
-- AFTER IT FINISHES
--
-- Section 10 prints a verification script. Run it in a NEW session (a new
-- Supabase SQL Editor tab) to confirm from OUTSIDE this transaction that the
-- fixtures are gone and both limit functions are back to 5000 / 500. That is
-- the only check this file cannot make about itself -- from in here, every
-- measurement would be reading its own uncommitted state.
-- ============================================================================

begin;

-- ============================================================================
-- Section 0. Guard and log.
-- ============================================================================
create temp table pf_log (
  ord        int,
  part       text,
  check_name text,
  expected   text,
  value      text
) on commit drop;

do $env$
declare
  v_is_owner boolean;
  v_applied  int;
begin
  select pg_catalog.pg_get_userbyid(c.relowner) = current_user
    into v_is_owner
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'events';

  if not coalesce(v_is_owner, false) then
    raise exception 'POSTFLIGHT MUST RUN AS THE OWNER OF public.events'
      using hint = 'RLS would filter every count and refuse every fixture, and '
                   'the results would be meaningless rather than merely wrong.';
  end if;

  select count(*) into v_applied
  from pg_catalog.pg_constraint con
  join pg_catalog.pg_class c on c.oid = con.conrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'events'
    and con.conname in ('events_title_len', 'events_recurrence_owner_fkey');

  if v_applied < 2 then
    raise exception '0011 DOES NOT APPEAR TO BE APPLIED (found % of 2 marker objects)', v_applied
      using hint = 'This is a postflight. Apply 0011 first.';
  end if;

  raise notice 'Postflight: running as %, 0011 markers present.', current_user;
end;
$env$;


-- ============================================================================
-- Section 1. Lower the two ceilings, for this transaction only.
--
-- The signatures, language, volatility and search_path are reproduced exactly
-- as 0011 declares them, so that the ROLLBACK restores a byte-identical
-- definition rather than an approximation of one.
-- ============================================================================
create or replace function public.events_max_per_owner()
returns int
language sql
immutable
parallel safe
set search_path = ''
as $fn$ select 20 $fn$;

create or replace function public.events_max_exceptions_per_master()
returns int
language sql
immutable
parallel safe
set search_path = ''
as $fn$ select 5 $fn$;


-- ============================================================================
-- Section 2. The objects 0011 created, and their properties.
--
-- convalidated is the point of check 11: NOT VALID would leave it false, and a
-- NOT VALID check is a materially weaker object than the one 0011 claims.
-- ============================================================================
insert into pf_log
select 10, 'objects', 'the three content CHECK constraints exist', '3', count(*)::text
from pg_catalog.pg_constraint con
join pg_catalog.pg_class c on c.oid = con.conrelid
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'events' and con.contype = 'c'
  and con.conname in ('events_title_len','events_category_len','events_description_len');

insert into pf_log
select 11, 'objects', 'all three are VALIDATED (not NOT VALID)', '3', count(*)::text
from pg_catalog.pg_constraint con
join pg_catalog.pg_class c on c.oid = con.conrelid
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'events'
  and con.conname in ('events_title_len','events_category_len','events_description_len')
  and con.convalidated;

insert into pf_log
select 12, 'objects', 'the legacy single-column self-FK is gone', '0', count(*)::text
from pg_catalog.pg_constraint con
join pg_catalog.pg_class c on c.oid = con.conrelid
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'events'
  and con.contype = 'f' and con.confrelid = con.conrelid
  and array_length(con.conkey, 1) = 1;

insert into pf_log
select 13, 'objects', 'the unique key the composite FK references exists', '1', count(*)::text
from pg_catalog.pg_constraint con
join pg_catalog.pg_class c on c.oid = con.conrelid
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'events'
  and con.conname = 'events_id_owner_key' and con.contype = 'u';

insert into pf_log
select 14, 'objects', 'the four quota triggers exist', '4', count(*)::text
from pg_catalog.pg_trigger t
join pg_catalog.pg_class c on c.oid = t.tgrelid
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'events' and not t.tgisinternal
  and t.tgname in ('events_quota_owner_ai','events_quota_owner_au',
                   'events_quota_exception_ai','events_quota_exception_au');

insert into pf_log
select 15, 'objects', 'both enforcement functions are SECURITY DEFINER', '2', count(*)::text
from pg_catalog.pg_proc p
join pg_catalog.pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('events_enforce_owner_quota','events_enforce_exception_quota')
  and p.prosecdef;

insert into pf_log
select 16, 'objects', 'the FK-supporting index exists', '1', count(*)::text
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'events_recurrence_owner_idx';

-- THE EARLY GATE. Checks 17/18 call the limit functions directly, which proves
-- the REPLACE landed but not that the TRIGGERS picked it up -- the trigger
-- bodies read the same functions through their own cached plans, and an
-- IMMUTABLE function is inlined into those plans as a constant.
--
-- The real proof is check 62: if a stale plan still held 5000, the row that
-- exceeds 20 would be ACCEPTED and 62 would report MISMATCH. So a stale plan
-- cannot produce a false PASS -- it produces a loud, specific failure.
--
-- The gate exists only to stop early and legibly when the REPLACE did not take
-- at all, rather than letting sections 6 and 7 fill toward a ceiling of 5000
-- twenty rows at a time and fail for a reason the reader has to infer.
insert into pf_log
select 17, 'objects', 'lowered owner ceiling is IN FORCE for this transaction',
       '20', public.events_max_per_owner()::text;

insert into pf_log
select 18, 'objects', 'lowered exception ceiling is IN FORCE for this transaction',
       '5', public.events_max_exceptions_per_master()::text;

insert into pf_log
select 19, 'objects', 'anon holds no EXECUTE on the limit functions', 'false',
       coalesce(bool_or(
         pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
       )::text, 'false')
from pg_catalog.pg_proc p
join pg_catalog.pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('events_max_per_owner','events_max_exceptions_per_master');

do $gate$
begin
  if public.events_max_per_owner() <> 20
     or public.events_max_exceptions_per_master() <> 5 then
    raise exception
      'CEILING REPLACEMENT DID NOT TAKE EFFECT (owner=%, exception=%)',
      public.events_max_per_owner(), public.events_max_exceptions_per_master()
      using hint = 'Stopping rather than running quota tests against the real '
                   '5000/500 ceilings, which would need thousands of rows.';
  end if;
end;
$gate$;


-- ============================================================================
-- Section 3. The fixture owner.
--
-- ASSERTED, NEVER CREATED. 0006 section 4 states the project rule: create the
-- test user through the normal Supabase Auth path, and do NOT insert into
-- auth.users from SQL. 0007-0010 repeat it. This file obeys it; there is no
-- DML against auth.users anywhere in it.
--
-- The zero-events assertion is not a formality. 0008 step E-3 is supposed to
-- delete the legacy M0 fixture row (events.id 5b2f1c7e-0000-4000-8000-
-- 000000000001) once its suite has passed. If that row is still present, this
-- account is not empty and every row-count expectation from section 7 onward
-- would be off by its count -- silently, and in a way that reads as a quota
-- bug rather than as leftover state.
-- ============================================================================
do $fixture$
declare
  v_f      constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_exists boolean;
  v_owned  bigint;
begin
  select exists (select 1 from auth.users u where u.id = v_f) into v_exists;

  if not v_exists then
    raise exception 'TEST USER % DOES NOT EXIST IN auth.users', v_f
      using hint = 'Create it through the normal Supabase Auth path (the app '
                   'login, or Dashboard > Authentication > Add user), exactly '
                   'as 0006 section 4 describes. This file never inserts into '
                   'auth.users.';
  end if;

  select count(*) into v_owned from public.events where owner_id = v_f;

  if v_owned <> 0 then
    raise exception 'TEST USER ALREADY OWNS % EVENTS; expected 0', v_owned
      using hint = 'Run 0008 step E-3 (delete the legacy M0 fixture row) or '
                   'otherwise empty the test account first. Proceeding would '
                   'make every row count below wrong by this number.';
  end if;

  perform pg_catalog.set_config('pf.owner_f', v_f::text, true);

  insert into pf_log values
    (20, 'fixture', 'the documented test user exists in auth.users', 'true', v_exists::text),
    (21, 'fixture', 'the test user owns ZERO events at start', '0', v_owned::text);
end;
$fixture$;


-- ============================================================================
-- Section 4. The CHECK constraints, at the boundary.
--
-- 200 must pass and 201 must fail. A limit that refuses 201 but also refuses
-- 200 is off by one and would reject values the dialog explicitly allows.
-- All fixtures are ALL-DAY rows: 0008's timezone trigger requires a zone only
-- on TIMED recurrence masters, so all-day keeps this file testing 0011 alone.
-- ============================================================================
do $content$
declare
  v_f uuid := current_setting('pf.owner_f')::uuid;
begin
  begin
    insert into public.events (owner_id, title, all_day, start_date, end_date)
    values (v_f, repeat('a', 200), true, date '2030-01-01', date '2030-01-02');
    insert into pf_log values (30, 'content', 'title of exactly 200 is ACCEPTED', 'accepted', 'accepted');
  exception when others then
    insert into pf_log values (30, 'content', 'title of exactly 200 is ACCEPTED', 'accepted',
      format('REFUSED %s', sqlstate));
  end;

  begin
    insert into public.events (owner_id, title, all_day, start_date, end_date)
    values (v_f, repeat('a', 201), true, date '2030-01-03', date '2030-01-04');
    insert into pf_log values (31, 'content', 'title of 201 is REFUSED', '23514', 'ACCEPTED');
  exception when check_violation then
    insert into pf_log values (31, 'content', 'title of 201 is REFUSED', '23514', sqlstate);
  end;

  begin
    insert into public.events (owner_id, title, category, all_day, start_date, end_date)
    values (v_f, 't', repeat('c', 50), true, date '2030-01-05', date '2030-01-06');
    insert into pf_log values (32, 'content', 'category of exactly 50 is ACCEPTED', 'accepted', 'accepted');
  exception when others then
    insert into pf_log values (32, 'content', 'category of exactly 50 is ACCEPTED', 'accepted',
      format('REFUSED %s', sqlstate));
  end;

  begin
    insert into public.events (owner_id, title, category, all_day, start_date, end_date)
    values (v_f, 't', repeat('c', 51), true, date '2030-01-07', date '2030-01-08');
    insert into pf_log values (33, 'content', 'category of 51 is REFUSED', '23514', 'ACCEPTED');
  exception when check_violation then
    insert into pf_log values (33, 'content', 'category of 51 is REFUSED', '23514', sqlstate);
  end;

  begin
    insert into public.events (owner_id, title, description, all_day, start_date, end_date)
    values (v_f, 't', repeat('d', 2000), true, date '2030-01-09', date '2030-01-10');
    insert into pf_log values (34, 'content', 'description of exactly 2000 is ACCEPTED', 'accepted', 'accepted');
  exception when others then
    insert into pf_log values (34, 'content', 'description of exactly 2000 is ACCEPTED', 'accepted',
      format('REFUSED %s', sqlstate));
  end;

  begin
    insert into public.events (owner_id, title, description, all_day, start_date, end_date)
    values (v_f, 't', repeat('d', 2001), true, date '2030-01-11', date '2030-01-12');
    insert into pf_log values (35, 'content', 'description of 2001 is REFUSED', '23514', 'ACCEPTED');
  exception when check_violation then
    insert into pf_log values (35, 'content', 'description of 2001 is REFUSED', '23514', sqlstate);
  end;
end;
$content$;


-- ============================================================================
-- Section 5a. The composite FK, verified from the catalog.
--
-- conkey and confkey are smallint[] whose ELEMENT ORDER is the column order in
-- the constraint definition, so they are translated back to names WITH
-- ORDINALITY and compared as ordered lists. Comparing them as sets would pass
-- a constraint declared (owner_id, recurrence_id) -> (owner_id, id), which is
-- a different rule that happens to use the same four columns.
--
-- The LEFT JOIN against a one-row dummy guarantees all eight rows are emitted
-- even when the constraint is absent entirely; they then read 'absent' rather
-- than vanishing and taking their own failure with them.
--
-- confmatchtype 's' (MATCH SIMPLE) is the one worth reading twice. It is what
-- makes the constraint skip any row where recurrence_id is NULL -- every
-- one-off event and every recurrence master. A cross-owner INSERT test could
-- not have demonstrated it at all.
-- ============================================================================
with fk as (
  select con.contype, con.conkey, con.confkey, con.conrelid, con.confrelid,
         con.confdeltype, con.confupdtype, con.confmatchtype, con.convalidated
  from pg_catalog.pg_constraint con
  where con.conname = 'events_recurrence_owner_fkey'
    and con.conrelid = 'public.events'::regclass
),
shape as (
  select
    f.contype::text                                              as contype,
    (select string_agg(a.attname, ',' order by k.ord)
       from unnest(f.conkey) with ordinality as k(attnum, ord)
       join pg_catalog.pg_attribute a
         on a.attrelid = f.conrelid and a.attnum = k.attnum)     as referencing,
    (select string_agg(a.attname, ',' order by k.ord)
       from unnest(f.confkey) with ordinality as k(attnum, ord)
       join pg_catalog.pg_attribute a
         on a.attrelid = f.confrelid and a.attnum = k.attnum)    as referenced,
    -- Spelled out from the catalog rather than via ::regclass::text, whose
    -- rendering depends on search_path: regclass prints 'events' when public
    -- is on the path and 'public.events' when it is not, so that form would
    -- report a false MISMATCH on a session with a different search_path.
    (select n.nspname || '.' || c.relname
       from pg_catalog.pg_class c
       join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      where c.oid = f.confrelid)                                 as referenced_table,
    f.confdeltype::text                                          as del_action,
    f.confupdtype::text                                          as upd_action,
    f.confmatchtype::text                                        as match_type,
    f.convalidated::text                                         as validated
  from fk f
)
insert into pf_log
select v.ord, 'composite FK', v.check_name, v.expected, coalesce(v.value, 'absent')
from (select 1 as one) d
left join shape s on true
cross join lateral (values
  (40, 'constraint exists and is a FOREIGN KEY',            'f',                        s.contype),
  (41, 'referencing columns, IN ORDER',                     'recurrence_id,owner_id',   s.referencing),
  (42, 'referenced columns, IN ORDER',                      'id,owner_id',              s.referenced),
  (43, 'referenced table',                                  'public.events',            s.referenced_table),
  (44, 'ON DELETE action (c = CASCADE)',                    'c',                        s.del_action),
  (45, 'ON UPDATE action (a = NO ACTION)',                  'a',                        s.upd_action),
  (46, 'match type (s = MATCH SIMPLE)',                     's',                        s.match_type),
  (47, 'constraint is VALIDATED',                           'true',                     s.validated)
) as v(ord, check_name, expected, value);


-- ============================================================================
-- Section 5b. The half of the FK that one owner CAN demonstrate.
--
-- A same-owner exception must be accepted, and deleting the master must still
-- cascade to it. The cross-owner refusal is covered by checks 41-46 above; it
-- is not attempted here, because attempting it would require a second account
-- and this file will not borrow one.
-- ============================================================================
do $fk$
declare
  v_f      uuid := current_setting('pf.owner_f')::uuid;
  v_master uuid;
  v_n      bigint;
begin
  insert into public.events (owner_id, title, all_day, start_date, end_date, rrule)
  values (v_f, 'pf master fk', true, date '2030-02-01', date '2030-02-02', 'FREQ=DAILY')
  returning id into v_master;

  begin
    insert into public.events
      (owner_id, title, all_day, start_date, end_date, recurrence_id, recurrence_slot_date)
    values (v_f, 'pf exc same', true, date '2030-02-03', date '2030-02-04',
            v_master, date '2030-02-03');
    insert into pf_log values (48, 'composite FK', 'same-owner exception ACCEPTED', 'accepted', 'accepted');
  exception when others then
    insert into pf_log values (48, 'composite FK', 'same-owner exception ACCEPTED', 'accepted',
      format('REFUSED %s', sqlstate));
  end;

  delete from public.events where id = v_master;
  select count(*) into v_n from public.events where recurrence_id = v_master;
  insert into pf_log values (49, 'composite FK', 'ON DELETE CASCADE still removes exceptions', '0', v_n::text);
end;
$fk$;


-- ============================================================================
-- Section 6. The per-master exception quota, against a ceiling of 5.
-- ============================================================================
do $excq$
declare
  v_f      uuid := current_setting('pf.owner_f')::uuid;
  v_limit  int  := public.events_max_exceptions_per_master();
  v_master uuid;
  v_n      bigint;
  v_det    text;
  i        int;
begin
  insert into public.events (owner_id, title, all_day, start_date, end_date, rrule)
  values (v_f, 'pf master q', true, date '2030-03-01', date '2030-03-02', 'FREQ=DAILY')
  returning id into v_master;

  for i in 1 .. v_limit loop
    insert into public.events
      (owner_id, title, all_day, start_date, end_date, recurrence_id, recurrence_slot_date)
    values (v_f, 'pf exc', true,
            date '2030-03-10' + i, date '2030-03-11' + i,
            v_master, date '2030-03-10' + i);
  end loop;

  select count(*) into v_n from public.events where recurrence_id = v_master;
  insert into pf_log values (50, 'exception quota', 'exceptions accepted up to the ceiling',
    v_limit::text, v_n::text);

  begin
    insert into public.events
      (owner_id, title, all_day, start_date, end_date, recurrence_id, recurrence_slot_date)
    values (v_f, 'pf exc over', true, date '2030-04-01', date '2030-04-02',
            v_master, date '2030-04-01');
    insert into pf_log values (51, 'exception quota', 'the exception that would exceed it is REFUSED',
      'TIMEWEAVE_QUOTA_EXCEPTIONS', 'ACCEPTED');
  exception when check_violation then
    get stacked diagnostics v_det = pg_exception_detail;
    insert into pf_log values (51, 'exception quota', 'the exception that would exceed it is REFUSED',
      'TIMEWEAVE_QUOTA_EXCEPTIONS', coalesce(v_det, sqlstate));
  end;

  select count(*) into v_n from public.events where recurrence_id = v_master;
  insert into pf_log values (52, 'exception quota', 'the refusal left the master at the ceiling',
    v_limit::text, v_n::text);

  -- Tombstones count too: 0011 says so, so it is measured rather than trusted.
  begin
    insert into public.events
      (owner_id, title, all_day, start_date, end_date,
       recurrence_id, recurrence_slot_date, is_cancelled)
    values (v_f, 'pf tombstone', true, date '2030-04-03', date '2030-04-04',
            v_master, date '2030-04-03', true);
    insert into pf_log values (53, 'exception quota', 'a TOMBSTONE over the ceiling is REFUSED too',
      'TIMEWEAVE_QUOTA_EXCEPTIONS', 'ACCEPTED');
  exception when check_violation then
    get stacked diagnostics v_det = pg_exception_detail;
    insert into pf_log values (53, 'exception quota', 'a TOMBSTONE over the ceiling is REFUSED too',
      'TIMEWEAVE_QUOTA_EXCEPTIONS', coalesce(v_det, sqlstate));
  end;
end;
$excq$;


-- ============================================================================
-- Section 7. The per-owner quota, against a ceiling of 20, and the delta rule.
--
-- The fill is computed from what the fixture owner holds after sections 4-6, so
-- the arithmetic does not depend on how many of the earlier fixtures were
-- accepted.
-- ============================================================================
do $ownq$
declare
  v_f     uuid := current_setting('pf.owner_f')::uuid;
  v_limit int  := public.events_max_per_owner();
  v_have  bigint;
  v_fill  int;
  v_n     bigint;
  v_det   text;
begin
  select count(*) into v_have from public.events where owner_id = v_f;
  v_fill := v_limit - v_have - 1;

  if v_fill < 0 then
    insert into pf_log values (60, 'owner quota', 'fill to LIMIT-1 was possible', 'yes',
      format('NO -- fixture owner already holds %s of %s', v_have, v_limit));
    return;
  end if;

  -- One multi-row INSERT. This is the bot-shaped payload in miniature: the
  -- AFTER STATEMENT trigger sees it as a single statement, exactly as it would
  -- see a 1000-row PostgREST array.
  if v_fill > 0 then
    insert into public.events (owner_id, title, all_day, start_date, end_date)
    select v_f, 'pf fill', true, date '2031-01-01', date '2031-01-02'
    from generate_series(1, v_fill);
  end if;

  select count(*) into v_n from public.events where owner_id = v_f;
  insert into pf_log values (60, 'owner quota', 'bulk INSERT to LIMIT-1 accepted',
    (v_limit - 1)::text, v_n::text);

  begin
    insert into public.events (owner_id, title, all_day, start_date, end_date)
    values (v_f, 'pf at limit', true, date '2031-02-01', date '2031-02-02');
    insert into pf_log values (61, 'owner quota', 'the row landing exactly ON the ceiling is ACCEPTED',
      'accepted', 'accepted');
  exception when others then
    insert into pf_log values (61, 'owner quota', 'the row landing exactly ON the ceiling is ACCEPTED',
      'accepted', format('REFUSED %s', sqlstate));
  end;

  begin
    insert into public.events (owner_id, title, all_day, start_date, end_date)
    values (v_f, 'pf over', true, date '2031-03-01', date '2031-03-02');
    insert into pf_log values (62, 'owner quota', 'the row that would exceed it is REFUSED',
      'TIMEWEAVE_QUOTA_EVENTS', 'ACCEPTED');
  exception when check_violation then
    get stacked diagnostics v_det = pg_exception_detail;
    insert into pf_log values (62, 'owner quota', 'the row that would exceed it is REFUSED',
      'TIMEWEAVE_QUOTA_EVENTS', coalesce(v_det, sqlstate));
  end;

  select count(*) into v_n from public.events where owner_id = v_f;
  insert into pf_log values (63, 'owner quota', 'after the refusal the owner is still at the ceiling',
    v_limit::text, v_n::text);

  -- THE ONE THAT MATTERS MOST: a multi-row INSERT crossing the line in a
  -- SINGLE statement must be refused WHOLE. A per-row check evaluated in the
  -- wrong order, or a statement trigger that double-counted, shows up here and
  -- nowhere else.
  begin
    insert into public.events (owner_id, title, all_day, start_date, end_date)
    select v_f, 'pf burst', true, date '2031-04-01', date '2031-04-02'
    from generate_series(1, 10);
    insert into pf_log values (64, 'owner quota', 'a 10-row burst over the ceiling is REFUSED',
      'TIMEWEAVE_QUOTA_EVENTS', 'ACCEPTED');
  exception when check_violation then
    get stacked diagnostics v_det = pg_exception_detail;
    insert into pf_log values (64, 'owner quota', 'a 10-row burst over the ceiling is REFUSED',
      'TIMEWEAVE_QUOTA_EVENTS', coalesce(v_det, sqlstate));
  end;

  select count(*) into v_n from public.events where owner_id = v_f;
  insert into pf_log values (65, 'owner quota', 'the refused burst inserted NO rows',
    v_limit::text, v_n::text);

  -- THE DELTA RULE. The owner sits exactly ON the ceiling. An UPDATE that adds
  -- no rows must still be allowed, or a full account is a frozen account --
  -- the tombstone bug all over again.
  begin
    update public.events set title = 'pf touched'
    where owner_id = v_f and title = 'pf at limit';
    insert into pf_log values (70, 'delta rule', 'UPDATE at the ceiling is ALLOWED',
      'allowed', 'allowed');
  exception when others then
    get stacked diagnostics v_det = pg_exception_detail;
    insert into pf_log values (70, 'delta rule', 'UPDATE at the ceiling is ALLOWED',
      'allowed', format('REFUSED %s / %s', sqlstate, coalesce(v_det, '')));
  end;

  -- And a DELETE, for the same reason: an over-quota owner must be able to
  -- tidy up. 0011 registers no DELETE trigger, so this must simply work.
  begin
    delete from public.events where owner_id = v_f and title = 'pf touched';
    insert into pf_log values (71, 'delta rule', 'DELETE at the ceiling is ALLOWED',
      'allowed', 'allowed');
  exception when others then
    insert into pf_log values (71, 'delta rule', 'DELETE at the ceiling is ALLOWED',
      'allowed', format('REFUSED %s', sqlstate));
  end;
end;
$ownq$;


-- ============================================================================
-- Section 8. Blast radius.
--
-- The strongest statement this file can make from inside its own transaction,
-- and it is worth making: every row it wrote belongs to the test account, and
-- the live table is unchanged.
-- ============================================================================
insert into pf_log
select 80, 'blast radius', 'rows written that do NOT belong to the fixture owner', '0',
       count(*)::text
from public.events
where (title like 'pf %' or title ~ '^a{200,}$')
  and owner_id <> current_setting('pf.owner_f')::uuid;

-- 16 is PINNED from the preflight, on purpose and with the same reasoning the
-- cleanup script used: if a real event has been created since, this reports
-- MISMATCH and says so, rather than quietly measuring a table that moved. A
-- MISMATCH here is information, not necessarily a fault -- confirm the new
-- number is legitimate, then update this one literal.
insert into pf_log
select 81, 'blast radius', 'real (non-fixture) events rows, unchanged since preflight', '16',
       count(*)::text
from public.events
where owner_id <> current_setting('pf.owner_f')::uuid;


-- ============================================================================
-- Section 9. The advisory locks this transaction actually holds.
--
-- 0011 keys them on hashtext(owner_id) and hashtext(recurrence_id), under lock
-- classes 811001 and 811002. The only owner involved is the test account, and
-- every master id was generated inside this transaction, so no live account's
-- key is ever the one being held.
--
-- Check 85 shows the count rather than asserting a number: the exact total
-- depends on how many distinct masters the sections above touched, and pinning
-- it would make this row a maintenance burden without making it more
-- informative. They are all released by the ROLLBACK, which is a property of
-- pg_advisory_xact_lock, not of this file.
-- ============================================================================
insert into pf_log
select 85, 'locks', 'advisory locks held by this backend (all released on ROLLBACK)',
       null, count(*)::text
from pg_catalog.pg_locks
where locktype = 'advisory' and pid = pg_catalog.pg_backend_pid();

insert into pf_log
select 86, 'locks', 'advisory locks held on a NON-quota classid', '0',
       count(*)::text
from pg_catalog.pg_locks
where locktype = 'advisory' and pid = pg_catalog.pg_backend_pid()
  and classid not in (811001, 811002);


-- ============================================================================
-- Section 9b. Coverage.
--
-- Every assertion above writes exactly one row. If a DO block returned early or
-- raised past its remaining inserts, the total comes up short and this reports
-- the shortfall -- which is what a gap in the numbering could otherwise hide.
--
--   10-19 objects      10      50-53 exception quota   4
--   20-21 fixture       2      60-65 owner quota       6
--   30-35 content       6      70-71 delta rule        2
--   40-47 FK catalog    8      80-81 blast radius      2
--   48-49 FK behaviour  2      85-86 locks             2
--                                                     --
--                                              total  44
-- ============================================================================
insert into pf_log
select 95, 'coverage', 'assertions recorded before this one', '44', count(*)::text
from pf_log;


-- ============================================================================
-- The report. A NULL `expected` marks a context row rather than an assertion.
-- ============================================================================
select ord, part, check_name,
       coalesce(expected, '-') as expected,
       value,
       case when expected is null then 'context'
            when value is not distinct from expected then 'ok'
            else 'MISMATCH' end as status
from pf_log
order by ord;

-- ###########################################################################
-- ROLLBACK, always. There is no version of this file that commits: its
-- fixtures exist to be refused, and its lowered ceilings exist for one
-- transaction. Do not change this line.
-- ###########################################################################
rollback;


-- ============================================================================
-- Section 10. VERIFY FROM OUTSIDE, IN A NEW SESSION.
--
-- Everything above measured its own uncommitted state, which cannot prove that
-- nothing survived. Open a NEW Supabase SQL Editor tab and run this. It is a
-- bare SELECT, read-only, and creates nothing.
--
--   select 'events_max_per_owner'              as item,
--          public.events_max_per_owner()::text as value, '5000' as expected
--   union all
--   select 'events_max_exceptions_per_master',
--          public.events_max_exceptions_per_master()::text, '500'
--   union all
--   select 'events rows in total',
--          (select count(*)::text from public.events), '16'
--   union all
--   select 'rows owned by the test user',
--          (select count(*)::text from public.events
--            where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727'), '0'
--   union all
--   select 'leftover pf_ fixture rows',
--          (select count(*)::text from public.events
--            where title like 'pf %' or title ~ '^a{200,}$'), '0';
--
-- All five must match. The first two prove the lowered ceilings were restored;
-- the last three prove no fixture survived. There is no auth.users row to check
-- for, because this file never created one.
-- ============================================================================
