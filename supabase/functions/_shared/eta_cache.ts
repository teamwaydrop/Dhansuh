// Shared helper: getEtaWithBudget
//
// Isolate-scoped, short-TTL cache + bounded race for the OLA Maps ETA lookup used by
// get-live-order-status. This function is polled every ~5s per active order from both the
// passenger and rider client -- calling OLA fresh on every single poll is both unnecessary
// (a rider's ETA doesn't need sub-20s precision) and, per the WayDrop Progressive Degradation
// investigation, a source of avoidable per-request latency sitting in the response's critical
// path. Two changes from the old inline behavior:
//
//   1. A successful OLA result is cached per order_id for TTL_MS and reused across polls in that
//      window, instead of calling OLA fresh every single time.
//   2. A fresh lookup (cache miss/expired) is raced against a short bound (RACE_TIMEOUT_MS, well
//      under OLA's own 8s request timeout). If OLA hasn't answered within that bound, the
//      response is returned immediately using the last cached value (if any) rather than waiting
//      -- OLA's own call is left running in the background and will populate the cache for the
//      *next* poll if it eventually succeeds.
//
// `fetchFresh` is expected to THROW on failure (not return a zero-value fallback itself) -- that
// is what lets a single transient OLA failure fall back to the last good cached value instead of
// overwriting it with a stale-looking zero for the full TTL window. The caller's own zero-value
// fallback ({distanceKm: 0, estimatedArrivalMinutes: 0}) is only ever used here when there is no
// cached value at all to fall back to -- identical to today's cold-start behavior.

type EtaResult = { distanceKm: number; estimatedArrivalMinutes: number; degraded?: boolean };

const TTL_MS = 20_000;
const RACE_TIMEOUT_MS = 2_000;

const cache = new Map<string, { value: EtaResult; cachedAt: number }>();

export async function getEtaWithBudget(
  orderId: string,
  fetchFresh: () => Promise<EtaResult>,
): Promise<EtaResult> {
  const cached = cache.get(orderId);
  const now = Date.now();
  if (cached && now - cached.cachedAt < TTL_MS) {
    return cached.value;
  }

  const freshPromise = fetchFresh()
    .then((value) => {
      cache.set(orderId, { value, cachedAt: Date.now() });
      return value;
    })
    .catch(() => null);

  const timeoutFallback = new Promise<null>((resolve) => {
    setTimeout(() => resolve(null), RACE_TIMEOUT_MS);
  });

  const raced = await Promise.race([freshPromise, timeoutFallback]);
  if (raced) return raced;

  // P1 fix (ETA failure must not break live ride status): the fresh lookup either failed
  // (caught above) or didn't answer within the race window -- order/rider/status data is still
  // returned normally by the caller either way (this function already never throws), but the
  // ETA value itself is now a fallback, not a real reading. `degraded: true` lets the caller
  // surface that distinction to the client instead of silently presenting a stale/zero ETA as
  // current.
  if (cached) return { ...cached.value, degraded: true };
  return { distanceKm: 0, estimatedArrivalMinutes: 0, degraded: true };
}
