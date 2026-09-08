import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Thrown by [IntercityMatchingService.sendTravelTogetherRequest] when the target travel plan has
/// zero seats left. Translated from the DB's `trigger_prevent_request_on_full_plan` rejection
/// (which raises a message prefixed `PLAN_FULLY_BOOKED:`) so call sites can show a clean,
/// human-readable message instead of raw Postgrest error text.
class TravelPlanFullyBookedException implements Exception {
  const TravelPlanFullyBookedException();
  @override
  String toString() => 'This travel plan is fully booked.';
}

/// Shared helpers for the "Travel Together" negotiation flow between a passenger's Travel
/// Request (an `orders` row) and a Partner's Travel Plan (`rider_travel_plans`), on top of the
/// existing `intercity_requests` negotiation table and `match-intercity-riders` edge function.
///
/// This consolidates logic that used to be duplicated inline in two places —
/// `travel_plan_details_screen.dart`'s `_sendProposal` (Partner-initiated) and
/// `intercity_searching_screen.dart`'s `contactTraveller` (User-initiated) — so both call sites,
/// plus the new Available Partners screen, share one implementation instead of a third copy.
class IntercityMatchingService {
  IntercityMatchingService._();

  static SupabaseClient get _supabase => Supabase.instance.client;

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  /// Formats a date as "20 Jul" (day + short month), matching the existing display convention
  /// already used in travel_plan_details_screen.dart.
  static String formatShortDate(DateTime date) {
    return '${date.day} ${_months[date.month - 1]}';
  }

