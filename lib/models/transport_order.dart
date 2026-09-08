/// Typed enum representing the operational flow type of the order.
enum OrderFlowType {
  ride,
  localParcel,
  intercityParcel,
  intercity,
}

/// Domain model representing a Transport Order in the Waydrop system.
class TransportOrder {
  final String id;
  final String orderCode;
  final String userId;
  final String? riderId;
  final String orderType; // 'ride', 'local_parcel', 'intercity_parcel', 'intercity'
  final String? vehicleType;
  final String orderStatus; // 'created', 'accepted', 'rider_arrived', 'picked_up', 'ongoing', 'rider_at_drop', 'completed', 'cancelled'
  final int distanceMeters;
  final double distanceKm;
  final int? estimatedDurationMin;
  final int? actualDurationMin;
  final int? timeTakenSeconds;
  
  final String pickupAddress;
  final double pickupLat;
  final double pickupLng;
  
  final String destinationAddress;
  final double destinationLat;
  final double destinationLng;
  
  final double actualFare;
  final double currentFare;
  final double? finalFare;
  
  final double baseFare;
  final double distanceFare;
  final double timeFare;
  final double waitingCharge;
  final double platformFee;
  
  final String paymentMode;
  final String paymentStatus;
  final String? paymentId;
  // The passenger's own fresh choice at payment_pending -- 'personal_upi' | 'cash' | 'cashfree' --
  // recorded via mark_fare_payment_attempted. Decides FarePaymentPanel's waiting state and, on the
  // server, whether the driver's swipe alone confirms payment (personal_upi/cash) or a real
  // Cashfree webhook is required first. Independent of paymentMode (set once at booking).
  final String? farePaymentMethod;
  final DateTime? farePaymentAttemptedAt;

  final String? pickupOtp;
  final String? deliveryOtp;
  
  // Parcel Metadata fields
  final String? parcelType;
  final String? receiverName;
  final String? receiverPhone;
  final String? weightCategory;
  final double? actualWeightKg;
  final List<String> parcelImages;
  final String? specialInstructions;
  
  final DateTime? createdAt;
  final DateTime? acceptedAt;
  final DateTime? riderArrivedAt;
  final DateTime? pickedUpAt;
  final DateTime? riderAtDropAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  
  final double boostAmount;
  final double boostPercentage;
  final String? pickupCity;
  final String? destinationCity;
  final DateTime? travelDate;
  final int seatsRequested;
  final DateTime? tripStartedAt;

  final double gstPercentage;
  final double gstAmount;
  final double commissionPercentage;
  final double commissionAmount;
  final double riderEarning;
  final double boostCompanyEarning;
  final double boostRiderEarning;
  final double surgeFee;
  final double rainFee;


  TransportOrder({
    required this.id,
    required this.orderCode,
    required this.userId,
    this.riderId,
    required this.orderType,
    this.vehicleType,
    required this.orderStatus,
    required this.distanceMeters,
    required this.distanceKm,
    this.estimatedDurationMin,
    this.actualDurationMin,
    this.timeTakenSeconds,
    required this.pickupAddress,
    required this.pickupLat,
    required this.pickupLng,
    required this.destinationAddress,
    required this.destinationLat,
    required this.destinationLng,
    required this.actualFare,
    required this.currentFare,
    this.finalFare,
    this.baseFare = 0,
    this.distanceFare = 0,
    this.timeFare = 0,
    this.waitingCharge = 0,
    this.platformFee = 0,
    required this.paymentMode,
    required this.paymentStatus,
    this.paymentId,
    this.farePaymentMethod,
    this.farePaymentAttemptedAt,
    this.pickupOtp,
    this.deliveryOtp,
    this.parcelType,
    this.receiverName,
    this.receiverPhone,
    this.weightCategory,
    this.actualWeightKg,
    this.parcelImages = const [],
    this.specialInstructions,
    this.createdAt,
    this.acceptedAt,
    this.riderArrivedAt,
    this.pickedUpAt,
    this.riderAtDropAt,
    this.completedAt,
    this.cancelledAt,
    this.boostAmount = 0,
    this.boostPercentage = 0,
    this.pickupCity,
    this.destinationCity,
    this.travelDate,
    this.seatsRequested = 1,
    this.tripStartedAt,
    this.gstPercentage = 0,
    this.gstAmount = 0,
    this.commissionPercentage = 0,
    this.commissionAmount = 0,
    this.riderEarning = 0,
    this.boostCompanyEarning = 0,
    this.boostRiderEarning = 0,
    this.surgeFee = 0,
    this.rainFee = 0,
  });

