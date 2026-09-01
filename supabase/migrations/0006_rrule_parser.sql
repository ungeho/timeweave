-- TimeWeave Phase 5b-0: SQL-side RRULE parser + "series already ended" narrowing.
--
-- WHAT THIS STEP DOES (and deliberately does NOT do):
--   * It adds a whitelist RRULE parser to SQL and uses it for ONE purpose:
--     proving that a recurring series contributed NOTHING to the requested
--     window, so it no longer has to force complete=false.
--   * It does NOT expand recurrences into busy slots. That is 5b-1.
--
-- THE SAFETY RULE THIS FILE IS BUILT AROUND:
--   complete may only be relaxed by PROVING ABSENCE of a busy contribution.
--   Every helper below returns the CONSERVATIVE value (false = "cannot prove")
--   on any doubt: unparseable rule, unknown key, missing UNTIL, UNTIL whose
--   value type does not match the row's all_day, or a NULL anywhere. A wrong
--   "true" here would be a false-free -- the one failure mode sharing must never
--   have -- so every branch defaults to false rather than to true.
--
--   Corollary: SQL may be STRICTER than the TypeScript parser, never laxer.
--   Where the two differ (see rrule_parse notes) SQL is the strict side.
--
-- Security: same boundary as 0005. The helpers are NOT granted to anon or
-- authenticated; only get_free_busy (SECURITY DEFINER) calls them, running as
-- the definer, so ownership alone suffices.
--
-- Tests: supabase/tests/0006_rrule_parser_test.sql (not a migration; run by hand
-- on a development project, wrapped in a transaction that rolls back).

-- ============================================================================
-- 1. rrule_parse: SYNTAX ONLY. Knows nothing about the event row.
--
-- Mirrors the vocabulary of services/recurrence.ts `parseRRule`. Note that
-- FREQ=MONTHLY and COUNT parse as status='ok' here -- they ARE part of
-- TimeWeave's RRULE vocabulary. Whether SQL can EXPAND them is a separate,
-- context-dependent policy question answered by rrule_sql_subset().
--
-- status: 'ok'          -> structured into the columns below
--         'unsupported' -> readable, but outside the vocabulary
--         'malformed'   -> not readable as an RRULE at all
-- Only 'ok' is ever acted on. 'unsupported' vs 'malformed' exists for
-- diagnostics (`reason`) and MUST NOT drive behaviour: both are equally unsafe
-- to act on, so callers treat them identically.
--
-- CONTRACT: this function must return EXACTLY ONE row for every input,
-- including NULL. Do NOT declare it STRICT -- a STRICT function returns zero
-- rows for a NULL argument, which would silently disable the narrowing for
-- rows whose rrule is NULL-ish. Enforced by section 1.0 of the test suite.
-- ============================================================================
create or replace function public.rrule_parse(p_rrule text)
returns table (
  status     text,
  reason     text,
  freq       text,
  interval_n integer,
  byday      text[],
  count_n    integer,
  until_date date,
  until_ts   timestamptz
)
language plpgsql
stable
set search_path = ''
as $fn$
declare
  v_seg        text;
  v_key        text;
  v_val        text;
  v_eq         integer;
  v_seen       text[] := '{}';
  v_tok        text;
  v_days       text[] := '{}';
  v_byday_raw  text;
  v_until_raw  text;
