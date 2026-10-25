-- ============================================================================
-- P8-finish-3a.2 REAL-PATH SUITE -- small volumes, EVERY trigger and limiter ON.
--
-- ISOLATED DATABASE ONLY. One transaction, rolled back. Fictional data only.
-- This file is the counterpart of P8f3a2_rrule_adversarial_test.sql, whose P
-- sections build 5,000-row fixtures with the zone and row-rate triggers OFF and
-- reset the limiters between sections. Nothing here is switched off and no
-- limiter is reset after the setup line, so what it shows is what a signed-in
-- user and an anonymous viewer get through the same objects PostgREST calls:
-- RLS, the 0008 zone trigger, the 0011 quota, the 0012 row-rate limiter, the
-- 0019 Free/Busy limiter.
--
-- WHAT IT CANNOT SHOW: PostgREST itself (HTTP mapping, statement_timeout set
-- per role by the platform, request size limits) -- those exist only in the
-- hosted project and are listed as production checks in the audit.
--
--   psql -h 127.0.0.1 -p 5433 -U postgres -d <db> -X -f supabase/tests/P8f3a2_real_path_test.sql
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off
begin;
set local timezone = 'UTC';
set local statement_timeout = '120s';

do $$ begin
  if not exists (select 1 from auth.users where id = '5e86935f-7661-4741-868f-0f51c4cf1727') then
    raise exception 'canonical test owner missing from auth.users -- wrong database?';
  end if;
  if exists (select 1 from public.events where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727')
     or exists (select 1 from public.share_links where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727') then
    raise exception 'the test owner already has rows -- refusing to run on a database in use';
  end if;
  if exists (select 1 from pg_catalog.pg_trigger where tgrelid = 'public.events'::regclass and not tgisinternal and tgenabled = 'D') then
    raise exception 'a trigger on public.events is disabled -- this suite must run with all of them on';
  end if;
end $$;

-- setup: the limiter state starts empty for this owner (the only reset in the file)
delete from timeweave_private.freebusy_owner_rate where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
delete from timeweave_private.event_write_rate where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
insert into public.share_links (owner_id, token_hash, include_private, share_available)
values ('5e86935f-7661-4741-868f-0f51c4cf1727', encode(extensions.digest('t1','sha256'),'hex'), true, true);

create temp table o(c text, note text, expected text, actual text);
create temp table m(c text, ms numeric, detail text);
grant insert, select on o, m to authenticated, anon;

-- ===================== the owner, through RLS and every write trigger ===============
set local role authenticated;
set local request.jwt.claim.sub = '5e86935f-7661-4741-868f-0f51c4cf1727';
do $$
declare t0 timestamptz; v_state text; v_det text;
begin
  -- RP1: a few ordinary writes, one statement each, and one malformed rule
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'ok', 'public', 'busy', false, '2026-06-03 01:00Z', '2026-06-03 02:00Z');
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'open', 'public', 'available', false, '2026-06-02 00:00Z', '2026-06-02 06:00Z');
  begin
    insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at, rrule, timezone)
    values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'K-SECRET', 'public', 'busy', false, '2026-05-05 01:00Z', '2026-05-05 02:00Z', 'FREQ=YEARLY', 'Asia/Tokyo');
    insert into o values ('RP1', 'through RLS and every trigger, the owner can store a malformed rule (no server check yet: K16)',
      case when exists (select 1 from pg_catalog.pg_trigger where tgname = 'events_validate_rrule') then 'refused' else 'stored' end, 'stored');
  exception when check_violation then
    insert into o values ('RP1', 'through RLS and every trigger: a malformed rule',
      case when exists (select 1 from pg_catalog.pg_trigger where tgname = 'events_validate_rrule') then 'refused' else 'stored' end, 'refused');
  end;

  -- RP2: ONE statement asking for 150 timed recurring rows. 0012 allows 1 row a
  --      second with 120 s of burst, so it must be refused -- but only AFTER the
  --      0008 zone check has run on every row (K15, write side).
  t0 := clock_timestamp();
  begin
    insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at, rrule, timezone)
    select '5e86935f-7661-4741-868f-0f51c4cf1727', 'bulk', 'public', 'busy', false, '2026-05-05 01:00Z', '2026-05-05 02:00Z', 'FREQ=WEEKLY', 'Asia/Tokyo'
    from generate_series(1, 150);
    v_state := 'stored';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_det = pg_exception_detail;
  end;
  insert into m values ('RP2', round(extract(epoch from clock_timestamp() - t0) * 1000), v_state || ' ' || coalesce(v_det, ''));
  insert into o values ('RP2', 'a 150-row statement is refused by the row-rate limiter (0012), and nothing of it is kept',
    'PT429|0', v_state || '|' || (select count(*) from public.events where title = 'bulk'));

  -- RP3: the refused statement left no charge behind (0012), so ordinary writing goes on
  insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
  values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'after', 'public', 'busy', false, '2026-06-04 01:00Z', '2026-06-04 02:00Z');
  insert into o values ('RP3', 'after the refusal the owner writes normally', '1', (select count(*) from public.events where title = 'after')::text);
