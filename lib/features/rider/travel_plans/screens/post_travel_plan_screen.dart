 import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/maps/ola_map_service.dart';
import 'package:waydrop/shared/helpers/location_display_service.dart';
import 'package:waydrop/shared/helpers/time_format_helper.dart';
import 'package:waydrop/features/rider/vehicles/screens/add_vehicle_screen.dart';
import 'package:waydrop/modules/payments/controllers/pricing_controller.dart';

class PostTravelPlanScreen extends StatefulWidget {
  final String riderId;
  final Function(Map<String, dynamic>) onPlanPosted;

  const PostTravelPlanScreen({
    super.key,
    required this.riderId,
    required this.onPlanPosted,
  });

  @override
  State<PostTravelPlanScreen> createState() => _PostTravelPlanScreenState();
}

class _PostTravelPlanScreenState extends State<PostTravelPlanScreen> {
  final supabase = Supabase.instance.client;

  // Colors based on premium design system
  static const Color darkBg = Color(0xFF090D1A);
  static const Color darkCard = Color(0xFF131926);
  static const Color primaryLime = Color(0xFFC5FF30);
  static const Color textGray = Color(0xFF94A3B8);

  final departureSearchController = TextEditingController();
  final arrivalSearchController = TextEditingController();
  final departureFocus = FocusNode();
  final arrivalFocus = FocusNode();

  List<dynamic> departurePredictions = [];
  List<dynamic> arrivalPredictions = [];
  bool loadingDepartureSearch = false;
  bool loadingArrivalSearch = false;

  bool isSearchingDeparture = false;
  bool isSearchingArrival = false;

  double? selectedDepartureLat;
  double? selectedDepartureLng;
  double? selectedArrivalLat;
  double? selectedArrivalLng;
  String? selectedDepartureAddress;
  String? selectedArrivalAddress;
  String? selectedDepartureCity;
  String? selectedArrivalCity;

  // Defaults to today so a Drop Partner who only sets the Time field (leaving the date picker
  // untouched) gets a same-day plan, not one silently bumped to tomorrow. Previously defaulted to
  // `DateTime.now().add(Duration(hours: 24))`, which is what produced the "Travel will start in
  // 24 hours" bug for plans the driver believed they'd created for today.
  DateTime selectedDate = DateTime.now();
  double weightPreference = 25.0;
  String travelPlanType = 'both'; // 'ride', 'parcel', 'both'
  String selectedVehicle = 'cab';  // 'cab', 'auto', 'bike' — must match an approved vehicle
  int maxBookings = 3;

  // Travel plans may only be created for a vehicle that has actually been
  // verified (either the one-time KYC vehicle, or an additional vehicle
  // approved via the "My Vehicles" flow) — no free-text vehicle entry.
  List<Map<String, dynamic>> approvedVehicles = [];
  bool loadingVehicles = true;
  // Defensive guard only — the real boundary is the rider_travel_plans
  // INSERT/UPDATE RLS policy (20260718000012), which already rejects a
  // Local Rides-mode partner's write at the database layer regardless of
  // what this screen does.
  bool wrongMode = false;

  Timer? departureDebounce;
  Timer? arrivalDebounce;
  bool submitting = false;

  // ============================================================================
  // VIA LOCATIONS (declared route) -- docs/13_Business_Logic.md section 5.
  //
  // The traveller may optionally declare the exact ordered corridor they intend to travel
  // through (Origin -> Via 1 -> Via 2 -> ... -> Destination). This list is ORDERED (index = travel
  // order) and never reordered. When non-empty it drives ONLY selected_route_* fields (matching /
  // navigation intent) -- never route_geometry / distance_km / pricing, which stay sourced from
  // the canonical getDirections() call exactly as before (Option C separation).
  //
  // The maximum is a product cap (not an Ola constraint): the multi-leg builder issues
  // (stops - 1) getDirections() calls, so this bounds worst-case plan-creation latency.
  // ============================================================================
  static const int maxViaStops = 5;
  // Via locations are REQUIRED for an Intercity travel plan -- the declared route is the primary
  // signal the matcher uses, so a plan with fewer than this many via stops cannot be created.
  static const int minViaStops = 2;
  final List<_ViaStop> viaStops = [];

  // Via rows the traveller has actually resolved to a real location (empty/half-typed rows are
  // ignored on submit and don't count toward the minimum).
  List<_ViaStop> get _resolvedViaStops => viaStops
      .where((v) => v.lat != null && v.lng != null && (v.address?.isNotEmpty ?? false))
      .toList();

  @override
  void initState() {
    super.initState();
    _loadApprovedVehicles();
  }

  Future<void> _loadApprovedVehicles() async {
    setState(() => loadingVehicles = true);
    try {
      final vehicles = <Map<String, dynamic>>[];

      final riderRes = await supabase
          .from('riders')
          .select('kyc_id, service_mode')
          .eq('id', widget.riderId)
          .maybeSingle();

      if (riderRes != null && riderRes['service_mode'] != 'intercity') {
        if (!mounted) return;
        setState(() {
          wrongMode = true;
          loadingVehicles = false;
        });
        return;
      }

      if (riderRes != null && riderRes['kyc_id'] != null) {
        final kycRes = await supabase
            .from('rider_kyc')
            .select('vehicle_type, vehicle_number, kyc_status')
            .eq('id', riderRes['kyc_id'])
            .maybeSingle();
        if (kycRes != null && kycRes['kyc_status'] == 'approved' && kycRes['vehicle_type'] != null) {
          vehicles.add({
            'vehicle_type': kycRes['vehicle_type'].toString(),
            'vehicle_number': kycRes['vehicle_number']?.toString() ?? '',
          });
        }
      }

      final extraRes = await supabase
          .from('rider_vehicles')
          .select('vehicle_type, vehicle_number')
          .eq('rider_id', widget.riderId)
          .eq('status', 'approved');
      for (final v in List<Map<String, dynamic>>.from(extraRes)) {
        vehicles.add({
          'vehicle_type': v['vehicle_type'].toString(),
          'vehicle_number': v['vehicle_number']?.toString() ?? '',
        });
      }

      // A travel plan only stores a vehicle_type, not a specific vehicle id,
      // so de-duplicate multiple approved vehicles of the same type.
      final Map<String, Map<String, dynamic>> byType = {
        for (final v in vehicles) v['vehicle_type'].toString(): v,
      };
      final distinct = byType.values.toList();

      if (!mounted) return;
      setState(() {
        approvedVehicles = distinct;
        loadingVehicles = false;
        if (distinct.length == 1) {
          selectedVehicle = distinct.first['vehicle_type'].toString();
        } else if (distinct.isNotEmpty && !distinct.any((v) => v['vehicle_type'] == selectedVehicle)) {
          selectedVehicle = distinct.first['vehicle_type'].toString();
        }
      });
      if (distinct.isNotEmpty) {
        updateMaxBookingsDefault(selectedVehicle);
      }
    } catch (e) {
      debugPrint('Error loading approved vehicles: $e');
      if (mounted) setState(() => loadingVehicles = false);
    }
  }