  OrderFlowType get flowType {
    if (orderType == 'ride' || orderType == 'ride_sharing') {
      return distanceMeters > 20000 ? OrderFlowType.intercity : OrderFlowType.ride;
    }
    if (orderType == 'intercity_ride') {
      return OrderFlowType.intercity;
    }
    switch (orderType) {
      case 'local_parcel':
        return OrderFlowType.localParcel;
      case 'intercity_parcel':
        return OrderFlowType.intercityParcel;
      default:
        return OrderFlowType.ride;
    }
  }

  // ===========================================================================
  // COMPUTED FIELD HELPERS (User request 3)
  // ===========================================================================
  bool get isRide => orderType == 'ride' || orderType == 'intercity_ride' || orderType == 'ride_sharing';
  bool get isParcel => orderType == 'local_parcel' || orderType == 'intercity_parcel';
  bool get isIntercity => flowType == OrderFlowType.intercity || flowType == OrderFlowType.intercityParcel;

  /// OTP validation checks
  bool get supportsOtp => isRide || flowType == OrderFlowType.intercity;
  bool get supportsDeliveryOtp => isParcel;

  /// DB status helpers
  // create-order always inserts orders directly with order_status = 'searching';
  // 'created' is kept here only for defensiveness against any legacy row.
  bool get isSearching => orderStatus == 'created' || orderStatus == 'searching';
  bool get isAccepted => orderStatus == 'accepted';
  bool get isRiderArrived => orderStatus == 'rider_arrived';
  bool get isOngoing => orderStatus == 'ongoing' || orderStatus == 'picked_up';
  bool get isRiderAtDrop => orderStatus == 'rider_at_drop';
  /// UPI-only waypoint between the driver's "trip finished" swipe and the driver actually being
  /// allowed to confirm receipt -- the passenger must be shown the UPI intent first.
  bool get isAwaitingUpiPayment => orderStatus == 'payment_pending';
  bool get isCompleted => orderStatus == 'completed' || orderStatus == 'delivered';
  bool get isCancelled => orderStatus == 'cancelled';
  /// Set by the server when no rider accepted within the configured search window
  /// (public.expire_stale_searching_orders(), never passenger-initiated) -- a distinct terminal
  /// state from isCancelled so the UI can show "no drivers were available" instead of "cancelled".
  bool get isExpired => orderStatus == 'expired';

  /// CANONICAL passenger-payable fare. `current_fare` is the pre-promo total (base + boost + GST);
  /// `final_fare` is only ever set once a promo discount has been applied (current_fare - discount)
  /// and is otherwise null. Every screen that shows "the fare" for an order past booking (tracking,
  /// completion, receipts, chat, UPI payment amount) must read this getter -- never currentFare or
  /// finalFare directly -- so a promo-discounted trip shows the same number everywhere instead of
  /// the pre-discount amount on some screens and the discounted one on others.
  double get payableFare => finalFare ?? currentFare;

  /// Feature 6/7/8: an accepted intercity booking sits here until the traveller explicitly
  /// presses "Start Trip" on the travel date — order_status stays 'accepted' throughout, so this
  /// is derived from tripStartedAt rather than a new order_status value.
  bool get isWaitingForTravelDay => isIntercity && isAccepted && tripStartedAt == null;

