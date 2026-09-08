/// In-memory cache for `driver_personal_qr` signed URLs, keyed by storage path.
///
/// Egress fix (Fix #10B): rider_payout_details_screen.dart, rider_payment_settings_screen.dart,
/// and rider_active_order_screen.dart each independently called `createSignedUrl(path, 3600)` --
/// a fresh signed-URL request (plus, before Fix #2's [QrImageCacheManager], a fresh image
/// download) every time any of those screens opened, even within the URL's own ~1 hour validity
/// window.
///
/// Caching by storage PATH (not by rider/user id) is what makes this safe with no explicit
/// invalidation step: every upload writes to a brand-new path
/// (`'$riderId/personal_qr_${DateTime.now().millisecondsSinceEpoch}.$ext'`, see
/// rider_payout_details_screen.dart._pickAndUploadQr), so a re-upload is automatically a cache
/// miss under its own new path -- the old path's cached URL is simply never looked up again, not
/// served stale. [ttl] is kept comfortably under the server-side 3600s expiry so a caller can
/// never be handed a URL already invalid or on the verge of expiring.
class QrSignedUrlCache {
  QrSignedUrlCache._();

  static const Duration ttl = Duration(minutes: 50);

  static final Map<String, ({String url, DateTime fetchedAt})> _cache = {};
  static final Map<String, Future<String?>> _inFlight = {};

  static Future<String?> get(
    String path,
    Future<String?> Function() fetch,
  ) async {
    final cached = _cache[path];
    if (cached != null && DateTime.now().difference(cached.fetchedAt) < ttl) {
      return cached.url;
    }
    final inFlight = _inFlight[path];
    if (inFlight != null) return inFlight;

    final future = fetch();
    _inFlight[path] = future;
    try {
      final url = await future;
      if (url != null) {
        _cache[path] = (url: url, fetchedAt: DateTime.now());
      }
      return url;
    } finally {
      _inFlight.remove(path);
    }
  }

  /// Call on logout/account-switch (see CacheCleanupHelper.clearAllCaches()) -- storage paths are
  /// per-rider so a leftover cached URL couldn't resolve to a *different* rider's QR, but there is
  /// no reason for a signed URL issued to the previous account's session to remain reachable after
  /// sign-out either.
  static void clear() {
    _cache.clear();
    _inFlight.clear();
  }
}
