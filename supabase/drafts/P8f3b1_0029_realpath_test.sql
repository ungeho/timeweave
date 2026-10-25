-- ============================================================================
-- 0029 REAL-PATH TEST -- through RLS and every trigger, as the roles PostgREST
-- uses. ISOLATED DATABASE ONLY (writes, then ROLLBACK). Fictional data only.
-- Runs in all three states and expects what each state should do:
--   no 0029 (before / after rollback)  -> malformed rules are STORED (today's gap)
--   0029 applied                        -> malformed rules are REFUSED
--   psql -h 127.0.0.1 -p 5433 -U postgres -d <db> -X -f supabase/drafts/P8f3b1_0029_realpath_test.sql
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off
begin;
set local timezone = 'UTC';
set local statement_timeout = '60s';

do $$ begin
  if not exists (select 1 from auth.users where id = '5e86935f-7661-4741-868f-0f51c4cf1727') then
    raise exception 'canonical test owner missing from auth.users -- wrong database?';
  end if;
  if exists (select 1 from public.events where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727') then
    raise exception 'the test owner already has rows -- refusing to run on a database in use';
  end if;
end $$;
delete from timeweave_private.event_write_rate where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';

create temp table st(k16 boolean, k15 boolean);
insert into st values (
  exists (select 1 from pg_catalog.pg_trigger where tgname = 'events_validate_rrule' and tgrelid = 'public.events'::regclass),
  to_regprocedure('public.timezone_name_listed(text)') is not null);
create temp table o(c text, note text, expected text, actual text);
grant select on st to authenticated, service_role;
grant insert on o to authenticated, service_role;

-- an attempt: 'stored' or 'refused <sqlstate> <detail> <message>'
create or replace function pg_temp.try(sql text) returns text language plpgsql as $$
declare v_state text; v_det text; v_msg text;
begin
  execute sql;
  return 'stored';
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail, v_msg = message_text;
  return 'refused ' || v_state || ' ' || coalesce(v_det, '') || ' | ' || v_msg;
end $$;
grant execute on function pg_temp.try(text) to authenticated, service_role;
create or replace function pg_temp.ins(rrule text, tz text default 'Asia/Tokyo', owner uuid default '5e86935f-7661-4741-868f-0f51c4cf1727', title text default 'r') returns text language sql as $$
  select format('insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at, rrule, timezone) values (%L, %L, ''public'', ''busy'', false, ''2026-06-01 01:00Z'', ''2026-06-01 02:00Z'', %L, %L)',
                owner, title, rrule, tz);
$$;
grant execute on function pg_temp.ins(text, text, uuid, text) to authenticated, service_role;

-- a legacy row with a malformed rule, as if stored before 0029 (trigger off only for this insert)
do $$ begin
  if (select k16 from st) then execute 'alter table public.events disable trigger events_validate_rrule'; end if;
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at, rrule, timezone)
  values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'legacy', 'public', 'busy', false, '2026-05-05 01:00Z', '2026-05-05 02:00Z', 'FREQ=YEARLY', 'Asia/Tokyo');
  if (select k16 from st) then execute 'alter table public.events enable trigger events_validate_rrule'; end if;
end $$;

