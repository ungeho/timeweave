-- ============================================================================
-- TimeWeave -- BEHAVIOURAL TEST for 0012_event_write_rate_limit.sql.
--
-- Run AFTER the postflight. Asserts what the limiter DOES; the postflight
-- asserts what it IS.
--
-- ############################################################################
-- THIS FILE WRITES, AND THEN UNWRITES. READ THIS BEFORE RUNNING IT.
--
--   * It is one transaction ending in ROLLBACK. Every row it inserts into
--     public.events, and every change it makes to the rate state, disappears.
--   * It uses a REAL account -- the oldest row in auth.users -- because the
--     state table has a foreign key to auth.users and a synthetic uuid would be
--     refused. Nothing about that account is read except its id.
--   * It DELETES that account's rate-state row at the start so the arithmetic
--     below starts from a known bucket. That delete is rolled back with
--     everything else, but while the test runs it HOLDS A ROW LOCK on that
--     owner's state row: any real write by that account will WAIT until this
--     transaction ends. The test takes well under a second; still, prefer to run
--     it while that account is idle.
--   * It impersonates `authenticated` for the charged sections. Following the
--     rule the P1 probe taught: while impersonating, this file writes NOTHING
--     of its own -- observations are carried out on transaction-local GUCs and
--     recorded after the role is restored. Granting the harness a privilege to
--     make the recording work would change the very posture under test.
-- ############################################################################
--
-- WHAT IS ASSERTED, AND WHY EACH ONE EARNS ITS PLACE
--
--   10  the exempt path charges nothing. If this breaks, every migration and
--       every support action starts consuming the account's budget.
--   20  a charged statement creates the bucket, and the arithmetic is exactly
--       cost * T. A single multi-row INSERT is used deliberately: one statement
--       means one statement_timestamp, so the expected tat is exact rather than
--       approximately right.
--   21  cost is ROWS, not statements -- three rows in one statement cost three.
--   30  UPDATE is charged, including an update to identical values. That is the
--       flow 0011's quota cannot see at all.
--   40  an UPDATE matching no rows costs nothing. The trigger still fires; the
--       transition table is empty; the loop does not run.
--   50  a statement larger than the burst is refused from ANY state, with
--       SQLSTATE PT429 and the stable token in DETAIL. Timing-independent by
--       construction: cost > burst can never fit under tau.
--   51  the refusal carries a parseable backoff in HINT.
--   52  THE REFUSED WORK IS NOT CHARGED. The upsert had already incremented the
--       bucket when the RAISE fired; the subtransaction rollback must have taken
--       that increment with it. This is the property that makes "refused" honest
--       rather than punitive, and it is the one a careless rewrite would lose.
--
-- NOT TESTED HERE, DELIBERATELY:
--   * the burst boundary itself (exactly N accepted, N+1 refused). It was
--     measured end to end under real concurrency -- 100 simultaneous requests,
--     exactly 20 accepted at burst 20 -- and reproducing it here would make the
--     result depend on how long the test takes to run, since tokens regenerate
--     at 1/T. Check 50 pins the same refusal path without that dependency.
--   * multi-owner statements. Under RLS a charged statement can only touch its
--     own rows, so the per-owner loop runs exactly once on every path a client
--     can reach. The loop and its ascending key order exist for a definer path
--     that does not exist yet.
-- ============================================================================

begin;

create temp table zz_test_out (ord int primary key, name text, got text, want text);

-- ---------------------------------------------------------------- preconditions
do $$
declare
  v_owner uuid;
begin
  select u.id into v_owner from auth.users u order by u.created_at limit 1;
  if v_owner is null then
    raise exception 'this test needs at least one row in auth.users'
      using hint = 'nothing has been written; the transaction will roll back';
  end if;
  perform set_config('zz.owner', v_owner::text, true);
end;
$$;

insert into zz_test_out values
  (1, 'parameter T',     public.events_rate_interval()::text, '00:00:01'),
  (2, 'parameter burst', public.events_rate_burst()::text,    '120');

-- Start from a known bucket. Rolled back with everything else.
delete from timeweave_private.event_write_rate
 where owner_id = current_setting('zz.owner')::uuid;

-- ---------------------------------------------------------------- 10 exempt
-- Run as the session role: auth.uid() is NULL, so the trigger returns before
-- touching the state at all.
insert into public.events (owner_id, title, all_day, start_date, end_date)
values (current_setting('zz.owner')::uuid, 'zz rate test exempt', true,
        date '2031-01-01', date '2031-01-02');

insert into zz_test_out values
  (10, 'exempt path (auth.uid() null) created no state row',
   (select count(*)::text from timeweave_private.event_write_rate
     where owner_id = current_setting('zz.owner')::uuid), '0');

-- ---------------------------------------------------------------- 20/21 charge
-- Become the owner, as PostgREST would. set_config rather than SET LOCAL,
-- because SET takes a literal and the subject has to be computed.
select set_config('request.jwt.claims',
                  json_build_object('sub',  current_setting('zz.owner'),
                                    'role', 'authenticated')::text,
                  true);
set local role authenticated;

-- ONE statement, three rows.
insert into public.events (owner_id, title, all_day, start_date, end_date)
values (current_setting('zz.owner')::uuid, 'zz rate test A', true, date '2031-02-01', date '2031-02-02'),
       (current_setting('zz.owner')::uuid, 'zz rate test B', true, date '2031-02-03', date '2031-02-04'),
       (current_setting('zz.owner')::uuid, 'zz rate test C', true, date '2031-02-05', date '2031-02-06');

