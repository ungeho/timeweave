-- ============================================================================
-- TimeWeave Phase 6-x (M-B): the recurrence graph invariant on public.events.
--
-- WHAT THIS IS. One statement-level trigger function and its two triggers,
-- enforcing that every exception row hangs off a proper recurring master:
--
--   for every row C with C.recurrence_id IS NOT NULL there is a row P with
--     P.id       = C.recurrence_id
--     P.owner_id = C.owner_id
--     P.rrule    IS NOT NULL
--     P.all_day  = C.all_day
--
-- WHAT THIS IS NOT. No RRULE grammar check and no check that an exception's
-- slot is an occurrence the rule actually produces -- that would mean
-- re-implementing recurrence expansion in the database, which is out of scope
-- on purpose. No duration caps, no timestamp hygiene, no FreeBusy change, no
-- change to 0011's quotas, 0012's rate limit, 0013's CHECKs, the composite FK,
-- any index, any RLS policy, any grant on public.events, or anything on
-- public.share_links. No DELETE trigger. No new advisory-lock class.
--
-- ============================================================================
-- WHO ENFORCES WHICH PART
--
-- Existence and owner equality are ALREADY guaranteed and are deliberately not
-- re-implemented here: 0011 replaced the single-column self-reference with
--
--   events_recurrence_owner_fkey  (recurrence_id, owner_id)
--                                   -> events (id, owner_id)  ON DELETE CASCADE
--
-- so a child cannot name a parent that does not exist or belongs to someone
-- else, and a parent's id or owner cannot change under its children (ON UPDATE
-- NO ACTION) unless the children move with it in the same statement.
--
-- What the FK cannot say is WHAT KIND of row the parent is. Before this file
-- any same-owner row was accepted as a parent -- a one-off, another exception,
-- a cancelled exception -- and a master could lose its rrule, become an
-- exception itself, or flip all_day while its exceptions still pointed at it.
-- The UI never does any of this, but authenticated clients hold table-level
-- UPDATE (0002) and the client passes rrule / recurrence_id / all_day straight
-- through a patch, so the database is the only place the rule can live. This
-- trigger adds exactly the two conditions the FK cannot express:
--
--   P.rrule IS NOT NULL          the parent is a recurring master
--   P.all_day = C.all_day        of the same kind; the application already
--                                refuses to build any other exception
--                                (exceptionEdit.ts throws), the DB now agrees
--
-- P.recurrence_id IS NULL is not checked separately: rrule IS NOT NULL already
-- implies it through the existing events_master_not_exception CHECK.
--
-- WHY THERE IS NO CYCLE DETECTOR. If every parent must be a master and no
-- master can be an exception, then a parent never has a parent. The graph is a
-- set of stars of depth one, so chains, exception-of-exception and cycles of
-- any length are structurally impossible. The shortest cycle, a row that is its
-- own parent, is also refused by 0013's events_recurrence_not_self CHECK, which
-- survives replica mode where this trigger does not.
--
-- WHY THERE IS NO DELETE TRIGGER. Deleting a master cascades to its exceptions
-- through the FK, and deleting an exception cannot orphan anything. A child
-- write racing a master delete is serialized by the FK's own row locks.
-- Measured in Matrix H2: all four DELETE/child-write orderings left no invalid
-- graph and produced no deadlock; every wait was a row-lock wait.
--
-- ============================================================================
-- WHAT IS VALIDATED, AND ON WHICH ROWS ONLY
--
-- FORWARD (the child side). INSERT: every new row that has a recurrence_id.
-- UPDATE: every row whose graph-relevant state changed -- recurrence_id,
-- owner_id, all_day, or whether rrule is null -- found by pairing OLD and NEW
-- rows on id. A row whose id itself changed cannot be paired and is treated
-- as changed. For each such row that is an exception now, its current parent
-- must satisfy the predicate above.
--
-- REVERSE (the parent side). For every changed row, under its old id and its
-- new id, every CURRENT exception pointing at it must still satisfy the
-- predicate. This is what refuses "master rrule -> NULL", "master becomes an
-- exception" and "master all_day flip" while exceptions exist.
--
-- Only the changed rows and the children of changed rows are read, through the
-- primary key and 0011's events_recurrence_owner_idx. Nothing scans an owner's
-- whole calendar and nothing scans other owners.
--
-- ============================================================================
-- SERIALIZATION: 811001 IS REUSED, AND THE LOCK SET IS CHOSEN FOR 0011
--
-- A read-then-decide check is a TOCTOU race: an exception can be inserted
-- while its master is losing its rrule, each transaction validating against a
-- snapshot that does not yet contain the other. The composite FK does NOT
-- close this: the child's FK check takes FOR KEY SHARE on the parent, and a
-- parent UPDATE that leaves (id, owner_id) alone takes FOR NO KEY UPDATE --
-- the two do not conflict (measured in the Matrix H work). So this trigger
-- takes the owner lock
--
--   pg_advisory_xact_lock(811001, hashtext(owner_id::text))
--
-- -- the SAME class and key as 0011's owner quota and 0016's share-link quota
-- -- for every owner the statement touches, in ascending owner order, BEFORE
-- it reads anything. A competing statement for the same owner blocks there,
-- and under READ COMMITTED its validation, run after the wait, sees the first
-- statement's committed rows. The composite FK means a child always shares
-- its parent's owner, so the owners of the transition rows already cover every
-- child reverse validation can find; no other owner is ever needed.
--
-- THE LOCK SET IS DELIBERATELY A SUPERSET OF 0011's. On INSERT it is the
-- owners of the new rows -- exactly the set events_enforce_owner_quota locks
-- next. On UPDATE it is the owners of the OLD and NEW rows, which contains the
-- set 0011 locks (owners whose row count rises) whatever the statement does.
-- Because this trigger runs first and takes the whole set in one ascending
-- pass, 0011's owner quota only ever re-takes locks already held (advisory
-- locks are reentrant) and never acquires a new 811001 key out of order.
-- Matrix H2 measured why this matters: when the graph trigger ran AFTER 0011
-- instead, two privileged statements moving rows between two owners in mirror
-- image each locked one owner in 0011 and then the other in the graph trigger,
-- and deadlocked (40P01). With the superset taken first: 0 of 60 trials.
-- If 0011's owner-quota lock set ever changes, this superset property must be
-- re-checked.
--
-- A statement that changes no graph-relevant column still takes the lock but
-- skips validation. For ordinary client writes this costs nothing new: 0012's
-- rate-state row already serializes a charged owner's writes (measured in H2:
-- ~300 ms of a 300 ms hold with or without this file). Only rate-exempt
-- writers (no JWT subject, or service_role) are newly serialized per owner.
--
-- ============================================================================
-- THE GLOBAL PER-STATEMENT LOCK ORDER, AND WHY THE TRIGGER NAMES ARE LOAD-BEARING
--
-- Every events INSERT and UPDATE statement acquires, in this order:
--
--   811002 keys (0011 exception quota)  ->  811001 keys (this file, all in one
--   ascending pass; 0011 owner quota re-takes them)  ->  the owner's row in
--   timeweave_private.event_write_rate (0012)
--
-- AFTER triggers of the same timing fire in NAME order, so that order is
-- produced entirely by the names:
--
--   events_quota_exception_*   811002
--   events_quota_graph_*       811001, the full ascending set   <- this file
--   events_quota_owner_*       811001, already held
--   events_rate_*              event_write_rate row lock
--
-- 'quota_e' < 'quota_g' < 'quota_o' < 'rate'. The graph trigger's name says
-- "quota" because it has to sort there, not because it is a quota.
--
-- DO NOT RENAME OR REORDER THESE TRIGGERS. Matrix H2 measured the alternative
-- this design first recorded, events_recurrence_graph_*, which sorts AFTER
-- events_rate_*. There an INSERT takes 811001 (0011) and then the rate row,
-- while a graph-relevant UPDATE takes the rate row and then 811001 (0011 takes
-- no lock on an ordinary UPDATE, so the graph trigger was first). Two such
-- statements of one owner formed a cycle: 40P01 in 5 of 5 controlled trials
-- and in 19 of 30 trials with no timing control at all. With the names above:
-- 40P01 in 0 of 90 same-owner trials. Any future trigger that takes 811001 on
-- public.events must also sort before events_rate_*.
--
-- 0016's share-link create follows the same rule on its own table (811001,
-- then its own rate row), so 811001 always precedes a rate-state row lock.
--
-- SCOPE OF THAT GUARANTEE. Trigger names order locks WITHIN one statement.
-- A multi-statement transaction can still take 811001 in one statement and
-- 811002 in a later one -- for example a plain event insert followed by an
-- exception insert -- and deadlock against a transaction doing the opposite.
-- That exists since 0011, is measured, is not introduced or changed here, and
-- no current code path reaches it: PostgREST runs one statement per request.
--
-- ============================================================================
-- ISOLATION: READ COMMITTED IS THE PREMISE
--
-- The invariant holds under READ COMMITTED, which is what PostgREST runs --
-- the same premise as 0011 and 0016. Measured in H2 over the four races
-- (exception insert against master rrule -> NULL, master becoming an
-- exception, master all_day flip, and exception reparent against its new
-- master losing its rrule): in both orders the second writer waited on 811001
-- and was refused, and in 20 unsynchronized trials of each no invalid graph
-- was ever committed.
--
-- REPEATABLE READ IS NOT SAFE, and this file does not claim otherwise. There
-- the second writer validates with the snapshot it took before the lock wait.
-- Measured in H2 for exception insert against master rrule -> NULL:
--
--   rate-exempt, trusted writer (no JWT subject / service_role): BOTH commit,
--     in both orders, leaving an exception under a non-master (5 of 5 each).
--     The FK's key-share lock does not prevent it.
--   charged writer: the second writer failed with 40001 (5 of 5 each). That
--     comes from the rate-state row, not from this trigger, and MUST NOT be
--     relied on as part of the graph guarantee: it disappears for every
--     rate-exempt writer and would disappear if 0012 changed.
--
-- SERIALIZABLE is expected to refuse the second writer through predicate
-- tracking, as it did for 0016's quota; it was not re-measured for this file.
--
-- ============================================================================
-- ERRORS
--
--   23514  DETAIL TIMEWEAVE_RECURRENCE_GRAPH
--
-- One token for every violation. The UI never produces these states and a user
-- could not act on finer distinctions, so the client needs only to know it hit
-- the graph rule; it maps an unknown DETAIL to its generic error today. MESSAGE
-- names the rule and a row count for logs and carries no row id, owner id or
-- other identifier.
-- ============================================================================
begin;

