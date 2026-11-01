-- Keep API permissions opt-in for objects created by postgres in public.
-- (Platform-only file: the per-app-table grants that used to live here moved
-- to ../migrations-app/013-api-permissions-for-app-layer.sql, together with
-- the search-path pin of public.claim_premium_reward from 009, because they
-- reference chuglii app tables/functions that do not exist on a clean
-- platform-only database — keeping them here would fail every fresh boot.)
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON TABLES FROM anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON FUNCTIONS FROM anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- The migration tracker is internal: neither client roles nor service_role may
-- reach it through the Data API. RLS remains enabled as an additional boundary.
REVOKE ALL ON TABLE public._schema_migrations
  FROM PUBLIC, anon, authenticated, service_role;

-- The per-app-table grants (user_premium, premium_purchases, site_settings,
-- performer_follows, user_notifications(+prefs), edge_cache) and the
-- service_role-only execute grants for claim_premium_reward /
-- increment_viewer_count live in ../migrations-app/013-api-permissions-for-app-layer.sql
-- so a clean platform database never references missing app objects.
