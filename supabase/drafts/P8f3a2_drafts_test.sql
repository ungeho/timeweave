-- ============================================================================
-- TEST FOR THE TWO DRAFTS (0028 timezone lookup, 0029 rrule write check).
-- Run on an ISOLATED COPY that has both drafts applied -- never on production,
-- never on a database without them (it asserts their presence first).
-- One transaction, rolled back. Fictional data only.
--   psql -h 127.0.0.1 -p 5433 -U postgres -d <copy> -X -f supabase/drafts/P8f3a2_drafts_test.sql
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off
begin;
set local timezone = 'UTC';
set local statement_timeout = '120s';

do $$ begin
  if to_regprocedure('public.timezone_name_listed(text)') is null or to_regprocedure('public.rrule_is_writable(text, boolean)') is null then
    raise exception 'apply both drafts to this copy first';
  end if;
  if exists (select 1 from public.events where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727') then
    raise exception 'the test owner already has rows';
  end if;
end $$;

create temp table o(c text, note text, expected text, actual text);
grant insert on o to authenticated, anon, service_role;
create or replace function pg_temp.reset_rate() returns void language sql as $$
  delete from timeweave_private.freebusy_owner_rate where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
  delete from timeweave_private.freebusy_link_rate
   where link_id in (select id from public.share_links where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727');
  delete from timeweave_private.event_write_rate where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
$$;

-- ===================== K15: same answers, cheaper ==================================
-- Z1: every known name, and names that are not, answer exactly as 0008's
--     predicate does (written out here as the reference).
insert into o
select 'Z1', 'timezone_is_supported equals the 0008 predicate for every known name and 16 others', '0',
  count(*) filter (where public.timezone_is_supported(n) is distinct from (
      n is not null and length(n) between 1 and 64 and n ~ '^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+){0,2}$'
      and n <> 'localtime' and n not like 'posix/%' and n not like 'right/%'
      and exists (select 1 from pg_catalog.pg_timezone_names z where z.name = n)))::text
from (select name as n from pg_catalog.pg_timezone_names
      union all select unnest(array[null, '', 'Asia/Tokio', 'asia/tokyo', 'Asia/Tokyo ', 'localtime', 'posix/Asia/Tokyo', 'right/UTC',
                                    'Etc/GMT+5', 'UTC', 'GMT', 'Not/AZone', repeat('A', 65), 'America/Argentina/Buenos_Aires',
                                    'Asia/Tokyo;drop', 'US/Eastern'])) x;
-- Z2: the list function is executable by exactly the roles that can execute
--     timezone_is_supported (on Supabase that may include service_role / anon
--     through default privileges; the copy emulates that before applying).
insert into o select 'Z2', 'the list function mirrors timezone_is_supported, role for role (anon|authenticated|service_role)',
  (select string_agg(has_function_privilege(r, 'public.timezone_is_supported(text)', 'EXECUTE')::text, '|' order by r)
     from unnest(array['anon', 'authenticated', 'service_role']) r),
  (select string_agg(has_function_privilege(r, 'public.timezone_name_listed(text)', 'EXECUTE')::text, '|' order by r)
     from unnest(array['anon', 'authenticated', 'service_role']) r);
-- Z2b: a service_role write of a zone row still passes the zone check
--      (only meaningful when service_role can execute timezone_is_supported)
do $$
begin
  if has_function_privilege('service_role', 'public.timezone_is_supported(text)', 'EXECUTE') then
    execute 'set local role service_role';
    insert into o values ('Z2b', 'service_role can still validate a zone through timezone_is_supported', 'true',
      public.timezone_is_supported('Asia/Tokyo')::text);
    execute 'reset role';
  end if;
end $$;

\timing on
-- Z3: the write cost. 200 timed recurring rows (0.15 s a row before the draft).
alter table public.events disable trigger events_rate_ai;
insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at, rrule, timezone)
select '5e86935f-7661-4741-868f-0f51c4cf1727', 'z', 'public', 'busy', false, '2026-05-05 01:00Z', '2026-05-05 02:00Z', 'FREQ=WEEKLY', 'Asia/Tokyo'
from generate_series(1, 200);
alter table public.events enable trigger events_rate_ai;
delete from public.events where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
\timing off

-- Z4: the read cost. 20 series in 20 zones, one anonymous call (5.95 s before the draft).
insert into public.share_links (owner_id, token_hash, include_private, share_available)
values ('5e86935f-7661-4741-868f-0f51c4cf1727', encode(extensions.digest('t1','sha256'),'hex'), true, true);
alter table public.events disable trigger events_rate_ai;
insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at, rrule, timezone)
select '5e86935f-7661-4741-868f-0f51c4cf1727', 'z', 'public', 'busy', false, '2026-05-05 01:00Z', '2026-05-05 02:00Z', 'FREQ=WEEKLY', z.name
from (select name from pg_catalog.pg_timezone_names where name ~ '^(Europe|America|Asia)/[A-Za-z_]+$' order by name limit 20) z;
alter table public.events enable trigger events_rate_ai;
select pg_temp.reset_rate();
create temp table calls(c text, ms numeric, j jsonb);
grant insert on calls to anon;
create or replace function pg_temp.fb(c text) returns void language plpgsql as $$
declare t0 timestamptz := clock_timestamp(); j jsonb;
begin
  j := public.get_free_busy('t1', '2026-06-01 00:00Z', '2026-06-08 00:00Z', '2026-06-01', '2026-06-08');
  insert into calls values (c, round(extract(epoch from clock_timestamp() - t0) * 1000, 1), j);
