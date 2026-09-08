/// Canonical financial-presentation helpers shared by every screen that renders a completed
/// order's fare/earnings breakdown (Local + Intercity, Drop Partner + passenger).
///
/// These helpers never compute or invent a financial value from percentages/raw customer totals
/// -- every number is read directly from the authoritative server-computed columns already on the
/// order row (gst_amount, commission_amount, rider_earning, final_fare/current_fare -- all written
/// exclusively by calculate_fare_breakdown()/update-order-status and protected from client writes
/// by the protect_order_financial_columns trigger). "Deriving" here only ever means addition/
/// subtraction between two already-authoritative numbers (e.g. fareBeforeGst = customerPaid -
/// gstAmount), never a percentage-based recalculation.
library;

/// Rounds a fare to the nearest whole rupee for DISPLAY ONLY (half-up, matching Postgres'
/// `ROUND(x, 0)` in calculate_fare_breakdown()/accept_intercity_request() and pricing-
/// calculations.ts's `roundToWholeRupee()` / `Math.round()`).
///
/// This exists for exactly one situation: a value that has NOT yet passed through the canonical
/// rounding path server-side -- e.g. `intercity_requests.proposed_fare`, a raw client-negotiated
/// figure that only becomes an authoritative whole-rupee `orders.current_fare`/`final_fare` at
/// the moment `accept_intercity_request()` runs. Showing that raw figure as-is before acceptance
/// (e.g. "₹23.64") and the rounded authoritative figure after ("₹24.00") is a real mismatch a
/// customer/rider would notice. Rounding it here for display lets the pre-acceptance UI show the
/// exact whole-rupee amount the order WILL have the instant it's accepted, without duplicating or
/// altering the real rounding formula (still owned exclusively by the server) and without ever
/// writing this rounded value anywhere.
///
/// Never use this on a value that is already authoritative (orders.current_fare/final_fare) --
/// those are already whole rupees; read and display them directly.
int roundFareForDisplay(num amount) => amount.round();

/// One canonical set of payment-method display strings, used by every completion/history screen
/// (Local + Intercity, Drop Partner + passenger) so the same collection method is never worded two
/// different ways in the app. Reads the real stored settlement method -- never assumes/guesses.
class PaymentMethodPresentation {
  static const String personalQr = 'Personal QR / UPI';
  static const String cash = 'Cash';
  static const String cashfree = 'Cashfree';

  /// [fareMethod] is `orders.fare_payment_method` ('personal_upi' | 'cash' | 'cashfree'), the
  /// passenger's actual settlement-time choice (or the driver's own declared collection method) --
  /// always preferred when present. [paymentMode] is the older booking-time
  /// `orders.payment_mode`/`payment_method` field, kept only as a fallback for parcels/legacy
  /// orders that never went through the fare_payment_method flow (see rider_active_order_screen.dart
  /// buildCompletionScreen's own comment on this exact fallback order).
  static String labelFor({String? fareMethod, String? paymentMode}) {
    switch (fareMethod) {
      case 'personal_upi':
        return personalQr;
      case 'cash':
        return cash;
      case 'cashfree':
        return cashfree;
    }
    switch (paymentMode?.toLowerCase()) {
      case 'cash':
        return cash;
      case 'upi':
        return personalQr;
      case 'cashfree':
        return cashfree;
      default:
        // Unknown/legacy 'online' bookings that were actually settled via Cashfree gateway.
        return cashfree;
    }
  }
}

/// Reconciles the canonical customer-payment breakdown from an order's authoritative columns.
/// Every field here is either read directly from the order or derived by pure addition/
/// subtraction of two already-authoritative numbers -- never a percentage-based recalculation of
/// what the server already computed.
class FareBreakdown {
  /// Fare before GST -- what calculate_fare_breakdown() calls the "base fare". Reconciles exactly
  /// with customerPaid - gstAmount by construction (calculate_fare_breakdown always computes
  /// gst_amount as new_total_fare - base_fare).
  final double fareBeforeGst;
  final double gstAmount;
  final double gstPercentage;

  /// The full amount the customer pays/owes -- final_fare when a promo discount applied, else
  /// current_fare. Never actual_fare (the pre-negotiation/pre-boost estimate).
  final double customerPaid;

  final double commissionAmount;
  final double commissionPercentage;
  final bool subscriptionCommissionWaived;

  /// The Drop Partner/Traveller's net trip earning, exactly as credited (fareBeforeGst -
  /// commissionAmount, or 0 commission when a WayDrop MAX subscription waived it).
  final double partnerEarning;

  /// `orders.pg_charge_amount` -- the business-rule Payment Gateway charge (2% of the customer-paid
  /// fare), deducted at completion for an eligible Cashfree ride by the deployed backend rule
  /// (migration 20260901000037, wallet formula updated by 20260901000038). Written once,
  /// server-side, by complete_order_and_settle; `0` for every other order. Authoritative -- always
  /// display this value directly, never recompute 2% in Dart.
  final double pgChargeAmount;

