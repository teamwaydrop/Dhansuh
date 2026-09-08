import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/features/intercity/shared/services/intercity_matching_service.dart';
import 'package:waydrop/shared/helpers/fare_presentation_helper.dart';
import 'package:waydrop/shared/widgets/app_snackbar.dart';

/// Whether [message] was sent by the currently authenticated participant.
///
/// Alignment must key off the actual sender's identity, never off sender_type/role: in a
/// passenger<->driver order chat, the viewer's own role (_senderType) is always 'user' or
/// 'rider' and so is every ride message's sender_type -- comparing those to the unrelated
/// 'admin' bucket is true for every message on both screens, which is the bug this replaces.
bool isChatMessageMine(Map<String, dynamic> message, String? currentUserId) {
  if (currentUserId == null) return false;
  return message['sender_id']?.toString() == currentUserId;
}

/// Reconciles a message this client just sent with the local list once the INSERT response
/// comes back, without producing a duplicate bubble if realtime already delivered the same
/// row first (a race between the websocket push and the REST insert's own response).
List<Map<String, dynamic>> mergeSentMessage(
  List<Map<String, dynamic>> messages,
  String tempId,
  Map<String, dynamic> inserted,
) {
  final realId = inserted['id']?.toString();
  final result = List<Map<String, dynamic>>.from(messages);
  final tempIdx = result.indexWhere((m) => m['id'] == tempId);
  final alreadyDelivered = result.any((m) => m['id']?.toString() == realId && m['id'] != tempId);
  if (alreadyDelivered) {
    if (tempIdx != -1) result.removeAt(tempIdx);
  } else if (tempIdx != -1) {
    result[tempIdx] = Map<String, dynamic>.from(inserted);
  }
  return result;
}

class OrderChatScreen extends StatefulWidget {
  final String orderId;
  final String? riderId;
  final String chatTitle;
  final String? riderImage;
  final bool isSupport;
  final String? peerUserId; // For admin panel to reply to a specific user
  const OrderChatScreen({
    super.key,
    required this.orderId,
    this.riderId,
    required this.chatTitle,
    this.riderImage,
    this.isSupport = false,
    this.peerUserId,
  });
  @override
  State<OrderChatScreen> createState() => _OrderChatScreenState();
}
class _OrderChatScreenState extends State<OrderChatScreen> {
  final supabase = Supabase.instance.client;
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  RealtimeChannel? _chatChannel;
  String? _currentUserId;
  String? _chatUserId; // The client user ID involved in the support session
  String _senderType = 'user';
  Map<String, dynamic>? _orderData;
  Map<String, dynamic>? _intercityRequest;
  // Phase 3 fix (Issue 3): widget.riderId is null on several real notification-tap paths
  // (chat_message/generic intercity_request payloads never carry a rider id, and orders.rider_id
  // stays null pre-acceptance) -- self-resolved by _loadIntercityRequest() in that case so the
  // "before accepted" guard and the message insert's rider_id both still work correctly.
  String? _resolvedRiderId;
  String? get _effectiveRiderId => widget.riderId ?? _resolvedRiderId;
  RealtimeChannel? _requestChannel;
  bool _orderPanelExpanded = false;
  
  Timer? _syncTimer;
  bool _syncing = false;

  static const Color primaryLime = Color(0xFFC5FF30);
  static const Color textGray = Color(0xFF94A3B8);
  static const Color darkCard = Color(0xFF171A21);

  @override
  void initState() {
    super.initState();
    _currentUserId = supabase.auth.currentUser?.id;
    _initializeChat();
    _checkAndStartSync();
  }

