#!/usr/bin/env bash
# =============================================================================
#  🧪 audit-restore.sh — prove the state snapshot actually restores
# =============================================================================
# Runs the persistence path end to end against a REAL PostgreSQL server, the
# way a session handover does it:
#
#   session 1  fresh cluster -> roles + custom role + 3 databases + data
#              -> dump with the exact commands from utils/snapshot-state.sh
#   session 2  fresh cluster (new runner) that only has the image-managed roles
#              -> preflight -> globals via the workflow's awk filter
#              -> per-DB pg_restore --create --clean -> ALTER DATABASE OWNER
#              -> assert the data, ownership and roles came back
#
# It also asserts the persistence contract the 5-hour handover depends on:
# migration-tracker rows, database-level GUCs (ALTER DATABASE ... SET),
# restored ALTER DEFAULT PRIVILEGES (pg_default_acl) and the contents of the
# second database (_supabase), not just its owner.
#
# Why it exists: the restore path silently produced an EMPTY database once
# (a db owned by a non-superuser failed "permission denied to create database",
# which aborted the whole restore), and the globals filter dropped memberships
# whose grantee was a managed role. Both are asserted below, so a regression
# fails CI instead of surfacing as "my data vanished" after a handover.
#
# Usage:
#   bash supabase/utils/audit-restore.sh                     # docker (default in CI)
#   AUDIT_BACKEND=local bash supabase/utils/audit-restore.sh
#   AUDIT_PGBIN=/usr/lib/postgresql/17/bin ... AUDIT_BACKEND=local ...
#
# Env:
#   AUDIT_BACKEND   docker | local   (default: docker when usable, else local)
#   AUDIT_IMAGE     image for the docker backend      (default postgres:17)
#   AUDIT_PGBIN     dir with initdb/pg_ctl/psql/...   (local backend)
#   AUDIT_PORT      first port for the local backend  (default 55432)
#   AUDIT_KEEP_WORK 1 = keep the temp dir (logs) when the audit fails
#   AUDIT_WORK_ROOT  parent dir for the temp dir (default: $TMPDIR or /tmp).
#                    CI points it at runner.temp so the artifact step can find
#                    the kept dir without guessing where TMPDIR was.
#
# Exit status: 0 when every check passes, 1 otherwise. Nothing outside the temp
# dir and the two throwaway clusters/containers is touched.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WF="$ROOT/.github/workflows/supabase-host.yml"
SNAPSHOT_SH="$ROOT/supabase/utils/snapshot-state.sh"
IMAGE="${AUDIT_IMAGE:-postgres:17}"
PORT1="${AUDIT_PORT:-55432}"
PORT2=$((PORT1 + 1))
WORKROOT="${AUDIT_WORK_ROOT:-${TMPDIR:-/tmp}}"
WORK="$(mktemp -d "$WORKROOT/audit-restore.XXXXXX")" || exit 1
mkdir -p "$WORK/db-backups"

