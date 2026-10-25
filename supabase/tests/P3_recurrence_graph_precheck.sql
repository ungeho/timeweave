-- ============================================================================
-- TimeWeave -- PRECHECK P3 for the planned recurrence-graph invariants.
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run by hand, once, against the project
-- the constraints will be applied to, BEFORE any migration is written.
--
-- READ-ONLY: no DDL, no DML, no SET, no temp table, no function creation. One
-- statement inside a read-only transaction that ends in ROLLBACK.
--
-- WHAT IT GATES. The local P3 audit found 19 of 25 graph manipulations
-- unguarded. These are the invariants proposed to close them, and this script
-- answers the only question a migration needs first: does existing production
-- data already satisfy them?
--
--   CHECK    recurrence_id <> id (no self-parent)               -> D01-D02
--   trigger  a child's parent is a proper recurrence master     -> B01-B06
--   trigger  parent and child agree on all_day                  -> C01-C04
--   trigger  a master with children may not be broken by UPDATE -> E01-E04
--
-- SCALE, NOT A LIMIT. Section F measures how many masters exist and how they
-- are spread across owners. It does NOT propose a number. The local finding
-- that 5000 daily masters made get_free_busy take about 266 s is a separate
-- resource-exhaustion item; the quota or timeout that answers it must come
-- from a proper scaling benchmark, not from this script. Nothing here
-- reproduces that load: F only counts rows that already exist.
--
-- SLOT VALUES ARE DELIBERATELY NOT VALIDATED. Whether a slot key corresponds
-- to an occurrence the series actually produces is NOT a hardening candidate.
-- The local probe showed a slot in the year 9999, a slot before DTSTART and a
-- slot at a time the rule never emits are all inert: they detach nothing, they
-- do not crash the expander, and they do not make get_free_busy report free
-- when it is busy. Section G therefore re-confirms only the SHAPE constraints
-- that already exist, from the catalog and by aggregate.
--
-- PRIVACY. Counts, booleans and small bucket tallies only. No owner uuid, no
-- event uuid, no title, no description, no rrule text. Rows that must stay
-- identifiable use the same pseudonym P1, P2 and P2b used:
--
--   substring(encode(sha256(uuid_send(id)), 'hex') from 1 for 10)
--
-- At most 5 per finding.
--
-- TOAST. `rrule is not null` is a null test and reads no TOAST chunk. The rrule
-- VALUE is never read: this script does not call rrule_parse and does not need
-- to. length(), char_length(), btrim(), substr() and convert_to() on a table
-- column all detoast and are not used on one here.
--
-- COST. public.events is scanned once into `ev` (referenced many times, so it
-- materialises). Every graph test is a self-join of that materialised set, and
-- the table held 163 rows with 1 exception row at the last count. The cycle
-- search in section H is the only recursive part; see its own note.
--
-- READING THE OUTPUT. status is 'ok' / 'FAIL' where an expectation exists and
-- 'context' where the value is a measurement. P00 summarises. A FAIL means the
-- matching invariant cannot be introduced as-is and needs either a cleanup or
-- a NOT VALID / grandfathered form first.
-- ============================================================================
begin transaction read only;

