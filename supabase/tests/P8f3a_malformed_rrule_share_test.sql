-- ============================================================================
-- P8-finish-3a RUNTIME SUITE -- K12: a master whose RRULE the client cannot
-- expand, through the real Free/Busy objects. Read-mostly: everything is rolled
-- back. No migration is involved and nothing here changes SQL behaviour.
--
-- WHY. P8-finish-3a makes the OWNER's calendar skip a series it cannot expand
-- (src/services/occurrences.ts) instead of failing to draw at all. The share
-- page never uses that code: Busy/Available are computed here, on the server,
-- from the rows themselves. So hiding a broken series on the owner's screen
-- cannot open free time to a viewer -- provided the server, given the same
-- rows, answers "incomplete" rather than "free". That is what this file pins,
-- for the four shapes K12 named (docs/p8-final-risk-audit.md):
--   FREQ=YEARLY · COUNT together with UNTIL · a malformed segment · BYDAY=XX
-- 0024_available_test.sql sections 8.1 and 9 already pin the same rule for
-- FREQ=MONTHLY; this extends it to the shapes the client throws on.
--
-- Run on the isolated DB only:
--   psql -h 127.0.0.1 -p 5433 -U postgres -d <db> -X -f supabase/tests/P8f3a_malformed_rrule_share_test.sql
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off
begin;
set local timezone = 'UTC';

