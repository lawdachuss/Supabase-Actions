# Committed migrations (Supabase platform SQL only)

SQL files in this folder are applied **on top of the restored database** at the
start of every session (in filename order), tracked in
`public._schema_migrations` so each file runs only once.

Every file here must be **Supabase-platform SQL**: things the stack itself
needs on a clean, appless database (auth hook wiring, migration-tracker RLS,
API role defaults, platform hardening). Application SQL (chuglii tables, RPCs,
app RLS and API permissions) lives in [`../migrations-app/`](../migrations-app/)
and is applied explicitly through the key-based bridge (`./remote.sh`), never
at boot. Statements that reference app tables are guaranteed to fail a fresh
platform boot, so they never belong in this folder.

## Why this exists

- Fresh databases get the `volumes/db/*.sql` init scripts at first boot.
- **Restored** databases get their schema from the state backup instead — so any
  change you make after the backup was taken would be lost on the next session.
- Committed migrations here close that gap: they apply every session, in order,
  exactly once, and the tracking table is carried by the state backup itself.

## Usage

```bash
# 1. Create a new migration (number prefixes keep the order)
echo "ALTER TABLE public.users ADD COLUMN IF NOT EXISTS avatar_url text;" > supabase/migrations/002-avatar-url.sql

# 2. Commit + push — it applies automatically on the next session
```

- Prefix with a number for ordering: `001-…`, `002-…`, …
- Failed files are **not** marked applied — they retry next session until they
  succeed, so fix the SQL and re-commit.
- Destructive statements run too — that's the point of versioned migrations, but
  review before committing.

### Apply instantly from anywhere (no commit needed)

While a session is LIVE, the repo-root [`remote.sh`](../../remote.sh) pushes SQL
over HTTPS to the running instance; see the README's "Remote control" section.
Remote pushes and committed files share the same `public._schema_migrations`
tracking table, so they never double-apply, and both survive the 6-hour session
restarts.

## Included migrations

- `001-custom-access-token-hook.sql` — pass-through `public.custom_access_token_hook`
  (Supabase Auth hook). Enabled by default config only when
  `ENABLE_CUSTOM_ACCESS_TOKEN_HOOK=true` is set. Add your claims logic to the
  function body.
- `009-security-linter-fixes.sql` — pins function search paths and limits the
  custom access-token hook to `supabase_auth_admin`.
- `010-schema-migrations-rls.sql` — enables RLS and revokes API-role access to
  the migration tracker. The tracker table intentionally has no policies;
  ordinary API roles must not read it (`./remote.sh status` reads it server-side
  as the superuser instead).
- `011-api-role-permissions.sql` — revokes broad default grants for new public
  objects. New public objects now need deliberate grants before they
  are reachable through the Data API.
- `012-service-role-api-access.sql` — re-grants the admin (`service_role`) key
  the table/sequence/function access it needs, while leaving `anon` and
  `authenticated` locked down. Also keeps `_schema_migrations` private.

> **Tracker names are basenames.** A file in this folder and a file in
> `migrations-app/` must never share a name, or the second one is silently
> skipped as "already applied". App migrations keep their historic 002–008
> names; new app files should use an `app-` prefix or the next free number
> (014+).
