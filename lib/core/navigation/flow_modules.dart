import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/models/payment_for.dart';
import 'package:waydrop/models/transport_order.dart';
import 'package:waydrop/modules/payments/services/payment_service.dart';
import 'package:waydrop/modules/payments/services/upi_app_launcher.dart';

/// Base abstract class defining the polymorphic visual modules
/// for the Searching and Live Tracking steps.
abstract class FlowModule {
  Widget buildSearchingMeta(BuildContext context, TransportOrder order);
  Widget buildCompletionContent(BuildContext context, TransportOrder order);
}

// =============================================================================
// 1. RIDE FLOW MODULE
// =============================================================================
class RideFlowModule extends FlowModule {
  @override
  Widget buildSearchingMeta(BuildContext context, TransportOrder order) {
    return const SizedBox();
  }

  @override
  Widget buildCompletionContent(BuildContext context, TransportOrder order) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final labelColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Large gradient checkmark
        Container(
          height: 72,
          width: 72,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFC5FF30), Color(0xFF9EFF00)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFC5FF30).withValues(alpha: 0.3),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Icon(Icons.check_rounded, color: Colors.black, size: 38),
        ),
        const SizedBox(height: 18),
        Text(
          'Your trip has been completed',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: textColor),
        ),
        const SizedBox(height: 6),
        Text(
          'Thank You! Tip rider for his service.',
          style: TextStyle(fontSize: 13, color: isDark ? Colors.white60 : Colors.grey.shade600),
        ),
        const SizedBox(height: 24),
        // Sleek receipt card
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFE2E8F0),
              width: 1,
            ),
          ),
          child: Column(
            children: [
              // "Total Paid" -- ride/ride_sharing/intercity_ride orders structurally cannot reach
              // order_status='completed' without payment_pending resolving first (via either a
              // direct settlement confirmation or a real Cashfree webhook), so payment is always
              // genuinely confirmed by the time this content renders -- see update-order-status's
              // transition table and its isCompleting/isDirectSettlement guard.
              Text(
                'Total Paid',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: labelColor),
              ),
              const SizedBox(height: 4),
              Text(
                '₹${order.payableFare.toStringAsFixed(0)}',
                style: TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: textColor),
              ),
              if (order.gstAmount > 0) ...[
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.check_circle_rounded, size: 13, color: Color(0xFF15803D)),
                    const SizedBox(width: 5),
                    const Text('GST included', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF15803D))),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Divider(color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0), height: 1),
              const SizedBox(height: 16),
              // Stat row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildStat('Distance', '${order.distanceKm.toStringAsFixed(1)} km', Icons.route_outlined, const Color(0xFFC5FF30), isDark),
                  Container(height: 32, width: 1, color: isDark ? Colors.white10 : Colors.grey.shade200),
                  _buildStat('Duration', '${order.actualDurationMin ?? order.estimatedDurationMin ?? 28} mins', Icons.access_time_rounded, const Color(0xFFC5FF30), isDark),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// 2. PARCEL FLOW MODULE
