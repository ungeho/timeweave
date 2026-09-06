-- TimeWeave Phase 5b-3: expand TIMED DAILY/WEEKLY recurrences into Free/Busy,
-- anchored to the time zone persisted by 0008.
--
-- SCOPE (deliberately narrow; everything else keeps 5b-1 behaviour):
--   expanded : timed masters with FREQ=DAILY or FREQ=WEEKLY, INTERVAL, BYDAY
--              (WEEKLY only) and an INSTANT-form UNTIL, whose timezone is
--              non-null and resolvable on THIS server, plus their exception
--              rows.
--   NOT yet  : COUNT, FREQ=MONTHLY, legacy M0 masters (timezone IS NULL) and
--              any zone this server cannot resolve. These stay fail-closed:
--              they force complete=false and contribute no slots.
--   UNCHANGED: the whole all-day path from 0007, byte for byte, apart from the
--              two places where "is this master expandable" now dispatches on
--              all_day.
--
-- TIME ZONE SEMANTICS (measured on the target server, pinned by the 0009
-- preflight -- see supabase/tests/0009_timed_recurrence_freebusy_preflight.sql):
--   A timed series repeats at a WALL-CLOCK time in its master timezone, so the
--   UTC instant of an occurrence moves across a DST transition. Occurrences are
--   therefore generated in `timestamp` (no zone) space and converted with
--   `AT TIME ZONE`, whose resolution of the two awkward cases IS TimeWeave
--   semantics:
--     gap  (a local time that does not exist)  -> standard-time offset, which
--          moves the occurrence FORWARD past the transition.
--     fold (a local time that happens twice)   -> standard-time offset, i.e.
--          the LATER of the two instants.
--   Neither is invented here and neither is overridden.
--
-- DTSTART IS NEVER RECONSTRUCTED (the fold hazard):
--   `start_at` is a stored instant. Rendering it in the master zone and
--   converting back is LOSSY exactly on a fold: a master stored at
--   2026-11-01 05:30Z renders as 01:30 in America/New_York, and 01:30 converts
--   back to 06:30Z -- moving DTSTART itself by an hour. So the occurrence whose
--   local timestamp equals DTSTART's local timestamp emits the STORED
--   `start_at` verbatim; every other occurrence is built from wall clock. That
--   candidate is unique, because all candidates share DTSTART's time of day and
--   differ only in date.
--
-- DURATION IS ABSOLUTE:
--   Occurrence end is start + (end_at - start_at) IN SECONDS. Adding a
--   day-bearing interval to a timestamptz is calendar arithmetic that depends
--   on the TimeZone GUC and absorbs DST transitions; seconds do not. This
--   matches rrule_definitely_ends_before (0006) and the TypeScript expander,
--   which adds a fixed durationMs.
--
-- THE INVARIANT THIS FILE PROTECTS (unchanged from 0007):
--   Never report free where a DISCLOSABLE busy exists. Anything that cannot be
--   computed exactly forces complete=false; the busy set is never truncated,
--   clamped or approximated downward. The closed-form index ranges are
--   deliberately WIDER than needed and exactness comes from the per-candidate
--   filter that follows.
--
-- EXCEPTION SLOTS ARE VERIFIED, NOT ASSUMED (see step 3d in get_free_busy):
--   An exception detaches its master occurrence by matching
--   recurrence_slot_start against a generated instant. A slot that overlaps the
--   window but matches NO generated occurrence means this server and whatever
--   wrote the slot disagree about where the occurrence is -- which is exactly
--   what the TypeScript expander does today on a fold, because it resolves
--   ambiguity differently (Phase 5b-4). That disagreement is reported as
--   complete=false. It is NOT assumed to be harmless in either direction.
--
-- Security: unchanged from 0005-0008. The new helpers read no tables, are not
-- SECURITY DEFINER, and are granted to nobody; get_free_busy remains the single
-- function anon can reach, with its argument names, signature, JSON shape,
-- token behaviour and 92-day limit untouched.

