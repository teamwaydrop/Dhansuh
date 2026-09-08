import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:waydrop/main.dart';
import 'package:waydrop/core/providers/notification_badge_provider.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';

/// Feature 1 ("Notification Badge: YES") + Feature 9 (realtime everywhere, no polling): keeps
/// [unreadNotificationCountProvider] in sync with the DB via a single RealtimeManager subscription
/// on public.notifications, filtered to the current user — never polled, only refreshed on
/// INSERT/UPDATE events (e.g. a new "Traveller Available" notification arriving, or the inbox
/// screen marking one read).
class NotificationBadgeService {
  NotificationBadgeService._();
  static final NotificationBadgeService instance = NotificationBadgeService._();

  final _supabase = Supabase.instance.client;
  String? _subscribedUserId;
  String? _subscriptionId;

  Future<void> refresh() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        providerContainer.read(unreadNotificationCountProvider.notifier).state = 0;
        return;
      }
      final rows = await _supabase
          .from('notifications')
          .select('id')
          .eq('user_id', user.id)
          .eq('is_read', false)
          .timeout(const Duration(seconds: 8));
      providerContainer.read(unreadNotificationCountProvider.notifier).state = rows.length;
    } catch (e) {
      debugPrint('NotificationBadgeService: failed to refresh unread count: $e');
    }
  }

  /// Starts (or re-scopes, on user switch) the realtime subscription driving the badge. Safe to
  /// call multiple times — RealtimeManager de-duplicates subscriptions to the same channel name.
  void startListening() {
    final user = _supabase.auth.currentUser;
    if (user == null || user.id == _subscribedUserId) return;

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

    _subscriptionId = RealtimeManager.instance.subscribe(
      channelName: 'notification-badge-${user.id}',
      table: 'notifications',
      owner: 'NotificationBadgeService',
      event: PostgresChangeEvent.all,
      schema: 'public',
      filterColumn: 'user_id',
      filterValue: user.id,
      callback: (payload) => refresh(),
    );

    refresh();
  }
}
