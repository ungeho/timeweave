-- ============================================================================
-- TimeWeave -- RUNTIME regression suite for 0021_freebusy_busy_only.sql.
--
-- NOT A MIGRATION AND NOT A STATIC VALIDATOR. Run by hand (psql) against an
-- ISOLATED development database AFTER 0021 is applied and AFTER its postflight
-- (0021_postflight.sql) has passed in full. Wrapped in a transaction that ends
-- with ROLLBACK, so it leaves no fixtures behind.
--
-- !! RUN THE WHOLE FILE, INCLUDING THE FINAL ROLLBACK. !!
--
-- THERE IS DELIBERATELY NO COMMIT IN THIS FILE. Every fixture below is created
-- inside one transaction and thrown away by the final ROLLBACK. Nothing here is
-- meant to survive the run.
--
-- A failing `assert` raises and aborts the transaction; every statement after it
-- reports "current transaction is aborted" until the final ROLLBACK. Read the
-- FIRST error message -- that is the real failure.
--
-- ----------------------------------------------------------------------------
-- WHAT THIS SUITE IS FOR, AND WHAT IT IS NOT
--
-- 0021_preflight.sql and 0021_postflight.sql establish that the deployed body
-- is "0019 plus ten availability predicates, in the right places, and nothing
-- else". They read text and catalogs. They establish NOTHING about run time.
--
-- This file answers the other half: with rows in the table, does the RPC
-- actually return the right busy set and the right `complete` flag? It covers
--
--   * the six BUSY SOURCES 0021 gated   (G11-G16): busy contributes, available
--     does not, in both time models;
--   * the four COMPLETENESS gates       (G17-G20): an available master no
--     longer forces `complete = false` about nothing;
--   * the places 0021 deliberately did NOT gate (N01, N02, N03, N05, N06, N07):
--     a wrong predicate there is invisible to a static check but changes the
--     answer, and each has a case here that would catch it.
--
-- N04 and N08 have no runtime counterpart and stay static-only -- see the
-- N-mapping at the foot of this header.
--
-- ----------------------------------------------------------------------------
-- DEDICATED TEST USER -- THIS FILE NEVER WRITES TO auth.users
--
-- Section 0 asserts the canonical test owner exists and owns nothing. It never
-- creates one. That is the same rule 0006 states and 0007-0010 repeat:
--
--   SETUP (once, per environment):
--     1. Create the test user through the normal Auth path -- or, in a local
--        isolated database with no Auth, through a SEPARATE bootstrap step that
--        is not this file. Do NOT insert into auth.users from here.
--     2. Point v_owner below at that id.
--     3. Never create calendar events with that account.
--
-- If the precondition fails, fix it by pointing v_owner at a clean test user --
-- not by clearing anybody's calendar.
--
-- ----------------------------------------------------------------------------
-- R8 IS A DEFENSIVE-BRANCH FIXTURE, AND IT NEEDS ONE TRIGGER OUT OF THE WAY
--
-- R8 constructs an exception whose all_day disagrees with its master. That is
-- the exact shape completeness branch (B) exists to catch, and 0021's header
-- calls it reachable -- true of the CHECK constraints, which constrain each row
-- alone. It is NOT reachable through the current client path: 0017 added
-- events_enforce_recurrence_graph, a statement-level trigger that requires
-- P.all_day = C.all_day for every exception.
--
--   R8 is a defensive-branch regression fixture. It intentionally constructs a
--   state that the current 0017 graph trigger rejects. It does not claim that a
--   normal current client can create this state.
--
-- So exactly ONE trigger is disabled, for exactly ONE statement:
--
--     events_quota_graph_ai   (AFTER INSERT)   -- disabled for X8's INSERT only
--
-- events_quota_graph_au is NOT touched: R8's P1 -> P2 step updates only
-- `availability`, and the UPDATE arm of the function rebuilds its candidate set
-- from rows whose owner_id, recurrence_id, all_day or rrule-nullness changed.
-- availability is none of those, so the candidate set is empty and the trigger
-- passes with the mismatched exception still in place. DELETE needs nothing
-- either: 0017 registers no DELETE trigger.
--
-- ALTER TABLE ... DISABLE TRIGGER is transactional. The final ROLLBACK restores
-- trigger state if execution aborts. That is the safety net, not the plan: the
-- ENABLE is the very next statement after the INSERT, and tgenabled is asserted
-- to be back to 'O' immediately, at the end of R8, and again at the end of the
-- file.
--
-- DISABLE TRIGGER ALL and DISABLE TRIGGER USER are never used here.
--
-- ----------------------------------------------------------------------------
-- WHO CALLS WHAT, AND WHY
--
--   FIXTURE PREPARATION and the CORE calls run as the migration owner. That is
--   not a shortcut around RLS: timeweave_private.free_busy_core is SECURITY
--   INVOKER and in production runs inside public.get_free_busy, a SECURITY
--   DEFINER function owned by the same role, so the effective read is the
--   owner's either way. Calling the core directly is how a single branch is
--   observed without the wrapper's rate limiter in the way.
--
--   WRAPPER calls run as `anon`, the role the share page actually reaches
--   public.get_free_busy with. PL/pgSQL has no SET statement, so
--   set_config('role', ..., true) is used and reset with 'none' on the very
--   next line -- the same device 0008's suite uses.
--
--   The wrapper is called SIX times in total (R8 twice, R11 once, R17 once,
--   R18 twice), all on one link. 0019's limiter allows a burst of 15 per link
--   and 40 per owner, so this is well inside it. Load testing the limiter is
--   0012's job and is not repeated here.
--
-- ----------------------------------------------------------------------------
-- FIXTURE ISOLATION
--
-- Every case creates its own rows, asserts, deletes exactly what it created,
-- and then re-asserts the empty baseline before the next case starts. No case
-- reads a row another case created. The two share links are the only fixtures
-- that live for the whole run.
--
-- ----------------------------------------------------------------------------
-- WINDOW AND ZONE
--
--   timed window   [2026-06-01T00:00Z, 2026-06-08T00:00Z)
--   date  window   [2026-06-01,        2026-06-08)
--   zone           UTC, asserted supported AND resolvable in section 0.
--
-- UTC is deliberate: DST correctness belongs to 0009's suite, and every instant
-- below is then readable without converting anything.
--
-- ----------------------------------------------------------------------------
-- G-MAPPING (the ten predicates 0021 added)
--
--   G11 timed_single ............................ R1,  R17, R18
--   G12 timed_expandable_master ................. R3,  R11, R14
--   G13 timed_exception_busy .................... R5,  R11, R14
--   G14 expandable_master (all-day) ............. R4,  R12, R15, R16
--   G15 exception_busy (all-day) ................ R6,  R12, R15
--   G16 allday_src single-event arm ............. R2
--   G17 completeness (A), e IS the master ....... R7
--   G18 completeness (B), m is the master ....... R8
--   G19 completeness (C), m is the master ....... R9
--   G20 slot-mismatch CTE, m is the master ...... R10
--
-- N-MAPPING (what must have NO availability condition)
--
--   N01 timed detach anti-join .................. R11        (runtime)
--   N02 all-day detach anti-join ................ R12        (runtime)
--   N03 slot-mismatch exception-side join ....... R13        (runtime)
--   N04 v_tz_all collection ..................... static-only
--         A busy master always contributes its OWN zone to v_tz_all, so
--         narrowing that collection to busy rows changes no output. There is
--         nothing a runtime case could observe.
--   N05 outer completeness scan ungated ......... R8         (runtime)
--   N06 include_private filters ................. R17        (runtime)
--   N07 is_cancelled tests ...................... R16        (runtime)
--   N08 reads public.events in 13 places ........ static-only
--         A count of syntactic occurrences. No observable runtime quantity
--         corresponds to it.
--
-- PRIVACY. Fixtures carry empty titles and no descriptions or categories. The
-- RPC returns time ranges only; that contract is 0005's and is pinned
-- structurally by the postflight, not re-tested here.
-- ============================================================================

begin;


-- ============================================================================
-- SECTION 0 -- PRECONDITIONS. If any of these fail, STOP; do not "fix" them by
--              deleting rows.
-- ============================================================================
do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';  -- <<< EDIT per environment
  v_n     bigint;
  v_tg    "char";
  v_ok    boolean;
begin
  raise notice 'Section 0: preconditions';

  -- 0.1 The canonical test user exists, exactly once. This file never creates it.
  select count(*) into v_n from auth.users u where u.id = v_owner;
  assert v_n = 1,
    format('0.1 the canonical test user must exist exactly once in auth.users, found %s. '
           'Create it through the bootstrap step for this environment; this suite '
           'never inserts into auth.users.', v_n);

  -- 0.2 The test owner owns nothing. Isolation of every case below depends on it.
  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0,
    format('0.2 the test owner must start with zero events, found %s. Point v_owner at '
           'a clean test user -- do NOT delete events to satisfy this.', v_n);

  select count(*) into v_n from public.share_links s where s.owner_id = v_owner;
  assert v_n = 0,
    format('0.3 the test owner must start with zero share links, found %s.', v_n);

  -- 0.4 0021 is applied. Not a substitute for the postflight -- a guard against
  --     running this file against the wrong database.
  select (p.prosrc ~ 'availability') into v_ok
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'timeweave_private' and p.proname = 'free_busy_core';
  assert v_ok,
    '0.4 timeweave_private.free_busy_core does not mention availability: 0021 is not '
    'applied to this database. Run the migration and its postflight first.';

  -- 0.5 UTC must be both accepted by the 0008 gate and resolvable by the 0009
  --     expander, or every timed master below would silently stop expanding.
  select public.timezone_is_supported('UTC') into v_ok;
  assert v_ok, '0.5 timezone_is_supported(''UTC'') is false; the timed fixtures cannot be created';
  select public.timezone_is_resolvable('UTC') into v_ok;
  assert v_ok, '0.6 timezone_is_resolvable(''UTC'') is false; timed masters would not expand '
               'and every timed expectation below would be wrong for the wrong reason';

  -- 0.7 The graph trigger starts enabled. R8 disables it for one statement and
  --     puts it back; if it were already off, R8 would prove nothing and the
  --     rest of the suite would be running without an invariant it assumes.
  select t.tgenabled into v_tg
  from pg_catalog.pg_trigger t
  where t.tgrelid = 'public.events'::regclass
    and t.tgname = 'events_quota_graph_ai' and not t.tgisinternal;
  assert v_tg = 'O',
    format('0.7 events_quota_graph_ai must start enabled, tgenabled=%s', v_tg);

  raise notice 'Section 0 OK';
