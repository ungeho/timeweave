-- ============================================================================
-- TimeWeave Phase 5b-3 -- PREFLIGHT for 0009_timed_recurrence_freebusy.sql
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run BEFORE applying 0009, by hand,
-- against the project 0009 will be applied to. READ-ONLY: no DDL, no DML, no
-- SET. Wrapped in a transaction ending in ROLLBACK as a belt-and-braces
-- guarantee that nothing can persist.
--
-- WHY: 0009 converts wall-clock times through AT TIME ZONE, which makes
-- PostgreSQL resolution of nonexistent and ambiguous local times part of
-- TimeWeave semantics. Neither is guaranteed stable across a server or tzdata
-- upgrade, so Section B pins both to the instants measured on 2026-09-04. If a
-- future server disagrees this fails BEFORE 0009 is applied, instead of moving
-- every recurring occurrence by an hour in silence.
--
-- Section F checks the prerequisites of the 0009 TEST SUITE, which builds a
-- genuine M0 row (timed master, timezone IS NULL) by disabling the 0008 trigger
-- for the length of one INSERT inside its own transaction. No pre-existing M0
-- fixture is required or looked for; the 5b-2 one was deleted permanently.
--
-- Re-running this file AFTER 0009 is applied fails E.3 by design.
--
-- A failing assert aborts the transaction; later statements then report
-- "current transaction is aborted" until the ROLLBACK. Read the FIRST error.
-- RUN THE WHOLE FILE, INCLUDING THE FINAL ROLLBACK.
-- ============================================================================

begin;

-- ============================================================================
-- SECTION A -- environment, recorded so later output can be interpreted.
-- The session TimeZone is printed, never asserted: every expression in this
-- file and in 0009 names its zone explicitly, so none depends on the GUC. It
-- matters only because the editor renders timestamptz values in it.
-- ============================================================================
do $$
declare
  v_pgcrypto text;
begin
  raise notice 'Section A: environment';
  raise notice '  version          : %', version();
  raise notice '  session TimeZone : %', current_setting('TimeZone');
  raise notice '  tz names         : %', (select count(*) from pg_catalog.pg_timezone_names);

  select n.nspname
    into v_pgcrypto
  from pg_catalog.pg_extension e
  join pg_catalog.pg_namespace n on n.oid = e.extnamespace
  where e.extname = 'pgcrypto';

  raise notice '  pgcrypto schema  : %', coalesce(v_pgcrypto, 'not installed');

  assert v_pgcrypto = 'extensions',
    'A.1 pgcrypto is not in the extensions schema; 0005-0009 call extensions.digest()';
end
$$;

-- ============================================================================
-- SECTION B -- DST resolution, pinned to measured values (America/New_York).
-- These assertions ARE the 5b-3 specification:
--   gap  (local time that does not exist) -> standard-time offset, which moves
--        it FORWARD past the transition.
--   fold (local time that happens twice)  -> standard-time offset, i.e. the
--        LATER of the two instants.
-- Measured, not assumed. Only these concrete values are asserted; 0009 itself
-- delegates to AT TIME ZONE, so it stays correct for zones not listed here.
-- ============================================================================
do $$
begin
  raise notice 'Section B: DST resolution (America/New_York, 2026)';

  assert (timestamp '2026-03-08 02:30:00' at time zone 'America/New_York')
         = timestamptz '2026-03-08 07:30:00+00',
    'B.1 gap 2026-03-08 02:30 no longer resolves to 07:30Z -- STOP';

  assert ((timestamp '2026-03-08 02:30:00' at time zone 'America/New_York')
           at time zone 'America/New_York')
         = timestamp '2026-03-08 03:30:00',
    'B.2 the gap no longer shifts forward to 03:30 local -- STOP';

  assert (timestamp '2026-03-08 03:30:00' at time zone 'America/New_York')
         = timestamptz '2026-03-08 07:30:00+00',
    'B.3 normal 2026-03-08 03:30 no longer resolves to 07:30Z -- STOP';

  assert (timestamp '2026-11-01 01:30:00' at time zone 'America/New_York')
         = timestamptz '2026-11-01 06:30:00+00',
    'B.4 fold 2026-11-01 01:30 no longer resolves to the LATER instant 06:30Z -- STOP';

  assert ((timestamp '2026-11-01 01:30:00' at time zone 'America/New_York')
           at time zone 'America/New_York')
         = timestamp '2026-11-01 01:30:00',
    'B.5 the fold no longer round-trips to the same local time -- STOP';

  assert (timestamp '2026-11-01 02:30:00' at time zone 'America/New_York')
         = timestamptz '2026-11-01 07:30:00+00',
    'B.6 normal 2026-11-01 02:30 no longer resolves to 07:30Z -- STOP';

  raise notice '  gap  02:30 -> % UTC (local %)',
    (timestamp '2026-03-08 02:30:00' at time zone 'America/New_York') at time zone 'UTC',
    (timestamp '2026-03-08 02:30:00' at time zone 'America/New_York') at time zone 'America/New_York';
  raise notice '  fold 01:30 -> % UTC (local %)',
    (timestamp '2026-11-01 01:30:00' at time zone 'America/New_York') at time zone 'UTC',
    (timestamp '2026-11-01 01:30:00' at time zone 'America/New_York') at time zone 'America/New_York';
