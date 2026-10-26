import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/local_rides/booking/nearby_rider_refresh.dart';

void main() {
  test('2000 overlapping local triggers remain one cosmetic request', () async {
    final refresh = NearbyRiderRefresh();
    final response = Completer<int>();
    var requests = 0;
    var applications = 0;
    final triggers = List.generate(2000, (_) => refresh.run<int>(
      fetch: () { requests++; return response.future; },
      isCurrent: () => true,
      apply: (_) async { applications++; },
    ));
    expect(requests, 1);
    response.complete(1);
    await Future.wait(triggers);
    expect(applications, 1);
  });
  test('timer and route-ready overlap issues one request, then permits the next tick', () async {
    final refresh = NearbyRiderRefresh();
    final response = Completer<int>();
    var requests = 0;
    final applied = <int>[];
    Future<void> run() => refresh.run(
      fetch: () { requests++; return response.future; },
      isCurrent: () => true,
      apply: (int value) async { applied.add(value); },
    );
    final first = run();
    await Future.wait([run(), run()]);
    expect(requests, 1);
    response.complete(1);
    await first;
    await run();
    expect(requests, 2);
    expect(applied, [1, 1]);
  });
  test('request and application failures release ownership and propagate', () async {
    final refresh = NearbyRiderRefresh();
    await expectLater(refresh.run<int>(
      fetch: () async => throw StateError('synthetic'),
      isCurrent: () => true,
      apply: (_) async => fail('No failed result application'),
    ), throwsStateError);
    await expectLater(refresh.run<int>(
      fetch: () async => 1,
      isCurrent: () => true,
      apply: (_) async => throw StateError('synthetic application'),
    ), throwsStateError);
    var applied = false;
    await refresh.run<int>(fetch: () async => 2, isCurrent: () => true,
      apply: (_) async { applied = true; });
    expect(applied, isTrue);
  });
  test('cleared and reentered route rejects old data even for the same pickup', () async {
    final refresh = NearbyRiderRefresh();
    final response = Completer<int>();
    final done = refresh.run<int>(fetch: () => response.future,
      isCurrent: () => true, apply: (_) async => fail('Old route applied'));
    refresh.invalidate();
    response.complete(1);
    await done;
    var applied = false;
    await refresh.run<int>(fetch: () async => 2, isCurrent: () => true,
      apply: (_) async { applied = true; });
    expect(applied, isTrue);
  });
  test('pickup change rejects stale results without launching extra requests', () async {
    final refresh = NearbyRiderRefresh();
    var current = true;
    final response = Completer<int>();
    final done = refresh.run<int>(fetch: () => response.future,
      isCurrent: () => current, apply: (_) async => fail('Stale pickup applied'));
    current = false;
    response.complete(1);
    await done;
    await refresh.run<int>(fetch: () async => fail('Invalid request'),
      isCurrent: () => current, apply: (_) async => fail('Invalid application'));
  });
  test('disposal rejects in-flight results and all future triggers', () async {
    final refresh = NearbyRiderRefresh();
    final response = Completer<int>();
    final done = refresh.run<int>(fetch: () => response.future,
      isCurrent: () => true, apply: (_) async => fail('Disposed application'));
    refresh.dispose();
    response.complete(1);
    await done;
    await refresh.run<int>(fetch: () async => fail('Disposed fetch'),
      isCurrent: () => true, apply: (_) async => fail('Disposed application'));
  });
  test('map application remains inside the one-active refresh boundary', () async {
    final refresh = NearbyRiderRefresh();
    final applying = Completer<void>();
    final finished = Completer<void>();
    final done = refresh.run<int>(fetch: () async => 1,
      isCurrent: () => true, apply: (_) async {
        applying.complete(); await finished.future;
      });
    await applying.future;
    await refresh.run<int>(fetch: () async => fail('Overlapping map refresh'),
      isCurrent: () => true, apply: (_) async {});
    finished.complete();
    await done;
  });
  test('screen wires the tested guard and preserves the existing timer cadence', () {
    final source = File('lib/features/local_rides/booking/screens/ride_location_screen.dart').readAsStringSync();
    expect(source, contains('_nearbyRiderRefresh.run<List<Map<String, dynamic>>>'));
    expect(source, contains('_nearbyRiderRefresh.dispose();'));
    expect(source, contains('_nearbyRiderRefresh.invalidate();'));
    for (final seconds in [5, 10, 20]) {
      expect(source, contains('return const Duration(seconds: $seconds)'));
    }
  });
}
