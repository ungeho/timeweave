-- TimeWeave Phase 5b-1: expand ALL-DAY DAILY/WEEKLY recurrences into Free/Busy.
--
-- SCOPE (deliberately narrow; everything else keeps 5b-0 behaviour):
--   expanded : all-day masters with FREQ=DAILY or FREQ=WEEKLY, INTERVAL, BYDAY
--              (WEEKLY only) and a DATE-form UNTIL, plus their exception rows.
--   NOT yet  : COUNT, FREQ=MONTHLY, and every timed recurrence (the latter needs
--              events.timezone, which arrives in 5b-2). These stay fail-closed:
--              they force complete=false and contribute no slots.
--
-- THE INVARIANT THIS FILE PROTECTS:
--   Never report free where a DISCLOSABLE busy exists. "Disclosable" matters:
--   a private event excluded by include_private=false is not disclosed by the
--   owner's own choice, so showing that time as free is intended behaviour, not
--   a false-free. What must never happen is claiming complete=true while a
--   disclosable occurrence was silently dropped.
--
--   Consequences, applied throughout:
--     * Anything we cannot compute exactly forces complete=false. We never
--       truncate, clamp, or approximate a busy set downward.
--     * The closed-form index ranges below are deliberately WIDER than needed;
--       exactness comes from the per-row filter that follows. Narrowing a range
--       too far is the one bug class that silently produces free time.
--     * Helper preconditions RAISE rather than return an empty set, because an
--       empty set is indistinguishable from "genuinely no busy".
--
-- DETACH vs VISIBILITY (the subtle part):
--   An exception row detaches its master's original occurrence REGARDLESS of
--   visibility -- that is a structural fact about the series, not a disclosure
--   decision. Visibility is evaluated only when deciding whether to add the
--   exception's own snapshot to the busy set. This mirrors
--   services/occurrences.ts, which builds its `detached` set from every
--   exception without consulting visibility.
--
-- Security: unchanged from 0005/0006. The helpers read no tables, are not
-- SECURITY DEFINER, and are granted to nobody; get_free_busy remains the single
-- function anon can reach, with its signature, JSON shape, token behaviour and
-- 92-day limit untouched.

-- ============================================================================
-- 1. rrule_allday_expansion_cap: the runtime safety cap, in one place.
--
-- A hard upper bound on how many candidate occurrences a single master may
-- contribute to one window. It is a safety valve, not an expected code path:
-- a 92-day window with a one-day event yields at most 92. It only bites for
-- pathological data (e.g. a multi-year all-day event repeating daily).
--
-- Exceeding it NEVER truncates the busy set. The master is simply not expanded
-- and the window is reported complete=false. This is a RUNTIME, window-dependent
-- judgement and is kept strictly separate from rrule_sql_subset(), which answers
-- the window-independent question "is this grammar supported at all".
-- ============================================================================
create or replace function public.rrule_allday_expansion_cap()
returns integer
language sql
immutable
set search_path = ''
as $fn$ select 5000 $fn$;

-- ============================================================================
-- 2. rrule_allday_occurrence_count: how many candidates WOULD be generated.
--
-- Closed form, computed WITHOUT generating anything, so the cap can be checked
-- before any work happens. The result is an upper bound on the candidate set
-- before the exact per-date filter, which is exactly what a safety cap wants.
--
-- Returns NULL when the rule is outside the all-day SQL subset or an argument is
-- missing. Callers must treat NULL as "over cap" (coalesce(..., cap + 1)), never
-- as zero.
--
-- Not STRICT: see rrule_parse in 0006. NULL arguments must reach the body so the
-- NULL return is a decision, not an accident of the call convention.
-- ============================================================================
create or replace function public.rrule_allday_occurrence_count(
  p_rrule      text,
  p_all_day    boolean,
  p_start_date date,
  p_end_date   date,
  p_from_date  date,
  p_to_date    date
)
returns bigint
language plpgsql
stable
set search_path = ''
as $fn$
declare
  p    record;
  v_n  integer;
  v_d  integer;
  v_b  integer;
  v_w0 date;
  v_lo numeric;
  v_hi numeric;