// =============================================================================
class ParcelFlowModule extends FlowModule {
  @override
  Widget buildSearchingMeta(BuildContext context, TransportOrder order) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFDF2F8),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFBCFE8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.local_shipping, color: Color(0xFFDB2777), size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Receiver: ${order.receiverName ?? "Not specified"} (${order.receiverPhone ?? "No phone"})',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF9D174D)),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (order.specialInstructions != null && order.specialInstructions!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Instructions: ${order.specialInstructions}',
              style: TextStyle(fontSize: 9, color: Colors.grey.shade700, fontStyle: FontStyle.italic),
            ),
          ]
        ],
      ),
    );
  }

  @override
  Widget buildCompletionContent(BuildContext context, TransportOrder order) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final labelColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    // Same predicate the FarePaymentPanel-visibility check below already uses to decide "is
    // payment still outstanding" -- reused here (instead of re-derived) so the label and the pay
    // panel can never disagree with each other.
    final isSettled = !(order.paymentMode == 'online' && order.paymentStatus != 'paid');

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Large gradient circle with package/local_shipping icon
        Container(
          height: 72,
          width: 72,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFEA580C), Color(0xFFF97316)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFEA580C).withValues(alpha: 0.3),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Icon(Icons.local_shipping_rounded, color: Colors.white, size: 36),
        ),
        const SizedBox(height: 18),
        Text(
          'Your delivery has been completed',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: textColor),
        ),
        const SizedBox(height: 6),
        Text(
          'Thank You! Tip rider for his service.',
          style: TextStyle(fontSize: 13, color: isDark ? Colors.white60 : Colors.grey.shade600),
        ),
        const SizedBox(height: 24),
        // Sleek receipt card
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFE2E8F0),
              width: 1,
            ),
          ),
          child: Column(
            children: [
              // BUG FIX: this label was unconditionally "Total Paid" even though the panel right
              // below (FarePaymentPanel, shown whenever paymentMode=='online' && paymentStatus !=
              // 'paid') proves payment was NOT actually confirmed yet for that exact case --
              // parcels can reach 'delivered' before an online payment resolves (unlike rides,
              // which always pass through payment_pending first). Never say "Paid" before
              // payment_status is actually 'paid'.
              Text(
                isSettled ? 'Total Paid' : 'Amount Due',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: labelColor),
              ),
              const SizedBox(height: 4),
              Text(
                '₹${order.payableFare.toStringAsFixed(0)}',
                style: TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: textColor),
              ),
              if (isSettled && order.gstAmount > 0) ...[
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.check_circle_rounded, size: 13, color: Color(0xFF15803D)),
                    const SizedBox(width: 5),
                    const Text('GST included', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF15803D))),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Divider(color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0), height: 1),
              const SizedBox(height: 16),
              // Stat row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildStat('Weight', order.actualWeightKg != null ? '${order.actualWeightKg} kg' : formatWeightCategory(order.weightCategory), Icons.scale_rounded, const Color(0xFFEA580C), isDark),
                  Container(height: 32, width: 1, color: isDark ? Colors.white10 : Colors.grey.shade200),
                  _buildStat('Receiver', order.receiverName ?? 'Receiver', Icons.person_outline_rounded, const Color(0xFFEA580C), isDark),
                ],
              ),
              if (order.parcelImages.isNotEmpty) ...[
                const SizedBox(height: 16),
                Divider(color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0), height: 1),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Proof Delivered',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: textColor),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Compliance Photo Uploaded',
                          style: TextStyle(fontSize: 10, color: labelColor),
                        ),
                      ],
                    ),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: CachedNetworkImage(
                        imageUrl: order.parcelImages.first,
                        width: 50,
                        height: 50,
                        fit: BoxFit.cover,
                        memCacheWidth: (50 * MediaQuery.of(context).devicePixelRatio).round(),
                        memCacheHeight: (50 * MediaQuery.of(context).devicePixelRatio).round(),
                        errorWidget: (context, url, error) => Container(
                          width: 50,
                          height: 50,
                          color: isDark ? Colors.white12 : Colors.grey.shade200,
                          child: const Icon(Icons.broken_image_rounded, size: 20, color: Colors.white30),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (order.paymentMode == 'online' && order.paymentStatus != 'paid') ...[
          const SizedBox(height: 16),
          FarePaymentPanel(order: order),
        ],
      ],
    );
  }
}

/// Formats the raw weight category string to show formatted weights (e.g. '5' becomes "Up to 5 kg").
String formatWeightCategory(String? category) {
  if (category == null || category.isEmpty) return 'Up to 5 kg';
  final clean = category.trim().toLowerCase();
  final number = int.tryParse(clean);
  if (number != null) {
    return 'Up to $number kg';
  }
  // Try to find digits in the category string
  final regex = RegExp(r'\d+');
  final match = regex.firstMatch(clean);
  if (match != null) {
    return 'Up to ${match.group(0)} kg';
  }
  return category.toUpperCase();
}