end $$;
reset role;

-- another signed-in user, same real path
set local role authenticated;
set local request.jwt.claim.sub = '0f0f0f0f-0000-4000-8000-00000000beef';
do $$
declare n int;
begin
  begin
    insert into public.events (owner_id, title, visibility, availability, all_day, start_at, end_at)
    values ('5e86935f-7661-4741-868f-0f51c4cf1727', 'planted', 'public', 'busy', false, '2026-06-02 01:00Z', '2026-06-02 02:00Z');
    insert into o values ('RP4', 'another user cannot write into the owner''s calendar', 'refused', 'stored');
  exception when insufficient_privilege then
    insert into o values ('RP4', 'another user cannot write into the owner''s calendar', 'refused', 'refused');
  end;
  delete from public.events where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
  get diagnostics n = row_count;
  insert into o values ('RP5', 'nor delete from it', '0', n::text);
end $$;
reset role;

-- ===================== an anonymous viewer, until the Free/Busy limiter answers =======
set local role anon;
do $$
declare t0 timestamptz; j jsonb; ok int := 0; v_state text; i int; v_first_refused int;
begin
  for i in 1 .. 60 loop
    t0 := clock_timestamp();
    begin
      j := public.get_free_busy('t1', '2026-06-01 00:00Z', '2026-06-08 00:00Z', '2026-06-01', '2026-06-08');
      ok := ok + 1;
      insert into m values ('RP6.' || lpad(i::text, 2, '0'), round(extract(epoch from clock_timestamp() - t0) * 1000, 1),
        (j->>'complete') || '|' || (j->'available'->>'status'));
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      v_first_refused := coalesce(v_first_refused, i);
      insert into m values ('RP6.' || lpad(i::text, 2, '0'), round(extract(epoch from clock_timestamp() - t0) * 1000, 1), 'refused ' || v_state);
    end;
  end loop;
  insert into o values ('RP6', 'repeated anonymous calls on one link: answered, then refused by the limiter (0019) with PT429',
    'answered>0|PT429', case when ok > 0 then 'answered>0' else 'none' end || '|' || coalesce((select split_part(detail, ' ', 2) from m where c like 'RP6.%' and detail like 'refused%' limit 1), 'never refused'));
  -- Without the K16 write check (draft 0029) the malformed busy master of RP1 is
  -- stored, so every answer must be fail-closed. With it, RP1 was refused,
  -- nothing malformed exists, and the answers are exact.
  if exists (select 1 from pg_catalog.pg_trigger where tgname = 'events_validate_rrule' and tgrelid = 'public.events'::regclass) then
    insert into o values ('RP7', 'with the K16 check nothing malformed was stored, so every answered call is exact', 'true|complete',
      coalesce((select string_agg(distinct detail, ',') from m where c like 'RP6.%' and detail not like 'refused%'), 'none'));
  else
    insert into o values ('RP7', 'every answered call is fail-closed (a malformed busy master is present)', 'false|indeterminate',
      coalesce((select string_agg(distinct detail, ',') from m where c like 'RP6.%' and detail not like 'refused%'), 'none'));
  end if;
end $$;
reset role;

\echo ''
\echo '== measured (ms): RP2 = the refused 150-row write; RP6.nn = each anonymous call'
select c, ms, detail from m where c = 'RP2' or c in ('RP6.01', 'RP6.02') or detail like 'refused%' order by c limit 8;
select 'answered calls' as what, count(*), round(avg(ms), 1) as avg_ms, max(ms) as max_ms from m where c like 'RP6.%' and detail not like 'refused%'
union all
select 'refused calls', count(*), round(avg(ms), 1), max(ms) from m where c like 'RP6.%' and detail like 'refused%';
\echo ''
select c, case when expected is not distinct from actual then 'ok' else 'FAIL' end as status, note, expected, actual
from o
union all
select 'ZZZ', case when count(*) filter (where expected is distinct from actual) = 0 then 'ok' else 'FAIL' end,
       'FAIL rows (GO requires 0)', '0', (count(*) filter (where expected is distinct from actual))::text
from o
order by 1;
rollback;
