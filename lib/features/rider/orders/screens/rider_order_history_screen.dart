import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:waydrop/shared/widgets/skeleton_loader.dart';
import 'package:waydrop/core/services/database/government_tax_ledger_cache.dart';
import 'package:waydrop/shared/helpers/fare_presentation_helper.dart';

class RiderOrderHistoryScreen extends StatefulWidget {
  final String riderId;

  const RiderOrderHistoryScreen({
    super.key,
    required this.riderId,
  });

  @override
  State<RiderOrderHistoryScreen> createState() => _RiderOrderHistoryScreenState();
}

class _RiderOrderHistoryScreenState extends State<RiderOrderHistoryScreen> {
  final supabase = Supabase.instance.client;
  List<Map<String, dynamic>> orderHistory = [];
  List<Map<String, dynamic>> travelPlansHistory = [];
  bool loading = true;

  static const Color primaryLime = Color(0xFFC5FF30);
  static const Color darkBg = Color(0xFF0B0F19);
  static const Color darkCard = Color(0xFF131926);
  static const Color textGray = Color(0xFF94A3B8);

  @override
  void initState() {
    super.initState();
    loadHistoryData();
  }

  Future<void> loadHistoryData() async {
    try {
      // Egress fix: narrowed from `*` to the exact columns this screen and its
      // travel-plan history sheet read (grepped exhaustively across every
      // `order['...']`/`plan['...']`/`widget.plan['...']` access in this file).
      //
      // BUG FIX (Government Tax always showed ₹0.00 here, even for orders that show a real amount
      // elsewhere): this select was missing `id` entirely, so the detail sheet's government_tax_
      // ledger lookup (keyed on order_id) always ran with a null id and matched nothing. Also
      // missing: every FareBreakdown.fromOrder() input (final_fare, current_fare, gst_amount,
      // gst_percentage, commission_amount, commission_percentage, subscription_commission_waived)
      // and the direct-collection fields (fare_payment_method, payment_mode, payment_status) --
      // all now added.
      final ordersData = await supabase
          .from('orders')
          .select(
            'id, order_type, order_code, distance_km, time_taken_seconds, '
            'picked_up_at, accepted_at, completed_at, boost_amount, '
            'pickup_address, destination_address, rider_earning, vehicle_type, '
            'final_fare, current_fare, gst_amount, gst_percentage, pg_charge_amount, '
            'commission_amount, commission_percentage, subscription_commission_waived, '
            'fare_payment_method, payment_mode, payment_status',
          )
          .eq('rider_id', widget.riderId)
          .inFilter('order_status', ['completed', 'delivered'])
          .order('completed_at', ascending: false)
          .limit(50);

      final plansData = await supabase
          .from('rider_travel_plans')
          .select('rider_id, pickup_city, destination_city, travel_date, status')
          .eq('rider_id', widget.riderId)
          .order('travel_date', ascending: false);

      if (mounted) {
        setState(() {
          orderHistory = List<Map<String, dynamic>>.from(ordersData);
          travelPlansHistory = List<Map<String, dynamic>>.from(plansData);
          loading = false;
        });
      }
    } catch (e) {
      debugPrint('LOAD HISTORY DATA ERROR => $e');
      if (mounted) {
        setState(() => loading = false);
      }
    }
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

  String _formatDateTime(dynamic dtStr) {
    if (dtStr == null) return '';
    try {
      final dt = DateTime.parse(dtStr.toString()).toLocal();
      final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      final minStr = dt.minute < 10 ? '0${dt.minute}' : '${dt.minute}';
      return '${dt.day} ${months[dt.month - 1]} at ${dt.hour}:$minStr';
    } catch (_) {
      return '';
    }
  }

  String _capitalize(String text) {
    if (text.isEmpty) return '';
    return text[0].toUpperCase() + text.substring(1);
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
                    // authoritative server-computed columns (never recomputed from userAmount
                    // client-side, which previously invented a GST/commission split whenever
                    // `base_fare` happened to be unset/stale -- see FareBreakdown.fromOrder's doc).
                    final breakdown = FareBreakdown.fromOrder(order);
                    final boost = double.tryParse(order['boost_amount']?.toString() ?? '') ?? 0.0;
                    final orderId = order['id']?.toString();

                    // Same direct-collection rule as complete_order_and_settle (20260813000000) --
                    // read only to choose an honest LABEL, never to alter the amount shown.
                    // breakdown.customerPaid (final_fare/current_fare) is the agreed total ride
                    // fare regardless of collection method -- a cash/personal-UPI ride has no real
                    // "amount WayDrop's own gateway collected" on this row, so labeling it
                    // "Customer Paid" would be misleading; "Ride Fare" is the honest label there.
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

                    // Government Tax is fetched once here (not re-derived from a hard-coded
                    // percentage) so "YOUR TRIP EARNINGS" below can be computed correctly.
                    // calculate_fare_breakdown() only ever subtracts commission from base_fare to
                    // get rider_earning, never government tax (that's a separate ledger
                    // apply_order_government_tax() maintains), so reading
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
                            // the total. Only the LABEL depends on collection method.
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
                            _buildDetailRow('Distance Traveled', '${distance.toStringAsFixed(1)} km'),
                            const SizedBox(height: 10),
                            _buildDetailRow('Time Taken', timeTakenStr),
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

  Widget _buildDetailRow(String label, String value, {Color valueColor = Colors.white, bool isBold = false}) {
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

  Widget _buildCompletedOrdersTab() {
    if (orderHistory.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inventory_2_rounded, color: textGray.withOpacity(0.3), size: 48),
            const SizedBox(height: 12),
            const Text(
              'No completed orders yet',
              style: TextStyle(color: textGray, fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      itemCount: orderHistory.length,
      itemBuilder: (context, index) {
        final order = orderHistory[index];
        final type = order['order_type']?.toString() ?? 'ride';
        final fare = double.tryParse(order['rider_earning']?.toString() ?? '0') ?? 0.0;
        final code = order['order_code']?.toString() ?? '';
        final timeStr = _formatDateTime(order['completed_at']);

        IconData icon;
        if (type == 'parcel') {
          icon = Icons.inventory_2_rounded;
        } else if (type == 'intercity') {
          icon = Icons.alt_route_rounded;
        } else {
          icon = Icons.two_wheeler_rounded;
        }

        final isParcel = type == 'local_parcel' || type == 'intercity_parcel' || type.contains('parcel');
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
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: darkCard,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.05), width: 1.5),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.asset(
                    isParcel ? 'assets/images/delivery.png' : 'assets/images/$vehicleImg.jpg',
                    height: 44,
                    width: 44,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      height: 44,
                      width: 44,
                      decoration: BoxDecoration(
                        color: primaryLime.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(icon, color: primaryLime, size: 22),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_capitalize(type)} • #$code',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_getAreaName(order['pickup_address'])} ➔ ${_getAreaName(order['destination_address'])}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: textGray,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (timeStr.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          timeStr,
                          style: const TextStyle(
                            color: Colors.white24,
                            fontSize: 10.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '+₹${fare.toStringAsFixed(2)}',
                  style: const TextStyle(
                    color: primaryLime,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTravelPlansTab() {
    if (travelPlansHistory.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.alt_route_rounded, color: textGray.withOpacity(0.3), size: 48),
            const SizedBox(height: 12),
            const Text(
              'No travel plans found',
              style: TextStyle(color: textGray, fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      itemCount: travelPlansHistory.length,
      itemBuilder: (context, index) {
        final plan = travelPlansHistory[index];
        final pickup = plan['pickup_city'] ?? 'Unknown';
        final dest = plan['destination_city'] ?? 'Unknown';
        final date = plan['travel_date']?.toString() ?? '';
        final status = plan['status']?.toString() ?? 'active';

        String formattedDate = '';
        if (date.isNotEmpty) {
          try {
            final dt = DateTime.parse(date).toLocal();
            final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
            formattedDate = '${dt.day} ${months[dt.month - 1]} ${dt.year}';
          } catch (_) {}
        }

        Color statusColor;
        if (status == 'completed') {
          statusColor = Colors.greenAccent;
        } else if (status == 'cancelled') {
          statusColor = Colors.redAccent;
        } else {
          statusColor = Colors.orangeAccent;
        }

        return GestureDetector(
          onTap: () {
            showModalBottomSheet(
              context: context,
              backgroundColor: darkCard,
              isScrollControlled: true,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              builder: (ctx) {
                return _TravelPlanHistoryDetailsSheet(plan: plan);
              },
            );
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: darkCard,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.05), width: 1.5),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.08),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.alt_route_rounded, color: statusColor, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$pickup ➔ $dest',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (formattedDate.isNotEmpty)
                        Text(
                          formattedDate,
                          style: const TextStyle(color: textGray, fontSize: 12),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    status.toUpperCase(),
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: darkBg,
        appBar: AppBar(
          backgroundColor: darkBg,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          title: const Text(
            'Order History',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 20,
            ),
          ),
          centerTitle: true,
          bottom: const TabBar(
            indicatorColor: primaryLime,
            labelColor: primaryLime,
            unselectedLabelColor: textGray,
            labelStyle: TextStyle(fontWeight: FontWeight.bold),
            unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w500),
            tabs: [
              Tab(text: 'Completed Orders'),
              Tab(text: 'Travel Plans'),
            ],
          ),
        ),
        body: SafeArea(
          child: loading
              ? const SkeletonLoader()
              : TabBarView(
                  children: [
                    _buildCompletedOrdersTab(),
                    _buildTravelPlansTab(),
                  ],
                ),
        ),
      ),
    );
  }
}

class _TravelPlanHistoryDetailsSheet extends StatefulWidget {
  final Map<String, dynamic> plan;
  const _TravelPlanHistoryDetailsSheet({required this.plan});

  @override
  State<_TravelPlanHistoryDetailsSheet> createState() => _TravelPlanHistoryDetailsSheetState();
}

class _TravelPlanHistoryDetailsSheetState extends State<_TravelPlanHistoryDetailsSheet> {
  final supabase = Supabase.instance.client;
  List<Map<String, dynamic>> matchedOrders = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    fetchMatchedOrders();
  }

  Future<void> fetchMatchedOrders() async {
    try {
      // Egress fix: narrowed from `*, users(...)` (unbounded) to the 4 fields
      // this sheet actually renders (order_code, users.full_name, rider_earning,
      // order_type), plus a limit -- this was pulling every column (parcel_images,
      // full addresses, etc.) for every completed order ever matched to this
      // route, with no cap.
      final res = await supabase
          .from('orders')
          .select('order_code, rider_earning, order_type, users(full_name)')
          .eq('rider_id', widget.plan['rider_id'])
          .eq('pickup_city', widget.plan['pickup_city'])
          .eq('destination_city', widget.plan['destination_city'])
          .inFilter('order_status', ['completed', 'delivered'])
          .order('completed_at', ascending: false)
          .limit(50);
      if (mounted) {
        setState(() {
          matchedOrders = List<Map<String, dynamic>>.from(res);
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const Color primaryLime = Color(0xFFC5FF30);
    const Color textGray = Color(0xFF94A3B8);
    const Color darkCard = Color(0xFF131926);

    final status = widget.plan['status']?.toString() ?? 'active';
    final dateStr = widget.plan['travel_date'] != null
        ? DateTime.tryParse(widget.plan['travel_date'].toString())?.toLocal().toString().split(' ').first ?? ''
        : '';

    Color statusColor;
    if (status == 'completed') {
      statusColor = Colors.greenAccent;
    } else if (status == 'cancelled') {
      statusColor = Colors.redAccent;
    } else {
      statusColor = Colors.orangeAccent;
    }

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.all(24),
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox.shrink(),
            const SizedBox(height: 20),
            Text(
              '${widget.plan['pickup_city']} ➔ ${widget.plan['destination_city']}',
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  'Date: $dateStr',
                  style: const TextStyle(color: textGray, fontSize: 12),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    status.toUpperCase(),
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(color: Colors.white10),
            const SizedBox(height: 12),
            const Text(
              'COMPLETED SHIPMENT ORDERS UNDER PLAN',
              style: TextStyle(color: textGray, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator(color: primaryLime))
                  : matchedOrders.isEmpty
                      ? const Center(
                          child: Text(
                            'No completed orders under this travel plan.',
                            style: TextStyle(color: textGray, fontSize: 13),
                          ),
                        )
                      : ListView.separated(
                          itemCount: matchedOrders.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (context, i) {
                            final o = matchedOrders[i];
                            final code = o['order_code']?.toString() ?? '';
                            final user = o['users'] as Map<String, dynamic>?;
                            final name = user?['full_name'] ?? 'User';
                            final fare = double.tryParse(o['rider_earning']?.toString() ?? '0') ?? 0.0;
                            final orderType = o['order_type']?.toString() ?? 'parcel';

                            return Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.02),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    orderType.contains('ride') ? Icons.two_wheeler_rounded : Icons.inventory_2_rounded,
                                    color: primaryLime,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Order #${code.toUpperCase()}',
                                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                                        ),
                                        Text(
                                          'User: $name',
                                          style: const TextStyle(color: textGray, fontSize: 11),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    '₹${fare.toStringAsFixed(2)}',
                                    style: const TextStyle(color: primaryLime, fontWeight: FontWeight.bold, fontSize: 14),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
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
  }
}
