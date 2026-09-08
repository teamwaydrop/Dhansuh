// Regression guard for the two production ride-chat bugs:
//   1. Sent/received message alignment must key off sender identity (sender_id ==
//      currentAuthenticatedUserId), never off role/sender_type.
//   2. Chat must stay strictly scoped to a single order -- fetch, realtime subscription,
//      disposal, and the RLS policies that back them.
//
// isChatMessageMine / mergeSentMessage are pure functions extracted from
// lib/modules/chat/screens/order_chat_screen.dart, so alignment and dedup logic are exercised
// directly here. The remaining scenarios (query/subscription scoping, disposal, RLS) can't run
// against a live Supabase instance in a unit test, so they're verified as structural assertions
// against the real source, following the pattern already used by
// test/payment_flow_regression_test.dart -- a future edit that removes the order_id filter, the
// dispose() cleanup, or the RLS fix fails this file immediately.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/modules/chat/screens/order_chat_screen.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('isChatMessageMine (Bug 1: alignment)', () {
    const passengerId = 'passenger-uuid';
    const driverId = 'driver-uuid';

    test('passenger\'s own message is mine on the passenger screen', () {
      final msg = {'sender_id': passengerId, 'sender_type': 'user', 'message': 'Where are you?'};
      expect(isChatMessageMine(msg, passengerId), isTrue);
    });

    test('driver\'s message is NOT mine on the passenger screen (must render LEFT)', () {
      final msg = {'sender_id': driverId, 'sender_type': 'rider', 'message': 'Coming in 2 mins'};
      expect(isChatMessageMine(msg, passengerId), isFalse);
    });

    test('driver\'s own message is mine on the driver screen', () {
      final msg = {'sender_id': driverId, 'sender_type': 'rider', 'message': 'Coming in 2 mins'};
      expect(isChatMessageMine(msg, driverId), isTrue);
    });

    test('passenger\'s message is NOT mine on the driver screen (must render LEFT)', () {
      final msg = {'sender_id': passengerId, 'sender_type': 'user', 'message': 'Where are you?'};
      expect(isChatMessageMine(msg, driverId), isFalse);
    });

    test('sender_type/role is never consulted -- identical role on both sides does not flip alignment', () {
      // Reproduces the exact old bug shape: two 'user'-role participants (e.g. admin support
      // session) must still be told apart by sender_id, not by matching sender_type.
      final ownMessage = {'sender_id': passengerId, 'sender_type': 'user', 'message': 'a'};
      final otherMessage = {'sender_id': 'other-user-uuid', 'sender_type': 'user', 'message': 'b'};
      expect(isChatMessageMine(ownMessage, passengerId), isTrue);
      expect(isChatMessageMine(otherMessage, passengerId), isFalse);
    });

    test('a newly received realtime message for the other participant is never mistaken for local/own', () {
      final incomingFromDriver = {'sender_id': driverId, 'sender_type': 'rider', 'message': 'Hi'};
      expect(isChatMessageMine(incomingFromDriver, passengerId), isFalse);
    });

    test('no current user id (not yet authenticated) never renders as mine', () {
      final msg = {'sender_id': passengerId, 'sender_type': 'user', 'message': 'x'};
      expect(isChatMessageMine(msg, null), isFalse);
    });
  });

  group('mergeSentMessage (duplicate-message prevention)', () {
    test('replaces the optimistic temp entry with the confirmed row on the normal path', () {
      final messages = [
        {'id': 'temp_1', 'message': 'hello', 'sender_id': 'p1'},
      ];
      final inserted = {'id': 'real-uuid-1', 'message': 'hello', 'sender_id': 'p1'};
      final result = mergeSentMessage(messages, 'temp_1', inserted);
      expect(result.length, 1);
      expect(result.first['id'], 'real-uuid-1');
    });

    test('drops the temp entry instead of duplicating when realtime already delivered the same row', () {
      // Simulates the race: the websocket push landed and appended the real row before this
      // client's own insert() REST call resolved.
      final messages = [
        {'id': 'temp_1', 'message': 'hello', 'sender_id': 'p1'},
        {'id': 'real-uuid-1', 'message': 'hello', 'sender_id': 'p1'},
      ];
      final inserted = {'id': 'real-uuid-1', 'message': 'hello', 'sender_id': 'p1'};
      final result = mergeSentMessage(messages, 'temp_1', inserted);
      expect(result.length, 1, reason: 'must not produce a duplicate bubble for the same message');
      expect(result.first['id'], 'real-uuid-1');
    });

    test('leaves other messages in the list untouched', () {
      final messages = [
        {'id': 'm0', 'message': 'earlier message', 'sender_id': 'driver'},
        {'id': 'temp_1', 'message': 'hello', 'sender_id': 'p1'},
      ];
      final inserted = {'id': 'real-uuid-1', 'message': 'hello', 'sender_id': 'p1'};
      final result = mergeSentMessage(messages, 'temp_1', inserted);
      expect(result.length, 2);
      expect(result[0]['id'], 'm0');
      expect(result[1]['id'], 'real-uuid-1');
    });
  });

  group('order_chat_screen.dart structural guards (Bug 2: ride isolation)', () {
    final source = _read('lib/modules/chat/screens/order_chat_screen.dart');

    test('non-support message fetch filters by the current order id', () {
      expect(source.contains("query = query.eq('order_id', widget.orderId);"), isTrue);
    });

    test('realtime subscription filter is scoped to the current order id', () {
      expect(source.contains("column: 'order_id',"), isTrue);
      expect(source.contains('value: widget.orderId,'), isTrue);
    });

    test('realtime channel name is unique per order (no cross-order channel collisions)', () {
      expect(source.contains("'order-chat-\${widget.orderId}-\${widget.riderId}'"), isTrue);
    });

    test('dispose() removes the chat realtime channel', () {
      final disposeSection = source.substring(source.indexOf('void dispose()'), source.indexOf('void dispose()') + 600);
      expect(disposeSection.contains('supabase.removeChannel(_chatChannel!)'), isTrue);
      expect(disposeSection.contains('_chatChannel = null'), isTrue);
    });

    test('offline queue key is scoped by order id + rider id, not just participant ids', () {
      expect(
        source.contains("'offline_chat_messages_\${widget.orderId}_\${widget.riderId ?? \"\"}'"),
        isTrue,
      );
    });

    test('sending is blocked once the ride has completed or been cancelled', () {
      expect(source.contains("status == 'completed' || status == 'cancelled'"), isTrue);
      expect(source.contains('if (_isRideEnded) return;'), isTrue);
    });

    test('completed/cancelled history is retained, not deleted, by this screen', () {
      expect(source.contains(".from('order_chat_messages').delete("), isFalse);
    });
  });

  group('RLS migration structural guards (Bug 2: database-level order isolation)', () {
    final fullFile = _read(
      'supabase/migrations/20260726000000_fix_chat_message_rider_assignment_order_scope.sql',
    );
    // Only the executable SQL, not the header comment explaining the historical bug (which
    // necessarily quotes the buggy expression by name).
    final migration = fullFile.substring(fullFile.indexOf('DROP POLICY IF EXISTS'));

    test('rider_assignments subquery no longer contains the self-referential tautology', () {
      expect(migration.contains('ra.order_id = ra.order_id'), isFalse);
      expect(migration.contains('WHERE ra.order_id = order_chat_messages.order_id'), isTrue);
    });

    test('INSERT policy no longer carries a bare sender_id/user_id bypass for order-scoped rows', () {
      final insertPolicyStart = migration.indexOf('FOR INSERT TO authenticated');
      final orderNotNullIdx = migration.indexOf('order_id IS NOT NULL', insertPolicyStart);
      final beforeParticipantCheck = migration.substring(insertPolicyStart, orderNotNullIdx);
      expect(beforeParticipantCheck.contains('sender_id = auth.uid()'), isFalse);
      expect(beforeParticipantCheck.contains('user_id = auth.uid()'), isFalse);
    });
  });
}
