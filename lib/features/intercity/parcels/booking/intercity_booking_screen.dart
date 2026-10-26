import 'package:waydrop/core/services/diagnostics/ride_diagnostics.dart';
import 'package:waydrop/core/services/diagnostics/ride_diagnostics_owner.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:waydrop/core/services/maps/ola_map_service.dart';
import 'package:waydrop/features/local_parcels/services/parcel_upload_service.dart';
import 'package:waydrop/features/intercity/shared/screens/intercity_searching_screen.dart';
import 'package:waydrop/modules/payments/controllers/pricing_controller.dart';
import 'package:waydrop/shared/helpers/location_display_service.dart';



class IntercityBookingScreen extends StatefulWidget {
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

  final DateTime? travelDate;
  final String? pickupCity;
  final String? destinationCity;

  const IntercityBookingScreen({
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
    this.travelDate,
    this.pickupCity,
    this.destinationCity,
  });

  @override
  State<IntercityBookingScreen> createState() => _IntercityBookingScreenState();
}

class _IntercityBookingScreenState extends State<IntercityBookingScreen> {
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

  Future<void> _applyPromo() async {
    final code = _promoController.text.trim();
    if (code.isEmpty) return;

    final pricingData = pricingController.pricingData;
    final targetVehicle = selectedVehicle ?? 'delivery';

    if (pricingData[targetVehicle] == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please wait for pricing to load.')),
      );
      return;
    }

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

  late final RideDiagnosticOwner _rideDiagnosticOwner;