  @override
  void dispose() {
    departureSearchController.dispose();
    arrivalSearchController.dispose();
    departureFocus.dispose();
    arrivalFocus.dispose();
    departureDebounce?.cancel();
    arrivalDebounce?.cancel();
    for (final v in viaStops) {
      v.dispose();
    }
    super.dispose();
  }

  // Seat/booking capacity is capped by what the vehicle can physically carry:
  // Bike = 1, Auto = up to 3, Cab = up to 4. Never allow a count outside
  // this range for the currently selected vehicle.
  List<int> seatOptionsFor(String vehicle) {
    switch (vehicle) {
      case 'bike':
        return const [1];
      case 'auto':
        return const [1, 2, 3];
      case 'cab':
        return const [1, 2, 3, 4];
      default:
        return const [1, 2, 3, 4];
    }
  }

  void updateMaxBookingsDefault(String vehicle) {
    setState(() {
      selectedVehicle = vehicle;
      if (vehicle == 'cab') {
        maxBookings = 3;
      } else if (vehicle == 'auto') {
        maxBookings = 2;
      } else if (vehicle == 'bike') {
        maxBookings = 1;
      } else {
        maxBookings = 3;
      }
    });
  }

  String extractCity(String? city, String address) {
    return LocationDisplayService.resolveCity(
      city: city,
      address: address,
      fallback: 'Other',
    );
  }

