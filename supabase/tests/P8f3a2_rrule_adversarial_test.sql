-- ============================================================================
-- P8-finish-3a.2 ADVERSARIAL SUITE -- the rrule column treated as untrusted
-- input, through the real tables, triggers, RLS and the anonymous RPC.
--
-- ISOLATED DATABASE ONLY. Everything runs in one transaction and is rolled
-- back. Fictional data only (the canonical test owner). Every timed probe runs
-- under statement_timeout, and the bulk sections stay inside the existing
-- per-owner quota (0011: 5,000 rows), so nothing here can run away.
--
-- WHAT IT CHECKS, SEPARATELY (a probe that "did not error" passes nothing):
--   D  data integrity     -- what the owner can and cannot store
--   S  share boundary     -- Busy/Available for a viewer with broken rows present
--   A  authorization      -- another user, and anon, against the owner's rows
--   P  load               -- wall time of the anonymous RPC with the worst
--                            legal and illegal data the quota allows
--   R  recovery           -- after the owner deletes the broken rows
--   E  error text         -- what an anonymous caller is told
--
--   psql -h 127.0.0.1 -p 5433 -U postgres -d <db> -X -f supabase/tests/P8f3a2_rrule_adversarial_test.sql
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off
begin;
set local timezone = 'UTC';
set local statement_timeout = '20s';
set local lock_timeout = '5s';

do $$ begin
  if not exists (select 1 from auth.users where id = '5e86935f-7661-4741-868f-0f51c4cf1727') then
    raise exception 'canonical test owner missing from auth.users -- wrong database?';
  end if;
  if exists (select 1 from public.events where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727')
     or exists (select 1 from public.share_links where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727') then
    raise exception 'the test owner already has rows -- refusing to run on a database in use';
  end if;
end $$;

create temp table o(c text, note text, expected text, actual text);
grant insert, select on o to anon, authenticated;
create or replace function pg_temp.ok(c text, note text, expected text, actual text) returns void language sql as $$
  insert into o values (c, note, expected, actual); $$;

create or replace function pg_temp.reset_rate() returns void language sql as $$
  delete from timeweave_private.freebusy_owner_rate where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
  delete from timeweave_private.freebusy_link_rate
   where link_id in (select id from public.share_links where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727');
  delete from timeweave_private.event_write_rate where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
$$;
create or replace function pg_temp.mk(tok text, ip boolean, sa boolean, exp timestamptz default null, rev boolean default false,
  created timestamptz default now()) returns void language sql as $$
  insert into public.share_links (owner_id, token_hash, include_private, share_available, expires_at, revoked_at, created_at)
  values ('5e86935f-7661-4741-868f-0f51c4cf1727', encode(extensions.digest(tok,'sha256'),'hex'), ip, sa, exp,
          case when rev then now() end, created);
$$;
select pg_temp.mk('t1', true, true);
select pg_temp.mk('texp', true, true, now() - interval '1 day', false, now() - interval '2 days');
select pg_temp.mk('trev', true, true, null, true);

-- one anonymous call over a 7-day window; returns the answer and its wall time
create temp table calls(c text, ms numeric, j jsonb);
grant insert, select on calls to anon;
create or replace function pg_temp.fb(c text, tok text) returns void language plpgsql as $$
declare t0 timestamptz := clock_timestamp(); j jsonb;
begin
  j := public.get_free_busy(tok, '2026-06-01 00:00Z', '2026-06-08 00:00Z', '2026-06-01', '2026-06-08');
  insert into calls values (c, round(extract(epoch from clock_timestamp() - t0) * 1000, 1), j);
end $$;
grant execute on function pg_temp.fb(text, text) to anon;
-- the longest window the RPC accepts (92 days)
create or replace function pg_temp.fb92(c text, tok text) returns void language plpgsql as $$
declare t0 timestamptz := clock_timestamp(); j jsonb;
begin
  j := public.get_free_busy(tok, '2026-05-01 00:00Z', '2026-08-01 00:00Z', '2026-05-01', '2026-08-01');
  insert into calls values (c, round(extract(epoch from clock_timestamp() - t0) * 1000, 1), j);
end $$;
grant execute on function pg_temp.fb92(text, text) to anon;

-- ===================== D: what the owner can store (as the owner, through RLS) =====
-- The column has one CHECK (0013: at most 255 bytes). Anything shorter is
-- stored, whatever it says -- that is the gap a server-side check would close.
-- With the draft K16 trigger applied (supabase/drafts/0029_*), none is: D1
-- expects whichever is true of the database it runs on.
set local role authenticated;
set local request.jwt.claim.sub = '5e86935f-7661-4741-868f-0f51c4cf1727';
do $$
declare v text; n int := 0;
begin
  foreach v in array array['garbage', 'FREQ=YEARLY', 'FREQ=DAILY;COUNT=3;UNTIL=20261231', 'FREQ=WEEKLY;BYDAY=XX',
                           'FREQ=DAILY;INTERVAL=1e+23', 'FREQ=DAILY;COUNT=10000000', 'FREQ=DAILY;UNTIL=20261340',
                           'FREQ=DAILY;' || repeat('X', 244)] loop
    begin
      insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at, rrule, timezone)
      values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'K-SECRET', 'public', 'busy', false,
              '2026-05-05 01:00Z', '2026-05-05 02:00Z', v, 'Asia/Tokyo');
      n := n + 1;
    exception when check_violation then null;
    end;
  end loop;
  if exists (select 1 from pg_catalog.pg_trigger where tgname = 'events_validate_rrule' and tgrelid = 'public.events'::regclass) then
    insert into o values ('D1', 'with the K16 draft: the owner can store none of the 8 malformed shapes', '0', n::text);
  else
    insert into o values ('D1', 'the owner can store any rrule up to 255 bytes (8 malformed shapes)', '8', n::text);
  end if;
  begin
    insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at, rrule, timezone)
    values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'x', 'public', 'busy', false, '2026-05-05 01:00Z', '2026-05-05 02:00Z',
            'FREQ=DAILY;' || repeat('X', 245), 'Asia/Tokyo');
    insert into o values ('D2', '256 bytes is refused by events_rrule_len', 'refused', 'stored');
  exception when check_violation then
    insert into o values ('D2', '256 bytes is refused by events_rrule_len', 'refused', 'refused');
  end;
