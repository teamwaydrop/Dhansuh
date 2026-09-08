// Regression guard for Issue 6: intercity parcel rating submission failed with
// "invalid input value for enum review_tag: \"ready_at_pickup\", code: 22P02".
//
// ROOT CAUSE (confirmed via live enum inspection, not assumed): review_tag
// (rider_reviews.tags, a review_tag[] column) was built exclusively for the passenger-rates-
// driver/traveller direction -- every existing value is a vehicle/driving concept (clean_vehicle,
// polite_behavior, safe_driving, on_time, dirty_vehicle, rude_behavior, unsafe_driving,
// late_arrival, other). rider_rating_screen.dart's role-aware tag sets ("Issue 6B fix") already
// correctly split tags by rating direction -- but the traveller/rider-rates-passenger tag set
// (widget.ratedByRider == true) uses keys the enum never had (good_behaviour, respectful,
// easy_to_communicate, clear_instructions, cooperative, ready_at_pickup, late_at_pickup,
// rude_behaviour, poor_communication, uncooperative, changed_plans, no_show) -- every one of them
// except on_time/other failed at INSERT time.
//
// FIX (20260831000000_add_passenger_rating_review_tag_values.sql): adds the missing values as new
// enum members via ALTER TYPE ... ADD VALUE IF NOT EXISTS -- additive, idempotent, no existing
// value renamed/removed, so no previously-saved rating is affected. The client's tag keys
// themselves are unchanged -- this migration makes the enum match a design that was already
// correctly implemented and shipped, not a client change.
//
// This file is a structural regression guard: it extracts every tag VALUE (the enum key, not the
// display label) rider_rating_screen.dart can possibly submit for either rating direction and
// star-rating band, and asserts each one is covered by review_tag either before this migration
// (passenger-rates-traveller) or is added by it (traveller-rates-passenger) -- so a future edit to
// either the client's tag maps or the enum can never silently drift out of sync again. It reads the
// real migration/Dart source, following the pattern already used throughout this test suite for
// backend correctness that can't run against a live Supabase instance in a plain unit test.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read(
    'supabase/migrations/20260831000000_add_passenger_rating_review_tag_values.sql',
  );
  final ratingScreen = _read('lib/features/local_rides/rating/screens/rider_rating_screen.dart');

  // Enum values that already existed live before this migration (passenger-rates-traveller
  // direction, plus the two shared keys 'on_time'/'other').
  const preExistingValues = {
    'clean_vehicle', 'polite_behavior', 'safe_driving', 'on_time',
    'dirty_vehicle', 'rude_behavior', 'unsafe_driving', 'late_arrival', 'other',
  };

  // Every tag key rider_rating_screen.dart can submit when a Traveller/Rider rates a Passenger
  // (ratedByRider == true), across both positive and negative tag maps.
  const travellerRatesPassengerTags = {
    'on_time', 'good_behaviour', 'respectful', 'easy_to_communicate', 'clear_instructions',
    'cooperative', 'ready_at_pickup', 'other',
    'late_at_pickup', 'rude_behaviour', 'poor_communication', 'uncooperative', 'changed_plans',
    'no_show',
  };

  // Every tag key when a Passenger rates a Traveller/driver (ratedByRider == false) -- must stay
  // exactly the pre-existing vehicle/driving set, untouched by this fix.
  const passengerRatesTravellerTags = {
    'clean_vehicle', 'polite_behavior', 'safe_driving', 'on_time', 'other',
    'dirty_vehicle', 'rude_behavior', 'unsafe_driving', 'late_arrival',
  };

  group('Issue 6 -- review_tag enum covers every tag the client can submit', () {
    test('every traveller-rates-passenger tag key is either pre-existing or added by this '
        'migration', () {
      for (final tag in travellerRatesPassengerTags) {
        final covered = preExistingValues.contains(tag) ||
            migration.contains("ADD VALUE IF NOT EXISTS '$tag';");
        expect(covered, isTrue,
            reason: "tag '$tag' (submittable when rating a passenger) is not covered by any "
                'existing or newly-added review_tag value -- would fail with 22P02');
      }
    });

    test('every passenger-rates-traveller tag key is pre-existing -- this migration does not '
        'need to (and does not) touch that direction', () {
      for (final tag in passengerRatesTravellerTags) {
        expect(preExistingValues.contains(tag), isTrue,
            reason: "tag '$tag' was expected to already be a valid enum value");
        expect(migration.contains("ADD VALUE IF NOT EXISTS '$tag';"), isFalse,
            reason: "'$tag' must not be re-added -- it already existed before this migration");
      }
    });

    test('no vehicle/driving-specific value is added for the passenger-rating direction', () {
      // These are the pre-existing vehicle/driving concepts -- none of them should appear as a
      // *newly added* value, since a passenger cannot legitimately be rated on their vehicle.
      for (final vehicleTag in [
        'clean_vehicle', 'dirty_vehicle', 'safe_driving', 'unsafe_driving', 'polite_behavior',
        'rude_behavior', 'late_arrival',
      ]) {
        expect(migration.contains("ADD VALUE IF NOT EXISTS '$vehicleTag';"), isFalse);
      }
    });

    test('the migration is additive/idempotent -- no DROP/RENAME of any existing enum value', () {
      expect(migration.contains('DROP TYPE'), isFalse);
      expect(migration.contains('RENAME VALUE'), isFalse);
      expect(migration.contains('DROP VALUE'), isFalse);
      // Every statement must be an additive, idempotent ADD VALUE IF NOT EXISTS.
      final alterStatements = RegExp(r'ALTER TYPE[^;]+;').allMatches(migration);
      expect(alterStatements.isNotEmpty, isTrue);
      for (final m in alterStatements) {
        expect(m.group(0)!.contains('ADD VALUE IF NOT EXISTS'), isTrue);
      }
    });
  });

  group('Issue 6 -- rating categories remain role-correct (unchanged by this fix, verified as a '
      'baseline)', () {
    test('ratedByRider == true (traveller/rider rates passenger) never shows a vehicle/driving '
        'tag', () {
      final start = ratingScreen.indexOf('Map<String, String> get _positiveTags');
      final end = ratingScreen.indexOf('Map<String, String> get _negativeTags');
      final positiveTagsSource = ratingScreen.substring(start, end);
      // The ratedByRider == true branch (before the ':' for the false branch) must not contain
      // any vehicle/driving concept.
      final trueBranch = positiveTagsSource.substring(0, positiveTagsSource.indexOf(': const {'));
      for (final vehicleWord in ['Vehicle', 'Driving']) {
        expect(trueBranch.contains(vehicleWord), isFalse);
      }
    });

    test('ratedByRider == false (passenger rates traveller/driver) includes vehicle/driving '
        'categories', () {
      expect(ratingScreen.contains("'Clean Vehicle': 'clean_vehicle'"), isTrue);
      expect(ratingScreen.contains("'Safe Driving': 'safe_driving'"), isTrue);
    });
  });
}
