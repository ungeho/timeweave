-- ============================================================================
-- TimeWeave Phase 6-x (M-A): row-local bounds on public.events.
--
-- WHAT THIS IS. The first of five hardening migrations. It adds only the
-- invariants that can be decided from ONE row, so every one of them is a CHECK.
-- Nothing here reads another row, takes a lock of its own, or runs application
-- logic. The cross-row recurrence invariants (M-B), the share_links work
-- (M-C/M-D/M-E) and everything on the deferred list are NOT in this file.
--
-- WHY CHECK AND NOT A TRIGGER, even where a trigger could also do the job:
-- `session_replication_role = 'replica'` disables triggers but NOT check
-- constraints, and that setting is what a logical-replication apply worker and
-- several restore paths run under. A row-local rule belongs in a CHECK so it
-- survives those paths.
--
-- COMPATIBILITY IS MEASURED, NOT ASSUMED. Every constraint below was gated by a
-- read-only precheck run against production before this file was written:
--
--   octet_length(rrule) <= 255     P1 B02 max = 35 bytes, B03 over-limit = 0
--   date / timestamp bounds        P1 D05 = D06 = D07 = 0, actual data spans
--                                  only 2026-08-29 .. 2026-09-24
--   end_at > start_at              P1 E01 zero-duration rows = 0
--   recurrence_id <> id            P1 D01 = 0 and P3 D01 = 0
--
-- P1 and P3 both reported P00 = 0. Nothing here needs a cleanup first and
-- nothing is added NOT VALID.
--
-- ============================================================================
-- THE TECHNICAL DATE BOUNDARY, AND WHY IT IS 0100-01-01 .. 9999-12-31
--
-- This is not a product opinion about which years a calendar should offer. It
-- is where TimeWeave's own implementation stops working, established by
-- measurement against the real code:
--
--   UPPER, 9999-12-31. Two independent failures start at year 10000.
--     * The RRULE UNTIL grammar cannot express a five-digit year on either
--       side: services/recurrence.ts uses /^(\d{4})(\d{2})(\d{2})$/ and
--       0006's rrule_parse uses '^[0-9]{8}$'. Measured: formatRRule emits
--       "UNTIL=100000101" for a year-10000 rule and parseRRule then REJECTS
--       its own output, so the documented round-trip contract breaks.
--     * Date#toISOString switches to the extended form "+010000-01-01T...".
--       occurrences.ts:170 and dayAgenda.ts:213-223 order occurrences with
--       localeCompare on those strings, and "+010000-..." sorts BEFORE
--       "2026-..." because '+' (0x2B) < '2' (0x32). A year-10000 event would
--       therefore appear first in every list.
--
--   LOWER, 0100-01-01. The Date constructor's two-digit-year rule silently
--     remaps years 1..99. Measured: isoFromDateString('0050-06-15') returns
--     1950-06-14T15:00:00.000Z. No error is raised; the value is simply wrong
--     by 1900 years. 0100-01-01 is the first date that round-trips.
--
-- Both the JS Date absolute limit (275760-09-13) and the ISO extended-year
-- boundary (10000-01-01) sit OUTSIDE this range, so this is the binding one.
--
-- The bounds are written half-open at the top (< 10000-01-01) so the whole of
-- year 9999 remains usable, including an all-day row whose EXCLUSIVE end_date
-- is 9999-12-31.
--
-- ============================================================================
-- WHY events_time_shape IS REPLACED RATHER THAN SUPPLEMENTED
--
-- The original constraint required `end_at >= start_at` on the timed arm while
-- the all-day arm already required `end_date > start_date`. That asymmetry
-- lets a timed event have zero duration: it occupies a row and the quota, it
-- renders as a zero-height chip, and get_free_busy never reports it because
-- its overlap test (start_at < p_to AND end_at > p_from) is strict on both
-- sides. Production holds no such row (P1 E01 = 0).
--
-- Adding a second constraint saying `end_at > start_at` would leave the schema
-- asserting `>=` in one place and `>` in another about the same two columns. A
-- reader would have to check both to know the rule. Replacing the one
-- constraint keeps a single statement of the time shape, which is the clearer
-- schema, and is why this file does a DROP and an ADD instead of an ADD.
--
-- The replacement is identical to the original in every other respect. Only
-- `>=` becomes `>`.
--
-- ============================================================================
-- LOCKING, AND WHY THIS DOES NOT USE NOT VALID
--
-- Each ADD CONSTRAINT takes ACCESS EXCLUSIVE on public.events and scans the
-- table once to validate. public.events holds 163 rows (P1 A01, P3 A01), so
-- that scan is sub-millisecond and the lock is held for the length of this
-- migration rather than for the length of a scan.
--
-- NOT VALID followed by VALIDATE CONSTRAINT exists to avoid a long ACCESS
-- EXCLUSIVE hold on a large table. At 163 rows it would buy nothing, cost two
-- statements per constraint, and leave a window in which the constraint is
-- present but unenforced for existing rows. The simple form is used on
-- purpose.
--
-- The whole file is one transaction. If any statement fails, the DROP of
-- events_time_shape rolls back with everything else and no partial schema
-- survives -- which is the reason the DROP/ADD pair is safe to do here at all.
-- ============================================================================
begin;