end $$;


-- ============================================================================
-- SECTION 1 -- THE TWO SHARE LINKS. Created once, used by every case, dropped
--              in the final cleanup. One statement, two rows: 0016's create
--              limiter allows a burst of 5 per minute per owner.
--
--   L1  include_private = true   -- the default link for the whole suite
--   L0  include_private = false  -- used only by R17
--
-- Tokens are plain text here and hashed on the way in, exactly as 0005 stores
-- them. They never leave this transaction.
-- ============================================================================
insert into public.share_links
  (id, owner_id, token_hash, label, include_private, expires_at, revoked_at)
values
  ('0021b001-0000-4000-8000-000000000001',
   '5e86935f-7661-4741-868f-0f51c4cf1727',
   encode(extensions.digest('tw-0021-runtime-suite-token-include-private-true', 'sha256'), 'hex'),
   '0021 runtime suite (include_private=true)',  true,  null, null),
  ('0021b001-0000-4000-8000-000000000000',
   '5e86935f-7661-4741-868f-0f51c4cf1727',
   encode(extensions.digest('tw-0021-runtime-suite-token-include-private-false', 'sha256'), 'hex'),
   '0021 runtime suite (include_private=false)', false, null, null);

do $$
declare
  v_owner constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_n     bigint;
begin
  select count(*) into v_n from public.share_links s where s.owner_id = v_owner;
  assert v_n = 2, format('1.1 expected exactly two suite links, found %s', v_n);
  raise notice 'Section 1 OK: two share links created';
end $$;


-- ============================================================================
-- R1 -- timed single event, busy vs available
--
--   covered G: G11 (timed_single)
--   covered N: none
--
-- The simplest statement 0021 makes, in the timed model: a one-off busy event
-- is disclosed, the same row marked available is not.
-- ============================================================================
do $$
declare
  v_owner constant uuid   := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    constant uuid   := '0021b001-0000-4000-8000-000000000001';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date   := date '2026-06-01';
  v_td    constant date   := date '2026-06-08';
  v_e1    constant uuid   := '0021c001-0000-4000-8000-000000000001';
  v_res   jsonb;
  v_n     bigint;
begin
  raise notice 'R1: timed single event, busy vs available';

  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at, availability)
  values (v_e1, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 10:00:00+00', 'busy');

  -- P1: busy contributes.
  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert (v_res->>'complete')::boolean = true, 'R1.P1 complete, got ' || v_res::text;
  assert jsonb_array_length(v_res->'slots') = 1,
    format('R1.P1 expected exactly one slot, got %s', jsonb_array_length(v_res->'slots'));
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-06-02 09:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-02 10:00:00+00')),
    'R1.P1 the busy interval must be the event itself, got ' || (v_res->'slots'->0)::text;

  -- P2: available contributes nothing, and says so completely.
  update public.events set availability = 'available' where id = v_e1;
  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert v_res = '{"complete": true, "slots": []}'::jsonb,
    'R1.P2 an available single timed event must disclose nothing, got ' || v_res::text;

  delete from public.events where id = v_e1;
  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('R1 cleanup: %s event(s) left behind', v_n);
  raise notice 'R1 OK';
end $$;


-- ============================================================================
-- R2 -- all-day single event, busy vs available
--
--   covered G: G16 (the single-event arm of allday_src)
--   covered N: none
--
-- The same statement in the date model. Not merged with R1: the two arms are
-- different CTEs over different columns, and the slot shape differs.
-- ============================================================================
do $$
declare
  v_owner constant uuid   := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    constant uuid   := '0021b001-0000-4000-8000-000000000001';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date   := date '2026-06-01';
  v_td    constant date   := date '2026-06-08';
  v_e2    constant uuid   := '0021c002-0000-4000-8000-000000000001';
  v_res   jsonb;
  v_n     bigint;
begin
  raise notice 'R2: all-day single event, busy vs available';

  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date, availability)
  values (v_e2, v_owner, '', 'busy_only', true, date '2026-06-03', date '2026-06-04', 'busy');

  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert (v_res->>'complete')::boolean = true, 'R2.P1 complete, got ' || v_res::text;
  assert jsonb_array_length(v_res->'slots') = 1,
    format('R2.P1 expected exactly one span, got %s', jsonb_array_length(v_res->'slots'));
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', true,
           'start_date', to_jsonb(date '2026-06-03'),
           'end_date',   to_jsonb(date '2026-06-04')),
    'R2.P1 the span must be the event itself (end_date exclusive), got ' || (v_res->'slots'->0)::text;

  update public.events set availability = 'available' where id = v_e2;
  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert v_res = '{"complete": true, "slots": []}'::jsonb,
    'R2.P2 an available all-day event must disclose nothing, got ' || v_res::text;

  delete from public.events where id = v_e2;
  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('R2 cleanup: %s event(s) left behind', v_n);
  raise notice 'R2 OK';
end $$;


-- ============================================================================
-- R3 -- timed expandable master, busy vs available
--
--   covered G: G12 (timed_expandable_master)
--   covered N: none
--
-- An available master generates no busy AT ALL -- every occurrence disappears,
-- not just the first -- and `complete` stays true, because gate (A) is written
-- to leave available masters alone.
-- ============================================================================
do $$
declare
  v_owner constant uuid   := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    constant uuid   := '0021b001-0000-4000-8000-000000000001';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date   := date '2026-06-01';
  v_td    constant date   := date '2026-06-08';
  v_m3    constant uuid   := '0021c003-0000-4000-8000-000000000001';
  v_res   jsonb;
  v_n     bigint;
begin
  raise notice 'R3: timed expandable master, busy vs available';

  -- FREQ=DAILY;COUNT=3 from 06-02 09:00Z: occurrences on 06-02, 06-03 and 06-04,
  -- one hour each, none adjacent, so none merge.
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             rrule, timezone, availability)
  values (v_m3, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 10:00:00+00',
          'FREQ=DAILY;COUNT=3', 'UTC', 'busy');

  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert (v_res->>'complete')::boolean = true, 'R3.P1 complete, got ' || v_res::text;
  assert jsonb_array_length(v_res->'slots') = 3,
    format('R3.P1 expected three occurrences, got %s', jsonb_array_length(v_res->'slots'));
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-06-02 09:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-02 10:00:00+00')),
    'R3.P1 slot 0, got ' || (v_res->'slots'->0)::text;
  assert v_res->'slots'->1 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-06-03 09:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-03 10:00:00+00')),
    'R3.P1 slot 1, got ' || (v_res->'slots'->1)::text;
  assert v_res->'slots'->2 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-06-04 09:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-04 10:00:00+00')),
    'R3.P1 slot 2, got ' || (v_res->'slots'->2)::text;

  update public.events set availability = 'available' where id = v_m3;
  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert v_res = '{"complete": true, "slots": []}'::jsonb,
    'R3.P2 an available timed master must generate nothing AND stay complete, got ' || v_res::text;

  delete from public.events where id = v_m3;
  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('R3 cleanup: %s event(s) left behind', v_n);
  raise notice 'R3 OK';
end $$;


-- ============================================================================
-- R4 -- all-day expandable master, busy vs available
--
--   covered G: G14 (expandable_master)
--   covered N: none
--
-- Three adjacent one-day occurrences merge into ONE span, so this also proves
-- the whole merged span disappears when the master turns available -- not just
-- one day of it.
-- ============================================================================
do $$
declare
  v_owner constant uuid   := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    constant uuid   := '0021b001-0000-4000-8000-000000000001';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date   := date '2026-06-01';
  v_td    constant date   := date '2026-06-08';
  v_m4    constant uuid   := '0021c004-0000-4000-8000-000000000001';
  v_res   jsonb;
  v_n     bigint;
begin
  raise notice 'R4: all-day expandable master, busy vs available';

  -- Occurrences on 06-02, 06-03, 06-04, each [d, d+1) -- adjacent, so they
  -- collapse to the single span [06-02, 06-05).
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             rrule, availability)
  values (v_m4, v_owner, '', 'busy_only', true,
          date '2026-06-02', date '2026-06-03', 'FREQ=DAILY;COUNT=3', 'busy');

  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert (v_res->>'complete')::boolean = true, 'R4.P1 complete, got ' || v_res::text;
  assert jsonb_array_length(v_res->'slots') = 1,
    format('R4.P1 three adjacent occurrences must merge into one span, got %s',
           jsonb_array_length(v_res->'slots'));
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', true,
           'start_date', to_jsonb(date '2026-06-02'),
           'end_date',   to_jsonb(date '2026-06-05')),
    'R4.P1 the merged span must END at 06-05; a series that did not stop would run to '
    'the window edge. Got ' || (v_res->'slots'->0)::text;

  update public.events set availability = 'available' where id = v_m4;
  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert v_res = '{"complete": true, "slots": []}'::jsonb,
    'R4.P2 an available all-day master must generate nothing AND stay complete, got ' || v_res::text;

  delete from public.events where id = v_m4;
  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('R4 cleanup: %s event(s) left behind', v_n);
  raise notice 'R4 OK';