  static String _dateKey(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  /// Sends a "Travel Together" request/invitation: inserts the `intercity_requests` negotiation
  /// row (if one doesn't already exist for this order/rider pair) plus the automated intro chat
  /// message. This is the ONLY place a negotiation should ever be created — `match-intercity-riders`'s
  /// background matching is discovery-only (it just notifies "N matches available") specifically so
  /// a negotiation is never created without the user explicitly pressing Travel Together and
  /// confirming the dialog first.
  ///
  /// Initial status is `'request_sent'` — a pending state the other side must explicitly Accept
  /// or Reject (via `accept_intercity_request` / [rejectTravelTogetherRequest]), matching the
  /// intended flow: Travel Together -> Confirmation Dialog -> Request Sent -> Traveller
  /// Notification -> Traveller Accept/Reject -> Trip Confirmed.
  ///
  /// [initiatedBy] must be `'traveller'` (Partner presses Travel Together — an invitation is
  /// sent) or `'sender'` (User presses Travel Together — a request is sent).
  ///
  /// Returns `true` if a new negotiation was created, `false` if one already existed (no-op).
  static Future<bool> sendTravelTogetherRequest({
    required String orderId,
    required String riderId,
    required String? planId,
    required String passengerUserId,
    required String initiatedBy,
    required double proposedFare,
    required bool isParcel,
    String? travelDateIso,
  }) async {
    assert(initiatedBy == 'traveller' || initiatedBy == 'sender');
    debugPrint('[RUNTIME_TRACE] sendTravelTogetherRequest() executes (intercity_matching_service.dart) orderId=$orderId riderId=$riderId initiatedBy=$initiatedBy');

    // Duplicate-request check is scoped to THIS specific travel plan (route_id), not just the
    // order+rider pair -- a request already sent for an OLDER travel plan from the same rider must
    // never block a new request for a DIFFERENT (e.g. newer) travel plan the same rider later
    // publishes. planId is only omitted by callers that genuinely have no specific plan in
    // context, in which case this falls back to the previous (order+rider-only) check.
    var existingQuery = _supabase
        .from('intercity_requests')
        .select('id')
        .eq('parcel_id', orderId)
        .eq('traveller_id', riderId);
    if (planId != null) {
      existingQuery = existingQuery.eq('route_id', planId);
    }
    final existing = await existingQuery.limit(1);

    if (existing.isNotEmpty) {
      return false;
    }

    final expiresAt = travelDateIso ??
        DateTime.now().add(const Duration(hours: 24)).toUtc().toIso8601String();

    try {
      await _supabase.from('intercity_requests').insert({
        'parcel_id': orderId,
        'route_id': planId,
        'traveller_id': riderId,
        'sender_id': passengerUserId,
        'initiated_by': initiatedBy,
        'status': 'request_sent',
        'proposed_fare': proposedFare,
        'booking_type': isParcel ? 'parcel' : 'ride',
        'expires_at': expiresAt,
      });
    } on PostgrestException catch (e) {
      if (e.message.contains('PLAN_FULLY_BOOKED')) {
        throw const TravelPlanFullyBookedException();
      }
      // idx_intercity_requests_one_active_per_order_traveller: the check above raced with another
      // insert for this exact order+traveller pair (double-tap/retry) and lost -- an active
      // request already exists now, same as if the check above had caught it. Never surface the
      // raw unique-violation to the user, and never send a second "New Travel Match" notification.
      if (e.code == '23505') {
        return false;
      }
      rethrow;
    }

    final currentUserId = _supabase.auth.currentUser?.id;
    if (currentUserId != null) {
      final isRiderInitiated = initiatedBy == 'traveller';
      final introMessage = isRiderInitiated
          ? (isParcel
              ? "Hi! I am interested in delivering your parcel. Let's discuss."
              : "Hi! I have a travel plan matching your route. Let's discuss.")
          : (isParcel
              ? "Hi! I am interested in your travel plan for my parcel shipment. Let's discuss."
              : "Hi! I am interested in your travel plan for my ride. Let's discuss.");

      try {
        await _supabase.from('order_chat_messages').insert({
          'sender_id': currentUserId,
          'sender_type': isRiderInitiated ? 'rider' : 'user',
          'message': introMessage,
          'user_id': isRiderInitiated ? passengerUserId : currentUserId,
          'is_support': false,
          'order_id': orderId,
          'rider_id': riderId,
        });
      } catch (e) {
        debugPrint('IntercityMatchingService: failed to send intro chat message: $e');
      }
    }

    return true;
  }

  /// Rejects a pending Travel Together negotiation via the `reject_intercity_offer` RPC
  /// (Parts 12/14) — notification to the opposite party is handled server-side by the existing
  /// `on_intercity_request_change` trigger, not here.
  static Future<Map<String, dynamic>> rejectTravelTogetherRequest({
    required String requestId,
    required String actorType,
  }) async {
    assert(actorType == 'traveller' || actorType == 'sender');
    final response = await _supabase.rpc('reject_intercity_offer', params: {
      'p_request_id': requestId,
      'p_actor_type': actorType,
    });
    return Map<String, dynamic>.from(response as Map);
  }

  /// Issue 4: cancels ONE already-accepted passenger/parcel request via
  /// `cancel_intercity_request_by_traveller` -- distinct from deleting the entire travel plan.
  /// Only 'confirmed'/'paid' requests are eligible server-side; the travel plan itself and every
  /// other passenger's request/order are left untouched. Notification to the cancelled passenger
  /// and the plan's fully_booked->active revival both happen automatically via existing triggers.
  static Future<Map<String, dynamic>> cancelAcceptedPassengerRequest({
    required String requestId,
    required String cancelReason,
  }) async {
    final response = await _supabase.rpc('cancel_intercity_request_by_traveller', params: {
      'p_request_id': requestId,
      'p_cancel_reason': cancelReason,
    });
    return Map<String, dynamic>.from(response as Map);
  }

  /// Issue 2: the ONE canonical, secure server-side path for a traveller to cancel their entire
  /// pre-trip travel plan, via `cancel_travel_plan_by_traveller`. Replaces every direct
  /// `rider_travel_plans` client-side status update -- the RPC enforces ownership, requires a
  /// non-empty reason, and refuses with `TRIP_ALREADY_STARTED` if any linked order has genuinely
  /// started (`orders.trip_started_at IS NOT NULL`), rather than trusting a client-side check.
  /// Cascading cleanup (cancelling open negotiations/accepted orders, notifying every affected
  /// passenger) happens entirely server-side via existing DB triggers -- this call performs no
  /// other write.
  static Future<Map<String, dynamic>> cancelTravelPlan({
    required String routeId,
    required String cancelReason,
  }) async {
    final response = await _supabase.rpc('cancel_travel_plan_by_traveller', params: {
      'p_route_id': routeId,
      'p_cancel_reason': cancelReason,
    });
    return Map<String, dynamic>.from(response as Map);
  }

  /// User-side browsing (Parts 5/6/8/26): simple, literal-spec filter (same pickup, same
  /// destination, same date, seats available, active) against `rider_travel_plans` — deliberately
  /// simpler than `match-intercity-riders`'s corridor-scoring algorithm, which stays the sole
  /// owner of match->negotiation creation. This is a read-only listing query, not new matching
  /// business logic.
  static Future<List<Map<String, dynamic>>> fetchAvailablePartnersForDate({
    required String pickupCity,
    required String destinationCity,
    required DateTime date,
  }) async {
    final startOfDay = DateTime.utc(date.year, date.month, date.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));

    final plans = await _supabase
        .from('rider_travel_plans')
        .select(_partnerPlanSelectColumns)
        .eq('status', 'active')
        .ilike('pickup_city', pickupCity)
        .ilike('destination_city', destinationCity)
        .gte('travel_date', startOfDay.toIso8601String())
        .lt('travel_date', endOfDay.toIso8601String());

    return _enrichPlans(plans);
  }

