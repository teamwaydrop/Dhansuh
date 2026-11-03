// Shared helper: getProductionConfig / isFeatureEnabled
//
// In-memory TTL cache for the single active `production_config` row, scoped to this Deno isolate --
// same pattern as getDispatchConfig (dispatch_config_cache.ts): Supabase Edge Function isolates are
// reused across nearby-in-time invocations, so a short module-scope TTL cache avoids re-querying a
// 1-row table on every single request while never risking config staler than the TTL.
//
// This is the server-side half of the Phase 1 production control system. The Flutter client enforces
// feature flags for UI visibility (see FeatureFlags/ProductionConfigService); this file is what the
// safest, most central Edge Functions (create-order, create-payment, send-push-notification) check
// before actually performing the operation a flag controls, so a flag is never "just a UI toggle".

// deno-lint-ignore no-explicit-any
type ProductionConfig = Record<string, any>;

const TTL_MS = 30_000;

let cached: ProductionConfig | null = null;
let cachedAt = 0;
let inFlight: Promise<ProductionConfig | null> | null = null;

/**
 * Returns the active production_config row, refetching via `supabase` only if the cache is empty or
 * older than 30s. Concurrent invocations that land in this isolate during a refresh share the same
 * in-flight request instead of each firing their own duplicate query.
 *
 * Returns null if the row cannot be fetched (e.g. transient DB error) -- callers must treat a null
 * config as "no restriction" (fail open), never as "everything disabled", so a config outage cannot
 * itself take down ride booking / payments / notifications. This mirrors the Flutter client's own
 * documented fail-open policy for the same reason.
 */
export async function getProductionConfig(
  // deno-lint-ignore no-explicit-any
  supabase: any,
): Promise<ProductionConfig | null> {
  const now = Date.now();
  if (cached && now - cachedAt < TTL_MS) {
    return cached;
  }
  if (inFlight) {
    return inFlight;
  }

  inFlight = (async () => {
    try {
      const { data } = await supabase
        .from("production_config")
        .select("*")
        .eq("is_active", true)
        .single();
      cached = data ?? null;
      cachedAt = Date.now();
      return cached;
    } catch (_e) {
      // Fail open: keep serving the previous cached value (even if stale) rather than treating a
      // transient fetch error as "config says disabled".
      return cached;
    }
  })();

  try {
    return await inFlight;
  } finally {
    inFlight = null;
  }
}

/**
 * Reads a named boolean flag off a (possibly null) config row, defaulting to `true` (enabled) when
 * the config is unavailable or the column is missing/null -- never fail closed on a config outage.
 */
export function isFeatureEnabled(
  config: ProductionConfig | null,
  key: string,
  defaultValue = true,
): boolean {
  if (!config) return defaultValue;
  const value = config[key];
  return typeof value === "boolean" ? value : defaultValue;
}