  @override
  void dispose() {
    if (_chatChannel != null) {
      supabase.removeChannel(_chatChannel!);
      _chatChannel = null;
    }
    if (_requestChannel != null) {
      supabase.removeChannel(_requestChannel!);
      _requestChannel = null;
    }
    if (_requestSubId != null) {
      RealtimeManager.instance.unsubscribe('intercity-request-${widget.orderId}-$_effectiveRiderId', _requestSubId!);
      _requestSubId = null;
    }
    _syncTimer?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String _getOfflineQueueKey() {
    if (widget.isSupport) {
      return 'offline_chat_messages_support_${_chatUserId ?? _currentUserId}';
    } else {
      return 'offline_chat_messages_${widget.orderId}_${widget.riderId ?? ""}';
    }
  }

  Future<void> _checkAndStartSync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _getOfflineQueueKey();
      final currentQueue = prefs.getStringList(key) ?? [];
      if (currentQueue.isNotEmpty) {
        _startSyncTimer();
      }
    } catch (_) {}
  }

  void _startSyncTimer() {
    if (_syncTimer != null && _syncTimer!.isActive) return;
    _syncTimer = Timer.periodic(const Duration(seconds: 8), (_) => _syncOfflineQueue());
  }

  Future<void> _queueOfflineMessage(Map<String, dynamic> msg) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _getOfflineQueueKey();
      final currentQueueJson = prefs.getStringList(key) ?? [];
      currentQueueJson.add(jsonEncode(msg));
      await prefs.setStringList(key, currentQueueJson);
      _startSyncTimer();
    } catch (e) {
      debugPrint('QUEUE OFFLINE MESSAGE ERROR => $e');
    }
  }

  Future<void> _loadOfflineMessagesIntoList() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _getOfflineQueueKey();
      final currentQueueJson = prefs.getStringList(key) ?? [];
      final offlineMsgs = currentQueueJson
          .map((item) => jsonDecode(item) as Map<String, dynamic>)
          .toList();

      if (mounted && offlineMsgs.isNotEmpty) {
        setState(() {
          for (var offlineMsg in offlineMsgs) {
            final id = offlineMsg['id'];
            _messages.removeWhere((m) => m['id'] == id);
            _messages.add(offlineMsg);
          }
          _messages.sort((a, b) {
            final aTime = DateTime.parse(a['created_at']);
            final bTime = DateTime.parse(b['created_at']);
            return aTime.compareTo(bTime);
          });
        });
      }
    } catch (e) {
      debugPrint('LOAD OFFLINE MESSAGES INTO LIST ERROR => $e');
    }
  }

  Future<void> _syncOfflineQueue() async {
    if (_syncing || _currentUserId == null || _chatUserId == null) return;
    _syncing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _getOfflineQueueKey();
      final currentQueueJson = prefs.getStringList(key) ?? [];
      if (currentQueueJson.isEmpty) {
        _syncTimer?.cancel();
        _syncing = false;
        return;
      }

      final hasInternet = await _checkInternetConnection();
      if (!hasInternet) {
        _syncing = false;
        return;
      }

      final List<String> remainingQueue = [];
      final List<Map<String, dynamic>> syncedMessages = [];

      for (final itemJson in currentQueueJson) {
        final msgMap = jsonDecode(itemJson) as Map<String, dynamic>;
        try {
          final sendData = Map<String, dynamic>.from(msgMap);
          final tempId = sendData['id'];
          sendData.remove('id');
          sendData.remove('is_offline');

          // Egress fix: narrowed to the same field set the main history query (below) and
          // _messages rendering already use -- the inserted row has more columns (order_id,
          // rider_id, user_id, is_offline, ...) but nothing downstream of this insert reads them.
          final inserted = await supabase
              .from('order_chat_messages')
              .insert(sendData)
              .select('id, sender_id, sender_type, message, message_type, created_at')
              .single();

          syncedMessages.add({
            'tempId': tempId,
            'inserted': Map<String, dynamic>.from(inserted),
          });
        } catch (e) {
          debugPrint('SYNC INDIVIDUAL MESSAGE ERROR => $e');
          final isNetworkErr = e.toString().contains('SocketException') ||
                               e.toString().contains('ClientException') ||
                               e.toString().contains('Failed host lookup');
          if (isNetworkErr) {
            remainingQueue.addAll(currentQueueJson.sublist(currentQueueJson.indexOf(itemJson)));
            break;
          }
        }
      }

      await prefs.setStringList(key, remainingQueue);

      if (mounted && syncedMessages.isNotEmpty) {
        setState(() {
          for (var syncItem in syncedMessages) {
            final tempId = syncItem['tempId'];
            final inserted = syncItem['inserted'];
            final idx = _messages.indexWhere((m) => m['id'] == tempId);
            if (idx != -1) {
              _messages[idx] = inserted;
            } else {
              _messages.add(inserted);
            }
          }
          _messages.sort((a, b) {
            final aTime = DateTime.parse(a['created_at']);
            final bTime = DateTime.parse(b['created_at']);
            return aTime.compareTo(bTime);
          });
        });
      }

      if (remainingQueue.isEmpty) {
        _syncTimer?.cancel();
      }
    } catch (e) {
      debugPrint('SYNC OFFLINE QUEUE ERROR => $e');
    } finally {
      _syncing = false;
    }
  }

  Future<bool> _checkInternetConnection() async {
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
  Future<void> _initializeChat() async {
    if (_currentUserId == null) return;
    // Determine chat user ID and sender type
    try {
      final userProfile = await supabase
          .from('users')
          .select('preferred_mode, role')
          .eq('id', _currentUserId!)
          .maybeSingle();
      final role = userProfile?['role']?.toString();
      if (role == 'admin' || role == 'support') {
        _senderType = 'admin';
        _chatUserId = widget.peerUserId ?? _currentUserId;
      } else {
        final mode = userProfile?['preferred_mode']?.toString() ?? 'user';
        _senderType = mode == 'rider' ? 'rider' : 'user';
        _chatUserId = _currentUserId;
      }
    } catch (e) {
      debugPrint('LOAD PROFILE ROLE ERROR => $e');
      _chatUserId = _currentUserId;
    }
    await _fetchMessages();
    // Auto-init support message when opened from an order
    if (widget.isSupport && widget.orderId.isNotEmpty) {
      final hasSentOrderInfo = _messages.any((m) => m['message']?.toString().contains(widget.orderId) ?? false);
      if (!hasSentOrderInfo) {
        try {
          final orderRes = await supabase
              .from('orders')
              .select('order_status, final_fare, current_fare, users(phone)')
              .eq('id', widget.orderId)
              .maybeSingle();
          if (orderRes != null) {
            final status = orderRes['order_status']?.toString() ?? 'searching';
            final fare = orderRes['final_fare'] ?? orderRes['current_fare'] ?? 0;
            final userMap = orderRes['users'] as Map<String, dynamic>?;
            final phoneNum = userMap?['phone']?.toString() ?? 'N/A';
            final infoText = "Order ID: ${widget.orderId}\nStatus: $status\nPrice: â‚¹$fare\nMobile: $phoneNum";
            // Insert system order details message from current user
            await supabase.from('order_chat_messages').insert({
              'sender_id': _currentUserId,
              'sender_type': _senderType,
              'message': infoText,
              'user_id': _chatUserId,
              'is_support': true,
              'order_id': widget.orderId,
            });
            // Insert agent welcoming message from 'support' sender
            await supabase.from('order_chat_messages').insert({
              'sender_id': '00000000-0000-0000-0000-000000000000', // System support UUID
              'sender_type': 'support',
              'message': 'How can I help you with this order today?',
              'user_id': _chatUserId,
              'is_support': true,
              'order_id': widget.orderId,
            });
            // Re-fetch messages locally to render instantly
            await _fetchMessages();
          }
        } catch (e) {
          debugPrint('AUTO SEND SUPPORT MESSAGE ERROR => $e');
        }
      }
    }
    if (!mounted) return;
    _subscribeChat();
    _loadOrderDetails();
    _loadIntercityRequest();
  }
  Future<void> _loadOrderDetails() async {
    if (widget.orderId.isEmpty || widget.isSupport) return;
    try {
      // Egress fix: narrowed from `*` to the fields this screen reads off _orderData (grepped
      // exhaustively across every `_orderData[...]`/`res['user_id']` access in this file) -- the
      // passenger's display name comes from widget.chatTitle (passed in by the caller), not from
      // this row, so only `phone` is needed off the joined user, matching the identical
      // `users(phone)` narrowing already used by the sibling order-info query in this same file.
      final res = await supabase
          .from('orders')
          .select(
            'user_id, order_status, order_type, pickup_address, destination_address, '
            'current_fare, final_fare, parcel_images, travel_date, users(phone)',
          )
          .eq('id', widget.orderId)
          .maybeSingle();
      if (res != null && res['user_id'] != null && widget.riderId != null && res['user_id'] == widget.riderId) {
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Cannot chat with yourself.'), backgroundColor: Colors.orange),
            );
            Navigator.pop(context);
          });
        }
        return;
      }
      if (mounted) {
        setState(() {
          _orderData = res;
        });
      }
    } catch (e) {
      debugPrint('LOAD ORDER DETAILS ERROR => $e');
    }
  }
  void _viewFullScreenImage(BuildContext context, String imageUrl) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.9),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          alignment: Alignment.center,
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.contain,
                width: double.infinity,
                height: double.infinity,
                placeholder: (_, __) => const Center(
                  child: CircularProgressIndicator(color: Colors.white30),
                ),
                errorWidget: (_, __, ___) => const Center(
                  child: Icon(Icons.broken_image_rounded, size: 48, color: Colors.white30),
                ),
              ),
            ),
            Positioned(
              top: MediaQuery.of(ctx).padding.top + 16,
              right: 16,
              child: GestureDetector(
                onTap: () => Navigator.pop(ctx),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close_rounded, color: Colors.white, size: 24),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
  void _showProposeFareDialog() {
    final fareController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: darkCard,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 1.5),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.payments_rounded, color: primaryLime, size: 22),
                  const SizedBox(width: 8),
                  const Text(
                    'Propose Custom Fare',
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Enter the fare amount you want to propose to the customer. They can agree or decline in real time.',
                style: TextStyle(color: textGray, fontSize: 12.5, height: 1.4),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F1115),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                ),
                child: TextField(
                  controller: fareController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                  decoration: const InputDecoration(
                    prefixText: '₹ ',
                    prefixStyle: TextStyle(color: primaryLime, fontWeight: FontWeight.bold),
                    hintText: 'e.g. 500',
                    hintStyle: TextStyle(color: Colors.white24, fontSize: 14),
                    border: InputBorder.none,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('CANCEL', style: TextStyle(color: Colors.white30, fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryLime,
                      foregroundColor: Colors.black,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                    onPressed: () async {
                      final amount = fareController.text.trim();
                      if (amount.isEmpty || double.tryParse(amount) == null) return;
                      Navigator.pop(ctx);
                      try {
                        final insertData = {
                          'sender_id': _currentUserId,
                          'sender_type': _senderType,
                          'message': '[PROPOSAL] ₹$amount',
                          'message_type': 'offer',
                          'metadata': {'amount': amount},
                          'user_id': _chatUserId,
                          'is_support': false,
                          'order_id': widget.orderId,
                        };
                        if (widget.riderId != null) {
                          insertData['rider_id'] = widget.riderId!;
                        }
                        await supabase.from('order_chat_messages').insert(insertData);
                        if (_intercityRequest != null) {
                          final fareVal = double.parse(amount);
                          final travelDateStr = _orderData?['travel_date']?.toString();
                          final expiresAt = travelDateStr ?? DateTime.now().add(const Duration(hours: 24)).toUtc().toIso8601String();

                          await supabase
                              .from('intercity_requests')
                              .update({
                                'proposed_fare': fareVal,
                                'status': 'discussion_started',
                                'expires_at': expiresAt,
                                'metadata': {
                                  ...(_intercityRequest?['metadata'] ?? {}),
                                  'sender_agreed': _senderType == 'user',
                                  'traveller_agreed': _senderType == 'rider',
                                }
                              })
                              .eq('id', _intercityRequest!['id']);
                          await _loadIntercityRequest();
                        }
                      } catch (e) {
                        debugPrint('SEND FARE PROPOSAL ERROR => $e');
                      }
                    },
                    child: const Text('SEND PROPOSAL', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ).then((_) => fareController.dispose());
  }
  String? _requestSubId;

  Future<void> _loadIntercityRequest() async {
    if (widget.orderId.isEmpty || widget.isSupport) return;
    String? travellerId = widget.riderId;
    if (travellerId == null) {
      travellerId = await _resolveTravellerIdForIntercityChat();
      if (travellerId == null) return; // not an intercity chat, or genuinely unresolvable
      _resolvedRiderId = travellerId;
    }
    try {
      // Egress fix: narrowed to the fields _intercityRequest is actually read for in this file
      // (grepped exhaustively across every `_intercityRequest[...]` access).
      final res = await supabase
          .from('intercity_requests')
          .select('id, metadata, proposed_fare, status, booking_type')
          .eq('parcel_id', widget.orderId)
          .eq('traveller_id', travellerId)
          .maybeSingle();
      if (mounted) {
        setState(() {
          _intercityRequest = res;
        });
        if (res != null) {
          _subscribeRequestUpdates();
        }
      }
    } catch (e) {
      debugPrint('LOAD INTERCITY REQUEST ERROR => $e');
    }
  }

  // Phase 3 fix (Issue 3): resolves the traveller's rider id for this order when the widget wasn't
  // constructed with one. If the current user IS a rider, find the request where they're the
  // traveller for this order; otherwise (the passenger) find their own request and read off its
  // traveller_id. Cheap/harmless no-op (returns null) for any order this user has no intercity
  // negotiation on at all.
  Future<String?> _resolveTravellerIdForIntercityChat() async {
    final currentUserId = _currentUserId;
    if (currentUserId == null) return null;
    try {
      final riderRow = await supabase.from('riders').select('id').eq('user_id', currentUserId).maybeSingle();
      if (riderRow != null) {
        final ownRiderId = riderRow['id']?.toString();
        if (ownRiderId == null) return null;
        final req = await supabase
            .from('intercity_requests')
            .select('traveller_id')
            .eq('parcel_id', widget.orderId)
            .eq('traveller_id', ownRiderId)
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle();
        return req?['traveller_id']?.toString();
      }
      final req = await supabase
          .from('intercity_requests')
          .select('traveller_id')
          .eq('parcel_id', widget.orderId)
          .eq('sender_id', currentUserId)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      return req?['traveller_id']?.toString();
    } catch (e) {
      debugPrint('RESOLVE TRAVELLER ID FOR CHAT ERROR => $e');
      return null;
    }
  }

  void _subscribeRequestUpdates() {
    if (_requestSubId != null) {
      RealtimeManager.instance.unsubscribe('intercity-request-${widget.orderId}-$_effectiveRiderId', _requestSubId!);
      _requestSubId = null;
    }
    _requestSubId = RealtimeManager.instance.subscribe(
      channelName: 'intercity-request-${widget.orderId}-$_effectiveRiderId',
      table: 'intercity_requests',
      owner: 'OrderChatScreen',
      filterColumn: 'parcel_id',
      filterValue: widget.orderId,
      callback: (payload) {
        if (!mounted) return;
        final newRec = payload.newRecord;
        if (newRec.isEmpty) return;
        if (newRec['traveller_id']?.toString() == _effectiveRiderId) {
          setState(() {
            _intercityRequest = Map<String, dynamic>.from(newRec);
          });
        }
      },
    );
  }

  Future<void> _acceptOffer() async {
    try {
      final actorType = _senderType == 'user' ? 'sender' : 'traveller';
      final res = await supabase.rpc('accept_intercity_offer', params: {
        'p_request_id': _intercityRequest!['id'],
        'p_actor_type': actorType,
      });
      await _loadIntercityRequest();
      await _loadOrderDetails();
      
      final updatedStatus = res?['status']?.toString();
      if (updatedStatus == 'fare_agreed') {
        final amount = _intercityRequest!['proposed_fare'];
        final insertData = {
          'sender_id': _currentUserId,
          'sender_type': _senderType,
          'message': '[AGREED] Fare updated to ₹$amount',
          'message_type': 'offer',
          'metadata': {'amount': amount},
          'user_id': _chatUserId,
          'is_support': false,
          'order_id': widget.orderId,
        };
        if (widget.riderId != null) {
          insertData['rider_id'] = widget.riderId!;
        }
        await supabase.from('order_chat_messages').insert(insertData);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to accept offer: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _rejectOffer() async {
    try {
      final actorType = _senderType == 'user' ? 'sender' : 'traveller';
      await IntercityMatchingService.rejectTravelTogetherRequest(
        requestId: _intercityRequest!['id'].toString(),
        actorType: actorType,
      );
      await _loadIntercityRequest();
      await _loadOrderDetails();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to reject request: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _confirmBooking() async {
    try {
      await supabase.rpc('confirm_intercity_booking', params: {
        'p_request_id': _intercityRequest!['id'],
      });
      await _loadIntercityRequest();
      await _loadOrderDetails();
    } catch (e) {
      if (mounted) {
        // Part 15: surface the passenger double-booking guard with the exact spec copy instead
        // of the raw Postgres exception text.
        final message = e.toString().contains('Passenger already confirmed another trip')
            ? 'Passenger already confirmed another trip.'
            : 'Failed to confirm booking: $e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: Colors.red),
        );
      }
    }
  }

  // The order's rider_id/order_status/current_fare/final_fare are already set correctly (with a
  // fully recomputed commission/GST/rider-earning breakdown) by confirm_intercity_booking() at the
  // confirm step. Direct writes to 'orders' from here were both redundant with that and, in
  // practice, a no-op: by this point order_status is no longer 'searching', so the RLS policy that
  // would otherwise permit this client to update its own order no longer applies. payment_status
  // itself is never set at booking time either way -- exactly like local rides/parcels, an
  // intercity trip's cash/UPI payment is only ever marked 'paid' at trip completion, once the
  // driver actually confirms receipt.
  Future<void> _payBooking() async {
    try {
      await supabase
          .from('intercity_requests')
          .update({'status': 'paid'})
          .eq('id', _intercityRequest!['id']);
      await _loadIntercityRequest();
      await _loadOrderDetails();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Payment failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // SECURITY/INTEGRITY FIX: this used to write orders.order_status directly once both handover
  // flags were true, trusting its own client-side computation of "both are true" and with no
  // participant check on the caller. Now delegates to confirm_intercity_handover(), a SECURITY
  // DEFINER RPC that derives which flag to set from auth.uid() itself (never a client-supplied
  // actor type), verifies the caller is actually a participant on the order, and re-reads both
  // flags from the row it just wrote before ever transitioning order_status. See migration
  // 20260730000007_confirm_intercity_handover.sql.
  Future<void> _confirmHandover() async {
    try {
      final response = await supabase.rpc('confirm_intercity_handover', params: {
        'p_order_id': widget.orderId,
      });
      final data = response is Map ? Map<String, dynamic>.from(response) : null;
      if (data == null || data['success'] != true) {
        throw Exception((data?['message'] as String?) ?? 'Failed to confirm handover. Please try again.');
      }

      await _loadIntercityRequest();
      await _loadOrderDetails();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to confirm handover: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _buildIntercityHeader() {
    if (_intercityRequest == null) return const SizedBox.shrink();
    
    final status = _intercityRequest!['status']?.toString() ?? 'request_sent';
    final proposedFare = double.tryParse(_intercityRequest!['proposed_fare']?.toString() ?? '0') ?? 0.0;

    // WHOLE-RUPEE FARE CONSISTENCY FIX: 'proposed_fare' is the raw, unrounded negotiated figure
    // (set from a Travel Plan's price_per_seat or later in-chat haggling) -- it is NEVER rounded
    // in the database. The only place a negotiated fare becomes authoritative and whole-rupee is
    // accept_intercity_request(), which rounds it via calculate_fare_breakdown() and writes the
    // result into orders.current_fare/final_fare. Before this fix, this header always displayed
    // the raw proposedFare, even for status == 'confirmed'/'paid' (i.e. AFTER acceptance) -- so a
    // rider/passenger could see e.g. "Fare Agreed at ₹23.64" pre-acceptance and still see
    // "Booking Locked • Fare: ₹23.64" post-acceptance, while the actual order (and the amount
    // charged/settled) was really ₹24. Once the order carries its own authoritative fare (any
    // status past negotiation), that value is used instead; only the negotiation-stage statuses
    // fall back to a DISPLAY-only whole-rupee rounding of proposedFare (never written anywhere --
    // see roundFareForDisplay()) so the number shown never changes the instant acceptance happens.
    final isPreAcceptance = status == 'request_sent' || status == 'discussion_started' || status == 'fare_agreed';
    final authoritativeOrderFare = isPreAcceptance
        ? null
        : double.tryParse(_orderData?['final_fare']?.toString() ?? _orderData?['current_fare']?.toString() ?? '');
    final displayFare = authoritativeOrderFare ?? roundFareForDisplay(proposedFare);

    final metadata = _intercityRequest!['metadata'] as Map<String, dynamic>? ?? {};
    final senderAgreed = metadata['sender_agreed'] == true;
    final travellerAgreed = metadata['traveller_agreed'] == true;
    
    final isRide = _intercityRequest!['booking_type'] == 'ride';
    final orderStatus = _orderData?['order_status']?.toString() ?? '';
    final tripStarted = ['picked_up', 'ongoing', 'rider_at_drop', 'payment_pending', 'completed'].contains(orderStatus);
    
    Color statusColor = primaryLime;
    String statusText = '';
    Widget actionButton = const SizedBox.shrink();
    
    if (status == 'request_sent' || status == 'discussion_started') {
      statusColor = Colors.orangeAccent;
      final selfAgreed = _senderType == 'user' ? senderAgreed : travellerAgreed;
      
      statusText = 'Fare: ₹$displayFare\n'
          '${senderAgreed ? "✓ Sender Agreed" : "⏳ Sender Awaiting"} • '
          '${travellerAgreed ? "✓ Traveller Agreed" : "⏳ Traveller Awaiting"}';
          
      if (selfAgreed) {
        actionButton = Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: primaryLime.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: primaryLime.withValues(alpha: 0.3)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle_rounded, color: primaryLime, size: 14),
              SizedBox(width: 4),
              Text('AGREED', style: TextStyle(color: primaryLime, fontSize: 11, fontWeight: FontWeight.bold)),
            ],
          ),
        );
      } else {
        actionButton = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.redAccent,
                side: const BorderSide(color: Colors.redAccent),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              onPressed: _rejectOffer,
              child: const Text('REJECT', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryLime,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              onPressed: _acceptOffer,
              child: const Text('AGREE TO FARE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      }
    } else if (status == 'fare_agreed') {
      statusColor = Colors.greenAccent;
      statusText = 'Fare Agreed at ₹$displayFare! ✓';
      
      actionButton = ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryLime,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
        onPressed: _confirmBooking,
        child: const Text('CONFIRM BOOKING', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
      );
    } else if (status == 'confirmed') {
      statusColor = Colors.blueAccent;
      statusText = 'Booking Locked • Fare: ₹$displayFare';
      
      if (_senderType == 'user') {
        actionButton = ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          ),
          onPressed: _payBooking,
          child: Text('PAY ₹$displayFare', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
        );
      } else {
        actionButton = const Text(
          'Awaiting Payment...',
          style: TextStyle(color: textGray, fontSize: 11, fontStyle: FontStyle.italic),
        );
      }
    } else if (status == 'paid') {
      if (!tripStarted) {
        statusColor = Colors.yellowAccent;
        final senderHandover = metadata['sender_handover_confirmed'] == true;
        final riderHandover = metadata['rider_handover_confirmed'] == true;
        
        final selfHandover = _senderType == 'user' ? senderHandover : riderHandover;
        final label = isRide ? 'DEPARTURE' : 'HANDOVER';
        
        statusText = 'Paid • '
            'Sender: ${senderHandover ? "Ready ✓" : "Waiting ⏳"}\n'
            'Traveller: ${riderHandover ? "Ready ✓" : "Waiting ⏳"}';
            
        if (selfHandover) {
          actionButton = const Text(
            'Ready to go ✓',
            style: TextStyle(color: primaryLime, fontSize: 11, fontWeight: FontWeight.bold),
          );
        } else {
          actionButton = ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryLime,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            onPressed: _confirmHandover,
            child: Text('CONFIRM $label', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          );
        }
      } else {
        statusColor = primaryLime;
        statusText = 'Trip Started! Status: ${orderStatus.toUpperCase()}';
        actionButton = Container(
          padding: const EdgeInsets.all(6),
          decoration: const BoxDecoration(
            color: Colors.white10,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.navigation_rounded, color: primaryLime, size: 16),
        );
      }
    } else if (status == 'in_progress') {
      statusColor = primaryLime;
      statusText = 'Trip Started! Status: ${orderStatus.toUpperCase()}';
      actionButton = Container(
        padding: const EdgeInsets.all(6),
        decoration: const BoxDecoration(
          color: Colors.white10,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.navigation_rounded, color: primaryLime, size: 16),
      );
    } else if (status == 'completed') {
      statusColor = primaryLime;
      statusText = 'Trip Completed ✓';
    } else if (status == 'expired') {
      statusColor = Colors.redAccent;
      statusText = 'Request Expired ❌';
    } else if (status == 'cancelled') {
      statusColor = Colors.redAccent;
      statusText = 'Booking Cancelled ❌';
    } else if (status == 'rejected') {
      statusColor = Colors.redAccent;
      statusText = 'Request Rejected ❌';
    }
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: darkCard,
        border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'INTERCITY NEGOTIATION',
                  style: TextStyle(color: textGray, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                ),
                const SizedBox(height: 2),
                Text(
                  statusText,
                  style: TextStyle(color: statusColor, fontSize: 12.5, fontWeight: FontWeight.bold, height: 1.3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          actionButton,
        ],
      ),
    );
  }
  Widget _buildOrderPanel() {
    if (_orderData == null) return const SizedBox();
    final pickup = _orderData!['pickup_address'] ?? 'Pickup';
    final dest = _orderData!['destination_address'] ?? 'Destination';
    final currentFare = _orderData!['current_fare'] ?? 0;
    final finalFare = _orderData!['final_fare'] ?? currentFare;
    final isParcel = _orderData!['order_type'] == 'local_parcel' || _orderData!['order_type'] == 'intercity_parcel';
    final rawImages = _orderData!['parcel_images'];
    List<String> parcelImages = [];
    if (rawImages is List) {
      parcelImages = rawImages.map((e) => e.toString()).toList();
    } else if (rawImages is String && rawImages.isNotEmpty) {
      try {
        final parsed = jsonDecode(rawImages);
        if (parsed is List) {
          parcelImages = parsed.map((e) => e.toString()).toList();
        }
      } catch (_) {}
    }
    return Container(
      decoration: BoxDecoration(
        color: darkCard,
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08), width: 1),
        ),
      ),
      child: Column(
        children: [
          GestureDetector(
            onTap: () {
              setState(() {
                _orderPanelExpanded = !_orderPanelExpanded;
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: Colors.white.withValues(alpha: 0.01),
              child: Row(
                children: [
                  Icon(
                    isParcel ? Icons.local_shipping_rounded : Icons.directions_car_rounded,
                    color: primaryLime,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Order Details & Negotiation',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '₹${finalFare.toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: primaryLime,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    _orderPanelExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    color: Colors.white54,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
          if (_orderPanelExpanded) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(color: Colors.white10, height: 1),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Column(
                        children: [
                          const Icon(Icons.my_location_rounded, color: Colors.greenAccent, size: 14),
                          Container(width: 1, height: 20, color: Colors.white10),
                          const Icon(Icons.location_on_rounded, color: Colors.redAccent, size: 14),
                        ],
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              pickup,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w500),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              dest,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (isParcel && parcelImages.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'PARCEL IMAGE(S)',
                      style: TextStyle(color: Colors.white30, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 52,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: parcelImages.length,
                        itemBuilder: (context, index) {
                          return Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: GestureDetector(
                              onTap: () => _viewFullScreenImage(context, parcelImages[index]),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: CachedNetworkImage(
                                  imageUrl: parcelImages[index],
                                  width: 52,
                                  height: 52,
                                  fit: BoxFit.cover,
                                  memCacheWidth: 104,
                                  memCacheHeight: 104,
                                  placeholder: (_, __) => Container(
                                    width: 52, height: 52,
                                    color: Colors.white10,
                                  ),
                                  errorWidget: (_, __, ___) => Container(
                                    width: 52, height: 52,
                                    color: Colors.white10,
                                    child: const Icon(Icons.broken_image_rounded, size: 16, color: Colors.white30),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                  if (_senderType == 'user' && _intercityRequest != null && _intercityRequest!['status'] == 'discussion_started') ...[
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      height: 38,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primaryLime,
                          foregroundColor: Colors.black,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: _showProposeFareDialog,
                        icon: const Icon(Icons.payments_rounded, size: 16),
                        label: const Text(
                          'PROPOSE NEW FARE',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
  Future<void> _fetchMessages() async {
    try {
      // R14 perf fix: narrowed from a bare select() (every column) to exactly the fields this
      // screen ever reads off a fetched message row -- verified via a full grep of every
      // msg['...']/m['...'] access in this file: id, sender_id, sender_type, message,
      // message_type, created_at. order_id/rider_id/user_id/is_support are used only as .eq()
      // filter predicates above (PostgREST filters don't require the filtered column to be in
      // the select list), never read from a result row afterward. Realtime-appended messages
      // (the _subscribeChat() callback below) still receive the full row regardless of this
      // projection -- Postgres Changes always sends the complete row -- so there is no shape
      // mismatch between initially-fetched and realtime-appended messages for any field this
      // screen actually consumes.
      var query = supabase
          .from('order_chat_messages')
          .select('id, sender_id, sender_type, message, message_type, created_at');
      if (widget.isSupport) {
        query = query.eq('is_support', true).eq('user_id', _chatUserId!);
      } else {
        query = query.eq('order_id', widget.orderId);
        if (widget.riderId != null) {
          query = query.eq('rider_id', widget.riderId!);
        }
      }
      final res = await query.order('created_at', ascending: true);
      if (mounted) {
        setState(() {
          _messages = List<Map<String, dynamic>>.from(res);
          _loading = false;
        });
        await _loadOfflineMessagesIntoList();
        _scrollToBottom();
      }
    } catch (e) {
      debugPrint('FETCH MESSAGES ERROR => $e');
      if (mounted) {
        setState(() {
          _loading = false;
        });
        await _loadOfflineMessagesIntoList();
        _scrollToBottom();
      }
      final isNetworkErr = e.toString().contains('SocketException') ||
                           e.toString().contains('ClientException') ||
                           e.toString().contains('Failed host lookup');
      if (isNetworkErr) {
        _startSyncTimer();
      }
    }
  }
  void _subscribeChat() {
    var channelName = widget.isSupport
        ? 'support-chat-$_chatUserId'
        : 'order-chat-${widget.orderId}-${widget.riderId}';
    _chatChannel = supabase
        .channel(channelName)
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'order_chat_messages',
          filter: widget.isSupport
              ? PostgresChangeFilter(
                  type: PostgresChangeFilterType.eq,
                  column: 'user_id',
                  value: _chatUserId!,
                )
              : PostgresChangeFilter(
                  type: PostgresChangeFilterType.eq,
                  column: 'order_id',
                  value: widget.orderId,
                ),
          callback: (payload) {
            final newMsg = payload.newRecord;
            if (newMsg.isEmpty) return;
            // In order negotiation, make sure rider matches too
            if (!widget.isSupport && widget.riderId != null && newMsg['rider_id']?.toString() != widget.riderId) {
              return;
            }
            // In support chat, filter by is_support
            if (widget.isSupport && newMsg['is_support'] != true) {
              return;
            }
            if (mounted) {
              setState(() {
                final id = newMsg['id']?.toString();
                final exists = _messages.any((m) => m['id']?.toString() == id);
                if (!exists) {
                  _messages.add(Map<String, dynamic>.from(newMsg));
                }
              });
              _scrollToBottom();
            }
          },
        )
        .subscribe();
  }
  // Chat is scoped to a single ride: once that ride has ended, it must stop accepting new
  // messages so a finished ride's thread can never be mistaken for (or reused as) the next
  // one's. History stays visible/retained for support and audit -- only sending is blocked.
  bool get _isRideEnded {
    if (widget.isSupport) return false;
    final status = _orderData?['order_status']?.toString();
    return status == 'completed' || status == 'cancelled';
  }

  Future<void> _sendMessage() async {
    if (_isRideEnded) return;
    // Issue 6A fix: messaging is intentionally blocked before the traveller responds to a Travel
    // Together request (intercity_requests.status == 'request_sent') -- previously only enforced
    // decoratively (the TextField's `enabled` flag), so a send attempted while _intercityRequest
    // hadn't loaded yet (e.g. this screen opened from a notification tap without riderId) could
    // still be tried and fail into the raw red error SnackBar below. Guarding here makes the block
    // itself airtight and replaces that failure path with a normal, non-alarming info message.
    if (_intercityRequest != null && _intercityRequest!['status'] == 'request_sent') {
      final isTravellerSide = _senderType == 'rider';
      showAppSnackBar(
        context,
        isTravellerSide
            ? 'Accept the request to start chatting with the passenger.'
            : 'You can chat once the traveller responds to your request.',
        type: SnackBarType.info,
      );
      return;
    }
    final text = _messageController.text.trim();
    if (text.isEmpty || _currentUserId == null || _chatUserId == null) return;
    _messageController.clear();

    final tempId = 'temp_${DateTime.now().millisecondsSinceEpoch}';
    final insertData = {
      'id': tempId,
      'sender_id': _currentUserId,
      'sender_type': _senderType,
      'message': text,
      'user_id': _chatUserId, // The client user owning the support session
      'is_support': widget.isSupport,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'is_offline': true,
    };
    if (widget.orderId.isNotEmpty) {
      insertData['order_id'] = widget.orderId;
    }
    if (_effectiveRiderId != null) {
      insertData['rider_id'] = _effectiveRiderId!;
    }

    if (mounted) {
      setState(() {
        _messages.add(insertData);
      });
      _scrollToBottom();
    }

    try {
      final sendData = Map<String, dynamic>.from(insertData);
      sendData.remove('id');
      sendData.remove('is_offline');

      // Egress fix: same narrowing as the offline-queue sync insert above -- only the fields
      // _messages rendering actually reads.
      final inserted = await supabase
          .from('order_chat_messages')
          .insert(sendData)
          .select('id, sender_id, sender_type, message, message_type, created_at')
          .single()
          .timeout(const Duration(seconds: 8));

      if (mounted) {
        setState(() {
          _messages = mergeSentMessage(_messages, tempId, Map<String, dynamic>.from(inserted));
        });
      }
    } catch (e) {
      debugPrint('SEND MESSAGE ERROR => $e');
      final isNetworkErr = e.toString().contains('SocketException') ||
                           e.toString().contains('ClientException') ||
                           e.toString().contains('Failed host lookup') ||
                           e.toString().contains('Timeout') ||
                           e.toString().contains('Network') ||
                           e.toString().contains('connection');

      if (isNetworkErr) {
        await _queueOfflineMessage(insertData);
      } else {
        if (mounted) {
          setState(() {
            _messages.removeWhere((m) => m['id'] == tempId);
          });
          // Phase 3 fix (Issue 3): a raw RLS denial (42501) must never reach the user as backend
          // implementation detail -- this is a defense-in-depth safety net alongside the actual
          // root-cause fix above (_effectiveRiderId resolution). RLS itself is untouched/unweakened;
          // only the text shown here is sanitized.
          final isRlsDenied = e is PostgrestException && e.code == '42501';
          if (isRlsDenied) {
            showAppSnackBar(
              context,
              'You can send messages after the request is accepted.',
              type: SnackBarType.info,
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to send message: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      }
    }
  }
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showAttachmentMenu() {
    if (_isRideEnded) return;
    final status = _intercityRequest?['status']?.toString();
    final isLocked = ['request_sent', 'discussion_started', 'fare_agreed', 'confirmed'].contains(status);

    if (isLocked) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: darkCard,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Colors.white10)),
          title: const Row(
            children: [
              Icon(Icons.lock_rounded, color: Colors.orangeAccent),
              SizedBox(width: 8),
              Text('Features Locked', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          content: const Text(
            'Rich features like Calls, Images, Location, and Voice notes are locked until booking payment is completed.',
            style: TextStyle(color: textGray, fontSize: 13, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK', style: TextStyle(color: primaryLime)),
            ),
          ],
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: darkCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Container(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Share Content',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildAttachmentItem(Icons.phone_rounded, 'Call', () {
                  Navigator.pop(ctx);
                  _handleCallAction();
                }),
                _buildAttachmentItem(Icons.image_rounded, 'Image', () {
                  Navigator.pop(ctx);
                  _handleImageAction();
                }),
                _buildAttachmentItem(Icons.location_on_rounded, 'Location', () {
                  Navigator.pop(ctx);
                  _handleLocationAction();
                }),
                _buildAttachmentItem(Icons.mic_rounded, 'Voice', () {
                  Navigator.pop(ctx);
                  _handleVoiceAction();
                }),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttachmentItem(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E222B),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white10),
            ),
            child: Icon(icon, color: primaryLime, size: 24),
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(color: textGray, fontSize: 12)),
        ],
      ),
    );
  }

  Future<void> _handleCallAction() async {
    final phone = _orderData?['users']?['phone']?.toString();
    if (phone != null && phone.isNotEmpty) {
      final url = Uri.parse('tel:$phone');
      if (await canLaunchUrl(url)) {
        await launchUrl(url);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cannot initiate call. Dialer not available.')),
          );
        }
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Phone number not available.')),
      );
    }
  }

  Future<void> _handleImageAction() async {
    if (_isRideEnded) return;
    // Issue 3 fix: mirrors _sendMessage()'s pre-acceptance guard (Issue 6A) -- the image/attachment
    // button was reachable and functional even while messaging is blocked
    // (intercity_requests.status == 'request_sent'), letting an image reach the database before
    // the traveller ever accepted the request. Same guard, same clean message, applied here too.
    if (_intercityRequest != null && _intercityRequest!['status'] == 'request_sent') {
      final isTravellerSide = _senderType == 'rider';
      showAppSnackBar(
        context,
        isTravellerSide
            ? 'Accept the request to start chatting with the passenger.'
            : 'You can chat once the traveller responds to your request.',
        type: SnackBarType.info,
      );
      return;
    }
    try {
      final picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.gallery);
      if (image == null) return;
      
      final insertData = {
        'sender_id': _currentUserId,
        'sender_type': _senderType,
        'message': '[IMAGE] gallery_photo.png',
        'message_type': 'image',
        'metadata': {'url': 'https://yvwpchffctiagevpqgwy.supabase.co/storage/v1/object/public/chat_attachments/mock.png'},
        'user_id': _chatUserId,
        'is_support': false,
        'order_id': widget.orderId,
      };
      if (widget.riderId != null) {
        insertData['rider_id'] = widget.riderId!;
      }
      await supabase.from('order_chat_messages').insert(insertData);
    } catch (e) {
      debugPrint('Image Action Error: $e');
    }
  }

  Future<void> _handleLocationAction() async {
    try {
      final insertData = {
        'sender_id': _currentUserId,
        'sender_type': _senderType,
        'message': '[LOCATION] Lat: 17.3850, Lng: 78.4867',
        'message_type': 'location',
        'metadata': {'latitude': 17.3850, 'longitude': 78.4867, 'address': 'Current Location'},
        'user_id': _chatUserId,
        'is_support': false,
        'order_id': widget.orderId,
      };
      if (widget.riderId != null) {
        insertData['rider_id'] = widget.riderId!;
      }
      await supabase.from('order_chat_messages').insert(insertData);
    } catch (e) {
      debugPrint('Location Action Error: $e');
    }
  }

  Future<void> _handleVoiceAction() async {
    try {
      final insertData = {
        'sender_id': _currentUserId,
        'sender_type': _senderType,
        'message': '🎤 Voice Note (0:05)',
        'message_type': 'text',
        'metadata': {'duration': 5},
        'user_id': _chatUserId,
        'is_support': false,
        'order_id': widget.orderId,
      };
      if (widget.riderId != null) {
        insertData['rider_id'] = widget.riderId!;
      }
      await supabase.from('order_chat_messages').insert(insertData);
    } catch (e) {
      debugPrint('Voice Action Error: $e');
    }
  }
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const primaryColor = Color(0xFF7C3AED);
    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF1E222B) : Colors.grey.shade50,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF171A21) : Colors.white,
        elevation: 0.5,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: isDark ? Colors.white : Colors.black),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            Container(
              height: 38,
              width: 38,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E222B) : Colors.grey.shade200,
                shape: BoxShape.circle,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(19),
                child: widget.riderImage != null && widget.riderImage!.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: widget.riderImage!,
                        fit: BoxFit.cover,
                        memCacheWidth: 76,
                        memCacheHeight: 76,
                        errorWidget: (context, error, stackTrace) =>
                            const Icon(Icons.person, color: primaryColor),
                      )
                    : const Icon(Icons.person, color: primaryColor),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.chatTitle,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black,
                    ),
                  ),
                  if (widget.isSupport) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Customer Support',
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        actions: const [],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: primaryColor),
                  )
                : _messages.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.chat_bubble_outline_rounded,
                              size: 48,
                              color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade300,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              widget.isSupport
                                  ? 'How can we help you today?'
                                  : 'Start negotiating details & pricing',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark ? const Color(0xFF64748B) : Colors.grey,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(16),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final msg = _messages[index];
                          final senderType = msg['sender_type']?.toString();
                          final bool isRight = isChatMessageMine(msg, _currentUserId);
                          final messageText = msg['message'] ?? '';
                          final isOffline = msg['is_offline'] == true;
                          final timestamp = DateTime.parse(msg['created_at']).toLocal();
                          final timeStr = isOffline
                              ? "Pending 🕒"
                              : "${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}";
                          final isProposal = msg['message_type'] == 'offer' || messageText.startsWith('[PROPOSAL] ₹');
                          final isAgreement = messageText.startsWith('[AGREED] Fare updated to ₹');
                          final isDecline = messageText.startsWith('[DECLINED] Fare proposal of ₹');
                          if (isProposal) {
                            final amount = messageText.replaceAll('[PROPOSAL] ₹', '').trim();
                            Color bubbleColor = isRight ? primaryColor : (isDark ? const Color(0xFF171A21) : Colors.white);
                            Color textCol = isRight ? Colors.white : (isDark ? Colors.white : const Color(0xFF0F172A));
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12.0),
                              child: Row(
                                mainAxisAlignment: isRight ? MainAxisAlignment.end : MainAxisAlignment.start,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Flexible(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                      decoration: BoxDecoration(
                                        color: bubbleColor,
                                        borderRadius: BorderRadius.only(
                                          topLeft: const Radius.circular(16),
                                          topRight: const Radius.circular(16),
                                          bottomLeft: isRight ? const Radius.circular(16) : const Radius.circular(2),
                                          bottomRight: isRight ? const Radius.circular(2) : const Radius.circular(16),
                                        ),
                                        border: !isRight
                                            ? Border.all(color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade200, width: 1)
                                            : null,
                                      ),
                                      child: Column(
                                        crossAxisAlignment: isRight ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.payments_rounded, color: isRight ? Colors.white : primaryColor, size: 16),
                                              const SizedBox(width: 6),
                                              Text(
                                                'Proposed Fare: ₹$amount',
                                                style: TextStyle(
                                                  fontSize: 13.5,
                                                  color: textCol,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ],
                                          ),
                                          if (!isRight && _senderType == 'user') ...[
                                            const SizedBox(height: 10),
                                            Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                SizedBox(
                                                  height: 28,
                                                  child: TextButton(
                                                    style: TextButton.styleFrom(
                                                      foregroundColor: Colors.redAccent,
                                                      padding: const EdgeInsets.symmetric(horizontal: 10),
                                                      shape: RoundedRectangleBorder(
                                                        borderRadius: BorderRadius.circular(6),
                                                        side: const BorderSide(color: Colors.redAccent, width: 1),
                                                      ),
                                                    ),
                                                    onPressed: () async {
                                                      try {
                                                        final insertData = {
                                                          'sender_id': _currentUserId,
                                                          'sender_type': 'user',
                                                          'message': '[DECLINED] Fare proposal of ₹$amount declined',
                                                          'user_id': _chatUserId,
                                                          'is_support': false,
                                                          'order_id': widget.orderId,
                                                        };
                                                        if (widget.riderId != null) {
                                                          insertData['rider_id'] = widget.riderId!;
                                                        }
                                                        await supabase.from('order_chat_messages').insert(insertData);
                                                      } catch (_) {}
                                                    },
                                                    child: const Text('Decline', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                SizedBox(
                                                  height: 28,
                                                  child: ElevatedButton(
                                                    style: ElevatedButton.styleFrom(
                                                      backgroundColor: const Color(0xFF22C55E),
                                                      foregroundColor: Colors.white,
                                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                                      elevation: 0,
                                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                                    ),
                                                    onPressed: () async {
                                                      // NOTE: this in-chat "Accept" only logs agreement to the chat; it deliberately does
                                                      // NOT write current_fare/final_fare directly. A direct client write here could never
                                                      // recompute commission_amount/gst_amount/rider_earning to match (the same staleness
                                                      // bug fixed for the structured intercity negotiation flow via
                                                      // confirm_intercity_booking()), and would silently no-op under RLS for any order
                                                      // past "searching" regardless. A proposed in-chat fare change for an
                                                      // already-assigned order has no canonical server-side acceptance path yet -- until
                                                      // one exists, this button only records the agreement message.
                                                      try {
                                                        final insertData = {
                                                          'sender_id': _currentUserId,
                                                          'sender_type': 'user',
                                                          'message': '[AGREED] Fare updated to ₹$amount',
                                                          'user_id': _chatUserId,
                                                          'is_support': false,
                                                          'order_id': widget.orderId,
                                                        };
                                                        if (widget.riderId != null) {
                                                          insertData['rider_id'] = widget.riderId!;
                                                        }
                                                        await supabase.from('order_chat_messages').insert(insertData);
                                                        _loadOrderDetails();
                                                      } catch (_) {}
                                                    },
                                                    child: const Text('Accept', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ] else ...[
                                            const SizedBox(height: 4),
                                            Text(
                                              isRight ? 'Awaiting response...' : 'Propose a new fare if needed',
                                              style: TextStyle(
                                                color: textCol.withOpacity(0.65),
                                                fontSize: 10.5,
                                                fontStyle: FontStyle.italic,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }
                          final isRiderAccept = messageText.startsWith('[AGREED] Rider accepted the');
                          if (isRiderAccept) {
                            final otpPart = messageText.split('OTP: ').length > 1 ? 'OTP: ' + messageText.split('OTP: ')[1] : '';
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6.0),
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: isDark ? const Color(0xFF1E293B).withOpacity(0.4) : Colors.grey.shade200,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.check_circle_outline_rounded, color: Color(0xFF22C55E), size: 13),
                                      const SizedBox(width: 4),
                                      Text(
                                        '✓ Booking confirmed ${otpPart.isNotEmpty ? "($otpPart)" : ""}',
                                        style: TextStyle(
                                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }
                          if (isAgreement) {
                            final amount = messageText.replaceAll('[AGREED] Fare updated to ₹', '').trim();
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6.0),
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: isDark ? const Color(0xFF1E293B).withOpacity(0.4) : Colors.grey.shade200,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.check_circle_outline_rounded, color: Color(0xFF22C55E), size: 13),
                                      const SizedBox(width: 4),
                                      Text(
                                        '✓ Fare accepted: ₹$amount',
                                        style: TextStyle(
                                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }
                          if (isDecline) {
                            final amount = messageText.replaceAll('[DECLINED] Fare proposal of ₹', '').replaceAll('declined', '').trim();
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6.0),
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: isDark ? const Color(0xFF1E293B).withOpacity(0.4) : Colors.grey.shade200,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.cancel_outlined, color: Colors.redAccent, size: 13),
                                      const SizedBox(width: 4),
                                      Text(
                                        '✕ Fare declined: ₹$amount',
                                        style: TextStyle(
                                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }
                           Color bubbleColor;
                          Color textCol;
                          if (isRight) {
                            bubbleColor = _senderType == 'admin' ? const Color(0xFF10B981) : primaryColor;
                            textCol = Colors.white;
                          } else {
                            bubbleColor = senderType == 'admin'
                                ? const Color(0xFF10B981).withValues(alpha: 0.15)
                                : (isDark ? const Color(0xFF171A21) : Colors.white);
                            textCol = isDark ? Colors.white : const Color(0xFF0F172A);
                          }
                          if (isOffline) {
                            bubbleColor = bubbleColor.withValues(alpha: 0.65);
                          }
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12.0),
                            child: Row(
                              mainAxisAlignment:
                                  isRight ? MainAxisAlignment.end : MainAxisAlignment.start,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Flexible(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: bubbleColor,
                                      borderRadius: BorderRadius.only(
                                        topLeft: const Radius.circular(16),
                                        topRight: const Radius.circular(16),
                                        bottomLeft: isRight
                                            ? const Radius.circular(16)
                                            : const Radius.circular(2),
                                        bottomRight: isRight
                                            ? const Radius.circular(2)
                                            : const Radius.circular(16),
                                      ),
                                      border: !isRight && senderType != 'admin'
                                          ? Border.all(
                                              color: isDark
                                                  ? const Color(0xFF1E293B)
                                                  : Colors.grey.shade200,
                                              width: 1,
                                            )
                                          : (senderType == 'admin' && !isRight
                                              ? Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3))
                                              : null),
                                      boxShadow: [
                                        if (!isRight)
                                          BoxShadow(
                                            color: Colors.black.withValues(alpha: 0.02),
                                            blurRadius: 4,
                                            offset: const Offset(0, 2),
                                          )
                                      ],
                                    ),
                                    child: Column(
                                      crossAxisAlignment: isRight
                                          ? CrossAxisAlignment.end
                                          : CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (widget.isSupport && !isRight) ...[
                                          Text(
                                            senderType == 'admin' ? 'Support Agent' : 'Client',
                                            style: TextStyle(
                                              fontSize: 9,
                                              fontWeight: FontWeight.bold,
                                              color: senderType == 'admin' ? const Color(0xFF10B981) : Colors.grey,
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                        ],
                                        Text(
                                          messageText,
                                          style: TextStyle(
                                            fontSize: 13.5,
                                            color: textCol,
                                            height: 1.4,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          timeStr,
                                          style: TextStyle(
                                            fontSize: 8.5,
                                            color: isRight
                                                ? Colors.white.withValues(alpha: 0.7)
                                                : (isDark
                                                    ? const Color(0xFF64748B)
                                                    : Colors.grey),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.of(context).padding.bottom + 12),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF171A21) : Colors.white,
              border: Border(
                top: BorderSide(
                  color: isDark ? const Color(0xFF1E293B) : Colors.grey.shade200,
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                Opacity(
                  opacity: _isRideEnded ? 0.35 : 1.0,
                  child: GestureDetector(
                    onTap: _handleImageAction,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1E222B) : Colors.grey.shade100,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.image_rounded,
                        color: primaryLime,
                        size: 20,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E222B) : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: isDark ? const Color(0xFF1E293B) : Colors.transparent,
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: _messageController,
                      style: TextStyle(
                        fontSize: 14,
                        color: isDark ? Colors.white : Colors.black,
                      ),
                      maxLines: null,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                      enabled: !_isRideEnded &&
                          (_intercityRequest == null || _intercityRequest!['status'] != 'request_sent'),
                      decoration: InputDecoration(
                        hintText: _isRideEnded
                            ? 'This ride has ended. Chat is read-only.'
                            : (_intercityRequest != null && _intercityRequest!['status'] == 'request_sent')
                                ? 'Awaiting discussion acceptance...'
                                : 'Type a message...',
                        hintStyle: const TextStyle(fontSize: 13, color: Colors.grey),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Opacity(
                  opacity: _isRideEnded ? 0.35 : 1.0,
                  child: GestureDetector(
                    onTap: _sendMessage,
                    child: Container(
                      height: 40,
                      width: 40,
                      decoration: const BoxDecoration(
                        color: primaryColor,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.send_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}