create or replace function public.events_enforce_recurrence_graph()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  c_lock_class constant int := 811001;
  v_owners     uuid[];
  v_key        uuid;
  v_bad        int;
begin
  -- The lock set: INSERT = owners of the new rows (0011's INSERT set exactly);
  -- UPDATE = owners of old and new rows (a superset of 0011's UPDATE set).
  if tg_op = 'INSERT' then
    select array_agg(distinct n.owner_id order by n.owner_id)
      into v_owners
    from new_rows n;
  else
    select array_agg(distinct x.owner_id order by x.owner_id)
      into v_owners
    from (
      select n.owner_id from new_rows n
      union
      select o.owner_id from old_rows o
    ) x;
  end if;

  if v_owners is null then
    return null;
  end if;

  -- Ascending, one pass, before any read (see the header on lock order).
  foreach v_key in array v_owners loop
    perform pg_catalog.pg_advisory_xact_lock(
      c_lock_class, pg_catalog.hashtext(v_key::text)
    );
  end loop;

  if tg_op = 'INSERT' then
    -- Forward only: a new row cannot already have children.
    select count(*)
      into v_bad
    from new_rows c
    where c.recurrence_id is not null
      and not exists (
        select 1
        from public.events p
        where p.id = c.recurrence_id
          and p.owner_id = c.owner_id
          and p.rrule is not null
          and p.all_day = c.all_day
      );
  else
    with changed as (
      -- Rows whose graph-relevant state changed, paired on id; a row whose id
      -- changed has no partner and counts as changed.
      select n.id
      from new_rows n
      left join old_rows o on o.id = n.id
      where o.id is null
         or n.owner_id      is distinct from o.owner_id
         or n.recurrence_id is distinct from o.recurrence_id
         or n.all_day       is distinct from o.all_day
         or (n.rrule is null) is distinct from (o.rrule is null)
      union
      select o.id
      from old_rows o
      left join new_rows n on n.id = o.id
      where n.id is null
         or n.owner_id      is distinct from o.owner_id
         or n.recurrence_id is distinct from o.recurrence_id
         or n.all_day       is distinct from o.all_day
         or (n.rrule is null) is distinct from (o.rrule is null)
    ),
    candidates as (
      -- forward: changed rows that are exceptions now
      select e.id, e.owner_id, e.recurrence_id, e.all_day
      from public.events e
      where e.id in (select id from changed)
        and e.recurrence_id is not null
      union
      -- reverse: current exceptions of any changed row
      select e.id, e.owner_id, e.recurrence_id, e.all_day
      from public.events e
      where e.recurrence_id in (select id from changed)
    )
    select count(*)
      into v_bad
    from candidates c
    where not exists (
      select 1
      from public.events p
      where p.id = c.recurrence_id
        and p.owner_id = c.owner_id
        and p.rrule is not null
        and p.all_day = c.all_day
    );
  end if;

  if v_bad > 0 then
    raise exception
      'recurrence graph violated: % exception row(s) would not belong to a recurring master of the same all-day kind',
      v_bad
      using errcode = '23514',
            detail  = 'TIMEWEAVE_RECURRENCE_GRAPH',
            hint    = 'An exception must belong to a recurring master, and a '
                      'master with exceptions must remain one.';
  end if;

  return null;
end;
$fn$;

-- ============================================================================
-- Triggers. NAME ORDER IS PART OF THE DESIGN -- see the header. Two
-- registrations because a trigger with transition tables may name only one
-- event. There is deliberately no DELETE trigger.
-- ============================================================================
drop trigger if exists events_quota_graph_ai on public.events;
drop trigger if exists events_quota_graph_au on public.events;

create trigger events_quota_graph_ai
  after insert on public.events
  referencing new table as new_rows
  for each statement
  execute function public.events_enforce_recurrence_graph();

create trigger events_quota_graph_au
  after update on public.events
  referencing old table as old_rows new table as new_rows
  for each statement
  execute function public.events_enforce_recurrence_graph();

-- ============================================================================
-- EXECUTE: nobody but the owner, as with 0016's enforcement functions.
-- ============================================================================
revoke execute on function public.events_enforce_recurrence_graph() from public, anon, authenticated;

commit;
