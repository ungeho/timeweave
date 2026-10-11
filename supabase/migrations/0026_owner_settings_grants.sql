-- ============================================================================
-- TimeWeave migration 0026: take TRUNCATE back off public.owner_settings.
--
-- WHAT WENT WRONG IN 0025. It wrote
--
--     revoke all on table public.owner_settings from public;
--     revoke all on table public.owner_settings from anon;
--     grant select, insert, update on table public.owner_settings to authenticated;
--
-- and never revoked from `authenticated`. On this project a new table in the
-- `public` schema is handed `Dxtm` -- TRUNCATE, REFERENCES, TRIGGER, MAINTAIN --
-- by the schema's default privileges, which 0012 measured and recorded in its
-- own comments. The GRANT above is ADDITIVE, so it put `arw` on top of a `Dxtm`
-- that was already there. The result in production was
--
--     authenticated=arwDxtm/postgres
--
-- i.e. SELECT, INSERT, UPDATE as intended, DELETE correctly absent, and
-- TRUNCATE present by accident. 0025's own postflight caught it at P04.
--
-- WHY THIS MATTERS. TRUNCATE is NOT filtered by RLS -- 0019's comments record
-- the same point. Every policy on this table is scoped to `owner_id =
-- auth.uid()`, which makes a signed-in user unable to read or write anybody
-- else's row, and completely unable to stop them wiping the table: one
-- TRUNCATE removes every owner's declared time zone. That silently reverts
-- every owner to "undeclared", which fails closed for Available sharing rather
-- than disclosing anything -- so this is availability damage, not a leak -- but
-- it is damage any authenticated account could do to every other account.
--
-- WHY 0025 IS NOT EDITED. It has already been applied to production, and its
-- file is the record of what ran there (md5 f153cfc10817491de7481fa756fcf979).
-- Rewriting it would make the history disagree with the database for the sake
-- of three lines. A fresh chain applies 0025 and then 0026 and lands in the
-- same place production will.
--
-- 0004 ALREADY KNEW THIS. It revokes from anon AND authenticated before
-- granting anything on share_links. 0025 copied half of that.
-- ============================================================================

begin;

-- REVOKE FIRST, THEN GRANT. The order is the whole fix: `revoke all` clears
-- the default-privilege Dxtm along with everything else, and the grant then
-- states the three verbs the settings dialog actually needs. Doing it the
-- other way round reproduces the bug.
revoke all on table public.owner_settings from authenticated;
grant select, insert, update on table public.owner_settings to authenticated;

-- anon and PUBLIC were already handled by 0025 and are restated here so this
-- file is sufficient on its own -- a fresh database that somehow ran 0026
-- without 0025's grant block would still end up correct. Both are no-ops
-- against production.
revoke all on table public.owner_settings from public;
revoke all on table public.owner_settings from anon;

-- service_role keeps whatever the schema default gave it, exactly as 0004 left
-- it for share_links. It is the admin key: it bypasses RLS by design, so
-- withholding TRUNCATE from it would be a gesture rather than a control, and
-- tightening it here would make this table behave unlike every other table in
-- the schema for no gain. The postflight records its privileges as CONTEXT so
-- the value is visible rather than assumed.

commit;

-- Verify: expect authenticated=arw and no TRUNCATE for anyone but the owner.
select 'authenticated' as grantee,
       concat_ws('|',
         pg_catalog.has_table_privilege('authenticated','public.owner_settings','SELECT')::text,
         pg_catalog.has_table_privilege('authenticated','public.owner_settings','INSERT')::text,
         pg_catalog.has_table_privilege('authenticated','public.owner_settings','UPDATE')::text,
         pg_catalog.has_table_privilege('authenticated','public.owner_settings','DELETE')::text,
         pg_catalog.has_table_privilege('authenticated','public.owner_settings','TRUNCATE')::text) as s_i_u_d_t,
       'expect true|true|true|false|false' as expected
union all
select 'anon',
       concat_ws('|',
         pg_catalog.has_table_privilege('anon','public.owner_settings','SELECT')::text,
         pg_catalog.has_table_privilege('anon','public.owner_settings','INSERT')::text,
         pg_catalog.has_table_privilege('anon','public.owner_settings','UPDATE')::text,
         pg_catalog.has_table_privilege('anon','public.owner_settings','DELETE')::text,
         pg_catalog.has_table_privilege('anon','public.owner_settings','TRUNCATE')::text),
       'expect false|false|false|false|false';