begin
  if p_all_day is not true then return null; end if;
  if p_start_date is null or p_end_date is null
     or p_from_date is null or p_to_date is null then
    return null;
  end if;

  select * into p from public.rrule_parse(p_rrule);
  if p.status <> 'ok' then return null; end if;
  if p.freq not in ('DAILY', 'WEEKLY') then return null; end if;
  if p.count_n is not null then return null; end if;
  if p.until_ts is not null then return null; end if;  -- instant UNTIL on an all-day row

  v_n := p.interval_n;
  v_d := p_end_date - p_start_date;  -- >= 1 by the events_time_shape CHECK

  -- NOTE ON DIVISION: every quotient below is cast to numeric before floor().
  -- Postgres integer division truncates TOWARD ZERO, not downward, so on a
  -- negative numerator (a series starting after the window) integer maths would
  -- round the range inward and drop occurrences -- a false-free. floor() on
  -- numeric is the only correct form here.
  if p.freq = 'DAILY' then
    v_lo := greatest(0, floor((p_from_date - v_d - p_start_date)::numeric / v_n));
    v_hi := floor((p_to_date - p_start_date)::numeric / v_n);
    if p.until_date is not null then
      v_hi := least(v_hi, floor((p.until_date - p_start_date)::numeric / v_n));
    end if;
    return greatest(0, v_hi - v_lo + 1)::bigint;
  else
    -- BYDAY omitted means "the weekday of DTSTART", i.e. exactly one per week.
    v_b  := coalesce(array_length(p.byday, 1), 1);
    -- Week anchor: the Monday of DTSTART's week (RFC 5545 default WKST=MO), the
    -- same anchor services/recurrence.ts uses via mondayOfWeek().
    v_w0 := p_start_date - (extract(isodow from p_start_date)::integer - 1);
    v_lo := greatest(0, floor((p_from_date - v_d - 7 - v_w0)::numeric / (7 * v_n)));
    v_hi := floor((p_to_date - v_w0)::numeric / (7 * v_n)) + 1;
    if p.until_date is not null then
      v_hi := least(v_hi, floor((p.until_date - v_w0)::numeric / (7 * v_n)));
    end if;
    return greatest(0, (v_hi - v_lo + 1) * v_b)::bigint;
  end if;
end;
$fn$;

-- ============================================================================
-- 3. rrule_allday_occurrence_starts: the occurrence START dates that can touch
--    the window, ascending.
--
-- Each occurrence spans [d, d + duration) where duration = end_date - start_date
-- of the master, so a date is emitted when
--     d >= start_date                (nothing before DTSTART; mirrors the
--                                     `d < dtstart` skip in the TS expander)
--     d <= until_date                (UNTIL caps the occurrence START and is
--                                     INCLUSIVE)
--     d <  p_to_date  AND  d + duration > p_from_date      (overlaps the window)
--
-- PRECONDITION: the caller has already established rrule_sql_subset() and the
-- expansion cap. Violations RAISE. Returning an empty set instead would be
-- indistinguishable from "this series has no busy here", i.e. a silent
-- false-free, so a future miswiring must fail loudly (the RPC error surfaces in
-- the UI as a fetch failure, never as free time).
-- ============================================================================
create or replace function public.rrule_allday_occurrence_starts(
  p_rrule      text,
  p_all_day    boolean,
  p_start_date date,
  p_end_date   date,
  p_from_date  date,
  p_to_date    date
)
returns setof date
language plpgsql
stable
set search_path = ''
as $fn$
declare
  p      record;
  v_cnt  bigint;
  v_n    integer;
  v_d    integer;
  v_w0   date;
  v_lo   bigint;
  v_hi   bigint;
  v_offs integer[];
  v_i    bigint;
  v_b    integer;
  v_date date;
