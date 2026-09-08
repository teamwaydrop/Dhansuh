/// ============================================================================
/// File: parcel_booking_screen.dart
///
/// Module:
/// Local Parcels → Booking
///
/// Purpose:
/// Confirm parcel shipment fare, details, and finalize request.
///
/// Responsibilities:
/// • Show pricing summaries, select payment options.
/// • Initiate delivery rider matching.
///
/// Related:
/// parcel_searching_screen.dart
/// parcel_details_screen.dart
/// ============================================================================

import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:waydrop/core/services/maps/ola_map_service.dart';
import 'package:waydrop/features/local_parcels/services/parcel_upload_service.dart';
import 'package:waydrop/features/local_parcels/searching/screens/parcel_searching_screen.dart';
import 'package:waydrop/modules/payments/controllers/pricing_controller.dart';
import 'package:waydrop/shared/widgets/states/vehicle_pricing_skeleton_card.dart';
import 'package:waydrop/shared/widgets/states/app_loading_overlay.dart';
import 'package:waydrop/shared/helpers/location_display_service.dart';
import 'package:waydrop/shared/helpers/device_info_helper.dart';



class ParcelBookingScreen extends StatefulWidget {
  final String orderType; // 'local_parcel' or 'intercity_parcel'
  final String pickupAddress;
  final String destinationAddress;
  final double pickupLat;
  final double pickupLng;
  final double destinationLat;
  final double destinationLng;
  final double totalDistanceMeters;
  final double durationSeconds;
  final List<Map<String, dynamic>> routePoints;

  // Parcel details meta
  final String receiverName;
  final String receiverPhone;
  final String parcelType;
  final String weightCategory;
  final String specialInstructions;
  final List<String> parcelImages;
  final String? pickupCity;
  final String? destinationCity;

  const ParcelBookingScreen({
    super.key,
    required this.orderType,
    required this.pickupAddress,
    required this.destinationAddress,
    required this.pickupLat,
    required this.pickupLng,
    required this.destinationLat,
    required this.destinationLng,
    required this.totalDistanceMeters,
    required this.durationSeconds,
    required this.routePoints,
    required this.receiverName,
    required this.receiverPhone,
    required this.parcelType,
    required this.weightCategory,
    required this.specialInstructions,
    required this.parcelImages,
    this.pickupCity,
    this.destinationCity,
  });

  @override
  State<ParcelBookingScreen> createState() => _ParcelBookingScreenState();
}

class _ParcelBookingScreenState extends State<ParcelBookingScreen> {
  late PricingController pricingController;
  late final WebViewController webController;
  bool mapLoaded = false;

  String? selectedVehicle;
  String paymentMode = 'cash';
  bool realTimeTracking = true;

  double selectedBoostAmount = 0;
  bool creatingOrder = false;
  bool waitingForPayment = false;

  final supabase = Supabase.instance.client;

  late double distanceKm;
  late double durationMin;
  List<Map<String, dynamic>> nearbyRiders = [];

  bool showPromoField = false;
  final TextEditingController _promoController = TextEditingController();
  String? _appliedPromoCode;
  double _promoDiscount = 0.0;
  bool _isValidatingPromo = false;
  Timer? _riderRefreshTimer;

  Future<void> _applyPromo() async {
    final code = _promoController.text.trim();
    if (code.isEmpty) return;
    
    final pricingData = pricingController.pricingData;
    final defaultVehicle = (double.tryParse(widget.weightCategory) ?? 0.0) >= 10.0 ? 'auto' : 'bike';
    final targetVehicle = selectedVehicle ?? defaultVehicle;
    final currentFare = double.tryParse(pricingData[targetVehicle]?['final_fare']?.toString() ?? '') ?? 0.0;

    if (currentFare == 0.0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pricing is not loaded yet.')),
      );
      return;
    }

    setState(() {
      _isValidatingPromo = true;
    });