  /// Task 2: the four booking-status stages shown to both traveller and passenger —
  /// Waiting for Travel Day → Trip Started → In Transit → Completed. "Trip Started" covers the
  /// window between the Start Trip press (trip_started_at set) and order_status actually reaching
  /// ongoing/picked_up (the traveller may still need to swipe-arrive/verify OTP with the
  /// passenger in between, exactly as the existing ride flow already does).
  String get intercityLifecycleLabel {
    if (!isIntercity) return OrderStatusResolver.getStatusTitle(flowType, orderStatus);
    if (isCancelled) return 'Cancelled';
    if (isExpired) return 'Expired';
    if (isCompleted) return 'Completed';
    if (isWaitingForTravelDay) return 'Waiting for Travel Day';
    if (isOngoing || isRiderAtDrop) return 'In Transit';
    if (tripStartedAt != null) return 'Trip Started';
    return OrderStatusResolver.getStatusTitle(flowType, orderStatus);
  }

  /// Factory constructor to map the raw Supabase JSON object to a typed domain class
  factory TransportOrder.fromJson(Map<String, dynamic> json) {
    List<String> parsedImages = [];
    if (json['parcel_images'] != null) {
      if (json['parcel_images'] is List) {
        parsedImages = (json['parcel_images'] as List).map((e) => e.toString()).toList();
      }
    }

    return TransportOrder(
      id: json['id'] ?? '',
      orderCode: json['order_code'] ?? '',
      userId: json['user_id'] ?? '',
      riderId: json['rider_id'],
      orderType: json['order_type'] ?? 'ride',
      vehicleType: json['vehicle_type'],
      orderStatus: json['order_status'] ?? 'created',
      distanceMeters: json['distance_meters'] is int 
          ? json['distance_meters'] 
          : (double.tryParse(json['distance_meters'].toString())?.round() ?? 0),
      distanceKm: double.tryParse(json['distance_km']?.toString() ?? '0') ?? 0,
      estimatedDurationMin: json['estimated_duration_min'] != null
          ? (double.tryParse(json['estimated_duration_min'].toString())?.round())
          : null,
      actualDurationMin: json['actual_duration_min'] != null
          ? (double.tryParse(json['actual_duration_min'].toString())?.round())
          : null,
      timeTakenSeconds: json['time_taken_seconds'] != null
          ? (double.tryParse(json['time_taken_seconds'].toString())?.round())
          : null,
      pickupAddress: json['pickup_address'] ?? '',
      pickupLat: double.tryParse(json['pickup_lat']?.toString() ?? '0') ?? 0,
      pickupLng: double.tryParse(json['pickup_lng']?.toString() ?? '0') ?? 0,
      destinationAddress: json['destination_address'] ?? '',
      destinationLat: double.tryParse(json['destination_lat']?.toString() ?? '0') ?? 0,
      destinationLng: double.tryParse(json['destination_lng']?.toString() ?? '0') ?? 0,
      actualFare: double.tryParse(json['actual_fare']?.toString() ?? '0') ?? 0,
      currentFare: double.tryParse(json['current_fare']?.toString() ?? '0') ?? 0,
      finalFare: json['final_fare'] != null ? (double.tryParse(json['final_fare'].toString()) ?? 0) : null,
      baseFare: double.tryParse(json['base_fare']?.toString() ?? '0') ?? 0,
      distanceFare: double.tryParse(json['distance_fare']?.toString() ?? '0') ?? 0,
      timeFare: double.tryParse(json['time_fare']?.toString() ?? '0') ?? 0,
      waitingCharge: double.tryParse(json['waiting_charge']?.toString() ?? '0') ?? 0,
      platformFee: double.tryParse(json['platform_fee']?.toString() ?? '0') ?? 0,
      paymentMode: json['payment_mode'] ?? 'cash',
      paymentStatus: json['payment_status'] ?? 'pending',
      paymentId: json['payment_id'],
      farePaymentMethod: json['fare_payment_method']?.toString(),
      farePaymentAttemptedAt: json['fare_payment_attempted_at'] != null
          ? DateTime.tryParse(json['fare_payment_attempted_at'].toString())
          : null,
      pickupOtp: json['pickup_otp']?.toString(),
      deliveryOtp: json['delivery_otp']?.toString(),
      parcelType: json['parcel_type']?.toString(),
      receiverName: json['receiver_name']?.toString(),
      receiverPhone: json['receiver_phone']?.toString(),
      weightCategory: json['weight_category']?.toString(),
      actualWeightKg: json['actual_weight_kg'] != null ? double.tryParse(json['actual_weight_kg'].toString()) : null,
      parcelImages: parsedImages,
      specialInstructions: json['special_instructions'] ?? json['instructions'],
      createdAt: json['created_at'] != null ? DateTime.tryParse(json['created_at'].toString()) : null,
      acceptedAt: json['accepted_at'] != null ? DateTime.tryParse(json['accepted_at'].toString()) : null,
      riderArrivedAt: json['rider_arrived_at'] != null ? DateTime.tryParse(json['rider_arrived_at'].toString()) : null,
      pickedUpAt: json['picked_up_at'] != null ? DateTime.tryParse(json['picked_up_at'].toString()) : null,
      riderAtDropAt: json['rider_at_drop_at'] != null ? DateTime.tryParse(json['rider_at_drop_at'].toString()) : null,
      completedAt: json['completed_at'] != null ? DateTime.tryParse(json['completed_at'].toString()) : null,
      cancelledAt: json['cancelled_at'] != null ? DateTime.tryParse(json['cancelled_at'].toString()) : null,
      boostAmount: double.tryParse(json['boost_amount']?.toString() ?? '0') ?? 0,
      boostPercentage: double.tryParse(json['boost_percentage']?.toString() ?? '0') ?? 0,
      pickupCity: json['pickup_city']?.toString(),
      destinationCity: json['destination_city']?.toString(),
      travelDate: json['travel_date'] != null ? DateTime.tryParse(json['travel_date'].toString()) : null,
      tripStartedAt: json['trip_started_at'] != null ? DateTime.tryParse(json['trip_started_at'].toString()) : null,
      seatsRequested: json['seats_requested'] != null
          ? (int.tryParse(json['seats_requested'].toString()) ?? 1)
          : (json['capacity'] != null
              ? (int.tryParse(json['capacity'].toString()) ?? 1)
              : 1),
      gstPercentage: double.tryParse(json['gst_percentage']?.toString() ?? '0') ?? 0,
      gstAmount: double.tryParse(json['gst_amount']?.toString() ?? '0') ?? 0,
      commissionPercentage: double.tryParse(json['commission_percentage']?.toString() ?? '0') ?? 0,
      commissionAmount: double.tryParse(json['commission_amount']?.toString() ?? '0') ?? 0,
      riderEarning: double.tryParse(json['rider_earning']?.toString() ?? '0') ?? 0,
      boostCompanyEarning: double.tryParse(json['boost_company_earning']?.toString() ?? '0') ?? 0,
      boostRiderEarning: double.tryParse(json['boost_rider_earning']?.toString() ?? '0') ?? 0,
      surgeFee: double.tryParse(json['surge_fee']?.toString() ?? '0') ?? 0,
      rainFee: double.tryParse(json['rain_fee']?.toString() ?? '0') ?? 0,
    );
  }
}

