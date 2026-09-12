-- TimeWeave Phase 6-x: hard limits on event CONTENT and on event COUNT.
--
-- Two unrelated failure modes are closed here, in one migration because they
-- share a table lock and a validation pass:
--
--   CONTENT  three CHECK constraints bounding title / category / description.
--            The numbers mirror src/services/contentLimits.ts, which is the
--            TypeScript side's single definition.
--
--   COUNT    two quotas -- events per owner, and exception rows per recurrence
--            master -- enforced by AFTER STATEMENT triggers that are hard
--            limits under concurrency, not advisory ones.
--
-- Plus the structural fix that makes the second quota countable at all: a
-- composite foreign key that forbids an exception from belonging to a different
-- owner than its master.
--
-- ============================================================================
-- WHY NOW, AND WHAT WAS DONE FIRST
--
-- A single account had accumulated 1103 rows of generated filler -- 1000 of
-- repeat(char, 10000) and 100 of repeat(char, 1000) -- 68.9 MB of logical
-- content. Every one of them was over at least one of the limits below.
--
-- Those rows were surveyed (0011_content_limits_survey.sql), rehearsed against,
-- archived into public.events_archive_20260912 and deleted, in a transaction
-- that asserted its own outcome 25 times. AFTER that cleanup the table held 16
-- rows and ZERO over-limit rows, confirmed by re-running
-- 0011_content_limits_preflight.sql:
--
--   title       max   9 / limit  200 / rows      16 / over_limit 0
--   category    max   3 / limit   50 / non_null 10 / over_limit 0
--   description max   3 / limit 2000 / non_null  5 / over_limit 0
--
-- THAT IS WHY THE CHECKS BELOW ARE ADDED VALIDATED RATHER THAN `NOT VALID`.
-- There is nothing to grandfather. A validated constraint is the stronger
-- object: `NOT VALID` still enforces on INSERT and UPDATE, so it would not have
-- spared the legacy rows anyway (see the tombstone note below), and it would
-- have left the table permanently unable to answer "does every row satisfy
-- this?" without a later VALIDATE pass.
--
-- WHY THE LEGACY ROWS COULD NOT SIMPLY BE LEFT ALONE:
--   src/services/exceptionEdit.ts copies master.title / .description /
--   .category into the tombstone row it inserts for "delete this occurrence".
--   It does not validate them. A CHECK is enforced on INSERT even when it is
--   NOT VALID, so an over-limit master would have made that one UI action fail
--   with 23514 forever. Removing the rows was the only fix that did not mean
--   weakening the constraint.
--
-- ============================================================================
-- THE PRODUCTION-MEASURED FACTS THIS FILE IS BUILT ON
--
-- These were measured on the production database with throwaway probes, not
-- assumed from documentation. They are the reason the quota is shaped the way
-- it is, so they are written down here rather than left in a session log.
--
--   (1) A PostgREST JSON-array INSERT is ONE multi-row INSERT statement
--       (INSERT ... SELECT ... FROM json_populate_recordset(...)). A statement
--       trigger therefore fires exactly ONCE for a 1000-row bot payload.
--
--   (2) Inside an AFTER STATEMENT trigger, a plain count(*) on the base table
--       ALREADY INCLUDES the rows this statement just wrote. Measured: a 5-row
--       INSERT into an empty table reports 5, not 0.
--       => The check below counts the base table ONCE and compares. Adding
--          "existing + incoming" would DOUBLE-COUNT. This is the single
--          easiest mistake to make here and the probe exists because of it.
--
--   (3) A BEFORE ROW trigger declared VOLATILE does see the earlier rows of its
--       own statement (measured 0,1,2,3,4); declared STABLE it does not
--       (measured 0,0,0,0,0), because SPI runs read-only and the command
--       counter never advances.
--       => BEFORE ROW would also be CORRECT. It is rejected for COST: it is
--          O(existing rows) per row, so a 1000-row payload against a 20,000-row
--          owner is ~20 million row accesses. AFTER STATEMENT is O(1) counts
--          per affected owner. Correctness is not the reason; arithmetic is.
--
--   (4) READ COMMITTED is what PostgREST uses. Every statement takes a fresh
--       snapshot. That is what makes the advisory-lock design below a hard
--       limit rather than a hopeful one -- see CONCURRENCY.
--
-- ============================================================================
-- CONCURRENCY: WHY THE ADVISORY LOCK IS LOAD-BEARING
--
-- Without a lock, "count then decide" is a textbook race. Two sessions each
-- holding one row short of the quota both count LIMIT-1, both conclude there is
-- room, and both commit: the quota is exceeded by one per concurrent writer.
-- Neither transaction did anything wrong; the check was simply not serialised.
--
-- pg_advisory_xact_lock, taken on a key derived from the owner id BEFORE the
-- count, serialises exactly the sessions that could collide and nobody else:
--
--   * it is TRANSACTION-scoped, so it is released by COMMIT or ROLLBACK with no
--     unlock call and no leak on an aborted statement;
--   * the second session BLOCKS until the first commits, and then -- under READ
--     COMMITTED -- its count statement takes a NEW snapshot and sees the rows
--     the first session committed. That is the whole argument. The limit is
--     hard because the waiter's count is fresh, not because the lock is magic;
--   * the key is per-owner, so two different users never wait on each other.
--     Contention is confined to concurrent writes by ONE account -- which is
--     precisely the bot case, and precisely where serialising is wanted.
--
-- ISOLATION LEVELS, STATED PLAINLY:
--   READ COMMITTED  hard limit. The waiter re-snapshots after the lock.
--   SERIALIZABLE    safe by a different mechanism -- SSI tracks the predicate
--                   read of the count and aborts one transaction with 40001.
--   REPEATABLE READ NOT a hard limit. The transaction snapshot is frozen at
--                   start, so after waiting for the lock the count is still
--                   stale and the quota can be overshot. Nothing in TimeWeave
--                   uses REPEATABLE READ; this is recorded so that a future
--                   batch job does not adopt it silently.
--
-- DEADLOCK: a statement touching several owners takes several locks. Locks are
-- always taken in ASCENDING KEY ORDER (the array is sorted before the loop), so
-- two statements touching the same set of owners acquire them in the same
-- order. Between the two quota triggers the order is fixed by trigger name --
-- triggers of equal timing fire alphabetically, so events_quota_exception_*
-- always precedes events_quota_owner_*, in every statement, in every session.
--
-- ============================================================================
-- WHY THE CHECK IS ON A DELTA, NOT ON "IS THIS OWNER OVER THE LIMIT"
--
-- The UPDATE triggers compare the old and new transition tables and check ONLY
-- the owners (or masters) whose row count this statement INCREASED.
--
-- That is not an optimisation. It is the same lesson the tombstone bug taught:
-- a limit that is re-evaluated on every write FREEZES anything already past it.
-- If an account ever sits above quota -- a limit lowered later, a restore from
-- the archive, a support action -- a whole-owner check would refuse its edits
-- AND its attempts to tidy up, while still permitting nothing useful. The delta
-- rule refuses only what makes the situation worse, so an over-quota owner can
-- always edit and always delete their way back under.
--
-- DELETE fires nothing here, for the same reason 0008's trigger skips it:
-- removing a row cannot push a count over a maximum.
--
-- ============================================================================
-- WHY THESE TWO FUNCTIONS ARE SECURITY DEFINER (0008 ARGUED THE OPPOSITE)
--
-- 0008 made events_validate_timezone SECURITY INVOKER and granted EXECUTE on
-- its helpers, reasoning that SECURITY DEFINER "would quietly bypass RLS the
-- day someone adds a table read to it". That reasoning is right for a validator
-- whose body is arithmetic on its arguments.
--
-- It inverts here, because the table read IS the function, and bypassing RLS is
-- the REQUIREMENT rather than the hazard:
--
--   * a quota must count every row an owner has, not the rows the calling role
--     happens to be allowed to see. Under SECURITY INVOKER the count is
--     RLS-filtered. Today that filter returns the identical number, because
--     events_select_own is exactly `owner_id = auth.uid()`. Tomorrow it is one
--     shared-calendar policy away from returning something else -- and a quota
--     silently computed from a visibility rule is a quota that can be widened
--     by a feature that has nothing to do with quotas;
--   * the functions read counts and raise. They RETURN NULL and emit no row
--     data, so the elevated privilege cannot leak content. The only fact they
--     disclose is the caller's own row count, in an error they caused;
--   * `set search_path = ''` is mandatory for a SECURITY DEFINER function and
--     is set on both. Every reference is schema-qualified.
--
-- Because the bodies run as the function owner, the helper functions need no
-- GRANT for the trigger path -- unlike 0008, whose invoker-run body forced
-- EXECUTE grants on its two helpers.
--
-- ============================================================================
-- WHAT THIS FILE DOES NOT DO
--
--   * NO RATE LIMIT. The quota bounds the STOCK of rows, not the FLOW. An
--     account may reach its ceiling as fast as it likes; it simply cannot pass
--     it. Requests per minute belong at the edge, not in a trigger.
--   * NO UI FIX. 5000 events is a sane storage ceiling and a hopeless month
--     grid -- the "+989 more" overflow makes a dense month unreadable long
--     before any quota is approached. That is a rendering problem with a
--     rendering fix and it is tracked separately; nothing here addresses it.
--   * NO CHANGE to get_free_busy, rrule_parse, the 0006-0010 expansion chain,
--     events_validate_timezone, set_updated_at, RLS policies, or any GRANT on
--     public.events.
--   * NO TOUCH of public.events_archive_20260912. It is retained deliberately.
--     Note that its 1103 rows are all over-limit: once section 1 is applied,
--     `insert into events select * from archive` can no longer succeed. The
--     archive stops being an undo at that moment and becomes evidence.
-- ============================================================================

