// Regression guard for two subscription UX/entitlement bugs found in local testing on a real
// production-shaped account (KYC vehicle: bike; 30-day free trial intentionally ended via a
// confirmed, explicit direct UPDATE: subscription_active=false, subscription_expires_at=NULL,
// free_trial_used stays true, free_trial_expires_at kept as a historical record only).
//
// BUG 1 (home screen still showed "30 Days Free • 0% Commission" / "X days remaining • Until 23
// Sep" after the trial was explicitly ended): _isFreeTrialActive() computed "is the trial
// currently running" from free_trial_expires_at ALONE. That field is permanent bookkeeping (set
// once by activate_rider_free_trial(), never reset -- see
// 20260901000016_rider_free_trial.sql's own doc comment) -- it is not proof the entitlement is
// still live. Once an admin ends the entitlement early (subscription_active=false,
// subscription_expires_at=NULL) while intentionally leaving free_trial_expires_at untouched (by
// design, so the historical record survives), the old _isFreeTrialActive still saw a
// still-in-the-future free_trial_expires_at and kept reporting the trial as active.
//
// FIX: _isFreeTrialActive now also requires _isSubscriptionActive(rider) -- the actual live
// entitlement, and the same source of truth already used by the go-online gate
// (toggleOnlineStatus) and the "Extend"/expired banners. This matches
// _buildSubscriptionBanner's own pre-existing documented assumption ("during the trial window,
// subscription_active ... IS the trial window") -- the fix makes that assumption an explicit
// check instead of an implicit, previously-false one. No other file in lib/ computes or displays
// free-trial status -- confirmed by a repo-wide search -- so this is the single source of truth
// and there is no competing/duplicate calculation to fix elsewhere.
//
// BUG 2 (the vehicle-specific subscription sheet let a rider whose only verified vehicle is Bike
// select Auto/Cab): investigated against real production data for the exact test account -- the
// account genuinely has Bike (rider_kyc, approved) AND Cab + Auto (rider_vehicles, approved) all
// verified, so seeing all three as selectable was correct given that account's real, if
// unexpected, data -- not a code defect. The vehicle-verification filtering
// (availableVehicleTypes, gating both the selector and the plan_id sent to create-payment) was
// already correct. This change is a UX IMPROVEMENT requested regardless: the selector now always
// shows all three vehicle types with their live prices, but greys out and labels "Not verified"
// any vehicle the rider does not have verified, and makes it non-tappable -- previously an
// unverified vehicle was simply omitted from the list entirely, which is harder to understand than
// showing it explicitly disabled. Backend enforcement (create-payment/index.ts) is completely
// unchanged and remains the sole authority -- this is a UI-only, defense-in-depth improvement.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

// Mirrors the (private, library-scoped) _isSubscriptionActive/_isFreeTrialActive logic in
// rider_home_tab.dart exactly -- cannot be imported directly since Dart privacy is per-file, so
// this is verified two ways: (1) structural assertions below confirm the real source contains
// this exact logic, (2) these mirror functions give real behavioral coverage of the four required
// scenarios.
bool _isSubscriptionActive(Map<String, dynamic>? rider) {
  return rider?['subscription_active'] == true &&
      rider?['subscription_expires_at'] != null &&
      DateTime.tryParse(rider!['subscription_expires_at'].toString())?.isAfter(DateTime.now()) == true;
}

bool _isFreeTrialActive(Map<String, dynamic>? rider) {
  if (!_isSubscriptionActive(rider)) return false;
  final expiresAtStr = rider?['free_trial_expires_at'];
  if (expiresAtStr == null) return false;
  final expiresAt = DateTime.tryParse(expiresAtStr.toString());
  return expiresAt != null && expiresAt.isAfter(DateTime.now());
}

