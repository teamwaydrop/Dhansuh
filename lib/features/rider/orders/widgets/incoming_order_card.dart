import 'package:waydrop/core/services/diagnostics/ride_diagnostics.dart';
import 'package:waydrop/core/services/diagnostics/ride_diagnostics_owner.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:waydrop/shared/widgets/app_snackbar.dart';
import 'package:waydrop/core/services/location/location_cache_service.dart';
import 'package:cached_network_image/cached_network_image.dart';

class IncomingOrderCard extends StatefulWidget {
  final Map<String, dynamic> assignment;
  final VoidCallback onAccepted;
  // Closes the popup only -- it must never call reject-order. The underlying rider_assignments
  // row stays 'sent', so the request keeps showing in the Orders tab and can be re-opened.
  final VoidCallback onMinimized;

  const IncomingOrderCard({
    super.key,
    required this.assignment,
    required this.onAccepted,
    required this.onMinimized,
  });

  @override
  State<IncomingOrderCard> createState() => _IncomingOrderCardState();
}

class _IncomingOrderCardState extends State<IncomingOrderCard> {
  final supabase = Supabase.instance.client;
  Map<String, dynamic>? order;
  bool loading = true;
  bool processing = false;

  Timer? _countdownTimer;
  int remainingSeconds = 120;
  int _totalDurationSeconds = 120;
  final ValueNotifier<int> _countdownNotifier = ValueNotifier<int>(120);

  RealtimeChannel? _orderSubscription;
  RealtimeChannel? _assignmentSubscription;

  late final RideDiagnosticOwner _rideDiagnosticOwner;

  @override
  void initState() {
    super.initState();
    _rideDiagnosticOwner = RideDiagnosticOwner.widget(() => mounted, surface: RideSurface.incomingCard);
    _startCountdown();
    fetchOrder();
    _subscribeToOrder();
    _subscribeToAssignment();
  }

  @override
  void dispose() {
    _rideDiagnosticOwner.dispose();
    _countdownTimer?.cancel();
    _countdownNotifier.dispose();
    if (_orderSubscription != null) {
      supabase.removeChannel(_orderSubscription!);
      _orderSubscription = null;
    }
    if (_assignmentSubscription != null) {
      supabase.removeChannel(_assignmentSubscription!);
      _assignmentSubscription = null;
    }
    super.dispose();
  }

