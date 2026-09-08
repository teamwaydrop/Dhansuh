import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/modules/chat/screens/order_chat_screen.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';

class AdminSupportChatsScreen extends StatefulWidget {
  const AdminSupportChatsScreen({super.key});

  @override
  State<AdminSupportChatsScreen> createState() => _AdminSupportChatsScreenState();
}

class _AdminSupportChatsScreenState extends State<AdminSupportChatsScreen> {
  final supabase = Supabase.instance.client;
  List<Map<String, dynamic>> _sessions = [];
  bool _loading = true;
  // P2 #3 (WayDrop production-scale audit): now routed through RealtimeManager instead of its own
  // raw supabase.channel() connection.
  String? _realtimeSubId;
  String? _realtimeSubChannel;

  @override
  void initState() {
    super.initState();
    _fetchSessions();
    _subscribeRealtime();
  }

  @override
  void dispose() {
    if (_realtimeSubId != null && _realtimeSubChannel != null) {
      RealtimeManager.instance.unsubscribe(_realtimeSubChannel!, _realtimeSubId!);
    }
    super.dispose();
  }

  Future<void> _fetchSessions() async {
    try {
      // Fetch all support messages with associated user profiles.
      // Egress fix: narrowed to the fields read below (`role` was selected but never read).
      final res = await supabase
          .from('order_chat_messages')
          .select('user_id, message, sender_type, created_at, user:users(full_name, phone, user_code)')
          .eq('is_support', true)
          .order('created_at', ascending: false);

      final Map<String, Map<String, dynamic>> latestMessages = {};
      for (final row in res) {
        final userId = row['user_id']?.toString();
        if (userId != null && !latestMessages.containsKey(userId)) {
          latestMessages[userId] = row;
        }
      }

      if (mounted) {
        setState(() {
          _sessions = latestMessages.values.toList();
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('FETCH SUPPORT SESSIONS ERROR => $e');
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _subscribeRealtime() {
    if (_realtimeSubId != null && _realtimeSubChannel != null) {
      RealtimeManager.instance.unsubscribe(_realtimeSubChannel!, _realtimeSubId!);
      _realtimeSubId = null;
      _realtimeSubChannel = null;
    }
    _realtimeSubChannel = 'admin-support-sessions';
    _realtimeSubId = RealtimeManager.instance.subscribe(
      channelName: _realtimeSubChannel!,
      table: 'order_chat_messages',
      owner: 'AdminSupportChatsScreen',
      event: PostgresChangeEvent.insert,
      schema: 'public',
      filterColumn: 'is_support',
      // Postgres Changes filter values are always transmitted as strings over the wire regardless
      // of the underlying column's type (boolean here) -- the server-side comparison coerces
      // correctly, so this is the same filter as the raw `value: true` it replaces, not a
      // behavior change.
      filterValue: 'true',
      callback: (payload) {
        _fetchSessions(); // Refresh list on new support messages
      },
    );
  }

  String _getInitials(String fullName) {
    if (fullName.isEmpty) return 'U';
    final parts = fullName.trim().split(' ');
    if (parts.length > 1) {
      return (parts[0][0] + parts[1][0]).toUpperCase();
    }
    return parts[0][0].toUpperCase();
  }

  String _getTimeAgo(String dateStr) {
    final date = DateTime.parse(dateStr).toLocal();
    final diff = DateTime.now().difference(date);

    if (diff.inDays > 0) {
      return "${diff.inDays}d ago";
    }
    if (diff.inHours > 0) {
      return "${diff.inHours}h ago";
    }
    if (diff.inMinutes > 0) {
      return "${diff.inMinutes}m ago";
    }
    return "just now";
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const emeraldColor = Color(0xFF10B981);

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF1E222B) : Colors.grey.shade50,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF171A21) : Colors.white,
        elevation: 0.5,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: isDark ? Colors.white : Colors.black),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Support Panel',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white : Colors.black,
          ),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: emeraldColor),
            )
          : _sessions.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.support_agent_rounded,
                        size: 56,
                        color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade300,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'No support sessions active',
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? const Color(0xFF64748B) : Colors.grey,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  itemCount: _sessions.length,
                  itemBuilder: (context, index) {
                    final session = _sessions[index];
                    final userId = session['user_id']?.toString() ?? '';
                    final user = session['user'] as Map<String, dynamic>?;
                    final fullName = user?['full_name']?.toString() ?? 'WayDrop Client';
                    final phone = user?['phone']?.toString() ?? 'N/A';
                    final lastMessage = session['message']?.toString() ?? '';
                    final senderType = session['sender_type']?.toString();
                    final timestamp = session['created_at']?.toString() ?? '';

                    // If latest message is not from admin, it needs a response
                    final needsResponse = senderType != 'admin';

                    return GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => OrderChatScreen(
                              orderId: '',
                              chatTitle: fullName,
                              isSupport: true,
                              peerUserId: userId,
                            ),
                          ),
                        ).then((_) => _fetchSessions());
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF171A21) : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isDark
                                ? (needsResponse ? emeraldColor.withOpacity(0.3) : const Color(0xFF1E293B))
                                : (needsResponse ? emeraldColor.withOpacity(0.4) : const Color(0xFFE2E8F0)),
                            width: 1.2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(isDark ? 0.2 : 0.03),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            // Initials Avatar
                            Container(
                              height: 44,
                              width: 44,
                              decoration: BoxDecoration(
                                color: needsResponse
                                    ? emeraldColor.withOpacity(0.15)
                                    : (isDark ? const Color(0xFF1E222B) : Colors.grey.shade100),
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  _getInitials(fullName),
                                  style: TextStyle(
                                    color: needsResponse ? emeraldColor : (isDark ? Colors.white70 : Colors.black87),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            // Details
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        fullName,
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13.5,
                                          color: isDark ? Colors.white : Colors.black,
                                        ),
                                      ),
                                      Text(
                                        _getTimeAgo(timestamp),
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: isDark ? const Color(0xFF64748B) : Colors.grey,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '$phone • ${user?['user_code']?.toString() ?? 'N/A'}',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    lastMessage,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: needsResponse ? FontWeight.w700 : FontWeight.normal,
                                      color: isDark ? Colors.white70 : Colors.grey.shade800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Status Badge
                            if (needsResponse)
                              Container(
                                height: 10,
                                width: 10,
                                decoration: const BoxDecoration(
                                  color: emeraldColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