  @override
  void initState() {
    super.initState();
    _rideDiagnosticOwner = RideDiagnosticOwner.widget(() => mounted, surface: RideSurface.booking);
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
    // This screen's webController loads the DEPRECATED, self-contained ola_map.html, which does
    // NOT pull in ola_map_core.js, so none of these helpers are defined there today -- every call
    // is a `typeof`-guarded no-op. It is kept here purely for defense-in-depth / consistency with
    // the other map screens and matches the guarded 'unload' handler already in ola_map.html
    // (c1ccf56); if that page is ever migrated onto ola_map_core.js it becomes functional with no
    // further change. The 'unload' event does not reliably fire when Flutter disposes the platform
    // WebView without a navigation. The call is wrapped in try/catch on the JS side and
    // .catchError on the Dart side, and is fire-and-forget because dispose() cannot await. The
    // outer try/catch covers the `late final webController` never being assigned (e.g.
    // WebViewController() unsupported on desktop), which would otherwise throw
    // LateInitializationError here.
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
            await _fetchNearbyRiders();
          },
        ),
      );
    await webController.loadFlutterAsset('assets/map/ola_map.html');
  }

  Future<void> _fetchNearbyRiders() async {
    try {
      final response = await supabase
          .from('riders')
          .select(
            'id, current_lat, current_lng, current_heading, '
            'rider_kyc!riders_kyc_id_fkey(vehicle_type)',
          )
          .eq('account_status', 'online')
          .not('current_lat', 'is', null)
          .not('current_lng', 'is', null);

      final List<Map<String, dynamic>> riders = (response as List)
          .map<Map<String, dynamic>>((r) {
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
          })
          .where((rider) {
            final double? lat = double.tryParse(rider['current_lat']?.toString() ?? '');
            final double? lng = double.tryParse(rider['current_lng']?.toString() ?? '');
            if (lat == null || lng == null) return false;

            const p = 0.017453292519943295; // Math.PI / 180
            final a = 0.5 -
                cos((lat - widget.pickupLat) * p) / 2 +
                cos(widget.pickupLat * p) *
                    cos(lat * p) *
                    (1 - cos((lng - widget.pickupLng) * p)) /
                    2;
            final distanceKm = 12742 * asin(sqrt(a));
            return distanceKm <= 5.0;
          })
          .toList();

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

    if (selectedVehicle == null) {
      final defaultVehicle = (double.tryParse(widget.weightCategory) ?? 0.0) >= 10.0 ? 'auto' : 'bike';
      if (pricingController.pricingData.containsKey(defaultVehicle)) {
        selectedVehicle = defaultVehicle;
      } else if (pricingController.pricingData.isNotEmpty) {
        selectedVehicle = pricingController.pricingData.keys.first;
      }
      if (mounted) setState(() {});
    }
  }

  String extractCity(String? city, String address) {
    return LocationDisplayService.resolveCity(
      city: city,
      address: address,
      fallback: 'Other',
    );
  }


  Future<void> _submitOrderToBackend({String? paymentId, RideAttempt? diagnosticAttempt}) async {
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

    final user = supabase.auth.currentUser;
    final response = await _rideDiagnosticOwner.api(RideEndpoint.booking, null, () => supabase.functions.invoke(
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
        'travel_date': widget.travelDate?.toUtc().toIso8601String(),
        'promo_code': _appliedPromoCode,
      },
      // CLIENT-1 (WayDrop Progressive Degradation Audit): bounded so a stalled backend surfaces
      // as the same caught exception the caller already handles, not an infinite wait.
    ).timeout(const Duration(seconds: 30)), attempt: diagnosticAttempt);

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
      MaterialPageRoute(builder: (_) => IntercitySearchingScreen(orderId: order['id'])),
    );
  }

  Future<void> _createOrder() async {
    final diagnosticAttempt = _rideDiagnosticOwner.begin(endpoint: RideEndpoint.booking);
    if (selectedVehicle == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to calculate fare for this route. Please retry pricing first.'),
          backgroundColor: Color(0xFFEF4444),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (widget.travelDate != null && widget.travelDate!.isBefore(DateTime.now())) {
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
        reason: 'create-order (intercity parcel) failed',
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

  Widget _buildParcelDetailsCard(Color textCol, Color subTextCol, Color borderCol, Color inputBg, Color primaryColor) {
    final travelDateStr = widget.travelDate != null
        ? () {
            try {
              final dt = widget.travelDate!.toLocal();
              final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
              final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
              final ampm = dt.hour >= 12 ? 'PM' : 'AM';
              final minute = dt.minute.toString().padLeft(2, '0');
              return '${dt.day} ${months[dt.month - 1]}, $hour:$minute $ampm';
            } catch (_) {
              return widget.travelDate.toString();
            }
          }()
        : 'Not scheduled';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'PARCEL DETAILS',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w900,
            color: subTextCol,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 8),
        InkWell(
          onTap: () => Navigator.pop(context),
          borderRadius: BorderRadius.circular(24),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: inputBg,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: borderCol),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Receiver Info Row
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.person_rounded, color: primaryColor, size: 18),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Receiver Info',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                    color: subTextCol,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${widget.receiverName} • ${widget.receiverPhone}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: textCol,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      
                      // Package Info Row
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.inventory_2_rounded, color: primaryColor, size: 18),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Package Type & Weight',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                    color: subTextCol,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${widget.parcelType.isNotEmpty ? (widget.parcelType[0].toUpperCase() + widget.parcelType.substring(1)) : "Parcel"} (${widget.weightCategory} kg)',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: textCol,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // Departure Time Info Row
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.access_time_rounded, color: primaryColor, size: 18),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Scheduled Departure',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                    color: subTextCol,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  travelDateStr,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: textCol,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      
                      if (widget.specialInstructions.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.chat_bubble_rounded, color: primaryColor, size: 18),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Special Instructions',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w900,
                                      color: subTextCol,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    widget.specialInstructions,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: textCol,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],

                      if (widget.parcelImages.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        SizedBox(
                          height: 50,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: widget.parcelImages.length,
                            physics: const ClampingScrollPhysics(),
                            itemBuilder: (context, idx) {
                              return Container(
                                margin: const EdgeInsets.only(right: 8),
                                width: 50,
                                height: 50,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: borderCol),
                                  image: DecorationImage(
                                    image: NetworkImage(widget.parcelImages[idx]),
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
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
      ],
    );
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
                    '- ₹${_promoDiscount.toStringAsFixed(2)}',
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
                                ? const SizedBox(
                                    height: 14,
                                    width: 14,
                                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.0),
                                  )
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

    final primaryColor = const Color(0xFF7C3AED);
    final accentOrange = const Color(0xFFFF4E25); // Vibrant Orange-Red Book Accent
    
    final pricingData = pricingController.pricingData;
    final loading = pricingController.loading;
    // A completed fetch that found no usable pricing for this route/order type -- never silently
    // rendered as ₹0.00 below; see the error/retry state in the price display and bottom bar.
    final bool pricingFailed = !loading && pricingData.isEmpty;
    final defaultVehicle = (double.tryParse(widget.weightCategory) ?? 0.0) >= 10.0 ? 'auto' : 'bike';
    final deliveryFare = double.tryParse(pricingData[defaultVehicle]?['final_fare']?.toString() ?? '') ?? 0.0;

    final double finalFare = selectedVehicle != null
        ? pricingController.getFinalFare(selectedVehicle!)
        : deliveryFare;

    final hasDiscount = _appliedPromoCode != null && _promoDiscount > 0;
    final displayFare = hasDiscount ? (finalFare - _promoDiscount).clamp(0.0, double.infinity) : finalFare;

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
            'Confirm Intercity Shipment',
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
            Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    physics: const ClampingScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 1. Framed Map Card
                        Container(
                          margin: const EdgeInsets.all(16),
                          height: 240,
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF131929)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: isDark
                                  ? const Color(0xFF1E293B)
                                  : const Color(0xFFE2E8F0),
                              width: 1.0,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(
                                  alpha: isDark ? 0.2 : 0.06,
                                ),
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
                              // Map Controls Overlay
                              Positioned(
                                bottom: 12,
                                right: 12,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    GestureDetector(
                                      onTap: () {
                                        if (mapLoaded) {
                                          webController.runJavaScript(
                                            'if(window.recenterToPickup){ window.recenterToPickup(); }',
                                          );
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
                                        child: Icon(
                                          Icons.my_location_rounded,
                                          size: 18,
                                          color: primaryColor,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),

                        // 2. Main Content Details Padding
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Estimated Price Title & Price tag (large)
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.center,
                                child: Text(
                                  'Estimated Price',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    color: textCol.withOpacity(0.45),
                                    letterSpacing: -0.2,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Center(
                                child: loading
                                    ? SizedBox(
                                        height: 50,
                                        width: 50,
                                        child: Center(
                                          child: CircularProgressIndicator(
                                            valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                                            strokeWidth: 3,
                                          ),
                                        ),
                                      )
                                    : pricingFailed
                                        ? Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(Icons.error_outline_rounded, color: Color(0xFFEF4444), size: 32),
                                              const SizedBox(height: 8),
                                              Text(
                                                'Unable to calculate fare for this route',
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w700,
                                                  color: textCol.withOpacity(0.7),
                                                ),
                                              ),
                                              const SizedBox(height: 10),
                                              TextButton.icon(
                                                onPressed: _fetchPricing,
                                                icon: const Icon(Icons.refresh_rounded, size: 16),
                                                label: const Text('Retry', style: TextStyle(fontWeight: FontWeight.bold)),
                                                style: TextButton.styleFrom(foregroundColor: primaryColor),
                                              ),
                                            ],
                                          )
                                        : Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
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
                                                    color: textCol.withOpacity(0.4),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              if (hasDiscount) ...[
                                                Text(
                                                  // Whole-rupee: traces back to
                                                  // calculate-order-pricing's rounded final_fare.
                                                  finalFare.toStringAsFixed(0),
                                                  style: TextStyle(
                                                    fontSize: 24,
                                                    fontWeight: FontWeight.w700,
                                                    color: textCol.withOpacity(0.4),
                                                    decoration: TextDecoration.lineThrough,
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                              ],
                                              Text(
                                                displayFare.toStringAsFixed(0),
                                                style: TextStyle(
                                                  fontSize: 44,
                                                  fontWeight: FontWeight.w900,
                                                  color: textCol,
                                                  letterSpacing: -1.5,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            'inclusive of GST',
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: textCol.withOpacity(0.3),
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                              const SizedBox(height: 24),

                              // Route Details Title
                              Text(
                                'ROUTE DETAILS',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  color: subTextCol,
                                  letterSpacing: 0.8,
                                ),
                              ),
                              const SizedBox(height: 8),

                              // Address Card (onTap pops back to edit route)
                              InkWell(
                                onTap: () => Navigator.pop(context),
                                borderRadius: BorderRadius.circular(24),
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

                              // Parcel Details summary card
                              _buildParcelDetailsCard(textCol, subTextCol, borderCol, inputBg, primaryColor),
                              const SizedBox(height: 20),

                              // Payment & Promo Code Panel
                              _buildPaymentPanel(primaryColor),
                              const SizedBox(height: 24),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // 3. Clean Bottom Bar (matching ride booking screen)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF131929) : Colors.white,
                    border: Border(
                      top: BorderSide(
                        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                        width: 1.0,
                      ),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: isDark ? 0.15 : 0.05,
                        ),
                        blurRadius: 10,
                        offset: const Offset(0, -4),
                      ),
                    ],
                  ),
                  child: SafeArea(
                    top: false,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'ESTIMATED FARE',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  color: isDark
                                      ? const Color(0xFF94A3B8)
                                      : const Color(0xFF64748B),
                                  letterSpacing: 0.5,
                                ),
                              ),
                              const SizedBox(height: 2),
                              pricingFailed
                                  ? Text(
                                      'Unavailable',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w800,
                                        color: const Color(0xFFEF4444),
                                      ),
                                    )
                                  : Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '₹',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            color: isDark
                                                ? const Color(0xFF94A3B8)
                                                : const Color(0xFF64748B),
                                          ),
                                        ),
                                        const SizedBox(width: 2),
                                        Text(
                                          displayFare.toStringAsFixed(0),
                                          style: TextStyle(
                                            fontSize: 22,
                                            fontWeight: FontWeight.w900,
                                            color: textCol,
                                            letterSpacing: -0.5,
                                          ),
                                        ),
                                      ],
                                    ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: 170,
                          height: 52,
                          child: ElevatedButton(
                            onPressed: (isLocked || pricingFailed) ? null : _createOrder,
                            style: ElevatedButton.styleFrom(
                              elevation: 0,
                              backgroundColor: accentOrange,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: accentOrange.withOpacity(0.5),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            child: isLocked
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                  )
                                : const Text(
                                    'Book Shipment',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 15,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
