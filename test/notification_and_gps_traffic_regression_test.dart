import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final badge = _read(
    'lib/modules/notifications/services/notification_badge_service.dart',
  );
  final location = _read(
    'lib/core/services/location/location_cache_service.dart',
  );

  group('notification badge traffic', () {
    test('uses an exact server count instead of downloading unread IDs', () {
      expect(badge.contains('.count(CountOption.exact)'), isTrue);
      expect(badge.contains('state = rows.length'), isFalse);
    });

    test('coalesces refreshes and rejects stale account responses', () {
      expect(badge.contains('Future<void>? _refreshInFlight;'), isTrue);
      expect(badge.contains('bool _refreshQueued = false;'), isTrue);
      expect(badge.contains('if (inFlight != null) return inFlight;'), isTrue);
      expect(
        badge.contains("_supabase.auth.currentUser?.id != user.id"),
        isTrue,
      );
    });
  });

  group('rider GPS database traffic', () {
    test('heartbeat reuses the movement/time upload gate', () {
      final start = location.indexOf(
        'static Future<void> _performHeartbeatUpdate() async {',
      );
      final end = location.indexOf('// START TRACKING', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final heartbeat = location.substring(start, end);
      expect(
        heartbeat.contains(
          'if (!_shouldUploadPosition(position) || isUpdatingDb)',
        ),
        isTrue,
      );
    });

    test('dispatch-safe heartbeat and movement thresholds remain unchanged', () {
      expect(
        RegExp(r'static const int movementThresholdMeters\s*=\s*10;')
            .hasMatch(location),
        isTrue,
      );
      expect(
        RegExp(r'static const int heartbeatSeconds\s*=\s*30;')
            .hasMatch(location),
        isTrue,
      );
    });
  });
}