begin;

-- ============================================================================
-- 1. CONTENT LENGTH.
--
-- char_length counts Unicode CODE POINTS. contentLimits.ts counts UTF-16 CODE
-- UNITS (String.length, which is also what the HTML maxlength attribute
-- enforces). A non-BMP character -- most emoji, some kanji -- is two units but
-- one code point, so char_length <= String.length ALWAYS.
--
-- That asymmetry runs in the safe direction and is why all three layers can use
-- the same numbers: the browser is strictest, the database loosest, and a value
-- the dialog accepted can never be refused here. The reverse -- a value SQL
-- accepts that the dialog would not -- is possible and harmless.
--
-- NULL: `char_length(null) <= 50` evaluates to NULL, and a CHECK is satisfied
-- by NULL. description and category are nullable and stay that way; only their
-- non-null values are bounded. title is NOT NULL with DEFAULT '' and is bounded
-- above only -- emptiness is the dialog's rule, deliberately not the schema's.
-- ============================================================================
alter table public.events
  add constraint events_title_len
    check (char_length(title) <= 200),
  add constraint events_category_len
    check (char_length(category) <= 50),
  add constraint events_description_len
    check (char_length(description) <= 2000);


-- ============================================================================
-- 2. THE COMPOSITE FOREIGN KEY.
--
-- 0001 declared `recurrence_id uuid references public.events (id)`, which
-- guarantees an exception points at a REAL row and says nothing about WHOSE.
-- Two separate things needed that gap closed:
--
--   correctness  nothing but application habit stopped an exception from
--                naming another account's master. RLS does not help: the
--                INSERT policy checks the NEW row's owner_id, never the
--                master's.
--   countability the per-master quota in section 4 counts with the owner's RLS
--                out of the way, and the "exceptions of master M" set is only
--                well defined if every one of them shares M's owner.
--
-- (id, owner_id) is trivially unique because id alone is the primary key. The
-- UNIQUE constraint exists solely to give the composite FK a target to
-- reference; PostgreSQL requires one and will not infer it from the PK.
--
-- MATCH SIMPLE (the default) is what makes this safe for ordinary rows: when
-- ANY column of the referencing key is NULL the constraint is not checked at
-- all. recurrence_id is NULL on one-off events and on masters, so they are
-- unaffected. owner_id is NOT NULL, so for an exception row both columns are
-- present and the pair is always checked.
--
-- ON DELETE CASCADE is carried over unchanged -- deleting a master still
-- deletes its exceptions, which the cleanup's check 21 relied on.
--
-- ON UPDATE is deliberately left at NO ACTION. Changing a master's owner_id
-- while it has exceptions will now raise, instead of silently splitting a
-- series across two accounts. There is no UI path that does this.
--
-- The old single-column FK is dropped because the composite one implies it: a
-- row satisfying (recurrence_id, owner_id) -> (id, owner_id) necessarily has a
-- valid recurrence_id. Keeping both would mean two constraint checks and two
-- cascade traversals per delete for one guarantee.
--
-- It is dropped BY CATALOG LOOKUP rather than by name. 0001 declared it inline
-- and unnamed, so its name is whatever PostgreSQL generated -- almost certainly
-- events_recurrence_id_fkey, but "almost certainly" is not a thing to write
-- into a migration that runs once against production.
-- ============================================================================
alter table public.events
  add constraint events_id_owner_key unique (id, owner_id);

