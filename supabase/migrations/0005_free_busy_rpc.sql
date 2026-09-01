-- TimeWeave Phase 5a: Free/Busy RPC + share-link management functions.
--
-- Security model:
--   * All four functions are SECURITY DEFINER with a pinned empty search_path;
--     every non-catalog object is schema-qualified (public.*, auth.*,
--     extensions.*). pg_catalog is always implicitly searched, so built-ins
--     (now(), coalesce, jsonb_*, window funcs, casts) resolve without qualifying.
--   * DEFINER bypasses RLS, so every function filters explicitly:
--       - management fns by owner_id = auth.uid()
--       - get_free_busy by the owner resolved from the token
--   * EXECUTE is revoked from PUBLIC (Postgres grants it by default) and then
--     granted narrowly: management fns to `authenticated`, get_free_busy to
--     `anon` + `authenticated`. anon can reach nothing else.
--   * Tokens are generated server-side (256-bit) and only their sha256 hash is
--     stored; the plaintext is returned once by create_share_link.
--
-- NOTE (verify before applying): this assumes pgcrypto lives in the `extensions`
-- schema (Supabase default). Confirm with:
--   select extnamespace::regnamespace from pg_extension where extname='pgcrypto';
-- If it is in `public`, replace `extensions.` with `public.` for digest() and
-- gen_random_bytes() below.

