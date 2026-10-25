-- ============================================================================
-- P8 RELEASE PREFLIGHT, STAGE A1c (1 of 2) -- ONE ZONE CHECK, TIMED. READ ONLY.
-- SEPARATE APPROVAL (A1c covers this file and P8_preflight_A1c2_zone_scan.sql).
-- ============================================================================
-- WHY EXPLAIN ANALYZE. Timing with clock_timestamp() around the call inside one
-- SELECT is not reliable (the planner runs the call as an InitPlan; on the
-- isolated database it reported 0.0 ms for a 110-145 ms call). EXPLAIN ANALYZE
-- times exactly the statement it runs; it agreed with psql \timing.
--
-- HOW TO RUN. This file is ONE unit: the two settings, the gate, the measured
-- statement. Run the whole file as one execution (SQL Editor: run all; psql:
-- psql -X -1 -v ON_ERROR_STOP=1 -f <this file>) -- only after A1a passed its
-- gate in the same editor. Run it TWICE and keep both "Execution Time" and
-- "Planning Time": the first run of a session can be slower (cold file cache:
-- 564 ms vs 120 ms on the isolated database); the second is the steady cost.
-- The gate guarantees that THIS measurement ran read-only with a 10 s limit:
-- if either setting is not in effect it stops before the EXPLAIN.
--
-- READ ONLY: timezone_is_supported is STABLE, INVOKER, SQL, without writes;
-- A1a F02 checks it is the reviewed body.
-- READING: the cost of ONE zone check, paid per timed recurring row written
-- (0008 trigger) and twice per distinct zone per anonymous share request.
-- >= 5 ms makes K15 serious. After 0028 it should be well under 1 ms.
-- ============================================================================
set transaction read only;
set local statement_timeout = '10s';
select case when current_setting('transaction_read_only') = 'on' and current_setting('statement_timeout') = '10s'
            then 'gate: read only, 10s'
            else ('STOPPED: read_only=' || current_setting('transaction_read_only') || ', statement_timeout=' || current_setting('statement_timeout'))::int::text end as gate;
explain (analyze, costs off, summary on) select public.timezone_is_supported('Asia/Tokyo');
