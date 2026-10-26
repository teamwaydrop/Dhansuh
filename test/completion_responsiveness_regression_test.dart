import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final activeOrder =
      _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');
  final dispatch = _read('supabase/functions/start-dispatch/index.ts');

  group('confirmed completion UI', () {
    test('applies confirmed status before scheduling bounded intercity cleanup', () {
      final genericStart = activeOrder.indexOf('Future<bool> updateStatus(');
      final statusIndex = activeOrder.indexOf(
        "order!['order_status'] = status",
        genericStart,
      );
      final cleanupIndex = activeOrder.indexOf(
        '_scheduleTravelPlanCleanupAfterCompletion()',
        statusIndex,
      );

      expect(statusIndex, greaterThan(-1));
      expect(
        cleanupIndex,
        greaterThan(statusIndex),
      );
      final updateEnd = activeOrder.indexOf(
        'Future<bool> _reconcileAfterTimeout',
        genericStart,
      );
      expect(
        activeOrder.substring(genericStart, updateEnd).contains(
          'await _deleteMatchingTravelPlan()',
        ),
        isFalse,
      );
    });

    test('cleanup is intercity-only, bounded, and handles failure', () {
      final start = activeOrder.indexOf(
        'void _scheduleTravelPlanCleanupAfterCompletion()',
      );
      final end = activeOrder.indexOf(
        'Future<void> _finishConfirmedCompletionUi',
        start,
      );
      final body = activeOrder.substring(start, end);

      expect(body.contains("orderType != 'intercity_ride'"), isTrue);
      expect(body.contains("orderType != 'intercity_parcel'"), isTrue);
      expect(body.contains('timeout(const Duration(seconds: 5))'), isTrue);
      expect(body.contains('catchError'), isTrue);
    });

    test('pre-request location work is bounded and post-success delay is removed', () {
      expect(
        RegExp(
          r'_getCurrentLocation\(\)\.timeout\(\s*const Duration\(seconds: 7\)',
        ).hasMatch(activeOrder),
        isTrue,
      );
      expect(
        activeOrder.contains(
          'Future.delayed(const Duration(milliseconds: 800))',
        ),
        isFalse,
      );
    });

    test('all completion entry points respect failure and refresh after releasing UI', () {
      expect(
        '_finishConfirmedCompletionUi(success)'.allMatches(activeOrder).length,
        4,
      );
      expect(
        activeOrder.contains('unawaited(_finishConfirmedCompletionUi(true))'),
        isTrue,
      );
      expect(
        activeOrder.contains(
          'fetchRiderProfile().timeout(const Duration(seconds: 5))',
        ),
        isTrue,
      );
      final finishStart = activeOrder.indexOf(
        'Future<void> _finishConfirmedCompletionUi',
      );
      final finishEnd = activeOrder.indexOf(
        'Future<bool> updateStatus(',
        finishStart,
      );
      final finishBody = activeOrder.substring(finishStart, finishEnd);
      expect(
        finishBody.indexOf('setState(() => loading = false)') <
            finishBody.indexOf('_refreshCompletionPartnerData()'),
        isTrue,
      );
      expect(activeOrder.contains('showingCompletionDialog = false;'), isTrue);
    });

    test('status request prepares location and device identity concurrently', () {
      final updateStart = activeOrder.indexOf('Future<bool> updateStatus(');
      final updateEnd = activeOrder.indexOf(
        'Future<bool> _reconcileAfterTimeout',
        updateStart,
      );
      final updateBody = activeOrder.substring(updateStart, updateEnd);

      expect(updateBody.contains('Future.wait<Object?>(['), isTrue);
      expect(updateBody.contains('_getCurrentLocation().timeout('), isTrue);
      expect(updateBody.contains('DeviceInfoHelper.getDeviceId(),'), isTrue);
      expect(updateBody.contains('if (_updatingStatus) return false;'), isTrue);
    });
  });

  test('dispatch audit failure is observable but remains non-fatal', () {
    expect(
      dispatch.contains('const { error: assignmentLogError } = await supabase'),
      isTrue,
    );
    expect(dispatch.contains('assignmentLogError.code === "23505"'), isTrue);
    expect(dispatch.contains(r'category=${assignmentLogError.code'), isTrue);
    expect(
      dispatch.contains('if (assignmentLogError) {\n              continue;'),
      isFalse,
      reason: 'an audit-row failure must not undo or suppress committed assignments',
    );
  });
}