    try {
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
        setState(() {
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
        setState(() {
          _isValidatingPromo = false;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    pricingController = PricingController();
    distanceKm = widget.totalDistanceMeters / 1000;
    durationMin = widget.durationSeconds / 60;
    _initWebView();
    _fetchPricing();
    _startRiderRefreshTimer();
  }

  @override
  void dispose() {
    _riderRefreshTimer?.cancel();
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

  // P2 fix (adaptive nearby-rider polling): reuses the exact same 5s->10s->20s elapsed-time bands
  // already proven for this identical "nearby riders map display" concept in
  // ride_searching_screen.dart/intercity_searching_screen.dart/parcel_searching_screen.dart -- not
  // a new threshold. The base 5s timer tick is unchanged, it now just re-evaluates whether a fetch
  // is actually due (by time spent on this screen) before calling _fetchNearbyRiders().
  DateTime? _riderTimerStartedAt;
  DateTime? _lastRiderFetchAt;

  Duration _riderRefreshInterval(Duration elapsed) {
    if (elapsed < const Duration(seconds: 60)) return const Duration(seconds: 5);
    if (elapsed < const Duration(seconds: 180)) return const Duration(seconds: 10);
    return const Duration(seconds: 20);
  }

  void _startRiderRefreshTimer() {
    _riderRefreshTimer?.cancel();
    _riderTimerStartedAt ??= DateTime.now();
    _riderRefreshTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      final now = DateTime.now();
      final interval = _riderRefreshInterval(now.difference(_riderTimerStartedAt!));
      if (_lastRiderFetchAt != null && now.difference(_lastRiderFetchAt!) < interval) {
        return;
      }
      _lastRiderFetchAt = now;
      _fetchNearbyRiders();
    });
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
            await _fetchNearbyRiders();
          },
        ),
      );
    await webController.loadFlutterAsset('assets/map/ola_map_booking.html');
  }

  Future<void> _fetchNearbyRiders() async {
    try {
      // Egress fix: mirrors the geographic bounding-box pattern from
      // ride_location_screen.dart's _fetchNearbyRiders() (CLIENT-3). The haversine
      // radius check below (unchanged) is the actual eligibility rule; this bounding
      // box is a strict superset of that same circle, so the returned rider set is
      // identical -- it only lets Postgres discard far-away rows before they're sent
      // over the network instead of transferring the whole online-rider table on
      // every poll tick.
      const double radiusKm = 5.0;
      const double kmPerDegreeLat = 111.32;
      final double latDelta = radiusKm / kmPerDegreeLat;
      final double lngDegreeKm =
          kmPerDegreeLat * cos(widget.pickupLat * (pi / 180)).abs();
      final double lngDelta =
          radiusKm / (lngDegreeKm < 0.000001 ? 0.000001 : lngDegreeKm);

      final response = await supabase
          .from('riders')
          .select(
            'id, current_lat, current_lng, current_heading, '
            'rider_kyc!riders_kyc_id_fkey(vehicle_type)',
          )
          .eq('account_status', 'online')
          .not('current_lat', 'is', null)
          .not('current_lng', 'is', null)
          .gte('current_lat', widget.pickupLat - latDelta)
          .lte('current_lat', widget.pickupLat + latDelta)
          .gte('current_lng', widget.pickupLng - lngDelta)
          .lte('current_lng', widget.pickupLng + lngDelta);

      final List<Map<String, dynamic>> riders =
          (response as List).map<Map<String, dynamic>>((r) {
        final map = Map<String, dynamic>.from(r as Map);
        final kyc = map['rider_kyc!riders_kyc_id_fkey'] ?? map['rider_kyc'];
        String vehicleType = 'bike';
        if (kyc is Map) {
          vehicleType = kyc['vehicle_type']?.toString().toLowerCase().trim() ?? 'bike';
        } else if (kyc is List && kyc.isNotEmpty && kyc[0] is Map) {
          vehicleType = kyc[0]['vehicle_type']?.toString().toLowerCase().trim() ?? 'bike';
        }
        if (vehicleType == 'car') {
          vehicleType = 'cab';
        }
        map['vehicle_type'] = vehicleType;
        map.remove('rider_kyc!riders_kyc_id_fkey');
        map.remove('rider_kyc');
        return map;
      }).where((rider) {
        final double? lat = double.tryParse(rider['current_lat']?.toString() ?? '');
        final double? lng = double.tryParse(rider['current_lng']?.toString() ?? '');
        if (lat == null || lng == null) return false;

        const p = 0.017453292519943295; // Math.PI / 180
        final a = 0.5 - cos((lat - widget.pickupLat) * p) / 2 +
            cos(widget.pickupLat * p) * cos(lat * p) *
            (1 - cos((lng - widget.pickupLng) * p)) / 2;
        final distanceKm = 12742 * asin(sqrt(a));
        return distanceKm <= 5.0;
      }).toList();

      if (mounted) {
        setState(() => nearbyRiders = riders);
      }
      await _updateRidersOnMap(filterType: selectedVehicle);
    } catch (e) {
      debugPrint('FETCH NEARBY RIDERS ERROR => $e');
    }
  }