  Future<void> _submitTravelPlan() async {
    if (approvedVehicles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add and verify a vehicle before posting a travel plan.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (selectedDepartureLat == null ||
        selectedDepartureLng == null ||
        selectedDepartureAddress == null ||
        selectedArrivalLat == null ||
        selectedArrivalLng == null ||
        selectedArrivalAddress == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select valid departure and arrival locations.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final fromCityName = extractCity(selectedDepartureCity, selectedDepartureAddress!);
    final toCityName = extractCity(selectedArrivalCity, selectedArrivalAddress!);

    if (fromCityName == toCityName) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Departure and arrival cities cannot be the same')),
      );
      return;
    }

    // Via locations (declared route) validation -- duplicates, invalid coords, unresolved rows,
    // Via == origin/destination. Empty Via rows are ignored (dropped on submit). See section 5.
    final viaError = _validateViaStops();
    if (viaError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(viaError), backgroundColor: Colors.orange),
      );
      return;
    }

    // Issue 3 fix: the date picker below already restricts `firstDate` to today, but the time
    // picker has no equivalent guard -- a rider could pick today's date and then a time already in
    // the past (e.g. selecting 8:10 PM at 8:30 PM). This was previously reaching
    // rider_travel_plans.insert() with no client-side check at all. Compared as absolute instants
    // (selectedDate is stored/sent via .toUtc()), so this is timezone-safe without any new
    // timezone model -- it uses the exact same DateTime the insert below already sends.
    if (!selectedDate.isAfter(DateTime.now())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please choose a future date and time for your travel plan.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => submitting = true);

    try {
      // ======================================================================
      // CANONICAL ROUTE (unchanged pre-feature single-route call). This alone controls
      // route_geometry, distance_km, and pricing -- see the "SELECTED ROUTE" block below for
      // why these two calls are DELIBERATELY independent (docs/13_Business_Logic.md section
      // 5.2/5.3, "Option C" pricing separation): a traveller's later matching-route choice must
      // never change the fare they were already quoted at plan-creation time.
      // ======================================================================
      String? routeGeometryJson;
      double planDistanceKm = 0;
      try {
        final directions = await OlaMapService.getDirections(
          originLat: selectedDepartureLat!,
          originLng: selectedDepartureLng!,
          destinationLat: selectedArrivalLat!,
          destinationLng: selectedArrivalLng!,
        );
        if (directions != null && directions.polylinePoints.isNotEmpty) {
          routeGeometryJson = jsonEncode(
            directions.polylinePoints.map((pt) => [pt['lat'], pt['lng']]).toList(),
          );
        }
        if (directions != null) {
          planDistanceKm = directions.distanceMeters / 1000;
        }
      } catch (e) {
        debugPrint('Error getting directions: $e');
      }

      // ======================================================================
      // DECLARED ROUTE / VIA LOCATIONS (docs/13_Business_Logic.md section 5) -- matching +
      // navigation intent ONLY. These three variables are populated below, AFTER the pricing
      // block, from the traveller's ordered Via locations via a multi-leg route build. They are
      // DELIBERATELY independent of routeGeometryJson / planDistanceKm / pricing above (Option C
      // separation): the Via route's own total distance must never change the fare the traveller
      // was quoted. When the traveller adds no Via locations, all three stay at their defaults
      // (NULL / 'none') and matching for this plan behaves exactly like a pre-feature plan.
      // ======================================================================
      String? selectedRouteGeometryJson;
      Map<String, dynamic>? selectedRouteMeta;
      String routeSelectionStatus = 'none';

      // The passenger/parcel seat fare is calculated and LOCKED here, once, at Travel Plan
      // creation time — using this plan's own route distance, the same PricingController /
      // pricing_config pipeline used everywhere else. It is stored on the plan row and never
      // recalculated later, so this plan keeps its original price even if Way Drop changes
      // pricing_config afterwards (see intercity_ride_booking_screen.dart's
      // _searchMatchingPlans, which reads these stored columns instead of recomputing).
      //
      // This used to run only for travelPlanType != 'parcel', leaving every parcel-only Travel
      // Plan's price_per_seat permanently at 0 (confirmed live: 100% of existing
      // travel_plan_type='parcel' rows had price_per_seat = 0) -- that 0 then flowed straight
      // into a passenger's Travel Together request as its proposedFare (see
      // available_partners_screen.dart) and, on acceptance, into the real order's final_fare.
      // Parcel-only plans now price via the 'intercity_parcel' pricing_config service_type
      // (ride/both plans keep using 'intercity_ride', unchanged from before).
      double baseFarePerSeat = 0;
      double gstAmountPerSeat = 0;
      double pricePerSeat = 0;
      if (planDistanceKm <= 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not determine route distance. Please try again.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }
      final farePricing = PricingController();
      await farePricing.fetchMultiplePricing(
        orderType: travelPlanType == 'parcel' ? 'intercity_parcel' : 'intercity_ride',
        distanceKm: planDistanceKm,
        pickupAddress: selectedDepartureAddress!,
        maxBoostAmount: 0,
        pickupLat: selectedDepartureLat,
        pickupLng: selectedDepartureLng,
      );
      if (farePricing.getVehiclePricing(selectedVehicle) == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Unable to calculate fare for this route right now. Please try again.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }
      baseFarePerSeat = farePricing.getBaseFare(selectedVehicle);
      gstAmountPerSeat = farePricing.getGstAmount(selectedVehicle);
      pricePerSeat = farePricing.getFinalFare(selectedVehicle);

      // ======================================================================
      // DECLARED ROUTE build (docs/13_Business_Logic.md section 5). Runs only when the traveller
      // added >=1 Via location. Builds ONE ordered route Origin -> Via 1 -> ... -> Destination
      // via OlaMapService.getMultiStopRoute (N-1 sequential getDirections() legs, stitched).
      //
      // This block is intentionally placed AFTER pricing: it never feeds routeGeometryJson /
      // planDistanceKm / any fare field. If the multi-leg build fails, plan creation is ABORTED
      // (no partial/corrupted route is ever persisted) -- section 5.1.
      // ======================================================================
      // _validateViaStops() (called before submission started) already guaranteed there are at
      // least minViaStops resolved via locations -- this list is never shorter than that here.
      final resolvedVias = _resolvedViaStops;
      if (resolvedVias.isNotEmpty) {
        final stops = <Map<String, double>>[
          {'lat': selectedDepartureLat!, 'lng': selectedDepartureLng!},
          for (final v in resolvedVias) {'lat': v.lat!, 'lng': v.lng!},
          {'lat': selectedArrivalLat!, 'lng': selectedArrivalLng!},
        ];

        final multi = await OlaMapService.getMultiStopRoute(stops: stops);
        if (!mounted) return;
        if (multi == null) {
          setState(() => submitting = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Could not build a route through your Via locations. Remove a stop or try again.',
              ),
              backgroundColor: Colors.orange,
            ),
          );
          return;
        }

        final labels = <String>[
          fromCityName,
          for (final v in resolvedVias) (v.city?.isNotEmpty ?? false) ? v.city! : (v.address ?? 'Via'),
          toCityName,
        ];
        final lats = <double>[
          selectedDepartureLat!,
          for (final v in resolvedVias) v.lat!,
          selectedArrivalLat!,
        ];
        final lngs = <double>[
          selectedDepartureLng!,
          for (final v in resolvedVias) v.lng!,
          selectedArrivalLng!,
        ];
        final totalKm = multi.route.distanceMeters / 1000;
        final cum = multi.cumulativeKm;

        final waypoints = <Map<String, dynamic>>[];
        for (var i = 0; i < lats.length; i++) {
          waypoints.add({
            'order': i,
            'type': i == 0
                ? 'origin'
                : (i == lats.length - 1 ? 'destination' : 'via'),
            'label': labels[i],
            'lat': lats[i],
            'lng': lngs[i],
            'along_track_km': i < cum.length ? cum[i] : totalKm,
          });
        }

        selectedRouteGeometryJson = jsonEncode(
          multi.route.polylinePoints.map((pt) => [pt['lat'], pt['lng']]).toList(),
        );
        selectedRouteMeta = {
          'waypoints': waypoints,
          'total_distance_km': totalKm,
          'provider': 'ola',
          'built_via': 'multi_leg',
          'leg_count': stops.length - 1,
          'selected_at': DateTime.now().toUtc().toIso8601String(),
        };
        routeSelectionStatus = 'via_declared';
      }

      final insertedPlan = await supabase.from('rider_travel_plans').insert({
        'rider_id': widget.riderId,
        'pickup_city': fromCityName,
        'destination_city': toCityName,
        'pickup_lat': selectedDepartureLat,
        'pickup_lng': selectedDepartureLng,
        'destination_lat': selectedArrivalLat,
        'destination_lng': selectedArrivalLng,
        'weight_preference': weightPreference.round(),
        'max_weight_kg': travelPlanType == 'ride' ? 0.0 : weightPreference.round(),
        'travel_plan_type': travelPlanType,
        'vehicle_type': selectedVehicle,
        'max_bookings': maxBookings,
        'travel_date': selectedDate.toUtc().toIso8601String(),
        'status': 'active',
        'route_geometry': routeGeometryJson,
        'distance_km': planDistanceKm,
        'base_fare_per_seat': baseFarePerSeat,
        'gst_amount_per_seat': gstAmountPerSeat,
        'price_per_seat': pricePerSeat,
        // FROZEN SPEC (docs/13_Business_Logic.md section 5.2): additive-only, NULL for every
        // plan created before this feature (see the migration's own comment). Existing
        // route_geometry above keeps its exact current meaning -- this does not overload it.
        'selected_route_geometry': selectedRouteGeometryJson,
        'selected_route_meta': selectedRouteMeta,
        'route_selection_status': routeSelectionStatus,
      }).select('id').single();  // Egress fix: only `id` is read below.

      // Issue 7 (Phase 2) fix: background matching for this newly-posted plan is no longer
      // triggered from here. It used to be a bare client-side fire-and-forget
      // `supabase.functions.invoke('match-intercity-riders', ...)` call, tied to this app
      // process's lifetime -- if the rider backgrounded/closed the app right after seeing "Travel
      // plan posted successfully!" (a completely natural next action once that SnackBar has
      // already fired), the in-flight request could be dropped before the server ever processed
      // it, silently losing the "Traveller Available" notification for any user whose matching
      // request/order already existed. rider_travel_plans' own AFTER INSERT trigger
      // (on_rider_travel_plan_insert(), 20260901000031) now calls match-intercity-riders itself
      // via pg_net -- server-guaranteed the instant this row commits, exactly mirroring how
      // create-order/index.ts already guarantees its own (order-first) direction via
      // EdgeRuntime.waitUntil(). Triggering it again here would only recompute the identical match
      // a second time for no benefit (travel_matches' dedup means no duplicate notification, just
      // duplicate work).

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Travel plan posted successfully!'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
        widget.onPlanPosted(Map<String, dynamic>.from(insertedPlan));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error posting plan: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  // ==========================================================================
  // VIA LOCATIONS (declared route) helpers -- docs/13_Business_Logic.md section 5.
  // ==========================================================================

  void _addViaStop() {
    if (viaStops.length >= maxViaStops) return;
    setState(() => viaStops.add(_ViaStop()));
  }

  void _removeViaStop(int index) {
    if (index < 0 || index >= viaStops.length) return;
    final removed = viaStops.removeAt(index);
    removed.dispose();
    setState(() {});
  }

  void _onViaChanged(_ViaStop via, String value) {
    via.debounce?.cancel();
    // Any keystroke invalidates a location previously picked for this row.
    via.lat = null;
    via.lng = null;
    via.address = null;
    via.city = null;
    if (value.trim().isEmpty) {
      setState(() => via.predictions = []);
      return;
    }
    via.debounce = Timer(const Duration(milliseconds: 400), () async {
      if (!mounted) return;
      setState(() => via.loading = true);
      try {
        final results = await OlaMapService.autocomplete(value);
        if (!mounted) return;
        setState(() {
          via.predictions = results;
          via.loading = false;
        });
      } catch (_) {
        if (mounted) setState(() => via.loading = false);
      }
    });
  }

  Future<void> _onViaPredictionTap(_ViaStop via, Map<String, dynamic> item) async {
    via.focus.unfocus();
    final desc = item['description']?.toString() ?? '';
    via.controller.text = desc;
    setState(() {
      via.predictions = [];
      via.loading = true;
    });
    try {
      final placeId = item['place_id']?.toString();
      Map<String, dynamic>? coords;
      if (placeId != null && placeId.isNotEmpty) {
        coords = await OlaMapService.getCoordinatesFromPlaceId(placeId);
      }
      coords ??= await OlaMapService.getCoordinatesFromAddress(desc);
      if (!mounted) return;
      if (coords != null) {
        setState(() {
          via.lat = (coords!['latitude'] as num?)?.toDouble();
          via.lng = (coords['longitude'] as num?)?.toDouble();
          via.address = desc;
          via.city = extractCity(coords['city']?.toString(), desc);
        });
      }
    } finally {
      if (mounted) setState(() => via.loading = false);
    }
  }

  bool _validLatLng(double lat, double lng) =>
      lat.abs() <= 90 && lng.abs() <= 180 && !(lat == 0 && lng == 0);

  // ~220 m box -- "is this effectively the same place the traveller already picked".
  bool _sameSpot(double lat1, double lng1, double lat2, double lng2) =>
      (lat1 - lat2).abs() < 0.002 && (lng1 - lng2).abs() < 0.002;

  /// Returns a user-facing error string if the current Via list is invalid, else null.
  /// Empty (never-selected) Via rows are ignored here and dropped on submit. Enforces the
  /// mandatory minimum of [minViaStops] resolved via locations.
  String? _validateViaStops() {
    for (var i = 0; i < viaStops.length; i++) {
      final v = viaStops[i];
      final hasText = v.controller.text.trim().isNotEmpty;
      final hasCoords =
          v.lat != null && v.lng != null && (v.address?.isNotEmpty ?? false);
      if (hasText && !hasCoords) {
        return 'Finish selecting Via location ${i + 1} from the suggestions, or remove it.';
      }
      if (!hasCoords) continue;
      if (!_validLatLng(v.lat!, v.lng!)) {
        return 'Via location ${i + 1} has an invalid location. Please re-select it.';
      }
      if (selectedDepartureLat != null &&
          selectedDepartureLng != null &&
          _sameSpot(v.lat!, v.lng!, selectedDepartureLat!, selectedDepartureLng!)) {
        return 'Via location ${i + 1} is the same as your departure location.';
      }
      if (selectedArrivalLat != null &&
          selectedArrivalLng != null &&
          _sameSpot(v.lat!, v.lng!, selectedArrivalLat!, selectedArrivalLng!)) {
        return 'Via location ${i + 1} is the same as your arrival location.';
      }
      for (var j = 0; j < i; j++) {
        final o = viaStops[j];
        if (o.lat != null &&
            o.lng != null &&
            _sameSpot(v.lat!, v.lng!, o.lat!, o.lng!)) {
          return 'Via locations ${j + 1} and ${i + 1} are the same place.';
        }
      }
    }

    // Mandatory minimum -- an Intercity travel plan cannot be created without a declared route.
    final resolved = _resolvedViaStops.length;
    if (resolved < minViaStops) {
      final needed = minViaStops - resolved;
      return resolved == 0
          ? 'Add at least $minViaStops via locations to create an Intercity travel plan.'
          : 'Add $needed more via location${needed == 1 ? '' : 's'} — at least $minViaStops are required.';
    }
    return null;
  }

  Widget _buildYourRouteSection() {
    final resolvedCount = _resolvedViaStops.length;
    final needsMore = resolvedCount < minViaStops;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Your Route',
              style: TextStyle(color: textGray, fontSize: 12, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: (needsMore ? Colors.orangeAccent : primaryLime).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                needsMore ? 'REQUIRED' : 'ADDED',
                style: TextStyle(
                  color: needsMore ? Colors.orangeAccent : primaryLime,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Add the main towns and cities on your route, in the order you will pass through them. '
          'This declared route is what we use to match passengers travelling your way — and to '
          'keep out requests that are not actually on your path. At least $minViaStops via stops '
          'are required.',
          style: const TextStyle(color: textGray, fontSize: 11, height: 1.45),
        ),
        const SizedBox(height: 12),
        for (int i = 0; i < viaStops.length; i++) ...[
          _buildViaField(i),
          const SizedBox(height: 10),
        ],
        if (needsMore)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                const Icon(Icons.info_outline_rounded, color: Colors.orangeAccent, size: 14),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    resolvedCount == 0
                        ? 'Add at least $minViaStops via locations to continue.'
                        : 'Add ${minViaStops - resolvedCount} more via location'
                            '${minViaStops - resolvedCount == 1 ? '' : 's'} to continue.',
                    style: const TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (viaStops.length < maxViaStops)
          GestureDetector(
            onTap: _addViaStop,
            child: Container(
              height: 46,
              decoration: BoxDecoration(
                color: darkCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: primaryLime.withValues(alpha: 0.4)),
              ),
              alignment: Alignment.center,
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_rounded, color: primaryLime, size: 18),
                  SizedBox(width: 6),
                  Text(
                    'Add Via Location',
                    style: TextStyle(
                      color: primaryLime,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          Text(
            'Maximum $maxViaStops Via locations.',
            style: const TextStyle(color: textGray, fontSize: 11),
          ),
      ],
    );
  }

  Widget _buildViaField(int index) {
    final via = viaStops[index];
    final selected = via.lat != null && via.lng != null && (via.address?.isNotEmpty ?? false);

    Widget removeButton = IconButton(
      icon: const Icon(Icons.close_rounded, color: textGray, size: 18),
      tooltip: 'Remove',
      onPressed: () => _removeViaStop(index),
    );

    if (selected) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        height: 52,
        decoration: BoxDecoration(
          color: darkBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: primaryLime.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              alignment: Alignment.center,
              child: Text(
                '${index + 1}',
                style: const TextStyle(
                  color: primaryLime,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                via.address ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            removeButton,
          ],
        ),
      );
    }

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: via.controller,
                focusNode: via.focus,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search Via location ${index + 1}...',
                  hintStyle: const TextStyle(color: textGray),
                  filled: true,
                  fillColor: darkBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Colors.white10),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: primaryLime),
                  ),
                  prefixIcon: const Icon(Icons.alt_route_rounded, color: textGray, size: 18),
                  suffixIcon: via.loading
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: primaryLime),
                          ),
                        )
                      : null,
                ),
                onChanged: (val) => _onViaChanged(via, val),
              ),
            ),
            removeButton,
          ],
        ),
        if (via.predictions.isNotEmpty)
          Container(
            constraints: const BoxConstraints(maxHeight: 220),
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: darkCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: via.predictions.map<Widget>((item) {
                  final desc = item['description']?.toString() ?? '';
                  final firstComma = desc.indexOf(',');
                  final mainText = firstComma != -1 ? desc.substring(0, firstComma).trim() : desc;
                  final secondaryText =
                      firstComma != -1 ? desc.substring(firstComma + 1).trim() : '';
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.location_on_outlined, color: primaryLime, size: 16),
                    title: Text(
                      mainText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    subtitle: secondaryText.isNotEmpty
                        ? Text(
                            secondaryText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: textGray, fontSize: 11),
                          )
                        : null,
                    onTap: () => _onViaPredictionTap(via, Map<String, dynamic>.from(item)),
                  );
                }).toList(),
              ),
            ),
          ),
      ],
    );
  }


  Widget _buildLocationField({
    required String label,
    required String hintText,
    required String? selectedAddress,
    required bool isSearching,
    required bool isLoading,
    required TextEditingController controller,
    required FocusNode focusNode,
    required List<dynamic> predictions,
    required Color iconColor,
    required VoidCallback onTap,
    required VoidCallback onClear,
    required Function(String) onChanged,
    required Function(Map<String, dynamic>) onPredictionTap,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: textGray, fontSize: 12, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (isSearching)
          Column(
            children: [
              TextField(
                controller: controller,
                focusNode: focusNode,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: hintText,
                  hintStyle: const TextStyle(color: textGray),
                  filled: true,
                  fillColor: darkBg,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.white10)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: primaryLime)),
                  prefixIcon: const Icon(Icons.search, color: textGray, size: 20),
                  suffixIcon: isLoading
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: primaryLime),
                          ),
                        )
                      : controller.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, color: textGray, size: 18),
                              onPressed: onClear,
                            )
                          : null,
                ),
                onChanged: onChanged,
              ),
              if (predictions.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxHeight: 250),
                  margin: const EdgeInsets.only(top: 4),
                  decoration: BoxDecoration(
                    color: darkCard,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                  ),
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: predictions.map<Widget>((item) {
                        final desc = item['description']?.toString() ?? '';
                        final firstComma = desc.indexOf(',');
                        final String mainText;
                        final String secondaryText;
                        if (firstComma != -1) {
                          mainText = desc.substring(0, firstComma).trim();
                          secondaryText = desc.substring(firstComma + 1).trim();
                        } else {
                          mainText = desc;
                          secondaryText = '';
                        }
                        final cityName = OlaMapService.getCityFromDescription(mainText, secondaryText);

                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.location_on_outlined, color: primaryLime, size: 16),
                          title: Text(
                            mainText, 
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)
                          ),
                          subtitle: secondaryText.isNotEmpty
                              ? Text(
                                  secondaryText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: textGray, fontSize: 11)
                                )
                              : null,
                          trailing: cityName.isNotEmpty
                              ? Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.05),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: Colors.white.withValues(alpha: 0.1),
                                      width: 1.0,
                                    ),
                                  ),
                                  child: Text(
                                    cityName,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: primaryLime,
                                    ),
                                  ),
                                )
                              : null,
                          onTap: () => onPredictionTap(item),
                        );
                      }).toList(),
                    ),
                  ),
                ),
            ],
          )
        else
          GestureDetector(
            onTap: onTap,
            child: Container(
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: darkBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: iconColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.location_on_rounded, color: iconColor, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      selectedAddress ?? hintText,
                      style: TextStyle(
                        color: selectedAddress != null ? Colors.white : textGray,
                        fontSize: 13,
                        fontWeight: selectedAddress != null ? FontWeight.bold : FontWeight.normal,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: textGray, size: 20),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTypeCard({
    required String type,
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    final bool isSelected = travelPlanType == type;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            travelPlanType = type;
          });
        },
        child: Container(
          height: 104,
          decoration: BoxDecoration(
            color: isSelected ? primaryLime.withValues(alpha: 0.05) : darkCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected ? primaryLime : Colors.white.withValues(alpha: 0.05),
              width: 1.5,
            ),
          ),
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      icon,
                      color: isSelected ? primaryLime : textGray,
                      size: 26,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      title,
                      style: TextStyle(
                        color: isSelected ? Colors.white : textGray,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: textGray,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: const BoxDecoration(
                      color: primaryLime,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check,
                      color: Colors.black,
                      size: 11,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _vehicleTitle(String type) {
    switch (type) {
      case 'bike':
        return 'Bike';
      case 'auto':
        return 'Auto';
      case 'cab':
        return 'Cab';
      default:
        return type.isEmpty ? 'Vehicle' : type[0].toUpperCase() + type.substring(1);
    }
  }

  IconData _vehicleIcon(String type) {
    switch (type) {
      case 'bike':
        return Icons.motorcycle_rounded;
      case 'auto':
        return Icons.electric_rickshaw_rounded;
      case 'cab':
        return Icons.local_taxi_rounded;
      default:
        return Icons.directions_car_rounded;
    }
  }

  Widget _buildVehicleCard({
    required String vehicle,
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    final bool isSelected = selectedVehicle == vehicle;
    return Expanded(
      child: GestureDetector(
        onTap: () => updateMaxBookingsDefault(vehicle),
        child: Container(
          height: 94,
          decoration: BoxDecoration(
            color: isSelected ? primaryLime.withValues(alpha: 0.05) : darkCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected ? primaryLime : Colors.white.withValues(alpha: 0.05),
              width: 1.5,
            ),
          ),
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      icon,
                      color: isSelected ? primaryLime : textGray,
                      size: 24,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      title,
                      style: TextStyle(
                        color: isSelected ? Colors.white : textGray,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: textGray,
                        fontSize: 9,
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: const BoxDecoration(
                      color: primaryLime,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check,
                      color: Colors.black,
                      size: 11,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDatePickerBox() {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Travel Date', style: TextStyle(color: textGray, fontSize: 11, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: selectedDate,
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 30)),
                builder: (context, child) {
                  return Theme(
                    data: ThemeData.dark().copyWith(
                      colorScheme: const ColorScheme.dark(
                        primary: primaryLime,
                        onPrimary: Colors.black,
                        surface: darkCard,
                        onSurface: Colors.white,
                      ),
                      dialogBackgroundColor: darkCard,
                    ),
                    child: child!,
                  );
                },
              );
              if (picked != null) {
                setState(() {
                  selectedDate = DateTime(
                    picked.year,
                    picked.month,
                    picked.day,
                    selectedDate.hour,
                    selectedDate.minute,
                  );
                });
              }
            },
            child: Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: darkCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today_rounded, color: primaryLime, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "${selectedDate.day.toString().padLeft(2, '0')}/${selectedDate.month.toString().padLeft(2, '0')}/${selectedDate.year}",
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: textGray, size: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimePickerBox() {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Travel Time', style: TextStyle(color: textGray, fontSize: 11, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: () async {
              final pickedTime = await showTimePicker(
                context: context,
                initialTime: TimeOfDay.fromDateTime(selectedDate),
                builder: (context, child) {
                  return Theme(
                    data: ThemeData.dark().copyWith(
                      colorScheme: const ColorScheme.dark(
                        primary: primaryLime,
                        onPrimary: Colors.black,
                        surface: darkCard,
                        onSurface: Colors.white,
                      ),
                      dialogBackgroundColor: darkCard,
                    ),
                    child: child!,
                  );
                },
              );
              if (pickedTime != null) {
                setState(() {
                  selectedDate = DateTime(
                    selectedDate.year,
                    selectedDate.month,
                    selectedDate.day,
                    pickedTime.hour,
                    pickedTime.minute,
                  );
                });
              }
            },
            child: Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: darkCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.access_time_rounded, color: primaryLime, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      TimeFormatHelper.formatTime12Hour(selectedDate),
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: textGray, size: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: wrongMode
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.tune_rounded, size: 56, color: textGray),
                    const SizedBox(height: 16),
                    const Text(
                      'Switch to Intercity Traveller mode in your Profile to post a travel plan.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: textGray, fontSize: 14, height: 1.5),
                    ),
                  ],
                ),
              ),
            )
          : SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Post Travel Plan',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Earn money by just travelling ',
                    style: TextStyle(
                      fontSize: 13,
                      color: textGray,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Departure Location
              _buildLocationField(
                label: 'From (Departure Location)',
                hintText: 'Search departure location...',
                selectedAddress: selectedDepartureAddress,
                isSearching: isSearchingDeparture,
                isLoading: loadingDepartureSearch,
                controller: departureSearchController,
                focusNode: departureFocus,
                predictions: departurePredictions,
                iconColor: primaryLime,
                onTap: () {
                  setState(() {
                    isSearchingDeparture = true;
                    isSearchingArrival = false;
                  });
                  departureFocus.requestFocus();
                },
                onClear: () {
                  departureSearchController.clear();
                  setState(() {
                    departurePredictions = [];
                    selectedDepartureLat = null;
                    selectedDepartureLng = null;
                    selectedDepartureAddress = null;
                  });
                },
                onChanged: (val) {
                  departureDebounce?.cancel();
                  if (val.trim().isEmpty) {
                    setState(() => departurePredictions = []);
                    return;
                  }
                  departureDebounce = Timer(const Duration(milliseconds: 400), () async {
                    if (!mounted) return;
                    setState(() => loadingDepartureSearch = true);
                    try {
                      final results = await OlaMapService.autocomplete(val);
                      if (!mounted) return;
                      setState(() {
                        departurePredictions = results;
                        loadingDepartureSearch = false;
                      });
                    } catch (e) {
                      if (mounted) setState(() => loadingDepartureSearch = false);
                    }
                  });
                },
                onPredictionTap: (item) async {
                  departureFocus.unfocus();
                  final desc = item['description']?.toString() ?? '';
                  departureSearchController.text = desc;
                  setState(() {
                    departurePredictions = [];
                    loadingDepartureSearch = true;
                  });
                  try {
                    final String? placeId = item['place_id']?.toString();
                    Map<String, dynamic>? coords;
                    if (placeId != null && placeId.isNotEmpty) {
                      coords = await OlaMapService.getCoordinatesFromPlaceId(placeId);
                    }
                    if (coords == null) {
                      coords = await OlaMapService.getCoordinatesFromAddress(desc);
                    }
                    if (coords != null) {
                      if (!mounted) return;
                      setState(() {
                        selectedDepartureLat = coords!['latitude'];
                        selectedDepartureLng = coords!['longitude'];
                        selectedDepartureAddress = desc;
                        selectedDepartureCity = extractCity(coords['city']?.toString(), desc);
                        isSearchingDeparture = false;
                      });
                    }
                  } finally {
                    if (mounted) setState(() => loadingDepartureSearch = false);
                  }
                },
              ),
              const SizedBox(height: 20),

              // Arrival Location
              _buildLocationField(
                label: 'To (Arrival Location)',
                hintText: 'Search arrival location...',
                selectedAddress: selectedArrivalAddress,
                isSearching: isSearchingArrival,
                isLoading: loadingArrivalSearch,
                controller: arrivalSearchController,
                focusNode: arrivalFocus,
                predictions: arrivalPredictions,
                iconColor: Colors.redAccent,
                onTap: () {
                  setState(() {
                    isSearchingArrival = true;
                    isSearchingDeparture = false;
                  });
                  arrivalFocus.requestFocus();
                },
                onClear: () {
                  arrivalSearchController.clear();
                  setState(() {
                    arrivalPredictions = [];
                    selectedArrivalLat = null;
                    selectedArrivalLng = null;
                    selectedArrivalAddress = null;
                  });
                },
                onChanged: (val) {
                  arrivalDebounce?.cancel();
                  if (val.trim().isEmpty) {
                    setState(() => arrivalPredictions = []);
                    return;
                  }
                  arrivalDebounce = Timer(const Duration(milliseconds: 400), () async {
                    if (!mounted) return;
                    setState(() => loadingArrivalSearch = true);
                    try {
                      final results = await OlaMapService.autocomplete(val);
                      if (!mounted) return;
                      setState(() {
                        arrivalPredictions = results;
                        loadingArrivalSearch = false;
                      });
                    } catch (e) {
                      if (mounted) setState(() => loadingArrivalSearch = false);
                    }
                  });
                },
                onPredictionTap: (item) async {
                  arrivalFocus.unfocus();
                  final desc = item['description']?.toString() ?? '';
                  arrivalSearchController.text = desc;
                  setState(() {
                    arrivalPredictions = [];
                    loadingArrivalSearch = true;
                  });
                  try {
                    final String? placeId = item['place_id']?.toString();
                    Map<String, dynamic>? coords;
                    if (placeId != null && placeId.isNotEmpty) {
                      coords = await OlaMapService.getCoordinatesFromPlaceId(placeId);
                    }
                    if (coords == null) {
                      coords = await OlaMapService.getCoordinatesFromAddress(desc);
                    }
                    if (coords != null) {
                      if (!mounted) return;
                      setState(() {
                        selectedArrivalLat = coords!['latitude'];
                        selectedArrivalLng = coords!['longitude'];
                        selectedArrivalAddress = desc;
                        selectedArrivalCity = extractCity(coords['city']?.toString(), desc);
                        isSearchingArrival = false;
                      });
                    }
                  } finally {
                    if (mounted) setState(() => loadingArrivalSearch = false);
                  }
                },
              ),
              const SizedBox(height: 24),

              // Your Route / Via Locations -- only after From and To are both chosen. Optional;
              // when empty the plan is created exactly as a pre-feature direct plan.
              if (selectedDepartureLat != null &&
                  selectedDepartureLng != null &&
                  selectedArrivalLat != null &&
                  selectedArrivalLng != null) ...[
                _buildYourRouteSection(),
                const SizedBox(height: 24),
              ],

              // Travel Plan Type
              const Text('Travel Plan Type', style: TextStyle(color: textGray, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(
                children: [
                  _buildTypeCard(
                    type: 'ride',
                    title: 'Ride Only',
                    subtitle: 'Passenger only',
                    icon: Icons.hail_rounded,
                  ),
                  const SizedBox(width: 8),
                  _buildTypeCard(
                    type: 'parcel',
                    title: 'Parcel Only',
                    subtitle: 'Send parcels',
                    icon: Icons.inventory_2_rounded,
                  ),
                  const SizedBox(width: 8),
                  _buildTypeCard(
                    type: 'both',
                    title: 'Both',
                    subtitle: 'Ride + Parcel',
                    icon: Icons.all_inclusive_rounded,
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Select Verified Vehicle — only vehicles that have actually
              // passed verification are selectable, never free text.
              const Text('Select Verified Vehicle', style: TextStyle(color: textGray, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (loadingVehicles)
                const Center(child: Padding(padding: EdgeInsets.symmetric(vertical: 12), child: CircularProgressIndicator(color: primaryLime, strokeWidth: 2)))
              else if (approvedVehicles.isEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: darkCard,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 20),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'No verified vehicles yet. Add and verify a vehicle to post a travel plan.',
                              style: TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            final added = await Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => AddVehicleScreen(riderId: widget.riderId)),
                            );
                            if (added == true) _loadApprovedVehicles();
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: primaryLime,
                            foregroundColor: Colors.black,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('Add Vehicle', style: TextStyle(fontWeight: FontWeight.w800)),
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
                Row(
                  children: [
                    for (final v in approvedVehicles) ...[
                      _buildVehicleCard(
                        vehicle: v['vehicle_type'].toString(),
                        title: _vehicleTitle(v['vehicle_type'].toString()),
                        subtitle: v['vehicle_number']?.toString() ?? '',
                        icon: _vehicleIcon(v['vehicle_type'].toString()),
                      ),
                      if (v != approvedVehicles.last) const SizedBox(width: 8),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 40,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final added = await Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => AddVehicleScreen(riderId: widget.riderId)),
                      );
                      if (added == true) _loadApprovedVehicles();
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: primaryLime,
                      side: const BorderSide(color: primaryLime, width: 1),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: const Text('Verify Another Vehicle', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5)),
                  ),
                ),
              ],
              const SizedBox(height: 24),

              // Max Bookings (Capacity) Selector
              const Text(
                'Max Bookings (Capacity)',
                style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Row(
                children: seatOptionsFor(selectedVehicle).map((val) {
                  final options = seatOptionsFor(selectedVehicle);
                  final bool isSelected = maxBookings == val;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          maxBookings = val;
                        });
                      },
                      child: Container(
                        margin: EdgeInsets.only(
                          left: val == options.first ? 0 : 4,
                          right: val == options.last ? 0 : 4,
                        ),
                        height: 48,
                        decoration: BoxDecoration(
                          color: isSelected ? primaryLime.withValues(alpha: 0.1) : darkCard,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected ? primaryLime : Colors.white.withValues(alpha: 0.05),
                            width: 1.5,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          val.toString(),
                          style: TextStyle(
                            color: isSelected ? primaryLime : Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),

              // Date and Time pickers side by side
              Row(
                children: [
                  _buildDatePickerBox(),
                  const SizedBox(width: 12),
                  _buildTimePickerBox(),
                ],
              ),
              const SizedBox(height: 24),

              // Max Weight Preference Slider
              if (travelPlanType != 'ride') ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Max Weight Preference',
                      style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '${weightPreference.round()} kg',
                      style: const TextStyle(color: primaryLime, fontSize: 14, fontWeight: FontWeight.w900),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Theme(
                  data: Theme.of(context).copyWith(
                    sliderTheme: SliderThemeData(
                      activeTrackColor: primaryLime,
                      inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
                      thumbColor: primaryLime,
                      overlayColor: primaryLime.withOpacity(0.2),
                      valueIndicatorColor: primaryLime,
                    ),
                  ),
                  child: Slider(
                    value: weightPreference,
                    min: 0,
                    max: 50,
                    divisions: 50,
                    onChanged: (val) {
                      setState(() {
                        weightPreference = val;
                      });
                    },
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('0 kg', style: TextStyle(color: textGray, fontSize: 11)),
                    Text('${weightPreference.round()} kg', style: const TextStyle(color: textGray, fontSize: 11)),
                    const Text('50 kg', style: TextStyle(color: textGray, fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 32),
              ],

              // Submit button
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton.icon(
                  onPressed: submitting ? null : _submitTravelPlan,
                  icon: submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2),
                        )
                      : const Icon(Icons.near_me_rounded, color: Colors.black, size: 20),
                  label: Text(
                    submitting ? 'Posting Plan...' : 'Post Travel Plan',
                    style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 15),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryLime,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    elevation: 0,
                  ),
                ),
              ),
              const SizedBox(height: 36),
            ],
          ),
        ),
      ),
    );
  }
}

/// One traveller-declared Via stop in the ordered route (Origin -> Via 1 -> ... -> Destination).
/// docs/13_Business_Logic.md section 5. Holds its own search controller/focus/debounce plus the
/// resolved location. Position in [_PostTravelPlanScreenState.viaStops] IS the travel order and
/// is never reordered.
class _ViaStop {
  final TextEditingController controller = TextEditingController();
  final FocusNode focus = FocusNode();
  Timer? debounce;
  List<dynamic> predictions = [];
  bool loading = false;
  double? lat;
  double? lng;
  String? address;
  String? city;

  void dispose() {
    debounce?.cancel();
    controller.dispose();
    focus.dispose();
  }
}
