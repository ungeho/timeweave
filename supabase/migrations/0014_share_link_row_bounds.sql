-- ============================================================================
-- TimeWeave Phase 6-x (M-C): row-local bounds on public.share_links.
--
-- WHAT THIS IS. The second of five hardening migrations, and the share_links
-- counterpart of 0013. It adds only invariants decidable from ONE row, so all
-- three are CHECK constraints for the same reason 0013 gave: a CHECK survives
-- session_replication_role = 'replica', which is what a restore and a logical-
-- replication apply worker run as, and a trigger does not.
--
-- WHAT THIS IS NOT. Deliberately absent, each belonging to a later migration:
-- the active and total quotas, the create rate limiter, delete_share_link,
-- any change to revoke_share_link or create_share_link, a direct DELETE grant,
-- a bound on the get_free_busy token, any FreeBusy change, any advisory lock,
-- any trigger, and anything touching public.events.
--
-- COMPATIBILITY IS MEASURED. Each constraint was gated by the read-only P2
-- precheck against production:
--
--   octet_length(label) <= 200         P2 C01 max = 20 bytes, C02 over = 0
--   expires_at > created_at            P2 D01 = 0, after C1 removed the one
--                                      born-dead row that this table held
--   expires_at technical range         P2 D04 = 0
--
-- P2 reported P00 = 0 on its post-C1 rerun. Nothing needs a cleanup first and
-- nothing is added NOT VALID.
--
-- ============================================================================
-- WHY created_at IS NOT GIVEN A RANGE, WHILE expires_at IS
--
-- 0013 bounded all four time columns on public.events because all four are
-- client-writable there. On this table the two timestamps are not alike, and
-- the difference was checked against the real schema, the real RPCs and the
-- real client rather than assumed:
--
--   expires_at IS client-supplied. It is the third parameter of
--   create_share_link and is written verbatim: `insert into
--   public.share_links (owner_id, token_hash, label, include_private,
--   expires_at) values (v_owner, v_hash, p_label, ..., p_expires_at)`.
--   An authenticated caller chooses the value.
--
--   created_at IS NOT. It is `timestamptz not null default now()`, it does
--   NOT appear in that INSERT's column list, so the default is what lands;
--   revoke_share_link writes only revoked_at; no other statement in any
--   migration writes this table; and 0004 revokes all table privileges from
--   anon and authenticated, so there is no direct REST path at all. Every
--   route that can set created_at is now().
--
-- The client side agrees. ShareDialog parses and renders expires_at
-- (`Date.parse(l.expiresAt)` for the expired badge, `toLocaleString` for the
-- label) but never reads createdAt, and list_share_links orders by created_at
-- in SQL, not by a JavaScript string compare. So an out-of-range created_at
-- has no reachable path and no known failure mode, whereas an out-of-range
-- expires_at has a measured one: PostgREST renders year 10000 as
-- "10000-01-01T00:00:00+00:00", a five-digit year with no leading '+', and
-- Date.parse returns NaN for it. `NaN <= Date.now()` is false, so such a link
-- would silently never show as expired.
--
-- Bounding created_at would therefore be unreachable by construction -- the
-- same standard by which the byte caps on title/description were rejected as
-- vacuous. It is left out.
--
-- ONE THING TO REVISIT LATER: the ordering constraint below reads created_at.
-- Its meaning rests on created_at being now(). If a future migration ever
-- grants a write path to that column, this file's range decision must be
-- reconsidered at the same time.
--
-- ============================================================================
-- THE TECHNICAL BOUNDARY IS THE SAME ONE 0013 ESTABLISHED
--
-- [0100-01-01, 9999-12-31], written half-open at the top (< 10000-01-01) so
-- the whole of year 9999 stays usable down to the last microsecond.
--
-- For share_links the UPPER bound is the load-bearing half, and it is
-- measured: Date.parse("10000-01-01T00:00:00+00:00") is NaN, while
-- Date.parse("9999-12-31T23:59:59.999999+00:00") is a finite instant that
-- renders. The LOWER bound carries no measured failure here -- a year-50
-- instant still parses -- and is included for one reason: the boundary is a
-- project-wide contract set by 0013, and a timestamp column that quietly
-- accepts a wider range than its sibling is a trap for whoever reads the
-- schema next. It costs nothing.
--
-- ============================================================================
-- LOCKING
--
-- Each ADD CONSTRAINT takes ACCESS EXCLUSIVE on public.share_links and scans
-- it once. The table holds 15 rows (P2 A01 after C1), so the scan is
-- sub-millisecond. NOT VALID / VALIDATE CONSTRAINT exists to shorten a long
-- lock hold on a large table; at 15 rows it would buy nothing and would leave
-- a window where existing rows are unchecked. The simple form is used.
--
-- The whole file is one transaction, so a failure anywhere leaves no partial
-- schema.
-- ============================================================================
begin;

-- ============================================================================
-- 1. label: a bounded number of BYTES.
--
-- octet_length, not char_length, for the same reason 0013 used it on rrule:
-- this is a storage bound. Unlike title and description on public.events,
-- which already carry char_length caps from 0011, label has NEVER had any
-- length bound -- create_share_link passes p_label straight through and the
-- ShareDialog input carries no maxLength. A 10 MB label was accepted in
-- testing.
--
-- 200 bytes against a measured 20 in production, a 10x margin. A label is an
-- owner-facing memo ("for client A"), not a document.
--
-- NULL is allowed: the label is optional and most links carry none.
-- ============================================================================
alter table public.share_links
  add constraint share_links_label_len
    check (label is null or octet_length(label) <= 200);


-- ============================================================================
-- 2. A link may not expire before it exists.
--
-- This does NOT forbid expired links: a link whose expires_at has since
-- passed is perfectly normal and get_free_busy already returns empty for it.
-- What it forbids is storing a link that was ALREADY dead at the instant it
-- was created, which is not a state any caller can have meant.
--
-- `>` and not `>=`: expires_at = created_at is a link that is expired at the
-- moment of its own creation, so it is refused too.
--
-- Production held exactly one such row. C1 deleted it under an exactly-one
-- guard after P2b proved the deletion inert, and the P2 rerun reported
-- D01 = 0. That row was created 60.000 seconds BEFORE its own created_at,
-- with the microseconds matching exactly -- a sign-or-arithmetic slip
-- somewhere between the dialog and the RPC. Where that value came from is
-- still unexplained and is tracked separately; this constraint stops the
-- state from being reachable either way.
--
-- created_at is NOT NULL, so only expires_at needs a null arm.
-- ============================================================================
alter table public.share_links
  add constraint share_links_expiry_after_created
    check (expires_at is null or expires_at > created_at);


-- ============================================================================
-- 3. expires_at inside the technical boundary.
--
-- See the header for why this applies to expires_at and not to created_at.
-- Half-open at the top so 9999-12-31 is usable in full.
--
-- NULL is allowed: null means "no expiry", which is how most links are made.
-- ============================================================================
alter table public.share_links
  add constraint share_links_expiry_range
    check (
      expires_at is null
        or (expires_at >= timestamptz '0100-01-01 00:00:00+00'
            and expires_at < timestamptz '10000-01-01 00:00:00+00')
    );

commit;