  Future<void> _updateRidersOnMap({String? filterType}) async {
    if (!mapLoaded) return;
    try {
      final ridersJson = jsonEncode(nearbyRiders);
      final filterArg = filterType != null ? '"$filterType"' : 'null';
      await webController.runJavaScript(
        'if(window.showNearbyRiders){ window.showNearbyRiders($ridersJson, $filterArg); }',
      );
    } catch (e) {
      debugPrint('UPDATE RIDERS ON MAP ERROR => $e');
    }
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
      await webController.runJavaScript('if(window.clearMarkers){ window.clearMarkers(); }');
      await webController.runJavaScript(
        'if(window.addPickupMarker){ window.addPickupMarker(${widget.pickupLat}, ${widget.pickupLng}); }',
      );
      await webController.runJavaScript(
        'if(window.addDestinationMarker){ window.addDestinationMarker(${widget.destinationLat}, ${widget.destinationLng}); }',
      );
      final polylineJson = jsonEncode(widget.routePoints);
      await webController.runJavaScript('if(window.drawRoute){ window.drawRoute($polylineJson); }');
      await webController.runJavaScript('if(window.fitRouteBounds){ window.fitRouteBounds(); }');
    } catch (e) {
      debugPrint('MAP UPDATE ROUTE ERROR => $e');
    }
  }

  Future<void> _fetchPricing() async {
    await pricingController.fetchMultiplePricing(
      orderType: widget.orderType,
      distanceKm: distanceKm,
      pickupAddress: widget.pickupAddress,
      maxBoostAmount: selectedBoostAmount,
      weightCategory: widget.weightCategory,
      pickupLat: widget.pickupLat,
      pickupLng: widget.pickupLng,
    );

    if (widget.orderType == 'local_parcel') {
      // Let the user explicitly pick Bike vs Auto (see _buildVehicleItem/_selectVehicle below) --
      // never auto-decide it here. If a previously-picked vehicle is no longer eligible (e.g. the
      // weight changed), clear it so the UI forces a fresh, valid choice.
      if (selectedVehicle != null && !pricingController.pricingData.containsKey(selectedVehicle)) {
        selectedVehicle = null;
      }
      if (mounted) {
        setState(() {});
        if (mapLoaded) {
          _updateRidersOnMap(filterType: selectedVehicle);
        }
      }
      return;
    }

    if (selectedVehicle == null) {
      if (pricingController.pricingData.isNotEmpty) {
        selectedVehicle = pricingController.pricingData.keys.first;
      } else {
        selectedVehicle = (double.tryParse(widget.weightCategory) ?? 0.0) >= 10.0 ? 'auto' : 'bike';
      }
      if (mounted) {
        setState(() {});
        if (mapLoaded) {
          _updateRidersOnMap(filterType: selectedVehicle);
        }
      }
    }
  }

  void _selectVehicle(String vehicle) {
    setState(() => selectedVehicle = vehicle);
    if (mapLoaded) {
      _updateRidersOnMap(filterType: vehicle);
    }
  }

  String extractCity(String? city, String address) {
    return LocationDisplayService.resolveCity(
      city: city,
      address: address,
      fallback: 'Other',
    );
  }



  Future<void> _submitOrderToBackend({String? paymentId}) async {
    List<String> uploadedUrls = [];

    if (widget.parcelImages.isNotEmpty) {
      final List<File> filesToUpload = widget.parcelImages
          .map((path) => File(path))
          .where((f) => f.existsSync())
          .toList();
      if (filesToUpload.isNotEmpty) {
        try {
          uploadedUrls = await ParcelUploadService.uploadImages(filesToUpload);
        } catch (e) {
          debugPrint('PARCEL UPLOAD ERROR IN BOOKING => $e');
          throw Exception('Failed to upload package images: $e');
        }
      } else {
        // Fallback: if already uploaded (e.g. URLs or retry)
        uploadedUrls = widget.parcelImages;
      }
    }

    final deviceMeta = await DeviceInfoHelper.getDeviceMetadata();
    final user = supabase.auth.currentUser;
    final response = await supabase.functions.invoke(
      'create-order',
      body: {
        'user_id': user?.id,
        'order_type': widget.orderType,
        'vehicle_type': selectedVehicle ?? ((double.tryParse(widget.weightCategory) ?? 0.0) >= 10.0 ? 'auto' : 'bike'),
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
        'destination_city': extractCity(widget.destinationCity, widget.destinationAddress),
        'max_boost_amount': selectedBoostAmount,
        // Parcel Metadata
        'receiver_name': widget.receiverName,
        'receiver_phone': widget.receiverPhone,
        'parcel_type': widget.parcelType,
        'weight_category': widget.weightCategory,
        'special_instructions': widget.specialInstructions,
        'parcel_images': uploadedUrls,
        'promo_code': _appliedPromoCode,
        // Device snapshot
        'created_device_id': deviceMeta['device_id'],
        'device_model': deviceMeta['device_model'],
        'device_brand': deviceMeta['device_brand'],
        'os_version': deviceMeta['os_version'],
        'app_version': deviceMeta['app_version'],
      },
      // CLIENT-1 (WayDrop Progressive Degradation Audit): bounded so a stalled backend surfaces
      // as the same caught exception the caller already handles, not an infinite wait.
    ).timeout(const Duration(seconds: 30));

    debugPrint('CREATE ORDER RESPONSE => ${response.data}');

    if (response.data == null || response.data['success'] != true) {
      final errorMsg = response.data?['error'] ?? 'Unknown error occurred while creating order';
      throw Exception(errorMsg);
    }

    final order = response.data['order'];
    if (order == null || order['id'] == null) {
      throw Exception('Failed to retrieve order ID from response');
    }

    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => ParcelSearchingScreen(orderId: order['id'])),
    );
  }

  Future<void> _createOrder() async {
    if (selectedVehicle == null) return;

    // Both 'cash' and 'upi' are collected directly by the driver at trip
    // completion — no payment gateway involved at booking time.
    try {
      setState(() => creatingOrder = true);
      await _submitOrderToBackend();
    } catch (e, stackTrace) {
      // Phase 5 F2: non-fatal Crashlytics report, purely additive -- does not affect the
      // existing SnackBar/finally behavior below.
      FirebaseCrashlytics.instance.recordError(
        e,
        stackTrace,
        reason: 'create-order (local parcel) failed',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) {
        setState(() {
          creatingOrder = false;
          waitingForPayment = false;
        });
      }
    }
  }

  Widget _buildPaymentPanel(Color primaryColor) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final panelBg = isDark ? const Color(0xFF0C101C) : const Color(0xFFF8FAFC);
    final borderCol = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);
    final textCol = isDark ? Colors.white : const Color(0xFF1E293B);
    final subCol = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final fieldBg = isDark ? const Color(0xFF171A21) : Colors.white;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: panelBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: borderCol),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPaymentChipVertical(
            icon: Icons.payments_rounded,
            label: 'Pay via Cash on Delivery',
            value: 'cash',
            accentColor: const Color(0xFF059669),
            bgColor: const Color(0xFFECFDF5),
          ),
          const SizedBox(height: 8),
          _buildPaymentChipVertical(
            icon: Icons.qr_code_rounded,
            label: 'Pay via UPI',
            value: 'online',
            accentColor: primaryColor,
            bgColor: primaryColor.withValues(alpha: 0.08),
          ),
          const SizedBox(height: 10),
          Divider(height: 1, color: borderCol),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => setState(() => showPromoField = !showPromoField),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF3F2D0B) : const Color(0xFFFFFBEB),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.card_giftcard_rounded, size: 14, color: Color(0xFFD97706)),
                ),
                const SizedBox(width: 10),
                Text(
                  'Apply Promo Code',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: textCol),
                ),
                const Spacer(),
                AnimatedRotation(
                  turns: showPromoField ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: subCol),
                ),
              ],
            ),
          ),
          if (_appliedPromoCode != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF10B981).withOpacity(0.12) : const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_rounded, size: 14, color: Color(0xFF10B981)),
                  const SizedBox(width: 8),
                  Text(
                    '$_appliedPromoCode Applied',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
                  ),
                  const Spacer(),
                  Text(
                    '- \u20B9${_promoDiscount.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _appliedPromoCode = null;
                        _promoDiscount = 0.0;
                        _promoController.clear();
                      });
                    },
                    child: Icon(Icons.cancel_rounded, size: 16, color: isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8)),
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
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: textCol, letterSpacing: 1.2),
                            decoration: InputDecoration(
                              hintText: 'Enter promo code...',
                              hintStyle: TextStyle(color: isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1), fontWeight: FontWeight.normal, letterSpacing: 0),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                              isDense: true,
                              filled: true,
                              fillColor: fieldBg,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: borderCol)),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: primaryColor, width: 1.5)),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: borderCol)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: _applyPromo,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                            decoration: BoxDecoration(color: primaryColor, borderRadius: BorderRadius.circular(10)),
                            child: _isValidatingPromo
                                ? const SizedBox(height: 14, width: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.0))
                                : const Text('Apply', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selected = paymentMode == value;
    final defaultBg = isDark ? const Color(0xFF171A21) : Colors.white;
    final defaultBorder = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);
    final defaultText = isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569);
    final activeBg = isDark ? accentColor.withOpacity(0.15) : bgColor;

    return GestureDetector(
      onTap: () => setState(() => paymentMode = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? activeBg : defaultBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? accentColor.withOpacity(0.6) : defaultBorder,
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: selected ? accentColor : const Color(0xFF94A3B8),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selected ? accentColor : defaultText,
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
                  border: Border.all(color: isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1), width: 1.5),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // Local-parcel Bike/Auto selector card, matching ride_location_screen.dart's
  // _buildVehicleItem pattern so vehicle selection looks/behaves consistently across the app.
  Widget _buildVehicleItem({
    required String vehicle,
    required String title,
    required double fare,
    required bool selected,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () => _selectVehicle(vehicle),
      child: Padding(
        padding: const EdgeInsets.only(right: 14.0),
        child: SizedBox(
          width: 76,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                height: 72,
                width: 72,
                decoration: BoxDecoration(
                  color: selected
                      ? (isDark ? const Color(0xFF10B981).withOpacity(0.18) : const Color(0xFFECFDF5))
                      : (isDark ? const Color(0xFF1E222B) : Colors.white),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: selected ? const Color(0xFF10B981) : (isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
                    width: selected ? 2.0 : 1.0,
                  ),
                  boxShadow: selected
                      ? [BoxShadow(color: const Color(0xFF10B981).withOpacity(0.2), blurRadius: 12, offset: const Offset(0, 4))]
                      : [BoxShadow(color: Colors.black.withOpacity(isDark ? 0.25 : 0.04), blurRadius: 8, offset: const Offset(0, 2))],
                ),
                padding: const EdgeInsets.all(6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset(
                    'assets/images/$vehicle.jpg',
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Icon(
                      vehicle == 'bike' ? Icons.directions_bike : Icons.electric_rickshaw,
                      color: selected ? const Color(0xFF10B981) : (isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8)),
                      size: 32,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                title,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.bold : FontWeight.w600,
                  color: selected ? (isDark ? Colors.white : const Color(0xFF0F172A)) : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                // Whole-rupee: fare is calculate-order-pricing's already-rounded final_fare.
                '₹${fare.toStringAsFixed(0)}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: selected ? const Color(0xFF10B981) : (isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMapCtrlBtn({required IconData icon, required VoidCallback onTap}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final iconCol = isDark ? Colors.white : const Color(0xFF334155);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 40,
        width: 40,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 8,
              offset: const Offset(0, 3),
            )
          ],
        ),
        child: Icon(icon, size: 18, color: iconCol),
      ),
    );
  }  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    // Dynamic Theme Color Mapping
    final screenBg = isDark ? const Color(0xFF1E222B) : const Color(0xFFF8FAFC);
    final cardBg = isDark ? const Color(0xFF171A21) : Colors.white;
    final textCol = isDark ? Colors.white : const Color(0xFF0F172A);
    final subTextCol = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final borderCol = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);
    final inputBg = isDark ? const Color(0xFF0C101C) : const Color(0xFFF8FAFC);
    final circleBtnBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final circleBtnIcon = isDark ? Colors.white : const Color(0xFF1E293B);

    final primaryColor = const Color(0xFF10B981);
    final accentOrange = const Color(0xFFFF4E25); // Vibrant Orange-Red Book Accent
    
    final pricingData = pricingController.pricingData;
    final loading = pricingController.loading;
    final defaultVehicle = (double.tryParse(widget.weightCategory) ?? 0.0) >= 10.0 ? 'auto' : 'bike';
    final deliveryFare = double.tryParse(pricingData[defaultVehicle]?['final_fare']?.toString() ?? '') ?? 0.0;

    final double originalFare = selectedVehicle != null
        ? pricingController.getFinalFare(selectedVehicle!)
        : deliveryFare;

    final hasDiscount = _appliedPromoCode != null && _promoDiscount > 0;
    final double finalFare = hasDiscount 
        ? (originalFare - _promoDiscount).clamp(0.0, double.infinity) 
        : originalFare;

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
        backgroundColor: screenBg,
        body: Stack(
          children: [
            // 1. OLA WEBVIEW MAP
            Positioned.fill(
              child: WebViewWidget(controller: webController),
            ),

            // 2. FLOATING BACK BUTTON ONLY (MATCHING TOP-LEFT OVERLAY)
            Positioned(
              top: 50,
              left: 16,
              child: GestureDetector(
                onTap: isLocked ? null : () => Navigator.pop(context),
                child: Container(
                  height: 44,
                  width: 44,
                  decoration: BoxDecoration(
                    color: isLocked
                        ? (isDark ? const Color(0xFF0C101C) : const Color(0xFFF1F5F9))
                        : circleBtnBg,
                    shape: BoxShape.circle,
                    boxShadow: isLocked
                        ? []
                        : [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.08),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            )
                          ],
                  ),
                  child: Icon(
                    Icons.arrow_back_ios_new_rounded,
                    size: 18,
                    color: isLocked ? subTextCol : circleBtnIcon,
                  ),
                ),
              ),
            ),

            // 3. FLOATING MAP CONTROLS
            Positioned(
              top: 110,
              right: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: () {
                      if (mapLoaded) {
                        webController.runJavaScript('if(window.recenterToPickup){ window.recenterToPickup(); }');
                      }
                    },
                    child: Container(
                      height: 40,
                      width: 40,
                      decoration: BoxDecoration(
                        color: circleBtnBg,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.08),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          )
                        ],
                      ),
                      child: Icon(Icons.my_location_rounded, size: 18, color: primaryColor),
                    ),
                  ),
                ],
              ),
            ),

            // 4. LARGE PREMIUM WHITE/DARK BOTTOM PANEL (FIXED, NOT DRAGGABLE)
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                height: MediaQuery.of(context).size.height * 0.45,
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                      blurRadius: 28,
                      offset: const Offset(0, -6),
                    )
                  ],
                ),
                child: ListView(
                  padding: const EdgeInsets.only(left: 20, right: 20, top: 12, bottom: 24),
                  physics: const BouncingScrollPhysics(),
                  children: [
                      const SizedBox.shrink(),
                      const SizedBox(height: 18),

                      // "Estimate Price" Center Title
                      Align(
                        alignment: Alignment.center,
                        child: Text(
                          'Estimate Price',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: textCol.withOpacity(0.45),
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),

                      // Huge styled price tag
                      loading
                          ? const VehiclePricingSkeletonCard()
                          : Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (hasDiscount) ...[
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          'Original: ₹${originalFare.toStringAsFixed(0)}',
                                          style: TextStyle(
                                            fontSize: 14,
                                            decoration: TextDecoration.lineThrough,
                                            fontWeight: FontWeight.w700,
                                            color: textCol.withOpacity(0.4),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                  ],
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.only(top: 6.0),
                                        child: Text(
                                          '₹',
                                          style: TextStyle(
                                            fontSize: 26,
                                            fontWeight: FontWeight.w800,
                                            color: hasDiscount ? const Color(0xFF10B981) : textCol.withOpacity(0.4),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        // Whole-rupee: finalFare traces back to
                                        // calculate-order-pricing's already-rounded final_fare.
                                        finalFare.toStringAsFixed(0),
                                        style: TextStyle(
                                          fontSize: 44,
                                          fontWeight: FontWeight.w900,
                                          color: hasDiscount ? const Color(0xFF10B981) : textCol,
                                          letterSpacing: -1.0,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'inclusive of GST',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: textCol.withOpacity(0.4),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                      const SizedBox(height: 20),

                      // 4b. LOCAL PARCEL VEHICLE SELECTOR (Bike / Auto) -- lets the user choose
                      // between whichever options pricingController resolved as eligible for this
                      // parcel's weight, instead of the app deciding for them.
                      if (widget.orderType == 'local_parcel' && !loading) ...[
                        Text(
                          'Choose a vehicle',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: textCol.withOpacity(0.6),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              if (pricingData.containsKey('bike'))
                                _buildVehicleItem(
                                  vehicle: 'bike',
                                  title: 'Bike',
                                  fare: double.tryParse(pricingData['bike']?['final_fare']?.toString() ?? '') ?? 0.0,
                                  selected: selectedVehicle == 'bike',
                                ),
                              if (pricingData.containsKey('auto'))
                                _buildVehicleItem(
                                  vehicle: 'auto',
                                  title: 'Auto',
                                  fare: double.tryParse(pricingData['auto']?['final_fare']?.toString() ?? '') ?? 0.0,
                                  selected: selectedVehicle == 'auto',
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],

                      // 5. SLATE-COLORED ELEGANT ADDRESS CARD (THEMED & EDITABLE)
                      InkWell(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: inputBg,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: borderCol),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  children: [
                                    // Pickup Address Row
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          margin: const EdgeInsets.only(top: 3),
                                          height: 10, width: 10,
                                          decoration: const BoxDecoration(color: Color(0xFF10B981), shape: BoxShape.circle),
                                        ),
                                        const SizedBox(width: 14),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                'Pickup Location',
                                                style: TextStyle(
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.w900,
                                                  color: textCol.withOpacity(0.4),
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                widget.pickupAddress,
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w800,
                                                  color: textCol,
                                                ),
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
                                        color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
                                      ),
                                    ),

                                    // Delivery Address Row
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          margin: const EdgeInsets.only(top: 3),
                                          height: 10, width: 10,
                                          decoration: const BoxDecoration(color: Color(0xFFEF4444), shape: BoxShape.circle),
                                        ),
                                        const SizedBox(width: 14),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                'Delivery Location',
                                                style: TextStyle(
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.w900,
                                                  color: textCol.withOpacity(0.4),
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                widget.destinationAddress,
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w800,
                                                  color: textCol,
                                                ),
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
                                decoration: const BoxDecoration(
                                  color: Color(0xFF10B981),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.edit_rounded,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // 6. PAYMENT PANEL AND PROMO (THEMED)
                      _buildPaymentPanel(primaryColor),
                      const SizedBox(height: 24),

                      // 7. BRIGHT ORANGE-RED BOOKING BUTTON (COMBINED PRICE & ACTION)
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton(
                          onPressed: (selectedVehicle == null || isLocked) ? null : _createOrder,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: accentOrange,
                            disabledBackgroundColor: accentOrange.withOpacity(0.5),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            elevation: 4,
                            shadowColor: accentOrange.withOpacity(0.35),
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                          ),
                          child: isLocked
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                )
                              : const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      'Book Parcel',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                    SizedBox(width: 6),
                                    Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 16),
                                  ],
                                ),
                        ),
                      ),
                    ],
                  ),
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
}