// =============================================================================
// 3. INTERCITY FLOW MODULE
// =============================================================================
class IntercityFlowModule extends FlowModule {
  @override
  Widget buildSearchingMeta(BuildContext context, TransportOrder order) {
    return const SizedBox();
  }

  @override
  Widget buildCompletionContent(BuildContext context, TransportOrder order) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final labelColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    final fromCity = (order.pickupCity == null || order.pickupCity!.isEmpty || order.pickupCity == 'Other')
        ? _getCityName(order.pickupAddress, 'Pickup')
        : order.pickupCity!;
    final toCity = (order.destinationCity == null || order.destinationCity!.isEmpty || order.destinationCity == 'Other')
        ? _getCityName(order.destinationAddress, 'Dropoff')
        : order.destinationCity!;

    String travelDateStr = 'Today';
    if (order.travelDate != null) {
      final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      travelDateStr = '${order.travelDate!.day} ${months[order.travelDate!.month - 1]}';
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Large gradient circle with explore icon
        Container(
          height: 72,
          width: 72,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF7C3AED), Color(0xFF9333EA)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF7C3AED).withValues(alpha: 0.3),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Icon(Icons.explore_rounded, color: Colors.white, size: 36),
        ),
        const SizedBox(height: 18),
        Text(
          'Your trip has been completed',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: textColor),
        ),
        const SizedBox(height: 6),
        Text(
          'Thank You! Tip rider for his service.',
          style: TextStyle(fontSize: 13, color: isDark ? Colors.white60 : Colors.grey.shade600),
        ),
        const SizedBox(height: 8),
        // Route representation
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              fromCity,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: textColor),
            ),
            const SizedBox(width: 8),
            Icon(Icons.arrow_forward_rounded, size: 14, color: isDark ? Colors.white30 : Colors.grey.shade400),
            const SizedBox(width: 8),
            Text(
              toCity,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: textColor),
            ),
          ],
        ),
        const SizedBox(height: 24),
        // Sleek receipt card
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFE2E8F0),
              width: 1,
            ),
          ),
          child: Column(
            children: [
              // Total Fare Display
              Text(
                'Total Paid',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: labelColor),
              ),
              const SizedBox(height: 4),
              Text(
                '₹${order.payableFare.toStringAsFixed(0)}',
                style: TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: textColor),
              ),
              const SizedBox(height: 16),
              Divider(color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0), height: 1),
              const SizedBox(height: 16),
              // Stat row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildStat('Distance', '${order.distanceKm.toStringAsFixed(1)} km', Icons.route_outlined, const Color(0xFF7C3AED), isDark),
                  Container(height: 32, width: 1, color: isDark ? Colors.white10 : Colors.grey.shade200),
                  _buildStat('Travel Date', travelDateStr, Icons.calendar_today_rounded, const Color(0xFF7C3AED), isDark),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// 4. FLOW MODULE FACTORY (User request 4)
// =============================================================================
class FlowModuleFactory {
  static FlowModule resolve(OrderFlowType type) {
    switch (type) {
      case OrderFlowType.ride:
        return RideFlowModule();
      case OrderFlowType.localParcel:
      case OrderFlowType.intercityParcel:
        return ParcelFlowModule();
      case OrderFlowType.intercity:
        return IntercityFlowModule();
    }
  }
}

// =============================================================================
// Helper widgets and functions for redesigned screens
// =============================================================================
Widget _buildStat(String label, String value, IconData icon, Color iconColor, bool isDark) {
  final labelColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
  final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 16, color: iconColor),
      const SizedBox(width: 8),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 10, color: labelColor, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: textColor),
          ),
        ],
      ),
    ],
  );
}

