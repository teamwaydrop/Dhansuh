// Shared helper: getActivePricingConfigs
//
// In-memory TTL cache for every active+approved `pricing_config` row (joined with pricing_zones),
// scoped to this Deno isolate. pricing_config only changes when an admin edits/approves a pricing
// rule, but calculate-order-pricing's resolvePricingConfig() previously issued up to 2 fresh
// queries against this table on every single pricing request -- measured live in production at
// 5,000+ reads across this query's two shapes (Performance Roadmap audit). The table itself is
// tiny (18 rows) and every caller ultimately filters the same is_active=true/approval_status=
// 'approved' predicate down to one service_type + pricing_zone_id combination -- so this fetches
// the full active+approved set once and lets callers filter it in memory, which returns the exact
// same rows a fresh `WHERE service_type = ? AND pricing_zone_id = ?` query would, since the cached
// set already carries the identical is_active/approval_status predicate the original query used.

// deno-lint-ignore no-explicit-any
type PricingConfig = Record<string, any>;

const TTL_MS = 30_000;
const SELECT =
  "*, pricing_zones(id, zone_code, zone_name, zone_type, cities, center_lat, center_lng, radius_km, is_active)";

let cached: PricingConfig[] | null = null;
let cachedAt = 0;
let inFlight: Promise<PricingConfig[] | null> | null = null;

/**
 * Returns every active+approved pricing_config row, refetching via `supabase` only if the cache
 * is empty or older than 30s. Concurrent invocations that land in this isolate during a refresh
 * share the same in-flight request instead of each firing their own duplicate query.
 *
 * Returns null (without touching the existing cache) if the underlying fetch errors, mirroring
 * the original per-call "log and return null" behaviour so a transient DB error still short-
 * circuits the caller exactly as before, instead of silently serving stale or empty data.
 */
export async function getActivePricingConfigs(
  // deno-lint-ignore no-explicit-any
  supabase: any,
): Promise<PricingConfig[] | null> {
  const now = Date.now();
  if (cached && now - cachedAt < TTL_MS) {
    return cached;
  }
  if (inFlight) {
    return inFlight;
  }

  inFlight = (async () => {
    const { data, error } = await supabase
      .from("pricing_config")
      .select(SELECT)
      .eq("is_active", true)
      .eq("approval_status", "approved");
    if (error) {
      console.error("Error fetching pricing config:", error);
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