with recursive
ev as (
  select e.id,
         e.owner_id,
         e.all_day,
         e.recurrence_id,
         e.is_cancelled,
         e.rrule is not null as has_rrule,
         e.recurrence_slot_start is not null as has_slot_start,
         e.recurrence_slot_date is not null as has_slot_date
  from public.events as e
),
-- Every parent edge, joined to the parent row. A LEFT JOIN so a missing parent
-- is counted rather than silently dropped -- the composite FK should make that
-- impossible, and B04 is the assertion that it did.
edge as (
  select c.id as child_id,
         c.all_day as child_all_day,
         p.id as parent_id,
         p.has_rrule as parent_has_rrule,
         p.recurrence_id as parent_recurrence_id,
         p.is_cancelled as parent_cancelled,
         p.all_day as parent_all_day,
         (p.id is not null
            and p.has_rrule
            and p.recurrence_id is null
            and not p.is_cancelled) as parent_is_proper_master
  from ev as c
  left join ev as p
    on p.id = c.recurrence_id
  where c.recurrence_id is not null
),
children as (
  select parent_id, count(*) as n
  from edge
  where parent_id is not null
  group by parent_id
),
by_owner as (
  select owner_id,
         count(*) as n_rows,
         count(*) filter (where has_rrule) as n_masters
  from ev
  group by owner_id
),
-- H. Cycle search, bounded. Only rows that HAVE a parent can sit on a cycle,
-- so the walk starts from the edge set alone. Depth is capped at 32; H04
-- reports whether any path was still running at the cap, which is the only
-- case where "no cycle found" would be weaker than "no cycle exists".
walk (start_id, node_id, depth, looped) as (
  select e.child_id, e.parent_id, 1,
         coalesce(e.parent_id = e.child_id, false)
  from edge as e
  where e.parent_id is not null
  union all
  select w.start_id, e2.parent_id, w.depth + 1,
         coalesce(e2.parent_id = w.start_id, false)
  from walk as w
  join edge as e2
    on e2.child_id = w.node_id
  where w.depth < 32
    and not w.looped
    and e2.parent_id is not null
),
cyc as (
  select count(*) filter (where looped) as n_looped,
         coalesce(max(depth), 0) as max_depth,
         count(*) filter (where depth >= 32 and not looped) as at_cap,
         count(*) as walk_rows
  from walk
),
agg as (
  select (select count(*) from ev) as n_events,
         (select count(*) from ev
           where recurrence_id is not null) as n_children,
         (select count(*) from ev where has_rrule) as n_masters,
         (select count(*) from by_owner) as n_owners,
         (select count(*) from edge where parent_id is null) as p_missing,
         (select count(*) from edge
           where parent_id is not null and not parent_has_rrule) as p_no_rrule,
         (select count(*) from edge
           where parent_recurrence_id is not null) as p_is_exception,
         (select count(*) from edge
           where parent_cancelled) as p_cancelled,
         (select count(*) from edge
           where parent_is_proper_master) as p_proper,
         (select count(*) from edge
           where parent_id is not null
             and child_all_day = false
             and parent_all_day = true) as mm_timed_child,
         (select count(*) from edge
           where parent_id is not null
             and child_all_day = true
             and parent_all_day = false) as mm_allday_child,
         (select count(*) from ev where recurrence_id = id) as self_parent,
         (select count(*) from children) as n_parents,
         (select coalesce(max(n), 0) from children) as max_children,
         (select count(*) from children c
           join ev p on p.id = c.parent_id
          where not (p.has_rrule and p.recurrence_id is null
                     and not p.is_cancelled)) as bad_parents,
         (select count(*) from by_owner
           where n_masters > 0) as owners_with_master,
         (select coalesce(max(n_masters), 0) from by_owner) as max_masters,
         (select coalesce(max(n_rows), 0) from by_owner) as max_rows_owner,
         (select count(*) from by_owner where n_masters between 1 and 9) as b1,
         (select count(*) from by_owner
           where n_masters between 10 and 49) as b2,
         (select count(*) from by_owner
           where n_masters between 50 and 199) as b3,
         (select count(*) from by_owner
           where n_masters between 200 and 999) as b4,
         (select count(*) from by_owner where n_masters >= 1000) as b5,
         (select count(*) from ev where has_rrule and all_day) as m_allday,
         (select count(*) from ev where has_rrule and not all_day) as m_timed,
         (select count(*) from ev
           where recurrence_id is not null
             and all_day = false
             and (not has_slot_start or has_slot_date)) as slot_bad_timed,
         (select count(*) from ev
           where recurrence_id is not null
             and all_day = true
             and (not has_slot_date or has_slot_start)) as slot_bad_allday,
         (select count(*) from ev
           where recurrence_id is null
             and (has_slot_start or has_slot_date)) as slot_on_non_child,
         (select count(*) from ev
           where is_cancelled and recurrence_id is null) as cancelled_master
),
cat as (
  select (select count(*) from pg_catalog.pg_constraint
           where conrelid = 'public.events'::regclass
             and contype = 'c'
             and conname in ('events_exception_slot',
                             'events_cancel_only_on_exception',
                             'events_master_not_exception')) as shape_checks,
         (select count(*) from pg_catalog.pg_indexes
           where tablename = 'events'
             and indexname in ('events_excl_timed_uidx',
                               'events_excl_allday_uidx')) as slot_uidx,
         (select count(*) from pg_catalog.pg_constraint
           where conrelid = 'public.events'::regclass
             and contype = 'f'
             and confrelid = 'public.events'::regclass) as self_fk
),
res as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL'
         end as status
  from agg as g
  cross join cyc as y
  cross join cat as k
  cross join lateral (values

    -- A. baseline.
    ('A01', 'baseline', 'events rows', null, g.n_events::text),
    ('A02', 'baseline', 'rows with recurrence_id (children / edges)', null,
     g.n_children::text),
    ('A03', 'baseline', 'rows with rrule (masters)', null, g.n_masters::text),
    ('A04', 'baseline', 'distinct owners', null, g.n_owners::text),

    -- B. is every child's parent a proper recurrence master?
    ('B01', 'parent', 'children whose parent has rrule IS NULL', '0',
     g.p_no_rrule::text),
    ('B02', 'parent', 'children whose parent is itself an exception', '0',
     g.p_is_exception::text),
    ('B03', 'parent', 'children whose parent is cancelled', '0',
     g.p_cancelled::text),
    ('B04', 'parent', 'children whose parent row is missing', '0',
     g.p_missing::text),
    ('B05', 'parent', 'children with a proper master parent (= A02)',
     g.n_children::text, g.p_proper::text),
    ('B06', 'parent', 'pseudonyms of up to 5 offending children', null,
     coalesce((
       select string_agg(x.h, ' ')
       from (
         select substring(encode(sha256(uuid_send(e.child_id)), 'hex')
                          from 1 for 10) as h
         from edge as e
         where not e.parent_is_proper_master
         order by e.child_id
         limit 5
       ) as x
     ), 'none')),

    -- C. do parent and child agree on all_day?
    ('C01', 'shape', 'TIMED child on an ALL-DAY parent', '0',
     g.mm_timed_child::text),
    ('C02', 'shape', 'ALL-DAY child on a TIMED parent', '0',
     g.mm_allday_child::text),
    ('C03', 'shape', 'all_day mismatches in total', '0',
     (g.mm_timed_child + g.mm_allday_child)::text),
    ('C04', 'shape', 'pseudonyms of up to 5 mismatched children', null,
     coalesce((
       select string_agg(x.h, ' ')
       from (
         select substring(encode(sha256(uuid_send(e.child_id)), 'hex')
                          from 1 for 10) as h
         from edge as e
         where e.parent_id is not null
           and e.child_all_day is distinct from e.parent_all_day
         order by e.child_id
         limit 5
       ) as x
     ), 'none')),

    -- D. self-parent.
    ('D01', 'self', 'rows where recurrence_id = id', '0',
     g.self_parent::text),
    ('D02', 'self', 'pseudonyms of up to 5 self-parent rows', null,
     coalesce((
       select string_agg(x.h, ' ')
       from (
         select substring(encode(sha256(uuid_send(e.id)), 'hex')
                          from 1 for 10) as h
         from ev as e
         where e.recurrence_id = e.id
         order by e.id
         limit 5
       ) as x
     ), 'none')),

    -- E. the master side: rows that HAVE children.
    ('E01', 'master', 'rows that have at least one child', null,
     g.n_parents::text),
    ('E02', 'master', 'of those, rows that are NOT a proper master', '0',
     g.bad_parents::text),
    ('E03', 'master', 'largest child count held by one parent', null,
     g.max_children::text),
    ('E04', 'master', 'pseudonyms of up to 5 improper parents with children',
     null,
     coalesce((
       select string_agg(x.h, ' ')
       from (
         select substring(encode(sha256(uuid_send(c.parent_id)), 'hex')
                          from 1 for 10) as h
         from children as c
         join ev as p on p.id = c.parent_id
         where not (p.has_rrule and p.recurrence_id is null
                    and not p.is_cancelled)
         order by c.parent_id
         limit 5
       ) as x
     ), 'none')),

    -- F. master SCALE. Measurement only -- no number is proposed here.
    ('F01', 'scale', 'masters in total', null, g.n_masters::text),
    ('F02', 'scale', 'owners holding at least one master', null,
     g.owners_with_master::text),
    ('F03', 'scale', 'largest master count held by one owner', null,
     g.max_masters::text),
    ('F04', 'scale', 'owners holding 1-9 masters', null, g.b1::text),
    ('F05', 'scale', 'owners holding 10-49 masters', null, g.b2::text),
    ('F06', 'scale', 'owners holding 50-199 masters', null, g.b3::text),
    ('F07', 'scale', 'owners holding 200-999 masters', null, g.b4::text),
    ('F08', 'scale', 'owners holding 1000 or more masters', null, g.b5::text),
    ('F09', 'scale', 'largest event count held by one owner', null,
     g.max_rows_owner::text),
    ('F10', 'scale', 'all-day masters', null, g.m_allday::text),
    ('F11', 'scale', 'timed masters', null, g.m_timed::text),

    -- G. the slot SHAPE constraints that already exist, re-confirmed.
    ('G01', 'slot', 'timed children with a wrong slot-key shape', '0',
     g.slot_bad_timed::text),
    ('G02', 'slot', 'all-day children with a wrong slot-key shape', '0',
     g.slot_bad_allday::text),
    ('G03', 'slot', 'non-children carrying a slot key', '0',
     g.slot_on_non_child::text),
    ('G04', 'slot', 'cancelled rows that are not children', '0',
     g.cancelled_master::text),
    ('G05', 'slot', 'shape CHECK constraints present (of 3)', '3',
     k.shape_checks::text),
    ('G06', 'slot', 'partial unique slot indexes present (of 2)', '2',
     k.slot_uidx::text),
    ('G07', 'slot', 'self-referencing foreign keys on events', '1',
     k.self_fk::text),

    -- H. cycle search, bounded at depth 32.
    ('H01', 'cycle', 'edges walked (rows with a parent)', null,
     g.n_children::text),
    ('H02', 'cycle', 'walk rows produced (cost proxy)', null,
     y.walk_rows::text),
    ('H03', 'cycle', 'deepest chain found', null, y.max_depth::text),
    ('H04', 'cycle', 'cycles detected within depth 32', '0',
     y.n_looped::text),
    ('H05', 'cycle', 'paths still running at the depth cap', '0',
     y.at_cap::text)

  ) as v (ord, phase, metric, expected, value)
)
select ord, phase, metric, expected, value, status
from res
union all
select 'P00', 'summary', 'checks that FAIL', '0',
       count(*) filter (where status = 'FAIL')::text,
       case when count(*) filter (where status = 'FAIL') = 0
            then 'ok'
            else 'FAIL'
       end
from res
order by 1;

rollback;