end $$;
reset role;
select pg_temp.reset_rate();

-- With K16 applied the rows above were refused; the share checks below are about
-- rows already stored (before such a check existed), so they are written here
-- as legacy rows with that trigger off for the rest of this rolled-back file.
do $$
declare v text;
begin
  if exists (select 1 from pg_catalog.pg_trigger where tgname = 'events_validate_rrule' and tgrelid = 'public.events'::regclass) then
    execute 'alter table public.events disable trigger events_validate_rrule';
    foreach v in array array['garbage', 'FREQ=YEARLY', 'FREQ=DAILY;COUNT=3;UNTIL=20261231', 'FREQ=WEEKLY;BYDAY=XX',
                             'FREQ=DAILY;INTERVAL=1e+23', 'FREQ=DAILY;COUNT=10000000', 'FREQ=DAILY;UNTIL=20261340',
                             'FREQ=DAILY;' || repeat('X', 244)] loop
      insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at, rrule, timezone)
      values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'K-SECRET', 'public', 'busy', false, '2026-05-05 01:00Z', '2026-05-05 02:00Z', v, 'Asia/Tokyo');
    end loop;
  end if;
end $$;
select pg_temp.reset_rate();

-- ===================== S: the share boundary with those rows present ============
insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'ok', 'public', 'busy', false, '2026-06-03 01:00Z', '2026-06-03 02:00Z'),
       ('5e86935f-7661-4741-868f-0f51c4cf1727', 'open', 'public', 'available', false, '2026-06-02 00:00Z', '2026-06-02 06:00Z');
set local statement_timeout = '20s';
set local role anon;
select pg_temp.fb('S1', 't1');
select pg_temp.fb('S2', 'texp');
select pg_temp.fb('S3', 'trev');
select pg_temp.fb('S4', 'no-such-token');
reset role;
insert into o select 'S1', 'malformed busy masters present -> Busy incomplete, Available indeterminate, no Available slots',
  'active|false|indeterminate|no-slots',
  (j->>'link_state')||'|'||(j->>'complete')||'|'||(j->'available'->>'status')||'|'||case when j->'available' ? 'slots' then 'slots' else 'no-slots' end
  from calls where c = 'S1';