end $$;


-- ============================================================================
-- R5 -- timed exception snapshot in isolation, busy vs available
--
--   covered G: G13 (timed_exception_busy)
--   covered N: none
--
-- The master's own occurrences are deliberately OUTSIDE the window (a COUNT=3
-- series that runs in May), so the only thing that can reach the window is the
-- exception's snapshot. That isolates the exception CTE's gate from any detach
-- behaviour -- which is R11's subject, not this one.
--
-- The master is still expandable FOR THIS WINDOW (it generates zero occurrences
-- in it), so neither (A) nor (C) fires and `complete` stays true in both phases.
-- ============================================================================
do $$
declare
  v_owner constant uuid   := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    constant uuid   := '0021b001-0000-4000-8000-000000000001';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date   := date '2026-06-01';
  v_td    constant date   := date '2026-06-08';
  v_m5    constant uuid   := '0021c005-0000-4000-8000-000000000001';
  v_x5    constant uuid   := '0021c005-0000-4000-8000-000000000002';
  v_res   jsonb;
  v_n     bigint;
begin
  raise notice 'R5: timed exception snapshot in isolation, busy vs available';

  -- Master: 05-20, 05-21, 05-22 at 09:00Z. All three are before the window.
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             rrule, timezone, availability)
  values (v_m5, v_owner, '', 'busy_only', false,
          timestamptz '2026-05-20 09:00:00+00', timestamptz '2026-05-20 10:00:00+00',
          'FREQ=DAILY;COUNT=3', 'UTC', 'busy');

  -- Exception on the second slot, moved INTO the window.
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             recurrence_id, recurrence_slot_start, is_cancelled, availability)
  values (v_x5, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-03 14:00:00+00', timestamptz '2026-06-03 15:00:00+00',
          v_m5, timestamptz '2026-05-21 09:00:00+00', false, 'busy');

  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert (v_res->>'complete')::boolean = true, 'R5.P1 complete, got ' || v_res::text;
  assert jsonb_array_length(v_res->'slots') = 1,
    format('R5.P1 only the exception snapshot may reach this window, got %s slot(s): %s',
           jsonb_array_length(v_res->'slots'), (v_res->'slots')::text);
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-06-03 14:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-03 15:00:00+00')),
    'R5.P1 the snapshot itself, got ' || (v_res->'slots'->0)::text;

  update public.events set availability = 'available' where id = v_x5;
  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert v_res = '{"complete": true, "slots": []}'::jsonb,
    'R5.P2 an available exception snapshot must disclose nothing, got ' || v_res::text;

  delete from public.events where id = v_x5;
  delete from public.events where id = v_m5;
  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('R5 cleanup: %s event(s) left behind', v_n);
  raise notice 'R5 OK';
end $$;


-- ============================================================================
-- R6 -- all-day exception snapshot in isolation, busy vs available
--
--   covered G: G15 (exception_busy)
--   covered N: none
--
-- R5 in the date model. Separate case because exception_busy is a different CTE
-- reading different columns, and the slot key is a date rather than an instant.
-- ============================================================================
do $$
declare
  v_owner constant uuid   := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    constant uuid   := '0021b001-0000-4000-8000-000000000001';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date   := date '2026-06-01';
  v_td    constant date   := date '2026-06-08';
  v_m6    constant uuid   := '0021c006-0000-4000-8000-000000000001';
  v_x6    constant uuid   := '0021c006-0000-4000-8000-000000000002';
  v_res   jsonb;
  v_n     bigint;
begin
  raise notice 'R6: all-day exception snapshot in isolation, busy vs available';

  -- Master: 05-20, 05-21, 05-22, all before the window.
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             rrule, availability)
  values (v_m6, v_owner, '', 'busy_only', true,
          date '2026-05-20', date '2026-05-21', 'FREQ=DAILY;COUNT=3', 'busy');

  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             recurrence_id, recurrence_slot_date, is_cancelled, availability)
  values (v_x6, v_owner, '', 'busy_only', true,
          date '2026-06-04', date '2026-06-05',
          v_m6, date '2026-05-21', false, 'busy');

  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert (v_res->>'complete')::boolean = true, 'R6.P1 complete, got ' || v_res::text;
  assert jsonb_array_length(v_res->'slots') = 1,
    format('R6.P1 only the exception snapshot may reach this window, got %s slot(s): %s',
           jsonb_array_length(v_res->'slots'), (v_res->'slots')::text);
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', true,
           'start_date', to_jsonb(date '2026-06-04'),
           'end_date',   to_jsonb(date '2026-06-05')),
    'R6.P1 the snapshot itself, got ' || (v_res->'slots'->0)::text;

  update public.events set availability = 'available' where id = v_x6;
  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert v_res = '{"complete": true, "slots": []}'::jsonb,
    'R6.P2 an available all-day exception snapshot must disclose nothing, got ' || v_res::text;

  delete from public.events where id = v_x6;
  delete from public.events where id = v_m6;
  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('R6 cleanup: %s event(s) left behind', v_n);
  raise notice 'R6 OK';
end $$;


-- ============================================================================
-- R7 -- completeness (A): an unexpandable master, busy vs available
--
--   covered G: G17 (branch (A), where the scanned row e IS the master)
--   covered N: none
--
-- FREQ=MONTHLY is outside the SQL subset, so the series cannot be expanded and
-- contributes no slots either way. The SLOTS ARE IDENTICAL in both phases and
-- only `complete` moves -- which is exactly the gate, observed on its own.
--
-- This is the case 0021's header describes in words: a repeating "I am free on
-- Tuesdays" that this server cannot expand must not raise the share page's
-- warning permanently, about nothing.
-- ============================================================================
do $$
declare
  v_owner constant uuid   := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    constant uuid   := '0021b001-0000-4000-8000-000000000001';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date   := date '2026-06-01';
  v_td    constant date   := date '2026-06-08';
  v_m7    constant uuid   := '0021c007-0000-4000-8000-000000000001';
  v_res   jsonb;
  v_n     bigint;
begin
  raise notice 'R7: completeness (A), unexpandable master, busy vs available';

  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             rrule, availability)
  values (v_m7, v_owner, '', 'busy_only', true,
          date '2026-06-02', date '2026-06-03', 'FREQ=MONTHLY', 'busy');

  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert v_res = '{"complete": false, "slots": []}'::jsonb,
    'R7.P1 a BUSY master this server cannot expand must force complete=false with no '
    'slots, got ' || v_res::text;

  update public.events set availability = 'available' where id = v_m7;
  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert v_res = '{"complete": true, "slots": []}'::jsonb,
    'R7.P2 an AVAILABLE master that cannot be expanded says nothing about the busy set, '
    'so complete must be true. Got ' || v_res::text;

  delete from public.events where id = v_m7;
  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('R7 cleanup: %s event(s) left behind', v_n);
  raise notice 'R7 OK';
end $$;


-- ============================================================================
-- R8 -- completeness (B): a shape-mismatched exception on a busy master
--
--   covered G: G18 (branch (B), where m is the master and e is the EXCEPTION)
--   covered N: N05 (the outer completeness scan must stay ungated)
--
-- DEFENSIVE-BRANCH FIXTURE. The exception below is timed while its master is
-- all-day. 0017's graph trigger rejects that shape, so this state is not
-- reachable through the current client path; see the file header. The branch
-- still has to work, because it is the only thing standing between an
-- OVER-STATED busy set and a complete=true answer.
--
-- What P1 pins: the all-day anti-join matches on recurrence_slot_date, which a
-- timed exception does not carry. Nothing detaches. The master's three
-- occurrences stay in the busy set even though the owner replaced one of them
-- with an AVAILABLE occurrence -- and (B) is what reports that as incomplete.
-- Gate the outer scan on e.availability and X8 drops out of the scan entirely,
-- (B) never fires, and the RPC would call that over-stated set complete.
--
-- BYPASS: events_quota_graph_ai only, for X8's INSERT only. See the header.
-- ============================================================================
do $$
declare
  v_owner constant uuid   := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    constant uuid   := '0021b001-0000-4000-8000-000000000001';
  v_t1    constant text   := 'tw-0021-runtime-suite-token-include-private-true';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date   := date '2026-06-01';
  v_td    constant date   := date '2026-06-08';
  v_m8    constant uuid   := '0021c008-0000-4000-8000-000000000001';
  v_x8    constant uuid   := '0021c008-0000-4000-8000-000000000002';
  v_res   jsonb;
  v_wrap  jsonb;
  v_tg    "char";
  v_n     bigint;
