import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/models/transport_order.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/core/services/network/poll_backoff.dart';

/// Clean state controller to isolate real-time database feeds (orders and riders)
/// from the UI layer. Exposes updates via ValueNotifier.
class RealtimeOrderController {
  final String orderId;
  final supabase = Supabase.instance.client;

  final ValueNotifier<TransportOrder?> orderNotifier = ValueNotifier<TransportOrder?>(null);
  final ValueNotifier<Map<String, double>?> riderLocationNotifier = ValueNotifier<Map<String, double>?>(null);
  final ValueNotifier<Map<String, dynamic>?> riderNotifier = ValueNotifier<Map<String, dynamic>?>(null);
  final ValueNotifier<Map<String, dynamic>?> liveStateNotifier = ValueNotifier<Map<String, dynamic>?>(null);
  final ValueNotifier<String> userNameNotifier = ValueNotifier<String>('');

  String? _orderSubId;
  String? _riderSubId;
  String? _currentRiderId;
  Timer? _pollingTimer;
  DateTime? _lastRealtimeDeliveryAt;
  // P1-E: when the polling fallback last actually ran a fetch (as opposed to every 5s base timer
  // tick, most of which now just re-evaluate whether a fetch is due yet under the backoff schedule
  // below). Distinct from _lastRealtimeDeliveryAt, which tracks realtime health, not polling pacing.
  DateTime? _lastPollFetchAt;
  bool _isDisposed = false;

  // Performance Roadmap Task 3: the realtime-health gate below only stops the polling timer from
  // firing while realtime has delivered recently -- it does not stop a realtime event from landing
  // (and starting its own fetchOrder()+fetchLiveOrderState() pair) while a timer-triggered fetch of
  // the exact same data is still in flight (fetchLiveOrderState alone can take up to its own 10s
  // timeout), or vice versa. These two flags coalesce that case into a single follow-up fetch
  // instead of two running concurrently -- same coalescing pattern already used for the identical
  // problem in rider_orders_screen.dart's fetchSearchingOrders().
  bool _refreshInFlight = false;
  bool _refreshQueued = false;

  // Egress fix: fetchOrder()/fetchLiveOrderState() both swallow their own errors
  // internally (existing try/catch/debugPrint pattern, never rethrows), so failure is
  // recorded directly from inside each of those functions' own catch blocks rather
  // than by wrapping the call here. Consulted once per due-to-fire tick, right before
  // _refreshOrderAndLiveState() -- see the polling timer below.
  final PollBackoff _pollBackoff = PollBackoff();

  RealtimeOrderController({required this.orderId});