  /// Looks up ONE specific active travel plan by id, through the exact same enrichment pipeline
  /// as [fetchAvailablePartnersForDate] (seats/kyc/rating/completed-trips). Used to guarantee a
  /// match notification's tap target is shown even if it falls outside the generic date/city-
  /// string search's stricter filters (the matching engine that produced the notification allows
  /// a wider date window and route-corridor/coordinate matches with different city strings) --
  /// see AvailablePartnersScreen.initialPlanId. Returns null if the plan is gone, inactive, or
  /// fully booked -- callers should then correctly fall back to the generic empty state.
  static Future<Map<String, dynamic>?> fetchPartnerByPlanId(String planId) async {
    final plans = await _supabase
        .from('rider_travel_plans')
        .select(_partnerPlanSelectColumns)
        .eq('id', planId)
        .eq('status', 'active')
        .limit(1);

    final enriched = await _enrichPlans(plans);
    return enriched.isEmpty ? null : enriched.first;
  }

  static const String _partnerPlanSelectColumns = '''
          id, pickup_city, destination_city, pickup_lat, pickup_lng, destination_lat, destination_lng,
          travel_date, status, rider_id, max_bookings,
          travel_plan_type, vehicle_type, price_per_seat,
          rider:riders!inner(id, user_id, rating, account_status)
        ''';

  /// Shared per-plan enrichment (seats/kyc/rating/completed-trips joins) used by both
  /// [fetchAvailablePartnersForDate] and [fetchPartnerByPlanId] so a single-plan lookup can never
  /// drift out of sync with the list lookup's shape.
  static Future<List<Map<String, dynamic>>> _enrichPlans(List<Map<String, dynamic>> plans) async {
    if (plans.isEmpty) return [];

    final planIds = plans.map((p) => p['id']).toList();
    final riderRows = plans.map((p) => p['rider'] as Map<String, dynamic>).toList();
    final riderUserIds = riderRows.map((r) => r['user_id']).whereType<Object>().toList();
    final riderIds = riderRows.map((r) => r['id']).whereType<Object>().toList();

    final seatRows = await _supabase
        .from('travel_plan_seat_availability_view')
        .select('plan_id, available_seats')
        .inFilter('plan_id', planIds);
    final seatMap = {for (final r in seatRows) r['plan_id'].toString(): r['available_seats'] as int};

    final kycRows = riderUserIds.isEmpty
        ? <Map<String, dynamic>>[]
        : await _supabase
            .from('rider_kyc')
            .select('user_id, full_name, vehicle_type, vehicle_number, rider_image, kyc_status')
            .inFilter('user_id', riderUserIds);
    final kycMap = {for (final k in kycRows) k['user_id'].toString(): k};

    final reviewRows = riderIds.isEmpty
        ? <Map<String, dynamic>>[]
        : await _supabase
            .from('rider_reviews')
            .select('rider_id')
            .inFilter('rider_id', riderIds)
            .eq('rated_by', 'user');
    final reviewCounts = <String, int>{};
    for (final r in reviewRows) {
      final id = r['rider_id'].toString();
      reviewCounts[id] = (reviewCounts[id] ?? 0) + 1;
    }

    // Feature 3: "Completed Trips" card field, sourced from the same reliability view the
    // match-intercity-riders edge function already uses for its own scoring — avoids computing
    // trip-completion counts a second, different way.
    final reliabilityRows = riderIds.isEmpty
        ? <Map<String, dynamic>>[]
        : await _supabase
            .from('rider_reliability_view')
            .select('rider_id, total_completed')
            .inFilter('rider_id', riderIds);
    final completedTripsMap = {
      for (final r in reliabilityRows) r['rider_id'].toString(): (r['total_completed'] as num?)?.toInt() ?? 0
    };

    final result = <Map<String, dynamic>>[];
    for (final p in plans) {
      final planId = p['id'].toString();
      final maxBookings = (p['max_bookings'] as int?) ?? 0;
      final availableSeats = seatMap[planId] ?? maxBookings;
      if (availableSeats <= 0) continue;

      final rider = p['rider'] as Map<String, dynamic>;
      final riderUserId = rider['user_id']?.toString();
      final riderIdStr = rider['id']?.toString();
      final kyc = riderUserId != null ? kycMap[riderUserId] : null;

      result.add({
        ...p,
        'available_seats': availableSeats,
        'full_name': kyc?['full_name'] ?? 'Rider Partner',
        'vehicle_type': p['vehicle_type'] ?? kyc?['vehicle_type'],
        'vehicle_number': kyc?['vehicle_number'] ?? '',
        'rider_image': kyc?['rider_image'] ?? '',
        'is_verified': kyc?['kyc_status'] == 'approved',
        'rating': rider['rating'],
        'reviews_count': riderIdStr != null ? (reviewCounts[riderIdStr] ?? 0) : 0,
        'completed_trips': riderIdStr != null ? (completedTripsMap[riderIdStr] ?? 0) : 0,
      });
    }
    return result;
  }


