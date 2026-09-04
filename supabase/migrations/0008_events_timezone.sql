-- TimeWeave Phase 5b-2: persist the IANA time zone of a TIMED recurrence master.
--
-- SCOPE: storage foundation only. This migration does NOT expand timed
-- recurrences into Free/Busy and does NOT touch get_free_busy. Timed
-- recurrences stay unsupported (complete=false, no slots) exactly as in 5b-1.
-- The expansion arrives in 5b-3 and will read the column added here.
--
-- WHY A COLUMN AT ALL:
--   A timed recurrence repeats at a WALL CLOCK time, not at a fixed offset from
--   UTC. Across a DST boundary the same wall clock maps to a different instant,
--   so start_at alone cannot reproduce the series. The zone the rule was
--   authored in is therefore part of the rule and must be stored with it.
--
-- THE STATE MODEL (this file's whole reason for existing):
--   is_timed_master(row) := row.all_day = false AND row.rrule IS NOT NULL
--   (events_master_not_exception makes recurrence_id IS NULL follow from the
--   rrule test, so the transition function below needs only these two fields
--   even though events_timezone_placement states all three.)
--
--     N  = not a timed master (all-day rows, one-off timed rows, exceptions).
--          timezone IS NULL, enforced by events_timezone_placement.
--     M0 = timed master, timezone IS NULL  -- LEGACY only
--     M1 = timed master, timezone set to a usable IANA name
--
--   Allowed transitions:
--     INSERT -> N   ok      INSERT -> M0  REJECT     INSERT -> M1  ok
--     N  -> N       ok      N  -> M0      REJECT     N  -> M1      ok
--     M0 -> N       ok      M0 -> M0      ok (*)     M0 -> M1      ok
--     M1 -> N       ok      M1 -> M0      REJECT     M1 -> M1'     ok
--
--   (*) M0 -> M0 is the grandfather clause. Rows that predate this migration
--       keep timezone NULL and stay fully editable -- title, visibility, times,
--       even the rrule. We do NOT guess a zone for them: the zone a legacy
--       series was authored in is unknowable, and silently stamping the current
--       browser's zone would change what the series MEANS. Such a row becomes
--       M1 only when its owner explicitly chooses a zone.
--
--   M1 -> M0 is rejected for two reasons: it is a silent regression from
--   supported to unsupported, and without it the INSERT rule would be trivially
--   bypassable (insert with a zone, then null it out).
--
--   M0 is unreachable by design -- no edge enters it. That is the point: the
--   only M0 rows that can ever exist are the ones that predate this migration.
--
-- NOT DONE HERE, deliberately:
--   * no backfill of existing rows (see the grandfather clause above)
--   * no UPDATE of any existing row at all
--   * no change to get_free_busy, 0005, 0006 or 0007
--   * no test fixtures (those live in supabase/tests/)
--   * no index (the column is never searched or filtered on)
--
-- Security: the two helpers are SECURITY INVOKER with search_path = '' and read
-- no application data. EXECUTE is revoked from PUBLIC and granted to
-- `authenticated` only -- section 4 explains why that grant is required here
-- when 0006/0007 needed none.

-- ============================================================================
-- 1. The column.
--
-- Nullable with no default, so adding it rewrites nothing and every existing
-- row starts as timezone IS NULL. Timed masters among them become M0.
-- ============================================================================
alter table public.events
  add column if not exists timezone text;

comment on column public.events.timezone is
  'IANA time zone name of a TIMED recurrence master (the zone its wall clock is '
  'anchored in). NULL everywhere else, and NULL on masters that predate Phase '
  '5b-2. Not canonicalised: aliases such as Asia/Calcutta are accepted and '
  'resolve to the same rules as their primary name.';

-- ============================================================================
-- 2. Placement: WHICH rows may carry a time zone at all.
--
-- All-day rows never use one (they are pure DATE arithmetic). One-off timed
-- rows and exception rows already pin an absolute instant, so a zone there
-- would be decoration that invites the question "does changing it move the
-- event?". Keeping the column NULL means the answer can only be "no".
--
-- Every existing row has timezone IS NULL, so this validates immediately -- no
-- NOT VALID, no deferred validation.
--
-- The third conjunct, recurrence_id IS NULL, is logically redundant:
-- events_master_not_exception already forbids a row from carrying both an rrule
-- and a recurrence_id, so "rrule IS NOT NULL" implies it. It is spelled out
-- anyway because the invariant this constraint exists to express is "a time
-- zone belongs to a timed recurrence MASTER, never to an exception snapshot",
-- and a reader should be able to see that here without first going to find
-- another constraint. The slot columns need no mention: events_exception_slot
-- already ties them to recurrence_id, so recurrence_id IS NULL forces both of
-- them NULL too.
--
-- This is the ONLY CHECK constraint on the column, on purpose. A second one
-- validating the VALUE's shape was considered and rejected: BEFORE ROW triggers
-- run before CHECK constraints, so the trigger below would reach every bad
-- value first and the constraint would be dead code on the INSERT/UPDATE path.
-- Worse, on the paths where it did fire it would raise 23514 WITHOUT the DETAIL
-- token clients depend on, splitting one client-facing contract in two. All
-- value validation therefore lives in timezone_is_supported(). The drop below
-- is kept so re-running this migration cleans up any earlier draft.
-- ============================================================================
alter table public.events
  drop constraint if exists events_timezone_format;

alter table public.events
  drop constraint if exists events_timezone_placement;

alter table public.events
  add constraint events_timezone_placement check (
    timezone is null
    or (all_day = false and rrule is not null and recurrence_id is null)
  );

-- ============================================================================
-- 3a. timezone_is_supported: the single gate for the VALUE.
--
-- Length, lexical shape, forbidden names and catalog membership are all here,
-- so that every rejected value reaches the client through one code path with
-- one DETAIL token. The cheap tests are written first; the catalog lookup is
-- the only expensive one.
--
-- WHAT THIS GUARANTEES, precisely: the name exists in this server's tz database
-- right now, and is not one of the shapes we refuse. It does NOT guarantee the
-- name is the canonical IANA identifier -- pg_timezone_names carries links
-- (Asia/Calcutta) alongside primary names (Asia/Kolkata) with no column that
-- tells them apart. That is fine: a link resolves to the same transition rules,
-- so occurrences computed from either are identical, and nothing in TimeWeave
-- compares zone strings across rows.
--
-- It guarantees nothing about the FUTURE either: a tzdata update can retire a
-- name. 5b-3 must therefore call this again at read time and treat a
-- now-unusable zone as unsupported (complete=false), rather than letting
-- AT TIME ZONE raise inside get_free_busy and break the whole share page.
--
-- Why membership rather than "just try AT TIME ZONE": that operator also
-- accepts abbreviations (JST, EST -- fixed offset, no DST, and ambiguous across
-- regions) and raw POSIX specifications (<+09>-9). Either would silently
-- produce a series that never observes DST. Requiring a pg_timezone_names row
-- excludes them.
--
-- Refusals, and why each is a correctness matter rather than taste:
--   localtime  -- resolves to the SERVER's configured zone, so the meaning of
--                 the stored value would change if the server is reconfigured.
--   right/...  -- leap-second-aware counting; offsets disagree with the plain
--                 zone of the same name.
--   posix/...  -- identical in meaning to the unprefixed name; storing both
--                 spellings buys nothing and splits one zone into two.
--
-- UTC and Etc/GMT+-N are ALLOWED. They resolve, they are stable, and a series
-- deliberately anchored to a fixed offset is a legitimate thing to want. The
-- sign inversion of Etc/GMT-9 (which means UTC+9) is a hazard for a human
-- typing it, so a future time zone picker should leave those out of its list --
-- that is a UI policy, not a database invariant.
--
-- Comparison is case sensitive on purpose. AT TIME ZONE would resolve
-- 'asia/tokyo', but pg_timezone_names holds only 'Asia/Tokyo', so requiring an
-- exact row keeps spelling variants out of the table.
-- ============================================================================
create or replace function public.timezone_is_supported(p_tz text)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $fn$
  select p_tz is not null
     and length(p_tz) between 1 and 64
     and p_tz ~ '^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+){0,2}$'
     and p_tz <> 'localtime'
     and p_tz not like 'posix/%'
     and p_tz not like 'right/%'
     and exists (
           select 1
           from pg_catalog.pg_timezone_names z
           where z.name = p_tz
         );
$fn$;

-- ============================================================================
-- 3b. events_timezone_transition_error: the whole state machine, as a pure
--     function of its arguments.
--
-- Returns NULL when the transition is allowed, or a stable token naming the
-- reason when it is not. It touches no table and no catalog, so it is IMMUTABLE
-- and can be exercised exhaustively -- all twelve transitions -- with no
-- fixture, no lock and no privilege. The trigger below is then a thin wrapper,
-- which is the point: the rule lives in one directly testable place.
--
-- `is false` rather than `= false` throughout, so a NULL argument can never
-- make a branch accidentally true. events.all_day is NOT NULL, but this
-- function is also called directly by the test suite.
-- ============================================================================
create or replace function public.events_timezone_transition_error(
  p_is_insert    boolean,
  p_old_all_day  boolean,
  p_old_rrule    text,
  p_old_timezone text,
  p_new_all_day  boolean,
  p_new_rrule    text,
  p_new_timezone text
)
returns text
language sql
immutable
security invoker
set search_path = ''
as $fn$
  select case
    -- The resulting row is not a timed master: nothing to enforce here. The
    -- placement CHECK already forces its timezone to be NULL.
    when not (p_new_all_day is false and p_new_rrule is not null)
      then null

    -- A timed master that carries a zone. Its VALUE is checked separately.
    when p_new_timezone is not null
      then null

    -- From here down: a timed master with NO zone.
    when p_is_insert is true
      then 'TIMEWEAVE_TZ_REQUIRED'

    -- Grandfathered: it was already a zone-less timed master and still is.
    when p_old_all_day is false
     and p_old_rrule is not null
     and p_old_timezone is null
      then null

    -- It had a zone and this update would drop it.
    when p_old_all_day is false
     and p_old_rrule is not null
     and p_old_timezone is not null
      then 'TIMEWEAVE_TZ_CLEARED'

    -- Anything else becoming a zone-less timed master: a one-off promoted to a
    -- series, an all-day series turned timed, an exception rewritten into a
    -- master. All of these are NEW recurrences and must declare their zone.
    else 'TIMEWEAVE_TZ_REQUIRED'
  end;
$fn$;

-- ============================================================================
-- 3c. The trigger function.
--
-- ERROR CONTRACT -- the client depends on this, so treat it as an API:
--
--   SQLSTATE is 23514 (check_violation) for all three failures. They are domain
--   invariants of the same kind as the placement constraint, and one class lets
--   generic client-side error handling cover them all.
--
--   DETAIL carries a stable machine-readable token, and nothing else:
--     TIMEWEAVE_TZ_INVALID   the value is not a usable IANA zone name -- too
--                            long, wrong shape, forbidden, or absent from
--                            pg_timezone_names. All four arrive here.
--                            USER-ACTIONABLE: the browser knew a name this
--                            server does not. Say so and let them choose again.
--     TIMEWEAVE_TZ_REQUIRED  a new timed recurrence arrived without a zone.
--                            An application bug: every create/convert path is
--                            supposed to send one.
--     TIMEWEAVE_TZ_CLEARED   an existing zone was being removed.
--                            An application bug: no UI offers this.
--
--   MESSAGE is for humans and logs. Clients MUST NOT parse it -- its wording is
--   free to change. PostgREST surfaces DETAIL as `details`, which is what the
--   client branches on. CONSTRAINT is deliberately not used as the identifier:
--   PostgREST does not pass it through.
--
-- OLD is read only on the UPDATE path; PL/pgSQL raises if OLD is touched during
-- an INSERT, so the two calls are written out separately rather than folded
-- into one expression.
-- ============================================================================
create or replace function public.events_validate_timezone()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $fn$
declare
  v_err text;
begin
  -- (1) The value, whenever one is present.
  if new.timezone is not null
     and not public.timezone_is_supported(new.timezone) then
    raise exception
      'events.timezone "%" is not a usable IANA time zone name', new.timezone
      using errcode = '23514',
            detail  = 'TIMEWEAVE_TZ_INVALID',
            hint    = 'Use a name present in pg_timezone_names, at most 64 '
                      'characters, excluding localtime and the posix/ and '
                      'right/ prefixes.';
  end if;

  -- (2) The transition.
  if tg_op = 'INSERT' then
    v_err := public.events_timezone_transition_error(
               true,
               null, null, null,
               new.all_day, new.rrule, new.timezone);
  else
    v_err := public.events_timezone_transition_error(
               false,
               old.all_day, old.rrule, old.timezone,
               new.all_day, new.rrule, new.timezone);
  end if;

  if v_err = 'TIMEWEAVE_TZ_REQUIRED' then
    raise exception
      'a timed recurring event must carry an IANA time zone'
      using errcode = '23514',
            detail  = 'TIMEWEAVE_TZ_REQUIRED',
            hint    = 'Set events.timezone when creating a timed recurrence, or '
                      'when turning an existing row into one.';
  elsif v_err = 'TIMEWEAVE_TZ_CLEARED' then
    raise exception
      'the time zone of a timed recurring event cannot be cleared'
      using errcode = '23514',
            detail  = 'TIMEWEAVE_TZ_CLEARED',
            hint    = 'Drop the rrule in the same statement if the row should '
                      'stop being a recurrence.';
  end if;

  return new;
end;
$fn$;

-- ============================================================================
-- 3d. The trigger.
--
-- INSERT and UPDATE only. DELETE is deliberately absent: removing a row can
-- never create an invalid one, and the 5b-2 verification run relies on being
-- able to delete its legacy fixture afterwards without disabling anything.
--
-- Fires after events_set_updated_at (triggers of the same timing run in name
-- order, and s < v). The two are independent; the order is noted only so a
-- future reader does not have to work it out.
-- ============================================================================
drop trigger if exists events_validate_timezone on public.events;

create trigger events_validate_timezone
  before insert or update on public.events
  for each row
  execute function public.events_validate_timezone();

-- ============================================================================
-- 4. EXECUTE privileges.
--
-- This differs from 0006/0007 on purpose, so the reasoning is written down.
--
-- Those helpers are granted to nobody because their only caller, get_free_busy,
-- is SECURITY DEFINER and calls them as the function owner. The trigger
-- function here is SECURITY INVOKER, so its body runs as `authenticated` and
-- PostgreSQL checks EXECUTE on every function it calls, at call time. Without
-- the grants below, every INSERT and UPDATE from the application would fail
-- with "permission denied for function".
--
-- Granting is the smaller hammer. The alternative -- making the trigger
-- function SECURITY DEFINER -- would run per-row code as the table owner on
-- every write to events, and would quietly bypass RLS the day someone adds a
-- table read to it. These two functions expose nothing: pg_timezone_names is
-- world-readable already, and the transition function is arithmetic on its
-- arguments.
--
-- anon gets nothing: 0002 grants it no DML on events, so it can never fire the
-- trigger. If service_role is ever used to write events, it will need the same
-- two grants.
--
-- The trigger function itself needs no grant. EXECUTE on a trigger function is
-- checked when CREATE TRIGGER runs, not when the trigger fires.
-- ============================================================================
revoke execute on function public.timezone_is_supported(text) from public;
revoke execute on function public.events_timezone_transition_error(
  boolean, boolean, text, text, boolean, text, text
) from public;
revoke execute on function public.events_validate_timezone() from public;

grant execute on function public.timezone_is_supported(text) to authenticated;
grant execute on function public.events_timezone_transition_error(
  boolean, boolean, text, text, boolean, text, text
) to authenticated;