begin
  -- Start from the rejecting value; every success path must overwrite it.
  status := 'malformed'; reason := 'unset';
  freq := null; interval_n := null; byday := null;
  count_n := null; until_date := null; until_ts := null;

  if p_rrule is null then
    reason := 'null_rrule'; return next; return;
  end if;

  foreach v_seg in array regexp_split_to_array(btrim(p_rrule), ';')
  loop
    -- Empty segments are ignored, matching the TS parser's filter(len > 0).
    continue when btrim(v_seg) = '';

    v_eq := position('=' in v_seg);
    if v_eq = 0 then
      status := 'malformed'; reason := 'segment_without_eq'; return next; return;
    end if;

    v_key := upper(btrim(substring(v_seg from 1 for v_eq - 1)));
    v_val := btrim(substring(v_seg from v_eq + 1));

    if v_key = any (v_seen) then
      status := 'malformed'; reason := 'duplicate_key:' || v_key; return next; return;
    end if;
    v_seen := v_seen || v_key;

    if v_key = 'FREQ' then
      freq := upper(v_val);

    elsif v_key = 'INTERVAL' then
      -- 1..9999. Rejecting 0/negative/huge keeps expansion bounded later.
      if v_val !~ '^[1-9][0-9]{0,3}$' then
        status := 'malformed'; reason := 'invalid_interval'; return next; return;
      end if;
      interval_n := v_val::integer;

    elsif v_key = 'BYDAY' then
      v_byday_raw := upper(v_val);

    elsif v_key = 'COUNT' then
      if v_val !~ '^[1-9][0-9]{0,6}$' then
        status := 'malformed'; reason := 'invalid_count'; return next; return;
      end if;
      count_n := v_val::integer;

    elsif v_key = 'UNTIL' then
      v_until_raw := upper(v_val);

    else
      -- Unknown key. We keep no registry of RFC 5545 keys: anything outside the
      -- whitelist (BYMONTHDAY, BYSETPOS, WKST, typos alike) is equally unusable.
      status := 'unsupported'; reason := 'unknown_key:' || v_key; return next; return;
    end if;
  end loop;

  if freq is null then
    status := 'malformed'; reason := 'missing_freq'; return next; return;
  end if;
  if freq not in ('DAILY', 'WEEKLY', 'MONTHLY') then
    status := 'unsupported'; reason := 'unsupported_freq:' || freq; return next; return;
  end if;

  if interval_n is null then
    interval_n := 1;  -- RFC default
  end if;

  if v_byday_raw is not null then
    if freq <> 'WEEKLY' then
      status := 'unsupported'; reason := 'byday_requires_weekly'; return next; return;
    end if;
    if v_byday_raw = '' then
      status := 'malformed'; reason := 'empty_byday'; return next; return;
    end if;

    foreach v_tok in array regexp_split_to_array(v_byday_raw, ',')
    loop
      v_tok := btrim(v_tok);
      -- Plain weekdays only. Ordinals (2MO, -1FR) are rejected, as in TS.
      if v_tok !~ '^(MO|TU|WE|TH|FR|SA|SU)$' then
        status := 'unsupported'; reason := 'unsupported_byday:' || v_tok; return next; return;
      end if;
      -- STRICTER THAN TS: TS tolerates BYDAY=MO,MO and emits the occurrence
      -- twice. Rejecting is the safe direction (it only forces complete=false).
      if v_tok = any (v_days) then
        status := 'malformed'; reason := 'duplicate_byday:' || v_tok; return next; return;
      end if;
      v_days := v_days || v_tok;
    end loop;
    byday := v_days;
  end if;

  -- Mirrors services/recurrence.ts:96, which throws for COUNT and UNTIL together.
  if count_n is not null and v_until_raw is not null then
    status := 'malformed'; reason := 'count_and_until'; return next; return;
  end if;

  if v_until_raw is not null then
    if v_until_raw ~ '^[0-9]{8}$' then
      -- DATE form (all-day series). Built as an explicit ISO literal and cast:
      -- to_date() is LENIENT and silently rolls 20260231 into March, which would
      -- push UNTIL later than written. The cast raises instead.
      begin
        until_date := (
          substring(v_until_raw from 1 for 4) || '-' ||
          substring(v_until_raw from 5 for 2) || '-' ||
          substring(v_until_raw from 7 for 2)
        )::date;
      exception when others then
        status := 'malformed'; reason := 'invalid_until_date'; return next; return;
      end;

    elsif v_until_raw ~ '^[0-9]{8}T[0-9]{6}Z$' then
      -- Instant form (timed series). The explicit +00 offset makes this
      -- independent of the session TimeZone setting.
      begin
        until_ts := (
          substring(v_until_raw from 1 for 4) || '-' ||
          substring(v_until_raw from 5 for 2) || '-' ||
          substring(v_until_raw from 7 for 2) || ' ' ||
          substring(v_until_raw from 10 for 2) || ':' ||
          substring(v_until_raw from 12 for 2) || ':' ||
          substring(v_until_raw from 14 for 2) || '+00'
        )::timestamptz;
      exception when others then
        status := 'malformed'; reason := 'invalid_until_instant'; return next; return;
      end;

    else
      -- Includes '2026-08-05' and floating 'YYYYMMDDTHHMMSS' without Z.
      status := 'malformed'; reason := 'invalid_until_format'; return next; return;
    end if;
  end if;

  status := 'ok'; reason := 'ok';
  return next;
