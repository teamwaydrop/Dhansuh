import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/providers/app_mode_provider.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/shared/widgets/mode_switch_overlay.dart';
import 'package:waydrop/features/rider/services/rider_status_service.dart';
import 'package:waydrop/features/rider/navigation/rider_main_navigation_screen.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_payout_details_screen.dart';
import 'package:waydrop/features/intercity/parcels/booking/intercity_details_screen.dart';
import 'package:waydrop/features/intercity/shared/screens/intercity_searching_screen.dart';
import 'package:waydrop/features/intercity/shared/screens/intercity_tracking_screen.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_entry_handler.dart';
import 'package:waydrop/shared/widgets/skeleton_loader.dart';
import 'package:waydrop/shared/helpers/location_display_service.dart';

class IntercityParcelsScreen extends ConsumerStatefulWidget {
  const IntercityParcelsScreen({super.key});

  @override
  ConsumerState<IntercityParcelsScreen> createState() => _IntercityParcelsScreenState();
}

class _IntercityParcelsScreenState extends ConsumerState<IntercityParcelsScreen> {
  final supabase = Supabase.instance.client;
  bool loading = true;
  List<Map<String, dynamic>> activeOrders = [];
  List<Map<String, dynamic>> historyOrders = [];
  // P2 #3 (WayDrop production-scale audit): now routed through RealtimeManager (the app's single
  // multiplexed realtime channel system) instead of its own raw supabase.channel() connection.
  String? _ordersSubId;
  String? _ordersSubChannel;
  bool kycCompleted = true;
  // Egress fix (Fix #7): same 500ms-debounce pattern already used by the sibling
  // passenger/rider activity tabs for the identical "orders realtime event -> full reload"
  // situation -- a burst of related order-row events reloads the list once per burst instead of
  // once per event.
  Timer? _ordersDebounceTimer;

  String _getCityName(String? city, String? address, String defaultName) {
    return LocationDisplayService.resolveCity(
      city: city,
      address: address,
      fallback: defaultName,
    );
  }

  @override
  void initState() {
    super.initState();
    _loadOrders();
    _subscribeToOrders();
  }

  @override
  void dispose() {
    _ordersDebounceTimer?.cancel();
    if (_ordersSubId != null && _ordersSubChannel != null) {
      RealtimeManager.instance.unsubscribe(_ordersSubChannel!, _ordersSubId!);
    }
    super.dispose();
  }

  Future<void> _loadOrders() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;

      // Egress fix: narrowed from `*` to the fields read off `order` in this file (grepped
      // exhaustively -- order['id'] is passed onward as a plain string, never the whole map).
      final response = await supabase
          .from('orders')
          .select(
            'id, order_status, order_type, pickup_city, pickup_address, destination_city, '
            'destination_address, final_fare, current_fare, actual_fare, parcel_type, '
            'weight_category, travel_date, receiver_name, created_at',
          )
          .eq('user_id', user.id)
          .eq('order_type', 'intercity_parcel')
          .order('created_at', ascending: false);

      final List<Map<String, dynamic>> allOrders =
          List<Map<String, dynamic>>.from(response);

      final kycResponse = await supabase
          .from('rider_kyc')
          .select('kyc_status')
          .eq('user_id', user.id)
          .maybeSingle();

      final kycStatus = kycResponse?['kyc_status']?.toString();

