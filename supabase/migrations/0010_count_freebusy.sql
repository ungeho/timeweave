-- TimeWeave Phase 5b-5B: expand DAILY / WEEKLY recurrences that carry COUNT
-- into Free/Busy, for BOTH the all-day (0007) and the timed (0009) paths.
--
-- SCOPE (deliberately narrow; everything else keeps 5b-3 behaviour):
--   expanded : FREQ=DAILY and FREQ=WEEKLY with a COUNT, on top of everything
--              0007 and 0009 already expand. All-day rows go through the 0007
--              helpers, timed rows through the 0009 helpers, unchanged apart
--              from the ordinal bound added here.
--   NOT yet  : FREQ=MONTHLY (with or without COUNT), legacy M0 masters
--              (timezone IS NULL), zones this server cannot resolve, an UNTIL
--              whose value type does not match all_day, and anything outside
--              rrule_parse's vocabulary. These stay fail-closed: they force
--              complete=false and contribute no slots.
--   UNCHANGED: get_free_busy, rrule_parse, rrule_definitely_ends_before,
--              timezone_is_resolvable, both expansion caps, the events schema,
--              every trigger, RLS, and every GRANT.
--
-- WHY COUNT WAS FAIL-CLOSED, AND WHERE:
--   rrule_sql_subset and rrule_timed_sql_subset each carried `count_n is null`.
--   rrule_allday_occurrence_count ALSO carried its own, independent
--   `if p.count_n is not null then return null` -- it inlines the subset tests
--   rather than calling rrule_sql_subset. Removing the subset test alone would
--   have left that helper returning NULL, and a NULL count is turned into
--   "over cap" by every caller's coalesce(count, cap + 1) rule. The master
--   would then be inside the subset yet outside the expandable set: branch (A)
--   would not fire and no occurrence would be generated either -- a silent
--   false-free. BOTH had to change, and this migration changes both.
--
-- THE ORDINAL CONTRACT (this file's whole reason for existing):
--   COUNT is a bound on an occurrence's ORDINAL, not a tally kept while
--   walking. The ordinal of every candidate is closed-form, so "is this the
--   N-th occurrence of the series" is answered without generating the ones
--   before it -- which is what keeps expansion O(window) however far the
--   window sits from DTSTART.
--
--     DAILY   ordinal(i)    = i
--     WEEKLY  ordinal(0, j) = j - (k - pw0)          <- week 0 is PARTIAL
--             ordinal(i, j) = pw0 + (i - 1) * k + j  <- i >= 1
--
--   where the BYDAY offsets are sorted ascending (0 = Monday .. 6 = Sunday),
--   j is the 0-based position in that sorted array, k is its length, and pw0
--   is how many offsets fall at or after DTSTART's own weekday. Because the
--   array is sorted, the offsets BEFORE DTSTART's weekday are exactly its
--   first (k - pw0) entries, which is what makes the week-0 rank a subtraction.
--
--   A week-0 candidate before DTSTART's weekday gets a NEGATIVE ordinal. Such a
--   candidate is already rejected by the `>= DTSTART` test that has always been
--   there, but `v_ord >= 0` is asserted independently so neither guard depends
--   on the other.
--
--   INTERVAL does not appear in either formula: it decides WHICH DATE a
--   candidate falls on, never how many occurrences precede it.
--
--   This is the same contract src/services/recurrence.ts implements as of
--   Phase 5b-5A (commit 81b1021). The two must generate the same sequence for
--   the same RRULE; supabase/tests/0010_count_freebusy_test.sql section 2 pins
--   the SQL side against the exact cases src/services/recurrence.test.ts A5-A9
--   pin on the TypeScript side.
--
-- COUNT IS APPLIED TWICE, ON PURPOSE:
--   * as an upper bound on the candidate index range (v_hi), so the loop and
--     the cap probe both shrink rather than generating candidates that will be
--     discarded; and
--   * as a per-candidate test, so correctness never depends on the bound
--     arithmetic being tight. The index range stays deliberately WIDER than
--     needed, exactly as it already is for the window and for UNTIL.
--
-- COUNT AND UNTIL ARE NEVER BOTH PRESENT:
--   rrule_parse reports `malformed` with reason `count_and_until` when both
--   appear, so status <> 'ok' and every subset test below is already false.
--   This migration DEPENDS on that exclusion and deliberately defines NO
--   precedence between them: the two `least()` bounds can never both apply.
--
-- FREQ=MONTHLY STAYS OUT:
--   Only `count_n is null` is removed from the subset tests. The
--   `freq in ('DAILY','WEEKLY')` test remains in both subsets AND inline in
--   rrule_allday_occurrence_count, so FREQ=MONTHLY -- with COUNT or without --
--   is still rejected and still forces complete=false. Nothing in this file
--   changes MONTHLY semantics on either side of the stack.
--
-- DST IS UNTOUCHED:
--   COUNT bounds an ordinal; it says nothing about which instant a wall clock
--   names. The timed helpers' `v_cl at time zone p_timezone` conversion, the
--   DTSTART exact-anchor (`if v_cl = v_dtl then v_start := p_start_at`), the
--   H-LATER resolution of gaps and folds that AT TIME ZONE performs, and the
--   absolute-seconds duration are all reproduced here VERBATIM.
--
-- ATTRIBUTES MUST BE RESTATED:
--   CREATE OR REPLACE FUNCTION resets any attribute the new definition omits.
--   Every function below therefore repeats `language`, `stable` and
--   `set search_path = ''` explicitly, and none of them declares
--   `security definer` (they stay SECURITY INVOKER, called by get_free_busy as
--   the definer). Dropping `stable` would silently make them VOLATILE.
--
-- NO GRANTS ARE ISSUED:
--   CREATE OR REPLACE FUNCTION preserves ownership and privileges, so the
--   REVOKEs from 0006/0007/0009 still hold and are intentionally NOT repeated,
--   the same way 0007 declined to repeat 0005's grant on get_free_busy.
--   supabase/tests/0010_count_freebusy_postflight.sql verifies that from
--   outside instead of asserting it here.
--
-- get_free_busy IS NOT TOUCHED:
--   It never reads count_n. It reaches COUNT only through the six helpers
--   replaced below, all of which keep their exact signatures, so replacing it
--   would copy 400 lines for no behavioural gain and put its SECURITY DEFINER
--   marker and its anon grant at risk of a transcription slip.
--
-- AFTER APPLYING, VERIFY (or just run the postflight, which does all of this):
--   select proname, pg_get_function_identity_arguments(oid), provolatile,
--          prosecdef, proconfig, proacl
--   from pg_proc where proname in (
--     'rrule_sql_subset','rrule_timed_sql_subset',
--     'rrule_allday_occurrence_count','rrule_timed_occurrence_count',
--     'rrule_allday_occurrence_starts','rrule_timed_occurrence_starts',
--     'get_free_busy');
-- ============================================================================

-- ============================================================================
-- 1. rrule_sql_subset: the ALL-DAY grammar gate.
--
-- Unchanged from 0006 apart from the removal of `and p.count_n is null`.
-- FREQ=MONTHLY is still excluded by the freq test, so MONTHLY+COUNT remains
-- unsupported without needing a test of its own.
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
       and p_all_day is true               -- timed rows go through 0009
       and p.until_ts is null              -- an all-day series must not carry an instant UNTIL
    from public.rrule_parse(p_rrule) p
  ), false);
