-- TimeWeave Phase 5a: share links for anonymous Free/Busy access.
--
-- Design (see README "セキュリティ方針"):
--   * A share link is a Free/Busy link: anonymous viewers see only opaque busy
--     intervals, never event details. The events table is NOT exposed to anon.
--   * Only a HASH of the token is stored (sha256, hex). The plaintext token is
--     generated server-side and returned exactly once at creation; it is never
--     stored or logged, so a DB leak cannot reconstruct working URLs.
--   * This table is reached ONLY through the SECURITY DEFINER functions added in
--     0005 (create/list/revoke + get_free_busy). No table privileges are granted
--     to `anon` or `authenticated`; RLS below is defense-in-depth.
--   * `include_private = false` lets an owner exclude their private events from
--     the busy set for a given link (default: include them, as opaque busy).

create extension if not exists pgcrypto;

create table public.share_links (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null default auth.uid()
                    references auth.users (id) on delete cascade,

  -- sha256(token) as hex. The plaintext token lives only in the share URL.
  token_hash      text not null unique,

  label           text,                          -- owner-facing memo (optional)
  include_private boolean not null default true, -- false => private excluded from busy

  expires_at      timestamptz,                   -- null = no expiry
  revoked_at      timestamptz,                   -- null = active; set to revoke

  created_at      timestamptz not null default now()
);

-- Owner-scoped listing, newest first.
create index share_links_owner_idx on public.share_links (owner_id, created_at desc);

-- Row Level Security: owner-only. This is defense-in-depth — the table carries
-- no role GRANTs, so it is normally reached only via the SECURITY DEFINER
-- functions in 0005 (which themselves filter by owner_id = auth.uid()).
alter table public.share_links enable row level security;

create policy share_links_owner_all on public.share_links
  for all
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

-- Make the security boundary explicit in the migration itself: neither anon nor
-- authenticated may touch this table directly. All access goes through the 0005
-- SECURITY DEFINER functions (create/list/revoke + get_free_busy). The owner-only
-- RLS policy above remains as defense-in-depth.
revoke all on table public.share_links from anon;
revoke all on table public.share_links from authenticated;
