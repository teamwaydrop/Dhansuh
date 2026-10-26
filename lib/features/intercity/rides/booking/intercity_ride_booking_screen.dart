import 'package:waydrop/core/services/diagnostics/ride_diagnostics.dart';
import 'package:waydrop/core/services/diagnostics/ride_diagnostics_owner.dart';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/cupertino.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:waydrop/shared/helpers/time_format_helper.dart';
import 'package:waydrop/core/services/maps/ola_map_service.dart';
import 'package:waydrop/features/intercity/shared/screens/intercity_searching_screen.dart';
import 'package:waydrop/modules/payments/controllers/pricing_controller.dart';
import 'package:waydrop/shared/widgets/states/vehicle_pricing_skeleton_card.dart';
import 'package:waydrop/shared/widgets/states/app_loading_overlay.dart';
import 'package:waydrop/shared/helpers/location_display_service.dart';
import 'package:waydrop/shared/helpers/device_info_helper.dart';

class IntercityRideBookingScreen extends StatefulWidget {
  final String pickupAddress;
  final String destinationAddress;
  final double pickupLat;
  final double pickupLng;
  final double destinationLat;
  final double destinationLng;
  final double totalDistanceMeters;
  final double durationSeconds;
  final List<Map<String, dynamic>> routePoints;
  final String? pickupCity;
  final String? destinationCity;

  const IntercityRideBookingScreen({
    super.key,
    required this.pickupAddress,
    required this.destinationAddress,
    required this.pickupLat,
    required this.pickupLng,
    required this.destinationLat,
    required this.destinationLng,
    required this.totalDistanceMeters,
    required this.durationSeconds,
    required this.routePoints,
    this.pickupCity,
    this.destinationCity,
  });

  @override
  State<IntercityRideBookingScreen> createState() =>
      _IntercityRideBookingScreenState();
}

