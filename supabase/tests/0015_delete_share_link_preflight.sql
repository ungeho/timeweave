-- ============================================================================
-- TimeWeave -- PREFLIGHT for 0015_delete_share_link_rpc.sql (M-E).
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run by hand, once, against the project
-- 0015 will be applied to, BEFORE applying it.
--
-- READ-ONLY: no DDL, no DML, no SET, no temp table, no function creation, no
-- VACUUM, no ANALYZE. One statement inside a read-only transaction that ends in
-- ROLLBACK. It reads the system catalogs and counts rows; it changes nothing.
--
-- WHAT IT GATES. 0015 adds public.delete_share_link(uuid) and nothing else. It
-- is safe to apply only if production still looks the way the design assumed:
--
--   A. the function does not exist yet, under any signature      -> A01-A03
--   B. share_links still has NO table privileges, and in          -> B01-B06
--      particular no DELETE for anon or authenticated, so the
--      function will be the only delete path
--   C. RLS is on and the owner-only policy is the one 0004 made   -> C01-C05
--   D. revoke_share_link is exactly the contract 0015 copies      -> D01-D07
--      (DEFINER, pinned search_path, EXECUTE to authenticated
--      and not to anon)
--   E. nothing else can interfere with a DELETE: no FK pointing   -> E01-E03
--      at the table, no trigger on it
--   F. 0014's three CHECKs are present and validated              -> F01-F03
--   G. minimal data context for the lifecycle the RPC serves      -> G01-G03
--
-- A FAIL anywhere means the premise 0015 was written against no longer holds,
-- so the migration must be re-reviewed rather than applied.
--
-- PRIVACY. Catalog metadata and counts only. It never returns a token, a
-- token_hash, a label, an id, an owner_id or any timestamp from a row. The
-- policy expression, the function ACLs and the constraint definitions are
-- schema text, not user data. No pseudonyms are needed because no row is
-- identified at all.
--
-- WHY has_table_privilege / has_function_privilege AND NOT ONLY
-- information_schema: the information_schema views are filtered by the roles
-- enabled for the caller, so a missing row there is not proof that a privilege
-- is absent. has_*_privilege() answers the actual question -- "could this role
-- do this?" -- including privileges inherited through PUBLIC or role
-- membership. The raw relacl is shown alongside as context.
--
-- READING THE OUTPUT. status is 'ok' / 'FAIL' where an expectation exists and
-- 'context' where the value is a measurement. P00 summarises.
-- ============================================================================
begin transaction read only;