-- ============================================================================
-- 1. rrule: a bounded number of BYTES.
--
-- octet_length, not char_length. This is a storage bound, not a typing
-- comfort: the incident this migration exists to prevent stored 800 rows of
-- 1,000,000-byte rrule and put the database at 177% of its tier.
--
-- 255 against a measured ceiling: the longest rule the SQL grammar in 0006 can
-- accept with every field at its maximum is 75 bytes
-- (FREQ=WEEKLY;INTERVAL=9999;BYDAY=MO,TU,WE,TH,FR,SA,SU;UNTIL=20261231T235959Z),
-- the longest the TypeScript form can emit -- including pathological numeric
-- input -- is 97 bytes, and the longest in production is 35. 255 leaves room
-- for a future BYMONTHDAY or BYSETPOS without another migration.
--
-- THE GRAMMAR IS DELIBERATELY NOT CHECKED HERE. 0006 states that SQL may be
-- stricter than the TypeScript parser as a NARROWING rule, never as a write
-- gate. SQL rejects duplicate BYDAY, INTERVAL > 9999 and COUNT > 9999999 where
-- TypeScript accepts them, so validating the grammar on write would start
-- refusing input the client has always been able to save. That is a product
-- decision, not a resource bound, and it is not this file's business. The byte
-- cap alone bounds the damage.
--
-- NULL is allowed: one-off events and exception rows carry no rule.
-- ============================================================================
alter table public.events
  add constraint events_rrule_len
    check (rrule is null or octet_length(rrule) <= 255);


-- ============================================================================
-- 2. The technical date boundary, one constraint per time model.
--
-- Split in two rather than one constraint over all four columns so a violation
-- names the model it came from: a timed row can never trip the all-day rule
-- and vice versa, and the constraint name is all a caller gets back.
--
-- NULL is allowed explicitly. Each row populates exactly one pair (that is
-- events_time_shape's job); the other pair is NULL and must stay legal. Naming
-- the NULL case rather than relying on NULL propagating through the comparison
-- keeps the intent readable.
-- ============================================================================
alter table public.events
  add constraint events_timed_range
    check (
      (start_at is null
         or (start_at >= timestamptz '0100-01-01 00:00:00+00'
             and start_at < timestamptz '10000-01-01 00:00:00+00'))
      and
      (end_at is null
         or (end_at >= timestamptz '0100-01-01 00:00:00+00'
             and end_at < timestamptz '10000-01-01 00:00:00+00'))
    );

alter table public.events
  add constraint events_allday_range
    check (
      (start_date is null
         or (start_date >= date '0100-01-01'
             and start_date < date '10000-01-01'))
      and
      (end_date is null
         or (end_date >= date '0100-01-01'
             and end_date < date '10000-01-01'))
    );


-- ============================================================================
-- 3. A timed event occupies time.
--
-- events_time_shape is replaced, not supplemented -- see the header. The only
-- difference from the 0001 original is `end_at >= start_at` becoming
-- `end_at > start_at`, which makes the timed arm agree with the all-day arm
-- that already required end_date > start_date.
-- ============================================================================
alter table public.events
  drop constraint events_time_shape;

alter table public.events
  add constraint events_time_shape
    check (
      (all_day = false
         and start_at is not null and end_at is not null
         and end_at > start_at
         and start_date is null and end_date is null)
      or
      (all_day = true
         and start_date is not null and end_date is not null
         and end_date > start_date
         and start_at is null and end_at is null)
    );


-- ============================================================================
-- 4. No row is its own recurrence parent.
--
-- Row-local, so it belongs here even though M-B's cross-row rule will make it
-- unreachable by a second route. Keeping both is deliberate:
--
--   * A CHECK survives session_replication_role = 'replica'; a trigger does
--     not. During a restore or a logical-replication apply, this is the only
--     one of the two still standing.
--   * It costs nothing: no parent row is read and no lock is taken.
--   * It is enforced from the moment this migration commits, which is before
--     M-B exists at all.
--
-- For the record, the derivation M-B will rely on: if a child's parent must
-- have rrule IS NOT NULL, then by events_master_not_exception that parent has
-- recurrence_id IS NULL, so it is not itself a child; the graph is therefore a
-- depth-1 star and no cycle of any length -- including this one -- can be
-- built. This constraint states the shortest case directly anyway.
--
-- NULL is allowed: almost every row is not an exception.
-- ============================================================================
alter table public.events
  add constraint events_recurrence_not_self
    check (recurrence_id is null or recurrence_id <> id);

commit;