begin
  raise notice 'R8: completeness (B), shape-mismatched exception on a busy master';

  -- Pre-bypass: the trigger we are about to step around must be on.
  select t.tgenabled into v_tg
  from pg_catalog.pg_trigger t
  where t.tgrelid = 'public.events'::regclass
    and t.tgname = 'events_quota_graph_ai' and not t.tgisinternal;
  assert v_tg = 'O', format('R8 pre-bypass: events_quota_graph_ai must be enabled, tgenabled=%s', v_tg);

  -- The master is an ordinary expandable all-day series: no bypass needed.
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             rrule, availability)
  values (v_m8, v_owner, '', 'busy_only', true,
          date '2026-06-02', date '2026-06-03', 'FREQ=DAILY;COUNT=3', 'busy');

  -- --------------------------------------------------- minimal bypass: 1 stmt
  alter table public.events disable trigger events_quota_graph_ai;
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             recurrence_id, recurrence_slot_start, is_cancelled, availability)
  values (v_x8, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-03 14:00:00+00', timestamptz '2026-06-03 15:00:00+00',
          v_m8, timestamptz '2026-06-03 00:00:00+00', false, 'available');
  alter table public.events enable trigger events_quota_graph_ai;
  -- ------------------------------------------------------- bypass ends here

  select t.tgenabled into v_tg
  from pg_catalog.pg_trigger t
  where t.tgrelid = 'public.events'::regclass
    and t.tgname = 'events_quota_graph_ai' and not t.tgisinternal;
  assert v_tg = 'O',
    format('R8 the trigger must be re-enabled immediately, tgenabled=%s', v_tg);

  -- The fixture is the one we meant to build, not something the trigger ate.
  assert exists (
    select 1 from public.events x
    where x.id = v_x8 and x.recurrence_id = v_m8
      and x.all_day = false and x.recurrence_slot_start is not null
      and x.availability = 'available'),
    'R8 the shape-mismatched exception was not created; the bypass did not take effect';

  ----------------------------------------------------------------- R8 P1
  -- Master busy: nothing detaches, the three occurrences merge, the available
  -- exception discloses nothing of its own, and (B) reports the window as
  -- incomplete.
  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert (v_res->>'complete')::boolean = false,
    'R8.P1 a mismatched exception on a BUSY master must force complete=false, got ' || v_res::text;
  assert jsonb_array_length(v_res->'slots') = 1,
    format('R8.P1 expected the single merged master span, got %s slot(s): %s',
           jsonb_array_length(v_res->'slots'), (v_res->'slots')::text);
  assert v_res->'slots'->0 = jsonb_build_object(
           'all_day', true,
           'start_date', to_jsonb(date '2026-06-02'),
           'end_date',   to_jsonb(date '2026-06-05')),
    'R8.P1 the master span must be intact -- a timed slot key cannot detach an all-day '
    'occurrence. Got ' || (v_res->'slots'->0)::text;
  -- The available timed exception must not have contributed a snapshot.
  assert not (v_res->'slots' @> jsonb_build_array(jsonb_build_object(
           'all_day', false,
           'start', to_jsonb(timestamptz '2026-06-03 14:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-03 15:00:00+00')))),
    'R8.P1 the AVAILABLE exception snapshot must not be disclosed, got ' || (v_res->'slots')::text;

  -- Through the public entry point, as the share page reaches it.
  perform set_config('role', 'anon', true);
  v_wrap := public.get_free_busy(v_t1, v_from, v_to, v_fd, v_td);
  perform set_config('role', 'none', true);
  assert v_wrap = v_res,
    'R8.P1 the wrapper must return exactly what the core returned. core=' || v_res::text
    || ' wrapper=' || v_wrap::text;

  ----------------------------------------------------------------- R8 P2
  -- Only `availability` changes here. events_quota_graph_au fires and passes:
  -- availability is not one of the graph-relevant columns, so its candidate set
  -- is empty and the mismatched exception is never re-examined. No bypass.
  update public.events set availability = 'available' where id = v_m8;

  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert v_res = '{"complete": true, "slots": []}'::jsonb,
    'R8.P2 with an AVAILABLE master there is no busy to over-state and nothing to be '
    'incomplete about, got ' || v_res::text;

  perform set_config('role', 'anon', true);
  v_wrap := public.get_free_busy(v_t1, v_from, v_to, v_fd, v_td);
  perform set_config('role', 'none', true);
  assert v_wrap = v_res,
    'R8.P2 the wrapper must return exactly what the core returned. core=' || v_res::text
    || ' wrapper=' || v_wrap::text;

  ----------------------------------------------------------------- cleanup
  -- 0017 registers no DELETE trigger, so neither delete needs a bypass.
  delete from public.events where id = v_x8;
  delete from public.events where id = v_m8;

  select t.tgenabled into v_tg
  from pg_catalog.pg_trigger t
  where t.tgrelid = 'public.events'::regclass
    and t.tgname = 'events_quota_graph_ai' and not t.tgisinternal;
  assert v_tg = 'O', format('R8 the trigger must end this case enabled, tgenabled=%s', v_tg);

  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('R8 cleanup: %s event(s) left behind', v_n);
  raise notice 'R8 OK';
end $$;


-- ============================================================================
-- R9 -- completeness (C): an exception whose master cannot be expanded
--
--   covered G: G19 (branch (C), where m is the master and e is the EXCEPTION)
--   covered N: none
--
-- The strongest single piece of evidence for 0021's central inference. The
-- SLOTS ARE BYTE-IDENTICAL in both phases -- the busy exception is enumerated
-- from its own columns and never joins the master -- while `complete` flips.
-- That is (C)'s gate and nothing else.
-- ============================================================================
do $$
declare
  v_owner constant uuid   := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    constant uuid   := '0021b001-0000-4000-8000-000000000001';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date   := date '2026-06-01';
  v_td    constant date   := date '2026-06-08';
  v_m9    constant uuid   := '0021c009-0000-4000-8000-000000000001';
  v_x9    constant uuid   := '0021c009-0000-4000-8000-000000000002';
  v_p1    jsonb;
  v_p2    jsonb;
  v_n     bigint;
begin
  raise notice 'R9: completeness (C), exception of an unexpandable master';

  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             rrule, availability)
  values (v_m9, v_owner, '', 'busy_only', true,
          date '2026-06-02', date '2026-06-03', 'FREQ=MONTHLY', 'busy');

  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             recurrence_id, recurrence_slot_date, is_cancelled, availability)
  values (v_x9, v_owner, '', 'busy_only', true,
          date '2026-06-05', date '2026-06-06',
          v_m9, date '2026-06-02', false, 'busy');

  v_p1 := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert (v_p1->>'complete')::boolean = false,
    'R9.P1 an exception whose BUSY parent cannot be expanded must force complete=false, '
    'got ' || v_p1::text;
  assert jsonb_array_length(v_p1->'slots') = 1,
    format('R9.P1 only the exception snapshot is disclosable, got %s slot(s): %s',
           jsonb_array_length(v_p1->'slots'), (v_p1->'slots')::text);
  assert v_p1->'slots'->0 = jsonb_build_object(
           'all_day', true,
           'start_date', to_jsonb(date '2026-06-05'),
           'end_date',   to_jsonb(date '2026-06-06')),
    'R9.P1 the snapshot, got ' || (v_p1->'slots'->0)::text;

  update public.events set availability = 'available' where id = v_m9;

  v_p2 := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert (v_p2->>'complete')::boolean = true,
    'R9.P2 an AVAILABLE parent can hide no busy, so complete must be true, got ' || v_p2::text;
  assert v_p2->'slots' = v_p1->'slots',
    'R9.P2 the disclosed busy set must be UNCHANGED -- the exception CTEs never join the '
    'master. P1=' || (v_p1->'slots')::text || ' P2=' || (v_p2->'slots')::text;

  delete from public.events where id = v_x9;
  delete from public.events where id = v_m9;
  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('R9 cleanup: %s event(s) left behind', v_n);
  raise notice 'R9 OK';
end $$;


-- ============================================================================
-- R10 -- the slot-mismatch CTE (step 3d)
--
--   covered G: G20 (the expandable CTE inside step 3d, gated on m)
--   covered N: none  (N03 is R13's subject)
--
-- A slot key one second off every generated instant. 0021's comment names a DST
-- fold as the way this happens in the wild; the off-by-one-second fixture
-- reaches the same branch deterministically, and DST correctness stays 0009's
-- job.
--
-- Reaching 3d, condition by condition:
--   expandable CTE:  rrule not null, all_day=false, visibility ok,
--                    m.availability='busy' (P1), start_at < p_to,
--                    timezone in v_ok_tz, timed subset, count <= cap  -- all true
--   exists clause:   slot 06-03T09:00:01Z  <  p_to                    -- true
--                    slot + dur (10:00:01Z) >  p_from                 -- true
--                    slot NOT in {06-02,06-03,06-04 at 09:00:00Z}     -- true
--   => v_slot_mismatch, so complete = false.
-- In P2 the master is available, the CTE is empty, and the exists cannot fire.
--
-- The exception stays BUSY in both phases on purpose: the only variable is the
-- master's availability, so the gate is observed on its own.
-- ============================================================================
do $$
declare
  v_owner constant uuid   := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    constant uuid   := '0021b001-0000-4000-8000-000000000001';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date   := date '2026-06-01';
  v_td    constant date   := date '2026-06-08';
  v_m10   constant uuid   := '0021c010-0000-4000-8000-000000000001';
  v_x10   constant uuid   := '0021c010-0000-4000-8000-000000000002';
  v_res   jsonb;
  v_n     bigint;
begin
  raise notice 'R10: slot-mismatch CTE (3d), busy vs available master';

  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             rrule, timezone, availability)
  values (v_m10, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 10:00:00+00',
          'FREQ=DAILY;COUNT=3', 'UTC', 'busy');

  -- One second past the second generated instant: matches nothing, detaches nothing.
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             recurrence_id, recurrence_slot_start, is_cancelled, availability)
  values (v_x10, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-03 14:00:00+00', timestamptz '2026-06-03 15:00:00+00',
          v_m10, timestamptz '2026-06-03 09:00:01+00', false, 'busy');

  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert (v_res->>'complete')::boolean = false,
    'R10.P1 a slot that matches no generated occurrence must force complete=false, got '
    || v_res::text;
  assert jsonb_array_length(v_res->'slots') = 4,
    format('R10.P1 nothing detaches, so all three occurrences plus the snapshot are '
           'disclosed; got %s slot(s): %s', jsonb_array_length(v_res->'slots'),
           (v_res->'slots')::text);
  assert v_res->'slots'->0 = jsonb_build_object('all_day', false,
           'start', to_jsonb(timestamptz '2026-06-02 09:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-02 10:00:00+00')),
    'R10.P1 slot 0, got ' || (v_res->'slots'->0)::text;
  assert v_res->'slots'->1 = jsonb_build_object('all_day', false,
           'start', to_jsonb(timestamptz '2026-06-03 09:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-03 10:00:00+00')),
    'R10.P1 slot 1 -- the occurrence the mismatched key failed to detach, got '
    || (v_res->'slots'->1)::text;
  assert v_res->'slots'->2 = jsonb_build_object('all_day', false,
           'start', to_jsonb(timestamptz '2026-06-03 14:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-03 15:00:00+00')),
    'R10.P1 slot 2 -- the exception snapshot, got ' || (v_res->'slots'->2)::text;
  assert v_res->'slots'->3 = jsonb_build_object('all_day', false,
           'start', to_jsonb(timestamptz '2026-06-04 09:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-04 10:00:00+00')),
    'R10.P1 slot 3, got ' || (v_res->'slots'->3)::text;

  update public.events set availability = 'available' where id = v_m10;

  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert (v_res->>'complete')::boolean = true,
    'R10.P2 an AVAILABLE master is not in the 3d CTE, so a mismatched slot beneath it '
    'corrupts no disclosed busy set, got ' || v_res::text;
  assert jsonb_array_length(v_res->'slots') = 1,
    format('R10.P2 only the still-busy exception snapshot remains, got %s slot(s): %s',
           jsonb_array_length(v_res->'slots'), (v_res->'slots')::text);
  assert v_res->'slots'->0 = jsonb_build_object('all_day', false,
           'start', to_jsonb(timestamptz '2026-06-03 14:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-03 15:00:00+00')),
    'R10.P2 the snapshot, got ' || (v_res->'slots'->0)::text;

  delete from public.events where id = v_x10;
  delete from public.events where id = v_m10;
  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('R10 cleanup: %s event(s) left behind', v_n);
  raise notice 'R10 OK';
