import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/rider/home/active_order_refresh_coordinator.dart';

void main() {
  test('authoritative order invalidation blocks free actions until that revision reconciles', () {
    final verification = RiderActiveOrderVerification()..beginIdentity('A');
    final complete = ActiveOrderEventMetadata().reconcile([], [], (_) => true);
    expect(verification.apply('A', complete, orderRevision: 1), isTrue);
    expect(verification.unresolvedFor('A', orderRevision: 1), isFalse);
    expect(verification.unresolvedFor('A', orderRevision: 2), isTrue);
    expect(verification.apply('A', complete, orderRevision: 2), isTrue);
    expect(verification.unresolvedFor('A', orderRevision: 2), isFalse);
    expect(verification.unresolvedFor('B', orderRevision: 2), isTrue);
    verification.dispose();
    expect(verification.unresolvedFor('A', orderRevision: 2), isTrue);
  });
  late String? rider;
  late List<Completer<String>> requests;
  late List<String> applied;
  late ActiveOrderRefreshCoordinator<String> coordinator;
  setUp(() {
    rider = 'a';
    requests = [];
    applied = [];
    coordinator = ActiveOrderRefreshCoordinator(
      currentRiderId: () => rider,
      fetch: (_) {
        final request = Completer<String>();
        requests.add(request);
        return request.future;
      },
      apply: applied.add,
    );
  });

  group('identity-scoped busy verification using production coordinator/reconciliation', () {
    final busyB = <String, dynamic>{'id': 'b-order', 'rider_id': 'B',
      'order_status': 'ongoing', 'updated_at': '2026-10-13T01:00:02Z'};
    test('B assignment arrives before verification; late A cannot release B', () async {
      final home = _IdentityVerificationHarness();
      home.verification.apply('A', home.metadata.reconcile([], [], (_) => true));
      expect(home.blocked, isFalse);
      final oldA = home.refresh.request('A');
      home.changeIdentity('B');
      final newB = home.refresh.request('B');
      expect(home.requests, hasLength(1));
      expect(home.announceIncoming(), isFalse);
      expect(home.canGoOffline, isFalse);
      expect(home.canAcceptSecondOrder, isFalse);
      home.requests[0].complete([]); // Even a successful/free A result is obsolete.
      await oldA;
      expect(home.requests, hasLength(2));
      expect(home.verification.unresolvedFor('B'), isTrue);
      expect(home.rows, isEmpty);
      expect(home.announceIncoming(), isFalse);
      home.requests[1].complete([busyB]);
      await newB;
      expect(home.verification.unresolvedFor('B'), isFalse);
      expect(home.rows, [busyB]);
      expect(home.blocked, isTrue); // Verified busy is still blocked.
      home.metadata.record({...busyB, 'order_status': 'completed',
        'updated_at': '2026-10-13T01:00:03Z'}, {}, deleted: false);
      final free = home.refresh.request('B');
      home.requests[2].complete([]);
      await free;
      expect(home.blocked, isFalse);
      expect(home.canGoOffline && home.canAcceptSecondOrder, isTrue);
      expect(home.announceIncoming(), isTrue);
      expect(home.announcements, 1);
    });
    test('B request failure keeps verification active and a later valid request releases it', () async {
      final home = _IdentityVerificationHarness()..changeIdentity('B');
      final failed = home.refresh.request('B');
      home.requests[0].completeError(StateError('synthetic request failure'));
      await failed;
      expect(home.blocked, isTrue);
      expect(home.announceIncoming(), isFalse);
      final retry = home.refresh.request('B');
      home.requests[1].complete([]);
      await retry;
      expect(home.blocked, isFalse);
    });
    for (final kind in ['ambiguous', 'malformed', 'stale']) {
      test('$kind B reconciliation cannot release verification', () async {
        final home = _IdentityVerificationHarness()..changeIdentity('B');
        if (kind != 'malformed') {
          home.metadata.record(busyB, {}, deleted: false);
        }
        if (kind == 'ambiguous') {
          home.metadata.record({...busyB, 'updated_at': null}, {}, deleted: false);
        }
        final done = home.refresh.request('B');
        home.requests.single.complete(kind == 'malformed' ? [{}] :
          [{...busyB, if (kind == 'stale') 'updated_at': '2026-10-13T01:00:01Z'}]);
        await done;
        expect(home.rows, isEmpty);
        expect(home.verification.unresolvedFor('B'), isTrue);
        expect(home.announceIncoming(), isFalse);
        expect(home.canGoOffline || home.canAcceptSecondOrder, isFalse);
      });
    }
    test('disposal prevents a pending valid/free result releasing verification', () async {
      final home = _IdentityVerificationHarness()..changeIdentity('B');
      final done = home.refresh.request('B');
      home.refresh.dispose();
      home.verification.dispose();
      home.requests.single.complete([]);
      await done;
      expect(home.blocked, isTrue);
      expect(home.announceIncoming(), isFalse);
    });
    test('verification refuses a result for another identity and tracks current identity', () {
      final verification = RiderActiveOrderVerification()..beginIdentity('B');
      final complete = ActiveOrderEventMetadata().reconcile([], [], (_) => true);
      expect(verification.apply('A', complete), isFalse);
      expect(verification.unresolvedFor('B'), isTrue);
      expect(verification.apply('B', complete), isTrue);
      expect(verification.unresolvedFor('B'), isFalse);
      expect(verification.unresolvedFor('A'), isTrue);
      verification.beginIdentity('B'); // An ordinary same-identity refresh does not reset evidence.
      expect(verification.unresolvedFor('B'), isFalse);
      verification.beginIdentity('A');
      expect(verification.unresolvedFor('A'), isTrue);
    });
  });

  test('timer/resume/events share one active and one trailing request', () async {
    final first = coordinator.request('a');
    final resume = coordinator.request('a');
    final event = coordinator.request('a');
    expect(requests, hasLength(1));
    expect(identical(first, resume), isFalse);
    expect(identical(resume, event), isTrue);
    requests[0].complete('old accepted');
    await Future<void>.value();
    expect(requests, hasLength(2));
    expect(applied, ['old accepted']);
    requests[1].complete('completed');
    await Future.wait([first, resume, event]);
    expect(applied, ['old accepted', 'completed']);
    expect(requests, hasLength(2));
  });

  test('trigger immediately before completion is retained and awaited', () async {
    final first = coordinator.request('a');
    requests[0].complete('accepted');
    final acceptedCaller = coordinator.request('a');
    var finished = false;
    unawaited(acceptedCaller.then((_) => finished = true));
    await Future<void>.value();
    expect(requests, hasLength(2));
    expect(finished, isFalse);
    requests[1].complete('new accepted');
    await first;
    await acceptedCaller;
    expect(applied, ['accepted', 'new accepted']);
  });

  test('a trigger during the trailing request queues only one next request', () async {
    final done = coordinator.request('a');
    coordinator.request('a');
    requests[0].complete('old');
    await Future<void>.value();
    coordinator.request('a');
    coordinator.request('a');
    requests[1].complete('also old');
    await Future<void>.value();
    expect(requests, hasLength(3));
    requests[2].complete('current');
    await done;
    await Future<void>.value();
    expect(applied, ['old', 'also old', 'current']);
  });

  test('failure releases state and allows subsequent refresh', () async {
    final failed = coordinator.request('a');
    requests[0].completeError(StateError('synthetic'));
    await failed;
    final next = coordinator.request('a');
    requests[1].complete('accepted');
    await next;
    expect(applied, ['accepted']);
  });

  test('sustained ordinary demand applies results and completes each assigned batch', () async {
    final first = coordinator.request('a');
    final second = coordinator.request('a');
    requests[0].complete('snapshot 1');
    await first;
    expect(applied, ['snapshot 1']);
    expect(requests, hasLength(2));
    final third = coordinator.request('a');
    requests[1].complete('snapshot 2');
    await second;
    expect(applied, ['snapshot 1', 'snapshot 2']);
    expect(requests, hasLength(3));
    final fourth = coordinator.request('a');
    requests[2].complete('snapshot 3');
    await third;
    expect(applied, ['snapshot 1', 'snapshot 2', 'snapshot 3']);
    requests[3].complete('snapshot 4');
    await fourth;
  });

  test('production-style event and refetch reject stale terminal resurrection', () async {
    final pending = <Completer<List<Map<String, dynamic>>>>[];
    final events = <String, Map<String, dynamic>?>{};
    final snapshots = <List<Map<String, dynamic>>>[];
    final refresh = ActiveOrderRefreshCoordinator<List<Map<String, dynamic>>>(
      currentRiderId: () => 'a',
      fetch: (_) async {
        final result = Completer<List<Map<String, dynamic>>>();
        pending.add(result);
        final rows = await result.future;
        if (!activeOrderSnapshotMatchesEvents(rows, events)) {
          throw StateError('superseded');
        }
        return rows;
      },
      apply: snapshots.add,
    );
    final old = {'id': 'order', 'rider_id': 'a', 'order_status': 'accepted',
      'updated_at': '2026-10-13T01:00:00Z'};
    final first = refresh.request('a');
    events['order'] = {...old, 'order_status': 'completed',
      'updated_at': '2026-10-13T01:00:01Z'};
    refresh.invalidate();
    final trailing = refresh.request('a');
    pending[0].complete([old]);
    await first;
    pending[1].complete([old]);
    await trailing;
    expect(snapshots, isEmpty);
    final valid = refresh.request('a');
    pending[2].complete([]);
    await valid;
    expect(snapshots, [[]]);
  });

  test('event comparison covers assignment, trip start, deletion and newer versions', () {
    final event = <String, dynamic>{'id': 'order', 'rider_id': 'a',
      'order_status': 'accepted', 'trip_started_at': null,
      'updated_at': '2026-10-13T01:00:01Z'};
    bool check(List<Map<String, dynamic>> rows, Map<String, dynamic>? observed,
        {bool busy = true}) => activeOrderSnapshotMatchesEvents(
          rows, {'order': observed});
    expect(check([], event), isTrue);
    expect(check([], event, busy: false), isTrue);
    expect(check([], {...event, 'rider_id': 'b'}), isTrue);
    expect(check([event], null), isFalse);
    expect(check([], null), isTrue);
    expect(check([{...event, 'updated_at': 'invalid', 'trip_started_at': 'started'}], event), isFalse);
    expect(check([{...event, 'updated_at': '2026-10-13T01:00:02Z',
      'order_status': 'ongoing'}], event), isTrue);
    expect(check([event], event), isTrue);
    expect(check([{...event, 'updated_at': null}], event), isFalse);
  });

  test('failure retains a queued refresh', () async {
    final done = coordinator.request('a');
    final trailing = coordinator.request('a');
    requests[0].completeError(StateError('synthetic'));
    await Future<void>.value();
    requests[1].complete('cancelled');
    await done;
    await trailing;
    expect(applied, ['cancelled']);
  });

  test('disposal suppresses application, queued and future requests', () async {
    final done = coordinator.request('a');
    coordinator.request('a');
    coordinator.dispose();
    requests[0].complete('accepted');
    await done;
    await coordinator.request('a');
    expect(requests, hasLength(1));
    expect(applied, isEmpty);
  });

  test('identity change rejects old results and serializes new identity', () async {
    final first = coordinator.request('a');
    rider = 'b';
    final second = coordinator.request('b');
    requests[0].complete('a accepted');
    await Future<void>.value();
    expect(requests, hasLength(2));
    requests[1].complete('b accepted');
    await Future.wait([first, second]);
    expect(applied, ['b accepted']);
    await coordinator.request('a');
    expect(requests, hasLength(2));
  });

  for (final state in ['accepted', 'completed', 'cancelled']) {
    test('new $state event invalidates an older HTTP snapshot', () async {
      final done = coordinator.request('a');
      coordinator.invalidate();
      final refetch = coordinator.request('a');
      requests[0].complete('old accepted');
      await done;
      expect(applied, isEmpty);
      requests[1].complete(state);
      await refetch;
      expect(applied, [state]);
    });
  }

  test('rider changes away and back invalidate the previous identity generation', () async {
    final done = coordinator.request('a');
    rider = 'b';
    coordinator.invalidate();
    rider = 'a';
    coordinator.invalidate();
    requests[0].complete('old identity');
    await done;
    expect(applied, isEmpty);
  });

  test('production wiring retains the complete query and local/intercity busy filter', () {
    final source = File('lib/features/rider/home/rider_home_tab.dart').readAsStringSync();
    expect(source, contains(".select('*, users(full_name, gender, profile_photo_url)')"));
    expect(source, contains(".inFilter('order_status', ['accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing', 'payment_pending'])"));
    expect(source, contains('_activeOrderEvents.reconcile(orderRows, activeOrders, _isOrderActivelyBusy)'));
    final contract = File('lib/features/rider/home/active_order_refresh_coordinator.dart').readAsStringSync();
    expect(source, contains('isRiderOrderActivelyBusy(order)'));
    expect(contract, contains("if (status != 'accepted') return true;"));
    expect(contract, contains("type.startsWith('intercity') || (type == 'ride' && distanceMeters > 20000)"));
    expect(contract, contains("return order['trip_started_at'] != null;"));
    expect(source, contains('await loadActiveOrder(riderId);'));
    expect(source, contains('_activeOrderRefresh.dispose();'));
    expect(source, contains("if (rider?['id'] != data?['id']) {"));
    expect(source, contains("_activeOrderVerification.apply(rider?['id']?.toString(), result,"));
    expect(source, contains('orderRevision: _activeOrderRefresh.invalidationRevision'));
    expect(source, contains("_activeOrderVerification.beginIdentity(data?['id']?.toString());"));
    expect(source, contains('if (_activeOrderEvidenceUnresolved) return;'));
    expect(source, contains('if (_activeOrderEvidenceUnresolved || activeOrders.isNotEmpty) {'));
    expect(source, contains('if (confirm != true || statusUpdating || !isOnline || !stillPermitted()) return;'));
    expect(source, contains(".eq('user_id', offlineOperation.userId)"));
  });

  group('offline confirmation uses the production operation-context guard', () {
    for (final change in ['identity', 'busy', 'unresolved', 'auth', 'disposed', 'order event', 'none', 'cancel']) {
      test('$change while confirmation is pending', () async {
        final verification = RiderActiveOrderVerification()..beginIdentity('A');
        final metadata = ActiveOrderEventMetadata();
        var riderId = 'A';
        var userId = 'user-A';
        var orderRevision = 0;
        var rows = <Map<String, dynamic>>[];
        verification.apply(riderId, metadata.reconcile([], [], isRiderOrderActivelyBusy));
        final operation = verification.captureOfflineContext(riderId: riderId,
          userId: userId, hasActiveOrders: false, orderRevision: orderRevision)!;
        final confirmation = Completer<bool?>();
        var stateChanges = 0;
        var trackingStops = 0;
        final writes = <String>[];
        Future<void> afterConfirmation() async {
          if (await confirmation.future != true || !verification.permitsOffline(operation,
            riderId: riderId, userId: userId, hasActiveOrders: rows.isNotEmpty,
              orderRevision: orderRevision)) {
            return;
          }
          stateChanges++;
          trackingStops++;
          writes.add(operation.userId);
        }
        final done = afterConfirmation();
        if (change == 'identity') {
          riderId = 'B'; userId = 'user-B'; verification.beginIdentity(riderId);
        } else if (change == 'busy') {
          rows = [{'id': 'busy', 'rider_id': 'A', 'order_status': 'ongoing',
            'updated_at': '2026-10-13T01:00:02Z'}];
          verification.apply(riderId, metadata.reconcile(rows, [], isRiderOrderActivelyBusy));
        } else if (change == 'unresolved') {
          verification.apply(riderId, metadata.reconcile([{}], [], isRiderOrderActivelyBusy));
        } else if (change == 'auth') {
          userId = 'user-B';
        } else if (change == 'disposed') {
          verification.dispose();
        } else if (change == 'order event') {
          orderRevision++;
        }
        confirmation.complete(change == 'cancel' ? false : true);
        await done;
        final allowed = change == 'none';
        expect(stateChanges, allowed ? 1 : 0);
        expect(trackingStops, allowed ? 1 : 0);
        expect(writes, allowed ? ['user-A'] : isEmpty);
      });
    }
    test('A to B to A cannot revive an old confirmation', () {
      final verification = RiderActiveOrderVerification()..beginIdentity('A');
      final valid = ActiveOrderEventMetadata().reconcile([], [], isRiderOrderActivelyBusy);
      verification.apply('A', valid);
      final operation = verification.captureOfflineContext(riderId: 'A', userId: 'user-A',
        hasActiveOrders: false, orderRevision: 0)!;
      verification.beginIdentity('B');
      verification.beginIdentity('A');
      verification.apply('A', valid);
      expect(verification.permitsOffline(operation, riderId: 'A', userId: 'user-A',
        hasActiveOrders: false, orderRevision: 0), isFalse);
    });
    test('a busy/uncertain interval expires the old confirmation even after free verification', () {
      final verification = RiderActiveOrderVerification()..beginIdentity('A');
      final metadata = ActiveOrderEventMetadata();
      final valid = metadata.reconcile([], [], isRiderOrderActivelyBusy);
      verification.apply('A', valid);
      final operation = verification.captureOfflineContext(riderId: 'A', userId: 'user-A',
        hasActiveOrders: false, orderRevision: 0)!;
      verification.apply('A', metadata.reconcile([{}], [], isRiderOrderActivelyBusy));
      verification.apply('A', valid);
      expect(verification.permitsOffline(operation, riderId: 'A', userId: 'user-A',
        hasActiveOrders: false, orderRevision: 0), isFalse);
    });
    test('ordinary verified-free refresh does not expire valid confirmation', () {
      final verification = RiderActiveOrderVerification()..beginIdentity('A');
      final valid = ActiveOrderEventMetadata().reconcile([], [], isRiderOrderActivelyBusy);
      verification.apply('A', valid);
      final operation = verification.captureOfflineContext(riderId: 'A', userId: 'user-A',
        hasActiveOrders: false, orderRevision: 0)!;
      verification.apply('A', valid);
      expect(verification.permitsOffline(operation, riderId: 'A', userId: 'user-A',
        hasActiveOrders: false, orderRevision: 0), isTrue);
    });
    test('new confirmation cannot use free verification from before an order event', () {
      final verification = RiderActiveOrderVerification()..beginIdentity('A');
      final valid = ActiveOrderEventMetadata().reconcile([], [], isRiderOrderActivelyBusy);
      verification.apply('A', valid, orderRevision: 0);
      expect(verification.captureOfflineContext(riderId: 'A', userId: 'user-A',
        hasActiveOrders: false, orderRevision: 1), isNull);
      verification.apply('A', valid, orderRevision: 1);
      expect(verification.captureOfflineContext(riderId: 'A', userId: 'user-A',
        hasActiveOrders: false, orderRevision: 1), isNotNull);
    });
    test('identity change during tracking stop cannot retarget the offline write or rollback', () async {
      final verification = RiderActiveOrderVerification()..beginIdentity('A');
      verification.apply('A', ActiveOrderEventMetadata().reconcile([], [], isRiderOrderActivelyBusy));
      var riderId = 'A';
      var userId = 'user-A';
      final operation = verification.captureOfflineContext(riderId: riderId,
        userId: userId, hasActiveOrders: false, orderRevision: 0)!;
      final confirmation = Completer<bool?>();
      final stopStarted = Completer<void>();
      final stopFinished = Completer<void>();
      final writes = <String>[];
      var rollbackCount = 0;
      bool permitted() => verification.permitsOffline(operation, riderId: riderId,
          userId: userId, hasActiveOrders: false, orderRevision: 0);
      Future<void> run() async {
        if (await confirmation.future != true || !permitted()) return;
        stopStarted.complete();
        await stopFinished.future;
        if (!permitted()) {
          if (verification.sameOfflineIdentity(operation, riderId, userId)) rollbackCount++;
          return;
        }
        writes.add(operation.userId);
      }
      final done = run();
      confirmation.complete(true);
      await stopStarted.future;
      riderId = 'B'; userId = 'user-B'; verification.beginIdentity(riderId);
      stopFinished.complete();
      await done;
      expect(writes, isEmpty);
      expect(rollbackCount, 0);
      expect(verification.unresolvedFor('B'), isTrue);
    });
  });

  group('version validation precedes the actual busy predicate', () {
    final future = <String, dynamic>{'id': 'future', 'rider_id': 'B',
      'order_status': 'accepted', 'order_type': 'intercity_ride',
      'trip_started_at': null, 'distance_meters': null, 'parcel_images': null,
      'updated_at': '2026-10-13T01:00:02Z'};
    for (final version in [null, 'malformed', '2026-10-13T01:00:02', 'missing']) {
      test('$version cannot verify a new rider even though the future order is not busy', () {
        final metadata = ActiveOrderEventMetadata();
        final verification = RiderActiveOrderVerification()..beginIdentity('B');
        final row = {...future, 'updated_at': version};
        if (version == 'missing') row.remove('updated_at');
        expect(isRiderOrderActivelyBusy(row), isFalse);
        metadata.record(row, {}, deleted: false);
        // Also check without any prior metadata, the original bypass path.
        final emptyMetadata = ActiveOrderEventMetadata();
        for (final recorder in [metadata, emptyMetadata]) {
          final result = recorder.reconcile([row], [], isRiderOrderActivelyBusy);
          expect(result.evidence, isNot(ActiveOrderEvidence.complete));
          verification.apply('B', result);
          expect(verification.unresolvedFor('B'), isTrue);
        }
      });
    }
    test('valid version and unrelated nullable fields permit complete verification', () {
      final metadata = ActiveOrderEventMetadata();
      metadata.record(future, {}, deleted: false);
      final result = metadata.reconcile([future], [], isRiderOrderActivelyBusy);
      expect(result.evidence, ActiveOrderEvidence.complete);
      expect(result.orders, isEmpty);
      final verification = RiderActiveOrderVerification()..beginIdentity('B');
      verification.apply('B', result);
      expect(verification.unresolvedFor('B'), isFalse);
    });
    test('bad-version future A does not stop valid ongoing B from partial progress', () {
      final row = {...future, 'updated_at': null};
      final busy = {...future, 'id': 'busy', 'order_type': 'ride', 'order_status': 'ongoing'};
      final result = ActiveOrderEventMetadata().reconcile([row, busy], [], isRiderOrderActivelyBusy);
      expect(result.evidence, ActiveOrderEvidence.partial);
      expect(result.orders, [busy]);
      expect(result.blocksBusyActions, isTrue);
    });
    test('existing local/intercity and payment-pending busy rules remain unchanged', () {
      expect(isRiderOrderActivelyBusy({...future, 'order_type': 'ride', 'distance_meters': 1000}), isTrue);
      expect(isRiderOrderActivelyBusy({...future, 'order_type': 'ride', 'distance_meters': 21000}), isFalse);
      expect(isRiderOrderActivelyBusy({...future, 'trip_started_at': 'started'}), isTrue);
      expect(isRiderOrderActivelyBusy({...future, 'order_status': 'payment_pending'}), isTrue);
      expect(isRiderOrderActivelyBusy({...future, 'order_type': 'intercity_parcel'}), isFalse);
    });
  });

  group('actual Realtime metadata recording and snapshot validation', () {
    final t1 = <String, dynamic>{'id': 'order', 'rider_id': 'a',
      'order_status': 'accepted', 'trip_started_at': null,
      'updated_at': '2026-10-13T01:00:01Z'};
    final t2 = {...t1, 'order_status': 'completed',
      'updated_at': '2026-10-13T01:00:02Z'};
    for (final timestamp in [null, 'invalid', '2026-10-13T01:00:01',
        '2026-02-30T01:00:01Z', '2026-10-13T01:00:01+25:00']) {
      test('invalid version $timestamp cannot downgrade a valid floor', () {
        final metadata = ActiveOrderEventMetadata();
        metadata.record(t2, {}, deleted: false);
        metadata.record({...t1, 'updated_at': timestamp}, {}, deleted: false);
        expect(metadata.matches([t1]), isFalse);
        expect(metadata.matches([]), isTrue, reason: 'No ambiguous order is returned');
        // An older valid event cannot clear the ambiguity or the floor.
        metadata.record(t1, {}, deleted: false);
        expect(metadata.matches([t1]), isFalse);
        metadata.record(t2, {}, deleted: false);
        expect(metadata.matches([t1]), isFalse);
        expect(metadata.matches([]), isTrue);
      });
      test('initial invalid version $timestamp is not evidence of freshness', () {
        final metadata = ActiveOrderEventMetadata();
        metadata.record({...t1, 'updated_at': timestamp}, {}, deleted: false);
        expect(metadata.matches([t1]), isFalse);
        expect(metadata.matches([]), isTrue, reason: 'Filtered absence does not resurrect the order');
        metadata.record(t2, {}, deleted: false);
        expect(metadata.matches([t1]), isFalse);
        expect(metadata.matches([]), isTrue);
      });
    }
    test('missing timestamp key retains the floor', () {
      final metadata = ActiveOrderEventMetadata();
      metadata.record(t2, {}, deleted: false);
      final missing = Map<String, dynamic>.from(t1)..remove('updated_at');
      metadata.record(missing, {}, deleted: false);
      expect(metadata.matches([t1]), isFalse);
    });
    for (final id in [null, '', ' ', ' order ', 123]) {
      test('invalid identity $id preserves floors and requires scoped recovery', () {
        final metadata = ActiveOrderEventMetadata();
        metadata.record(t2, {}, deleted: false);
        metadata.record({...t1, 'id': id}, t1, deleted: false);
        metadata.record(t2, {}, deleted: false);
        expect(metadata.matches([t1]), isFalse);
        expect(metadata.matches([]), isTrue);
        expect(metadata.matches([{...t1, 'id': 'unobserved', 'updated_at': null}]), isFalse);
        expect(metadata.matches([{...t1, 'id': 'unobserved'}]), isTrue);
        metadata.clear();
        expect(metadata.matches([]), isTrue);
      });
    }
    test('missing ID key does not fall back to an UPDATE oldRecord identity', () {
      final metadata = ActiveOrderEventMetadata();
      final missing = Map<String, dynamic>.from(t1)..remove('id');
      metadata.record(missing, t2, deleted: false);
      expect(metadata.matches([t1]), isFalse);
      expect(metadata.matches([]), isTrue);
      expect(metadata.matches([{...t1, 'id': 'unobserved', 'updated_at': null}]), isFalse);
    });
    test('timezone offsets compare by instant and newer valid events advance the floor', () {
      final metadata = ActiveOrderEventMetadata();
      metadata.record(t2, {}, deleted: false);
      final newer = {...t1, 'order_status': 'ongoing',
        'updated_at': '2026-10-13T06:30:03+05:30'};
      metadata.record(newer, {}, deleted: false);
      expect(metadata.matches([t1]), isFalse);
      expect(metadata.matches([newer]), isTrue);
      expect(metadata.matches([{...newer, 'updated_at': '2026-10-13T01:00:03'}]), isFalse);
    });
    test('equal-version conflicting events cannot erase authoritative status', () {
      final metadata = ActiveOrderEventMetadata();
      metadata.record(t2, {}, deleted: false);
      metadata.record({...t1, 'updated_at': t2['updated_at']}, {}, deleted: false);
      expect(metadata.matches([t1]), isFalse);
      expect(metadata.matches([]), isTrue, reason: 'Ambiguity is scoped to returned orders');
    });
    test('valid unassignment and DELETE remain compatible', () {
      final metadata = ActiveOrderEventMetadata();
      metadata.record({...t2, 'rider_id': null}, {}, deleted: false);
      expect(metadata.matches([]), isTrue);
      metadata.record({}, t2, deleted: true);
      expect(metadata.matches([t1]), isFalse);
      expect(metadata.matches([]), isTrue);
    });

    test('ambiguous terminal A does not block valid B or lose its own floor', () {
      final metadata = ActiveOrderEventMetadata();
      final b = {...t1, 'id': 'b'};
      metadata.record(t2, {}, deleted: false);
      metadata.record({...t1, 'updated_at': null}, {}, deleted: false);
      metadata.record(b, {}, deleted: false);
      expect(metadata.matches([b]), isTrue);
      expect(metadata.matches([t1]), isFalse);
      expect(metadata.matches([b, t1]), isFalse);
      metadata.record(t1, {}, deleted: false);
      expect(metadata.matches([t1]), isFalse);
      metadata.record(t2, {}, deleted: false);
      expect(metadata.matches([t1]), isFalse);
      expect(metadata.matches([t2]), isTrue);
      expect(metadata.matches([b]), isTrue);
    });

    test('unscoped event permits B recovery but cannot clear A ambiguity', () {
      final metadata = ActiveOrderEventMetadata();
      final b = {...t1, 'id': 'b'};
      metadata.record(t2, {}, deleted: false);
      metadata.record({'updated_at': t1['updated_at']}, {}, deleted: false);
      expect(metadata.matches([{...b, 'updated_at': null}]), isFalse);
      expect(metadata.matches([b]), isTrue);
      metadata.record(b, {}, deleted: false);
      expect(metadata.matches([b]), isTrue);
      expect(metadata.matches([t1]), isFalse);
      expect(metadata.matches([t2]), isFalse);
      metadata.record(t2, {}, deleted: false);
      expect(metadata.matches([t2]), isTrue);
      expect(metadata.matches([t1]), isFalse);
    });

    for (final id in [null, '', ' ', ' order ', 1]) {
      test('malformed snapshot identity $id cannot bypass scoped ambiguity', () {
        final metadata = ActiveOrderEventMetadata();
        metadata.record(t2, {}, deleted: false);
        metadata.record({...t1, 'updated_at': null}, {}, deleted: false);
        expect(metadata.matches([{...t1, 'id': id}]), isFalse);
      });
    }
    test('missing or duplicate snapshot ID cannot bypass scoped ambiguity', () {
      final metadata = ActiveOrderEventMetadata();
      final missing = Map<String, dynamic>.from(t1)..remove('id');
      expect(metadata.matches([missing]), isFalse);
      expect(metadata.matches([t1, t1]), isFalse);
    });

    test('DELETE wins a same-instant replay; strictly newer valid event can recover', () {
      final metadata = ActiveOrderEventMetadata();
      metadata.record(t1, {}, deleted: false);
      metadata.record({}, t1, deleted: true);
      final sameInstant = {...t1, 'updated_at': '2026-10-13T06:30:01+05:30'};
      metadata.record(sameInstant, {}, deleted: false);
      expect(metadata.matches([sameInstant]), isFalse);
      expect(metadata.matches([t1]), isFalse);
      expect(metadata.matches([]), isTrue);
      final newer = {...t1, 'updated_at': '2026-10-13T01:00:02Z'};
      metadata.record(newer, {}, deleted: false);
      expect(metadata.matches([newer]), isTrue);
      expect(metadata.matches([t1]), isFalse);
      // Replaying an older DELETE cannot erase the newer valid event.
      metadata.record({}, t1, deleted: true);
      expect(metadata.matches([newer]), isTrue);
    });
    test('same-version DELETE also wins when it arrives after the live event', () {
      final metadata = ActiveOrderEventMetadata();
      metadata.record(t1, {}, deleted: false);
      metadata.record({}, {...t1, 'updated_at': '2026-10-13T06:30:01+05:30'}, deleted: true);
      expect(metadata.matches([t1]), isFalse);
    });
    test('unversioned DELETE stays latched through versioned replays until identity reset', () {
      final metadata = ActiveOrderEventMetadata();
      metadata.record(t1, {}, deleted: false);
      metadata.record({}, {'id': 'order'}, deleted: true);
      metadata.record(t2, {}, deleted: false);
      expect(metadata.matches([t2]), isFalse);
      metadata.record({}, t2, deleted: true);
      final newer = {...t1, 'updated_at': '2026-10-13T01:00:03Z'};
      metadata.record(newer, {}, deleted: false);
      expect(metadata.matches([newer]), isFalse);
      metadata.clear(); // New owning identity/lifecycle, not proof about the old deletion.
      metadata.record(newer, {}, deleted: false);
      expect(metadata.matches([newer]), isTrue);
    });
    test('same instant in different offsets compares equal without ambiguity', () {
      final metadata = ActiveOrderEventMetadata();
      metadata.record(t1, {}, deleted: false);
      final offset = {...t1, 'updated_at': '2026-10-13T06:30:01+05:30'};
      metadata.record(offset, {}, deleted: false);
      expect(metadata.matches([t1]), isTrue);
      expect(metadata.matches([offset]), isTrue);
    });
    test('unidentified event invalidates old HTTP but permits a fresh unrelated snapshot', () async {
      final metadata = ActiveOrderEventMetadata();
      final pending = <Completer<List<Map<String, dynamic>>>>[];
      final applied = <List<Map<String, dynamic>>>[];
      final refresh = ActiveOrderRefreshCoordinator<List<Map<String, dynamic>>>(
        currentRiderId: () => 'a',
        fetch: (_) async {
          final response = Completer<List<Map<String, dynamic>>>();
          pending.add(response);
          final rows = await response.future;
          if (!metadata.matches(rows)) throw StateError('superseded');
          return rows;
        },
        apply: applied.add,
      );
      metadata.record(t2, {}, deleted: false);
      final old = refresh.request('a');
      refresh.invalidate();
      metadata.record({}, {}, deleted: false);
      final trailing = refresh.request('a');
      final b = {...t1, 'id': 'b'};
      pending[0].complete([b]);
      await old;
      expect(applied, isEmpty);
      pending[1].complete([b]);
      await trailing;
      expect(applied, [[b]]);
      expect(metadata.matches([t1]), isFalse);
    });

    group('complete versus partial reconciliation contract', () {
      final a = {...t1, 'order_status': 'ongoing', 'current_fare': 100};
      final b = {...t1, 'id': 'b', 'current_fare': 200};
      ActiveOrderEventMetadata ambiguousA() {
        final metadata = ActiveOrderEventMetadata();
        metadata.record(a, {}, deleted: false);
        metadata.record({...a, 'updated_at': null}, {}, deleted: false);
        return metadata;
      }
      test('repeated mixed snapshots advance B while retaining A and busy protection', () {
        final metadata = ambiguousA();
        var current = <Map<String, dynamic>>[a, b];
        var second = 3;
        for (final status in ['rider_arrived', 'ongoing', 'payment_pending']) {
          final nextB = {...b, 'order_status': status,
            'updated_at': '2026-10-13T01:00:0${second++}Z'};
          metadata.record(nextB, {}, deleted: false);
          final result = metadata.reconcile([{...a, 'current_fare': 0}, nextB], current, (_) => true);
          expect(result.evidence, ActiveOrderEvidence.partial);
          expect(result.orders, hasLength(2));
          expect(identical(result.orders.firstWhere((row) => row['id'] == 'order'), a), isTrue);
          expect(result.orders.firstWhere((row) => row['id'] == 'b')['order_status'], status);
          expect(result.blocksBusyActions, isTrue); // Incoming work must remain suppressed.
          current = result.orders;
        }
      });
      test('partial absence cannot remove either previously known busy row', () {
        final metadata = ambiguousA();
        final result = metadata.reconcile([a], [a, b], (_) => true);
        expect(result.orders, [a, b]);
        expect(result.unresolved, isTrue);
        expect(result.blocksBusyActions, isTrue);
      });
      test('unambiguous terminal event removes only its own B row during partial recovery', () {
        final metadata = ambiguousA();
        metadata.record({...b, 'order_status': 'completed',
          'updated_at': '2026-10-13T01:00:03Z'}, {}, deleted: false);
        final result = metadata.reconcile([a], [a, b], (_) => true);
        expect(result.orders, [a]);
        expect(result.blocksBusyActions, isTrue);
      });
      test('older terminal evidence cannot remove a newer validated B row', () {
        final metadata = ambiguousA();
        metadata.record({...b, 'order_status': 'completed'}, {}, deleted: false);
        final newerB = {...b, 'order_status': 'ongoing',
          'updated_at': '2026-10-13T01:00:03Z'};
        final result = metadata.reconcile([a, newerB], [a, b], (_) => true);
        expect(result.orders, [a, newerB]);
      });
      test('resolving A restores full replacement and authoritative removal semantics', () {
        final metadata = ambiguousA();
        metadata.record({...a, 'order_status': 'completed',
          'updated_at': '2026-10-13T01:00:03Z'}, {}, deleted: false);
        final result = metadata.reconcile([b], [a, b], (_) => true);
        expect(result.evidence, ActiveOrderEvidence.complete);
        expect(result.orders, [b]);
        final empty = metadata.reconcile([], result.orders, (_) => true);
        expect(empty.evidence, ActiveOrderEvidence.complete);
        expect(empty.orders, isEmpty);
        expect(empty.blocksBusyActions, isFalse);
      });
      test('unseen ambiguous A never becomes a fabricated row or proof of being free', () {
        final metadata = ambiguousA();
        final result = metadata.reconcile([a, b], [], (_) => false);
        expect(result.orders, isEmpty); // Existing busy predicate decides B's membership.
        expect(result.evidence, ActiveOrderEvidence.partial);
        expect(result.blocksBusyActions, isTrue);
      });
      test('invalid snapshot identity rejects replacement and retains known busy state', () {
        final result = ActiveOrderEventMetadata().reconcile([{}], [a, b], (_) => true);
        expect(result.evidence, ActiveOrderEvidence.rejected);
        expect(result.orders, [a, b]);
        expect(result.blocksBusyActions, isTrue);
      });
      test('partial reconciliation cannot downgrade the previous HTTP version', () {
        final metadata = ambiguousA();
        final newerB = {...b, 'updated_at': '2026-10-13T01:00:03Z'};
        final result = metadata.reconcile([a, b], [a, newerB], (_) => true);
        expect(result.orders, [a, newerB]);
      });
      test('actual coordinator applies partial progress only after the event-triggered refetch', () async {
        final metadata = ambiguousA();
        var current = <Map<String, dynamic>>[a, b];
        final requests = <Completer<List<Map<String, dynamic>>>>[];
        final results = <ActiveOrderReconciliation>[];
        final refresh = ActiveOrderRefreshCoordinator<ActiveOrderReconciliation>(
          currentRiderId: () => 'a',
          fetch: (_) async {
            final request = Completer<List<Map<String, dynamic>>>();
            requests.add(request);
            return metadata.reconcile(await request.future, current, (_) => true);
          },
          apply: (result) { current = result.orders; results.add(result); },
        );
        final old = refresh.request('a');
        final newerB = {...b, 'order_status': 'ongoing',
          'updated_at': '2026-10-13T01:00:03Z'};
        refresh.invalidate();
        metadata.record(newerB, {}, deleted: false);
        final trailing = refresh.request('a');
        requests[0].complete([a, b]);
        await old;
        expect(results, isEmpty);
        requests[1].complete([{...a, 'current_fare': 0}, newerB]);
        await trailing;
        expect(current, [a, newerB]);
        expect(results.single.evidence, ActiveOrderEvidence.partial);
        expect(results.single.blocksBusyActions, isTrue);
      });
    });
  });
}

