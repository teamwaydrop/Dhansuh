import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/core/services/realtime/order_snapshot_contract.dart';
import 'package:waydrop/models/transport_order.dart';

Map<String, dynamic> _snapshot({
  String orderType = 'ride',
  String status = 'searching',
  String? riderId,
  String? vehicleType = 'bike',
}) {
  return <String, dynamic>{
    'contract_version': 2,
    'id': 'order-1',
    'updated_at': '2026-10-12T08:30:00.000Z',
    'order_code': 'WD-TEST',
    'user_id': 'user-1',
    'rider_id': riderId,
    'order_type': orderType,
    'vehicle_type': vehicleType,
    'order_status': status,
    'distance_meters': 12500,
    'distance_km': 12.5,
    'estimated_duration_min': 28,
    'actual_duration_min': null,
    'time_taken_seconds': null,
    'pickup_address': 'Sanitized pickup',
    'pickup_lat': 12.9,
    'pickup_lng': 77.5,
    'destination_address': 'Sanitized destination',
    'destination_lat': 13.0,
    'destination_lng': 77.6,
    'actual_fare': 210.5,
    'current_fare': 225.5,
    'final_fare': 205.5,
    'base_fare': 50,
    'distance_fare': 125,
    'time_fare': 20,
    'waiting_charge': 5,
    'platform_fee': 10,
    'payment_mode': 'cash',
    'payment_status': 'pending',
    'payment_id': null,
    'fare_payment_method': null,
    'fare_payment_attempted_at': null,
    'pickup_otp': '1111',
    'delivery_otp': null,
    'parcel_type': null,
    'receiver_name': null,
    'receiver_phone': null,
    'weight_category': null,
    'actual_weight_kg': null,
    'parcel_images': <String>[],
    'special_instructions': null,
    'created_at': '2026-10-12T08:00:00.000Z',
    'accepted_at': null,
    'rider_arrived_at': null,
    'picked_up_at': null,
    'rider_at_drop_at': null,
    'completed_at': null,
    'cancelled_at': null,
    'boost_amount': 15,
    'boost_percentage': 5,
    'pickup_city': null,
    'destination_city': null,
    'travel_date': null,
    'seats_requested': 1,
    'trip_started_at': null,
    'gst_percentage': 5,
    'gst_amount': 10,
    'commission_percentage': 12,
    'commission_amount': 24,
    'rider_earning': 181.5,
    'boost_company_earning': 2,
    'boost_rider_earning': 13,
  };
}

