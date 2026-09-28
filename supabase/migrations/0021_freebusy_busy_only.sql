-- ============================================================================
-- TimeWeave Phase 2B (Available, step 2 of 5): Free/Busy stops reporting
-- AVAILABLE events as busy.
--
-- WHAT THIS IS. timeweave_private.free_busy_core, replaced in place, with ten
-- added predicates and nothing else. Six of them keep 'available' rows out of
-- the busy set; four of them keep an 'available' MASTER from forcing
-- complete=false about a busy set it cannot contribute to.
--
-- WHAT THIS IS NOT. public.get_free_busy is untouched -- it hands this function
-- a link id and returns its jsonb verbatim (0019 lines 884 and 909), so nothing
-- about token resolution, the GCRA rate limit, the k=2 concurrency gate or the
-- error contract passes through here. No change to share_links, to any RPC, to
-- RLS, to any GRANT or REVOKE, to any index, or to the client. No
-- share_available flag, no `available` array, no Available/Busy difference --
-- those are later steps and NOTHING about them is anticipated here.
--
-- THE RESPONSE IS BYTE-FOR-BYTE THE SAME SHAPE:
--
--   { "complete": boolean, "slots": [ ... ] }
--
-- and `slots` still means exactly one thing: BUSY. What changes is which rows
-- put intervals in it.
--
-- ============================================================================
-- THE ONE RULE FOR WHERE THE PREDICATE GOES
--
-- availability answers a different question from the two filters already in
-- this function, and the whole correctness of this migration is a matter of not
-- confusing the three:
--
--   visibility    -- "may we DISCLOSE this row?"
--   is_cancelled  -- "did this row's occurrence happen at all?"
--   availability  -- "does this row CONTRIBUTE BUSY at all?"
--
-- A busy SOURCE asks the third question, so availability goes there -- in
-- exactly the same six places `is_cancelled = false` and the visibility filter
-- already live. A STRUCTURAL test asks whether an occurrence was replaced, and
-- that is a fact about the series which none of the three changes. So
-- availability is kept out of the detach anti-joins for the identical reason
-- 0019 keeps visibility and is_cancelled out of them (see its comments above
-- each anti-join: "detaching is a structural fact about the series, and a
-- private or cancelled exception removes the original occurrence just the
-- same").
--
-- FOUR PLACES ARE DELIBERATELY LEFT ALONE. Adding a predicate to any of them is
-- a bug, and each would be a DIFFERENT bug:
--
--   * the timed detach anti-join (`where x.recurrence_id = m.id and
--     x.recurrence_slot_start = s.t`) -- filtering it would leave a BUSY
--     master's occurrence in the busy set after an AVAILABLE exception had
--     replaced it;
--   * the all-day detach anti-join (`x.recurrence_slot_date = s.d`) -- same
--     failure in date space;
--   * the exception side of the slot-mismatch check (`join public.events x on
--     x.recurrence_id = m.id and x.all_day = false`) -- filtering it would hide
--     a mismatch that DOES corrupt the busy set, because a slot that matches
--     nothing fails to detach whatever its own availability is;
--   * v_tz_all -- it collects the zones this server must try to resolve, and
--     v_ok_tz is allowed to be a superset. Narrowing it would change what the
--     `timezone = any(v_ok_tz)` test in branch (A) means for busy masters.
--
-- The visibility filters and the is_cancelled tests are not touched either. No
-- existing condition that makes complete FALSE is removed.
--
-- ============================================================================
-- WHAT `complete` MEANS FROM HERE
--
-- Unchanged in words, and that is the point: "the disclosed busy set accounts
-- for everything that could contribute BUSY to this window". Since `slots` now
-- holds only busy, the flag and the array finally describe the same set.
--
-- An AVAILABLE master contributes no busy at all, so failing to expand one says
-- nothing about the busy set. Without the four gates below, creating a single
-- repeating "I am free on Tuesdays" with a rule this server cannot expand
-- (MONTHLY, COUNT, a legacy master with no timezone, or anything over the cap)
-- would raise the share page's warning -- "times not shown are not necessarily
-- free" -- permanently, about nothing.
--
-- THE GATES GO ON THE MASTER, ONE BRANCH AT A TIME. A single
-- `and e.availability = 'busy'` on the outer scan would be WRONG, and silently
-- so. In branch (A) the scanned row `e` IS the master; in (B) and (C) it is the
-- EXCEPTION and the master is `m`. Gating the outer scan would therefore test
-- the exception's availability in (B) and (C), and this is reachable:
--
--     master m : all_day = true,  availability = 'busy', EXPANDABLE
--     exception x: all_day = false, availability = 'available'
--
--   The shapes disagree, so x carries recurrence_slot_start while the anti-join
--   for an all-day master matches on recurrence_slot_date. x therefore does NOT
--   detach anything, m's occurrence stays in the busy set, and the owner --
--   who replaced that occurrence with an available one -- sees busy disclosed
--   where they declared themselves free. Branch (B) is the only thing that
--   catches it. An outer gate would drop x from the scan because x is
--   available, (B) would never fire, and the RPC would report an OVER-STATED
--   busy set as complete=true.
--
-- So: (A) gates on e.availability (e is the master there), and (B), (C) and the
-- slot-mismatch CTE gate on m.availability (m is the master there).
--
-- ============================================================================
-- WHY AN AVAILABLE MASTER MAY BE IGNORED EVEN WHEN IT HAS BUSY EXCEPTIONS
--
-- This is the one inference the gates rest on, so it is spelled out.
--
-- The busy a recurring series can put in a window comes from exactly two
-- places: the occurrences the master generates and the exception snapshots that
-- replace some of them. A master propagates its availability to every
-- occurrence it generates, and the ONLY way an occurrence becomes busy against
-- an available master is an exception row that says so. So for an available
-- master the first place contributes nothing -- whether or not this server can
-- expand it.
--
-- The second place is enumerated WITHOUT the master. Both exception CTEs select
-- from public.events on the exception row's own columns alone: owner,
-- recurrence_id is not null, is_cancelled = false, the all_day discriminant,
-- the visibility filter, and an overlap test against the row's own
-- start_at/end_at (or start_date/end_date). There is no join to the master, to
-- the expandable CTEs or to any generated occurrence, and 0019 says so above
-- both of them: "evaluated independently of whether the parent was expandable,
-- because a snapshot pins absolute instants either way". events_time_shape
-- guarantees the row carries exactly one usable pair matching its all_day, so
-- every busy exception is placeable and none is missed.
--
-- Therefore, for an available master, the disclosed busy set IS the complete
-- busy set of that series, and complete=true is accurate rather than optimistic.
-- The reverse case keeps its old answer: a BUSY master that cannot be expanded
-- still fails branch (A), because its own occurrences are the busy this
-- function cannot enumerate.
--
-- ============================================================================
-- THE TEN EDITS
--
--   BUSY SOURCES (six) -- `and e.availability = 'busy'`, placed beside the
--   visibility filter each of them already has:
--     timed_single, timed_expandable_master, timed_exception_busy,
--     expandable_master, exception_busy, and the single-event arm of allday_src
--
--   COMPLETENESS (four):
--     (A)  `and e.availability = 'busy'`   -- e is the master
--     (B)  `and m.availability = 'busy'`   -- m is the master
--     (C)  `and m.availability = 'busy'`   -- m is the master
--     3d   `and m.availability = 'busy'`   -- the expandable CTE's master
--
-- Nothing else in the 534-line body differs from 0019. The window validation,
-- the link re-resolution, the two-statement timezone hoist, every expansion
-- helper call, both anti-joins, all three merge chains and slots_union are
-- carried over unchanged.
--
-- ============================================================================
-- APPLIED RIGHT AFTER 0020, THIS CHANGES NOTHING
--
-- 0020 adds availability NOT NULL DEFAULT 'busy' and writes no row, so at the
-- moment this file lands every row is 'busy' and all ten predicates are true
-- everywhere. The output is identical to 0019's for every link and every
-- window. That is deliberate: it is what makes it safe to apply this BEFORE the
-- application that can write 'available' is deployed, which in turn is what
-- closes the window in which an available event would have been disclosed as
-- busy. Verifying that identity is a step of the release, not of this file.
--
-- ============================================================================
-- ORDER
--
--   0020  public.events.availability          (required: the predicates name it)
--   0021  this file
--   then  deploy the application (17c4423, f726f72, 86a7844)
--
-- Do not deploy between 0020 and 0021.
--
-- ============================================================================
-- ROLLBACK
--
-- Before the application is deployed, no row can be 'available', so restoring
-- 0019's body (as a CREATE OR REPLACE -- 0019 itself must never be re-run,
-- it creates tables) is a true rollback and changes nothing observable.
--
-- AFTER THE DEPLOY IT IS NOT A ROLLBACK. Removing these predicates while
-- 'available' rows exist re-discloses them as busy, which is the opposite of
-- what their owners declared -- a fresh defect, not a return to a known state.
-- If something is wrong with this file after that point, fix it forward.
--
-- ============================================================================
-- NOT VERIFIED HERE
--
-- This file was written by reading 0019, not by executing anything. Before it
-- is applied, a preflight must confirm that the deployed definition of
-- timeweave_private.free_busy_core still matches 0019's text (pg_get_functiondef),
-- that public.events.availability exists with the shape 0020 declares, and that
-- no row is yet anything other than 'busy'.
-- ============================================================================

