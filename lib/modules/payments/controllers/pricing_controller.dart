import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:convert';

class PricingController extends ChangeNotifier {

  final supabase =
      Supabase.instance.client;

  // =====================================================
  // STATE
  // =====================================================

  bool _loading = false;

  bool get loading => _loading;

  Map<String, dynamic>
      _pricingData = {};

  Map<String, dynamic>
      get pricingData =>
          _pricingData;

  String _error = '';

  String get error => _error;

  // =====================================================
  // IN-FLIGHT REQUEST DEDUPLICATION (P3)
  // =====================================================
  // Per-instance only -- each screen creates its own PricingController (see
  // fetchMultiplePricing() call sites), so this map is never shared across users, screens, or
  // controllers. Keyed by the exact request body a per-vehicle call would send to
  // calculate-order-pricing, so two calls only ever share a request when every fare-affecting
  // input is identical. An entry exists only while its network call is actually in flight and is
  // removed the instant that call resolves (success or failure) -- there is no TTL and nothing
  // is cached after completion, so a retry after a failure always starts a fresh request.
  final Map<String, Future<MapEntry<String, dynamic>?>> _inFlightPricingRequests = {};

  String _dedupKeyFor(Map<String, dynamic> body) {
    final normalized = Map<String, dynamic>.from(body);
    final distance = normalized['distance_km'];
    if (distance is num) {
      // Round to avoid float-precision noise (e.g. 4.9999999 vs 5.0) causing a false cache miss.
      normalized['distance_km'] = distance.toStringAsFixed(2);
    }
    final lat = normalized['pickup_lat'];
    if (lat is num) normalized['pickup_lat'] = lat.toStringAsFixed(5);
    final lng = normalized['pickup_lng'];
    if (lng is num) normalized['pickup_lng'] = lng.toStringAsFixed(5);

    final sortedKeys = normalized.keys.toList()..sort();
    final buffer = StringBuffer();
    for (final k in sortedKeys) {
      buffer.write('$k=${normalized[k]}&');
    }
    return buffer.toString();
  }

  // =====================================================
  // FETCH MULTIPLE PRICING
  // =====================================================

  Future<void> fetchMultiplePricing({
    required String orderType,
    required double distanceKm,
    required String pickupAddress,
    required double maxBoostAmount,
    String? weightCategory,
    double? pickupLat,
    double? pickupLng,
  }) async {
    final stopwatch = Stopwatch()..start();
    _loading = true;
    _error = '';
    _pricingData = {};
    notifyListeners();

    try {
      debugPrint(
        'FETCH PRICING => '
        'Type: $orderType '
        'Distance: $distanceKm '
        'Pickup: $pickupAddress '
        'Weight: $weightCategory '
        'Lat: $pickupLat '
        'Lng: $pickupLng'
      );

      await _fetchPricingFallback(
        orderType: orderType,
        distanceKm: distanceKm,
        pickupAddress: pickupAddress,
        maxBoostAmount: maxBoostAmount,
        weightCategory: weightCategory,
        pickupLat: pickupLat,
        pickupLng: pickupLng,
      );
    } catch (e) {
      // _fetchPricingFallback() already wraps its entire body in its own try/catch and never
      // rethrows (every per-vehicle failure is caught individually and every catch path sets
      // `_error` instead of throwing) -- this branch was calling it a second time with identical
      // arguments, which could only ever duplicate the exact same batch of pricing requests, never
      // recover a genuinely-thrown error. Removed the duplicate call (Remove duplicate pricing
      // requests, production-readiness pass); the failure is already recorded via `_error` by the
      // call above, so this stays a safety log only. Fare calculations are unaffected either way.
      debugPrint('MULTIPLE PRICING ERROR => $e');
    } finally {
      stopwatch.stop();
      final elapsed = stopwatch.elapsedMilliseconds;
      if (elapsed < 500) {
        await Future.delayed(Duration(milliseconds: 500 - elapsed));
      }
      _loading = false;
      notifyListeners();
    }
  }

  // =====================================================
  // FALLBACK PRICING
  // =====================================================

