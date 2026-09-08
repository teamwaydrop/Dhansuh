// Shared helper: getDispatchConfig
//
// In-memory TTL cache for the single active `dispatch_config` row, scoped to this Deno isolate.
// dispatch_config only changes when an admin edits pricing/dispatch settings, but start-dispatch
// (supabase/functions/start-dispatch/index.ts) previously read it fresh on every single
// invocation -- measured live in production at 41,414+ identical-shape reads of a 1-row table
// (Performance Roadmap audit, DB-6/CRON-1). Supabase edge function isolates are reused across
// nearby-in-time invocations (they are not torn down per-request), so a short module-scope TTL
// cache removes the large majority of those reads without ever risking config staler than the
// TTL, and with zero change to any value start-dispatch reads or acts on.

// deno-lint-ignore no-explicit-any
type DispatchConfig = Record<string, any>;

const TTL_MS = 30_000;

let cached: DispatchConfig | null = null;
let cachedAt = 0;
let inFlight: Promise<DispatchConfig | null> | null = null;

/**
 * Returns the active dispatch_config row, refetching via `supabase` only if the cache is empty
 * or older than 30s. Concurrent invocations that land in this isolate during a refresh share the
 * same in-flight request instead of each firing their own duplicate query.
 */
export async function getDispatchConfig(
  // deno-lint-ignore no-explicit-any
  supabase: any,
): Promise<DispatchConfig | null> {
  const now = Date.now();
  if (cached && now - cachedAt < TTL_MS) {
    return cached;
  }
  if (inFlight) {
    return inFlight;
  }

  inFlight = (async () => {
    const { data } = await supabase
      .from("dispatch_config")
      .select("*")
      .eq("is_active", true)
      .single();
    cached = data ?? null;
    cachedAt = Date.now();
    return cached;
  })();

  try {
    return await inFlight;
  } finally {
    inFlight = null;
  }
}
