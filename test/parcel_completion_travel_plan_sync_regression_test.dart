// Regression guard for 20260906000000_fix_parcel_completion_travel_plan_status_sync.sql.
//
// The migration redefines confirm_intercity_parcel_payment_received() -- the ONLY server-side
// path that completes a PARCEL travel plan -- changing ONLY the rider_travel_plans status write
// so it (a) also covers 'fully_booked' plans and (b) keys off the plan's route_id (Via senders
// board mid-route). Every settlement / fare / commission / GST / tax / wallet line must be
// byte-for-byte the same as the prior definition in 20260901000019.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  final fix = _read('supabase/migrations/20260906000000_fix_parcel_completion_travel_plan_status_sync.sql');
  final prior = _read('supabase/migrations/20260901000019_gate_free_trial_waiver_to_local_orders.sql');

  // Comment-stripped executable text (the header legitimately mentions the old query while
  // explaining it is replaced).
  String exec(String s) => s
      .split('\n')
      .map((l) {
        final i = l.indexOf('--');
        return i >= 0 ? l.substring(0, i) : l;
      })
      .join('\n');
  final fixExec = exec(fix);

  group('A. The plan-status fix', () {
    test('redefines the same function (CREATE OR REPLACE, same name/signature)', () {
      expect(fix.contains('CREATE OR REPLACE FUNCTION public.confirm_intercity_parcel_payment_received(p_order_id uuid)'), isTrue);
    });

    test('the old `status = \'active\'` + pickup/destination-city-only write is gone from executable SQL', () {
      expect(fixExec.contains("AND status = 'active'"), isFalse);
    });

    test('the plan write now covers fully_booked and resolves the plan via intercity_requests.route_id', () {
      expect(fixExec.contains("tp.status IN ('active', 'fully_booked')"), isTrue);
      expect(fixExec.contains('SELECT ir.route_id'), isTrue);
      expect(fixExec.contains('WHERE ir.parcel_id = v_order.id'), isTrue);
      // endpoint-city fallback kept, also widened.
      expect(fixExec.contains("AND status IN ('active', 'fully_booked')"), isTrue);
      expect(fixExec.contains('IF NOT FOUND THEN'), isTrue);
    });

    test('the plan write still sits inside the existing "no other in-flight parcel orders" guard', () {
      final guardIdx = fixExec.indexOf("o.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'payment_pending')");
      final planIdx = fixExec.indexOf('UPDATE public.rider_travel_plans tp');
      expect(guardIdx, greaterThan(-1));
      expect(planIdx, greaterThan(guardIdx));
    });
  });

  group('B. Everything else is unchanged vs 20260901000019', () {
    test('every settlement / fare / tax / wallet line from the prior definition is still present', () {
      for (final line in [
        'v_fare := COALESCE(v_order.final_fare, v_order.current_fare, 0);',
        'v_breakdown := public.calculate_fare_breakdown(',
        "v_commission_amount := (v_breakdown->>'commission_amount')::numeric;",
        "v_gst_amount := (v_breakdown->>'gst_amount')::numeric;",
        "v_rider_earning := (v_breakdown->>'rider_earning')::numeric;",
        'v_tax_result := public.apply_order_government_tax(',
        'PERFORM public.credit_rider_for_completed_order(',
        "SET order_status = 'delivered'::public.order_status_enum,",
        'subscription_commission_waived = false,',
        'UPDATE public.intercity_requests',
        "SET status = 'completed', updated_at = v_now",
        'INSERT INTO public.order_status_history (order_id, previous_status, new_status, changed_by, changed_by_rider_id, changed_by_user_id)',
        'GRANT EXECUTE ON FUNCTION public.confirm_intercity_parcel_payment_received(uuid) TO authenticated;',
        '\$\$ LANGUAGE plpgsql SECURITY DEFINER',
        'SET search_path = public;',
      ]) {
        expect(fix.contains(line), isTrue, reason: 'missing preserved line: $line');
        expect(prior.contains(line), isTrue, reason: 'sanity: line should also exist in the prior def: $line');
      }
    });

    test('no pricing/commission/GST/wallet/schema change: forbidden tokens absent from executable SQL', () {
      for (final forbidden in [
        'ALTER TABLE',
        'DROP TABLE',
        'DELETE FROM',
        'CREATE TABLE',
        'pricing_config',
        'commission_percentage =',
        'gst_percentage =',
        'wallet_balance =',
      ]) {
        expect(fixExec.contains(forbidden), isFalse, reason: 'unexpected: $forbidden');
      }
    });

    test('the prior migration file itself is untouched (forward-only convention)', () {
      expect(prior.contains("AND status = 'active'\n          AND pickup_city = v_order.pickup_city"), isTrue);
      expect(prior.contains('UPDATE public.rider_travel_plans tp'), isFalse);
    });
  });
}
