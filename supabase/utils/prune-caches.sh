#!/usr/bin/env bash
# =============================================================================
# 🧹 prune-caches.sh — prune stale GitHub Actions cache entries
# =============================================================================
# Each run saves its state archive to the Actions cache at shutdown (keys
# 'supabase-db-live-<run_id>-final'; GitHub doesn't expose cache-service env
# vars to run: steps, so mid-session uploads aren't possible). Over time those
# accumulate and can hit GitHub's 10GB per-repo cache cap. This keeps only the
# newest few of each family so the cache stays small while the restore step
# always has the freshest data available.
#
# Policy:
#   supabase-db-*    keep newest KEEP (default 3)  — state archives
#   docker-images-*  keep newest DOCKER_KEEP (default 2) — image tars
#                    (only present if the Docker cache is ever re-added)
#
# Requires:
#   GITHUB_TOKEN      - must have 'actions: write' (best-effort if not granted)
#   GITHUB_REPOSITORY - set automatically by the Actions runner
# =============================================================================
set -uo pipefail

# The workflow steps export GH_TOKEN (what `gh` reads) but this script has
# always read GITHUB_TOKEN — under `set -u` that aborted with
# "GITHUB_TOKEN: unbound variable" and NOTHING was ever pruned (32 stale
# state-cache entries piled up toward GitHub's 10GB eviction cap). Accept
# either name, and fail LOUDLY instead of silently doing nothing.
if [ -z "${GITHUB_TOKEN:-}" ]; then
  GITHUB_TOKEN="${GH_TOKEN:-}"
fi
export GITHUB_TOKEN
if [ -z "${GITHUB_TOKEN}" ]; then
  echo "::warning::prune-caches: no GITHUB_TOKEN/GH_TOKEN in env — cache pruning SKIPPED"
  exit 0
fi

export KEEP="${KEEP:-5}"
export DOCKER_KEEP="${DOCKER_KEEP:-2}"
API="https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/caches"

# prune <key-prefix> <keep>: delete all entries starting with <key-prefix>
# except the <keep> newest (sorted by created_at).
prune() {
  local prefix="$1" keep="$2"
  export KEEP="$keep"
  export PREFIX="$prefix"
  local ids
  # The REST API's `key` parameter is an EXACT key match, not a prefix — asking
  # for ?key=supabase-db- always returned zero entries, so nothing was ever
  # pruned and state archives piled up toward GitHub's 10 GB cap until GitHub
  # began evicting them. List the entries and match the prefix here instead.
  ids=$(curl -sS -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$API?per_page=100" 2>/dev/null | \
    python3 -c '
import sys, json, os
d = json.load(sys.stdin)
keep = int(os.environ.get("KEEP", "3"))
prefix = os.environ["PREFIX"]
entries = [c for c in d.get("actions_caches", []) if c["key"].startswith(prefix)]
entries.sort(key=lambda c: c["created_at"], reverse=True)
print("\n".join(str(c["id"]) for c in entries[keep:]))' 2>/dev/null || true)

  if [ -n "$ids" ]; then
    local n=0
    for ID in $ids; do
      curl -sS -X DELETE -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "$API/$ID" >/dev/null 2>&1 || true
      n=$((n + 1))
    done
    echo "🗑️  Pruned $n '${prefix}' cache entrie(s)"
  fi
}

prune "supabase-db-" "$KEEP"
prune "docker-images-" "$DOCKER_KEEP"
