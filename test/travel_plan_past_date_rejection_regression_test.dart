// Regression guard for Issue 3: a Traveller could post an intercity travel plan for a date/time
// already in the past (real example: current time 8:30 PM, plan created for 8:10 PM).
//
// ROOT CAUSE: post_travel_plan_screen.dart creates the plan via a direct client-side
// `supabase.from('rider_travel_plans').insert(...)` -- there is no edge function/RPC in this path.
// The date picker's `firstDate: DateTime.now()` only restricts the DATE, not the TIME, and nothing
// validated the combined date+time before submission. rider_travel_plans also had no DB-level
// constraint/trigger on travel_date.
//
// FIX (two layers, verified independently):
//   1. Client: _submitTravelPlan() now rejects (SnackBar, no insert attempted) whenever
//      `!selectedDate.isAfter(DateTime.now())`.
//   2. Database (20260901000027_reject_past_travel_plan_date.sql): a BEFORE INSERT trigger on
//      rider_travel_plans raises an exception whenever `NEW.travel_date <= NOW()`. PROVEN via real
//      execution against a local Supabase/Docker instance:
//        - travel_date = NOW() - 20 minutes  -> rejected (ERROR raised)
//        - travel_date = NOW() (exact)       -> rejected (ERROR raised)
//        - travel_date = NOW() + 1 minute    -> inserted successfully
//        - travel_date = NOW() + 1 day       -> inserted successfully
//        - travel_date = NOW() - 1 day       -> rejected (ERROR raised)
//      All five match the issue's own required edge-case table exactly, with the DB acting on
//      absolute timestamptz instants -- no new timezone model, using the same `.toUtc()` value the
//      client already sends.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final screen = _read('lib/features/rider/travel_plans/screens/post_travel_plan_screen.dart');
  final migration = _read('supabase/migrations/20260901000027_reject_past_travel_plan_date.sql');

  group('1. Client-side guard rejects a non-future travel_date before ever attempting the insert', () {
    test('_submitTravelPlan() checks !selectedDate.isAfter(DateTime.now()) and returns before '
        'setState(() => submitting = true) / the rider_travel_plans insert', () {
      expect(screen.contains('if (!selectedDate.isAfter(DateTime.now())) {'), isTrue);
      final guardIdx = screen.indexOf('if (!selectedDate.isAfter(DateTime.now())) {');
      final submittingIdx = screen.indexOf('setState(() => submitting = true);');
      final insertIdx = screen.indexOf("await supabase.from('rider_travel_plans').insert(");
      expect(guardIdx, greaterThan(-1));
      expect(submittingIdx, greaterThan(guardIdx));
      expect(insertIdx, greaterThan(guardIdx));
    });

    test('the date picker still restricts firstDate to today (unchanged) -- an earlier CALENDAR '
        'date can never even be picked, independent of the new time-of-day guard', () {
      expect(screen.contains('firstDate: DateTime.now(),'), isTrue);
    });
  });

  group('2. THE FIX: database-level trigger rejects a non-future travel_date regardless of client '
      'behaviour', () {
    test('reject_past_travel_plan_date() raises an exception whenever NEW.travel_date <= NOW()', () {
      expect(migration.contains('IF NEW.travel_date <= NOW() THEN'), isTrue);
      expect(migration.contains("RAISE EXCEPTION 'Travel plan date/time must be in the future'"), isTrue);
    });

    test('the trigger fires BEFORE INSERT on rider_travel_plans (not UPDATE -- no existing code '
        'path ever changes travel_date after creation, so this cannot block any other write)', () {
      expect(migration.contains('BEFORE INSERT ON public.rider_travel_plans'), isTrue);
      expect(migration.contains('BEFORE UPDATE'), isFalse);
    });
  });
}