  /// Bug 5: which of [riderIds] already have an `intercity_requests` row for [orderId] —
  /// used to render a persisted "Request Sent ✓" button state instead of a transient one that
  /// resets on reload. Every status counts (not just "active" ones), matching
  /// [sendTravelTogetherRequest]'s own idempotency check (any existing row is a no-op), so the
  /// button state never claims something is sendable when the backend would silently reject it.
  static Future<Set<String>> fetchExistingRequestRiderIds({
    required String orderId,
    required List<String> riderIds,
  }) async {
    if (riderIds.isEmpty) return {};
    final rows = await _supabase
        .from('intercity_requests')
        .select('traveller_id')
        .eq('parcel_id', orderId)
        .inFilter('traveller_id', riderIds);
    return rows.map((r) => r['traveller_id'].toString()).toSet();
  }

  /// Bug 5, Partner side: which of [orderIds] already have an `intercity_requests` row from
  /// this [riderId] — mirrors [fetchExistingRequestRiderIds] with the fixed/varying sides
  /// swapped, for the new Available Travelers screen.
  static Future<Set<String>> fetchExistingRequestOrderIds({
    required String riderId,
    required List<String> orderIds,
  }) async {
    if (orderIds.isEmpty) return {};
    final rows = await _supabase
        .from('intercity_requests')
        .select('parcel_id')
        .eq('traveller_id', riderId)
        .inFilter('parcel_id', orderIds);
    return rows.map((r) => r['parcel_id'].toString()).toSet();
  }