do $fk$
declare
  v_attnum smallint;
  v_name   text;
begin
  select a.attnum into v_attnum
  from pg_catalog.pg_attribute a
  join pg_catalog.pg_class c on c.oid = a.attrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'events'
    and a.attname = 'recurrence_id' and not a.attisdropped;

  select con.conname into v_name
  from pg_catalog.pg_constraint con
  join pg_catalog.pg_class c on c.oid = con.conrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'events'
    and con.contype = 'f'
    and con.confrelid = con.conrelid      -- self-referential
    and con.conkey = array[v_attnum];     -- exactly (recurrence_id)

  if v_name is null then
    raise notice 'no single-column recurrence_id FK found; nothing to drop';
  else
    raise notice 'dropping legacy self-FK %', v_name;
    execute format('alter table public.events drop constraint %I', v_name);
  end if;
end;
$fk$;

alter table public.events
  add constraint events_recurrence_owner_fkey
    foreign key (recurrence_id, owner_id)
    references public.events (id, owner_id)
    on delete cascade;

-- The referencing side of a foreign key gets NO index automatically, and two
-- things want one here: the per-master count in section 4, and ON DELETE
-- CASCADE, which otherwise scans to find a master's children on every delete.
--
-- 0003's events_excl_timed_uidx / events_excl_allday_uidx both lead with
-- recurrence_id and between them cover every exception row, but each is partial
-- on a different slot key, so a plain `where recurrence_id = $1` can use at
-- best one of them and the planner may prefer a seq scan over combining both.
-- 0001's events_owner_recurrence_idx leads with owner_id and cannot serve a
-- lookup that does not name an owner.
--
-- Partial `where recurrence_id is not null` keeps it to exception rows only --
-- currently 1 of 16.
create index events_recurrence_owner_idx
  on public.events (recurrence_id, owner_id)
  where recurrence_id is not null;


