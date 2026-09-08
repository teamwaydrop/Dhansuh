import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:waydrop/core/services/cache/qr_image_cache_manager.dart';
import 'package:waydrop/core/services/cache/qr_signed_url_cache.dart';
import 'package:waydrop/core/services/database/government_tax_ledger_cache.dart';
import 'package:waydrop/core/services/database/rider_payout_account_cache.dart';

class CacheCleanupHelper {
  /// Clears network image cache on disk and clears in-memory image cache.
  static Future<void> clearAllCaches() async {
    try {
      // Clear disk cache for cached_network_image
      await DefaultCacheManager().emptyCache();
    } catch (e) {
      // Safely ignore if cache manager has issues
    }

    // Egress fix: the two QR caches and the payout-account cache introduced by the egress audit
    // work are separate stores from DefaultCacheManager above -- they were never swept here, so a
    // logout/account-switch left them holding the previous account's data (session-lifetime only,
    // no persistence, but still reachable for as long as the process stayed alive). None of these
    // throw on an empty/already-cleared store, but each is wrapped independently so one failing
    // never skips the others.
    try {
      await QrImageCacheManager.instance.emptyCache();
    } catch (e) {
      // Safely ignore
    }
    try {
      QrSignedUrlCache.clear();
    } catch (e) {
      // Safely ignore
    }
    try {
      RiderPayoutAccountCache.clear();
    } catch (e) {
      // Safely ignore
    }
    try {
      GovernmentTaxLedgerCache.clearAll();
    } catch (e) {
      // Safely ignore
    }

    try {
      // Clear Flutter's in-memory image cache
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (e) {
      // Safely ignore
    }
  }
}
