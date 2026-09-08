import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/modules/notifications/services/notification_service.dart';
import 'package:waydrop/shared/helpers/time_format_helper.dart';

/// Full-message detail view for a single notification -- the destination Issue 4 (Phase 2)
/// requires for an intercity notification tap, instead of the notification auto-opening Chat.
///
/// Reads the complete, untruncated title/body straight from the `notifications` row (the single
/// authoritative store every notification -- push, foreground, and this in-app inbox -- already
/// shares; see NotificationService/send_push_notification_fnc). Never re-derives or duplicates
/// the message text -- this is purely a presentation layer over the existing row.
class NotificationDetailScreen extends StatefulWidget {
  /// `notifications.id` -- present on every tap payload (both the in-app inbox, which builds it
  /// from the row it already has, and a real FCM/local-notification tap, since
  /// on_notification_insert() stamps it into the push `data` payload). Used to fetch the
  /// complete, authoritative row.
  final String? notificationId;

  /// The original tap payload (type/order_id/rider_id/request_id/etc.) -- reused verbatim by the
  /// explicit "Open Chat" button so Chat is opened through the exact same, single code path
  /// (NotificationService.openChatForOrder) the rest of the app already uses, never a second
  /// re-implementation.
  final Map<String, dynamic> tapData;

  /// Optional pre-known values (the inbox list already has these in memory) so the detail view
  /// can render instantly without waiting on the network fetch; the fetch still runs to pick up
  /// notification_type/created_at when they weren't already supplied.
  final String? initialTitle;
  final String? initialBody;

  const NotificationDetailScreen({
    super.key,
    required this.notificationId,
    required this.tapData,
    this.initialTitle,
    this.initialBody,
  });

  @override
  State<NotificationDetailScreen> createState() => _NotificationDetailScreenState();
}

class _NotificationDetailScreenState extends State<NotificationDetailScreen> {
  final _supabase = Supabase.instance.client;
  bool _loading = true;
  String? _title;
  String? _body;
  String? _notificationType;
  DateTime? _createdAt;

  @override
  void initState() {
    super.initState();
    _title = widget.initialTitle;
    _body = widget.initialBody;
    _notificationType = widget.tapData['type']?.toString();
    _load();
  }

  Future<void> _load() async {
    final id = widget.notificationId;
    if (id == null || id.isEmpty) {
      // No row to fetch (e.g. a malformed/legacy payload) -- fall back to whatever the tap
      // payload already carried rather than showing an empty screen.
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final row = await _supabase
          .from('notifications')
          .select('title,body,notification_type,created_at')
          .eq('id', id)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      if (mounted) {
        setState(() {
          if (row != null) {
            _title = row['title']?.toString() ?? _title;
            _body = row['body']?.toString() ?? _body;
            _notificationType = row['notification_type']?.toString() ?? _notificationType;
            _createdAt = DateTime.tryParse(row['created_at']?.toString() ?? '')?.toLocal();
          }
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('NotificationDetailScreen: failed to load notification $id: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  String _typeLabel(String? type) {
    switch (type) {
      case 'intercity_request':
        return 'Intercity';
      case 'order_status':
        return 'Order Update';
      case 'chat_message':
        return 'Chat';
      case 'support_message':
        return 'Support';
      case 'order_assignment':
        return 'New Order';
      case 'cod_settlement':
        return 'Cash Settlement';
      case 'new_rating':
        return 'Rating';
      default:
        return 'Notification';
    }
  }

  bool get _canOpenChat {
    final orderId = widget.tapData['order_id']?.toString();
    if (orderId == null || orderId.isEmpty) return false;
    // Issue 5 (Phase 2): a whole-travel-plan deletion is a terminal status update, not a chat
    // message -- the negotiation this order's chat channel belonged to has ended entirely. Scoped
    // precisely to that one event (on_intercity_request_change() only ever sets
    // cancelled_scope='travel_plan' for a cascade_cancel_travel_plan_dependents()-driven row) --
    // every other intercity_request notification (including the individual-request and generic
    // cancellation flavors) is unaffected and still offers Chat when an order id is present.
    if (widget.tapData['cancelled_scope']?.toString() == 'travel_plan') return false;
    // Phase 11 (Issue 2): a rating notification (new_rating) always carries the order_id it was
    // rated against, but the order's negotiation/chat channel has long since ended by the time a
    // rating exists (the order is completed) -- offering "Open Chat" here led straight to "you
    // cannot message". order_id presence alone was never a reliable signal for "this notification
    // represents an active chat/message context"; the notification's own type is.
    if (_notificationType == 'new_rating') return false;
    return true;
  }

  void _openChat() {
    final orderId = widget.tapData['order_id']?.toString();
    if (orderId == null || orderId.isEmpty) return;
    final riderId = widget.tapData['rider_id']?.toString() ?? widget.tapData['traveller_id']?.toString();
    final isSupport = widget.tapData['is_support']?.toString() == 'true';
    NotificationService().openChatForOrder(
      orderId: orderId,
      riderId: riderId,
      isSupport: isSupport,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF1A1A1A);
    final subTextColor = isDark ? const Color(0xFFA9B0BE) : const Color(0xFF6B7280);
    const primaryLime = Color(0xFFC5FF30);

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F1115) : const Color(0xFFF9FAFB),
      appBar: AppBar(
        title: const Text('Notification'),
        backgroundColor: isDark ? const Color(0xFF171A21) : Colors.white,
        foregroundColor: textColor,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: primaryLime.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _typeLabel(_notificationType).toUpperCase(),
                          style: const TextStyle(color: primaryLime, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (_createdAt != null)
                        Text(
                          TimeFormatHelper.formatDateTime12Hour(_createdAt!),
                          style: TextStyle(color: subTextColor, fontSize: 12),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _title ?? '',
                    style: TextStyle(color: textColor, fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  // The complete, untruncated body -- no maxLines/overflow, unlike the inbox
                  // list's compact preview. Selectable so a long cancellation reason can be
                  // copied out (e.g. to quote back to support).
                  SelectableText(
                    _body ?? '',
                    style: TextStyle(color: textColor.withValues(alpha: 0.9), fontSize: 15, height: 1.5),
                  ),
                  if (_canOpenChat) ...[
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _openChat,
                        icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                        label: const Text('Open Chat'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: primaryLime,
                          side: const BorderSide(color: primaryLime),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}