String _getCityName(String address, String fallback) {
  if (address.isEmpty) return fallback;
  final parts = address.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  if (parts.length > 1) {
    final statesAndCountries = {
      'telangana', 'andhra pradesh', 'karnataka', 'tamil nadu', 'maharashtra',
      'delhi', 'goa', 'gujarat', 'haryana', 'himachal pradesh', 'kerala',
      'madhya pradesh', 'punjab', 'rajasthan', 'uttar pradesh', 'uttarakhand',
      'west bengal', 'bihar', 'chhattisgarh', 'odisha', 'india'
    };
    for (int i = parts.length - 2; i >= 0; i--) {
      final candidate = parts[i];
      final lower = candidate.toLowerCase().replaceAll(RegExp(r'\d+'), '').trim();
      if (lower.isNotEmpty && !statesAndCountries.contains(lower)) {
        return candidate;
      }
    }
    if (parts.length >= 3) {
      return parts[parts.length - 3];
    }
    return parts[parts.length - 2];
  }
  return address;
}

// =============================================================================
// PASSENGER FARE PAYMENT PANEL
// Shown the moment the order enters payment_pending (trip finished, Drop Partner is waiting to be
// paid before they can confirm and close out the trip).
//   1. "Total Fare ₹X" + a single [ Pay ₹X ] button that opens "Choose Payment Method" -- two
//      equally-weighted first-class options, UPI Apps and Cash (never a tiny text link).
//   2. Picking "UPI Apps" opens "Choose UPI App" -- a list of the UPI apps actually installed on
//      this device (UpiAppLauncher), or a "No supported UPI apps detected" sheet (Try Again / Pay
//      Cash) if none can be reliably detected/opened. Picking an app only brings IT to the
//      foreground (no data, no payment intent of any kind -- see UpiAppLauncher) so the passenger
//      can use its own QR scanner on the Drop Partner's displayed Personal QR and type the amount
//      themselves.
//   3. Picking "Cash" (from either the top-level chooser or the UPI fallback sheet) records the
//      passenger's declaration directly -- no gateway, no intent.
//   Either path records the passenger's declaration (mark_fare_payment_attempted, method
//   'personal_upi' or 'cash') purely so the Drop Partner's screen and update-order-status's
//   completion guard know what to expect, and so the wallet-crediting logic knows the Drop
//   Partner already holds the money directly (no wallet credit) rather than the platform
//   (cashfree, credit wallet).
//   4. This panel never constructs or launches a `upi://pay` (or any other) payment intent, and
//      never sends an amount, order code, note, or reference to a UPI app. An earlier "UPI Apps"
//      button did exactly that, prefilled with the exact fare and a `WayDrop <order_code>` note --
//      real-device testing showed GPay rejects that pattern outright ("declined for security
//      reasons"), so it was removed. The Drop Partner's uploaded Personal QR image is the only
//      supported UPI payment path, and it is rendered byte-for-byte by the Drop Partner's own
//      screen (rider_active_order_screen.dart), never generated or modified here.
//   5. "Having trouble paying?" is always available as a backup escape hatch (Cash / Pay Online
//      Securely -- the existing Cashfree checkout), never triggered automatically.
// =============================================================================
class FarePaymentPanel extends StatefulWidget {
  final TransportOrder order;

  const FarePaymentPanel({super.key, required this.order});

  @override
  State<FarePaymentPanel> createState() => _FarePaymentPanelState();
}

class _FarePaymentPanelState extends State<FarePaymentPanel> {
  static const Color _primaryColor = Color(0xFF10B981);

  bool _actionLoading = false;
  String? _error;

  // Optimistic mirror of the order's own fare_payment_method/fare_payment_attempted_at, set the
  // instant this passenger's own action succeeds so the UI updates immediately instead of waiting
  // on the realtime order subscription to round-trip. The order's real server value (once it
  // arrives) always agrees with this and simply supersedes it -- this is never itself relied on to
  // decide anything financial (nothing here ever sets payment_status).
  String? _optimisticMethod;
  bool _optimisticAttempted = false;

  String? get _method => widget.order.farePaymentMethod ?? _optimisticMethod;
  bool get _attempted => widget.order.farePaymentAttemptedAt != null || _optimisticAttempted;