end
$$;

-- ============================================================================
-- SECTION C -- tzdata transition instants and the fixed-offset controls.
-- The 0009 suite hardcodes 2026-03-08 and 2026-11-01 as the US transition days
-- and uses Asia/Tokyo and Etc/GMT-9 as constant-offset controls. These prove
-- the server tzdata agrees, instead of the suite testing an ordinary day.
-- ============================================================================
do $$
begin
  raise notice 'Section C: tzdata transitions and fixed-offset controls';

  assert (timestamptz '2026-03-08 06:59:59+00' at time zone 'America/New_York')
         = timestamp '2026-03-08 01:59:59',
    'C.1 spring transition is not at 07:00Z as the 0009 suite assumes -- STOP';

  assert (timestamptz '2026-03-08 07:00:00+00' at time zone 'America/New_York')
         = timestamp '2026-03-08 03:00:00',
    'C.2 spring transition is not at 07:00Z as the 0009 suite assumes -- STOP';

  assert (timestamptz '2026-11-01 05:59:59+00' at time zone 'America/New_York')
         = timestamp '2026-11-01 01:59:59',
    'C.3 autumn transition is not at 06:00Z as the 0009 suite assumes -- STOP';

  assert (timestamptz '2026-11-01 06:00:00+00' at time zone 'America/New_York')
         = timestamp '2026-11-01 01:00:00',
    'C.4 autumn transition is not at 06:00Z as the 0009 suite assumes -- STOP';

  assert (timestamp '2026-03-08 09:00:00' at time zone 'Asia/Tokyo')
         = timestamptz '2026-03-08 00:00:00+00',
    'C.5 Asia/Tokyo is no longer a constant UTC+9 control (spring day) -- STOP';

  assert (timestamp '2026-11-01 09:00:00' at time zone 'Asia/Tokyo')
         = timestamptz '2026-11-01 00:00:00+00',
    'C.5 Asia/Tokyo is no longer a constant UTC+9 control (autumn day) -- STOP';

  assert (timestamp '2026-03-08 09:00:00' at time zone 'Etc/GMT-9')
         = timestamptz '2026-03-08 00:00:00+00',
    'C.6 Etc/GMT-9 is no longer a constant UTC+9 control (spring day) -- STOP';

  assert (timestamp '2026-11-01 09:00:00' at time zone 'Etc/GMT-9')
         = timestamptz '2026-11-01 00:00:00+00',
    'C.6 Etc/GMT-9 is no longer a constant UTC+9 control (autumn day) -- STOP';
end
$$;

-- ============================================================================
-- SECTION D -- timezone_is_supported (0008): the gate 0009 puts in front of
-- every AT TIME ZONE call. A zone that fails here must make the window
-- incomplete, never reach the operator, and never raise inside get_free_busy.
-- ============================================================================
do $$
begin
  raise notice 'Section D: timezone_is_supported';

  assert public.timezone_is_supported('America/New_York'),
    'D.1 America/New_York is not storable; the 0009 DST tests cannot run';

  assert public.timezone_is_supported('Asia/Tokyo'),
    'D.2 Asia/Tokyo is not storable';

  assert public.timezone_is_supported('Etc/GMT-9'),
    'D.3 Etc/GMT-9 is not storable';

  assert not public.timezone_is_supported('JST'),
    'D.4 an abbreviation is accepted; it carries no DST rules';

  assert not public.timezone_is_supported('posix/Asia/Tokyo'),
    'D.5 a posix/ spelling is accepted';

  assert not public.timezone_is_supported('Nowhere/Nothing'),
    'D.6 a nonexistent zone is accepted';

  assert not public.timezone_is_supported(null),
    'D.7 NULL is accepted';
