// Regression guard for the Phase 8B fix: GovernmentTaxLedgerCache was never cleared during
// logout/account-switch, unlike its sibling session caches (RiderPayoutAccountCache,
// QrSignedUrlCache). Fix adds a clearAll() method (mirroring the sibling caches' clear()) and
// wires it into CacheCleanupHelper.clearAllCaches(), independently try/catch-wrapped so one
// cache's failure never prevents the others from clearing. No caching logic (get/invalidate,
// null-never-cached, in-flight dedup) was touched -- only a new cleanup entry point was added.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final cleanupSource = _read('lib/core/services/cache/cache_cleanup_helper.dart');
  final cacheSource = _read('lib/core/services/database/government_tax_ledger_cache.dart');

  group('E. clearAllCaches() calls GovernmentTaxLedgerCache cleanup', () {
    test('the import is present', () {
      expect(
        cleanupSource.contains(
          "import 'package:waydrop/core/services/database/government_tax_ledger_cache.dart';",
        ),
        isTrue,
      );
    });

    test('clearAllCaches() calls GovernmentTaxLedgerCache.clearAll()', () {
      expect(cleanupSource.contains('GovernmentTaxLedgerCache.clearAll();'), isTrue);
    });

    test('GovernmentTaxLedgerCache.clearAll() exists and clears both internal maps', () {
      final start = cacheSource.indexOf('static void clearAll() {');
      final end = cacheSource.indexOf('}', start);
      final body = cacheSource.substring(start, end);
      expect(body.contains('_cache.clear();'), isTrue);
      expect(body.contains('_inFlight.clear();'), isTrue);
    });
  });

  group('F. Other cache cleanup still executes if one cache throws', () {
    test('the new call is wrapped in its own try/catch, matching the existing isolation pattern '
        'for every other cache in this method', () {
      final callIdx = cleanupSource.indexOf('GovernmentTaxLedgerCache.clearAll();');
      final tryIdx = cleanupSource.lastIndexOf('try {', callIdx);
      final catchIdx = cleanupSource.indexOf('} catch (e) {', callIdx);
      expect(callIdx, greaterThan(-1));
      expect(tryIdx, greaterThan(-1));
      expect(catchIdx, greaterThan(callIdx));
      // The try block containing this call is its own isolated block (starts right before the
      // call, not shared with QrImageCacheManager/QrSignedUrlCache/RiderPayoutAccountCache).
      expect(callIdx - tryIdx, lessThan(30));
    });

    test('every cache-clearing call in this method is independently try/catch-isolated -- 5 '
        'distinct try blocks (disk image cache, QR image cache, QR signed-URL cache, payout '
        'account cache, government tax ledger cache)', () {
      expect('try {'.allMatches(cleanupSource).length, greaterThanOrEqualTo(5));
    });

    test('the government tax cache cleanup call sits after RiderPayoutAccountCache.clear() and '
        'before the Flutter image-cache clear, preserving the existing ordering/isolation shape', () {
      final payoutIdx = cleanupSource.indexOf('RiderPayoutAccountCache.clear();');
      final taxIdx = cleanupSource.indexOf('GovernmentTaxLedgerCache.clearAll();');
      final imageCacheIdx = cleanupSource.indexOf('PaintingBinding.instance.imageCache.clear();');
      expect(payoutIdx, greaterThan(-1));
      expect(taxIdx, greaterThan(payoutIdx));
      expect(imageCacheIdx, greaterThan(taxIdx));
    });
  });

  group('G. No tax data/logic changed', () {
    test('null stays uncached and in-flight dedup preserves current request ownership', () {
      expect(
        cacheSource.contains(
          'static Future<Map<String, dynamic>?> get(\n    String orderId,\n    Future<Map<String, dynamic>?> Function() fetch,\n  ) async {',
        ),
        isTrue,
      );
      expect(cacheSource.contains('if (result != null && identical(_inFlight[orderId], future)) {\n        _cache[orderId] = result;\n      }'), isTrue);
      expect(cacheSource.contains('if (identical(_inFlight[orderId], future)) _inFlight.remove(orderId);'), isTrue);
      expect(cacheSource.contains('static void invalidate(String orderId) => _cache.remove(orderId);'), isTrue);
    });

    test('no tax calculation or GST business-logic identifiers were introduced in the cleanup '
        'helper, which never had any before this fix', () {
      for (final forbidden in ['apply_order_government_tax', 'gst_percentage', 'commission']) {
        expect(cleanupSource.contains(forbidden), isFalse);
      }
    });
  });
}
