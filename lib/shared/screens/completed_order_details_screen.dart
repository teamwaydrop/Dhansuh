import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/models/transport_order.dart';
import 'package:waydrop/features/local_rides/rating/screens/rider_rating_screen.dart';
import 'package:waydrop/features/local_rides/booking/screens/ride_location_screen.dart';
import 'package:waydrop/features/local_parcels/booking/screens/parcel_details_screen.dart';
import 'package:waydrop/features/intercity/parcels/booking/intercity_details_screen.dart';
import 'package:waydrop/shared/helpers/fare_presentation_helper.dart';

class CompletedOrderDetailsScreen extends StatefulWidget {
  final Map<String, dynamic> order;
  final VoidCallback? onReviewSubmitted;

  const CompletedOrderDetailsScreen({
    super.key,
    required this.order,
    this.onReviewSubmitted,
  });

  @override
  State<CompletedOrderDetailsScreen> createState() => _CompletedOrderDetailsScreenState();
}

class _CompletedOrderDetailsScreenState extends State<CompletedOrderDetailsScreen> {
  final _supabase = Supabase.instance.client;
  Map<String, dynamic>? _fetchedRider;
  List<dynamic>? _fetchedReviews;

  Map<String, dynamic> get order => widget.order;
  VoidCallback? get onReviewSubmitted => widget.onReviewSubmitted;

  @override
  void initState() {
    super.initState();
    _loadRiderAndReviewsIfMissing();
  }

  // Egress fix: the passenger history list query (activity_tab.dart's _pastOrderColumns) no
  // longer embeds rider/rider_kyc/users/rider_reviews for every row in every page -- most rows
  // are never opened via "View Details". This is the one screen that still needs that data, so
  // it fetches it itself, on demand, only for the single order actually being viewed. Orders that
  // still arrive with the embed already present (e.g. an ACTIVE order passed in with its original
  // embedding columns) skip the fetch entirely.
  Future<void> _loadRiderAndReviewsIfMissing() async {
    final needsRider = order['rider'] == null && order['rider_id'] != null;
    final needsReviews = order['rider_reviews'] == null && order['id'] != null;
    if (!needsRider && !needsReviews) return;

    try {
      final Future<dynamic> riderFuture = needsRider
          ? _supabase
              .from('riders')
              .select(
                  'id,rating,rider_kyc!riders_kyc_id_fkey(full_name,vehicle_number,vehicle_type,rider_image),users!riders_user_id_fkey(full_name,phone,user_code)')
              .eq('id', order['rider_id'])
              .maybeSingle()
          : Future.value(null);

      final Future<dynamic> reviewsFuture = needsReviews
          ? _supabase.from('rider_reviews').select('id,rating,comment').eq('order_id', order['id'])
          : Future.value(null);

      final results = await Future.wait<dynamic>([riderFuture, reviewsFuture]);
      if (!mounted) return;
      setState(() {
        if (needsRider && results[0] != null) {
          _fetchedRider = Map<String, dynamic>.from(results[0] as Map);
        }
        if (needsReviews && results[1] != null) {
          _fetchedReviews = List<dynamic>.from(results[1] as List);
        }
      });
    } catch (_) {
      // Best-effort enrichment -- if it fails, the screen still renders correctly with the
      // rider/feedback sections simply omitted, same as a genuinely rider-less order today.
    }
  }