class _IntercityRideBookingScreenState
    extends State<IntercityRideBookingScreen> {
  late PricingController pricingController;
  late final WebViewController webController;
  bool mapLoaded = false;

  String? selectedVehicle;
  String paymentMode = 'cash';

  double selectedBoostAmount = 0;
  bool creatingOrder = false;
  bool waitingForPayment = false;
  DateTime _selectedTravelDate = DateTime.now().add(const Duration(days: 1));

  /// Number of passenger seats this Travel Request is for. The fare shown
  /// (and the fare charged server-side, see create-order) scales with this.
  int passengerCount = 1;
  static const int _maxPassengerCount = 4;

  final supabase = Supabase.instance.client;

  late double distanceKm;
  late double durationMin;

  // Lets widgets shown inside a showModalBottomSheet rebuild correctly —
  // setState() on this State does not rebuild the sheet's own subtree.
  StateSetter? _activeModalSetState;

  // Promo code state
  bool showPromoField = false;
  final TextEditingController _promoController = TextEditingController();
  String? _appliedPromoCode;
  double _promoDiscount = 0.0;
  bool _isValidatingPromo = false;

  void _setState(VoidCallback fn) {
    setState(fn);
    _activeModalSetState?.call(() {});
  }

  Future<void> _applyPromo() async {
    final code = _promoController.text.trim();
    if (code.isEmpty) return;
    if (selectedVehicle == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please wait for the fare to load.')),
      );
      return;
    }

    _setState(() {
      _isValidatingPromo = true;
    });

    try {
      final currentFare = estimatedFare;
      final user = supabase.auth.currentUser;

      if (user == null) {
        throw Exception("User session not found");
      }

      final response = await supabase.rpc(
        'validate_and_calculate_promo',
        params: {
          'p_code': code,
          'p_order_value': currentFare,
          'p_user_id': user.id,
        },
      );

      if (response == null) {
        throw Exception("Failed to validate promo code");
      }

      final Map<String, dynamic> result = Map<String, dynamic>.from(response as Map);

      if (result['success'] == true) {
        _setState(() {
          _appliedPromoCode = code.toUpperCase();
          _promoDiscount = (result['discount_amount'] ?? 0.0).toDouble();
          showPromoField = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Promo code "$_appliedPromoCode" applied! Discount: ₹${_promoDiscount.toStringAsFixed(2)}'),
              backgroundColor: const Color(0xFF10B981),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } else {
        throw Exception(result['message'] ?? "Invalid promo code");
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceAll("Exception: ", "")),
            backgroundColor: const Color(0xFFEF4444),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        _setState(() {
          _isValidatingPromo = false;
        });
      }
    }
  }

  late final RideDiagnosticOwner _rideDiagnosticOwner;

  @override
  void initState() {
    super.initState();
    _rideDiagnosticOwner = RideDiagnosticOwner.widget(() => mounted, surface: RideSurface.booking);
    debugPrint('[RUNTIME_TRACE] ENTER IntercityRideBookingScreen (intercity_ride_booking_screen.dart)');
    pricingController = PricingController();
    distanceKm = widget.totalDistanceMeters / 1000;
    durationMin = widget.durationSeconds / 60;
    _initWebView();
    _fetchPricing();
  }

  @override
  void dispose() {
    _rideDiagnosticOwner.dispose();
    _promoController.dispose();

    // Phase 2F-C1 -- explicit WebView teardown, mirroring the Phase 2F-B pattern (c1ccf56).
    // This screen's webController loads ola_map_booking.html (which pulls in ola_map_core.js, so
    // destroyMap / destroyNearbyRidersEngine are defined). That page tears the map down only on
    // the document 'unload' event, which does not reliably fire when Flutter disposes the platform
    // WebView without a navigation -- leaking the MapLibre GL context and, if any nearby riders
    // were plotted, the AnimationManager RAF loop. All helpers are `typeof`-guarded and idempotent;
    // the call is wrapped in try/catch on the JS side and .catchError on the Dart side, and is
    // fire-and-forget because dispose() cannot await. The outer try/catch covers the
    // `late final webController` never being assigned (e.g. WebViewController() unsupported on
    // desktop), which would otherwise throw LateInitializationError here.
    try {
      webController
          .runJavaScript(
            'try { '
            'if (typeof destroyNearbyRidersEngine === "function") { destroyNearbyRidersEngine(); } '
            'if (typeof destroyTrackingEngine === "function") { destroyTrackingEngine(); } '
            'if (typeof destroyMap === "function") { destroyMap(); } '
            '} catch (e) {}',
          )
          .catchError((_) {});
    } catch (_) {}

    super.dispose();
  }

  Future<void> _initWebView() async {
    webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..enableZoom(true)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) async {
            setState(() => mapLoaded = true);
            await _injectMap();
            await _updateMapRoute();
          },
        ),
      );
    await webController.loadFlutterAsset('assets/map/ola_map_booking.html');
  }

  Future<void> _injectMap() async {
    final apiKey = OlaMapService.apiKey;
    final safeApiKey = apiKey.replaceAll('"', '');
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeMode = isDark ? 'dark' : 'light';
    await webController.runJavaScript(
      'if(window.initializeMap){ window.initializeMap("$safeApiKey", "$themeMode"); }',
    );
  }

  Future<void> _updateMapRoute() async {
    try {
      await webController.runJavaScript(
        'if(window.clearMarkers){ window.clearMarkers(); }',
      );
      await webController.runJavaScript(
        'if(window.addPickupMarker){ window.addPickupMarker(${widget.pickupLat}, ${widget.pickupLng}); }',
      );
      await webController.runJavaScript(
        'if(window.addDestinationMarker){ window.addDestinationMarker(${widget.destinationLat}, ${widget.destinationLng}); }',
      );
      final polylineJson = jsonEncode(widget.routePoints);
      await webController.runJavaScript(
        'if(window.drawRoute){ window.drawRoute($polylineJson); }',
      );
      await webController.runJavaScript(
        'if(window.fitRouteBounds){ window.fitRouteBounds(); }',
      );
    } catch (e) {
      debugPrint('MAP UPDATE ROUTE ERROR => $e');
    }
  }

  Future<void> _fetchPricing() async {
    await pricingController.fetchMultiplePricing(
      orderType: 'intercity_ride',
      distanceKm: distanceKm,
      pickupAddress: widget.pickupAddress,
      maxBoostAmount: selectedBoostAmount,
      pickupLat: widget.pickupLat,
      pickupLng: widget.pickupLng,
    );

    if (mounted) {
      // Marks the fare as loaded and ready to submit. This Travel Request
      // has no vehicle preference — it must match travellers across
      // bike/auto/cab alike (all three price identically, see
      // PricingController.fetchMultiplePricing), so 'any' is sent verbatim
      // to create-order/calculate-order-pricing/match-intercity-riders.
      setState(() => selectedVehicle = 'any');
    }
  }

  /// Every vehicle's fare is identical for intercity_ride (₹/km rate is the
  /// same across bike/auto/cab in pricing_config) — 'cab' is just a
  /// representative pick. Scales by passengerCount because each requested
  /// seat is billed at the full per-km rate (mirrors how
  /// rider_travel_plans.price_per_seat is computed, and how create-order
  /// scales fare fields for intercity_ride orders with seats_requested > 1).
  double get estimatedFare => pricingController.getFinalFare('cab') * passengerCount;
  double get estimatedBaseFare => pricingController.getBaseFare('cab') * passengerCount;
  double get estimatedGstAmount => pricingController.getGstAmount('cab') * passengerCount;

  String extractCity(String? city, String address) {
    return LocationDisplayService.resolveCity(
      city: city,
      address: address,
      fallback: 'Other',
    );
  }

  Future<void> _submitOrderToBackend({String? paymentId, RideAttempt? diagnosticAttempt}) async {
    final deviceMeta = await DeviceInfoHelper.getDeviceMetadata();
    final user = supabase.auth.currentUser;
    final response = await _rideDiagnosticOwner.api(RideEndpoint.booking, null, () => supabase.functions.invoke(
      'create-order',
      body: {
        'user_id': user?.id,
        'order_type': 'intercity_ride',
        'vehicle_type': selectedVehicle,
        'pickup_address': widget.pickupAddress,
        'pickup_lat': widget.pickupLat,
        'pickup_lng': widget.pickupLng,
        'destination_address': widget.destinationAddress,
        'destination_lat': widget.destinationLat,
        'destination_lng': widget.destinationLng,
        'distance_km': distanceKm,
        'distance_meters': (distanceKm * 1000).round(),
        'duration_seconds': (durationMin * 60).round(),
        'payment_mode': paymentMode,
        'payment_id': paymentId,
        'pickup_city': extractCity(widget.pickupCity, widget.pickupAddress),
        'destination_city': extractCity(
          widget.destinationCity,
          widget.destinationAddress,
        ),
        'max_boost_amount': selectedBoostAmount,
        'travel_date': _selectedTravelDate.toUtc().toIso8601String(),
        'promo_code': _appliedPromoCode,
        'seats_requested': passengerCount,
        // Device snapshot
        'created_device_id': deviceMeta['device_id'],
        'device_model': deviceMeta['device_model'],
        'device_brand': deviceMeta['device_brand'],
        'os_version': deviceMeta['os_version'],
        'app_version': deviceMeta['app_version'],
      },
      // CLIENT-1 (WayDrop Progressive Degradation Audit): bounded so a stalled backend surfaces
      // as the same caught exception _createOrder already handles, not an infinite wait.
    ).timeout(const Duration(seconds: 30)), attempt: diagnosticAttempt);

    debugPrint('CREATE ORDER RESPONSE => ${response.data}');

    if (response.data == null || response.data['success'] != true) {
      final errorMsg =
          response.data?['error'] ??
          'Unknown error occurred while creating order';
      throw Exception(errorMsg);
    }

    final order = response.data['order'];
    if (order == null || order['id'] == null) {
      throw Exception('Failed to retrieve order ID from response');
    }

    // No Travel Plan is pre-selected — create-order already triggers
    // match-intercity-riders in the background for every intercity_ride
    // order (is_background: true), which finds matching Travel Plans and
    // creates the intercity_requests rows (+ traveller notification) for
    // us. See supabase/functions/create-order/index.ts.
    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => IntercitySearchingScreen(orderId: order['id']),
      ),
    );
  }

  Future<void> _createOrder() async {
    final diagnosticAttempt = _rideDiagnosticOwner.begin(endpoint: RideEndpoint.booking);
    if (selectedVehicle == null) return;

    if (_selectedTravelDate.isBefore(DateTime.now())) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a departure date and time in the future!'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // Both 'cash' and 'upi' are collected directly by the driver at trip
    // completion — no payment gateway involved at booking time.
    try {
      setState(() => creatingOrder = true);
      await _submitOrderToBackend(diagnosticAttempt: diagnosticAttempt);
    } catch (e, stackTrace) {
      // Phase 5 F2: non-fatal Crashlytics report, purely additive -- does not affect the
      // existing SnackBar/finally behavior below.
      FirebaseCrashlytics.instance.recordError(
        e,
        stackTrace,
        reason: 'create-order (intercity ride) failed',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) {
        setState(() {
          creatingOrder = false;
          waitingForPayment = false;
        });
      }
    }
  }

  void _selectDateCupertino(BuildContext context, Color primaryColor, Color textCol, Color subTextCol, Color borderCol) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF131929) : Colors.white,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (context) {
        DateTime tempPickedDate = _selectedTravelDate;
        return Container(
          height: 380,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: subTextCol.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Select Departure Date',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: textCol,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: CupertinoTheme(
                  data: CupertinoThemeData(
                    textTheme: CupertinoTextThemeData(
                      dateTimePickerTextStyle: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        color: textCol,
                      ),
                    ),
                  ),
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.date,
                    initialDateTime: tempPickedDate,
                    minimumDate: DateTime.now(),
                    maximumDate: DateTime.now().add(const Duration(days: 30)),
                    onDateTimeChanged: (DateTime date) {
                      tempPickedDate = date;
                    },
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(27),
                    ),
                  ),
                  onPressed: () {
                    setState(() {
                      _selectedTravelDate = DateTime(
                        tempPickedDate.year,
                        tempPickedDate.month,
                        tempPickedDate.day,
                        _selectedTravelDate.hour,
                        _selectedTravelDate.minute,
                      );
                    });
                    Navigator.pop(context);
                  },
                  child: const Text(
                    'Confirm Date',
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _selectTimeCupertino(BuildContext context, Color primaryColor, Color textCol, Color subTextCol, Color borderCol) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF131929) : Colors.white,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (context) {
        DateTime tempPickedTime = _selectedTravelDate;
        return Container(
          height: 380,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: subTextCol.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Select Departure Time',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: textCol,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: CupertinoTheme(
                  data: CupertinoThemeData(
                    textTheme: CupertinoTextThemeData(
                      dateTimePickerTextStyle: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        color: textCol,
                      ),
                    ),
                  ),
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.time,
                    initialDateTime: tempPickedTime,
                    onDateTimeChanged: (DateTime date) {
                      tempPickedTime = date;
                    },
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(27),
                    ),
                  ),
                  onPressed: () {
                    setState(() {
                      _selectedTravelDate = DateTime(
                        _selectedTravelDate.year,
                        _selectedTravelDate.month,
                        _selectedTravelDate.day,
                        tempPickedTime.hour,
                        tempPickedTime.minute,
                      );
                    });
                    Navigator.pop(context);
                  },
                  child: const Text(
                    'Confirm Time',
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  // =====================================================
  // WIDGETS
  // =====================================================

  /// Payment + promo panel — compact single-row chips + promo
  Widget _buildPaymentPanel() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF131929) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPaymentChipVertical(
            icon: Icons.payments_rounded,
            label: 'Pay via Cash',
            value: 'cash',
            accentColor: const Color(0xFF10B981),
            bgColor: isDark
                ? const Color(0xFF10B981).withValues(alpha: 0.15)
                : const Color(0xFFECFDF5),
          ),
          const SizedBox(height: 8),
          _buildPaymentChipVertical(
            icon: Icons.qr_code_rounded,
            label: 'Pay via UPI',
            value: 'online',
            accentColor: const Color(0xFF10B981),
            bgColor: isDark
                ? const Color(0xFF10B981).withValues(alpha: 0.15)
                : const Color(0xFFECFDF5),
          ),
          const SizedBox(height: 10),
          Divider(
            height: 1,
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => _setState(() => showPromoField = !showPromoField),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF1E293B)
                        : const Color(0xFFFFFBEB),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.card_giftcard_rounded,
                    size: 14,
                    color: isDark
                        ? const Color(0xFF10B981)
                        : const Color(0xFFD97706),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'Apply Promo Code',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : const Color(0xFF1E293B),
                  ),
                ),
                const Spacer(),
                AnimatedRotation(
                  turns: showPromoField ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
          if (_appliedPromoCode != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF10B981).withValues(alpha: 0.12) : const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.check_circle_rounded, size: 14, color: const Color(0xFF10B981)),
                  const SizedBox(width: 8),
                  Text(
                    '$_appliedPromoCode Applied',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
                  ),
                  const Spacer(),
                  Text(
                    '- ₹${_promoDiscount.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      _setState(() {
                        _appliedPromoCode = null;
                        _promoDiscount = 0.0;
                        _promoController.clear();
                      });
                    },
                    child: Icon(Icons.cancel_rounded, size: 16, color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8)),
                  ),
                ],
              ),
            ),
          ],
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            child: showPromoField
                ? Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _promoController,
                            autofocus: true,
                            textCapitalization: TextCapitalization.characters,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2,
                              color: isDark
                                  ? Colors.white
                                  : const Color(0xFF1E293B),
                            ),
                            decoration: InputDecoration(
                              hintText: 'Enter promo code...',
                              hintStyle: TextStyle(
                                color: isDark
                                    ? const Color(0xFF64748B)
                                    : const Color(0xFFCBD5E1),
                                fontWeight: FontWeight.normal,
                                letterSpacing: 0,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 9,
                              ),
                              isDense: true,
                              filled: true,
                              fillColor: isDark
                                  ? const Color(0xFF090D1A)
                                  : Colors.white,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(
                                  color: isDark
                                      ? const Color(0xFF1E293B)
                                      : const Color(0xFFE2E8F0),
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: const BorderSide(
                                  color: Color(0xFF10B981),
                                  width: 1.5,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(
                                  color: isDark
                                      ? const Color(0xFF1E293B)
                                      : const Color(0xFFE2E8F0),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: _applyPromo,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 9,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF10B981),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: _isValidatingPromo
                                ? const SizedBox(height: 14, width: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.0))
                                : const Text(
                                    'Apply',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentChipVertical({
    required IconData icon,
    required String label,
    required String value,
    required Color accentColor,
    required Color bgColor,
  }) {
    final selected = paymentMode == value;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () => _setState(() => paymentMode = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? bgColor
              : (isDark ? const Color(0xFF090D1A) : Colors.white),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? accentColor.withValues(alpha: 0.6)
                : (isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
            width: selected ? 1.5 : 1.0,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: accentColor.withValues(alpha: 0.05),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ]
              : [],
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: selected
                  ? accentColor
                  : (isDark
                        ? const Color(0xFF64748B)
                        : const Color(0xFF94A3B8)),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selected
                      ? (isDark ? Colors.white : accentColor)
                      : (isDark
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF475569)),
                ),
              ),
            ),
            const SizedBox(width: 6),
            if (selected)
              Icon(Icons.check_circle_rounded, size: 16, color: accentColor)
            else
              Container(
                height: 16,
                width: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isDark
                        ? const Color(0xFF1E293B)
                        : const Color(0xFFCBD5E1),
                    width: 1.5,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFareBreakupCard({
    required double baseFare,
    required double gstAmount,
    required double totalFare,
    required String label,
    double gstPercentage = 5.0,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final cardBg = isDark ? const Color(0xFF131929) : Colors.white;
    final textCol = isDark ? Colors.white : const Color(0xFF0F172A);
    final subTextCol = isDark
        ? const Color(0xFF94A3B8)
        : const Color(0xFF64748B);
    final borderCol = isDark
        ? const Color(0xFF1E293B)
        : const Color(0xFFE2E8F0);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: borderCol, width: 1.0),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'FARE BREAKDOWN',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: subTextCol,
                  letterSpacing: 0.8,
                ),
              ),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: subTextCol,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Fare before GST',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white70 : const Color(0xFF475569),
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                '₹${baseFare.toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 12,
                  color: textCol,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'GST (${gstPercentage.toStringAsFixed(0)}%)',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white70 : const Color(0xFF475569),
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                '₹${gstAmount.toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 12,
                  color: textCol,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1, thickness: 0.5),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Estimated Total',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: textCol,
                ),
              ),
              Text(
                '₹${totalFare.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF10B981),
                ),
              ),
            ],
          ),
          if (gstAmount > 0) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: const [
                Icon(Icons.check_circle_rounded, size: 12, color: Color(0xFF10B981)),
                SizedBox(width: 4),
                Text(
                  'Inclusive of GST',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF10B981)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Opens the payment + confirm sheet for this Travel Request. No Travel
  /// Plan is picked here — the passenger is booking N seats on this route
  /// at the estimated fare; matching travellers are found afterwards (see
  /// _submitOrderToBackend / IntercitySearchingScreen).
  void _openConfirmRequestSheet() {
    setState(() {
      _appliedPromoCode = null;
      _promoDiscount = 0.0;
      _promoController.clear();
    });

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final isDark = Theme.of(sheetContext).brightness == Brightness.dark;
        return StatefulBuilder(
          builder: (ctx, modalSetState) {
            _activeModalSetState = modalSetState;
            return Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF090D1A) : const Color(0xFFF8FAFC),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              ),
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 38,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.grey.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Confirm Travel Request',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                          color: isDark ? Colors.white : const Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildFareBreakupCard(
                        baseFare: estimatedBaseFare,
                        gstAmount: estimatedGstAmount,
                        totalFare: estimatedFare,
                        label: '$passengerCount Passenger${passengerCount == 1 ? '' : 's'} • Intercity Ride',
                        gstPercentage: pricingController.getGstPercentage('cab'),
                      ),
                      const SizedBox(height: 12),
                      _buildPaymentPanel(),
                      const SizedBox(height: 20),
                      SizedBox(
                        height: 52,
                        child: ElevatedButton(
                          onPressed: (creatingOrder || waitingForPayment)
                              ? null
                              : () {
                                  Navigator.pop(ctx);
                                  _activeModalSetState = null;
                                  _createOrder();
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          child: (creatingOrder || waitingForPayment)
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                                )
                              : const Text(
                                  'Confirm Travel Request',
                                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      _activeModalSetState = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Block ALL back navigation while payment is in-flight or order is being created.
    final bool isLocked = waitingForPayment || creatingOrder;

    return PopScope(
      canPop: !isLocked,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && isLocked) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please wait — payment is being processed.'),
              backgroundColor: Color(0xFFEF4444),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      child: Scaffold(
        backgroundColor: isDark
            ? const Color(0xFF090D1A)
            : const Color(0xFFF8FAFC),
        appBar: AppBar(
          backgroundColor: isDark ? const Color(0xFF131929) : Colors.white,
          elevation: 0,
          centerTitle: true,
          leading: IconButton(
            icon: Icon(
              Icons.arrow_back_ios_new_rounded,
              color: isDark ? Colors.white : const Color(0xFF0F172A),
              size: 18,
            ),
            onPressed: isLocked ? null : () => Navigator.pop(context),
          ),
          title: Text(
            'Intercity Travel Request',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: isDark ? Colors.white : const Color(0xFF0F172A),
              letterSpacing: -0.3,
            ),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1.0),
            child: Container(
              color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
              height: 1.0,
            ),
          ),
        ),
        body: Stack(
          children: [
            SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 1. Framed Map Card
                  Container(
                    margin: const EdgeInsets.all(16),
                    height: 220,
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF131929) : Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                        width: 1.0,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.06),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAliasWithSaveLayer,
                    child: Stack(
                      children: [
                        WebViewWidget(
                          controller: webController,
                          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
                            Factory<OneSequenceGestureRecognizer>(
                              () => EagerGestureRecognizer(),
                            ),
                          },
                        ),
                        Positioned(
                          bottom: 12,
                          right: 12,
                          child: _buildMapCtrlBtn(
                            icon: Icons.my_location_rounded,
                            onTap: () {
                              if (mapLoaded) {
                                webController.runJavaScript(
                                  'if(window.recenterToPickup){ window.recenterToPickup(); }',
                                );
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),

                  // 2. Address & Route summary details
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF131929) : Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                          width: 1.0,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.04),
                            blurRadius: 10,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'ROUTE DETAILS',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w800,
                                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                        letterSpacing: 0.8,
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF10B981).withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        '${distanceKm.toStringAsFixed(1)} km • ${durationMin.toStringAsFixed(0)} mins',
                                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF10B981)),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      margin: const EdgeInsets.only(top: 3),
                                      height: 10,
                                      width: 10,
                                      decoration: const BoxDecoration(color: Color(0xFF10B981), shape: BoxShape.circle),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Pickup Location',
                                            style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            widget.pickupAddress,
                                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: isDark ? Colors.white : const Color(0xFF1E293B)),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Container(
                                    margin: const EdgeInsets.only(left: 4, top: 4, bottom: 4),
                                    width: 1.5,
                                    height: 16,
                                    color: isDark ? const Color(0xFF1E293B) : const Color(0xFFCBD5E1),
                                  ),
                                ),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      margin: const EdgeInsets.only(top: 3),
                                      height: 10,
                                      width: 10,
                                      decoration: const BoxDecoration(color: Color(0xFFEF4444), shape: BoxShape.circle),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Drop Location',
                                            style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            widget.destinationAddress,
                                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: isDark ? Colors.white : const Color(0xFF1E293B)),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Container(
                            height: 32,
                            width: 32,
                            decoration: const BoxDecoration(color: Color(0xFF10B981), shape: BoxShape.circle),
                            child: const Icon(Icons.edit_rounded, color: Colors.white, size: 16),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // 3. Travel Date & Time Selection — drives which Travel Plans we search for
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF131929) : Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                        width: 1.0,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.04),
                          blurRadius: 10,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'TRAVEL DATE',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                            letterSpacing: 0.8,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                onTap: () => _selectDateCupertino(
                                  context,
                                  const Color(0xFF10B981),
                                  isDark ? Colors.white : const Color(0xFF1E293B),
                                  isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                  isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                                ),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                  decoration: BoxDecoration(
                                    color: isDark ? const Color(0xFF090D1A) : const Color(0xFFF8FAFC),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.calendar_today_rounded, color: Color(0xFF10B981), size: 14),
                                      const SizedBox(width: 8),
                                      Text(
                                        "${_selectedTravelDate.day.toString().padLeft(2, '0')}/${_selectedTravelDate.month.toString().padLeft(2, '0')}/${_selectedTravelDate.year}",
                                        style: TextStyle(color: isDark ? Colors.white : const Color(0xFF1E293B), fontSize: 12, fontWeight: FontWeight.bold),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: GestureDetector(
                                onTap: () => _selectTimeCupertino(
                                  context,
                                  const Color(0xFF10B981),
                                  isDark ? Colors.white : const Color(0xFF1E293B),
                                  isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                  isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                                ),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                  decoration: BoxDecoration(
                                    color: isDark ? const Color(0xFF090D1A) : const Color(0xFFF8FAFC),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.access_time_rounded, color: Color(0xFF10B981), size: 14),
                                      const SizedBox(width: 8),
                                      Text(
                                        TimeFormatHelper.formatTime12Hour(_selectedTravelDate),
                                        style: TextStyle(color: isDark ? Colors.white : const Color(0xFF1E293B), fontSize: 12, fontWeight: FontWeight.bold),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // 4. Passenger count — drives how many seats this Travel
                  // Request books and how the fare estimate scales.
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF131929) : Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                        width: 1.0,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'NUMBER OF PASSENGERS',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                            letterSpacing: 0.8,
                          ),
                        ),
                        Row(
                          children: [
                            _buildStepperBtn(
                              icon: Icons.remove_rounded,
                              onTap: passengerCount > 1
                                  ? () => setState(() => passengerCount--)
                                  : null,
                            ),
                            SizedBox(
                              width: 32,
                              child: Text(
                                '$passengerCount',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w900,
                                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                                ),
                              ),
                            ),
                            _buildStepperBtn(
                              icon: Icons.add_rounded,
                              onTap: passengerCount < _maxPassengerCount
                                  ? () => setState(() => passengerCount++)
                                  : null,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // 5. Estimated fare — fetched live from pricing_config via
                  // PricingController (see _fetchPricing/estimatedFare), shown
                  // before the passenger commits to anything.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                      'ESTIMATED FARE',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  AnimatedBuilder(
                    animation: pricingController,
                    builder: (context, _) {
                      if (pricingController.loading) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: VehiclePricingSkeletonCard(),
                        );
                      }
                      // PRIMARY amount = the full estimated payable amount INCLUDING GST
                      // (pricingController.getFinalFare(), server-computed, GST already applied --
                      // never a separate pre-tax figure) -- this is the one number the passenger
                      // should read as "what I'll pay". "Inclusive of GST" is shown directly under
                      // it so GST never reads as a charge that gets added later; no second/
                      // competing total is shown on this primary screen.
                      final gstAmount = pricingController.getGstAmount('cab') * passengerCount;
                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 16),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF131929) : Colors.white,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '$passengerCount seat${passengerCount == 1 ? '' : 's'} • ${distanceKm.toStringAsFixed(1)} km',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: isDark ? Colors.white70 : const Color(0xFF475569),
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  // Whole-rupee: calculate-order-pricing already rounds
                                  // final_fare to a whole rupee at the source, so this never
                                  // shows a paisa amount that the payment stage then charges
                                  // differently.
                                  '₹${estimatedFare.toStringAsFixed(0)}',
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w900,
                                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                                  ),
                                ),
                                if (gstAmount > 0) ...[
                                  const SizedBox(height: 3),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: const [
                                      Icon(Icons.check_circle_rounded, size: 12, color: Color(0xFF10B981)),
                                      SizedBox(width: 4),
                                      Text(
                                        'Inclusive of GST',
                                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF10B981)),
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SizedBox(
                      height: 54,
                      child: ElevatedButton(
                        onPressed: (selectedVehicle == null || pricingController.loading)
                            ? null
                            : _openConfirmRequestSheet,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: const Text(
                          'Confirm Travel Request',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),
                ],
              ),
            ),

            if (waitingForPayment)
              Positioned.fill(
                child: AppLoadingOverlay(
                  message: 'Processing Payment\nPlease do not close or go back.\nYour payment is being captured.',
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapCtrlBtn({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 38,
        width: 38,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF131929).withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.9),
          shape: BoxShape.circle,
          border: Border.all(
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
            width: 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.10),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Icon(
          icon,
          size: 20,
          color: isDark ? Colors.white : const Color(0xFF334155),
        ),
      ),
    );
  }

  Widget _buildStepperBtn({
    required IconData icon,
    required VoidCallback? onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 30,
        width: 30,
        decoration: BoxDecoration(
          color: enabled
              ? const Color(0xFF10B981).withValues(alpha: 0.12)
              : (isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9)),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 16,
          color: enabled
              ? const Color(0xFF10B981)
              : (isDark ? Colors.white24 : Colors.black26),
        ),
      ),
    );
  }
}
