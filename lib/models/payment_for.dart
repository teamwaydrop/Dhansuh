/// Mirrors the Supabase `payment_for_enum` type. `subscription` is the driver
/// subscription checkout (Cashfree). The `*Order`/`rideSharing` members are
/// passenger fare payments -- collected into the platform's own Cashfree
/// merchant account instead of the old direct-to-driver `upi://pay` deep
/// link (which banks/NPCI reliably block regardless of which UPI app sends
/// it; see UpiPaymentPanel's removal). The driver is credited via their
/// existing wallet + Cashfree Payouts withdrawal flow, not paid directly.
enum PaymentFor {
  subscription,
  rideOrder,
  parcelOrder,
  intercityRideOrder,
  intercityParcelOrder,
  rideSharing,
  // Government Tax Due repayment -- a rider's overall tax-due balance, not tied to a single
  // order/plan. Deliberately separate from `subscription` and every fare type: paying this never
  // activates a subscription and never settles a specific order. See
  // migration 20260726000003_government_tax_due_schema.sql.
  taxDue,
  // "Cash to be Paid" (COD Settlement) -- the platform's commission share owed by a rider who
  // settled a ride/parcel by collecting cash/personal-UPI directly (riders.cod_pending_amount).
  // Same shape as taxDue: an overall balance, not tied to a single order. See
  // migration 20260808000011_cod_settlement_payment_flow.sql.
  codSettlement;

  /// The snake_case string stored in the database `payment_for` column.
  String get value {
    switch (this) {
      case PaymentFor.subscription:
        return 'subscription';
      case PaymentFor.rideOrder:
        return 'ride_order';
      case PaymentFor.parcelOrder:
        return 'parcel_order';
      case PaymentFor.intercityRideOrder:
        return 'intercity_ride_order';
      case PaymentFor.intercityParcelOrder:
        return 'intercity_parcel_order';
      case PaymentFor.rideSharing:
        return 'ride_sharing';
      case PaymentFor.taxDue:
        return 'tax_due';
      case PaymentFor.codSettlement:
        return 'cod_settlement';
    }
  }

  /// Resolve the payment_for value for a passenger fare payment from the
  /// order's own `order_type` string, mirroring the DB's payment_for_enum.
  static PaymentFor forOrderType(String orderType) {
    switch (orderType) {
      case 'ride':
        return PaymentFor.rideOrder;
      case 'local_parcel':
        return PaymentFor.parcelOrder;
      case 'intercity_ride':
        return PaymentFor.intercityRideOrder;
      case 'intercity_parcel':
        return PaymentFor.intercityParcelOrder;
      case 'ride_sharing':
        return PaymentFor.rideSharing;
      default:
        throw ArgumentError('No fare payment_for mapping for order_type: $orderType');
    }
  }

  /// Parse a database string back into the enum.
  static PaymentFor fromString(String raw) {
    switch (raw) {
      case 'subscription':
        return PaymentFor.subscription;
      case 'ride_order':
        return PaymentFor.rideOrder;
      case 'parcel_order':
        return PaymentFor.parcelOrder;
      case 'intercity_ride_order':
        return PaymentFor.intercityRideOrder;
      case 'intercity_parcel_order':
        return PaymentFor.intercityParcelOrder;
      case 'ride_sharing':
        return PaymentFor.rideSharing;
      case 'tax_due':
        return PaymentFor.taxDue;
      case 'cod_settlement':
        return PaymentFor.codSettlement;
      default:
        throw ArgumentError('Unknown PaymentFor value: $raw');
    }
  }

  @override
  String toString() => value;
}