end $$;


-- ============================================================================
-- R11 -- Busy timed master + AVAILABLE timed exception          [MOST IMPORTANT]
--
--   covered G: G12 (master side), G13 (the snapshot that must not appear)
--   covered N: N01 -- the timed detach anti-join must have NO availability filter
--
-- The owner replaced one occurrence of a busy series with an available one. Two
-- things must happen, and they are different things:
--
--   * the replaced occurrence DETACHES -- that is structural, and the anti-join
--     is deliberately blind to availability, visibility and is_cancelled alike;
--   * the replacement contributes NO busy -- that is availability, and it is
--     the exception CTE's gate.
--
-- Put an availability filter on the anti-join and the master's 06-03 occurrence
-- comes back: the owner declared themselves free and the share page would show
-- them busy. This case asserts the ABSENCE of both intervals, and the exact
-- identity of the two that remain.
--
-- The contrast phase flips only the exception to busy: the detach must be
-- unchanged, and only the snapshot appears.
-- ============================================================================
do $$
declare
  v_owner constant uuid   := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    constant uuid   := '0021b001-0000-4000-8000-000000000001';
  v_t1    constant text   := 'tw-0021-runtime-suite-token-include-private-true';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date   := date '2026-06-01';
  v_td    constant date   := date '2026-06-08';
  v_m11   constant uuid   := '0021c011-0000-4000-8000-000000000001';
  v_x11   constant uuid   := '0021c011-0000-4000-8000-000000000002';
  -- The three intervals this case reasons about.
  v_occ1  constant jsonb  := jsonb_build_object('all_day', false,
                              'start', to_jsonb(timestamptz '2026-06-02 09:00:00+00'),
                              'end',   to_jsonb(timestamptz '2026-06-02 10:00:00+00'));
  v_occ2  constant jsonb  := jsonb_build_object('all_day', false,
                              'start', to_jsonb(timestamptz '2026-06-03 09:00:00+00'),
                              'end',   to_jsonb(timestamptz '2026-06-03 10:00:00+00'));
  v_occ3  constant jsonb  := jsonb_build_object('all_day', false,
                              'start', to_jsonb(timestamptz '2026-06-04 09:00:00+00'),
                              'end',   to_jsonb(timestamptz '2026-06-04 10:00:00+00'));
  v_snap  constant jsonb  := jsonb_build_object('all_day', false,
                              'start', to_jsonb(timestamptz '2026-06-03 14:00:00+00'),
                              'end',   to_jsonb(timestamptz '2026-06-03 15:00:00+00'));
  v_res   jsonb;
  v_wrap  jsonb;
  v_n     bigint;
begin
  raise notice 'R11: Busy timed master + AVAILABLE timed exception';

  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             rrule, timezone, availability)
  values (v_m11, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 10:00:00+00',
          'FREQ=DAILY;COUNT=3', 'UTC', 'busy');

  -- Slot key EXACTLY the second generated instant, so the detach is real.
  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             recurrence_id, recurrence_slot_start, is_cancelled, availability)
  values (v_x11, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-03 14:00:00+00', timestamptz '2026-06-03 15:00:00+00',
          v_m11, timestamptz '2026-06-03 09:00:00+00', false, 'available');

  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);

  -- complete: the master expands, the shapes agree, the slot matches. Nothing
  -- here is unaccountable.
  assert (v_res->>'complete')::boolean = true,
    'R11 complete must be true -- everything in this window is accounted for. Got '
    || v_res::text;

  -- ABSENCE 1: the replaced occurrence must NOT come back.
  assert not (v_res->'slots' @> jsonb_build_array(v_occ2)),
    'R11 THE POINT OF THIS CASE: the busy master occurrence at 06-03T09:00Z was replaced '
    'by an AVAILABLE exception and must not be disclosed. If it is here, the detach '
    'anti-join has been given an availability filter. Got ' || (v_res->'slots')::text;

  -- ABSENCE 2: the available replacement contributes nothing of its own.
  assert not (v_res->'slots' @> jsonb_build_array(v_snap)),
    'R11 the AVAILABLE exception snapshot must not be disclosed, got ' || (v_res->'slots')::text;

  -- PRESENCE: and exactly the two untouched occurrences remain, in order.
  assert jsonb_array_length(v_res->'slots') = 2,
    format('R11 expected exactly the two untouched occurrences, got %s slot(s): %s',
           jsonb_array_length(v_res->'slots'), (v_res->'slots')::text);
  assert v_res->'slots'->0 = v_occ1,
    'R11 the occurrence BEFORE the exception must still be busy, got ' || (v_res->'slots'->0)::text;
  assert v_res->'slots'->1 = v_occ3,
    'R11 the occurrence AFTER the exception must still be busy, got ' || (v_res->'slots'->1)::text;

  -- The public entry point must agree.
  perform set_config('role', 'anon', true);
  v_wrap := public.get_free_busy(v_t1, v_from, v_to, v_fd, v_td);
  perform set_config('role', 'none', true);
  assert v_wrap = v_res,
    'R11 the wrapper must return exactly what the core returned. core=' || v_res::text
    || ' wrapper=' || v_wrap::text;

  ------------------------------------------------------------- contrast phase
  -- Only the exception's availability changes. The detach must not move.
  update public.events set availability = 'busy' where id = v_x11;

  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert (v_res->>'complete')::boolean = true, 'R11 contrast complete, got ' || v_res::text;
  assert not (v_res->'slots' @> jsonb_build_array(v_occ2)),
    'R11 contrast: the detach is structural and must hold whatever the exception says '
    'about itself. Got ' || (v_res->'slots')::text;
  assert jsonb_array_length(v_res->'slots') = 3,
    format('R11 contrast expected three slots, got %s: %s',
           jsonb_array_length(v_res->'slots'), (v_res->'slots')::text);
  assert v_res->'slots'->0 = v_occ1, 'R11 contrast slot 0, got ' || (v_res->'slots'->0)::text;
  assert v_res->'slots'->1 = v_snap, 'R11 contrast slot 1 (the snapshot), got ' || (v_res->'slots'->1)::text;
  assert v_res->'slots'->2 = v_occ3, 'R11 contrast slot 2, got ' || (v_res->'slots'->2)::text;

  delete from public.events where id = v_x11;
  delete from public.events where id = v_m11;
  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('R11 cleanup: %s event(s) left behind', v_n);
  raise notice 'R11 OK';
end $$;


-- ============================================================================
-- R12 -- Busy all-day master + AVAILABLE all-day exception
--
--   covered G: G14 (master side), G15 (the snapshot that must not appear)
--   covered N: N02 -- the all-day detach anti-join must have NO availability filter
--
-- R11 in date space, and a separate case because it is separate code: the
-- anti-join matches recurrence_slot_date against a generated DATE, and the
-- occurrences are day spans rather than instants.
--
-- The three generated days are 06-02, 06-03 and 06-04, each [d, d+1). Detaching
-- 06-03 leaves two spans with a hole between them -- so the hole is visible in
-- the slot count as well as in the containment check, and 06-03 must be FREE.
-- ============================================================================
do $$
declare
  v_owner constant uuid   := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    constant uuid   := '0021b001-0000-4000-8000-000000000001';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date   := date '2026-06-01';
  v_td    constant date   := date '2026-06-08';
  v_m12   constant uuid   := '0021c012-0000-4000-8000-000000000001';
  v_x12   constant uuid   := '0021c012-0000-4000-8000-000000000002';
  v_day2  constant jsonb  := jsonb_build_object('all_day', true,
                              'start_date', to_jsonb(date '2026-06-02'),
                              'end_date',   to_jsonb(date '2026-06-03'));
  v_day3  constant jsonb  := jsonb_build_object('all_day', true,
                              'start_date', to_jsonb(date '2026-06-03'),
                              'end_date',   to_jsonb(date '2026-06-04'));
  v_day4  constant jsonb  := jsonb_build_object('all_day', true,
                              'start_date', to_jsonb(date '2026-06-04'),
                              'end_date',   to_jsonb(date '2026-06-05'));
  v_snap  constant jsonb  := jsonb_build_object('all_day', true,
                              'start_date', to_jsonb(date '2026-06-06'),
                              'end_date',   to_jsonb(date '2026-06-07'));
  v_res   jsonb;
  v_cover bigint;
  v_n     bigint;