end
$$;

-- ============================================================================
-- SECTION E -- the objects 0009 depends on, and the names it is about to take.
-- ============================================================================
do $$
declare
  v_count integer;
  v_oids  oid[];
  v_types text[];
  v_names text[];
  v_acl   text;
  v_name  text;
begin
  raise notice 'Section E: existing objects';

  select count(*)
    into v_count
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'get_free_busy';

  assert v_count = 1,
    format('E.1 expected exactly one public.get_free_busy, found %s', v_count);

  select p.proargtypes::oid[], p.proargnames, p.proacl::text
    into v_oids, v_names, v_acl
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'get_free_busy';

  -- Types come from the catalog, not from
  -- pg_get_function_identity_arguments(): that function renders argument NAMES
  -- alongside the types, so comparing it against a bare type list can never
  -- match. Types and names are checked separately instead, and both matter.
  select array(
           select pg_catalog.format_type(u.t, null)
           from unnest(v_oids) with ordinality as u(t, ord)
           order by u.ord
         )
    into v_types;

  assert v_types = array['text', 'timestamp with time zone',
                         'timestamp with time zone', 'date', 'date']::text[],
    format('E.2 get_free_busy argument types changed: %s',
           coalesce(array_to_string(v_types, ', '), 'null'));

  -- Argument NAMES matter as much as the types. 0009 replaces this function in
  -- place, which cannot rename an existing parameter, and PostgREST passes
  -- arguments by name. 0009 must declare exactly these five names.
  assert v_names = array['p_token', 'p_from', 'p_to',
                         'p_from_date', 'p_to_date']::text[],
    format('E.2 get_free_busy argument names changed: %s',
           coalesce(array_to_string(v_names, ', '), 'null'));

  -- RECORD THIS LINE. create or replace preserves privileges, so after
  -- applying 0009 this value must be identical.
  raise notice '  get_free_busy proacl (record and compare after applying): %',
    coalesce(v_acl, 'null (owner-only defaults)');

  foreach v_name in array array[
    'rrule_timed_expansion_cap',
    'rrule_timed_sql_subset',
    'rrule_timed_occurrence_count',
    'rrule_timed_occurrence_starts'
  ]
  loop
    assert not exists (
      select 1
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname = v_name
    ), format('E.3 public.%s already exists; is 0009 already applied?', v_name);
  end loop;

  foreach v_name in array array[
    'rrule_parse',
    'rrule_sql_subset',
    'rrule_definitely_ends_before',
    'rrule_allday_expansion_cap',
    'rrule_allday_occurrence_count',
    'rrule_allday_occurrence_starts',
    'timezone_is_supported'
  ]
  loop
    assert exists (
      select 1
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname = v_name
    ), format('E.4 public.%s is missing; apply 0006 to 0008 first', v_name);
  end loop;
end
$$;

-- ============================================================================
-- SECTION F -- prerequisites of the 0009 TEST SUITE.
--
-- That suite needs two fixtures the 0008 trigger refuses to let the application
-- create: a genuine M0 (timed master, timezone IS NULL) and a row whose zone
-- this server cannot resolve. It builds them by disabling
-- events_validate_timezone for the length of one INSERT, inside its own
-- transaction, re-enabling immediately, and ending in ROLLBACK.
--
-- No pre-existing M0 fixture is required. F.2 requires the OPPOSITE: the test
-- owner must hold zero events, which is also what the 0006 and 0007 suites
-- require, and which confirms the 5b-2 fixture stayed deleted.
--
-- EDIT v_owner if this project uses a different development test user.
-- ============================================================================
do $$
declare
  v_owner    constant uuid := '5e86935f-7661-4741-868f-0f51c4cf1727';
  v_events   integer;
  v_enabled  "char";
  v_tblowner name;
  v_super    boolean;
  v_notnull  boolean;
  v_def      text;