  static double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    final dLat = (lat2 - lat1) * (pi / 180);
    final dLng = (lng2 - lng1) * (pi / 180);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * sin(dLng / 2) * sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return r * c;
  }

  /// Feature 3: enriches each partner with 'distance_from_pickup_km' / 'estimated_arrival_minutes'
  /// (haversine from the passenger's current device position to the partner's pickup point, using
  /// a per-vehicle average speed — the same style of estimate travel_plan_details_screen.dart
  /// already uses for its own ETA display), then sorts by Highest Rating -> Nearest Pickup ->
  /// Earliest Departure, matching the spec's required Available Travellers ordering exactly.
  static List<Map<String, dynamic>> enrichWithDistanceAndSort({
    required List<Map<String, dynamic>> partners,
    double? currentLat,
    double? currentLng,
  }) {
    final enriched = partners.map((p) {
      final pickupLat = double.tryParse((p['pickup_lat'] ?? '').toString());
      final pickupLng = double.tryParse((p['pickup_lng'] ?? '').toString());
      double? distanceKm;
      if (currentLat != null && currentLng != null && pickupLat != null && pickupLng != null) {
        distanceKm = _haversineKm(currentLat, currentLng, pickupLat, pickupLng);
      }
      final vehicle = (p['vehicle_type'] ?? '').toString().toLowerCase();
      final speedKmh = vehicle == 'bike' ? 40.0 : (vehicle == 'auto' ? 35.0 : 50.0);
      final etaMinutes = distanceKm != null ? ((distanceKm / speedKmh) * 60).round() : null;
      return <String, dynamic>{
        ...p,
        'distance_from_pickup_km': distanceKm,
        'estimated_arrival_minutes': etaMinutes,
      };
    }).toList();

    enriched.sort((a, b) {
      final ratingA = double.tryParse((a['rating'] ?? 0).toString()) ?? 0;
      final ratingB = double.tryParse((b['rating'] ?? 0).toString()) ?? 0;
      if (ratingB != ratingA) return ratingB.compareTo(ratingA);

      final distA = a['distance_from_pickup_km'] as double?;
      final distB = b['distance_from_pickup_km'] as double?;
      if (distA != null && distB != null && distA != distB) return distA.compareTo(distB);
      if (distA != null && distB == null) return -1;
      if (distA == null && distB != null) return 1;

      final dateA = DateTime.tryParse((a['travel_date'] ?? '').toString());
      final dateB = DateTime.tryParse((b['travel_date'] ?? '').toString());
      if (dateA != null && dateB != null) return dateA.compareTo(dateB);
      return 0;
    });

    return enriched;
  }

  /// Per-date partner counts for the Available Partners date strip (Part 6). Sequential per-date
  /// reads are fine for the small (~7 day) browsing horizon this screen shows.
  static Future<Map<String, int>> fetchDateCounts({
    required String pickupCity,
    required String destinationCity,
    required List<DateTime> dates,
  }) async {
    final counts = <String, int>{};
    for (final date in dates) {
      final partners = await fetchAvailablePartnersForDate(
        pickupCity: pickupCity,
        destinationCity: destinationCity,
        date: date,
      );
      counts[_dateKey(date)] = partners.length;
    }
    return counts;
  }

  /// Partner-side "Matched Passengers"/"Matched Drop Partners" list on Travel Plan Details:
  /// the Partner's actual incoming `intercity_requests` rows for this plan, not a live
  /// re-match search. A request created via [sendTravelTogetherRequest] must show up here
  /// immediately, so this queries the negotiation table directly (joined to its order and the
  /// passenger's user info) instead of re-running match-intercity-riders.
  static Future<List<Map<String, dynamic>>> fetchIncomingRequestsForPlan({
    required String planId,
    required String riderId,
  }) async {
    debugPrint('[RUNTIME_TRACE] Incoming requests query executes (intercity_matching_service.dart fetchIncomingRequestsForPlan) planId=$planId riderId=$riderId');
    final rows = await _supabase
        .from('intercity_requests')
        .select('parcel_id, orders(*, users(full_name, gender, profile_photo_url, rating, total_ratings, profile_completed))')
        .eq('route_id', planId)
        .eq('traveller_id', riderId)
        .not('status', 'in', '(cancelled,rejected,expired)')
        .order('created_at', ascending: false);

    final matches = <Map<String, dynamic>>[];
    for (final row in rows) {
      final orderData = row['orders'];
      if (orderData is Map) {
        matches.add(Map<String, dynamic>.from(orderData));
      }
    }
    return enrichWithCompletedTrips(matches);
  }

  /// Fetches each match's passenger `completed_trips` count from `passenger_trip_stats_view`
  /// (a plain aggregate, never raw order rows -- see the migration adding it) and stamps it onto
  /// `match['users']['completed_trips']`, so Accept Request / OTP verification cards can show a
  /// real number instead of the (previously non-existent) `total_completed_orders` field.
  static Future<List<Map<String, dynamic>>> enrichWithCompletedTrips(
    List<Map<String, dynamic>> matches,
  ) async {
    final userIds = matches
        .map((m) => m['user_id'])
        .whereType<Object>()
        .map((id) => id.toString())
        .toSet()
        .toList();
    if (userIds.isEmpty) return matches;

    final statsRows = await _supabase
        .from('passenger_trip_stats_view')
        .select('user_id, completed_trips')
        .inFilter('user_id', userIds);
    final statsMap = {
      for (final r in statsRows) r['user_id'].toString(): (r['completed_trips'] as num?)?.toInt() ?? 0
    };

    for (final match in matches) {
      final uid = match['user_id']?.toString();
      final completed = uid != null ? (statsMap[uid] ?? 0) : 0;
      final users = match['users'];
      if (users is Map) {
        match['users'] = {...users, 'completed_trips': completed};
      }
    }
    return matches;
  }
}