$fn$;

-- ============================================================================
-- 2. rrule_timed_sql_subset: the TIMED grammar gate.
--
-- Unchanged from 0009 apart from the removal of `and p.count_n is null`. The
-- zone requirement is NOT here and never was: it is a row property, applied by
-- the callers and re-checked inside the two timed helpers.
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
       and p_all_day is false              -- all-day rows go through 0007
       and p.until_date is null            -- a timed series must not carry a DATE UNTIL
    from public.rrule_parse(p_rrule) p
  ), false);
$fn$;

-- ============================================================================
-- 3. rrule_allday_occurrence_count: how many all-day candidates WOULD be
--    generated, as an upper bound, without generating any.
--
-- TWO CHANGES from 0007:
--   * the independent `if p.count_n is not null then return null` is GONE.
--     That line, not the subset, is what made an all-day COUNT master report
--     NULL; see the header. The remaining inline tests (status, freq, all_day,
--     until_ts) still mirror rrule_sql_subset exactly.
--   * COUNT now caps v_hi. Because it can only LOWER the bound, the returned
--     number is monotonically non-increasing in COUNT and the cap check can
--     only get easier to pass -- COUNT can never push a master over the cap.
--
-- When COUNT ends the series before the window, the tightened v_hi falls below
-- v_lo and `greatest(0, ...)` returns 0. A zero candidate count is a perfectly
-- ordinary answer: the master IS expandable, it simply contributes nothing to
-- this window, so get_free_busy reports complete=true with no slots. That is
-- the case rrule_definitely_ends_before could never prove for a COUNT series,
-- and it is now handled by expansion instead of by narrowing.
--
-- Returns NULL outside the subset, never 0, so callers that write
-- coalesce(count, cap + 1) keep failing closed.
--
-- Not STRICT: NULL arguments must reach the body so the NULL return is a
-- decision, not an accident of the call convention.
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
  p     record;
  v_n   integer;
  v_d   integer;
  v_b   integer;
  v_s   integer;
  v_pw0 integer;
  v_w0  date;
  v_lo  numeric;
  v_hi  numeric;
