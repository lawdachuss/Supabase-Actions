-- =============================================================================
-- 012 — restore the admin key's access, keep client roles opt-in
-- =============================================================================
-- 011 made every object created in public opt-in for ALL roles, service_role
-- included. Measured against a real PostgreSQL server (16.2):
--
--   image defaults      → new table: anon=t authenticated=t service_role=t
--   after 011           → new table: anon=f authenticated=f service_role=f
--   service_role on RLS → 3 rows (BYPASSRLS works: it skips policies, never GRANTs)
--
-- So the service_role key — the admin key used by ./remote.sh, server-side
-- clients and CI — got "ERROR: permission denied for table x" (SQLSTATE 42501)
-- on anything created after 011. This migration gives that key full control of
-- schema public while leaving anon and authenticated exactly as locked down as
-- 011 made them.
--
-- These grants are what the Data API (PostgREST) needs per object:
--   TABLES     SELECT/INSERT/UPDATE/DELETE
--   SEQUENCES  USAGE/SELECT — without it an INSERT into a serial column fails
--              with "permission denied for sequence x", even with the table grant
--   FUNCTIONS  EXECUTE — RPC calls
-- =============================================================================

-- Existing objects.
GRANT ALL ON ALL TABLES    IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO service_role;

-- Future objects, created by the migration runner / Studio / remote.sh, which
-- all write as postgres. 011 revokes these defaults, so re-grant them for the
-- admin key only. They live in pg_default_acl, which the state snapshot carries
-- (pg_dump emits them), so they survive the session restarts.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT ALL ON SEQUENCES TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT ALL ON FUNCTIONS TO service_role;

-- The blanket GRANT above reaches the migration tracker too. Keep it private:
-- it is an internal table, and service_role has BYPASSRLS, so only the GRANT
-- stands between it and the Data API. Use ./remote.sh status (the migrate
-- function talks to Postgres as the superuser) to read it.
REVOKE ALL ON TABLE public._schema_migrations FROM service_role;
