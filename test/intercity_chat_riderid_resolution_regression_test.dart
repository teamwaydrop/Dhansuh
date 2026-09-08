// Regression guard for PHASE 3, Issue 3: a raw RLS 42501 PostgrestException must never reach the
// user; before acceptance, sending must show a clean informational message instead.
//
// ROOT CAUSE: order_chat_screen.dart's _loadIntercityRequest() returned immediately whenever
// widget.riderId was null -- a real, reachable path (chat_message/generic intercity_request
// notification payloads never carry a rider id; orders.rider_id stays null pre-acceptance). This
// silently disabled the "before accepted" guard AND left rider_id out of the message insert, so
// RLS's participant check failed with a raw 42501 that reached the user verbatim. RLS itself
// (participation-only, no status check) is correct and untouched.
//
// FIX: self-resolve the traveller's own rider id via intercity_requests when widget.riderId is
// null, so the guard activates and the insert is RLS-satisfiable; plus a defense-in-depth
// sanitizer in the send catch block for PostgrestException code 42501 specifically.
//
// Structural guard (reads the real source), matching the pattern used throughout this suite.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final source = _read('lib/modules/chat/screens/order_chat_screen.dart');

  group('_loadIntercityRequest self-resolves riderId instead of giving up', () {
    final start = source.indexOf('Future<void> _loadIntercityRequest() async {');
    final end = source.indexOf('void _subscribeRequestUpdates() {');
    final body = source.substring(start, end);

    test('no longer early-returns just because widget.riderId is null', () {
      expect(body.contains('if (widget.orderId.isEmpty || widget.riderId == null'), isFalse);
      expect(body.contains('if (widget.orderId.isEmpty || widget.isSupport) return;'), isTrue);
    });

    test('falls back to _resolveTravellerIdForIntercityChat() when riderId is null', () {
      expect(body.contains('travellerId = await _resolveTravellerIdForIntercityChat();'), isTrue);
    });

    test('_resolveTravellerIdForIntercityChat exists and covers both the rider-mode and '
        'passenger-mode lookups', () {
      expect(source.contains('Future<String?> _resolveTravellerIdForIntercityChat() async {'), isTrue);
      final resolveStart = source.indexOf('Future<String?> _resolveTravellerIdForIntercityChat() async {');
      final resolveEnd = source.indexOf('void _subscribeRequestUpdates() {');
      final resolveBody = source.substring(resolveStart, resolveEnd);
      expect(resolveBody.contains("from('riders').select('id').eq('user_id', currentUserId)"), isTrue);
      expect(resolveBody.contains("eq('sender_id', currentUserId)"), isTrue);
    });
  });

  group('_sendMessage() uses the resolved rider id, both for the guard and the insert', () {
    test('insertData rider_id uses _effectiveRiderId (widget.riderId ?? _resolvedRiderId), not '
        'widget.riderId directly', () {
      final sendStart = source.indexOf('Future<void> _sendMessage() async {');
      final sendGuardEnd = source.indexOf('final text = _messageController.text.trim();', sendStart);
      final insertStart = source.indexOf("insertData['rider_id'] = _effectiveRiderId!;", sendGuardEnd);
      expect(insertStart, greaterThanOrEqualTo(0));
      expect(source.contains('String? get _effectiveRiderId => widget.riderId ?? _resolvedRiderId;'), isTrue);
    });

    test('the pre-acceptance guard is unchanged (still info-style, not a red error)', () {
      expect(
        source.contains("_intercityRequest != null && _intercityRequest!['status'] == 'request_sent'"),
        isTrue,
      );
      expect(source.contains('type: SnackBarType.info,'), isTrue);
    });
  });

  group('defense-in-depth: a raw 42501 RLS denial is sanitized, never shown verbatim', () {
    test('the send catch block detects PostgrestException code 42501 and shows a friendly '
        'message instead of the raw exception', () {
      final catchStart = source.indexOf("debugPrint('SEND MESSAGE ERROR => \$e');");
      final catchEnd = source.indexOf('void _scrollToBottom() {', catchStart);
      final catchBody = source.substring(catchStart, catchEnd);

      expect(catchBody.contains("e is PostgrestException && e.code == '42501'"), isTrue);
      expect(
        catchBody.contains('You can send messages after the request is accepted.'),
        isTrue,
      );
    });

    test('a genuine non-RLS send failure still shows the original (non-security-sensitive) error '
        'path, unchanged', () {
      expect(source.contains("'Failed to send message: \$e'"), isTrue);
      expect(source.contains('backgroundColor: Colors.red'), isTrue);
    });

    test('no raw PostgreSQL/RLS/error-code implementation detail strings are hardcoded into any '
        'user-facing message added by this fix', () {
      final friendlyMsgIndex = source.indexOf('You can send messages after the request is accepted.');
      expect(friendlyMsgIndex, greaterThanOrEqualTo(0));
      final surrounding = source.substring(friendlyMsgIndex - 5, friendlyMsgIndex + 60);
      expect(surrounding.toLowerCase().contains('postgres'), isFalse);
      expect(surrounding.contains('42501'), isFalse);
    });
  });
}
