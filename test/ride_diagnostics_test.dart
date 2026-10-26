import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/diagnostics/ride_diagnostics.dart';
import 'package:waydrop/core/services/diagnostics/ride_diagnostics_owner.dart';

List<Map<String, dynamic>> events(RideDiagnostics r) =>
    (jsonDecode(r.exportJson())['events'] as List).cast<Map<String, dynamic>>();

void main() {
  test('independent captures correlate only with the same run key', () {
    // Fixed fixtures only; no build defines or operator run key are created.
    final a = RideDiagnostics(enabled: true, pseudonymKey: List.filled(32, 11));
    final b = RideDiagnostics(enabled: true, pseudonymKey: List.filled(32, 11));
    final other = RideDiagnostics(
      enabled: true,
      pseudonymKey: List.filled(32, 12),
    );
    for (final recorder in [a, b, other]) {
      recorder.begin(isCurrent: () => true, rawRide: 'fixture-order');
    }
    final first = jsonDecode(a.exportJson()) as Map;
    final second = jsonDecode(b.exportJson()) as Map;
    final different = jsonDecode(other.exportJson()) as Map;
    expect(first['capture_namespace'], second['capture_namespace']);
    expect(events(a).single['ride'], events(b).single['ride']);
    expect(first['capture_namespace'], isNot(different['capture_namespace']));
    expect(events(a).single['ride'], isNot(events(other).single['ride']));
    for (final recorder in [a, b, other]) {
      expect(recorder.exportJson(), isNot(contains('fixture-order')));
    }
  });

  test(
    'same-key captures retain independent monotonic origins and durations',
    () {
      var clockA = 9000000;
      var clockB = 20;
      final a = RideDiagnostics(
        enabled: true,
        pseudonymKey: List.filled(32, 11),
        monotonicMicros: () => clockA,
      );
      final b = RideDiagnostics(
        enabled: true,
        pseudonymKey: List.filled(32, 11),
        monotonicMicros: () => clockB,
      );
      final attemptA = a.begin(isCurrent: () => true, rawRide: 'fixture-order');
      final attemptB = b.begin(isCurrent: () => true, rawRide: 'fixture-order');
      clockA += 150;
      attemptA.event(RideEvent.rendered);
      expect(events(b).single['mono_us'], 20);
      clockB += 400;
      attemptB.event(RideEvent.rendered);
      expect(
        a.durationMicros(
          attemptA.operation,
          RideEvent.action,
          RideEvent.rendered,
        ),
        150,
      );
      expect(
        b.durationMicros(
          attemptB.operation,
          RideEvent.action,
          RideEvent.rendered,
        ),
        400,
      );
      for (final recorder in [a, b]) {
        expect(
          jsonDecode(recorder.exportJson())['clock_alignment'],
          'unverified',
        );
      }
      expect(jsonDecode(a.exportJson())['wall_anchor_mono_us'], 9000000);
      expect(jsonDecode(b.exportJson())['wall_anchor_mono_us'], 20);
      // Matching ride labels do not align either monotonic origin.
      expect(events(a).first['ride'], events(b).first['ride']);
    },
  );

  test(
    'another ride response cannot supply confirmation/version for requested ride',
    () async {
      final r = RideDiagnostics(enabled: true);
      final response = {
        'success': true,
        'order': {
          'id': 'OTHER-PRIVATE',
          'order_status': 'completed',
          'updated_at': '2026-10-14T10:00:00Z',
        },
      };
      final result = await r
          .begin(
            isCurrent: () => true,
            rawRide: 'REQUESTED-PRIVATE',
            endpoint: RideEndpoint.status,
          )
          .observe(() async => response, evidence: (v) => v);
      expect(identical(result, response), isTrue);
      expect(events(r).last['event'], 'evidenceMismatch');
      expect(
        events(r).any(
          (e) =>
              e['event'] == 'confirmed' ||
              e.containsKey('server_version_candidate'),
        ),
        isFalse,
      );
      expect(r.exportJson(), isNot(contains('PRIVATE')));
    },
  );

  test(
    'pending observer metadata bounded without suppressing requests',
    () async {
      final r = RideDiagnostics(enabled: true);
      var calls = 0;
      final pending = List.generate(65, (_) => Completer<int>());
      final results = <Future<int>>[];
      for (final done in pending) {
        results.add(
          r.begin(isCurrent: () => true).observe(() {
            calls++;
            return done.future;
          }),
        );
      }
      expect(calls, 65);
      expect(jsonDecode(r.exportJson())['client_observed_waits'], 64);
      expect(
        events(r).where((e) => e['event'] == 'observationSkipped').length,
        1,
      );
      for (final done in pending) {
        done.complete(42);
      }
      expect(await Future.wait(results), List.filled(65, 42));
      expect(jsonDecode(r.exportJson())['client_observed_waits'], 0);
    },
  );

  test(
    'approved same-run key correlates phones without exporting the key or identity',
    () {
      final key = List<int>.filled(
        32,
        7,
      ); // Synthetic test key, not a credential.
      final a = RideDiagnostics(enabled: true, pseudonymKey: key);
      final b = RideDiagnostics(enabled: true, pseudonymKey: key);
      key[0] = 1; // Caller mutation cannot change the captured namespace.
      expect(a.pseudonym('PRIVATE-ORDER'), b.pseudonym('PRIVATE-ORDER'));
      a.begin(isCurrent: () => true, rawRide: 'PRIVATE-ORDER');
      expect(a.exportJson(), isNot(contains('PRIVATE-ORDER')));
      expect(a.exportJson(), isNot(contains('pseudonymKey')));
      expect(() => RideDiagnostics(pseudonymKey: [1]), throwsArgumentError);
    },
  );

  test(
    'partner receipt keeps duplicate deliveries but rejects retired account callbacks',
    () async {
      final r = RideDiagnostics(enabled: true);
      String? current = 'A';
      final stream = StreamController<String?>.broadcast(sync: true);
      final owner = RideDiagnosticOwner(
        recorder: r,
        isAlive: () => true,
        currentIdentity: () => current,
        identities: stream.stream,
      );
      owner.receipt('PRIVATE-ORDER', endpoint: RideEndpoint.assignmentFeed);
      owner.receipt('PRIVATE-ORDER', endpoint: RideEndpoint.assignmentFeed);
      expect(events(r).length, 2);
      expect(events(r)[0]['ride'], events(r)[1]['ride']);
      expect(events(r)[0]['endpoint'], 'assignmentFeed');
      current = 'B';
      stream.add(current);
      owner.receipt('PRIVATE-ORDER', endpoint: RideEndpoint.assignmentFeed);
      expect(events(r).length, 2);
      expect(r.exportJson(), isNot(contains('PRIVATE-ORDER')));
      owner.dispose();
      await stream.close();
    },
  );

  test('capacity bounds and equivalent server instants remain explicit', () {
    expect(() => RideDiagnostics(capacity: 0), throwsArgumentError);
    expect(() => RideDiagnostics(capacity: 8193), throwsArgumentError);
    final r = RideDiagnostics(enabled: true);
    final a = r.begin(isCurrent: () => true, action: false);
    a.event(RideEvent.realtimeReceipt, version: '2026-10-14T10:00:00Z');
    a.event(RideEvent.realtimeReceipt, version: '2026-10-14T15:30:00+05:30');
    final rows = events(r);
    expect(
      rows[0]['server_version_candidate'],
      rows[1]['server_version_candidate'],
    );
    expect(rows[0]['event'], 'realtimeReceipt');
    expect(
      rows[1]['event'],
      'realtimeReceipt',
    ); // Duplicate evidence is not hidden.
  });

  test(
    'overlapping attempts retain their own pairing when responses reverse',
    () async {
      var clock = 0;
      final r = RideDiagnostics(enabled: true, monotonicMicros: () => clock);
      final action = r.begin(isCurrent: () => true);
      final a = Completer<int>(), b = Completer<int>();
      final first = action.observe(() => a.future);
      clock = 10;
      final second = action.observe(() => b.future);
      clock = 20;
      b.complete(2);
      await second;
      clock = 40;
      a.complete(1);
      await first;
      final starts = events(
        r,
      ).where((e) => e['event'] == 'requestStart').toList();
      expect(
        r.durationMicros(
          action.operation,
          RideEvent.requestStart,
          RideEvent.response,
          attempt: starts[0]['attempt'],
        ),
        40,
      );
      expect(
        r.durationMicros(
          action.operation,
          RideEvent.requestStart,
          RideEvent.response,
          attempt: starts[1]['attempt'],
        ),
        10,
      );
    },
  );

  test(
    'actual owner unwraps HTTP response and excludes raw SDK error details',
    () async {
      final r = RideDiagnostics(enabled: true);
      final stream = StreamController<String?>.broadcast();
      final owner = RideDiagnosticOwner(
        recorder: r,
        isAlive: () => true,
        currentIdentity: () => 'A',
        identities: stream.stream,
      );
      await owner.api(
        RideEndpoint.acceptance,
        'ride',
        () async => FunctionResponse(
          status: 200,
          data: {
            'success': true,
            'order': {'id': 'ride', 'order_status': 'accepted'},
          },
        ),
      );
      const error = FunctionException(
        status: 403,
        details: {'token': 'SECRET'},
      );
      await expectLater(
        owner.api(
          RideEndpoint.status,
          'ride',
          () => Future<FunctionResponse>.error(error),
        ),
        throwsA(same(error)),
      );
      expect(
        events(r).where((e) => e['event'] == 'response').single['http_status'],
        200,
      );
      expect(events(r).last['http_status'], 403);
      expect(r.exportJson(), isNot(contains('SECRET')));
      owner.dispose();
      await stream.close();
    },
  );

  test(
    'RPC acknowledgement without version is not a commit-time or status assertion',
    () async {
      final r = RideDiagnostics(enabled: true);
      final a = r.begin(
        isCurrent: () => true,
        endpoint: RideEndpoint.intercityCompletion,
        status: RideStatus.delivered,
      );
      await a.observe(
        () async => {'success': true, 'order_id': 'SECRET'},
        evidence: (v) => v,
      );
      final confirmed = events(r).last;
      expect(confirmed['event'], 'confirmed');
      expect(confirmed['requested_status'], 'delivered');
      expect(confirmed.containsKey('observed_status'), isFalse);
      expect(confirmed.containsKey('server_version_candidate'), isFalse);
      expect(r.exportJson(), isNot(contains('SECRET')));
    },
  );

  test(
    'malformed booking success cannot establish a confirmed booking',
    () async {
      final r = RideDiagnostics(enabled: true);
      await r
          .begin(isCurrent: () => true, endpoint: RideEndpoint.booking)
          .observe(() async => {'success': true}, evidence: (v) => v);
      expect(events(r).last['event'], 'response');
    },
  );

  test('read response is not relabeled a mutation confirmation', () async {
    final r = RideDiagnostics(enabled: true);
    await r
        .begin(isCurrent: () => true, endpoint: RideEndpoint.liveStatus)
        .observe(() async => {'success': true}, evidence: (v) => v);
    expect(events(r).last['event'], 'response');
  });

  test(
    'counter snapshots are fixed numeric fields and disabled counting is inert',
    () {
      final r = RideDiagnostics(enabled: true);
      r.count(RideCounter.gpsCallbacks);
      r.count(RideCounter.gpsCallbacks);
      r.count(RideCounter.locationWriteStarts);
      r.begin(isCurrent: () => true);
      expect(events(r).single['counter_snapshot'], {
        'gpsCallbacks': 2,
        'locationWriteStarts': 1,
      });
      final disabled = RideDiagnostics();
      disabled.count(RideCounter.gpsCallbacks);
      expect(jsonDecode(disabled.exportJson())['counters'], isEmpty);
    },
  );

  test(
    'local auth listener cleanup happens once; same-account refresh is compatible',
    () async {
      var cancels = 0;
      final r = RideDiagnostics(enabled: true);
      final stream = StreamController<String?>.broadcast(
        sync: true,
        onCancel: () => cancels++,
      );
      final owner = RideDiagnosticOwner(
        recorder: r,
        isAlive: () => true,
        currentIdentity: () => 'A',
        identities: stream.stream,
      );
      final done = Completer<Map>();
      final pending = owner.api(
        RideEndpoint.acceptance,
        'ride',
        () => done.future,
      );
      stream.add('A');
      done.complete({'success': true});
      await pending;
      expect(events(r).last['event'], 'confirmed');
      owner.dispose();
      owner.dispose();
      await stream.close();
      expect(cancels, 1);
    },
  );

  test(
    'default recorder disabled; enabled observer issues exactly the same request',
    () async {
      expect(RideDiagnostics.instance.enabled, isFalse);
      for (final enabled in [false, true]) {
        final r = RideDiagnostics(enabled: enabled);
        var calls = 0;
        final response = {
          'success': true,
          'order': {'id': 'private-ride'},
        };
        final a = r.begin(isCurrent: () => true, rawRide: 'private-ride');
        final result = await a.observe(() async {
          calls++;
          return response;
        }, evidence: (v) => v);
        expect(calls, 1);
        expect(identical(response, result), isTrue);
        expect(events(r).isEmpty, !enabled);
      }
    },
  );

  test(
    'monotonic timestamp pairing; server version is separate ordering evidence',
    () async {
      var now = 10;
      final r = RideDiagnostics(enabled: true, monotonicMicros: () => now);
      final a = r.begin(
        isCurrent: () => true,
        rawRide: 'ride',
        endpoint: RideEndpoint.status,
      );
      final done = Completer<Map<String, dynamic>>();
      final pending = a.observe(() => done.future, evidence: (v) => v);
      now = 5010;
      done.complete({
        'success': true,
        'order': {'id': 'ride', 'updated_at': '2026-10-14T10:00:00Z'},
      });
      await pending;
      expect(
        r.durationMicros(
          a.operation,
          RideEvent.requestStart,
          RideEvent.response,
        ),
        5000,
      );
      expect(
        events(r)
            .where((e) => e['event'] == 'confirmed')
            .single['server_version_candidate'],
        '2026-10-14T10:00:00.000Z',
      );
      expect(events(r).any((e) => e.containsKey('commit_time')), isFalse);
    },
  );

  test(
    'retry retains correlation and operation but distinct attempt IDs',
    () async {
      final r = RideDiagnostics(enabled: true);
      final a = r.begin(
        isCurrent: () => true,
        rawCorrelation: 'private-idempotency',
      );
      await expectLater(
        a.observe(() => Future<void>.error(TimeoutException('SECRET'))),
        throwsA(isA<TimeoutException>()),
      );
      await a.observe(
        () async => {
          'success': true,
          'order': {'id': 'ride'},
        },
        evidence: (v) => v,
      );
      final rows = events(r);
      expect(rows.where((e) => e['event'] == 'action').length, 1);
      expect(
        rows
            .where((e) => e['event'] == 'requestStart')
            .map((e) => e['attempt'])
            .toSet()
            .length,
        2,
      );
      expect(rows.map((e) => e['operation']).toSet(), {a.operation});
      expect(rows.map((e) => e['correlation']).toSet().length, 1);
      expect(
        r.durationMicros(
          a.operation,
          RideEvent.requestStart,
          RideEvent.response,
        ),
        isNull,
      );
      expect(r.exportJson(), isNot(contains('private-idempotency')));
    },
  );

  test('missing evidence and duplicate endpoints are not interpolated', () {
    final r = RideDiagnostics(enabled: true);
    final a = r.begin(isCurrent: () => true);
    expect(
      r.durationMicros(a.operation, RideEvent.action, RideEvent.rendered),
      isNull,
    );
    a.event(RideEvent.realtimeReceipt);
    a.event(RideEvent.realtimeReceipt);
    a.event(RideEvent.applied);
    expect(
      r.durationMicros(
        a.operation,
        RideEvent.realtimeReceipt,
        RideEvent.applied,
      ),
      isNull,
    );
  });

  test(
    'unknown thrown objects and timeout outcomes never imply server failure',
    () async {
      final r = RideDiagnostics(enabled: true);
      final secret = {
        'token': 'PRIVATE',
        'phone': 'PRIVATE',
        'location': 'PRIVATE',
      };
      await expectLater(
        r
            .begin(isCurrent: () => true)
            .observe(() => Future<void>.error(secret)),
        throwsA(same(secret)),
      );
      final row = events(r).last;
      expect(row['event'], 'exceptionUnknown');
      expect(r.exportJson(), isNot(contains('PRIVATE')));
      expect(
        events(
          r,
        ).any((e) => e['event'] == 'confirmed' || e['event'] == 'rejected'),
        isFalse,
      );
    },
  );

  test(
    'strict allowlist drops bodies, identities, payments and invalid metadata',
    () async {
      final r = RideDiagnostics(enabled: true);
      final a = r.begin(
        isCurrent: () => true,
        rawRide: 'SECRET-ID',
        rawCorrelation: 'SECRET-REQUEST',
      );
      await a.observe(
        () async => {
          'success': true,
          'access_token': 'SECRET-TOKEN',
          'phone': 'SECRET-PHONE',
          'payment': 'SECRET-PAYMENT',
          'latitude': 'SECRET-LOCATION',
          'order': {'id': 'SECRET-ID', 'updated_at': '2026-02-30T10:00:00Z'},
        },
        evidence: (v) => v,
      );
      a.event(RideEvent.realtimeReceipt, version: '2026-10-14T10:00:00');
      a.event(RideEvent.applied, version: 'SECRET-STACK');
      expect(r.exportJson(), isNot(contains('SECRET')));
      const allowed = {
        'event',
        'sequence',
        'mono_us',
        'operation',
        'attempt',
        'ride',
        'correlation',
        'endpoint',
        'status',
        'server_version_candidate',
        'http_status',
        'observed_status',
        'requested_status',
        'surface',
        'counter_snapshot',
      };
      for (final row in events(r)) {
        expect(row.keys.toSet().difference(allowed), isEmpty);
      }
      expect(
        events(r).any((e) => e.containsKey('server_version_candidate')),
        isFalse,
      );
    },
  );

  test('evidence inspection failure cannot change request outcome', () async {
    final r = RideDiagnostics(enabled: true);
    final a = r.begin(isCurrent: () => true);
    expect(
      await a.observe(
        () async => 42,
        evidence: (_) => throw StateError('SECRET'),
      ),
      42,
    );
    expect(events(r).last['event'], 'response');
  });

  test('throwing instrumentation guard cannot alter the request', () async {
    final r = RideDiagnostics(enabled: true);
    final a = r.begin(isCurrent: () => throw StateError('SECRET'));
    expect(await a.observe(() async => 42), 42);
    expect(events(r), isEmpty);
  });

  test(
    'bounded eviction retains no raw-ID mapping; lost pair is unavailable',
    () {
      final r = RideDiagnostics(enabled: true, capacity: 3);
      final a = r.begin(isCurrent: () => true, rawRide: 'SECRET');
      for (var i = 0; i < 10; i++) {
        a.event(RideEvent.realtimeReceipt);
      }
      expect(events(r).length, 3);
      expect(jsonDecode(r.exportJson())['dropped'], 8);
      expect(
        r.durationMicros(
          a.operation,
          RideEvent.action,
          RideEvent.realtimeReceipt,
        ),
        isNull,
      );
    },
  );

  test('pseudonyms stable only within session; plan identity separate', () {
    final a = RideDiagnostics(enabled: true),
        b = RideDiagnostics(enabled: true);
    expect(a.pseudonym('ride'), a.pseudonym('ride'));
    expect(a.pseudonym('ride'), isNot(b.pseudonym('ride')));
    expect(a.pseudonym('ride', plan: true), isNot(a.pseudonym('ride')));
    expect(a.pseudonym(null), isNull);
  });

  for (final replacement in ['B', 'A-back', 'dispose', 'logout']) {
    test(
      'late result after $replacement does not publish diagnostic evidence',
      () async {
        final r = RideDiagnostics(enabled: true);
        final identities = StreamController<String?>.broadcast(sync: true);
        String? current = 'A';
        var alive = true;
        final owner = RideDiagnosticOwner(
          recorder: r,
          isAlive: () => alive,
          currentIdentity: () => current,
          identities: identities.stream,
        );
        final done = Completer<Map<String, dynamic>>();
        final result = owner.api(
          RideEndpoint.acceptance,
          'ride',
          () => done.future,
        );
        final before = events(r).length;
        if (replacement == 'dispose') {
          alive = false;
          owner.dispose();
        } else {
          current = replacement == 'logout' ? null : 'B';
          identities.add(current);
          if (replacement == 'A-back') {
            current = 'A';
            identities.add(current);
          }
        }
        done.complete({'success': true});
        expect(await result, {
          'success': true,
        }); // Lifecycle behavior is not changed.
        expect(events(r).length, before);
        owner.dispose();
        await identities.close();
      },
    );
  }

  test(
    'disabled owner creates no auth listener and retains original future',
    () async {
      var subscriptions = 0;
      final identities = StreamController<String?>.broadcast(
        onListen: () => subscriptions++,
      );
      final owner = RideDiagnosticOwner(
        recorder: RideDiagnostics(),
        isAlive: () => true,
        currentIdentity: () => 'A',
        identities: identities.stream,
      );
      final done = Completer<int>();
      final result = owner.api(RideEndpoint.status, 'ride', () => done.future);
      expect(identical(result, done.future), isTrue);
      expect(subscriptions, 0);
      done.complete(7);
      expect(await result, 7);
      owner.dispose();
      await identities.close();
    },
  );

  testWidgets(
    'actual frame hook records after frame and deduplicates rebuilt status',
    (tester) async {
      final r = RideDiagnostics(enabled: true);
      final identities = StreamController<String?>.broadcast(sync: true);
      final owner = RideDiagnosticOwner(
        recorder: r,
        isAlive: () => true,
        currentIdentity: () => 'A',
        identities: identities.stream,
      );
      Widget view() => MaterialApp(
        home: Builder(
          builder: (context) {
            owner.frame(context, 'ride', 'accepted', () => true);
            return const Text('Accepted');
          },
        ),
      );
      await tester.pumpWidget(view());
      expect(find.text('Accepted'), findsOneWidget);
      expect(events(r).where((e) => e['event'] == 'rendered').length, 1);
      await tester.pumpWidget(view());
      expect(events(r).where((e) => e['event'] == 'rendered').length, 1);
      owner.dispose();
      await identities.close();
    },
  );

  testWidgets(
    'disposal or changed status before frame suppresses pending render marker',
    (tester) async {
      for (final disposed in [false, true]) {
        final r = RideDiagnostics(enabled: true);
        final identities = StreamController<String?>.broadcast();
        final owner = RideDiagnosticOwner(
          recorder: r,
          isAlive: () => true,
          currentIdentity: () => 'A',
          identities: identities.stream,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                owner.frame(context, 'ride', 'accepted', () => false);
                if (disposed) owner.dispose();
                return const Text('Replaced');
              },
            ),
          ),
        );
        expect(events(r), isEmpty);
        owner.dispose();
        await identities.close();
      }
    },
  );
  testWidgets(
    'pending frames are bounded, deduplicated and retain latest status',
    (tester) async {
      final recorder = RideDiagnostics(enabled: true);
      final identities = StreamController<String?>.broadcast(sync: true);
      final owner = RideDiagnosticOwner(
        recorder: recorder,
        isAlive: () => true,
        currentIdentity: () => 'A',
        identities: identities.stream,
      );
      late BuildContext frameContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              frameContext = context;
              return const Text('Status');
            },
          ),
        ),
      );
      await tester
          .pumpAndSettle(); // Finish initial route construction before capture.
      frameContext = tester.element(find.text('Status'));
      var checks = 0;
      var status = 'accepted';
      for (var i = 0; i < 2000; i++) {
        owner.frame(frameContext, 'ride', 'accepted', () {
          checks++;
          return status == 'accepted';
        });
      }
      expect(owner.pendingFrameObservations, 1);
      expect(owner.hasScheduledFrameObservation, isTrue);
      status = 'completed';
      tester.binding.scheduleFrame();
      await tester.pump();
      expect(checks, 1);
      expect(
        events(recorder),
        isEmpty,
      ); // Changed status cannot record accepted.
      for (var i = 0; i < 2000; i++) {
        owner.frame(frameContext, 'ride-$i', 'accepted', () {
          checks++;
          return true;
        });
      }
      expect(owner.pendingFrameObservations, 64);
      owner.frame(
        frameContext,
        'ride-1999',
        'completed',
        () => status == 'completed',
      );
      expect(owner.pendingFrameObservations, 64);
      tester.binding.scheduleFrame();
      await tester.pump();
      final rendered = events(
        recorder,
      ).where((e) => e['event'] == 'rendered').toList();
      expect(rendered.length, 64);
      expect(rendered.last['status'], 'completed');
      expect(
        checks,
        64,
      ); // One stale check plus 63 retained accepted observations.
      expect(owner.pendingFrameObservations, 0);
      expect(owner.hasScheduledFrameObservation, isFalse);
      owner.dispose();
      await identities.close();
    },
  );

  for (final retire in ['dispose', 'account']) {
    testWidgets('pending frame burst is cleared on $retire', (tester) async {
      final recorder = RideDiagnostics(enabled: true);
      final identities = StreamController<String?>.broadcast(sync: true);
      var identity = 'A';
      final owner = RideDiagnosticOwner(
        recorder: recorder,
        isAlive: () => true,
        currentIdentity: () => identity,
        identities: identities.stream,
      );
      late BuildContext frameContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              frameContext = context;
              return const Text('Status');
            },
          ),
        ),
      );
      var checks = 0;
      for (var i = 0; i < 2000; i++) {
        owner.frame(frameContext, 'ride-$i', 'accepted', () {
          checks++;
          return true;
        });
      }
      expect(owner.pendingFrameObservations, 64);
      if (retire == 'dispose') {
        owner.dispose();
      } else {
        identity = 'B';
        identities.add(identity);
      }
      expect(owner.pendingFrameObservations, 0);
      owner.frame(frameContext, 'new-ride', 'accepted', () => true);
      expect(owner.pendingFrameObservations, 0);
      tester.binding.scheduleFrame();
      await tester.pump();
      expect(checks, 0);
      expect(events(recorder), isEmpty);
      expect(owner.hasScheduledFrameObservation, isFalse);
      owner.dispose();
      await identities.close();
    });
  }
  testWidgets('route replacement rejects the old route pending observation', (
    tester,
  ) async {
    final recorder = RideDiagnostics(enabled: true);
    final identities = StreamController<String?>.broadcast(sync: true);
    final owner = RideDiagnosticOwner(
      recorder: recorder,
      isAlive: () => true,
      currentIdentity: () => 'A',
      identities: identities.stream,
    );
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Text('Old route')),
    );
    await tester.pumpAndSettle();
    final oldContext = tester.element(find.text('Old route'));
    final oldRoute = ModalRoute.of(oldContext)!;
    expect(oldContext.mounted, isTrue);
    expect(oldRoute.isCurrent, isTrue);
    var statusChecks = 0;
    owner.frame(oldContext, 'ride', 'accepted', () {
      statusChecks++;
      return true; // Status and identity stay valid: only route ownership changes.
    });
    expect(owner.pendingFrameObservations, 1);
    navigator.currentState!.pushReplacement<void, void>(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(seconds: 1),
        pageBuilder: (context, animation, secondaryAnimation) =>
            const Text('Replacement route'),
      ),
    );
    expect(oldRoute.isCurrent, isFalse);
    await tester
        .pump(); // First replacement frame; old route has not been disposed.
    expect(oldContext.mounted, isTrue);
    expect(statusChecks, 1); // Proves execution reached the route check.
    expect(events(recorder), isEmpty);
    expect(owner.pendingFrameObservations, 0);
    expect(owner.hasScheduledFrameObservation, isFalse);
    await tester.pumpAndSettle();
    expect(find.text('Replacement route'), findsOneWidget);
    expect(oldContext.mounted, isFalse);
    owner.dispose();
    await identities.close();
  });
}
