import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Dedicated [CacheManager] for payout/UPI QR images loaded via Supabase Storage
/// signed URLs (~1 hour validity, see `createSignedUrl(path, 3600)` call sites).
/// `stalePeriod` is capped to that same window so a cached QR image is never
/// served past the point its signed URL would already need to be re-signed --
/// distinct from [DefaultCacheManager] (used for parcel photos, which are not
/// time-limited) so the two caches don't share eviction policy.
class QrImageCacheManager {
  static const key = 'qrImageCache';

  static final CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: const Duration(hours: 1),
      maxNrOfCacheObjects: 50,
    ),
  );
}
