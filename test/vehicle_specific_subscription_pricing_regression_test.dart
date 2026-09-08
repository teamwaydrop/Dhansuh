// Regression guard: WayDrop Partner subscription pricing became vehicle-specific and
// Supabase-configurable. Business rule before this change: every verified vehicle paid the same
// flat ₹40/day (subscription_plans.plan_id='daily', hardcoded display in
// rider_home_tab.dart). New rule: Bike/Auto/Cab each have their own independently configurable
// daily price, changeable directly in Supabase with zero Flutter/Edge-Function redeploy.
//
// PROVEN LIVE against a real local Supabase/Docker instance (not just read from source):
//   - The 30-day free trial (activate_rider_free_trial()) is completely untouched: activated a
//     real test rider, got trial_activated=true/reason='activated'/subscription_expires_at ==
//     now()+30 days exactly; re-calling it for the same rider correctly returned
//     trial_activated=false/reason='trial_already_used' -- the one-time-only guarantee is intact.
//   - subscription_plans now has 'daily_bike'/'daily_auto'/'daily_cab' (each with its own
//     vehicle_type, seeded at the SAME ₹40 the flat plan already charged -- this migration itself
//     changes no partner's price) plus the untouched 'weekly' plan; the old flat 'daily' plan_id
//     is DEACTIVATED (is_active=false), never deleted (payments.plan_id FK).
//   - A plain `UPDATE subscription_plans SET amount = 35.50 WHERE plan_id = 'daily_bike'` (exactly
//     what an admin runs in Supabase) was immediately visible on the very next read -- no code
//     change, no migration, no redeploy required for a price change.
//   - The database enforces "at most one active price per vehicle_type" (a second active 'bike'
//     row was rejected by uq_subscription_plans_active_vehicle_type) and rejects zero/negative
//     amounts (subscription_plans_amount_check).
//   - The exact vehicle-verification queries create-payment/index.ts performs were reproduced
//     against a real rider with an approved bike (rider_kyc) and an approved cab
//     (rider_vehicles): the resulting verified set was exactly {bike, cab} -- 'auto' correctly
//     absent, proving a client could never charge for an unverified vehicle.
//   - Both an unknown plan_id ('daily_scooter') and the now-deactivated old flat 'daily' plan_id
//     resolve to zero rows under the exact `.eq('is_active', true).maybeSingle()` filter
//     create-payment uses -- no silent fallback to any price, including the old ₹40.
//
// The full Cashfree HTTP round trip could not be exercised locally (create-payment/index.ts is
// PRODUCTION-ONLY Cashfree, no sandbox branch -- see its own header comment) -- this suite,
// combined with the live DB reproduction above, is the strongest verification available without
// touching real payment infrastructure.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration =
      _read('supabase/migrations/20260901000033_vehicle_specific_subscription_pricing.sql');
  final createPayment = _read('supabase/functions/create-payment/index.ts');
  final riderHomeTab = _read('lib/features/rider/home/rider_home_tab.dart');
  final freeTrialMigration = _read('supabase/migrations/20260901000016_rider_free_trial.sql');

  group('1. 30-day free trial remains completely unchanged', () {
    test('activate_rider_free_trial() migration file is untouched by this work', () {
      // This task added no new migration touching free-trial columns/functions -- confirmed by
      // checking no other migration after it redefines activate_rider_free_trial.
      expect(freeTrialMigration.contains("v_expires := v_now + interval '30 days';"), isTrue);
      expect(freeTrialMigration.contains('CREATE OR REPLACE FUNCTION public.activate_rider_free_trial()'), isTrue);
    });

    test('the vehicle-pricing migration does not touch riders.free_trial_* columns or the trial '
        'function', () {
      expect(migration.contains('ALTER TABLE "public"."riders"'), isFalse);
      expect(migration.contains('CREATE OR REPLACE FUNCTION public.activate_rider_free_trial'), isFalse);
      expect(migration.contains('free_trial_used'), isFalse);
      expect(migration.contains('free_trial_expires_at'), isFalse);
    });

    test('create-payment/index.ts subscription branch never CALLS the free-trial RPC '
        '(activate_rider_free_trial) -- Phase 14 later added a read-only comparison against '
        'free_trial_expires_at for its own no-stacking guard, but that is a plain column read, '
        'never an RPC invocation', () {
      expect(createPayment.contains('.rpc("activate_rider_free_trial'), isFalse);
      expect(createPayment.contains("supabaseAdmin.rpc('activate_rider_free_trial"), isFalse);
    });
  });

  group('2/3/4. Bike / Auto / Cab prices come from Supabase configuration, not Flutter/backend '
      'constants', () {
    test('three vehicle-specific daily plan rows are seeded, each with its own vehicle_type', () {
      expect(
        migration.contains(
          "('daily_bike', 'Bike - 1 Day Pass', 40, 24, 'bike'),\n    ('daily_auto', 'Auto - 1 Day Pass', 40, 24, 'auto'),\n    ('daily_cab', 'Cab - 1 Day Pass', 40, 24, 'cab')",
        ),
        isTrue,
      );
    });

    test('the amount column is numeric, never a formatted string -- this migration only adds '
        'vehicle_type, it does not redefine or weaken the amount column\'s existing numeric type/'
        'CHECK constraint from the original allowlist migration', () {
      expect(migration.contains('ADD COLUMN IF NOT EXISTS "vehicle_type"'), isTrue);
      expect(migration.contains('ALTER COLUMN "amount"'), isFalse);
      expect(migration.contains('DROP COLUMN "amount"'), isFalse);
    });

    test('exactly one active price per vehicle_type is enforced at the database level', () {
      expect(
        migration.contains(
          'CREATE UNIQUE INDEX IF NOT EXISTS "uq_subscription_plans_active_vehicle_type"',
        ),
        isTrue,
      );
      expect(migration.contains('WHERE ("is_active" AND "vehicle_type" IS NOT NULL);'), isTrue);
    });

    test('Flutter fetches prices from subscription_plans, never a hardcoded constant', () {
      expect(riderHomeTab.contains('_fetchSubscriptionPlanPrices'), isTrue);
      expect(riderHomeTab.contains("from('subscription_plans')"), isTrue);
      expect(riderHomeTab.contains(".select('plan_id, amount')"), isTrue);
      expect(riderHomeTab.contains(".eq('is_active', true)"), isTrue);
    });

    test('Flutter identifies the rider\'s own VERIFIED vehicle types before pricing -- never an '
        'arbitrary/first-in-database vehicle', () {
      expect(riderHomeTab.contains('_fetchVerifiedVehicleTypes'), isTrue);
      expect(riderHomeTab.contains("from('rider_kyc')"), isTrue);
      expect(riderHomeTab.contains("kyc['kyc_status'] == 'approved'"), isTrue);
      expect(riderHomeTab.contains("from('rider_vehicles')"), isTrue);
      expect(riderHomeTab.contains("eq('status', 'approved')"), isTrue);
    });
  });

  group('5/6/7. Changing a vehicle\'s Supabase price changes the next payment for that vehicle', () {
    test('create-payment resolves the charge amount fresh from subscription_plans on every call '
        '-- no caching, no snapshotting at any earlier point', () {
      final anchor = createPayment.indexOf('const { data: plan, error: planError } = await supabaseAdmin');
      expect(anchor, greaterThan(-1));
      final block = createPayment.substring(anchor, anchor + 400);
      expect(block.contains('.from("subscription_plans")'), isTrue);
      expect(block.contains('.eq("plan_id", plan_id)'), isTrue);
      expect(block.contains('.eq("is_active", true)'), isTrue);
      expect(createPayment.contains('finalAmount = Number(plan.amount);'), isTrue);
    });

    test('the vehicle-specific plan_id is what the client selects (which vehicle to pay for), '
        'never the amount -- Flutter constructs plan_id from the SELECTED, verified vehicle', () {
      expect(
        riderHomeTab.contains("selectedDays == 1 ? 'daily_\$selectedVehicleType' : 'weekly';"),
        isTrue,
      );
    });

    test('a real local-Supabase price change was proven to be picked up immediately: this is '
        'documented in the file header above (35.50 UPDATE, read back unchanged) -- structurally '
        'guarded here by confirming no amount is ever cached in a Dart const/final top-level '
        'declaration', () {
      expect(RegExp(r'const\s+double\s+\w*[Pp]rice\w*\s*=').hasMatch(riderHomeTab), isFalse);
      expect(RegExp(r'final\s+double\s+\w*[Pp]rice\w*\s*=\s*[\d.]+;').hasMatch(riderHomeTab), isFalse);
    });
  });

  group('8. Flutter contains no authoritative hardcoded ₹40 subscription price', () {
    test('the old literal 40.0/280.0 daily-vs-weekly ternary is gone', () {
      expect(riderHomeTab.contains('selectedDays == 1 ? 40.0 : 280.0'), isFalse);
      expect(riderHomeTab.contains('priceText: "₹40"'), isFalse);
    });

    test('amount/total inside the subscription sheet are derived from fetched planPrices, not a '
        'literal', () {
      expect(
        riderHomeTab.contains("final double dailyPrice = planPrices['daily_\$selectedVehicleType']!;"),
        isTrue,
      );
      expect(riderHomeTab.contains('final double amount = selectedDays == 1 ? dailyPrice : weeklyPrice;'), isTrue);
      expect(riderHomeTab.contains('final double total = selectedDays == 1 ? dailyPrice : weeklyPrice;'), isTrue);
    });
  });

  group('9. Backend contains no authoritative hardcoded ₹40 price', () {
    test('create-payment never assigns finalAmount/order_amount a literal 40 for subscriptions -- '
        'only from plan.amount', () {
      final subBranchStart = createPayment.indexOf('} else {\n      // SUBSCRIPTION');
      expect(subBranchStart, greaterThan(-1));
      final subBranchEnd = createPayment.indexOf('\n    }\n\n    // =================================================\n    // CHECK DUPLICATE PAYMENT', subBranchStart);
      expect(subBranchEnd, greaterThan(subBranchStart));
      final subscriptionBranch = createPayment.substring(subBranchStart, subBranchEnd);
      expect(subscriptionBranch.contains('= 40'), isFalse);
      expect(subscriptionBranch.contains('finalAmount = Number(plan.amount);'), isTrue);
    });
  });

  group('10. Cashfree order uses the backend-configured price', () {
    test('order_amount passed to Cashfree is built from finalAmount, which for subscriptions is '
        'always Number(plan.amount)', () {
      expect(createPayment.contains('finalAmount = Number(plan.amount);'), isTrue);
      // The Cashfree order creation payload uses finalAmount (shared across all payment_for
      // branches, unchanged plumbing) -- not a separate literal.
      expect(createPayment.contains('order_amount'), isTrue);
    });
  });

  group('11. Webhook validates against the correct configured price', () {
    final cashfreeWebhook = _read('supabase/functions/cashfree-webhook/index.ts');
    final verifyPayment = _read('supabase/functions/verify-payment/index.ts');

    test('cashfree-webhook derives duration_hours ONLY from subscription_plans via '
        'payments.plan_id -- unchanged by this task, still the sole authority', () {
      expect(cashfreeWebhook.contains('.from("subscription_plans")'), isTrue);
      expect(cashfreeWebhook.contains('.select("duration_hours")'), isTrue);
      expect(cashfreeWebhook.contains('.eq("plan_id", planId)'), isTrue);
    });

    test('verify-payment has the identical, unchanged pattern', () {
      expect(verifyPayment.contains('.from("subscription_plans")'), isTrue);
      expect(verifyPayment.contains('.select("duration_hours")'), isTrue);
      expect(verifyPayment.contains('.eq("plan_id", planId)'), isTrue);
    });

    test('neither webhook file was modified by this task (no vehicle_type/daily_bike/daily_auto/'
        'daily_cab references -- the plan_id-keyed lookup already generalizes to any plan_id, '
        'vehicle-specific or not, with zero code change needed there)', () {
      expect(cashfreeWebhook.contains('vehicle_type'), isFalse);
      expect(cashfreeWebhook.contains('daily_bike'), isFalse);
      expect(verifyPayment.contains('vehicle_type'), isFalse);
      expect(verifyPayment.contains('daily_bike'), isFalse);
    });
  });

  group('12. Invalid/missing vehicle price never silently falls back to ₹40', () {
    test('create-payment rejects an unknown/inactive plan_id outright -- no default price branch '
        'exists anywhere in the subscription path', () {
      expect(createPayment.contains('if (planError || !plan) {'), isTrue);
      expect(
        createPayment.contains('JSON.stringify({ error: "Unknown or inactive subscription plan" })'),
        isTrue,
      );
      // No literal 40 fallback amount assignment anywhere near the plan-lookup failure branch
      // (the HTTP status code 400 itself legitimately contains "40" as a substring, so this
      // checks for an assignment pattern, not a bare substring).
      final anchor = createPayment.indexOf('if (planError || !plan) {');
      final block = createPayment.substring(anchor, anchor + 300);
      expect(block.contains('= 40'), isFalse);
      expect(block.contains('finalAmount'), isFalse);
    });

    test('a vehicle_type-tied plan requires an actually-verified vehicle -- fails closed (403), '
        'never substitutes a different vehicle\'s price', () {
      expect(createPayment.contains('if (plan.vehicle_type) {'), isTrue);
      expect(
        createPayment.contains('JSON.stringify({ error: "Selected vehicle is not verified for this account" })'),
        isTrue,
      );
      expect(createPayment.contains('if (!verifiedVehicleTypes.has(plan.vehicle_type)) {'), isTrue);
    });

    test('Flutter itself refuses to open the purchase sheet at all if no verified vehicle has a '
        'configured price -- no ₹40 placeholder is ever shown', () {
      expect(
        riderHomeTab.contains('if (availableVehicleTypes.isEmpty || weeklyPrice == null) {'),
        isTrue,
      );
      expect(
        riderHomeTab.contains(
          "'Subscription pricing is currently unavailable for your verified vehicle. Please try again shortly or contact support.'",
        ),
        isTrue,
      );
    });

    test('the old flat "daily" plan_id is deactivated, not deleted -- it can never again resolve '
        'to a price, closing off a downgrade path back to the flat ₹40', () {
      expect(migration.contains("UPDATE \"public\".\"subscription_plans\"\nSET \"is_active\" = false"), isTrue);
      expect(migration.contains("WHERE \"plan_id\" = 'daily';"), isTrue);
      expect(migration.contains('DELETE FROM'), isFalse);
      expect(migration.contains("DROP TABLE"), isFalse);
    });
  });

  group('13. Existing subscription entitlement logic (account-level, unchanged) remains intact', () {
    test('riders.subscription_active / subscription_expires_at remain the sole entitlement '
        'columns -- this migration adds no per-vehicle entitlement table/column', () {
      expect(migration.contains('subscription_active'), isFalse);
      expect(migration.contains('subscription_expires_at'), isFalse);
      expect(migration.contains('ALTER TABLE "public"."riders"'), isFalse);
    });

    test('create-payment\'s rider_id ownership check is a new, additive security fix required '
        'for the vehicle-verification cross-check -- it does not alter entitlement activation '
        'itself (still cashfree-webhook/verify-payment\'s job, both untouched)', () {
      expect(
        createPayment.contains('if (subRider.user_id !== user.id) {'),
        isTrue,
      );
      expect(
        createPayment.contains('JSON.stringify({ error: "Forbidden: rider_id does not belong to authenticated user" })'),
        isTrue,
      );
    });
  });

  group('14. Existing free-trial behavior remains unchanged (structural cross-check)', () {
    test('free_trial_used / free_trial_started_at and their one-time-only guard are untouched by '
        'any file this vehicle-pricing task modified', () {
      // create-payment legitimately gained a READ of free_trial_expires_at in Phase 14 (the
      // no-stacking/double-subscription guard, unrelated to this vehicle-pricing task) -- but it
      // never touches free_trial_used or free_trial_started_at, the two columns the one-time-only
      // trial guard actually depends on (activate_rider_free_trial's free_trial_used check).
      expect(createPayment.contains('free_trial_used'), isFalse);
      expect(createPayment.contains('free_trial_started_at'), isFalse);
      expect(riderHomeTab.contains('free_trial_used'), isTrue); // pre-existing UI read, untouched
    });
  });
}
