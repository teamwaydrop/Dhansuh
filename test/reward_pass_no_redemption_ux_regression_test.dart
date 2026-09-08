// Regression guard for PHASE 14 -- WayDrop Rewards is a poster/pass UX, NOT a
// coupon-code-redemption system.
//
// BUSINESS RULE: the customer shows a "WayDrop Rewards Pass" screen to merchant staff,
// who manually apply the discount. There is no in-app redeem/verify/scan action, and the
// coupon_code field (kept in the schema for future extensibility) is not part of this
// UX -- it must never be the main interaction, and no code-entry control may exist.
//
// Structural guard (reads the real source as text), consistent with this repo's other
// regression tests.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// Strips `//`/`///` line comments so substring checks below assert on actual code
/// (widget text, method calls) rather than doc comments that describe what's absent.
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
  final rewardsScreen = _read('lib/modules/rewards/screens/rewards_screen.dart');
  final categoryOffersScreen = _read('lib/modules/rewards/screens/category_offers_screen.dart');
  final offerDetailScreen = _read('lib/modules/rewards/screens/offer_detail_screen.dart');
  // Since the Phase 14 activation flow was added, offer_detail_screen.dart is the
  // pre-activation confirmation/detail screen and active_pass_screen.dart is the live,
  // post-activation "WayDrop Rewards Pass" -- see reward_activation_single_use_pass_regression_test.dart
  // for the full activation-flow guard set.
  final activePassScreen = _read('lib/modules/rewards/screens/active_pass_screen.dart');

  group('Merchant list -> confirmation -> pass flow', () {
    test('rewards_screen.dart navigates into CategoryOffersScreen per category (Restaurants/Shopping Malls list entry points)', () {
      expect(rewardsScreen.contains('CategoryOffersScreen('), isTrue);
    });

    test('category_offers_screen.dart fetches offers scoped to the selected category only', () {
      expect(categoryOffersScreen.contains('RewardService.fetchOffersForCategory(widget.categoryId)'), isTrue);
    });

    test('selecting a merchant card navigates to OfferDetailScreen (the confirmation/detail screen)', () {
      expect(categoryOffersScreen.contains('OfferDetailScreen('), isTrue);
    });

    test('the live pass screen (post-activation) is titled as a WayDrop Rewards Pass, not a generic coupon/offer redemption page', () {
      expect(activePassScreen.contains('WayDrop Rewards Pass'), isTrue);
    });
  });

  group('No coupon-code redemption interaction anywhere in the Rewards UI', () {
    test('offer_detail_screen.dart never reads or displays offer[\'coupon_code\']', () {
      expect(_codeOnly(offerDetailScreen).contains("coupon_code"), isFalse);
    });

    test('category_offers_screen.dart never reads or displays offer[\'coupon_code\']', () {
      expect(_codeOnly(categoryOffersScreen).contains("coupon_code"), isFalse);
    });

    test('no Redeem/Verify/Scan action exists anywhere in the Rewards UI (code, not comments)', () {
      for (final source in [rewardsScreen, categoryOffersScreen, offerDetailScreen, activePassScreen]) {
        final code = _codeOnly(source).toLowerCase();
        expect(code.contains('redeem'), isFalse);
        expect(code.contains('verify'), isFalse);
        expect(code.contains('scan'), isFalse);
        expect(code.contains('qr'), isFalse);
      }
    });

    test('the live pass screen carries the required customer-facing instruction sentence', () {
      expect(activePassScreen.contains('Show this screen at the merchant to claim your WayDrop discount.'), isTrue);
    });
  });

  group('Displayed discount is always the selected offer\'s own value', () {
    test('offer_detail_screen.dart formats the discount from the offer row itself, not a category default', () {
      expect(offerDetailScreen.contains("offer['discount_type']"), isTrue);
      expect(offerDetailScreen.contains("offer['discount_value']"), isTrue);
      expect(offerDetailScreen.contains('default_discount'), isFalse);
    });
  });
}
