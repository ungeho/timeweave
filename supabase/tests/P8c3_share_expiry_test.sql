-- ============================================================================
-- P8-c3 RUNTIME SUITE -- share-link expiry on the server, all rolled back.
--
-- WHAT IT PINS. The server never interprets a wall clock: create_share_link
-- stores the timestamptz it is given, the CHECK refuses an expiry at or before
-- creation, and every access check is `expires_at > now()` on the SERVER's
-- clock -- so a link is dead AT its expiry instant. Expired, revoked and
-- unknown tokens get the same answer. The rest of the link contract
-- (share_available, include_private, visibility, Busy wins, no details) is the
-- same while the link is alive. The DST question lives in the client, which
-- decides which instant is sent (src/features/share/shareExpiry.test.ts).
--
-- Independent of 0027 (no all-day boundary is involved). Isolated DB only:
--   psql -h 127.0.0.1 -p 5433 -U postgres -d <db> -X -f supabase/tests/P8c3_share_expiry_test.sql
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off
begin;
\set owner '''5e86935f-7661-4741-868f-0f51c4cf1727'''
do $$ begin
  if not exists (select 1 from auth.users where id = '5e86935f-7661-4741-868f-0f51c4cf1727') then
    raise exception 'canonical test owner missing from auth.users -- wrong database?';
  end if;
  if exists (select 1 from public.share_links where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727')
     or exists (select 1 from public.events where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727') then
    raise exception 'the test owner already has rows -- refusing to run on a database in use';
  end if;
end $$;
create temp table o(c text, note text, expected text, actual text);
grant insert, select on o to authenticated, anon;

-- ===================== 1. create_share_link stores the instant as given =======
-- As the owner, through the real RPC. Far-future DST instants (New York 2099:
-- the 2nd 01:30 of 11-01 and 03:30 EDT of 03-08), sent as ISO with Z exactly as
-- the client sends toISOString(), under three different SESSION zones.
set local role authenticated;
set local request.jwt.claim.sub = '5e86935f-7661-4741-868f-0f51c4cf1727';
do $$
declare z text; r record;
begin
  foreach z in array array['UTC','Asia/Tokyo','America/New_York'] loop
    perform pg_catalog.set_config('timezone', z, true);
    select * into r from public.create_share_link('p8c3-' || z, true, '2099-11-01T06:30:00.000Z', false);
    insert into o values ('C1-' || z, '保存値はセッションのゾーンに依存しない（2回目01:30 EST）',
      '2099-11-01 06:30:00+00', (r.expires_at at time zone 'UTC')::text || '+00');
  end loop;
  perform pg_catalog.set_config('timezone', 'UTC', true);
end $$;
do $$ declare r record; begin
  select * into r from public.create_share_link('p8c3-gapday', true, '2099-03-08T07:30:00.000Z', false);
  insert into o values ('C2', '送られた瞬間のまま保存（サーバーは壁時計を解釈しない）', '2099-03-08 07:30:00+00',
    (r.expires_at at time zone 'UTC')::text || '+00');
end $$;
-- an expiry at or before creation is refused by the CHECK (no link is created)
do $$ begin
  begin
    perform public.create_share_link('p8c3-past', true, now() - interval '1 second', false);
    insert into o values ('C3', '過去の期限 -> 拒否', '23514', 'created');
  exception when check_violation then
    insert into o values ('C3', '過去の期限 -> 拒否', '23514', '23514');
  end;
  begin
    perform public.create_share_link('p8c3-now', true, now(), false);
    insert into o values ('C4', '作成時刻と同じ期限 -> 拒否（expires_at > created_at）', '23514', 'created');
  exception when check_violation then
    insert into o values ('C4', '作成時刻と同じ期限 -> 拒否（expires_at > created_at）', '23514', '23514');
  end;
end $$;
do $$ declare r record; begin
  select * into r from public.create_share_link('p8c3-none', true, null, false);
  insert into o values ('C5', '期限なし -> null のまま（期限なしの契約）', 'null', coalesce(r.expires_at::text, 'null'));
end $$;
reset role;
delete from public.share_links where owner_id = :owner;

-- ===================== 2. access at the boundary, on the server's clock ======
-- Rows written directly (created two days ago) so that expires_at can sit
-- exactly at, just before and just after now(). now() is fixed for this
-- transaction, so the boundary is exact.
create or replace function pg_temp.mk(tok text, ip boolean, sa boolean, exp timestamptz, rev timestamptz default null)
returns void language sql as $$
  -- 0016's create-rate trigger charges every insert, fixtures included. Reset the
  -- test owner's bucket first; this is internal state and the whole run rolls back.
  delete from timeweave_private.share_link_create_rate where owner_id = '5e86935f-7661-4741-868f-0f51c4cf1727';
  insert into public.share_links (owner_id, token_hash, include_private, share_available, expires_at, revoked_at, created_at)
  values ('5e86935f-7661-4741-868f-0f51c4cf1727', encode(extensions.digest(tok,'sha256'),'hex'), ip, sa, exp, rev,
          now() - interval '2 days');
$$;
select pg_temp.mk('e-at',     true, true, now());
select pg_temp.mk('e-before', true, true, now() - interval '1 microsecond');
select pg_temp.mk('e-after',  true, true, now() + interval '1 microsecond');
select pg_temp.mk('e-later',  true, true, now() + interval '1 hour');
select pg_temp.mk('e-revoked',true, true, now() + interval '1 hour', now() - interval '1 minute');
select pg_temp.mk('e-ip0',    false, true, now() + interval '1 hour');
select pg_temp.mk('e-sa0',    true, false, now() + interval '1 hour');
select pg_temp.mk('e-none',   true, true, null);

-- events (fictional) in a fixed window: private busy 10:00-11:00, busy_only busy
-- 13:00-14:00, public busy 15:00-16:00, public Available 09:00-17:00 (UTC, 2026-12-07)
insert into public.events (owner_id,title,description,category,visibility,availability,all_day,start_at,end_at) values
  (:owner,'P8C3-SECRET','P8C3-MEMO','P8C3-CAT','private','busy',false,'2026-12-07 10:00Z','2026-12-07 11:00Z'),
  (:owner,'P8C3-SECRET','P8C3-MEMO','P8C3-CAT','busy_only','busy',false,'2026-12-07 13:00Z','2026-12-07 14:00Z'),
  (:owner,'P8C3-SECRET','P8C3-MEMO','P8C3-CAT','public','busy',false,'2026-12-07 15:00Z','2026-12-07 16:00Z'),
  (:owner,'P8C3-SECRET','P8C3-MEMO','P8C3-CAT','public','available',false,'2026-12-07 09:00Z','2026-12-07 17:00Z');

create temp table w(c text, tz text, j jsonb);
grant insert, select on w to anon;
create or replace function pg_temp.norm(slots jsonb) returns text language sql as $$
  select coalesce(string_agg('T:' || to_char((s ->> 'start')::timestamptz at time zone 'UTC', 'HH24:MI') || '/'
                             || to_char((s ->> 'end')::timestamptz at time zone 'UTC', 'HH24:MI'), ' ' order by ord), '(none)')
  from jsonb_array_elements(slots) with ordinality as e(s, ord)
$$;
set local role anon;
insert into w select t, 'UTC', public.get_free_busy(t, '2026-12-07 00:00Z', '2026-12-08 00:00Z', '2026-12-07', '2026-12-08')
from unnest(array['e-at','e-before','e-after','e-later','e-revoked','e-ip0','e-sa0','e-none','no-such-token']) t;
-- the viewer's zone (session TimeZone) must not change the decision or the answer
set local timezone = 'Pacific/Kiritimati';
insert into w select 'e-later', 'Kiritimati', public.get_free_busy('e-later', '2026-12-07 00:00Z', '2026-12-08 00:00Z', '2026-12-07', '2026-12-08');
set local timezone = 'Pacific/Pago_Pago';
insert into w select 'e-at', 'Pago_Pago', public.get_free_busy('e-at', '2026-12-07 00:00Z', '2026-12-08 00:00Z', '2026-12-07', '2026-12-08');
reset role;
set local timezone = 'UTC';

create or replace function pg_temp.st(tok text, z text default 'UTC') returns text language sql as $$
  select (j ->> 'link_state') || '|' || jsonb_array_length(j -> 'slots') || '|'
         || case when j ? 'available' then coalesce(j -> 'available' ->> 'status', '?') else 'no-available-key' end
  from w where c = tok and tz = z
$$;
insert into o values
  ('A1','期限ちょうど(expires_at = now()) -> 使えない', 'unavailable|0|no-available-key', pg_temp.st('e-at')),
  ('A2','期限の1µs後 -> 使えない', 'unavailable|0|no-available-key', pg_temp.st('e-before')),
  ('A3','期限の1µs前 -> 使える', 'active|3|complete', pg_temp.st('e-after')),
  ('A4','失効済み -> 使えない', 'unavailable|0|no-available-key', pg_temp.st('e-revoked')),
  ('A5','期限なし -> 使える', 'active|3|complete', pg_temp.st('e-none')),
  ('A6','存在しないトークン -> 使えない', 'unavailable|0|no-available-key', pg_temp.st('no-such-token')),
  ('A7','期限切れ・失効・存在しないの応答は同一（何も区別できない）', 'true',
    ((select j from w where c='e-at' and tz='UTC') = (select j from w where c='e-revoked')
     and (select j from w where c='e-revoked') = (select j from w where c='no-such-token')
     and (select j from w where c='e-before') = (select j from w where c='no-such-token'))::text),
  -- Compared as INSTANTS: to_jsonb(timestamptz) prints the session's offset
  -- (+14:00 here), so the TEXT differs while every instant is the same. Through
  -- the real API the session zone is the database default, not the viewer's.
  ('A8','閲覧者のゾーン（+14）でも使える側の答えは同じ（瞬間として比較）', 'true',
    ((select pg_temp.st('e-later') || pg_temp.norm(j -> 'slots') || pg_temp.norm(j -> 'available' -> 'slots')
        from w where c='e-later' and tz='UTC')
     = (select pg_temp.st('e-later','Kiritimati') || pg_temp.norm(j -> 'slots') || pg_temp.norm(j -> 'available' -> 'slots')
        from w where c='e-later' and tz='Kiritimati'))::text),
  ('A9','閲覧者のゾーン（-11）でも期限ちょうどは使えない', 'unavailable|0|no-available-key', pg_temp.st('e-at','Pago_Pago')),
  ('B1','有効なリンク: Busy は private(ip=ON)・busy_only・public の3つ', 'T:10:00/11:00 T:13:00/14:00 T:15:00/16:00',
    (select pg_temp.norm(j -> 'slots') from w where c='e-later' and tz='UTC')),
  ('B2','有効なリンク: Available は Busy に削られる（Busy優先）', 'T:09:00/10:00 T:11:00/13:00 T:14:00/15:00 T:16:00/17:00',
    (select pg_temp.norm(j -> 'available' -> 'slots') from w where c='e-later' and tz='UTC')),
  ('B3','include_private=OFF: private の Busy は出ない、busy_only は出る', 'T:13:00/14:00 T:15:00/16:00',
    (select pg_temp.norm(j -> 'slots') from w where c='e-ip0')),
  ('B4','include_private=OFF: Available は残りの Busy で削られる', 'T:09:00/13:00 T:14:00/15:00 T:16:00/17:00',
    (select pg_temp.norm(j -> 'available' -> 'slots') from w where c='e-ip0')),
  ('B5','share_available=OFF: Available は要求されない', 'not_requested',
    (select j -> 'available' ->> 'status' from w where c='e-sa0')),
  ('B6','応答にタイトル・メモ・カテゴリが無い', 'false',
    (select bool_or(j::text ~ 'P8C3-|"title"|"description"|"category"') from w)::text);

\echo ''
select c, case when expected is not distinct from actual then 'ok' else 'FAIL' end as status, note, expected, actual
from o
union all
select 'ZZZ', case when count(*) filter (where expected is distinct from actual) = 0 then 'ok' else 'FAIL' end,
       'FAIL rows (GO requires 0)', '0', (count(*) filter (where expected is distinct from actual))::text
from o
order by 1;
rollback;
