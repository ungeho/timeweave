-- ============================================================================
-- 0025 POSTFLIGHT -- read-only. Run AFTER applying 0025_freebusy_crossmodel.sql.
--
-- GO requires the ZZZ summary row to read 0, and that row counts EVERY gate
-- below rather than a sample of them.
--
-- The shape of this file follows the risk. 0025 adds a table that anonymous
-- viewers must never reach and replaces a function whose ACL is the only thing
-- keeping a raw link id out of reach, so the privilege rows outnumber the
-- behaviour rows. Behaviour itself is covered by 0025_crossmodel_test.sql,
-- which runs the real wrapper against real rows; this file asks only whether
-- the objects came out the way the migration said they would.
-- ============================================================================

begin transaction read only;

with
fn as (
  select p.oid, n.nspname, p.proname,
         replace(p.prosrc, E'\r', '') as body,
         p.proowner, p.prosecdef, p.provolatile, p.proconfig
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
),
wrp as (select * from fn where oid = to_regprocedure('public.get_free_busy(text, timestamptz, timestamptz, date, date)')),
cor as (select * from fn where oid = to_regprocedure('timeweave_private.free_busy_core(uuid, timestamptz, timestamptz, date, date)')),
hlp as (select * from fn where oid = to_regprocedure('timeweave_private.free_busy_available(uuid, timestamptz, timestamptz, date, date, jsonb)')),
res as (
  select v.ord, v.phase, v.metric, v.expected, v.value,
         case when v.expected is null then 'context'
              when v.value is not distinct from v.expected then 'ok'
              else 'FAIL'
         end as status
  from (values

    -- T. the new table -----------------------------------------------------
    ('T01','table','GATE: public.owner_settings exists',
      'true', (to_regclass('public.owner_settings') is not null)::text),
    ('T02','table','GATE: its columns, in order',
      'owner_id,timezone,language,created_at,updated_at',
      (select string_agg(column_name, ',' order by ordinal_position)
       from information_schema.columns
       where table_schema='public' and table_name='owner_settings')),
    ('T03','table','GATE: owner_id is the primary key',
      'owner_id',
      (select string_agg(a.attname, ',')
       from pg_catalog.pg_constraint c
       join pg_catalog.pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
       where c.conrelid = 'public.owner_settings'::regclass and c.contype = 'p')),
    ('T04','table','GATE: owner_id defaults to auth.uid(), so clients never send it',
      'true',
      (select (column_default like '%auth.uid()%')::text from information_schema.columns
       where table_schema='public' and table_name='owner_settings' and column_name='owner_id')),
    ('T05','table','GATE: timezone is NULLABLE -- unset is a real state, not a gap',
      'YES',
      (select is_nullable from information_schema.columns
       where table_schema='public' and table_name='owner_settings' and column_name='timezone')),
    ('T06','table','GATE: language is NULLABLE (means "follow the browser")',
      'YES',
      (select is_nullable from information_schema.columns
       where table_schema='public' and table_name='owner_settings' and column_name='language')),
    ('T07','table','GATE: the language CHECK is present',
      'true',
      (select (count(*) = 1)::text from pg_catalog.pg_constraint
       where conrelid = 'public.owner_settings'::regclass
         and conname = 'owner_settings_language_values' and contype = 'c')),
    ('T08','table','GATE: there is NO check constraint on timezone',
      '0',
      -- timezone_is_supported() reads pg_timezone_names and is STABLE, so a
      -- CHECK over it would be a lie to the planner. 0008 used a trigger and
      -- so does this. A CHECK appearing here means someone "simplified" it.
      (select count(*)::text from pg_catalog.pg_constraint
       where conrelid = 'public.owner_settings'::regclass and contype = 'c'
         and pg_catalog.pg_get_constraintdef(oid) ilike '%timezone%')),
    ('T09','table','GATE: the validating trigger is attached, BEFORE INSERT OR UPDATE',
      'true',
      (select (count(*) = 1)::text from pg_catalog.pg_trigger
       where tgrelid = 'public.owner_settings'::regclass
         and tgname = 'owner_settings_validate_timezone' and not tgisinternal)),
    ('T10','table','GATE: RLS is enabled',
      'true', (select relrowsecurity::text from pg_catalog.pg_class
               where oid = 'public.owner_settings'::regclass)),
    ('T11','table','GATE: exactly three policies -- select, insert, update',
      'INSERT,SELECT,UPDATE',
      (select string_agg(distinct cmd, ',' order by cmd) from pg_catalog.pg_policies
       where schemaname='public' and tablename='owner_settings')),
    ('T12','table','GATE: NO delete policy (clearing is an UPDATE to NULL)',
      '0',
      (select count(*)::text from pg_catalog.pg_policies
       where schemaname='public' and tablename='owner_settings' and cmd = 'DELETE')),
    ('T13','table','GATE: every policy is scoped to auth.uid()',
      '3',
      (select count(*)::text from pg_catalog.pg_policies
       where schemaname='public' and tablename='owner_settings'
         and coalesce(qual, '') || coalesce(with_check, '') like '%auth.uid()%')),

    -- P. privileges on the new table --------------------------------------
    ('P01','priv','GATE: anon holds NOTHING on owner_settings',
      '(none)',
      coalesce((select string_agg(distinct privilege_type, ',' order by privilege_type)
                from information_schema.role_table_grants
                where table_schema='public' and table_name='owner_settings'
                  and grantee = 'anon'), '(none)')),
    ('P02','priv','GATE: PUBLIC holds NOTHING (the schema default grants TRUNCATE)',
      '(none)',
      coalesce((select string_agg(distinct privilege_type, ',' order by privilege_type)
                from information_schema.role_table_grants
                where table_schema='public' and table_name='owner_settings'
                  and grantee = 'PUBLIC'), '(none)')),
    ('P03','priv','GATE: anon cannot SELECT, INSERT, UPDATE, DELETE or TRUNCATE',
      'false|false|false|false|false',
      concat_ws('|',
        pg_catalog.has_table_privilege('anon','public.owner_settings','SELECT')::text,
        pg_catalog.has_table_privilege('anon','public.owner_settings','INSERT')::text,
        pg_catalog.has_table_privilege('anon','public.owner_settings','UPDATE')::text,
        pg_catalog.has_table_privilege('anon','public.owner_settings','DELETE')::text,
        pg_catalog.has_table_privilege('anon','public.owner_settings','TRUNCATE')::text)),
    ('P04','priv','GATE: authenticated has SELECT|INSERT|UPDATE but NOT DELETE|TRUNCATE',
      'true|true|true|false|false',
      concat_ws('|',
        pg_catalog.has_table_privilege('authenticated','public.owner_settings','SELECT')::text,
        pg_catalog.has_table_privilege('authenticated','public.owner_settings','INSERT')::text,
        pg_catalog.has_table_privilege('authenticated','public.owner_settings','UPDATE')::text,
        pg_catalog.has_table_privilege('authenticated','public.owner_settings','DELETE')::text,
        pg_catalog.has_table_privilege('authenticated','public.owner_settings','TRUNCATE')::text)),
    ('P06','priv','GATE: the wrapper''s SECURITY DEFINER owner CAN select owner_settings',
      'true',
      -- THE SAME COUPLING A14 EXISTS FOR, one object further along. The helper
      -- is SECURITY INVOKER, so inside the definer wrapper it runs as the
      -- WRAPPER'S OWNER -- and that is the role that must be able to read this
      -- table. Ownership of the function and of the table are set
      -- independently, so they can drift apart, and when they do every other
      -- row in this file still passes while get_free_busy raises 42501
      -- "permission denied for table owner_settings" on the first cross-model
      -- window. That failure takes BUSY down with it, not just Available.
      --
      -- Found by an isolated-DB run where the wrapper belonged to the migration
      -- role and the table to postgres. Production has both as postgres (A14b),
      -- so this reads true there -- which is exactly why it has to be asserted
      -- rather than assumed.
      coalesce((select pg_catalog.has_table_privilege(w.proowner, 'public.owner_settings', 'SELECT')::text
                from wrp w), 'UNRESOLVED')),
    ('P07','priv','CONTEXT: owner of owner_settings (compare with A03)',
      null::text,
      (select pg_catalog.pg_get_userbyid(relowner)::text
       from pg_catalog.pg_class where oid = 'public.owner_settings'::regclass)),
    ('P05','priv','CONTEXT: service_role on owner_settings',
      null::text,
      coalesce((select string_agg(distinct privilege_type, ',' order by privilege_type)
                from information_schema.role_table_grants
                where table_schema='public' and table_name='owner_settings'
                  and grantee = 'service_role'), '(none)')),

    -- G. the trigger function ----------------------------------------------
    ('G01','trigger','GATE: the trigger function exists',
      'true',
      (to_regprocedure('timeweave_private.owner_settings_validate_timezone()') is not null)::text),
    ('G02','trigger','GATE: it lives in timeweave_private, not public',
      'timeweave_private',
      (select nspname from fn
       where oid = to_regprocedure('timeweave_private.owner_settings_validate_timezone()'))),
    ('G03','trigger','GATE: search_path pinned empty',
      'search_path=""',
      (select array_to_string(proconfig, ',') from fn
       where oid = to_regprocedure('timeweave_private.owner_settings_validate_timezone()'))),
    ('G04','trigger','GATE: SECURITY INVOKER -- it must not run as its owner',
      'false',
      (select prosecdef::text from fn
       where oid = to_regprocedure('timeweave_private.owner_settings_validate_timezone()'))),
    ('G05','trigger','GATE: it raises 0008''s marker, so clients need no new mapping',
      '1',
      (select count(*)::text from regexp_matches(
        (select body from fn where oid = to_regprocedure('timeweave_private.owner_settings_validate_timezone()')),
        'TIMEWEAVE_TZ_INVALID', 'g'))),
    ('G06','trigger','GATE: it consults public.timezone_is_supported',
      '1',
      (select count(*)::text from regexp_matches(
        (select body from fn where oid = to_regprocedure('timeweave_private.owner_settings_validate_timezone()')),
        'timezone_is_supported', 'g'))),

    -- F. fingerprints: ONE function changed --------------------------------
    ('F01','fingerprint','GATE: wrapper UNCHANGED (0025 must not touch it)',
      '3a46a5d13e13361744860f7f270f8fbe', (select md5(body) from wrp)),
    ('F02','fingerprint','GATE: core UNCHANGED',
      'a9b4097e4b390cee1229709945475d2b', (select md5(body) from cor)),
    ('F03','fingerprint','GATE: helper is the 0025 body',
      '23f069bd792768f9279f5308e3edbaaf', (select md5(body) from hlp)),
    ('F04','fingerprint','GATE: the helper is NOT still 0024''s',
      'false', (select (md5(body) = 'ac87ef2526ab12f0f7c4d8c2142bcbd0')::text from hlp)),
    ('F05','fingerprint','GATE: still exactly one helper overload',
      '1', (select count(*)::text from fn
            where nspname = 'timeweave_private' and proname = 'free_busy_available')),

    -- A. the helper's posture, preserved by CREATE OR REPLACE --------------
    ('A01','helper','GATE: NOT executable by public|anon|authenticated|service_role',
      'false|false|false|false',
      (select concat_ws('|',
        pg_catalog.has_function_privilege('public', oid, 'EXECUTE')::text,
        pg_catalog.has_function_privilege('anon', oid, 'EXECUTE')::text,
        pg_catalog.has_function_privilege('authenticated', oid, 'EXECUTE')::text,
        pg_catalog.has_function_privilege('service_role', oid, 'EXECUTE')::text) from hlp)),
    ('A02','helper','GATE: the wrapper owner CAN execute it (A14)',
      'true',
      coalesce((select pg_catalog.has_function_privilege(w.proowner, h.oid, 'EXECUTE')::text
                from wrp w, hlp h), 'UNRESOLVED')),
    ('A03','helper','CONTEXT: wrapper owner | helper owner',
      null::text,
      coalesce((select pg_catalog.pg_get_userbyid(w.proowner) from wrp w), '?')
      || ' | ' || coalesce((select pg_catalog.pg_get_userbyid(h.proowner) from hlp h), '?')),
    ('A04','helper','GATE: SECURITY INVOKER',
      'false', (select prosecdef::text from hlp)),
    ('A05','helper','GATE: STABLE',
      's', (select provolatile::text from hlp)),
    ('A06','helper','GATE: search_path pinned empty',
      'search_path=""', (select array_to_string(proconfig, ',') from hlp)),

    -- H. what the new body does and does not contain -----------------------
    ('H01','body','GATE: it reads owner_settings exactly once',
      '1', (select count(*)::text from regexp_matches((select body from hlp),
              'from public.owner_settings', 'g'))),
    ('H02','body','GATE: it NEVER reads the language column',
      '0',
      -- The structural guarantee that display language cannot reach Free/Busy.
      (select count(*)::text from regexp_matches((select body from hlp),
              'language', 'g'))),
    ('H03','body','GATE: it still never reads share_available (A12 of 0024)',
      '0', (select count(*)::text from regexp_matches((select body from hlp),
              'share_available', 'g'))),
    ('H04','body','GATE: the zone is re-checked with timezone_is_resolvable',
      '1', (select count(*)::text from regexp_matches((select body from hlp),
              'not public\.timezone_is_resolvable\(', 'g'))),
    ('H05','body','GATE: no offset is derived from the caller''s window',
      '0',
      -- The attack 0025 exists to refuse: an attacker-chosen offset could slide
      -- all-day Busy off a timed Available block. p_from must never be
      -- subtracted from p_from_date anywhere in this body.
      (select count(*)::text from regexp_matches((select body from hlp),
              'p_from_date::timestamp|p_from_date\s*-\s*p_from|p_from\s*-\s*p_from_date', 'g'))),
    ('H06','body','GATE: v_ok_tz is NOT used as the conversion zone',
      '0',
      (select count(*)::text from regexp_matches((select body from hlp),
              'at time zone\s+v_ok_tz|v_tz\s*:=\s*v_ok_tz', 'g'))),
    ('H07','body','GATE: the indeterminate constant is still reachable (fail-closed)',
      'true',
      (select ((select count(*) from regexp_matches((select body from hlp), 'return c_indet;', 'g')) >= 9)::text)),
    ('H08','body','GATE: the DST round-trip check is present',
      '1',
      (select count(*)::text from regexp_matches((select body from hlp),
              'at time zone v_tz\) at time zone v_tz\)::date', 'g'))),

    -- C. context for the operator -----------------------------------------
    ('C01','context','CONTEXT: owners who have declared a zone',
      null::text,
      (select count(*)::text from public.owner_settings where timezone is not null)),
    ('C02','context','CONTEXT: rows in owner_settings',
      null::text, (select count(*)::text from public.owner_settings)),
    ('C03','context','CONTEXT: share links opted in to Available',
      null::text,
      (select count(*)::text from public.share_links
       where share_available and revoked_at is null)),
    ('C04','context','CONTEXT: PUBLIC EXECUTE on the wrapper (compare with preflight B06)',
      null::text,
      pg_catalog.has_function_privilege('public',
        'public.get_free_busy(text, timestamptz, timestamptz, date, date)','EXECUTE')::text)

  ) as v(ord, phase, metric, expected, value)
)
select ord, phase, metric, expected, value, status from res
union all
-- P00 over EVERY row above. A summary that covers only some of its own checks
-- reads green while the rest fail, which is worse than a FAIL because nobody
-- looks twice at a zero.
select 'ZZZ', 'summary', 'FAIL rows across ALL checks (GO requires 0)', '0',
       (select count(*) filter (where status = 'FAIL') from res)::text,
       case when (select count(*) filter (where status = 'FAIL') from res) = 0
            then 'ok' else 'FAIL' end
order by ord;

rollback;
