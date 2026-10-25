-- ============================================================================
-- P8-finish-3b K18 -- the date bounds the client now enforces
-- (src/features/event/eventDateBounds.ts) are exactly the ones the database
-- enforces (0013), through RLS and every trigger, as the signed-in owner.
-- ISOLATED DATABASE ONLY. One transaction, rolled back. Fictional data only.
--   psql -h 127.0.0.1 -p 5433 -U postgres -d <db> -X -f supabase/tests/P8f3b_date_bounds_test.sql
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

create temp table o(c text, note text, expected text, actual text);
grant insert on o to authenticated;
set local role authenticated;
set local request.jwt.claim.sub = '5e86935f-7661-4741-868f-0f51c4cf1727';

create or replace function pg_temp.try_allday(c text, note text, expected text, sd date, ed date) returns void language plpgsql as $$
declare v_con text;
begin
  insert into public.events (owner_id, title, visibility, availability, all_day, start_date, end_date)
  values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'b', 'public', 'busy', true, sd, ed);
  insert into o values (c, note, expected, 'stored');
exception when check_violation then
  get stacked diagnostics v_con = constraint_name;
  insert into o values (c, note, expected, 'refused ' || v_con);
end $$;
create or replace function pg_temp.try_timed(c text, note text, expected text, sa timestamptz, ea timestamptz) returns void language plpgsql as $$
declare v_con text;
begin
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'b', 'public', 'busy', false, sa, ea);
  insert into o values (c, note, expected, 'stored');
exception when check_violation then
  get stacked diagnostics v_con = constraint_name;
  insert into o values (c, note, expected, 'refused ' || v_con);
end $$;

select pg_temp.try_allday('A1', 'all-day 9999-12-30 (exclusive end 9999-12-31) -- the last day the form allows', 'stored', '9999-12-30', '9999-12-31');
select pg_temp.try_allday('A2', 'all-day 9999-12-31 (exclusive end 10000-01-01) -- what the form used to send', 'refused events_allday_range', '9999-12-31', '10000-01-01');
select pg_temp.try_allday('A3', 'all-day starting 0100-01-01', 'stored', '0100-01-01', '0100-01-02');
select pg_temp.try_timed('T1', 'timed ending at the last millisecond before 10000-01-01 UTC', 'stored', '9999-12-31 23:00Z', '9999-12-31 23:59:59.999Z');
select pg_temp.try_timed('T2', 'timed ending exactly at 10000-01-01 UTC', 'refused events_timed_range', '9999-12-31 23:00Z', '10000-01-01 00:00Z');
select pg_temp.try_timed('T3', 'timed 9999-12-31 22:00-23:00 New York (10000-01-01 03:00 UTC) -- what the form used to send', 'refused events_timed_range', '10000-01-01 03:00Z', '10000-01-01 04:00Z');
select pg_temp.try_timed('T4', 'timed 9999-12-31 22:00-23:00 Tokyo (9999-12-31 13:00 UTC) -- inside', 'stored', '9999-12-31 13:00Z', '9999-12-31 14:00Z');
reset role;

select c, case when expected is not distinct from actual then 'ok' else 'FAIL' end as status, note, expected, actual
from o
union all
select 'ZZZ', case when count(*) filter (where expected is distinct from actual) = 0 then 'ok' else 'FAIL' end,
       'FAIL rows (GO requires 0)', '0', (count(*) filter (where expected is distinct from actual))::text
from o
order by 1;
rollback;