/// Resolves user-facing status details and live CTA actions dynamically 
/// depending on the flow type (User requests 2 & 6).
class OrderStatusResolver {
  static String getStatusTitle(OrderFlowType flow, String dbStatus) {
    if (dbStatus == 'cancelled') return 'Order Cancelled';
    if (dbStatus == 'expired') return 'No Drop Partners Available';
    if (dbStatus == 'created' || dbStatus == 'searching') {
      switch (flow) {
        case OrderFlowType.ride:
          return 'Searching for rides';
        case OrderFlowType.localParcel:
        case OrderFlowType.intercityParcel:
          return 'Searching for couriers';
        case OrderFlowType.intercity:
          return 'Searching for Drop Partners';
      }
    }
    if (dbStatus == 'accepted') {
      switch (flow) {
        case OrderFlowType.ride:
          return 'Drop Partner is coming';
        case OrderFlowType.localParcel:
        case OrderFlowType.intercityParcel:
          return 'Courier assigned';
        case OrderFlowType.intercity:
          return 'Drop Partner is coming';
      }
    }
    if (dbStatus == 'rider_arrived') {
      switch (flow) {
        case OrderFlowType.ride:
          return 'Drop Partner has arrived';
        case OrderFlowType.localParcel:
        case OrderFlowType.intercityParcel:
          return 'Courier at pickup point';
        case OrderFlowType.intercity:
          return 'Drop Partner has arrived';
      }
    }
    if (dbStatus == 'picked_up') {
      switch (flow) {
        case OrderFlowType.ride:
          return 'Trip started';
        case OrderFlowType.localParcel:
        case OrderFlowType.intercityParcel:
          return 'Parcel picked up';
        case OrderFlowType.intercity:
          return 'Journey started';
      }
    }
    if (dbStatus == 'ongoing') {
      switch (flow) {
        case OrderFlowType.ride:
          return 'On the way';
        case OrderFlowType.localParcel:
        case OrderFlowType.intercityParcel:
          return 'Parcel in transit';
        case OrderFlowType.intercity:
          return 'In transit';
      }
    }
    if (dbStatus == 'rider_at_drop') {
      switch (flow) {
        case OrderFlowType.ride:
          return 'Reached destination';
        case OrderFlowType.localParcel:
        case OrderFlowType.intercityParcel:
          return 'Reached receiver';
        case OrderFlowType.intercity:
          return 'Reached drop point';
      }
    }
    if (dbStatus == 'payment_pending') {
      return 'Awaiting payment';
    }
    if (dbStatus == 'completed' || dbStatus == 'delivered') {
      switch (flow) {
        case OrderFlowType.ride:
          return 'Ride completed';
        case OrderFlowType.localParcel:
        case OrderFlowType.intercityParcel:
          return 'Delivery completed';
        case OrderFlowType.intercity:
          return 'Trip completed';
      }
    }
    return dbStatus.replaceAll('_', ' ').toUpperCase();
  }

