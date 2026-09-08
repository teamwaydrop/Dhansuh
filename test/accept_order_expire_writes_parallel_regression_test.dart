// Regression guard for the accept-order "expire other pending offers" parallelization
// (WayDrop Phase I performance pass).
//
// CONTEXT: after successfully accepting/upserting this rider's own assignment, accept-order
// expires every OTHER rider's still-pending ('sent') offer for the same order: one UPDATE on
// rider_assignments, one UPDATE on order_assignment_logs. These write to different tables, neither
// reads the other's result, and nothing downstream (the fare-breakdown RPC, the orders UPDATE)
// depends on either -- they previously ran back-to-back awaited serially. They now run concurrently
// via Promise.all, but both must still fully complete before the function continues, both writes
// must remain byte-for-byte identical, and neither result was (or is now) checked -- a failure in
// either must not block acceptance, exactly as before.
//
// Structural guard (reads the real source), matching the pattern used throughout this suite for
// Deno edge functions that can't run against a live Supabase instance in a plain unit test.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('accept-order -- expire-other-pending-offers writes run concurrently', () {
    final source = _read('supabase/functions/accept-order/index.ts');
    final blockStart = source.indexOf('await Promise.all([\n      supabase\n        .from("rider_assignments")');
    final blockEnd = source.indexOf('// UPDATE ORDER STATUS');
    final block = blockStart >= 0 && blockEnd > blockStart
        ? source.substring(blockStart, blockEnd)
        : '';

    test('both expiry UPDATEs are destructured from a single Promise.all', () {
      expect(blockStart, greaterThanOrEqualTo(0),
          reason: 'expected a single Promise.all wrapping both expiry writes');
      expect(block.contains('.from("rider_assignments")'), isTrue);
      expect(block.contains('.from("order_assignment_logs")'), isTrue);
    });

    test('the rider_assignments expiry write is unchanged: same fields, same filters', () {
      expect(block.contains('assignment_status: "expired"'), isTrue);
      expect(block.contains('response_type: "ignored"'), isTrue);
      expect(block.contains('last_response_at: now.toISOString()'), isTrue);
      // Appears once for rider_assignments and once for order_assignment_logs -- both filter sets
      // must still be present unchanged.
      expect('.neq("rider_id", rider_id)'.allMatches(block).length, 2);
      expect('.eq("assignment_status", "sent")'.allMatches(block).length, 2);
      expect('.eq("order_id", order_id)'.allMatches(block).length, 2);
    });

    test('the order_assignment_logs expiry write is unchanged: same fields', () {
      final logsIdx = block.indexOf('.from("order_assignment_logs")');
      expect(logsIdx, greaterThan(0));
      final logsBlock = block.substring(logsIdx);
      expect(logsBlock.contains('assignment_status: "expired"'), isTrue);
      expect(logsBlock.contains('responded_at: now.toISOString()'), isTrue);
    });

    test('neither write result is checked -- both remain fire-and-forget, exactly as before', () {
      expect(block.contains('.error'), isFalse,
          reason: 'a failure in either expiry write must not block acceptance, same as before '
              'parallelization');
      expect(block.contains('throw'), isFalse);
    });

    test('no unrelated operation (order/fare-breakdown writes) was pulled into this parallel '
        'block', () {
      expect(block.contains('calculate_fare_breakdown'), isFalse);
      expect(block.contains('.from("orders")'), isFalse);
    });

    test('this expiry block still runs strictly after the accepting rider\'s own assignment '
        'insert/update, and strictly before the order UPDATE (order of operations preserved)', () {
      final ownAssignmentIdx = source.indexOf('let finalAssignment = assignment;');
      final orderUpdateIdx = source.indexOf('.from("orders")\n      .update({\n        order_status: "accepted"');
      expect(ownAssignmentIdx, greaterThan(0));
      expect(orderUpdateIdx, greaterThan(0));
      expect(blockStart, greaterThan(ownAssignmentIdx));
      expect(blockStart, lessThan(orderUpdateIdx));
    });
  });
}
