-- ============================================================================
-- P8-c2 RUNTIME SUITE -- recurring series on DST days, through the real Free/Busy
-- objects. Read-mostly: everything is rolled back. No migration is involved.
--
-- WHAT IT PINS. The CURRENT rule for a timed master with a zone (0009/0018):
-- an occurrence whose wall clock happens twice takes the LATER instant; one
-- whose wall clock does not exist takes the later candidate (pushed forward by
-- the jump). The client expander does the same (src/services/recurrenceDst.test.ts
-- has the same instants). Each row states the exact Busy and Available answer.
--
-- WHAT IT PROVES FOR PRIVACY. On every DST case the Busy occurrence is where
-- the owner's calendar shows it, Available is cut by it, exceptions detach
-- exactly their own occurrence, and an exception the server cannot place
-- makes the answer incomplete / indeterminate instead of opening a free slot.
--
-- Runs identically with or without 0027 (that migration only changes the
-- all-day boundary on a doubled MIDNIGHT; no row here depends on one in the
-- cross-model path). Run on the isolated DB only:
--   psql -h 127.0.0.1 -p 5433 -U postgres -d <db> -X -f supabase/tests/P8c2_recurrence_dst_test.sql
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off
begin;
set local timezone = 'UTC';
\set owner '''5e86935f-7661-4741-868f-0f51c4cf1727'''