-- ============================================================================
-- create_share_link: generate a link, return the plaintext token exactly once.
-- ============================================================================
create or replace function public.create_share_link(
  p_label           text        default null,
  p_include_private boolean     default true,
  p_expires_at      timestamptz default null
)
returns table (
  id              uuid,
  token           text,
  label           text,
  include_private boolean,
  expires_at      timestamptz,
  created_at      timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := auth.uid();
  v_token text;
  v_hash  text;
begin
  if v_owner is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  -- URL-safe base64 of 32 random bytes (256-bit); strip '=' padding.
  v_token := translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');
  v_hash  := encode(extensions.digest(v_token, 'sha256'), 'hex');

  return query
  with ins as (
    insert into public.share_links (owner_id, token_hash, label, include_private, expires_at)
    values (v_owner, v_hash, p_label, coalesce(p_include_private, true), p_expires_at)
    returning share_links.id,
              share_links.label,
              share_links.include_private,
              share_links.expires_at,
              share_links.created_at
  )
  select ins.id, v_token, ins.label, ins.include_private, ins.expires_at, ins.created_at
  from ins;
end;
$$;

-- ============================================================================
-- list_share_links: the caller's own links. token_hash is never returned.
-- ============================================================================
create or replace function public.list_share_links()
returns table (
  id              uuid,
  label           text,
  include_private boolean,
  expires_at      timestamptz,
  revoked_at      timestamptz,
  created_at      timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return query
  select s.id, s.label, s.include_private, s.expires_at, s.revoked_at, s.created_at
  from public.share_links s
  where s.owner_id = auth.uid()
  order by s.created_at desc;
end;
$$;

-- ============================================================================
-- revoke_share_link: soft-revoke one of the caller's links. Returns true if a
-- currently-active link was revoked.
-- ============================================================================
create or replace function public.revoke_share_link(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_done boolean;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  update public.share_links
     set revoked_at = now()
   where id = p_id
     and owner_id = auth.uid()
     and revoked_at is null
  returning true into v_done;

  return coalesce(v_done, false);
end;
$$;

-- ============================================================================
-- get_free_busy: anonymous Free/Busy for a share token.
-- Returns jsonb { complete: boolean, slots: [ <timed|all-day slot> ] }.
--   timed slot   : { "all_day": false, "start": <utc iso>, "end": <utc iso> }
--   all-day slot : { "all_day": true,  "start_date": "YYYY-MM-DD",
--                    "end_date": "YYYY-MM-DD" }   (end exclusive)
--
-- Two windows, one for each time model (they must never be mixed):
--   * p_from / p_to      : UTC instants, drive TIMED events.
--   * p_from_date / p_to_date : LOCAL calendar dates, half-open, drive ALL-DAY
--     events with NO timezone conversion (all-day is date-space in TimeWeave).
-- The caller (FreeBusyPage) derives BOTH from the same visible range in the
-- viewer's zone. Over-long or malformed windows are REJECTED (not clamped) so a
-- viewer can never mistake a truncated answer for a complete one.
--
-- Phase 5a computes busy from SINGLE events only. `complete` is false whenever
-- the owner has any recurring master (that may recur into the window) or any
-- exception overlapping the window that WOULD contribute busy (respecting
-- include_private), so a recurring calendar is never silently reported as free.
-- ============================================================================
create or replace function public.get_free_busy(
  p_token     text,
  p_from      timestamptz,
  p_to        timestamptz,
  p_from_date date,
  p_to_date   date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_owner           uuid;
  v_include_private boolean;
  v_complete        boolean;
  v_slots           jsonb;
begin
  -- 1. Validate BOTH windows explicitly; reject malformed or over-long ranges.
  if p_from is null or p_to is null or p_from >= p_to then
    raise exception 'invalid time window' using errcode = '22023';
  end if;
  if p_to > p_from + interval '92 days' then
    raise exception 'requested range exceeds 92 days' using errcode = '22023';
  end if;
  if p_from_date is null or p_to_date is null or p_from_date >= p_to_date then
    raise exception 'invalid date window' using errcode = '22023';
  end if;
  if p_to_date - p_from_date > 92 then
    raise exception 'requested date range exceeds 92 days' using errcode = '22023';
  end if;

  -- 2. Resolve an ACTIVE token (hash compare). Invalid/expired/revoked -> empty
  --    (no error, no existence oracle).
  select s.owner_id, s.include_private
    into v_owner, v_include_private
  from public.share_links s
  where s.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and s.revoked_at is null
    and (s.expires_at is null or s.expires_at > now())
  limit 1;

  if v_owner is null then
    return jsonb_build_object('complete', true, 'slots', '[]'::jsonb);
  end if;

  -- 3. Completeness: any recurring artifact that could touch the window AND that
  --    would contribute busy (respecting include_private) makes the result
  --    incomplete. Timed use the instant window; all-day use the date window.
  select not exists (
    select 1
    from public.events e
    where e.owner_id = v_owner
      and (v_include_private or e.visibility <> 'private')
      and (
        -- recurring MASTER that may recur into the window (COUNT/UNTIL end is
        -- not parsed here; over-flagging incomplete is the safe direction).
        ( e.rrule is not null
          and (
            (e.all_day = false and e.start_at   < p_to)
            or (e.all_day = true and e.start_date < p_to_date)
          )
        )
        or
        -- EXCEPTION row overlapping the window.
        ( e.recurrence_id is not null
          and (
            (e.all_day = false and e.start_at < p_to and e.end_at > p_from)
            or (e.all_day = true and e.start_date < p_to_date and e.end_date > p_from_date)
          )
        )
      )
  )
  into v_complete;

  -- 4. Busy intervals from SINGLE events only (accurate), clipped to the window,
  --    then merged (overlapping/adjacent) per type. Titles/ids are never read.
  with timed_raw as (
    select greatest(e.start_at, p_from) as s, least(e.end_at, p_to) as t
    from public.events e
    where e.owner_id = v_owner
      and e.rrule is null
      and e.recurrence_id is null
      and e.all_day = false
      and (v_include_private or e.visibility <> 'private')
      and e.start_at < p_to
      and e.end_at   > p_from
  ),
  timed_flag as (
    select s, t,
      case when coalesce(
             max(t) over (order by s, t rows between unbounded preceding and 1 preceding),
             '-infinity'::timestamptz) < s
           then 1 else 0 end as is_new
    from timed_raw
  ),
  timed_grp as (
    select s, t,
      sum(is_new) over (order by s, t rows between unbounded preceding and current row) as g
    from timed_flag
  ),
  timed_merged as (
    select min(s) as start_at, max(t) as end_at
    from timed_grp
    group by g
  ),
  allday_raw as (
    select greatest(e.start_date, p_from_date) as sd,
           least(e.end_date, p_to_date)        as ed
    from public.events e
    where e.owner_id = v_owner
      and e.rrule is null
      and e.recurrence_id is null
      and e.all_day = true
      and (v_include_private or e.visibility <> 'private')
      and e.start_date < p_to_date
      and e.end_date   > p_from_date
  ),
  allday_flag as (
    select sd, ed,
      case when coalesce(
             max(ed) over (order by sd, ed rows between unbounded preceding and 1 preceding),
             '-infinity'::date) < sd
           then 1 else 0 end as is_new
    from allday_raw
  ),
  allday_grp as (
    select sd, ed,
      sum(is_new) over (order by sd, ed rows between unbounded preceding and current row) as g
    from allday_flag
  ),
  allday_merged as (
    select min(sd) as start_date, max(ed) as end_date
    from allday_grp
    group by g
  ),
  slots_union as (
    -- Order WITHOUT converting between time models: all-day sorts by its date,
    -- timed by its instant, and a fixed type rank (all-day first) separates them.
    -- No date -> timestamptz cast, so ordering never depends on session timezone.
    -- FreeBusyPage may re-sort per union type for final display.
    select 0 as ord_group, am.start_date as sort_date, null::timestamptz as sort_ts,
           jsonb_build_object(
             'all_day', true,
             'start_date', to_jsonb(am.start_date),
             'end_date',   to_jsonb(am.end_date)
           ) as slot
    from allday_merged am
    union all
    select 1 as ord_group, null::date as sort_date, tm.start_at as sort_ts,
           jsonb_build_object(
             'all_day', false,
             'start', to_jsonb(tm.start_at),
             'end',   to_jsonb(tm.end_at)
           ) as slot
    from timed_merged tm
  )
  select coalesce(jsonb_agg(slot order by ord_group, sort_date, sort_ts), '[]'::jsonb)
    into v_slots
  from slots_union;

  return jsonb_build_object('complete', v_complete, 'slots', coalesce(v_slots, '[]'::jsonb));
end;
$$;

-- ============================================================================
-- EXECUTE privileges: revoke the default PUBLIC grant, then grant narrowly.
-- ============================================================================
revoke execute on function public.create_share_link(text, boolean, timestamptz) from public;
revoke execute on function public.list_share_links()                            from public;
revoke execute on function public.revoke_share_link(uuid)                       from public;
revoke execute on function public.get_free_busy(text, timestamptz, timestamptz, date, date) from public;

grant execute on function public.create_share_link(text, boolean, timestamptz) to authenticated;
grant execute on function public.list_share_links()                            to authenticated;
grant execute on function public.revoke_share_link(uuid)                       to authenticated;
grant execute on function public.get_free_busy(text, timestamptz, timestamptz, date, date) to anon, authenticated;
