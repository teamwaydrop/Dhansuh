// Regression guard for Issue 3: the intercity chat image/attachment button could send an image
// before the traveller accepted the Travel Together request, even though the text field was
// already correctly disabled.
//
// ROOT CAUSE (confirmed via live RLS inspection, not assumed): the "Allow chat participants to
// send messages" INSERT policy on order_chat_messages never checked intercity_requests.status at
// all -- messaging was only blocked client-side, by _sendMessage()'s existing "Issue 6A fix"
// pre-acceptance guard. That guard was never applied to _handleImageAction() at all, so the image
// button stayed fully tappable and would insert a real order_chat_messages row regardless of
// request status. Because the DB-level policy had no status check, even the text guard was only
// client-side, not backend-enforced -- a direct API call could bypass it entirely.
//
// FIX:
//   1. lib/modules/chat/screens/order_chat_screen.dart -- _handleImageAction() now runs the exact
//      same pre-acceptance check and clean SnackBar as _sendMessage() before ever opening the
//      image picker or attempting an insert.
//   2. supabase/migrations/20260828000000_block_chat_before_intercity_request_acceptance.sql -- a
//      BEFORE INSERT trigger on order_chat_messages rejects ANY message (text or image, any
//      client) tied to a still-'request_sent' intercity request, with a clean RAISE EXCEPTION
//      message Postgrest surfaces directly (never a raw 42501/RLS denial). Admin/support senders
//      are exempt, matching the existing RLS policy. Orders with no intercity_requests row
//      (local rides/parcels, and intercity chats past request-sent) are unaffected.
//
// This file is a structural regression guard (reads the real migration/Dart source, following the
// pattern already used throughout this test suite for backend correctness that can't run against a
// live Supabase instance in a plain unit test).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final chatScreen = _read('lib/modules/chat/screens/order_chat_screen.dart');
  final migration = _read(
    'supabase/migrations/20260828000000_block_chat_before_intercity_request_acceptance.sql',
  );

  group('Issue 3 -- text pre-acceptance guard (pre-existing, "Issue 6A fix")', () {
    test('_sendMessage() blocks sending while intercity_requests.status == request_sent', () {
      final start = chatScreen.indexOf('Future<void> _sendMessage() async {');
      expect(start, greaterThan(-1));
      final body = chatScreen.substring(start, start + 1200);
      expect(
        body.contains("_intercityRequest!['status'] == 'request_sent'"),
        isTrue,
      );
      expect(body.contains('return;'), isTrue);
    });
  });

  group('Issue 3 -- image pre-acceptance guard (the fix)', () {
    test('_handleImageAction() now runs the identical pre-acceptance check before doing anything',
        () {
      final start = chatScreen.indexOf('Future<void> _handleImageAction() async {');
      expect(start, greaterThan(-1));
      final end = chatScreen.indexOf('try {', start);
      final guardBody = chatScreen.substring(start, end);
      expect(
        guardBody.contains("_intercityRequest!['status'] == 'request_sent'"),
        isTrue,
        reason: 'the image button must be gated by the same condition as the text field, checked '
            'before the image picker or any DB write is attempted',
      );
      expect(
        guardBody.contains('showAppSnackBar('),
        isTrue,
        reason: 'must show the same clean, role-aware message as the text-send guard, never a '
            'raw error',
      );
      expect(guardBody.contains('return;'), isTrue);
    });

    test('the pre-acceptance guard runs before the image picker is ever opened', () {
      final start = chatScreen.indexOf('Future<void> _handleImageAction() async {');
      final guardIndex = chatScreen.indexOf("_intercityRequest!['status'] == 'request_sent'", start);
      final pickerIndex = chatScreen.indexOf('picker.pickImage(', start);
      expect(guardIndex, greaterThan(-1));
      expect(pickerIndex, greaterThan(-1));
      expect(guardIndex, lessThan(pickerIndex),
          reason: 'must check acceptance status before ever invoking the gallery picker, not '
              'just before the database insert');
    });
  });

  group('Issue 3 -- backend enforcement (defense-in-depth, closes the RLS gap)', () {
    test('a BEFORE INSERT trigger rejects any message tied to a still request_sent intercity '
        'request', () {
      expect(
        migration.contains('BEFORE INSERT ON public.order_chat_messages'),
        isTrue,
      );
      expect(
        migration.contains(
          "SELECT 1 FROM public.intercity_requests ir\n        WHERE ir.parcel_id = NEW.order_id\n          AND ir.status = 'request_sent'",
        ),
        isTrue,
      );
    });

    test('the rejection is a clean RAISE EXCEPTION message, never a bare RLS/42501 surface', () {
      expect(
        migration.contains(
          "RAISE EXCEPTION 'You can send messages after the request is accepted.';",
        ),
        isTrue,
        reason: 'Postgrest surfaces a RAISE EXCEPTION message directly in the error response -- '
            'this is what keeps the user from ever seeing 42501/PostgrestException/RLS text',
      );
    });

    test('admin/support senders are exempt, matching the existing RLS policy carve-out', () {
      expect(
        migration.contains("role IN ('admin', 'support')"),
        isTrue,
      );
    });

    test('local ride/parcel chats and non-intercity messages are unaffected (no matching '
        'intercity_requests row means the guard is a no-op)', () {
      expect(
        migration.contains('IF NEW.order_id IS NULL THEN\n        RETURN NEW;'),
        isTrue,
        reason: 'support/admin chats with no order_id must never be blocked',
      );
    });

    test('existing RLS policies on order_chat_messages are not modified by this migration', () {
      expect(migration.contains('DROP POLICY'), isFalse);
      expect(migration.contains('CREATE POLICY'), isFalse);
      expect(migration.contains('ALTER POLICY'), isFalse);
    });
  });
}