-- ============================================================================
-- 3. THE LIMITS, IN ONE PLACE EACH.
--
-- IMMUTABLE so the planner inlines them: the trigger bodies read them as if the
-- numbers were literals, with none of the cost of a function call per statement
-- and none of the drift of a number written twice.
--
-- CHOOSING THE NUMBERS. Both are deliberately far above any real calendar and
-- far below the point where the table misbehaves -- a quota is a blast radius,
-- not a product decision, and should never be the thing a genuine user meets.
--
--   5000 events per owner       ~10 events every week for 10 years. The abuse
--                               run that prompted this reached 1103.
--    500 exceptions per master  a daily series individually edited every day
--                               for well over a year. The real table holds 1.
--
-- Raising either later is `create or replace` on one function and costs
-- nothing. LOWERING one does not retroactively refuse anything: by the delta
-- rule in section 4, owners already above a lowered limit keep full edit and
-- delete rights and are only blocked from growing.
--
-- These are the only two numbers in this migration that are a judgement rather
-- than a measurement.
-- ============================================================================
create or replace function public.events_max_per_owner()
returns int
language sql
immutable
parallel safe
set search_path = ''
as $fn$ select 5000 $fn$;

create or replace function public.events_max_exceptions_per_master()
returns int
language sql
immutable
parallel safe
set search_path = ''
as $fn$ select 500 $fn$;


