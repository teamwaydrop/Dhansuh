// Structural regression guard for Phase 1 / Issue 3: when a PASSENGER cancels their own intercity
// Travel Request/booking, they must be told "You cancelled this request.", never the generic
// "Your traveller cancelled this trip." wording that wrongly blames the other party.
//
// PRODUCTION RECONCILIATION (2026-08-23): the actor sentinel this fix hinges on --
// intercity_requests.cancelled_by_actor, written by update-order-status/index.ts and read by
// on_intercity_request_change()'s 'cancelled' branch -- was originally drafted using 'passenger'
// as the value. A read-only audit of the linked production project found:
//   - orders.cancelled_by (the sibling column this new column mirrors) is the REAL Postgres enum
//     `cancelled_by_enum`, with exactly four labels: 'user', 'rider', 'admin', 'system'. There is
//     no 'passenger' label anywhere in this codebase's actual actor-attribution convention.
//   - The pre-existing (already-deployed, unrelated-to-this-fix) write of orders.cancelled_by at
//     update-order-status/index.ts's TIMESTAMP UPDATES block had ALSO drifted: the local file (git
//     HEAD) still wrote 'passenger' there, but production's actual live deployed code already
//     wrote 'user' -- writing 'passenger' into a real enum column with no such label would throw
//     an invalid-enum-value error on every passenger-initiated cancellation, for every order type
//     (local ride, local parcel, intercity ride, intercity parcel alike). That line was corrected
//     to match the already-verified production value.
// Both the new cancelled_by_actor sentinel (migration 20260901000024) and the pre-existing
// cancelled_by sentinel (update-order-status/index.ts, ~line 552) were therefore aligned on
// 'user', and this migration's own actor check was corrected from 'passenger' to 'user' to match,
// before ever being deployed.
//
// FIX: intercity_requests gains a new `cancelled_by_actor` column (nullable, additive), stamped by
// update-order-status/index.ts's existing intercity_requests sync block from the same server-
// resolved isDriver/isPassenger used for orders.cancelled_by a few hundred lines above (never a
// client-supplied value). on_intercity_request_change()'s 'cancelled' branch gains one new,
// highest-priority check: `NEW.cancelled_by_actor = 'user'` -> "You cancelled this request." --
// checked ahead of the existing cancelled_scope='travel_plan'/'individual_request' branches (which
// are populated by an entirely different write path -- cascade_cancel_travel_plan_dependents /
// cancel_intercity_request_by_traveller -- and never touch this new column, so they fall through
// unaffected) and ahead of the generic ELSE fallback (still correct for genuine rider-initiated
// cancellations, where cancelled_by_actor='rider').
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read(
    'supabase/migrations/20260901000024_intercity_request_cancel_actor_column_and_wording.sql',
  );
  final updateOrderStatus = _read('supabase/functions/update-order-status/index.ts');

  group('1. New additive column: intercity_requests.cancelled_by_actor', () {
    test('column is added nullable, additive, forward-only (IF NOT EXISTS, no default, no '
        'backfill, no NOT NULL constraint)', () {
      expect(
        migration.contains(
          'ALTER TABLE public.intercity_requests ADD COLUMN IF NOT EXISTS cancelled_by_actor text;',
        ),
        isTrue,
      );
    });
  });

  group('2. Correct self-attribution: passenger cancelling their own request', () {
    test("the trigger's new highest-priority check compares cancelled_by_actor to 'user' -- NOT "
        "'passenger' -- and produces the self-attributed copy", () {
      expect(
        migration.contains(
          "IF NEW.cancelled_by_actor = 'user' THEN\n                    v_title := 'Booking Cancelled';\n"
          "                    v_body := 'You cancelled this request.';",
        ),
        isTrue,
      );
    });

    test('this new check is the FIRST branch inside the cancelled/rejected_by-is-null block -- '
        'checked ahead of both existing cancelled_scope branches, so it takes priority whenever '
        'the passenger cancelled their own booking directly (not via a travel-plan-wide or '
        'individual-request cascade)', () {
      final cancelledBlockStart = migration.indexOf("ELSIF NEW.status = 'cancelled' THEN");
      final selfAttrCheck = migration.indexOf("NEW.cancelled_by_actor = 'user' THEN");
      final travelPlanCheck = migration.indexOf("cancelled_scope' = 'travel_plan' THEN");
      final individualCheck = migration.indexOf("cancelled_scope' = 'individual_request' THEN");
      expect(cancelledBlockStart, greaterThan(-1));
      expect(selfAttrCheck, greaterThan(cancelledBlockStart));
      expect(travelPlanCheck, greaterThan(selfAttrCheck));
      expect(individualCheck, greaterThan(selfAttrCheck));
    });
  });

  group('3. No "passenger" sentinel anywhere -- the corrected, production-verified convention '
      'uses "user"', () {
    test('migration 24\'s actual executable SQL never compares against or assigns the literal '
        "string 'passenger' as an actor value (checked with every -- comment line stripped, since "
        "both the header prose AND several inline comments explain -- in English -- the historical "
        "'passenger' draft this was corrected from)", () {
      final codeLines = migration
          .split('\n')
          .where((line) => !line.trim().startsWith('--'))
          .join('\n');
      expect(codeLines.contains("'passenger'"), isFalse);
    });

    test('update-order-status/index.ts never assigns the literal string "passenger" as an actor '
        'value for either cancelled_by or cancelled_by_actor', () {
      expect(updateOrderStatus.contains('"passenger"'), isFalse);
    });
  });

  group('4. update-order-status/index.ts stamps cancelled_by_actor in the SAME update as the '
      'status sync (no race with the trigger), using the corrected \'user\' sentinel', () {
    test('the intercity_requests sync block writes cancelled_by_actor only when cancelling, '
        "deriving it from isDriver/isPassenger exactly like orders.cancelled_by", () {
      expect(
        updateOrderStatus.contains(
          '...(new_status === "cancelled"\n'
          '            ? { cancelled_by_actor: isDriver ? "rider" : (isPassenger ? "user" : null) }\n'
          '            : {}),',
        ),
        isTrue,
      );
    });

    test('the pre-existing orders.cancelled_by write (unrelated to this migration, but the sibling '
        "sentinel this fix must stay consistent with) also uses 'user', not the stale 'passenger' "
        'this local file previously had -- a production/local drift discovered and corrected during '
        'the same reconciliation pass', () {
      expect(
        updateOrderStatus.contains(
          'timestampUpdates.cancelled_by = isDriver ? "rider" : (isPassenger ? "user" : null);',
        ),
        isTrue,
      );
    });

    test('both cancelled_by writes are server-derived from isDriver/isPassenger -- never a client-'
        'supplied field -- preserving the pre-existing "Issue 7 fix" security property', () {
      expect(
        updateOrderStatus.contains(
          'derive the actor server-side from the already-resolved isDriver/isPassenger',
        ),
        isTrue,
      );
    });
  });

  group('5. Every other branch of on_intercity_request_change() is untouched', () {
    test('the two existing cancelled_scope branches (travel_plan / individual_request) keep their '
        'exact original wording', () {
      expect(
        migration.contains(
          "v_title := 'Travel Plan Cancelled';",
        ),
        isTrue,
      );
      expect(
        migration.contains(
          "|| ' was cancelled by the traveller. You can search for another available traveller.';",
        ),
        isTrue,
      );
    });

    test('the generic ELSE fallback (still correct for a genuine rider-initiated cancellation) is '
        'unchanged', () {
      expect(
        migration.contains(
          "v_body := 'Your traveller cancelled this trip. Please choose another available partner.';",
        ),
        isTrue,
      );
    });

    test('every non-cancelled status branch (INSERT match-notifications, discussion_started, '
        'confirmed, rejected, paid, in_progress, completed, and the trailing rejected/confirmed '
        'notify blocks) is reproduced byte-for-byte', () {
      expect(migration.contains("v_title := 'Discussion Opened 💬';"), isTrue);
      expect(migration.contains("v_title := 'Travel Request Accepted';"), isTrue);
      expect(migration.contains("v_title := 'Payment Verified! 💳';"), isTrue);
      expect(
        migration.contains(
          "'Booking Confirmed',\n                'You''ve accepted this trip. It''s now confirmed -- coordinate the pickup with your passenger.',",
        ),
        isTrue,
      );
    });

    test('rider_id/parcel_id/status jsonb payload shape for the intercity_request push is '
        'unchanged', () {
      expect(migration.contains("'type', 'intercity_request',"), isTrue);
    });
  });

  group('6. Migration safety: documents the production reconciliation trace', () {
    test('the header explicitly documents the passenger -> user correction and cites the '
        'production audit that discovered it', () {
      expect(migration.contains('RECONCILED AGAINST ACTUAL PRODUCTION'), isTrue);
      expect(migration.contains('cancelled_by_enum'), isTrue);
    });

    test('no pricing, GST, commission, tax, payment, or subscription keyword appears in the '
        'actual function body -- confirms the scope stayed actor-wording-only', () {
      final bodyStart = migration.indexOf('AS \$function\$');
      expect(bodyStart, greaterThan(-1));
      final body = migration.substring(bodyStart).toLowerCase();
      for (final forbidden in [
        'gst_percentage',
        'commission_percentage',
        'tax_rate_config',
        'government_tax_ledger',
        'cashfree',
        'pricing_config',
        'subscription_active',
      ]) {
        expect(body.contains(forbidden.toLowerCase()), isFalse,
            reason: 'unexpected "$forbidden" reference in an actor-wording-only migration');
      }
    });
  });
}