end;
$fn$;

-- ============================================================================
-- 2. rrule_sql_subset: POLICY + ROW CONTEXT. Is this rule inside the subset
--    that SQL will be able to expand?
--
-- DEFINED HERE, DELIBERATELY UNUSED IN 5b-0. get_free_busy does not call it,
-- because expansion does not exist yet: a rule being "expandable in principle"
-- must never relax complete before the expansion is actually implemented.
-- 5b-1 starts calling it in the same commit that adds the expansion.
--
-- 5b-0/5b-1 subset: all-day + DAILY/WEEKLY + no COUNT + UNTIL in DATE form.
-- 5b-3 will widen this to timed rows once events.timezone exists.
-- ============================================================================
create or replace function public.rrule_sql_subset(
  p_rrule   text,
  p_all_day boolean
)
returns boolean
language sql
stable
set search_path = ''
as $fn$
  select coalesce((
    select p.status = 'ok'
       and p.freq in ('DAILY', 'WEEKLY')   -- MONTHLY: month-end skip not in SQL yet
       and p.count_n is null               -- COUNT: needs counting from DTSTART
       and p_all_day is true               -- timed: needs events.timezone (5b-2/5b-3)
       and p.until_ts is null              -- an all-day series must not carry an instant UNTIL
    from public.rrule_parse(p_rrule) p
  ), false);
$fn$;

-- ============================================================================
-- 3. rrule_definitely_ends_before: the ONE narrowing 5b-0 acts on.
--
-- Returns true ONLY when the whole series provably ends at or before the start
-- of the requested window, i.e. it cannot contribute any busy to it. Anything
-- unproven returns false, so the caller keeps reporting incomplete.
--
-- Boundary semantics (no safety margin -- the half-open interval is exact):
--   Occurrence spans are [start, end). UNTIL is INCLUSIVE and caps the last
--   occurrence's START. So the latest possible END is until + duration, and the
--   window [from, to) is untouched exactly when  latest_end <= from.
--   Equality is "ended": an end that lands ON the window start does not overlap.
--
--   all-day: until_date + (end_date - start_date) <= p_from_date   (pure date math)
--   timed  : until_ts   + (end_at   - start_at)   <= p_from
--
-- The timed case is compared in EPOCH SECONDS on purpose. Adding a day-bearing
-- interval to a timestamptz is calendar arithmetic and can absorb a DST
-- transition (a "day" becoming 23h), which would compute an end EARLIER than the
-- true one and could wrongly prove the series finished -- a false-free. Epoch
-- seconds treat the duration as absolute, matching the TS expander, which adds a
-- fixed durationMs.
--
-- Note this narrowing is INDEPENDENT of rrule_sql_subset: a MONTHLY series with
-- an UNTIL in the past is just as provably finished as a DAILY one, even though
-- SQL cannot expand MONTHLY.
-- ============================================================================
create or replace function public.rrule_definitely_ends_before(
  p_rrule      text,
  p_all_day    boolean,
  p_start_date date,
  p_end_date   date,
  p_start_at   timestamptz,
  p_end_at     timestamptz,
  p_from       timestamptz,
  p_from_date  date
)
returns boolean
language sql
stable
set search_path = ''
as $fn$
  select coalesce((
    select case
      -- Unparseable / outside the vocabulary: prove nothing.
      when p.status <> 'ok' then false

      when p_all_day is true then
             p.until_date is not null      -- COUNT-bounded or infinite: unprovable
         and p.until_ts   is null          -- UNTIL kind must match all_day
         and p_start_date is not null
         and p_end_date   is not null
         and p_from_date  is not null
         and (p.until_date + (p_end_date - p_start_date)) <= p_from_date

      when p_all_day is false then
             p.until_ts   is not null
         and p.until_date is null          -- UNTIL kind must match all_day
         and p_start_at   is not null
         and p_end_at     is not null
         and p_from       is not null
         and (
               extract(epoch from p.until_ts)
             + extract(epoch from (p_end_at - p_start_at))
             ) <= extract(epoch from p_from)

      else false   -- p_all_day IS NULL
    end
    from public.rrule_parse(p_rrule) p
  ), false);
