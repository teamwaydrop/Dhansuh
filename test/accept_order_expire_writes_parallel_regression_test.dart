// Expiry writes now share the same database transaction as the winning claim.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
void main() {
  final edge = File('supabase/functions/accept-order/index.ts').readAsStringSync();
  final sql = File('supabase/functions/accept-order/acceptance_sql.ts').readAsStringSync();
  group('accept-order atomic expiry and assignment invariants', () {
    test('both expiry writes belong to the same RPC', () {
      expect(sql.contains("UPDATE public.rider_assignments SET assignment_status='expired'"), isTrue);
      expect(sql.contains("UPDATE public.order_assignment_logs SET assignment_status='expired'"), isTrue);
    });
    test('expiry retains order, other-rider and sent-only filters', () {
      expect("WHERE order_id=p_order_id AND rider_id<>p_rider_id AND assignment_status='sent'".allMatches(sql).length, 2);
      expect(sql.contains("response_type='ignored',last_response_at=v_now"), isTrue);
    });
    test('audit log expiry keeps the response timestamp', () {
      expect(sql.contains("UPDATE public.order_assignment_logs SET assignment_status='expired',responded_at=v_now"), isTrue);
    });
    test('expiry failure cannot leave a partial acceptance', () {
      expect(sql.contains('EXCEPTION WHEN OTHERS'), isFalse);
      expect(edge.contains('} catch (error) {'), isTrue);
    });
    test('canonical fare function is retained inside the transaction', () {
      expect(sql.contains('v_breakdown:=public.calculate_fare_breakdown('), isTrue);
      expect(sql.contains('v_order.current_fare-COALESCE(v_order.final_fare,v_order.current_fare)'), isTrue);
    });
    test('order lock precedes claim and all assignments enforce one accepted rider', () {
      final lock = sql.indexOf('WHERE id=p_order_id FOR NO KEY UPDATE');
      expect(lock, greaterThan(0)); expect(sql.indexOf('UPDATE public.orders SET'), greaterThan(lock));
      expect(sql.contains('CREATE UNIQUE INDEX'), isFalse); expect(sql.contains("assignment_status='accepted')<>1"), isTrue);
    });
  });
}
