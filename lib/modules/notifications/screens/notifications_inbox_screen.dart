import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/modules/notifications/services/notification_service.dart';

/// Generic in-app Notifications inbox — the first in-app view onto the existing
/// `public.notifications` table (previously push-only). Reused by both the User and Partner
/// shells via a bell icon rather than a new bottom-nav tab, and by both app modes since the
/// table/RLS already scope rows to `auth.currentUser` regardless of role.
class NotificationsInboxScreen extends StatefulWidget {
  const NotificationsInboxScreen({super.key});

  @override
  State<NotificationsInboxScreen> createState() => _NotificationsInboxScreenState();
}

class _NotificationsInboxScreenState extends State<NotificationsInboxScreen> {
  final _supabase = Supabase.instance.client;
  List<Map<String, dynamic>> _notifications = [];
  bool _loading = true;
  // Egress fix: this was a single unbounded `.limit(100)` reload on every open --
  // paginated with .range() so a user with a long history only ever downloads
  // what they actually scroll to, instead of 100 rows every time the inbox opens.
  static const int _pageSize = 30;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _accountId;
  int _generation = 0;
  bool _pageOnePending = false;
  StreamSubscription<AuthState>? _accountSubscription;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _accountId = _supabase.auth.currentUser?.id;
    _accountSubscription = _supabase.auth.onAuthStateChange.listen((event) {
      final next = event.session?.user.id;
      if (!mounted || next == _accountId) return;
      _generation++;
      setState(() {
        _accountId = next;
        _notifications = [];
        _loading = next != null;
        _loadingMore = false;
        _pageOnePending = false;
        _hasMore = true;
      });
      _load(); // Rebind automatically; no screen re-entry requirement.
    });
    _load();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _generation++;
    _accountSubscription?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore || _loading || _pageOnePending) return;
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final userId = _supabase.auth.currentUser?.id;
    if (userId != _accountId) return; // Auth listener owns replacement/clearing.
    final generation = ++_generation;
    _loadingMore = false;
    if (userId == null) {
      setState(() => _loading = false);
      return;
    }
    _pageOnePending = true;

    try {
      // Column projection (Finding F, WayDrop Performance Roadmap): every field below is read by
      // this screen's list UI or by NotificationService.handleNotificationTap() (which performs
      // the actual mark-as-read UPDATE using only notification_id -- it never reads read_at or any
      // other raw column back, so read_at is write-only here and doesn't need to be selected).
      final rows = await _supabase
          .from('notifications')
          .select('id,payload,notification_type,reference_id,is_read,created_at,title,body')
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .range(0, _pageSize - 1);

      if (_isCurrent(userId, generation)) {
        setState(() {
          _notifications = List<Map<String, dynamic>>.from(rows);
          _hasMore = rows.length == _pageSize;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading notifications: $e');
      if (_isCurrent(userId, generation)) setState(() => _loading = false);
    } finally {
      if (_isCurrent(userId, generation)) _pageOnePending = false;
    }
  }

  Future<void> _loadMore() async {
    if (!mounted || _loadingMore || _loading || _pageOnePending || !_hasMore) return;
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null || userId != _accountId) return;
    final generation = _generation;

    setState(() => _loadingMore = true);
    try {
      final from = _notifications.length;
      final rows = await _supabase
          .from('notifications')
          .select('id,payload,notification_type,reference_id,is_read,created_at,title,body')
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .range(from, from + _pageSize - 1);

      if (_isCurrent(userId, generation)) {
        setState(() {
          _notifications.addAll(List<Map<String, dynamic>>.from(rows));
          _hasMore = rows.length == _pageSize;
          _loadingMore = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading more notifications: $e');
      if (_isCurrent(userId, generation)) setState(() => _loadingMore = false);
    }
  }

  bool _isCurrent(String userId, int generation) => mounted &&
      generation == _generation && userId == _accountId && _supabase.auth.currentUser?.id == userId;

  Future<void> _onTapNotification(Map<String, dynamic> notification) async {
    if (!mounted || _accountId == null || _supabase.auth.currentUser?.id != _accountId ||
        !_notifications.contains(notification)) {
      return;
    }
    final payload = (notification['payload'] as Map<String, dynamic>?) ?? const {};
    final data = <String, dynamic>{
      ...payload,
      'notification_id': notification['id'],
      'type': notification['notification_type'],
      'order_id': notification['reference_id'] ?? payload['order_id'],
    };

    if (mounted) {
      setState(() {
        notification['is_read'] = true;
      });
    }

    await NotificationService().handleNotificationTap(data);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF1A1A1A);
    final subTextColor = isDark ? const Color(0xFFA9B0BE) : const Color(0xFF6B7280);

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F1115) : const Color(0xFFF9FAFB),
      appBar: AppBar(
        title: const Text('Notifications'),
        backgroundColor: isDark ? const Color(0xFF171A21) : Colors.white,
        foregroundColor: textColor,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _notifications.isEmpty
              ? Center(
                  child: Text('No notifications yet.', style: TextStyle(color: subTextColor)),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    controller: _scrollController,
                    itemCount: _notifications.length + (_hasMore ? 1 : 0),
                    separatorBuilder: (context, index) => Divider(height: 1, color: isDark ? Colors.white10 : const Color(0xFFE5E7EB)),
                    itemBuilder: (context, index) {
                      if (index >= _notifications.length) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final n = _notifications[index];
                      final isRead = n['is_read'] == true;
                      final createdAt = DateTime.tryParse(n['created_at']?.toString() ?? '')?.toLocal();

                      return ListTile(
                        onTap: () => _onTapNotification(n),
                        tileColor: isRead ? Colors.transparent : (isDark ? Colors.white.withValues(alpha: 0.03) : const Color(0xFFF3F4F6)),
                        leading: CircleAvatar(
                          backgroundColor: isDark ? Colors.white10 : const Color(0xFFEFF6FF),
                          child: Icon(
                            isRead ? Icons.notifications_none_rounded : Icons.notifications_active_rounded,
                            color: isRead ? subTextColor : const Color(0xFF7C3AED),
                          ),
                        ),
                        title: Text(
                          (n['title'] ?? '').toString(),
                          style: TextStyle(color: textColor, fontWeight: isRead ? FontWeight.w500 : FontWeight.bold, fontSize: 14),
                        ),
                        subtitle: Text(
                          (n['body'] ?? '').toString(),
                          style: TextStyle(color: subTextColor, fontSize: 12),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: createdAt != null
                            ? Text(
                                '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}',
                                style: TextStyle(color: subTextColor, fontSize: 11),
                              )
                            : null,
                      );
                    },
                  ),
                ),
    );
  }
}
