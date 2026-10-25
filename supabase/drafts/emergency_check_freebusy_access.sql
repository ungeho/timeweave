-- ============================================================================
-- EMERGENCY CHECK -- READ ONLY. Who can call public.get_free_busy, and how.
-- Run BEFORE an emergency stop (save the output: it is the state a restore must
-- return to), AFTER it (the stopped roles must show effective = false), and
-- AFTER a restore (must match the saved output).
-- ============================================================================
set transaction read only;
set local statement_timeout = '10s';
with f as (select to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)') as oid),
acl as (select a.* from pg_catalog.pg_proc p, f, pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) a
        where p.oid = f.oid and a.privilege_type = 'EXECUTE')
select r.rolname as role,
       exists (select 1 from acl where acl.grantee = r.oid) as direct_grant,
       exists (select 1 from acl where acl.grantee = 0) as via_public,
       coalesce((select string_agg(g.rolname, ',') from pg_catalog.pg_auth_members m join pg_catalog.pg_roles g on g.oid = m.roleid
                 where m.member = r.oid and pg_catalog.has_function_privilege(g.oid, (select oid from f), 'EXECUTE')), '') as via_membership,
       pg_catalog.has_function_privilege(r.oid, (select oid from f), 'EXECUTE') as effective,
       -- the ACL as a sorted list of grantee:EXECUTE[*]: the raw aclitem[] text
       -- changes ORDER when a grant is removed and re-added, the entries do not
       (select string_agg(e, ',' order by e) from (
          select case when acl.grantee = 0 then 'PUBLIC' else pg_catalog.pg_get_userbyid(acl.grantee) end
                 || case when acl.is_grantable then '*' else '' end as e from acl) s) as execute_acl,
       current_setting('transaction_read_only') as read_only
from pg_catalog.pg_roles r
where r.rolname in ('anon', 'authenticated')
order by 1;
