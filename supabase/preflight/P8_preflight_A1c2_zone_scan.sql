-- ============================================================================
-- P8 RELEASE PREFLIGHT, STAGE A1c (2 of 2) -- ONE SCAN OF THE ZONE LIST, TIMED.
-- READ ONLY. Same approval and same way of running as A1c (1 of 2):
-- one execution of the whole file (psql: psql -X -1 -v ON_ERROR_STOP=1 -f <file>).
-- The gate stops the run before the EXPLAIN unless read-only and the 10 s limit
-- are in effect for this unit.
-- READING: what each zone check scans (pg_timezone_names, a catalog function
-- that reads every zone file).
-- ============================================================================
set transaction read only;
set local statement_timeout = '10s';
select case when current_setting('transaction_read_only') = 'on' and current_setting('statement_timeout') = '10s'
            then 'gate: read only, 10s'
            else ('STOPPED: read_only=' || current_setting('transaction_read_only') || ', statement_timeout=' || current_setting('statement_timeout'))::int::text end as gate;
explain (analyze, costs off, summary on) select count(*) from pg_catalog.pg_timezone_names;
