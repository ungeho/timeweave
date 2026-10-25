-- ============================================================================
-- TimeWeave -- POSTFLIGHT for 0019_freebusy_rate_limit.sql (A2).
--
-- NOT A MIGRATION AND NOT A TEST SUITE. Run by hand, once, against the project
-- 0019 was applied to, AFTER the apply. Valid only for the frozen 0019:
--
--   sha256   7e244cc8845c6cc5718ffec33b13b00c5fab943b99937e20746819ed5a6359e8
--   git blob 42b64475705e72aa636f51991d5b555348468980   (42,213 bytes, 927 lines)
--
-- READ-ONLY, AND IT CONSUMES NO RATE STATE. It calls NO project function at
-- all -- not get_free_busy, not the core, not even the five IMMUTABLE
-- parameter functions: the limits are read out of the catalog instead. It
-- creates no share link, writes no event, takes no advisory lock and runs no
-- load. Two SELECTs inside one read-only transaction that ends in ROLLBACK, so
-- it can never leave a bucket row, a lock or a plan behind.
--
-- TWO STATEMENTS, ON PURPOSE. Statement 1 is pure catalog and mentions no new
-- object by name, so it still parses and still reports a full FAIL table on a
-- database where 0019 was NOT applied (or was applied in part). Statement 2
-- reads the two new tables for section D and can only run once they exist; if
-- it errors with 'relation ... does not exist', statement 1 has already said
-- why. Both live in the same read-only transaction.
--
-- WHAT IT GATES
--
--   V. context     server, role                                             V01-V03
--   W. wrapper     public.get_free_busy: signature and ACL unchanged, now   W01-W20
--                  VOLATILE, still DEFINER with search_path = ''; body is
--                  the 0019 gate: 4 validation raises, the 0018 token
--                  predicate verbatim, 3 PT429 raises, ONE try-lock, ONE
--                  core call, exactly 2 charging upserts, no row lock in
--                  the pre-check
--   C. core        timeweave_private.free_busy_core: STABLE, SECURITY       C01-C16
--                  INVOKER, search_path = '', granted to nobody -- and
--                  C12, THE EQUIVALENCE GATE: put 0018's token predicate
--                  back in place of `where s.id = p_link_id` and the body
--                  hashes to the EXACT 0018 body the 0018 postflight
--                  confirmed in production. That is the proof that the
--                  computation itself was not edited.
--   T. tables      the two rate tables: columns, NOT NULL, PK, FK, RLS      T01-T14
--                  with no policy, fillfactor, ACL, and no privilege for
--                  any API role
--   Q. params      the five parameter functions: attributes, ACL, owner     Q01-Q09
--   N. numbers     the limits actually deployed, read from the catalog:     N01-N08
--                  link T=2s burst 15, owner T=1s burst 40, k=2
--   A. advisory    the classes the gate can take are 811031/811032 and      A01-A09
--                  they do not meet 811001/811002; existing takers unchanged
--   M. private     the two 0018 *_in_zones helpers: untouched               M01-M06
--   Z. deps        helpers 0019 never touches: bodies, owner, ACLs          Z01-Z08
--   S. schema      timeweave_private: same owner, nobody else has USAGE     S01-S04
--   X. unrelated   every other function, every trigger, every table ACL     X01-X06
--                  and every RLS policy as before the apply
--   D. state       the rate tables' initial state (statement 2)             D01-D04
--
-- D01 IS THE ONE CHECK THAT LEGITIMATELY MOVES. Run straight after the apply
-- it must be '0|0'. Once anonymous traffic has arrived, non-zero counts are
-- the limiter working, not a defect -- but D01 then FAILs, so run this before
-- announcing the change and read D01 together with D02.
--
-- Production-confirmed baselines quoted below come from the 0018 POSTFLIGHT
-- (2026-09-19, FAIL 0): the 0018 body md5 17f05831c60abd63a652c0a9d691b94c
-- (used by C12), M03 7023e51d..., M04 f4a39463..., Z01-Z05, the ACL strings,
-- X01 9fe515f1ec7489df45c51960b90a9176, X02 35f508637a7c1a995ba65caf1ebb7d54.
--
-- X01 IS A PRODUCTION CONSTANT: a fingerprint of production's own remaining
-- functions. Against any other database -- a local rebuild, a staging copy --
-- X01 FAILs although nothing is wrong. What must hold operationally is that
-- the preflight X01 and this X01 are the same value: 0019 must not move it.
--
-- X03 and X04 have no hard-coded expectation (production-specific). They use
-- the SAME expressions as the preflight: compare the two outputs by hand, they
-- must be character-for-character identical.
--
-- PRIVACY. Counts, catalog text, ACLs and source hashes only. No title,
-- description, label, token, row id or owner id is ever returned.
--
-- READING THE OUTPUT. status 'ok' / 'FAIL' where an expectation exists,
-- 'context' otherwise. P00 summarises statement 1, P01 summarises statement 2.
-- ============================================================================
begin transaction read only;

