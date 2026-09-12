-- ENVIRONMENT PROBE: does a SECURITY DEFINER function with `set search_path = ''`
-- still see its transition tables (new_rows / old_rows)?
--
-- KEPT DELIBERATELY. This is not tied to 0011: it answers a question about the
-- SERVER, and the answer can change under a major-version upgrade. Re-run it
-- before adding any new statement-level trigger that reads a transition table
-- -- the planned rate-limit work is the next such case. Measured PASS on
-- production 2026-09-12 (all 11 checks ok, leftover objects = 0).
--
-- It runs safely on production: see the safety banner below.
--
-- ############################################################################
-- THIS PROBE LEAVES NOTHING BEHIND, ON EITHER PATH.
--   success -> the DO block drops everything it created, in reverse order
--   failure -> the DO block raises, its implicit transaction aborts, and every
--              CREATE inside it is rolled back (DDL is transactional in
--              PostgreSQL, which is the whole reason this shape works)
-- Section 3 then PROVES it rather than asserting it: it counts catalog entries
-- named zz_probe_% and must report 0.
-- ############################################################################
--
-- ============================================================================
-- THE QUESTION, AND WHY IT IS NOT OBVIOUS
--
-- 0011 enforces both quotas from AFTER STATEMENT triggers whose functions are
-- SECURITY DEFINER with `set search_path = ''`. Those two settings are chosen
-- for good reasons (a quota must count past RLS; a SECURITY DEFINER function
-- must pin its search path), but neither is used anywhere else in this project
-- together with a transition table.
--
-- A transition table is not a schema object. It is an Ephemeral Named Relation
-- registered in the query environment, and the parser is expected to match it
-- BEFORE it ever consults the search path. If that expectation is right,
-- `search_path = ''` is irrelevant to it. If it is wrong, every quota trigger
-- fails at runtime with `relation "new_rows" does not exist` -- on the first
-- INSERT a real user makes, in production, after the migration has committed.
--
-- That is a cheap thing to measure and an expensive thing to assume, so it is
-- measured. This file exists because the alternative was a paragraph beginning
-- "should be fine".
--
-- ============================================================================
-- WHAT IS ASSERTED, AND WHY EACH ONE EARNS ITS PLACE
--
--   10  AFTER INSERT, NEW TABLE is readable from inside the function.
--       The headline question, on the INSERT path.
--   11  the base-table count taken inside AFTER STATEMENT ALREADY INCLUDES the
--       rows this statement wrote. Re-measured HERE rather than trusted from
--       the earlier probe, because that one used a plain SECURITY INVOKER
--       function -- this checks the fact survives the change of shape.
--   12  pg_advisory_xact_lock and hashtext are callable under search_path = ''
--       when schema-qualified as pg_catalog. If they are not, 0011's whole
--       concurrency argument is unreachable code.
--   20  a NON-OWNER role (authenticated) can fire the trigger with NO EXECUTE
--       grant on the trigger function. 0011 section 5 states this as fact --
--       "EXECUTE is checked when CREATE TRIGGER runs, not when it fires" -- and
--       grants nothing. If that is wrong, every write from the app breaks.
--   21  NEW TABLE is readable when the statement is run by that non-owner.
--       Assertion 10 proves it for the table owner only, and the table owner is
--       exempt from a great deal.
--   22  the function counts ALL rows, not the RLS-visible slice. This is the
--       entire justification for SECURITY DEFINER in 0011 -- the section that
--       deliberately contradicts 0008 -- so it is measured, not argued.
--   23  RLS is genuinely active on the probe table for that role. Without this,
--       assertion 22 proves nothing: an unfiltered count over an unfiltered
--       table is not evidence of a bypass.
--   30  AFTER UPDATE, NEW TABLE readable.
--   31  AFTER UPDATE, OLD TABLE readable. 0011's delta rule needs BOTH, and
--       only the UPDATE triggers declare OLD TABLE, so this is a distinct
--       registration shape from 10/21 and not implied by them.
--   90  no leftover catalog entries. Requirement stated by the operator.
--
-- ============================================================================
-- WHY THE RESULTS SURVIVE A ROLLBACK
--
-- The probe's own log cannot live in a table the probe creates: on the failure
-- path that table is rolled back and takes the evidence with it.
--
-- The trigger function therefore parks each observation in a custom GUC
-- (`zz_probe.*`) via set_config(..., is_local => false). A GUC is session
-- state, not table state: it crosses the function boundary without a table, is
-- unaffected by search_path, and disappears when the connection closes. The DO
-- block reads them back after each statement and writes them into a TEMP table
-- created BEFORE the probe -- which is why section 0 is a separate statement.
--
-- Section 4 blanks the GUCs afterwards, so a second run cannot read a stale
-- value from the first and report a false PASS.
--
-- ============================================================================
-- HOW TO READ IT
--
--   An ERROR anywhere  -> FAIL. The message names the assertion. Nothing was
--                         left behind; paste the error.
--   A grid, all 'ok'   -> PASS. 0011 keeps `set search_path = ''` as written.
--   Grid with MISMATCH -> FAIL on that row specifically.
--
-- If assertion 10 or 21 is the one that fails, the fix in 0011 is one line per
-- function: `set search_path = pg_catalog` instead of `set search_path = ''`.
-- Nothing else in the migration depends on it.
-- ============================================================================


