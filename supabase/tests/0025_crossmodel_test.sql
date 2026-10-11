-- ============================================================================
-- 0025 RUNTIME SUITE -- behaviour, through the real objects, all rolled back.
--
-- The preflight and postflight ask whether the OBJECTS are right. This asks
-- whether the ANSWERS are, against real rows.
--
-- R rows are the regression half and matter more than the X rows: they are the
-- windows 0024 already answered correctly, and 0025 must answer identically.
-- R1 is the one that caught a real bug during implementation -- a multirange
-- union with an uninitialised NULL erased every timed Available slot on the
-- non-cross-model path, which is the path most owners are on.
--
-- X rows are the new capability: an owner who has declared a zone gets exact
-- subtraction across the two time models instead of a refusal.
--
-- The probe calls free_busy_core + free_busy_available directly rather than
-- public.get_free_busy, for one reason only: the wrapper charges 0019's rate
-- buckets on every call and a suite this size exhausts them. The wrapper path
-- itself is exercised separately (see the E2E in docs/0025_crossmodel_design.md);
-- what 0025 changes is the helper, and that is what this calls.
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off
begin;
\set owner '''5e86935f-7661-4741-868f-0f51c4cf1727'''

create or replace function pg_temp.mk(tok text, ip boolean, sa boolean) returns void language sql as $$
  insert into public.share_links (owner_id, token_hash, include_private, share_available)
  values ('5e86935f-7661-4741-868f-0f51c4cf1727', encode(extensions.digest(tok,'sha256'),'hex'), ip, sa);
$$;
select pg_temp.mk('t1', true, true);
select pg_temp.mk('t0', false, true);
select pg_temp.mk('toff', true, false);
insert into public.share_links (owner_id, token_hash, include_private, share_available, revoked_at)
values (:owner, encode(extensions.digest('trev','sha256'),'hex'), true, true, now());

create or replace function pg_temp.probe(tok text, f timestamptz, t timestamptz, fd date, td date)
returns table(ls text, bc boolean, bs int, av text, avs int, shapes text)
language sql as $$
  with lk as (select id from public.share_links
               where token_hash = encode(extensions.digest(tok,'sha256'),'hex')
                 and revoked_at is null
                 and (expires_at is null or expires_at > now())
                 and share_available limit 1),
  r as (select coalesce(
          (select c.r || jsonb_build_object('link_state','active')
                      || jsonb_build_object('available', a.r)
           from lk,
                timeweave_private.free_busy_core(lk.id,f,t,fd,td) as c(r),
                lateral timeweave_private.free_busy_available(lk.id,f,t,fd,td,c.r) as a(r)),
          jsonb_build_object('link_state','unavailable','complete',true,
                             'slots','[]'::jsonb,
                             'available', jsonb_build_object('status','not_requested'))) as j)
  select j->>'link_state', (j->'complete')::boolean, jsonb_array_length(j->'slots'),
         j->'available'->>'status',
         case when jsonb_typeof(j->'available'->'slots')='array'
              then jsonb_array_length(j->'available'->'slots') end,
         (select string_agg(case when (s->'all_day')::boolean then 'D' else 'T' end,'' order by ord)
          from jsonb_array_elements(coalesce(j->'available'->'slots','[]'::jsonb))
               with ordinality as e(s,ord))
  from r;
$$;
create temp table o(c text, note text, ls text, bc boolean, bs int, av text, avs int, shapes text);
create or replace function pg_temp.rec(c text, note text, tok text default 't1',
  f timestamptz default '2026-10-05 00:00+09', t timestamptz default '2026-10-12 00:00+09',
  fd date default '2026-10-05', td date default '2026-10-12')
returns void language sql as $$ insert into o select c, note, * from pg_temp.probe(tok,f,t,fd,td); $$;

create or replace function pg_temp.ev(ttl text, vis text, av text, ad boolean,
  sa timestamptz, ea timestamptz, sd date, ed date, rr text, tz text)
returns void language sql as $$
  insert into public.events (owner_id,title,visibility,availability,all_day,
    start_at,end_at,start_date,end_date,rrule,timezone)
  values ('5e86935f-7661-4741-868f-0f51c4cf1727',ttl,vis,av,ad,sa,ea,sd,ed,rr,tz);
$$;