  void _startCountdown() {
    final expiresAt = DateTime.tryParse(widget.assignment['expires_at']?.toString() ?? '');
    final sentAt = DateTime.tryParse(widget.assignment['sent_at']?.toString() ?? '');

    int total = 120;
    if (expiresAt != null && sentAt != null) {
      // Calculate server-side total duration to eliminate client clock skew completely
      final totalSeconds = expiresAt.difference(sentAt).inSeconds;
      
      // Adjust client clock with the estimated skew
      final adjustedNow = DateTime.now().subtract(LocationCacheService.serverClockSkew);
      final elapsed = adjustedNow.difference(sentAt).inSeconds;
      
      total = totalSeconds > 0 ? totalSeconds : 120;
      remainingSeconds = (total - elapsed).clamp(5, 120);
    } else if (expiresAt != null) {
      final diff = expiresAt.difference(DateTime.now());
      int seconds = diff.inSeconds;
      if (seconds <= 0) seconds = 25;
      total = seconds;
      remainingSeconds = seconds.clamp(5, 120);
    }
    _totalDurationSeconds = total > 0 ? total : 120;
    _countdownNotifier.value = remainingSeconds;

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      remainingSeconds--;
      _countdownNotifier.value = remainingSeconds;
      if (remainingSeconds <= 0) {
        t.cancel();
        _markAssignmentAsExpired();
        widget.onMinimized();
      }
    });
  }

  Future<void> _markAssignmentAsExpired() async {
    try {
      final assignmentId = widget.assignment['id'];
      final riderId = widget.assignment['rider_id'];
      final orderId = widget.assignment['order_id'];
      if (assignmentId == null) return;

      final nowStr = DateTime.now().toUtc().toIso8601String();
      await supabase
          .from('rider_assignments')
          .update({
            'assignment_status': 'expired',
            'responded_at': nowStr,
            'updated_at': nowStr,
            'response_type': 'ignored',
            'last_response_at': nowStr,
          })
          .eq('id', assignmentId);

      if (riderId != null) {
        await supabase
            .from('order_assignment_logs')
            .update({
              'assignment_status': 'expired',
              'responded_at': nowStr,
            })
            .eq('order_id', orderId)
            .eq('rider_id', riderId);
      }
    } catch (e) {
      debugPrint('Error marking assignment as expired in IncomingOrderCard: $e');
    }
  }

  Future<void> fetchOrder() async {
    try {
      final orderId = widget.assignment['order_id'];
      // Egress fix: narrowed from `*` to the exact fields read off `order` in this file (grepped
      // exhaustively across every `order!['...']`/`order?['...']` access).
      final data = await supabase
          .from('orders')
          .select(
            'order_type, distance_meters, distance_km, estimated_duration_min, rider_earning, '
            'current_fare, final_fare, boost_percentage, boost_amount, parcel_type, '
            'weight_category, special_instructions, pickup_address, destination_address, '
            'vehicle_type, parcel_images, users(full_name, phone, user_code)',
          )
          .eq('id', orderId)
          .single();
      if (mounted) {
        setState(() {
          order = data;
          loading = false;
        });
      }
    } catch (e) {
      debugPrint('FETCH ORDER DETAILS ERROR => $e');
      if (mounted) setState(() => loading = false);
    }
  }

  void _subscribeToOrder() {
    final orderId = widget.assignment['order_id'];
    _orderSubscription = supabase
        .channel('incoming-order-$orderId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'orders',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: orderId,
          ),
          callback: (payload) async {
            final updatedRecord = payload.newRecord;
            if (updatedRecord.isNotEmpty && mounted) {
              final status = updatedRecord['order_status']?.toString();
              if (status != 'searching') {
                _countdownTimer?.cancel();
                widget.onMinimized(); // Close the card
                return;
              }
              // Preserve the users pre-fetched map
              final oldUsers = order?['users'];
              setState(() {
                order = updatedRecord;
                if (oldUsers != null) {
                  order?['users'] = oldUsers;
                }
              });
            }
          },
        )
        .subscribe();
  }

  void _subscribeToAssignment() {
    final assignmentId = widget.assignment['id'];
    if (assignmentId == null) return;
    _assignmentSubscription = supabase
        .channel('incoming-assignment-$assignmentId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'rider_assignments',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: assignmentId,
          ),
          callback: (payload) async {
            final updatedRecord = payload.newRecord;
            if (updatedRecord.isNotEmpty && mounted) {
              final status = updatedRecord['assignment_status']?.toString();
              if (status == 'expired' || status == 'rejected' || status == 'cancelled') {
                _countdownTimer?.cancel();
                widget.onMinimized(); // Close the card
              }
            }
          },
        )
        .subscribe();
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
              // Full-screen view: no mem-cache downsampling (this is the largest display
              // size for this image), but still routed through CachedNetworkImage so it
              // reads the same disk cache entry the thumbnail below already populated
              // instead of re-downloading the same URL.
              child: CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.contain,
                width: double.infinity,
                height: double.infinity,
                placeholder: (context, url) => const Center(
                  child: CircularProgressIndicator(color: Colors.white54),
                ),
                errorWidget: (context, url, error) => const Center(
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

  Future<void> acceptOrder() async {
    if (processing) return;
    HapticFeedback.mediumImpact();
    try {
      setState(() => processing = true);
      final riderId = widget.assignment['rider_id'];
      final orderId = widget.assignment['order_id'];
      
      final response = await _rideDiagnosticOwner.api(RideEndpoint.acceptance, orderId?.toString(), () => supabase.functions.invoke(
        'accept-order',
        body: {'order_id': orderId, 'rider_id': riderId},
      ));

      if (response.data != null && response.data['success'] != true) {
        throw Exception(response.data['message'] ?? 'Failed to accept order');
      }

      widget.onAccepted();
    } catch (e) {
      if (mounted) {
        final errorMsg = _getExceptionMessage(e);
        showAppSnackBar(
          context,
          errorMsg.isEmpty ? 'Failed to accept order' : errorMsg,
          type: SnackBarType.error,
        );
        setState(() => processing = false);
      }
    }
  }

  // Minimize only closes the popup -- it must NEVER call reject-order. The rider_assignments row
  // stays 'sent' so this request keeps showing in the Orders tab and can be reopened later.
  void minimizeOrder() {
    if (processing) return;
    _countdownTimer?.cancel();
    widget.onMinimized();
  }

  String _getExceptionMessage(Object e) {
    if (e is FunctionException) {
      final details = e.details;
      if (details != null) {
        if (details is Map && details.containsKey('message')) {
          return details['message'].toString();
        } else if (details is String) {
          try {
            final Map<String, dynamic> decoded = jsonDecode(details);
            if (decoded.containsKey('message')) {
              return decoded['message'].toString();
            }
          } catch (_) {
            return details;
          }
        }
      }
    }
    return e.toString().replaceAll('Exception:', '').replaceAll('FunctionException:', '').trim();
  }

  String _getAreaName(dynamic address) {
    if (address == null) return 'Unknown';
    final str = address.toString();
    final parts = str.split(',');
    if (parts.isNotEmpty) {
      return parts.first.trim();
    }
    return str;
  }

  Widget _buildStatChip({required IconData icon, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: const Color(0xFFC5FF30), size: 13),
          const SizedBox(width: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final diagnosticStatus = order?['order_status'];
    _rideDiagnosticOwner.frame(context, order?['id']?.toString(), diagnosticStatus,
      () => !loading && order?['order_status'] == diagnosticStatus);
    final sentAtStr = widget.assignment['sent_at'] ?? '';
    final dt = DateTime.tryParse(sentAtStr.toString())?.toLocal() ?? DateTime.now();
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final months = ['Sep', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final monthStr = months[dt.month];
    final dayStr = dt.day.toString().padLeft(2, '0');
    final year = dt.year;
    final timeDateStr = '$hour:$minute $monthStr $dayStr,$year';

    final userMap = order?['users'] as Map<String, dynamic>?;
    final userName = userMap?['full_name']?.toString() ?? 'Customer';
    final userPhone = userMap?['phone']?.toString() ?? '';
    final userCode = userMap?['user_code']?.toString() ?? '';

    final rawImages = order?['parcel_images'];
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
      decoration: const BoxDecoration(
        color: Color(0xFF0B0F19), // darkBg
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              const SizedBox.shrink(),

              // Title Header
              Row(
                children: [
                  Expanded(
                    child: Text(
                      order != null
                          ? (order!['order_type'] == 'ride' || order!['order_type'] == 'intercity_ride' || order!['order_type'] == 'intercity'
                              ? ((double.tryParse(order!['distance_meters']?.toString() ?? '0') ?? 0) > 20000 || order!['order_type'] == 'intercity_ride' || order!['order_type'] == 'intercity'
                                  ? 'Received a new\nintercity ride request'
                                  : 'Received a new\nride request')
                              : 'Received a new\nparcel request')
                          : 'Received a new\nrequest',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        height: 1.2,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Subtitle & Queue Timer Badge
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      timeDateStr,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF94A3B8), // textGray
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Queue timer badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ValueListenableBuilder<int>(
                          valueListenable: _countdownNotifier,
                          builder: (context, remaining, _) {
                            return Text(
                              remaining.toString().padLeft(2, '0'),
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.white70,
                              ),
                            );
                          },
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          'Queue',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF94A3B8),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.chevron_right_rounded,
                          color: Color(0xFFC5FF30), // primaryLime
                          size: 14,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Shrinking Progress Indicator
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: ValueListenableBuilder<int>(
                  valueListenable: _countdownNotifier,
                  builder: (context, remaining, _) {
                    return LinearProgressIndicator(
                      value: (_totalDurationSeconds > 0)
                          ? (remaining / _totalDurationSeconds).clamp(0.0, 1.0)
                          : 0.0,
                      backgroundColor: Colors.white.withValues(alpha: 0.05),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        remaining > 30 ? const Color(0xFFC5FF30) : Colors.redAccent,
                      ),
                      minHeight: 4,
                    );
                  },
                ),
              ),
              const SizedBox(height: 20),

              // Fare Increased / Boosted fare badge
              if (order != null) ...[
                (() {
                  final currentFare = double.tryParse(order!['rider_earning']?.toString() ?? order!['current_fare']?.toString() ?? '0') ?? 0.0;
                  final previousFare = double.tryParse(widget.assignment['last_seen_fare']?.toString() ?? widget.assignment['estimated_earnings']?.toString() ?? '0') ?? 0.0;
                  final diff = currentFare - previousFare;
                  if (diff > 0 && previousFare > 0) {
                    return Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFE11D48), Color(0xFFF43F5E)], // Rose gradient
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFF43F5E).withValues(alpha: 0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.local_fire_department_rounded, color: Colors.white, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '🔥 Fare Increased',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Previous: ₹${previousFare.toStringAsFixed(0)}  →  Now: ₹${currentFare.toStringAsFixed(0)}',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.9),
                                    fontWeight: FontWeight.w500,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '+₹${diff.toStringAsFixed(0)}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                })(),
              ],

              // Boosted fare badge
              if (order != null && (double.tryParse(order!['boost_percentage']?.toString() ?? '0') ?? 0.0) > 0) ...[
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF8B5CF6), Color(0xFFEC4899)], // Violet to pink neon gradient
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFEC4899).withValues(alpha: 0.3),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.bolt_rounded, color: Colors.white, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            (() {
                              final bp = double.tryParse(order!['boost_percentage']?.toString() ?? '0') ?? 0.0;
                              return bp >= 50
                                  ? '⚡ MAX BOOSTED Earning'
                                  : '⚡ Boosted Priority (+${bp.toStringAsFixed(0)}% Earning)';
                            })(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '+₹${double.tryParse(order!['boost_amount']?.toString() ?? '0')?.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // Customer Details block
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF131926), // darkCard
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: Colors.white10,
                      child: Text(
                        userName.isNotEmpty ? userName[0].toUpperCase() : 'C',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  userName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              if (userCode.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Text(
                                  '($userCode)',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.white.withValues(alpha: 0.5),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              const Icon(Icons.star_rounded, color: Color(0xFFF59E0B), size: 14),
                              const SizedBox(width: 4),
                              Text(
                                '4.9 rating',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.white.withValues(alpha: 0.5),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (userPhone.isNotEmpty)
                      GestureDetector(
                        onTap: () async {
                          final url = Uri.parse('tel:$userPhone');
                          if (await canLaunchUrl(url)) {
                            await launchUrl(url);
                          }
                        },
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.05),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 1),
                          ),
                          child: const Center(
                            child: Icon(Icons.phone_rounded, color: Colors.white70, size: 18),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (order != null && (order!['order_type'] == 'local_parcel' || order!['order_type'] == 'intercity_parcel')) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.blue.withValues(alpha: 0.08), width: 1.2),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.inventory_2_rounded, color: Colors.blueAccent, size: 14),
                          const SizedBox(width: 8),
                          const Text(
                            'Parcel details',
                            style: TextStyle(color: Colors.blueAccent, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (order!['parcel_type'] != null)
                        _buildParcelDetailRow('Category', order!['parcel_type'].toString()),
                      if (order!['weight_category'] != null)
                        _buildParcelDetailRow('Weight Class', order!['weight_category'].toString()),
                      // Receiver details hidden before acceptance
                      if (order!['special_instructions'] != null && order!['special_instructions'].toString().trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        const Divider(color: Colors.white10),
                        const SizedBox(height: 4),
                        Text(
                          'Note: ${order!['special_instructions']}',
                          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontStyle: FontStyle.italic),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              if (parcelImages.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'PARCEL IMAGES',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 80,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: parcelImages.length,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 10.0),
                        child: GestureDetector(
                          onTap: () => _viewFullScreenImage(context, parcelImages[index]),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            // 80x80 display size: downsample the decoded image in memory
                            // to the actual thumbnail size instead of holding a full-res
                            // decode. Shares the same disk cache entry as the full-screen
                            // viewer above, so tapping to view full-screen does not
                            // re-download the image.
                            child: CachedNetworkImage(
                              imageUrl: parcelImages[index],
                              width: 80,
                              height: 80,
                              fit: BoxFit.cover,
                              memCacheWidth: (80 * MediaQuery.of(context).devicePixelRatio).round(),
                              memCacheHeight: (80 * MediaQuery.of(context).devicePixelRatio).round(),
                              placeholder: (context, url) => Container(
                                width: 80,
                                height: 80,
                                color: Colors.white10,
                              ),
                              errorWidget: (context, url, error) => Container(
                                width: 80,
                                height: 80,
                                color: Colors.white10,
                                child: const Icon(Icons.broken_image_rounded, size: 24, color: Colors.white30),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 16),

              // Route Card (Neon Lime)
              if (loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFFC5FF30))),
                )
              else if (order != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFFC5FF30), // primaryLime
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Pickup Location black capsule
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0B0F19), // darkBg
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.my_location_rounded, color: Color(0xFFC5FF30), size: 14),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                order!['pickup_address'] ?? 'Pickup Address',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      // Route path & details
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'PICKUP FROM',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black.withValues(alpha: 0.5),
                                  ),
                                ),
                                Text(
                                  _getAreaName(order!['pickup_address']),
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w900,
                                    color: Colors.black,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '• • •',
                                  style: TextStyle(color: Colors.black.withValues(alpha: 0.25), fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  (order!['order_type'] == 'ride' || order!['order_type'] == 'intercity_ride' || order!['order_type'] == 'intercity')
                                      ? ((order!['vehicle_type'] == 'cab' || order!['vehicle_type'] == 'car')
                                          ? Icons.directions_car_rounded
                                          : Icons.two_wheeler_rounded)
                                      : Icons.inventory_2_rounded,
                                  color: Colors.black,
                                  size: 20,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '• • •',
                                  style: TextStyle(color: Colors.black.withValues(alpha: 0.25), fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  'DESTINATION',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black.withValues(alpha: 0.5),
                                  ),
                                ),
                                Text(
                                  _getAreaName(order!['destination_address']),
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w900,
                                    color: Colors.black,
                                  ),
                                  textAlign: TextAlign.right,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                // Issue 4 fix: the pickup capsule above already shows the full
                                // pickup_address -- destination previously only ever showed the
                                // short area name (first comma segment), never the exact drop
                                // address, before the Drop Partner accepts.
                                if ((order!['destination_address']?.toString() ?? '').isNotEmpty)
                                  Text(
                                    order!['destination_address'].toString(),
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.black.withValues(alpha: 0.6),
                                    ),
                                    textAlign: TextAlign.right,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Issue 4 fix: two clearly-labeled distances instead of one ambiguous "Distance: X
                // km" -- both already precomputed server-side, no new Maps/routing API calls here.
                // Driver -> Pickup: `rider_assignments.distance_km`, written once by start-dispatch
                // (find_nearby_riders' haversine straight-line calculation) when this assignment was
                // created -- read from the SAME field name the DB actually has. The previous
                // 'rider_distance_km' key never existed on rider_assignments (only on the separate
                // order_assignment_logs table), so this chip silently never rendered before this fix.
                // Pickup -> Drop: `orders.distance_km`/`distance_meters`, the same canonical trip
                // distance create-order already computed for pricing -- never recalculated here.
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: Row(
                    children: [
                      if (widget.assignment['distance_km'] != null) ...[
                        _buildStatChip(
                          icon: Icons.navigation_rounded,
                          label: 'You → Pickup: ${double.tryParse(widget.assignment['distance_km'].toString())?.toStringAsFixed(1)} km',
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (widget.assignment['estimated_pickup_time_min'] != null) ...[
                        _buildStatChip(
                          icon: Icons.hourglass_top_rounded,
                          label: 'Pickup: ${widget.assignment['estimated_pickup_time_min']} mins',
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (order!['distance_km'] != null || order!['distance_meters'] != null) ...[
                        _buildStatChip(
                          icon: Icons.directions_bike_rounded,
                          label: 'Pickup → Drop: ${double.tryParse((order!['distance_km'] ?? (double.tryParse(order!['distance_meters'].toString()) ?? 0.0) / 1000.0).toString())?.toStringAsFixed(1)} km',
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (order!['estimated_duration_min'] != null) ...[
                        _buildStatChip(
                          icon: Icons.schedule_rounded,
                          label: 'Ride Est: ${(double.tryParse(order!['estimated_duration_min'].toString()) ?? 0.0).round()} mins',
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),

              // Action buttons row (Circular Minimize + SlideToAcceptButton)
              Row(
                children: [
                  // Minimize circle button -- closes this popup only. Does NOT reject the ride;
                  // the assignment stays 'sent' and reappears in the Orders tab.
                  Semantics(
                    button: true,
                    label: 'Minimize',
                    child: GestureDetector(
                      onTap: processing ? null : minimizeOrder,
                      child: Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 1.5),
                        ),
                        child: const Center(
                          child: Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white70, size: 28),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Slide to Accept
                  Expanded(
                    child: SlideToAcceptButton(
                      fare: double.tryParse(order?['final_fare']?.toString() ?? order?['current_fare']?.toString() ?? widget.assignment['estimated_earnings']?.toString() ?? '0') ?? 0.0,
                      onAccept: acceptOrder,
                      processing: processing,
                    ),
                  ),
                ],
              ),
            ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildParcelDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label: ',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 11, fontWeight: FontWeight.bold),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

// =========================================================
// CUSTOM SLIDING ACCEPT BUTTON
// =========================================================
class SlideToAcceptButton extends StatefulWidget {
  final double fare;
  final VoidCallback onAccept;
  final bool processing;

  const SlideToAcceptButton({
    super.key,
    required this.fare,
    required this.onAccept,
    this.processing = false,
  });

  @override
  State<SlideToAcceptButton> createState() => _SlideToAcceptButtonState();
}

class _SlideToAcceptButtonState extends State<SlideToAcceptButton> {
  double _dragPosition = 0;
  bool _isAccepted = false;

  @override
  void didUpdateWidget(covariant SlideToAcceptButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.processing && oldWidget.processing) {
      // Reset position if processing state has cleared (e.g. on error)
      setState(() {
        _dragPosition = 0;
        _isAccepted = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxDrag = constraints.maxWidth - 46 - 6; // track width minus button width and padding margins
        return Container(
          height: 52,
          width: double.infinity,
          decoration: BoxDecoration(
            color: const Color(0xFF131926), // darkCard
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 1.5),
          ),
          child: Stack(
            children: [
              // Price & Arrow markers on right
              Positioned.fill(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 20),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.chevron_right_rounded, color: Colors.white.withValues(alpha: 0.15), size: 18),
                        Icon(Icons.chevron_right_rounded, color: Colors.white.withValues(alpha: 0.35), size: 18),
                        Icon(Icons.chevron_right_rounded, color: Colors.white.withValues(alpha: 0.65), size: 18),
                        const SizedBox(width: 6),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            // WHOLE-RUPEE FARE CONSISTENCY FIX: widget.fare is order.final_fare ??
                            // order.current_fare -- already a canonical whole-rupee amount (rounded
                            // once, server-side, by calculate-order-pricing / calculate_fare_
                            // breakdown()). Displaying it with 2 decimal places (e.g. "24.00")
                            // instead of matching every other whole-rupee fare display in the app
                            // (post-accept screens, the booking screens) is the one remaining
                            // inconsistency in an otherwise already-whole value -- toStringAsFixed(0)
                            // here never changes what number is shown, only its formatting.
                            '₹${widget.fare.toStringAsFixed(0)}',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFFC5FF30), // primaryLime
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Instruction text
              Positioned.fill(
                child: Center(
                  child: widget.processing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text(
                          'Accept',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: Colors.white60,
                          ),
                        ),
                ),
              ),
              // Slide Handle Button
              Positioned(
                left: 3 + _dragPosition,
                top: 3,
                bottom: 3,
                child: GestureDetector(
                  onHorizontalDragUpdate: (details) {
                    if (_isAccepted || widget.processing) return;
                    setState(() {
                      _dragPosition = (_dragPosition + details.delta.dx).clamp(0.0, maxDrag);
                    });
                  },
                  onHorizontalDragEnd: (details) {
                    if (_isAccepted || widget.processing) return;
                    if (_dragPosition >= maxDrag * 0.8) {
                      setState(() {
                        _dragPosition = maxDrag;
                        _isAccepted = true;
                      });
                      widget.onAccept();
                    } else {
                      setState(() {
                        _dragPosition = 0;
                      });
                    }
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    width: 46,
                    height: 46,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 4,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.arrow_forward_rounded,
                        color: Color(0xFF0B0F19), // darkBg
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
