-- ============================================================================
-- P8 RELEASE PREFLIGHT, STAGE A1d -- RRULE TEXT. READ ONLY. SEPARATE APPROVAL.
-- ============================================================================
-- Prints the rrule TEXT (no owner, no title, no id) of the recurring masters
-- that the client or the draft 0029 check would not accept, with how many rows
-- carry each, so they can be checked against the client parser locally. This
-- reads part of the users' data (their repeat rules), which is why it is its
-- own approval. Run A1b first: if its D03-D06 are all 0, there is nothing to list.
-- Same cost as A1b's D03 (one scan, one rrule_parse per master).
-- ============================================================================
set transaction read only;
set local statement_timeout = '30s';
-- GATE: stops the run here, before reading any rule, unless both lines above
-- are in effect. HOW TO RUN: one execution of the whole file, after A1a passed
-- its gate in the same editor (psql: psql -X -1 -v ON_ERROR_STOP=1 -f <file>).
select case when current_setting('transaction_read_only') = 'on' and current_setting('statement_timeout') = '30s'
            then 'gate: read only, 30s'
            else ('STOPPED: read_only=' || current_setting('transaction_read_only') || ', statement_timeout=' || current_setting('statement_timeout'))::int::text end as gate;
select e.rrule, e.all_day, count(*) as rows
from public.events e
where e.rrule is not null
  and not exists (
        select 1 from public.rrule_parse(e.rrule) p
        where p.status = 'ok'
          and e.rrule ~ '^FREQ=(DAILY|WEEKLY|MONTHLY)(;INTERVAL=[1-9][0-9]{0,3})?(;BYDAY=(MO|TU|WE|TH|FR|SA|SU)(,(MO|TU|WE|TH|FR|SA|SU)){0,6})?(;COUNT=[1-9][0-9]{0,6}|;UNTIL=[0-9]{8}(T[0-9]{6}Z)?)?$'
          and case when e.all_day then p.until_ts is null else p.until_date is null end)
group by 1, 2
order by 3 desc
limit 200;
