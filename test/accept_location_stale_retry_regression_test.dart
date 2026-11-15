import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

// Regression guards for the LOCATION_STALE accept-retry fix (Nov 2026).
//
// Symptom: during a backend slowdown the rider's periodic GPS heartbeat was
// delayed, so riders.last_location_updated_at aged past rider_location_stale_sec
// and dispatch_eligibility returned LOCATION_STALE -> "Rider is not eligible for
// this order". Tapping accept 2-3 times eventually worked once a fresh heartbeat
// landed. Fix: on a LOCATION_STALE accept failure, push ONE genuinely fresh GPS
// fix and retry acceptance exactly once; every other eligibility/security check
// is re-run server-side by that retry.
//
// These are structural guards (source-text) because the behavior spans
// supabase.functions.invoke + Geolocator, which the suite does not mock. They
// lock the fix shape on BOTH accept paths and the shared helper.

void main() {
  const orders = 'lib/features/rider/orders/rider_orders_screen.dart';
  const card = 'lib/features/rider/orders/widgets/incoming_order_card.dart';
  const loc = 'lib/core/services/location/location_cache_service.dart';

  String read(String p) => File(p).readAsStringSync();
  String noWs(String s) => s.replaceAll(RegExp(r'\s+'), '');

  group('LOCATION_STALE accept-retry — shared location helper', () {
    final src = read(loc);
    final flat = noWs(src);

    test('forceFreshLocationUpdate exists and returns bool', () {
      expect(src.contains('Future<bool> forceFreshLocationUpdate()'), isTrue,
          reason: 'The accept flow needs a fresh-location recovery helper.');
    });

    test('obtains a GENUINELY fresh GPS fix (getCurrentPosition, not cached)', () {
      expect(flat.contains('Geolocator.getCurrentPosition('), isTrue,
          reason: 'Must read a live position, never stamp a cached/last-known fix as fresh.');
    });

    test('checks location service and permission before reading', () {
      expect(src.contains('isLocationServiceEnabled'), isTrue,
          reason: 'Return false (not throw) when location services are off.');
      expect(src.contains('checkPermission'), isTrue,
          reason: 'Return false when permission is denied/deniedForever.');
      expect(
        flat.contains('LocationPermission.denied') &&
            flat.contains('LocationPermission.deniedForever'),
        isTrue,
        reason: 'Both denied states must stop the refresh.',
      );
    });

    test('awaits the DB write and returns its success', () {
      expect(flat.contains('awaitupdateRiderLocation(position)'), isTrue,
          reason: 'The riders-row write (last_location_updated_at) must complete before success.');
    });
  });

  for (final entry in {
    'rider_orders_screen': orders,
    'incoming_order_card': card,
  }.entries) {
    group('LOCATION_STALE accept-retry — ${entry.key}', () {
      final src = read(entry.value);
      final flat = noWs(src);

      test('retry only on explicit LOCATION_STALE code', () {
        expect(src.contains("_getExceptionCode(e) == 'LOCATION_STALE'"), isTrue,
            reason: 'Retry must be gated on the backend code, not the message or any other error.');
        expect(src.contains('String? _getExceptionCode('), isTrue,
            reason: 'Code extraction helper must exist to read the FunctionException body code.');
      });

      test('refreshes location, then retries via continue only when refreshed', () {
        expect(src.contains('LocationCacheService.forceFreshLocationUpdate()'), isTrue,
            reason: 'Must obtain a fresh GPS fix before retrying.');
        expect(flat.contains('if(refreshed){continue;'), isTrue,
            reason: 'Retry (continue) must happen ONLY when the refresh succeeded.');
      });

      test('exactly one retry — one-shot guard', () {
        expect(flat.contains('retriedForLocation=false'), isTrue,
            reason: 'A one-shot flag must bound the retry.');
        expect(src.contains('!retriedForLocation'), isTrue,
            reason: 'The retry branch must be gated by the one-shot flag (no infinite loop).');
        expect(flat.contains('retriedForLocation=true'), isTrue,
            reason: 'The flag must be set before retrying so a second LOCATION_STALE does not loop.');
      });

      test('refresh failure stops and shows a message (no retry)', () {
        expect(src.contains('Could not refresh your GPS location'), isTrue,
            reason: 'On refresh failure the rider must get an actionable message, not a silent retry.');
      });

      test('genuine rejections are not routed through the retry branch', () {
        // The retry predicate is specifically LOCATION_STALE; the existing
        // message-based branches (already accepted / no longer available) remain.
        expect(
          entry.key == 'rider_orders_screen'
              ? src.contains("errorMsg.contains('already accepted')")
              : src.contains('_getExceptionMessage(e)'),
          isTrue,
          reason: 'Existing genuine-rejection handling must be preserved.',
        );
      });
    });
  }
}