begin;

-- ============================================================================
-- timeweave_private.free_busy_core -- 0019's body, with the ten predicates.
--
-- The signature, STABLE, SECURITY INVOKER and search_path = '' are reproduced
-- exactly. CREATE OR REPLACE keeps the function's owner and its ACL, so 0019's
-- `revoke all ... from public, anon, authenticated, service_role` still stands
-- and no GRANT is repeated here. A single character's difference in the
-- argument list would create a second overload instead of replacing this one.
-- ============================================================================
create or replace function timeweave_private.free_busy_core(
  p_link_id   uuid,
  p_from      timestamptz,
  p_to        timestamptz,
  p_from_date date,
  p_to_date   date
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $fn$
declare
  v_owner           uuid;
  v_include_private boolean;
  v_complete        boolean;
  v_slots           jsonb;
  v_slot_mismatch   boolean;
  v_ok_tz           text[];
  v_tz_all          text[];
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
  where s.id = p_link_id
    and s.revoked_at is null
    and (s.expires_at is null or s.expires_at > now())
  limit 1;

  if v_owner is null then
    return jsonb_build_object('complete', true, 'slots', '[]'::jsonb);
  end if;

  -- 2b. The zones this server can actually resolve right now, validated ONCE
  --     PER DISTINCT ZONE (0018): timezone_is_resolvable scans
  --     pg_timezone_names and probes AT TIME ZONE, and it must not run once per
  --     row on an anonymous code path.
  --
  --     TWO STATEMENTS ON PURPOSE. Written as one query with the predicate
  --     outside a SELECT DISTINCT subquery, PostgreSQL pushed the predicate
  --     below the DISTINCT and ran it once per master (measured, 0018 header).
  --     Here the first statement collects the distinct zones into a variable
  --     and the second filters that array, so the predicate's input is already
  --     distinct whatever plan either statement gets.
  --
  --     v_ok_tz IS THE EVIDENCE the timed expansion below runs on: every
  --     element passed timezone_is_resolvable in this call. The
  --     timeweave_private *_in_zones helpers accept a zone only if it is in
  --     this list, so a NULL, unsupported or unresolvable zone still yields
  --     NULL / no rows there -> complete=false, never an exception, whatever
  --     order the surrounding conditions are evaluated in. The public helpers
  --     keep validating on their own for every other caller.
  select coalesce(array_agg(distinct e.timezone), array[]::text[])
    into v_tz_all
  from public.events e
  where e.owner_id = v_owner
    and e.all_day = false
    and e.rrule is not null
    and e.timezone is not null;

  select coalesce(array_agg(z.tz), array[]::text[])
    into v_ok_tz
  from unnest(v_tz_all) as z(tz)
  where public.timezone_is_resolvable(z.tz);

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
          -- 0021: here `e` IS the master, so its own availability decides
          -- whether the occurrences it generates could be busy at all.
          and e.availability = 'busy'
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
                             timeweave_private.rrule_timed_occurrence_count_in_zones(
                               e.rrule, e.all_day, e.start_at, e.end_at, e.timezone,
                               p_from, p_to, v_ok_tz),
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
              -- 0021: the MASTER's availability, never the exception's. An
              -- available exception against a busy master is exactly the shape
              -- this branch exists to catch, so gating on `e` here would be the
              -- bug described in the header.
              and m.availability = 'busy'
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
              -- 0021: the MASTER's availability again. The question this branch
              -- asks is whether the SERIES this exception belongs to could put
              -- busy here that we cannot enumerate; an available series cannot.
              -- The exception's own snapshot is exact either way and is
              -- enumerated by the exception CTEs below without the master.
              and m.availability = 'busy'
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
                                   timeweave_private.rrule_timed_occurrence_count_in_zones(
                                     m.rrule, m.all_day, m.start_at, m.end_at, m.timezone,
                                     p_from, p_to, v_ok_tz),
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
      -- 0021: a mismatched slot matters only where the master's occurrences
      -- could be busy. The exception side of the join below is NOT filtered:
      -- a slot that matches nothing fails to detach whatever it says about
      -- itself.
      and m.availability = 'busy'
      and m.start_at < p_to
      and m.timezone = any(v_ok_tz)
      and public.rrule_timed_sql_subset(m.rrule, m.all_day)
      and coalesce(
            timeweave_private.rrule_timed_occurrence_count_in_zones(
              m.rrule, m.all_day, m.start_at, m.end_at, m.timezone, p_from, p_to, v_ok_tz),
            v_timed_cap + 1) <= v_timed_cap
  ),
  generated as (
    select m.id, m.dur, array_agg(s.t) as starts
    from expandable m
    cross join lateral timeweave_private.rrule_timed_occurrence_starts_in_zones(
      m.rrule, m.all_day, m.start_at, m.end_at, m.timezone, p_from, p_to, v_ok_tz) as s(t)
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
      and e.availability = 'busy'   -- 0021
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
      and e.availability = 'busy'   -- 0021: an available master generates no busy
      and e.start_at < p_to
      and e.timezone = any(v_ok_tz)
      and public.rrule_timed_sql_subset(e.rrule, e.all_day)
      and coalesce(
            timeweave_private.rrule_timed_occurrence_count_in_zones(
              e.rrule, e.all_day, e.start_at, e.end_at, e.timezone, p_from, p_to, v_ok_tz),
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
    cross join lateral timeweave_private.rrule_timed_occurrence_starts_in_zones(
      m.rrule, m.all_day, m.start_at, m.end_at, m.timezone, p_from, p_to, v_ok_tz) as s(t)
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
      -- 0021: beside is_cancelled, and for the same kind of reason -- both ask
      -- whether this snapshot puts busy here. Neither affects the detach.
      and e.availability = 'busy'
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
      and e.availability = 'busy'   -- 0021: an available master generates no busy
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
      -- 0021: beside is_cancelled, exactly as in the timed case above.
      and e.availability = 'busy'
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
      and e.availability = 'busy'   -- 0021
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

commit;