begin
  raise notice 'R12: Busy all-day master + AVAILABLE all-day exception';

  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             rrule, availability)
  values (v_m12, v_owner, '', 'busy_only', true,
          date '2026-06-02', date '2026-06-03', 'FREQ=DAILY;COUNT=3', 'busy');

  -- recurrence_slot_date matches the second generated DATE exactly.
  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             recurrence_id, recurrence_slot_date, is_cancelled, availability)
  values (v_x12, v_owner, '', 'busy_only', true,
          date '2026-06-06', date '2026-06-07',
          v_m12, date '2026-06-03', false, 'available');

  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);

  assert (v_res->>'complete')::boolean = true,
    'R12 complete must be true -- the master expands and the slot key matches. Got '
    || v_res::text;

  -- ABSENCE 1: the detached DAY must not be disclosed, as a span of its own ...
  assert not (v_res->'slots' @> jsonb_build_array(v_day3)),
    'R12 THE POINT OF THIS CASE: the busy master occurrence on 06-03 was replaced by an '
    'AVAILABLE exception and must not be disclosed. Got ' || (v_res->'slots')::text;

  -- ... nor swallowed inside a wider span. Containment alone cannot see that,
  -- so this asks the question directly: does any disclosed span cover 06-03?
  select count(*) into v_cover
  from jsonb_array_elements(v_res->'slots') s
  where (s.value->>'all_day')::boolean = true
    and (s.value->>'start_date')::date <= date '2026-06-03'
    and (s.value->>'end_date')::date   >  date '2026-06-03';
  assert v_cover = 0,
    format('R12 no disclosed span may cover 06-03; %s does/do. Got %s',
           v_cover, (v_res->'slots')::text);

  -- ABSENCE 2: the available replacement contributes nothing of its own.
  assert not (v_res->'slots' @> jsonb_build_array(v_snap)),
    'R12 the AVAILABLE exception snapshot must not be disclosed, got ' || (v_res->'slots')::text;

  -- PRESENCE: exactly the two surviving days, in date order, unmerged.
  assert jsonb_array_length(v_res->'slots') = 2,
    format('R12 expected the two surviving days, got %s slot(s): %s',
           jsonb_array_length(v_res->'slots'), (v_res->'slots')::text);
  assert v_res->'slots'->0 = v_day2, 'R12 slot 0, got ' || (v_res->'slots'->0)::text;
  assert v_res->'slots'->1 = v_day4, 'R12 slot 1, got ' || (v_res->'slots'->1)::text;

  ------------------------------------------------------------- contrast phase
  update public.events set availability = 'busy' where id = v_x12;

  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert (v_res->>'complete')::boolean = true, 'R12 contrast complete, got ' || v_res::text;
  assert not (v_res->'slots' @> jsonb_build_array(v_day3)),
    'R12 contrast: the date-space detach is structural and must hold whatever the '
    'exception says about itself. Got ' || (v_res->'slots')::text;
  select count(*) into v_cover
  from jsonb_array_elements(v_res->'slots') s
  where (s.value->>'all_day')::boolean = true
    and (s.value->>'start_date')::date <= date '2026-06-03'
    and (s.value->>'end_date')::date   >  date '2026-06-03';
  assert v_cover = 0,
    format('R12 contrast: 06-03 must still be free, %s span(s) cover it. Got %s',
           v_cover, (v_res->'slots')::text);
  assert jsonb_array_length(v_res->'slots') = 3,
    format('R12 contrast expected three spans, got %s: %s',
           jsonb_array_length(v_res->'slots'), (v_res->'slots')::text);
  assert v_res->'slots'->0 = v_day2, 'R12 contrast slot 0, got ' || (v_res->'slots'->0)::text;
  assert v_res->'slots'->1 = v_day4, 'R12 contrast slot 1, got ' || (v_res->'slots'->1)::text;
  assert v_res->'slots'->2 = v_snap, 'R12 contrast slot 2 (the snapshot), got ' || (v_res->'slots'->2)::text;

  delete from public.events where id = v_x12;
  delete from public.events where id = v_m12;
  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('R12 cleanup: %s event(s) left behind', v_n);
  raise notice 'R12 OK';
end $$;


-- ============================================================================
-- R13 -- a mismatched slot carried by an AVAILABLE exception
--
--   covered G: none of its own (it travels the 3d path R10 pins)
--   covered N: N03 -- the exception side of the slot-mismatch join must have NO
--                     availability filter
--
-- 0021 says it in one line: "a slot that matches nothing fails to detach
-- whatever it says about itself". Filter that join on availability and this
-- window silently reports complete=true while the busy set it discloses is not
-- the one the owner sees.
--
-- Single observation, no phases: the master stays busy and the exception stays
-- available, because that pairing is the whole question.
-- ============================================================================
do $$
declare
  v_owner constant uuid   := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    constant uuid   := '0021b001-0000-4000-8000-000000000001';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date   := date '2026-06-01';
  v_td    constant date   := date '2026-06-08';
  v_m13   constant uuid   := '0021c013-0000-4000-8000-000000000001';
  v_x13   constant uuid   := '0021c013-0000-4000-8000-000000000002';
  v_res   jsonb;
  v_n     bigint;
begin
  raise notice 'R13: mismatched slot carried by an AVAILABLE exception';

  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             rrule, timezone, availability)
  values (v_m13, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 10:00:00+00',
          'FREQ=DAILY;COUNT=3', 'UTC', 'busy');

  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             recurrence_id, recurrence_slot_start, is_cancelled, availability)
  values (v_x13, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-03 14:00:00+00', timestamptz '2026-06-03 15:00:00+00',
          v_m13, timestamptz '2026-06-03 09:00:01+00', false, 'available');

  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);

  assert (v_res->>'complete')::boolean = false,
    'R13 THE POINT OF THIS CASE: an AVAILABLE exception with a slot key that matches no '
    'generated occurrence still corrupts the busy set, and must still force '
    'complete=false. If this is true, the exception side of the 3d join has been given '
    'an availability filter. Got ' || v_res::text;

  assert jsonb_array_length(v_res->'slots') = 3,
    format('R13 nothing detaches and the available exception discloses nothing, so the '
           'three master occurrences stand alone; got %s slot(s): %s',
           jsonb_array_length(v_res->'slots'), (v_res->'slots')::text);
  assert v_res->'slots'->0 = jsonb_build_object('all_day', false,
           'start', to_jsonb(timestamptz '2026-06-02 09:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-02 10:00:00+00')),
    'R13 slot 0, got ' || (v_res->'slots'->0)::text;
  assert v_res->'slots'->1 = jsonb_build_object('all_day', false,
           'start', to_jsonb(timestamptz '2026-06-03 09:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-03 10:00:00+00')),
    'R13 slot 1, got ' || (v_res->'slots'->1)::text;
  assert v_res->'slots'->2 = jsonb_build_object('all_day', false,
           'start', to_jsonb(timestamptz '2026-06-04 09:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-04 10:00:00+00')),
    'R13 slot 2, got ' || (v_res->'slots'->2)::text;
  assert not (v_res->'slots' @> jsonb_build_array(jsonb_build_object('all_day', false,
           'start', to_jsonb(timestamptz '2026-06-03 14:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-03 15:00:00+00')))),
    'R13 the AVAILABLE snapshot must not be disclosed, got ' || (v_res->'slots')::text;

  delete from public.events where id = v_x13;
  delete from public.events where id = v_m13;
  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('R13 cleanup: %s event(s) left behind', v_n);
  raise notice 'R13 OK';
end $$;


-- ============================================================================
-- R14 -- AVAILABLE timed master + BUSY timed exception
--
--   covered G: G12 (master suppressed), G13 (exception still enumerated)
--   covered N: none
--
-- The inverse of R11, and the runtime form of the inference 0021's gates rest
-- on: the busy a series can put in a window comes from the occurrences the
-- master generates and the snapshots that replace some of them. An available
-- master contributes nothing from the first source whether or not this server
-- can expand it; the second source is enumerated WITHOUT the master, from the
-- exception row's own columns. So the disclosed set IS the complete set, and
-- complete=true is accurate rather than optimistic.
--
-- The master here is perfectly expandable -- that is deliberate. Its
-- occurrences are suppressed because it is available, not because anything
-- failed.
-- ============================================================================
do $$
declare
  v_owner constant uuid   := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    constant uuid   := '0021b001-0000-4000-8000-000000000001';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date   := date '2026-06-01';
  v_td    constant date   := date '2026-06-08';
  v_m14   constant uuid   := '0021c014-0000-4000-8000-000000000001';
  v_x14   constant uuid   := '0021c014-0000-4000-8000-000000000002';
  v_res   jsonb;
  v_n     bigint;