end $$;
grant execute on function pg_temp.fb(text) to anon;
set local role anon;
select pg_temp.fb('Z4');
reset role;
insert into o select 'Z4', '20 zones: the same Busy answer as before the draft (20 series at one instant merge to 1 slot), complete', 'active|true|1',
  (j->>'link_state')||'|'||(j->>'complete')||'|'||jsonb_array_length(j->'slots') from calls where c = 'Z4';
delete from public.events where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';

-- ===================== K16: what may be written ====================================
create temp table good(r text, all_day boolean);
insert into good values
  ('FREQ=DAILY', false), ('FREQ=WEEKLY', false), ('FREQ=MONTHLY', false), ('FREQ=DAILY', true),
  ('FREQ=DAILY;INTERVAL=2', false), ('FREQ=DAILY;INTERVAL=9999', false), ('FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR', false),
  ('FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR,SA,SU', true), ('FREQ=DAILY;COUNT=1', false), ('FREQ=DAILY;COUNT=9999999', false),
  ('FREQ=MONTHLY;INTERVAL=3;COUNT=12', true), ('FREQ=DAILY;UNTIL=20261231', true), ('FREQ=WEEKLY;BYDAY=TU;UNTIL=20261231T145959Z', false),
  ('FREQ=DAILY;INTERVAL=1', false);
create temp table bad(r text, all_day boolean, why text);
insert into bad values
  ('garbage', false, 'not a rule'), ('FREQ=YEARLY', false, 'unsupported FREQ'), ('freq=daily', false, 'lower case'),
  ('FREQ=DAILY;INTERVAL=0', false, 'zero'), ('FREQ=DAILY;INTERVAL=05', false, 'leading zero'), ('FREQ=DAILY;INTERVAL=10000', false, 'above 9999'),
  ('FREQ=DAILY;INTERVAL=1e+23', false, 'exponent'), ('FREQ=DAILY;COUNT=10000000', false, 'above 9,999,999'), ('FREQ=DAILY;COUNT=2.0', false, 'decimal'),
  ('FREQ=DAILY;COUNT=3;UNTIL=20261231', true, 'COUNT and UNTIL'), ('FREQ=WEEKLY;BYDAY=MO,MO', false, 'repeated day'), ('FREQ=WEEKLY;BYDAY=XX', false, 'unknown day'),
  ('FREQ=WEEKLY;BYDAY=2MO', false, 'ordinal'), ('FREQ=DAILY;BYDAY=MO', false, 'BYDAY without WEEKLY'), ('FREQ=DAILY;UNTIL=20261340', true, 'no such date'),
  ('FREQ=DAILY;UNTIL=20260231T120000Z', false, 'no such date (instant)'), ('FREQ=DAILY;UNTIL=20261231', false, 'date UNTIL on a timed series'),
  ('FREQ=DAILY;UNTIL=20261231T000000Z', true, 'instant UNTIL on an all-day series'), ('FREQ=DAILY;UNTIL=20261231t000000z', false, 'lower case UNTIL'),
  ('FREQ=DAILY;WKST=MO', false, 'unknown key'), ('FREQ=DAILY;FREQ=WEEKLY', false, 'repeated key'), ('FREQ=DAILY;', false, 'trailing separator'),
  (' FREQ=DAILY', false, 'leading space'), (E'FREQ=DAILY\n', false, 'control character'), ('FREQ=DAILY;INTERVAL=2;BYDAY=MO', false, 'BYDAY on DAILY'),
  ('FREQ=WEEKLY;BYDAY=MO;INTERVAL=2', false, 'non-canonical order'), ('INTERVAL=2;FREQ=DAILY', false, 'FREQ not first'),
  ('FREQ=ＤＡＩＬＹ', false, 'full-width'), ('RRULE:FREQ=DAILY', false, 'RRULE: prefix');
insert into o select 'W1', 'every canonical rule is writable', '0', count(*) filter (where not public.rrule_is_writable(r, all_day))::text from good;
insert into o select 'W2', 'every non-canonical or unsupported rule is refused (' || count(*) || ' shapes)', '0',
  count(*) filter (where public.rrule_is_writable(r, all_day))::text from bad;

