// Structural regression guard for the reconciliation migration that documents production's
// CURRENT LIVE definition of public.cascade_cancel_travel_plan_dependents() in git (Phase 12
// drift investigation). This function's live body was never committed to this repository under
// any prior migration -- see the migration's own header for the full evidence chain
// (git history search, pg_get_functiondef, pg_stat_statements recovery).
//
// This is a documentation/reconciliation migration only -- it changes no behavior (production
// already has this exact definition). This test guards that the migration:
//   1. targets ONLY cascade_cancel_travel_plan_dependents() -- no other function/table/trigger.
//   2. reproduces the CURRENT live searching/expired behavior, not the old hard-cancel behavior.
//   3. never reintroduces `order_status = 'cancelled'` as part of the active dependent-order
//      UPDATE logic (only allowed inside explanatory comments, describing the superseded old
//      behavior it is deliberately NOT restoring).
//   4. does not touch cancel_intercity_request_by_traveller() (explicitly out of scope here).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read(
    'supabase/migrations/20260901000039_reconcile_live_cascade_cancel_travel_plan_dependents.sql',
  );
  // CODE-only view (comments stripped) -- explanatory prose is allowed to mention the superseded
  // 'cancelled' behavior for context; only the ACTIVE SQL must never reintroduce it.
  final code = migration
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('--'))
      .join('\n');

  group('1. Targets ONLY cascade_cancel_travel_plan_dependents() -- nothing else', () {
    test('exactly one CREATE OR REPLACE FUNCTION, and it is the right one', () {
      final defs = RegExp(r'CREATE OR REPLACE FUNCTION (public\.\w+)')
          .allMatches(migration)
          .map((m) => m.group(1))
          .toSet();
      expect(defs, {'public.cascade_cancel_travel_plan_dependents'});
    });

    test('no DROP FUNCTION / CREATE TRIGGER / GRANT / REVOKE / ALTER TABLE / CREATE POLICY', () {
      for (final banned in [
        'DROP FUNCTION',
        'DROP TRIGGER',
        'CREATE TRIGGER',
        'GRANT ',
        'REVOKE ',
        'ALTER TABLE',
        'CREATE POLICY',
        'ALTER POLICY',
        'DROP POLICY',
        'CREATE INDEX',
        'DROP INDEX',
      ]) {
        expect(migration.contains(banned), isFalse, reason: 'migration must not contain "$banned"');
      }
    });

    test('cancel_intercity_request_by_traveller() is not touched by this migration', () {
      // CODE-only check -- the header comment legitimately names it once, to state explicitly
      // that it is out of scope for this migration.
      expect(code.contains('cancel_intercity_request_by_traveller'), isFalse);
    });
  });

  group('2. Current live searching/expired behavior is present', () {
    test('dependent orders revert to searching, or expired if travel_date has passed', () {
      expect(code.contains("'searching'::public.order_status_enum"), isTrue);
      expect(code.contains("'expired'::public.order_status_enum"), isTrue);
      expect(code.contains('o.travel_date <= v_now'), isTrue);
    });

    test('rider_id/OTP fields are cleared on the reverted order (re-matchable, not orphaned)', () {
      final s = code.indexOf('WITH updated_orders AS (');
      expect(s, greaterThan(-1));
      final block = code.substring(s, s + 600);
      expect(block.contains('rider_id = NULL'), isTrue);
      expect(block.contains('accepted_at = NULL'), isTrue);
      expect(block.contains('pickup_otp = NULL'), isTrue);
      expect(block.contains('delivery_otp = NULL'), isTrue);
    });

    test('the WITH updated_orders AS (...) CTE + order_status_history INSERT logic is present', () {
      expect(code.contains('WITH updated_orders AS ('), isTrue);
      expect(code.contains('INSERT INTO public.order_status_history'), isTrue);
      expect(code.contains('FROM updated_orders;'), isTrue);
    });

    test('cancelled_reason / cancelled_scope=travel_plan / cancelled_by_actor metadata preserved', () {
      expect(code.contains("'cancelled_scope', 'travel_plan'"), isTrue);
      expect(code.contains("'cancelled_by_actor', 'traveller'"), isTrue);
    });

    test('the app.bypass_order_state_guard bypass is preserved', () {
      expect(code.contains("set_config('app.bypass_order_state_guard', 'true', true)"), isTrue);
    });
  });

  group('3. Old hard-cancel behavior is NOT reintroduced', () {
    test('the active CODE never sets a dependent order to order_status = \'cancelled\'', () {
      // The only two occurrences of this exact string in the whole file are inside explanatory
      // comments (describing what the superseded old migrations did / what this one does NOT
      // do) -- neither survives comment-stripping.
      expect(code.contains("order_status = 'cancelled'"), isFalse);
    });

    test('no CASE branch/UPDATE unconditionally forces the dependent order to \'cancelled\'', () {
      // The only order_status assignment in the dependent-order UPDATE is the searching/expired
      // CASE expression -- there is no second, unconditional order_status = 'cancelled'::...
      expect(code.contains("order_status = 'cancelled'::public.order_status_enum"), isFalse);
    });
  });

  group('4. Migration header documents this as reconciliation-only, not a behavior change', () {
    test('explicitly states it is a no-op against current production', () {
      expect(migration.toLowerCase().contains('no-op if ever run'), isTrue);
    });
  });
}
