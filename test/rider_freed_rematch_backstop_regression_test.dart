// Regression guard for Issue 1: "searching Ride B exists while Rider A is busy on Ride A -> Rider A
// becomes free -> Ride B is never offered to Rider A."
//
// Reproduced live on a real device/account pair against production (not simulated): Ride B was
// created while Rider A was busy and correctly rejected by the busy-rider guard (one
// order_assignment_logs row, zero rider_assignments rows). Rider A then completed Ride A -- the
// rider-freed trigger's WHEN clause condition was confirmed satisfied, and pg_net recorded a clean
// 204 response with no error/timeout. Every eligibility rule inside assign_nearby_searching_orders_
// core() was independently re-verified against the exact historical values (radius, service_mode,
// vehicle, staleness, tax-block, COD-block) and all passed. Yet zero rows were ever written to
// rider_assignments or order_assignment_logs for Rider A + Ride B, and Ride B was eventually
// cancelled unmatched. This isolates the failure to the single, un-retried, unobservable
// fire-and-forget net.http_post call in assign_nearby_searching_orders_on_rider_freed() -- a `204`
// only proves HTTP delivery, never proves the business operation (the match) actually happened.
//
// FIX (20260824000000_backstop_redispatch_freed_riders.sql): a pg_cron backstop,
// redispatch_freed_riders(), mirroring the already-proven redispatch_stalled_searching_orders
// pattern -- calls the SAME, unmodified assign_nearby_searching_orders_core() directly and
// synchronously (no HTTP/pg_net hop) for online riders who recently had an order updated and are
// not currently blocked by an active order. This is a reliability net alongside the existing async
// trigger, not a replacement for it, and duplicates none of its matching rules.
//
// This file is a structural regression guard (reads the real migration source, following the
// pattern already used throughout this test suite for backend correctness that can't run against a
// live Supabase instance in a plain unit test) -- it asserts the fix's key invariants can never
// silently regress.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('redispatch_freed_riders() backstop -- Issue 1 (rider-freed rematch reliability)', () {
    final migration = _read(
      'supabase/migrations/20260824000000_backstop_redispatch_freed_riders.sql',
    );

    test('the backstop function exists and is scheduled via pg_cron', () {
      expect(
        migration.contains('CREATE OR REPLACE FUNCTION public.redispatch_freed_riders()'),
        isTrue,
      );
      expect(
        migration.contains("cron.schedule(\n    'redispatch-freed-riders',"),
        isTrue,
        reason: 'the backstop must actually be scheduled, not just defined',
      );
    });

    test('busy-rider protection is preserved: candidates must have NO order in the blocking set '
        '(including payment_pending)', () {
      // This must stay byte-for-byte the same blocking set already used by
      // trigger_assign_nearby_orders_on_rider_freed's own WHEN clause and by
      // prevent_local_ride_assignment_to_busy_rider -- widening or narrowing it here would either
      // let a genuinely busy rider get offered a second ride, or stop freed riders from ever being
      // picked up by this backstop. payment_pending is included per the coordinated fix in
      // 20260825000000_payment_pending_busy_state_fix.sql -- a rider awaiting payment confirmation
      // is still busy and must never be a rematch candidate.
      final blockingSetShape = RegExp(
        r"NOT EXISTS\s*\(\s*"
        r"-- busy-rider protection[\s\S]*?"
        r"SELECT 1 FROM public\.orders bo\s*"
        r"WHERE bo\.rider_id = r\.id\s*"
        r"AND bo\.order_status IN \(\s*'accepted',\s*'rider_arrived',\s*'picked_up',\s*'ongoing',\s*'payment_pending'\s*\)",
      );
      expect(
        blockingSetShape.hasMatch(migration),
        isTrue,
        reason: 'a busy rider (accepted/rider_arrived/picked_up/ongoing/payment_pending) must '
            'never be a candidate for this backstop',
      );
    });

    test('only online riders with a known location are considered', () {
      expect(migration.contains("r.account_status = 'online'"), isTrue);
      expect(migration.contains('r.current_lat IS NOT NULL'), isTrue);
      expect(migration.contains('r.current_lng IS NOT NULL'), isTrue);
    });

    test('the scan is bounded to recently-touched riders, not the full online fleet', () {
      // This is what keeps the backstop from reintroducing the O(all online riders) rescan-per-
      // tick problem that 20260806000002 deliberately eliminated -- it must only ever consider
      // riders who plausibly just became free, not every online rider on every tick.
      expect(
        migration.contains("o.updated_at >= NOW() - INTERVAL '5 minutes'"),
        isTrue,
        reason: 'candidate set must stay bounded to recently-updated riders',
      );
    });

    test('the backstop reuses assign_nearby_searching_orders_core() as-is -- no duplicated or '
        'diverging matching rules', () {
      expect(
        migration.contains('PERFORM public.assign_nearby_searching_orders_core('),
        isTrue,
        reason: 'radius/service-mode/vehicle/weight matching, tax-due and COD-limit gating, '
            'assignment uniqueness, and expires_at must all come from the single existing core '
            'function, never a reimplementation',
      );
    });

    test('the original async trigger is left untouched by this fix', () {
      final freedTriggerAsyncBody = _read(
        'supabase/migrations/20260809000001_async_rider_freed_rematch.sql',
      );
      // The backstop is additive; it must not modify, replace, or remove the existing async path.
      expect(
        freedTriggerAsyncBody.contains(
          "url := v_supabase_url || '/rest/v1/rpc/assign_nearby_searching_orders_core'",
        ),
        isTrue,
      );
    });
  });
}