reset role;

insert into zz_test_out values
  (20, 'a charged statement created the bucket',
   (select count(*)::text from timeweave_private.event_write_rate
     where owner_id = current_setting('zz.owner')::uuid), '1'),
  (21, 'cost is rows, not statements: 3 rows charged 3',
   (select charged_rows::text from timeweave_private.event_write_rate
     where owner_id = current_setting('zz.owner')::uuid), '3'),
  -- Compared as a NUMBER, not as text. extract(epoch from interval) returns
  -- numeric on PostgreSQL 14+, whose text form keeps its scale -- '3.000000',
  -- not '3' -- so a text comparison here would fail against a perfectly correct
  -- three-second debt. The P3 probe lost a round trip to the same class of
  -- mistake (an interval compared against a literal '20:00:00').
  (22, 'debt after that statement is exactly cost * T = 3 s',
   (select (extract(epoch from (tat - last_charge_at)) = 3)::text
      from timeweave_private.event_write_rate
     where owner_id = current_setting('zz.owner')::uuid), 'true');

-- ---------------------------------------------------------------- 30 update
select set_config('request.jwt.claims',
                  json_build_object('sub',  current_setting('zz.owner'),
                                    'role', 'authenticated')::text,
                  true);
set local role authenticated;

-- Identical values on purpose: a no-op UPDATE is still a row version, still
-- WAL, still work. Measured to appear in NEW TABLE.
update public.events set title = title
 where owner_id = current_setting('zz.owner')::uuid
   and title in ('zz rate test A', 'zz rate test B');

reset role;

insert into zz_test_out values
  (30, 'UPDATE is charged, including an update to identical values (3 + 2)',
   (select charged_rows::text from timeweave_private.event_write_rate
     where owner_id = current_setting('zz.owner')::uuid), '5');

-- ---------------------------------------------------------------- 40 zero rows
select set_config('request.jwt.claims',
                  json_build_object('sub',  current_setting('zz.owner'),
                                    'role', 'authenticated')::text,
                  true);
set local role authenticated;

update public.events set title = title
 where owner_id = current_setting('zz.owner')::uuid
   and title = 'zz rate test NO SUCH ROW';

reset role;

insert into zz_test_out values
  (40, 'an UPDATE matching no rows charges nothing (still 5)',
   (select charged_rows::text from timeweave_private.event_write_rate
     where owner_id = current_setting('zz.owner')::uuid), '5');

-- ---------------------------------------------------------------- 50/51/52
-- One statement of burst + 1 rows. cost > burst cannot fit under tau from any
-- state, so this is a refusal with no dependence on how long the test has taken.
--
-- The failing INSERT sits in its own BEGIN/EXCEPTION block so that only IT is
-- rolled back -- wrapping the whole section would also undo the five charges
-- above and check 52 would prove nothing.
select set_config('request.jwt.claims',
                  json_build_object('sub',  current_setting('zz.owner'),
                                    'role', 'authenticated')::text,
                  true);
set local role authenticated;

do $$
declare
  v_state  text;
  v_detail text;
  v_hint   text;
begin
  begin
    insert into public.events (owner_id, title, all_day, start_date, end_date)
    select current_setting('zz.owner')::uuid,
           'zz rate test burst',
           true,
           date '2031-06-01' + g,
           date '2031-06-02' + g
    from generate_series(1, public.events_rate_burst() + 1) g;

    v_state  := '<accepted>';
    v_detail := '<accepted>';
    v_hint   := '<accepted>';
  exception when others then
    get stacked diagnostics
      v_state  = returned_sqlstate,
      v_detail = pg_exception_detail,
      v_hint   = pg_exception_hint;
  end;

  -- No table write here: still impersonating. See the banner at the top.
  perform set_config('zz.state',  v_state,  true);
  perform set_config('zz.detail', v_detail, true);
  perform set_config('zz.hint',   v_hint,   true);
end;
$$;

reset role;

insert into zz_test_out values
  (50, 'a statement of burst + 1 rows is refused with PT429',
   current_setting('zz.state', true), 'PT429'),
  (51, 'the refusal carries the stable token in DETAIL',
   current_setting('zz.detail', true), 'TIMEWEAVE_RATE_EVENTS'),
  (52, 'the refusal carries a parseable backoff in HINT',
   (current_setting('zz.hint', true) ~ '^retry_after_seconds=[0-9]+$')::text, 'true'),
  (53, 'REFUSED WORK IS NOT CHARGED: the bucket is still at 5',
   (select charged_rows::text from timeweave_private.event_write_rate
     where owner_id = current_setting('zz.owner')::uuid), '5'),
  (54, 'and no row of the refused statement survived',
   (select count(*)::text from public.events
     where owner_id = current_setting('zz.owner')::uuid
       and title = 'zz rate test burst'), '0');

-- ---------------------------------------------------------------- result
select ord, name, got, want,
       case when got is not distinct from want then 'ok' else 'FAIL' end as verdict
from zz_test_out
order by ord;

rollback;

-- ############################################################################
-- AFTER THE ROLLBACK, CONFIRM THE DATABASE IS WHERE IT STARTED:
--
--   select count(*) from public.events where title like 'zz rate test%';
--   -- must be 0
--
--   select owner_id, charged_rows, tat
--   from timeweave_private.event_write_rate;
--   -- must be exactly what it was before this file ran (the test's delete,
--   --  its charges and its refusal all rolled back together)
-- ############################################################################