begin
  if p_all_day is not true
     or p_start_date is null or p_end_date is null
     or p_from_date is null or p_to_date is null
     or not public.rrule_sql_subset(p_rrule, p_all_day) then
    raise exception
      'rrule_allday_occurrence_starts: precondition violated (all-day row with non-null dates and rrule_sql_subset = true required)';
  end if;

  -- Defence in depth: the caller also checks the cap, but a runaway loop here
  -- would be far worse than a loud error.
  v_cnt := public.rrule_allday_occurrence_count(
             p_rrule, p_all_day, p_start_date, p_end_date, p_from_date, p_to_date);
  if v_cnt is null or v_cnt > public.rrule_allday_expansion_cap() then
    raise exception
      'rrule_allday_occurrence_starts: expansion cap exceeded (% candidates)', coalesce(v_cnt, -1);
  end if;

  select * into p from public.rrule_parse(p_rrule);
  v_n := p.interval_n;
  v_d := p_end_date - p_start_date;

  if p.freq = 'DAILY' then
    v_lo := greatest(0, floor((p_from_date - v_d - p_start_date)::numeric / v_n))::bigint;
    v_hi := floor((p_to_date - p_start_date)::numeric / v_n)::bigint;
    if p.until_date is not null then
      v_hi := least(v_hi, floor((p.until_date - p_start_date)::numeric / v_n)::bigint);
    end if;

    for v_i in v_lo .. v_hi loop
      v_date := p_start_date + (v_i * v_n)::integer;
      if v_date >= p_start_date
         and (p.until_date is null or v_date <= p.until_date)
         and v_date < p_to_date
         and v_date + v_d > p_from_date then
        return next v_date;
      end if;
    end loop;

  else
    -- WEEKLY. Offsets are 0 = Monday .. 6 = Sunday, matching the WEEKDAYS array
    -- order in src/types/recurrence.ts.
    if p.byday is null then
      v_offs := array[ extract(isodow from p_start_date)::integer - 1 ];
    else
      select array_agg(o.idx order by o.idx)
        into v_offs
      from (
        select array_position(array['MO','TU','WE','TH','FR','SA','SU'], tok) - 1 as idx
        from unnest(p.byday) as tok
      ) o;
    end if;

    v_w0 := p_start_date - (extract(isodow from p_start_date)::integer - 1);
    v_lo := greatest(0, floor((p_from_date - v_d - 7 - v_w0)::numeric / (7 * v_n)))::bigint;
    v_hi := (floor((p_to_date - v_w0)::numeric / (7 * v_n)) + 1)::bigint;
    if p.until_date is not null then
      v_hi := least(v_hi, floor((p.until_date - v_w0)::numeric / (7 * v_n))::bigint);
    end if;

    for v_i in v_lo .. v_hi loop
      foreach v_b in array v_offs loop
        v_date := v_w0 + (v_i * 7 * v_n + v_b)::integer;
        if v_date >= p_start_date
           and (p.until_date is null or v_date <= p.until_date)
           and v_date < p_to_date
           and v_date + v_d > p_from_date then
          return next v_date;
        end if;
      end loop;
    end loop;
  end if;

  return;
end;
$fn$;