  Future<void> _fetchPricingFallback({
    required String orderType,
    required double distanceKm,
    required String pickupAddress,
    required double maxBoostAmount,
    String? weightCategory,
    double? pickupLat,
    double? pickupLng,
  }) async {
    try {
      List<String> vehicles;
      if (orderType == 'ride' || orderType == 'intercity_ride' || orderType == 'ride_sharing') {
        vehicles = ['bike', 'auto', 'cab'];
      } else if (orderType == 'local_parcel') {
        // Offer every vehicle the parcel's weight is actually eligible for, instead of picking
        // one on the user's behalf -- ParcelBookingScreen renders a selector over whatever this
        // returns and lets the rider choose. Auto has no upper weight bound in this system, so
        // it's always eligible; Bike is excluded once the parcel is too heavy for it.
        double weight = 0.0;
        if (weightCategory != null) {
          weight = double.tryParse(weightCategory) ?? 0.0;
        }
        vehicles = weight > 10.0 ? ['auto'] : ['bike', 'auto'];
      } else {
        double weight = 0.0;
        if (weightCategory != null) {
          weight = double.tryParse(weightCategory) ?? 0.0;
        }
        vehicles = [weight > 10.0 ? 'auto' : 'bike'];
      }

      final Map<String, dynamic> tempPricing = {};

      final futures = vehicles.map(
        (vehicle) async {
          final body = {
            'order_type': orderType,
            'vehicle_type': vehicle,
            'distance_km': distanceKm,
            'pickup_address': pickupAddress,
            'max_boost_amount': maxBoostAmount,
            'weight_category': weightCategory,
            'pickup_lat': pickupLat,
            'pickup_lng': pickupLng,
          };
          final dedupKey = _dedupKeyFor(body);

          final inFlight = _inFlightPricingRequests[dedupKey];
          if (inFlight != null) {
            // An identical request (same vehicle + same fare-affecting inputs) is already
            // running -- await its result instead of firing a second network call. Whichever
            // caller resolves first, both receive the exact same outcome, success or failure.
            return inFlight;
          }

          final requestFuture = _fetchSinglePricing(vehicle, body);
          _inFlightPricingRequests[dedupKey] = requestFuture;
          try {
            return await requestFuture;
          } finally {
            // Clear on completion regardless of outcome so a later call with the same key (e.g.
            // a genuine retry after a failure) starts a fresh request rather than reusing a
            // resolved or failed Future.
            if (identical(_inFlightPricingRequests[dedupKey], requestFuture)) {
              _inFlightPricingRequests.remove(dedupKey);
            }
          }
        },
      );

      final results =
          await Future.wait(
        futures,
      );

      for (final result
          in results) {

        if (result != null) {

          tempPricing[
              result.key] =
              result.value;
        }
      }

      // -----------------------------------------------
      // SAVE
      // -----------------------------------------------

      if (
          tempPricing.isNotEmpty) {

        _pricingData =
            tempPricing;

      } else {

        _error =
            'Unable to fetch pricing';
      }

    } catch (e) {

      _error =
          'Pricing service failure';

      debugPrint(
        'PRICING FALLBACK GENERAL ERROR => $e',
      );
    }

    notifyListeners();
  }

  // =====================================================
  // SINGLE VEHICLE PRICING REQUEST
  // (extracted from _fetchPricingFallback so it can be shared by the in-flight dedup map above)
  // =====================================================

  Future<MapEntry<String, dynamic>?> _fetchSinglePricing(
    String vehicle,
    Map<String, dynamic> body,
  ) async {
    try {
      final response = await supabase.functions.invoke(
        'calculate-order-pricing',
        body: body,
        // WayDrop Progressive Degradation Audit, finding CLIENT-1: this call had no bound,
        // so a stalled request left this vehicle's fetchMultiplePricing() future waiting
        // forever (the direct cause of "price calculation sometimes never returns"). The
        // surrounding try/catch already treats any failure here as "this vehicle's pricing
        // unavailable" and continues with the others, so a timeout is handled identically
        // to any other per-vehicle error — no behavior change beyond bounding the wait.
      ).timeout(const Duration(seconds: 15));

      dynamic decodedData = response.data;
      debugPrint('PRICING RAW RESPONSE [$vehicle] => Status: ${response.status}, Data: ${response.data}');
      if (decodedData is String) {
        try {
          decodedData = jsonDecode(decodedData);
        } catch (e) {
          debugPrint('PRICING DECODE ERROR [$vehicle] => $e');
        }
      }

      if (decodedData is Map && decodedData['pricing'] != null) {
        final pricing = decodedData['pricing'] as Map<String, dynamic>;
        debugPrint(
          '=== PRICING LOG [$vehicle] ===\n'
          '  Order Type:   ${pricing['order_type']}\n'
          '  Vehicle:      ${pricing['vehicle_type']}\n'
          '  Pricing Code: ${pricing['pricing_code']}\n'
          '  Config ID:    ${pricing['config_id']}\n'
          '  Distance:     ${pricing['distance_km']} km\n'
          '  Base Fare:    ₹${pricing['base_fare']}\n'
          '  Surge Boost:  ₹${pricing['boost_amount']}\n'
          '  Weight Chg:   ₹${pricing['weight_charge'] ?? 0.0}\n'
          '  Subtotal:     ₹${pricing['subtotal']}\n'
          '  Commission:   ₹${pricing['commission_amount']} (${pricing['commission_percent']}%)\n'
          '  GST:          ₹${pricing['gst_amount']} (${pricing['gst_percentage']}%)\n'
          '  Rider Earn:   ₹${pricing['rider_earning']}\n'
          '  Final Fare:   ₹${pricing['final_fare']}\n'
          '=============================='
        );
        return MapEntry(
          vehicle,
          pricing,
        );
      } else {
        debugPrint('PRICING WARNING [$vehicle] => Missing or invalid pricing object in data structure: $decodedData');
      }
    } catch (e) {
      debugPrint(
        'FALLBACK ERROR [$vehicle] => $e',
      );
    }

    return null;
  }

