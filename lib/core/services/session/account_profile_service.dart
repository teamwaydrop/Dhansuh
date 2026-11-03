import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

class AccountRestrictedException implements Exception {
  final bool deleted;
  const AccountRestrictedException({this.deleted = false});
}

class AccountProfileSchemaException implements Exception {
  final Object cause;
  const AccountProfileSchemaException(this.cause);
}

class _AccountReadFlight<T> {
  final String? credential;
  _AccountReadFlight(this.credential);
  late final Future<T> result;
  late final void Function() release;
  int pendingReads = 0;
  bool resultSettled = false;
}

/// Public profile fields are schema-checked. Account bans belong to Auth,
/// not to an invented users boolean or user-editable metadata.
class AccountProfileService {
  static AccountProfileService? _instance;
  static AccountProfileService get instance =>
      _instance ??= AccountProfileService(Supabase.instance.client);
  static const projection =
      'id, full_name, deleted_at, profile_completed, '
      'onboarding_completed, preferred_mode, is_developer, role';
  final SupabaseClient client;
  final Future<void> Function(Duration) delay;
  final Map<String, _AccountReadFlight<Map<String, dynamic>?>> _pending = {};
  final Map<String, _AccountReadFlight<void>> _authPending = {};
  final Map<String, AccountProfileSchemaException> _schemaErrors = {};

  AccountProfileService(this.client, {Future<void> Function(Duration)? delay})
    : delay = delay ?? Future<void>.delayed;

  static String? postgrestCode(PostgrestException error) {
    // postgrest 2.5.0 maybeSingle can wrap the original JSON as message,
    // replacing SQLSTATE with HTTP 400. Preserve the actual server code.
    try {
      final body = jsonDecode(error.message);
      if (body is Map && body['code'] is String) return body['code'] as String;
    } on FormatException {
      // Normal decoded PostgREST errors already expose the SQLSTATE directly.
    }
    return error.code;
  }

  static bool isSchemaError(Object error) =>
      error is AccountProfileSchemaException ||
      (error is PostgrestException &&
          const {
            '42703',
            '42P01',
            'PGRST200',
            'PGRST204',
          }.contains(postgrestCode(error)));

  static bool isTransient(Object error) {
    if (error is TimeoutException ||
        error is http.ClientException ||
        error is AuthRetryableFetchException) {
      return true;
    }
    final code = error is PostgrestException
        ? error.code
        : error is AuthException
        ? error.statusCode
        : null;
    return const {
          '408',
          '429',
          '500',
          '502',
          '503',
          '504',
          'PGRST000',
          'PGRST001',
          'PGRST002',
          'PGRST003',
          '53300',
          '57014',
          '08000',
          '08006',
        }.contains(code) ||
        error.toString().contains('SocketException');
  }

  Future<T> _read<T>(
    Future<T> Function() action,
    String userId,
    DateTime deadline,
    _AccountReadFlight<dynamic> owner,
  ) async {
    for (var attempt = 0; ; attempt++) {
      if (client.auth.currentUser?.id != userId) {
        throw const AuthException('Account changed during verification');
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException('Account verification timed out');
      }
      try {
        owner.pendingReads++;
        // Observe the materialized transport, not the non-cancelling UI timeout.
        final raw = Future<T>.sync(action).whenComplete(() {
          owner.pendingReads--;
          owner.release();
        });
        return await raw.timeout(
          remaining < const Duration(seconds: 3)
              ? remaining
              : const Duration(seconds: 3),
        );
      } catch (error) {
        // Future.timeout does not cancel the HTTP operation. Returning the
        // bounded failure must not start another request while it is pending.
        // Completed HTTP/network failures retain the bounded retry policy below.
        if (error is TimeoutException) rethrow;
        if (!isTransient(error) || attempt >= 2) rethrow;
        final backoff = Duration(milliseconds: 500 * (1 << attempt));
        if (deadline.difference(DateTime.now()) <= backoff) rethrow;
        await delay(backoff);
      }
    }
  }

  Future<T> _owned<T>(
    Map<String, _AccountReadFlight<T>> owners,
    String userId,
    Future<T> Function(_AccountReadFlight<T>) action,
  ) async {
    final credential = client.auth.currentSession?.accessToken;
    final existing = owners[userId];
    if (existing != null && existing.credential == credential) {
      return existing.result;
    }
    final owner = _AccountReadFlight<T>(credential);
    owner.release = () {
      if (owner.resultSettled &&
          owner.pendingReads == 0 &&
          identical(owners[userId], owner)) {
        owners.remove(userId);
      }
    };
    owners[userId] = owner;
    owner.result = Future<T>.sync(() => action(owner));
    try {
      return await owner.result;
    } finally {
      owner.resultSettled = true;
      owner.release();
    }
  }

  Future<void> verifyAuth(String userId, {DateTime? deadline}) => _owned<void>(
    _authPending,
    userId,
    (owner) => _verifyAuth(userId, deadline, owner),
  );

  Future<void> _verifyAuth(
    String userId,
    DateTime? deadline,
    _AccountReadFlight<void> owner,
  ) async {
    try {
      final response = await _read(
        () => client.auth.getUser(),
        userId,
        deadline ?? DateTime.now().add(const Duration(seconds: 12)),
        owner,
      );
      if (response.user?.id != userId ||
          client.auth.currentUser?.id != userId) {
        throw const AuthException('Unable to verify the current account');
      }
    } on AuthException catch (error) {
      if (error.code == 'user_banned') throw const AccountRestrictedException();
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> load(String userId) {
    final failure = _schemaErrors[userId];
    if (failure != null) return Future.error(failure);
    return _owned(_pending, userId, (owner) => _load(userId, owner));
  }

  Future<Map<String, dynamic>?> _load(
    String userId,
    _AccountReadFlight<Map<String, dynamic>?> owner,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    try {
      // A successful server Auth check establishes ban/session status. A timeout
      // or failed check never becomes an implicit "not suspended" decision.
      await verifyAuth(userId, deadline: deadline);
      final profile = await _read(
        () => client
            .from('users')
            .select(projection)
            .eq('id', userId)
            .maybeSingle(),
        userId,
        deadline,
        owner,
      );
      if (client.auth.currentUser?.id != userId) {
        throw const AuthException('Account changed during profile loading');
      }
      if (profile != null) {
        if (profile['id'] != userId || !profile.containsKey('deleted_at')) {
          throw const AccountProfileSchemaException(
            'Incomplete account profile',
          );
        }
        if (profile['deleted_at'] != null) {
          throw const AccountRestrictedException(deleted: true);
        }
      }
      return profile;
    } catch (error) {
      if (isSchemaError(error)) {
        final failure = error is AccountProfileSchemaException
            ? error
            : AccountProfileSchemaException(error);
        _schemaErrors[userId] = failure;
        throw failure;
      }
      rethrow;
    }
  }

  void clear() => _schemaErrors.clear();
}