insert into o select 'S1b', 'the answer carries no title, rule or id', 'false',
  (j::text ~ 'K-SECRET|FREQ|garbage|"id"|"title"|"rrule"|owner')::text from calls where c = 'S1';
insert into o select 'S2', 'expired link -> unavailable, nothing else', 'unavailable|0|no-available',
  (j->>'link_state')||'|'||jsonb_array_length(j->'slots')||'|'||case when j ? 'available' then 'available' else 'no-available' end from calls where c = 'S2';
insert into o select 'S3', 'revoked link -> the same answer as expired', 'same', case when (select j from calls where c='S3') = (select j from calls where c='S2') then 'same' else 'differs' end;
insert into o select 'S4', 'unknown token -> the same answer (no oracle)', 'same', case when (select j from calls where c='S4') = (select j from calls where c='S2') then 'same' else 'differs' end;

-- ===================== A: authorization ===========================================
-- another signed-in user (a uuid with no rows; auth.users is never written)
set local role authenticated;
set local request.jwt.claim.sub = '0f0f0f0f-0000-4000-8000-00000000beef';
do $$
declare n int;
begin
  select count(*) into n from public.events where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
  insert into o values ('A1', 'another user reads none of the owner''s rows', '0', n::text);
  update public.events set rrule = 'FREQ=DAILY', title = 'pwned' where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
  get diagnostics n = row_count;
  insert into o values ('A2', 'another user updates none of them', '0', n::text);
  delete from public.events where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
  get diagnostics n = row_count;
  insert into o values ('A3', 'another user deletes none of them', '0', n::text);
  begin
    insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at, rrule, timezone)
    values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'planted', 'public', 'busy', false, '2026-06-02 01:00Z', '2026-06-02 02:00Z', 'garbage', 'Asia/Tokyo');
    insert into o values ('A4', 'another user cannot plant a row in the owner''s calendar', 'refused', 'stored');
  exception when insufficient_privilege then
    insert into o values ('A4', 'another user cannot plant a row in the owner''s calendar', 'refused', 'refused');
  end;
end $$;
reset role;
-- anon: no table access, no parser
set local role anon;
do $$ begin
  begin
    perform 1 from public.events limit 1;
    insert into o values ('A5', 'anon cannot read events', 'refused', 'read');
  exception when insufficient_privilege then insert into o values ('A5', 'anon cannot read events', 'refused', 'refused'); end;
  begin
    insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
    values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'anon', 'public', 'busy', false, '2026-06-02 01:00Z', '2026-06-02 02:00Z');
    insert into o values ('A6', 'anon cannot write events', 'refused', 'stored');
  exception when insufficient_privilege then insert into o values ('A6', 'anon cannot write events', 'refused', 'refused'); end;
  begin
    perform * from public.rrule_parse('FREQ=DAILY');
    insert into o values ('A7', 'anon cannot call the parser directly', 'refused', 'called');
  exception when insufficient_privilege then insert into o values ('A7', 'anon cannot call the parser directly', 'refused', 'refused'); end;
end $$;
-- E: what an anonymous caller is told for a bad request
do $$ begin
  begin
    perform public.get_free_busy('t1', '2026-06-01 00:00Z', '2026-12-01 00:00Z', '2026-06-01', '2026-12-01');
    insert into o values ('E1', 'an over-long window is refused with a generic message (no internals)', 'refused-generic', 'answered');
  exception when others then
    insert into o values ('E1', 'an over-long window is refused with a generic message (no internals)', 'refused-generic',
      case when sqlerrm ~* 'timeweave_private|owner|events|select|line [0-9]' then 'LEAKS: ' || sqlerrm else 'refused-generic' end);
  end;
end $$;
reset role;
select pg_temp.reset_rate();