-- ===================== R: 回帰（ゾーン未設定で 0024 と同一） =================
select pg_temp.ev('bt','public','busy',false,'2026-10-07 09:00+09','2026-10-07 10:00+09',null,null,null,null);
select pg_temp.ev('at','public','available',false,'2026-10-08 13:00+09','2026-10-08 17:00+09',null,null,null,null);
select pg_temp.rec('R1','時刻busy x 時刻available（ゾーン未設定）');
delete from public.events;
select pg_temp.ev('bd','public','busy',true,null,null,'2026-10-06','2026-10-07',null,null);
select pg_temp.ev('ad','public','available',true,null,null,'2026-10-08','2026-10-10',null,null);
select pg_temp.rec('R2','終日busy x 終日available（ゾーン未設定）');
delete from public.events;
select pg_temp.ev('bt','public','busy',false,'2026-10-07 09:00+09','2026-10-07 10:00+09',null,null,null,null);
select pg_temp.rec('R3','available 0件');
select pg_temp.rec('R4','share_available=false','toff');
select pg_temp.rec('R5','失効リンク','trev');
delete from public.events;
select pg_temp.ev('bm','public','busy',true,null,null,'2026-09-01','2026-09-02','FREQ=MONTHLY',null);
select pg_temp.ev('at','public','available',false,'2026-10-08 13:00+09','2026-10-08 17:00+09',null,null,null,null);
select pg_temp.rec('R6','Busy complete=false');
delete from public.events;
select pg_temp.ev('am','public','available',true,null,null,'2026-09-01','2026-09-02','FREQ=MONTHLY',null);
select pg_temp.rec('R7','展開不能な available マスター');
delete from public.events;
select pg_temp.ev('bd','public','busy',true,null,null,'2026-10-06','2026-10-07',null,null);
select pg_temp.ev('at','public','available',false,'2026-10-08 13:00+09','2026-10-08 17:00+09',null,null,null,null);
select pg_temp.rec('R8','クロスモデル ＋ ゾーン未設定 -> 0024と同じ indeterminate');

-- ===================== ゾーンを宣言 =========================================
insert into public.owner_settings (owner_id, timezone, language)
values (:owner, 'Asia/Tokyo', 'ja');

select pg_temp.rec('X1','A: 終日busy(10/6) x 時刻available(10/8) -> 両立');
delete from public.events;

-- 本番 P1 形状
select pg_temp.ev('ad1','private','busy',true,null,null,'2026-09-07','2026-09-08','FREQ=WEEKLY;BYDAY=MO',null);
select pg_temp.ev('ad2','private','busy',true,null,null,'2026-09-12','2026-09-14','FREQ=WEEKLY;BYDAY=SA',null);
select pg_temp.ev('bt','private','busy',false,'2026-09-09 09:00+09','2026-09-09 10:00+09',null,null,'FREQ=WEEKLY;BYDAY=WE','Asia/Tokyo');
select pg_temp.ev('av1','private','available',false,'2026-10-09 09:00+09','2026-10-09 12:00+09',null,null,null,null);
select pg_temp.ev('av2','private','available',false,'2026-10-10 10:00+09','2026-10-10 12:00+09',null,null,null,null);
select pg_temp.ev('av3','private','available',false,'2026-10-08 09:00+09','2026-10-08 11:00+09',null,null,null,null);
select pg_temp.rec('X2','本番P1形状 ip=ON -> complete');
select pg_temp.rec('X3','同 ip=OFF -> privateは全除外','t0');

delete from public.events;
-- B: 終日available に 時刻busy が1分だけ重なる
select pg_temp.ev('ad','public','available',true,null,null,'2026-10-08','2026-10-09',null,null);
select pg_temp.ev('bt','public','busy',false,'2026-10-08 09:00+09','2026-10-08 09:01+09',null,null,null,null);
select pg_temp.rec('X4','B: 終日available を 時刻busy が1分だけ削る');

delete from public.events;
-- 終日available 2日分、うち1日だけ時刻busyが触る -> 形状保存
select pg_temp.ev('ad','public','available',true,null,null,'2026-10-08','2026-10-10',null,null);
select pg_temp.ev('bt','public','busy',false,'2026-10-09 09:00+09','2026-10-09 10:00+09',null,null,null,null);
select pg_temp.rec('X5','触られない日は終日のまま / 触られた日だけ時刻化');

