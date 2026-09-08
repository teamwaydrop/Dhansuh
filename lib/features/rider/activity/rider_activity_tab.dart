import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:waydrop/shared/widgets/skeleton_loader.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/core/services/database/government_tax_ledger_cache.dart';
import 'package:waydrop/shared/helpers/fare_presentation_helper.dart';

class RiderActivityTab extends StatefulWidget {
  const RiderActivityTab({super.key});

  @override
  State<RiderActivityTab> createState() => _RiderActivityTabState();
}

class _RiderActivityTabState extends State<RiderActivityTab> with WidgetsBindingObserver {
  final supabase = Supabase.instance.client;
  List<Map<String, dynamic>> orders = [];
  bool loading = true;
  String? _riderActivitySubId;
  String? _riderActivityChannelName;
  Timer? _debounceTimer;
  Timer? _riderActivitySilentRefreshTimer;
  // Timestamp of the last realtime delivery for this tab. Used to skip the
  // redundant 30s silent refresh while realtime is healthy, matching the
  // pattern in the sibling user ActivityTab -- the timer stays as the pure
  // fallback when realtime is quiet or stale.
  DateTime? _lastRealtimeEventAt;

  // Egress fix (Fix #4): loadActivity() and _subscribeRealtime() both used to independently run
  // their own `riders.select('id')` lookup a few milliseconds apart in initState() -- same value,
  // two requests. Memoizing the in-flight Future (not just the resolved id) means whichever of the
  // two calls it first, the other reuses that exact same pending request instead of firing a
  // second one -- preserves the original concurrent-call timing (initState still calls both
  // without awaiting between them) while guaranteeing only one query.
  Future<String?>? _riderIdFuture;

  Future<String?> _resolveRiderId() {
    return _riderIdFuture ??= () async {
      final user = supabase.auth.currentUser;
      if (user == null) return null;
      final riderData = await supabase.from('riders').select('id').eq('user_id', user.id).maybeSingle();
      return riderData?['id']?.toString();
    }();
  }