begin
  raise notice 'R14: AVAILABLE timed master + BUSY timed exception';

  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             rrule, timezone, availability)
  values (v_m14, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 10:00:00+00',
          'FREQ=DAILY;COUNT=3', 'UTC', 'available');

  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at,
                             recurrence_id, recurrence_slot_start, is_cancelled, availability)
  values (v_x14, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-03 14:00:00+00', timestamptz '2026-06-03 15:00:00+00',
          v_m14, timestamptz '2026-06-03 09:00:00+00', false, 'busy');

  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);

  assert (v_res->>'complete')::boolean = true,
    'R14 an available master hides no busy, so complete must be true, got ' || v_res::text;

  -- The master generated NOTHING -- checked as absence, not inferred from a count.
  assert not (v_res->'slots' @> jsonb_build_array(jsonb_build_object('all_day', false,
           'start', to_jsonb(timestamptz '2026-06-02 09:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-02 10:00:00+00')))),
    'R14 the AVAILABLE master must generate no busy (06-02), got ' || (v_res->'slots')::text;
  assert not (v_res->'slots' @> jsonb_build_array(jsonb_build_object('all_day', false,
           'start', to_jsonb(timestamptz '2026-06-04 09:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-04 10:00:00+00')))),
    'R14 the AVAILABLE master must generate no busy (06-04), got ' || (v_res->'slots')::text;

  -- The busy exception stands on its own.
  assert jsonb_array_length(v_res->'slots') = 1,
    format('R14 only the busy exception snapshot may be disclosed, got %s slot(s): %s',
           jsonb_array_length(v_res->'slots'), (v_res->'slots')::text);
  assert v_res->'slots'->0 = jsonb_build_object('all_day', false,
           'start', to_jsonb(timestamptz '2026-06-03 14:00:00+00'),
           'end',   to_jsonb(timestamptz '2026-06-03 15:00:00+00')),
    'R14 a BUSY exception contributes independently of its available master, got '
    || (v_res->'slots'->0)::text;

  delete from public.events where id = v_x14;
  delete from public.events where id = v_m14;
  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('R14 cleanup: %s event(s) left behind', v_n);
  raise notice 'R14 OK';
end $$;


-- ============================================================================
-- R15 -- AVAILABLE all-day master + BUSY all-day exception
--
--   covered G: G14 (master suppressed), G15 (exception still enumerated)
--   covered N: none
--
-- R14 in date space. Kept separate rather than copied: exception_busy is a
-- different CTE from timed_exception_busy, and branch (C)'s slot test reads the
-- parent's DURATION in the all-day arm while over-approximating in the timed
-- one. Nothing here is a timestamp.
-- ============================================================================
do $$
declare
  v_owner constant uuid   := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    constant uuid   := '0021b001-0000-4000-8000-000000000001';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date   := date '2026-06-01';
  v_td    constant date   := date '2026-06-08';
  v_m15   constant uuid   := '0021c015-0000-4000-8000-000000000001';
  v_x15   constant uuid   := '0021c015-0000-4000-8000-000000000002';
  v_res   jsonb;
  v_cover bigint;
  v_n     bigint;
begin
  raise notice 'R15: AVAILABLE all-day master + BUSY all-day exception';

  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             rrule, availability)
  values (v_m15, v_owner, '', 'busy_only', true,
          date '2026-06-02', date '2026-06-03', 'FREQ=DAILY;COUNT=3', 'available');

  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             recurrence_id, recurrence_slot_date, is_cancelled, availability)
  values (v_x15, v_owner, '', 'busy_only', true,
          date '2026-06-06', date '2026-06-07',
          v_m15, date '2026-06-03', false, 'busy');

  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);

  assert (v_res->>'complete')::boolean = true,
    'R15 an available all-day master hides no busy, so complete must be true, got '
    || v_res::text;

  -- None of the days the master would have generated may be disclosed.
  select count(*) into v_cover
  from jsonb_array_elements(v_res->'slots') s
  where (s.value->>'all_day')::boolean = true
    and (s.value->>'start_date')::date <  date '2026-06-05'
    and (s.value->>'end_date')::date   >  date '2026-06-02';
  assert v_cover = 0,
    format('R15 the AVAILABLE master must generate no busy anywhere in 06-02..06-05; '
           '%s span(s) overlap it. Got %s', v_cover, (v_res->'slots')::text);

  assert jsonb_array_length(v_res->'slots') = 1,
    format('R15 only the busy exception snapshot may be disclosed, got %s slot(s): %s',
           jsonb_array_length(v_res->'slots'), (v_res->'slots')::text);
  assert v_res->'slots'->0 = jsonb_build_object('all_day', true,
           'start_date', to_jsonb(date '2026-06-06'),
           'end_date',   to_jsonb(date '2026-06-07')),
    'R15 a BUSY all-day exception contributes independently of its available master, got '
    || (v_res->'slots'->0)::text;

  delete from public.events where id = v_x15;
  delete from public.events where id = v_m15;
  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('R15 cleanup: %s event(s) left behind', v_n);
  raise notice 'R15 OK';
end $$;


-- ============================================================================
-- R16 -- a cancelled exception is availability-independent
--
--   covered G: G14 (the master side). G15 is deliberately NOT reached: the
--              exception CTE requires is_cancelled = false.
--   covered N: N07 -- availability must not have been wired into the
--                     is_cancelled tests
--
-- A tombstone removes its slot and adds nothing. 0021 put availability beside
-- is_cancelled in the two exception CTEs, which is correct -- both ask whether
-- this snapshot puts busy here -- but neither may change what CANCELLING means.
--
-- Both values of availability are reachable in practice: buildCancellation
-- copies the master's availability onto the tombstone (see
-- src/services/exceptionEdit.test.ts). So the two answers below must be
-- identical, byte for byte, and that identity is the assertion.
-- ============================================================================
do $$
declare
  v_owner constant uuid   := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    constant uuid   := '0021b001-0000-4000-8000-000000000001';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date   := date '2026-06-01';
  v_td    constant date   := date '2026-06-08';
  v_m16   constant uuid   := '0021c016-0000-4000-8000-000000000001';
  v_x16   constant uuid   := '0021c016-0000-4000-8000-000000000002';
  v_day2  constant jsonb  := jsonb_build_object('all_day', true,
                              'start_date', to_jsonb(date '2026-06-02'),
                              'end_date',   to_jsonb(date '2026-06-03'));
  v_day4  constant jsonb  := jsonb_build_object('all_day', true,
                              'start_date', to_jsonb(date '2026-06-04'),
                              'end_date',   to_jsonb(date '2026-06-05'));
  v_p1    jsonb;
  v_p2    jsonb;
  v_cover bigint;
  v_n     bigint;
begin
  raise notice 'R16: cancelled exception is availability-independent';

  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             rrule, availability)
  values (v_m16, v_owner, '', 'busy_only', true,
          date '2026-06-02', date '2026-06-03', 'FREQ=DAILY;COUNT=3', 'busy');

  insert into public.events (id, owner_id, title, visibility, all_day, start_date, end_date,
                             recurrence_id, recurrence_slot_date, is_cancelled, availability)
  values (v_x16, v_owner, '', 'busy_only', true,
          date '2026-06-03', date '2026-06-04',
          v_m16, date '2026-06-03', true, 'busy');

  -- P1: tombstone carrying availability = 'busy' (a busy master's cancellation).
  v_p1 := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert (v_p1->>'complete')::boolean = true, 'R16.P1 complete, got ' || v_p1::text;
  assert jsonb_array_length(v_p1->'slots') = 2,
    format('R16.P1 the cancelled day is removed and nothing is added, so two spans '
           'remain; got %s: %s', jsonb_array_length(v_p1->'slots'), (v_p1->'slots')::text);
  assert v_p1->'slots'->0 = v_day2, 'R16.P1 slot 0, got ' || (v_p1->'slots'->0)::text;
  assert v_p1->'slots'->1 = v_day4, 'R16.P1 slot 1, got ' || (v_p1->'slots'->1)::text;
  select count(*) into v_cover
  from jsonb_array_elements(v_p1->'slots') s
  where (s.value->>'start_date')::date <= date '2026-06-03'
    and (s.value->>'end_date')::date   >  date '2026-06-03';
  assert v_cover = 0,
    format('R16.P1 the cancelled day 06-03 must be free, %s span(s) cover it', v_cover);

  -- P2: the same tombstone carrying availability = 'available'.
  update public.events set availability = 'available' where id = v_x16;
  v_p2 := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);

  assert v_p2 = v_p1,
    'R16 THE POINT OF THIS CASE: a cancellation means the occurrence did not happen, '
    'which is not a question about availability. The two answers must be identical. '
    'busy-tombstone=' || v_p1::text || ' available-tombstone=' || v_p2::text;

  delete from public.events where id = v_x16;
  delete from public.events where id = v_m16;
  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('R16 cleanup: %s event(s) left behind', v_n);
  raise notice 'R16 OK';
end $$;


