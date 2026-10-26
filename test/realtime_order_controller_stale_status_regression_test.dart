import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/models/transport_order.dart';

String _read(String path) => File(path).readAsStringSync();

Map<String, dynamic> _fullOrder(String orderType) => {
  'id': 'test-order',
  'order_code': 'TEST',
  'user_id': 'test-user',
  'order_type': orderType,
  'order_status': 'completed',
  'distance_meters': 1000,
  'distance_km': 1,
  'pickup_address': 'Pickup',
  'pickup_lat': 0,
  'pickup_lng': 0,
  'destination_address': 'Destination',
  'destination_lat': 0,
  'destination_lng': 0,
  'actual_fare': 100,
  'current_fare': 100,
  'payment_mode': 'cash',
  'payment_status': 'paid',
  'updated_at': '2026-10-11T10:00:00Z',
};

void main() {
  final source = _read(
    'lib/core/services/realtime/realtime_order_controller.dart',
  );

  group('order Realtime health is independent from rider streams', () {
    test('only the order callback refreshes order-channel health', () {
      expect('_lastOrderRealtimeDeliveryAt ='.allMatches(source).length, 1);

      final riderSubscriptions = source.substring(
        source.indexOf('void _subscribeRider('),
      );
      expect(
        riderSubscriptions.contains('_lastOrderRealtimeDeliveryAt ='),
        isFalse,
        reason: 'GPS/profile events must not suppress fallback order polling',
      );
    });
  });

  group('safe live-status reconciliation', () {
    test(
      'partial live order is only a mismatch signal and is never applied to the model',
      () {
        expect(source.contains("final liveOrder = data['order'];"), isTrue);
        expect(
          source.contains(
            "liveOrder['order_status'] != orderNotifier.value?.orderStatus",
          ),
          isTrue,
        );
        expect(
          source.contains('await _fetchOrder(recordPollingResult: false)'),
          isTrue,
        );
        expect(source.contains('_applyOrderData(liveOrder'), isFalse);
        expect(source.contains('TransportOrder.fromJson(liveOrder'), isFalse);
      },
    );

    test(
      'older full rows are rejected using updated_at rather than status ranking',
      () {
        expect(source.contains("data['updated_at']"), isTrue);
        expect(
          source.contains('incomingUpdatedAt.isBefore(lastApplied)'),
          isTrue,
        );
        expect(
          source.contains('currentOrder != null && incomingUpdatedAt == null'),
          isTrue,
        );
        expect(source.contains('statusRank'), isFalse);
      },
    );
  });

  group('failure and lifecycle behavior', () {
    test(
      'all live-request failure categories record failure and never success',
      () {
        for (final category in [
          'null_payload',
          'invalid_payload',
          'remote_failure',
          'timeout',
          'request_exception',
        ]) {
          expect(source.contains('category=$category'), isTrue);
        }
        expect(
          RegExp(
            r"data\['success'\] != true[\s\S]{0,240}_pollBackoff\.recordFailure\(\)",
          ).hasMatch(source),
          isTrue,
        );
      },
    );

    test('refreshes remain coalesced and disposal blocks late writes', () {
      expect(source.contains('if (_refreshInFlight)'), isTrue);
      expect(source.contains('_refreshQueued = true'), isTrue);
      expect(
        source.contains(
          'if (_isDisposed) return _LiveStateFetchOutcome.disposed',
        ),
        isTrue,
      );
      expect(source.contains('_pollingTimer?.cancel()'), isTrue);
    });
  });

  group('initial live-status refresh coalescing', () {
    test('startup enters the shared guard without repeating the full order read', () {
      final startBody = source.substring(
        source.indexOf('Future<void> start() async {'),
        source.indexOf('Duration _refreshInterval'),
      );

      expect('await fetchOrder();'.allMatches(startBody).length, 1);
      expect(
        startBody.contains(
          'unawaited(_refreshOrderAndLiveState(includeOrderFetch: false));',
        ),
        isTrue,
      );
      expect(startBody.contains('fetchLiveOrderState();'), isFalse);
    });

    test('timer and Realtime overlap are coalesced without concurrent work', () {
      expect(source.contains('if (_refreshInFlight)'), isTrue);
      expect(source.contains('_refreshQueued = true;'), isTrue);
      expect(
        source.contains(
          '_refreshQueuedIncludeOrderFetch || includeOrderFetch',
        ),
        isTrue,
        reason: 'a timer request for a full row must survive coalescing',
      );
      expect(
        source.contains('includeOrderFetch: queuedIncludeOrderFetch'),
        isTrue,
      );
    });

    test('live-only overlap does not manufacture another full order fetch', () {
      expect(source.contains('bool _refreshQueuedIncludeOrderFetch = false;'), isTrue);
      expect(
        source.contains(
          'final queuedIncludeOrderFetch = _refreshQueuedIncludeOrderFetch;',
        ),
        isTrue,
      );
      expect(
        source.contains('_refreshQueuedIncludeOrderFetch = false;'),
        isTrue,
      );
    });

    test('terminal and disposal guards still precede refresh network work', () {
      final refreshBody = source.substring(
        source.indexOf('Future<void> _refreshOrderAndLiveState'),
        source.indexOf('bool _applyOrderData'),
      );
      expect(refreshBody.indexOf('if (_isDisposed) return;'), greaterThanOrEqualTo(0));
      expect(refreshBody.indexOf('currentOrder.isCompleted'), greaterThanOrEqualTo(0));
      expect(
        refreshBody.indexOf("final liveResult = await _fetchLiveOrderState("),
        greaterThan(refreshBody.indexOf('currentOrder.isCompleted')),
      );
    });
  });

  group('full-order model compatibility', () {
    for (final type in [
      'ride',
      'intercity_ride',
      'local_parcel',
      'intercity_parcel',
    ]) {
      test('$type remains compatible with full-row reconciliation', () {
        final order = TransportOrder.fromJson(_fullOrder(type));
        expect(order.orderType, type);
        expect(order.orderStatus, 'completed');
        expect(order.isCompleted, isTrue);
      });
    }
  });
}