-- ============================================================================
-- 4a. THE PER-OWNER QUOTA.
--
-- Shape of the body, and why each step is in that order:
--
--   1. work out which owners this statement could have pushed UPWARD.
--      INSERT: every owner in the new rows. UPDATE: only owners with a positive
--      net delta between the old and new transition tables -- an owner that
--      merely had rows edited in place has delta 0 and is not checked at all.
--   2. take one advisory lock per affected owner, IN ASCENDING KEY ORDER.
--      Sorting is what prevents deadlock between two statements that touch the
--      same owners in different row orders.
--   3. count the base table ONCE per owner and compare. Per measured fact (2),
--      that count already includes this statement's rows. Nothing is added.
--
-- A statement that matched no rows still fires this trigger; new_rows is then
-- empty, v_keys is NULL, and the function returns immediately having taken no
-- lock and run no count.
--
-- TG_OP BRANCHING AND TRANSITION TABLES. PostgreSQL forbids declaring
-- transition tables on a trigger registered for more than one event, so INSERT
-- and UPDATE get separate triggers -- and only the UPDATE one declares OLD
-- TABLE. One function serves both: PL/pgSQL prepares a statement the first time
-- it is REACHED, so the INSERT path never prepares the query naming old_rows
-- and never discovers that it does not exist.
-- ============================================================================
create or replace function public.events_enforce_owner_quota()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  -- Advisory lock namespace. Any two distinct ints would do; these are written
  -- out so a future lock in this project can pick a third and not collide.
  c_lock_class constant int := 811001;
  v_limit      int := public.events_max_per_owner();
  v_keys       uuid[];
  v_key        uuid;
  r            record;
begin
  if tg_op = 'INSERT' then
    select array_agg(distinct n.owner_id order by n.owner_id)
      into v_keys
    from new_rows n;
  else
    select array_agg(d.owner_id order by d.owner_id)
      into v_keys
    from (
      select x.owner_id
      from (
        select n.owner_id, 1 as delta from new_rows n
        union all
        select o.owner_id, -1        from old_rows o
      ) x
      group by x.owner_id
      having sum(x.delta) > 0
    ) d;
  end if;

  if v_keys is null then
    return null;
  end if;

  -- Step 2. Ascending order is guaranteed by the ORDER BY above.
  foreach v_key in array v_keys loop
    perform pg_catalog.pg_advisory_xact_lock(
      c_lock_class, pg_catalog.hashtext(v_key::text)
    );
  end loop;

  -- Step 3. One grouped count for every affected owner.
  for r in
    select e.owner_id, count(*) as n
    from public.events e
    where e.owner_id = any(v_keys)
    group by e.owner_id
  loop
    if r.n > v_limit then
      raise exception
        'event quota exceeded: owner % would hold % events, limit is %',
        r.owner_id, r.n, v_limit
        using errcode = '23514',
              detail  = 'TIMEWEAVE_QUOTA_EVENTS',
              hint    = 'Delete existing events before creating more.';
    end if;
  end loop;

  return null;
end;
$fn$;


-- ============================================================================
-- 4b. THE PER-MASTER EXCEPTION QUOTA.
--
-- Identical in shape to 4a; the key is recurrence_id instead of owner_id and
-- NULLs are excluded, because a row with no recurrence_id is not an exception
-- and belongs to no master's budget.
--
-- TOMBSTONES COUNT. A "delete this occurrence" row is an ordinary exception row
-- with is_cancelled = true; it occupies storage and is expanded over like any
-- other. Excluding it would leave an unbounded way to grow a series.
--
-- WHY THIS IS COUNTABLE AT ALL: section 2's composite FK. Without it, "the
-- exceptions of master M" could span owners, and a per-master ceiling would be
-- a number several accounts could contribute to.
-- ============================================================================
create or replace function public.events_enforce_exception_quota()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  c_lock_class constant int := 811002;
  v_limit      int := public.events_max_exceptions_per_master();
  v_keys       uuid[];
  v_key        uuid;
  r            record;