do $$ begin
  if not exists (select 1 from auth.users where id = '5e86935f-7661-4741-868f-0f51c4cf1727') then
    raise exception 'canonical test owner missing from auth.users -- wrong database?';
  end if;
  if exists (select 1 from public.events where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727')
     or exists (select 1 from public.owner_settings where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727') then
    raise exception 'the test owner already has rows -- refusing to run on a database in use';
  end if;
  -- the tzdata facts every expectation below rests on
  if ('2026-11-01 05:30Z'::timestamptz at time zone 'America/New_York') <> '2026-11-01 01:30'
     or ('2026-11-01 06:30Z'::timestamptz at time zone 'America/New_York') <> '2026-11-01 01:30'
     or ('2026-03-08 06:59Z'::timestamptz at time zone 'America/New_York') <> '2026-03-08 01:59'
     or ('2026-03-08 07:00Z'::timestamptz at time zone 'America/New_York') <> '2026-03-08 03:00'
     or ('2026-11-01 04:30Z'::timestamptz at time zone 'America/Havana') <> '2026-11-01 00:30'
     or ('2026-11-01 05:30Z'::timestamptz at time zone 'America/Havana') <> '2026-11-01 00:30'
     or ('2026-03-08 05:00Z'::timestamptz at time zone 'America/Havana') <> '2026-03-08 01:00'
     or ('2026-10-25 00:30Z'::timestamptz at time zone 'Atlantic/Azores') <> '2026-10-25 00:30'
     or ('2026-10-25 01:30Z'::timestamptz at time zone 'Atlantic/Azores') <> '2026-10-25 00:30'
     or ('2026-03-29 00:59Z'::timestamptz at time zone 'America/Godthab') <> '2026-03-28 22:59'
     or ('2026-03-29 01:00Z'::timestamptz at time zone 'America/Godthab') <> '2026-03-29 00:00' then
    raise exception 'this server''s tzdata does not have the transitions this suite is written for';
  end if;
end $$;

create or replace function pg_temp.mk(tok text, ip boolean, sa boolean) returns void language sql as $$
  insert into public.share_links (owner_id, token_hash, include_private, share_available)
  values ('5e86935f-7661-4741-868f-0f51c4cf1727', encode(extensions.digest(tok,'sha256'),'hex'), ip, sa);
$$;
select pg_temp.mk('t1', true, true);
select pg_temp.mk('t0', false, true);
select pg_temp.mk('toff', true, false);

-- one master / one row; returns its id
create or replace function pg_temp.ev(ttl text, vis text, av text, sa timestamptz, ea timestamptz,
  rr text default null, tz text default null, ad boolean default false, sd date default null, ed date default null)
returns uuid language sql as $$
  insert into public.events (owner_id,title,visibility,availability,all_day,start_at,end_at,start_date,end_date,rrule,timezone)
  values ('5e86935f-7661-4741-868f-0f51c4cf1727',ttl,vis,av,ad,sa,ea,sd,ed,rr,tz) returning id;
$$;
-- an exception row on master m, as the app writes it (slot = the generated instant)
create or replace function pg_temp.ex(m uuid, slot timestamptz, cancelled boolean, sa timestamptz, ea timestamptz)
returns void language sql as $$
  insert into public.events (owner_id,title,visibility,availability,all_day,start_at,end_at,recurrence_id,recurrence_slot_start,is_cancelled)
  select owner_id, case when cancelled then '' else 'moved' end, visibility, availability, false, sa, ea, id, slot, cancelled
  from public.events where id = m;
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
-- "busy <slots> <complete|INCOMPLETE> | avail <status or slots>"
create or replace function pg_temp.probe(tok text, f timestamptz, t timestamptz, fd date, td date)
returns text language sql as $$
  select coalesce(
    (select 'busy ' || pg_temp.norm(c.r -> 'slots')
            || case when (c.r -> 'complete')::boolean then '' else ' INCOMPLETE' end
            || ' | avail ' || case when a.r ->> 'status' = 'complete' then pg_temp.norm(a.r -> 'slots') else a.r ->> 'status' end
       from public.share_links lk,
            timeweave_private.free_busy_core(lk.id, f, t, fd, td) as c(r),
            lateral timeweave_private.free_busy_available(lk.id, f, t, fd, td, c.r) as a(r)
      where lk.token_hash = encode(extensions.digest(tok,'sha256'),'hex') and lk.share_available),
    'link-not-eligible');
$$;
create temp table o(c text, note text, expected text, actual text);
create or replace function pg_temp.chk(c text, note text, expected text, tok text,
  f timestamptz, t timestamptz, fd date, td date)
returns void language sql as $$ insert into o values (c, note, expected, pg_temp.probe(tok, f, t, fd, td)); $$;
-- windows: the New York week of the autumn switch, and of the spring switch
create or replace function pg_temp.nyf(c text, note text, expected text, tok text default 't1') returns void language sql as $$
  select pg_temp.chk(c, note, expected, tok, '2026-10-26 04:00Z', '2026-11-02 05:00Z', '2026-10-26', '2026-11-02'); $$;
create or replace function pg_temp.nys(c text, note text, expected text, tok text default 't1') returns void language sql as $$
  select pg_temp.chk(c, note, expected, tok, '2026-03-02 05:00Z', '2026-03-09 04:00Z', '2026-03-02', '2026-03-09'); $$;

-- ===================== New York, autumn fold (Sunday 2026-11-01) ==============
-- weekly Sunday 01:30-02:00 Busy, DTSTART 2026-10-18 01:30 EDT; Available 01:00 EDT .. 03:00 EST.
do $$ declare m uuid; begin
  m := pg_temp.ev('R1S-SECRET','public','busy','2026-10-18 05:30Z','2026-10-18 06:00Z','FREQ=WEEKLY;BYDAY=SU','America/New_York');
  perform pg_temp.ev('a','public','available','2026-11-01 05:00Z','2026-11-01 08:00Z');
end $$;
select pg_temp.nyf('F1','秋の二重時刻: 毎週日曜01:30 の11/1回は2回目(06:30Z)。Availableはその30分だけ削られる',
  'busy T:11-01T06:30/11-01T07:00 | avail T:11-01T05:00/11-01T06:30 T:11-01T07:00/11-01T08:00');
select pg_temp.nyf('F1b','同 include_private=OFF（予定は public）-> 同じ',
  'busy T:11-01T06:30/11-01T07:00 | avail T:11-01T05:00/11-01T06:30 T:11-01T07:00/11-01T08:00', 't0');
select pg_temp.nyf('F1c','同 share_available=OFF -> Available は要求されない', 'link-not-eligible', 'toff');
-- delete the fold occurrence (slot = the generated instant)
select pg_temp.ex((select id from public.events where title = 'R1S-SECRET'), '2026-11-01 06:30Z', true, '2026-11-01 06:30Z', '2026-11-01 07:00Z');
select pg_temp.nyf('F2','その回を削除（slot=06:30Z）-> Busy なし、Available は全部',
  'busy (none) | avail T:11-01T05:00/11-01T08:00');
delete from public.events where recurrence_id is not null;
-- move it to 04:00-04:30 EST
select pg_temp.ex((select id from public.events where title = 'R1S-SECRET'), '2026-11-01 06:30Z', false, '2026-11-01 09:00Z', '2026-11-01 09:30Z');
select pg_temp.nyf('F3','その回を04:00 ESTへ移動 -> Busy は移動先だけ、元の時間は空く',
  'busy T:11-01T09:00/11-01T09:30 | avail T:11-01T05:00/11-01T08:00');
delete from public.events where recurrence_id is not null;
-- a slot the server cannot place (the OTHER 01:30): fail closed
select pg_temp.ex((select id from public.events where title = 'R1S-SECRET'), '2026-11-01 05:30Z', true, '2026-11-01 05:30Z', '2026-11-01 06:00Z');
select pg_temp.nyf('F4','1回目(05:30Z)を指す例外 = 置けない slot -> Busy は INCOMPLETE、Available は indeterminate（空きにしない）',
  'busy T:11-01T06:30/11-01T07:00 INCOMPLETE | avail indeterminate');
delete from public.events;

-- the visibility of the MASTER decides, per link, independently of availability
do $$ begin
  perform pg_temp.ev('p','private','busy','2026-10-18 05:30Z','2026-10-18 06:00Z','FREQ=WEEKLY;BYDAY=SU','America/New_York');
  perform pg_temp.ev('a','public','available','2026-11-01 05:00Z','2026-11-01 08:00Z');
end $$;
select pg_temp.nyf('V1','private の繰り返し Busy / include_private=ON -> 2回目01:30がBusy',
  'busy T:11-01T06:30/11-01T07:00 | avail T:11-01T05:00/11-01T06:30 T:11-01T07:00/11-01T08:00');
select pg_temp.nyf('V2','同 include_private=OFF -> 共有されない（既存の契約）',
  'busy (none) | avail T:11-01T05:00/11-01T08:00', 't0');
update public.events set visibility = 'busy_only' where title = 'p';
select pg_temp.nyf('V3','busy_only の繰り返し Busy / include_private=OFF -> Busy として効く',
  'busy T:11-01T06:30/11-01T07:00 | avail T:11-01T05:00/11-01T06:30 T:11-01T07:00/11-01T08:00', 't0');
delete from public.events;

-- an AVAILABLE recurring master on the fold, cut by a one-off Busy
do $$ begin
  perform pg_temp.ev('ar','public','available','2026-10-18 05:30Z','2026-10-18 06:00Z','FREQ=WEEKLY;BYDAY=SU','America/New_York');
  perform pg_temp.ev('b','public','busy','2026-11-01 06:30Z','2026-11-01 06:45Z');
end $$;
select pg_temp.nyf('A1','Available の繰り返しも2回目01:30。Busy 06:30-06:45 に削られる（Busy優先）',
  'busy T:11-01T06:30/11-01T06:45 | avail T:11-01T06:45/11-01T07:00');
delete from public.events;

-- ===================== New York, spring gap (Sunday 2026-03-08) ===============
do $$ begin
  perform pg_temp.ev('g','public','busy','2026-02-22 07:30Z','2026-02-22 08:00Z','FREQ=WEEKLY;BYDAY=SU','America/New_York');
  perform pg_temp.ev('a','public','available','2026-03-08 06:00Z','2026-03-08 09:00Z');
end $$;
select pg_temp.nys('S1','春の欠落: 毎週日曜02:30 の3/8回は03:30 EDT(07:30Z)。Availableはその30分だけ削られる',
  'busy T:03-08T07:30/03-08T08:00 | avail T:03-08T06:00/03-08T07:30 T:03-08T08:00/03-08T09:00');
select pg_temp.ex((select id from public.events where title = 'g'), '2026-03-08 07:30Z', true, '2026-03-08 07:30Z', '2026-03-08 08:00Z');
select pg_temp.nys('S2','その回を削除（slot=07:30Z）-> Busy なし', 'busy (none) | avail T:03-08T06:00/03-08T09:00');
delete from public.events;

-- ===================== midnight switches =====================================
do $$ begin
  perform pg_temp.ev('h1','public','busy','2026-02-22 05:30Z','2026-02-22 06:00Z','FREQ=WEEKLY;BYDAY=SU','America/Havana');
end $$;
select pg_temp.chk('M1','Havana 毎週日曜00:30、3/8（0時台が無い）-> 01:30 CDT の同じ日曜',
  'busy T:03-08T05:30/03-08T06:00 | avail (none)', 't1', '2026-03-02 05:00Z', '2026-03-09 04:00Z', '2026-03-02', '2026-03-09');
delete from public.events;
do $$ begin
  perform pg_temp.ev('h2','public','busy','2026-10-18 04:30Z','2026-10-18 05:00Z','FREQ=WEEKLY;BYDAY=SU','America/Havana');
end $$;
select pg_temp.chk('M2','Havana 毎週日曜00:30、11/1（0時台が2回）-> 2回目(05:30Z)',
  'busy T:11-01T05:30/11-01T06:00 | avail (none)', 't1', '2026-10-26 04:00Z', '2026-11-02 05:00Z', '2026-10-26', '2026-11-02');
delete from public.events;
do $$ begin
  perform pg_temp.ev('z','public','busy','2026-10-11 00:30Z','2026-10-11 01:00Z','FREQ=WEEKLY;BYDAY=SU','Atlantic/Azores');
end $$;
select pg_temp.chk('M3','Azores 毎週日曜00:30、10/25（0時台が2回）-> 2回目(01:30Z)',
  'busy T:10-25T01:30/10-25T02:00 | avail (none)', 't1', '2026-10-19 00:00Z', '2026-10-26 01:00Z', '2026-10-19', '2026-10-26');
delete from public.events;
do $$ begin
  perform pg_temp.ev('n','public','busy','2026-03-15 01:30Z','2026-03-15 02:00Z','FREQ=WEEKLY;BYDAY=SA','America/Godthab');
end $$;
select pg_temp.chk('M4','Nuuk 毎週土曜23:30、3/28 23:00→3/29 00:00 の欠落 -> 日曜 00:30(01:30Z)（現行規則・曜日が変わる）',
  'busy T:03-29T01:30/03-29T02:00 | avail (none)', 't1', '2026-03-23 02:00Z', '2026-03-30 01:00Z', '2026-03-23', '2026-03-30');
delete from public.events;

-- ===================== ordinary zone, and all-day =============================
do $$ begin
  perform pg_temp.ev('t','public','busy','2026-02-22 00:00Z','2026-02-22 01:00Z','FREQ=WEEKLY;BYDAY=SU','Asia/Tokyo');
end $$;
select pg_temp.chk('N1','Tokyo 毎週日曜09:00（DSTなし）', 'busy T:03-08T00:00/03-08T01:00 | avail (none)',
  't1', '2026-03-01 15:00Z', '2026-03-08 15:00Z', '2026-03-02', '2026-03-09');
delete from public.events;
insert into public.owner_settings (owner_id, timezone) values (:owner, 'America/New_York');
do $$ begin
  perform pg_temp.ev('ad','public','busy',null,null,'FREQ=WEEKLY;BYDAY=SU',null,true,'2026-10-18','2026-10-19');
  perform pg_temp.ev('a','public','available','2026-11-01 03:30Z','2026-11-01 04:30Z');
end $$;
select pg_temp.nyf('D1','終日の毎週日曜Busy: 11/1 は日付のまま。所有者ゾーンの0時(04:00Z)で時刻Availableを切る',
  'busy D:2026-11-01/2026-11-02 | avail T:11-01T03:30/11-01T04:00');
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