-- ============================================================================
-- 1. rrule_timed_expansion_cap: the runtime safety cap for TIMED expansion.
--
-- Separate from rrule_allday_expansion_cap() on purpose, at the same value, so
-- the two can be tuned independently later. Same contract: exceeding it NEVER
-- truncates the busy set -- the master is simply not expanded and the window is
-- reported complete=false. A runtime, window-dependent judgement, kept strictly
-- apart from rrule_timed_sql_subset(), which answers the window-independent
-- question "is this grammar supported at all".
-- ============================================================================
create or replace function public.rrule_timed_expansion_cap()
returns integer
language sql
immutable
set search_path = ''
as $fn$ select 5000 $fn$;

-- ============================================================================
-- 2. timezone_is_resolvable: can THIS SERVER, RIGHT NOW, convert with this zone?
--
-- timezone_is_supported (0008) is the write-path authority on which names are
-- allowed to be stored: it refuses abbreviations, posix/ and right/ spellings,
-- localtime, and anything absent from pg_timezone_names. That policy is not
-- reimplemented here -- this function calls it and adds one thing on top: proof
-- that the AT TIME ZONE operator actually accepts the name on this server.
--
-- WHY THE EXTRA STEP: a name stored years ago can be retired by a tzdata
-- update, and TimeWeave never rewrites a stored zone. Reading such a row is
-- DATA DRIFT, not a bug, and the anonymous Free/Busy RPC must answer
-- "this series is unsupported" (complete=false) instead of raising. Nothing may
-- reach AT TIME ZONE without passing here first.
--
-- WHAT THE PROBE ESTABLISHES, and nothing more: that BOTH directions of the
-- AT TIME ZONE operator accept this zone NAME on this server right now. The two
-- directions are different operators, so both are exercised. The value is a
-- fixed constant chosen only for reproducibility; no claim is made about it
-- being unambiguous, or a real local time, in any particular zone. Ambiguity
-- and gaps are not errors -- they resolve to an instant, which is exactly the
-- semantics this migration adopts -- so they cannot affect the answer here.
--
-- EXCEPTION SCOPE: this block is the ONLY place in 0009 that catches anything,
-- and it catches ONLY invalid_parameter_value, the code AT TIME ZONE raises for
-- an unrecognised zone. Every other error propagates: swallowing more would
-- turn programming faults into silent NULLs. Callers therefore need no handler
-- of their own -- they ask this question first and act on the answer.
--
-- One subtransaction per call, never per occurrence.
-- ============================================================================
create or replace function public.timezone_is_resolvable(p_tz text)
returns boolean
language plpgsql
stable
set search_path = ''
as $fn$
declare
  v_local   timestamp;
  v_instant timestamptz;
begin
  if p_tz is null then return false; end if;
  if not public.timezone_is_supported(p_tz) then return false; end if;

  begin
    v_instant := timestamp   '2000-06-15 12:00:00'    at time zone p_tz;
    v_local   := timestamptz '2000-06-15 12:00:00+00' at time zone p_tz;
  exception
    when invalid_parameter_value then
      return false;
  end;

  return v_instant is not null and v_local is not null;
end;
$fn$;

-- ============================================================================
-- 3. rrule_timed_sql_subset: POLICY. Is this rule, on a TIMED row, inside the
--    subset 0009 can expand?
--
-- Deliberately mirrors rrule_sql_subset (0006) in shape and says nothing about
-- the time zone: this function answers the GRAMMAR question only.
--
-- Zone usability is a separate question with its own authority,
-- timezone_is_resolvable (section 2), which wraps the 0008 storage policy and
-- adds a live AT TIME ZONE probe. Keeping the two apart is what lets
-- get_free_busy hoist the zone check out of its row filters -- it collects the
-- owner distinct zones once -- without any caller having to reimplement policy.
--
-- The full gate a caller must apply is therefore
--     rrule_timed_sql_subset  AND  timezone_is_resolvable  AND  within cap
-- and no layer trusts another to have applied it: get_free_busy filters on all
-- three, and rrule_timed_occurrence_count / _starts re-check the zone
-- themselves, so calling either one directly is safe as well.
--
-- 5b-3 subset: timed + DAILY/WEEKLY + no COUNT + UNTIL absent or in INSTANT
-- form. MONTHLY and COUNT stay outside, exactly as for all-day.
-- ============================================================================
create or replace function public.rrule_timed_sql_subset(
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
       and p_all_day is false              -- all-day rows go through 0007
       and p.until_date is null            -- a timed series must not carry a DATE UNTIL
    from public.rrule_parse(p_rrule) p
  ), false);
