// Regression guard for PHASE 14 (WayDrop Rewards/Coupons) -- per-offer independent discount.
//
// REQUIREMENT: discount_type/discount_value must be authoritative on each individual
// reward_offers row. Two merchants in the same category (e.g. Restaurant A = 10%,
// Restaurant B = 15%) must be independently configurable, and a category-level default
// (reward_offer_categories.default_discount_type/value) may only ever be used as a
// creation-time convenience for a brand-new offer row -- never read again once an offer
// has its own value, and never overridden by an UPDATE.
//
// This guards against a future regression where someone "simplifies" the schema by making
// reward_offers.discount_value derive from its category (a generated column, a view, or a
// trigger that also fires on UPDATE) -- any of which would make same-category merchants
// share one discount and break admin's ability to edit one offer without affecting others.
//
// Structural guard (reads the real source as text), consistent with this repo's other
// regression tests.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read('supabase/migrations/20260902000000_waydrop_rewards_system.sql');
  final categoryOffersScreen = _read('lib/modules/rewards/screens/category_offers_screen.dart');
  final offerDetailScreen = _read('lib/modules/rewards/screens/offer_detail_screen.dart');

  group('reward_offers.discount_type/discount_value are per-row authoritative', () {
    test('reward_offers has its own plain NOT NULL discount_type/discount_value columns', () {
      expect(migration.contains("discount_type text NOT NULL CHECK (discount_type IN ('percentage', 'flat'))"), isTrue);
      expect(migration.contains('discount_value numeric NOT NULL CHECK (discount_value > 0)'), isTrue);
    });

    test('no GENERATED/computed column ties an offer discount back to its category', () {
      expect(migration.contains('GENERATED ALWAYS'), isFalse);
    });

    test('the category-default-fill trigger only ever fires BEFORE INSERT, never BEFORE UPDATE', () {
      final triggerBlock = migration.substring(migration.indexOf('CREATE TRIGGER fill_discount_default'));
      expect(triggerBlock.startsWith('CREATE TRIGGER fill_discount_default\nBEFORE INSERT ON public.reward_offers'), isTrue);
    });

    test('the fill-default function only writes when the incoming value is NULL (COALESCE), never unconditionally', () {
      final fnBlock = migration.substring(
        migration.indexOf('CREATE OR REPLACE FUNCTION public.fill_reward_offer_discount_default'),
        migration.indexOf('CREATE TRIGGER fill_discount_default'),
      );
      expect(fnBlock.contains('IF NEW.discount_type IS NULL OR NEW.discount_value IS NULL THEN'), isTrue);
      expect(fnBlock.contains('COALESCE(NEW.discount_type'), isTrue);
      expect(fnBlock.contains('COALESCE(NEW.discount_value'), isTrue);
    });
  });

  group('Rewards UI displays the exact per-offer discount, never a category default', () {
    test('category_offers_screen.dart formats the discount from the offer row itself', () {
      expect(categoryOffersScreen.contains("offer['discount_type']"), isTrue);
      expect(categoryOffersScreen.contains("offer['discount_value']"), isTrue);
      expect(categoryOffersScreen.contains('default_discount'), isFalse);
    });

    test('offer_detail_screen.dart formats the discount from the offer row itself', () {
      expect(offerDetailScreen.contains("offer['discount_type']"), isTrue);
      expect(offerDetailScreen.contains("offer['discount_value']"), isTrue);
      expect(offerDetailScreen.contains('default_discount'), isFalse);
    });
  });
}