  /// Starts the state merging and real-time subscription lifecycle
  Future<void> start() async {
    await fetchOrder();
    if (_isDisposed) return;
    // Fetch live state in background asynchronously to prevent screen loading delays. Skipped for
    // an order that's already terminal by the time this screen opened (matching guard in
    // _refreshOrderAndLiveState below) -- there is no live rider ETA to show for a finished ride.
    final loadedOrder = orderNotifier.value;
    if (loadedOrder == null || !(loadedOrder.isCompleted || loadedOrder.isCancelled)) {
      fetchLiveOrderState();
    }
    // The two fetches above already cover the initial poll -- mark it done so the timer below
    // waits its own full interval before firing again, instead of re-fetching immediately.
    _lastPollFetchAt = DateTime.now();
    _subscribeOrder();

    // Polling timer: queries live order status and details as a safety backup
    // to ensure status updates and dynamic ETAs sync if WebSockets disconnect/drop! The 5s tick is
    // just the base heartbeat used to re-evaluate whether a fetch is actually due -- see
    // _refreshInterval below for the real (adaptive) cadence.
    _pollingTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (_isDisposed) {
        timer.cancel();
        return;
      }

      // Realtime-health gate: while the WebSocket has delivered an update
      // recently, the poll is a pure duplicate -- skip it entirely (zero
      // polling while realtime is healthy). It stays as the safety fallback
      // the moment realtime goes stale (WS drop/backoff).
      final lastDelivery = _lastRealtimeDeliveryAt;
      if (lastDelivery != null &&
          DateTime.now().difference(lastDelivery) <
              const Duration(seconds: 15)) {
        return;
      }

      final now = DateTime.now();
      final interval = _refreshInterval(
        staleness: lastDelivery == null ? Duration.zero : now.difference(lastDelivery),
        status: orderNotifier.value?.orderStatus,
      );
      if (_lastPollFetchAt != null && now.difference(_lastPollFetchAt!) < interval) {
        return;
      }
      _lastPollFetchAt = now;

      // Egress fix: skip this fetch if recent attempts have been failing (Supabase
      // throttle/outage) -- consumed only on ticks that were actually due to fire
      // above, so backoff is measured in "would-be fetches", not raw 5s base ticks.
      if (!_pollBackoff.shouldAttempt()) return;

      debugPrint(
        '[TRACE_CANCEL] RealtimeOrderController pollingTimer tick=${timer.tick} '
        'order=$orderId (fallback fetch, realtime may be stale, interval=${interval.inSeconds}s) '
        'epoch=${DateTime.now().millisecondsSinceEpoch}',
      );
      await _refreshOrderAndLiveState();
    });
  }

  /// P1-E: how often the polling fallback should actually fetch, given how long realtime has been
  /// stale and the order's current status. Callers only reach this once the realtime-health gate
  /// above has already decided a poll is even in play (i.e. staleness >= 15s or realtime has never
  /// delivered yet this session) -- this only controls the cadence WITHIN that fallback window, it
  /// never causes a poll to fire while realtime is healthy.
  ///
  /// The longer a realtime gap persists, the more this backs off, rather than hammering the same
  /// fixed cadence indefinitely -- a prolonged gap is itself often a symptom of the same backend
  /// contention this investigation traced production slowdowns to, so widening the interval here
  /// reduces peak simultaneous DB demand precisely when it matters most. Still always converges on
  /// SOME bounded interval (never fully stops), so no state update can be permanently missed --
  /// only spaced further apart the longer realtime stays stale. `searching`/`created` orders (no
  /// rider assigned yet, dispatch actively in progress) keep a tighter band throughout, since a
  /// rider being matched needs to reach the passenger/rider UI promptly, unchanged from before.
  Duration _refreshInterval({required Duration staleness, String? status}) {
    final isSearchingOrCreated = status == 'searching' || status == 'created' || status == null;
    if (staleness < const Duration(seconds: 60)) {
      return isSearchingOrCreated ? const Duration(seconds: 5) : const Duration(seconds: 15);
    } else if (staleness < const Duration(seconds: 180)) {
      return isSearchingOrCreated ? const Duration(seconds: 10) : const Duration(seconds: 30);
    } else {
      return isSearchingOrCreated ? const Duration(seconds: 20) : const Duration(seconds: 45);
    }
  }

  /// Shared entry point for both the polling fallback and the realtime callback below.
  ///
  /// P2 fix: the realtime order-update callback already has the fresh row (`payload.newRecord`) --
  /// it applies that directly via `_applyOrderData` (see `_subscribeOrder` below) instead of paying
  /// for a second `orders` SELECT that would return the exact same data. Only `fetchLiveOrderState()`
  /// (rider/ETA/signed-URL enrichment, which the raw order payload doesn't carry) is still needed
  /// there, so `includeOrderFetch: false` skips the redundant read for that caller. The polling
  /// fallback has no payload to draw from, so it keeps doing both, unchanged (`includeOrderFetch`
  /// defaults to true).
  ///
  /// Still guarded so that if one trigger's fetch is already running, the other coalesces into a
  /// single queued follow-up instead of running a second concurrent fetch (Performance Roadmap
  /// Task 3) -- both callers share this SAME guard, so a realtime-triggered fetchLiveOrderState()
  /// and a timer-triggered full pair can never run concurrently against each other either. A queued
  /// follow-up always re-runs the full pair (the safer default) regardless of what the coalesced
  /// trigger actually needed.
  Future<void> _refreshOrderAndLiveState({bool includeOrderFetch = true}) async {
    if (_isDisposed) return;
    // WayDrop Ola egress reduction (2026-08-22): once the order has reached a terminal state,
    // fetchLiveOrderState()'s rider-ETA lookup (an Ola Distance Matrix call, only cache-deduped
    // for 20s -- see get-live-order-status/_shared/eta_cache.ts) is no longer meaningful, and
    // fetchOrder() has nothing further to discover either. This is reached, in particular, right
    // on the realtime callback's OWN transition into a terminal status (_subscribeOrder below
    // already applied the fresh terminal row via _applyOrderData before calling here) -- which
    // previously still fired one more full live-state fetch for a ride that had just ended.
    final currentOrder = orderNotifier.value;
    if (currentOrder != null && (currentOrder.isCompleted || currentOrder.isCancelled)) {
      return;
    }
    if (_refreshInFlight) {
      _refreshQueued = true;
      return;
    }
    _refreshInFlight = true;
    try {
      final fetches = <Future<void>>[fetchLiveOrderState()];
      if (includeOrderFetch) fetches.add(fetchOrder());
      await Future.wait(fetches);
    } finally {
      _refreshInFlight = false;
      if (_refreshQueued) {
        _refreshQueued = false;
        if (!_isDisposed) {
          unawaited(_refreshOrderAndLiveState());
        }
      }
    }
  }

  /// Applies a fresh order row -- from either a direct `orders` fetch or a realtime payload, both
  /// carry the identical shape -- to state, and runs the same side effects (username fetch, rider
  /// fetch/subscribe) either way. Extracted out of fetchOrder() (P2 fix) so the realtime callback
  /// can use payload.newRecord directly without a redundant network round trip for data it already
  /// has.
  void _applyOrderData(Map<String, dynamic> data) {
    if (_isDisposed) return;
    final transportOrder = TransportOrder.fromJson(data);
    debugPrint(
      '[TRACE_CANCEL] RealtimeOrderController._applyOrderData order=$orderId '
      'status=${transportOrder.orderStatus} isCancelled=${transportOrder.isCancelled} '
      'isCompleted=${transportOrder.isCompleted} epoch=${DateTime.now().millisecondsSinceEpoch}',
    );
    orderNotifier.value = transportOrder;

    if (userNameNotifier.value.isEmpty) {
      _fetchUserName(transportOrder.userId);
    }

    if (transportOrder.riderId != null && transportOrder.riderId != _currentRiderId) {
      // Fetch rider profile details in background without awaiting to speed up loading
      _fetchRider(transportOrder.riderId!);
      _subscribeRider(transportOrder.riderId!);
    }
  }

  /// Initial order fetch to set the base state
  //
  // Egress fix pass (Fix #5): deliberately left as a bare select, not narrowed. TransportOrder
  // .fromJson (models/transport_order.dart) reads ~55 distinct fields off this row -- fare, GST,
  // commission, timestamps, addresses, OTPs, parcel data -- across every ride/parcel/intercity
  // tracking screen, so a field-list narrow here would already need to be nearly as wide as `*`
  // to stay correct, with real financial-field-omission risk for comparatively little byte
  // savings. It also wouldn't reduce the dominant cost: `orders` has REPLICA IDENTITY FULL, so
  // every realtime UPDATE this same order later receives already ships the complete row
  // regardless of what this one-time initial fetch selects.
  Future<void> fetchOrder() async {
    try {
      final response = await supabase
          .from('orders')
          .select()
          .eq('id', orderId)
          .maybeSingle();

      if (_isDisposed) return;
      if (response == null) {
        orderNotifier.value = null;
        _pollBackoff.recordSuccess();
        return;
      }
      _applyOrderData(response);
      _pollBackoff.recordSuccess();
    } catch (e) {
      if (!_isDisposed) {
        debugPrint('REALTIME ORDER CONTROLLER FETCH ERROR => $e');
      }
      _pollBackoff.recordFailure();
    }
  }

  Future<void> _fetchUserName(String userId) async {
    try {
      final res = await supabase
          .from('users')
          .select('full_name')
          .eq('id', userId)
          .single();
      if (_isDisposed) return;
      userNameNotifier.value = res['full_name']?.toString() ?? '';
    } catch (e) {
      debugPrint('Error fetching user name in RealtimeOrderController: $e');
    }
  }

  Future<void> fetchLiveOrderState() async {
    try {
      final response = await supabase.functions.invoke(
        'get-live-order-status',
        body: {'order_id': orderId},
        // CLIENT-1 (WayDrop Progressive Degradation Audit): this is polled periodically, so a
        // stalled call must never block the next poll indefinitely — bounded here, caught by the
        // existing silent catch below exactly like any other network error.
      ).timeout(const Duration(seconds: 10));
      
      if (_isDisposed) return;
      if (response.data != null) {
        Map<String, dynamic> data;
        try {
          if (response.data is String) {
            data = Map<String, dynamic>.from(jsonDecode(response.data as String));
          } else {
            data = Map<String, dynamic>.from(response.data as Map);
          }
        } catch (e) {
          debugPrint('JSON DECODE ERROR => $e');
          return;
        }

        if (_isDisposed) return;
        if (data['success'] == true) {
          liveStateNotifier.value = data;

          if (data['rider_assigned'] == true && data['rider'] != null) {
            final riderData = data['rider'];
            final location = data['live_location'];
            final String? rId = data['rider']?['id']?.toString() ?? orderNotifier.value?.riderId;

            if (rId != null && rId != _currentRiderId) {
              await _fetchRider(rId);
              if (_isDisposed) return;
              _subscribeRider(rId);
            }

            if (_isDisposed) return;
            riderNotifier.value = {
              'id': riderData['id'],
              'name': riderData['name'] ?? '',
              'phone': riderData['phone'],
              'rider_image': riderData['image'] ?? '',
              'vehicle_number': riderData['vehicle_number'] ?? '',
              // Issue 3 fix: no hardcoded 'bike' fallback here -- get-live-order-status already
              // resolves this correctly (intercity travel-plan vehicle_type, falling back to the
              // rider's KYC vehicle_type, falling back to null when truly unknown). Defaulting a
              // missing value to a specific vehicle type here was itself the root cause of showing
              // "BIKE" for a CAR trip whenever the authoritative source was briefly unavailable.
              'vehicle_type': riderData['vehicle_type'],
              'rating': double.tryParse(riderData['rating']?.toString() ?? '') ?? 4.5,
            };

            if (location != null) {
              final lat = double.tryParse(location['latitude']?.toString() ?? '');
              final lng = double.tryParse(location['longitude']?.toString() ?? '');
              final heading = double.tryParse(location['heading']?.toString() ?? '') ?? 0.0;
              if (lat != null && lng != null && !_isDisposed) {
                riderLocationNotifier.value = {'lat': lat, 'lng': lng, 'heading': heading};
              }
            }
          }
        }
      }
      _pollBackoff.recordSuccess();
    } catch (e) {
      if (!_isDisposed) {
        debugPrint('REALTIME LIVE STATE EDGE FUNCTION ERROR => $e');
      }
      _pollBackoff.recordFailure();
    }
  }

  /// Fetches rider's profile and initial position — joins riders + rider_kyc + users
  Future<void> _fetchRider(String riderId) async {
    try {
      final response = await supabase
          .from('riders')
          .select('''
            id,
            user_id,
            rating,
            total_orders,
            total_completed_orders,
            total_cancelled_orders,
            account_status,
            current_lat,
            current_lng,
            current_heading,

            rider_kyc!riders_kyc_id_fkey(
              full_name,
              vehicle_number,
              vehicle_type,
              rider_image,
              vehicle_image
            ),

            users!riders_user_id_fkey(
              full_name,
              phone
            )
          ''')
          .eq('id', riderId)
          .single();

      if (_isDisposed) return;

      // Fetch dynamic reliability stats
      Map<String, dynamic>? reliabilityRes;
      try {
        // Egress fix: narrowed to the 6 fields flattened into `flat` immediately below.
        reliabilityRes = await supabase
            .from('rider_reliability_view')
            .select(
              'reliability_score, completion_rate, on_time_rate, total_completed, '
              'total_cancelled, experience_score',
            )
            .eq('rider_id', riderId)
            .maybeSingle();
      } catch (e) {
        debugPrint('Error fetching rider reliability view in controller: $e');
      }

      // Flatten nested joins into the top-level map so the UI
      // can use simple keys: 'name', 'vehicle_number', 'rating', 'phone' etc.
      final Map<String, dynamic> flat = Map<String, dynamic>.from(response);

      if (reliabilityRes != null) {
        flat['reliability_score'] = reliabilityRes['reliability_score'];
        flat['completion_rate'] = reliabilityRes['completion_rate'];
        flat['on_time_rate'] = reliabilityRes['on_time_rate'];
        flat['total_completed'] = reliabilityRes['total_completed'];
        flat['total_cancelled'] = reliabilityRes['total_cancelled'];
        flat['experience_score'] = reliabilityRes['experience_score'];
      }

      final kyc = flat['rider_kyc!riders_kyc_id_fkey'] ?? flat['rider_kyc'];
      String? kycName;
      if (kyc is Map) {
        flat['vehicle_number'] = kyc['vehicle_number'];
        flat['vehicle_type']   = kyc['vehicle_type'];
        flat['rider_image']    = kyc['rider_image'];
        flat['vehicle_image']  = kyc['vehicle_image'];
        kycName                = kyc['full_name']?.toString();
      }
      flat.remove('rider_kyc!riders_kyc_id_fkey');
      flat.remove('rider_kyc');

      // Issue 3 fix: rider_kyc.vehicle_type is the rider's own KYC-verified vehicle, which can
      // differ from the specific vehicle they published for THIS travel plan/trip. For intercity
      // orders, rider_travel_plans.vehicle_type (via the accepted intercity_requests row linking
      // this order to this traveller) is authoritative and overrides the KYC value. This runs on
      // every _fetchRider() call -- including realtime rider-row-change events (e.g. location
      // pings) -- so a correct value set by fetchLiveOrderState() is never clobbered back to the
      // wrong KYC vehicle by a later realtime update. Local ride/parcel orders are untouched.
      final currentOrderType = orderNotifier.value?.orderType;
      if (currentOrderType == 'intercity_ride' || currentOrderType == 'intercity_parcel') {
        try {
          final intercityRequest = await supabase
              .from('intercity_requests')
              .select('rider_travel_plans!intercity_requests_route_id_fkey(vehicle_type)')
              .eq('parcel_id', orderId)
              .eq('traveller_id', riderId)
              .not('route_id', 'is', null)
              .order('updated_at', ascending: false)
              .limit(1)
              .maybeSingle();
          final planVehicleType =
              (intercityRequest?['rider_travel_plans'] as Map?)?['vehicle_type'];
          if (planVehicleType != null) {
            flat['vehicle_type'] = planVehicleType;
          }
        } catch (e) {
          debugPrint('Error fetching intercity plan vehicle_type in controller: $e');
        }
      }

      if (_isDisposed) return;

      final user = flat['users!riders_user_id_fkey'] ?? flat['users'];
      if (user is Map) {
        flat['phone'] = user['phone'];
        flat['name']  = kycName ?? user['full_name'] ?? '';
      } else {
        flat['name']  = kycName ?? '';
      }
      flat.remove('users!riders_user_id_fkey');
      flat.remove('users');

      flat['id'] = riderId;
      if (_isDisposed) return;
      // Database profile is the absolute source of truth. Always set it.
      riderNotifier.value = flat;
      _updateRiderLocation(flat);
    } catch (e) {
      if (!_isDisposed) {
        debugPrint('REALTIME RIDER FETCH ERROR => $e');
      }
    }
  }

  /// Resolves lat/lng map updates from raw rider update payload
  void _updateRiderLocation(Map<String, dynamic> riderData) {
    if (_isDisposed) return;
    final lat = double.tryParse(riderData['current_lat']?.toString() ?? '');
    final lng = double.tryParse(riderData['current_lng']?.toString() ?? '');
    final heading = double.tryParse(riderData['current_heading']?.toString() ?? '') ?? 0.0;
    if (lat != null && lng != null) {
      riderLocationNotifier.value = {
        'lat': lat,
        'lng': lng,
        'heading': heading,
      };
    }
  }

  /// Registers order database listeners
  void _subscribeOrder() {
    _orderSubId = RealtimeManager.instance.subscribe(
      channelName: 'realtime-order-$orderId',
      table: 'orders',
      owner: 'RealtimeOrderController',
      event: PostgresChangeEvent.update,
      filterColumn: 'id',
      filterValue: orderId,
      callback: (payload) async {
        if (_isDisposed) return;
        _lastRealtimeDeliveryAt = DateTime.now();
        debugPrint(
          '[TRACE_CANCEL] RealtimeOrderController._subscribeOrder postgres_changes fired '
          'order=$orderId newStatus=${payload.newRecord['order_status']} '
          'epoch=${DateTime.now().millisecondsSinceEpoch}',
        );
        // P2 fix: payload.newRecord IS the fresh order row -- apply it directly instead of
        // re-fetching the identical data via fetchOrder(). This happens synchronously (no network
        // wait), so order-status changes are reflected immediately regardless of the coalescing
        // below. Only fetchLiveOrderState() (rider/ETA/signed-URL enrichment) still needs a network
        // round trip here.
        _applyOrderData(payload.newRecord);
        await _refreshOrderAndLiveState(includeOrderFetch: false);
      },
    );
  }

  /// Registers rider database listeners
  void _subscribeRider(String riderId) {
    if (_isDisposed) return;
    if (_currentRiderId == riderId && _riderSubId != null) return;
    if (_riderSubId != null) {
      RealtimeManager.instance.unsubscribe('realtime-rider-$_currentRiderId', _riderSubId!);
      _riderSubId = null;
    }

    // RESET PREVIOUS RIDER STATE ONLY IF DIFFERENT AND NOT PRE-FETCHED
    if (_currentRiderId != riderId) {
      _currentRiderId = riderId;
      if (riderNotifier.value?['id'] != riderId) {
        riderNotifier.value = null;
        riderLocationNotifier.value = null;
      }
    }

    _riderSubId = RealtimeManager.instance.subscribe(
      channelName: 'realtime-rider-$riderId',
      table: 'riders',
      owner: 'RealtimeOrderController',
      event: PostgresChangeEvent.update,
      filterColumn: 'id',
      filterValue: riderId,
      callback: (payload) async {
        if (_isDisposed) return;
        _lastRealtimeDeliveryAt = DateTime.now();
        debugPrint('REALTIME RIDER LOCATION UPDATE RECEIVED');
        final newRecord = payload.newRecord;
        final lat = double.tryParse(newRecord['current_lat']?.toString() ?? '');
        final lng = double.tryParse(newRecord['current_lng']?.toString() ?? '');
        final heading = double.tryParse(newRecord['current_heading']?.toString() ?? '') ?? 0.0;
        if (lat != null && lng != null && !_isDisposed) {
          riderLocationNotifier.value = {'lat': lat, 'lng': lng, 'heading': heading};
        }

        if (riderNotifier.value != null && !_isDisposed) {
          final oldVal = riderNotifier.value!;
          final ratingChanged = newRecord['rating']?.toString() != oldVal['rating']?.toString();
          final kycChanged = newRecord['rider_kyc_id']?.toString() != oldVal['rider_kyc_id']?.toString();
          if (ratingChanged || kycChanged) {
            await _fetchRider(riderId);
          }
        }
      },
    );
  }

  /// Clean teardown of Supabase streams to avoid leaks
  void dispose() {
    _isDisposed = true;
    _pollingTimer?.cancel();
    if (_orderSubId != null) {
      RealtimeManager.instance.unsubscribe('realtime-order-$orderId', _orderSubId!);
      _orderSubId = null;
    }
    if (_riderSubId != null && _currentRiderId != null) {
      RealtimeManager.instance.unsubscribe('realtime-rider-$_currentRiderId', _riderSubId!);
      _riderSubId = null;
    }
    orderNotifier.dispose();
    riderLocationNotifier.dispose();
    riderNotifier.dispose();
    liveStateNotifier.dispose();
    userNameNotifier.dispose();
  }
}