void main() {
  test('schema-null values preserve existing model semantics without replacing real values', () {
    for (final key in ['base_fare', 'distance_fare', 'time_fare', 'waiting_charge',
      'platform_fee', 'boost_amount', 'boost_percentage', 'gst_percentage', 'gst_amount',
      'commission_percentage', 'commission_amount', 'rider_earning',
      'boost_company_earning', 'boost_rider_earning', 'created_at']) {
      final candidate = _snapshot()..[key] = null;
      final validated = OrderSnapshotContract.validate(candidate, expectedOrderId: 'order-1');
      expect(validated, isNotNull, reason: key);
      expect(validated![key], isNull);
      final direct = TransportOrder.fromJson(candidate);
      final snapshot = TransportOrder.fromJson(validated);
      expect(snapshot.currentFare, direct.currentFare);
      expect(snapshot.baseFare, direct.baseFare);
      expect(snapshot.riderEarning, direct.riderEarning);
      expect(snapshot.createdAt, direct.createdAt);
      expect(OrderSnapshotContract.validate(_snapshot()..[key] = 'malformed',
        expectedOrderId: 'order-1'), isNull);
    }
  });
  test('rejects malformed maps, normalized dates, and fractional seats', () {
    expect(OrderSnapshotContract.validate({1: 'invalid'}, expectedOrderId: 'order-1'), isNull);
    for (final timestamp in [
      '2026-02-30T08:30:00Z',
      '2026-10-12T25:30:00Z',
      '2026-10-12T08:30:00+99:00',
    ]) {
      expect(OrderSnapshotContract.validate(_snapshot()..['updated_at'] = timestamp,
        expectedOrderId: 'order-1'), isNull);
    }
    expect(OrderSnapshotContract.validate(_snapshot()..['seats_requested'] = 1.5,
      expectedOrderId: 'order-1'), isNull);
    expect(OrderSnapshotContract.validate(_snapshot()..['completed_at'] = '2026-02-30T00:00:00Z',
      expectedOrderId: 'order-1'), isNull);
    expect(OrderSnapshotContract.validate(_snapshot()..['travel_date'] = '2026-10-13',
      expectedOrderId: 'order-1'), isNotNull);
    expect(OrderSnapshotContract.validate(_snapshot()..['updated_at'] = '2026-10-12T08:30:00.123456+00:00',
      expectedOrderId: 'order-1'), isNotNull);
  });
  group('OrderSnapshotContract', () {
    test('accepts complete local ride, parcel, and intercity variants', () {
      final variants = <Map<String, dynamic>>[
        _snapshot(),
        _snapshot(
          orderType: 'local_parcel',
          riderId: 'rider-1',
        )
          ..addAll({
            'parcel_type': 'documents',
            'receiver_name': 'Receiver',
            'receiver_phone': '0000000000',
            'weight_category': 'small',
            'actual_weight_kg': 1.25,
            'parcel_images': <String>['sanitized-image-path'],
            'delivery_otp': '2222',
          }),
        _snapshot(
          orderType: 'intercity_ride',
          riderId: 'rider-2',
          vehicleType: 'car',
        )
          ..addAll({
            'pickup_city': 'City A',
            'destination_city': 'City B',
            'travel_date': '2026-10-13T00:00:00+05:30',
            'trip_started_at': '2026-10-13T03:30:00Z',
            'seats_requested': 2,
          }),
        _snapshot(
          orderType: 'intercity_parcel',
          status: 'payment_pending',
          riderId: 'rider-3',
        ),
      ];

      for (final candidate in variants) {
        final validated = OrderSnapshotContract.validate(
          candidate,
          expectedOrderId: 'order-1',
        );
        expect(validated, isNotNull);
        final order = TransportOrder.fromJson(validated!);
        expect(order.id, 'order-1');
        expect(order.orderType, candidate['order_type']);
        expect(order.vehicleType, candidate['vehicle_type']);
        expect(order.currentFare, 225.5);
        expect(order.finalFare, 205.5);
        expect(order.commissionAmount, 24);
        expect(order.riderEarning, 181.5);
      }
    });

    test('accepts nullable fields only when explicitly present', () {
      final candidate = _snapshot();
      expect(
        OrderSnapshotContract.validate(
          candidate,
          expectedOrderId: 'order-1',
        ),
        isNotNull,
      );

      candidate.remove('rider_id');
      expect(
        OrderSnapshotContract.validate(
          candidate,
          expectedOrderId: 'order-1',
        ),
        isNull,
      );
    });

    test('rejects unsupported version, wrong id, and invalid timestamps', () {
      final invalid = <Map<String, dynamic>>[
        _snapshot()..['contract_version'] = 1,
        _snapshot()..['id'] = 'another-order',
        _snapshot()..['updated_at'] = '2026-10-12 08:30:00',
        _snapshot()..['updated_at'] = 'not-a-date',
      ];

      for (final candidate in invalid) {
        expect(
          OrderSnapshotContract.validate(
            candidate,
            expectedOrderId: 'order-1',
          ),
          isNull,
        );
      }
    });

    test('rejects malformed values rather than allowing parser defaults', () {
      final invalid = <Map<String, dynamic>>[
        _snapshot()..['current_fare'] = 'not-a-number',
        _snapshot()..['distance_meters'] = null,
        _snapshot()..['payment_status'] = null,
        _snapshot()..['parcel_images'] = <Object>['ok', 1],
      ];

      for (final candidate in invalid) {
        expect(
          OrderSnapshotContract.validate(
            candidate,
            expectedOrderId: 'order-1',
          ),
          isNull,
        );
      }
      expect(
        OrderSnapshotContract.validate(null, expectedOrderId: 'order-1'),
        isNull,
      );
    });
  });

  group('snapshot server and controller integration', () {
    late String edgeFunction;
    late String controller;

    setUpAll(() {
      edgeFunction = File(
        'supabase/functions/get-live-order-status/index.ts',
      ).readAsStringSync();
      controller = File(
        'lib/core/services/realtime/realtime_order_controller.dart',
      ).readAsStringSync();
    });

    test('constructs the allowlisted snapshot only after owner authorization', () {
      final ownerGuard = edgeFunction.indexOf(
        'if (order.user_id !== user.id)',
      );
      final construction = edgeFunction.indexOf(
        'const orderSnapshot = buildOrderSnapshot(order);',
      );
      expect(ownerGuard, greaterThanOrEqualTo(0));
      expect(construction, greaterThan(ownerGuard));
      expect(edgeFunction, isNot(contains('order_snapshot: order,')));
      expect(edgeFunction, isNot(contains('...order')));
      expect(
        RegExp(r'order_snapshot: orderSnapshot').allMatches(edgeFunction),
        hasLength(2),
      );
    });

    test('keeps raw vehicle type separate from display enrichment', () {
      expect(edgeFunction, contains('vehicle_type: order.vehicle_type,'));
      expect(
        edgeFunction,
        contains('intercityPlanVehicleType ?? order.vehicle_type'),
      );
    });

    test('live status logging does not emit profiles or ETA payloads', () {
      expect(edgeFunction, isNot(contains('"RIDER USER =>"')));
      expect(edgeFunction, isNot(contains('"OLA ETA RESPONSE =>"')));
      expect(edgeFunction, contains('category=unexpected_failure'));
    });

    test('version 2 omits unsupported columns and sanitizes outer errors', () {
      expect(edgeFunction, isNot(contains('surge_fee')));
      expect(edgeFunction, isNot(contains('rain_fee')));
      expect(edgeFunction, contains('contract_version: 2'));
      expect(edgeFunction, isNot(contains('error: String(error)')));
      expect(edgeFunction, contains('error: "Unable to retrieve live order status"'));
      final model = TransportOrder.fromJson(_snapshot());
      expect(model.surgeFee, 0);
      expect(model.rainFee, 0);
      expect(OrderSnapshotContract.requiredKeys, hasLength(63));
    });

    test('valid snapshot replaces direct read and invalid snapshot falls back', () {
      expect(
        controller,
        contains('OrderSnapshotContract.validate('),
      );
      expect(controller, contains('_applyOrderData(orderSnapshot);'));
      expect(
        controller,
        contains(
          'liveResult != _LiveStateFetchOutcome.successWithSnapshot',
        ),
      );
      expect(
        controller,
        contains('orderResult = await _fetchOrder(recordPollingResult: false);'),
      );
    });
  });
}
