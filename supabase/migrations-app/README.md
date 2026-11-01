# chuglii app-layer SQL (NOT part of the boot path)

SQL in this folder belongs to the **chuglii application database** (the
frontend + backend stack served at supabase.chuglii.in) — user tables, app
views/RPCs and app RLS/permissions. It is kept out of
`supabase/migrations/` on purpose:

- The self-hosted Supabase platform's boot path
  (`.github/workflows/supabase-host.yml` → "Apply committed migrations")
  applies ONLY `supabase/migrations/*.sql`, i.e. Supabase-system SQL
  (auth hook wiring, migration-tracker RLS, API role defaults).
- A clean platform-only database therefore boots without any app objects.
  The app layer is applied explicitly, over HTTPS, with the service role key
  (the anon key must never be used for DDL).

## Apply the app layer

These files are **incremental migrations on an existing app schema** — they are
not a bootstrap. `003` alters `watch_history`, and the RPCs read
`recordings`/`user_profiles`, so the base chuglii tables must already exist:

```bash
# 1. Restore the base app schema (user_profiles, watch_history, recordings, …).
#    From a schema dump / snapshot:
./remote.sh run - < schema.sql

# 2. Apply every app migration in order (002–008, then 013 permissions):
./remote.sh push-app

# or a single file:
./remote.sh push-app supabase/migrations-app/013-api-permissions-for-app-layer.sql
```

`002` (email backfill) and `013` (permissions) are self-guarded and skip with a
`NOTICE` when their objects are absent. `003` deliberately fails if
`watch_history` is missing: marking it applied without applying the columns
would silently lose them. A failed file is not tracked, so it retries on the
next `push-app`; the rest of the batch still runs.

Everything applied this way is tracked in the same
`public._schema_migrations` table as the platform migrations and is part of
the state archive, so it survives session restarts and restores.

## Persistence across the 5-hour handover

The app layer is ordinary database state, so the normal snapshot/restore path
covers it with no extra work:

- tables, RPCs, RLS policies, grants and sequence values live in the
  `postgres` database dump;
- the `public._schema_migrations` rows that mark 002–008/013 applied live in
  the same dump, so a restored session **skips** them instead of re-running;
- `service_role` / `anon` grants applied by `013` are carried by the dump
  (ACLs), and the default privileges from 011/012 are carried by
  `pg_default_acl`.

Two things are *not* in the database archive:

- **The SQL files themselves** — they come from git. Commit
  `supabase/migrations-app/*.sql` before the session ends, or the next run has
  the objects but not the file that created them.
- **A push made in the last few minutes of a session** — the tracker row only
  exists in the next archive after the next 5-minute snapshot. If the session
  dies first, re-run `./remote.sh push-app`; every file here is idempotent
  (`CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`,
  `DROP POLICY IF EXISTS` before `CREATE POLICY`, `ON CONFLICT DO NOTHING`).

`supabase/utils/audit-restore.sh` (run in CI by `audit-restore.yml`) asserts
that tracker rows, database-level GUCs, default privileges and the `_supabase`
database all come back from a real dump/restore cycle.

## Rules

- **Never** put app SQL in `supabase/migrations/` — a fresh platform boot has
  no app tables, so the migration would fail every session.
- **Do not reuse a platform migration number.** The tracker keys on the file
  *basename* only, so an app file named `009-…` would collide with the platform
  `009-…` and be skipped. Existing app files keep their historic 002–008 names
  (their tracker rows are already valid); new app files should use an `app-`
  prefix or the next free number (014+).
- `013` is self-guarded: it skips missing tables/functions with a `NOTICE`
  instead of aborting. If you apply it before the schema exists, untrack and
  re-run it afterwards:
  `./remote.sh untrack 013-api-permissions-for-app-layer.sql && ./remote.sh push-app`.

## History

Files 002–008 were removed from the boot path (they had been committed as
application migrations by mistake, as was the app part of 009/011 — now
extracted into 013). Their tracker rows on already-migrated instances remain
valid; nothing re-applies.