$fn$;

-- ============================================================================
-- 4. rrule_timed_occurrence_count: how many candidates WOULD be generated.
--
-- Closed form, computed WITHOUT generating anything, so the cap can be checked
-- before any work happens. An upper bound on the candidate set before the exact
-- per-occurrence filter, which is what a safety cap wants.
--
-- The index range is derived in the master zone, from the window converted to
-- LOCAL DATES and then widened by one day at each end. That margin absorbs
-- every offset a zone can apply (always less than a day), so no candidate that
-- could overlap the window is ever excluded here; exactness comes from the
-- instant-space filter in rrule_timed_occurrence_starts.
--
-- Returns NULL when the rule is outside the timed subset, the zone is null or
-- no longer resolvable on this server, or an argument is missing. Callers must
-- treat NULL as "over cap" (coalesce(..., cap + 1)), never as zero.
--
-- Not STRICT: see rrule_parse in 0006. NULL arguments must reach the body so
-- the NULL return is a decision, not an accident of the call convention.
-- ============================================================================
create or replace function public.rrule_timed_occurrence_count(
  p_rrule    text,
  p_all_day  boolean,
  p_start_at timestamptz,
  p_end_at   timestamptz,
  p_timezone text,
  p_from     timestamptz,
  p_to       timestamptz
)
returns bigint
language plpgsql
stable
set search_path = ''
as $fn$
declare
  p        record;
  v_n      integer;
  v_b      integer;
  v_d0     date;
  v_w0     date;
  v_durs   numeric;
  v_durd   integer;
  v_fromd  date;
  v_tod    date;
  v_untild date;
  v_lo     numeric;
  v_hi     numeric;
begin
  if p_all_day is not false then return null; end if;
  if p_start_at is null or p_end_at is null
     or p_from is null or p_to is null then
    return null;
  end if;
  -- Data drift, not a caller fault: a zone stored when it was valid can stop
  -- resolving. NULL is the fail-closed answer, and the caller's
  -- coalesce(count, cap + 1) rule turns it into complete=false. No exception
  -- handler is added anywhere below: an invalid_parameter_value that is NOT
  -- about the zone would be a programming fault and must stay visible.
  if p_timezone is null or not public.timezone_is_resolvable(p_timezone) then
    return null;
  end if;
  if not public.rrule_timed_sql_subset(p_rrule, p_all_day) then return null; end if;

  select * into p from public.rrule_parse(p_rrule);

  v_n     := p.interval_n;
  v_durs  := extract(epoch from (p_end_at - p_start_at));
  v_durd  := ceil(v_durs / 86400.0)::integer;   -- whole days the span can cover
  v_d0    := (p_start_at at time zone p_timezone)::date;
  v_fromd := (p_from at time zone p_timezone)::date - 1;
  v_tod   := (p_to   at time zone p_timezone)::date + 1;
  if p.until_ts is not null then
    v_untild := (p.until_ts at time zone p_timezone)::date;
  end if;

  -- NOTE ON DIVISION: every quotient is cast to numeric before floor().
  -- Postgres integer division truncates TOWARD ZERO, not downward, so on a
  -- negative numerator (a series starting after the window) integer maths would
  -- round the range inward and drop occurrences -- a false-free.
  if p.freq = 'DAILY' then
    v_lo := greatest(0, floor((v_fromd - v_durd - v_d0)::numeric / v_n));
    v_hi := floor((v_tod - v_d0)::numeric / v_n);
    if v_untild is not null then
      v_hi := least(v_hi, floor((v_untild - v_d0)::numeric / v_n));
    end if;
    return greatest(0, v_hi - v_lo + 1)::bigint;
  else
    -- BYDAY omitted means "the weekday of DTSTART", i.e. exactly one per week.
    v_b  := coalesce(array_length(p.byday, 1), 1);
    -- Week anchor: the Monday of DTSTART's LOCAL week (RFC 5545 default
    -- WKST=MO), the same anchor 0007 and services/recurrence.ts use.
    v_w0 := v_d0 - (extract(isodow from v_d0)::integer - 1);
    v_lo := greatest(0, floor((v_fromd - v_durd - 7 - v_w0)::numeric / (7 * v_n)));
    v_hi := floor((v_tod - v_w0)::numeric / (7 * v_n)) + 1;
    if v_untild is not null then
      v_hi := least(v_hi, floor((v_untild - v_w0)::numeric / (7 * v_n)));
    end if;
    return greatest(0, (v_hi - v_lo + 1) * v_b)::bigint;
  end if;