$fn$;

-- ============================================================================
-- 4. get_free_busy: body replaced. SIGNATURE AND RETURN SHAPE ARE UNCHANGED, so
--    the existing grants survive `create or replace` and the frontend needs no
--    change whatsoever.
--
-- The ONLY difference from 0005 is in step 3: a recurring master that provably
-- ended before the window no longer forces complete=false. Busy computation
-- (step 4) is unchanged -- single events only.
--
-- Exception rows (including cancellations) still force incomplete exactly as in
-- 0005; their semantics are revisited in 5b-1 together with master expansion.
--
-- rrule_sql_subset is intentionally NOT called here. See its comment above.
--
-- AFTER APPLYING, VERIFY there is exactly ONE get_free_busy (a mismatched
-- argument list would create an overload that anon could still reach):
--   select proname, pg_get_function_identity_arguments(oid)
--   from pg_proc where proname = 'get_free_busy';
-- and that its grants survived:
--   select proacl from pg_proc where proname = 'get_free_busy';
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
as $fn$
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

  -- 3. Completeness. Phase 5b-0 refinement: a recurring master whose series
  --    PROVABLY ended at or before the window start contributes nothing, so it
  --    no longer forces incomplete. Everything else is unchanged and still
  --    over-flags on purpose (over-flagging is the safe direction).
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
          and not public.rrule_definitely_ends_before(
                    e.rrule, e.all_day,
                    e.start_date, e.end_date,
                    e.start_at,   e.end_at,
                    p_from,       p_from_date)
        )
        or
        -- EXCEPTION row overlapping the window (cancellations included; 5b-1).
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
  --    UNCHANGED from 0005.
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
$fn$;

-- ============================================================================
-- 5. EXECUTE privileges.
--
-- The three helpers are internal. They are NOT granted to anon or to
-- authenticated: only get_free_busy calls them, and it is SECURITY DEFINER, so
-- it executes them as the function owner. Leaving them ungranted keeps the anon
-- surface exactly as small as it was after 0005 -- one callable function.
--
-- Note the helpers are deliberately NOT security definer themselves: they are
-- pure functions over their arguments and touch no tables, so they need no
-- elevated rights.
--
-- get_free_busy itself keeps the grants it already has: `create or replace`
-- preserves privileges, so 0005's `grant ... to anon, authenticated` still holds
-- and is intentionally NOT repeated here.
-- ============================================================================
revoke execute on function public.rrule_parse(text) from public;
revoke execute on function public.rrule_sql_subset(text, boolean) from public;
revoke execute on function public.rrule_definitely_ends_before(
  text, boolean, date, date, timestamptz, timestamptz, timestamptz, date
) from public;