-- ============================================================================
-- 4. get_free_busy: now expands all-day DAILY/WEEKLY recurrences.
--
-- SIGNATURE, RETURN SHAPE, ERROR CODES AND TOKEN BEHAVIOUR ARE UNCHANGED from
-- 0005/0006, so `create or replace` preserves the existing grants and the
-- frontend needs no change.
--
-- What changed relative to 0006:
--   * Step 3 (completeness) gains branches (B) and (C) and drops the blanket
--     "any exception makes it incomplete" rule -- exceptions are now computed
--     exactly, so their mere existence no longer forces incomplete.
--   * Step 4 (busy) gains two more all-day sources: master occurrences after
--     detach, and non-cancelled exception snapshots.
--   * Timed busy is untouched: single timed events only. Every timed recurrence
--     still forces complete=false via branch (A) or (C).
--
-- AFTER APPLYING, VERIFY there is exactly ONE get_free_busy and its grants
-- survived:
--   select proname, pg_get_function_identity_arguments(oid), proacl
--   from pg_proc where proname = 'get_free_busy';
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
  v_cap             constant integer := public.rrule_allday_expansion_cap();
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

  -- 3. Completeness. A row makes the answer incomplete when it could contribute
  --    busy to this window and we cannot account for it exactly.
  select not exists (
    select 1
    from public.events e
    where e.owner_id = v_owner
      and (v_include_private or e.visibility <> 'private')
      and (

        ----------------------------------------------------------------------
        -- (A) A recurring master that may reach the window but cannot be
        --     expanded: MONTHLY, COUNT, timed, malformed, unsupported, an
        --     UNTIL whose value type does not match all_day, or a rule whose
        --     expansion would exceed the runtime cap for THIS window.
        ----------------------------------------------------------------------
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
          and not (
                public.rrule_sql_subset(e.rrule, e.all_day)
            and coalesce(
                  public.rrule_allday_occurrence_count(
                    e.rrule, e.all_day, e.start_date, e.end_date, p_from_date, p_to_date),
                  v_cap + 1) <= v_cap
          )
        )

        or

        ----------------------------------------------------------------------
        -- (B) Integrity guard: an exception whose all_day disagrees with its
        --     master. The DB CHECKs constrain each row alone, not the pair, so
        --     this shape is reachable. Its slot key is then the wrong type to
        --     detach with, and its own snapshot cannot be placed either.
        --
        --     Window relevance is "snapshot overlaps the window OR the slot may
        --     touch it" -- the SAME conservative slot test as (C-2). A mismatched
        --     exception affects this window structurally (it detaches, or fails
        --     to detach, an occurrence here) even when its own snapshot sits
        --     entirely outside; keying only on the snapshot would let that slip
        --     through as complete=true.
        ----------------------------------------------------------------------
        ( e.recurrence_id is not null
          and exists (
            select 1
            from public.events m
            where m.id = e.recurrence_id
              and e.all_day is distinct from m.all_day
              and (
                    -- (B-1) the exception's own snapshot overlaps the window
                    (
                      (e.all_day = false and e.start_at < p_to and e.end_at > p_from)
                      or (e.all_day = true and e.start_date < p_to_date and e.end_date > p_from_date)
                    )
                    -- (B-2) the slot it points at may touch the window. Uses the
                    --       PARENT's duration where readable; over-approximates
                    --       (assumes it touches) when the parent is timed or its
                    --       shape is unreadable.
                 or (
                      e.recurrence_slot_date is not null
                      and e.recurrence_slot_date < p_to_date
                      and (
                            m.all_day is not true
                            or m.start_date is null or m.end_date is null
                            or e.recurrence_slot_date + (m.end_date - m.start_date) > p_from_date
                          )
                    )
                 or (
                      e.recurrence_slot_start is not null
                      and e.recurrence_slot_start < p_to
                    )
              )
          )
        )

        or

        ----------------------------------------------------------------------
        -- (C) An exception that touches this window -- either because its own
        --     snapshot lands here, or because the slot it detaches would have
        --     -- while its parent series cannot be expanded.
        --
        --     The parent's VISIBILITY is deliberately ignored: "may we disclose
        --     the master's snapshots" and "can we account for the series this
        --     disclosed exception belongs to" are different questions. Without
        --     this branch a private unsupported master could hide behind a
        --     visible exception and still report complete=true.
        --
        --     Note the slot test uses the PARENT's duration: an occurrence spans
        --     [slot, slot + duration), so a multi-day master can reach into the
        --     window from a slot that sits before it. Where the parent's shape
        --     is unknown (or timed) we over-approximate and assume it touches.
        ----------------------------------------------------------------------
        ( e.recurrence_id is not null
          and exists (
            select 1
            from public.events m
            where m.id = e.recurrence_id
              and (
                    -- (C-1) the exception's own snapshot overlaps the window
                    (
                      (e.all_day = false and e.start_at < p_to and e.end_at > p_from)
                      or (e.all_day = true and e.start_date < p_to_date and e.end_date > p_from_date)
                    )
                    -- (C-2) the detached slot's original occurrence touches it
                 or (
                      e.recurrence_slot_date is not null
                      and e.recurrence_slot_date < p_to_date
                      and (
                            m.all_day is not true
                            or m.start_date is null or m.end_date is null
                            or e.recurrence_slot_date + (m.end_date - m.start_date) > p_from_date
                          )
                    )
                 or (
                      e.recurrence_slot_start is not null
                      and e.recurrence_slot_start < p_to
                    )
              )
              and not (
                    public.rrule_definitely_ends_before(
                      m.rrule, m.all_day,
                      m.start_date, m.end_date,
                      m.start_at,   m.end_at,
                      p_from,       p_from_date)
                or (
                      public.rrule_sql_subset(m.rrule, m.all_day)
                  and coalesce(
                        public.rrule_allday_occurrence_count(
                          m.rrule, m.all_day, m.start_date, m.end_date, p_from_date, p_to_date),
                        v_cap + 1) <= v_cap
                )
              )
          )
        )
      )
  )
  into v_complete;

  -- 4. Busy intervals. Timed: single events only (unchanged). All-day: single
  --    events, expanded master occurrences after detach, and non-cancelled
  --    exception snapshots -- merged together so nothing about event count or
  --    individual boundaries survives. Titles/ids/categories are never read.
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

  -- Masters this migration can expand exactly, for THIS window.
  expandable_master as (
    select e.id, e.rrule, e.start_date, e.end_date
    from public.events e
    where e.owner_id = v_owner
      and e.rrule is not null
      and e.all_day = true
      and (v_include_private or e.visibility <> 'private')
      and e.start_date < p_to_date
      and public.rrule_sql_subset(e.rrule, e.all_day)
      and coalesce(
            public.rrule_allday_occurrence_count(
              e.rrule, e.all_day, e.start_date, e.end_date, p_from_date, p_to_date),
            v_cap + 1) <= v_cap
  ),

  -- Generated occurrences, minus every slot an exception has taken over.
  -- The anti-join deliberately has NO visibility and NO is_cancelled filter:
  -- detaching is a structural fact about the series, and a private or cancelled
  -- exception removes the original occurrence just the same.
  master_occ as (
    select s.d as sd0, s.d + (m.end_date - m.start_date) as ed0
    from expandable_master m
    cross join lateral public.rrule_allday_occurrence_starts(
      m.rrule, true, m.start_date, m.end_date, p_from_date, p_to_date) as s(d)
    where not exists (
      select 1
      from public.events x
      where x.recurrence_id = m.id
        and x.recurrence_slot_date = s.d
    )
  ),

  -- Exception snapshots. THIS is where visibility applies: whether to disclose
  -- this particular event. Evaluated independently of whether the parent master
  -- was expandable, because the snapshot itself is exact either way.
  exception_busy as (
    select e.start_date as sd0, e.end_date as ed0
    from public.events e
    where e.owner_id = v_owner
      and e.recurrence_id is not null
      and e.is_cancelled = false
      and e.all_day = true
      and (v_include_private or e.visibility <> 'private')
      and e.start_date < p_to_date
      and e.end_date   > p_from_date
  ),

  allday_src as (
    select e.start_date as sd0, e.end_date as ed0
    from public.events e
    where e.owner_id = v_owner
      and e.rrule is null
      and e.recurrence_id is null
      and e.all_day = true
      and (v_include_private or e.visibility <> 'private')
      and e.start_date < p_to_date
      and e.end_date   > p_from_date
    union all
    select sd0, ed0 from master_occ
    union all
    select sd0, ed0 from exception_busy
  ),
  allday_raw as (
    select greatest(sd0, p_from_date) as sd, least(ed0, p_to_date) as ed
    from allday_src
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
-- The new helpers join the 0006 ones as internal-only: no grants to anon or
-- authenticated, and not SECURITY DEFINER, because they read no tables and need
-- no elevated rights. get_free_busy calls them as the definer, by ownership.
--
-- get_free_busy keeps the grants it already has: `create or replace` preserves
-- privileges, so 0005's `grant ... to anon, authenticated` still holds and is
-- intentionally NOT repeated here.
-- ============================================================================
revoke execute on function public.rrule_allday_expansion_cap() from public;
revoke execute on function public.rrule_allday_occurrence_count(
  text, boolean, date, date, date, date
) from public;
revoke execute on function public.rrule_allday_occurrence_starts(
  text, boolean, date, date, date, date
) from public;
