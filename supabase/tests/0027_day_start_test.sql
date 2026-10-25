-- ============================================================================
-- 0027 RUNTIME SUITE -- R1-S through the real objects, all rolled back.
--
-- WHAT IT ASSERTS. Every row carries the EXPECTED Available answer, written as
-- exact UTC instants from the rule "calendar day D starts at the FIRST instant
-- whose local date is D" (docs/p8-datetime-contract.md §9/§11), and the summary
-- row counts mismatches. Run it:
--   * BEFORE 0027 -> the S/V/Z rows marked [R1-S] FAIL (that is the bug,
--     reproduced through the real helper); every other row passes.
--   * AFTER 0027  -> every row passes (ZZZ = 0).
--
-- THE PASS CONDITION IS PRIVACY, NOT FEWER SLOTS. Each expectation was derived
-- from what the owner declared and what Busy covers, by hand, per case:
-- Available may appear only where the owner declared it, the link opted in
-- (share_available), visibility allows it (private needs include_private),
-- and NO Busy -- timed or all-day, in the owner's zone -- covers it.
--
-- DATA. One fictional owner (the chain DB's canonical test owner, which the
-- suite asserts exists and never writes to auth.users), fictional titles. The
-- owner's zone is the variable under test. Everything is rolled back.
--
-- HOW. Like 0025_crossmodel_test.sql, most rows call free_busy_core +
-- free_busy_available directly (the wrapper charges 0019's rate buckets per
-- call). The W rows go through the real public.get_free_busy AS anon, once per
-- link, to prove the wrapper path, the link states and the response contents.
--
-- RUN (isolated DB only; never production):
--   psql -h 127.0.0.1 -p 5433 -U postgres -d <db> -X -f supabase/tests/0027_day_start_test.sql
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
end $$;

create or replace function pg_temp.mk(tok text, ip boolean, sa boolean,
  rev timestamptz default null, exp timestamptz default null) returns void language sql as $$
  -- created two days ago, so an expiry in the past still satisfies share_links_expiry_after_created
  insert into public.share_links (owner_id, token_hash, include_private, share_available, revoked_at, expires_at, created_at)
  values ('5e86935f-7661-4741-868f-0f51c4cf1727', encode(extensions.digest(tok,'sha256'),'hex'), ip, sa, rev, exp,
          now() - interval '2 days');
$$;
select pg_temp.mk('t1', true, true);                 -- include_private ON,  share_available ON
select pg_temp.mk('t0', false, true);                -- include_private OFF, share_available ON
select pg_temp.mk('toff', true, false);              -- share_available OFF
select pg_temp.mk('trev', true, true, now());        -- revoked
select pg_temp.mk('texp', true, true, null, now() - interval '1 day');  -- expired
select pg_temp.mk('w1', true, true);                 -- wrapper-only links, one call each
select pg_temp.mk('w0', false, true);

create or replace function pg_temp.ev(ttl text, vis text, av text, ad boolean,
  sa timestamptz, ea timestamptz, sd date, ed date)
returns void language sql as $$
  insert into public.events (owner_id,title,description,category,visibility,availability,all_day,
    start_at,end_at,start_date,end_date)
  values ('5e86935f-7661-4741-868f-0f51c4cf1727', ttl, 'R1S-SECRET-MEMO', 'R1S-SECRET-CAT',
          vis, av, ad, sa, ea, sd, ed);
$$;