end;
$fn$;

-- ============================================================================
-- 5. rrule_timed_occurrence_starts: the occurrence START instants that can
--    touch the window, ascending.
--
-- Each occurrence spans [start, start + duration) with duration in absolute
-- seconds, so an instant is emitted when
--     start >= p_start_at            (nothing before DTSTART; mirrors the
--                                     `d < dtstart` skip in the TS expander)
--     start <= until_ts              (UNTIL is INCLUSIVE and caps the START)
--     start <  p_to  AND  start + duration > p_from      (overlaps the window)
--
-- DTSTART: the candidate whose LOCAL timestamp equals DTSTART's local timestamp
-- emits the stored p_start_at unchanged. Round-tripping it through the zone
-- would move it by an hour whenever it sits on a fold, and the stored instant
-- is the authority for that one occurrence. Candidates all share DTSTART's time
-- of day, so that candidate is unique.
--
-- TWO CLASSES OF REFUSAL (see the bodies of the two guards below):
--   caller wiring (shape, window, rule outside the subset, cap exceeded)
--     -> RAISE. An empty set would be indistinguishable from "no busy here",
--        so a miswiring must fail loudly; the RPC error surfaces in the UI as a
--        fetch failure, never as free time.
--   data or environment drift (no zone, or a zone this server can no longer
--   resolve)
--     -> return NO ROWS, never raise. Paired with a NULL from
--        rrule_timed_occurrence_count, which forces complete=false.
--
-- The occurrence loop has NO exception handler on purpose: rows already emitted
-- with RETURN NEXT survive a caught exception, so catching one there could return a
-- TRUNCATED busy set -- the exact false-free this file exists to prevent. The
-- zone is therefore validated before the loop, and anything unexpected inside
-- it fails loudly.
-- ============================================================================
create or replace function public.rrule_timed_occurrence_starts(
  p_rrule    text,
  p_all_day  boolean,
  p_start_at timestamptz,
  p_end_at   timestamptz,
  p_timezone text,
  p_from     timestamptz,
  p_to       timestamptz
)
returns setof timestamptz
language plpgsql
stable
set search_path = ''
as $fn$
declare
  p        record;
  v_cnt    bigint;
  v_n      integer;
  v_b      integer;
  v_d0     date;
  v_w0     date;
  v_tod0   time;
  v_durs   numeric;
  v_dur    interval;
  v_durd   integer;
  v_dtl    timestamp;
  v_fromd  date;
  v_tod    date;
  v_untild date;
  v_lo     bigint;
  v_hi     bigint;
  v_offs   integer[];
  v_i      bigint;
  v_off    integer;
  v_cl     timestamp;
  v_start  timestamptz;