      if (mounted) {
        setState(() {
          kycCompleted = kycResponse != null && kycStatus == 'approved';
          activeOrders = allOrders.where((o) => [
                'searching',
                'accepted',
                'rider_arrived',
                'picked_up',
                'ongoing',
                'rider_at_drop'
              ].contains(o['order_status'])).toList();

          historyOrders = allOrders.where((o) => [
                'completed',
                'cancelled'
              ].contains(o['order_status'])).toList();

          loading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading intercity orders: $e');
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  void _subscribeToOrders() {
    final user = supabase.auth.currentUser;
    if (user == null) return;

    if (_ordersSubId != null && _ordersSubChannel != null) {
      RealtimeManager.instance.unsubscribe(_ordersSubChannel!, _ordersSubId!);
      _ordersSubId = null;
      _ordersSubChannel = null;
    }
    _ordersSubChannel = 'intercity-parcels-orders-${user.id}';
    _ordersSubId = RealtimeManager.instance.subscribe(
      channelName: _ordersSubChannel!,
      table: 'orders',
      owner: 'IntercityParcelsScreen',
      event: PostgresChangeEvent.all,
      schema: 'public',
      filterColumn: 'user_id',
      filterValue: user.id,
      callback: (payload) {
        _ordersDebounceTimer?.cancel();
        _ordersDebounceTimer = Timer(const Duration(milliseconds: 500), () {
          if (mounted) _loadOrders();
        });
      },
    );
  }

  void _navigateToOrder(Map<String, dynamic> order) {
    final orderId = order['id'] as String;
    final status = order['order_status'] as String;
    final isRide = order['order_type'] == 'ride';

    if (status == 'searching' || status == 'created') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => IntercitySearchingScreen(orderId: orderId),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => IntercityTrackingScreen(orderId: orderId),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subTextColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final cardBg = isDark ? const Color(0xFF171A21) : Colors.white;
    final screenBg = isDark ? const Color(0xFF1E222B) : const Color(0xFFF8FAFC);
    final borderColor = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);
    final primaryColor = const Color(0xFF7C3AED);

    return Scaffold(
      backgroundColor: screenBg,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF171A21) : Colors.white,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            color: textColor,
            size: 18,
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Intercity Shipment Dashboard',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w900,
            color: textColor,
            letterSpacing: -0.3,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1.0),
          child: Container(
            color: borderColor,
            height: 1.0,
          ),
        ),
      ),
      body: loading
          ? const SkeletonLoader()
          : ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                  // 1. Premium Hero Booking Card
                  Container(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF7C3AED), Color(0xFF5B21B6)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF7C3AED).withValues(alpha: 0.35),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      children: [
                        Positioned(
                          right: -30,
                          bottom: -30,
                          child: Icon(
                            Icons.explore_rounded,
                            size: 160,
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Text(
                                  'SEND PARCELS',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'Book Intercity Parcel',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Deliver packages safely to other cities using verified riders on existing trips.',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.8),
                                  fontSize: 13,
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: 20),
                              ElevatedButton(
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => const IntercityDetailsScreen(
                                          orderType: 'intercity_parcel'),
                                    ),
                                  ).then((_) => _loadOrders());
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.white,
                                  foregroundColor: primaryColor,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  elevation: 0,
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      'Create Shipment',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    SizedBox(width: 6),
                                    Icon(Icons.arrow_forward_rounded, size: 14),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  if (!kycCompleted) ...[
                    _buildBecomeRiderCard(context, isDark),
                    const SizedBox(height: 20),
                  ],

                  // 2. Active Shipments Section
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Active Shipments',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                          color: textColor,
                          letterSpacing: -0.2,
                        ),
                      ),
                      if (activeOrders.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: primaryColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${activeOrders.length} active',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: primaryColor,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  if (activeOrders.isEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: borderColor),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.local_shipping_outlined,
                            size: 40,
                            color: subTextColor.withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'No active shipments at the moment',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: subTextColor,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: activeOrders.length,
                      separatorBuilder: (context, index) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final order = activeOrders[index];
                        final from = _getCityName(order['pickup_city'], order['pickup_address'], 'Pickup');
                        final to = _getCityName(order['destination_city'], order['destination_address'], 'Destination');
                        final status = order['order_status'] ?? 'searching';
                        final price = double.tryParse(order['final_fare']?.toString() ?? order['current_fare']?.toString() ?? order['actual_fare']?.toString() ?? '0') ?? 0.0;
                        final parcelType = order['parcel_type']?.toString() ?? '';
                        final weightCategory = order['weight_category']?.toString() ?? '';

                        final travelDateStr = order['travel_date'] != null
                            ? () {
                                try {
                                  final dt = DateTime.parse(order['travel_date'].toString()).toLocal();
                                  final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
                                  final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
                                  final ampm = dt.hour >= 12 ? 'PM' : 'AM';
                                  final minute = dt.minute.toString().padLeft(2, '0');
                                  return '${dt.day} ${months[dt.month - 1]}, $hour:$minute $ampm';
                                } catch (_) {
                                  return order['travel_date'].toString();
                                }
                              }()
                            : null;

                        String details = '';
                        if (parcelType.isNotEmpty) {
                          details += parcelType[0].toUpperCase() + parcelType.substring(1);
                        } else {
                          details += 'Parcel';
                        }
                        if (weightCategory.isNotEmpty) {
                          final formattedWeight = weightCategory.replaceAll('_', '-');
                          details += ' ($formattedWeight kg)';
                        }
                        if (order['receiver_name'] != null && order['receiver_name'].toString().trim().isNotEmpty) {
                          details += ' • To: ${order['receiver_name']}';
                        }
                        if (travelDateStr != null) {
                          details += '\nDeparture: $travelDateStr';
                        }

                        final bool isSearching = status == 'searching' || status == 'created';

                        return Container(
                          decoration: BoxDecoration(
                            color: cardBg,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: borderColor),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.03),
                                blurRadius: 10,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(20),
                              onTap: () => _navigateToOrder(order),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Timeline connections
                                    Row(
                                      children: [
                                        Icon(Icons.circle, size: 8, color: primaryColor),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            from,
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold,
                                              color: textColor,
                                            ),
                                          ),
                                        ),
                                        Icon(Icons.arrow_forward_rounded, size: 14, color: subTextColor),
                                        const SizedBox(width: 8),
                                        Icon(Icons.location_on_rounded, size: 10, color: const Color(0xFFFF4E25)),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            to,
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold,
                                              color: textColor,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    Divider(height: 1, color: borderColor),
                                    const SizedBox(height: 12),
                                     Row(
                                       mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                       children: [
                                         Expanded(
                                           child: Column(
                                             crossAxisAlignment: CrossAxisAlignment.start,
                                             children: [
                                               Text(
                                                 details,
                                                 style: TextStyle(
                                                   fontSize: 12,
                                                   color: subTextColor,
                                                   fontWeight: FontWeight.w600,
                                                 ),
                                               ),
                                               const SizedBox(height: 4),
                                               Text(
                                                 '₹${price.toStringAsFixed(0)}',
                                                 style: TextStyle(
                                                   fontSize: 14,
                                                   fontWeight: FontWeight.w900,
                                                   color: textColor,
                                                 ),
                                               ),
                                             ],
                                           ),
                                         ),
                                         const SizedBox(width: 16),
                                         Column(
                                          crossAxisAlignment: CrossAxisAlignment.end,
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                              decoration: BoxDecoration(
                                                color: isSearching
                                                    ? const Color(0xFFFFFBEB)
                                                    : const Color(0xFFECFDF5),
                                                borderRadius: BorderRadius.circular(8),
                                                border: Border.all(
                                                  color: isSearching
                                                      ? const Color(0xFFFDE68A)
                                                      : const Color(0xFFA7F3D0),
                                                ),
                                              ),
                                              child: Text(
                                                status.toUpperCase(),
                                                style: TextStyle(
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.w900,
                                                  color: isSearching
                                                      ? const Color(0xFFD97706)
                                                      : const Color(0xFF059669),
                                                ),
                                              ),
                                            ),
                                            if (isSearching) ...[
                                              const SizedBox(height: 6),
                                              IntercityMatchBadge(orderId: order['id']),
                                            ],
                                          ],
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  const SizedBox(height: 24),

                  // 3. History Section
                  Text(
                    'History',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: textColor,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 12),

                  if (historyOrders.isEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      alignment: Alignment.center,
                      child: Text(
                        'No shipment history found',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: subTextColor,
                        ),
                      ),
                    )
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: historyOrders.length,
                      separatorBuilder: (context, index) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final order = historyOrders[index];
                        final from = _getCityName(order['pickup_city'], order['pickup_address'], 'Pickup');
                        final to = _getCityName(order['destination_city'], order['destination_address'], 'Destination');
                        final status = order['order_status'] ?? 'completed';
                        final price = double.tryParse(order['final_fare']?.toString() ?? order['current_fare']?.toString() ?? order['actual_fare']?.toString() ?? '0') ?? 0.0;
                        final dateStr = order['created_at']?.toString() ?? '';
                        String formattedDate = '';
                        if (dateStr.isNotEmpty) {
                          try {
                            final dt = DateTime.parse(dateStr).toLocal();
                            formattedDate = '${dt.day}/${dt.month}/${dt.year}';
                          } catch (_) {}
                        }

                        final bool isCompleted = status == 'completed';

                        return Container(
                          decoration: BoxDecoration(
                            color: cardBg.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: borderColor),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            title: Text(
                              '$from → $to',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: textColor,
                              ),
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Row(
                                children: [
                                  Text(
                                    formattedDate,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      color: subTextColor,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    height: 4,
                                    width: 4,
                                    decoration: BoxDecoration(color: subTextColor, shape: BoxShape.circle),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    status.toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: isCompleted ? const Color(0xFF10B981) : Colors.red,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            trailing: Text(
                              '₹${price.toStringAsFixed(0)}',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
                                color: textColor,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
    );
  }

  Widget _buildBecomeRiderCard(BuildContext context, bool isDark) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subTextColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final cardBg = isDark ? const Color(0xFF171A21) : Colors.white;
    final borderColor = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: borderColor, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.12 : 0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.assignment_ind_outlined,
                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Become a Delivery Partner',
                      style: TextStyle(
                        color: textColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Complete verification and start accepting intercity bookings.',
                      style: TextStyle(
                        color: subTextColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const RiderEntryHandler()),
                ).then((_) => _loadOrders());
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: const Text(
                'Complete Verification',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class IntercityMatchBadge extends StatefulWidget {
  final String orderId;

  const IntercityMatchBadge({super.key, required this.orderId});

  @override
  State<IntercityMatchBadge> createState() => _IntercityMatchBadgeState();
}

class _IntercityMatchBadgeState extends State<IntercityMatchBadge>
    with SingleTickerProviderStateMixin {
  final supabase = Supabase.instance.client;
  int? matchedCount;
  bool loading = true;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _checkMatches();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _checkMatches() async {
    try {
      final response = await supabase.functions.invoke(
        'match-intercity-riders',
        body: {
          'order_id': widget.orderId,
        },
      );

      if (response.data != null && response.data['success'] == true) {
        final List matches = response.data['matches'] ?? [];
        if (mounted) {
          setState(() {
            matchedCount = matches.length;
            loading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            matchedCount = 0;
            loading = false;
          });
        }
      }
    } catch (e) {
      debugPrint('Error loading matches badge for ${widget.orderId}: $e');
      if (mounted) {
        setState(() {
          matchedCount = 0;
          loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 1.5,
          color: Colors.orange,
        ),
      );
    }

    if (matchedCount == null || matchedCount == 0) {
      return const SizedBox.shrink();
    }

    return ScaleTransition(
      scale: _pulseAnimation,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFEA580C),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFEA580C).withValues(alpha: 0.4),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          '$matchedCount riders available',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}