  static const Color primaryLime = Color(0xFFC5FF30);
  static const Color darkBg = Color(0xFF0B0F19);
  static const Color textGray = Color(0xFF94A3B8);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    loadActivity();
    _subscribeRealtime();
    _startSilentRefreshTimer();
  }

  void _startSilentRefreshTimer() {
    _riderActivitySilentRefreshTimer?.cancel();
    _riderActivitySilentRefreshTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (!mounted) return;
      final lastEvent = _lastRealtimeEventAt;
      if (lastEvent != null &&
          DateTime.now().difference(lastEvent) < const Duration(seconds: 30)) {
        return;
      }
      loadActivity();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      loadActivity();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounceTimer?.cancel();
    _riderActivitySilentRefreshTimer?.cancel();
    if (_riderActivitySubId != null && _riderActivityChannelName != null) {
      RealtimeManager.instance.unsubscribe(_riderActivityChannelName!, _riderActivitySubId!);
      _riderActivitySubId = null;
      _riderActivityChannelName = null;
    }
    super.dispose();
  }

  Future<void> loadActivity() async {
    try {
      final riderId = await _resolveRiderId();
      if (riderId == null) {
        if (mounted) setState(() => loading = false);
        return;
      }

      // Egress fix: narrowed from bare `.select()` (every column, including large JSON/address/
      // image fields) to the exact fields this tab and its order-details sheet read (grepped
      // exhaustively across every `order['...']` access in this file, plus FareBreakdown.fromOrder's
      // inputs) -- same field list rider_order_history_screen.dart already uses for the identical
      // `orders` shape, plus `order_status` (this tab, unlike order history, also lists cancelled
      // orders and branches its UI on that field) and `updated_at` (the date-fallback this tab's
      // sort/display already relies on for orders with no completed_at).
      final data = await supabase
          .from('orders')
          .select(
            'id, order_type, order_code, order_status, distance_km, time_taken_seconds, '
            'picked_up_at, accepted_at, completed_at, updated_at, boost_amount, '
            'pickup_address, destination_address, rider_earning, vehicle_type, '
            'final_fare, current_fare, gst_amount, gst_percentage, pg_charge_amount, '
            'commission_amount, commission_percentage, subscription_commission_waived, '
            'fare_payment_method, payment_mode, payment_status',
          )
          .eq('rider_id', riderId)
          .inFilter('order_status', ['completed', 'delivered', 'cancelled'])
          .order('updated_at', ascending: false)
          .limit(30);

      if (!mounted) return;
      setState(() {
        orders = List<Map<String, dynamic>>.from(data);
        loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _subscribeRealtime() async {
    try {
      final riderId = await _resolveRiderId();
      if (!mounted) return;
      if (riderId == null) return;

      if (_riderActivitySubId != null && _riderActivityChannelName != null) {
        RealtimeManager.instance.unsubscribe(_riderActivityChannelName!, _riderActivitySubId!);
        _riderActivitySubId = null;
        _riderActivityChannelName = null;
      }

      _riderActivityChannelName = 'rider-activity-channel-$riderId';
      _riderActivitySubId = RealtimeManager.instance.subscribe(
        channelName: _riderActivityChannelName!,
        table: 'orders',
        owner: 'RiderActivityTab',
        event: PostgresChangeEvent.all,
        filterColumn: 'rider_id',
        filterValue: riderId,
        callback: (payload) {
          _lastRealtimeEventAt = DateTime.now();
          _debounceTimer?.cancel();
          _debounceTimer = Timer(const Duration(milliseconds: 500), () {
            if (mounted) loadActivity();
          });
        },
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: darkBg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 24, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Activity',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -0.5),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Your completed rides & deliveries',
                    style: TextStyle(fontSize: 13, color: textGray, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
            Expanded(
              child: loading
                  ? const SkeletonLoader()
                  : orders.isEmpty
                      ? _empty()
                      : RefreshIndicator(
                          color: primaryLime,
                          onRefresh: loadActivity,
                          child: ListView.separated(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            itemCount: orders.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (_, i) => _ActivityRow(order: orders[i]),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: primaryLime.withOpacity(0.08), borderRadius: BorderRadius.circular(20)),
            child: const Icon(Icons.history_rounded, color: primaryLime, size: 32),
          ),
          const SizedBox(height: 16),
          const Text('No Recent Trips', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white)),
          const SizedBox(height: 6),
          const Text(
            'Completed rides & deliveries appear here',
            style: TextStyle(fontSize: 13, color: textGray),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final Map<String, dynamic> order;
  const _ActivityRow({required this.order});

  bool get completed => ['completed', 'delivered'].contains(order['order_status']);

  @override
  Widget build(BuildContext context) {
    // Show net earnings (rider_earning) for completed orders, otherwise show current/final fare
    final fare = completed
        ? (double.tryParse(order['rider_earning']?.toString() ?? '0') ?? 0.0)
        : (double.tryParse(order['final_fare']?.toString() ?? order['current_fare']?.toString() ?? '0') ?? 0.0);
    final type = order['order_type'] ?? '';
    final code = order['order_code'] ?? '';
    final date = order['completed_at'] ?? order['updated_at'] ?? '';
    final dt = DateTime.tryParse(date.toString())?.toLocal();
    final dateStr = dt != null ? '${dt.day}/${dt.month}/${dt.year}' : '';

    const Color primaryLime = Color(0xFFC5FF30);
    const Color darkCard = Color(0xFF131926);
    const Color textGray = Color(0xFF94A3B8);

    final isParcel = type == 'local_parcel' || type == 'intercity_parcel' || type.toString().contains('parcel');
    final vehicleType = order['vehicle_type']?.toString().toLowerCase() ?? 'bike';
    String vehicleImg = 'bike';
    if (vehicleType.contains('delivery') || vehicleType.contains('parcel') || vehicleType.contains('package')) {
      vehicleImg = 'delivery';
    } else if (vehicleType.contains('auto') || vehicleType.contains('rickshaw')) {
      vehicleImg = 'auto';
    } else if (vehicleType.contains('cab') || vehicleType.contains('car') || vehicleType.contains('sedan')) {
      vehicleImg = 'cab';
    } else {
      vehicleImg = 'bike';
    }

    return GestureDetector(
      onTap: () => _showOrderDetailsSheet(context, order),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: darkCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.05), width: 1.5),
        ),
        child: Row(
          children: [
            completed
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.asset(
                      isParcel ? 'assets/images/delivery.png' : 'assets/images/$vehicleImg.jpg',
                      width: 44,
                      height: 44,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: primaryLime.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(Icons.check_circle_outline_rounded, color: primaryLime, size: 22),
                      ),
                    ),
                  )
                : Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2).withOpacity(0.08),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.cancel_outlined,
                      color: Color(0xFFEF4444),
                      size: 22,
                    ),
                  ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_label(type), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white)),
                  Text('$code · $dateStr', style: const TextStyle(fontSize: 11, color: textGray)),
                ],
              ),
            ),
            Text(
              completed ? '+₹${fare.toStringAsFixed(2)}' : '₹${fare.toStringAsFixed(2)}',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w900,
                color: completed ? primaryLime : textGray,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _label(String type) {
    if (type == 'ride') return 'Ride';
    if (type == 'local_parcel') return 'Local Parcel';
    if (type == 'intercity_parcel') return 'Intercity Parcel';
    return 'Order';
  }
}

void _showOrderDetailsSheet(BuildContext context, Map<String, dynamic> order) {
  final type = order['order_type']?.toString() ?? 'ride';
  final code = order['order_code']?.toString() ?? '';
  final distance = double.tryParse(order['distance_km']?.toString() ?? '0') ?? 0.0;
  final timeTakenSec = int.tryParse(order['time_taken_seconds']?.toString() ?? '') ?? 0;

  String timeTakenStr = 'N/A';
  if (timeTakenSec > 0) {
    final mins = timeTakenSec ~/ 60;
    final secs = timeTakenSec % 60;
    timeTakenStr = '${mins}m ${secs}s';
  } else {
    try {
      final pAt = DateTime.tryParse(order['picked_up_at']?.toString() ?? order['accepted_at']?.toString() ?? '');
      final cAt = DateTime.tryParse(order['completed_at']?.toString() ?? '');
      if (pAt != null && cAt != null) {
        final diff = cAt.difference(pAt);
        final mins = diff.inMinutes;
        final secs = diff.inSeconds % 60;
        timeTakenStr = '${mins}m ${secs}s';
      }
    } catch (_) {}
  }

  const Color primaryLime = Color(0xFFC5FF30);
  const Color darkCard = Color(0xFF131926);
  const Color textGray = Color(0xFF94A3B8);

  showModalBottomSheet(
    context: context,
    backgroundColor: darkCard,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
               const SizedBox.shrink(),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Order #${code.toUpperCase()}',
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: primaryLime.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      type.toUpperCase(),
                      style: const TextStyle(color: primaryLime, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(color: Colors.white10),
              const SizedBox(height: 12),
                Builder(
                  builder: (context) {
                    // Canonical breakdown: every value here is read directly from the
                    // authoritative server-computed columns (never recomputed client-side from the
                    // customer total, which previously invented a GST/commission split whenever
                    // `base_fare` happened to be unset/stale -- see FareBreakdown.fromOrder's doc).
                    final breakdown = FareBreakdown.fromOrder(order);
                    final boost = double.tryParse(order['boost_amount']?.toString() ?? '') ?? 0.0;
                    final orderId = order['id']?.toString();

                    // Same direct-collection rule as complete_order_and_settle (20260813000000) --
                    // read here only to choose an honest LABEL, never to alter the amount shown.
                    // final_fare/current_fare (breakdown.customerPaid) is the agreed total ride
                    // fare regardless of how it was collected -- it's the same figure already shown
                    // to the partner on the active-ride screen before completion (e.g. the amount
                    // quoted for a personal-UPI/cash handoff), so it is never fabricated/zero for a
                    // direct-collection ride. Only the LABEL differs: "Customer Paid" implies
                    // WayDrop's own gateway collected it, which is misleading for cash/personal-UPI.
                    final fareMethod = order['fare_payment_method']?.toString();
                    final paymentModeStr = (order['payment_mode']?.toString() ?? 'cash').toLowerCase();
                    final paymentStatusStr = order['payment_status']?.toString();
                    final isDirectCollection = fareMethod != null
                        ? (fareMethod == 'personal_upi' || fareMethod == 'cash')
                        : (paymentModeStr == 'cash' || paymentModeStr == 'upi' || paymentStatusStr != 'paid');

                    Widget buildBreakdownRow(String label, String value, {Color? color, bool isSub = false}) {
                      return Padding(
                        padding: EdgeInsets.only(left: isSub ? 16 : 0, top: 4, bottom: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(label, style: TextStyle(color: isSub ? textGray : Colors.white70, fontSize: isSub ? 11 : 12)),
                            Text(value, style: TextStyle(color: color ?? (isSub ? textGray : Colors.white), fontSize: isSub ? 11 : 13, fontWeight: isSub ? FontWeight.w500 : FontWeight.bold)),
                          ],
                        ),
                      );
                    }

                    Widget buildSectionHeader(String label) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4, top: 2),
                        child: Text(
                          label,
                          style: const TextStyle(color: textGray, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.6),
                        ),
                      );
                    }

                    // Government Tax is fetched once here (not derived from a hard-coded
                    // percentage) so YOUR TRIP EARNINGS below can be computed correctly.
                    // calculate_fare_breakdown() only ever subtracts commission from base_fare to
                    // get rider_earning, never government tax (that lives in the separate
                    // government_tax_ledger apply_order_government_tax() maintains), so reading
                    // rider_earning/breakdown.partnerEarning directly here would silently equal
                    // Ride Fare whenever commission is 0% (free trial/MAX) -- part of the reported
                    // bug. The other part: base_fare (what riderEarning is derived from) already
                    // has "Platform GST" (orders.gst_amount, a distinct, partner-facing-hidden
                    // concept) netted out of it, so riderEarning - govTax alone would silently
                    // understate earnings by the Platform GST amount too (the reported
                    // "₹51.49 shown before completion becomes ₹49.04 on the completed screen" bug).
                    // Fix: reuse the already-correct riderEarning and add back the Platform GST
                    // base_fare had netted out -- customerPaid - commission - govTax algebraically
                    // equals riderEarning + platformGstAmount - govTax. Only addition/subtraction of
                    // existing authoritative values; Platform GST itself is still never displayed.
                    // Egress fix (Fix #6): a government_tax_ledger ORDER_TAX row is immutable once
                    // written, so it's safe to cache per order_id -- reopening this same order's
                    // detail sheet within a session no longer re-fetches it.
                    return FutureBuilder<Map<String, dynamic>?>(
                      future: orderId == null
                          ? Future.value(null)
                          : GovernmentTaxLedgerCache.get(
                              orderId,
                              () => Supabase.instance.client
                                  .from('government_tax_ledger')
                                  .select('amount, rate_percent')
                                  .eq('order_id', orderId)
                                  .eq('entry_type', 'ORDER_TAX')
                                  .maybeSingle(),
                            ),
                      builder: (context, snapshot) {
                        final taxLoading = snapshot.connectionState == ConnectionState.waiting;
                        final row = snapshot.data;
                        final taxAmount = double.tryParse(row?['amount']?.toString() ?? '0') ?? 0.0;
                        final taxRate = double.tryParse(row?['rate_percent']?.toString() ?? '0') ?? 0.0;
                        // Eligible Cashfree ride under the deployed PG-charge rule
                        // (breakdown.isPgChargeRide, migration 20260901000038): rider_earning is
                        // ALREADY the final net (fare - 2% PG charge only; GST recorded separately,
                        // not deducted; government tax skipped). Show it directly -- adding
                        // gstAmount back would over-report by the GST amount.
                        final netEarnings = breakdown.isPgChargeRide
                            ? breakdown.partnerEarning
                            : (taxLoading
                                ? breakdown.partnerEarning
                                : (breakdown.partnerEarning + breakdown.gstAmount - taxAmount));

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            buildSectionHeader('RIDE FARE'),
                            // Ride Fare = breakdown.customerPaid (final_fare/current_fare) -- the
                            // full agreed total, same figure already shown to the partner on the
                            // active-ride screen before completion, regardless of collection
                            // method. NEVER breakdown.fareBeforeGst, which nets Platform GST out of
                            // the total. Only the LABEL depends on collection method (a cash/
                            // personal-UPI ride is settled directly between rider and passenger, so
                            // "Customer Paid" -- implying WayDrop's own gateway collected it --
                            // would be misleading; "Ride Fare" is the honest label there instead).
                            buildBreakdownRow(
                              isDirectCollection ? 'Ride Fare' : 'Customer Paid',
                              '₹${breakdown.customerPaid.toStringAsFixed(2)}',
                            ),
                            if (boost > 0)
                              buildBreakdownRow('• Surge Boost', '+₹${boost.toStringAsFixed(2)}', isSub: true, color: primaryLime),
                            const SizedBox(height: 8),
                            const Divider(color: Colors.white10),
                            const SizedBox(height: 8),
                            buildSectionHeader('DEDUCTIONS'),
                            buildBreakdownRow(
                              breakdown.subscriptionCommissionWaived
                                  ? 'WayDrop Commission (0%)'
                                  : 'WayDrop Commission (${breakdown.commissionPercentage.toStringAsFixed(0)}%)',
                              breakdown.subscriptionCommissionWaived ? '₹0.00' : '-₹${breakdown.commissionAmount.toStringAsFixed(2)}',
                              color: breakdown.subscriptionCommissionWaived ? Colors.white : const Color(0xFFEF4444),
                            ),
                            if (breakdown.subscriptionCommissionWaived)
                              buildBreakdownRow('Subscription Benefit', 'Commission waived', color: primaryLime),
                            if (breakdown.isPgChargeRide)
                              // Eligible 2% PG-charge ride -- only the PG charge is an actual wallet
                              // deduction (orders.pg_charge_amount). GST (orders.gst_amount) is
                              // recorded separately and shown below the earnings line, never here
                              // under DEDUCTIONS -- it no longer reduces YOUR TRIP EARNINGS.
                              buildBreakdownRow('PG Charge (2%)', '₹${breakdown.pgChargeAmount.toStringAsFixed(2)}')
                            else
                              // Government Tax -- a SEPARATE concept from WayDrop Commission above,
                              // read from government_tax_ledger (the same table
                              // apply_order_government_tax() writes -- see
                              // 20260726000003_government_tax_due_schema.sql's
                              // government_tax_ledger_read_own RLS policy, which already lets a rider
                              // read their own rows directly). 0% company commission during a free
                              // trial/MAX subscription never changes this value.
                              taxLoading
                                  ? const Padding(
                                      padding: EdgeInsets.symmetric(vertical: 4),
                                      child: Text(
                                        'Checking applicable government tax...',
                                        style: TextStyle(color: textGray, fontSize: 11),
                                      ),
                                    )
                                  : buildBreakdownRow(
                                      taxRate > 0 ? 'Government Tax (${taxRate.toStringAsFixed(0)}%)' : 'Government Tax',
                                      '₹${taxAmount.toStringAsFixed(2)}',
                                    ),
                            const SizedBox(height: 8),
                            const Divider(color: Colors.white10),
                            const SizedBox(height: 8),
                            buildBreakdownRow('YOUR TRIP EARNINGS', '₹${netEarnings.toStringAsFixed(2)}', color: primaryLime),
                            if (breakdown.isPgChargeRide) ...[
                              const SizedBox(height: 4),
                              // GST (5%) -- recorded on the order for reporting/audit only. Not part
                              // of DEDUCTIONS, not subtracted from YOUR TRIP EARNINGS (Phase 12,
                              // migration 20260901000038). Neutral color so it never reads as a
                              // wallet deduction.
                              buildBreakdownRow(
                                'GST (5%) -- recorded separately',
                                '₹${breakdown.gstAmount.toStringAsFixed(2)}',
                                color: textGray,
                              ),
                            ],
                            Padding(
                              padding: const EdgeInsets.only(top: 2, bottom: 4),
                              child: Text(
                                breakdown.isPgChargeRide
                                    ? 'PG Charge (2%) is the only deduction from your wallet. GST is recorded separately and is not deducted. No government tax applies on this ride.'
                                    : 'Government tax is separate from company commission and applies '
                                        'regardless of subscription/free-trial status.',
                                style: const TextStyle(color: textGray, fontSize: 10, height: 1.3),
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Divider(color: Colors.white10),
                            const SizedBox(height: 8),
                            _buildDetailRowHelper('Distance Traveled', '${distance.toStringAsFixed(1)} km'),
                            const SizedBox(height: 10),
                            _buildDetailRowHelper('Time Taken', timeTakenStr),
                          ],
                        );
                      },
                    );
                  },
                ),
              const SizedBox(height: 12),
              const Divider(color: Colors.white10),
              const SizedBox(height: 12),
              const Text(
                'PICKUP',
                style: TextStyle(color: textGray, fontSize: 10, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                order['pickup_address'] ?? 'N/A',
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),
              const Text(
                'DESTINATION',
                style: TextStyle(color: textGray, fontSize: 10, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                order['destination_address'] ?? 'N/A',
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    final cleanPhone = '1800-WAY-DROP'.replaceAll(RegExp(r'\s+'), '');
                    final uri = Uri.parse('tel:$cleanPhone');
                    try {
                      await launchUrl(uri);
                    } catch (_) {}
                  },
                  icon: const Icon(Icons.support_agent_rounded, size: 18),
                  label: const Text('Customer Support', style: TextStyle(fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryLime,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.05),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                  child: const Text('Close', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Widget _buildDetailRowHelper(String label, String value, {Color valueColor = Colors.white, bool isBold = false}) {
  const textGray = Color(0xFF94A3B8);
  return Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(label, style: const TextStyle(color: textGray, fontSize: 12, fontWeight: FontWeight.w500)),
      Text(
        value,
        style: TextStyle(
          color: valueColor,
          fontSize: 13,
          fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
        ),
      ),
    ],
  );
}