begin
  -- CLASS 1 -- caller wiring. Returning an empty set for these would be
  -- indistinguishable from "this series has no busy here", i.e. a silent
  -- false-free, so they fail loudly.
  if p_all_day is not false
     or p_start_at is null or p_end_at is null
     or p_from is null or p_to is null
     or not public.rrule_timed_sql_subset(p_rrule, p_all_day) then
    raise exception
      'rrule_timed_occurrence_starts: precondition violated (timed row with non-null instants and rrule_timed_sql_subset = true required)';
  end if;

  -- CLASS 2 -- data or environment drift. A zone that was storable when the row
  -- was written can stop resolving later, and a legacy M0 master carries none at
  -- all. Neither is a fault, and neither may take the anonymous Free/Busy RPC
  -- down, so this returns NO ROWS instead of raising.
  --
  -- That empty result cannot be mistaken for "no busy": for exactly these inputs
  -- rrule_timed_occurrence_count returns NULL, and the caller's
  -- coalesce(count, cap + 1) rule has already forced complete=false. The 0009
  -- test suite pins that pairing.
  --
  -- Checked BEFORE the cap probe below, which would otherwise report a NULL
  -- count as a cap violation and raise.
  if p_timezone is null or not public.timezone_is_resolvable(p_timezone) then
    return;
  end if;

  -- Defence in depth: the caller also checks the cap, but a runaway loop here
  -- would be far worse than a loud error.
  v_cnt := public.rrule_timed_occurrence_count(
             p_rrule, p_all_day, p_start_at, p_end_at, p_timezone, p_from, p_to);
  if v_cnt is null or v_cnt > public.rrule_timed_expansion_cap() then
    raise exception
      'rrule_timed_occurrence_starts: expansion cap exceeded (% candidates)', coalesce(v_cnt, -1);
  end if;

  select * into p from public.rrule_parse(p_rrule);

  v_n     := p.interval_n;
  v_durs  := extract(epoch from (p_end_at - p_start_at));
  v_dur   := make_interval(secs => v_durs::double precision);
  v_durd  := ceil(v_durs / 86400.0)::integer;
  v_dtl   := p_start_at at time zone p_timezone;
  v_d0    := v_dtl::date;
  v_tod0  := v_dtl::time;
  v_fromd := (p_from at time zone p_timezone)::date - 1;
  v_tod   := (p_to   at time zone p_timezone)::date + 1;
  if p.until_ts is not null then
    v_untild := (p.until_ts at time zone p_timezone)::date;
  end if;

  if p.freq = 'DAILY' then
    v_lo := greatest(0, floor((v_fromd - v_durd - v_d0)::numeric / v_n))::bigint;
    v_hi := floor((v_tod - v_d0)::numeric / v_n)::bigint;
    if v_untild is not null then
      v_hi := least(v_hi, floor((v_untild - v_d0)::numeric / v_n)::bigint);
    end if;

    for v_i in v_lo .. v_hi loop
      v_cl := (v_d0 + (v_i * v_n)::integer) + v_tod0;
      -- DTSTART keeps its stored instant; see the header note on folds.
      if v_cl = v_dtl then
        v_start := p_start_at;
      else
        v_start := v_cl at time zone p_timezone;
      end if;
      if v_start >= p_start_at
         and (p.until_ts is null or v_start <= p.until_ts)
         and v_start < p_to
         and v_start + v_dur > p_from then
        return next v_start;
      end if;
    end loop;

  else
    -- WEEKLY. Offsets are 0 = Monday .. 6 = Sunday, matching the WEEKDAYS array
    -- order in src/types/recurrence.ts.
    if p.byday is null then
      v_offs := array[ extract(isodow from v_d0)::integer - 1 ];
    else
      select array_agg(o.idx order by o.idx)
        into v_offs
      from (
        select array_position(array['MO','TU','WE','TH','FR','SA','SU'], tok) - 1 as idx
        from unnest(p.byday) as tok
      ) o;
    end if;

    v_w0 := v_d0 - (extract(isodow from v_d0)::integer - 1);
    v_lo := greatest(0, floor((v_fromd - v_durd - 7 - v_w0)::numeric / (7 * v_n)))::bigint;
    v_hi := (floor((v_tod - v_w0)::numeric / (7 * v_n)) + 1)::bigint;
    if v_untild is not null then
      v_hi := least(v_hi, floor((v_untild - v_w0)::numeric / (7 * v_n))::bigint);
    end if;

    for v_i in v_lo .. v_hi loop
      foreach v_off in array v_offs loop
        v_cl := (v_w0 + (v_i * 7 * v_n + v_off)::integer) + v_tod0;
        if v_cl = v_dtl then
          v_start := p_start_at;
        else
          v_start := v_cl at time zone p_timezone;
        end if;
        if v_start >= p_start_at
           and (p.until_ts is null or v_start <= p.until_ts)
           and v_start < p_to
           and v_start + v_dur > p_from then
          return next v_start;
        end if;
      end loop;
    end loop;
  end if;

  return;
