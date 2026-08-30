-- Fix "permission denied for table events".
--
-- RLS controls WHICH ROWS a user can access, but PostgREST's `authenticated`
-- role still needs table-level DML privileges to touch the table at all.
-- Because "Automatically expose new tables" was OFF at project creation, no
-- default GRANTs were applied. Grant the minimal DML to `authenticated` only;
-- the owner-only RLS policies remain the actual access control.
--
-- `anon` is intentionally NOT granted anything: login is required, and future
-- Free/Busy sharing will go through a SECURITY DEFINER RPC, never direct table
-- access.

-- Usually already present on the public schema, included for reproducibility
-- on projects where schema exposure was locked down.
grant usage on schema public to authenticated;

-- Minimal per-table privileges. RLS still restricts rows to owner_id = auth.uid().
grant select, insert, update, delete on table public.events to authenticated;
