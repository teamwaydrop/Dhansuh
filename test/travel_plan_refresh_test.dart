import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/rider/home/travel_plan_refresh.dart';

void main() {
  test('leaving and reentering the same rider scope cannot revive its pre-reset snapshot', () async {
    final h = _Harness();
    final old = h.refresh.request('A');
    h.rider = null;
    h.refresh.invalidate(); // Identity/service-mode lifecycle boundary.
    h.rider = 'A';
    final fresh = h.refresh.request('A');
    h.plans[0].complete([{'id': 'old'}]);
    await old;
    expect(h.requests, isEmpty);
    expect(h.applied, isEmpty);
    h.plans[1].complete([]);
    await fresh;
    expect(h.applied.length, 1);
  });
  test('overlapping callers retain one trailing batch and await their assigned attempt', () async {
    final h = _Harness();
    final first = h.refresh.request('A');
    var trailingDone = false;
    final trailing = h.refresh.request('A').then((_) => trailingDone = true);
    final third = h.refresh.request('A');
    expect(h.plans.length, 1);
    h.plans[0].complete([{'id': 'P', 'status': 'fully_booked'}]);
    await Future<void>.value();
    expect(h.applied, isEmpty); // Never publish partial plans before counts.
    h.requests[0].complete([
      {'route_id': 'P', 'status': 'confirmed'},
      {'route_id': 'P', 'status': 'paid'},
      {'route_id': 'P', 'status': 'in_progress'},
      {'route_id': 'P', 'status': 'request_sent'},
      {'route_id': 'P', 'status': 'discussion_started'},
      {'route_id': 'P', 'status': 'fare_agreed'},
      {'route_id': 'P', 'status': 'cancelled'},
    ]);
    await first;
    expect(h.applied.single.acceptedCounts, {'P': 3});
    expect(h.applied.single.pendingCounts, {'P': 3});
    expect(trailingDone, isFalse);
    expect(h.plans.length, 2);
    h.plans[1].complete([]);
    await Future.wait([trailing, third]);
    expect(h.applied.last.plans, isEmpty);
    expect(h.requests.length, 1); // Empty plans require no second query.
  });
  test('Realtime invalidation during plans suppresses obsolete count query and retains fresh demand', () async {
    final h = _Harness();
    final first = h.refresh.request('A');
    h.refresh.invalidate();
    final second = h.refresh.request('A');
    h.plans[0].complete([{'id': 'old'}]);
    await first;
    expect(h.requests, isEmpty);
    expect(h.applied, isEmpty);
    h.plans[1].complete([]);
    await second;
    expect(h.applied.single.plans, isEmpty);
  });
  test('invalidation during counts rejects the entire stale snapshot', () async {
    final h = _Harness();
    final first = h.refresh.request('A');
    h.plans[0].complete([{'id': 'P'}]);
    await Future<void>.value();
    h.refresh.invalidate();
    final fresh = h.refresh.request('A');
    h.requests[0].complete([{'route_id': 'P', 'status': 'paid'}]);
    await first;
    expect(h.applied, isEmpty);
    h.plans[1].complete([]);
    await fresh;
    expect(h.applied.length, 1);
  });
  for (final stage in ['plans', 'counts']) {
    test('$stage failure preserves previous snapshot and permits a future request', () async {
      final h = _Harness();
      final first = h.refresh.request('A');
      if (stage == 'plans') {
        h.plans[0].completeError(StateError('synthetic'));
      } else {
        h.plans[0].complete([{'id': 'P'}]);
        await Future<void>.value();
        h.requests[0].completeError(StateError('synthetic'));
      }
      await first;
      expect(h.applied, isEmpty);
      expect(h.failures, 1);
      final next = h.refresh.request('A');
      h.plans[1].complete([]);
      await next;
      expect(h.applied.length, 1);
    });
  }
  test('identity change retires old data and gives the new rider a trailing batch', () async {
    final h = _Harness();
    final a = h.refresh.request('A');
    h.rider = 'B';
    h.refresh.invalidate();
    final b = h.refresh.request('B');
    h.plans[0].complete([{'id': 'A-plan'}]);
    await a;
    expect(h.requests, isEmpty);
    h.plans[1].complete([]);
    await b;
    expect(h.fetchIdentities, ['A', 'B']);
    expect(h.applied.single.plans, isEmpty);
  });
  test('disposal suppresses second-stage, queued and future work', () async {
    final h = _Harness();
    final first = h.refresh.request('A');
    final queued = h.refresh.request('A');
    h.refresh.dispose();
    h.plans[0].complete([{'id': 'P'}]);
    await Future.wait([first, queued, h.refresh.request('A')]);
    expect(h.plans.length, 1);
    expect(h.requests, isEmpty);
    expect(h.applied, isEmpty);
  });
  test('a trigger immediately before completion is retained', () async {
    final h = _Harness();
    final first = h.refresh.request('A');
    h.plans[0].complete([]);
    final nearCompletion = h.refresh.request('A');
    await first;
    expect(h.plans.length, 2);
    h.plans[1].complete([]);
    await nearCompletion;
    expect(h.applied.length, 2);
  });
}

class _Harness {
  _Harness() {
    refresh = TravelPlanRefresh(
      currentRiderId: () => rider,
      fetchPlans: (id) {
        fetchIdentities.add(id);
        final response = Completer<List<Map<String, dynamic>>>();
        plans.add(response);
        return response.future;
      },
      fetchRequests: (ids) {
        final response = Completer<List<Map<String, dynamic>>>();
        requests.add(response);
        return response.future;
      },
      apply: applied.add,
      onFailure: () { failures++; },
    );
  }
  String? rider = 'A';
  int failures = 0;
  late final TravelPlanRefresh refresh;
  final fetchIdentities = <String>[];
  final plans = <Completer<List<Map<String, dynamic>>>>[];
  final requests = <Completer<List<Map<String, dynamic>>>>[];
  final applied = <TravelPlanSnapshot>[];
}
