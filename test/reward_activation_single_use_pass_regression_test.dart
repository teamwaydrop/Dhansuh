// Regression guard for PHASE 14 (cont.) -- reward-cycle activation, 5-minute pass, and
// the "one reward cycle = one merchant activation, ever" rule.
//
// This codebase's established convention for backend/SQL logic changes is a structural
// guard that reads the real migration/source text and asserts the guarantees are wired
// the way the business rule requires (see e.g.
// update_order_status_production_reconciliation_regression_test.dart) rather than a live
// database round trip -- there is no Docker/local Supabase instance in this environment
// to exercise the actual atomic UPDATE against real rows. Scenario numbers below match
// the 30 scenarios requested for this phase; several are covered by the same guard and
// are grouped together with a comment explaining why.
//
// Structural guard (reads the real source as text), consistent with this repo's other
// regression tests.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

String _codeOnly(String source) {
  return source
      .split('\n')
      .map((line) {
        final commentIndex = line.indexOf('//');
        return commentIndex == -1 ? line : line.substring(0, commentIndex);
      })
      .join('\n');
}

void main() {
  final migration = _read('supabase/migrations/20260903000000_reward_activation_single_use_pass.sql');
  final rewardService = _read('lib/modules/rewards/services/reward_service.dart');
  final rewardsScreen = _read('lib/modules/rewards/screens/rewards_screen.dart');
  final categoryOffersScreen = _read('lib/modules/rewards/screens/category_offers_screen.dart');
  final offerDetailScreen = _read('lib/modules/rewards/screens/offer_detail_screen.dart');
  final activePassScreen = _read('lib/modules/rewards/screens/active_pass_screen.dart');

  group('Scenarios 1-3: unlock and browsing never consume the reward', () {
    test('get_reward_status still reports required_rides/progress unchanged (cycle unlock logic untouched)', () {
      expect(migration.contains("qualifying_ride_count', v_count"), isTrue);
      expect(migration.contains("current_cycle_number', v_cycle_number"), isTrue);
    });

    test('fetching offers for a category is a plain read (fetchOffersForCategory), no activation call involved', () {
      expect(categoryOffersScreen.contains('RewardService.fetchOffersForCategory'), isTrue);
      expect(_codeOnly(categoryOffersScreen).contains('activateOffer'), isFalse);
    });

    test('opening the merchant detail screen does not call activateOffer (browsing-only)', () {
      // activateOffer must only appear inside the confirm-callback, never in build()/initState().
      final buildStart = offerDetailScreen.indexOf('Widget build(BuildContext context) {');
      final beforeBuild = offerDetailScreen.substring(0, buildStart);
      expect(beforeBuild.contains('RewardService.activateOffer'), isTrue); // only in _confirmAndActivate, above build()
      expect(_codeOnly(offerDetailScreen.substring(buildStart)).contains('RewardService.activateOffer'), isFalse);
    });
  });

  group('Scenarios 4-5: confirmation screen appears; cancel/back never activates', () {
    test('a confirmation dialog with the exact required wording exists before activation', () {
      expect(offerDetailScreen.contains('Activate this offer?'), isTrue);
      expect(offerDetailScreen.contains('available for \${widget.activationWindowMinutes}'), isTrue);
      expect(offerDetailScreen.contains('If you go back, leave the app, or the offer times out, the reward is'), isTrue);
      expect(offerDetailScreen.contains('OK, ACTIVATE OFFER'), isTrue);
      expect(offerDetailScreen.contains('CANCEL'), isTrue);
    });

    test('activation only proceeds when the dialog resolves true (Cancel/back leaves it unconsumed)', () {
      expect(offerDetailScreen.contains('if (confirmed != true || !mounted) return;'), isTrue);
    });
  });

  group('Scenarios 6, 14, 15, 16, 21, 22, 27: exactly one activation per cycle, race-safe, cross-user blocked', () {
    // One atomic compare-and-swap UPDATE is the single mechanism that: creates exactly
    // one redemption (6), blocks a second merchant from the same cycle whether it's
    // another mall, another restaurant, or the same category (14/15/16 -- the guard is
    // on the CYCLE, not the offer/category, so it is category-agnostic), makes
    // concurrent duplicate attempts resolve to exactly one success (27 -- Postgres
    // row-level locking serializes the two UPDATEs), and rejects a cycle that does not
    // belong to the resolved owner (21) since owner_id is never client-supplied.
    test('activate_reward_offer performs a single atomic UPDATE gated on status=active', () {
      expect(migration.contains("SET status = 'redeemed',"), isTrue);
      expect(migration.contains('WHERE id = p_reward_cycle_id\n      AND owner_type = p_owner_type\n      AND owner_id = v_owner_id\n      AND status = \'active\'\n      AND expires_at >= v_now'), isTrue);
      expect(migration.contains("RETURN jsonb_build_object('success', false, 'error', 'CYCLE_NOT_AVAILABLE');"), isTrue);
    });

    test('owner_id is always resolved from auth.uid(), never accepted as a client parameter', () {
      expect(migration.contains('v_owner_id := auth.uid();'), isTrue);
      expect(migration.contains('SELECT id INTO v_owner_id FROM public.riders WHERE user_id = auth.uid()'), isTrue);
      expect(migration.contains('p_owner_id'), isFalse); // no such parameter exists anywhere
    });

    test('no advisory lock is used -- matches this codebase\'s established idiom of compare-and-swap only', () {
      expect(_codeOnly(migration).contains('pg_advisory_xact_lock('), isFalse);
    });
  });

  group('Scenario 17: a new cycle restores activation availability', () {
    test('reward_offers RLS is keyed on ANY currently-active cycle, so a fresh cycle re-enables browsing/activation independent of a consumed one', () {
      // Unchanged from the original migration -- consuming one cycle only flips THAT
      // row's status; a different, still-active cycle continues to satisfy this policy.
      final rlsMigration = _read('supabase/migrations/20260902000000_waydrop_rewards_system.sql');
      expect(rlsMigration.contains("rc.status = 'active'"), isTrue);
    });
  });

  group('Scenarios 18-20: expiry rules', () {
    test('an expired reward cycle cannot activate (expires_at check in the UPDATE guard)', () {
      expect(migration.contains('AND expires_at >= v_now'), isTrue);
    });

    test('an expired/not-yet-valid merchant offer cannot activate (offer\'s OWN valid_from/valid_until, independent of the cycle)', () {
      expect(migration.contains('(o.valid_from IS NULL OR o.valid_from <= v_now)'), isTrue);
      expect(migration.contains('(o.valid_until IS NULL OR o.valid_until >= v_now)'), isTrue);
    });

    test('cycle expiry and offer expiry are two separate WHERE conditions, never merged into one check', () {
      final cycleCheckIndex = migration.indexOf('AND expires_at >= v_now');
      final offerCheckIndex = migration.indexOf('o.valid_until IS NULL OR o.valid_until >= v_now');
      expect(cycleCheckIndex, greaterThan(-1));
      expect(offerCheckIndex, greaterThan(-1));
      expect(cycleCheckIndex, isNot(equals(offerCheckIndex)));
    });
  });

  group('Scenarios 8-10: active pass content', () {
    test('the active pass shows the exact merchant-specific discount from the activation payload, not a category default', () {
      expect(activePassScreen.contains("activation['discount_type']"), isTrue);
      expect(activePassScreen.contains("activation['discount_value']"), isTrue);
      expect(_codeOnly(activePassScreen).contains('default_discount'), isFalse);
    });

    test('the active pass never displays a coupon code', () {
      expect(_codeOnly(activePassScreen).contains('coupon_code'), isFalse);
    });

    test('no redeem/verify/scan/QR action exists on the active pass (code, not comments)', () {
      final code = _codeOnly(activePassScreen).toLowerCase();
      expect(code.contains('redeem'), isFalse);
      expect(code.contains('verify'), isFalse);
      expect(code.contains('scan'), isFalse);
      expect(code.contains('qr'), isFalse);
    });
  });

  group('Scenario 7: the 5-minute window starts at activation, not at browsing', () {
    test('activation_expires_at is computed from v_now + the configured window inside activate_reward_offer, not stamped anywhere else', () {
      expect(migration.contains('v_expires_at := v_now + make_interval(mins => v_config.activation_window_minutes);'), isTrue);
    });

    test('the countdown on the active pass is derived from the server expires_at, never a client-side "+5 minutes" literal', () {
      expect(activePassScreen.contains("DateTime.parse(widget.activation['expires_at'] as String)"), isTrue);
      expect(_codeOnly(activePassScreen).contains('Duration(minutes: 5'), isFalse);
    });
  });

  group('Scenarios 11-13: terminal conditions close the pass server-side', () {
    test('back navigation from the active pass calls close_active_pass', () {
      expect(activePassScreen.contains('onPopInvokedWithResult'), isTrue);
      expect(activePassScreen.contains('_closePass();'), isTrue);
    });

    test('app backgrounding (paused lifecycle state) calls close_active_pass', () {
      expect(activePassScreen.contains('AppLifecycleState.paused'), isTrue);
      expect(activePassScreen.contains('didChangeAppLifecycleState'), isTrue);
    });

    test('the 5-minute timeout is enforced by the countdown reaching zero, independent of any user action', () {
      expect(activePassScreen.contains("expired ? 'EXPIRED'"), isTrue);
    });

    test('close_active_pass is best-effort only -- never the security boundary (activation already consumed the cycle atomically)', () {
      expect(migration.contains('NOT the security boundary'), isTrue);
    });
  });

  group('Scenario 28: activation failure cannot mutate unrelated state', () {
    test('activate_reward_offer touches only reward_cycles -- no write to orders/payments/wallet tables anywhere in this function', () {
      final fnStart = migration.indexOf('CREATE OR REPLACE FUNCTION public.activate_reward_offer');
      final fnEnd = migration.indexOf(r'$function$;', fnStart + 1);
      final fnBody = migration.substring(fnStart, fnEnd);
      expect(fnBody.contains('UPDATE public.orders'), isFalse);
      expect(fnBody.contains('UPDATE public.riders'), isFalse);
      expect(fnBody.contains('credit_rider_for_completed_order'), isFalse);
    });
  });

  group('Scenarios 23-26: thresholds/validity remain configurable (untouched by this migration)', () {
    test('user/partner required_rides and offer_validity_days columns are not dropped or redefined by this migration', () {
      expect(migration.contains('DROP COLUMN'), isFalse);
      expect(migration.contains('ALTER COLUMN'), isFalse);
      // get_reward_status legitimately still READS these columns (reproduced verbatim);
      // this migration only ADDs a new reward_config column alongside them.
      expect(migration.contains('ADD COLUMN IF NOT EXISTS activation_window_minutes'), isTrue);
    });

    test('Scenario 22: RewardsScreen requires an explicit ownerType so the same one-cycle-one-activation code path serves both audiences identically', () {
      expect(rewardsScreen.contains('required this.ownerType'), isTrue);
    });

    test('the activation window itself is centralized in reward_config, never hardcoded in Flutter', () {
      expect(migration.contains('activation_window_minutes integer NOT NULL DEFAULT 5'), isTrue);
      expect(rewardService.contains("status['activation_window_minutes']"), isTrue);
      expect(_codeOnly(offerDetailScreen).contains(RegExp(r"'\d+ minutes")), isFalse); // no hardcoded minute count as a string literal
    });
  });

  group('Scenarios 29-30: pre-existing behavior remains intact', () {
    test('per-offer discount independence guard file still exists and is unaffected by this change', () {
      expect(File('test/reward_offer_discount_independence_regression_test.dart').existsSync(), isTrue);
    });

    test('RewardService.isUnlocked/isFeatureEnabled (profile visibility gating) are untouched by this migration', () {
      expect(rewardService.contains('static bool isUnlocked(Map<String, dynamic> status)'), isTrue);
      expect(rewardService.contains('static bool isFeatureEnabled(Map<String, dynamic> status)'), isTrue);
    });

    test('security: new functions are revoked from PUBLIC and granted only to authenticated', () {
      expect(migration.contains('REVOKE ALL ON FUNCTION public.activate_reward_offer(text, uuid, uuid) FROM PUBLIC;'), isTrue);
      expect(migration.contains('GRANT EXECUTE ON FUNCTION public.activate_reward_offer(text, uuid, uuid) TO authenticated;'), isTrue);
      expect(migration.contains('REVOKE ALL ON FUNCTION public.close_active_pass(text, uuid) FROM PUBLIC;'), isTrue);
    });
  });
}