-- ===================== the owner, through RLS =====================================
set local role authenticated;
set local request.jwt.claim.sub = '5e86935f-7661-4741-868f-0f51c4cf1727';
do $$
declare k16 boolean := (select k16 from st); v text; id uuid;
begin
  insert into o values ('P1', 'canonical rule: INSERT', 'stored', pg_temp.try(pg_temp.ins('FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=10')));
  v := pg_temp.try(pg_temp.ins('FREQ=DAILY;INTERVAL=1e+23', 'Asia/Tokyo', '5e86935f-7661-4741-868f-0f51c4cf1727', 'bad'));
  insert into o values ('P2', 'malformed rule: INSERT', case when k16 then 'refused 23514 TIMEWEAVE_RRULE_INVALID' else 'stored' end, split_part(v, ' |', 1));
  insert into o values ('P2m', 'the refusal names no input and no internals beyond the column', case when k16 then 'events.rrule is not a supported recurrence rule' else '-' end,
    case when k16 then split_part(v, '| ', 2) else '-' end);
  insert into o values ('P2e', 'the refusal does not echo the input', 'false', (v ~ '1e\+23|INTERVAL')::text);
  select e.id into id from public.events e where e.title = 'r' limit 1;
  insert into o values ('P3', 'UPDATE to another canonical rule', 'stored', pg_temp.try(format('update public.events set rrule = %L where id = %L', 'FREQ=DAILY;COUNT=5', id)));
  insert into o values ('P4', 'UPDATE to a malformed rule', case when k16 then 'refused 23514 TIMEWEAVE_RRULE_INVALID' else 'stored' end,
    split_part(pg_temp.try(format('update public.events set rrule = %L where id = %L', 'FREQ=WEEKLY;BYDAY=MO,MO', id)), ' |', 1));
  insert into o values ('P5', 'UPDATE that does not touch rrule on a canonical row', 'stored', pg_temp.try(format('update public.events set title = %L where id = %L', 'renamed', id)));
  -- the upsert PostgREST performs for Prefer: resolution=merge-duplicates
  insert into o values ('P6', 'upsert (INSERT ... ON CONFLICT DO UPDATE) carrying a malformed rule', case when k16 then 'refused 23514 TIMEWEAVE_RRULE_INVALID' else 'stored' end,
    split_part(pg_temp.try(format('insert into public.events (id, owner_id, title, visibility, availability, all_day, start_at, end_at, rrule, timezone) values (%L, %L, ''u'', ''public'', ''busy'', false, ''2026-06-01 01:00Z'', ''2026-06-01 02:00Z'', ''FREQ=WEEKLY'', ''Asia/Tokyo'') on conflict (id) do update set rrule = %L',
      id, '5e86935f-7661-4741-868f-0f51c4cf1727', 'garbage')), ' |', 1));
  -- the legacy malformed row
  select e.id into id from public.events e where e.title = 'legacy';
  insert into o values ('L1', 'legacy malformed row: rename and move (rrule untouched)', 'stored',
    pg_temp.try(format('update public.events set title = %L, start_at = start_at + interval ''1 hour'', end_at = end_at + interval ''1 hour'' where id = %L', 'legacy-2', id)));
  insert into o values ('L2', 'legacy row: change to another malformed rule', case when k16 then 'refused 23514 TIMEWEAVE_RRULE_INVALID' else 'stored' end,
    split_part(pg_temp.try(format('update public.events set rrule = %L where id = %L', 'FREQ=YEARLY;INTERVAL=2', id)), ' |', 1));
  insert into o values ('L3', 'legacy row: repair to a canonical rule', 'stored', pg_temp.try(format('update public.events set rrule = %L where id = %L', 'FREQ=WEEKLY', id)));
  insert into o values ('L4', 'legacy row: DELETE', 'stored', pg_temp.try(format('delete from public.events where id = %L', id)));
  -- 0028 and 0029 together: which check answers first. A malformed rule with a
  -- zone that does not exist is refused by the rrule check (it fires first by
  -- name), before any zone lookup.
  insert into o values ('T1', 'malformed rule AND unknown zone: the rrule check answers first', case when k16 then 'refused 23514 TIMEWEAVE_RRULE_INVALID' else 'refused 23514 TIMEWEAVE_TZ_INVALID' end,
    split_part(pg_temp.try(pg_temp.ins('garbage', 'Not/AZone')), ' |', 1));
end $$;
reset role;