with res as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL'
         end as status
  from (values

    -- A. 0015 has not been applied yet.
    ('A01', 'target', 'public.delete_share_link(uuid) exists', '0',
     (case when to_regprocedure('public.delete_share_link(uuid)') is null
           then '0' else '1' end)),
    ('A02', 'target', 'any function named delete_share_link in public', '0',
     (select count(*) from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'delete_share_link')::text),
    ('A03', 'target', 'functions named delete_share_link in ANY schema', '0',
     (select count(*) from pg_proc p where p.proname = 'delete_share_link')::text),

    -- B. no table privileges: the function must be the only delete path.
    ('B01', 'grants', 'authenticated has DELETE on public.share_links', 'false',
     has_table_privilege('authenticated', 'public.share_links', 'DELETE')::text),
    ('B02', 'grants', 'anon has DELETE on public.share_links', 'false',
     has_table_privilege('anon', 'public.share_links', 'DELETE')::text),
    ('B03', 'grants', 'authenticated holds ANY of S/I/U/D/TRUNCATE', 'false',
     (has_table_privilege('authenticated', 'public.share_links', 'SELECT')
      or has_table_privilege('authenticated', 'public.share_links', 'INSERT')
      or has_table_privilege('authenticated', 'public.share_links', 'UPDATE')
      or has_table_privilege('authenticated', 'public.share_links', 'DELETE')
      or has_table_privilege('authenticated', 'public.share_links', 'TRUNCATE'))::text),
    ('B04', 'grants', 'anon holds ANY of S/I/U/D/TRUNCATE', 'false',
     (has_table_privilege('anon', 'public.share_links', 'SELECT')
      or has_table_privilege('anon', 'public.share_links', 'INSERT')
      or has_table_privilege('anon', 'public.share_links', 'UPDATE')
      or has_table_privilege('anon', 'public.share_links', 'DELETE')
      or has_table_privilege('anon', 'public.share_links', 'TRUNCATE'))::text),
    ('B05', 'grants', 'anon/authenticated grant rows in information_schema', '0',
     (select count(*) from information_schema.role_table_grants
       where table_schema = 'public' and table_name = 'share_links'
         and grantee in ('anon', 'authenticated'))::text),
    ('B06', 'grants', 'raw relacl on public.share_links', null,
     (select coalesce(array_to_string(c.relacl, ' '), '(null = owner only)')
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = 'share_links')),

    -- C. RLS and the owner-only policy 0004 created.
    ('C01', 'rls', 'row level security enabled', 'true',
     (select c.relrowsecurity::text
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = 'share_links')),
    ('C02', 'rls', 'policies on public.share_links', '1',
     (select count(*) from pg_policies
       where schemaname = 'public' and tablename = 'share_links')::text),
    ('C03', 'rls', 'share_links_owner_all exists', '1',
     (select count(*) from pg_policies
       where schemaname = 'public' and tablename = 'share_links'
         and policyname = 'share_links_owner_all')::text),
    ('C04', 'rls', 'share_links_owner_all cmd / roles', null,
     (select p.cmd || ' to ' || array_to_string(p.roles, ',')
        from pg_policies p
       where p.schemaname = 'public' and p.tablename = 'share_links'
         and p.policyname = 'share_links_owner_all')),
    ('C05', 'rls', 'share_links_owner_all using / with check', null,
     (select 'USING ' || coalesce(p.qual, '(none)')
                     || ' | CHECK ' || coalesce(p.with_check, '(none)')
        from pg_policies p
       where p.schemaname = 'public' and p.tablename = 'share_links'
         and p.policyname = 'share_links_owner_all')),

    -- D. revoke_share_link: the contract 0015 copies verbatim.
    ('D01', 'revoke', 'public.revoke_share_link(uuid) exists', '1',
     (case when to_regprocedure('public.revoke_share_link(uuid)') is null
           then '0' else '1' end)),
    ('D02', 'revoke', 'it is SECURITY DEFINER', 'true',
     (select p.prosecdef::text from pg_proc p
       where p.oid = to_regprocedure('public.revoke_share_link(uuid)'))),
    ('D03', 'revoke', 'its proconfig', 'search_path=""',
     (select coalesce(array_to_string(p.proconfig, ','), '(none)') from pg_proc p
       where p.oid = to_regprocedure('public.revoke_share_link(uuid)'))),
    ('D04', 'revoke', 'authenticated may EXECUTE it', 'true',
     has_function_privilege('authenticated', 'public.revoke_share_link(uuid)', 'EXECUTE')::text),
    ('D05', 'revoke', 'anon may EXECUTE it', 'false',
     has_function_privilege('anon', 'public.revoke_share_link(uuid)', 'EXECUTE')::text),
    ('D06', 'revoke', 'its raw proacl', null,
     (select coalesce(array_to_string(p.proacl, ' '), '(null = default PUBLIC)')
        from pg_proc p
       where p.oid = to_regprocedure('public.revoke_share_link(uuid)'))),
    ('D07', 'revoke', '0005 RPCs that are DEFINER with pinned search_path', '4',
     (select count(*) from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname in ('create_share_link', 'list_share_links',
                           'revoke_share_link', 'get_free_busy')
         and p.prosecdef
         and array_to_string(p.proconfig, ',') = 'search_path=""')::text),

    -- E. nothing else participates in a DELETE on this table.
    ('E01', 'shape', 'foreign keys REFERENCING public.share_links', '0',
     (select count(*) from pg_constraint
       where contype = 'f' and confrelid = 'public.share_links'::regclass)::text),
    ('E02', 'shape', 'user triggers on public.share_links', '0',
     (select count(*) from pg_trigger
       where tgrelid = 'public.share_links'::regclass and not tgisinternal)::text),
    ('E03', 'shape', 'rules on public.share_links other than the default view', '0',
     (select count(*) from pg_rewrite
       where ev_class = 'public.share_links'::regclass and rulename <> '_RETURN')::text),

    -- F. 0014 is in place and validated.
    ('F01', 'checks', 'the 3 M-C CHECK constraints present', '3',
     (select count(*) from pg_constraint
       where conrelid = 'public.share_links'::regclass and contype = 'c'
         and conname in ('share_links_label_len',
                         'share_links_expiry_after_created',
                         'share_links_expiry_range'))::text),
    ('F02', 'checks', 'those 3 are convalidated', '3',
     (select count(*) from pg_constraint
       where conrelid = 'public.share_links'::regclass and contype = 'c'
         and convalidated
         and conname in ('share_links_label_len',
                         'share_links_expiry_after_created',
                         'share_links_expiry_range'))::text),
    ('F03', 'checks', 'total CHECK constraints on the table', null,
     (select count(*) from pg_constraint
       where conrelid = 'public.share_links'::regclass and contype = 'c')::text),

    -- G. minimal data context. Counts only; no row is identified.
    ('G01', 'data', 'share_links rows', null,
     (select count(*) from public.share_links)::text),
    ('G02', 'data', 'revoked rows (what delete_share_link may remove)', null,
     (select count(*) from public.share_links where revoked_at is not null)::text),
    ('G03', 'data', 'rows never revoked (out of reach of the RPC)', null,
     (select count(*) from public.share_links where revoked_at is null)::text)

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