-- ============================================================================
-- R17 -- private x availability x include_private are independent questions
--
--   covered G: G11 (timed_single, where the visibility filter and the
--              availability gate sit side by side)
--   covered N: N06 -- the eight include_private filters must still be there and
--                     must not have been replaced by availability
--
-- visibility answers "may we DISCLOSE this row?"; availability answers "does it
-- CONTRIBUTE BUSY at all?". Two one-variable comparisons separate them:
--
--   O1 -> O2 : only include_private moves (false -> true). The private BUSY row
--              appears. So its absence in O1 was visibility's doing.
--   O2 -> O3 : only E17b's availability moves (available -> busy), with
--              visibility and include_private held fixed. The private row
--              appears. So its absence in O2 was availability's doing.
--
-- The existing "private busy discloses a time range but no metadata" contract
-- is 0005's and is pinned structurally by the postflight (J01-J04); it is not
-- re-tested here.
-- ============================================================================
do $$
declare
  v_owner constant uuid   := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    constant uuid   := '0021b001-0000-4000-8000-000000000001';
  v_l0    constant uuid   := '0021b001-0000-4000-8000-000000000000';
  v_t1    constant text   := 'tw-0021-runtime-suite-token-include-private-true';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date   := date '2026-06-01';
  v_td    constant date   := date '2026-06-08';
  v_a     constant uuid   := '0021c017-0000-4000-8000-000000000001';  -- private BUSY
  v_b     constant uuid   := '0021c017-0000-4000-8000-000000000002';  -- private AVAILABLE
  v_slota constant jsonb  := jsonb_build_object('all_day', false,
                              'start', to_jsonb(timestamptz '2026-06-02 09:00:00+00'),
                              'end',   to_jsonb(timestamptz '2026-06-02 10:00:00+00'));
  v_slotb constant jsonb  := jsonb_build_object('all_day', false,
                              'start', to_jsonb(timestamptz '2026-06-05 09:00:00+00'),
                              'end',   to_jsonb(timestamptz '2026-06-05 10:00:00+00'));
  v_res   jsonb;
  v_wrap  jsonb;
  v_n     bigint;
begin
  raise notice 'R17: private x availability x include_private';

  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at, availability)
  values (v_a, v_owner, '', 'private', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 10:00:00+00', 'busy'),
         (v_b, v_owner, '', 'private', false,
          timestamptz '2026-06-05 09:00:00+00', timestamptz '2026-06-05 10:00:00+00', 'available');

  -- O1: include_private = false. Visibility removes BOTH rows.
  v_res := timeweave_private.free_busy_core(v_l0, v_from, v_to, v_fd, v_td);
  assert v_res = '{"complete": true, "slots": []}'::jsonb,
    'R17.O1 a link with include_private=false must disclose no private row at all, got '
    || v_res::text;

  -- O2: include_private = true. The BUSY private row appears; the AVAILABLE one
  --     does not, although visibility now permits it.
  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert (v_res->>'complete')::boolean = true, 'R17.O2 complete, got ' || v_res::text;
  assert jsonb_array_length(v_res->'slots') = 1,
    format('R17.O2 exactly the private BUSY row, got %s slot(s): %s',
           jsonb_array_length(v_res->'slots'), (v_res->'slots')::text);
  assert v_res->'slots'->0 = v_slota,
    'R17.O2 the private BUSY row, got ' || (v_res->'slots'->0)::text;
  assert not (v_res->'slots' @> jsonb_build_array(v_slotb)),
    'R17.O2 THE POINT OF THIS CASE: include_private=true lets us disclose the private '
    'row, and availability still says there is nothing to disclose. Got '
    || (v_res->'slots')::text;

  -- Same observation through the public entry point.
  perform set_config('role', 'anon', true);
  v_wrap := public.get_free_busy(v_t1, v_from, v_to, v_fd, v_td);
  perform set_config('role', 'none', true);
  assert v_wrap = v_res,
    'R17.O2 the wrapper must return exactly what the core returned. core=' || v_res::text
    || ' wrapper=' || v_wrap::text;

  -- O3: only E17b's availability changes. Everything else is held fixed.
  update public.events set availability = 'busy' where id = v_b;
  v_res := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);
  assert (v_res->>'complete')::boolean = true, 'R17.O3 complete, got ' || v_res::text;
  assert jsonb_array_length(v_res->'slots') = 2,
    format('R17.O3 both private rows are busy now, got %s slot(s): %s',
           jsonb_array_length(v_res->'slots'), (v_res->'slots')::text);
  assert v_res->'slots'->0 = v_slota, 'R17.O3 slot 0, got ' || (v_res->'slots'->0)::text;
  assert v_res->'slots'->1 = v_slotb,
    'R17.O3 the row that O2 withheld appears once -- and only once -- availability '
    'changes; nothing about visibility moved. Got ' || (v_res->'slots'->1)::text;

  delete from public.events where id in (v_a, v_b);
  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('R17 cleanup: %s event(s) left behind', v_n);
  raise notice 'R17 OK';
end $$;


-- ============================================================================
-- R18 -- the public wrapper contract
--
--   covered G: G11 (through the wrapper rather than the core)
--   covered N: none
--
-- Two things, both about public.get_free_busy rather than about a branch:
--
--   PHASE A  every relevant event is AVAILABLE -> {"complete": true, "slots": []}.
--            0021 creates a new way to reach that answer, and the answer is
--            load-bearing: it is byte-identical to what an expired, revoked or
--            unknown token returns (no existence oracle), and FreeBusyPage
--            renders it with the "nothing is shared for this period" note
--            rather than as a week of free time.
--
--   PHASE B  with busy present, the wrapper returns EXACTLY the core's answer.
--            0019's rate limiter and link resolution sit in between and must
--            not reshape it.
--
-- The wrapper is called as `anon`, which is the role the share page uses. Load
-- testing the limiter belongs to 0012 and is not repeated here.
-- ============================================================================
do $$
declare
  v_owner constant uuid   := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_l1    constant uuid   := '0021b001-0000-4000-8000-000000000001';
  v_t1    constant text   := 'tw-0021-runtime-suite-token-include-private-true';
  v_from  constant timestamptz := timestamptz '2026-06-01 00:00:00+00';
  v_to    constant timestamptz := timestamptz '2026-06-08 00:00:00+00';
  v_fd    constant date   := date '2026-06-01';
  v_td    constant date   := date '2026-06-08';
  v_e18   constant uuid   := '0021c018-0000-4000-8000-000000000001';
  v_core  jsonb;
  v_wrap  jsonb;
  v_n     bigint;
begin
  raise notice 'R18: public wrapper contract';

  insert into public.events (id, owner_id, title, visibility, all_day, start_at, end_at, availability)
  values (v_e18, v_owner, '', 'busy_only', false,
          timestamptz '2026-06-02 09:00:00+00', timestamptz '2026-06-02 10:00:00+00', 'available');

  ------------------------------------------------------------------- PHASE A
  perform set_config('role', 'anon', true);
  v_wrap := public.get_free_busy(v_t1, v_from, v_to, v_fd, v_td);
  perform set_config('role', 'none', true);
  assert v_wrap = '{"complete": true, "slots": []}'::jsonb,
    'R18.A with every relevant event AVAILABLE the wrapper must return the empty answer '
    'verbatim -- the same one an expired or unknown token returns. Got ' || v_wrap::text;

  ------------------------------------------------------------------- PHASE B
  update public.events set availability = 'busy' where id = v_e18;

  v_core := timeweave_private.free_busy_core(v_l1, v_from, v_to, v_fd, v_td);

  perform set_config('role', 'anon', true);
  v_wrap := public.get_free_busy(v_t1, v_from, v_to, v_fd, v_td);
  perform set_config('role', 'none', true);

  assert v_wrap = v_core,
    'R18.B the wrapper must not reshape the core answer. core=' || v_core::text
    || ' wrapper=' || v_wrap::text;
  assert v_wrap = jsonb_build_object(
           'complete', true,
           'slots', jsonb_build_array(jsonb_build_object(
             'all_day', false,
             'start', to_jsonb(timestamptz '2026-06-02 09:00:00+00'),
             'end',   to_jsonb(timestamptz '2026-06-02 10:00:00+00')))),
    'R18.B the wrapper answer itself, got ' || v_wrap::text;

  delete from public.events where id = v_e18;
  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('R18 cleanup: %s event(s) left behind', v_n);
  raise notice 'R18 OK';
end $$;


-- ============================================================================
-- FINAL CLEANUP AND WHOLE-SUITE ASSERTIONS
--
-- The canonical auth.users row is NOT touched: this file did not create it and
-- does not remove it. Everything else this suite made goes here, and then the
-- ROLLBACK below throws away even that.
-- ============================================================================
do $$
declare
  v_owner constant uuid   := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_tg    "char";
  v_n     bigint;
begin
  raise notice 'Final cleanup';

  delete from public.share_links
   where id in ('0021b001-0000-4000-8000-000000000001',
                '0021b001-0000-4000-8000-000000000000');

  select count(*) into v_n from public.events e where e.owner_id = v_owner;
  assert v_n = 0, format('FINAL fixtures leaked: %s event(s) remain for the test owner', v_n);

  select count(*) into v_n from public.share_links s where s.owner_id = v_owner;
  assert v_n = 0, format('FINAL fixtures leaked: %s share link(s) remain for the test owner', v_n);

  -- The one trigger R8 stepped around must end the run exactly as it started.
  select t.tgenabled into v_tg
  from pg_catalog.pg_trigger t
  where t.tgrelid = 'public.events'::regclass
    and t.tgname = 'events_quota_graph_ai' and not t.tgisinternal;
  assert v_tg = 'O',
    format('FINAL events_quota_graph_ai must end enabled, tgenabled=%s. The ROLLBACK '
           'below would restore it in any case, but reaching here with it off means the '
           'ENABLE in R8 did not run where it should have.', v_tg);

  -- The bootstrap row is still there, still exactly one, still not ours to delete.
  select count(*) into v_n from auth.users u where u.id = v_owner;
  assert v_n = 1,
    format('FINAL the canonical test user must still exist exactly once, found %s. This '
           'suite must never write to auth.users.', v_n);

  raise notice '0021 RUNTIME SUITE PASSED -- R1-R18 -- rolling back, no fixtures remain.';
end $$;


rollback;
