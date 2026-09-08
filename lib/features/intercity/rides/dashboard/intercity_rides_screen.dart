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
import 'package:waydrop/features/intercity/shared/screens/intercity_location_screen.dart';
import 'package:waydrop/features/intercity/shared/screens/intercity_searching_screen.dart';
import 'package:waydrop/features/intercity/shared/screens/intercity_tracking_screen.dart';
import 'package:waydrop/features/intercity/parcels/dashboard/intercity_parcels_screen.dart'; // To reuse IntercityMatchBadge if needed, or define it here.
import 'package:waydrop/features/rider/onboarding/screens/rider_entry_handler.dart';
import 'package:waydrop/shared/widgets/skeleton_loader.dart';
import 'package:waydrop/shared/helpers/location_display_service.dart';
import 'package:waydrop/models/transport_order.dart';

class IntercityRidesScreen extends ConsumerStatefulWidget {
  const IntercityRidesScreen({super.key});

  @override
  ConsumerState<IntercityRidesScreen> createState() => _IntercityRidesScreenState();
}

class _IntercityRidesScreenState extends ConsumerState<IntercityRidesScreen> {
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
  // Lifecycle method called once when the stateful widget initialized for the first time
  void initState() {
    // Lifecycle method called once when the stateful widget initialized for the first time
    super.initState();
    debugPrint('[RUNTIME_TRACE] ENTER IntercityRidesScreen (intercity_rides_screen.dart)');
    _loadOrders();
    _subscribeToOrders();
  }

  @override
  // Lifecycle method called before the widget is removed permanently from the tree to clean resources
  void dispose() {
    _ordersDebounceTimer?.cancel();
    if (_ordersSubId != null && _ordersSubChannel != null) {
      RealtimeManager.instance.unsubscribe(_ordersSubChannel!, _ordersSubId!);
    }
    // Lifecycle method called before the widget is removed permanently from the tree to clean resources
    super.dispose();
  }

  Future<void> _loadOrders() async {
    try {
      // Perform an asynchronous database operation using the Supabase client wrapper
      final user = supabase.auth.currentUser;
      if (user == null) return;

      // Egress fix: narrowed from `*` to the fields read off `order` in this file (grepped
      // exhaustively -- order['id'] is passed onward as a plain string, never the whole map).
      // distance_meters stays filter-only (Postgrest filters apply to the underlying table
      // columns regardless of what's selected, so it doesn't need to be in this list).
      final response = await supabase
          .from('orders')
          .select(
            'id, order_status, pickup_city, pickup_address, destination_city, '
            'destination_address, final_fare, current_fare, actual_fare, travel_date, created_at',
          )
          .eq('user_id', user.id)
          .or('order_type.eq.intercity_ride,and(order_type.eq.ride,distance_meters.gt.20000)')
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
        // Update the widget state to trigger a UI rebuild with the new variables
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
      debugPrint('Error loading intercity rides: $e');
      if (mounted) {
        // Update the widget state to trigger a UI rebuild with the new variables
        setState(() => loading = false);
      }
    }
  }

  void _subscribeToOrders() {
    // Perform an asynchronous database operation using the Supabase client wrapper
    final user = supabase.auth.currentUser;
    if (user == null) return;

    if (_ordersSubId != null && _ordersSubChannel != null) {
      RealtimeManager.instance.unsubscribe(_ordersSubChannel!, _ordersSubId!);
      _ordersSubId = null;
      _ordersSubChannel = null;
    }
    _ordersSubChannel = 'intercity-rides-orders-${user.id}';
    _ordersSubId = RealtimeManager.instance.subscribe(
      channelName: _ordersSubChannel!,
      table: 'orders',
      owner: 'IntercityRidesScreen',
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

    if (status == 'searching' || status == 'created') {
      // Navigate to a new screen layout using Flutter's Navigator router
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => IntercitySearchingScreen(orderId: orderId),
        ),
      );
    } else {
      // Navigate to a new screen layout using Flutter's Navigator router
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => IntercityTrackingScreen(orderId: orderId),
        ),
      );
    }
  }

  @override
  // Build method responsible for rendering the entire widget layout hierarchy on the viewport
  Widget build(BuildContext context) {
    // Retrieve the active theme parameters (like colors, text style, dark mode) from BuildContext
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subTextColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final cardBg = isDark ? const Color(0xFF171A21) : Colors.white;
    final screenBg = isDark ? const Color(0xFF1E222B) : const Color(0xFFF8FAFC);
    final borderColor = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);
    final primaryColor = const Color(0xFF2563EB);

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
          // Close/pop the current screen or modal bottom sheet context
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Intercity Rides Dashboard',
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
                        colors: [Color(0xFF2563EB), Color(0xFF1D4ED8)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF2563EB).withValues(alpha: 0.35),
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
                            Icons.directions_car_rounded,
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
                                  'BOOK RIDES',
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
                                'Book Intercity Ride',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Travel comfortably between cities with verified, rated travel partners.',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.8),
                                  fontSize: 13,
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: 20),
                              ElevatedButton(
                                onPressed: () {
                                  // Navigate to a new screen layout using Flutter's Navigator router
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => const IntercityLocationScreen(
                                          orderType: 'ride'),
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
                                      'Find Ride',
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

                  // 2. Active Rides Section
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Active Rides',
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
                            Icons.directions_car_outlined,
                            size: 40,
                            color: subTextColor.withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'No active rides at the moment',
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
                        final bool isSearchingStatus = status == 'searching' || status == 'created';
                        // Issue 3 fix: expire_stale_searching_orders() explicitly excludes
                        // intercity_ride/intercity_parcel (order_type NOT IN (...)) from its
                        // auto-expiry sweep, so an intercity order's own order_status can remain
                        // 'searching' indefinitely after its scheduled travel_date/time has passed
                        // -- match-intercity-riders and accept_intercity_request are already
                        // travel_date-aware and correctly refuse to match/accept it, but nothing
                        // ever propagates that into order_status or this card. Compared as full
                        // instants (travel_date is `timestamp with time zone`; DateTime.parse(...)
                        // on an ISO 8601 string with an offset already yields the correct absolute
                        // instant with no manual timezone conversion needed) -- never a date-only
                        // comparison, so a same-day-but-later-time plan is not falsely flagged.
                        final DateTime? travelDateTime = order['travel_date'] != null
                            ? DateTime.tryParse(order['travel_date'].toString())
                            : null;
                        final bool isTravelTimeExpired = isSearchingStatus &&
                            travelDateTime != null &&
                            travelDateTime.isBefore(DateTime.now());
                        // Task 2: Waiting for Travel Day → Trip Started → In Transit → Completed.
                        final statusLabel = isTravelTimeExpired
                            ? 'Travel Time Expired'
                            : TransportOrder.fromJson(order).intercityLifecycleLabel;
                        final price = double.tryParse(order['final_fare']?.toString() ?? order['current_fare']?.toString() ?? order['actual_fare']?.toString() ?? '0') ?? 0.0;
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

                        String details = 'Scheduled Ride';
                        if (travelDateStr != null) {
                          details += ' • Departure: $travelDateStr';
                        }

                        // Issue 3 fix: a travel-time-expired order is no longer actively searching
                        // -- stops showing the amber "searching" badge/color and (below) the live
                        // IntercityMatchBadge, which would be misleading for a request that can no
                        // longer be matched.
                        final bool isSearching = isSearchingStatus && !isTravelTimeExpired;

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
                                                statusLabel.toUpperCase(),
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
                        'No ride history found',
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
                // Navigate to a new screen layout using Flutter's Navigator router
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