begin
  if tg_op = 'INSERT' then
    select array_agg(distinct n.recurrence_id order by n.recurrence_id)
      into v_keys
    from new_rows n
    where n.recurrence_id is not null;
  else
    select array_agg(d.recurrence_id order by d.recurrence_id)
      into v_keys
    from (
      select x.recurrence_id
      from (
        select n.recurrence_id, 1 as delta
          from new_rows n where n.recurrence_id is not null
        union all
        select o.recurrence_id, -1
          from old_rows o where o.recurrence_id is not null
      ) x
      group by x.recurrence_id
      having sum(x.delta) > 0
    ) d;
  end if;

  if v_keys is null then
    return null;
  end if;

  foreach v_key in array v_keys loop
    perform pg_catalog.pg_advisory_xact_lock(
      c_lock_class, pg_catalog.hashtext(v_key::text)
    );
  end loop;

  for r in
    select e.recurrence_id, count(*) as n
    from public.events e
    where e.recurrence_id = any(v_keys)
    group by e.recurrence_id
  loop
    if r.n > v_limit then
      raise exception
        'exception quota exceeded: master % would hold % exception rows, limit is %',
        r.recurrence_id, r.n, v_limit
        using errcode = '23514',
              detail  = 'TIMEWEAVE_QUOTA_EXCEPTIONS',
              hint    = 'Edit or delete the whole series instead of more '
                        'individual occurrences.';
    end if;
  end loop;

  return null;
end;
$fn$;


-- ============================================================================
-- 4c. THE TRIGGERS.
--
-- Four, not two: transition tables may not be declared on a trigger registered
-- for more than one event, so INSERT and UPDATE are separate registrations.
--
-- NAME ORDER IS PART OF THE DESIGN. Triggers of the same timing fire
-- alphabetically, so events_quota_exception_* always runs before
-- events_quota_owner_*. That fixes a single global lock-acquisition order
-- (class 811002 before class 811001) across every session, which together with
-- the sorted key arrays in each function is the whole deadlock argument.
--
-- No DELETE trigger: a delete cannot push a count over a ceiling.
--
-- ERROR SHAPE follows 0008: SQLSTATE 23514 with a stable machine-readable token
-- in DETAIL, which PostgREST surfaces as `details` and which the client
-- branches on. MESSAGE is for humans and logs and its wording may change; it
-- names the offending id and the two numbers so a support question is
-- answerable from the log line alone.
--
-- The trigger functions themselves need no GRANT: EXECUTE on a trigger function
-- is checked when CREATE TRIGGER runs, not when the trigger fires.
-- ============================================================================
drop trigger if exists events_quota_exception_ai on public.events;
drop trigger if exists events_quota_exception_au on public.events;
drop trigger if exists events_quota_owner_ai     on public.events;
drop trigger if exists events_quota_owner_au     on public.events;

create trigger events_quota_exception_ai
  after insert on public.events
  referencing new table as new_rows
  for each statement
  execute function public.events_enforce_exception_quota();

create trigger events_quota_exception_au
  after update on public.events
  referencing old table as old_rows new table as new_rows
  for each statement
  execute function public.events_enforce_exception_quota();

create trigger events_quota_owner_ai
  after insert on public.events
  referencing new table as new_rows
  for each statement
  execute function public.events_enforce_owner_quota();

create trigger events_quota_owner_au
  after update on public.events
  referencing old table as old_rows new table as new_rows
  for each statement
  execute function public.events_enforce_owner_quota();


-- ============================================================================
-- 5. EXECUTE privileges.
--
-- The two enforcement functions are SECURITY DEFINER and are reachable ONLY as
-- triggers, so PUBLIC is revoked and nothing is granted back. Calling them
-- outside a trigger is meaningless anyway -- they read transition tables that
-- only the trigger machinery supplies.
--
-- The two limit functions ARE granted to authenticated, on purpose: the client
-- can then show "4,995 of 5,000 events" from the same number the trigger
-- enforces, instead of hardcoding a second copy in TypeScript. They are pure
-- constants and disclose nothing.
--
-- anon gets nothing. 0002 grants it no DML on events, so it can never reach the
-- triggers; and it has no reason to read a limit it cannot approach.
-- ============================================================================
revoke execute on function public.events_enforce_owner_quota()     from public;
revoke execute on function public.events_enforce_exception_quota() from public;
revoke execute on function public.events_max_per_owner()             from public;
revoke execute on function public.events_max_exceptions_per_master() from public;

grant execute on function public.events_max_per_owner()             to authenticated;
grant execute on function public.events_max_exceptions_per_master() to authenticated;
commit;
