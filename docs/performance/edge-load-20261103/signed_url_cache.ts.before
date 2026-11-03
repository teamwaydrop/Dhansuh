// Shared helper: getSignedRiderImageUrl
//
// Isolate-scoped cache for signed rider-KYC-image URLs used by get-live-order-status. The
// underlying signed URL is valid for 21600s (6h); this function is polled every ~5s per active
// order, so without caching, every single poll pays for a fresh Supabase Storage sign operation
// for a URL that is still valid from the previous poll. Cache entries are kept for TTL_MS, safely
// under the real 21600s validity window, so a cached URL returned here is never actually expired.

const SIGN_EXPIRY_SECONDS = 21600;
const TTL_MS = 5.5 * 60 * 60 * 1000; // 5.5h -- comfortably under the 6h real expiry.

const cache = new Map<string, { url: string; cachedAt: number }>();

export async function getSignedRiderImageUrl(
  // deno-lint-ignore no-explicit-any
  supabaseAdmin: any,
  storagePath: string,
): Promise<string | null> {
  const cached = cache.get(storagePath);
  if (cached && Date.now() - cached.cachedAt < TTL_MS) {
    return cached.url;
  }

  const { data: signedData } = await supabaseAdmin.storage
    .from("rider_kyc")
    .createSignedUrl(storagePath, SIGN_EXPIRY_SECONDS);

  const url = signedData?.signedUrl ?? null;
  if (url) {
    cache.set(storagePath, { url, cachedAt: Date.now() });
  }
  return url;
}
