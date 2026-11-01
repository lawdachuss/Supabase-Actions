#!/usr/bin/env node
// =============================================================================
// 💾 save-actions-cache.cjs — mid-job real-time GitHub Actions Cache saver
// =============================================================================
// Directly commits the current state archive (supabase-state.tar.gz) into the
// GitHub Actions Cache while the session is actively running.
//
// Uses @actions/cache to communicate directly with GitHub's cache service using
// the ACTIONS_RUNTIME_TOKEN and ACTIONS_RESULTS_URL / ACTIONS_CACHE_URL exposed
// to the workflow environment.
//
// Key format: supabase-db-live-<run_id>-slot-<slot>
// Prefix:     supabase-db-live- (matches restore-keys in restore step)
// =============================================================================

const fs = require('fs');
const path = require('path');

async function main() {
  const archivePath = process.argv[2] || path.join(__dirname, '..', 'supabase-state.tar.gz');
  const runId = process.env.GITHUB_RUN_ID || 'manual';
  const slot = process.env.SLOT || Math.floor(Date.now() / 1000);
  const key = `supabase-db-live-${runId}-slot-${slot}`;

  if (!fs.existsSync(archivePath)) {
    console.log(`[actions-cache] Archive ${archivePath} does not exist; skipping cache save`);
    return;
  }

  // Route caching requests to v2 Results service and avoid dead v1 endpoint
  delete process.env.ACTIONS_CACHE_URL;
  if (process.env.ACTIONS_RESULTS_URL) {
    process.env.ACTIONS_CACHE_SERVICE_V2 = 'true';
  }

  // Intercept raw HTML/503 errors from @actions/core warning logger
  try {
    const core = require('@actions/core');
    if (core && typeof core.warning === 'function') {
      const origWarning = core.warning.bind(core);
      core.warning = (msg, ...args) => {
        if (typeof msg === 'string' && (msg.includes('Our services') || msg.includes('503') || msg.includes('<!DOCTYPE') || msg.includes('<html') || msg.includes('<h2>'))) {
          console.log('[actions-cache] ℹ️ In-job cache service returned 503; persistent state is preserved by Cloudflare KV + GitHub Releases');
          return;
        }
        origWarning(msg, ...args);
      };
    }
  } catch (_) {}

  let cache;
  try {
    cache = require('@actions/cache');
  } catch (err) {
    console.log(`[actions-cache] @actions/cache not installed; skipping mid-job cache save (${err.message})`);
    return;
  }

  if (typeof cache.isFeatureAvailable === 'function' && !cache.isFeatureAvailable()) {
    console.log('[actions-cache] GitHub Actions cache service not available in current environment');
    return;
  }

  // Ensure path is relative to repository root for consistency with actions/cache/restore
  const repoRoot = path.resolve(__dirname, '..', '..');
  const relativePath = path.relative(repoRoot, path.resolve(archivePath)).replace(/\\/g, '/');

  const archiveStat = fs.statSync(archivePath);
  const sizeMb = (archiveStat.size / (1024 * 1024)).toFixed(2);
  console.log(`[actions-cache] 🚀 Uploading real-time cache entry (${sizeMb} MB) with key: ${key}...`);

  try {
    const cwd = process.cwd();
    process.chdir(repoRoot);
    const cacheId = await cache.saveCache([relativePath], key);
    process.chdir(cwd);
    if (cacheId && cacheId !== -1) {
      console.log(`[actions-cache] ✅ Real-time cache committed to GitHub Actions! (Cache ID: ${cacheId}, key: ${key})`);
    } else {
      console.log(`[actions-cache] ℹ️ Cache save returned status ${cacheId}`);
    }
  } catch (err) {
    console.log(`[actions-cache] ⚠️ Mid-job cache save notice: ${err.message}`);
  }
}

main().catch((err) => {
  console.log(`[actions-cache] ⚠️ Unexpected error: ${err.message}`);
});