end;
$fn$;

-- ============================================================================
-- 6. get_free_busy: now expands TIMED DAILY/WEEKLY recurrences as well.
--
-- SIGNATURE, ARGUMENT NAMES, RETURN SHAPE, ERROR CODES AND TOKEN BEHAVIOUR ARE
-- UNCHANGED from 0005/0006/0007, so `create or replace` preserves the existing
-- grants and the frontend needs no change. The five parameter names stay
-- p_token, p_from, p_to, p_from_date, p_to_date: PostgREST passes arguments by
-- name, and `create or replace` cannot rename an existing parameter anyway.
--
-- What changed relative to 0007:
--   * A new step 2b resolves the owner's distinct time zones ONCE.
--   * Step 3 branch (A) and branch (C) now dispatch on all_day when asking
--     whether a master is expandable; the all-day arm is the 0007 expression
--     verbatim.
--   * A new step 3d reports a window incomplete when an exception slot that
--     overlaps it matches no generated occurrence.
--   * Step 4 gains two timed sources: expanded master occurrences after detach,
--     and non-cancelled timed exception snapshots.
--   * The all-day busy pipeline is untouched.
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
  v_slot_mismatch   boolean;
  v_ok_tz           text[];
  v_cap             constant integer := public.rrule_allday_expansion_cap();
  v_timed_cap       constant integer := public.rrule_timed_expansion_cap();
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

  -- 2b. The zones this server can actually resolve right now, collected once
  --     per DISTINCT zone rather than once per row: timezone_is_resolvable
  --     scans pg_timezone_names and probes AT TIME ZONE, and an unbounded
  --     catalog scan per table row does not belong on an anonymous code path.
  --
  --     THIS IS A HOIST, NOT THE ONLY CHECK. rrule_timed_occurrence_count and
  --     rrule_timed_occurrence_starts each re-validate the zone independently,
  --     as defence in depth, so the real number of validations is one per
  --     distinct zone here plus one per expandable master inside each helper.
  --     Neither layer relies on the other: this one keeps unusable zones out of
  --     the row sets structurally, and the helpers stay safe when called alone.
  select coalesce(array_agg(t.tz), array[]::text[])
    into v_ok_tz
  from (
    select distinct e.timezone as tz
    from public.events e
    where e.owner_id = v_owner
      and e.all_day = false
      and e.rrule is not null
      and e.timezone is not null
  ) t
  where public.timezone_is_resolvable(t.tz);

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
                case when e.all_day is true then
                       public.rrule_sql_subset(e.rrule, e.all_day)
                       and coalesce(
                             public.rrule_allday_occurrence_count(
                               e.rrule, e.all_day, e.start_date, e.end_date,
                               p_from_date, p_to_date),
                             v_cap + 1) <= v_cap
                     else
                       -- 5b-3: a timed master is expandable only with a rule in
                       -- the timed subset AND a zone this server resolves. M0
                       -- (timezone IS NULL) fails the second test, so a legacy
                       -- master keeps forcing complete=false.
                       public.rrule_timed_sql_subset(e.rrule, e.all_day)
                       and e.timezone = any(v_ok_tz)
                       and coalesce(
                             public.rrule_timed_occurrence_count(
                               e.rrule, e.all_day, e.start_at, e.end_at, e.timezone,
                               p_from, p_to),
                             v_timed_cap + 1) <= v_timed_cap
                end
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
                      case when m.all_day is true then
                             public.rrule_sql_subset(m.rrule, m.all_day)
                             and coalesce(
                                   public.rrule_allday_occurrence_count(
                                     m.rrule, m.all_day, m.start_date, m.end_date,
                                     p_from_date, p_to_date),
                                   v_cap + 1) <= v_cap
                           else
                             public.rrule_timed_sql_subset(m.rrule, m.all_day)
                             and m.timezone = any(v_ok_tz)
                             and coalesce(
                                   public.rrule_timed_occurrence_count(
                                     m.rrule, m.all_day, m.start_at, m.end_at, m.timezone,
                                     p_from, p_to),
                                   v_timed_cap + 1) <= v_timed_cap
                      end
                )
              )
          )
        )
      )
  )
  into v_complete;

  -- 3d. Exception slots that this server cannot account for.
  --
  --     An exception detaches its master occurrence by matching
  --     recurrence_slot_start against a generated instant. If a slot overlaps
  --     this window but equals NO generated occurrence, then whatever wrote the
  --     slot and this server disagree about where that occurrence is, and the
  --     busy set here is not the one the owner sees. The TypeScript expander
  --     does exactly that today on a DST fold, because it resolves an ambiguous
  --     local time to the other instant (Phase 5b-4).
  --
  --     Such a window is reported incomplete. No assumption is made about which
  --     direction the disagreement errs in.
  --
  --     The master VISIBILITY filter is deliberate here, unlike in the detach
  --     anti-join: this asks whether the DISCLOSED busy set is wrong, and a
  --     master excluded by include_private contributes nothing to disclose.
  --     A missing slot key on a same-shape exception counts as a mismatch too.
  with expandable as materialized (   -- see step 4: filters complete before LATERAL
    select m.id, m.rrule, m.all_day, m.start_at, m.end_at, m.timezone,
           make_interval(secs => extract(epoch from (m.end_at - m.start_at))::double precision) as dur
    from public.events m
    where m.owner_id = v_owner
      and m.rrule is not null
      and m.all_day = false
      and (v_include_private or m.visibility <> 'private')
      and m.start_at < p_to
      and m.timezone = any(v_ok_tz)
      and public.rrule_timed_sql_subset(m.rrule, m.all_day)
      and coalesce(
            public.rrule_timed_occurrence_count(
              m.rrule, m.all_day, m.start_at, m.end_at, m.timezone, p_from, p_to),
            v_timed_cap + 1) <= v_timed_cap
  ),
  generated as (
    select m.id, m.dur, array_agg(s.t) as starts
    from expandable m
    cross join lateral public.rrule_timed_occurrence_starts(
      m.rrule, m.all_day, m.start_at, m.end_at, m.timezone, p_from, p_to) as s(t)
    group by m.id, m.dur
  )
  select exists (
    select 1
    from expandable m
    join public.events x
      on x.recurrence_id = m.id
     and x.all_day = false
    left join generated g on g.id = m.id
    where (
            x.recurrence_slot_start is null
         or (
              x.recurrence_slot_start < p_to
              and x.recurrence_slot_start + m.dur > p_from
              and not (x.recurrence_slot_start = any(coalesce(g.starts, array[]::timestamptz[])))
            )
          )
  )
  into v_slot_mismatch;

  v_complete := v_complete and not v_slot_mismatch;

  -- 4. Busy intervals. Both time models now draw from three sources: single
  --    events, expanded master occurrences after detach, and non-cancelled
  --    exception snapshots -- merged per model so nothing about event count or
  --    individual boundaries survives. Titles/ids/categories are never read.
  with timed_single as (
    select e.start_at as s0, e.end_at as t0
    from public.events e
    where e.owner_id = v_owner
      and e.rrule is null
      and e.recurrence_id is null
      and e.all_day = false
      and (v_include_private or e.visibility <> 'private')
      and e.start_at < p_to
      and e.end_at   > p_from
  ),

  -- Timed masters this migration can expand exactly, for THIS window. The zone
  -- gate is the hoisted v_ok_tz, so M0 and unresolvable zones drop out here and
  -- are accounted for by branch (A) instead.
  --
  -- MATERIALIZED on purpose: every filter -- zone, subset and cap -- must be
  -- fully applied BEFORE the LATERAL expansion below runs. Without it the
  -- planner may inline this CTE and evaluate the set-returning function for
  -- rows it has not filtered yet. The helper tolerates that (an unusable zone
  -- yields no rows rather than an error), but the RPC does not depend on the
  -- helper being forgiving, nor on evaluation order.
  timed_expandable_master as materialized (
    select e.id, e.rrule, e.all_day, e.start_at, e.end_at, e.timezone,
           make_interval(secs => extract(epoch from (e.end_at - e.start_at))::double precision) as dur
    from public.events e
    where e.owner_id = v_owner
      and e.rrule is not null
      and e.all_day = false
      and (v_include_private or e.visibility <> 'private')
      and e.start_at < p_to
      and e.timezone = any(v_ok_tz)
      and public.rrule_timed_sql_subset(e.rrule, e.all_day)
      and coalesce(
            public.rrule_timed_occurrence_count(
              e.rrule, e.all_day, e.start_at, e.end_at, e.timezone, p_from, p_to),
            v_timed_cap + 1) <= v_timed_cap
  ),

  -- Generated occurrences, minus every slot an exception has taken over. The
  -- anti-join deliberately has NO visibility and NO is_cancelled filter:
  -- detaching is a structural fact about the series, and a private or cancelled
  -- exception removes the original occurrence just the same. Slots that match
  -- nothing are handled by step 3d, not here.
  timed_master_occ as (
    select s.t as s0, s.t + m.dur as t0
    from timed_expandable_master m
    cross join lateral public.rrule_timed_occurrence_starts(
      m.rrule, m.all_day, m.start_at, m.end_at, m.timezone, p_from, p_to) as s(t)
    where not exists (
      select 1
      from public.events x
      where x.recurrence_id = m.id
        and x.recurrence_slot_start = s.t
    )
  ),

  -- Timed exception snapshots. Visibility applies here -- whether to disclose
  -- this particular event -- and is evaluated independently of whether the
  -- parent was expandable, because a snapshot pins absolute instants either way.
  timed_exception_busy as (
    select e.start_at as s0, e.end_at as t0
    from public.events e
    where e.owner_id = v_owner
      and e.recurrence_id is not null
      and e.is_cancelled = false
      and e.all_day = false
      and (v_include_private or e.visibility <> 'private')
      and e.start_at < p_to
      and e.end_at   > p_from
  ),

  timed_src as (
    select s0, t0 from timed_single
    union all
    select s0, t0 from timed_master_occ
    union all
    select s0, t0 from timed_exception_busy
  ),
  timed_raw as (
    select greatest(s0, p_from) as s, least(t0, p_to) as t
    from timed_src
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
-- 7. EXECUTE privileges.
--
-- The new helpers join the 0006/0007 ones as internal-only: no grants to anon
-- or authenticated, and not SECURITY DEFINER, because they read no tables and
-- need no elevated rights. get_free_busy calls them as the definer, by
-- ownership.
--
-- timezone_is_resolvable joins them: it is called only from get_free_busy and
-- from the two helpers above, all of which run as the definer. It is NOT
-- granted to authenticated, because the write path validates zones through the
-- 0008 trigger and timezone_is_supported, which are unchanged.
--
-- timezone_is_supported (0008) needs no new grant either: it is already granted
-- to authenticated for the write path, and get_free_busy reaches it as the
-- definer.
--
-- get_free_busy keeps the grants it already has: `create or replace` preserves
-- privileges, so 0005's `grant ... to anon, authenticated` still holds and is
-- intentionally NOT repeated here.
-- ============================================================================
revoke execute on function public.timezone_is_resolvable(text) from public;
revoke execute on function public.rrule_timed_expansion_cap() from public;
revoke execute on function public.rrule_timed_sql_subset(text, boolean) from public;
revoke execute on function public.rrule_timed_occurrence_count(
  text, boolean, timestamptz, timestamptz, text, timestamptz, timestamptz
) from public;
revoke execute on function public.rrule_timed_occurrence_starts(
  text, boolean, timestamptz, timestamptz, text, timestamptz, timestamptz
) from public;
