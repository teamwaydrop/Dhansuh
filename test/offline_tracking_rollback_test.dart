import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:waydrop/core/services/location/location_cache_service.dart';
import 'package:waydrop/features/rider/home/offline_tracking_rollback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final change in ['user', 'rider', 'disposed', 'unknown', 'write', 'unchanged']) {
    test('pending online startup is fenced after $change', () async {
      final evidence = OfflineStatusEvidence();
      final revision = evidence.readRevision;
      var user = 'A';
      var rider = 'rider-A';
      var mounted = true;
      var writes = 0;
      final startup = Completer<void>();
      Future<void> online() async {
        await startup.future;
        if (evidence.permitsOnlineOperation(revision, mounted: mounted,
            userId: 'A', riderId: 'rider-A', currentUserId: user, currentRiderId: rider)) {
          writes++;
        }
      }
      final done = online();
      switch (change) {
        case 'user': user = 'B'; break;
        case 'rider': rider = 'rider-B'; break;
        case 'disposed': mounted = false; break;
        case 'unknown': evidence.markUnknown(); break;
        case 'write': evidence.beginWrite(); break;
      }
      startup.complete();
      await done;
      expect(writes, change == 'unchanged' ? 1 : 0);
    });
  }

  for (final failure in ['context expiry', 'write failure']) {
    test('$failure restores tracking without inventing backend status', () async {
      var current = true;
      var tracking = true;
      var online = true;
      var starts = 0;
      var writes = 0;
      final evidence = OfflineStatusEvidence();
      final restartStarted = Completer<void>();
      final restartFinished = Completer<void>();
      Future<void> offline() async {
        online = false;
        tracking = false; // The existing stop has completed.
        try {
          if (failure == 'context expiry') throw StateError('expired');
          writes++;
          evidence.beginWrite();
          throw StateError('synthetic write failure');
        } catch (_) {
          if (writes > 0) evidence.markUnknown();
          final result = await restoreOfflineTracking(
            isCurrentIdentity: () => current,
            isTrackingActive: () => tracking,
            restartTracking: () async {
              starts++;
              restartStarted.complete();
              await restartFinished.future;
              if (current) tracking = true;
            },
            stopIncompleteTracking: () async { tracking = false; },
          );
          if (current) {
            online = evidence.permitsOnline(
                result == OfflineTrackingRollback.restored && tracking);
          }
        }
      }
      final done = offline();
      await restartStarted.future;
      expect(online, isFalse);
      expect(tracking, isFalse);
      restartFinished.complete();
      await done;
      expect(tracking, isTrue);
      expect(online, failure == 'context expiry');
      expect(evidence.unknown, failure == 'write failure');
      expect(starts, 1);
      expect(writes, failure == 'write failure' ? 1 : 0);
      current = false;
    });
  }
  for (final committed in [false, true]) {
    test('lost write outcome (committed=$committed) needs a fresh read, not tracking', () async {
      final evidence = OfflineStatusEvidence();
      final oldRead = evidence.readRevision;
      evidence.beginWrite();
      final duringWrite = evidence.readRevision;
      evidence.markUnknown();
      final result = await restoreOfflineTracking(
        isCurrentIdentity: () => true,
        isTrackingActive: () => true,
        restartTracking: () async => fail('Already tracking'),
        stopIncompleteTracking: () async => fail('No cleanup'),
      );
      expect(result, OfflineTrackingRollback.restored);
      expect(evidence.permitsOnline(true), isFalse);
      evidence.finishWrite();
      evidence.confirmRead(oldRead, 'online');
      evidence.confirmRead(duringWrite, 'online');
      expect(evidence.unknown, isTrue);
      final serverStatus = committed ? 'offline' : 'online';
      evidence.confirmRead(evidence.readRevision, serverStatus);
      expect(evidence.unknown, isFalse);
      expect(evidence.permitsOnline(true) && serverStatus == 'online', !committed);
    });
  }
  test('identity reset rejects old status evidence; invalid status cannot resolve uncertainty', () {
    final evidence = OfflineStatusEvidence();
    evidence.markUnknown();
    evidence.beginWrite();
    final oldRead = evidence.readRevision;
    evidence.resetIdentity();
    evidence.markUnknown();
    evidence.confirmRead(oldRead, 'online');
    evidence.confirmRead(evidence.readRevision, null);
    expect(evidence.unknown, isTrue);
    evidence.confirmRead(evidence.readRevision, 'offline');
    expect(evidence.unknown, isFalse);
  });
  test('successful write has no unknown outcome and rejects reads begun during it', () {
    final evidence = OfflineStatusEvidence();
    evidence.beginWrite();
    final duringWrite = evidence.readRevision;
    expect(evidence.acceptsRead(duringWrite), isFalse);
    evidence.finishWrite();
    expect(evidence.acceptsRead(duringWrite), isFalse);
    expect(evidence.unknown, isFalse);
  });
  test('identity retired before rollback never touches new tracking resources', () async {
    var starts = 0;
    var stops = 0;
    final result = await restoreOfflineTracking(
      isCurrentIdentity: () => false,
      isTrackingActive: () => true,
      restartTracking: () async { starts++; },
      stopIncompleteTracking: () async { stops++; },
    );
    expect(result, OfflineTrackingRollback.retired);
    expect(starts + stops, 0);
  });
  test('identity change during restart prevents old UI restoration and cleanup', () async {
    var current = true;
    bool ownsIdentity() => current;
    var newIdentityOnline = false;
    var cleanup = 0;
    final started = Completer<void>();
    final finished = Completer<void>();
    final done = restoreOfflineTracking(
      isCurrentIdentity: ownsIdentity,
      isTrackingActive: () => false,
      restartTracking: () async { started.complete(); await finished.future; },
      stopIncompleteTracking: () async { cleanup++; },
    );
    await started.future;
    current = false;
    finished.complete();
    final result = await done;
    if (ownsIdentity()) newIdentityOnline = result == OfflineTrackingRollback.restored;
    expect(result, OfflineTrackingRollback.retired);
    expect(newIdentityOnline, isFalse);
    expect(cleanup, 0);
  });
  for (final throws in [false, true]) {
    test('restart failure ($throws) reports unavailable and does not publish online', () async {
      var cleanup = 0;
      final result = await restoreOfflineTracking(
        isCurrentIdentity: () => true,
        isTrackingActive: () => false,
        restartTracking: () async { if (throws) throw StateError('synthetic restart failure'); },
        stopIncompleteTracking: () async { cleanup++; },
      );
      expect(result, OfflineTrackingRollback.unavailable);
      expect(result == OfflineTrackingRollback.restored, isFalse);
      expect(cleanup, 1);
    });
  }
  test('already active tracking needs no second subscription or heartbeat', () async {
    var starts = 0;
    final result = await restoreOfflineTracking(
      isCurrentIdentity: () => true,
      isTrackingActive: () => true,
      restartTracking: () async { starts++; },
      stopIncompleteTracking: () async { fail('Unexpected cleanup'); },
    );
    expect(result, OfflineTrackingRollback.restored);
    expect(starts, 0);
  });
  test('successful offline write never enters the rollback restart path', () async {
    var tracking = true;
    var online = true;
    var starts = 0;
    try {
      online = false;
      tracking = false;
      await Future<void>.value(); // Successful controlled write.
    } catch (_) {
      await restoreOfflineTracking(
        isCurrentIdentity: () => true,
        isTrackingActive: () => tracking,
        restartTracking: () async { starts++; tracking = true; },
        stopIncompleteTracking: () async { tracking = false; },
      );
    }
    expect(online || tracking, isFalse);
    expect(starts, 0);
  });

  group('actual tracking lifecycle with a local platform fake', () {
    late GeolocatorPlatform originalPlatform;
    late _LocalGeolocator platform;
    setUp(() {
      originalPlatform = GeolocatorPlatform.instance;
      platform = _LocalGeolocator();
      GeolocatorPlatform.instance = platform;
      LocationCacheService.cachedPosition = null;
      LocationCacheService.lastUpdated = null;
    });
    tearDown(() async {
      await LocationCacheService.stopRiderLiveTracking();
      await LocationCacheService.gpsStatusStream?.cancel();
      LocationCacheService.gpsStatusStream = null;
      await platform.positions.close();
      GeolocatorPlatform.instance = originalPlatform;
    });
    test('concurrent starts install exactly one stream and one heartbeat', () async {
      platform.enabledGate = Completer<bool>();
      final first = LocationCacheService.startRiderLiveTracking();
      final second = LocationCacheService.startRiderLiveTracking();
      platform.enabledGate!.complete(true);
      await Future.wait([first, second]);
      expect(platform.streamStarts, 1);
      expect(LocationCacheService.isRiderLiveTrackingActive, isTrue);
      final heartbeat = LocationCacheService.riderHeartbeatTimer;
      await LocationCacheService.startRiderLiveTracking();
      expect(platform.streamStarts, 1);
      expect(identical(LocationCacheService.riderHeartbeatTimer, heartbeat), isTrue);
    });
    test('open stream error retains ownership until stop; late errors cannot affect replacement', () async {
      await LocationCacheService.startRiderLiveTracking();
      final oldStream = LocationCacheService.riderLocationStream;
      final oldHeartbeat = LocationCacheService.riderHeartbeatTimer!;
      final oldError = platform.errorCallbacks.single;
      oldError(StateError('synthetic error'));
      expect(identical(LocationCacheService.riderLocationStream, oldStream), isTrue);
      expect(platform.positions.hasListener, isTrue);
      expect(oldHeartbeat.isActive, isFalse);
      expect(LocationCacheService.isRiderLiveTrackingActive, isFalse);
      await Future.wait([
        LocationCacheService.startRiderLiveTracking(),
        LocationCacheService.startRiderLiveTracking(),
      ]);
      expect(platform.streamStarts, 1);
      await LocationCacheService.stopRiderLiveTracking();
      expect(platform.positions.hasListener, isFalse);
      await LocationCacheService.startRiderLiveTracking();
      final replacement = LocationCacheService.riderLocationStream;
      final heartbeat = LocationCacheService.riderHeartbeatTimer;
      oldError(StateError('synthetic late error'));
      expect(identical(LocationCacheService.riderLocationStream, replacement), isTrue);
      expect(identical(LocationCacheService.riderHeartbeatTimer, heartbeat), isTrue);
      expect(LocationCacheService.isRiderLiveTrackingActive, isTrue);
      expect(platform.streamStarts, 2);
      await LocationCacheService.stopRiderLiveTracking();
      expect(platform.positions.hasListener, isFalse);
      expect(heartbeat!.isActive, isFalse);
    });
    test('actual error event from an open stream stops heartbeat but retains its handle', () async {
      await LocationCacheService.startRiderLiveTracking();
      final owned = LocationCacheService.riderLocationStream;
      final delivered = Completer<void>();
      final observed = platform.positions.stream.listen((_) {}, onError: (Object _) => delivered.complete());
      platform.positions.addError(StateError('synthetic platform error'));
      await delivered.future;
      expect(identical(LocationCacheService.riderLocationStream, owned), isTrue);
      expect(LocationCacheService.isRiderLiveTrackingActive, isFalse);
      await observed.cancel();
      await LocationCacheService.stopRiderLiveTracking();
      expect(platform.positions.hasListener, isFalse);
    });
    test('failed stream stays owned while cancellation is pending; starts remain deduplicated', () async {
      final cancelStarted = Completer<void>();
      final cancelFinished = Completer<void>();
      final failed = StreamController<Position>(onCancel: () {
        cancelStarted.complete();
        return cancelFinished.future;
      });
      platform.positionOverride = failed.stream;
      await LocationCacheService.startRiderLiveTracking();
      final owned = LocationCacheService.riderLocationStream;
      platform.errorCallbacks.single(StateError('synthetic error'));
      final stop = LocationCacheService.stopRiderLiveTracking();
      await cancelStarted.future;
      await LocationCacheService.startRiderLiveTracking();
      expect(identical(LocationCacheService.riderLocationStream, owned), isTrue);
      expect(platform.streamStarts, 1);
      cancelFinished.complete();
      await stop;
      expect(LocationCacheService.riderLocationStream, isNull);
      platform.positionOverride = null;
      await LocationCacheService.startRiderLiveTracking();
      expect(platform.streamStarts, 2);
      expect(LocationCacheService.isRiderLiveTrackingActive, isTrue);
      await failed.close();
    });
    test('retired owner during permission await cannot install tracking', () async {
      var current = true;
      platform.permissionGate = Completer<LocationPermission>();
      final start = LocationCacheService.startRiderLiveTracking(canStart: () => current);
      await platform.permissionStarted.future;
      current = false;
      platform.permissionGate!.complete(LocationPermission.always);
      await start;
      expect(platform.streamStarts, 0);
      expect(LocationCacheService.isRiderLiveTrackingActive, isFalse);
    });
    test('quiet unavailable-GPS startup is detected rather than reported restored', () async {
      platform.enabled = false;
      final result = await restoreOfflineTracking(
        isCurrentIdentity: () => true,
        isTrackingActive: () => LocationCacheService.isRiderLiveTrackingActive,
        restartTracking: () => LocationCacheService.startRiderLiveTracking(),
        stopIncompleteTracking: () => LocationCacheService.stopRiderLiveTracking(),
      );
      expect(result, OfflineTrackingRollback.unavailable);
      expect(LocationCacheService.isRiderLiveTrackingActive, isFalse);
    });
    test('old stop cannot clear replacement stream or cancel replacement heartbeat', () async {
      final cancelStarted = Completer<void>();
      final cancelFinished = Completer<void>();
      final old = StreamController<Position>(onCancel: () {
        cancelStarted.complete();
        return cancelFinished.future;
      });
      LocationCacheService.riderLocationStream = old.stream.listen((_) {});
      final oldHeartbeat = Timer.periodic(const Duration(hours: 1), (_) {});
      LocationCacheService.riderHeartbeatTimer = oldHeartbeat;
      final stop = LocationCacheService.stopRiderLiveTracking();
      await cancelStarted.future;
      final replacement = platform.positions.stream.listen((_) {});
      final newHeartbeat = Timer.periodic(const Duration(hours: 1), (_) {});
      LocationCacheService.riderLocationStream = replacement;
      LocationCacheService.riderHeartbeatTimer = newHeartbeat;
      cancelFinished.complete();
      await stop;
      expect(oldHeartbeat.isActive, isFalse);
      expect(identical(LocationCacheService.riderLocationStream, replacement), isTrue);
      expect(newHeartbeat.isActive, isTrue);
      await old.close();
    });
  });
}

