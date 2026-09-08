import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:waydrop/core/services/cache/qr_image_cache_manager.dart';
import 'package:waydrop/core/services/cache/qr_signed_url_cache.dart';
import 'package:waydrop/core/services/database/rider_payout_account_cache.dart';
import 'package:waydrop/core/services/database/government_tax_ledger_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:geolocator/geolocator.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:waydrop/core/config/env.dart';
import 'package:pinput/pinput.dart';
import 'package:waydrop/shared/widgets/maps/transport_map_widget.dart';
import 'package:waydrop/core/services/location/location_cache_service.dart';
import 'package:waydrop/core/services/maps/ola_map_service.dart';
import 'package:waydrop/core/services/session/pip_service.dart';
import 'package:waydrop/core/services/session/active_order_screen_state.dart';
import 'package:waydrop/modules/chat/screens/order_chat_screen.dart';
import 'package:waydrop/models/transport_order.dart';
import 'package:waydrop/features/intercity/shared/widgets/waiting_for_travel_day_card.dart';
import 'package:waydrop/features/local_rides/rating/screens/rider_rating_screen.dart';
import 'package:waydrop/features/local_rides/shared/navigation/local_ride_home_navigator.dart';
import 'package:waydrop/shared/widgets/skeleton_loader.dart';
import 'package:image_picker/image_picker.dart';
import 'package:waydrop/shared/helpers/device_info_helper.dart';
import 'package:waydrop/shared/helpers/fare_presentation_helper.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/shared/widgets/waydrop_3d_bike.dart';
import 'package:waydrop/shared/helpers/insets.dart';
import 'package:waydrop/shared/helpers/location_display_service.dart';
import 'package:waydrop/modules/payments/services/payment_service.dart';
import 'package:waydrop/modules/payments/screens/payment_processing_screen.dart';

const Color _primaryLime = Color(0xFFC5FF30);
const Color _darkBg = Color(0xFF0B0F19);
const Color _darkCard = Color(0xFF131926);
const Color _textGray = Color(0xFF94A3B8);

class RiderActiveOrderScreen
    extends StatefulWidget {

  final String orderId;

  // Amplification-reduction pass: when the caller just received a fresh, complete `orders` row
  // from accept-order's own response (which already ran the authoritative update+select), it can
  // be handed in here instead of this screen re-querying the exact same row a moment later.
  // Optional and defaults to null so every OTHER entry point into this screen (opening an existing
  // active order from Home, Intercity Bookings, a push notification, Travel Plan details, etc. --
  // none of which have a just-fetched order in hand) is completely unaffected and keeps doing the
  // original full fetch below.
  final Map<String, dynamic>? initialOrder;

  // Amplification-reduction pass (fetchRiderProfile audit): RiderHomeTab already holds its own
  // `rider`/`todayEarnings` local state, kept fresh via its own realtime subscription -- when this
  // screen is opened FROM RiderHomeTab, that data can be handed in here instead of fetchRiderProfile()
  // re-querying the same `riders`+`rider_kyc` row and re-summing today's earnings a moment later.
  // Optional and defaults to null so every OTHER entry point (Intercity Bookings, push-notification
  // deep link, Travel Plan details, the accept-order flow, etc. -- none of which hold this data)
  // is completely unaffected and keeps calling fetchRiderProfile() exactly as before.
  final Map<String, dynamic>? initialRiderProfile;
  final double? initialTodayEarnings;

  const RiderActiveOrderScreen({

    super.key,

    required this.orderId,

    this.initialOrder,

    this.initialRiderProfile,

    this.initialTodayEarnings,
  });

  @override
  State<RiderActiveOrderScreen>
      createState() =>
          _RiderActiveOrderScreenState();
}

