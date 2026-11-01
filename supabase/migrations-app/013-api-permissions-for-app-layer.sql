-- =============================================================================
-- 013 — API permissions for the chuglii app layer
-- =============================================================================
-- Statements extracted from supabase/migrations/009-security-linter-fixes.sql
-- and supabase/migrations/011-api-role-permissions.sql: they reference chuglii
-- app tables/functions (user_premium, premium_purchases, site_settings,
-- performer_follows, user_notifications(+prefs), edge_cache,
-- claim_premium_reward, increment_viewer_count) that do not exist on a clean
-- platform-only database, so they cannot live in the boot-path migrations.
--
-- This folder is NOT part of the boot path. Apply the whole app layer, in
-- filename order, through the key-based bridge AFTER the chuglii schema is in
-- place:
--   ./remote.sh push-app          # supabase/migrations-app/*.sql
--   ./remote.sh push-app supabase/migrations-app/013-api-permissions-for-app-layer.sql
-- Tracked in the same public._schema_migrations table as everything else.
--
-- The file is deliberately SELF-GUARDED: applying it before (or without) the
-- table-creating migrations (002–008) skips the missing objects with a NOTICE
-- instead of aborting the rest of the batch. Re-run it once the schema exists
-- (`./remote.sh untrack 013-api-permissions-for-app-layer.sql && ./remote.sh
-- push-app`) to apply the grants.
-- =============================================================================

-- (from 009) keep callers from influencing name resolution of the reward RPC
DO $$
BEGIN
  IF to_regprocedure('public.claim_premium_reward(uuid,integer,integer)') IS NOT NULL THEN
    EXECUTE 'ALTER FUNCTION public.claim_premium_reward(uuid, integer, integer)
             SET search_path = public, pg_catalog';
  ELSE
    RAISE NOTICE '013: claim_premium_reward(uuid,integer,integer) is missing; skipping its search_path pin';
  END IF;
END $$;

-- (from 011) internal/app data tables: client access is limited to
-- authenticated owners; service_role access remains server-side and explicit.
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['user_premium', 'premium_purchases'] LOOP
    IF to_regclass('public.' || t) IS NULL THEN
      RAISE NOTICE '013: public.% is missing; skipping its grants', t;
      CONTINUE;
    END IF;
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT SELECT ON TABLE public.%I TO authenticated', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.%I TO service_role', t);
  END LOOP;
END $$;

-- Site settings are intentionally readable by clients, but writable only by
-- trusted server-side code.
DO $$
BEGIN
  IF to_regclass('public.site_settings') IS NULL THEN
    RAISE NOTICE '013: public.site_settings is missing; skipping its grants';
    RETURN;
  END IF;
  EXECUTE 'REVOKE ALL ON TABLE public.site_settings FROM PUBLIC, anon, authenticated';
  EXECUTE 'GRANT SELECT ON TABLE public.site_settings TO anon, authenticated';
  EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.site_settings TO service_role';
END $$;

-- Owner-scoped client data; anonymous API callers have no table privileges.
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['performer_follows', 'user_notifications', 'user_notification_preferences'] LOOP
    IF to_regclass('public.' || t) IS NULL THEN
      RAISE NOTICE '013: public.% is missing; skipping its grants', t;
      CONTINUE;
    END IF;
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.%I TO authenticated', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.%I TO service_role', t);
  END LOOP;
END $$;

-- Neither client roles nor service_role should access the internal cache table
-- through the Data API. RLS remains enabled as an additional boundary.
DO $$
BEGIN
  IF to_regclass('public.edge_cache') IS NULL THEN
    RAISE NOTICE '013: public.edge_cache is missing; skipping its grants';
    RETURN;
  END IF;
  EXECUTE 'REVOKE ALL ON TABLE public.edge_cache FROM PUBLIC, anon, authenticated, service_role';
  EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.edge_cache TO service_role';
END $$;

-- Mutating RPCs move rows with caller-supplied identifiers; the app routes
-- them through trusted server-side clients, so they stay service_role-only.
DO $$
BEGIN
  IF to_regprocedure('public.claim_premium_reward(uuid,integer,integer)') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON FUNCTION public.claim_premium_reward(uuid, integer, integer)
             FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.claim_premium_reward(uuid, integer, integer)
             TO service_role';
  ELSE
    RAISE NOTICE '013: claim_premium_reward(uuid,integer,integer) is missing; skipping its execute grants';
  END IF;
END $$;

DO $$
BEGIN
  IF to_regprocedure('public.increment_viewer_count(uuid)') IS NOT NULL THEN
    EXECUTE 'ALTER FUNCTION public.increment_viewer_count(uuid)
             SET search_path = pg_catalog, public';
    EXECUTE 'REVOKE ALL ON FUNCTION public.increment_viewer_count(uuid)
             FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.increment_viewer_count(uuid)
             TO service_role';
  ELSE
    RAISE NOTICE '013: increment_viewer_count(uuid) is missing; skipping its execute grants';
  END IF;
END $$;
