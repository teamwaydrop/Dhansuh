import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/rider/earnings/earnings_order_completeness.dart';

void main() {
  test('complete and legitimate empty rows preserve all financial/model values', () {
    final rows = [{'id': 'R', 'rider_earning': '17.95', 'final_fare': 21, 'created_at': null}];
    expect(completeEarningsOrders(rows, 1), rows);
    expect(completeEarningsOrders([], 0), isEmpty);
  });
  test('truncation, absent/invalid count and malformed row shapes fail closed', () {
    for (final count in [null, -1, 0, 2]) {
      expect(() => completeEarningsOrders([{'id': 'R'}], count), throwsStateError);
    }
    expect(() => completeEarningsOrders(null, 0), throwsStateError);
    expect(() => completeEarningsOrders([null], 1), throwsA(isA<TypeError>()));
    expect(() => completeEarningsOrders(List.generate(1000, (_) => {'id': 'R'}), 1001), throwsStateError);
  });
}