delete from public.events;
-- 日付をまたぐ時刻busy
select pg_temp.ev('ad','public','available',true,null,null,'2026-10-08','2026-10-10',null,null);
select pg_temp.ev('bt','public','busy',false,'2026-10-08 23:00+09','2026-10-09 01:00+09',null,null,null,null);
select pg_temp.rec('X6','日付をまたぐ時刻busy');

delete from public.events;
-- 終日busy が時刻available を完全に覆う
select pg_temp.ev('bd','public','busy',true,null,null,'2026-10-08','2026-10-09',null,null);
select pg_temp.ev('at','public','available',false,'2026-10-08 13:00+09','2026-10-08 17:00+09',null,null,null,null);
select pg_temp.rec('X7','終日busy が 時刻available を完全被覆 -> 0件');

delete from public.events;
-- 重複する終日busy
select pg_temp.ev('bd1','public','busy',true,null,null,'2026-10-08','2026-10-10',null,null);
select pg_temp.ev('bd2','public','busy',true,null,null,'2026-10-09','2026-10-11',null,null);
select pg_temp.ev('at','public','available',false,'2026-10-07 13:00+09','2026-10-11 17:00+09',null,null,null,null);
select pg_temp.rec('X8','重複する終日busy -> 二重差引なし');

delete from public.events;
-- private + available, ip=ON/OFF
select pg_temp.ev('bd','public','busy',true,null,null,'2026-10-06','2026-10-07',null,null);
select pg_temp.ev('ap','private','available',false,'2026-10-08 13:00+09','2026-10-08 15:00+09',null,null,null,null);
select pg_temp.rec('X9','private+available ip=ON -> 開示');
select pg_temp.rec('X10','private+available ip=OFF -> 除外','t0');

-- 解決不能ゾーン
update public.owner_settings set timezone = null where owner_id = :owner;
select pg_temp.rec('X11','ゾーンを外した -> indeterminate に戻る');
update public.owner_settings set timezone = 'Asia/Tokyo' where owner_id = :owner;

-- DST: America/New_York の 2026-03-08(23h) と 2026-11-01(25h)
update public.owner_settings set timezone = 'America/New_York' where owner_id = :owner;
delete from public.events;
select pg_temp.ev('bd','public','busy',true,null,null,'2026-03-08','2026-03-09',null,null);
select pg_temp.ev('at','public','available',false,'2026-03-07 12:00-05','2026-03-10 12:00-04',null,null,null,null);
select pg_temp.rec('X12','DST開始日(23時間)を終日busyで削る','t1',
  '2026-03-02 00:00-05','2026-03-16 00:00-04','2026-03-02','2026-03-16');
delete from public.events;
select pg_temp.ev('bd','public','busy',true,null,null,'2026-11-01','2026-11-02',null,null);
select pg_temp.ev('at','public','available',false,'2026-10-31 12:00-04','2026-11-03 12:00-05',null,null,null,null);
select pg_temp.rec('X13','DST終了日(25時間)を終日busyで削る','t1',
  '2026-10-26 00:00-04','2026-11-09 00:00-05','2026-10-26','2026-11-09');

-- 閲覧者ゾーン != オーナーゾーン（窓を UTC で送る）
update public.owner_settings set timezone = 'Asia/Tokyo' where owner_id = :owner;
delete from public.events;
select pg_temp.ev('bd','public','busy',true,null,null,'2026-10-08','2026-10-09',null,null);
select pg_temp.ev('at','public','available',false,'2026-10-08 13:00+09','2026-10-08 17:00+09',null,null,null,null);
select pg_temp.rec('X14','窓をUTCで送っても結果はオーナーゾーン基準','t1',
  '2026-10-05 00:00+00','2026-10-12 00:00+00','2026-10-05','2026-10-12');
select pg_temp.rec('X15','窓を UTC-11 で送っても同じ（窓細工が効かない）','t1',
  '2026-10-05 00:00-11','2026-10-12 00:00-11','2026-10-05','2026-10-12');

-- 決定性
select pg_temp.rec('X16','1回目');
select pg_temp.rec('X17','2回目（同一入力）');

\echo ''
select c, note, ls, bc as busy_complete, bs as busy_slots, av as avail, avs as n, shapes
from o order by c;
rollback;