-- ---------------------------------------------------------------------------
-- Statement 1: catalog only. Mentions no new object by name, so it reports
-- rather than errors when 0019 is absent or half-applied.
-- ---------------------------------------------------------------------------
with
fn as (
  select n.nspname as nsp, p.proname, p.oid, p.proowner,
         pg_catalog.pg_get_function_identity_arguments(p.oid) as args,
         pg_catalog.pg_get_function_result(p.oid) as ret,
         p.prosecdef, p.provolatile, p.proconfig, p.proacl, l.lanname,
         md5(replace(p.prosrc, E'\r', '')) as h,
         replace(p.prosrc, E'\r', '') as body,
         regexp_replace(replace(p.prosrc, E'\r', ''), '--[^\n]*', '', 'g') as code,
         p.prosrc
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
pc  as (select * from fn where oid = to_regprocedure('timeweave_private.rrule_timed_occurrence_count_in_zones(text, boolean, timestamptz, timestamptz, text, timestamptz, timestamptz, text[])')),
ps  as (select * from fn where oid = to_regprocedure('timeweave_private.rrule_timed_occurrence_starts_in_zones(text, boolean, timestamptz, timestamptz, text, timestamptz, timestamptz, text[])')),
dep as (select * from fn where nsp = 'public'
          and proname in ('timezone_is_resolvable', 'timezone_is_supported', 'rrule_timed_sql_subset',
                          'rrule_parse', 'rrule_timed_expansion_cap')),
own as (select min(proowner::text)::oid as o, count(*) as n from gfb),
xo as (
  select f.oid,
         case when f.proacl is null then 1
              else (select count(*) from pg_catalog.aclexplode(f.proacl) a
                     where a.privilege_type = 'EXECUTE' and a.grantee <> f.proowner) end as n
  from fn f
),
tp as (
  select n.oid, n.nspowner, n.nspacl from pg_catalog.pg_namespace n where n.nspname = 'timeweave_private'
),
rel as (
  select n.nspname as nsp, c.relname, c.oid, c.relkind, c.relrowsecurity, c.relacl, c.relowner, c.reloptions
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public', 'timeweave_private')
),
own_rate as (select * from rel where nsp = 'timeweave_private' and relname = 'freebusy_owner_rate' and relkind::text = 'r'),
lnk_rate as (select * from rel where nsp = 'timeweave_private' and relname = 'freebusy_link_rate' and relkind::text = 'r'),
-- Columns as "name type" in attnum order, plus the NOT NULL tally.
cols as (
  select a.attrelid,
         string_agg(a.attname || ' ' || pg_catalog.format_type(a.atttypid, a.atttypmod), ',' order by a.attnum) as def,
         count(*) filter (where a.attnotnull) as nn,
         count(*) as n
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
cls as (
  select distinct m.arr[1] as c
  from fn f, lateral regexp_matches(f.code, '(81[0-9]{4})', 'g') as m(arr)
),
-- The deployed limits, read out of the parameter functions' source. Reading
-- beats calling here: it parses (and reports) even when 0019 is absent, and it
-- executes none of the project's own code.
pv as (
  select
    max(case when proname = 'freebusy_link_rate_interval'  then (regexp_match(prosrc, 'interval\s+''([^'']+)'''))[1] end) as link_t,
    max(case when proname = 'freebusy_owner_rate_interval' then (regexp_match(prosrc, 'interval\s+''([^'']+)'''))[1] end) as owner_t,
    max(case when proname = 'freebusy_link_rate_burst'     then (regexp_match(prosrc, 'select\s+([0-9]+)'))[1] end) as link_b,
    max(case when proname = 'freebusy_owner_rate_burst'    then (regexp_match(prosrc, 'select\s+([0-9]+)'))[1] end) as owner_b,
    max(case when proname = 'freebusy_concurrency_slots'   then (regexp_match(prosrc, 'select\s+([0-9]+)'))[1] end) as k
  from par
),
-- The classes the gate can actually take, derived from the deployed k.
slots as (
  select string_agg((811030 + g)::text, ',' order by g) as list,
         count(*) filter (where 811030 + g in (811001, 811002)) as clash
  from pv, lateral generate_series(1, pv.k::integer) g
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
    ('V02', 'context', 'server_version_num', null, current_setting('server_version_num')),
    ('V03', 'context', 'role running this postflight', null, current_user::text),

    -- W. the public wrapper.
    ('W01', 'wrapper', 'public.get_free_busy overloads', '1',
     (select count(*) from fn where nsp = 'public' and proname = 'get_free_busy')::text),
    ('W02', 'wrapper', 'identity arguments (unchanged)', 'p_token text, p_from timestamp with time zone, p_to timestamp with time zone, p_from_date date, p_to_date date',
     (select args from gfb)),
    ('W03', 'wrapper', 'result type (unchanged)', 'jsonb', (select ret from gfb)),
    ('W04', 'wrapper', 'SECURITY DEFINER (unchanged)', 'true', (select prosecdef::text from gfb)),
    ('W05', 'wrapper', 'volatility is VOLATILE (0019 makes it write)', 'v', (select provolatile::text from gfb)),
    ('W06', 'wrapper', 'proconfig (unchanged)', 'search_path=""', (select array_to_string(proconfig, ',') from gfb)),
    ('W07', 'wrapper', 'language (unchanged)', 'plpgsql', (select lanname::text from gfb)),
    ('W08', 'wrapper', 'full ACL == production-before (0018 postflight F08)', 'postgres=X/postgres anon=X/postgres authenticated=X/postgres',
     (select coalesce(array_to_string(proacl, ' '), '(default)') from gfb)),
    ('W09', 'wrapper', 'anon|authenticated may EXECUTE, PUBLIC may not', 'true|true|false',
     (select pg_catalog.has_function_privilege('anon', oid, 'EXECUTE')::text || '|'
          || pg_catalog.has_function_privilege('authenticated', oid, 'EXECUTE')::text || '|'
          || (proacl is null or exists (select 1 from pg_catalog.aclexplode(proacl) a
                                         where a.grantee = 0 and a.privilege_type = 'EXECUTE'))::text from gfb)),
    ('W10', 'wrapper', 'body md5, CR removed (0019 wrapper)', '162c218d890630c6478c6e26638c2ca9', (select h from gfb)),
    ('W11', 'wrapper', 'owned by the role running this postflight', 'true',
     (select (proowner = current_user::regrole::oid)::text from gfb)),
    ('W12', 'wrapper', 'calls timeweave_private.free_busy_core exactly once', '1',
     (select count(*) from regexp_matches((select code from gfb), 'timeweave_private\.free_busy_core\(', 'g'))::text),
    ('W13', 'wrapper', 'the 0018 token predicate, verbatim, exactly once', '1',
     (select count(*) from regexp_matches((select body from gfb),
        'where s\.token_hash = encode\(extensions\.digest\(p_token, ''sha256''\), ''hex''\)', 'g'))::text),
    ('W14', 'wrapper', 'validation raises with errcode 22023 (both windows, both shapes)', '4',
     (select count(*) from regexp_matches((select code from gfb), '''22023''', 'g'))::text),
    ('W15', 'wrapper', 'PT429 raises (owner rate, link rate, busy)', '3',
     (select count(*) from regexp_matches((select code from gfb), '''PT429''', 'g'))::text),
    ('W16', 'wrapper', 'DETAIL markers: TIMEWEAVE_RATE_FREEBUSY total|_BUSY', '3|1',
     (select (select count(*) from regexp_matches((select code from gfb), '''TIMEWEAVE_RATE_FREEBUSY(_BUSY)?''', 'g'))::text || '|'
          || (select count(*) from regexp_matches((select code from gfb), '''TIMEWEAVE_RATE_FREEBUSY_BUSY''', 'g'))::text)),
    ('W17', 'wrapper', 'pg_try_advisory_xact_lock called exactly once (inside the slot loop)', '1',
     (select count(*) from regexp_matches((select code from gfb), 'pg_try_advisory_xact_lock\(', 'g'))::text),
    ('W18', 'wrapper', 'charging upserts: owner|link|ON CONFLICT DO UPDATE', '1|1|2',
     (select (select count(*) from regexp_matches((select code from gfb), 'insert into timeweave_private\.freebusy_owner_rate', 'g'))::text || '|'
          || (select count(*) from regexp_matches((select code from gfb), 'insert into timeweave_private\.freebusy_link_rate', 'g'))::text || '|'
          || (select count(*) from regexp_matches((select code from gfb), 'on conflict \([a-z_]+\) do update', 'g'))::text)),
    ('W19', 'wrapper', 'the pre-check locks nothing: no FOR UPDATE / FOR SHARE anywhere in the body', '0',
     (select count(*) from regexp_matches((select code from gfb), 'for (update|share|no key update|key share)', 'g'))::text),
    ('W20', 'wrapper', 'computes nothing itself: no *_in_zones and no public timed helper call', '0',
     ((select count(*) from regexp_matches((select code from gfb), '_in_zones\(', 'g'))
      + (select count(*) from regexp_matches((select code from gfb), 'public\.rrule_timed_occurrence_(count|starts)\(', 'g')))::text),

    -- C. the private core. C12 is the equivalence gate.
    ('C01', 'core', 'timeweave_private.free_busy_core at the exact signature', '1', (select count(*) from cor)::text),
    ('C02', 'core', 'identity arguments', 'p_link_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_from_date date, p_to_date date',
     (select args from cor)),
    ('C03', 'core', 'result type', 'jsonb', (select ret from cor)),
    ('C04', 'core', 'volatility is STABLE (one snapshot per call)', 's', (select provolatile::text from cor)),
    ('C05', 'core', 'SECURITY INVOKER (it runs inside the DEFINER wrapper)', 'false', (select prosecdef::text from cor)),
    ('C06', 'core', 'proconfig', 'search_path=""', (select array_to_string(proconfig, ',') from cor)),
    ('C07', 'core', 'language', 'plpgsql', (select lanname::text from cor)),
    ('C08', 'core', 'full ACL (owner only)', 'postgres=X/postgres',
     (select coalesce(array_to_string(proacl, ' '), '(default)') from cor)),
    ('C09', 'core', 'EXECUTE holders besides owner (NULL acl counts as PUBLIC)', '0',
     (select n::text from xo where oid = (select oid from cor))),
    ('C10', 'core', 'anon|authenticated|service_role may EXECUTE', 'false|false|false',
     (select pg_catalog.has_function_privilege('anon', oid, 'EXECUTE')::text || '|'
          || pg_catalog.has_function_privilege('authenticated', oid, 'EXECUTE')::text || '|'
          || pg_catalog.has_function_privilege('service_role', oid, 'EXECUTE')::text from cor)),
    ('C11', 'core', 'body md5, CR removed (0019 core)', 'a7558dfa02a4ce6444d538e370eb631d', (select h from cor)),
    ('C12', 'core', 'EQUIVALENCE GATE: core body with the token predicate put back == the 0018 body confirmed in production',
     '17f05831c60abd63a652c0a9d691b94c',
     (select md5(replace(body, 'where s.id = p_link_id',
                 'where s.token_hash = encode(extensions.digest(p_token, ''sha256''), ''hex'')')) from cor)),
    ('C13', 'core', 'looks the link up by id, exactly once', '1',
     (select count(*) from regexp_matches((select body from cor), 'where s\.id = p_link_id', 'g'))::text),
    ('C14', 'core', 'no token, hash or digest in the core CODE (the 0018 comment above the lookup stays verbatim)', '0',
     (select count(*) from cor where code ~ '(token|digest|sha256)')::text),
    ('C15', 'core', 'calls count_in_zones 4x and starts_in_zones 2x, each with v_ok_tz (0018 shape)', '4|2',
     (select (select count(*) from regexp_matches(code, 'timeweave_private\.rrule_timed_occurrence_count_in_zones\([^()]*v_ok_tz\)', 'g'))::text || '|'
          || (select count(*) from regexp_matches(code, 'timeweave_private\.rrule_timed_occurrence_starts_in_zones\([^()]*v_ok_tz\)', 'g'))::text from cor)),
    ('C16', 'core', 'owned by get_free_busy''s owner', 'true',
     (select (proowner = (select o from own))::text from cor)),

    -- T. the two rate tables.
    ('T01', 'tables', 'both rate tables exist as ordinary tables', '2',
     ((select count(*) from own_rate) + (select count(*) from lnk_rate))::text),
    ('T02', 'tables', 'freebusy_owner_rate columns',
     'owner_id uuid,tat timestamp with time zone,charged_calls bigint,last_charge_at timestamp with time zone',
     (select def from cols where attrelid = (select oid from own_rate))),
    ('T03', 'tables', 'freebusy_link_rate columns',
     'link_id uuid,tat timestamp with time zone,charged_calls bigint,last_charge_at timestamp with time zone',
     (select def from cols where attrelid = (select oid from lnk_rate))),
    ('T04', 'tables', 'every column NOT NULL: owner|link', '4/4|4/4',
     (select (select nn::text || '/' || n::text from cols where attrelid = (select oid from own_rate)) || '|'
          || (select nn::text || '/' || n::text from cols where attrelid = (select oid from lnk_rate)))),
    ('T05', 'tables', 'primary keys', 'PRIMARY KEY (owner_id)|PRIMARY KEY (link_id)',
     (select (select def from cons where conrelid = (select oid from own_rate) and contype = 'p') || '|'
          || (select def from cons where conrelid = (select oid from lnk_rate) and contype = 'p'))),
    ('T06', 'tables', 'foreign keys (schema prefix normalised)',
     'FOREIGN KEY (owner_id) REFERENCES auth.users(id) ON DELETE CASCADE|FOREIGN KEY (link_id) REFERENCES share_links(id) ON DELETE CASCADE',
     (select (select def from cons where conrelid = (select oid from own_rate) and contype = 'f') || '|'
          || (select def from cons where conrelid = (select oid from lnk_rate) and contype = 'f'))),
    ('T07', 'tables', 'RLS enabled: owner|link', 'true|true',
     (select (select relrowsecurity::text from own_rate) || '|' || (select relrowsecurity::text from lnk_rate))),
    ('T08', 'tables', 'RLS policies on them (RLS with no policy = deny all)', '0',
     (select count(*) from pg_catalog.pg_policy p
       where p.polrelid in (select oid from own_rate union all select oid from lnk_rate))::text),
    ('T09', 'tables', 'ACL after revoke all: owner|link (same shape as 0012 and 0016)',
     'postgres=arwdDxtm/postgres|postgres=arwdDxtm/postgres',
     (select (select coalesce(array_to_string(relacl, ' '), '(default)') from own_rate) || '|'
          || (select coalesce(array_to_string(relacl, ' '), '(default)') from lnk_rate))),
    ('T10', 'tables', 'ACL entries for anon / authenticated / service_role', '0',
     (select count(*) from rel r, pg_catalog.aclexplode(r.relacl) a
       where r.oid in (select oid from own_rate union all select oid from lnk_rate)
         and a.grantee in ('anon'::regrole::oid, 'authenticated'::regrole::oid, 'service_role'::regrole::oid))::text),
    ('T11', 'tables', 'API role x privilege x table combinations that evaluate TRUE', '0',
     (select count(*)
        from (values ('anon'), ('authenticated'), ('service_role'), ('authenticator')) r(rol),
             (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) p(priv),
             (select oid from own_rate union all select oid from lnk_rate) t(oid)
       where pg_catalog.has_table_privilege(r.rol, t.oid, p.priv))::text),
    ('T12', 'tables', 'reloptions: owner|link', '{fillfactor=70}|{fillfactor=70}',
     (select (select coalesce(reloptions::text, '(none)') from own_rate) || '|'
          || (select coalesce(reloptions::text, '(none)') from lnk_rate))),
    ('T13', 'tables', 'relations in timeweave_private (0018 left 4; 0019 adds 2 tables + 2 pkeys)', '8',
     (select count(*) from rel where nsp = 'timeweave_private')::text),
    ('T14', 'tables', 'both owned by get_free_busy''s owner', 'true',
     (select (count(*) = 2 and bool_and(relowner = (select o from own)))::text
        from (select relowner from own_rate union all select relowner from lnk_rate) q)),

    -- Q. the five parameter functions.
    ('Q01', 'params', 'the five parameter functions exist in timeweave_private', '5', (select count(*) from par)::text),
    ('Q02', 'params', 'names', 'freebusy_concurrency_slots,freebusy_link_rate_burst,freebusy_link_rate_interval,freebusy_owner_rate_burst,freebusy_owner_rate_interval',
     (select string_agg(proname, ',' order by proname collate "C") from par)),
    ('Q03', 'params', 'all IMMUTABLE', 'i', (select string_agg(distinct provolatile::text, ',') from par)),
    ('Q04', 'params', 'none is SECURITY DEFINER', 'false', (select string_agg(distinct prosecdef::text, ',') from par)),
    ('Q05', 'params', 'all set search_path = ''''', 'search_path=""',
     (select string_agg(distinct array_to_string(proconfig, ','), ',') from par)),
    ('Q06', 'params', 'all language sql', 'sql', (select string_agg(distinct lanname::text, ',') from par)),
    ('Q07', 'params', 'ACL, owner only, identical on all five', 'postgres=X/postgres',
     (select string_agg(distinct coalesce(array_to_string(proacl, ' '), '(default)'), ',') from par)),
    ('Q08', 'params', 'EXECUTE holders besides owner, summed over the five', '0',
     (select coalesce(sum(x.n), 0)::text from par p join xo x on x.oid = p.oid)),
    ('Q09', 'params', 'all owned by get_free_busy''s owner', 'true',
     (select (count(*) = 5 and bool_and(proowner = (select o from own)))::text from par)),

    -- N. the limits actually deployed, read from the catalog (no call).
    ('N01', 'numbers', 'link interval T', '00:00:02', (select link_t::interval::text from pv)),
    ('N02', 'numbers', 'link burst', '15', (select link_b from pv)),
    ('N03', 'numbers', 'owner interval T', '00:00:01', (select owner_t::interval::text from pv)),
    ('N04', 'numbers', 'owner burst', '40', (select owner_b from pv)),
    ('N05', 'numbers', 'owner concurrency slots k', '2', (select k from pv)),
    ('N06', 'numbers', 'link allowance tau = burst * T', '00:00:30',
     (select (link_b::integer * link_t::interval)::text from pv)),
    ('N07', 'numbers', 'owner allowance tau = burst * T', '00:00:40',
     (select (owner_b::integer * owner_t::interval)::text from pv)),
    ('N08', 'numbers', 'sustained calls per minute: link|owner', '30|60',
     (select (60 / extract(epoch from link_t::interval))::bigint::text || '|'
          || (60 / extract(epoch from owner_t::interval))::bigint::text from pv)),

    -- A. advisory lock classes.
    ('A01', 'advisory', 'the wrapper declares base class 811030', 'true',
     (select (code ~ 'c_slot_class\s+constant\s+integer\s*:=\s*811030')::text from gfb)),
    ('A02', 'advisory', 'the slot is taken as (c_slot_class + v_slot, hashtext(v_owner::text))', 'true',
     (select (code ~ 'pg_try_advisory_xact_lock\(c_slot_class \+ v_slot,\s*pg_catalog\.hashtext\(v_owner::text\)\)')::text from gfb)),
    ('A03', 'advisory', 'classes reachable with the deployed k', '811031,811032', (select list from slots)),
    ('A04', 'advisory', 'any reachable class equals 811001 or 811002', '0', (select clash::text from slots)),
    ('A05', 'advisory', 'distinct advisory classes named in code (0019 adds the base 811030)', '811001,811002,811030',
     (select string_agg(c, ',' order by c collate "C") from cls)),
    ('A06', 'advisory', 'functions taking class 811001 (unchanged by 0019)',
     'public.events_enforce_owner_quota,public.events_enforce_recurrence_graph,public.share_links_enforce_quota',
     (select string_agg(nsp || '.' || proname, ',' order by nsp || '.' || proname collate "C")
        from fn where code ~ '811001')),
    ('A07', 'advisory', 'functions taking class 811002 (unchanged by 0019)', 'public.events_enforce_exception_quota',
     (select string_agg(nsp || '.' || proname, ',' order by nsp || '.' || proname collate "C")
        from fn where code ~ '811002')),
    ('A08', 'advisory', 'the wrapper takes neither 811001 nor 811002 (it cannot disturb the write-path order)', '0',
     (select count(*) from gfb where code ~ '(811001|811002)')::text),
    ('A09', 'advisory', 'advisory locks held right now in classes 811030-811039', null,
     (select count(*) from pg_catalog.pg_locks l
       where l.locktype = 'advisory' and l.classid between 811030 and 811039)::text),

    -- M. the two 0018 private helpers: untouched (production-confirmed values).
    ('M01', 'private', 'count_in_zones at the exact 8-argument signature', '1', (select count(*) from pc)::text),
    ('M02', 'private', 'starts_in_zones at the exact 8-argument signature', '1', (select count(*) from ps)::text),
    ('M03', 'private', 'count_in_zones body md5 (0018)', '7023e51dc8675be1338e3a5b5b2f9d1b', (select h from pc)),
    ('M04', 'private', 'starts_in_zones body md5 (0018)', 'f4a394632a1b26903554df766116912f', (select h from ps)),
    ('M05', 'private', 'DEFINER count|starts, volatility count|starts', 'false|false|s|s',
     (select (select prosecdef::text from pc) || '|' || (select prosecdef::text from ps) || '|'
          || (select provolatile::text from pc) || '|' || (select provolatile::text from ps))),
    ('M06', 'private', 'EXECUTE holders besides owner, count|starts', '0|0',
     (select (select n::text from xo where oid = (select oid from pc)) || '|'
          || (select n::text from xo where oid = (select oid from ps)))),

    -- Z. dependencies 0019 never touches (production-confirmed).
    ('Z01', 'deps', 'timezone_is_resolvable body md5', '28e6b9f4d8a83a274226745edef206dc',
     (select string_agg(h, ',') from dep where proname = 'timezone_is_resolvable')),
    ('Z02', 'deps', 'timezone_is_supported body md5', 'd6d46c844ff9c154870f67b757dd3b4f',
     (select string_agg(h, ',') from dep where proname = 'timezone_is_supported')),
    ('Z03', 'deps', 'rrule_timed_sql_subset body md5', 'd34812cfb2fe12e0d44054751cee3430',
     (select string_agg(h, ',') from dep where proname = 'rrule_timed_sql_subset')),
    ('Z04', 'deps', 'rrule_parse body md5', '2e59e47964e4f403914c86249a2daaaa',
     (select string_agg(h, ',') from dep where proname = 'rrule_parse')),
    ('Z05', 'deps', 'rrule_timed_expansion_cap body md5', 'c9bb9b6680f94aa14aa2083dfcd4bd23',
     (select string_agg(h, ',') from dep where proname = 'rrule_timed_expansion_cap')),
    ('Z06', 'deps', 'all five owned by get_free_busy''s owner', 'true',
     (select (count(*) = 5 and bool_and(proowner = (select o from own)))::text from dep)),
    ('Z07', 'deps', 'timezone_is_resolvable ACL == production-before', 'postgres=X/postgres',
     (select coalesce(array_to_string(proacl, ' '), '(default)') from dep where proname = 'timezone_is_resolvable')),
    ('Z08', 'deps', 'timezone_is_supported ACL == production-before', 'postgres=X/postgres authenticated=X/postgres',
     (select coalesce(array_to_string(proacl, ' '), '(default)') from dep where proname = 'timezone_is_supported')),

    -- S. timeweave_private, now holding six more objects.
    ('S01', 'schema', 'timeweave_private exists', '1', (select count(*) from tp)::text),
    ('S02', 'schema', 'owned by get_free_busy''s owner', 'true', (select (nspowner = (select o from own))::text from tp)),
    ('S03', 'schema', 'USAGE/CREATE holders besides owner (incl. PUBLIC)', '0',
     (select count(*) from tp, pg_catalog.aclexplode(tp.nspacl) a
       where a.grantee <> tp.nspowner)::text),
    ('S04', 'schema', 'USAGE for anon|authenticated|service_role|authenticator', 'false|false|false|false',
     (select pg_catalog.has_schema_privilege('anon', 'timeweave_private', 'USAGE')::text || '|'
          || pg_catalog.has_schema_privilege('authenticated', 'timeweave_private', 'USAGE')::text || '|'
          || pg_catalog.has_schema_privilege('service_role', 'timeweave_private', 'USAGE')::text || '|'
          || pg_catalog.has_schema_privilege('authenticator', 'timeweave_private', 'USAGE')::text)),

    -- X. everything 0019 must not have moved. Same expressions as the preflight.
    ('X01', 'unrelated', 'md5 over every other public/timeweave_private function == production-before',
     '9fe515f1ec7489df45c51960b90a9176',
     (select md5(string_agg(nsp || '.' || proname || '(' || args || ')|' || coalesce(array_to_string(proacl, ' '), '-') || '|'
                            || coalesce(array_to_string(proconfig, ','), '') || '|' || prosecdef::text || '|' || h,
                            ';' order by nsp || '.' || proname || '(' || args || ')' collate "C"))
        from fn where nsp in ('public', 'timeweave_private')
          and proname not in ('get_free_busy', 'rrule_timed_occurrence_count', 'rrule_timed_occurrence_starts',
                              'rrule_timed_occurrence_count_in_zones', 'rrule_timed_occurrence_starts_in_zones',
                              'free_busy_core', 'freebusy_link_rate_interval', 'freebusy_link_rate_burst',
                              'freebusy_owner_rate_interval', 'freebusy_owner_rate_burst', 'freebusy_concurrency_slots'))),
    ('X02', 'unrelated', 'md5 over events + share_links trigger definitions == production-before',
     '35f508637a7c1a995ba65caf1ebb7d54',
     (select md5(string_agg(pg_catalog.pg_get_triggerdef(t.oid), ';' order by t.tgname collate "C"))
        from pg_catalog.pg_trigger t
       where t.tgrelid in ('public.events'::regclass, 'public.share_links'::regclass) and not t.tgisinternal)),
    ('X03', 'unrelated', 'md5 over every RLS policy on public tables (must equal the preflight value)', null,
     (select md5(coalesce(string_agg(p.polrelid::regclass::text || '.' || p.polname || '|' || p.polcmd::text || '|'
                            || coalesce(pg_catalog.pg_get_expr(p.polqual, p.polrelid), '-') || '|'
                            || coalesce(pg_catalog.pg_get_expr(p.polwithcheck, p.polrelid), '-'),
                            ';' order by p.polrelid::regclass::text || '.' || p.polname collate "C"), ''))
        from pg_catalog.pg_policy p
       where p.polrelid in (select oid from rel where nsp = 'public'))),
    ('X04', 'unrelated', 'md5 over table ACLs and RLS flags, excluding the two new tables (must equal the preflight value)', null,
     (select md5(string_agg(nsp || '.' || relname || '|' || coalesce(array_to_string(relacl, ' '), '-') || '|' || relrowsecurity::text,
                            ';' order by nsp || '.' || relname collate "C"))
        from rel where relkind::text in ('r', 'p')
          and relname not in ('freebusy_owner_rate', 'freebusy_link_rate'))),
    ('X05', 'unrelated', 'functions in timeweave_private (0018 left 2; 0019 adds 6)', '8',
     (select count(*) from fn where nsp = 'timeweave_private')::text),
    ('X06', 'unrelated', 'events + share_links triggers that are NOT enabled (tgenabled <> O)', '0',
     (select count(*) from pg_catalog.pg_trigger t
       where t.tgrelid in ('public.events'::regclass, 'public.share_links'::regclass)
         and not t.tgisinternal and t.tgenabled::text <> 'O')::text)

  ) as v (ord, phase, metric, expected, value)
)
select ord, phase, metric, expected, value, status
from res
union all
select 'P00', 'summary', 'statement 1: checks that FAIL', '0',
       count(*) filter (where status = 'FAIL')::text,
       case when count(*) filter (where status = 'FAIL') = 0 then 'ok' else 'FAIL' end
from res
order by 1;

-- ---------------------------------------------------------------------------
-- Statement 2: the two new tables' own state. Reads them; writes nothing.
-- If 0019 is absent this statement errors -- statement 1 has already reported
-- why -- and the transaction is rolled back below either way.
-- ---------------------------------------------------------------------------
with res2 as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL'
         end as status
  from (values

    ('D01', 'state', 'rows: freebusy_owner_rate|freebusy_link_rate (0|0 right after the apply)', '0|0',
     ((select count(*) from timeweave_private.freebusy_owner_rate)::text || '|'
      || (select count(*) from timeweave_private.freebusy_link_rate)::text)),
    ('D02', 'state', 'calls charged so far: owner|link (read D01 with this)', null,
     (coalesce((select sum(charged_calls) from timeweave_private.freebusy_owner_rate), 0)::text || '|'
      || coalesce((select sum(charged_calls) from timeweave_private.freebusy_link_rate), 0)::text)),
    ('D03', 'state', 'rows violating the charging invariant (charged_calls < 1)', '0',
     ((select count(*) from timeweave_private.freebusy_owner_rate where charged_calls < 1)
      + (select count(*) from timeweave_private.freebusy_link_rate where charged_calls < 1))::text),
    ('D04', 'state', 'buckets in debt at this instant: owner|link', null,
     ((select count(*) from timeweave_private.freebusy_owner_rate where tat > now())::text || '|'
      || (select count(*) from timeweave_private.freebusy_link_rate where tat > now())::text))

  ) as v (ord, phase, metric, expected, value)
)
select ord, phase, metric, expected, value, status
from res2
union all
select 'P01', 'summary', 'statement 2: checks that FAIL', '0',
       count(*) filter (where status = 'FAIL')::text,
       case when count(*) filter (where status = 'FAIL') = 0 then 'ok' else 'FAIL' end
from res2
order by 1;

rollback;
