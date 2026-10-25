-- ============================================================================
-- TimeWeave -- STATE CHECK for 0019_freebusy_rate_limit.sql (A2).
--
-- WHY THIS FILE EXISTS. An apply can end with the outcome UNKNOWN: the client
-- gave up (timeout, lost connection) while the server was still working. Both
-- endings were measured locally against the same injected lock -- once the
-- server took the lock afterwards and COMMITTED the whole migration, once it
-- did not. So "the client timed out" says nothing about the database, and a
-- second apply must never be the way to find out.
--
-- This file is that way to find out. It answers ONE question from the catalog:
--
--   fully_applied          every object 0019 creates is there, with the
--                          attributes 0019 gives it, and get_free_busy is the
--                          0019 wrapper
--   not_applied            none of it is there and get_free_busy is still the
--                          0018 body
--   partial_or_inconsistent  some of it is there, or something is there with
--                          the wrong shape -- NEVER a success
--   indeterminate          the catalog cannot decide (get_free_busy missing,
--                          overloaded, or a body that is neither 0018 nor
--                          0019) -- NEVER a success
--
-- IT IS NOT THE POSTFLIGHT. It decides which state the database is in; the
-- postflight is what verifies the applied state in full (107 checks, the
-- baselines carried over from the preflight). Reaching fully_applied here is
-- a licence to run the postflight, not a substitute for it.
--
-- READ-ONLY AND PARSE-SAFE. Catalog inspection only: no DDL, no DML, no SET,
-- no temp table, no advisory lock, no RPC call, and -- deliberately -- not one
-- read of the two rate tables, so this file parses and reports whether or not
-- 0019 exists. It calls no project function either; the deployed limits are
-- read out of prosrc. One statement inside a read-only transaction that ends
-- in ROLLBACK, so it can leave nothing behind, not even rate state.
--
-- NO PRODUCTION-ONLY CONSTANT. Every expectation here is derived from the
-- frozen files (body md5s, literals, ACL shapes), not from a fingerprint of
-- one particular database. The same file therefore decides the same way on a
-- local rebuild, which is how its four verdicts are tested.
--
--   V. context     server, role                                        V01-V03
--   I. invariants  what must hold in ANY state; a FAIL here is what     I01-I05
--                  makes the verdict 'indeterminate'
--   O. objects     what is actually present, and with which shape       O01-O18
--   Z. verdict     the classification and the two conjunctions it       Z00-Z04
--                  is built from
--
-- READING THE OUTPUT. Z00 carries the verdict. P00 counts the FAILs among the
-- invariants. status 'ok' / 'FAIL' where an expectation exists, 'context'
-- otherwise: most O rows are evidence, not expectations, because their
-- expected value depends on the state being diagnosed.
--
-- Body fingerprints are md5 of prosrc with CR removed:
--   0018 get_free_busy  17f05831c60abd63a652c0a9d691b94c
--   0019 get_free_busy  162c218d890630c6478c6e26638c2ca9
--   0019 free_busy_core a7558dfa02a4ce6444d538e370eb631d
--
-- PRIVACY. Counts, catalog text, ACLs and hashes only. No title, description,
-- label, token, row id or owner id is ever returned.
-- ============================================================================
begin transaction read only;

with
fn as (
  select n.nspname as nsp, p.proname, p.oid, p.proowner,
         pg_catalog.pg_get_function_identity_arguments(p.oid) as args,
         p.prosecdef, p.provolatile, p.proconfig, p.proacl, l.lanname,
         md5(replace(p.prosrc, E'\r', '')) as h, p.prosrc
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  join pg_catalog.pg_language l on l.oid = p.prolang
  where n.nspname not in ('pg_catalog', 'information_schema')
    and n.nspname not like 'pg\_%'
),
gfb as (select * from fn where oid = to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)')),
cor as (select * from fn where oid = to_regprocedure('timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')),
par as (select * from fn where nsp = 'timeweave_private'
          and proname in ('freebusy_link_rate_interval', 'freebusy_link_rate_burst',
                          'freebusy_owner_rate_interval', 'freebusy_owner_rate_burst',
                          'freebusy_concurrency_slots')),