begin
  if p_all_day is not true then return null; end if;
  if p_start_date is null or p_end_date is null
     or p_from_date is null or p_to_date is null then
    return null;
  end if;

  select * into p from public.rrule_parse(p_rrule);
  if p.status <> 'ok' then return null; end if;
  if p.freq not in ('DAILY', 'WEEKLY') then return null; end if;
  -- 5b-5B: the `p.count_n is not null` rejection that used to sit here is gone.
  -- It was independent of rrule_sql_subset, so leaving it would have made an
  -- all-day COUNT master pass the subset and still report an unknown count.
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
    -- COUNT: ordinal(i) = i, so the last candidate index is count_n - 1.
    if p.count_n is not null then
      v_hi := least(v_hi, (p.count_n - 1)::numeric);
    end if;
    return greatest(0, v_hi - v_lo + 1)::bigint;
  else
    -- BYDAY omitted means "the weekday of DTSTART", i.e. exactly one per week.
    v_b  := coalesce(array_length(p.byday, 1), 1);
    -- Week anchor: the Monday of DTSTART's week (RFC 5545 default WKST=MO), the
    -- same anchor services/recurrence.ts uses.
    v_w0 := p_start_date - (extract(isodow from p_start_date)::integer - 1);
    v_lo := greatest(0, floor((p_from_date - v_d - 7 - v_w0)::numeric / (7 * v_n)));
    v_hi := floor((p_to_date - v_w0)::numeric / (7 * v_n)) + 1;
    if p.until_date is not null then
      v_hi := least(v_hi, floor((p.until_date - v_w0)::numeric / (7 * v_n)));
    end if;
    -- COUNT: week 0 contributes pw0 occurrences and every later week k, so the
    -- last week holding an occurrence is 1 + floor((count - 1 - pw0) / k) once
    -- COUNT outruns week 0, and week 0 itself otherwise.
    if p.count_n is not null then
      v_s := extract(isodow from p_start_date)::integer - 1;
      if p.byday is null then
        v_pw0 := 1;   -- the only offset IS DTSTART's weekday
      else
        select count(*)
          into v_pw0
        from unnest(p.byday) as tok
        where array_position(array['MO','TU','WE','TH','FR','SA','SU'], tok) - 1 >= v_s;
      end if;
      if p.count_n <= v_pw0 then
        v_hi := least(v_hi, 0::numeric);
      else
        v_hi := least(v_hi, 1 + floor((p.count_n - 1 - v_pw0)::numeric / v_b));
      end if;
    end if;
    return greatest(0, (v_hi - v_lo + 1) * v_b)::bigint;
  end if;
end;
$fn$;

-- ============================================================================
-- 4. rrule_timed_occurrence_count: the same upper bound for timed masters.
--
-- ONE CHANGE from 0009: COUNT caps v_hi. There is no inline count_n rejection
-- to remove here -- this helper delegates the whole grammar question to
-- rrule_timed_sql_subset, which section 2 has already widened.
--
-- The zone check, its NULL-on-drift contract, and the index range derived in
-- the master zone are reproduced unchanged.
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
  v_s      integer;
  v_pw0    integer;
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
    -- COUNT: ordinal(i) = i.
    if p.count_n is not null then
      v_hi := least(v_hi, (p.count_n - 1)::numeric);
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
    -- COUNT: DTSTART's weekday is read in the MASTER ZONE, like every other
    -- calendar field on this path.
    if p.count_n is not null then
      v_s := extract(isodow from v_d0)::integer - 1;
      if p.byday is null then
        v_pw0 := 1;
      else
        select count(*)
          into v_pw0
        from unnest(p.byday) as tok
        where array_position(array['MO','TU','WE','TH','FR','SA','SU'], tok) - 1 >= v_s;
      end if;
      if p.count_n <= v_pw0 then
        v_hi := least(v_hi, 0::numeric);
      else
        v_hi := least(v_hi, 1 + floor((p.count_n - 1 - v_pw0)::numeric / v_b));
      end if;
    end if;
    return greatest(0, (v_hi - v_lo + 1) * v_b)::bigint;
  end if;