class _RiderActiveOrderScreenState
    extends State<RiderActiveOrderScreen> {

  final supabase =
      Supabase.instance.client;

  Map<String, dynamic>? order;

  bool loading = true;

  // Single in-flight guard for updateStatus (H18): prevents a duplicate
  // update-order-status call if a swipe/tap fires again before the first
  // request resolves.
  bool _updatingStatus = false;

  // P1-D: defensive single-flight guard for _reconcileAfterTimeout -- see its doc comment.
  bool _reconciling = false;
  // Event-driven reconciliation (see _reconcileAfterTimeout): when set, listenRealtime()'s own
  // callback below completes this the moment it observes order_status == _reconcileTargetStatus,
  // so a timed-out request's eventual success is confirmed via the SAME realtime subscription this
  // screen already keeps live, instead of only ever polling.
  Completer<bool>? _reconcileCompleter;
  String? _reconcileTargetStatus;

  String? realtimeSubId;

  WebViewController? mapController;
  StreamSubscription<Position>? _localLocationSubscription;

  // ---------------------------------------------------------------------------
  // Phase 2A -- rider GPS -> WebView map presentation throttle.
  //
  // The local GPS stream below is PRESENTATION-ONLY: _onLocalLocationUpdate() does nothing but
  // push the position into the tracking WebView via runJavaScript(). It never writes to the DB
  // and never feeds dispatch -- the backend/dispatch GPS path is LocationCacheService's own
  // separate stream (which already runs at a 10s interval and writes riders.current_lat/heading).
  // So it is safe to rate-limit this path to the map's refresh needs without touching tracking
  // correctness.
  //
  // Behaviour: at most one runJavaScript(updateRiderLocation) call per _mapPushMinGap; while one
  // JS eval is still in flight the newest fix is stashed in _pendingMapPosition (latest-value-
  // wins, never a growing queue) and flushed the moment the previous call resolves / the gap
  // elapses, whichever is later.
  static const Duration _mapPushMinGap = Duration(milliseconds: 1000);
  DateTime? _lastMapPushAt;
  Position? _pendingMapPosition;
  bool _mapPushInFlight = false;
  Timer? _mapPushTimer;

  // Set at the very top of dispose() so any in-flight throttle callback / JS future that resolves
  // after teardown becomes a no-op instead of touching a disposed controller.
  bool _disposed = false;

  // One-shot guard for the WebView main-document failure recovery (see _initMapController).
  int _mapReloadAttempts = 0;

  bool get _useMockMap {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  final otpController =
      TextEditingController();

  Duration elapsed =
      Duration.zero;

  Timer? timer;

  DateTime? acceptedAt;

  Map<String, dynamic>? riderProfile;
  double todayEarnings = 0.0;
  bool showingCompletionDialog = false;

  // Government tax for the completion screen's "YOUR TRIP EARNINGS" figure -- fetched ONCE per
  // order (guarded by _completionTaxOrderId) so the hero card at the top of buildCompletionScreen
  // and the DEDUCTIONS section further down always show the identical value, never two
  // independently-fetched numbers that could disagree.
  String? _completionTaxOrderId;
  bool _completionTaxLoading = true;
  double _completionGovTaxAmount = 0.0;
  double _completionGovTaxRate = 0.0;

  Future<void> _loadCompletionGovernmentTax(String orderId) async {
    try {
      // Egress fix (Fix #6): a government_tax_ledger ORDER_TAX row is immutable once written, so
      // it's safe to cache per order_id (GovernmentTaxLedgerCache never caches a null/not-found
      // result -- see that class's doc for the Phase 2/Issue 5 "shows ₹0.00" fix this is part of).
      final row = await GovernmentTaxLedgerCache.get(
        orderId,
        () => supabase
            .from('government_tax_ledger')
            .select('amount, rate_percent')
            .eq('order_id', orderId)
            .eq('entry_type', 'ORDER_TAX')
            .maybeSingle(),
      );
      if (!mounted || _completionTaxOrderId != orderId) return;
      if (row == null) {
        // Issue 5 fix: settlement writes the order's terminal status and its government-tax
        // ledger row in the SAME atomic transaction (confirm_intercity_parcel_payment_received()/
        // complete_order_and_settle()), so a genuinely-missing row here should be exceptionally
        // rare -- but silently locking this screen onto "0.00 forever" if it ever does happen
        // (a defensive read racing something outside this app, e.g. connection-level staleness)
        // is exactly the class of bug this fix removes. Clearing _completionTaxOrderId lets the
        // very next rebuild (pull-to-refresh, a realtime order update, re-opening this order)
        // retry the fetch instead of latching onto a stale empty result for the rest of this
        // screen instance's lifetime.
        setState(() {
          _completionGovTaxAmount = 0.0;
          _completionGovTaxRate = 0.0;
          _completionTaxLoading = false;
          _completionTaxOrderId = null;
        });
        return;
      }
      setState(() {
        _completionGovTaxAmount = double.tryParse(row['amount']?.toString() ?? '0') ?? 0.0;
        _completionGovTaxRate = double.tryParse(row['rate_percent']?.toString() ?? '0') ?? 0.0;
        _completionTaxLoading = false;
      });
    } catch (_) {
      if (!mounted || _completionTaxOrderId != orderId) return;
      // Issue 5 fix: a transient fetch failure (network blip right after a heavy settlement call)
      // must not permanently show ₹0 for this order either -- clear the guard so the next rebuild
      // retries instead of giving up for the rest of this screen instance's lifetime.
      setState(() {
        _completionTaxLoading = false;
        _completionTaxOrderId = null;
      });
    }
  }
  String? optimizedGeometry;
  bool fetchingRoute = false;
  bool _isUploadingPhoto = false;
  bool pickupPhotoCompleted = false;
  bool dropoffPhotoCompleted = false;

  DateTime? _lastRouteFetch;
  // Set when a target/status change wants an immediate route refresh but a Directions request was
  // already in flight -- consumed in fetchOptimizedRoute's finally block so the change is retried
  // the instant the in-flight request completes instead of being silently dropped (the function
  // early-returns when `fetchingRoute` is already true). WayDrop Ola Directions egress reduction
  // (2026-08-22).
  bool _pendingForceRouteFetch = false;

  // WayDrop Ola Directions egress reduction (2026-08-22): startTimer()'s periodic check used to
  // refetch Directions whenever >25s had passed (in practice ~30s, quantized by the 15s tick
  // below) regardless of how far the rider still was from the target. Replaced with a
  // distance-to-target-aware floor, matching the passenger-side throttle in
  // ride_tracking_screen.dart: far from the target a stale-by-tens-of-seconds polyline is
  // visually indistinguishable, so the floor widens; close to the target it stays tighter.
  static const double _nearTargetThresholdMeters = 600;
  static const int _farRefreshIntervalSeconds = 40;
  static const int _nearRefreshIntervalSeconds = 20;

  // WayDrop Ola Directions egress reduction -- Phase 10E 2B follow-up. startTimer()'s throttle
  // condition was `optimizedGeometry == null || <interval elapsed>`: while no route geometry was
  // held (the first fetch after load, or -- the real problem -- a fetch that failed or timed out)
  // the `optimizedGeometry == null` disjunct short-circuited the interval check entirely, so a
  // persistently-failing route re-hit Ola Directions on *every* 15s timer tick. A route that has
  // not resolved yet now retries on this bounded interval instead. Kept deliberately tighter than
  // the "far" interval so a broken route still recovers quickly, but strictly wider than the 15s
  // tick so it can no longer fire on every tick. A route we already hold keeps using the adaptive
  // near/far interval above, unchanged.
  static const int _failedRouteRetryIntervalSeconds = 20;

  // Item 1: route_id for this order's travel plan, used by _startIntercityTrip -- see
  // _loadIntercityRequestMeta.
  String? _intercityRouteId;
  // Post-start individual cancellation fix: this order's own intercity_requests.id, used to call
  // cancel_intercity_request_by_traveller from confirmCancellation -- see _loadIntercityRequestMeta.
  String? _intercityRequestId;
  // Phase 12 (Part C correction): the travel plan's own vehicle_type for THIS order/trip --
  // authoritative for the traveller's own tracking marker and completion-screen vehicle image.
  // orders.vehicle_type is the PASSENGER's booking-time preference (can even be null for an "any"
  // request) and must never be treated as the traveller's actual vehicle -- see
  // _loadIntercityRequestMeta and the matching, already-correct pattern in
  // realtime_order_controller.dart's _fetchRider(). null for local ride/parcel orders (untouched).
  String? _intercityPlanVehicleType;

  // Driver's own uploaded Personal QR + reference VPA, lazy-loaded the first time this order
  // reaches payment_pending (see _ensureMyPayoutInfoLoaded). Shown fullscreen via
  // showPersonalQrFullscreen -- never regenerated/modified per ride, per the QR-based direct-
  // payment architecture (a static personal QR, exactly as issued by GPay/PhonePe/Paytm/the bank).
  Map<String, dynamic>? _myPayoutInfo;
  String? _myQrSignedUrl;
  bool _loadingPayoutInfo = false;

  // In-flight guard + last result for the "Cashfree QR" button (create-fare-qr), so a second tap
  // while one call is already running doesn't mint a second Cashfree order for the same fare.
  bool _loadingCashfreeQr = false;

  @override
  void initState() {
    super.initState();
    ActiveOrderScreenState.isOpen.value = true;
    PipService.setPipEnabled(true);
    PipService.onPipRecenter = () {
      if (!_useMockMap && mapController != null) {
        mapController?.runJavaScript('recenterToRider();');
      }
    };
    PipService.onPipZoomIn = () {
      if (!_useMockMap && mapController != null) {
        mapController?.runJavaScript('zoomIn();');
      }
    };
    PipService.onPipZoomOut = () {
      if (!_useMockMap && mapController != null) {
        mapController?.runJavaScript('zoomOut();');
      }
    };
    loadOrder();
    listenRealtime();
    if (widget.initialRiderProfile != null) {
      // Seeded path -- see initialRiderProfile's doc comment above. fetchRiderProfile() itself is
      // untouched and remains the only implementation every post-completion call site uses; this
      // branch only replaces the ONE-TIME initState fetch when the caller already has fresh data.
      riderProfile = widget.initialRiderProfile;
      todayEarnings = widget.initialTodayEarnings ?? 0.0;
      if (!_useMockMap) {
        _triggerInitialLocation();
      }
    } else {
      fetchRiderProfile();
    }
  }

  @override
  void dispose() {
    // Phase 2A: mark disposed first so any throttle-timer callback or in-flight runJavaScript
    // future that resolves during/after teardown short-circuits instead of using a dead controller.
    _disposed = true;
    ActiveOrderScreenState.isOpen.value = false;
    PipService.setPipEnabled(false);
    PipService.onPipRecenter = null;
    PipService.onPipZoomIn = null;
    PipService.onPipZoomOut = null;
    if (realtimeSubId != null) {
      RealtimeManager.instance.unsubscribe('active-order-${widget.orderId}', realtimeSubId!);
      realtimeSubId = null;
    }
    timer?.cancel();
    otpController.dispose();
    _localLocationSubscription?.cancel();
    _localLocationSubscription = null;
    _mapPushTimer?.cancel();
    _mapPushTimer = null;
    _pendingMapPosition = null;

    // Phase 2A -- explicit WebView teardown. ola_map_tracking_rider.html only tears the map/engine
    // down on the document 'unload' event, which does not reliably fire when Flutter disposes the
    // platform WebView without a navigation -- leaking the MapLibre GL context, its RAF render loop,
    // and the rider-marker animation frame for the life of the process. Both JS functions are
    // already idempotent (they guard on window.riderMarker / window.MapState.map), the call is
    // wrapped in try/catch on the JS side and .catchError on the Dart side, and it is fire-and-
    // forget because dispose() cannot await. Skipped entirely on the mock/desktop map path.
    if (!_useMockMap) {
      final controller = mapController;
      if (controller != null) {
        controller
            .runJavaScript(
              'try { '
              'if (typeof destroyTrackingEngine === "function") { destroyTrackingEngine(); } '
              'if (typeof destroyMap === "function") { destroyMap(); } '
              '} catch (e) {}',
            )
            .catchError((_) {});
      }
    }

    super.dispose();
  }

  // =========================================================
  // AUTOMATIC LOCATION CAPTURE
  // =========================================================

  Future<Position?> _getCurrentLocation() async {
    try {
      final cached = LocationCacheService.cachedPosition;
      if (cached != null) return cached;

      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return null;
      
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return null;
      }
      if (permission == LocationPermission.deniedForever) return null;

      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 5),
      );
    } catch (_) {
      try {
        return await Geolocator.getLastKnownPosition();
      } catch (_) {
        return null;
      }
    }
  }

  // =========================================================
  // MANDATORY PHOTO UPLOAD & BYPASS
  // =========================================================

  Future<void> loadVerifications() async {
    try {
      final verificationsRes = await supabase
          .from('order_verifications')
          .select('verification_type, verification_status')
          .eq('order_id', widget.orderId);

      if (mounted) {
        setState(() {
          pickupPhotoCompleted = (verificationsRes as List).any((v) =>
              v['verification_type'] == 'pickup' &&
              (v['verification_status'] == 'verified' || v['verification_status'] == 'bypassed'));
          dropoffPhotoCompleted = (verificationsRes as List).any((v) =>
              v['verification_type'] == 'dropoff' &&
              (v['verification_status'] == 'verified' || v['verification_status'] == 'bypassed'));
        });
      }
    } catch (e) {
      debugPrint('Error loading verifications: $e');
    }
  }

  Future<void> _takeVerificationPhoto(String type) async {
    try {
      final picker = ImagePicker();
      final XFile? file = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 70,
      );
      if (file == null) return;

      setState(() {
        _isUploadingPhoto = true;
      });

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final uniqueId = '${timestamp}_${timestamp % 100000}';
      final path = 'orders/${widget.orderId}/verifications/$type/$uniqueId.jpg';

      final fileBytes = await file.readAsBytes();
      await supabase.storage.from('parcel_images').uploadBinary(
        path,
        fileBytes,
        fileOptions: const FileOptions(
          upsert: true,
          contentType: 'image/jpeg',
        ),
      );

      final String publicUrl = supabase.storage
          .from('parcel_images')
          .getPublicUrl(path);

      final pos = await _getCurrentLocation();
      final deviceId = await DeviceInfoHelper.getDeviceId();

      final response = await supabase.functions.invoke(
        'process-verification-photo',
        body: {
          'order_id': widget.orderId,
          'photo_type': type,
          'photo_url': publicUrl,
          'latitude': pos?.latitude,
          'longitude': pos?.longitude,
          'rider_id': order?['rider_id'],
          'device_id': deviceId,
        },
      );

      final data = response.data;
      if (data == null || data['success'] != true) {
        final errMsg = data?['error'] ?? data?['message'] ?? 'Unknown error';
        throw Exception(errMsg);
      }

      await loadVerifications();
      await _maybeGenerateIntercityDeliveryOtpAfterProof(type);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${type == 'pickup' ? 'Pickup' : 'Dropoff'} verification photo uploaded successfully!'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (mounted) {
        _showBypassDialog(type, e.toString());
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingPhoto = false;
        });
      }
    }
  }

  // Phase 3 fix (Issue 5): for intercity_parcel only, the delivery/completion OTP is generated
  // (server-side, gated on this exact photo proof, never returned to this client) the moment the
  // mandatory dropoff proof is satisfied -- via camera capture (here) or bypass (_bypassVerification
  // below), whichever the rider actually completes. Silent/best-effort: if this call fails, the
  // rider isn't blocked here -- the "Resend OTP" action on the next screen (regenerate_intercity_
  // delivery_otp, gated by the same photo-proof check) doubles as a recovery path.
  Future<void> _maybeGenerateIntercityDeliveryOtpAfterProof(String type) async {
    if (type != 'dropoff' || order?['order_type'] != 'intercity_parcel') return;
    try {
      await supabase.rpc('generate_intercity_delivery_otp_after_proof', params: {
        'p_order_id': widget.orderId,
      });
    } catch (e) {
      debugPrint('GENERATE INTERCITY DELIVERY OTP ERROR => $e');
    }
  }

  Future<void> _showBypassDialog(String type, String errorDetail) async {
    final reasonController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: _darkCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withOpacity(0.08), width: 1),
        ),
        title: Row(
          children: [
            const Icon(Icons.error_outline_rounded, color: Colors.orangeAccent, size: 24),
            const SizedBox(width: 8),
            Text(
              '${type == 'pickup' ? 'Pickup' : 'Dropoff'} Photo Failed',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ],
        ),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Photo process failed: $errorDetail\n\nDo you need to bypass verification to proceed?',
                style: const TextStyle(color: _textGray, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: reasonController,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Bypass Reason (Required)',
                  labelStyle: const TextStyle(color: _textGray, fontSize: 12),
                  hintText: 'e.g., Camera broken, network issue...',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.2), fontSize: 12),
                  filled: true,
                  fillColor: _darkBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: _primaryLime),
                  ),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Please enter a reason';
                  }
                  if (val.trim().length < 5) {
                    return 'Reason must be at least 5 characters';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'RETRY PHOTO',
              style: TextStyle(
                color: Colors.white54,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              if (formKey.currentState?.validate() == true) {
                final reason = reasonController.text.trim();
                Navigator.pop(ctx);
                await _bypassVerification(type, reason);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orangeAccent,
              foregroundColor: _darkBg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text(
              'BYPASS',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _bypassVerification(String type, String reason) async {
    try {
      setState(() {
        _isUploadingPhoto = true;
      });

      final pos = await _getCurrentLocation();
      final deviceId = await DeviceInfoHelper.getDeviceId();

      await supabase.from('order_verifications').insert({
        'order_id': widget.orderId,
        'verification_type': type,
        'verification_status': 'bypassed',
        'photo_url': null,
        'latitude': pos?.latitude,
        'longitude': pos?.longitude,
        'metadata': {
          'bypass_reason': reason,
          'device_id': deviceId,
          'bypassed_at': DateTime.now().toUtc().toIso8601String(),
        },
        'created_by': supabase.auth.currentUser?.id,
      });

      if (type == 'pickup') {
        await supabase
            .from('orders')
            .update({
              'pickup_verification_completed': true,
              'pickup_verification_completed_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', widget.orderId);
      }

      await loadVerifications();
      await _maybeGenerateIntercityDeliveryOtpAfterProof(type);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${type == 'pickup' ? 'Pickup' : 'Dropoff'} verification bypassed successfully.'),
          backgroundColor: Colors.orange,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to bypass verification: ${e.toString()}'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingPhoto = false;
        });
      }
    }
  }

  // =========================================================
  // POLICE SOS TRIGGER & BOTTOM SHEET
  // =========================================================

  Future<void> _triggerPoliceSOS() async {
    // BUG FIX: the catch block below used to call Navigator.pop(context) unconditionally
    // (guarded only by `mounted`), regardless of whether the loading dialog was still open. If
    // the FIRST insert (police_sos_logs) succeeded and the dialog was already closed at step 4,
    // but the SECOND insert (parcel_security_logs) then threw, the catch block's pop would eject
    // the rider from this entire active-order screen instead of closing an already-closed
    // dialog -- silently kicking them out of the screen mid-emergency-SOS flow. Track whether the
    // dialog is actually still showing so the catch block only ever pops it, never the screen.
    var dialogOpen = false;
    try {
      // 1. Show loading indicator
      dialogOpen = true;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => Center(
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: _darkCard,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const CircularProgressIndicator(color: _primaryLime),
          ),
        ),
      );

      // 2. Fetch coordinates
      final pos = await _getCurrentLocation();

      // 3. Log row in police_sos_logs
      // Egress fix: only police_reference_code/support_ticket_code are read below (in this
      // function and _showPoliceSosBottomSheet).
      final response = await supabase
          .from('police_sos_logs')
          .insert({
            'order_id': widget.orderId,
            'rider_id': order?['rider_id'],
            'rider_lat': pos?.latitude,
            'rider_lng': pos?.longitude,
            'latitude': pos?.latitude,
            'longitude': pos?.longitude,
          })
          .select('police_reference_code, support_ticket_code')
          .single();

      // 4. Close spinner
      if (mounted && dialogOpen) {
        Navigator.pop(context);
        dialogOpen = false;
      }

      // 5. Log in parcel_security_logs
      await supabase.from('parcel_security_logs').insert({
        'order_id': widget.orderId,
        'sender_user_id': order?['user_id'],
        'rider_id': order?['rider_id'],
        'event_type': 'police_sos_opened',
        'latitude': pos?.latitude,
        'longitude': pos?.longitude,
        'event_latitude': pos?.latitude,
        'event_longitude': pos?.longitude,
        'device_id': order?['created_device_ref'] ?? 'DEV-UNKNOWN',
        'metadata': {
          'police_reference_code': response['police_reference_code'],
          'support_ticket_code': response['support_ticket_code'],
          'client_timestamp': DateTime.now().toUtc().toIso8601String(),
        }
      });

      // 6. Open the Police SOS compliance bottom sheet
      if (mounted) {
        _showPoliceSosBottomSheet(response);
      }
    } catch (e) {
      if (mounted) {
        // Close spinner only if it's actually still open -- never pop the active-order screen.
        if (dialogOpen) {
          Navigator.pop(context);
          dialogOpen = false;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to trigger SOS: ${e.toString()}'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _showPoliceSosBottomSheet(Map<String, dynamic> sosLog) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _darkCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(26),
        ),
      ),
      builder: (context) {
        final status = order?['order_status']?.toString();
        final otpTransferVerified = status == 'picked_up' || status == 'rider_at_drop' || status == 'delivered';
        final photoVerified = order?['pickup_verification_completed'] == true;
        final declarationAccepted = order?['sender_declaration_accepted'] == true;

        final parcelImages = (order?['parcel_images'] as List?)?.cast<String>() ?? [];

        return SafeArea(
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.85,
            ),
            padding: const EdgeInsets.all(24.0),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                // Header indicator
                Center(
                  child: Container(
                    width: 48,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.security_rounded, color: Colors.redAccent, size: 24),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'WayDrop Compliance Record',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Official Law Enforcement Dispatch Information',
                            style: TextStyle(
                              color: _textGray,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
  
                // Booking Details Container
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _darkBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 1),
                  ),
                  child: Column(
                    children: [
                      _buildComplianceInfoRow('Order Code', order?['order_code']?.toString() ?? 'N/A'),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Divider(color: Colors.white10, height: 1),
                      ),
                      _buildComplianceInfoRow('Police Reference', sosLog['police_reference_code']?.toString() ?? 'Pending'),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Divider(color: Colors.white10, height: 1),
                      ),
                      _buildComplianceInfoRow('Support Ticket', sosLog['support_ticket_code']?.toString() ?? 'Pending'),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
  
                // Verification status list
                const Text(
                  'COMPLIANCE CHECKLIST',
                  style: TextStyle(
                    color: _textGray,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 12),
                _buildComplianceCheckItem('Verified Sender ✓', declarationAccepted),
                _buildComplianceCheckItem('Verified Booking ✓', true),
                _buildComplianceCheckItem('OTP Transfer Verified ✓', otpTransferVerified),
                _buildComplianceCheckItem('Photo Verification Completed ✓', photoVerified),
                
                if (parcelImages.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  const Text(
                    'PARCEL IMAGES',
                    style: TextStyle(
                      color: _textGray,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 80,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: parcelImages.length,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            // 80x80 display size: downsample the decoded image in memory
                            // instead of holding a full-res decode.
                            child: CachedNetworkImage(
                              imageUrl: parcelImages[index],
                              width: 80,
                              height: 80,
                              fit: BoxFit.cover,
                              memCacheWidth: (80 * MediaQuery.of(context).devicePixelRatio).round(),
                              memCacheHeight: (80 * MediaQuery.of(context).devicePixelRatio).round(),
                              errorWidget: (context, url, error) => Container(
                                width: 80,
                                height: 80,
                                color: Colors.white.withValues(alpha: 0.04),
                                child: const Icon(Icons.broken_image_rounded, size: 24, color: Colors.white30),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
                
                const SizedBox(height: 24),
  
                // Safe Legal Disclaimer Wording
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'LOGISTICS CARRIER DISCLAIMER',
                        style: TextStyle(
                          color: _textGray,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        'WayDrop acts as a technology-enabled logistics platform.\n\nThe parcel was booked by a verified sender and transferred through OTP verification and photo verification procedures.\n\nThe transport partner does not have independent visibility into sealed parcel contents.\n\nAdditional compliance information may be obtained from WayDrop Support upon lawful request.',
                        style: TextStyle(
                          color: _textGray,
                          fontSize: 11,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 24),
  
                // Support Button
                ElevatedButton.icon(
                  onPressed: () async {
                    final Uri phoneUri = Uri(scheme: 'tel', path: '+919876543210');
                    if (await canLaunchUrl(phoneUri)) {
                      await launchUrl(phoneUri);
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primaryLime,
                    foregroundColor: _darkBg,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: const Icon(Icons.phone_in_talk_rounded, size: 20),
                  label: const Text(
                    'Contact WayDrop Support',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
                const SizedBox(height: 12),
                
                // Dismiss button
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'DISMISS RECORD',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
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
  }

  Widget _buildComplianceInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(color: _textGray, fontSize: 13),
        ),
        Text(
          value,
          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _buildComplianceCheckItem(String text, bool completed) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        children: [
          Icon(
            completed ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
            color: completed ? _primaryLime : Colors.white24,
            size: 18,
          ),
          const SizedBox(width: 10),
          Text(
            text,
            style: TextStyle(
              color: completed ? Colors.white : Colors.white38,
              fontSize: 13,
              fontWeight: completed ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  // =========================================================
  // LOAD ORDER
  // =========================================================

  Future<void> loadOrder() async {

    try {

      if (widget.initialOrder != null) {
        // Amplification-reduction pass: accept-order's response is the exact same authoritative
        // `orders` row (post-update, unprojected) this query would fetch -- seed from it instead of
        // re-querying every column again. The only piece that response doesn't carry is the
        // `users(...)` embed below, so that alone is fetched here, narrowly projected to just the
        // fields the original embed selected. Same final `order` shape as the branch below, at a
        // fraction of the read cost.
        order = Map<String, dynamic>.from(widget.initialOrder!);
        final passengerUserId = order?['user_id']?.toString();
        if (passengerUserId != null) {
          try {
            final usersRow = await supabase
                .from('users')
                .select('full_name, phone, user_code, gender, profile_photo_url')
                .eq('id', passengerUserId)
                .maybeSingle();
            if (usersRow != null) order!['users'] = usersRow;
          } catch (e) {
            debugPrint('LOAD ORDER (seeded) users enrichment ERROR => $e');
          }
        }
      } else {
        // Egress fix audit: deliberately left broad, not narrowed. `order` is read via 40+
        // bracket accesses across this file (pricing, OTP, verification, addresses, parcel data)
        // -- same risk class as TransportOrder.fromJson/realtime_order_controller.dart's
        // fetchOrder(), already deliberately left broad in a previous pass for the same reason.
        final response =
            await supabase

                .from('orders')

                .select('*, users(full_name, phone, user_code, gender, profile_photo_url)')

                .eq(
                  'id',
                  widget.orderId,
                )

                .single();

        order = response;
      }

      // Perf fix: these two reads are independent -- different tables (order_verifications vs
      // intercity_requests), different state fields (pickupPhotoCompleted/dropoffPhotoCompleted vs
      // _intercityRouteId/_intercityRequestId), each with its own try/catch and `mounted`-guarded
      // setState -- so running them concurrently changes only wall-clock time, not behavior.
      await Future.wait([
        loadVerifications(),
        _loadIntercityRequestMeta(),
      ]);

      if (
          order?['accepted_at'] !=
          null) {

        acceptedAt =
            DateTime.parse(
          order!['accepted_at'],
        );

        startTimer();
      }

      if (mounted) {
        setState(() {
          loading = false;
        });
        if (!_useMockMap) {
          _initMapController();
          _startLocalLocationTracking();
        }
        // Initial route for a freshly opened/reloaded screen -- forced so it isn't dropped if a
        // stray fetch somehow raced it in.
        fetchOptimizedRoute(isForced: true);
      }
    }

    catch (e) {

      debugPrint(
        'LOAD ORDER ERROR => $e',
      );
    }
  }

  // Item 1 (Start Trip business rule): route_id isn't stored directly on `orders`, so it's looked
  // up via this order's own intercity_requests row (scoped to the assigned rider via
  // traveller_id, not just parcel_id, since a rejected/older negotiation row from a different
  // traveller could otherwise share the same parcel_id). Payment status is deliberately NOT
  // fetched/tracked here -- intercity payment is collected from the passenger AFTER the trip
  // completes, not before, so Start Trip must never gate on it (see _startIntercityTrip below).
  Future<void> _loadIntercityRequestMeta() async {
    final riderId = order?['rider_id']?.toString();
    if (riderId == null) return;
    try {
      final row = await supabase
          .from('intercity_requests')
          .select('id, route_id, rider_travel_plans!intercity_requests_route_id_fkey(vehicle_type)')
          .eq('parcel_id', widget.orderId)
          .eq('traveller_id', riderId)
          .maybeSingle();
      if (mounted) {
        setState(() {
          _intercityRouteId = row?['route_id']?.toString();
          _intercityRequestId = row?['id']?.toString();
          // Phase 12 (Part C correction): the travel plan's own vehicle_type -- authoritative for
          // this trip, never orders.vehicle_type (the passenger's booking-time preference).
          _intercityPlanVehicleType =
              (row?['rider_travel_plans'] as Map?)?['vehicle_type']?.toString();
        });
      }
    } catch (e) {
      debugPrint('LOAD INTERCITY REQUEST META ERROR => $e');
    }
  }

  // =========================================================
  // TIMER
  // =========================================================

  void startTimer() {
    timer?.cancel();
    timer = Timer.periodic(
      const Duration(
        seconds: 15,
      ),
      (_) {
        final now = DateTime.now();
        final currentStatus = order?['order_status']?.toString();
        // Duplicate/validity guard (Ola egress reduction): stop the periodic Directions refresh
        // once the order is no longer active. fetchOptimizedRoute() already no-ops for these
        // statuses (neither of its target branches matches), so this is a defensive early-out,
        // not a behavior change for active orders.
        if (order == null ||
            currentStatus == 'completed' ||
            currentStatus == 'delivered' ||
            currentStatus == 'cancelled') {
          return;
        }

        final riderLat = LocationCacheService.currentLat;
        final riderLng = LocationCacheService.currentLng;

        // WayDrop Ola Directions egress reduction (2026-08-22): the refresh floor now adapts to
        // how far the rider still is from the active target instead of a flat >25s check (see the
        // constants declared with the state fields above). Falls back to the wider "far" interval
        // if the rider's own position or the target coordinates aren't available yet.
        int refreshIntervalSeconds = _farRefreshIntervalSeconds;
        if (riderLat != null && riderLng != null) {
          final pLat = double.tryParse(order?['pickup_lat']?.toString() ?? '');
          final pLng = double.tryParse(order?['pickup_lng']?.toString() ?? '');
          final dLat = double.tryParse(order?['destination_lat']?.toString() ?? '');
          final dLng = double.tryParse(order?['destination_lng']?.toString() ?? '');
          double? targetLat;
          double? targetLng;
          if (currentStatus == 'ongoing' || currentStatus == 'picked_up' || currentStatus == 'rider_at_drop') {
            targetLat = dLat;
            targetLng = dLng;
          } else {
            targetLat = pLat;
            targetLng = pLng;
          }
          if (targetLat != null && targetLng != null) {
            final distanceMeters = Geolocator.distanceBetween(riderLat, riderLng, targetLat, targetLng);
            refreshIntervalSeconds = distanceMeters <= _nearTargetThresholdMeters
                ? _nearRefreshIntervalSeconds
                : _farRefreshIntervalSeconds;
          }
        }

        // When no route geometry is held yet (initial load, or a failed/timed-out fetch) retry on
        // the bounded _failedRouteRetryIntervalSeconds instead of bypassing the throttle on every
        // tick; when a route is held, use the adaptive near/far interval. Either way the interval
        // check is now always applied -- `optimizedGeometry == null` no longer short-circuits it.
        final int effectiveIntervalSeconds = optimizedGeometry == null
            ? _failedRouteRetryIntervalSeconds
            : refreshIntervalSeconds;

        final shouldFetch = _lastRouteFetch == null ||
            now.difference(_lastRouteFetch!).inSeconds >= effectiveIntervalSeconds;

        if (shouldFetch && riderLat != null) {
          _lastRouteFetch = now;
          fetchOptimizedRoute();
        }
      },
    );
  }


  // =========================================================
  // REALTIME
  // =========================================================

  void listenRealtime() {
    if (realtimeSubId != null) {
      RealtimeManager.instance.unsubscribe('active-order-${widget.orderId}', realtimeSubId!);
      realtimeSubId = null;
    }

    realtimeSubId = RealtimeManager.instance.subscribe(
      channelName: 'active-order-${widget.orderId}',
      table: 'orders',
      owner: 'RiderActiveOrderScreen',
      event: PostgresChangeEvent.update,
      filterColumn: 'id',
      filterValue: widget.orderId,
      callback: (payload) {
        // R4 perf fix: loadVerifications() re-queries order_verifications, which only ever
        // changes alongside an `orders` UPDATE via one of two proxy columns -- pickup_verification_
        // completed (process-verification-photo / _bypassVerification, pickup only) or delivery_otp
        // (generate_intercity_delivery_otp_after_proof, intercity_parcel dropoff only). Every other
        // orders UPDATE (plain order_status transitions) was re-querying order_verifications for no
        // reason -- gate on the diff `orders` already delivers (REPLICA IDENTITY FULL) instead of a
        // fresh query.
        final oldPickupVerified = payload.oldRecord['pickup_verification_completed'];
        final newPickupVerified = payload.newRecord['pickup_verification_completed'];
        final oldDeliveryOtp = payload.oldRecord['delivery_otp'];
        final newDeliveryOtp = payload.newRecord['delivery_otp'];
        if (oldPickupVerified != newPickupVerified || oldDeliveryOtp != newDeliveryOtp) {
          loadVerifications();
        }
        final oldStatus = order?['order_status']?.toString();
        final oldUsers = order?['users'];
        order = payload.newRecord;
        if (oldUsers != null) {
          order?['users'] = oldUsers;
        }
        final newStatus = order?['order_status']?.toString();

        // Event-driven reconciliation hook (P1-D): if updateStatus()'s own request timed out and
        // _reconcileAfterTimeout is currently waiting to find out whether it actually landed, this
        // realtime delivery IS that confirmation -- resolve it immediately rather than making
        // _reconcileAfterTimeout wait for its own next poll tick.
        final pendingReconcileTarget = _reconcileTargetStatus;
        final pendingCompleter = _reconcileCompleter;
        if (pendingReconcileTarget != null &&
            pendingCompleter != null &&
            !pendingCompleter.isCompleted &&
            newStatus == pendingReconcileTarget) {
          pendingCompleter.complete(true);
        }

        if (!mounted) return;

        if (oldStatus != newStatus) {
          optimizedGeometry = null;
          // Status transition changes (or may change) the active target -- force so this can
          // never be silently dropped by the in-flight guard (see fetchOptimizedRoute).
          fetchOptimizedRoute(isForced: true);
        }

        if (newStatus == 'cancelled') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('This order was cancelled by the customer')),
          );
          if (ModalRoute.of(context)?.isCurrent == true) {
            Navigator.pop(context);
          }
          return;
        }

        final myRiderId = riderProfile?['id']?.toString();
        final currentRiderIdInOrder = order?['rider_id']?.toString();

        if (newStatus == 'searching' || 
            newStatus == 'created' || 
            (currentRiderIdInOrder == null && newStatus != 'completed' && newStatus != 'delivered') || 
            (myRiderId != null && currentRiderIdInOrder != null && currentRiderIdInOrder != myRiderId)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('This order is no longer assigned to you.')),
          );
          if (ModalRoute.of(context)?.isCurrent == true) {
            Navigator.pop(context);
          }
          return;
        }

        if (newStatus == 'completed' || newStatus == 'delivered') {
          _deleteMatchingTravelPlan();
          if (mounted && !showingCompletionDialog) {
            showingCompletionDialog = true;
            setState(() {
              loading = true;
            });
            Future.delayed(const Duration(milliseconds: 1000)).then((_) async {
              if (mounted) {
                await fetchRiderProfile();
                setState(() {
                  loading = false;
                });
              }
            });
          }
        }

        if (order?['accepted_at'] != null && acceptedAt == null) {
          acceptedAt = DateTime.tryParse(order!['accepted_at'].toString());
          startTimer();
        }

        setState(() {});
      },
    );
  }

  // =========================================================
  // AUTO-DELETE MATCHING TRAVEL PLAN ON COMPLETION
  // =========================================================
  Future<void> _deleteMatchingTravelPlan() async {
    final rId = (order?['rider_id'] ?? riderProfile?['id'])?.toString();
    if (rId == null) return;

    // Resolve THIS order's own travel plan by its intercity_requests link (route_id). This is the
    // reliable key: for a Via-declared plan the passenger often boards at an intermediate town, so
    // the order's pickup_city no longer equals the plan's pickup_city and the old city match
    // silently never fired.
    String? routeId = _intercityRouteId;
    if (routeId == null) {
      try {
        final row = await supabase
            .from('intercity_requests')
            .select('route_id')
            .eq('parcel_id', widget.orderId)
            .eq('traveller_id', rId)
            .maybeSingle();
        routeId = row?['route_id']?.toString();
      } catch (e) {
        debugPrint('resolve travel plan route_id failed: $e');
      }
    }

    // The plan is only closed once this traveller has no other trip still running on it -- a
    // multi-seat plan stays on Home until the last passenger's trip ends (mirrors the server-side
    // completion guard in update-order-status).
    const inFlightStatuses = [
      'accepted',
      'rider_arrived',
      'picked_up',
      'rider_at_drop',
      'ongoing',
      'payment_pending',
    ];

    try {
      if (routeId != null) {
        List<String> siblingOrderIds = const [];
        try {
          final reqs = await supabase
              .from('intercity_requests')
              .select('parcel_id')
              .eq('route_id', routeId)
              .inFilter('status', ['confirmed', 'paid', 'in_progress']);
          siblingOrderIds = List<Map<String, dynamic>>.from(reqs)
              .map((r) => r['parcel_id']?.toString())
              .whereType<String>()
              .where((id) => id != widget.orderId)
              .toList();
        } catch (e) {
          debugPrint('resolve sibling orders failed: $e');
        }

        if (siblingOrderIds.isNotEmpty) {
          final stillActive = await supabase
              .from('orders')
              .select('id')
              .inFilter('id', siblingOrderIds)
              .inFilter('order_status', inFlightStatuses)
              .limit(1);
          if ((stillActive as List).isNotEmpty) {
            debugPrint('Travel plan $routeId kept visible: another passenger trip is still active.');
            return;
          }
        }

        // NOTE: covers both 'active' AND 'fully_booked' -- a plan is auto-flipped to
        // 'fully_booked' once its confirmed bookings reach max_bookings (trigger from
        // 20260617000001), which for a single-seat plan is the very first acceptance, so by
        // completion time the plan is almost never still 'active'.
        await supabase
            .from('rider_travel_plans')
            .update({'status': 'completed'})
            .eq('id', routeId)
            .inFilter('status', ['active', 'fully_booked']);
        debugPrint('Travel plan $routeId marked completed after trip completion.');
        return;
      }

      // Fallback for orders with no resolvable intercity_requests link: endpoint-city match,
      // now also covering 'fully_booked'.
      final pCity = order?['pickup_city'];
      final dCity = order?['destination_city'];
      if (pCity != null && dCity != null) {
        await supabase
            .from('rider_travel_plans')
            .update({'status': 'completed'})
            .eq('rider_id', rId)
            .inFilter('status', ['active', 'fully_booked'])
            .eq('pickup_city', pCity)
            .eq('destination_city', dCity);
        debugPrint('Matching travel plan marked as completed (city fallback).');
      }
    } catch (e) {
      debugPrint('Error completing matching travel plan: $e');
    }
  }

  // =========================================================
  // UPDATE STATUS
  // =========================================================

  Future<bool> updateStatus(
    String status, {
    String? pickupOtp,
    String? deliveryOtp,
    // Personal-UPI fare payments only -- optional driver-entered evidence for the disputes flow
    // (this payment method has no gateway confirmation of its own; see update-order-status).
    String? farePaymentReference,
    // Driver's own declaration of which DIRECT method they collected via ('personal_upi' | 'cash'),
    // sent only on the payment_pending -> completed transition -- see update-order-status's
    // settlement_method handling.
    String? settlementMethod,
  }) async {
    if (_updatingStatus) return false;
    _updatingStatus = true;
    try {
      // Issue 5 fix: intercity_parcel's payment_pending -> delivered settlement has its own
      // authoritative RPC, confirm_intercity_parcel_payment_received() -- mirrors how this
      // order type's OTP-verify step already exclusively uses complete_intercity_parcel_delivery()
      // rather than the generic update-order-status edge function below, which does not run
      // intercity_parcel's specific subscription/tax-due/rider_travel_plans-completion-sync
      // settlement side effects (see that RPC's own migration header for the prior
      // dual-completion-path bug this avoids reintroducing). Every other order type/transition
      // continues through the unchanged generic path below.
      final orderType = order?['order_type']?.toString();
      final currentOrderStatus = order?['order_status']?.toString();
      if (orderType == 'intercity_parcel' &&
          currentOrderStatus == 'payment_pending' &&
          (status == 'delivered' || status == 'completed')) {
        final response = await supabase
            .rpc('confirm_intercity_parcel_payment_received', params: {'p_order_id': widget.orderId})
            .timeout(const Duration(seconds: 25));
        final data = Map<String, dynamic>.from(response as Map);
        if (data['success'] != true) {
          throw Exception(data['message'] ?? 'Unknown error');
        }
        await _deleteMatchingTravelPlan();
        if (mounted && order != null) {
          setState(() {
            order!['order_status'] = 'delivered';
          });
        }
        return true;
      }

      final pos = await _getCurrentLocation();
      final deviceId = await DeviceInfoHelper.getDeviceId();
      final response = await supabase.functions.invoke(
        'update-order-status',
        body: {
          'order_id': widget.orderId,
          'new_status': status,
          'pickup_otp': pickupOtp,
          'delivery_otp': deliveryOtp,
          'changed_by': supabase.auth.currentUser?.id,
          if (pos != null) 'latitude': pos.latitude,
          if (pos != null) 'longitude': pos.longitude,
          'device_id': deviceId,
          if (farePaymentReference != null && farePaymentReference.isNotEmpty)
            'fare_payment_reference': farePaymentReference,
          if (settlementMethod != null) 'settlement_method': settlementMethod,
        },
        // CLIENT-1 (WayDrop Progressive Degradation Audit): bounded so a stalled backend surfaces
        // as the same caught exception below (SnackBar + _updatingStatus reset), instead of
        // leaving the rider stuck on a swipe/tap with no feedback — the direct cause of "intercity
        // trip completion becomes very slow" reads as an infinite wait without this.
      ).timeout(const Duration(seconds: 25));

      final data = response.data;
      if (data == null || data['success'] != true) {
        final errMsg = data?['error'] ?? data?['message'] ?? 'Unknown error';
        throw Exception(errMsg);
      }

      if (status == 'completed' || status == 'delivered') {
        await _deleteMatchingTravelPlan();
      }

      // Reflect the just-confirmed status locally right away -- `order` is otherwise only
      // refreshed by the realtime subscription (see `order = payload.newRecord;` above), which
      // has network round-trip latency. Without this, a rider tapping Cancel in that window
      // (e.g. right after SWIPE TO ARRIVE) computes its target status from the stale pre-update
      // value and sends a transition the backend has already moved past -- surfaced to the rider
      // as "Invalid transition from rider_arrived to searching". This mirrors the shape of the
      // authoritative row without altering any transition rule.
      if (mounted && order != null) {
        setState(() {
          order!['order_status'] = status;
        });
      }

      return true;
    } on TimeoutException {
      // FIX (Client Retry Storm, WayDrop Progressive Degradation investigation, 2026-08-08):
      // Future.timeout() only stops THIS call from waiting -- it never cancels the underlying
      // update-order-status invocation, which can still be executing (and, under the backend
      // contention proven live, often still IS executing well past 25s). Blindly falling through
      // to the generic catch below and releasing _updatingStatus would let the rider immediately
      // retry while that orphaned request is still in flight -- proven live to be exactly how Ride
      // 4's two pairs of overlapping concurrent update-order-status calls (up to 46.5s row-lock
      // waits each) came about. Ask the server what actually happened before deciding whether a
      // retry is even necessary.
      return await _reconcileAfterTimeout(status);
    } catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceAll('Exception: ', '')),
          backgroundColor: Colors.redAccent,
        ),
      );
      return false;
    } finally {
      _updatingStatus = false;
    }
  }

  /// Reconciles against the authoritative server-side order_status after updateStatus()'s own
  /// 25s client timeout fires, instead of assuming the transition failed. Two outcomes:
  ///   - The timed-out request actually succeeded server-side (order_status already == targetStatus)
  ///     -> treat this exactly like a normal success, no retry, no duplicate request ever sent.
  ///   - It genuinely hasn't landed yet -> safe to let the rider retry now. Even in the residual
  ///     race where the original orphaned request finally lands AFTER a retry, update-order-status's
  ///     own optimistic lock (`.eq('order_status', currentStatus)`) already guarantees the loser is a
  ///     harmless no-op, exactly as it does for any other concurrent-call scenario the server was
  ///     already designed to handle -- this fix only avoids needlessly creating that contention in
  ///     the first place, it isn't the only thing preventing a double-applied transition.
  /// This method deliberately does NOT introduce any persistent/cross-session lock: _updatingStatus
  /// stays a plain in-memory field (cleared here in every branch, and implicitly reset by a fresh
  /// widget instance on app restart), so a rider can never be permanently stranded by this guard.
  ///
  /// P1-D v2 (WayDrop consolidated performance/correctness pass): the previous fixed 3-check/~16s
  /// polling window was PROVEN insufficient by a real forensic incident (order 66759dad-b386-4814-
  /// 8065-c6f9182e5c01, WDPHI3039) -- the rider's genuinely-correct first delivery attempt didn't
  /// even reach its own `orders_update` step until ~40s after the client gave up, and didn't finish
  /// settling until well over a minute later. All three of the old checks landed before any of that,
  /// so the rider was wrongly told to retry.
  ///
  /// Rather than just widening the polling window (more requests, same blind-guessing shape), this
  /// races TWO confirmation sources and takes whichever arrives first:
  ///   1. Realtime -- this screen's own `listenRealtime()` subscription is already live and already
  ///      updates `order` on every change to this exact row; the moment it observes
  ///      order_status == targetStatus, it completes `_reconcileCompleter` directly (see the hook in
  ///      that callback) -- near-instant once Postgres Changes delivers the event, no extra request.
  ///   2. A polling fallback (`_pollForStatus`) for exactly the case realtime itself is degraded --
  ///      spaced-out checks, not a tight loop, still bounded by the same overall window.
  /// Both share one 90s overall bound -- generous enough to cover the worst case actually observed
  /// live, while the event-driven path means the COMMON case (realtime healthy) resolves in
  /// milliseconds once the DB write lands, not after a fixed multi-second wait regardless.
  ///
  /// `_reconciling` is a defensive single-flight guard: updateStatus's own `_updatingStatus` guard
  /// already prevents two updateStatus calls from overlapping, so this only protects against this
  /// method itself somehow being re-entered, and — like `_updatingStatus` — is a plain in-memory
  /// field with no persistence, cleared in `finally` on every path. This method still never writes
  /// anything -- it only ever reads/observes -- so it cannot itself create a duplicate settlement;
  /// that guarantee continues to come entirely from the server's own optimistic-lock UPDATE.
  Future<bool> _reconcileAfterTimeout(String targetStatus) async {
    if (_reconciling) return false;
    _reconciling = true;
    _reconcileTargetStatus = targetStatus;
    _reconcileCompleter = Completer<bool>();
    try {
      final matched = await Future.any([
        _reconcileCompleter!.future,
        _pollForStatus(targetStatus),
      ]).timeout(const Duration(seconds: 90), onTimeout: () => false);

      if (matched) {
        if (mounted && order != null) {
          setState(() {
            order!['order_status'] = targetStatus;
          });
        }
        return true;
      }

      // Neither realtime nor polling saw the target status land within the window -- fail OPEN
      // exactly as before: let the rider retry, never strand them behind this guard.
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That took longer than expected. Please try again.'),
          backgroundColor: Colors.orangeAccent,
        ),
      );
      return false;
    } finally {
      _reconciling = false;
      _reconcileTargetStatus = null;
      _reconcileCompleter = null;
    }
  }

  /// Polling fallback for _reconcileAfterTimeout, used only for whatever portion of its 90s window
  /// elapses before realtime confirms (or if realtime is itself degraded). Spaced out rather than a
  /// tight loop -- this is a fallback path, not the primary confirmation mechanism.
  Future<bool> _pollForStatus(String targetStatus) async {
    const delays = [
      Duration.zero,
      Duration(seconds: 3),
      Duration(seconds: 6),
      Duration(seconds: 10),
      Duration(seconds: 15),
      Duration(seconds: 20),
      Duration(seconds: 20),
    ];
    for (final delay in delays) {
      if (delay > Duration.zero) {
        await Future.delayed(delay);
        if (!mounted) return false;
      }
      try {
        final latest = await supabase
            .from('orders')
            .select('order_status')
            .eq('id', widget.orderId)
            .single()
            .timeout(const Duration(seconds: 10));

        if (latest['order_status']?.toString() == targetStatus) {
          return true;
        }
      } catch (e) {
        // A single check failing (e.g. a transient network hiccup) doesn't mean the fallback itself
        // is unreachable -- fall through to the next scheduled check.
        debugPrint('Reconcile poll check error: $e');
      }
    }
    return false;
  }

  // =========================================================
  // INTERCITY PARCEL: MARK ARRIVED AT DROP-OFF
  // =========================================================

  // BUG FIX (intercity parcel drop-off stuck at "Continue in Travel Plan"): the generic parcel
  // flow's "SWIPE TO ARRIVE AT DROP" button used to call updateStatus('rider_at_drop') directly
  // for every parcel order type, including intercity_parcel. For local_parcel that is correct --
  // but for intercity_parcel it bypassed mark_intercity_trip_at_dropoff(), the SECURITY DEFINER
  // RPC that is the ONLY place a fresh, server-generated delivery OTP is ever issued for this
  // order type (see 20260730000004_intercity_parcel_delivery_settlement.sql and
  // intercity_bookings_screen.dart's _markRideArrived(), which already calls this same RPC for
  // its own "Arrived" button). update-order-status runs as service_role, so
  // protect_order_state_columns_trigger did not block that direct path either -- order_status
  // still reached 'rider_at_drop' via the generic route, but with delivery_otp left at whatever
  // stale value existed from order creation, and the receiver was never issued the real
  // completion OTP. The traveller then landed on a dead-end screen with no way to actually
  // complete the delivery (that dead-end was later replaced by an in-place completion flow, see
  // the Issue 9 fix in the 'rider_at_drop' branch of buildBottomButton() below). Fix here: for
  // intercity_parcel only,
  // route this exact same transition through mark_intercity_trip_at_dropoff instead, mirroring
  // _markRideArrived's call/response handling exactly. local_parcel, local rides, and intercity
  // rides are untouched -- this method is only ever invoked from the intercity_parcel branch
  // below.
  Future<void> _markIntercityParcelAtDropoff() async {
    if (_updatingStatus) return;
    _updatingStatus = true;
    try {
      final response = await supabase.rpc('mark_intercity_trip_at_dropoff', params: {
        'p_order_id': widget.orderId,
      });
      final data = response is Map ? Map<String, dynamic>.from(response) : null;
      if (data == null || data['success'] != true) {
        throw Exception((data?['message'] as String?) ?? 'Failed to mark arrived. Please try again.');
      }

      if (!mounted) return;
      // Phase 3 fix (Issue 5): mark_intercity_trip_at_dropoff() no longer generates/returns a
      // delivery OTP for intercity_parcel -- it is generated only after the mandatory delivery-
      // proof photo, by generate_intercity_delivery_otp_after_proof() (called automatically from
      // _takeVerificationPhoto('dropoff') below), and is never shown to the traveller at all.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Marked arrived at drop-off. Please capture the delivery proof photo to continue.'),
          backgroundColor: Colors.green,
        ),
      );

      // Same local-state reflection updateStatus() already does on success -- realtime will
      // reconcile `order` fully once the postgres_changes event for this RPC's UPDATE arrives.
      if (order != null) {
        setState(() {
          order!['order_status'] = 'rider_at_drop';
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceAll('Exception: ', '')),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      _updatingStatus = false;
    }
  }

  // =========================================================
  // PERSONAL QR / CASHFREE QR (payment_pending, QR-based direct-payment architecture)
  // =========================================================

  Future<void> _ensureMyPayoutInfoLoaded() async {
    if (_myPayoutInfo != null || _loadingPayoutInfo) return;
    setState(() => _loadingPayoutInfo = true);
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;
      // Egress fix (Fix #6 completion): shared via RiderPayoutAccountCache with the other
      // display/edit reads of this same row -- see that class's doc comment.
      final info = await RiderPayoutAccountCache.get(
        user.id,
        () => supabase
            .from('rider_payout_accounts')
            .select(
              'beneficiary_name, beneficiary_phone, beneficiary_email, upi_vpa, '
              'personal_qr_path, account_number, ifsc_code, beneficiary_id, '
              'cashfree_beneficiary_status, default_fare_payment_method, upi_self_certified',
            )
            .eq('user_id', user.id)
            .maybeSingle(),
      );

      String? signedUrl;
      final qrPath = info?['personal_qr_path']?.toString();
      if (qrPath != null && qrPath.isNotEmpty) {
        try {
          // Egress fix (Fix #10B): cached per storage path for its ~1hr validity, shared with
          // rider_payout_details_screen.dart/rider_payment_settings_screen.dart's own lookups of
          // this same rider's QR, instead of re-signing on every active-order screen open.
          signedUrl = await QrSignedUrlCache.get(
            qrPath,
            () => supabase.storage.from('driver_personal_qr').createSignedUrl(qrPath, 3600),
          );
        } catch (e) {
          debugPrint('MY QR SIGNED URL ERROR => $e');
        }
      }

      if (!mounted) return;
      setState(() {
        _myPayoutInfo = info ?? {};
        _myQrSignedUrl = signedUrl;
        _loadingPayoutInfo = false;
      });
    } catch (e) {
      debugPrint('LOAD MY PAYOUT INFO ERROR => $e');
      if (mounted) setState(() => _loadingPayoutInfo = false);
    }
  }

  // Fullscreen viewer for the driver's own uploaded, STATIC Personal QR. Never regenerated or
  // modified per ride -- the exact image the driver uploaded from their UPI app is what's shown,
  // and the passenger enters the amount themselves after scanning (see spec: fare is never
  // embedded into this QR).
  Future<void> _showPersonalQrFullscreen(double fare) async {
    await _ensureMyPayoutInfoLoaded();
    if (!mounted) return;

    final qrUrl = _myQrSignedUrl;
    final vpa = _myPayoutInfo?['upi_vpa']?.toString();

    await showDialog(
      context: context,
      barrierColor: Colors.black,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),
              const Spacer(),
              const Text(
                'Personal UPI QR',
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                'Ride Fare: ₹${fare.toStringAsFixed(0)}',
                style: const TextStyle(color: _primaryLime, fontSize: 24, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 24),
              Container(
                width: 260,
                height: 260,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                child: qrUrl != null
                    ? CachedNetworkImage(
                        imageUrl: qrUrl,
                        fit: BoxFit.contain,
                        cacheManager: QrImageCacheManager.instance,
                        memCacheWidth: (260 * MediaQuery.of(context).devicePixelRatio).round(),
                        memCacheHeight: (260 * MediaQuery.of(context).devicePixelRatio).round(),
                      )
                    : const Center(
                        child: Text(
                          'No Personal QR uploaded yet.\nAdd one in Payment Settings.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.black54, fontWeight: FontWeight.w600),
                        ),
                      ),
              ),
              if (vpa != null && vpa.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(vpa, style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w700)),
              ],
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  'Scan this QR using your preferred UPI app.\nEnter at least the ride fare. '
                  'You may pay more if you wish to add a tip.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13, height: 1.5),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }

  // Opens Cashfree's own UPI-restricted hosted checkout (create-fare-qr creates/reuses the
  // underlying Cashfree order). Cashfree itself renders a genuine per-order "Scan and Pay" QR
  // inside that checkout -- the driver holds the phone up so the passenger can scan it with any
  // UPI app. If Cashfree can't even create the order (network/account error), this shows an honest
  // "unavailable" message -- it never fabricates a QR locally or relabels checkout as a QR.
  Future<void> _showCashfreeQrFullscreen(double fare) async {
    debugPrint('STEP 1: Cashfree QR button clicked => orderId=${widget.orderId}');
    if (_loadingCashfreeQr) return;
    setState(() => _loadingCashfreeQr = true);

    final result = await PaymentService.createFareQr(orderId: widget.orderId);

    if (!mounted) {
      return;
    }
    setState(() => _loadingCashfreeQr = false);

    final available = result['qr_available'] == true;
    final paymentSessionId = result['payment_session_id']?.toString();
    final paymentCode = result['payment_code']?.toString();
    final paymentId = result['payment_id']?.toString();
    final cfOrderId = result['order_id']?.toString();
    // Logged only, never rendered -- the unavailable dialog below always shows fixed, non-technical
    // copy.
    debugPrint('CASHFREE QR => qr_available=$available reason=${result['reason'] ?? result['message']}');
    debugPrint(
      'STEP 3b: extracted from response => paymentSessionId=$paymentSessionId '
      'paymentCode=$paymentCode paymentId=$paymentId cfOrderId=$cfOrderId',
    );

    if (available && paymentSessionId != null && paymentCode != null && paymentId != null && cfOrderId != null) {
      if (!mounted) return;
      final navResult = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => PaymentProcessingScreen(
            paymentCode: paymentCode,
            paymentId: paymentId,
            orderId: cfOrderId,
            paymentSessionId: paymentSessionId,
            amount: fare,
            paymentForLabel: 'Ride Fare',
            screenTitle: 'Cashfree QR',
            instructionText: 'Tap "UPI" then "Scan and Pay" in the screen that opens, then hand '
                'your phone to the passenger to scan the QR shown there with any UPI app.',
            successHeadline: 'Payment Received!\nYou can now swipe to complete the ride.',
          ),
        ),
      );
      // Nothing further to do here for success -- buildBottomButton's payment_pending banner
      // already watches order.payment_status/fare_payment_method via the realtime order
      // subscription (listenRealtime above) and flips to "SWIPE TO COMPLETE RIDE" the instant the
      // real Cashfree webhook/poll confirms payment, whether or not this screen is still open.
      // Displaying/leaving this screen never itself marks anything paid or completes the ride.
      //
      // BUG FIX: "Retry Payment" (payment_processing_screen.dart) used to pop 'retry' into a void
      // -- the driver had to notice the screen closed and manually tap "Cashfree QR" again. Now it
      // re-invokes this same flow directly, which (combined with the create-fare-qr fix checking
      // Cashfree's live order status before reuse) always gets either the still-valid session or a
      // genuinely fresh one, instead of silently handing back the same expired session forever.
      if (navResult == 'retry' && mounted) {
        await _showCashfreeQrFullscreen(fare);
      }
      return;
    }

    await showDialog(
      context: context,
      barrierColor: Colors.black,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),
              const Spacer(),
              const Text(
                'Cashfree QR',
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                'Ride Fare: ₹${fare.toStringAsFixed(0)}',
                style: const TextStyle(color: _primaryLime, fontSize: 24, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 24),
              Container(
                width: 260,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  children: [
                    const Icon(Icons.qr_code_2_rounded, color: Colors.white54, size: 48),
                    const SizedBox(height: 12),
                    // Fixed, non-technical copy regardless of what the server/client error
                    // path reported -- `reason` is only ever logged (see above), never rendered
                    // here. No HTTP codes, raw JSON, or API error text belong on this screen.
                    const Text(
                      'Cashfree QR is temporarily unavailable.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Please use Personal QR or Cash instead.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  'This will not block the ride -- confirm payment once received via Personal QR or Cash.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }

  // =========================================================
  // CONFIRM CANCELLATION BY RIDER
  // =========================================================

  Future<void> confirmCancellation(BuildContext context) async {
    final isAtPickup = order?['order_status']?.toString() == 'rider_arrived';
    // Post-start individual cancellation fix: an intercity trip that has already started
    // (trip_started_at set) must never go through the generic "back to searching" transition --
    // order_status stays 'accepted' through Start Trip, so without this check the ride would be
    // detached and re-dispatched into the general pool for any rider, instead of being terminally
    // cancelled for this one passenger. See cancel_intercity_request_by_traveller.
    final isIntercityPostStart = _isIntercityOrder && _tripStarted;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _darkCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08), width: 1),
        ),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 24),
            SizedBox(width: 8),
            Text(
              'Cancel Ride',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ],
        ),
        content: Text(
          isIntercityPostStart
              ? 'Are you sure you want to cancel this passenger? This will cancel their booking entirely. Other passengers on this Travel Plan are not affected.'
              : isAtPickup
                  ? 'Are you sure you want to cancel this ride? This will cancel the ride entirely.'
                  : 'Are you sure you want to cancel this ride? It will go back to searching and be assigned to other riders.',
          style: const TextStyle(
            color: _textGray,
            fontSize: 14,
            height: 1.4,
          ),
        ),
        actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'NO, KEEP RIDE',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontWeight: FontWeight.w600,
                fontSize: 12,
                letterSpacing: 0.5,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            child: const Text(
              'YES, CANCEL',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      setState(() {
        loading = true;
      });

      bool success;
      if (isIntercityPostStart) {
        // Post-start individual cancellation fix: routes through the canonical, trusted
        // cancel_intercity_request_by_traveller RPC instead of update-order-status's generic
        // 'searching' transition -- terminates this passenger's order to 'cancelled' (never
        // re-dispatched), clears their OTP, and syncs intercity_requests so they disappear from
        // the Travel Plan. Other passengers on the same plan are never touched.
        success = await _cancelIntercityPassengerAfterTripStart();
      } else {
        // From 'accepted' the order still has no committed pickup, so it goes
        // back to the searching pool for another rider. From 'rider_arrived'
        // the only transition the backend allows is a real cancellation.
        final currentStatus = order?['order_status']?.toString();
        final targetStatus = currentStatus == 'rider_arrived' ? 'cancelled' : 'searching';
        success = await updateStatus(targetStatus);
      }
      if (!mounted) return;
      if (success) {
        // Pop the active order screen back to orders list safely
        try {
          final nav = Navigator.of(context);
          if (nav.canPop() && ModalRoute.of(context)?.isCurrent == true) {
            nav.pop();
          }
        } catch (e) {
          debugPrint('Error popping screen: $e');
        }
      } else {
        setState(() {
          loading = false;
        });
      }
    }
  }

  // Post-start individual cancellation fix: the only safe, canonical path for a Traveller to
  // cancel ONE passenger's ride after Start Trip has been pressed for it. Calls
  // cancel_intercity_request_by_traveller (SECURITY DEFINER, ownership-checked server-side) rather
  // than writing order_status/OTP directly from Flutter -- see that RPC for the full effect
  // (order terminates to 'cancelled', OTP cleared, intercity_requests synced, no redispatch, other
  // passengers on the same plan untouched).
  Future<bool> _cancelIntercityPassengerAfterTripStart() async {
    final requestId = _intercityRequestId;
    if (requestId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to cancel: this passenger\'s request could not be found.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return false;
    }
    try {
      final response = await supabase.rpc('cancel_intercity_request_by_traveller', params: {
        'p_request_id': requestId,
        'p_cancel_reason': 'Cancelled by traveller from the active trip screen',
      }).timeout(const Duration(seconds: 25));
      final data = Map<String, dynamic>.from(response as Map);
      if (data['success'] != true) {
        throw Exception(data['message']?.toString() ?? 'Unable to cancel this passenger.');
      }
      if (mounted && order != null) {
        setState(() {
          order!['order_status'] = 'cancelled';
        });
      }
      return true;
    } catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceAll('Exception: ', '')),
          backgroundColor: Colors.redAccent,
        ),
      );
      return false;
    }
  }

  // =========================================================
  // OTP VALIDATION
  // =========================================================

  Future<String?> validateOtp({
    required bool pickup,
    required String enteredOtp,
  }) async {
    try {
      final entered = enteredOtp.trim();

      // FIX (OTP Frozen Snapshot, WayDrop Progressive Degradation investigation, 2026-08-08):
      // `order` can be stale here -- openOtpSheet() passes it into OtpSheetContent as a one-time
      // constructor value, and Flutter's showModalBottomSheet builder is never re-invoked just
      // because this screen's own `order` field is reassigned later (via realtime, regenerateOtp(),
      // or updateStatus()'s own optimistic patch) while the sheet stays open -- proven live to
      // reject a genuinely correct OTP. Always read the authoritative pickup_otp/delivery_otp fresh
      // from the server immediately before comparing, instead of trusting whatever this screen (or
      // the sheet) happened to have cached. OTP generation/values/verification rules are unchanged
      // -- this only changes WHERE the compared-against value is read from.
      String? actual;
      try {
        final latest = await supabase
            .from('orders')
            .select('pickup_otp, delivery_otp')
            .eq('id', widget.orderId)
            .single()
            .timeout(const Duration(seconds: 10));
        actual = pickup ? latest['pickup_otp']?.toString() : latest['delivery_otp']?.toString();
        // Keep this screen's own cached copy in sync too, so anything else reading `order` locally
        // (e.g. a resend/retry inside this same sheet) also sees the current value.
        if (order != null) {
          order![pickup ? 'pickup_otp' : 'delivery_otp'] = actual;
        }
      } catch (e) {
        // Fresh read failed (e.g. offline) -- fall back to the cached value rather than blocking
        // verification entirely; this matches the pre-fix behavior exactly in the failure case.
        debugPrint('OTP fresh-read error, falling back to cached order: $e');
        actual = pickup ? (order?['pickup_otp']?.toString()) : (order?['delivery_otp']?.toString());
      }

      if (entered != actual) {
        return 'Incorrect OTP entered. Please try again.';
      }

      final isParcel = order?['order_type'] == 'local_parcel' || order?['order_type'] == 'intercity_parcel';
      // Parcel delivery OTP now moves the order to payment_pending, not straight to delivered --
      // the partner confirms payment received afterward (mirrors ride's ongoing -> payment_pending
      // -> completed flow). See update-order-status/index.ts's parcelTransitions.
      final nextStatus = pickup
          ? (isParcel ? 'picked_up' : 'ongoing')
          : (isParcel ? 'payment_pending' : 'completed');

      final success = await updateStatus(
        nextStatus,
        pickupOtp: pickup ? entered : null,
        deliveryOtp: !pickup ? entered : null,
      );

      if (!success) {
        return 'Failed to update order status. Please try again.';
      }

      if (mounted) {
        Navigator.pop(context);
      }
      return null;
    } catch (e) {
      debugPrint('OTP ERROR => $e');
      return e.toString().replaceAll('Exception: ', '');
    }
  }

  Future<String?> regenerateOtp({required bool pickup}) async {
    try {
      final response = await supabase.functions.invoke(
        'regenerate-otp',
        body: {
          'order_id': widget.orderId,
          'otp_type': pickup ? 'pickup' : 'delivery',
          'actor_type': 'rider',
          'actor_rider_id': order?['rider_id']?.toString() ?? riderProfile?['id']?.toString(),
          'reason': 'Rider requested OTP regeneration',
        },
      );

      final data = response.data;
      if (data == null || data['success'] != true) {
        final errMsg = data?['error'] ?? data?['message'] ?? 'Unable to regenerate OTP';
        throw Exception(errMsg);
      }

      final newOtp = data['otp']?.toString();
      final updatedOrder = data['order'] as Map<String, dynamic>?;

      if (updatedOrder != null && mounted) {
        setState(() {
          order = updatedOrder;
        });
      }

      return newOtp;
    } catch (e) {
      debugPrint('REGENERATE OTP ERROR => $e');
      rethrow;
    }
  }

  // =========================================================
  // EXTERNAL NAVIGATION (GOOGLE MAPS)
  // =========================================================

  // External Google Maps navigation only ever launches from the driver's own explicit tap on the
  // "Directions on Maps" / "NAVIGATE TO DESTINATION" button below -- never automatically on ride
  // acceptance or any other status/lifecycle transition (WayDrop must stay foreground until the
  // driver chooses to leave it).
  Future<void> _openExternalGoogleMaps() async {
    final status = order?['order_status']?.toString();
    final isToPickup = (status == 'accepted' || status == 'rider_arrived' || status == 'rider_at_pickup');
    
    final latKey = isToPickup ? 'pickup_lat' : 'destination_lat';
    final lngKey = isToPickup ? 'pickup_lng' : 'destination_lng';
    
    final lat = double.tryParse(order?[latKey]?.toString() ?? '');
    final lng = double.tryParse(order?[lngKey]?.toString() ?? '');
    
    if (lat != null && lng != null) {
      final googleMapsUrl = Uri.parse('google.navigation:q=$lat,$lng&mode=d');
      final fallbackUrl = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving');
      
      try {
        if (await canLaunchUrl(googleMapsUrl)) {
          await launchUrl(googleMapsUrl);
        } else if (await canLaunchUrl(fallbackUrl)) {
          await launchUrl(fallbackUrl, mode: LaunchMode.externalApplication);
        } else {
          throw 'Could not launch map';
        }
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error opening Google Maps: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Coordinates are missing for this location.'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  // =========================================================
  // OTP SHEET
  // =========================================================

  void openOtpSheet({
    required bool pickup,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _darkCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(26),
        ),
      ),
      builder: (_) {
        return OtpSheetContent(
          pickup: pickup,
          order: order,
          onVerify: (enteredOtp) => validateOtp(
            pickup: pickup,
            enteredOtp: enteredOtp,
          ),
          onResend: () => regenerateOtp(
            pickup: pickup,
          ),
        );
      },
    );
  }

  // Issue 9 fix: intercity_parcel's drop-OTP entry/verify must go exclusively through
  // complete_intercity_parcel_delivery() (the same authoritative RPC intercity_bookings_screen.dart
  // already uses), never through validateOtp()/update-order-status -- see the P0 comment on the
  // buildBottomButton() branch below for why those two paths must never both be reachable for this
  // order type. Reuses the same OtpSheetContent widget, just wired to different verify/resend
  // callbacks, so the traveller gets the identical OTP-entry UI without ever leaving this screen.
  void openIntercityParcelDropOtpSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _darkCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(26),
        ),
      ),
      builder: (_) {
        return OtpSheetContent(
          pickup: false,
          order: order,
          onVerify: (enteredOtp) => _completeIntercityParcelDelivery(enteredOtp),
          onResend: () => _resendIntercityDeliveryOtp(),
        );
      },
    );
  }

  Future<String?> _completeIntercityParcelDelivery(String enteredOtp) async {
    try {
      final response = await supabase.rpc('complete_intercity_parcel_delivery', params: {
        'p_order_id': widget.orderId,
        'p_delivery_otp': enteredOtp.trim(),
      });
      final data = response is Map ? Map<String, dynamic>.from(response) : null;
      if (data == null || data['success'] != true) {
        return (data?['message'] as String?) ?? 'Failed to complete delivery. Please try again.';
      }

      // Same local-state reflection updateStatus()/_markIntercityParcelAtDropoff() already do on
      // success -- realtime will reconcile `order` fully once the postgres_changes event for this
      // RPC's UPDATE arrives, which is also what drives this screen's own completed-status redirect.
      if (order != null) {
        setState(() {
          order!['order_status'] = 'delivered';
        });
      }
      if (mounted) {
        Navigator.pop(context);
      }
      return null;
    } catch (e) {
      debugPrint('INTERCITY PARCEL COMPLETE ERROR => $e');
      return e.toString().replaceAll('Exception: ', '');
    }
  }

  Future<String?> _resendIntercityDeliveryOtp() async {
    try {
      final response = await supabase.rpc('regenerate_intercity_delivery_otp', params: {
        'p_order_id': widget.orderId,
      });
      final data = response is Map ? Map<String, dynamic>.from(response) : null;
      if (data == null || data['success'] != true) {
        throw Exception((data?['message'] as String?) ?? 'Unable to regenerate OTP');
      }
      final newOtp = data['delivery_otp']?.toString();
      if (order != null && newOtp != null) {
        setState(() {
          order!['delivery_otp'] = newOtp;
        });
      }
      return newOtp;
    } catch (e) {
      debugPrint('INTERCITY RESEND OTP ERROR => $e');
      rethrow;
    }
  }

  // =========================================================
  // CTA
  // =========================================================

  Widget buildBottomButton() {
    final status = order?['order_status']?.toString();
    final isParcel = order?['order_type'] == 'local_parcel' || order?['order_type'] == 'intercity_parcel';
    final fare = double.tryParse(order?['final_fare']?.toString() ?? order?['current_fare']?.toString() ?? '0') ?? 0.0;

    if (isParcel) {
      if (status == 'accepted') {
        return SwipeToConfirmButton(
          text: 'SWIPE TO ARRIVE AT PICKUP',
          onSwipeComplete: () {
            updateStatus('rider_arrived');
          },
        );
      }
      if (status == 'rider_arrived') {
        final photoCompleted = pickupPhotoCompleted;
        if (!photoCompleted) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.security_rounded,
                      color: _primaryLime,
                      size: 16,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Why take a photo? Capturing a parcel photo guarantees your safety, verifies package status, and protects you from false claims or liability.',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.8),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.amber.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.amber.withOpacity(0.2)),
                            ),
                            child: const Row(
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  color: Colors.amberAccent,
                                  size: 14,
                                ),
                                SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'Do NOT open the parcel under any circumstances to ensure safety and avoid legal or liability issues.',
                                    style: TextStyle(
                                      color: Colors.amberAccent,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      height: 1.3,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SwipeToConfirmButton(
                text: _isUploadingPhoto ? 'UPLOADING PHOTO...' : 'SWIPE TO TAKE PARCEL PHOTO',
                onSwipeComplete: () {
                  if (!_isUploadingPhoto) {
                    _takeVerificationPhoto('pickup');
                  }
                },
              ),
            ],
          );
        }
        return SwipeToConfirmButton(
          text: 'SWIPE TO ENTER PICKUP OTP',
          onSwipeComplete: () {
            openOtpSheet(pickup: true);
          },
        );
      }
      if (status == 'picked_up') {
        // BUG FIX (see _markIntercityParcelAtDropoff's doc comment): intercity_parcel must reach
        // 'rider_at_drop' via mark_intercity_trip_at_dropoff (the only place a fresh, real
        // delivery OTP is issued for this order type), not the generic update-order-status call
        // every other parcel order type uses.
        final isIntercityParcel = order?['order_type'] == 'intercity_parcel';
        return SwipeToConfirmButton(
          text: 'SWIPE TO ARRIVE AT DROP',
          onSwipeComplete: () {
            if (isIntercityParcel) {
              _markIntercityParcelAtDropoff();
            } else {
              updateStatus('rider_at_drop');
            }
          },
        );
      }
      if (status == 'rider_at_drop') {
        // P0 fix (WayDrop dual-completion-path audit), Issue 9 follow-up: intercity_parcel delivery
        // has its OWN authoritative completion path -- complete_intercity_parcel_delivery() (a
        // SECURITY DEFINER RPC that also owns delivery OTP regeneration via
        // mark_intercity_trip_at_dropoff()/regenerate_intercity_delivery_otp()). This screen's
        // GENERIC parcel OTP path (validateOtp() -> update-order-status) must never be used for this
        // order type -- it's a separate, uncoordinated implementation that could verify against a
        // delivery_otp the RPC has since regenerated out from under it. That is still true and still
        // enforced below (the final OTP action branches by order_type). What changed: this screen no
        // longer bounces the traveller away to IntercityBookingsScreen to actually complete -- it now
        // continues in place, reusing the exact same photo-capture step every other parcel type uses
        // (order-type-agnostic: process-verification-photo has no order_type check) and then opening
        // openIntercityParcelDropOtpSheet(), which calls complete_intercity_parcel_delivery()
        // directly -- never validateOtp()/update-order-status for this order type.
        final photoCompleted = dropoffPhotoCompleted;
        if (!photoCompleted) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.security_rounded,
                      color: _primaryLime,
                      size: 16,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Please capture a delivery proof photo. This confirms the package condition upon arrival and protects you from delivery disputes.',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.8),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SwipeToConfirmButton(
                text: _isUploadingPhoto ? 'UPLOADING PHOTO...' : 'SWIPE TO TAKE DEPROOF PHOTO',
                onSwipeComplete: () {
                  if (!_isUploadingPhoto) {
                    _takeVerificationPhoto('dropoff');
                  }
                },
              ),
            ],
          );
        }
        return SwipeToConfirmButton(
          text: 'SWIPE TO ENTER DELIVERY OTP',
          onSwipeComplete: () {
            if (order?['order_type'] == 'intercity_parcel') {
              openIntercityParcelDropOtpSheet();
            } else {
              openOtpSheet(pickup: false);
            }
          },
        );
      }
      // Local parcel now stops at payment_pending before delivering, mirroring the ride flow's
      // ongoing -> payment_pending -> completed stop above -- reuses the exact same driver
      // payment-collection panel/sheets (cashfree/personal_upi/cash), just targeting 'delivered'
      // instead of 'completed' once payment is confirmed.
      if (status == 'payment_pending') {
        final fareMethod = order?['fare_payment_method']?.toString();
        final paymentStatus = order?['payment_status']?.toString();
        final paymentMode = order?['payment_mode']?.toString() ?? 'cash';
        final isLegacyUpiOrder = paymentMode == 'upi' && fareMethod == null;

        if (fareMethod == 'cashfree') {
          if (paymentStatus == 'paid') {
            return SwipeToConfirmButton(
              text: 'SWIPE TO COMPLETE DELIVERY',
              onSwipeComplete: () {
                completeOnlineRide(fare, targetStatus: 'delivered');
              },
            );
          }
          return _buildPaymentWaitBanner("Waiting for the sender's Cashfree payment to be confirmed...");
        }

        if (isLegacyUpiOrder) {
          if (order?['upi_payment_prompted_at'] == null) {
            return _buildPaymentWaitBanner('Waiting for the sender to open their UPI app...');
          }
          return SwipeToConfirmButton(
            text: 'SWIPE TO CONFIRM UPI RECEIVED',
            onSwipeComplete: () {
              showUpiCollectionSheet(fare, targetStatus: 'delivered');
            },
          );
        }

        return _buildDirectPaymentPendingPanel(fare, targetStatus: 'delivered');
      }
      if (status == 'delivered') {
        return SwipeToConfirmButton(
          text: 'SWIPE TO FINISH',
          onSwipeComplete: () {
            Navigator.pop(context);
          },
        );
      }
    } else {
      if (status == 'accepted') {
        return SwipeToConfirmButton(
          text: 'SWIPE TO ARRIVE',
          onSwipeComplete: () {
            updateStatus('rider_arrived');
          },
        );
      }
      if (status == 'rider_arrived') {
        return SwipeToConfirmButton(
          text: 'SWIPE TO START RIDE',
          onSwipeComplete: () {
            openOtpSheet(pickup: true);
          },
        );
      }
      if (status == 'ongoing') {
        return SwipeToConfirmButton(
          text: 'SWIPE TO COMPLETE RIDE',
          onSwipeComplete: () {
            // Every ride now stops at payment_pending before completing, regardless of
            // payment_mode -- the passenger picks how to actually settle the fare (UPI Apps /
            // Cash / Cashfree backup) fresh at drop-off. This is the realtime signal the
            // passenger's tracking screen is waiting on to show its payment UI.
            updateStatus('payment_pending');
          },
        );
      }
      if (status == 'payment_pending') {
        final fareMethod = order?['fare_payment_method']?.toString();
        final paymentStatus = order?['payment_status']?.toString();
        final paymentMode = order?['payment_mode']?.toString() ?? 'cash';
        final isLegacyUpiOrder = paymentMode == 'upi' && fareMethod == null;

        // Cashfree: only ever confirmed by the real, server-verified webhook -- the driver cannot
        // self-report this, whether the passenger chose it themselves (Pay ₹X -> Pay Online
        // Securely) or scanned the driver's own "Cashfree QR". Once confirmed, closing out the
        // ride is a plain swipe.
        if (fareMethod == 'cashfree') {
          if (paymentStatus == 'paid') {
            return SwipeToConfirmButton(
              text: 'SWIPE TO COMPLETE RIDE',
              onSwipeComplete: () {
                completeOnlineRide(fare);
              },
            );
          }
          return _buildPaymentWaitBanner("Waiting for the passenger's Cashfree payment to be confirmed...");
        }

        // Legacy in-flight 'upi' deep-link orders from before this architecture -- no new order
        // can ever select this path.
        if (isLegacyUpiOrder) {
          if (order?['upi_payment_prompted_at'] == null) {
            return _buildPaymentWaitBanner('Waiting for the passenger to open their UPI app...');
          }
          return SwipeToConfirmButton(
            text: 'SWIPE TO CONFIRM UPI RECEIVED',
            onSwipeComplete: () {
              showUpiCollectionSheet(fare);
            },
          );
        }

        // QR-based direct-payment architecture: Personal QR / Cashfree QR + Confirm Payment
        // Received are shown immediately, the moment the ride enters payment_pending --
        // independent of anything the passenger does in-app, since the passenger may pay by
        // scanning the driver's uploaded Personal QR entirely outside the app.
        return _buildDirectPaymentPendingPanel(fare);
      }
      if (status == 'completed') {
        return SwipeToConfirmButton(
          text: 'SWIPE TO FINISH',
          onSwipeComplete: () {
            Navigator.pop(context);
          },
        );
      }
    }

    return const SizedBox();
  }

  Widget _buildPaymentWaitBanner(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _primaryLime.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: _primaryLime),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Driver's payment_pending screen -- shown the instant the ride enters payment_pending,
  // regardless of anything the passenger does in-app. [Personal QR] and [Cashfree QR] are clearly
  // separate options (spec section 5); [Confirm Payment Received] is the driver's own attestation
  // after checking their bank/UPI app for a direct settlement.
  Widget _buildDirectPaymentPendingPanel(double fare, {String targetStatus = 'completed'}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              const Text(
                'Payment Pending',
                style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                'Ride Fare: ₹${fare.toStringAsFixed(0)}',
                style: const TextStyle(color: _primaryLime, fontSize: 24, fontWeight: FontWeight.w900),
              ),
            ],
          ),
        ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _showPersonalQrFullscreen(fare),
                icon: const Icon(Icons.qr_code_rounded, color: _primaryLime, size: 18),
                label: const Text(
                  'Personal QR',
                  style: TextStyle(color: _primaryLime, fontWeight: FontWeight.w800, fontSize: 13),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: _primaryLime, width: 1.5),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _loadingCashfreeQr ? null : () => _showCashfreeQrFullscreen(fare),
                icon: _loadingCashfreeQr
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                      )
                    : const Icon(Icons.qr_code_2_rounded, color: Colors.white70, size: 18),
                label: const Text(
                  'Cashfree QR',
                  style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w800, fontSize: 13),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.2), width: 1.5),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SwipeToConfirmButton(
          text: 'SWIPE TO CONFIRM ₹${fare.toStringAsFixed(0)} RECEIVED',
          onSwipeComplete: () {
            showPersonalUpiCollectionSheet(fare, targetStatus: targetStatus);
          },
        ),
      ],
    );
  }

  // =========================================================
  // FEATURE 6/7/8: WAITING FOR TRAVEL DAY / START TRIP (intercity only)
  // =========================================================

  bool get _isIntercityOrder {
    final type = order?['order_type']?.toString() ?? '';
    if (type.startsWith('intercity')) return true;
    final distanceMeters = double.tryParse(order?['distance_meters']?.toString() ?? '0') ?? 0.0;
    return type == 'ride' && distanceMeters > 20000;
  }

  DateTime? get _travelDate {
    final raw = order?['travel_date']?.toString();
    return raw != null ? DateTime.tryParse(raw) : null;
  }

  bool get _tripStarted => order?['trip_started_at'] != null;

  // Item 1 (business rule correction): intercity payment is collected from the passenger AFTER
  // the trip completes, not before -- Start Trip must depend ONLY on the booking being accepted,
  // the travel date, and the 1-hour-before-departure window (all enforced below and, server-side,
  // by start_intercity_trip_for_plan itself). It must never gate on payment status.
  Future<void> _startIntercityTrip() async {
    try {
      final routeId = _intercityRouteId;
      if (routeId == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to start the trip: no travel plan linked to this booking.'),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }

      final response = await supabase.rpc('start_intercity_trip_for_plan', params: {'p_route_id': routeId});
      final data = Map<String, dynamic>.from(response as Map);
      if (data['success'] != true) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(data['message']?.toString() ?? 'Unable to start the trip.'),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }
      // The 'orders' realtime subscription already active on this screen will refresh `order`
      // with the new trip_started_at as soon as the DB update lands (event-driven, no polling) —
      // no local state mutation needed here beyond surfacing failures above.
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start trip: $e'), backgroundColor: Colors.redAccent),
      );
    }
  }

  Widget buildActionArea(String? status, bool isParcel, double fare) {
    final clientPhone = order?['users']?['phone']?.toString() ?? '';
    final clientName = order?['users']?['full_name']?.toString() ?? 'Client';

    if (_isIntercityOrder && status == 'accepted' && !_tripStarted) {
      // Feature 8: navigation/swipe-to-arrive must never appear before the travel date — this
      // replaces that entire UI with the Waiting for Travel Day card until Start Trip is pressed.
      // Item 1 (business rule): Start Trip depends ONLY on the booking being accepted, the travel
      // date, and the 1-hour-before-departure window -- WaitingForTravelDayCard already enforces
      // exactly that gate (see its _canStartTrip) and nothing about payment, matching the actual
      // business model: the passenger pays the traveller after the trip completes, not before.
      return SafeArea(
        top: false,
        child: WaitingForTravelDayCard(
          travelDate: _travelDate,
          isTraveller: true,
          onStartTrip: _startIntercityTrip,
        ),
      );
    }

    final showNavigate = status == 'accepted' || status == 'ongoing' || status == 'picked_up';
    // intercity_parcel delivery is never verified through this screen's OTP sheet -- see the
    // dual-completion-path fix in buildBottomButton()'s 'rider_at_drop' branch above; this "reopen
    // OTP sheet" button is a second surface into the same sheet and must be excluded the same way.
    final isInterCityParcelAtDrop = status == 'rider_at_drop' && order?['order_type'] == 'intercity_parcel';
    final showVerifyOtp = (status == 'rider_arrived' || status == 'rider_at_drop') &&
        (!isParcel ||
         (status == 'rider_arrived' ? pickupPhotoCompleted : dropoffPhotoCompleted)) &&
        !isInterCityParcelAtDrop;
    final showCancel = status == 'accepted' || status == 'rider_arrived';

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Navigation Button (En route)
          if (showNavigate) ...[
            ElevatedButton.icon(
              onPressed: _openExternalGoogleMaps,
              icon: Icon(
                status == 'accepted' ? Icons.map_rounded : Icons.navigation_rounded,
                color: Colors.black,
                size: 20,
              ),
              label: Text(
                status == 'accepted' ? 'Directions on Maps' : 'NAVIGATE TO DESTINATION',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                  fontSize: 14,
                  letterSpacing: 0.5,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _primaryLime,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 0,
              ),
            ),
            const SizedBox(height: 12),
          ],

          // 2. Swipe Action Button
          buildBottomButton(),

          // 3. OTP Reopen Button (Verify OTP)
          if (showVerifyOtp) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => openOtpSheet(pickup: status == 'rider_arrived'),
              icon: const Icon(Icons.pin_rounded, color: _primaryLime, size: 20),
              label: const Text(
                'VERIFY OTP',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  letterSpacing: 0.5,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: _primaryLime, width: 1.5),
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ],

          const SizedBox(height: 12),

          // 4. Utility Row (Call / Chat)
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    if (clientPhone.isNotEmpty) {
                      final cleanPhone = clientPhone.replaceAll(RegExp(r'\s+'), '');
                      final uri = Uri.parse('tel:$cleanPhone');
                      try {
                        await launchUrl(uri);
                      } catch (_) {}
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Client phone number is not available.')),
                      );
                    }
                  },
                  icon: const Icon(Icons.phone_rounded, color: _primaryLime, size: 18),
                  label: const Text(
                    'Call',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    if (order != null) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => OrderChatScreen(
                            orderId: widget.orderId,
                            riderId: order?['rider_id']?.toString(),
                            chatTitle: clientName,
                            isSupport: false,
                          ),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.chat_bubble_rounded, color: _primaryLime, size: 18),
                  label: const Text(
                    'Chat',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],
          ),

          // 5. Cancel Button
          if (showCancel) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => confirmCancellation(context),
              style: TextButton.styleFrom(
                foregroundColor: Colors.redAccent,
                padding: const EdgeInsets.symmetric(vertical: 12),
                minimumSize: const Size(double.infinity, 48),
              ),
              child: const Text(
                'CANCEL RIDE',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // =========================================================
  // UI
  // =========================================================

  String? get routeGeometry {
    if (optimizedGeometry != null) {
      return optimizedGeometry;
    }
    final status = order?['order_status']?.toString();
    final pLat = double.tryParse(order?['pickup_lat']?.toString() ?? '');
    final pLng = double.tryParse(order?['pickup_lng']?.toString() ?? '');
    final dLat = double.tryParse(order?['destination_lat']?.toString() ?? '');
    final dLng = double.tryParse(order?['destination_lng']?.toString() ?? '');
    final rLat = LocationCacheService.currentLat;
    final rLng = LocationCacheService.currentLng;

    if (status == 'accepted' || status == 'rider_arrived' || status == 'rider_at_pickup') {
      if (rLat != null && rLng != null && pLat != null && pLng != null) {
        return jsonEncode([
          [rLng, rLat],
          [pLng, pLat],
        ]);
      }
    } else if (status == 'ongoing' || status == 'picked_up' || status == 'rider_at_drop') {
      final startLat = rLat ?? pLat;
      final startLng = rLng ?? pLng;
      if (startLat != null && startLng != null && dLat != null && dLng != null) {
        return jsonEncode([
          [startLng, startLat],
          [dLng, dLat],
        ]);
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const SkeletonLoader();
    }
    final screenHeight = MediaQuery.of(context).size.height;

    final status = order?['order_status']?.toString();
    if (status == 'completed' || status == 'delivered') {
      return buildCompletionScreen();
    }

    final fare = double.tryParse(order?['final_fare']?.toString() ?? order?['current_fare']?.toString() ?? '0') ?? 0.0;
    final isParcel = order?['order_type'] == 'local_parcel' || order?['order_type'] == 'intercity_parcel';
    
    final pickupLatitude = double.tryParse(order?['pickup_lat']?.toString() ?? '0') ?? 0.0;
    final pickupLongitude = double.tryParse(order?['pickup_lng']?.toString() ?? '0') ?? 0.0;
    final destinationLatitude = double.tryParse(order?['destination_lat']?.toString() ?? '0') ?? 0.0;
    final destinationLongitude = double.tryParse(order?['destination_lng']?.toString() ?? '0') ?? 0.0;

    return ValueListenableBuilder<bool>(
      valueListenable: PipService.isInPipMode,
      builder: (context, isInPip, child) {
        final mapWidget = _useMockMap
            ? TransportMapWidget(
                pickupLat: pickupLatitude,
                pickupLng: pickupLongitude,
                destinationLat: destinationLatitude,
                destinationLng: destinationLongitude,
                riderLat: LocationCacheService.currentLat,
                riderLng: LocationCacheService.currentLng,
                geometry: routeGeometry,
                isDark: true,
                riderAvatar: (riderProfile?['rider_kyc!riders_kyc_id_fkey'] ?? riderProfile?['rider_kyc']) is Map 
                    ? (riderProfile?['rider_kyc!riders_kyc_id_fkey'] ?? riderProfile?['rider_kyc'])['rider_image']?.toString() 
                    : null,
                riderName: (riderProfile?['rider_kyc!riders_kyc_id_fkey'] ?? riderProfile?['rider_kyc']) is Map 
                    ? (riderProfile?['rider_kyc!riders_kyc_id_fkey'] ?? riderProfile?['rider_kyc'])['full_name']?.toString() 
                    : null,
                vehicleType: (riderProfile?['rider_kyc!riders_kyc_id_fkey'] ?? riderProfile?['rider_kyc']) is Map 
                    ? (riderProfile?['rider_kyc!riders_kyc_id_fkey'] ?? riderProfile?['rider_kyc'])['vehicle_type']?.toString() 
                    : null,
                showSupportButton: false,
                showRecenterButton: false,
                showZoomButtons: false,
                controlsTopOffset: 0,
              )
            : (mapController == null
                ? const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF10B981),
                      strokeWidth: 2.5,
                    ),
                  )
                : WebViewWidget(controller: mapController!));

        if (isInPip) {
          return Scaffold(
            backgroundColor: _darkBg,
            body: mapWidget,
          );
        }

        return Scaffold(
          backgroundColor: _darkBg,
          body: Stack(
            children: [
              // 1. Full-screen map widget
              Positioned.fill(
                child: _useMockMap
                    ? TransportMapWidget(
                        pickupLat: pickupLatitude,
                        pickupLng: pickupLongitude,
                        destinationLat: destinationLatitude,
                        destinationLng: destinationLongitude,
                        riderLat: LocationCacheService.currentLat,
                        riderLng: LocationCacheService.currentLng,
                        geometry: routeGeometry,
                        isDark: true,
                        riderAvatar: (riderProfile?['rider_kyc!riders_kyc_id_fkey'] ?? riderProfile?['rider_kyc']) is Map 
                            ? (riderProfile?['rider_kyc!riders_kyc_id_fkey'] ?? riderProfile?['rider_kyc'])['rider_image']?.toString() 
                            : null,
                        riderName: (riderProfile?['rider_kyc!riders_kyc_id_fkey'] ?? riderProfile?['rider_kyc']) is Map 
                            ? (riderProfile?['rider_kyc!riders_kyc_id_fkey'] ?? riderProfile?['rider_kyc'])['full_name']?.toString() 
                            : null,
                        vehicleType: (riderProfile?['rider_kyc!riders_kyc_id_fkey'] ?? riderProfile?['rider_kyc']) is Map 
                            ? (riderProfile?['rider_kyc!riders_kyc_id_fkey'] ?? riderProfile?['rider_kyc'])['vehicle_type']?.toString() 
                            : null,
                        showSupportButton: true,
                        showRecenterButton: true,
                        showZoomButtons: true,
                        controlsTopOffset: MediaQuery.of(context).padding.top + 70,
                      )
                    : (mapController == null
                        ? const Center(
                            child: CircularProgressIndicator(
                              color: Color(0xFF10B981),
                              strokeWidth: 2.5,
                            ),
                          )
                        : WebViewWidget(controller: mapController!)),
              ),

              // 1.1. WebView Map Controls (Zoom / Recenter)
              if (!_useMockMap && mapController != null)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 70,
                  right: 16,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _MapBtn(
                        icon: Icons.my_location_rounded,
                        tooltip: 'Recenter on Drop Partner',
                        onTap: () {
                          mapController?.runJavaScript('focusOnRider();');
                        },
                      ),
                      const SizedBox(height: 8),
                      _MapBtn(
                        icon: Icons.add_rounded,
                        tooltip: 'Zoom In',
                        onTap: () {
                          mapController?.runJavaScript('zoomIn();');
                        },
                      ),
                      const SizedBox(height: 8),
                      _MapBtn(
                        icon: Icons.remove_rounded,
                        tooltip: 'Zoom Out',
                        onTap: () {
                          mapController?.runJavaScript('zoomOut();');
                        },
                      ),
                    ],
                  ),
                ),

                // 2. Floating Back Button
                Positioned(
                  top: MediaQuery.of(context).padding.top + 10,
                  left: 16,
                  child: Card(
                    elevation: 4,
                    shape: const CircleBorder(),
                    color: _darkCard,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => Navigator.pop(context),
                      child: const SizedBox(
                        height: 44,
                        width: 44,
                        child: Icon(Icons.arrow_back_rounded, color: Colors.white, size: 24),
                      ),
                    ),
                  ),
                ),

                // 3. Floating Police SOS Shield Button (if parcel)
                if (isParcel)
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 10,
                    right: 16,
                    child: Card(
                      elevation: 4,
                      shape: const CircleBorder(),
                      color: const Color(0xFFEF4444),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _triggerPoliceSOS,
                        child: const SizedBox(
                          height: 44,
                          width: 44,
                          child: Icon(
                            Icons.security_rounded,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                      ),
                    ),
                  ),

                // 3. Floating Bottom Sheet (Glassmorphic Premium Aesthetic)
                // Perf: expand/collapse of this sheet is purely local presentation state (see
                // _OrderDetailsSheet below), extracted into its own StatefulWidget so tapping
                // "show/hide details" only rebuilds the sheet itself -- not the map, back button,
                // and SOS button above, which previously all lived inside this same build().
                _OrderDetailsSheet(
                  order: order,
                  orderId: widget.orderId,
                  status: status,
                  isParcel: isParcel,
                  fare: fare,
                  screenHeight: screenHeight,
                  actionArea: buildActionArea(status, isParcel, fare),
                ),
              ],
            ),
        );
      },
    );
  }

  // =========================================================
  // MINI STAT
  // =========================================================

  Widget buildMiniStat({

    required String title,

    required String value,
  }) {

    return Column(

      children: [

        Text(

          value,

          style:
              const TextStyle(

            fontSize: 14,

            fontWeight:
                FontWeight.w700,
          ),
        ),

        const SizedBox(
          height: 4,
        ),

        Text(

          title,

          style:
              TextStyle(

            fontSize: 11,

            color:
                Colors.grey.shade600,
          ),
        ),
      ],
    );
  }

  // =========================================================
  // ADDRESS TILE
  // =========================================================

  Widget addressTile({

    required Color color,

    required String title,

    required String address,
  }) {

    return Row(

      crossAxisAlignment:
          CrossAxisAlignment.start,

      children: [

        Container(

          margin:
              const EdgeInsets.only(
            top: 4,
          ),

          height: 10,
          width: 10,

          decoration:
              BoxDecoration(

            color: color,

            shape:
                BoxShape.circle,
          ),
        ),

        const SizedBox(
          width: 12,
        ),

        Expanded(

          child: Column(

            crossAxisAlignment:
                CrossAxisAlignment.start,

            children: [

              Text(

                title,

                style:
                    TextStyle(

                  fontSize: 11,

                  color:
                      Colors.grey.shade600,
                ),
              ),

              const SizedBox(
                height: 4,
              ),

              Text(

                address,

                style:
                    const TextStyle(

                  fontSize: 13,

                  fontWeight:
                      FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // =========================================================
  // FORMAT
  // =========================================================

  String formatDuration(
    Duration duration,
  ) {

    final mins =
        duration.inMinutes;

    final secs =
        duration.inSeconds % 60;

    return '${mins}m ${secs}s';
  }

  Future<void> fetchOptimizedRoute({bool isForced = false}) async {
    if (order == null) return;
    if (fetchingRoute) {
      // Duplicate-request guard: a Directions request is already in flight -- never start a
      // second one. If this call was a forced (target/status-change) trigger, remember it so it
      // fires the instant the in-flight request completes (see the finally block below) instead
      // of being silently dropped.
      if (isForced) _pendingForceRouteFetch = true;
      return;
    }
    final status = order?['order_status']?.toString();
    // Duplicate/validity guard (Ola egress reduction): never call Ola Directions for an order
    // that has already finished. The branches below already implicitly no-op for these statuses
    // (neither matches, so startLat/endLat stay null) -- this makes that guarantee explicit and
    // independently verifiable.
    if (status == 'completed' || status == 'delivered' || status == 'cancelled') return;
    final pLat = double.tryParse(order?['pickup_lat']?.toString() ?? '');
    final pLng = double.tryParse(order?['pickup_lng']?.toString() ?? '');
    final dLat = double.tryParse(order?['destination_lat']?.toString() ?? '');
    final dLng = double.tryParse(order?['destination_lng']?.toString() ?? '');
    final rLat = LocationCacheService.currentLat;
    final rLng = LocationCacheService.currentLng;

    double? startLat, startLng, endLat, endLng;

    if (status == 'accepted' || status == 'rider_arrived' || status == 'rider_at_pickup') {
      startLat = rLat;
      startLng = rLng;
      endLat = pLat;
      endLng = pLng;
    } else if (status == 'ongoing' || status == 'picked_up' || status == 'rider_at_drop') {
      startLat = rLat ?? pLat;
      startLng = rLng ?? pLng;
      endLat = dLat;
      endLng = dLng;
    }

    if (startLat != null && startLng != null && endLat != null && endLng != null) {
      fetchingRoute = true;
      try {
        // `timeout:` is passed *into* getDirections rather than wrapped around it with
        // `.timeout(...)`: the old wrapper made this await give up at 8s (releasing the
        // `fetchingRoute` guard) while the underlying Ola HTTP request stayed alive against the
        // shared Dio's 15s ceiling -- a ~7s window in which the periodic timer could start a
        // second, overlapping Directions request. Passing the budget in makes getDirections
        // actually cancel the in-flight request at 8s, so the guard and the request are released
        // together. A cancelled/timed-out request returns null here, exactly like any other
        // failed fetch.
        final routeModel = await OlaMapService.getDirections(
          originLat: startLat,
          originLng: startLng,
          destinationLat: endLat,
          destinationLng: endLng,
          timeout: const Duration(seconds: 8),
        );

        if (routeModel != null && routeModel.polylinePoints.isNotEmpty) {
          final List<List<double>> coords = routeModel.polylinePoints
              .map((pt) => [pt['lng']!, pt['lat']!])
              .toList();
          if (mounted) {
            // Perf: `optimizedGeometry` is only ever read by the mock/desktop map path (see the
            // `routeGeometry` getter, consumed solely by TransportMapWidget's `geometry` prop
            // below). On real devices the route is pushed straight into the WebView via
            // `updateRiderRoute` JS, independent of the widget tree -- so wrapping the assignment
            // in setState() there would just force this screen's entire ~400-line build() to
            // re-run every ~15-25s for the whole trip, for a value nothing on-screen reads.
            if (_useMockMap) {
              setState(() {
                optimizedGeometry = jsonEncode(coords);
              });
            } else {
              optimizedGeometry = jsonEncode(coords);
              // Guarded like every other injected map call in this codebase: this can fire right
              // as the tracking screen (and its WebView) is freshly created on order acceptance,
              // before tracking_engine.js has finished loading -- an unguarded call threw an
              // uncaught ReferenceError in that window. Skipping is safe; fetchOptimizedRoute()
              // re-fires on the next order status transition.
              mapController?.runJavaScript(
                "if (typeof updateRiderRoute === 'function') { updateRiderRoute(${jsonEncode(coords)}); }",
              );
            }
          }
        }
      } catch (e) {
        debugPrint('Error fetching active rider optimized route: $e');
      } finally {
        fetchingRoute = false;
        // Duplicate-request guard follow-up: a target/status change arrived while this request
        // was in flight -- retry immediately instead of waiting for the next throttle window.
        if (_pendingForceRouteFetch) {
          _pendingForceRouteFetch = false;
          fetchOptimizedRoute(isForced: true);
        }
      }
    }
  }

  Future<void> fetchRiderProfile() async {
    try {
      final user = supabase.auth.currentUser;
      if (user != null) {
        // Egress fix: narrowed from `*` to the exact fields read off `riderProfile` throughout
        // this file (grepped exhaustively).
        final profile = await supabase
            .from('riders')
            .select('''
              id,
              total_completed_orders,
              wallet_balance,
              rider_kyc!riders_kyc_id_fkey(
                full_name,
                rider_image,
                vehicle_type
              )
            ''')
            .eq('user_id', user.id)
            .maybeSingle();

        double calculatedTodayEarnings = 0.0;
        if (profile != null) {
          final nowLocal = DateTime.now();
          final startOfToday = DateTime(nowLocal.year, nowLocal.month, nowLocal.day).toUtc();
          final ordersData = await supabase
              .from('orders')
              .select('rider_earning')
              .eq('rider_id', profile['id'])
              .inFilter('order_status', ['completed', 'delivered'])
              .gte('completed_at', startOfToday.toIso8601String());

          for (var o in ordersData) {
            calculatedTodayEarnings += double.tryParse(o['rider_earning']?.toString() ?? '0') ?? 0.0;
          }
        }

        if (mounted) {
          setState(() {
            riderProfile = profile;
            todayEarnings = calculatedTodayEarnings;
          });
          if (!_useMockMap) {
            _triggerInitialLocation();
          }
        }
      }
    } catch (e) {
      debugPrint('FETCH RIDER PROFILE IN ACTIVE ORDER ERROR => $e');
    }
  }

  // targetStatus lets local parcel's payment_pending step reuse this exact same sheet, swiping to
  // 'delivered' instead of 'completed' -- everything else (the driver-attestation UX/trust model)
  // is identical, so no separate parcel-specific sheet is needed.
  void showCashCollectionSheet(double fare, {String targetStatus = 'completed'}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _darkCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.shrink(),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF08A).withValues(alpha: 0.05),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFFEF08A).withValues(alpha: 0.1), width: 1.5),
                ),
                child: const Icon(
                  Icons.payments_rounded,
                  color: Color(0xFFFEF08A),
                  size: 48,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Payment Pending',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Cash fallback. Only swipe once you have physically received it.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _textGray,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Expected Amount',
                      style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '₹${fare.toStringAsFixed(2)}',
                      style: const TextStyle(
                        color: _primaryLime,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              SwipeToConfirmButton(
                text: 'SWIPE TO CONFIRM ₹${fare.toStringAsFixed(0)} RECEIVED',
                onSwipeComplete: () async {
                  Navigator.pop(ctx); // Close cash bottom sheet
                  showingCompletionDialog = true;
                  setState(() => loading = true);
                  await updateStatus(targetStatus, settlementMethod: 'cash');
                  await Future.delayed(const Duration(milliseconds: 800)); // wait for wallet triggers
                  await fetchRiderProfile();
                  if (!mounted) return;
                  setState(() => loading = false);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void showUpiCollectionSheet(double fare, {String targetStatus = 'completed'}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _darkCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.shrink(),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _primaryLime.withValues(alpha: 0.05),
                  shape: BoxShape.circle,
                  border: Border.all(color: _primaryLime.withValues(alpha: 0.1), width: 1.5),
                ),
                child: const Icon(
                  Icons.qr_code_rounded,
                  color: _primaryLime,
                  size: 48,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Confirm UPI Payment',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Only swipe once you\'ve checked your UPI app and confirmed the passenger\'s payment has arrived.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _textGray,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Expected from Passenger',
                      style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '₹${fare.toStringAsFixed(2)}',
                      style: const TextStyle(
                        color: _primaryLime,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              SwipeToConfirmButton(
                text: 'SWIPE TO CONFIRM UPI RECEIVED',
                onSwipeComplete: () async {
                  Navigator.pop(ctx); // Close UPI collection sheet
                  showingCompletionDialog = true;
                  setState(() => loading = true);
                  await updateStatus(targetStatus);
                  await Future.delayed(const Duration(milliseconds: 800)); // wait for wallet triggers
                  await fetchRiderProfile();
                  if (!mounted) return;
                  setState(() => loading = false);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // Driver self-attestation for a personal_upi fare payment -- same trust model as cash/legacy
  // UPI (the driver's swipe IS the confirmation), since a raw upi://pay push has no gateway
  // confirmation of its own. The optional reference field feeds the disputes flow
  // (fare_payment_reference) -- there's no NPCI-provided transaction id for a plain P2P push, so
  // this is whatever the driver can see in their own bank SMS/app, entered on a best-effort basis.
  void showPersonalUpiCollectionSheet(double fare, {String targetStatus = 'completed'}) {
    final referenceController = TextEditingController();
    showModalBottomSheet(
      context: context,
      backgroundColor: _darkCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.shrink(),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _primaryLime.withValues(alpha: 0.05),
                  shape: BoxShape.circle,
                  border: Border.all(color: _primaryLime.withValues(alpha: 0.1), width: 1.5),
                ),
                child: const Icon(
                  Icons.qr_code_rounded,
                  color: _primaryLime,
                  size: 48,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Confirm Payment Received',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'WayDrop does not process this direct payment -- only confirm once you\'ve checked '
                'your UPI/bank app and the passenger\'s payment has genuinely arrived in your account.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _textGray,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Expected Amount',
                      style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '₹${fare.toStringAsFixed(2)}',
                      style: const TextStyle(
                        color: _primaryLime,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: referenceController,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Transaction reference (optional)',
                  labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
                  hintText: 'UTR / reference number from your bank SMS',
                  hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 11),
                  filled: true,
                  fillColor: Colors.black.withValues(alpha: 0.2),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SwipeToConfirmButton(
                text: 'SWIPE TO CONFIRM ₹${fare.toStringAsFixed(0)} RECEIVED',
                onSwipeComplete: () async {
                  Navigator.pop(ctx); // Close personal UPI collection sheet
                  showingCompletionDialog = true;
                  setState(() => loading = true);
                  await updateStatus(
                    targetStatus,
                    farePaymentReference: referenceController.text.trim(),
                    settlementMethod: 'personal_upi',
                  );
                  await Future.delayed(const Duration(milliseconds: 800)); // wait for wallet triggers
                  await fetchRiderProfile();
                  if (!mounted) return;
                  setState(() => loading = false);
                },
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  showCashCollectionSheet(fare, targetStatus: targetStatus);
                },
                child: const Text(
                  'Received as cash instead',
                  style: TextStyle(color: _textGray, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> completeOnlineRide(double fare, {String targetStatus = 'completed'}) async {
    showingCompletionDialog = true;
    setState(() => loading = true);
    await updateStatus(targetStatus);
    await Future.delayed(const Duration(milliseconds: 800)); // wait for wallet triggers
    await fetchRiderProfile();
    if (!mounted) return;
    setState(() => loading = false);
  }

  Widget buildCompletionScreen() {
    final earnings = todayEarnings;
    final totalRides = riderProfile?['total_completed_orders'] ?? 0;
    final walletBalance = double.tryParse(riderProfile?['wallet_balance']?.toString() ?? '0') ?? 0.0;
    final type = order?['order_type']?.toString() ?? 'ride';
    final isParcel = type.contains('parcel') || type.contains('delivery');
    final fare = double.tryParse(order?['final_fare']?.toString() ?? order?['current_fare']?.toString() ?? '0') ?? 0.0;
    // Canonical breakdown -- every value read directly from the authoritative server-computed
    // columns (written exclusively by calculate_fare_breakdown()/update-order-status, protected
    // from client writes by the protect_order_financial_columns trigger). Never recomputed here.
    final breakdown = FareBreakdown.fromOrder(order ?? const {});
    final riderEarning = breakdown.partnerEarning;
    final commissionAmount = breakdown.commissionAmount;
    final commissionPercentage = breakdown.commissionPercentage;
    final subscriptionWaived = breakdown.subscriptionCommissionWaived;
    final completionOrderId = order?['id']?.toString();
    if (completionOrderId != null && _completionTaxOrderId != completionOrderId) {
      _completionTaxOrderId = completionOrderId;
      _completionTaxLoading = true;
      _completionGovTaxAmount = 0.0;
      _completionGovTaxRate = 0.0;
      _loadCompletionGovernmentTax(completionOrderId);
    }
    // "YOUR TRIP EARNINGS" (both the hero figure below and the DEDUCTIONS row further down) is
    // Ride Fare - WayDrop Commission - Government Tax, i.e. breakdown.customerPaid -
    // commission - governmentTax -- NEVER breakdown.fareBeforeGst (calculate_fare_breakdown()'s
    // internal "base_fare"), because base_fare already has "Platform GST" (orders.gst_amount, a
    // completely separate, partner-facing-hidden concept) netted out of it. Using base_fare here
    // silently understated Ride Fare/earnings by exactly the Platform GST amount -- the reported
    // "₹51.49 shown pre-completion becomes ₹49.04 on the completed screen" bug.
    //
    // Rather than re-deriving commission's effect from scratch (risking drift from whatever the
    // backend's subscription-waiver logic actually decided), this reuses riderEarning
    // (= base_fare - commission, already correct and backend-authoritative) and simply adds back
    // the Platform GST that base_fare had netted out: customerPaid - commission - govTax
    // algebraically equals riderEarning + platformGstAmount - govTax. Every term is an existing
    // authoritative column/ledger value; only addition/subtraction is performed here.
    //
    // EXCEPTION -- eligible Cashfree ride under the deployed PG-charge rule
    // (breakdown.isPgChargeRide, migration 20260901000038): orders.rider_earning is ALREADY the
    // final rider net (customer fare - 2% PG charge only; GST recorded separately, not deducted;
    // government tax skipped), credited in full by complete_order_and_settle. Display it directly
    // -- adding gstAmount back here would over-report by the GST amount, and there is no
    // government tax to subtract.
    final completionNetEarnings = breakdown.isPgChargeRide
        ? riderEarning
        : (_completionTaxLoading ? riderEarning : (riderEarning + breakdown.gstAmount - _completionGovTaxAmount));
    final paymentMode = (order?['payment_mode'] ?? order?['payment_method'] ?? 'cash').toString().toLowerCase();
    // The passenger's actual settlement choice (fare_payment_method, chosen fresh at
    // payment_pending) is what determines whether the driver's wallet was credited -- not the
    // order's booking-time payment_mode, which no longer decides this. Falls back to payment_mode
    // only for parcels/legacy orders that never went through that flow.
    final fareMethod = order?['fare_payment_method']?.toString();
    final isDirectSettlement = fareMethod != null
        ? (fareMethod == 'personal_upi' || fareMethod == 'cash')
        : (paymentMode == 'cash' || paymentMode == 'upi');
    final isCash = isDirectSettlement;
    final directSettlementLabel = PaymentMethodPresentation.labelFor(fareMethod: fareMethod, paymentMode: paymentMode);

    final orderCode = order?['order_code']?.toString() ?? 'N/A';
    final distanceMeters = double.tryParse(order?['distance_meters']?.toString() ?? '0') ?? 0.0;
    final distanceStr = distanceMeters > 0 ? '${(distanceMeters / 1000.0).toStringAsFixed(1)} Km' : 'N/A';
    final pickupAddr = order?['pickup_address']?.toString() ?? 'N/A';
    final dropoffAddr = order?['destination_address']?.toString() ?? 'N/A';

    final rawKyc = riderProfile?['rider_kyc!riders_kyc_id_fkey'] ?? riderProfile?['rider_kyc'];
    // Phase 12 (Part C): same root cause as the live-tracking marker fix above -- this completion
    // screen's vehicle image must reflect THIS trip/order's actual vehicle (orders.vehicle_type),
    // never the rider's primary KYC-registered vehicle. rawKyc is kept only as a fallback for the
    // rare case the order row itself is missing vehicle_type.
    final vehicleType = _intercityPlanVehicleType
        ?? order?['vehicle_type']?.toString().toLowerCase()
        ?? (rawKyc is Map ? rawKyc['vehicle_type'] : null)?.toString().toLowerCase()
        ?? 'bike';

    String vehicleImg = 'bike';
    if (vehicleType.contains('delivery') || vehicleType.contains('parcel') || vehicleType.contains('package')) {
      vehicleImg = 'delivery';
    } else if (vehicleType.contains('auto') || vehicleType.contains('rickshaw')) {
      vehicleImg = 'auto';
    } else if (vehicleType.contains('cab') || vehicleType.contains('car') || vehicleType.contains('sedan')) {
      vehicleImg = 'cab';
    } else {
      vehicleImg = 'bike';
    }

    return Scaffold(
      backgroundColor: _darkBg,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    // Pulsing Success Vehicle Image
                    isParcel || (vehicleImg != 'cab' && vehicleImg != 'auto')
                        ? const SizedBox(
                            width: 110,
                            height: 110,
                            child: WayDrop3dBike(size: 90),
                          )
                        : Container(
                            width: 96,
                            height: 96,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: _primaryLime.withValues(alpha: 0.3), width: 2),
                              boxShadow: [
                                BoxShadow(
                                  color: _primaryLime.withValues(alpha: 0.1),
                                  blurRadius: 16,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: ClipOval(
                              child: vehicleImg == 'cab'
                                  ? SvgPicture.asset('assets/images/3dcar.svg', fit: BoxFit.contain)
                                  : Image.asset(
                                      'assets/images/3dauto.png',
                                      fit: BoxFit.contain,
                                      errorBuilder: (ctx, err, stack) => Container(
                                        color: const Color(0xFF10B981).withValues(alpha: 0.1),
                                        child: const Icon(
                                          Icons.check_circle_outline_rounded,
                                          color: Color(0xFF10B981),
                                          size: 56,
                                        ),
                                      ),
                                    ),
                            ),
                          ),
                    const SizedBox(height: 24),
                    Text(
                      isParcel ? 'Delivery Completed!' : 'Ride Completed!',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      isParcel
                          ? 'Thank you for delivering the order safely!'
                          : 'Thank you for completing the ride safely!',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: _textGray,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 28),

                    // Card 1: Trip Earnings Card (Highlight)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: _darkCard,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: _primaryLime.withValues(alpha: 0.15), width: 1.5),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 16,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'YOUR TRIP EARNINGS',
                                    style: TextStyle(
                                      color: _textGray,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '₹${completionNetEarnings.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                      color: _primaryLime,
                                      fontSize: 32,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ],
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: isCash
                                      ? const Color(0xFF064E3B)
                                      : const Color(0xFF1E3A8A),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isCash
                                        ? const Color(0xFF059669).withValues(alpha: 0.5)
                                        : const Color(0xFF3B82F6).withValues(alpha: 0.5),
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      isCash
                                          ? Icons.payments_rounded
                                          : Icons.account_balance_wallet_rounded,
                                      size: 14,
                                      color: isCash
                                          ? const Color(0xFF34D399)
                                          : const Color(0xFF60A5FA),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      isCash ? directSettlementLabel : 'Online Paid',
                                      style: TextStyle(
                                        color: isCash
                                            ? const Color(0xFF34D399)
                                            : const Color(0xFF60A5FA),
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          const Divider(color: Colors.white10, height: 1),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // A cash/personal-UPI ride is settled directly between rider and
                                    // passenger -- WayDrop's order row never records that private
                                    // amount as something WayDrop "collected", so labeling it
                                    // "Customer Paid" would be misleading. "Ride Fare" (the real,
                                    // authoritative pre-negotiation figure) is shown instead; only a
                                    // genuine gateway-collected settlement is labeled "Customer Paid".
                                    Text(
                                      isDirectSettlement ? 'Ride Fare' : 'Customer Paid',
                                      style: const TextStyle(color: _textGray, fontSize: 12, fontWeight: FontWeight.w500),
                                    ),
                                    const SizedBox(height: 4),
                                    // Same total figure either way (fare == breakdown.customerPaid) --
                                    // only the LABEL above depends on settlement type. Previously
                                    // this read breakdown.fareBeforeGst for direct settlements, which
                                    // silently subtracted Platform GST from the displayed Ride Fare.
                                    Text(
                                      '₹${fare.toStringAsFixed(2)}',
                                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Trip Distance',
                                      style: TextStyle(color: _textGray, fontSize: 12, fontWeight: FontWeight.w500),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      distanceStr,
                                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          const Divider(color: Colors.white10, height: 1),
                          const SizedBox(height: 16),
                          const Text(
                            'RIDE FARE',
                            style: TextStyle(
                              color: _textGray,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(height: 12),
                          // Ride Fare = breakdown.customerPaid (final_fare/current_fare) -- the same
                          // total already shown to the partner on the active-ride screen before
                          // completion. NEVER breakdown.fareBeforeGst, which nets Platform GST out.
                          _buildStatRow('Ride Fare', '₹${fare.toStringAsFixed(2)}'),
                          const SizedBox(height: 12),
                          const Divider(color: Colors.white10, height: 1),
                          const SizedBox(height: 12),
                          const Text(
                            'DEDUCTIONS',
                            style: TextStyle(
                              color: _textGray,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _buildStatRow(
                            subscriptionWaived
                                ? 'WayDrop Commission (0%)'
                                : (commissionPercentage > 0
                                    ? 'WayDrop Commission (${_formatPercent(commissionPercentage)}%)'
                                    : 'WayDrop Commission'),
                            subscriptionWaived ? '₹0.00' : '-₹${commissionAmount.toStringAsFixed(2)}',
                            valueColor: subscriptionWaived ? Colors.white : const Color(0xFFF87171),
                          ),
                          if (subscriptionWaived) ...[
                            const SizedBox(height: 10),
                            _buildStatRow('Subscription Benefit', 'Commission waived', valueColor: _primaryLime),
                          ],
                          if (breakdown.isPgChargeRide) ...[
                            // Eligible Cashfree ride under the deployed PG-charge rule
                            // (migration 20260901000038). rider_earning is ALREADY the final net
                            // (fare - 2% PG charge only; no government tax applies). Only the PG
                            // charge is an actual wallet deduction (orders.pg_charge_amount, never
                            // recomputed in Dart) -- GST (orders.gst_amount) is recorded separately
                            // and shown below YOUR TRIP EARNINGS, never listed here under
                            // DEDUCTIONS, since it no longer reduces the credited amount.
                            const SizedBox(height: 10),
                            _buildStatRow('PG Charge (2%)', '₹${breakdown.pgChargeAmount.toStringAsFixed(2)}'),
                            const Padding(
                              padding: EdgeInsets.only(top: 4),
                              child: Text(
                                'PG Charge (2%) is the only deduction from your wallet. GST is '
                                'recorded separately and is not deducted. No government tax applies '
                                'on this ride.',
                                style: TextStyle(color: _textGray, fontSize: 10, height: 1.3),
                              ),
                            ),
                          ] else ...[
                            const SizedBox(height: 10),
                            // Government Tax -- a SEPARATE concept from WayDrop Commission above and
                            // from "Platform GST" (orders.gst_amount, deliberately not shown on this
                            // partner-facing screen), read live from government_tax_ledger (the same
                            // table apply_order_government_tax() writes -- RLS already lets a rider
                            // read their own rows). 0% company commission during a free trial/MAX
                            // subscription never changes this value.
                            //
                            // Your Trip Earnings is computed from the SAME state-level fetch the hero
                            // card above (completionNetEarnings) already used, not read from
                            // riderEarning/rider_earning directly and not from a second independent
                            // fetch -- calculate_fare_breakdown() only ever subtracts commission from
                            // base_fare to get rider_earning, never government tax, so rider_earning
                            // silently equals Ride Fare whenever commission is 0% (free trial/MAX).
                            // That identity is exactly the reported "Ride Fare == Your Trip Earnings"
                            // bug, and using one shared fetch for both the hero figure and this row
                            // guarantees they can never disagree.
                            _completionTaxLoading
                                ? const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 2),
                                    child: Text(
                                      'Checking applicable government tax...',
                                      style: TextStyle(color: _textGray, fontSize: 11),
                                    ),
                                  )
                                : _buildStatRow(
                                    _completionGovTaxRate > 0
                                        ? 'Government Tax (${_formatPercent(_completionGovTaxRate)}%)'
                                        : 'Government Tax',
                                    '₹${_completionGovTaxAmount.toStringAsFixed(2)}',
                                  ),
                            const Padding(
                              padding: EdgeInsets.only(top: 4),
                              child: Text(
                                'Government tax is separate from company commission and applies '
                                'regardless of subscription/free-trial status.',
                                style: TextStyle(color: _textGray, fontSize: 10, height: 1.3),
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          const Divider(color: Colors.white10, height: 1),
                          const SizedBox(height: 12),
                          _buildStatRow(
                            'YOUR TRIP EARNINGS',
                            '₹${completionNetEarnings.toStringAsFixed(2)}',
                            valueColor: _primaryLime,
                          ),
                          if (breakdown.isPgChargeRide) ...[
                            const SizedBox(height: 8),
                            // GST (5%) -- recorded on the order for reporting/audit only. Not part of
                            // DEDUCTIONS, not subtracted from YOUR TRIP EARNINGS (Phase 12, migration
                            // 20260901000038). Neutral color so it never reads as a wallet deduction.
                            _buildStatRow(
                              'GST (5%) -- recorded separately',
                              '₹${breakdown.gstAmount.toStringAsFixed(2)}',
                              valueColor: _textGray,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Card 2: Route Details Card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: _darkCard,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.15),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.route_outlined, color: _primaryLime, size: 18),
                              const SizedBox(width: 8),
                              const Text(
                                'TRIP ROUTE DETAILS',
                                style: TextStyle(
                                  color: _textGray,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.8,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                '#$orderCode',
                                style: const TextStyle(
                                  color: Colors.white30,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Divider(color: Colors.white10, height: 1),
                          const SizedBox(height: 16),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                margin: const EdgeInsets.only(top: 2),
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF38BDF8),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Pickup Address',
                                      style: TextStyle(color: _textGray, fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      pickupAddr,
                                      style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.3),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const Padding(
                            padding: EdgeInsets.only(left: 4, top: 4, bottom: 4),
                            child: SizedBox(
                              height: 16,
                              child: VerticalDivider(color: Colors.white12, width: 1),
                            ),
                          ),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                margin: const EdgeInsets.only(top: 2),
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: Color(0xFFF43F5E),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Destination Address',
                                      style: TextStyle(color: _textGray, fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      dropoffAddr,
                                      style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.3),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Card 3: Today's Summary Card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: _darkCard,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.15),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.query_stats_rounded, color: _primaryLime, size: 18),
                              SizedBox(width: 8),
                              Text(
                                'TODAY\'S PERFORMANCE',
                                style: TextStyle(
                                  color: _textGray,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Divider(color: Colors.white10, height: 1),
                          const SizedBox(height: 16),
                          _buildStatRow('Updated Wallet Balance', '₹${(double.tryParse(walletBalance.toString()) ?? 0.0).toStringAsFixed(2)}'),
                          const SizedBox(height: 10),
                          _buildStatRow('Today\'s Total Earnings', '₹${(double.tryParse(earnings.toString()) ?? 0.0).toStringAsFixed(2)}'),
                          const SizedBox(height: 10),
                          _buildStatRow(isParcel ? 'Total Completed Deliveries' : 'Total Completed Rides', '$totalRides'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
            
            // Back to Home Button Row Pinned at Bottom
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              decoration: BoxDecoration(
                color: _darkBg,
                border: Border(
                  top: BorderSide(color: Colors.white.withValues(alpha: 0.05), width: 1),
                ),
              ),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: () async {
                    // Part 22: Partner rates the User right after an intercity trip completes,
                    // reusing the same rider_reviews-backed screen as the passenger's own rating
                    // (rated_by='rider' instead of the default 'user').
                    final isIntercity = type.startsWith('intercity');
                    if (isIntercity && order != null && mounted) {
                      // Task 4: replace (not push-on-top-of) this screen so its WebView/realtime
                      // listeners are disposed immediately via a single, normal route transition
                      // — RiderRatingScreen itself already returns the traveller to Intercity Home
                      // for intercity orders, so no trailing pop is needed (the previous
                      // await-push-then-pop pattern raced against RiderRatingScreen's own
                      // navigation and could pop an already-removed route).
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                          builder: (_) => RiderRatingScreen(
                            order: TransportOrder.fromJson(order!),
                            riderData: {
                              'name': order?['users']?['full_name']?.toString() ?? 'Passenger',
                            },
                            ratedByRider: true,
                          ),
                        ),
                      );
                      return;
                    }
                    // Task 4 (local): replace the bare pop with a pushAndRemoveUntil back to a
                    // fresh Rider Home instance -- this screen can be reached via several
                    // Navigator.push entry points (banner tap, notification deep-link, accept
                    // flow), so a bare pop can land on a stale/blank route instead of Rider Home,
                    // which is exactly the reported black-screen bug.
                    if (mounted) returnToLocalRideHome(context, isRider: true);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primaryLime,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  child: const Text(
                    'Back to Home',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
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

  // Drops a trailing ".0" for whole-number rates (e.g. "10%" instead of "10.0%") while still
  // showing one decimal place for fractional configured rates (e.g. "7.5%").
  String _formatPercent(double value) {
    return value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  }

  Widget _buildStatRow(String label, String value, {Color valueColor = Colors.white}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: _textGray, fontSize: 13, fontWeight: FontWeight.w500),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          value,
          style: TextStyle(color: valueColor, fontSize: 14, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  void _initMapController() {
    if (order == null) return;

    mapController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) async {
          if (!mounted) return;
          final apiKey = Env.olaMapsApiKey;
          final safeApiKey = apiKey.replaceAll('"', '');
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final themeMode = isDark ? 'dark' : 'light';
          final pickupLat = double.tryParse(order?['pickup_lat']?.toString() ?? '') ?? 0.0;
          final pickupLng = double.tryParse(order?['pickup_lng']?.toString() ?? '') ?? 0.0;
          final destLat = double.tryParse(order?['destination_lat']?.toString() ?? '') ?? 0.0;
          final destLng = double.tryParse(order?['destination_lng']?.toString() ?? '') ?? 0.0;
          final initialRiderRouteGeo = optimizedGeometry ?? '[]';

          await mapController?.runJavaScript(
            'if(window.initTrackingMap){ window.initTrackingMap("$safeApiKey", "$themeMode", $pickupLat, $pickupLng, $destLat, $destLng, [], $initialRiderRouteGeo); }'
          );
          _triggerInitialLocation();
        },
        // Phase 2A -- minimal WebView failure recovery. If the map's own document (a bundled
        // Flutter asset -- essentially only fails when the Android renderer process is killed under
        // memory pressure, the very failure mode the GPS/camera churn this PR fixes was making more
        // likely) fails to load, the tracking screen would otherwise sit permanently blank. Reload
        // the asset ONCE; onPageFinished above then re-runs initTrackingMap + _triggerInitialLocation
        // and the map comes back. The one-shot guard (_mapReloadAttempts) makes a reload storm
        // impossible. Sub-resource failures (map tiles, fonts) have isForMainFrame != true and are
        // ignored -- those are transient network blips MapLibre already retries on its own.
        onWebResourceError: (error) {
          if (_disposed || !mounted) return;
          if (error.isForMainFrame != true) return;
          if (_mapReloadAttempts >= 1) return;
          _mapReloadAttempts++;
          debugPrint(
            'RiderActiveOrder: tracking WebView main-frame error '
            '(${error.errorCode}: ${error.description}) -- reloading map once',
          );
          mapController?.loadFlutterAsset('assets/map/ola_map_tracking_rider.html');
        },
      ))
      ..loadFlutterAsset('assets/map/ola_map_tracking_rider.html');
  }

  void _startLocalLocationTracking() {
    _localLocationSubscription?.cancel();

    // Phase 2A: the old settings were bare `LocationSettings(bestForNavigation, distanceFilter: 3)`
    // with NO interval. On Android, geolocator then leaves the fused-provider intervalDuration at 0,
    // so a moving rider gets a fix as fast as the GPS produces one (multiple per second) -- every
    // one of which was pushed straight into the WebView. AndroidSettings.intervalDuration caps the
    // OS delivery rate at ~1/s; the 3 m distanceFilter and bestForNavigation accuracy are preserved
    // (a stationary rider still emits nothing; a moving one is still tracked at full precision).
    // The Dart-side coalescing in _onLocalLocationUpdate() is the platform-independent backstop
    // (iOS has no intervalDuration).
    LocationSettings locationSettings;
    if (defaultTargetPlatform == TargetPlatform.android) {
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
        intervalDuration: const Duration(milliseconds: 1000),
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      locationSettings = AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: false,
      );
    } else {
      locationSettings = const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
      );
    }

    _localLocationSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen((position) {
      if (!mounted || _disposed) return;
      _onLocalLocationUpdate(position);
    });
  }

  /// Phase 2A entry point for a fresh local GPS fix bound for the tracking WebView.
  ///
  /// This does NOT push to the map directly any more. It records the newest position (latest-
  /// value-wins) and hands off to [_maybeFlushRiderLocationToMap], which enforces:
  ///   * at most one runJavaScript(updateRiderLocation) call per [_mapPushMinGap];
  ///   * only one such call in flight at a time (a fix arriving mid-eval is coalesced, not queued);
  ///   * a bounded footprint -- exactly one pending Position slot and at most one trailing Timer,
  ///     never a growing backlog of JS calls.
  /// Nothing here touches the DB / dispatch path (that is LocationCacheService's separate stream).
  void _onLocalLocationUpdate(Position position) {
    if (_disposed) return;
    _pendingMapPosition = position;
    _maybeFlushRiderLocationToMap();
  }

  void _maybeFlushRiderLocationToMap() {
    if (_disposed || !mounted) return;
    if (_pendingMapPosition == null || mapController == null || order == null) return;

    // A previous eval is still running -> do nothing; its .whenComplete() below re-drives us with
    // whatever the latest pending position is by then. Watchdog: if that eval somehow never
    // resolves (dead renderer), don't wedge the flag forever -- treat it as stale after 4 s.
    if (_mapPushInFlight) {
      final startedAt = _lastMapPushAt;
      if (startedAt == null || DateTime.now().difference(startedAt) < const Duration(seconds: 4)) {
        return;
      }
      _mapPushInFlight = false;
    }

    final last = _lastMapPushAt;
    if (last != null) {
      final sinceLast = DateTime.now().difference(last);
      if (sinceLast < _mapPushMinGap) {
        // Too soon. Arm exactly one trailing timer for the gap boundary (never stack timers).
        if (_mapPushTimer == null || !_mapPushTimer!.isActive) {
          _mapPushTimer = Timer(_mapPushMinGap - sinceLast, () {
            _mapPushTimer = null;
            _maybeFlushRiderLocationToMap();
          });
        }
        return;
      }
    }

    _pushRiderLocationToMap(_pendingMapPosition!);
  }

  void _pushRiderLocationToMap(Position position) {
    final controller = mapController;
    if (_disposed || !mounted || controller == null || order == null) return;

    final lat = position.latitude;
    final lng = position.longitude;
    final heading = position.heading.isNaN ? 0.0 : position.heading;

    final kyc = (riderProfile?['rider_kyc!riders_kyc_id_fkey'] ?? riderProfile?['rider_kyc']);
    final name = kyc is Map ? kyc['full_name']?.toString() ?? '' : '';
    final image = kyc is Map ? kyc['rider_image']?.toString() ?? '' : '';
    // Phase 12 (Part C): the traveller's own live-tracking marker must reflect the vehicle
    // actually being used for THIS trip/order (orders.vehicle_type, e.g. an approved rider_vehicles
    // entry used for an intercity trip), never the rider's primary KYC-registered vehicle -- a rider
    // whose KYC vehicle is 'bike' but who is driving this trip on an approved 'auto'/'cab' would
    // otherwise see the wrong marker on their own map while the passenger already sees the correct
    // one (intercity_tracking_screen.dart already sources this from the order/rider row, not KYC).
    // kyc['vehicle_type'] is kept only as a last-resort fallback for the rare case order data is
    // still loading.
    final vehicleType = _intercityPlanVehicleType ??
        order?['vehicle_type']?.toString().toLowerCase() ??
        (kyc is Map ? kyc['vehicle_type']?.toString() : null) ??
        'bike';
    final status = order?['order_status']?.toString() ?? '';

    _lastMapPushAt = DateTime.now();
    _mapPushInFlight = true;
    // If we're sending exactly the pending fix, clear the slot -- a fix that lands during the eval
    // re-populates it and is flushed by whenComplete() below.
    if (identical(_pendingMapPosition, position)) _pendingMapPosition = null;

    controller
        .runJavaScript(
          "if (typeof updateRiderLocation === 'function') { updateRiderLocation($lat, $lng, ${jsonEncode(name)}, ${jsonEncode(image)}, ${jsonEncode(vehicleType)}, $heading, ${jsonEncode(status)}); }",
        )
        .whenComplete(() {
      _mapPushInFlight = false;
      _maybeFlushRiderLocationToMap();
    });
  }

  Future<void> _triggerInitialLocation() async {
    final cached = LocationCacheService.cachedPosition;
    if (cached != null) {
      _onLocalLocationUpdate(cached);
      return;
    }
    try {
      final lastPos = await Geolocator.getLastKnownPosition();
      if (lastPos != null) {
        _onLocalLocationUpdate(lastPos);
      }
    } catch (_) {}
  }


}

// =========================================================
// ORDER DETAILS BOTTOM SHEET
// =========================================================
// Perf: extracted from _RiderActiveOrderScreenState.build() so that expanding/collapsing this
// sheet (a purely local UI toggle -- no order data or business logic involved) only rebuilds the
// sheet itself, not the full-screen map/back-button/SOS-button stack that used to live in the same
// build() as these two toggles. `order`, `status`, `isParcel`, `fare` and the pre-built
// `actionArea` (buildActionArea(status, isParcel, fare), computed once by the parent) are passed
// in as an immutable snapshot -- this widget owns no order/business state of its own, so there is
// no duplicated source of truth: the parent's realtime/order-status updates still flow down
// normally via a fresh snapshot on the next parent rebuild.
class _OrderDetailsSheet extends StatefulWidget {
  final Map<String, dynamic>? order;
  final String orderId;
  final String? status;
  final bool isParcel;
  final double fare;
  final double screenHeight;
  final Widget actionArea;

  const _OrderDetailsSheet({
    required this.order,
    required this.orderId,
    required this.status,
    required this.isParcel,
    required this.fare,
    required this.screenHeight,
    required this.actionArea,
  });

  @override
  State<_OrderDetailsSheet> createState() => _OrderDetailsSheetState();
}

class _OrderDetailsSheetState extends State<_OrderDetailsSheet> {
  bool _detailsExpanded = false;
  bool _parcelSpecsExpanded = false;

  Map<String, dynamic>? get order => widget.order;

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    final isParcel = widget.isParcel;
    final fare = widget.fare;
    final screenHeight = widget.screenHeight;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: BoxDecoration(
          color: _darkCard,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 24,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
        padding: EdgeInsets.fromLTRB(20, 12, 20, 24 + Insets.bottom(context)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag Indicator Handle & Header Gestures (Tappable + Draggable)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                setState(() {
                  _detailsExpanded = !_detailsExpanded;
                });
              },
              onVerticalDragEnd: (dragDetails) {
                if (dragDetails.primaryVelocity != null) {
                  if (dragDetails.primaryVelocity! < -250) {
                    // Swiped up -> Expand
                    setState(() {
                      _detailsExpanded = true;
                    });
                  } else if (dragDetails.primaryVelocity! > 250) {
                    // Swiped down -> Collapse
                    setState(() {
                      _detailsExpanded = false;
                    });
                  }
                }
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 38,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Status Tag & Fare Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                        ),
                        child: Text(
                          status.toString().replaceAll('_', ' ').toUpperCase(),
                          style: const TextStyle(
                            color: _primaryLime,
                            fontWeight: FontWeight.bold,
                            fontSize: 10,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      Text(
                        '₹${fare.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Show/Hide Details Indicator Row
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _detailsExpanded ? 'HIDE DETAILS' : 'SHOW DETAILS',
                          style: const TextStyle(
                            color: _primaryLime,
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          _detailsExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                          color: _primaryLime,
                          size: 16,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            if (_detailsExpanded) ...[
              // Constrain details height
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: screenHeight * 0.35 > 320.0
                      ? 320.0
                      : (screenHeight * 0.35 < 220.0 ? 220.0 : screenHeight * 0.35),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Timeline Address Box (Translucent Dark Background)
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
                        ),
                        child: Column(
                          children: [
                            // Pickup Location Row
                            Row(
                              children: [
                                const Icon(Icons.my_location_rounded, color: Colors.greenAccent, size: 16),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'PICKUP',
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white.withValues(alpha: 0.3),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        order?['pickup_address'] ?? 'Pickup Address',
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Divider(color: Colors.white.withValues(alpha: 0.04), height: 1),
                            ),
                            // Destination Location Row
                            Row(
                              children: [
                                const Icon(Icons.location_on_rounded, color: Colors.redAccent, size: 16),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        isParcel ? 'DELIVERY' : 'DROP OFF',
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white.withValues(alpha: 0.3),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        order?['destination_address'] ?? 'Destination Address',
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
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
                      if (isParcel) _buildParcelDetailsPanel(),
                      _buildTripInfoPanel(),
                    ],
                  ),
                ),
              ),
            ] else ...[
              if (isParcel && (status == 'picked_up' || status == 'rider_at_drop'))
                _buildCompactReceiverPanel(),
            ],
            const SizedBox(height: 16),
            Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),
            const SizedBox(height: 16),

            // Fixed CTA Action Area
            widget.actionArea,
          ],
        ),
      ),
    );
  }

  Widget _buildParcelDetailsPanel() {
    final status = order?['order_status']?.toString() ?? 'accepted';
    final isPickedUp = (status == 'picked_up' || status == 'rider_at_drop' || status == 'delivered' || status == 'completed');
    final receiverName = isPickedUp ? (order?['receiver_name']?.toString() ?? 'Receiver') : 'Hidden until pickup';
    final receiverPhone = isPickedUp ? (order?['receiver_phone']?.toString() ?? '') : '';
    final parcelType = order?['parcel_type']?.toString().replaceAll('_', ' ').toUpperCase() ?? 'DOCUMENT';
    final weightCategory = order?['weight_category']?.toString().toUpperCase() ?? 'MEDIUM';
    final specialInstructions = order?['special_instructions']?.toString() ?? '';

    final rawImages = order?['parcel_images'];
    List<String> parcelImages = [];
    if (rawImages is List) {
      parcelImages = rawImages.map((e) => e.toString()).toList();
    } else if (rawImages is String && rawImages.isNotEmpty) {
      try {
        final parsed = jsonDecode(rawImages);
        if (parsed is List) {
          parcelImages = parsed.map((e) => e.toString()).toList();
        }
      } catch (_) {}
    }

    return Container(
      margin: const EdgeInsets.only(top: 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              setState(() {
                _parcelSpecsExpanded = !_parcelSpecsExpanded;
              });
            },
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.inventory_2_rounded, color: _primaryLime, size: 16),
                      const SizedBox(width: 8),
                      const Text(
                        'PARCEL SPECIFICATIONS',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                  Icon(
                    _parcelSpecsExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    color: _primaryLime,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
          if (_parcelSpecsExpanded) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Receiver Row
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.04),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.person_rounded, color: Colors.white70, size: 16),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'RECEIVER',
                              style: TextStyle(
                                fontSize: 8.5,
                                fontWeight: FontWeight.bold,
                                color: Colors.white.withValues(alpha: 0.3),
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              receiverName,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                            if (receiverPhone.isNotEmpty) ...[
                              const SizedBox(height: 1),
                              Text(
                                receiverPhone,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.white.withValues(alpha: 0.5),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ]
                          ],
                        ),
                      ),
                      if (receiverPhone.isNotEmpty)
                        GestureDetector(
                          onTap: () async {
                            final cleanPhone = receiverPhone.replaceAll(RegExp(r'\s+'), '');
                            final uri = Uri.parse('tel:$cleanPhone');
                            try {
                              await launchUrl(uri);
                            } catch (_) {}
                          },
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: _primaryLime.withValues(alpha: 0.1),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.phone_rounded, color: _primaryLime, size: 16),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Specs chips
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.03),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.line_weight_rounded, size: 12, color: _primaryLime),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  weightCategory,
                                  style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white70),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.03),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.category_rounded, size: 12, color: _primaryLime),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  parcelType,
                                  style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white70),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),

                  if (specialInstructions.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Divider(color: Colors.white10, height: 1),
                    const SizedBox(height: 10),
                    Text(
                      'SPECIAL INSTRUCTIONS',
                      style: TextStyle(
                        fontSize: 8.5,
                        fontWeight: FontWeight.bold,
                        color: Colors.white.withValues(alpha: 0.3),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      specialInstructions,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.white70,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],

                  if (parcelImages.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Divider(color: Colors.white10, height: 1),
                    const SizedBox(height: 10),
                    Text(
                      'ATTACHED IMAGES',
                      style: TextStyle(
                        fontSize: 8.5,
                        fontWeight: FontWeight.bold,
                        color: Colors.white.withValues(alpha: 0.3),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 52,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: parcelImages.length,
                        itemBuilder: (context, index) {
                          return Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: GestureDetector(
                              onTap: () => _viewFullScreenImage(context, parcelImages[index]),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                // 52x52 display size: downsample the decoded image in
                                // memory. Shares the same disk cache entry as the
                                // full-screen viewer below, so tapping to view
                                // full-screen does not re-download the image.
                                child: CachedNetworkImage(
                                  imageUrl: parcelImages[index],
                                  width: 52,
                                  height: 52,
                                  fit: BoxFit.cover,
                                  memCacheWidth: (52 * MediaQuery.of(context).devicePixelRatio).round(),
                                  memCacheHeight: (52 * MediaQuery.of(context).devicePixelRatio).round(),
                                  errorWidget: (_, _, _) => Container(
                                    width: 52,
                                    height: 52,
                                    color: Colors.white.withValues(alpha: 0.04),
                                    child: const Icon(Icons.broken_image_rounded, size: 16, color: Colors.white30),
                                  ),
                                ),
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
          ],
        ],
      ),
    );
  }

  String _formatTravelPlanDate(dynamic dt) {
    if (dt == null) return '';
    try {
      final parsed = dt is DateTime ? dt : DateTime.parse(dt.toString());
      final localDt = parsed.toLocal();

      final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      final month = months[localDt.month - 1];
      final day = localDt.day.toString();

      final hourVal = localDt.hour;
      final amPm = hourVal >= 12 ? 'PM' : 'AM';
      final hour12 = hourVal % 12 == 0 ? 12 : hourVal % 12;
      final minute = localDt.minute.toString().padLeft(2, '0');

      return '$day $month, $hour12:$minute $amPm';
    } catch (e) {
      return dt.toString();
    }
  }

  Widget _buildTripInfoPanel() {
    final orderType = order?['order_type']?.toString() ?? '';
    final isParcel = orderType == 'local_parcel' || orderType == 'intercity_parcel' || orderType.contains('parcel') || orderType.contains('delivery');
    if (isParcel) return const SizedBox();

    final orderCode = order?['order_code']?.toString() ?? widget.orderId;
    final isIntercity = orderType == 'intercity_ride' || orderType == 'intercity';
    final travelDateStr = order?['travel_date'] != null ? _formatTravelPlanDate(order?['travel_date']) : '';

    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.info_outline, color: _primaryLime, size: 16),
              const SizedBox(width: 8),
              Text(
                'TRIP DETAILS',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildDetailItem('Order Code', '#$orderCode'),
          if (isIntercity && travelDateStr.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildDetailItem('Travel Date', travelDateStr),
          ],
        ],
      ),
    );
  }

  Widget _buildDetailItem(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withValues(alpha: 0.5),
            fontWeight: FontWeight.w500,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 12,
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  void _viewFullScreenImage(BuildContext context, String imageUrl) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.9),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          alignment: Alignment.center,
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              // Full-screen view: no mem-cache downsampling (largest display size
              // here), but still routed through CachedNetworkImage so it reads the
              // same disk cache entry the 52x52 thumbnail already populated instead
              // of re-downloading the same URL.
              child: CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.contain,
                width: double.infinity,
                height: double.infinity,
                placeholder: (context, url) => const Center(
                  child: CircularProgressIndicator(color: Colors.white54),
                ),
                errorWidget: (_, _, _) => const Center(
                  child: Icon(Icons.broken_image_rounded, size: 48, color: Colors.white30),
                ),
              ),
            ),
            Positioned(
              top: MediaQuery.of(ctx).padding.top + 16,
              right: 16,
              child: GestureDetector(
                onTap: () => Navigator.pop(ctx),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close_rounded, color: Colors.white, size: 24),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactReceiverPanel() {
    final receiverName = order?['receiver_name']?.toString() ?? 'Receiver';
    final receiverPhone = order?['receiver_phone']?.toString() ?? '';
    if (receiverPhone.isEmpty) return const SizedBox();

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.person_rounded, color: Colors.white70, size: 16),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'DELIVER TO',
                  style: TextStyle(
                    fontSize: 8.5,
                    fontWeight: FontWeight.bold,
                    color: Colors.white.withValues(alpha: 0.3),
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  receiverName,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () async {
              final cleanPhone = receiverPhone.replaceAll(RegExp(r'\s+'), '');
              final uri = Uri.parse('tel:$cleanPhone');
              try {
                await launchUrl(uri);
              } catch (_) {}
            },
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _primaryLime.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.phone_rounded, color: _primaryLime, size: 16),
            ),
          ),
        ],
      ),
    );
  }
}

// =========================================================
// PREMIUM SWIPE TO CONFIRM BUTTON
// =========================================================
class SwipeToConfirmButton extends StatefulWidget {
  final String text;
  final FutureOr<void> Function() onSwipeComplete;
  final Color baseColor;
  final Color thumbColor;
  final Color textColor;

  const SwipeToConfirmButton({
    super.key,
    required this.text,
    required this.onSwipeComplete,
    this.baseColor = const Color(0xFF1E293B), // Dark slate
    this.thumbColor = _primaryLime, // Neon lime
    this.textColor = Colors.white,
  });

  @override
  State<SwipeToConfirmButton> createState() => _SwipeToConfirmButtonState();
}

class _SwipeToConfirmButtonState extends State<SwipeToConfirmButton> {
  double _dragPercentage = 0.0;
  bool _completed = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double width = constraints.maxWidth;
        final double height = 56.0;
        final double thumbSize = 48.0;
        final double maxDragDistance = width - thumbSize - 8.0; // 4px padding on each side

        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: widget.baseColor,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 1.5),
          ),
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              // Swipe text
              Center(
                child: Opacity(
                  opacity: (1.0 - _dragPercentage).clamp(0.2, 1.0),
                  child: Text(
                    widget.text,
                    style: TextStyle(
                      color: widget.textColor,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),

              // Sliding active background (translucent lime fill)
              Positioned(
                left: 4,
                top: 4,
                bottom: 4,
                child: Container(
                  width: (_dragPercentage * maxDragDistance) + (thumbSize / 2),
                  decoration: BoxDecoration(
                    color: widget.thumbColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
              ),

              // Draggable Thumb
              Positioned(
                left: 4 + (_dragPercentage * maxDragDistance),
                child: GestureDetector(
                  onHorizontalDragUpdate: (details) {
                    if (_completed) return;
                    setState(() {
                      _dragPercentage += details.delta.dx / maxDragDistance;
                      _dragPercentage = _dragPercentage.clamp(0.0, 1.0);
                    });
                  },
                  onHorizontalDragEnd: (details) {
                    if (_completed) return;
                    if (_dragPercentage >= 0.85) {
                      setState(() {
                        _dragPercentage = 1.0;
                        _completed = true;
                      });
                      // Re-arm the swipe only once the in-flight call (if any) has
                      // actually finished, not after a blind fixed delay -- on a
                      // slow network a fixed delay let a second swipe fire a
                      // duplicate request before the first one resolved.
                      () async {
                        final result = widget.onSwipeComplete();
                        await Future.wait([
                          Future.delayed(const Duration(milliseconds: 600)),
                          if (result is Future) result else Future.value(),
                        ]);
                        if (mounted) {
                          setState(() {
                            _dragPercentage = 0.0;
                            _completed = false;
                          });
                        }
                      }();
                    } else {
                      setState(() {
                        _dragPercentage = 0.0;
                      });
                    }
                  },
                  child: Container(
                    width: thumbSize,
                    height: thumbSize,
                    decoration: BoxDecoration(
                      color: widget.thumbColor,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: widget.thumbColor.withValues(alpha: 0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Icon(
                      _completed ? Icons.check_rounded : Icons.chevron_right_rounded,
                      color: Colors.black,
                      size: 26,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// =========================================================
// CUSTOM OTP ENTRY SHEET WITH 4 DIGIT BOXES & TIMER
// =========================================================
class OtpSheetContent extends StatefulWidget {
  final bool pickup;
  final Map<String, dynamic>? order;
  final Future<String?> Function(String enteredOtp) onVerify;
  final Future<String?> Function() onResend;

  const OtpSheetContent({
    super.key,
    required this.pickup,
    required this.order,
    required this.onVerify,
    required this.onResend,
  });

  @override
  State<OtpSheetContent> createState() => _OtpSheetContentState();
}

class _OtpSheetContentState extends State<OtpSheetContent> {
  final TextEditingController _otpController = TextEditingController();
  final FocusNode _pinFocusNode = FocusNode();
  
  Timer? _resendTimer;
  int _countdown = 30;

  bool _isVerifying = false;
  bool _isResending = false;
  String? _errorMessage;
  String? _successMessage;

  @override
  void initState() {
    super.initState();
    _startCountdown();
  }

  void _startCountdown() {
    _countdown = 30;
    _resendTimer?.cancel();
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdown > 0) {
        setState(() {
          _countdown--;
        });
      } else {
        _resendTimer?.cancel();
      }
    });
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    _otpController.dispose();
    _pinFocusNode.dispose();
    super.dispose();
  }

  Future<void> _resendOtp() async {
    setState(() {
      _isResending = true;
      _errorMessage = null;
      _successMessage = null;
    });
    try {
      await widget.onResend();
      if (!mounted) return;
      _startCountdown();
      setState(() {
        _successMessage = 'OTP regenerated successfully!';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _isResending = false;
        });
      }
    }
  }

  Future<void> _onVerifyPressed() async {
    final entered = _otpController.text.trim();
    if (entered.length < 4) {
      setState(() {
        _errorMessage = 'Please enter all 4 digits';
        _successMessage = null;
      });
      return;
    }
    setState(() {
      _isVerifying = true;
      _errorMessage = null;
      _successMessage = null;
    });
    try {
      final error = await widget.onVerify(entered);
      if (!mounted) return;
      if (error != null) {
        setState(() {
          _errorMessage = error;
          _otpController.clear();
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _otpController.clear();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isVerifying = false;
        });
      }
    }
  }

  Widget _buildPassengerIdentity() {
    final order = widget.order;
    final users = order?['users'] as Map<String, dynamic>?;
    final name = users?['full_name']?.toString() ?? 'Passenger';
    final gender = users?['gender']?.toString();
    final photoUrl = users?['profile_photo_url']?.toString();
    final pickupCity = LocationDisplayService.resolveCity(
      city: order?['pickup_city'],
      address: order?['pickup_address'],
      fallback: 'Pickup',
    );
    final destCity = LocationDisplayService.resolveCity(
      city: order?['destination_city'],
      address: order?['destination_address'],
      fallback: 'Drop',
    );
    final genderLabel = gender == 'male' ? 'Male' : gender == 'female' ? 'Female' : gender == 'other' ? 'Other' : 'Not specified';
    final genderIcon = gender == 'female' ? Icons.female_rounded : gender == 'male' ? Icons.male_rounded : Icons.wc_rounded;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _darkCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _primaryLime.withValues(alpha: 0.15), width: 1.5),
      ),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: Colors.white.withValues(alpha: 0.06),
                backgroundImage: (photoUrl != null && photoUrl.isNotEmpty) ? NetworkImage(photoUrl) : null,
                child: (photoUrl == null || photoUrl.isEmpty)
                    ? const Icon(Icons.person_rounded, color: _textGray, size: 24)
                    : null,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(genderIcon, color: _textGray, size: 13),
                        const SizedBox(width: 4),
                        Text(genderLabel, style: const TextStyle(color: _textGray, fontSize: 12, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Container(height: 1, color: Colors.white.withValues(alpha: 0.06)),
          ),
          Row(
            children: [
              const Icon(Icons.trip_origin_rounded, color: _primaryLime, size: 13),
              const SizedBox(width: 6),
              Expanded(
                child: Text(pickupCity, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
              Icon(Icons.arrow_forward_rounded, color: _textGray.withValues(alpha: 0.5), size: 13),
              const SizedBox(width: 6),
              const Icon(Icons.location_on_rounded, color: Colors.redAccent, size: 13),
              const SizedBox(width: 6),
              Expanded(
                child: Text(destCity, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedPadding(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
          const SizedBox.shrink(),
          const SizedBox(height: 22),
          // Passenger identity block -- shown before the OTP input so the traveller always knows
          // exactly which passenger they're verifying, even with several accepted passengers on
          // the same travel plan. Never shows phone (contact info isn't relevant to identity
          // confirmation and stays in the order detail/chat surfaces instead).
          _buildPassengerIdentity(),
          const SizedBox(height: 20),
          Text(
            widget.pickup ? 'Enter Pickup OTP' : 'Enter Delivery OTP',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.pickup
                ? 'Ask user for the 4-digit pickup code'
                : 'Ask user for the 4-digit delivery code',
            style: TextStyle(
              fontSize: 13,
              color: _textGray,
            ),
          ),
          const SizedBox(height: 24),
          // OTP Entering Boxes Row
          Pinput(
            length: 4,
            controller: _otpController,
            focusNode: _pinFocusNode,
            enabled: !_isVerifying && !_isResending,
            keyboardType: TextInputType.number,
            defaultPinTheme: PinTheme(
              width: 56,
              height: 56,
              textStyle: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 1.5),
              ),
            ),
            focusedPinTheme: PinTheme(
              width: 56,
              height: 56,
              textStyle: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _primaryLime, width: 2),
              ),
            ),
            disabledPinTheme: PinTheme(
              width: 56,
              height: 56,
              textStyle: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white54,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.02),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withValues(alpha: 0.04), width: 1.5),
              ),
            ),
            onCompleted: (pin) => _onVerifyPressed(),
          ),
          const SizedBox(height: 24),
          // Inline alert notifications
          if (_errorMessage != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.redAccent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ] else if (_successMessage != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: _primaryLime.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _primaryLime.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_outline_rounded, color: _primaryLime, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _successMessage!,
                      style: const TextStyle(
                        color: _primaryLime,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
          // Resend OTP section
          _isResending
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    color: _primaryLime,
                    strokeWidth: 2,
                  ),
                )
              : (_countdown > 0
                  ? Text(
                      'Resend OTP in ${_countdown}s',
                      style: TextStyle(
                        fontSize: 13,
                        color: _textGray,
                        fontWeight: FontWeight.w500,
                      ),
                    )
                  : TextButton(
                      onPressed: _resendOtp,
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text(
                        'Resend OTP',
                        style: TextStyle(
                          fontSize: 14,
                          color: _primaryLime,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    )),
          const SizedBox(height: 24),
          // Verify Button
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _isVerifying || _isResending ? null : _onVerifyPressed,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isVerifying || _isResending ? Colors.grey.shade800 : _primaryLime,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                elevation: 0,
              ),
              child: _isVerifying
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        color: Colors.black,
                        strokeWidth: 2.5,
                      ),
                    )
                  : const Text(
                      'Verify OTP',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Colors.black,
                      ),
                    ),
            ),
          ),
        ],
      ),
    ),);
  }
}

class _MapBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  const _MapBtn({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Tooltip(
      message: tooltip ?? '',
      child: Card(
        elevation: 4,
        shape: const CircleBorder(),
        color: isDark ? const Color(0xFF131929) : Colors.white,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              icon,
              color: isDark ? Colors.white : const Color(0xFF475569),
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}