do $$ begin
  if not exists (select 1 from auth.users where id = '5e86935f-7661-4741-868f-0f51c4cf1727') then
    raise exception 'canonical test owner missing from auth.users -- wrong database?';
  end if;
  if exists (select 1 from public.events where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727')
     or exists (select 1 from public.owner_settings where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727') then
    raise exception 'the test owner already has rows -- refusing to run on a database in use';
  end if;
end $$;

create or replace function pg_temp.mk(tok text, ip boolean, sa boolean) returns void language sql as $$
  insert into public.share_links (owner_id, token_hash, include_private, share_available)
  values ('5e86935f-7661-4741-868f-0f51c4cf1727', encode(extensions.digest(tok,'sha256'),'hex'), ip, sa);
$$;
select pg_temp.mk('t1', true, true);    -- include_private ON,  share_available ON
select pg_temp.mk('t0', false, true);   -- include_private OFF, share_available ON
select pg_temp.mk('toff', true, false); -- share_available OFF

create or replace function pg_temp.ev(ttl text, vis text, av text, sa timestamptz, ea timestamptz,
  rr text default null, tz text default null, ad boolean default false, sd date default null, ed date default null)
returns uuid language sql as $$
  insert into public.events (owner_id,title,visibility,availability,all_day,start_at,end_at,start_date,end_date,rrule,timezone)
  values ('5e86935f-7661-4741-868f-0f51c4cf1727',ttl,vis,av,ad,sa,ea,sd,ed,rr,tz) returning id;
$$;

create or replace function pg_temp.norm(slots jsonb) returns text language sql as $$
  select coalesce(string_agg(
           case when (s -> 'all_day')::boolean
                then 'D:' || (s ->> 'start_date') || '/' || (s ->> 'end_date')
                else 'T:' || to_char((s ->> 'start')::timestamptz at time zone 'UTC', 'MM-DD"T"HH24:MI')
                     || '/' || to_char((s ->> 'end')::timestamptz at time zone 'UTC', 'MM-DD"T"HH24:MI')
           end, ' ' order by ord), '(none)')
  from jsonb_array_elements(slots) with ordinality as e(s, ord)
$$;
-- "busy <slots> <''|INCOMPLETE> | avail <status or slots>", over 2026-06-01 .. 06-08 (UTC)
create or replace function pg_temp.probe(tok text) returns text language sql as $$
  select coalesce(
    (select 'busy ' || pg_temp.norm(c.r -> 'slots')
            || case when (c.r -> 'complete')::boolean then '' else ' INCOMPLETE' end
            || ' | avail ' || case when a.r ->> 'status' = 'complete' then pg_temp.norm(a.r -> 'slots') else a.r ->> 'status' end
       from public.share_links lk,
            timeweave_private.free_busy_core(lk.id, '2026-06-01 00:00Z', '2026-06-08 00:00Z', '2026-06-01', '2026-06-08') as c(r),
            lateral timeweave_private.free_busy_available(lk.id, '2026-06-01 00:00Z', '2026-06-08 00:00Z', '2026-06-01', '2026-06-08', c.r) as a(r)
      where lk.token_hash = encode(extensions.digest(tok,'sha256'),'hex') and lk.share_available),
    'link-not-eligible');
$$;
-- If the draft K16 write check is applied (supabase/drafts/0029_*), the rows
-- below could no longer be written; they stand for rows stored before it, so
-- that trigger is off for this rolled-back file.
do $$ begin
  if exists (select 1 from pg_catalog.pg_trigger where tgname = 'events_validate_rrule' and tgrelid = 'public.events'::regclass) then
    execute 'alter table public.events disable trigger events_validate_rrule';
  end if;
end $$;

create temp table o(c text, note text, expected text, actual text);
create or replace function pg_temp.chk(c text, note text, expected text, tok text default 't1')
returns void language sql as $$ insert into o values (c, note, expected, pg_temp.probe(tok)); $$;

-- ===================== control: a well-formed weekly master ====================
-- A normal one-off Busy 06-03 01:00-02:00Z and an Available window 06-02 00:00-06:00Z
-- are present in every case below; only the master changes.
create or replace function pg_temp.base() returns void language sql as $$
  select pg_temp.ev('ok-one-off','public','busy','2026-06-03 01:00Z','2026-06-03 02:00Z');
  select pg_temp.ev('open','public','available','2026-06-02 00:00Z','2026-06-02 06:00Z');
$$;
select pg_temp.base();
select pg_temp.ev('K12-SECRET','public','busy','2026-05-05 01:00Z','2026-05-05 02:00Z','FREQ=WEEKLY;BYDAY=TU','Asia/Tokyo');
select pg_temp.chk('C0','対照: 正しい毎週火曜 10:00 JST の Busy -> 06-02 01:00Z が Busy、Available はそこだけ削られる',
  'busy T:06-02T01:00/06-02T02:00 T:06-03T01:00/06-03T02:00 | avail T:06-02T00:00/06-02T01:00 T:06-02T02:00/06-02T06:00');
delete from public.events;

-- ===================== the four K12 shapes, timed Busy master ==================
-- The master would cover 06-02 01:00Z if it could be expanded. The server must
-- NOT answer as if it were absent (that would show 01:00-02:00 as free).
create temp table shapes(code text, rr text);
insert into shapes values
  ('Y', 'FREQ=YEARLY'),
  ('U', 'FREQ=DAILY;COUNT=3;UNTIL=20260630T000000Z'),
  ('G', 'garbage'),
  ('B', 'FREQ=WEEKLY;BYDAY=XX');

do $$ declare s record; begin
  for s in select * from shapes order by code loop
    perform pg_temp.base();
    perform pg_temp.ev('K12-SECRET','public','busy','2026-05-05 01:00Z','2026-05-05 02:00Z', s.rr, 'Asia/Tokyo');
    perform pg_temp.chk('T' || s.code, '時刻つき Busy マスター ' || s.rr || ' -> Busy は INCOMPLETE、Available は indeterminate（空きにしない）',
      'busy T:06-03T01:00/06-03T02:00 INCOMPLETE | avail indeterminate');
    perform pg_temp.chk('T' || s.code || 'p', '同、include_private=OFF のリンク（予定は public）-> 同じ',
      'busy T:06-03T01:00/06-03T02:00 INCOMPLETE | avail indeterminate', 't0');
    perform pg_temp.chk('T' || s.code || 'o', '同、share_available=OFF -> Available は要求されない', 'link-not-eligible', 'toff');
    delete from public.events;
  end loop;
end $$;

-- ===================== all-day Busy master ====================================
do $$ declare s record; begin
  for s in select * from shapes order by code loop
    perform pg_temp.ev('ok-one-off','public','busy',null,null,null,null,true,'2026-06-04','2026-06-05');
    perform pg_temp.ev('open','public','available',null,null,null,null,true,'2026-06-02','2026-06-03');
    perform pg_temp.ev('K12-SECRET','public','busy',null,null, s.rr, null, true,'2026-05-05','2026-05-06');
    perform pg_temp.chk('D' || s.code, '終日 Busy マスター ' || s.rr || ' -> Busy は INCOMPLETE、Available は indeterminate',
      'busy D:2026-06-04/2026-06-05 INCOMPLETE | avail indeterminate');
    delete from public.events;
  end loop;
end $$;

-- ===================== Available master =======================================
-- A broken AVAILABLE series must not be read as "no available time" either: the
-- Available answer is indeterminate, and Busy stays complete (an available row
-- never makes Busy incomplete -- 0024 8.1b).
do $$ declare s record; begin
  for s in select * from shapes order by code loop
    perform pg_temp.ev('ok-one-off','public','busy','2026-06-03 01:00Z','2026-06-03 02:00Z');
    perform pg_temp.ev('K12-SECRET','public','available','2026-05-05 01:00Z','2026-05-05 02:00Z', s.rr, 'Asia/Tokyo');
    perform pg_temp.chk('A' || s.code, '時刻つき Available マスター ' || s.rr || ' -> Available は indeterminate、Busy は complete',
      'busy T:06-03T01:00/06-03T02:00 | avail indeterminate');
    delete from public.events;
  end loop;
end $$;

-- ===================== mixed: normal + several broken series ==================
do $$ begin
  perform pg_temp.base();
  perform pg_temp.ev('K12-SECRET','public','busy','2026-05-05 01:00Z','2026-05-05 02:00Z','FREQ=YEARLY','Asia/Tokyo');
  perform pg_temp.ev('K12-SECRET','public','busy','2026-05-06 03:00Z','2026-05-06 04:00Z','garbage','Asia/Tokyo');
  perform pg_temp.ev('ok-weekly','public','busy','2026-05-07 05:00Z','2026-05-07 06:00Z','FREQ=WEEKLY;BYDAY=TH','Asia/Tokyo');
end $$;
select pg_temp.chk('M1','正常な単発・正常な毎週・不正2件の混在 -> 正常分は Busy に出るが INCOMPLETE、Available は indeterminate',
  'busy T:06-03T01:00/06-03T02:00 T:06-04T05:00/06-04T06:00 INCOMPLETE | avail indeterminate');

-- ===================== the real wrapper, as anon ===============================
create temp table w(c text, j jsonb);
grant insert on w to anon;
set local role anon;
insert into w select 'W1', public.get_free_busy('t1', '2026-06-01 00:00Z', '2026-06-08 00:00Z', '2026-06-01', '2026-06-08');
reset role;
insert into o select 'W1','実RPC(anon): 混在 -> link active・Busy INCOMPLETE・Available indeterminate（slots なし）',
  'active|false|indeterminate|no-slots',
  (j ->> 'link_state') || '|' || (j ->> 'complete') || '|' || (j -> 'available' ->> 'status')
  || '|' || case when j -> 'available' ? 'slots' then 'slots' else 'no-slots' end from w where c = 'W1';
insert into o select 'W1b','実RPC: 予定のタイトル・本文・カテゴリ・規則が応答に無い',
  'false', (j::text ~ 'K12-SECRET|ok-weekly|ok-one-off|"title"|"description"|"category"|rrule|FREQ|garbage')::text from w where c = 'W1';
insert into o select 'W1c','実RPC: 枠のキーは all_day/start/end/start_date/end_date だけ',
  'true', coalesce((select bool_and(k in ('all_day','start','end','start_date','end_date'))
     from (select jsonb_object_keys(s) k from jsonb_array_elements(j -> 'slots') s) x), true)::text
  from w where c = 'W1';
delete from public.events;

\echo ''
select c, case when expected is not distinct from actual then 'ok' else 'FAIL' end as status, note, expected, actual
from o
union all
select 'ZZZ', case when count(*) filter (where expected is distinct from actual) = 0 then 'ok' else 'FAIL' end,
       'FAIL rows (GO requires 0)', '0', (count(*) filter (where expected is distinct from actual))::text
from o
order by 1;
rollback;
