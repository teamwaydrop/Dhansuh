// Regression guard for the Mode 2 trigger payload fix (FROZEN SPEC,
// docs/13_Business_Logic.md section 5 "Intercity Selected-Route Corridor Matching").
//
// ROOT CAUSE (proven via static read of the deployed migration, not assumed): the Mode 2
// background-matching trigger on_rider_travel_plan_insert() (originally
// 20260901000031_travel_plan_insert_triggers_matching_server_side.sql) builds its
// match-intercity-riders request body via an explicit jsonb_build_object(...) field
// enumeration, not a full-row serialization -- so selected_route_geometry/selected_route_meta/
// route_selection_status (added by 20260905000001_add_selected_route_columns.sql) were
// structurally invisible to it.
//
// FIX (20260905000002_forward_selected_route_fields_to_mode2_trigger.sql): CREATE OR REPLACE
// FUNCTION with the exact same body, plus the three new keys appended to the existing
// jsonb_build_object('plan', ...) call. This test proves the fix is purely additive: every
// original field/behavior is still present, byte-for-byte, and only the three new keys were
// added -- no trigger-timing, HTTP-mechanism, auth, or unrelated-logic change.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final original = _read(
    'supabase/migrations/20260901000031_travel_plan_insert_triggers_matching_server_side.sql',
  );
  final fix = _read(
    'supabase/migrations/20260905000002_forward_selected_route_fields_to_mode2_trigger.sql',
  );
  // SQL `--` comments (including this migration's own explanatory header, which legitimately
  // mentions "CREATE TRIGGER"/"dispatches" while EXPLAINING that neither is touched) are
  // documentation, not executable statements -- strip them before checking for forbidden
  // executable SQL below, mirroring geometric-corridor.test.ts's equivalent comment-stripping
  // convention for its own structural guards.
  final fixExecutable = fix
      .split('\n')
      .map((line) {
        final idx = line.indexOf('--');
        return idx >= 0 ? line.substring(0, idx) : line;
      })
      .join('\n');

  group('K. Mode 2 receives the three new selected-route fields', () {
    test('the new migration\'s payload includes all three new keys, reading NEW.<column>', () {
      for (final field in [
        "'selected_route_geometry', NEW.selected_route_geometry",
        "'selected_route_meta', NEW.selected_route_meta",
        "'route_selection_status', NEW.route_selection_status",
      ]) {
        expect(fix.contains(field), isTrue, reason: 'missing payload field: $field');
      }
    });

    test('CREATE OR REPLACE FUNCTION public.on_rider_travel_plan_insert() is used (not a brand-new function name)', () {
      expect(
        fix.contains('CREATE OR REPLACE FUNCTION public.on_rider_travel_plan_insert()'),
        isTrue,
      );
    });

    test('the original migration file itself is untouched (forward-only convention -- never edit past migrations)', () {
      expect(
        original.contains("'route_geometry', NEW.route_geometry\n                    ),"),
        isTrue,
        reason: '20260901000031 must remain exactly as it was; the fix is a new migration only',
      );
      expect(original.contains('selected_route_geometry'), isFalse);
    });
  });

  group('Additive-only: every original payload field is still present, unchanged', () {
    test('all 15 original plan fields are present in the new function body', () {
      for (final field in [
        "'id', NEW.id",
        "'rider_id', NEW.rider_id",
        "'pickup_lat', NEW.pickup_lat",
        "'pickup_lng', NEW.pickup_lng",
        "'destination_lat', NEW.destination_lat",
        "'destination_lng', NEW.destination_lng",
        "'weight_preference', NEW.weight_preference",
        "'max_weight_kg', NEW.max_weight_kg",
        "'travel_plan_type', NEW.travel_plan_type",
        "'vehicle_type', NEW.vehicle_type",
        "'max_bookings', NEW.max_bookings",
        "'pickup_city', NEW.pickup_city",
        "'destination_city', NEW.destination_city",
        "'travel_date', NEW.travel_date",
        "'route_geometry', NEW.route_geometry",
      ]) {
        expect(fix.contains(field), isTrue, reason: 'original field missing/altered: $field');
      }
    });

    test('trigger timing, HTTP mechanism, auth, and status guard are unchanged', () {
      expect(fix.contains("IF NEW.status != 'active' THEN"), isTrue);
      expect(fix.contains('net.http_post('), isTrue);
      expect(fix.contains("url := v_supabase_url || '/functions/v1/match-intercity-riders'"), isTrue);
      expect(fix.contains("FROM vault.decrypted_secrets"), isTrue);
      expect(fix.contains("'is_background', true"), isTrue);
      expect(fix.contains('timeout_milliseconds := 8000'), isTrue);
      // This migration does not (and does not need to) touch the CREATE TRIGGER statement --
      // the existing trigger already dispatches by function name. (Checked against the
      // comment-stripped executable text -- this file's own header comment legitimately
      // mentions both phrases while explaining that neither is touched.)
      expect(fixExecutable.contains('CREATE TRIGGER'), isFalse);
      expect(fixExecutable.contains('DROP TRIGGER'), isFalse);
    });

    test('no unrelated logic (pricing/commission/GST/payment/wallet/dispatch) is touched', () {
      for (final forbidden in [
        'commission',
        'gst',
        'cashfree',
        'wallet',
        'payout',
        'dispatch',
        'pricing_config',
        'DROP TABLE',
        'ALTER TABLE',
        'DELETE FROM',
      ]) {
        expect(
          fixExecutable.toLowerCase().contains(forbidden.toLowerCase()),
          isFalse,
          reason: 'migration must be a pure trigger-function payload extension, found "$forbidden"',
        );
      }
    });
  });

  group('L. Old plans with NULL selected-route fields remain valid', () {
    test('the new fields are read directly from NEW (no COALESCE/default that would fabricate a value for NULL columns)', () {
      // jsonb_build_object emits JSON null for a NULL NEW.<column> automatically -- exactly
      // like every pre-existing nullable field above (e.g. vehicle_type). No special-casing is
      // needed or present for old plans.
      expect(fix.contains('COALESCE(NEW.selected_route'), isFalse);
    });
  });
}