end;
$fn$;

-- ============================================================================
-- 5. rrule_allday_occurrence_starts: the all-day occurrence START dates.
--
-- TWO CHANGES from 0007:
--   * COUNT caps v_hi, mirroring section 3.
--   * the WEEKLY inner loop is INDEXED (`for v_j in 1 .. v_k`) instead of
--     `foreach v_b in array v_offs`, because the ordinal needs j. v_offs is
--     built with `order by o.idx`, so it is ascending and (v_j - 1) is exactly
--     the j of the ordinal formula. THAT SORT IS LOAD BEARING: with COUNT the
--     order decides WHICH occurrences exist, not merely the order they are
--     reported in. src/services/recurrence.ts sorts its offsets for the same
--     reason as of 5b-5A.
--
-- Everything else -- the precondition raise, the cap probe, the date tests --
-- is reproduced verbatim.
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
  v_j    integer;
  v_k    integer;
  v_s    integer;
  v_pw0  integer;
  v_ord  bigint;
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
    if p.count_n is not null then
      v_hi := least(v_hi, (p.count_n - 1)::bigint);
    end if;

    for v_i in v_lo .. v_hi loop
      -- ordinal(i) = i, and v_i >= v_lo >= 0, so the non-negative half of the
      -- ordinal test is structural here. It is written out anyway so the DAILY
      -- and WEEKLY arms state the same contract.
      v_ord := v_i;
      v_date := p_start_date + (v_i * v_n)::integer;
      if v_date >= p_start_date
         and (p.until_date is null or v_date <= p.until_date)
         and (p.count_n is null or (v_ord >= 0 and v_ord < p.count_n))
         and v_date < p_to_date
         and v_date + v_d > p_from_date then
        return next v_date;
      end if;
    end loop;

  else
    -- WEEKLY. Offsets are 0 = Monday .. 6 = Sunday, matching the WEEKDAYS array
    -- order in src/types/recurrence.ts, and are SORTED ASCENDING.
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
    v_k := array_length(v_offs, 1);
    v_s := extract(isodow from p_start_date)::integer - 1;
    -- How many offsets survive week 0. Because v_offs is sorted, the ones that
    -- do not are exactly its first (v_k - v_pw0) entries.
    select count(*) into v_pw0 from unnest(v_offs) as o where o >= v_s;

    v_w0 := p_start_date - (extract(isodow from p_start_date)::integer - 1);
    v_lo := greatest(0, floor((p_from_date - v_d - 7 - v_w0)::numeric / (7 * v_n)))::bigint;
    v_hi := (floor((p_to_date - v_w0)::numeric / (7 * v_n)) + 1)::bigint;
    if p.until_date is not null then
      v_hi := least(v_hi, floor((p.until_date - v_w0)::numeric / (7 * v_n))::bigint);
    end if;
    if p.count_n is not null then
      if p.count_n <= v_pw0 then
        v_hi := least(v_hi, 0::bigint);
      else
        v_hi := least(v_hi, (1 + floor((p.count_n - 1 - v_pw0)::numeric / v_k))::bigint);
      end if;
    end if;

    for v_i in v_lo .. v_hi loop
      for v_j in 1 .. v_k loop
        v_b := v_offs[v_j];
        if v_i = 0 then
          v_ord := (v_j - 1) - (v_k - v_pw0);
        else
          v_ord := v_pw0 + (v_i - 1) * v_k + (v_j - 1);
        end if;
        v_date := v_w0 + (v_i * 7 * v_n + v_b)::integer;
        if v_date >= p_start_date
           and (p.until_date is null or v_date <= p.until_date)
           and (p.count_n is null or (v_ord >= 0 and v_ord < p.count_n))
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
-- 6. rrule_timed_occurrence_starts: the timed occurrence START instants.
--
-- The same two changes as section 5, and NOTHING ELSE. In particular:
--   * `v_start := v_cl at time zone p_timezone` is untouched, so gaps and folds
--     keep resolving to the LATER of the two candidate instants -- measured,
--     not assumed (0009 preflight section B, and the Phase 5b-4 Dublin probe).
--   * the DTSTART exact-anchor `if v_cl = v_dtl then v_start := p_start_at` is
--     untouched, so a series whose first occurrence sits on a fold still emits
--     the stored instant verbatim.
--   * the duration stays absolute seconds.
-- COUNT adds an ordinal bound and changes no instant.
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
  v_j      integer;
  v_k      integer;
  v_s      integer;
  v_pw0    integer;
  v_ord    bigint;
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
    if p.count_n is not null then
      v_hi := least(v_hi, (p.count_n - 1)::bigint);
    end if;

    for v_i in v_lo .. v_hi loop
      v_ord := v_i;   -- ordinal(i) = i
      v_cl := (v_d0 + (v_i * v_n)::integer) + v_tod0;
      -- DTSTART keeps its stored instant; see the header note on folds.
      if v_cl = v_dtl then
        v_start := p_start_at;
      else
        v_start := v_cl at time zone p_timezone;
      end if;
      if v_start >= p_start_at
         and (p.until_ts is null or v_start <= p.until_ts)
         and (p.count_n is null or (v_ord >= 0 and v_ord < p.count_n))
         and v_start < p_to
         and v_start + v_dur > p_from then
        return next v_start;
      end if;
    end loop;

  else
    -- WEEKLY. Offsets are 0 = Monday .. 6 = Sunday, matching the WEEKDAYS array
    -- order in src/types/recurrence.ts, and are SORTED ASCENDING.
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
    v_k := array_length(v_offs, 1);
    -- DTSTART's weekday IN THE MASTER ZONE, like every other calendar field here.
    v_s := extract(isodow from v_d0)::integer - 1;
    select count(*) into v_pw0 from unnest(v_offs) as o where o >= v_s;

    v_w0 := v_d0 - (extract(isodow from v_d0)::integer - 1);
    v_lo := greatest(0, floor((v_fromd - v_durd - 7 - v_w0)::numeric / (7 * v_n)))::bigint;
    v_hi := (floor((v_tod - v_w0)::numeric / (7 * v_n)) + 1)::bigint;
    if v_untild is not null then
      v_hi := least(v_hi, floor((v_untild - v_w0)::numeric / (7 * v_n))::bigint);
    end if;
    if p.count_n is not null then
      if p.count_n <= v_pw0 then
        v_hi := least(v_hi, 0::bigint);
      else
        v_hi := least(v_hi, (1 + floor((p.count_n - 1 - v_pw0)::numeric / v_k))::bigint);
      end if;
    end if;

    for v_i in v_lo .. v_hi loop
      for v_j in 1 .. v_k loop
        v_off := v_offs[v_j];
        if v_i = 0 then
          v_ord := (v_j - 1) - (v_k - v_pw0);
        else
          v_ord := v_pw0 + (v_i - 1) * v_k + (v_j - 1);
        end if;
        v_cl := (v_w0 + (v_i * 7 * v_n + v_off)::integer) + v_tod0;
        if v_cl = v_dtl then
          v_start := p_start_at;
        else
          v_start := v_cl at time zone p_timezone;
        end if;
        if v_start >= p_start_at
           and (p.until_ts is null or v_start <= p.until_ts)
           and (p.count_n is null or (v_ord >= 0 and v_ord < p.count_n))
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
-- 7. EXECUTE privileges: NONE ARE ISSUED HERE, ON PURPOSE.
--
-- All six functions above already existed, and CREATE OR REPLACE FUNCTION
-- preserves ownership and privileges. The REVOKEs in 0006 (rrule_sql_subset),
-- 0007 (the two all-day helpers) and 0009 (rrule_timed_sql_subset and the two
-- timed helpers) therefore still hold, and repeating them would only create a
-- second place where the intent could drift. 0007 made the same call about
-- 0005's grant on get_free_busy.
--
-- The postflight asserts the outcome instead: PUBLIC still has no EXECUTE on
-- any of the six, get_free_busy still has its anon/authenticated grant, and all
-- six are still STABLE, SECURITY INVOKER and search_path = ''.
-- ============================================================================