  // =====================================================
  // GET PRICING BY VEHICLE
  // =====================================================

  Map<String, dynamic>?
      getVehiclePricing(
    String vehicle,
  ) {

    if (
      !_pricingData.containsKey(
        vehicle,
      )
    ) {

      return null;
    }

    return _pricingData[
        vehicle];
  }

  // =====================================================
  // GET FINAL FARE
  // BACKEND ALREADY INCLUDES BOOST
  // NEVER ADD AGAIN
  // =====================================================

  double _parsePrice(dynamic val) {
    if (val == null) return 0.0;
    if (val is num) return val.toDouble();
    return double.tryParse(val.toString()) ?? 0.0;
  }

  double getFinalFare(
    String vehicle,
  ) {
    return _parsePrice(getVehiclePricing(vehicle)?['final_fare']);
  }

  double getBaseFare(
    String vehicle,
  ) {
    return _parsePrice(getVehiclePricing(vehicle)?['base_fare']);
  }

  double getBoostAmount(
    String vehicle,
  ) {
    return _parsePrice(getVehiclePricing(vehicle)?['boost_amount']);
  }

  String getCityTier(
    String vehicle,
  ) {

    final pricing =
        getVehiclePricing(
      vehicle,
    );

    if (pricing == null) {

      return 'tier_2';
    }

    return pricing[
            'city_tier']
        ?.toString() ??

        'tier_2';
  }

  double getCommissionPercent(String vehicle) {
    final pricing = getVehiclePricing(vehicle);
    if (pricing == null) return 10.0;
    return _parsePrice(pricing['commission_percent'] ?? 10.0);
  }

  double getCommissionAmount(String vehicle) {
    return _parsePrice(getVehiclePricing(vehicle)?['commission_amount']);
  }

  double getGstPercentage(String vehicle) {
    final pricing = getVehiclePricing(vehicle);
    if (pricing == null) return 5.0;
    return _parsePrice(pricing['gst_percentage'] ?? 5.0);
  }

  double getGstAmount(String vehicle) {
    return _parsePrice(getVehiclePricing(vehicle)?['gst_amount']);
  }

  double getRiderEarning(String vehicle) {
    return _parsePrice(getVehiclePricing(vehicle)?['rider_earning']);
  }

  double getSubtotal(String vehicle) {
    return _parsePrice(getVehiclePricing(vehicle)?['subtotal']);
  }

  double getCancellationFee(String vehicle) {
    return _parsePrice(getVehiclePricing(vehicle)?['cancellation_fee']);
  }

  double getWaitingChargePerMin(String vehicle) {
    return _parsePrice(getVehiclePricing(vehicle)?['waiting_charge_per_min']);
  }

  // =====================================================
  // GET SUBSCRIPTION COMMISSION WAIVER
  // =====================================================
  bool getSubscriptionCommissionWaiver(String vehicle) {
    final pricing = getVehiclePricing(vehicle);
    if (pricing == null) return true;
    return pricing['subscription_commission_waiver'] ?? true;
  }

  // =====================================================
  // GET PRICING CODE
  // =====================================================
  String? getPricingCode(String vehicle) {
    final pricing = getVehiclePricing(vehicle);
    return pricing?['pricing_code']?.toString();
  }

  // =====================================================
  // GET CONFIG ID
  // =====================================================
  String? getConfigId(String vehicle) {
    final pricing = getVehiclePricing(vehicle);
    return pricing?['config_id']?.toString();
  }

  // =====================================================
  // RESET
  // =====================================================

  void reset() {

    _loading = false;

    _pricingData = {};

    _error = '';

    notifyListeners();
  }
}