/// Uses the same production helpers and guard expression as Rider Home;
/// only the network responses and assignment arrival are controlled locally.
class _IdentityVerificationHarness {
  _IdentityVerificationHarness() {
    verification.beginIdentity(rider);
    refresh = ActiveOrderRefreshCoordinator(
      currentRiderId: () => rider,
      fetch: (_) async {
        final response = Completer<List<Map<String, dynamic>>>();
        requests.add(response);
        return metadata.reconcile(await response.future, rows, (_) => true);
      },
      apply: (result) {
        if (verification.apply(rider, result)) rows = result.orders;
      },
    );
  }
  String rider = 'A';
  final metadata = ActiveOrderEventMetadata();
  final verification = RiderActiveOrderVerification();
  late final ActiveOrderRefreshCoordinator<ActiveOrderReconciliation> refresh;
  final requests = <Completer<List<Map<String, dynamic>>>>[];
  List<Map<String, dynamic>> rows = [];
  int announcements = 0;
  bool get blocked => verification.unresolvedFor(rider) || rows.isNotEmpty;
  bool get canGoOffline => !blocked;
  bool get canAcceptSecondOrder => !blocked;
  bool announceIncoming() {
    if (blocked) return false;
    announcements++;
    return true;
  }
  void changeIdentity(String next) {
    refresh.invalidate();
    metadata.clear();
    verification.beginIdentity(next);
    rows = [];
    rider = next;
  }
}