  Future<void> _markAttempted(String method) async {
    try {
      final result = await Supabase.instance.client.rpc(
        'mark_fare_payment_attempted',
        params: {'p_order_id': widget.order.id, 'p_method': method},
      );
      debugPrint('FARE PANEL => mark_fare_payment_attempted($method) => $result for order ${widget.order.id}');
    } catch (e) {
      debugPrint('MARK FARE PAYMENT ATTEMPTED ERROR => $e');
    }
  }

  // Cash: no gateway, no intent -- just records the passenger's choice so the Drop Partner's
  // screen shows the expected amount and can accept a "Swipe to Confirm ₹X Received" once actually paid.
  Future<void> _payViaCash() async {
    setState(() {
      _actionLoading = true;
      _error = null;
    });
    try {
      await _markAttempted('cash');
      if (!mounted) return;
      setState(() {
        _optimisticMethod = 'cash';
        _optimisticAttempted = true;
      });
    } finally {
      if (mounted) setState(() => _actionLoading = false);
    }
  }

  // Passenger picked a specific installed UPI app from "Choose UPI App". Opens ONLY that app's own
  // home screen (UpiAppLauncher -- no data, no payment intent) so the passenger can use its own QR
  // scanner on the Drop Partner's displayed Personal QR and type the amount themselves.
  Future<void> _payViaUpiApp(UpiApp app) async {
    setState(() {
      _actionLoading = true;
      _error = null;
    });
    try {
      await _markAttempted('personal_upi');
      final opened = await UpiAppLauncher.open(app);
      if (!mounted) return;
      setState(() {
        _optimisticMethod = 'personal_upi';
        _optimisticAttempted = true;
        if (!opened) {
          _error = 'Could not open ${app.name}. Open it yourself and scan your Drop Partner\'s QR.';
        }
      });
    } finally {
      if (mounted) setState(() => _actionLoading = false);
    }
  }

  // Cashfree backup ("Pay Online Securely") -- the only path where WayDrop/Cashfree ever collects
  // the fare itself. payment_status is only ever set to 'paid' by the real server-side Cashfree
  // webhook (see cashfree-webhook), never by this client.
  Future<void> _payViaCashfree() async {
    setState(() {
      _actionLoading = true;
      _error = null;
    });

    try {
      await _markAttempted('cashfree');
      if (!mounted) return;
      setState(() {
        _optimisticMethod = 'cashfree';
        _optimisticAttempted = true;
      });

      if (!context.mounted) return;
      final result = await PaymentService.startPayment(
        context: context,
        paymentFor: PaymentFor.forOrderType(widget.order.orderType),
        amount: widget.order.payableFare,
        paymentMethod: 'cashfree',
        referenceId: widget.order.id,
        paymentForLabel: 'Ride Fare',
      );

      if (!mounted) return;

      if (result['success'] != true) {
        setState(() {
          _error = result['message']?.toString() ?? 'Payment was not completed. Please try again.';
        });
      }
      // On success, orders.payment_status is already 'paid' server-side (set by the Cashfree
      // webhook) -- the tracking screen's realtime order subscription re-renders and the driver
      // can now confirm; there's nothing further to do here.
    } catch (e) {
      debugPrint('FARE PANEL => cashfree payment error for order ${widget.order.id}: $e');
      if (!mounted) return;
      setState(() => _error = 'Unable to start payment. Please try again.');
    } finally {
      if (mounted) setState(() => _actionLoading = false);
    }
  }

  // "Pay ₹X" tapped -- the button is only a UI entry point, it never itself moves money or builds
  // a payment request. Opens "Choose Payment Method" with UPI Apps and Cash as two equally
  // prominent first-class options (Cash is never a tiny text link here).
  Future<void> _handlePayTap() async {
    if (_actionLoading) return;
    await _showChoosePaymentMethodSheet();
  }