-- Available as one comparable string: D:<start_date>/<end_date> or T:<start>/<end> (UTC, minutes).
create or replace function pg_temp.norm(a jsonb) returns text language sql as $$
  select case
    when a ->> 'status' <> 'complete' then a ->> 'status'
    else coalesce((
      select string_agg(
               case when (s -> 'all_day')::boolean
                    then 'D:' || (s ->> 'start_date') || '/' || (s ->> 'end_date')
                    else 'T:' || to_char((s ->> 'start')::timestamptz at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI')
                         || '/' || to_char((s ->> 'end')::timestamptz at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI')
               end, ' ' order by ord)
      from jsonb_array_elements(a -> 'slots') with ordinality as e(s, ord)), '(none)')
  end
$$;

create or replace function pg_temp.probe(tok text, f timestamptz, t timestamptz, fd date, td date)
returns text language sql as $$
  select coalesce(
    (select pg_temp.norm(a.r)
       from public.share_links lk,
            timeweave_private.free_busy_core(lk.id, f, t, fd, td) as c(r),
            lateral timeweave_private.free_busy_available(lk.id, f, t, fd, td, c.r) as a(r)
      where lk.token_hash = encode(extensions.digest(tok,'sha256'),'hex')
        and lk.revoked_at is null and (lk.expires_at is null or lk.expires_at > now())
        and lk.share_available),
    'link-not-eligible');
$$;

create temp table o(c text, note text, expected text, actual text);
create or replace function pg_temp.chk(c text, note text, expected text, tok text,
  f timestamptz, t timestamptz, fd date, td date)
returns void language sql as $$ insert into o values (c, note, expected, pg_temp.probe(tok, f, t, fd, td)); $$;
-- The Havana week around the 2026-11-01 fold. 10-26 00:00 CDT .. 11-03 00:00 CST.
create or replace function pg_temp.hv(c text, note text, expected text, tok text default 't1')
returns void language sql as $$
  select pg_temp.chk(c, note, expected, tok, '2026-10-26 04:00Z', '2026-11-03 05:00Z', '2026-10-26', '2026-11-03');
$$;

-- ============================ owner zone: America/Havana ====================
-- tzdata fact the expectations rest on (checked, not assumed): 2026-11-01 00:00
-- happens at 04:00Z (CDT) and again at 05:00Z (CST); 03-08 00:00 never happens.
do $$ begin
  if ('2026-11-01 04:00Z'::timestamptz at time zone 'America/Havana') <> '2026-11-01 00:00'
     or ('2026-11-01 05:00Z'::timestamptz at time zone 'America/Havana') <> '2026-11-01 00:00'
     or ('2026-11-01 03:59:59Z'::timestamptz at time zone 'America/Havana') <> '2026-10-31 23:59:59'
     or ('2026-03-08 04:59:59Z'::timestamptz at time zone 'America/Havana') <> '2026-03-07 23:59:59'
     or ('2026-03-08 05:00Z'::timestamptz at time zone 'America/Havana') <> '2026-03-08 01:00' then
    raise exception 'this server''s tzdata does not have the Havana transitions this suite is written for';
  end if;
end $$;
insert into public.owner_settings (owner_id, timezone) values (:owner, 'America/Havana');

-- S1 [R1-S] all-day Busy on 11-01 x timed Available around the FIRST midnight.
--   A 03:00-03:30Z  10-31 23:00 CDT   before the day          -> stays
--   B 03:50-04:10Z  straddles the first midnight              -> cut to 03:50-04:00
--   C 04:15-04:45Z  11-01 00:15 (first)                       -> gone   (0025 published it)
--   D 05:10-05:20Z  11-01 00:10 (second)                      -> gone
--   E 11-02 04:50-05:10Z straddles the END of 11-01 (11-02 00:00 CST = 05:00Z) -> 05:00-05:10
select pg_temp.ev('R1S-SECRET-TITLE','public','busy',true,null,null,'2026-11-01','2026-11-02');
select pg_temp.ev('a','public','available',false,'2026-11-01 03:00Z','2026-11-01 03:30Z',null,null);
select pg_temp.ev('b','public','available',false,'2026-11-01 03:50Z','2026-11-01 04:10Z',null,null);
select pg_temp.ev('c','public','available',false,'2026-11-01 04:15Z','2026-11-01 04:45Z',null,null);
select pg_temp.ev('d','public','available',false,'2026-11-01 05:10Z','2026-11-01 05:20Z',null,null);
select pg_temp.ev('e','public','available',false,'2026-11-02 04:50Z','2026-11-02 05:10Z',null,null);
select pg_temp.hv('S1','[R1-S] 11/1 終日busy x 1回目の0時台の時刻available（直前・またぎ・内側・2回目・終端）',
  'T:2026-11-01T03:00/2026-11-01T03:30 T:2026-11-01T03:50/2026-11-01T04:00 T:2026-11-02T05:00/2026-11-02T05:10');
-- the viewer's zone must not matter: same dates, windows sent at other offsets (UTC, +14, -11)
select pg_temp.chk('V9a','閲覧者ゾーン≠所有者: 窓をUTCで送る（S1と同じ答え）',
  'T:2026-11-01T03:00/2026-11-01T03:30 T:2026-11-01T03:50/2026-11-01T04:00 T:2026-11-02T05:00/2026-11-02T05:10',
  't1', '2026-10-26 00:00Z', '2026-11-03 00:00Z', '2026-10-26', '2026-11-03');
select pg_temp.chk('V9b','閲覧者ゾーン≠所有者: 窓を+14で送る',
  'T:2026-11-01T03:00/2026-11-01T03:30 T:2026-11-01T03:50/2026-11-01T04:00 T:2026-11-02T05:00/2026-11-02T05:10',
  't1', '2026-10-25 10:00Z', '2026-11-03 10:00Z', '2026-10-26', '2026-11-03');
select pg_temp.chk('V9c','閲覧者ゾーン≠所有者: 窓を-11で送る',
  'T:2026-11-01T03:00/2026-11-01T03:30 T:2026-11-01T03:50/2026-11-01T04:00 T:2026-11-02T05:00/2026-11-02T05:10',
  't1', '2026-10-26 11:00Z', '2026-11-03 11:00Z', '2026-10-26', '2026-11-03');

-- W rows: the same data through the real wrapper, as anon. Contents are checked below.
create temp table w(c text, j jsonb);
grant insert on w to anon;
set local role anon;
insert into w select 'W1', public.get_free_busy('w1', '2026-10-26 04:00Z', '2026-11-03 05:00Z', '2026-10-26', '2026-11-03');
insert into w select 'W2', public.get_free_busy('toff', '2026-10-26 04:00Z', '2026-11-03 05:00Z', '2026-10-26', '2026-11-03');
insert into w select 'W3', public.get_free_busy('trev', '2026-10-26 04:00Z', '2026-11-03 05:00Z', '2026-10-26', '2026-11-03');
insert into w select 'W4', public.get_free_busy('texp', '2026-10-26 04:00Z', '2026-11-03 05:00Z', '2026-10-26', '2026-11-03');
-- anon must not reach the helper or the new function directly
do $$ begin
  begin
    perform timeweave_private.zoned_day_start(date '2026-11-01', 'America/Havana');
    raise exception 'anon could execute zoned_day_start';
  exception when insufficient_privilege or undefined_function or invalid_schema_name then null;
  end;
  begin
    perform timeweave_private.free_busy_available(gen_random_uuid(), now(), now() + interval '1 day',
      current_date, current_date + 1, '{}'::jsonb);
    raise exception 'anon could execute free_busy_available';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
insert into o select 'W1','実RPC(anon): S1と同じ答え',
  'T:2026-11-01T03:00/2026-11-01T03:30 T:2026-11-01T03:50/2026-11-01T04:00 T:2026-11-02T05:00/2026-11-02T05:10',
  pg_temp.norm(j -> 'available') from w where c = 'W1';
insert into o select 'W1b','実RPC: busy は終日11/1のまま（Busyの答えは不変）',
  '[{"all_day": true, "end_date": "2026-11-02", "start_date": "2026-11-01"}]', (j -> 'slots')::text from w where c = 'W1';
insert into o select 'W1c','実RPC: タイトル・メモ・カテゴリが応答に無い',
  'false', (j::text ~ 'R1S-SECRET|"title"|"description"|"category"')::text from w where c = 'W1';
insert into o select 'W1d','実RPC: 枠のキーは all_day/start/end/start_date/end_date だけ',
  'true', coalesce((select bool_and(k in ('all_day','start','end','start_date','end_date'))
     from (select jsonb_object_keys(s) k from jsonb_array_elements((j -> 'slots') || (j -> 'available' -> 'slots')) s) x), true)::text
  from w where c = 'W1';
insert into o select 'W2','実RPC: share_available=OFF -> not_requested', 'active|not_requested',
  (j ->> 'link_state') || '|' || (j -> 'available' ->> 'status') from w where c = 'W2';
insert into o select 'W3','実RPC: 失効リンク -> unavailable', 'unavailable|no-available-key|0',
  (j ->> 'link_state') || '|' || case when j ? 'available' then 'available-key' else 'no-available-key' end || '|' || jsonb_array_length(j -> 'slots') from w where c = 'W3';
insert into o select 'W4','実RPC: 期限切れリンク -> unavailable', 'unavailable|no-available-key|0',
  (j ->> 'link_state') || '|' || case when j ? 'available' then 'available-key' else 'no-available-key' end || '|' || jsonb_array_length(j -> 'slots') from w where c = 'W4';
delete from public.events;

-- S2 [R1-S] all-day Busy on 10-31 x Available in 11-01's FIRST hour.
--   C 04:15-04:45Z is 11-01 by the wall clock: declared, public, opted in, and no
--   Busy covers it -> published. 0025 hid it behind 10-31's Busy.
--   F 03:40-03:50Z is 10-31 23:40: covered by 10-31's Busy -> gone (both versions).
select pg_temp.ev('R1S-SECRET-TITLE','public','busy',true,null,null,'2026-10-31','2026-11-01');
select pg_temp.ev('c','public','available',false,'2026-11-01 04:15Z','2026-11-01 04:45Z',null,null);
select pg_temp.ev('f','public','available',false,'2026-11-01 03:40Z','2026-11-01 03:50Z',null,null);
select pg_temp.hv('S2','[R1-S] 10/31 終日busy x 11/1 1回目0時台のavailable -> 正当な空きだけ出る',
  'T:2026-11-01T04:15/2026-11-01T04:45');
select pg_temp.hv('S2b','同 share_available=OFF のリンク -> 何も出ない', 'link-not-eligible', 'toff');
delete from public.events;

-- S3 [R1-S] all-day Available on 10-31 x timed Busy 10-31 10:00-11:00 CDT.
--   The fragments must end at 11-01's FIRST midnight (04:00Z); 0025 ran to 05:00Z,
--   publishing an hour of 11-01 the owner never declared.
select pg_temp.ev('R1S-SECRET-TITLE','public','available',true,null,null,'2026-10-31','2026-11-01');
select pg_temp.ev('bt','public','busy',false,'2026-10-31 14:00Z','2026-10-31 15:00Z',null,null);
select pg_temp.hv('S3','[R1-S] 10/31 終日available x 10/31 時刻busy -> 断片は1回目の0時で終わる',
  'T:2026-10-31T04:00/2026-10-31T14:00 T:2026-10-31T15:00/2026-11-01T04:00');
delete from public.events;

-- S4 [R1-S] all-day Available on 11-01 x timed Busy in the first 00:xx hour.
select pg_temp.ev('R1S-SECRET-TITLE','public','available',true,null,null,'2026-11-01','2026-11-02');
select pg_temp.ev('bt','public','busy',false,'2026-11-01 04:30Z','2026-11-01 04:50Z',null,null);
select pg_temp.hv('S4','[R1-S] 11/1 終日available x 1回目00:30の時刻busy -> 日が削られる',
  'T:2026-11-01T04:00/2026-11-01T04:30 T:2026-11-01T04:50/2026-11-02T05:00');
delete from public.events where title = 'bt';
select pg_temp.ev('bt','public','busy',false,'2026-11-01 05:10Z','2026-11-01 05:20Z',null,null);
select pg_temp.hv('S4b','[R1-S] 同 2回目00:10の時刻busy -> 1回目の0時台も日の一部',
  'T:2026-11-01T04:00/2026-11-01T05:10 T:2026-11-01T05:20/2026-11-02T05:00');
delete from public.events where title = 'bt';
select pg_temp.ev('bt','public','busy',false,'2026-11-01 03:00Z','2026-11-01 04:00Z',null,null);
select pg_temp.hv('S4c','境界ちょうど: busy が1回目の0時で終わる -> 日は触られず終日のまま',
  'D:2026-11-01/2026-11-02');
delete from public.events where title = 'bt';
select pg_temp.ev('bt','public','busy',false,'2026-11-02 05:00Z','2026-11-02 05:30Z',null,null);
select pg_temp.hv('S4d','境界ちょうど: busy が翌日の0時に始まる -> 終日のまま',
  'D:2026-11-01/2026-11-02');
delete from public.events;

-- V: visibility x include_private, on the S1 shape (Busy all day 11-01, Available C)
select pg_temp.ev('R1S-SECRET-TITLE','private','busy',true,null,null,'2026-11-01','2026-11-02');
select pg_temp.ev('c','public','available',false,'2026-11-01 04:15Z','2026-11-01 04:45Z',null,null);
select pg_temp.hv('V1','busy=private / ip=OFF: そのBusyは共有されない（既存契約）-> C は出る',
  'T:2026-11-01T04:15/2026-11-01T04:45', 't0');
select pg_temp.hv('V2','[R1-S] busy=private / ip=ON: Busy優先 -> C は出ない', '(none)', 't1');
delete from public.events;
select pg_temp.ev('R1S-SECRET-TITLE','public','busy',true,null,null,'2026-11-01','2026-11-02');
select pg_temp.ev('c','private','available',false,'2026-11-01 04:15Z','2026-11-01 04:45Z',null,null);
select pg_temp.hv('V3','available=private / ip=OFF -> 出ない', '(none)', 't0');
select pg_temp.hv('V4','[R1-S] available=private / ip=ON / Busy終日 -> 出ない', '(none)', 't1');
delete from public.events;
select pg_temp.ev('R1S-SECRET-TITLE','busy_only','busy',true,null,null,'2026-11-01','2026-11-02');
select pg_temp.ev('c','public','available',false,'2026-11-01 04:15Z','2026-11-01 04:45Z',null,null);
select pg_temp.hv('V5','[R1-S] busy=busy_only / ip=OFF: busy_only は Busy として効く -> 出ない', '(none)', 't0');
delete from public.events;
select pg_temp.ev('R1S-SECRET-TITLE','public','busy',true,null,null,'2026-11-01','2026-11-02');
select pg_temp.ev('c','busy_only','available',false,'2026-11-01 04:15Z','2026-11-01 04:45Z',null,null);
select pg_temp.hv('V6','[R1-S] available=busy_only / ip=OFF / Busy終日 -> 出ない', '(none)', 't0');
select pg_temp.ev('g','busy_only','available',false,'2026-10-30 16:00Z','2026-10-30 17:00Z',null,null);
-- C (from V6) is still there: only g may come out.
select pg_temp.hv('V7','[R1-S] available=busy_only: Busyの無い日の g だけ出る、11/1 の C は出ない（visibilityとavailabilityは独立）',
  'T:2026-10-30T16:00/2026-10-30T17:00', 't0');
delete from public.events;

-- G: a MISSING midnight (Havana 2026-03-08) -- 0025 and 0027 must agree.
select pg_temp.ev('R1S-SECRET-TITLE','public','busy',true,null,null,'2026-03-08','2026-03-09');
select pg_temp.ev('p','public','available',false,'2026-03-08 04:30Z','2026-03-08 04:50Z',null,null);
select pg_temp.ev('q','public','available',false,'2026-03-08 05:00Z','2026-03-08 05:30Z',null,null);
select pg_temp.chk('G1','深夜が無い日(3/8): 前日23:30は出る / 3/8 01:00は出ない（0025と同じ）',
  'T:2026-03-08T04:30/2026-03-08T04:50', 't1', '2026-03-02 05:00Z', '2026-03-10 04:00Z', '2026-03-02', '2026-03-10');
delete from public.events;

-- N: an ordinary day in the same zone -- unchanged.
select pg_temp.ev('R1S-SECRET-TITLE','public','busy',true,null,null,'2026-10-28','2026-10-29');
select pg_temp.ev('r','public','available',false,'2026-10-28 03:30Z','2026-10-28 04:30Z',null,null);
select pg_temp.hv('N1','通常日(10/28) 終日busy x 前日から続くavailable -> 0時で切れる', 'T:2026-10-28T03:30/2026-10-28T04:00');
delete from public.events;

-- ============================ owner zone: Atlantic/Azores ===================
-- 2026-10-25 00:00 happens at 00:00Z (+00) and again at 01:00Z (-01).
do $$ begin
  if ('2026-10-25 00:00Z'::timestamptz at time zone 'Atlantic/Azores') <> '2026-10-25 00:00'
     or ('2026-10-25 01:00Z'::timestamptz at time zone 'Atlantic/Azores') <> '2026-10-25 00:00' then
    raise exception 'this server''s tzdata does not have the Azores fold this suite is written for';
  end if;
end $$;
update public.owner_settings set timezone = 'Atlantic/Azores' where owner_id = :owner;
select pg_temp.ev('R1S-SECRET-TITLE','public','busy',true,null,null,'2026-10-25','2026-10-26');
select pg_temp.ev('z1','public','available',false,'2026-10-25 00:15Z','2026-10-25 00:45Z',null,null);
select pg_temp.ev('z2','public','available',false,'2026-10-25 01:10Z','2026-10-25 01:20Z',null,null);
select pg_temp.ev('z3','public','available',false,'2026-10-24 23:30Z','2026-10-24 23:45Z',null,null);
select pg_temp.chk('Z1','[R1-S] Azores 10/25 終日busy x 1回目/2回目の0時台 -> どちらも出ない、前日23:30は出る',
  'T:2026-10-24T23:30/2026-10-24T23:45', 't1', '2026-10-19 00:00Z', '2026-10-27 01:00Z', '2026-10-19', '2026-10-27');
delete from public.events;

-- ============================ owner zone: Pacific/Apia ======================
-- 2011-12-30 never happened there: a boundary on it does not round-trip, so the
-- cross-model answer is refused, exactly as in 0025.
update public.owner_settings set timezone = 'Pacific/Apia' where owner_id = :owner;
select pg_temp.ev('R1S-SECRET-TITLE','public','busy',true,null,null,'2011-12-30','2011-12-31');
select pg_temp.ev('k','public','available',false,'2011-12-31 12:00Z','2011-12-31 13:00Z',null,null);
select pg_temp.chk('K1','存在しない日付(Apia 2011-12-30)の境界 -> indeterminate（0025と同じ）',
  'indeterminate', 't1', '2011-12-26 10:00Z', '2012-01-01 10:00Z', '2011-12-26', '2012-01-02');
delete from public.events;

-- ============================ ordinary zones: unchanged =====================
update public.owner_settings set timezone = 'Asia/Tokyo' where owner_id = :owner;
select pg_temp.ev('R1S-SECRET-TITLE','public','busy',true,null,null,'2026-10-08','2026-10-09');
select pg_temp.ev('t','public','available',false,'2026-10-07 14:30Z','2026-10-07 15:30Z',null,null);
select pg_temp.chk('N2','Tokyo 通常日: 終日busy x 0時をまたぐavailable -> 0時(15:00Z)で切れる',
  'T:2026-10-07T14:30/2026-10-07T15:00', 't1', '2026-10-04 15:00Z', '2026-10-11 15:00Z', '2026-10-05', '2026-10-12');
delete from public.events;
update public.owner_settings set timezone = 'America/New_York' where owner_id = :owner;
select pg_temp.ev('R1S-SECRET-TITLE','public','busy',true,null,null,'2026-11-01','2026-11-02');
select pg_temp.ev('n','public','available',false,'2026-11-01 03:30Z','2026-11-01 04:30Z',null,null);
select pg_temp.ev('m','public','available',false,'2026-11-01 05:30Z','2026-11-01 06:30Z',null,null);
select pg_temp.chk('N3','New York 11/1(25時間・深夜は普通): 0時(04:00Z)で切れる、01:30の2回は日の中',
  'T:2026-11-01T03:30/2026-11-01T04:00', 't1', '2026-10-26 04:00Z', '2026-11-03 05:00Z', '2026-10-26', '2026-11-03');
delete from public.events;

\echo ''
select c, case when expected is not distinct from actual then 'ok' else 'FAIL' end as status,
       note, expected, actual
from o
union all
select 'ZZZ', case when count(*) filter (where expected is distinct from actual) = 0 then 'ok' else 'FAIL' end,
       'FAIL rows (0027 applied requires 0)', '0',
       (count(*) filter (where expected is distinct from actual))::text
from o
order by 1;
rollback;