-- W3..: through RLS, as the owner
create temp table w(c text, outcome text);
grant insert on w to authenticated;
set local role authenticated;
set local request.jwt.claim.sub = '5e86935f-7661-4741-868f-0f51c4cf1727';
do $$
declare v_id uuid; v_det text; v_msg text;
begin
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at, rrule, timezone)
  values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'ok', 'public', 'busy', false, '2026-05-05 01:00Z', '2026-05-05 02:00Z', 'FREQ=WEEKLY;BYDAY=TU;COUNT=9999999', 'Asia/Tokyo')
  returning id into v_id;
  insert into w values ('W3', 'stored');
  begin
    insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at, rrule, timezone)
    values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'x', 'public', 'busy', false, '2026-05-05 01:00Z', '2026-05-05 02:00Z', 'FREQ=DAILY;INTERVAL=1e+23', 'Asia/Tokyo');
    insert into w values ('W4', 'stored');
  exception when check_violation then
    get stacked diagnostics v_det = pg_exception_detail, v_msg = message_text;
    insert into w values ('W4', 'refused ' || v_det || case when v_msg ~ '1e\+23|INTERVAL|rrule_parse|timeweave' then ' LEAKS' else '' end);
  end;
  begin
    update public.events set rrule = 'garbage' where id = v_id;
    insert into w values ('W5', 'stored');
  exception when check_violation then insert into w values ('W5', 'refused'); end;
  update public.events set title = 'renamed' where id = v_id;
  insert into w values ('W6', 'renamed');
end $$;
reset role;
-- W7: an existing odd row (written before the trigger existed) can still be
-- renamed and deleted by its owner; changing its rule to another odd one cannot.
alter table public.events disable trigger events_validate_rrule;
insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at, rrule, timezone)
values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'legacy', 'public', 'busy', false, '2026-05-05 01:00Z', '2026-05-05 02:00Z', 'FREQ=YEARLY', 'Asia/Tokyo');
alter table public.events enable trigger events_validate_rrule;
set local role authenticated;
set local request.jwt.claim.sub = '5e86935f-7661-4741-868f-0f51c4cf1727';
do $$
declare n int;
begin
  update public.events set title = 'legacy renamed', start_at = start_at + interval '1 hour', end_at = end_at + interval '1 hour' where title = 'legacy';
  get diagnostics n = row_count;
  insert into w values ('W7', 'renamed ' || n);
  begin
    update public.events set rrule = 'FREQ=YEARLY;INTERVAL=2' where title = 'legacy renamed';
    insert into w values ('W8', 'stored');
  exception when check_violation then insert into w values ('W8', 'refused'); end;
  update public.events set rrule = 'FREQ=WEEKLY' where title = 'legacy renamed';
  get diagnostics n = row_count;
  insert into w values ('W9', 'repaired ' || n);
  delete from public.events where title = 'legacy renamed';
  get diagnostics n = row_count;
  insert into w values ('W10', 'deleted ' || n);
end $$;
reset role;
insert into o select c, case c
    when 'W3' then 'a canonical rule at the largest COUNT is stored'
    when 'W4' then 'a non-canonical rule is refused, with a code and no echo of the input'
    when 'W5' then 'changing a rule to garbage is refused'
    when 'W6' then 'a stored row is renamed without its rule being re-judged'
    when 'W7' then 'an existing odd row can still be renamed and moved'
    when 'W8' then 'its rule cannot be changed to another odd one'
    when 'W9' then 'its rule CAN be changed to a supported one (the owner can repair it)'
    when 'W10' then 'and it can always be deleted' end,
  case c when 'W3' then 'stored' when 'W4' then 'refused TIMEWEAVE_RRULE_INVALID' when 'W5' then 'refused' when 'W6' then 'renamed'
         when 'W7' then 'renamed 1' when 'W8' then 'refused' when 'W9' then 'repaired 1' when 'W10' then 'deleted 1' end,
  outcome from w;
insert into o select 'W11', 'no client role may execute the predicate or the trigger function', 'false|false|false|false',
  has_function_privilege('anon', 'public.rrule_is_writable(text, boolean)', 'EXECUTE')||'|'||has_function_privilege('authenticated', 'public.rrule_is_writable(text, boolean)', 'EXECUTE')
  ||'|'||has_function_privilege('anon', 'public.events_validate_rrule()', 'EXECUTE')||'|'||has_function_privilege('authenticated', 'public.events_validate_rrule()', 'EXECUTE');

\echo ''
\echo '== anonymous call time (ms)'
select c, ms from calls;
select c, case when expected is not distinct from actual then 'ok' else 'FAIL' end as status, note, expected, actual
from o
union all
select 'ZZZ', case when count(*) filter (where expected is distinct from actual) = 0 then 'ok' else 'FAIL' end,
       'FAIL rows (GO requires 0)', '0', (count(*) filter (where expected is distinct from actual))::text
from o
order by 1;
rollback;
