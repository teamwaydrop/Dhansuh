// Shared helper: getActivePricingZones
//
// In-memory TTL cache for every active `pricing_zones` row, scoped to this Deno isolate. Direct
// sibling of _shared/pricing_config_cache.ts (getActivePricingConfigs) -- same shape, same 30s
// TTL, same in-flight de-dup, same "return null on fetch error, never serve stale on error"
// contract.
//
// WHY: calculate-order-pricing's resolveZone() issued a fresh
//   `pricing_zones SELECT ... WHERE is_active = true`
// on EVERY pricing request (plus a second `... LIMIT 1` on the intercity / developer / long-ride
// fallback path). PricingController.fetchMultiplePricing() fires up to 3 of these concurrently
// (bike/auto/cab) for a single ride quote -- 3+ identical zone reads for one user action. The
// table is tiny and effectively static during normal operation (an admin editing a zone boundary
// is rare); the multi-second production latency on this function is per-round-trip queue/
// contention time, not slow queries (calculate-order-pricing/index.ts already documents the
// EXPLAIN ANALYZE finding). Fetching the full active set once per isolate per 30s and letting
// resolveZone() do its existing geofence / city / address matching over that in-memory list
// returns the exact same rows the per-request query did, with the identical `is_active = true`
// predicate already applied.
//
// SAFETY: this caches ONLY immutable zone-configuration rows -- never a calculated fare, never any
// per-user or per-order value. The pricing RATES themselves already come through the sibling 30s
// pricing_config cache, so a zone edit and a rate edit now share the same <=30s propagation
// window. A cold start (new isolate) starts with an empty cache. Nothing here changes zone
// matching, fare formulas, distance, tax, surge, discounts, or eligibility.

// deno-lint-ignore no-explicit-any
type PricingZone = Record<string, any>;

const TTL_MS = 30_000;
// Superset of the columns resolveZone() and its LIMIT-1 fallback both select today, so a single
// cached fetch serves both call sites with identically-shaped rows.
const SELECT =
  "id, zone_code, zone_name, zone_type, cities, center_lat, center_lng, radius_km, zone_shape";

let cached: PricingZone[] | null = null;
let cachedAt = 0;
let inFlight: Promise<PricingZone[] | null> | null = null;

/**
 * Returns every active pricing_zones row, refetching via `supabase` only if the cache is empty or
 * older than 30s. Concurrent invocations that land in this isolate during a refresh share the same
 * in-flight request instead of each firing their own duplicate query.
 *
 * Returns null (without touching the existing cache) if the underlying fetch errors, mirroring
 * resolveZone()'s original "log and return null" behaviour so a transient DB error still short-
 * circuits the caller exactly as before, instead of silently serving stale or empty data.
 */
export async function getActivePricingZones(
  // deno-lint-ignore no-explicit-any
  supabase: any,
): Promise<PricingZone[] | null> {
  const now = Date.now();
  if (cached && now - cachedAt < TTL_MS) {
    return cached;
  }
  if (inFlight) {
    return inFlight;
  }

  inFlight = (async () => {
    const { data, error } = await supabase
      .from("pricing_zones")
      .select(SELECT)
      .eq("is_active", true);
    if (error) {
      console.error("Error fetching pricing zones:", error);
      return null;
    }
    cached = data ?? [];
    cachedAt = Date.now();
    return cached;
  })();

  try {
    return await inFlight;
  } finally {
    inFlight = null;
  }
}