tp as (select n.oid, n.nspowner from pg_catalog.pg_namespace n where n.nspname = 'timeweave_private'),
rel as (
  select n.nspname as nsp, c.relname, c.oid, c.relkind, c.relrowsecurity, c.relacl, c.relowner, c.reloptions
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'timeweave_private'
),
own_rate as (select * from rel where relname = 'freebusy_owner_rate' and relkind::text = 'r'),
lnk_rate as (select * from rel where relname = 'freebusy_link_rate' and relkind::text = 'r'),
cols as (
  select a.attrelid,
         string_agg(a.attname || ' ' || pg_catalog.format_type(a.atttypid, a.atttypmod), ',' order by a.attnum) as def,
         count(*) filter (where a.attnotnull) as nn, count(*) as n
  from pg_catalog.pg_attribute a
  where a.attrelid in (select oid from own_rate union all select oid from lnk_rate)
    and a.attnum > 0 and not a.attisdropped
  group by a.attrelid
),
cons as (
  select k.conrelid, k.contype,
         string_agg(replace(pg_catalog.pg_get_constraintdef(k.oid), 'public.', ''), ';' order by k.conname collate "C") as def
  from pg_catalog.pg_constraint k
  where k.conrelid in (select oid from own_rate union all select oid from lnk_rate)
  group by k.conrelid, k.contype
),
-- The deployed limits, read from source (no call, so this parses when absent).
pv as (
  select
    max(case when proname = 'freebusy_link_rate_interval'  then (regexp_match(prosrc, 'interval\s+''([^'']+)'''))[1] end) as link_t,
    max(case when proname = 'freebusy_owner_rate_interval' then (regexp_match(prosrc, 'interval\s+''([^'']+)'''))[1] end) as owner_t,
    max(case when proname = 'freebusy_link_rate_burst'     then (regexp_match(prosrc, 'select\s+([0-9]+)'))[1] end) as link_b,
    max(case when proname = 'freebusy_owner_rate_burst'    then (regexp_match(prosrc, 'select\s+([0-9]+)'))[1] end) as owner_b,
    max(case when proname = 'freebusy_concurrency_slots'   then (regexp_match(prosrc, 'select\s+([0-9]+)'))[1] end) as k
  from par
),
ev as (
  select
    (select count(*) from own_rate) + (select count(*) from lnk_rate) as n_tables,
    (select count(*) from par) as n_params,
    (select count(*) from cor) as n_core,
    (select count(*) from fn where nsp = 'public' and proname = 'get_free_busy') as n_wrapper,
    (select h from gfb) as w_md5,
    (select provolatile::text from gfb) as w_vol,
    (select prosecdef::text from gfb) as w_secdef,
    (select array_to_string(proconfig, ',') from gfb) as w_cfg,
    (select args from gfb) as w_args,
    (select h from cor) as c_md5,
    -- table shape, both tables
    (select count(*) = 2 from (select oid from own_rate union all select oid from lnk_rate) q) as t_both,
    (select (select def from cols where attrelid = (select oid from own_rate)) = 'owner_id uuid,tat timestamp with time zone,charged_calls bigint,last_charge_at timestamp with time zone'
        and (select def from cols where attrelid = (select oid from lnk_rate)) = 'link_id uuid,tat timestamp with time zone,charged_calls bigint,last_charge_at timestamp with time zone'
        and (select nn = 4 and n = 4 from cols where attrelid = (select oid from own_rate))
        and (select nn = 4 and n = 4 from cols where attrelid = (select oid from lnk_rate))) as t_cols,
    (select (select def from cons where conrelid = (select oid from own_rate) and contype = 'p') = 'PRIMARY KEY (owner_id)'
        and (select def from cons where conrelid = (select oid from lnk_rate) and contype = 'p') = 'PRIMARY KEY (link_id)'
        and (select def from cons where conrelid = (select oid from own_rate) and contype = 'f') = 'FOREIGN KEY (owner_id) REFERENCES auth.users(id) ON DELETE CASCADE'
        and (select def from cons where conrelid = (select oid from lnk_rate) and contype = 'f') = 'FOREIGN KEY (link_id) REFERENCES share_links(id) ON DELETE CASCADE') as t_keys,
    (select bool_and(relrowsecurity) from (select relrowsecurity from own_rate union all select relrowsecurity from lnk_rate) q) as t_rls,
    (select count(*) = 0 from pg_catalog.pg_policy p
      where p.polrelid in (select oid from own_rate union all select oid from lnk_rate)) as t_nopolicy,
    (select bool_and(coalesce(array_to_string(relacl, ' '), '-') = 'postgres=arwdDxtm/postgres')
       from (select relacl from own_rate union all select relacl from lnk_rate) q) as t_acl,
    (select bool_and(coalesce(reloptions::text, '-') = '{fillfactor=70}')
       from (select reloptions from own_rate union all select reloptions from lnk_rate) q) as t_fill,
    (select count(*) = 0 from rel r, pg_catalog.aclexplode(r.relacl) a
      where r.oid in (select oid from own_rate union all select oid from lnk_rate)
        and a.grantee in ('anon'::regrole::oid, 'authenticated'::regrole::oid, 'service_role'::regrole::oid)) as t_private,
    -- function shape
    (select count(*) = 5 and bool_and(provolatile::text = 'i') and bool_and(prosecdef = false)
        and bool_and(array_to_string(proconfig, ',') = 'search_path=""') and bool_and(lanname::text = 'sql')
        and bool_and(coalesce(array_to_string(proacl, ' '), '-') = 'postgres=X/postgres') from par) as f_params,
    (select count(*) = 1 and bool_and(provolatile::text = 's') and bool_and(prosecdef = false)
        and bool_and(array_to_string(proconfig, ',') = 'search_path=""') and bool_and(lanname::text = 'plpgsql')
        and bool_and(coalesce(array_to_string(proacl, ' '), '-') = 'postgres=X/postgres') from cor) as f_core,
    (select (link_t = '2 seconds' and owner_t = '1 second' and link_b = '15' and owner_b = '40' and k = '2') from pv) as f_limits,
    (select pg_catalog.has_function_privilege('anon', oid, 'EXECUTE')
        and pg_catalog.has_function_privilege('authenticated', oid, 'EXECUTE')
        and not (proacl is null or exists (select 1 from pg_catalog.aclexplode(proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
       from gfb) as w_grants,
    (select count(*) = 0 from par p, pg_catalog.aclexplode(p.proacl) a
      where a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner) as f_params_private,
    (select count(*) = 0 from cor p, pg_catalog.aclexplode(p.proacl) a
      where a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner) as f_core_private
  from (select 1) _
),
verdict as (
  select e.*,
    case when e.w_md5 = '162c218d890630c6478c6e26638c2ca9' then '0019'
         when e.w_md5 = '17f05831c60abd63a652c0a9d691b94c' then '0018'
         else 'unknown' end as w_kind,
    -- The same conditions the I rows assert. If any of them fails the catalog
    -- is not describing a database this file can classify, whatever else is
    -- present: an extra overload, a changed signature or a lost DEFINER means
    -- indeterminate, never 'not_applied'.
    ((select count(*) from tp) = 1 and e.n_wrapper = 1
      and e.w_args = 'p_token text, p_from timestamp with time zone, p_to timestamp with time zone, p_from_date date, p_to_date date'
      and e.w_secdef = 'true' and e.w_cfg = 'search_path=""'
      and e.w_md5 in ('162c218d890630c6478c6e26638c2ca9', '17f05831c60abd63a652c0a9d691b94c')) as inv_ok,
    (e.n_tables = 2 and e.n_params = 5 and e.n_core = 1
      and e.w_md5 = '162c218d890630c6478c6e26638c2ca9' and e.w_vol = 'v' and e.w_secdef = 'true'
      and e.w_cfg = 'search_path=""' and e.w_grants
      and e.c_md5 = 'a7558dfa02a4ce6444d538e370eb631d'
      and e.t_both and e.t_cols and e.t_keys and e.t_rls and e.t_nopolicy and e.t_acl and e.t_fill and e.t_private
      and e.f_params and e.f_core and e.f_limits and e.f_params_private and e.f_core_private) as full_ok,
    (e.n_tables = 0 and e.n_params = 0 and e.n_core = 0
      and e.w_md5 = '17f05831c60abd63a652c0a9d691b94c' and e.w_vol = 's') as none_ok
  from ev e
),
res as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL'
         end as status
  from (values

    -- V. context.
    ('V01', 'context', 'server version', null, (select pg_catalog.version())),
    ('V02', 'context', 'role running this state check', null, current_user::text),
    ('V03', 'context', 'this transaction is read only', 'on', current_setting('transaction_read_only')),

    -- I. invariants: a FAIL here means the catalog cannot decide (indeterminate).
    ('I01', 'invariant', 'timeweave_private exists', '1', (select count(*) from tp)::text),
    ('I02', 'invariant', 'public.get_free_busy overloads', '1', (select n_wrapper from ev)::text),
    ('I03', 'invariant', 'get_free_busy identity arguments unchanged', 'p_token text, p_from timestamp with time zone, p_to timestamp with time zone, p_from_date date, p_to_date date',
     (select w_args from ev)),
    ('I04', 'invariant', 'get_free_busy is SECURITY DEFINER with search_path = ''''', 'true|search_path=""',
     (select w_secdef || '|' || coalesce(w_cfg, '(none)') from ev)),
    ('I05', 'invariant', 'its body is one of the two known ones (0018 or 0019)', 'true',
     (select (w_kind <> 'unknown')::text from verdict)),

    -- O. what is actually present. Evidence, not expectations.
    ('O01', 'objects', 'rate tables present (0, 1 or 2)', null, (select n_tables from ev)::text),
    ('O02', 'objects', 'parameter functions present (0..5)', null, (select n_params from ev)::text),
    ('O03', 'objects', 'free_busy_core present (0 or 1)', null, (select n_core from ev)::text),
    ('O04', 'objects', 'names of the 0019 objects that exist', null,
     (select coalesce(string_agg(x, ',' order by x collate "C"), '(none)') from (
        select relname as x from rel where relname in ('freebusy_owner_rate', 'freebusy_link_rate')
        union all select proname from fn where nsp = 'timeweave_private'
          and proname in ('free_busy_core', 'freebusy_link_rate_interval', 'freebusy_link_rate_burst',
                          'freebusy_owner_rate_interval', 'freebusy_owner_rate_burst', 'freebusy_concurrency_slots')) q)),
    ('O05', 'objects', 'get_free_busy body md5 (CR removed)', null, (select w_md5 from ev)),
    ('O06', 'objects', 'which body that is', null, (select w_kind from verdict)),
    ('O07', 'objects', 'get_free_busy volatility (0018 s, 0019 v)', null, (select w_vol from ev)),
    ('O08', 'objects', 'anon+authenticated may EXECUTE it and PUBLIC may not', null, (select w_grants::text from ev)),
    ('O09', 'objects', 'free_busy_core body md5', null, (select coalesce(c_md5, '(absent)') from ev)),
    ('O10', 'objects', 'rate tables: columns and NOT NULL as 0019 defines them', null, (select coalesce(t_cols::text, '(absent)') from ev)),
    ('O11', 'objects', 'rate tables: primary and foreign keys as 0019 defines them', null, (select coalesce(t_keys::text, '(absent)') from ev)),
    ('O12', 'objects', 'rate tables: RLS on, no policy', null, (select coalesce((t_rls and t_nopolicy)::text, '(absent)') from ev)),
    ('O13', 'objects', 'rate tables: owner-only ACL, fillfactor 70, nothing for the API roles', null,
     (select coalesce((t_acl and t_fill and t_private)::text, '(absent)') from ev)),
    ('O14', 'objects', 'parameter functions: attributes and owner-only EXECUTE', null, (select coalesce((f_params and f_params_private)::text, 'false') from ev)),
    ('O15', 'objects', 'core: STABLE, INVOKER, search_path, owner-only EXECUTE', null, (select coalesce((f_core and f_core_private)::text, 'false') from ev)),
    ('O16', 'objects', 'deployed limits link T/burst, owner T/burst, k', null,
     (select coalesce(link_t || '/' || link_b || ', ' || owner_t || '/' || owner_b || ', k=' || k, '(absent)') from pv)),
    ('O17', 'objects', 'limits are exactly the frozen ones', null, (select coalesce(f_limits::text, 'false') from ev)),
    ('O18', 'objects', 'relations in timeweave_private (4 before 0019, 8 after)', null, (select count(*) from rel)::text),

    -- Z. the verdict.
    ('Z01', 'verdict', 'EVERY piece of 0019 is present and correctly shaped', null, (select full_ok::text from verdict)),
    ('Z02', 'verdict', 'NOTHING of 0019 is present and get_free_busy is still the 0018 body', null, (select none_ok::text from verdict)),
    ('Z03', 'verdict', 'pieces present (tables + params + core, 0 or 8 are the only consistent counts)', null,
     (select (n_tables + n_params + n_core)::text from ev)),
    ('Z00', 'verdict', 'VERDICT', null,
     (select case when not inv_ok then 'indeterminate'
                  when full_ok then 'fully_applied'
                  when none_ok then 'not_applied'
                  else 'partial_or_inconsistent' end from verdict))

  ) as v (ord, phase, metric, expected, value)
)
select ord, phase, metric, expected, value, status
from res
union all
select 'P00', 'summary', 'invariant checks that FAIL (any FAIL forces the verdict indeterminate)', '0',
       count(*) filter (where status = 'FAIL')::text,
       case when count(*) filter (where status = 'FAIL') = 0 then 'ok' else 'FAIL' end
from res
order by 1;

rollback;