  /// `orders.order_type` / `fare_payment_method` / `payment_status` -- read only to identify the
  /// eligible-PG-ride special case below.
  final String orderType;
  final String farePaymentMethod;
  final String paymentStatus;

  /// True only for a ride settled under the deployed 2% PG-charge rule -- ALL of:
  ///   1. order_type = 'ride'
  ///   2. rider had an active Free Trial / WayDrop MAX at completion
  ///      (persisted as subscription_commission_waived = true)
  ///   3. fare_payment_method = 'cashfree'
  ///   4. payment_status = 'paid'
  ///   5. pg_charge_amount > 0
  ///
  /// When true, [partnerEarning] (`orders.rider_earning`) is ALREADY the final rider net
  /// (customer fare - 2% PG charge ONLY -- migration 20260901000038; GST/[gstAmount] is still
  /// computed and recorded but is a SEPARATE, reporting-only figure, no longer subtracted from
  /// the wallet-credited amount; government tax skipped). Display it DIRECTLY -- never
  /// `partnerEarning + gstAmount - governmentTax`, which assumes rider_earning has government tax
  /// still to subtract, and would over-report by exactly the government tax amount for this case.
  bool get isPgChargeRide =>
      pgChargeAmount > 0 &&
      orderType == 'ride' &&
      farePaymentMethod == 'cashfree' &&
      paymentStatus == 'paid' &&
      subscriptionCommissionWaived;

  const FareBreakdown({
    required this.fareBeforeGst,
    required this.gstAmount,
    required this.gstPercentage,
    required this.customerPaid,
    required this.commissionAmount,
    required this.commissionPercentage,
    required this.subscriptionCommissionWaived,
    required this.partnerEarning,
    this.pgChargeAmount = 0,
    this.orderType = '',
    this.farePaymentMethod = '',
    this.paymentStatus = '',
  });

  /// Builds from a raw `orders` row map (as returned by Supabase), matching exactly what
  /// rider_active_order_screen.dart's buildCompletionScreen already does correctly: derive
  /// fareBeforeGst from rider_earning + commission_amount (both authoritative, always populated by
  /// calculate_fare_breakdown()) rather than trusting a possibly-stale `base_fare` column, which is
  /// never updated when a fare is renegotiated/boosted after booking (see
  /// 20260724000005_canonical_fare_breakdown_and_intercity_fix.sql).
  factory FareBreakdown.fromOrder(Map<String, dynamic> order) {
    final customerPaid = double.tryParse(
          order['final_fare']?.toString() ?? order['current_fare']?.toString() ?? '0',
        ) ??
        0.0;
    final gstAmount = double.tryParse(order['gst_amount']?.toString() ?? '0') ?? 0.0;
    final gstPercentage = double.tryParse(order['gst_percentage']?.toString() ?? '0') ?? 0.0;
    final commissionAmount = double.tryParse(order['commission_amount']?.toString() ?? '0') ?? 0.0;
    final commissionPercentage = double.tryParse(order['commission_percentage']?.toString() ?? '0') ?? 0.0;
    final riderEarning = double.tryParse(order['rider_earning']?.toString() ?? '0') ?? 0.0;
    final subscriptionWaived = order['subscription_commission_waived'] == true;
    final pgChargeAmount = double.tryParse(order['pg_charge_amount']?.toString() ?? '0') ?? 0.0;
    final orderType = order['order_type']?.toString() ?? '';
    final farePaymentMethod = order['fare_payment_method']?.toString() ?? '';
    final paymentStatus = order['payment_status']?.toString() ?? '';

    // Two independently-authoritative derivations of the same pre-GST fare
    // (customerPaid - gstAmount, and riderEarning + commissionAmount) should always agree by
    // construction. Prefer the customer-side derivation (always available, even for orders with no
    // assigned rider yet) and fall back to the earnings-side one only if gstAmount is missing.
    final fareBeforeGst = gstAmount > 0 || customerPaid > 0
        ? (customerPaid - gstAmount)
        : (riderEarning + commissionAmount);

    return FareBreakdown(
      fareBeforeGst: fareBeforeGst,
      gstAmount: gstAmount,
      gstPercentage: gstPercentage,
      customerPaid: customerPaid,
      commissionAmount: commissionAmount,
      commissionPercentage: commissionPercentage,
      subscriptionCommissionWaived: subscriptionWaived,
      partnerEarning: riderEarning,
      pgChargeAmount: pgChargeAmount,
      orderType: orderType,
      farePaymentMethod: farePaymentMethod,
      paymentStatus: paymentStatus,
    );
  }
}
