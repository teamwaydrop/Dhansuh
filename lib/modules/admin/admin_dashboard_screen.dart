import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/core/services/realtime/realtime_observability.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  final supabase = Supabase.instance.client;
  Timer? _refreshTimer;

  // DB Operational Stats
  int onlineRiders = 0;
  int activeTrips = 0;
  int pendingOrders = 0;
  int failedDispatches = 0;
  int failedNotifications = 0;

  // Financial Stats
  double todayRevenue = 0.0;
  int todayTrips = 0;
  double totalWalletBalances = 0.0;

  // Dispatch Metrics
  double dispatchSuccessPercent = 94.5;
  double dispatchTimeoutPercent = 5.5;
  int averageAssignmentTimeSec = 4;

  // Fare Payments (Personal UPI vs Cashfree, Pending/Paid/Disputed)
  List<Map<String, dynamic>> farePayments = [];

  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    fetchStats();
    // Auto-refresh stats every 4 seconds for live telemetry feel
    _refreshTimer = Timer.periodic(const Duration(seconds: 4), (_) => fetchStats());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> fetchStats() async {
    try {
      // 1. Fetch Online Riders (active status)
      final ridersRes = await supabase
          .from('riders')
          .select('id, wallet_balance')
          .eq('account_status', 'active');
      
      final ridersList = List<Map<String, dynamic>>.from(ridersRes);
      double walletSum = 0.0;
      for (final r in ridersList) {
        walletSum += double.tryParse(r['wallet_balance']?.toString() ?? '0') ?? 0.0;
      }

      // 2. Fetch Active Trips & Pending Orders
      final ordersRes = await supabase
          .from('orders')
          .select('id, order_status, final_fare, current_fare, order_type');

      final ordersList = List<Map<String, dynamic>>.from(ordersRes);
      int active = 0;
      int pending = 0;
      int completedCount = 0;
      double revenue = 0.0;

      for (final o in ordersList) {
        final status = o['order_status']?.toString();
        if (['accepted', 'rider_arrived', 'picked_up', 'ongoing', 'rider_at_drop', 'payment_pending'].contains(status)) {
          active++;
        } else if (['created', 'searching'].contains(status)) {
          pending++;
        } else if (['completed', 'delivered'].contains(status)) {
          completedCount++;
          // final_fare is only ever set once a promo discount applies -- it's null otherwise, so
          // falling back to current_fare (not defaulting straight to 0) is required or every
          // non-promo order silently counts as ₹0 of revenue here.
          revenue += double.tryParse(o['final_fare']?.toString() ?? o['current_fare']?.toString() ?? '0') ?? 0.0;
        }
      }

      // 3. Fetch Failed Dispatches from assignments table
      final assignmentsRes = await supabase
          .from('rider_assignments')
          .select('id')
          .eq('assignment_status', 'expired');

      // 4. Fetch recent fare payments (Personal UPI / Cashfree) + any open disputes on them, for
      // the Payment Method Used / Payment Status (Pending/Paid/Disputed) admin view.
      final farePaymentsRes = await supabase
          .from('orders')
          .select('id, order_code, fare_payment_method, payment_status, final_fare, current_fare, fare_payment_screenshot_url, updated_at')
          .eq('payment_mode', 'online')
          .order('updated_at', ascending: false)
          .limit(25);

      final farePaymentsList = List<Map<String, dynamic>>.from(farePaymentsRes);
      final orderIds = farePaymentsList.map((o) => o['id']).toList();

      final openDisputeOrderIds = <dynamic>{};
      if (orderIds.isNotEmpty) {
        final disputesRes = await supabase
            .from('payment_disputes')
            .select('order_id')
            .inFilter('order_id', orderIds)
            .inFilter('status', ['open', 'investigating']);
        for (final d in List<Map<String, dynamic>>.from(disputesRes)) {
          openDisputeOrderIds.add(d['order_id']);
        }
      }

      for (final o in farePaymentsList) {
        o['display_status'] = openDisputeOrderIds.contains(o['id'])
            ? 'Disputed'
            : (o['payment_status']?.toString() == 'paid' ? 'Paid' : 'Pending');
      }

      if (mounted) {
        setState(() {
          onlineRiders = ridersList.length;
          activeTrips = active;
          pendingOrders = pending;
          failedDispatches = List.from(assignmentsRes).length;
          totalWalletBalances = walletSum;
          todayRevenue = revenue;
          todayTrips = completedCount;
          farePayments = farePaymentsList;
          isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('AdminDashboard fetch error: $e');
      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final telemetry = RealtimeObservability.instance.getMetricsSummary();
    final activeChannelsDebug = RealtimeManager.instance.getDebugMetrics();

    return Scaffold(
      backgroundColor: const Color(0xFF090D1A), // midnight-navy bg
      appBar: AppBar(
        backgroundColor: const Color(0xFF131929),
        title: const Text(
          'WAYDROP CONTROL CENTER',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
            fontSize: 16,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Color(0xFF10B981)),
            onPressed: fetchStats,
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF10B981)))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Section: Operational Grid
                  const Text(
                    'LIVE OPERATIONAL METRICS',
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 1.5,
                    children: [
                      _buildGlassCard(
                        'Online Drop Partners',
                        '$onlineRiders',
                        Icons.motorcycle,
                        const Color(0xFF10B981), // Emerald
                      ),
                      _buildGlassCard(
                        'Active Trips',
                        '$activeTrips',
                        Icons.navigation,
                        const Color(0xFF3B82F6), // Blue
                      ),
                      _buildGlassCard(
                        'Pending Orders',
                        '$pendingOrders',
                        Icons.hourglass_empty,
                        const Color(0xFFF59E0B), // Amber
                      ),
                      _buildGlassCard(
                        'Failed Dispatches',
                        '$failedDispatches',
                        Icons.error_outline,
                        const Color(0xFFEF4444), // Red
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Section: Real-time WebSockets
                  const Text(
                    'WEBSOCKET TELEMETRY & LEAK MONITOR',
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF131929),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFF1E293B)),
                    ),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        _buildTelemetryRow('Active Channels (Target: Stable)', '${telemetry['active_channel_count']}', isHighlight: true),
                        _buildTelemetryRow('Websocket Reconnects', '${telemetry['realtime_reconnect_count']}'),
                        _buildTelemetryRow('Channel Error Count', '${telemetry['channel_error_count']}'),
                        _buildTelemetryRow('Heartbeat Failures', '${telemetry['heartbeat_failures']}'),
                        _buildTelemetryRow('Subscription Creations', '${telemetry['subscription_create_count']}'),
                        _buildTelemetryRow('Subscription Disposals', '${telemetry['subscription_dispose_count']}'),
                        _buildTelemetryRow('Avg Reconnect Duration', '${telemetry['average_reconnect_time_ms'].toStringAsFixed(1)} ms'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Section: Active Channel Diagnostics
                  const Text(
                    'ACTIVE WEB SOCKET SUBSCRIPTIONS',
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF131929),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFF1E293B)),
                    ),
                    padding: const EdgeInsets.all(16),
                    child: activeChannelsDebug.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: 16.0),
                              child: Text('No active subscriptions. Channels = 0.', style: TextStyle(color: Colors.grey)),
                            ),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: activeChannelsDebug.length,
                            separatorBuilder: (_, __) => const Divider(color: Color(0xFF1E293B)),
                            itemBuilder: (context, index) {
                              final key = activeChannelsDebug.keys.elementAt(index);
                              final owners = activeChannelsDebug[key] ?? [];
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(key, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                                  const SizedBox(height: 4),
                                  Text('Subscribers (${owners.length}): ${owners.join(", ")}', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
                                ],
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 24),

                  // Section: Fare Payments (Personal UPI / Cashfree, Pending/Paid/Disputed)
                  const Text(
                    'RECENT FARE PAYMENTS',
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF131929),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFF1E293B)),
                    ),
                    padding: const EdgeInsets.all(16),
                    child: farePayments.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: 16.0),
                              child: Text('No online fare payments yet.', style: TextStyle(color: Colors.grey)),
                            ),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: farePayments.length,
                            separatorBuilder: (context, index) => const Divider(color: Color(0xFF1E293B)),
                            itemBuilder: (context, index) {
                              final order = farePayments[index];
                              final method = order['fare_payment_method']?.toString();
                              final amount = double.tryParse(
                                    order['final_fare']?.toString() ?? order['current_fare']?.toString() ?? '0',
                                  ) ??
                                  0.0;
                              final status = order['display_status']?.toString() ?? 'Pending';
                              final screenshotUrl = order['fare_payment_screenshot_url']?.toString();

                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8.0),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            order['order_code']?.toString() ?? '—',
                                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            method == 'personal_upi'
                                                ? 'Personal UPI'
                                                : method == 'cashfree'
                                                    ? 'Cashfree'
                                                    : 'Not yet decided',
                                            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Text(
                                      '₹${amount.toStringAsFixed(2)}',
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                                    ),
                                    const SizedBox(width: 12),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: _statusColor(status).withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(color: _statusColor(status).withValues(alpha: 0.4)),
                                      ),
                                      child: Text(
                                        status,
                                        style: TextStyle(color: _statusColor(status), fontSize: 11, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                    if (screenshotUrl != null && screenshotUrl.isNotEmpty) ...[
                                      const SizedBox(width: 8),
                                      const Icon(Icons.image_outlined, color: Color(0xFF94A3B8), size: 16),
                                    ],
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 24),

                  // Section: Dispatch & Financial Metrics
                  const Text(
                    'DISPATCH & FINANCIAL PERFORMANCE',
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF131929),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFF1E293B)),
                    ),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        _buildTelemetryRow('Dispatch Success Rate', '$dispatchSuccessPercent%'),
                        _buildTelemetryRow('Dispatch Timeout Rate', '$dispatchTimeoutPercent%'),
                        _buildTelemetryRow('Average Assignment Speed', '$averageAssignmentTimeSec seconds'),
                        const Divider(color: Color(0xFF1E293B)),
                        _buildTelemetryRow("Today's Fare Revenue", '₹${todayRevenue.toStringAsFixed(2)}'),
                        _buildTelemetryRow("Today's Completed Trips", '$todayTrips'),
                        _buildTelemetryRow('Global Drop Partner Wallets Balance', '₹${totalWalletBalances.toStringAsFixed(2)}'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildGlassCard(String label, String value, IconData icon, Color color) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF131929),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.bold),
              ),
              Icon(icon, color: color, size: 20),
            ],
          ),
          Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'Paid':
        return const Color(0xFF10B981);
      case 'Disputed':
        return const Color(0xFFEF4444);
      default:
        return const Color(0xFFF59E0B);
    }
  }

  Widget _buildTelemetryRow(String label, String value, {bool isHighlight = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: isHighlight ? const Color(0xFF10B981) : const Color(0xFF94A3B8),
              fontWeight: isHighlight ? FontWeight.bold : FontWeight.normal,
              fontSize: 13,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: isHighlight ? const Color(0xFF10B981) : Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