  static String getStatusSubtitle(OrderFlowType flow, String dbStatus, {String? otp}) {
    if (dbStatus == 'cancelled') return 'This order was cancelled';
    if (dbStatus == 'expired') return 'No Drop Partner accepted this request in time';
    if (dbStatus == 'created' || dbStatus == 'searching') return 'Finding a partner near you';
    if (dbStatus == 'accepted') {
      switch (flow) {
        case OrderFlowType.ride:
          return 'Drop Partner is moving to pickup';
        case OrderFlowType.localParcel:
        case OrderFlowType.intercityParcel:
          return 'Courier is coming to collect parcel';
        case OrderFlowType.intercity:
          return 'Drop Partner is heading to your location';
      }
    }
    if (dbStatus == 'rider_arrived') {
      switch (flow) {
        case OrderFlowType.ride:
          return otp != null ? 'Share OTP $otp to start' : 'Drop Partner is waiting';
        case OrderFlowType.localParcel:
        case OrderFlowType.intercityParcel:
          return otp != null ? 'Share OTP $otp to hand over parcel' : 'Courier is waiting for parcel';
        case OrderFlowType.intercity:
          return otp != null ? 'Share OTP $otp to begin' : 'Drop Partner is at pickup';
      }
    }
    if (dbStatus == 'picked_up' || dbStatus == 'ongoing') {
      switch (flow) {
        case OrderFlowType.ride:
          return 'Heading to your destination';
        case OrderFlowType.localParcel:
        case OrderFlowType.intercityParcel:
          return 'Parcel is on the way to receiver';
        case OrderFlowType.intercity:
          return 'En route to intercity dropoff';
      }
    }
    if (dbStatus == 'rider_at_drop') {
      switch (flow) {
        case OrderFlowType.ride:
          return 'Hope you had a nice journey';
        case OrderFlowType.localParcel:
        case OrderFlowType.intercityParcel:
          return otp != null ? 'Receiver should share OTP $otp to verify delivery' : 'Courier has reached receiver';
        case OrderFlowType.intercity:
          return 'Arrived at destination';
      }
    }
    if (dbStatus == 'payment_pending') {
      return 'Pay your Drop Partner to complete the trip';
    }
    if (dbStatus == 'completed' || dbStatus == 'delivered') {
      return 'Thank you for choosing Waydrop';
    }
    return '';
  }
}