begin
  raise notice 'Section F: prerequisites of the 0009 test suite';

  assert exists (select 1 from auth.users u where u.id = v_owner),
    'F.1 the dedicated test user does not exist; edit v_owner here and in the suite';

  select count(*)
    into v_events
  from public.events e
  where e.owner_id = v_owner;

  assert v_events = 0,
    format('F.2 the test owner holds %s events; the 0009 suite requires zero. '
           'Do not recreate the 5b-2 legacy M0 fixture', v_events);

  select t.tgenabled
    into v_enabled
  from pg_catalog.pg_trigger t
  where t.tgrelid = 'public.events'::regclass
    and t.tgname = 'events_validate_timezone'
    and not t.tgisinternal;

  assert v_enabled is not null,
    'F.3 trigger events_validate_timezone is missing; apply 0008 first';

  assert v_enabled = 'O',
    format('F.3 trigger events_validate_timezone is not enabled (tgenabled=%s). '
           'A previous run may have left it disabled; fix that first', v_enabled);

  select r.rolname
    into v_tblowner
  from pg_catalog.pg_class c
  join pg_catalog.pg_roles r on r.oid = c.relowner
  where c.oid = 'public.events'::regclass;

  select r.rolsuper
    into v_super
  from pg_catalog.pg_roles r
  where r.rolname = current_user;

  raise notice '  current_user = %, public.events owner = %, superuser = %',
    current_user, v_tblowner, coalesce(v_super, false);

  -- ALTER TABLE ... DISABLE TRIGGER requires table ownership or superuser.
  -- Required literally: current_user must BE the owner, or be a superuser.
  assert current_user = v_tblowner or coalesce(v_super, false),
    format('F.4 role %s is neither the owner of public.events (%s) nor a superuser, '
           'so it cannot disable and re-enable the trigger. Run the 0009 suite '
           'as the table owner', current_user, v_tblowner);

  select a.attnotnull
    into v_notnull
  from pg_catalog.pg_attribute a
  where a.attrelid = 'public.events'::regclass
    and a.attname = 'timezone'
    and not a.attisdropped;

  assert v_notnull is not null,
    'F.5 column public.events.timezone is missing; apply 0008 first';

  assert v_notnull = false,
    'F.5 public.events.timezone is NOT NULL; a genuine M0 row can no longer be '
    'built and the 0009 M0 test must be redesigned';

  select pg_catalog.pg_get_constraintdef(c.oid)
    into v_def
  from pg_catalog.pg_constraint c
  where c.conrelid = 'public.events'::regclass
    and c.conname = 'events_timezone_placement';

  assert v_def is not null,
    'F.6 constraint events_timezone_placement is missing; apply 0008 first';

  raise notice '  events_timezone_placement: %', v_def;

  assert v_def ilike '%timezone is null%',
    'F.6 events_timezone_placement no longer admits timezone IS NULL; the M0 '
    'fixture cannot be built by disabling the trigger alone';
end
$$;

-- ============================================================================
-- SECTION G -- OBSERVATION ONLY. No assertions: this section records values for
-- the 5b-4 differential work and does not gate the migration. A SQL error here
-- is still a preflight failure, as everywhere else.
--
-- Both measured data points are northern-hemisphere. A southern-hemisphere fold
-- separates "PostgreSQL prefers standard time" from "PostgreSQL uses the
-- pre-transition offset", because there standard time comes AFTER the
-- transition. TimeWeave semantics do not depend on which is right: 0009
-- delegates to AT TIME ZONE either way.
-- ============================================================================
do $$
begin
  raise notice 'Section G: southern-hemisphere observation (no assertions)';
  raise notice '  AEST = UTC+10 (standard), AEDT = UTC+11 (summer)';
  raise notice '  Sydney 2026-04-05 02:30 -> % UTC (local %)',
    (timestamp '2026-04-05 02:30:00' at time zone 'Australia/Sydney') at time zone 'UTC',
    (timestamp '2026-04-05 02:30:00' at time zone 'Australia/Sydney') at time zone 'Australia/Sydney';
  raise notice '  Sydney 2026-10-04 02:30 -> % UTC (local %)',
    (timestamp '2026-10-04 02:30:00' at time zone 'Australia/Sydney') at time zone 'UTC',
    (timestamp '2026-10-04 02:30:00' at time zone 'Australia/Sydney') at time zone 'Australia/Sydney';
end
$$;

do $$
begin
  raise notice 'PREFLIGHT PASSED -- 0009 may be applied';
end
$$;

rollback;