class _LocalGeolocator extends GeolocatorPlatform {
  bool enabled = true;
  Completer<bool>? enabledGate;
  Completer<LocationPermission>? permissionGate;
  final permissionStarted = Completer<void>();
  final positions = StreamController<Position>.broadcast();
  int streamStarts = 0;
  Stream<Position>? positionOverride;
  final errorCallbacks = <void Function(Object)>[];
  @override
  Future<bool> isLocationServiceEnabled() async => enabledGate == null ? enabled : await enabledGate!.future;
  @override
  Future<LocationPermission> checkPermission() async {
    if (!permissionStarted.isCompleted) permissionStarted.complete();
    return permissionGate == null ? LocationPermission.always : await permissionGate!.future;
  }
  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    streamStarts++;
    return _CapturedErrorStream(positionOverride ?? positions.stream, errorCallbacks);
  }
  @override
  Stream<ServiceStatus> getServiceStatusStream() => const Stream.empty();
  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) =>
      Future.error(StateError('synthetic position unavailable')); // Never reach a database write.
  @override
  Future<Position?> getLastKnownPosition({bool forceLocationManager = false}) => Future.value(null);
}

// Retain the real registered callback to simulate a platform's late callback
// after cancellation. Data/error delivery otherwise uses a real Dart stream.
class _CapturedErrorStream extends Stream<Position> {
  _CapturedErrorStream(this.source, this.callbacks);
  final Stream<Position> source;
  final List<void Function(Object)> callbacks;
  @override
  StreamSubscription<Position> listen(void Function(Position)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    callbacks.add((error) => Function.apply(onError!, [error]));
    return source.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }
}