-- ===================== P: load, with the worst data the quota allows ===============
-- P1: 4,998 malformed masters (5,000 rows in all, the per-owner quota).
-- FIXTURE SHORTCUT. 0008 validates each zone row by row against
-- pg_timezone_names, about 0.1 s a row here (that cost is K15, measured in
-- P8f3a2_timezone_write_cost.sql). 5,000 such rows would take minutes, so the
-- zone trigger is off while the P fixtures are written. Every zone written is
-- 'Asia/Tokyo', which it accepts. The row-rate trigger (0012: one row a second,
-- 120 s of burst) is off too -- it would rightly refuse 5,000 rows -- so the
-- fixtures stand for an owner who filled the quota slowly. The quota trigger
-- (0011: 5,000 rows) stays ON. Both are back on before R; the file rolls back.
set local statement_timeout = '300s';
alter table public.events disable trigger events_validate_timezone;
alter table public.events disable trigger events_rate_ai;
delete from public.events where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at, rrule, timezone)
select '5e86935f-7661-4741-868f-0f51c4cf1727', 'K-SECRET', 'public', case when g % 3 = 0 then 'available' else 'busy' end, false,
       '2026-05-05 01:00Z'::timestamptz + (g % 30) * interval '1 hour', '2026-05-05 02:00Z'::timestamptz + (g % 30) * interval '1 hour',
       (array['garbage','FREQ=YEARLY','FREQ=DAILY;INTERVAL=1e+23','FREQ=WEEKLY;BYDAY=XX','FREQ=DAILY;COUNT=10000000',
              'FREQ=DAILY;' || repeat('X', 244)])[1 + g % 6], 'Asia/Tokyo'
from generate_series(1, 4998) g;
insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'ok', 'public', 'busy', false, '2026-06-03 01:00Z', '2026-06-03 02:00Z'),
       ('5e86935f-7661-4741-868f-0f51c4cf1727', 'open', 'public', 'available', false, '2026-06-02 00:00Z', '2026-06-02 06:00Z');
select pg_temp.reset_rate();
set local statement_timeout = '20s';
set local role anon;
select pg_temp.fb('P1', 't1');
select pg_temp.fb92('P1w', 't1');
reset role;
set local statement_timeout = '300s';
insert into o select 'P1', '5,000 rows, 4,998 malformed masters: answered, fail-closed, within 20 s',
  'active|false|indeterminate', (j->>'link_state')||'|'||(j->>'complete')||'|'||(j->'available'->>'status') from calls where c = 'P1';

-- P2: 4,998 LEGAL masters at the largest legal values (DAILY, COUNT=9,999,999),
--     plus 2 one-offs: the most expansion work legal data can ask for.
delete from public.events where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at, rrule, timezone)
select '5e86935f-7661-4741-868f-0f51c4cf1727', 'legal', 'public', case when g % 3 = 0 then 'available' else 'busy' end, false,
       '2026-05-04 01:00Z'::timestamptz + (g % 1440) * interval '1 minute', '2026-05-04 01:30Z'::timestamptz + (g % 1440) * interval '1 minute',
       'FREQ=DAILY;COUNT=9999999', 'Asia/Tokyo'
from generate_series(1, 4998) g;
insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'ok', 'public', 'busy', false, '2026-06-03 01:00Z', '2026-06-03 02:00Z'),
       ('5e86935f-7661-4741-868f-0f51c4cf1727', 'open', 'public', 'available', false, '2026-06-02 00:00Z', '2026-06-02 06:00Z');
select pg_temp.reset_rate();
set local statement_timeout = '20s';
set local role anon;
select pg_temp.fb('P2', 't1');
select pg_temp.fb92('P2w', 't1');
reset role;
set local statement_timeout = '300s';
insert into o select 'P2', '4,998 legal daily masters with COUNT=9,999,999: answered within 20 s, never complete with Available',
  'active|ok', (j->>'link_state')||'|'||case when (j->>'complete')::boolean and j->'available'->>'status' = 'complete' and jsonb_array_length(j->'available'->'slots') > 0
                                               then 'AVAILABLE-WITH-' || jsonb_array_length(j->'slots') || '-BUSY' else 'ok' end from calls where c = 'P2';

-- P3: one malformed master carrying the most exceptions the quota allows (500)
delete from public.events where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
with m as (
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at, rrule, timezone)
  values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'K-SECRET', 'public', 'busy', false, '2026-05-05 01:00Z', '2026-05-05 02:00Z', 'garbage', 'Asia/Tokyo')
  returning id)
insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at, recurrence_id, recurrence_slot_start, is_cancelled)
select '5e86935f-7661-4741-868f-0f51c4cf1727', 'moved', 'public', 'busy', false,
       '2026-06-01 00:00Z'::timestamptz + g * interval '10 minutes', '2026-06-01 00:05Z'::timestamptz + g * interval '10 minutes',
       m.id, '2026-05-05 01:00Z'::timestamptz + g * interval '1 day', false