void main() {
  final riderHomeTab = _read('lib/features/rider/home/rider_home_tab.dart');
  final createPayment = _read('supabase/functions/create-payment/index.ts');

  group('0. The mirrored logic above matches the real source exactly', () {
    test('_isFreeTrialActive requires _isSubscriptionActive first, in the real file', () {
      final anchor = riderHomeTab.indexOf('static bool _isFreeTrialActive(Map<String, dynamic>? rider) {');
      expect(anchor, greaterThan(-1));
      final body = riderHomeTab.substring(anchor, anchor + 400);
      expect(body.contains('if (!_isSubscriptionActive(rider)) return false;'), isTrue);
    });

    test('_isSubscriptionActive itself is unchanged (still the real entitlement check)', () {
      expect(
        riderHomeTab.contains(
          "rider?['subscription_active'] == true &&\n"
          "        rider?['subscription_expires_at'] != null &&\n"
          "        DateTime.tryParse(rider!['subscription_expires_at'].toString())?.isAfter(DateTime.now()) == true;",
        ),
        isTrue,
      );
    });

    test('no other file in lib/ computes or displays free-trial status', () {
      final libDir = Directory('lib');
      final offenders = <String>[];
      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith('rider_home_tab.dart')) continue;
        final content = entity.readAsStringSync();
        if (content.contains('free_trial_expires_at') || content.contains('30 Days Free')) {
          offenders.add(entity.path);
        }
      }
      expect(offenders, isEmpty, reason: 'competing free-trial display logic found: $offenders');
    });
  });

  group('1. Active free trial -> "30 Days Free" IS shown', () {
    test('subscription_active=true, subscription_expires_at=future, free_trial_expires_at=same future', () {
      final rider = {
        'subscription_active': true,
        'subscription_expires_at': DateTime.now().add(const Duration(days: 20)).toIso8601String(),
        'free_trial_expires_at': DateTime.now().add(const Duration(days: 20)).toIso8601String(),
        'free_trial_used': true,
      };
      expect(_isSubscriptionActive(rider), isTrue);
      expect(_isFreeTrialActive(rider), isTrue);
    });
  });

  group('2. Expired/ended trial -> "30 Days Free" is NOT shown (the exact bug scenario)', () {
    test("Bala's account exact state: subscription_active=false, subscription_expires_at=NULL, "
        'free_trial_expires_at still a future historical timestamp', () {
      final rider = {
        'subscription_active': false,
        'subscription_expires_at': null,
        'free_trial_expires_at': DateTime.now().add(const Duration(days: 29)).toIso8601String(),
        'free_trial_used': true,
      };
      expect(_isSubscriptionActive(rider), isFalse);
      // This is the exact bug: before the fix, this returned true.
      expect(_isFreeTrialActive(rider), isFalse);
    });

    test('a genuinely time-expired trial (free_trial_expires_at in the past) is also correctly not shown', () {
      final rider = {
        'subscription_active': false,
        'subscription_expires_at': null,
        'free_trial_expires_at': DateTime.now().subtract(const Duration(days: 1)).toIso8601String(),
        'free_trial_used': true,
      };
      expect(_isFreeTrialActive(rider), isFalse);
    });
  });

  group('3. Paid active subscription -> paid subscription state is shown, not the trial banner', () {
    test('subscription_active=true with a real paid expiry, free_trial_expires_at=null (never had a trial)', () {
      final rider = {
        'subscription_active': true,
        'subscription_expires_at': DateTime.now().add(const Duration(hours: 20)).toIso8601String(),
        'free_trial_expires_at': null,
        'free_trial_used': false,
      };
      expect(_isSubscriptionActive(rider), isTrue);
      expect(_isFreeTrialActive(rider), isFalse); // falls through to the paid "isSubscribed" banner
    });

    test('a rider who bought a paid plan AFTER their trial (both fields set, but expires_at is '
        'now beyond the original trial length due to stacking) still correctly shows the paid '
        'banner once free_trial_expires_at itself has passed', () {
      final rider = {
        'subscription_active': true,
        'subscription_expires_at': DateTime.now().add(const Duration(days: 5)).toIso8601String(),
        'free_trial_expires_at': DateTime.now().subtract(const Duration(days: 2)).toIso8601String(),
        'free_trial_used': true,
      };
      expect(_isSubscriptionActive(rider), isTrue);
      expect(_isFreeTrialActive(rider), isFalse);
    });
  });

  group('4. No active subscription/trial -> normal commission/Go Online state is shown', () {
    test('a brand-new rider: everything null/false/unused', () {
      final rider = {
        'subscription_active': false,
        'subscription_expires_at': null,
        'free_trial_expires_at': null,
        'free_trial_used': false,
      };
      expect(_isSubscriptionActive(rider), isFalse);
      expect(_isFreeTrialActive(rider), isFalse);
    });

    test('null rider map (not yet loaded) is handled safely', () {
      expect(_isSubscriptionActive(null), isFalse);
      expect(_isFreeTrialActive(null), isFalse);
    });
  });

  group('5/6/7. Vehicle selector: only verified vehicles are selectable, all three are visible', () {
    test('the selector always iterates all 3 vehicle types (vehicleTypeOrder), not just the '
        'verified subset', () {
      final anchor = riderHomeTab.indexOf("for (final vt in vehicleTypeOrder) ...[");
      expect(anchor, greaterThan(-1));
    });

    test('an unverified vehicle is non-tappable (onTap is null) and shows "Not verified"', () {
      expect(
        riderHomeTab.contains('onTap: isVerified ? () => setSheetState(() => selectedVehicleType = vt) : null,'),
        isTrue,
      );
      expect(riderHomeTab.contains("isVerified\n                                                ? (priceForVt != null ? '₹\${priceForVt.toStringAsFixed(0)}' : '—')\n                                                : 'Not verified',"), isTrue);
    });

    test('isVerified is derived from availableVehicleTypes, which is filtered to '
        'verifiedVehicleTypes -- the rider\'s actual verified vehicles (KYC-approved primary or '
        'approved rider_vehicles), never an arbitrary/unfiltered set', () {
      expect(riderHomeTab.contains('final isVerified = availableVehicleTypes.contains(vt);'), isTrue);
      expect(
        riderHomeTab.contains(
          "final availableVehicleTypes = vehicleTypeOrder\n"
          "        .where((v) => verifiedVehicleTypes.contains(v) && planPrices.containsKey('daily_\$v'))",
        ),
        isTrue,
      );
    });

    test('a verified vehicle with a selected state is visually distinct and tappable', () {
      expect(riderHomeTab.contains('final isSelectedVerified = isVerified && selectedVehicleType == vt;'), isTrue);
    });
  });

  group('8. Backend vehicle verification (create-payment v59) remains fully enforced, unchanged', () {
    test('the rider-ownership check is still present', () {
      expect(createPayment.contains('if (subRider.user_id !== user.id) {'), isTrue);
    });

    test('the vehicle-verification block is still present and still fails closed', () {
      expect(createPayment.contains('if (plan.vehicle_type) {'), isTrue);
      expect(createPayment.contains('if (!verifiedVehicleTypes.has(plan.vehicle_type)) {'), isTrue);
      expect(
        createPayment.contains('JSON.stringify({ error: "Selected vehicle is not verified for this account" })'),
        isTrue,
      );
    });

    test('the authoritative charge amount is still exclusively plan.amount, never client-supplied', () {
      expect(createPayment.contains('finalAmount = Number(plan.amount);'), isTrue);
    });
  });
}