FAILS=0
CHECKS=0
pass() { CHECKS=$((CHECKS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
info() { printf '\n== %s\n' "$1"; }
# Infrastructure crashes (no cluster, unreadable workflow, missing tool) count
# as failures too, so AUDIT_KEEP_WORK keeps the evidence for those exits as well.
die() { echo "AUDIT ERROR: $*" >&2; FAILS=1; exit 1; }

cleanup() {
  local s
  for s in 1 2; do
    if [ "${BACKEND:-}" = "docker" ]; then
      docker rm -f "$(cname "$s")" >/dev/null 2>&1 || true
    elif [ "${BACKEND:-}" = "local" ] && [ -d "$WORK/pg$s" ]; then
      pg_ctl -D "$WORK/pg$s" -m immediate -w stop >/dev/null 2>&1 || true
    fi
  done
  if [ "${AUDIT_KEEP_WORK:-0}" = "1" ] && [ "${FAILS:-0}" -gt 0 ]; then
    printf '\nwork dir kept for inspection: %s\n' "$WORK"
    return
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM   # route signals through the EXIT handler, or a cancelled
                           # audit orphans its local postgres clusters

# ── backend ─────────────────────────────────────────────────────────────────
# PID suffix: two audits running at once (two terminals, or two jobs on one
# shared docker daemon) must not fight over one set of container names.
cname() { printf 'audit-restore-%s-%s' "$$" "$1"; }
aport() { if [ "$1" = "1" ]; then printf '%s' "$PORT1"; else printf '%s' "$PORT2"; fi; }

BACKEND="${AUDIT_BACKEND:-}"
if [ -z "$BACKEND" ]; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    BACKEND=docker
  else
    BACKEND=local
  fi
fi

if [ "$BACKEND" = "local" ]; then
  [ -n "${AUDIT_PGBIN:-}" ] && PATH="$AUDIT_PGBIN:$PATH" && export PATH
  for b in initdb pg_ctl psql pg_dump pg_dumpall pg_restore; do
    command -v "$b" >/dev/null 2>&1 || die "missing '$b' for the local backend (set AUDIT_PGBIN)"
  done
else
  command -v docker >/dev/null 2>&1 || die "the docker backend needs docker"
fi
# python3 extracts the globals awk filter from the workflow and base64s the
# manifest fields, so it is required no matter which backend runs.
command -v python3 >/dev/null 2>&1 || die "python3 is required (globals-filter extraction + manifest base64)"

# Every server interaction goes through pq, so the audit logic is identical for
# both backends. Containers run the client tools themselves (no host psql).
pq() { # pq <session> <cmd...>
  local s="$1"; shift
  if [ "$BACKEND" = "docker" ]; then
    docker exec -i "$(cname "$s")" "$@"
  else
    PGHOST=127.0.0.1 PGPORT="$(aport "$s")" "$@"
  fi
}

start_cluster() { # start_cluster <session>
  local s="$1" i
  if [ "$BACKEND" = "docker" ]; then
    docker rm -f "$(cname "$s")" >/dev/null 2>&1 || true
    docker run -d --rm --name "$(cname "$s")" \
      -e POSTGRES_PASSWORD=audit -e POSTGRES_HOST_AUTH_METHOD=trust \
      "$IMAGE" >/dev/null || return 1
    for i in $(seq 1 60); do
      docker exec "$(cname "$s")" pg_isready -U postgres >/dev/null 2>&1 && return 0
      sleep 1
    done
    echo "container $(cname "$s") ($IMAGE) never became ready; last log lines:" >&2
    docker logs --tail 15 "$(cname "$s")" 2>&1 | sed 's/^/    /' >&2 || true
    return 1
  fi
  initdb -D "$WORK/pg$s" -U postgres --encoding=UTF8 --locale=C -A trust >"$WORK/initdb$s.log" 2>&1 || return 1
  printf "port = %s\nlisten_addresses = '127.0.0.1'\n" "$(aport "$s")" >> "$WORK/pg$s/postgresql.conf"
  pg_ctl -D "$WORK/pg$s" -l "$WORK/pg$s.log" -w start >/dev/null 2>&1
}

q() { # q <session> <db> <sql> -> single trimmed FIRST row (keep queries single-row)
  pq "$1" psql -X -U postgres -Atq -d "$2" -c "$3" 2>/dev/null | tr -d '\r' | head -1
}

# base64 via python3 (already required above): the -w0 / -d flags used before
# are GNU-only and macOS/BSD base64 rejects them, which broke the snapshot
# stage there.
b64e() {
  printf '%s' "$1" | python3 -c 'import base64, sys; sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode())'
}
b64d() {
  printf '%s' "$1" | python3 -c 'import base64, sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.buffer.read()))'
}

put_file() { # put_file <session> <host file> -> path the server can read
  # Mirrors the workflow's `docker compose cp` before pg_restore: --jobs cannot
  # read an archive from stdin, so the dump has to exist server-side.
  local s="$1" f="$2" b
  b=$(basename "$f")
  if [ "$BACKEND" = "docker" ]; then
    docker cp "$f" "$(cname "$s"):/tmp/$b" >/dev/null || return 1
    printf '/tmp/%s' "$b"
  else
    printf '%s' "$f"
  fi
}
tpriv() { q "$1" postgres "select has_table_privilege('$2','$3','SELECT')"; }

echo "=============================================================="
if [ "$BACKEND" = "docker" ]; then
  echo " restore audit  (backend: docker, image: $IMAGE)"
else
  echo " restore audit  (backend: local)"
fi
echo "=============================================================="

# ── drift guard: the dump flags this audit exercises must still be the ones
#    snapshot-state.sh uses, or the audit would be testing a fiction.
for needle in '--format=custom --compress=6 --create' 'pg_dumpall' 'pg_restore --list'; do
  grep -qF -- "$needle" "$SNAPSHOT_SH" \
    || die "snapshot-state.sh no longer contains '$needle' — this audit would test the wrong dump"
done
# ...and the restore role/flags the workflow uses must be the ones this audit
# exercises — the live chain proved Role matters when `postgres` turned out not
# to be a superuser on the real image.
for needle in 'pg_restore -U supabase_admin' '--clean --if-exists --create --disable-triggers --exit-on-error --jobs 2'; do
  grep -qF -- "$needle" "$WF" \
    || die "the workflow's restore command no longer contains '$needle' — mirror it here before trusting this audit"
done

# ── platform/app split guard: supabase/migrations/ is replayed on a fresh
#    platform-only database at every session start. If any of those files
#    references a chuglii app object, the whole file fails on a cache miss and
#    its grants never apply. That is exactly the bug this split fixed, so make
#    a regression fail CI instead of a fresh boot.
info "platform migrations must not reference app-layer objects"
APP_OBJECT_RE='(user_premium|premium_purchases|site_settings|performer_follows|user_notifications|user_notification_preferences|edge_cache|claim_premium_reward|increment_viewer_count|watch_history|user_profiles)'
APP_HITS=""
for f in "$ROOT"/supabase/migrations/*.sql; do
  [ -e "$f" ] || continue
  # Ignore SQL comments: they may name the app objects to explain the split.
  hit=$(sed 's/--.*$//' "$f" | grep -nEi "$APP_OBJECT_RE" || true)
  [ -z "$hit" ] || APP_HITS="${APP_HITS}$(basename "$f"):${hit}"$'\n'
done
if [ -z "$APP_HITS" ]; then
  pass "platform migrations reference no app-layer objects"
else
  fail "platform migrations reference app-layer objects (move them to migrations-app/)"
  printf '%s' "$APP_HITS" | head -10 | sed 's/^/       /'
fi

# ── pull the globals awk filter straight out of the workflow, so editing the
#    filter there immediately changes what this audit exercises.
python3 - "$WF" "$WORK/filter.awk" <<'PY' || die "could not extract the workflow's globals awk filter"
import sys
lines = open(sys.argv[1], encoding='utf-8').read().splitlines()
try:
    start = next(i for i, l in enumerate(lines) if "if ! awk '" in l) + 1
    end = next(i for i, l in enumerate(lines)
               if i > start and 'globals.sql' in l and 'GLOBAL_RESTORE_FILE' in l)
except StopIteration:
    sys.exit("could not locate the globals awk filter in the workflow "
             "(no 'if ! awk' marker, or the globals.sql redirect line is missing)")
body = [l.strip() for l in lines[start:end] if l.strip()]
if not body:
    sys.exit('could not extract the globals awk filter from the workflow')
open(sys.argv[2], 'w', encoding='utf-8', newline='\n').write("\n".join(body) + "\n")
PY

# ── roles the supabase image creates at container start; tolerant so this also
#    works against supabase/postgres (where they already exist).
MANAGED_ROLES_SQL=$(cat <<'SQL'
DO $$ BEGIN CREATE ROLE anon NOLOGIN NOINHERIT; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE authenticated NOLOGIN NOINHERIT; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE authenticator LOGIN NOINHERIT PASSWORD 'audit'; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE dashboard_user NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE pgbouncer NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE supabase_admin LOGIN SUPERUSER PASSWORD 'audit'; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE supabase_realtime_admin NOINHERIT CREATEROLE REPLICATION; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE supabase_replication_admin NOINHERIT REPLICATION; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
GRANT anon, authenticated, service_role TO authenticator;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
SQL
)

ensure_db() { # ensure_db <session> <name> <owner>
  if [ "$(q "$1" postgres "select 1 from pg_database where datname='$2'")" != "1" ]; then
    pq "$1" psql -X -U postgres -q -d postgres -c "CREATE DATABASE \"$2\" OWNER \"$3\"" >/dev/null 2>&1
  fi
}

echo
echo "--------------------------------------------------------------"
echo " SESSION 1 — populate, then snapshot"
echo "--------------------------------------------------------------"
start_cluster 1 || die "could not start cluster 1"
info "postgres: $(q 1 postgres 'select version()' | cut -c1-40)"

pq 1 psql -X -U postgres -q -v ON_ERROR_STOP=1 -d postgres <<< "$MANAGED_ROLES_SQL" >/dev/null 2>&1 \
  || fail "managed roles / schema grants did not apply"
pq 1 psql -X -U postgres -q -v ON_ERROR_STOP=1 -d postgres <<'SQL' >/dev/null 2>&1
DO $$ BEGIN CREATE ROLE app_owner LOGIN PASSWORD 'app-secret' NOINHERIT; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
GRANT app_owner TO authenticated;
SQL
ensure_db 1 _supabase supabase_admin
ensure_db 1 _analytics supabase_admin
ensure_db 1 appdb app_owner

pq 1 psql -X -U postgres -q -v ON_ERROR_STOP=1 -d postgres <<'SQL' >/dev/null 2>&1
CREATE TABLE IF NOT EXISTS public.notes (
  id bigserial PRIMARY KEY, body text, owner text DEFAULT current_user,
  created timestamptz DEFAULT now());
INSERT INTO public.notes (body) SELECT 'note ' || g FROM generate_series(1,1000) g;
CREATE INDEX IF NOT EXISTS notes_owner_idx ON public.notes (owner);
CREATE OR REPLACE VIEW public.notes_recent AS SELECT * FROM public.notes WHERE id > 900;
CREATE OR REPLACE FUNCTION public.count_notes() RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM public.notes $$;
CREATE TABLE IF NOT EXISTS public.secrets (id int PRIMARY KEY, v text);
ALTER TABLE public.secrets ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN CREATE POLICY p_secrets ON public.secrets FOR SELECT TO authenticated USING (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
INSERT INTO public.secrets VALUES (1,'s1') ON CONFLICT DO NOTHING;
CREATE SEQUENCE IF NOT EXISTS public.order_seq START 5000;
SELECT nextval('public.order_seq') FROM generate_series(1,7);
CREATE TABLE IF NOT EXISTS public.parent (id int PRIMARY KEY);
CREATE TABLE IF NOT EXISTS public.child (id int PRIMARY KEY, pid int REFERENCES public.parent(id));
INSERT INTO public.parent VALUES (1),(2) ON CONFLICT DO NOTHING;
INSERT INTO public.child VALUES (10,1),(11,2) ON CONFLICT DO NOTHING;
CREATE OR REPLACE FUNCTION public.touch() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.body := NEW.body; RETURN NEW; END $$;
DROP TRIGGER IF EXISTS notes_touch ON public.notes;
CREATE TRIGGER notes_touch BEFORE INSERT ON public.notes FOR EACH ROW EXECUTE FUNCTION public.touch();

-- Migration tracker (platform + app layers share it). Its rows must survive,
-- or every committed/applied migration re-runs on the next session.
CREATE TABLE IF NOT EXISTS public._schema_migrations (
  name text PRIMARY KEY, applied_at timestamptz DEFAULT now());
INSERT INTO public._schema_migrations (name) VALUES
  ('001-custom-access-token-hook.sql'),
  ('013-api-permissions-for-app-layer.sql')
ON CONFLICT DO NOTHING;

-- Database-level GUCs (volumes/db/jwt.sql uses ALTER DATABASE ... SET).
ALTER DATABASE postgres SET "app.settings.jwt_exp" = '3600';

-- Default privileges (migrations 011/012) live in pg_default_acl; a restored
-- database must still grant service_role on tables created afterwards.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT SELECT ON TABLES TO service_role;
SQL
pq 1 psql -X -U postgres -q -v ON_ERROR_STOP=1 -d _supabase <<'SQL' >/dev/null 2>&1
CREATE SCHEMA IF NOT EXISTS _analytics;
CREATE TABLE IF NOT EXISTS _analytics.logs (id bigserial PRIMARY KEY, event text);
INSERT INTO _analytics.logs (event)
  SELECT 'e' || g FROM generate_series(1,3) g
  WHERE NOT EXISTS (SELECT 1 FROM _analytics.logs);
SQL
pq 1 psql -X -U postgres -q -v ON_ERROR_STOP=1 -d appdb <<'SQL' >/dev/null 2>&1
CREATE TABLE IF NOT EXISTS public.widgets (id serial PRIMARY KEY, label text);
INSERT INTO public.widgets (label) SELECT 'w' || g FROM generate_series(1,42) g
  WHERE NOT EXISTS (SELECT 1 FROM public.widgets);
ALTER TABLE public.widgets OWNER TO app_owner;
SQL

info "snapshot with snapshot-state.sh's commands"
pq 1 pg_dumpall -U postgres --globals-only > "$WORK/db-backups/globals.sql" 2>/dev/null \
  || { fail "pg_dumpall --globals-only failed"; exit 1; }
pq 1 psql -X -U postgres -Atq -d postgres \
  -c "SELECT datname || '|' || pg_get_userbyid(datdba) FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname" \
  2>/dev/null | tr -d '\r' > "$WORK/db_list.txt"
: > "$WORK/db-backups/manifest.tsv"
IDX=0
while IFS='|' read -r N O; do
  [ -n "$N" ] || continue
  IDX=$((IDX + 1))
  F=$(printf 'db-%08d.dump' "$IDX")
  # < /dev/null HERE and in the preflight loop: `docker exec -i` drains its
  # stdin when the child doesn't read it, which consumed the enclosing
  # read-loop's file — the first CI docker run failed with exactly this and
  # only snapshotted the first database in the list.
  pq 1 pg_dump -U postgres --format=custom --compress=6 --create --dbname="$N" \
    </dev/null > "$WORK/db-backups/$F" 2>/dev/null \
    || { fail "pg_dump failed for $N"; exit 1; }
  pq 1 pg_restore -U postgres --list < "$WORK/db-backups/$F" >/dev/null 2>&1 \
    || { fail "dump validation failed for $N"; exit 1; }
  printf '%s\t%s\t%s\n' "$F" "$(b64e "$N")" "$(b64e "$O")" \
    >> "$WORK/db-backups/manifest.tsv"
done < "$WORK/db_list.txt"
[ "$IDX" -ge 3 ] && pass "snapshot: $IDX databases dumped and validated" || fail "snapshot produced only $IDX dump(s)"

echo
echo "--------------------------------------------------------------"
echo " SESSION 2 — fresh cluster, restore from the snapshot"
echo "--------------------------------------------------------------"
if [ "$BACKEND" = "docker" ]; then
  docker rm -f "$(cname 1)" >/dev/null 2>&1 || true
else
  pg_ctl -D "$WORK/pg1" -m immediate -w stop >/dev/null 2>&1 || true
fi
start_cluster 2 || die "could not start cluster 2"
pq 2 psql -X -U postgres -q -v ON_ERROR_STOP=1 -d postgres <<< "$MANAGED_ROLES_SQL" >/dev/null 2>&1

[ "$(q 2 postgres "select count(*) from pg_roles where rolname='app_owner'")" = "0" ] \
  && pass "fresh cluster: custom role app_owner absent (it must come back from globals)" \
  || fail "fresh cluster already had app_owner"

info "preflight — pg_restore --list dbname must match the manifest"
PF=1
while IFS=$'\t' read -r D NB _OB; do
  [ -n "$D" ] || continue
  WANT=$(b64d "$NB")
  SP=$(put_file 2 "$WORK/db-backups/$D") || { PF=0; continue; }
  GOT=$(pq 2 pg_restore -U postgres --list "$SP" </dev/null 2>/dev/null \
        | sed -n -e 's/^;[[:space:]]*dbname: //p' -e 's/^; Database: //p' | tr -d '\r')
  [ "$WANT" = "$GOT" ] || { PF=0; printf '       %s: manifest=%s dump=%s\n' "$D" "$WANT" "$GOT"; }
done < "$WORK/db-backups/manifest.tsv"
[ "$PF" = "1" ] && pass "preflight dbname check" || fail "preflight dbname check"

info "globals — the workflow's own awk filter"
awk -f "$WORK/filter.awk" "$WORK/db-backups/globals.sql" > "$WORK/globals.filtered.sql" 2>"$WORK/awk.err" \
  && pass "filter ran ($(wc -l < "$WORK/globals.filtered.sql" | tr -d ' ') of $(wc -l < "$WORK/db-backups/globals.sql" | tr -d ' ') lines kept)" \
  || fail "awk filter errored: $(cat "$WORK/awk.err")"
pq 2 psql -X -U supabase_admin -q -d postgres < "$WORK/globals.filtered.sql" > "$WORK/globals.log" 2>&1 || true
GLOBAL_ERRORS=$(grep -i 'ERROR:' "$WORK/globals.log" 2>/dev/null \
  | grep -viE 'role ".*" already exists|tablespace ".*" already exists' || true)
[ -z "$GLOBAL_ERRORS" ] && pass "globals replayed without unexpected ERROR" \
  || { fail "globals replay errors"; printf '%s\n' "$GLOBAL_ERRORS" | head -5 | sed 's/^/       /'; }

info "databases — pg_restore --create --clean as a superuser"
RESTORE_FAILED=0
while IFS=$'\t' read -r D NB OB; do
  [ -n "$D" ] || continue
  N=$(b64d "$NB")
  O=$(b64d "$OB")
  SP=$(put_file 2 "$WORK/db-backups/$D") || { fail "could not stage $D server-side"; RESTORE_FAILED=1; continue; }
  pq 2 dropdb -U supabase_admin --maintenance-db=template1 --if-exists --force "$N" </dev/null >/dev/null 2>&1 || true
  if pq 2 pg_restore -U supabase_admin --clean --if-exists --create --disable-triggers \
       --exit-on-error --jobs 2 -d template1 "$SP" </dev/null > "$WORK/r_$N.log" 2>&1; then
    A=0
    printf '%s\n' 'ALTER DATABASE :"db_name" OWNER TO :"db_owner";' \
      | pq 2 psql -X -U supabase_admin -q -d template1 -v ON_ERROR_STOP=1 -v "db_name=$N" -v "db_owner=$O" \
        > "$WORK/a_$N.log" 2>&1 || A=$?
    if [ "$A" -eq 0 ]; then
      pass "restored $N (owner $O)"
    else
      fail "owner step failed for $N: $(head -2 "$WORK/a_$N.log" | tr '\n' ' ')"
      RESTORE_FAILED=1
    fi
  else
    fail "pg_restore failed for $N: $(grep -m1 -i error "$WORK/r_$N.log" | cut -c1-100)"
    RESTORE_FAILED=1
  fi
done < "$WORK/db-backups/manifest.tsv"
[ "$RESTORE_FAILED" = "0" ] && pass "every database restored (incl. one owned by a non-superuser)" \
                            || fail "at least one database did not restore"

info "verify the restored state"
chk() { # chk <label> <db> <sql> <expected>
  local got; got=$(q 2 "$2" "$3")
  [ "$got" = "$4" ] && pass "$1 ($got)" || fail "$1 expected [$4] got [$got]"
}
chk "postgres: rows survived"           postgres "select count(*) from public.notes"                          1000
chk "postgres: sequence value survived" postgres "select last_value from public.order_seq"                    5006
chk "postgres: view restored"           postgres "select count(*) from public.notes_recent"                 100
chk "postgres: function restored"       postgres "select public.count_notes()"                               1000
chk "postgres: index restored"          postgres "select count(*) from pg_indexes where indexname='notes_owner_idx'" 1
chk "postgres: RLS policy restored"     postgres "select count(*) from pg_policies where policyname='p_secrets'"     1
chk "postgres: FK restored"             postgres "select count(*) from pg_constraint where conname='child_pid_fkey'" 1
chk "postgres: trigger restored"        postgres "select count(*) from pg_trigger where tgname='notes_touch'"        1
chk "postgres: table owner kept"        postgres "select tableowner from pg_tables where tablename='notes'"  postgres
chk "appdb: rows survived"              appdb    "select count(*) from public.widgets"                       42
chk "appdb: database owner"             postgres "select pg_get_userbyid(datdba) from pg_database where datname='appdb'" app_owner
chk "_supabase: owner"                  postgres "select pg_get_userbyid(datdba) from pg_database where datname='_supabase'" supabase_admin
chk "custom role restored"              postgres "select count(*) from pg_roles where rolname='app_owner'"  1
chk "custom role kept LOGIN"            postgres "select rolcanlogin from pg_roles where rolname='app_owner'" t
chk "managed roles intact"              postgres "select count(*) from pg_roles where rolname in ('anon','authenticated','service_role','authenticator','supabase_admin')" 5
chk "membership app_owner->authenticated" postgres "select count(*) from pg_auth_members m join pg_roles r on r.oid=m.roleid join pg_roles g on g.oid=m.member where r.rolname='app_owner' and g.rolname='authenticated'" 1

# ── persistence contract: everything the 5-hour handover depends on ──────────
# These are the pieces that, if dropped, silently re-run migrations or break
# the API on the next session instead of failing loudly.
chk "postgres: migration tracker survived" postgres \
  "select count(*) from public._schema_migrations where name='013-api-permissions-for-app-layer.sql'" 1
chk "postgres: tracker keeps platform rows" postgres \
  "select count(*) from public._schema_migrations where name='001-custom-access-token-hook.sql'" 1
chk "postgres: database-level GUC survived" postgres \
  "select current_setting('app.settings.jwt_exp', true)" 3600
chk "_supabase: rows survived" _supabase \
  "select count(*) from _analytics.logs" 3

# pg_default_acl: create a table AFTER the restore and check the restored
# default privilege still applies to it.
pq 2 psql -X -U postgres -q -v ON_ERROR_STOP=1 -d postgres \
  -c "CREATE TABLE IF NOT EXISTS public.dp_probe (id int)" >/dev/null 2>&1
chk "postgres: default privileges survived" postgres \
  "select has_table_privilege('service_role','public.dp_probe','SELECT')" t

echo
echo "=============================================================="
if [ "$FAILS" -eq 0 ]; then
  printf ' RESULT: %d/%d checks passed\n' "$CHECKS" "$CHECKS"
else
  printf ' RESULT: %d of %d checks FAILED\n' "$FAILS" "$CHECKS"
fi
echo "=============================================================="
exit $([ "$FAILS" -eq 0 ] && echo 0 || echo 1)