from m, generate_series(0, 499) g;
select pg_temp.reset_rate();
set local statement_timeout = '20s';
set local role anon;
select pg_temp.fb('P3', 't1');
reset role;
set local statement_timeout = '300s';
insert into o select 'P2w', 'the same over the longest window (92 days): answered within 20 s, no Available beside incomplete Busy',
  'active|ok', (j->>'link_state')||'|'||case when not (j->>'complete')::boolean and j->'available' ? 'slots' then 'AVAILABLE-WHILE-INCOMPLETE' else 'ok' end from calls where c = 'P2w';
insert into o select 'P1w', '5,000 malformed over 92 days: fail-closed', 'false|indeterminate', (j->>'complete')||'|'||(j->'available'->>'status') from calls where c = 'P1w';
insert into o select 'P3', 'a malformed master with 500 exceptions -> fail-closed', 'false|indeterminate',
  (j->>'complete')||'|'||(j->'available'->>'status') from calls where c = 'P3';

-- P4: K15 on the READ side. get_free_busy checks every distinct zone the owner's
--     timed series use (0018 v_ok_tz, timezone_is_resolvable ->
--     pg_timezone_names), once per call. 20 legal weekly series in 20 zones.
delete from public.events where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at, rrule, timezone)
select '5e86935f-7661-4741-868f-0f51c4cf1727', 'z', 'public', 'busy', false, '2026-05-05 01:00Z', '2026-05-05 02:00Z', 'FREQ=WEEKLY', z.name
from (select name from pg_catalog.pg_timezone_names where name ~ '^(Europe|America|Asia)/[A-Za-z_]+$' order by name limit 20) z;
select pg_temp.reset_rate();
set local statement_timeout = '20s';
set local role anon;
select pg_temp.fb('P4', 't1');
reset role;
set local statement_timeout = '300s';
insert into o select 'P4', '20 legal series in 20 distinct zones: answered (the time is the K15 measurement)', 'active',
  j->>'link_state' from calls where c = 'P4';

alter table public.events enable trigger events_validate_timezone;
alter table public.events enable trigger events_rate_ai;
-- ===================== R: recovery =================================================
-- The owner can always delete a broken series (no trigger reads rrule on DELETE),
-- and the share page is exact again.
set local role authenticated;
set local request.jwt.claim.sub = '5e86935f-7661-4741-868f-0f51c4cf1727';
delete from public.events where rrule is not null and owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'ok', 'public', 'busy', false, '2026-06-03 01:00Z', '2026-06-03 02:00Z'),
       ('5e86935f-7661-4741-868f-0f51c4cf1727', 'open', 'public', 'available', false, '2026-06-02 00:00Z', '2026-06-02 06:00Z');
reset role;
select pg_temp.reset_rate();
set local statement_timeout = '20s';
set local role anon;
select pg_temp.fb('R1', 't1');
reset role;
insert into o select 'R1', 'after the owner deletes the broken series (exceptions cascade), the answer is exact again',
  'false|complete|T:06-02T00:00/06-02T06:00',
  (select (count(*) > 0)::text from public.events where recurrence_id is not null and owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727')
  ||'|'||(j->'available'->>'status')||'|'||
  (select string_agg('T:'||to_char((s->>'start')::timestamptz at time zone 'UTC','MM-DD"T"HH24:MI')||'/'||to_char((s->>'end')::timestamptz at time zone 'UTC','MM-DD"T"HH24:MI'), ' ')
     from jsonb_array_elements(j->'available'->'slots') s)
  from calls where c = 'R1';

\echo ''
\echo '== wall time (ms), answer size (bytes), Busy completeness and slot count of each anonymous call'
select c, ms, octet_length(j::text) as bytes, j->>'complete' as complete, jsonb_array_length(coalesce(j->'slots','[]')) as busy_slots, j->'available'->>'status' as available from calls order by c;
\echo ''
select c, case when expected is not distinct from actual then 'ok' else 'FAIL' end as status, note, expected, actual
from o
union all
select 'ZZZ', case when count(*) filter (where expected is distinct from actual) = 0 then 'ok' else 'FAIL' end,
       'FAIL rows (GO requires 0)', '0', (count(*) filter (where expected is distinct from actual))::text
from o
order by 1;
rollback;
