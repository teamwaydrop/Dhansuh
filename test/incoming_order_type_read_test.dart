import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/rider/home/incoming_order_type_read.dart';

void main() {
  test('duplicate INSERT display lookups share one request, without caching later events', () async {
    final reader = IncomingOrderTypeRead();
    final response = Completer<Map<String, dynamic>?>();
    var count = 0;
    Future<Map<String, dynamic>?> fetch() { count++; return response.future; }
    final a = reader.read(userId: 'A', riderId: 'R', orderId: 'O', fetch: fetch);
    final b = reader.read(userId: 'A', riderId: 'R', orderId: 'O', fetch: fetch);
    expect(count, 1);
    response.complete({'order_type': 'intercity_ride'});
    expect(await a, 'intercity_ride');
    expect(await b, 'intercity_ride');
    await reader.read(userId: 'A', riderId: 'R', orderId: 'O', fetch: fetch);
    expect(count, 2);
  });
  test('different users, riders and orders never share type results', () async {
    final reader = IncomingOrderTypeRead();
    final a = Completer<Map<String, dynamic>?>();
    final first = reader.read(userId: 'A', riderId: 'R', orderId: 'O', fetch: () => a.future);
    for (final scope in [('B', 'R', 'O'), ('A', 'S', 'O'), ('A', 'R', 'P')]) {
      expect(await reader.read(userId: scope.$1, riderId: scope.$2, orderId: scope.$3,
          fetch: () async => {'order_type': 'parcel'}), 'parcel');
    }
    a.complete({'order_type': 'ride'});
    expect(await first, 'ride');
  });
  test('null and missing type retain existing unknown-type semantics', () async {
    final reader = IncomingOrderTypeRead();
    for (final row in [null, <String, dynamic>{}, {'order_type': null}]) {
      expect(await reader.read(userId: 'A', riderId: 'R', orderId: 'O', fetch: () async => row), isNull);
    }
  });
  test('failure propagates to both callers and future requests remain possible', () async {
    final reader = IncomingOrderTypeRead();
    final response = Completer<Map<String, dynamic>?>();
    final a = reader.read(userId: 'A', riderId: 'R', orderId: 'O', fetch: () => response.future);
    final b = reader.read(userId: 'A', riderId: 'R', orderId: 'O', fetch: () async => fail('Duplicate'));
    final assertions = [expectLater(a, throwsStateError), expectLater(b, throwsStateError)];
    response.completeError(StateError('synthetic'));
    await Future.wait(assertions);
    expect(await reader.read(userId: 'A', riderId: 'R', orderId: 'O',
        fetch: () async => {'order_type': 'ride'}), 'ride');
  });
  test('disposal rejects future queries; caller must fence any already-running result', () async {
    final reader = IncomingOrderTypeRead();
    final response = Completer<Map<String, dynamic>?>();
    final pending = reader.read(userId: 'A', riderId: 'R', orderId: 'O', fetch: () => response.future);
    reader.dispose();
    response.complete({'order_type': 'ride'});
    expect(await pending, 'ride'); // Widget identity/mounted guard owns UI application.
    await expectLater(reader.read(userId: 'A', riderId: 'R', orderId: 'O',
        fetch: () async => fail('Disposed fetch')), throwsStateError);
  });
}
