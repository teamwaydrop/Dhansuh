import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:waydrop/main.dart';
import 'package:waydrop/core/providers/notification_badge_provider.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'notification_count_events.dart';

/// Feature 1 ("Notification Badge: YES") + Feature 9 (realtime everywhere, no polling): keeps
/// [unreadNotificationCountProvider] in sync with the DB via a single RealtimeManager subscription
/// on public.notifications, filtered to the current user, refreshed on
/// INSERT/UPDATE events (e.g. a new "Traveller Available" notification arriving, or the inbox
/// screen marking one read), with bounded backoff to reconcile a failed count.
class NotificationBadgeService {
  NotificationBadgeService._({SupabaseClient? client, DateTime Function()? now})
    : _supabase = client ?? Supabase.instance.client,
      _now = now ?? DateTime.now;
  @visibleForTesting
  factory NotificationBadgeService.forClient(
    SupabaseClient client, {
    DateTime Function()? now,
  }) => NotificationBadgeService._(client: client, now: now);
  static final NotificationBadgeService instance = NotificationBadgeService._();

  final SupabaseClient _supabase;
  final DateTime Function() _now;
  DateTime? _retryAt;
  Timer? _retryTimer;
  int _failures = 0;
  String? _subscribedUserId;
  String? _subscriptionId;
  Future<void>? _refreshInFlight;
  bool _refreshQueued = false;
  int _refreshGeneration = 0;
  final _countEvents = NotificationCountEvents();

  Future<void> refresh() {
    if (_retryAt?.isAfter(_now()) ?? false) return Future.value();
    _refreshQueued = true;
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;

    final operation = _drainRefreshQueue();
    _refreshInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_refreshInFlight, operation)) {
        _refreshInFlight = null;
      }
    });
  }

  Future<void> _drainRefreshQueue() async {
    do {
      _refreshQueued = false;
      if (!await _refreshOnce()) {
        // Do not immediately drain another expensive HEAD after a failed one.
        _refreshQueued = false;
        break;
      }
    } while (_refreshQueued);
  }

  Future<bool> _refreshOnce() async {
    final generation = _refreshGeneration;
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        providerContainer.read(unreadNotificationCountProvider.notifier).state =
            0;
        return true;
      }
      final count = await _supabase
          .from('notifications')
          .count(CountOption.exact)
          .eq('user_id', user.id)
          .eq('is_read', false);

      // Ignore a response belonging to an account that signed out/switched while this request was
      // in flight. The auth cleanup path owns resetting the badge to zero.
      if (generation != _refreshGeneration ||
          _supabase.auth.currentUser?.id != user.id) {
        return true;
      }
      _failures = 0;
      _retryAt = null;
      _retryTimer?.cancel();
      providerContainer.read(unreadNotificationCountProvider.notifier).state =
          count;
      return true;
    } catch (e) {
      if (generation != _refreshGeneration) return true;
      // A failed reconciliation must not make later metadata events look settled.
      _countEvents.clear();
      _failures = (_failures + 1).clamp(1, 5);
      final seconds = (8 * (1 << (_failures - 1))).clamp(8, 120);
      _retryAt = _now().add(Duration(seconds: seconds));
      _retryTimer?.cancel();
      if (_subscribedUserId != null &&
          _subscribedUserId == _supabase.auth.currentUser?.id) {
        _retryTimer = Timer(Duration(seconds: seconds), () {
          if (generation != _refreshGeneration) return;
          _retryAt = null;
          unawaited(refresh());
        });
      }
      debugPrint(
        'NotificationBadgeService: count unavailable; reconciliation backed off.',
      );
      return false;
    }
  }

  /// Starts (or re-scopes, on user switch) the realtime subscription driving the badge. Safe to
  /// call multiple times — RealtimeManager de-duplicates subscriptions to the same channel name.
  void startListening() {
    final user = _supabase.auth.currentUser;
    if (user == null || user.id == _subscribedUserId) return;
    ++_refreshGeneration;
    _retryAt = null;
    _failures = 0;
    _retryTimer?.cancel();

    // R11 fix: the previous subscription's ID was never captured, so the OLD channel had no way
    // to ever be unsubscribed on an account switch -- it stayed registered in RealtimeManager
    // indefinitely (until process death), accumulating one leaked live channel per distinct
    // account seen in this process's lifetime. Tear the old one down first, now that we actually
    // retain what's needed to do so.
    if (_subscribedUserId != null && _subscriptionId != null) {
      RealtimeManager.instance.unsubscribe(
        'notification-badge-$_subscribedUserId',
        _subscriptionId!,
      );
    }

    _subscribedUserId = user.id;
    _countEvents.clear();

    _subscriptionId = RealtimeManager.instance.subscribe(
      channelName: 'notification-badge-${user.id}',
      table: 'notifications',
      owner: 'NotificationBadgeService',
      event: PostgresChangeEvent.all,
      schema: 'public',
      filterColumn: 'user_id',
      filterValue: user.id,
      callback: (payload) {
        final type = payload.eventType.name.toUpperCase();
        if (_countEvents.needsRefresh(
          type,
          type == 'DELETE' ? payload.oldRecord : payload.newRecord,
        )) {
          refresh();
        }
      },
    );

    refresh();
  }

  /// Releases the account-scoped realtime listener and clears all account-scoped state.
  /// Safe to call repeatedly from every logout/deletion path.
  void stopListening() {
    ++_refreshGeneration;
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAt = null;
    _failures = 0;
    final userId = _subscribedUserId;
    final subscriptionId = _subscriptionId;

    // Clear local identity first so a synchronous auth/account transition cannot observe stale
    // state and incorrectly skip startListening() for a later login of the same account.
    _subscribedUserId = null;
    _subscriptionId = null;
    _refreshQueued = false;
    _countEvents.clear();

    if (userId != null && subscriptionId != null) {
      RealtimeManager.instance.unsubscribe(
        'notification-badge-$userId',
        subscriptionId,
      );
    }

    providerContainer.read(unreadNotificationCountProvider.notifier).state = 0;
  }
}