-- ===================== another signed-in user ======================================
set local role authenticated;
set local request.jwt.claim.sub = '0f0f0f0f-0000-4000-8000-00000000beef';
do $$
declare k16 boolean := (select k16 from st);
begin
  insert into o values ('X1', 'another user: canonical rule into the owner''s calendar', 'refused 42501',
    left(split_part(pg_temp.try(pg_temp.ins('FREQ=WEEKLY')), ' |', 1), 13));
  -- with 0029 the BEFORE trigger answers before the RLS check, so the other user
  -- learns only that the rule THEY sent is unsupported -- nothing about the owner
  insert into o values ('X2', 'another user: malformed rule into the owner''s calendar', case when k16 then 'refused 23514 TIMEWEAVE_RRULE_INVALID' else 'refused 42501' end,
    case when k16 then split_part(pg_temp.try(pg_temp.ins('garbage')), ' |', 1) else left(split_part(pg_temp.try(pg_temp.ins('garbage')), ' |', 1), 13) end);
  insert into o values ('X3', 'another user sees none of the owner''s rows', '0', (select count(*) from public.events where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727')::text);
end $$;
reset role;

-- ===================== service_role (bypasses RLS on Supabase) =========================
-- The isolated database's service_role has neither BYPASSRLS nor EXECUTE on
-- timezone_is_supported (on Supabase it bypasses RLS and may hold EXECUTE
-- through default privileges). Emulate that for this one check -- table
-- grants, EXECUTE, and the owner's id so RLS passes -- all rolled back, so
-- what is tested is the rrule check, not this environment's privileges.
do $$ begin
  if exists (select 1 from pg_catalog.pg_roles where rolname = 'service_role') then
    grant insert, select on public.events to service_role;
    grant execute on function public.timezone_is_supported(text) to service_role;
    if to_regprocedure('public.timezone_name_listed(text)') is not null then
      grant execute on function public.timezone_name_listed(text) to service_role;
    end if;
  end if;
end $$;
set local role service_role;
set local request.jwt.claim.sub = '5e86935f-7661-4741-868f-0f51c4cf1727';
do $$
declare k16 boolean := (select k16 from st);
begin
  insert into o values ('S1', 'service_role: malformed rule', case when k16 then 'refused 23514 TIMEWEAVE_RRULE_INVALID' else 'stored' end,
    split_part(pg_temp.try(pg_temp.ins('FREQ=YEARLY')), ' |', 1));
end $$;
reset role;

-- ===================== the objects themselves ========================================
insert into o select 'O1', 'trigger function: SECURITY DEFINER, search_path pinned, owned by the events owner',
  case when (select k16 from st) then 'true|search_path=""|true' else '-' end,
  case when (select k16 from st) then
    (select p.prosecdef::text || '|' || array_to_string(p.proconfig, ',') || '|' || (p.proowner = (select relowner from pg_catalog.pg_class where oid = 'public.events'::regclass))::text
       from pg_catalog.pg_proc p where p.oid = to_regprocedure('public.events_validate_rrule()')) else '-' end;
insert into o select 'O2', 'no client role (or PUBLIC) may EXECUTE the trigger function or the predicate',
  case when (select k16 from st) then '0' else '-' end,
  case when (select k16 from st) then
    (select count(*) from unnest(array['anon', 'authenticated', 'service_role']) r, unnest(array['public.events_validate_rrule()', 'public.rrule_is_writable(text, boolean)']) f
      where has_function_privilege(r, f::regprocedure, 'EXECUTE'))::text
    || (select case when count(*) > 0 then '+PUBLIC' else '' end from pg_catalog.pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
         where p.oid in (to_regprocedure('public.events_validate_rrule()'), to_regprocedure('public.rrule_is_writable(text, boolean)')) and a.grantee = 0)
  else '-' end;
insert into o select 'O3', 'BEFORE ROW triggers on events, in firing (name) order',
  case when (select k16 from st) then 'events_set_updated_at,events_validate_rrule,events_validate_timezone' else 'events_set_updated_at,events_validate_timezone' end,
  (select string_agg(tgname, ',' order by tgname) from pg_catalog.pg_trigger
    where tgrelid = 'public.events'::regclass and not tgisinternal and (tgtype & 2) = 2 and (tgtype & 1) = 1);

\echo ''
select 'state: 0029 ' || case when k16 then 'APPLIED' else 'absent' end || ', 0028 ' || case when k15 then 'APPLIED' else 'absent' end as state from st;
select c, case when expected is not distinct from actual then 'ok' else 'FAIL' end as status, note, expected, actual
from o
union all
select 'ZZZ', case when count(*) filter (where expected is distinct from actual) = 0 then 'ok' else 'FAIL' end,
       'FAIL rows (GO requires 0)', '0', (count(*) filter (where expected is distinct from actual))::text
from o
order by 1;
rollback;