  Future<void> _showChoosePaymentMethodSheet() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fareLabel = widget.order.payableFare.toStringAsFixed(0);
    await showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Choose Payment Method',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 16),
              _buildSheetOption(
                context: ctx,
                isDark: isDark,
                icon: Icons.qr_code_scanner_rounded,
                title: 'UPI Apps',
                subtitle: 'Pay using a UPI app',
                onTap: () {
                  Navigator.pop(ctx);
                  _handleUpiAppsTap();
                },
              ),
              const SizedBox(height: 12),
              _buildSheetOption(
                context: ctx,
                isDark: isDark,
                icon: Icons.payments_rounded,
                title: 'Cash',
                subtitle: 'Pay ₹$fareLabel directly to your Drop Partner',
                onTap: () {
                  Navigator.pop(ctx);
                  _payViaCash();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // "UPI Apps" chosen from "Choose Payment Method". Detects installed UPI apps (UpiAppLauncher)
  // and shows either a picker or, if none can be reliably detected/opened, plain instructions --
  // never a upi://pay fallback.
  Future<void> _handleUpiAppsTap() async {
    if (_actionLoading) return;
    setState(() => _actionLoading = true);
    List<UpiApp> apps = const [];
    try {
      apps = await UpiAppLauncher.getAvailableApps();
    } finally {
      if (mounted) setState(() => _actionLoading = false);
    }
    if (!mounted) return;
    debugPrint('FARE PANEL => UPI Apps tapped for order ${widget.order.id}: ${apps.length} UPI app(s) detected'
        '${apps.isEmpty ? '' : ' (${apps.map((a) => a.androidPackage).join(', ')})'}');
    if (apps.isEmpty) {
      await _showUpiInstructionsSheet();
    } else {
      await _showChooseUpiAppSheet(apps);
    }
  }

  Future<void> _showChooseUpiAppSheet(List<UpiApp> apps) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Choose UPI App',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Open a UPI app and scan the QR displayed on your Drop Partner\'s phone, then enter '
                'the amount yourself -- WayDrop never sends a payment request to the app.',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              for (final app in apps) ...[
                _buildSheetOption(
                  context: ctx,
                  isDark: isDark,
                  icon: Icons.qr_code_scanner_rounded,
                  title: app.name,
                  subtitle: 'Open ${app.name} to scan your Drop Partner\'s QR',
                  onTap: () {
                    Navigator.pop(ctx);
                    _payViaUpiApp(app);
                  },
                ),
                const SizedBox(height: 10),
              ],
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _payViaCash();
                },
                child: Text(
                  'Paying cash instead?',
                  style: TextStyle(
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // No UPI app could be reliably detected/opened on this device. Offers a retry (detection can be
  // re-run -- e.g. the passenger just installed/enabled one) or a direct fall-through to cash --
  // never a dead-end acknowledgement screen, and never a pre-filled upi://pay transaction.
  Future<void> _showUpiInstructionsSheet() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'No supported UPI apps detected',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'We couldn\'t find Google Pay, PhonePe, Paytm, or BHIM installed on this device.',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 44,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _handleUpiAppsTap();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primaryColor,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Try Again', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 44,
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _payViaCash();
                  },
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(
                    'Pay Cash',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showTroubleSheet() async {
    if (_actionLoading) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Having trouble paying?',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 16),
              _buildSheetOption(
                context: ctx,
                isDark: isDark,
                icon: Icons.payments_rounded,
                title: 'Pay Cash',
                subtitle: 'Hand the fare to your Drop Partner directly',
                onTap: () {
                  Navigator.pop(ctx);
                  _payViaCash();
                },
              ),
              const SizedBox(height: 12),
              _buildSheetOption(
                context: ctx,
                isDark: isDark,
                icon: Icons.security_rounded,
                title: 'Pay Online Securely',
                subtitle: 'Card, UPI or wallet via Cashfree checkout',
                onTap: () {
                  Navigator.pop(ctx);
                  _payViaCashfree();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSheetOption({
    required BuildContext context,
    required bool isDark,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final labelColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withValues(alpha: 0.04) : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _primaryColor.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _primaryColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: _primaryColor, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: textColor)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(fontSize: 11, color: labelColor)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: labelColor),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final labelColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final fareLabel = widget.order.payableFare.toStringAsFixed(0);

    final boxDecoration = BoxDecoration(
      color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _primaryColor.withValues(alpha: 0.25)),
    );

    // ── Stage 1: nothing chosen yet -- Total Fare + a single Pay button. ────────────────────────
    if (!_attempted) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: boxDecoration,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Total Fare', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: labelColor)),
            const SizedBox(height: 4),
            Text(
              '₹$fareLabel',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: textColor),
            ),
            const SizedBox(height: 8),
            Text(
              'Pay your Drop Partner by scanning their displayed QR code with any UPI app, or in cash.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: labelColor, fontWeight: FontWeight.w600, height: 1.4),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Color(0xFFEF4444), fontWeight: FontWeight.w500)),
            ],
            const SizedBox(height: 16),
            SizedBox(
              height: 48,
              child: ElevatedButton(
                onPressed: _actionLoading ? null : _handlePayTap,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primaryColor,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: _actionLoading
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.0),
                      )
                    : Text(
                        'Pay ₹$fareLabel',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14),
                      ),
              ),
            ),
          ],
        ),
      );
    }

    // ── Stage 2: a method has been chosen -- waiting for driver/gateway confirmation. ───────────
    final method = _method;
    String headline;
    Widget? amountBlock;
    if (method == 'cash') {
      headline = 'Cash payment';
      amountBlock = Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04), borderRadius: BorderRadius.circular(14)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Amount to give Drop Partner', style: TextStyle(color: labelColor, fontSize: 13, fontWeight: FontWeight.w700)),
            Text('₹$fareLabel', style: TextStyle(color: _primaryColor, fontSize: 20, fontWeight: FontWeight.w900)),
          ],
        ),
      );
    } else if (method == 'cashfree') {
      headline = 'Complete your payment to close out the trip';
    } else if (method == 'personal_upi') {
      headline = 'Waiting for your Drop Partner to confirm ₹$fareLabel received';
      amountBlock = Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04), borderRadius: BorderRadius.circular(14)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Amount to pay via UPI', style: TextStyle(color: labelColor, fontSize: 13, fontWeight: FontWeight.w700)),
            Text('₹$fareLabel', style: TextStyle(color: _primaryColor, fontSize: 20, fontWeight: FontWeight.w900)),
          ],
        ),
      );
    } else {
      headline = 'Waiting for your Drop Partner to confirm ₹$fareLabel received';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: boxDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                method == 'cash' ? Icons.payments_rounded : Icons.qr_code_rounded,
                color: _primaryColor,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(headline, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: textColor)),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(fontSize: 12, color: Color(0xFFEF4444), fontWeight: FontWeight.w500)),
          ],
          if (amountBlock != null) ...[
            const SizedBox(height: 12),
            amountBlock,
          ],
          if (method == 'cashfree') ...[
            const SizedBox(height: 14),
            SizedBox(
              height: 44,
              child: OutlinedButton(
                onPressed: _actionLoading ? null : _payViaCashfree,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: _primaryColor.withValues(alpha: 0.5)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _actionLoading
                    ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2.0, color: _primaryColor))
                    : Text(
                        'Retry Payment',
                        style: TextStyle(color: textColor, fontWeight: FontWeight.w700, fontSize: 13),
                      ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          SizedBox(
            height: 36,
            child: TextButton(
              onPressed: _actionLoading ? null : _showTroubleSheet,
              child: Text(
                'Having trouble paying?',
                style: TextStyle(color: labelColor, fontWeight: FontWeight.w700, fontSize: 12, decoration: TextDecoration.underline),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'The trip closes once your Drop Partner confirms they received the payment.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: labelColor),
          ),
        ],
      ),
    );
  }
}