  void _reorderTrip(BuildContext context) {
    final type = order['order_type']?.toString() ?? 'ride';
    final distanceMeters = double.tryParse(order['distance_meters']?.toString() ?? '0') ?? 0;
    final isIntercityRide = type == 'intercity_ride' || (type == 'ride' && distanceMeters > 20000);
    final isParcel = type.contains('parcel') || type.contains('delivery');

    if (isParcel) {
      if (type == 'local_parcel') {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ParcelDetailsScreen(
              orderType: 'local_parcel',
              pickupAddress: order['pickup_address']?.toString(),
              destinationAddress: order['destination_address']?.toString(),
              pickupLat: double.tryParse(order['pickup_lat']?.toString() ?? ''),
              pickupLng: double.tryParse(order['pickup_lng']?.toString() ?? ''),
              destinationLat: double.tryParse(order['destination_lat']?.toString() ?? ''),
              destinationLng: double.tryParse(order['destination_lng']?.toString() ?? ''),
              totalDistanceMeters: double.tryParse(order['distance_meters']?.toString() ?? ''),
              durationSeconds: double.tryParse(order['time_taken_seconds']?.toString() ?? ''),
              receiverName: order['receiver_name']?.toString(),
              receiverPhone: order['receiver_phone']?.toString(),
              parcelType: order['parcel_type']?.toString(),
              weightCategory: order['weight_category']?.toString(),
              specialInstructions: order['special_instructions']?.toString(),
            ),
          ),
        );
      } else {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => IntercityDetailsScreen(
              orderType: 'intercity_parcel',
              pickupAddress: order['pickup_address']?.toString(),
              destinationAddress: order['destination_address']?.toString(),
              pickupLat: double.tryParse(order['pickup_lat']?.toString() ?? ''),
              pickupLng: double.tryParse(order['pickup_lng']?.toString() ?? ''),
              destinationLat: double.tryParse(order['destination_lat']?.toString() ?? ''),
              destinationLng: double.tryParse(order['destination_lng']?.toString() ?? ''),
              totalDistanceMeters: double.tryParse(order['distance_meters']?.toString() ?? ''),
              durationSeconds: double.tryParse(order['time_taken_seconds']?.toString() ?? ''),
              receiverName: order['receiver_name']?.toString(),
              receiverPhone: order['receiver_phone']?.toString(),
              parcelType: order['parcel_type']?.toString(),
              weightCategory: order['weight_category']?.toString(),
              specialInstructions: order['special_instructions']?.toString(),
            ),
          ),
        );
      }
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RideLocationScreen(
            orderType: isIntercityRide ? 'intercity' : 'ride',
            prefillPickupAddress: order['pickup_address']?.toString(),
            prefillDestinationAddress: order['destination_address']?.toString(),
            prefillPickupLat: double.tryParse(order['pickup_lat']?.toString() ?? ''),
            prefillPickupLng: double.tryParse(order['pickup_lng']?.toString() ?? ''),
            prefillDestinationLat: double.tryParse(order['destination_lat']?.toString() ?? ''),
            prefillDestinationLng: double.tryParse(order['destination_lng']?.toString() ?? ''),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtitleColor = isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600;
    final cardBgColor = isDark ? const Color(0xFF171A21) : Colors.white;
    final borderColor = isDark ? Colors.white.withOpacity(0.06) : const Color(0xFFE2E8F0);

    final type = order['order_type']?.toString() ?? 'ride';
    final isParcel = type.contains('parcel') || type.contains('delivery');

    // Metrics conversion
    final distanceMeters = double.tryParse(order['distance_meters']?.toString() ?? '0') ?? 0;
    final distanceKm = distanceMeters / 1000.0;
    final distanceStr = '${distanceKm.toStringAsFixed(1)}Km';

    final durationSec = double.tryParse(order['time_taken_seconds']?.toString() ?? order['duration_seconds']?.toString() ?? '0') ?? 0;
    final durationMin = (durationSec / 60.0).round();
    final durationStr = '$durationMin Minutes';

    final fare = double.tryParse(order['final_fare']?.toString() ?? order['current_fare']?.toString() ?? '0') ?? 0;
    final fareStr = '₹${fare.toStringAsFixed(0)}';

    // boost_amount is the actual surcharge the passenger added while searching (stored directly
    // on the order) -- comparing final_fare/current_fare against each other here can never detect
    // it, since final_fare is only ever current_fare minus a promo discount (never higher).
    final surgeAmt = double.tryParse(order['boost_amount']?.toString() ?? '0') ?? 0.0;
    final hasSurge = surgeAmt > 0;
    final initialFare = (fare - surgeAmt).clamp(0.0, double.infinity);

    // orders has no `payment_method` column (that exists only on the separate `payments` table,
    // one row per gateway transaction) -- reading it here was always null, so this badge silently
    // showed "Cash" for every order regardless of how it was actually settled. fare_payment_method
    // is the passenger's real settlement-time choice ('personal_upi' | 'cash' | 'cashfree'),
    // recorded via mark_fare_payment_attempted; payment_mode is the booking-time intent, kept only
    // as a fallback for orders that never reached that flow. Canonical labels/mapping shared with
    // every other completed-order screen (Local + Intercity, Drop Partner + passenger) --
    // see PaymentMethodPresentation.
    final fareMethod = order['fare_payment_method']?.toString();
    final paymentMode = order['payment_mode']?.toString().toLowerCase();
    final paymentMethodLabel = PaymentMethodPresentation.labelFor(fareMethod: fareMethod, paymentMode: paymentMode);

    // FARE DETAILS -- authoritative server-computed breakdown (never recomputed from percentages
    // client-side). "Total Paid" is only ever shown once payment is actually confirmed
    // (payment_status == 'paid', which update-order-status guarantees before an order can reach
    // 'completed'/'delivered' for every settlement method -- see its isDirectSettlement/isCompleting
    // guard); otherwise this reads "Total Fare" so an unsettled legacy/edge-case order is never
    // mislabeled as paid.
    final breakdown = FareBreakdown.fromOrder(order);
    final paymentStatus = order['payment_status']?.toString().toLowerCase();
    final isPaymentConfirmed = paymentStatus == 'paid';
    final totalLabel = isPaymentConfirmed ? 'Total Paid' : 'Total Fare';

    // Driver details -- falls back to the lazily-fetched copy when the passed-in order didn't
    // come with the embed (see _loadRiderAndReviewsIfMissing above).
    final riderRaw = order['rider'] ?? _fetchedRider;
    final rider = riderRaw is Map
        ? riderRaw
        : (riderRaw is List && riderRaw.isNotEmpty ? riderRaw.first as Map? : null);
        
    final kycRaw = rider?['rider_kyc'];
    final riderKyc = kycRaw is Map
        ? kycRaw
        : (kycRaw is List && kycRaw.isNotEmpty ? kycRaw.first as Map? : null);

    final driverName = riderKyc?['full_name']?.toString() ?? rider?['users']?['full_name']?.toString() ?? 'Drop Partner';
    final driverImage = riderKyc?['rider_image']?.toString() ?? '';
    final vehicleName = riderKyc?['vehicle_type']?.toString() ?? 'Vehicle';
    final vehicleNumber = riderKyc?['vehicle_number']?.toString() ?? '';

    final driverRatingRaw = rider?['rating'];
    final double? driverRating = driverRatingRaw is num 
        ? driverRatingRaw.toDouble() 
        : (driverRatingRaw != null ? double.tryParse(driverRatingRaw.toString()) : null);

    // Reviews details -- same lazy-fetch fallback as riderRaw above.
    final reviewsRaw = order['rider_reviews'] ?? _fetchedReviews;
    final List? reviewsList = reviewsRaw is List ? reviewsRaw : null;
    final hasReview = reviewsList != null && reviewsList.isNotEmpty;
    final reviewMap = hasReview ? reviewsList.first as Map? : null;
    final userRating = reviewMap?['rating'] is num ? (reviewMap?['rating'] as num).round() : null;
    final feedbackText = reviewMap?['comment']?.toString() ?? '';

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF1E222B) : const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: textColor, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Completed Order',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: textColor,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 1. TOP ROUTE CARD
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: cardBgColor,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: borderColor, width: 1.5),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(isDark ? 0.25 : 0.02),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          )
                        ],
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Custom Dotted Line Indicator
                          Column(
                            children: [
                              const SizedBox(height: 6),
                              Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE0F2FE),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: const Color(0xFF38BDF8), width: 1.5),
                                ),
                                child: const Center(
                                  child: Icon(
                                    Icons.arrow_downward_rounded,
                                    size: 12,
                                    color: Color(0xFF0284C7),
                                  ),
                                ),
                              ),
                              // Vertical dots representation
                              SizedBox(
                                width: 1.5,
                                height: 32,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                  children: List.generate(4, (index) => Container(
                                    width: 1.5,
                                    height: 3.5,
                                    color: const Color(0xFFCBD5E1),
                                  )),
                                ),
                              ),
                              Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF1F5F9),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: const Color(0xFF0F172A), width: 1.5),
                                ),
                                child: const Center(
                                  child: Icon(
                                    Icons.location_on_rounded,
                                    size: 12,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Pickup point
                                Text(
                                  'Pickup point',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: subtitleColor,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  order['pickup_address'] ?? 'Pickup point',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: textColor,
                                  ),
                                ),
                                const SizedBox(height: 20),
                                // Destination
                                Text(
                                  'Destination',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: subtitleColor,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  order['destination_address'] ?? 'Destination',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: textColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Distance / Payment columns
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                'Distance',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: subtitleColor),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                distanceStr,
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: textColor),
                              ),
                              const SizedBox(height: 20),
                              Text(
                                'Payment',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: subtitleColor),
                              ),
                              const SizedBox(height: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFDCFCE7),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  fareStr,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFF15803D),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    // 2. DETAILS HEADER ROW
                    Row(
                      children: [
                        Expanded(child: Divider(color: borderColor)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          child: Text(
                            'DETAILS',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              color: subtitleColor,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ),
                        Expanded(child: Divider(color: borderColor)),
                      ],
                    ),

                    const SizedBox(height: 24),

                    // 3. DRIVER INFO BOX (Only if rider details exist)
                    if (rider != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: cardBgColor,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: borderColor, width: 1.5),
                        ),
                        child: Row(
                          children: [
                            Container(
                              height: 44,
                              width: 44,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: const Color(0xFF10B981), width: 1.5),
                              ),
                              child: ClipOval(
                                child: (driverImage.isNotEmpty && driverImage.startsWith('http'))
                                    ? CachedNetworkImage(
                                        imageUrl: driverImage,
                                        fit: BoxFit.cover,
                                        errorWidget: (ctx, url, err) => Center(
                                          child: Text(driverName.isNotEmpty ? driverName[0] : 'D', style: TextStyle(color: textColor, fontWeight: FontWeight.bold)),
                                        ),
                                      )
                                    : Center(
                                        child: Text(driverName.isNotEmpty ? driverName[0] : 'D', style: TextStyle(color: textColor, fontWeight: FontWeight.bold)),
                                      ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Flexible(
                                        child: Text(
                                          driverName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: textColor),
                                        ),
                                      ),
                                      if (driverRating != null) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFFEF3C7),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(Icons.star_rounded, size: 12, color: Color(0xFFD97706)),
                                              const SizedBox(width: 2),
                                              Text(
                                                driverRating.toStringAsFixed(1),
                                                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFFD97706)),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Drop Partner',
                                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: subtitleColor),
                                  ),
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  vehicleName,
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: textColor),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  vehicleNumber,
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: subtitleColor),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],

                    // 4. METRICS & FARE GRID (3 columns, 2 rows layout)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              // Column 1: Rating
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Rating',
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: subtitleColor),
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      children: List.generate(5, (index) {
                                        final starVal = index + 1;
                                        final isLit = userRating != null && starVal <= userRating;
                                        return Icon(
                                          Icons.star_rounded,
                                          size: 15,
                                          color: isLit ? const Color(0xFFF59E0B) : Colors.grey.shade300,
                                        );
                                      }),
                                    ),
                                  ],
                                ),
                              ),
                              // Column 2: Payment Method
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Payment Method',
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: subtitleColor),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      paymentMethodLabel,
                                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: textColor),
                                    ),
                                  ],
                                ),
                              ),
                              // Column 3: Travel Duration
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Travel Duration',
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: subtitleColor),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      durationStr,
                                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: textColor),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              // Column 1: Ride Fare
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      isParcel ? 'Delivery Fare' : 'Ride Fare',
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: subtitleColor),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      '₹${(hasSurge ? initialFare : fare).toStringAsFixed(2)}',
                                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: textColor),
                                    ),
                                  ],
                                ),
                              ),
                              // Column 2: Peak Surge / Discount
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      hasSurge ? 'Peak Surge' : 'Discount',
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: subtitleColor),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      hasSurge ? '₹${surgeAmt.toStringAsFixed(2)}' : '--',
                                      style: TextStyle(
                                        fontSize: 14, 
                                        fontWeight: FontWeight.w900, 
                                        color: hasSurge ? const Color(0xFFE11D48) : textColor
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              // Column 3: Total fare
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Total fare',
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: subtitleColor),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      '₹${fare.toStringAsFixed(2)}',
                                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: textColor),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (hasSurge) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF1E1B4B) : const Color(0xFFEEF2FF),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: isDark ? const Color(0xFF312E81) : const Color(0xFFC7D2FE)),
                        ),
                        child: Row(
                          children: [
                            const Text('⚠️', style: TextStyle(fontSize: 16)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Fare was adjusted by +₹${surgeAmt.toStringAsFixed(0)} due to dynamic pricing surge or route changes.',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: isDark ? const Color(0xFFC7D2FE) : const Color(0xFF4338CA),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 24),

                    // 4b. FARE DETAILS -- authoritative Fare-before-GST / GST / Total breakdown so
                    // "Customer Paid"/"Total" concepts are never left ambiguous on the passenger's
                    // own completed-trip screen (Local + Intercity).
                    Text(
                      'FARE DETAILS',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: subtitleColor,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: cardBgColor,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: borderColor, width: 1.5),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('Fare before GST', style: TextStyle(fontSize: 13, color: subtitleColor, fontWeight: FontWeight.w500)),
                              Text('₹${breakdown.fareBeforeGst.toStringAsFixed(2)}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: textColor)),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                breakdown.gstPercentage > 0 ? 'GST (${breakdown.gstPercentage.toStringAsFixed(0)}%)' : 'GST',
                                style: TextStyle(fontSize: 13, color: subtitleColor, fontWeight: FontWeight.w500),
                              ),
                              Text('₹${breakdown.gstAmount.toStringAsFixed(2)}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: textColor)),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Divider(color: borderColor, height: 1),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(totalLabel, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: textColor)),
                              Text('₹${breakdown.customerPaid.toStringAsFixed(2)}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF15803D))),
                            ],
                          ),
                          if (isPaymentConfirmed) ...[
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                const Icon(Icons.check_circle_rounded, size: 14, color: Color(0xFF15803D)),
                                const SizedBox(width: 6),
                                Text(
                                  breakdown.gstAmount > 0 ? 'GST included' : 'Payment confirmed',
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF15803D)),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    // 5. FEEDBACK SECTION
                    Text(
                      'Feedback',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: subtitleColor,
                      ),
                    ),
                    const SizedBox(height: 10),
                    GestureDetector(
                      onTap: () {
                        if (!hasReview && rider != null) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => RiderRatingScreen(
                                order: TransportOrder.fromJson(order),
                                riderData: {
                                  'name': driverName,
                                  'rider_image': driverImage,
                                },
                              ),
                            ),
                          ).then((_) {
                            if (onReviewSubmitted != null) onReviewSubmitted!();
                          });
                        }
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: cardBgColor,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: borderColor, width: 1.5),
                        ),
                        child: Text(
                          hasReview
                              ? feedbackText
                              : (rider != null
                                  ? 'No feedback submitted. Tap to leave a rating!'
                                  : 'No feedback available.'),
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                            color: hasReview ? textColor : Colors.grey.shade400,
                            height: 1.45,
                            fontStyle: hasReview ? FontStyle.normal : FontStyle.italic,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),

            // 6. BOTTOM ACTION BUTTON BAR
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              decoration: BoxDecoration(
                color: cardBgColor,
                border: Border(top: BorderSide(color: borderColor, width: 1.5)),
              ),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    elevation: 0,
                    backgroundColor: const Color(0xFF0F4E5A), // Premium dark teal
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  onPressed: () => _reorderTrip(context),
                  child: Text(
                    isParcel ? 'Re-order Parcel' : 'Re-order Ride',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