-- ============================================================================
-- Section 0. The log. Created OUTSIDE the probe so it survives a rollback.
-- TEMP: session-scoped, never persistent, gone when the connection closes.
-- ============================================================================
drop table if exists zz_probe_log;

create temp table zz_probe_log (
  ord        int,
  check_name text,
  expected   text,
  value      text
);


-- ============================================================================
-- Section 1. The probe. One DO block, so that a failure anywhere rolls back
-- every object it created without needing a cleanup handler.
-- ============================================================================
do $probe$
declare
  v_seen    text;
  v_invoker text;
begin
  -- --------------------------------------------------------------------
  -- Build a miniature of public.events: RLS on, owner-scoped policy,
  -- granted to authenticated. The shape is what matters, not the columns.
  -- --------------------------------------------------------------------
  create table public.zz_probe_events (
    id        uuid primary key default gen_random_uuid(),
    owner_tag text not null,
    note      text
  );

  alter table public.zz_probe_events enable row level security;

  create policy zz_probe_sel on public.zz_probe_events
    for select using (owner_tag = 'mine');
  create policy zz_probe_ins on public.zz_probe_events
    for insert with check (true);
  create policy zz_probe_upd on public.zz_probe_events
    for update using (owner_tag = 'mine') with check (true);

  -- Granted on the PROBE TABLE only, so it is dropped with the table and
  -- cannot outlive this block. No schema-level grant is issued: 0002 already
  -- gave authenticated USAGE on public, and re-granting it would be a catalog
  -- write that does NOT get dropped with the table.
  grant select, insert, update on table public.zz_probe_events to authenticated;

  -- --------------------------------------------------------------------
  -- The function under test. Exactly the two settings 0011 uses.
  -- Every observation goes into a GUC; nothing is returned.
  -- --------------------------------------------------------------------
  create function public.zz_probe_trg()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
  as $enr$
  declare
    v_new  bigint := 0;
    v_old  bigint := 0;
    v_base bigint := 0;
    v_tag  text   := lower(tg_op);
  begin
    -- THE HEADLINE READ. Unqualified ENR name, search_path = ''.
    select count(*) into v_new from new_rows;

    if tg_op = 'UPDATE' then
      select count(*) into v_old from old_rows;
    end if;

    -- Schema-qualified base table read, as 0011 does it.
    select count(*) into v_base from public.zz_probe_events;

    -- The concurrency primitives, schema-qualified for search_path = ''.
    perform pg_catalog.pg_advisory_xact_lock(
      811999, pg_catalog.hashtext('zz_probe')
    );

    perform pg_catalog.set_config('zz_probe.' || v_tag || '_new',  v_new::text,  false);
    perform pg_catalog.set_config('zz_probe.' || v_tag || '_old',  v_old::text,  false);
    perform pg_catalog.set_config('zz_probe.' || v_tag || '_base', v_base::text, false);
    perform pg_catalog.set_config('zz_probe.' || v_tag || '_lock', 'taken',      false);
    perform pg_catalog.set_config('zz_probe.' || v_tag || '_user', current_user, false);

    return null;
  end;
  $enr$;

  -- Two registrations, because PostgreSQL forbids transition tables on a
  -- trigger defined for more than one event. This is the same split 0011 makes.
  create trigger zz_probe_ai
    after insert on public.zz_probe_events
    referencing new table as new_rows
    for each statement execute function public.zz_probe_trg();

  create trigger zz_probe_au
    after update on public.zz_probe_events
    referencing old table as old_rows new table as new_rows
    for each statement execute function public.zz_probe_trg();

  -- ====================================================================
  -- PHASE A -- as the table owner. 2 rows in one statement.
  -- ====================================================================
  insert into public.zz_probe_events (owner_tag, note)
  values ('theirs', 'a'), ('theirs', 'b');

  insert into zz_probe_log values
    (10, 'AFTER INSERT: rows visible in NEW TABLE',
         '2', current_setting('zz_probe.insert_new', true)),
    (11, 'AFTER INSERT: base count already includes this statement',
         '2', current_setting('zz_probe.insert_base', true)),
    (12, 'pg_advisory_xact_lock + hashtext callable under empty search_path',
         'taken', current_setting('zz_probe.insert_lock', true));

  if current_setting('zz_probe.insert_new', true) is distinct from '2' then
    raise exception
      'PROBE 10 FAILED: NEW TABLE unreadable or wrong size (got %)',
      coalesce(current_setting('zz_probe.insert_new', true), '<null>')
      using hint = 'A SECURITY DEFINER function with search_path = '''' cannot '
                   'see its transition table. Change 0011 to '
                   'set search_path = pg_catalog.';
  end if;

  if current_setting('zz_probe.insert_base', true) is distinct from '2' then
    raise exception
      'PROBE 11 FAILED: base count inside AFTER STATEMENT is %, expected 2',
      coalesce(current_setting('zz_probe.insert_base', true), '<null>')
      using hint = 'The measured rule -- the count already includes this '
                   'statement -- does not hold in this shape. 0011 would '
                   'either double-count or under-count.';
  end if;

  if current_setting('zz_probe.insert_lock', true) is distinct from 'taken' then
    raise exception 'PROBE 12 FAILED: advisory lock / hashtext not reached';
  end if;

  -- ====================================================================
  -- PHASE B -- as authenticated. Non-owner, RLS applies to IT, and it holds
  -- no EXECUTE grant on zz_probe_trg().
  -- ====================================================================
  execute 'set local role authenticated';

  -- Captured OUTSIDE the function. Inside a SECURITY DEFINER function
  -- current_user is the function OWNER, so the invoker's identity is not
  -- observable from in there -- which is exactly the elevation being tested.
  v_invoker := current_user;

  insert into public.zz_probe_events (owner_tag, note)
  values ('mine','c'),('mine','d'),('mine','e'),('mine','f'),('mine','g');

  -- What THIS role can see, for assertion 23.
  select count(*)::text into v_seen from public.zz_probe_events;

  execute 'reset role';

  insert into zz_probe_log values
    (20, 'the statement really was run by a non-owner role',
         'authenticated', v_invoker),
    (24, 'SECURITY DEFINER elevated: body ran as someone other than the invoker',
         'elevated',
         case when current_setting('zz_probe.insert_user', true)
                   is distinct from v_invoker
              then 'elevated' else 'NOT elevated' end),
    (21, 'AFTER INSERT as non-owner: rows visible in NEW TABLE',
         '5', current_setting('zz_probe.insert_new', true)),
    (22, 'SECURITY DEFINER counts ALL rows, not the RLS slice',
         '7', current_setting('zz_probe.insert_base', true)),
    (23, 'RLS really is filtering that role (else 22 proves nothing)',
         '5', v_seen);

  if v_invoker is distinct from 'authenticated' then
    raise exception
      'PROBE 20 FAILED: SET LOCAL ROLE did not take; statement ran as %', v_invoker
      using hint = 'Everything after this point would be measuring the table '
                   'owner, which is exempt from RLS and proves nothing.';
  end if;

  if current_setting('zz_probe.insert_user', true) is not distinct from v_invoker then
    raise exception
      'PROBE 24 FAILED: trigger body also ran as %, so SECURITY DEFINER did '
      'not elevate.', v_invoker;
  end if;

  if current_setting('zz_probe.insert_new', true) is distinct from '5' then
    raise exception
      'PROBE 21 FAILED: NEW TABLE unreadable for a non-owner (got %)',
      coalesce(current_setting('zz_probe.insert_new', true), '<null>');
  end if;

  if current_setting('zz_probe.insert_base', true) is distinct from '7' then
    raise exception
      'PROBE 22 FAILED: base count is %, expected 7 (2 theirs + 5 mine). '
      'SECURITY DEFINER is NOT bypassing RLS here, so 0011''s quota would be '
      'computed from a visibility rule.',
      coalesce(current_setting('zz_probe.insert_base', true), '<null>');
  end if;

  if v_seen is distinct from '5' then
    raise exception
      'PROBE 23 FAILED: authenticated saw % rows, expected 5. RLS is not '
      'filtering, so assertion 22 is not evidence of anything.', v_seen;
  end if;

  -- ====================================================================
  -- PHASE C -- UPDATE, the only shape that declares OLD TABLE.
  -- ====================================================================
  update public.zz_probe_events set note = note || '!' where owner_tag = 'mine';

  insert into zz_probe_log values
    (30, 'AFTER UPDATE: rows visible in NEW TABLE',
         '5', current_setting('zz_probe.update_new', true)),
    (31, 'AFTER UPDATE: rows visible in OLD TABLE',
         '5', current_setting('zz_probe.update_old', true));

  if current_setting('zz_probe.update_new', true) is distinct from '5' then
    raise exception 'PROBE 30 FAILED: UPDATE NEW TABLE unreadable (got %)',
      coalesce(current_setting('zz_probe.update_new', true), '<null>');
  end if;

  if current_setting('zz_probe.update_old', true) is distinct from '5' then
    raise exception
      'PROBE 31 FAILED: UPDATE OLD TABLE unreadable (got %). 0011''s delta '
      'rule needs both transition tables.',
      coalesce(current_setting('zz_probe.update_old', true), '<null>');
  end if;

  -- --------------------------------------------------------------------
  -- Teardown, in reverse order of creation. Reached only when every
  -- assertion above passed; a failure gets the same result by rollback.
  -- --------------------------------------------------------------------
  drop trigger zz_probe_au on public.zz_probe_events;
  drop trigger zz_probe_ai on public.zz_probe_events;
  drop function public.zz_probe_trg();
  drop table public.zz_probe_events;   -- takes its policies and grants with it
end;
$probe$;


-- ============================================================================
-- Section 2. Blank the GUCs, so a later run cannot read this run's values and
-- report a PASS it did not earn.
-- ============================================================================
select pg_catalog.set_config(n, '', false)
from (values
  ('zz_probe.insert_new'), ('zz_probe.insert_old'), ('zz_probe.insert_base'),
  ('zz_probe.insert_lock'), ('zz_probe.insert_user'),
  ('zz_probe.update_new'), ('zz_probe.update_old'), ('zz_probe.update_base'),
  ('zz_probe.update_lock'), ('zz_probe.update_user')
) as g(n);


-- ============================================================================
-- Section 3. Prove the probe left nothing behind, rather than claiming it.
-- Counts tables, functions and triggers named zz_probe_% anywhere in public.
-- ============================================================================
insert into zz_probe_log
select 90, 'leftover zz_probe_% objects in the catalog (must be 0)', '0',
       count(*)::text
from (
  select 1
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname like 'zz\_probe\_%'
  union all
  select 1
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname like 'zz\_probe\_%'
  union all
  select 1
  from pg_catalog.pg_trigger t
  where t.tgname like 'zz\_probe\_%' and not t.tgisinternal
) x;


-- ============================================================================
-- Section 4. The verdict. All 'ok' means 0011 keeps set search_path = ''.
-- ============================================================================
select ord,
       check_name,
       expected,
       coalesce(value, '<null>') as value,
       case when value is not distinct from expected then 'ok' else 'MISMATCH' end
         as status
from zz_probe_log
order by ord;
