// Eligibility moved into the atomic RPC. Native PG17 tests execute these rules.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
void main() {
  final edge = File('supabase/functions/accept-order/index.ts').readAsStringSync();
  final sql = File('supabase/functions/accept-order/acceptance_sql.ts').readAsStringSync();
  group('accept-order eligibility inside the atomic transaction', () {
    test('one RPC receives the actor from the verified session', () {
      expect(RegExp(r'supabase\.rpc\(').allMatches(edge).length, 0);
      expect(edge.contains('acceptance = await acceptOrderAtomically'), isTrue);
      expect(edge.contains('acceptOrderAtomically(order_id, rider_id, authData.user.id)'), isTrue);
    });
    test('tax, COD and busy checks retain their precedence', () {
      final tax = sql.indexOf('IF public.is_rider_blocked_by_tax_due(p_rider_id)');
      final cod = sql.indexOf('IF public.is_rider_blocked_by_cod_limit(p_rider_id)');
      final busy = sql.indexOf('IF public.rider_is_on_active_trip(p_rider_id)');
      expect(tax, greaterThan(0)); expect(cod, greaterThan(tax)); expect(busy, greaterThan(cod));
    });
    test('eligibility errors abort the transaction and fail closed', () {
      expect(sql.contains('EXCEPTION WHEN OTHERS'), isFalse);
      expect(edge.contains('} catch (error) {'), isTrue);
      expect(edge.contains('Unable to accept order'), isTrue);
    });
    test('busy check happens under rider serialization and before writes', () {
      final lock = sql.indexOf('WHERE id=p_rider_id FOR NO KEY UPDATE');
      final busy = sql.indexOf('IF public.rider_is_on_active_trip(p_rider_id)');
      final write = sql.indexOf('UPDATE public.orders SET');
      expect(lock, greaterThan(0)); expect(busy, greaterThan(lock)); expect(write, greaterThan(busy));
    });
    test('Edge never falls back to split assignment/order writes', () {
      expect(edge.contains('.insert('), isFalse); expect(edge.contains('.update('), isFalse);
    });
  });
}
