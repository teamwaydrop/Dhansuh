import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:waydrop/core/services/developer/developer_mode_service.dart';
import 'package:waydrop/core/services/location/location_cache_service.dart';

Position _position(double latitude) => Position(
  longitude: 0,
  latitude: latitude,
  timestamp: DateTime.utc(2026),
  accuracy: 1,
  altitude: 0,
  altitudeAccuracy: 1,
  heading: 0,
  headingAccuracy: 1,
  speed: 0,
  speedAccuracy: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('test mutation entry points reject non-debug builds before mutation', () {
    final source = File(
      'lib/core/services/location/location_cache_service.dart',
    ).readAsStringSync();
    for (final signature in [
      'static set riderLocationWriterForTesting(',
      'static Future<void> handlePositionUpdateForTesting(',
      'static Future<void> performHeartbeatUpdateForTesting()',
    ]) {
      final start = source.indexOf(signature);
      expect(start, greaterThanOrEqualTo(0));
      final bodyStart = source.indexOf('{', start);
      final bodyEnd = source.indexOf('\n  }', bodyStart);
      final body = source.substring(bodyStart, bodyEnd);
      expect(body.trimLeft(), startsWith('{\n    _requireDebugTestSeam();'));
    }
    final start = source.indexOf('static void _requireDebugTestSeam()');
    final end = source.indexOf('\n  }', start);
    final gate = source.substring(start, end);
    expect(gate, contains('if (!kDebugMode)'));
    expect(gate, contains('throw StateError('));
    expect(gate, isNot(contains('assert(')));
  });

  test('normal writer cannot consult the fake writer outside debug mode', () {
    final source = File(
      'lib/core/services/location/location_cache_service.dart',
    ).readAsStringSync();
    final start = source.indexOf('      updateRiderLocation(');
    final body = source.substring(start);
    expect(body, contains('if (kDebugMode) {\n      final testWriter = _riderLocationWriterForTesting;'));
    expect(body.indexOf('if (kDebugMode)'),
        lessThan(body.indexOf('Supabase.instance.client')));
    expect(source, contains('kDebugMode ? _riderLocationWriterForTesting : null'));
  });

  setUp(() {
    // Use the existing in-memory serviceability bypass only to avoid zone I/O.
    // No authentication, account changes, GPS calls or Supabase client is used.
    DeveloperModeService.instance.setFromProfile({'is_developer': true});
    LocationCacheService.cachedPosition = null;
    LocationCacheService.lastUpdated = null;
    LocationCacheService.lastUploadedPosition = null;
    LocationCacheService.lastDbUpdateTime = null;
    LocationCacheService.isUpdatingDb = false;
    LocationCacheService.riderLocationWriterForTesting = null;
  });

  tearDown(() {
    LocationCacheService.riderLocationWriterForTesting = null;
    LocationCacheService.isUpdatingDb = false;
    LocationCacheService.cachedPosition = null;
    LocationCacheService.lastUpdated = null;
    LocationCacheService.lastUploadedPosition = null;
    LocationCacheService.lastDbUpdateTime = null;
    DeveloperModeService.instance.clear();
  });

  test('A owns the guard; skipped B and C cannot release it', () async {
    final started = Completer<void>();
    final finish = Completer<void>();
    var writes = 0;
    var activeWrites = 0;
    var peakWrites = 0;
    LocationCacheService.riderLocationWriterForTesting = (_) async {
      writes++;
      activeWrites++;
      if (activeWrites > peakWrites) peakWrites = activeWrites;
      if (!started.isCompleted) started.complete();
      try {
        await finish.future;
      } finally {
        activeWrites--;
      }
    };

    final a = LocationCacheService.handlePositionUpdateForTesting(_position(0));
    await started.future;
    await LocationCacheService.handlePositionUpdateForTesting(_position(0.01));
    expect(LocationCacheService.isUpdatingDb, isTrue);
    await LocationCacheService.handlePositionUpdateForTesting(_position(0.02));
    expect(writes, 1);
    expect(LocationCacheService.cachedPosition!.latitude, 0.02);

    finish.complete();
    await a;
    expect(LocationCacheService.isUpdatingDb, isFalse);
    await LocationCacheService.handlePositionUpdateForTesting(_position(0.03));
    expect(writes, 2);
    expect(peakWrites, 1);
  });

  test('movement-threshold return does not release a heartbeat-owned guard', () async {
    final position = _position(0);
    LocationCacheService.cachedPosition = position;
    LocationCacheService.lastUpdated = DateTime.now();
    LocationCacheService.lastUploadedPosition = position;
    LocationCacheService.lastDbUpdateTime = DateTime.now();
    final started = Completer<void>();
    final finish = Completer<void>();
    var writes = 0;
    LocationCacheService.riderLocationWriterForTesting = (_) async {
      writes++;
      started.complete();
      await finish.future;
    };

    final heartbeat = LocationCacheService.performHeartbeatUpdateForTesting();
    await started.future;
    final skippedPosition = _position(0.00001);
    await LocationCacheService.handlePositionUpdateForTesting(skippedPosition);
    expect(LocationCacheService.cachedPosition, same(skippedPosition));
    expect(LocationCacheService.isUpdatingDb, isTrue);
    await LocationCacheService.handlePositionUpdateForTesting(_position(0.01));
    expect(writes, 1);
    finish.complete();
    await heartbeat;
    expect(LocationCacheService.isUpdatingDb, isFalse);
  });

  test('successful GPS write releases its guard and records upload state', () async {
    final position = _position(0);
    LocationCacheService.riderLocationWriterForTesting = (_) async {};
    await LocationCacheService.handlePositionUpdateForTesting(position);
    expect(LocationCacheService.isUpdatingDb, isFalse);
    expect(LocationCacheService.lastUploadedPosition, same(position));
    expect(LocationCacheService.lastDbUpdateTime, isNotNull);
  });

  test('GPS writer exception releases the guard and allows a later write', () async {
    LocationCacheService.riderLocationWriterForTesting = (_) async {
      throw StateError('synthetic writer failure');
    };
    await LocationCacheService.handlePositionUpdateForTesting(_position(0));
    expect(LocationCacheService.isUpdatingDb, isFalse);
    expect(LocationCacheService.lastUploadedPosition, isNull);
    var writes = 0;
    LocationCacheService.riderLocationWriterForTesting = (_) async { writes++; };
    await LocationCacheService.handlePositionUpdateForTesting(_position(0));
    expect(writes, 1);
  });

  for (final heartbeatFirst in [false, true]) {
    test('GPS/heartbeat overlap has one writer (heartbeatFirst=$heartbeatFirst)', () async {
      LocationCacheService.cachedPosition = _position(0);
      LocationCacheService.lastUpdated = DateTime.now();
      final started = Completer<void>();
      final finish = Completer<void>();
      var writes = 0;
      LocationCacheService.riderLocationWriterForTesting = (_) async {
        writes++;
        started.complete();
        await finish.future;
      };
      final active = heartbeatFirst
          ? LocationCacheService.performHeartbeatUpdateForTesting()
          : LocationCacheService.handlePositionUpdateForTesting(_position(0));
      await started.future;
      if (heartbeatFirst) {
        await LocationCacheService.handlePositionUpdateForTesting(_position(0.01));
      } else {
        await LocationCacheService.performHeartbeatUpdateForTesting();
      }
      expect(LocationCacheService.isUpdatingDb, isTrue);
      expect(writes, 1);
      finish.complete();
      await active;
      expect(LocationCacheService.isUpdatingDb, isFalse);
    });
  }

  test('heartbeat writer exception preserves its existing guard cleanup', () async {
    LocationCacheService.cachedPosition = _position(0);
    LocationCacheService.lastUpdated = DateTime.now();
    LocationCacheService.riderLocationWriterForTesting = (_) async {
      throw StateError('synthetic heartbeat failure');
    };
    await LocationCacheService.performHeartbeatUpdateForTesting();
    expect(LocationCacheService.isUpdatingDb, isFalse);
  });

  test('existing movement and heartbeat cadence remain unchanged', () {
    expect(LocationCacheService.movementThresholdMeters, 150);
    expect(LocationCacheService.heartbeatSeconds, 60);
  });
}
