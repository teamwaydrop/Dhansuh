import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/session/account_profile_service.dart';
import 'package:waydrop/core/services/diagnostics/performance_trace.dart';

class ChatRetryLater implements Exception {}

/// One outstanding write per account. A UI timeout must never release this lane
/// while the underlying HTTP INSERT can still commit. Existing UUID PK supplies
/// idempotency; no database migration or weaker authorization is required.
class ChatMessageDelivery {
  static ChatMessageDelivery? _instance;
  static ChatMessageDelivery get instance =>
      _instance ??= ChatMessageDelivery(Supabase.instance.client);
  final SupabaseClient client;
  final DateTime Function() now;
  final Map<String, Future<void>> _tails = {};
  final Map<
    String,
    ({Map<String, dynamic> message, Future<Map<String, dynamic>> future})
  >
  _pending = {};
  final Map<String, DateTime> _retryAt = {};
  final Map<String, int> _failures = {};
  static final _random = Random.secure();
  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  static const fields =
      'id, sender_id, sender_type, message, message_type, created_at';

  ChatMessageDelivery(this.client, {DateTime Function()? now})
    : now = now ?? DateTime.now;

  static String newMessageId() {
    final bytes = List.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static Map<String, dynamic> prepare(Map<String, dynamic> message) => {
    ...message,
    'client_message_id':
        _uuid.hasMatch(message['client_message_id']?.toString() ?? '')
        ? message['client_message_id']
        : _uuid.hasMatch(message['id']?.toString() ?? '')
        ? message['id']
        : newMessageId(),
  };

  static bool retryable(Object error) =>
      error is ChatRetryLater ||
      AccountProfileService.isTransient(error) ||
      (error is PostgrestException &&
          const {
            '57014',
            'PGRST003',
            '53300',
            '08006',
          }.contains(AccountProfileService.postgrestCode(error)));

  bool canAttempt(String userId) =>
      !(_retryAt[userId]?.isAfter(now()) ?? false);

  Future<Map<String, dynamic>> send(Map<String, dynamic> message) =>
      PerformanceTrace.measure('chat', () => _send(message));

  Future<Map<String, dynamic>> _send(Map<String, dynamic> message) {
    final userId = client.auth.currentUser?.id;
    if (userId == null || message['sender_id'] != userId) {
      return Future.error(
        const AuthException('Chat sender must be the current account'),
      );
    }
    final stableId = message['client_message_id']?.toString() ?? '';
    if (!_uuid.hasMatch(stableId)) {
      return Future.error(
        ArgumentError('Persist a stable chat message id before sending'),
      );
    }
    final key = '$userId/$stableId';
    final pending = _pending[key];
    if (pending != null) {
      if (!mapEquals(pending.message, message)) {
        return Future.error(
          ArgumentError('Message id reused with different content'),
        );
      }
      return pending.future;
    }
    message = Map<String, dynamic>.from(message);
    final result = Completer<Map<String, dynamic>>();
    _pending[key] = (message: message, future: result.future);
    unawaited(
      result.future.then<void>(
        (_) {
          _pending.remove(key);
        },
        onError: (Object _, StackTrace _) {
          _pending.remove(key);
        },
      ),
    );
    final previous = _tails[userId] ?? Future<void>.value();
    final task = previous.then((_) async {
      try {
        if (client.auth.currentUser?.id != userId) {
          throw const AuthException('Chat account changed');
        }
        if (!canAttempt(userId)) throw ChatRetryLater();
        final row = await _insert(message, userId);
        _retryAt.remove(userId);
        _failures.remove(userId);
        result.complete(row);
      } catch (error, stack) {
        if (retryable(error) && error is! ChatRetryLater) {
          final failures = min((_failures[userId] ?? 0) + 1, 5);
          _failures[userId] = failures;
          _retryAt[userId] = now().add(
            Duration(seconds: min(8 * (1 << (failures - 1)), 120)),
          );
          PerformanceTrace.record({
            'kind': 'retry_wait',
            'screen': 'chat',
            'ms': min(8 * (1 << (failures - 1)), 120) * 1000,
          });
        }
        result.completeError(error, stack);
      }
    });
    _tails[userId] = task;
    unawaited(
      task.then((_) {
        if (identical(_tails[userId], task)) _tails.remove(userId);
      }),
    );
    return result.future;
  }

  Future<Map<String, dynamic>> _insert(
    Map<String, dynamic> message,
    String userId,
  ) async {
    final data = Map<String, dynamic>.from(message);
    final stableId = data.remove('client_message_id')?.toString();
    if (stableId == null || !_uuid.hasMatch(stableId)) {
      throw ArgumentError('Persist a stable chat message id before sending');
    }
    data['id'] = stableId;
    data.remove('is_offline');
    try {
      // Intentionally no .timeout(): Dart Future.timeout does not cancel POST.
      return await client
          .from('order_chat_messages')
          .insert(data)
          .select(fields)
          .single();
    } on PostgrestException catch (error) {
      if (AccountProfileService.postgrestCode(error) != '23505') rethrow;
      var query = client
          .from('order_chat_messages')
          .select(fields)
          .eq('id', stableId)
          .eq('sender_id', userId);
      for (final column in ['order_id', 'rider_id', 'user_id']) {
        query = data[column] == null
            ? query.isFilter(column, null)
            : query.eq(column, data[column]);
      }
      final existing = await query
          .eq('is_support', data['is_support'] ?? false)
          .maybeSingle();
      if (existing == null ||
          existing['message'] != data['message'] ||
          (existing['message_type'] ?? 'text') != (data['message_type'] ?? 'text') ||
          existing['sender_type'] != data['sender_type']) {
        rethrow;
      }
      return existing;
    }
  }

  static Future<void> enqueue(
    SharedPreferences prefs,
    String key,
    Map<String, dynamic> message,
  ) async {
    final items = prefs.getStringList(key) ?? [];
    if (!items.any((s) => (jsonDecode(s) as Map)['id'] == message['id'])) {
      items.add(jsonEncode(message));
      await prefs.setStringList(key, items);
    }
  }

  static Future<void> replaceQueued(
    SharedPreferences prefs,
    String key,
    Map<String, dynamic> message,
  ) async {
    final items = (prefs.getStringList(key) ?? [])
        .map(
          (s) => (jsonDecode(s) as Map)['id'] == message['id']
              ? jsonEncode(message)
              : s,
        )
        .toList();
    await prefs.setStringList(key, items);
  }

  static Future<void> acknowledge(
    SharedPreferences prefs,
    String key,
    Object? localId,
  ) async {
    // Re-read on acknowledgement; never overwrite a snapshot taken before POST.
    final items = (prefs.getStringList(key) ?? [])
        .where((s) => (jsonDecode(s) as Map)['id'] != localId)
        .toList();
    await prefs.setStringList(key, items);
  }
}
