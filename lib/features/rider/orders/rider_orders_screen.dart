import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:waydrop/core/services/network/poll_backoff.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/database/dispatch_config_cache.dart';
import 'package:waydrop/core/services/location/location_cache_service.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:waydrop/features/rider/orders/screens/rider_active_order_screen.dart';
import 'package:waydrop/core/services/session/active_order_screen_state.dart';
import 'package:waydrop/shared/widgets/skeleton_loader.dart';
import 'package:waydrop/main.dart';
import 'package:geolocator/geolocator.dart';
import 'package:waydrop/core/providers/initial_data_provider.dart';
import 'package:waydrop/shared/widgets/app_snackbar.dart';
import 'package:waydrop/shared/helpers/insets.dart';

class RiderOrdersScreen extends StatefulWidget {
  final String? riderId;
  final String? vehicleType;
  // [PERF] whether this tab is the currently visible/selected tab inside
  // RiderMainNavigationScreen's IndexedStack. Defaults to true so any call site that doesn't pass
  // it keeps running exactly as before. Mirrors RiderHomeTab.isActive: only ever pauses the 10s
  // startLocationTimer() fallback poll below -- realtime subscriptions (incoming-order
  // sound/badge, rider status, active-order detection), the 1s local expiry timer (writes
  // rider_assignments.assignment_status = 'expired'), and the 30s active-order poll (triggers
  // rider_self_rematch() on busy->free) are all untouched by this flag and keep running while
  // this screen is off-screen.
  final bool isActive;

  const RiderOrdersScreen({
    super.key,
    this.riderId,
    this.vehicleType,
    this.isActive = true,
  });

  @override
  State<RiderOrdersScreen> createState() => RiderOrdersScreenState();
}

class RiderOrdersScreenState extends State<RiderOrdersScreen> with SingleTickerProviderStateMixin {
  final supabase = Supabase.instance.client;
  late TabController tabController;

  String? riderId;
  String? vehicleType;

  // R1 FIX #4: distinguishes a true cold-start mount (initialRiderDataProvider's snapshot is
  // guaranteed fresh -- fetched by AppStartScreen moments earlier in the same navigation
  // transition) from a mid-session recreation (returnToLocalRideHome()'s pushAndRemoveUntil
  // rebuilds RiderMainNavigationScreen and, with it, a brand-new RiderOrdersScreenState -- the
  // same never-refreshed snapshot would otherwise be stale there). `static` survives individual
  // State disposal but not a process restart, so this is false exactly once per app launch and
  // true for every subsequent RiderOrdersScreenState construction within that same process.
  // Scoped to this class only -- intentionally independent of RiderMainNavigationScreen's and
  // RiderHomeTab's own identically-shaped flags, so none of the three can cause another to skip
  // its own check.
  static bool _hasConsumedColdStartSeed = false;

  List<Map<String, dynamic>> rideOrders = [];
  List<Map<String, dynamic>> parcelOrders = [];
  final Map<String, DateTime> rejectedOrderIds = {};
  bool loading = true;
  bool isRiderOnline = false;
  bool processing = false;
  double codPendingAmount = 0.0;
  double codLimit = 500.0;

  String? _ordersSubId;
  String? _ordersSubChannel;
  String? _ordersUpdateSubId;
  String? _ordersUpdateSubChannel;
  // P1 fix (RiderOrdersScreen realtime duplication): these two now go through RealtimeManager
  // (the app's single multiplexed realtime channel system) instead of each opening its own raw
  // supabase.stream() connection. _activeOrderPollTimer/_pollActiveOrderFallback below are
  // UNCHANGED and still the safety net for the proven Postgres Changes gap where an UPDATE that
  // makes a row stop matching its own filter (rider_id set to null) never delivers an event to
  // either mechanism -- switching transport here does not affect that gap either way.
  String? _activeOrderSubId;
  String? _activeOrderSubChannel;
  String? _riderStatusSubId;
  String? _riderStatusSubChannel;
  Timer? _locationTimer;
  Timer? _expiryTimer;
  Timer? _activeOrderPollTimer;
  // Phase 5 F8: one PollBackoff instance per independent poll loop -- tracks consecutive
  // failures for that loop only and skips ticks under sustained failure (e.g. a Supabase
  // throttle) instead of hammering the same endpoint on the fixed interval. Does not change
  // normal-path cadence at all: shouldAttempt() only ever returns false after recordFailure()
  // has actually been called, so a healthy poll fires exactly as before.
  final PollBackoff _searchingOrdersPollBackoff = PollBackoff();
  final PollBackoff _activeOrderPollBackoff = PollBackoff();
  final ValueNotifier<int> _expiryNotifier = ValueNotifier<int>(0);

  // [PERF] Phase 8A: realtime-health gate + re-entrancy guard for the 10 s
  // fallback timer. Mirrors the proven pattern in home_tab.dart and
  // RealtimeOrderController (15 s health threshold).
  static const Duration _realtimeHealthThreshold = Duration(seconds: 15);
  DateTime? _lastRealtimeEventAt;
  bool _fetchInFlight = false;
  bool _refetchQueued = false;

  // P8 FIX #6.4-B: separate re-entrancy guard for _pollActiveOrderFallback() -- mirrors
  // _fetchInFlight/_refetchQueued's pattern in shape only. Kept as distinct flags because this
  // guards a different query/function; sharing flags with fetchSearchingOrders() would incorrectly
  // let a poll block a searching-orders fetch or vice versa.
  bool _pollInFlight = false;
  bool _pollQueued = false;

  // ROOT CAUSE FIX (Ride B never appearing after a rider completes Ride A via "Back to Home"):
  // wasBusy (below, in _pollActiveOrderFallback) is in-memory State on THIS widget instance --
  // but returnToLocalRideHome() (local_ride_home_navigator.dart) rebuilds RiderMainNavigationScreen
  // via pushAndRemoveUntil on every local-ride completion exit, the single most common way a rider
  // actually finishes a ride, destroying this screen's State and creating a brand new one. A fresh
  // instance's wasBusy starts false and has never observed "busy=true", so the busy->free
  // transition rider_self_rematch() exists specifically to catch (Issue 1 follow-up,
  // 20260826000000) is invisible to it -- it silently never fires, leaving the rider dependent
  // entirely on the async trigger (proven, via the 20260824000000 forensic investigation, to have
  // a real silent-failure mode with no retry) and the 20s cron backstop. Tracks whether THIS
  // instance has completed its first _pollActiveOrderFallback() call yet, so that first poll can
  // also self-heal when the rider is found free, not only on an in-memory-observed transition.
  bool _hasPolledActiveOrderOnce = false;

  final AudioPlayer _audioPlayer = AudioPlayer();
  final Set<String> _announcedOrders = {};
  DateTime? _lastSoundPlayed;

  bool hasActiveOrder = false;
  Map<String, dynamic>? activeOrder;

  static const Color primaryLime = Color(0xFFC5FF30);
  static const Color darkBg = Color(0xFF0B0F19);
  static const Color darkCard = Color(0xFF131926);
  static const Color textGray = Color(0xFF94A3B8);

  @override
  void initState() {
    super.initState();
    tabController = TabController(length: 2, vsync: this);
    _audioPlayer.setAudioContext(AudioContext(
      android: const AudioContextAndroid(
        isSpeakerphoneOn: true,
        stayAwake: true,
        contentType: AndroidContentType.music,
        usageType: AndroidUsageType.notificationEvent,
        audioFocus: AndroidAudioFocus.gainTransientMayDuck,
      ),
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.playback,
        options: {
          AVAudioSessionOptions.mixWithOthers,
        },
      ),
    ));
    // Perf fix (WayDrop Phase J): see _onActiveOrderScreenVisibilityChanged() below.
    ActiveOrderScreenState.isOpen.addListener(_onActiveOrderScreenVisibilityChanged);
    resolveRiderAndLoad();
  }

  @override
  void didUpdateWidget(covariant RiderOrdersScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive != oldWidget.isActive) {
      if (widget.isActive) {
        // Tab became visible again -- refresh immediately (the fallback poll was paused, so the
        // list may be stale) and resume the timer, mirroring RiderHomeTab's same transition.
        fetchSearchingOrders();
        startLocationTimer();
      } else {
        _locationTimer?.cancel();
      }
    }
  }

  @override
  void dispose() {
    ActiveOrderScreenState.isOpen.removeListener(_onActiveOrderScreenVisibilityChanged);
    if (_ordersSubId != null && _ordersSubChannel != null) {
      RealtimeManager.instance.unsubscribe(_ordersSubChannel!, _ordersSubId!);
    }
    if (_ordersUpdateSubId != null && _ordersUpdateSubChannel != null) {
      RealtimeManager.instance.unsubscribe(_ordersUpdateSubChannel!, _ordersUpdateSubId!);
    }
    if (_activeOrderSubId != null && _activeOrderSubChannel != null) {
      RealtimeManager.instance.unsubscribe(_activeOrderSubChannel!, _activeOrderSubId!);
    }
    if (_riderStatusSubId != null && _riderStatusSubChannel != null) {
      RealtimeManager.instance.unsubscribe(_riderStatusSubChannel!, _riderStatusSubId!);
    }
    _locationTimer?.cancel();
    _expiryTimer?.cancel();
    _activeOrderPollTimer?.cancel();
    _expiryNotifier.dispose();
    tabController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> resolveRiderAndLoad() async {
    debugPrint('[INSTR] ${DateTime.now().toIso8601String()} resolveRiderAndLoad() ENTERED');
    // Ensure location is initialized in the background to avoid blocking the initial orders fetch
    // R8 perf fix: main.dart already fires initializeLocation() unconditionally at process start
    // -- if that call already produced a fresh cache by the time this screen mounts, firing this
    // one too just re-runs a full GPS + OLA reverse-geocode + zone-load pass for no reason (the
    // existing isFetching guard only coalesces a call that's still IN FLIGHT, not one that already
    // finished). hasValidCache uses the same 5-minute policy the dispatch-poll guard below (line
    // ~415-ish, `if (currentLat == null)`) already relies on.
    if (!LocationCacheService.hasValidCache) {
      unawaited(LocationCacheService.initializeLocation()
          .timeout(const Duration(seconds: 2))
          .catchError((_) => null));
    }

    if (widget.riderId != null && widget.vehicleType != null) {
      riderId = widget.riderId;
      vehicleType = widget.vehicleType;
      debugPrint('[INSTR] ${DateTime.now().toIso8601String()} riderId resolved (from widget param) = $riderId');
      try {
        final user = supabase.auth.currentUser;
        if (user != null) {
          final data = await supabase
              .from('riders')
              .select('account_status, cod_pending_amount, cod_limit')
              .eq('user_id', user.id)
              .maybeSingle();
          if (data != null) {
            isRiderOnline = data['account_status'] == 'online';
            codPendingAmount = double.tryParse(data['cod_pending_amount']?.toString() ?? '0') ?? 0.0;
            codLimit = double.tryParse(data['cod_limit']?.toString() ?? '500') ?? 500.0;
          }
        }
      } catch (_) {}
    } else {
      try {
        final user = supabase.auth.currentUser;
        if (user != null) {
          // R1 FIX #4: a true cold start reuses AppStartScreen's already-fetched riders row
          // instead of re-querying an identical row a moment later -- safe because nothing can
          // have changed server-side between that fetch and this mount. Only vehicleType is
          // absent from the seed (its rider_kyc embed doesn't request vehicle_type), which is
          // harmless: vehicleType is never read anywhere in this screen (grepped exhaustively).
          final seedRider = providerContainer.read(initialRiderDataProvider)?.rider;
          if (seedRider != null && seedRider['id'] != null && !_hasConsumedColdStartSeed) {
            _hasConsumedColdStartSeed = true;
            riderId = seedRider['id']?.toString();
            isRiderOnline = seedRider['account_status'] == 'online';
            codPendingAmount = double.tryParse(seedRider['cod_pending_amount']?.toString() ?? '0') ?? 0.0;
            codLimit = double.tryParse(seedRider['cod_limit']?.toString() ?? '500') ?? 500.0;
            debugPrint('[INSTR] ${DateTime.now().toIso8601String()} riderId resolved (from cold-start seed) = $riderId, isRiderOnline=$isRiderOnline');
          } else {
            final data = await supabase
                .from('riders')
                .select('''
                  id,
                  account_status,
                  cod_pending_amount,
                  cod_limit,
                  rider_kyc!riders_kyc_id_fkey(
                    vehicle_type
                  )
                ''')
                .eq('user_id', user.id)
                .single();
            riderId = data['id']?.toString();
            isRiderOnline = data['account_status'] == 'online';
            codPendingAmount = double.tryParse(data['cod_pending_amount']?.toString() ?? '0') ?? 0.0;
            codLimit = double.tryParse(data['cod_limit']?.toString() ?? '500') ?? 500.0;
            final kyc = data['rider_kyc!riders_kyc_id_fkey'] ?? data['rider_kyc'];
            if (kyc is Map) {
              vehicleType = kyc['vehicle_type']?.toString();
            }
            debugPrint('[INSTR] ${DateTime.now().toIso8601String()} riderId resolved (from DB fetch) = $riderId, isRiderOnline=$isRiderOnline');
          }
        }
      } catch (e) {
        debugPrint('FETCH RIDER PROFILE IN ORDERS ERROR => $e');
        debugPrint('[INSTR] ${DateTime.now().toIso8601String()} riderId resolution FAILED with exception: $e');
      }
    }

    if (riderId != null) {
      await fetchSearchingOrders();
      if (!mounted) return;
      if (!Platform.environment.containsKey('FLUTTER_TEST')) {
        debugPrint('[INSTR] ${DateTime.now().toIso8601String()} starting listeners: listenSearchingOrders, listenActiveOrder, listenRiderStatus, startLocationTimer, startExpiryTimer');
        listenSearchingOrders();
        listenActiveOrder();
        startActiveOrderPollTimer();
        listenRiderStatus();
        startLocationTimer();
        startExpiryTimer();
        // P8 FIX #6.5: only re-run fetchSearchingOrders() once location resolves if it genuinely
        // wasn't ready for the call above -- _processAndFilterAssignments()'s GPS-fallback distance
        // calc (used only when the DB-provided distance is null) would already have run identically
        // during that first fetch if location was already available, making a second full fetch a
        // no-op repeat. Captured here, immediately after Call #1 and before scheduling the
        // microtask, so it reflects location's actual availability at the moment Call #1's
        // processing ran (nothing between that call and here awaits or changes location state).
        final locationReadyForCall1 =
            LocationCacheService.currentLat != null &&
            LocationCacheService.currentLng != null;
        if (!locationReadyForCall1) {
          // Asynchronously wait for location initialization, then refresh orders immediately
          Future.microtask(() async {
            await LocationCacheService.initializeLocation().catchError((_) => null);
            if (mounted) {
              await fetchSearchingOrders();
            }
          });
        }
      } else {
        debugPrint('[INSTR] ${DateTime.now().toIso8601String()} FLUTTER_TEST env detected -- listeners NOT started');
      }
    } else {
      debugPrint('[INSTR] ${DateTime.now().toIso8601String()} riderId is NULL -- resolveRiderAndLoad() aborting, no listeners will ever start for this widget instance');
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  // P8 FIX #6.1 (RiderOrdersScreen location-only rebuild gate): the exact `riders` columns
  // LocationCacheService's GPS heartbeat/movement update writes on every ping while online --
  // same allowlist as RiderHomeTab._locationHeartbeatFields, which this mirrors verbatim. This
  // screen only ever reads account_status/cod_pending_amount/cod_limit off a `riders` UPDATE
  // (see listenRiderStatus() below), so a change confined to these columns can never affect
  // anything rendered here.
  static const Set<String> _locationHeartbeatFields = {
    'current_lat',
    'current_lng',
    'current_heading',
    'last_location_updated_at',
    'last_active_at',
    'updated_at',
  };

  // P1 fix (RiderOrdersScreen realtime duplication): now goes through RealtimeManager instead of
  // its own raw supabase.stream() connection. Behaviorally equivalent: the account_status/
  // cod_pending_amount/cod_limit fields this reacts to only ever change via an UPDATE on this
  // rider's own row (never an INSERT/DELETE), and the *current* value at subscribe time is
  // already set synchronously by resolveRiderAndLoad()'s own initial rider fetch just before this
  // runs -- so, unlike .stream(), not receiving an immediate initial emission here changes
  // nothing observable.
  void listenRiderStatus() {
    debugPrint('[INSTR] ${DateTime.now().toIso8601String()} listenRiderStatus() STARTED (RealtimeManager)');
    final user = supabase.auth.currentUser;
    if (user == null) return;
    if (_riderStatusSubId != null && _riderStatusSubChannel != null) {
      RealtimeManager.instance.unsubscribe(_riderStatusSubChannel!, _riderStatusSubId!);
      _riderStatusSubId = null;
      _riderStatusSubChannel = null;
    }
    // Channel-pooling fix (P0, WayDrop duplicate-realtime audit): unified with RiderHomeTab's
    // identical riders-row subscription. Both screens watch the exact same row for the exact same
    // rider -- previously under different channel names AND different filter columns
    // ('rider-orders-riderstatus-${user.id}' filtered on user_id vs RiderHomeTab's
    // 'rider-home-$riderId' filtered on id), so RealtimeManager (which only pools on an exact
    // channelName match) opened two separate realtime deliveries for one underlying UPDATE.
    // riders.id (this rider's own PK, already resolved into `riderId` by resolveRiderAndLoad()
    // before this runs -- same precondition this screen's own 'rider-assignments-$riderId' channel
    // already relies on) and riders.user_id are a fixed 1:1 pair for one rider, so filtering on
    // `id`/riderId instead of `user_id`/user.id watches the identical row -- only the channel
    // name and filter column/value changed here, the callback below is untouched.
    _riderStatusSubChannel = 'rider-home-$riderId';
    _riderStatusSubId = RealtimeManager.instance.subscribe(
      channelName: _riderStatusSubChannel!,
      table: 'riders',
      owner: 'RiderOrdersScreen_RiderStatus',
      event: PostgresChangeEvent.update,
      schema: 'public',
      filterColumn: 'id',
      filterValue: riderId!,
      callback: (payload) {
        final first = payload.newRecord;
        debugPrint('[INSTR] ${DateTime.now().toIso8601String()} listenRiderStatus() event received via RealtimeManager');

        // P8 FIX #6.1: skip setState()/fetchSearchingOrders() entirely for a `riders` UPDATE
        // confined to GPS heartbeat columns -- mirrors RiderHomeTab.subscribeRider()'s
        // isLocationOnlyUpdate gate exactly, including its conservative fallback: if oldRecord is
        // empty (no diff available), every key in `first` counts as "changed", so this still
        // falls through to the existing unconditional behavior below instead of silently skipping.
        final oldRecord = payload.oldRecord;
        final isLocationOnlyUpdate = oldRecord.isNotEmpty &&
            first.keys.every((key) =>
                !oldRecord.containsKey(key) ||
                oldRecord[key] == first[key] ||
                _locationHeartbeatFields.contains(key));
        if (isLocationOnlyUpdate) {
          debugPrint('[INSTR] ${DateTime.now().toIso8601String()} listenRiderStatus() SKIPPED setState -- location-only update');
          return;
        }

        final online = first['account_status'] == 'online';
        final pending = double.tryParse(first['cod_pending_amount']?.toString() ?? '0') ?? 0.0;
        final limit = double.tryParse(first['cod_limit']?.toString() ?? '500') ?? 500.0;
        if (mounted) {
          final wasOffline = !isRiderOnline;
          debugPrint('[INSTR] ${DateTime.now().toIso8601String()} listenRiderStatus() wasOffline=$wasOffline, online=$online');
          setState(() {
            isRiderOnline = online;
            codPendingAmount = pending;
            codLimit = limit;
          });
          if (wasOffline && online) {
            debugPrint('[INSTR] ${DateTime.now().toIso8601String()} listenRiderStatus() OFFLINE->ONLINE transition detected -- calling fetchSearchingOrders()');
            fetchSearchingOrders();
          }
        }
      },
    );
  }

  // =========================================================
  // LOCATION TRACKING TIMER (Updates Distances periodically)
  // =========================================================
  void startLocationTimer() {
    _locationTimer?.cancel();
    // [PERF] don't run this fallback poll while this tab isn't the visible one -- it's a
    // duplicate-detection safety net for stale/dropped realtime, already gated by the
    // realtime-health check below; the realtime subscription itself (the primary path for
    // incoming-order sound/badge delivery) is untouched and keeps running regardless of visibility.
    if (!widget.isActive) return;
    debugPrint('[INSTR] ${DateTime.now().toIso8601String()} startLocationTimer() STARTED');
    _locationTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      debugPrint('[INSTR] ${DateTime.now().toIso8601String()} startLocationTimer TICK #${timer.tick}');
      // P0 PERFORMANCE FIX: a rider with a genuinely active order can never be assigned a new
      // dispatch order (dispatch already excludes busy riders), so refreshing the searching-orders
      // list is pure wasted work while one is active -- this screen stays mounted the whole time
      // via IndexedStack even with RiderActiveOrderScreen pushed on top. Reuses `hasActiveOrder`,
      // the same field _pollActiveOrderFallback()/listenActiveOrder() already maintain as the
      // single source of truth elsewhere in this screen (lines 771/996) -- no second state system,
      // no change to the timer's own start/cancel lifecycle, so it resumes on the very next tick
      // once hasActiveOrder goes back to false (ride completed/cancelled), with no risk of a
      // leaked or duplicate Timer.
      if (hasActiveOrder) {
        debugPrint('[INSTR] ${DateTime.now().toIso8601String()} startLocationTimer TICK #${timer.tick} SKIPPED fetchSearchingOrders() -- rider has an active order');
        return;
      }
      if (LocationCacheService.currentLat == null) {
        LocationCacheService.initializeLocation().catchError((_) => null);
      }
      // [PERF] Phase 8A: realtime-health gate -- while realtime has delivered an
      // assignment/order update recently, this tick is a pure duplicate, so skip
      // it. The timer stays as the fallback when realtime is quiet or stale.
      final lastEvent = _lastRealtimeEventAt;
      if (lastEvent != null &&
          DateTime.now().difference(lastEvent) < _realtimeHealthThreshold) {
        debugPrint('[INSTR] ${DateTime.now().toIso8601String()} startLocationTimer TICK #${timer.tick} SKIPPED fetchSearchingOrders() -- realtime healthy, lastEvent=${lastEvent.toIso8601String()}, gap=${DateTime.now().difference(lastEvent).inMilliseconds}ms');
        return;
      }
      // Phase 5 F8: skip this tick if the poll has been failing recently -- only ever engages
      // after real failures (recordFailure() inside fetchSearchingOrders()'s own catch block);
      // a healthy poll always returns true here and this line changes nothing for it.
      if (!_searchingOrdersPollBackoff.shouldAttempt()) {
        debugPrint('[INSTR] ${DateTime.now().toIso8601String()} startLocationTimer TICK #${timer.tick} SKIPPED fetchSearchingOrders() -- backed off after recent failures');
        return;
      }
      debugPrint('[INSTR] ${DateTime.now().toIso8601String()} startLocationTimer TICK #${timer.tick} -> calling fetchSearchingOrders() (lastEvent=$lastEvent)');
      await fetchSearchingOrders();
    });
  }

  // =========================================================
  // REAL-TIME LOCAL EXPIRY TIMER (Immediate card dismissal)
  // =========================================================
  void startExpiryTimer() {
    _expiryTimer?.cancel();
    _expiryTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        _filterExpiredAssignmentsFromState();
        _expiryNotifier.value++; // Rebuild only the countdown chips, not the whole screen
      }
    });
  }

  void _filterExpiredAssignmentsFromState() {
    bool changed = false;
    final now = DateTime.now();

    final List<Map<String, dynamic>> updatedRides = [];
    for (final order in rideOrders) {
      final expiresAtStr = order['expires_at'];
      if (expiresAtStr != null) {
        final expiresAt = DateTime.tryParse(expiresAtStr.toString());
        if (expiresAt != null && now.isAfter(expiresAt)) {
          changed = true;
          final assignmentId = order['assignment_id'];
          if (assignmentId != null) {
            _markAssignmentAsExpired(assignmentId, order['id']);
          }
          continue;
        }
      }
      updatedRides.add(order);
    }

    final List<Map<String, dynamic>> updatedParcels = [];
    for (final order in parcelOrders) {
      final expiresAtStr = order['expires_at'];
      if (expiresAtStr != null) {
        final expiresAt = DateTime.tryParse(expiresAtStr.toString());
        if (expiresAt != null && now.isAfter(expiresAt)) {
          changed = true;
          final assignmentId = order['assignment_id'];
          if (assignmentId != null) {
            _markAssignmentAsExpired(assignmentId, order['id']);
          }
          continue;
        }
      }
      updatedParcels.add(order);
    }

    if (changed) {
      setState(() {
        rideOrders = updatedRides;
        parcelOrders = updatedParcels;
      });
      try {
        providerContainer.read(activeAssignmentsCountProvider.notifier).state = updatedRides.length + updatedParcels.length;
      } catch (e) {
        debugPrint('Error updating active assignments badge count: $e');
      }
    }
  }

  Future<void> _markAssignmentAsExpired(dynamic assignmentId, dynamic orderId) async {
    try {
      final nowStr = DateTime.now().toUtc().toIso8601String();
      await supabase
          .from('rider_assignments')
          .update({
            'assignment_status': 'expired',
            'responded_at': nowStr,
            'updated_at': nowStr,
            'response_type': 'ignored',
            'last_response_at': nowStr,
          })
          .eq('id', assignmentId);

      if (riderId != null) {
        await supabase
            .from('order_assignment_logs')
            .update({
              'assignment_status': 'expired',
              'responded_at': nowStr,
            })
            .eq('order_id', orderId)
            .eq('rider_id', riderId!);
      }
    } catch (e) {
      debugPrint('Error marking assignment as expired in DB: $e');
    }
  }

  // =========================================================
  // ACTIVE ORDER
  // =========================================================
  // Proven via [TRACE_ACTIVEORDER] instrumentation: when a rider cancels an accepted order,
  // update-order-status nulls orders.rider_id (see that function's "searching" branch) to detach
  // the rider and free the order for re-dispatch. That row then no longer matches this stream's
  // `eq('rider_id', riderId)` filter, and Postgres Changes never delivers an event for an update
  // that makes a row stop matching its own filter -- so this stream's local cache is left showing
  // the order as still "accepted" indefinitely, which is what pinned "Active Ride in Progress" on
  // permanently after a rider-side cancel. RiderHomeTab has an equivalent stream (subscribeActiveOrder)
  // with the exact same gap, but survives it by accident via its unrelated 30s loadRider() timer
  // also re-running loadActiveOrder() as a plain one-shot fetch. Mirrors that same fallback here.
  //
  // BUG FIX (rider sound-fires-but-card-missing): mirrors RiderHomeTab._isOrderActivelyBusy()
  // exactly. Without this, an accepted intercity/long-distance job still "Waiting for Travel Day"
  // (trip_started_at still null) was counted as busy here -- permanently pinning hasActiveOrder
  // true and blocking fetchSearchingOrders()/buildOrdersList() -- while RiderHomeTab correctly
  // treated the same rider as free and kept announcing (sound/haptic) new incoming assignments
  // that could then never appear on this screen. Not extracted into a shared helper (intentional,
  // narrow fix scope) -- keep in sync with RiderHomeTab's copy if that logic ever changes.
  bool _isOrderActivelyBusy(Map<String, dynamic> order) {
    final status = order['order_status']?.toString();
    if (status != 'accepted') return true;
    final type = order['order_type']?.toString() ?? '';
    final distanceMeters = double.tryParse(order['distance_meters']?.toString() ?? '0') ?? 0.0;
    final isIntercity = type.startsWith('intercity') || (type == 'ride' && distanceMeters > 20000);
    if (!isIntercity) return true;
    return order['trip_started_at'] != null;
  }

  Future<void> _pollActiveOrderFallback() async {
    if (riderId == null || !mounted) return;
    // P8 FIX #6.4-B: a trigger arriving while a poll is already in flight is coalesced into a
    // single guaranteed follow-up instead of starting a second concurrent query -- the follow-up
    // (below, in `finally`) always runs AFTER the in-flight poll completes, so it observes fresh
    // DB state rather than a stale/replayed result. This eliminates both the wasted duplicate
    // query and the narrow stale-overwrite window proven possible when the 30s timer and a
    // realtime `orders` UPDATE (pooled since #6.2) land close together.
    if (_pollInFlight) {
      _pollQueued = true;
      return;
    }
    _pollInFlight = true;
    try {
      // P8 FIX #6.4-A: narrowed from a bare, unprojected select() -- `activeOrder` (the Map this
      // populates below) is never read anywhere in this file (grepped exhaustively: declaration +
      // these two writes only). order_status/trip_started_at/order_type/distance_meters are read
      // only by _isOrderActivelyBusy() below (BUG FIX, see its doc comment) to decide row
      // eligibility -- still far short of the full unread row.
      final rows = await supabase
          .from('orders')
          .select('id, order_status, trip_started_at, order_type, distance_meters')
          .eq('rider_id', riderId!)
          .inFilter('order_status', ['accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing', 'payment_pending']);
      // Phase 5 F8: only resets the 30s timer's own backoff state -- does not affect this
      // function's return value/control flow for any other caller (e.g. visibility change).
      _activeOrderPollBackoff.recordSuccess();
      if (!mounted) return;
      final active = (rows as List).cast<Map<String, dynamic>>().where(_isOrderActivelyBusy).toList();
      final wasBusy = hasActiveOrder;
      // See _hasPolledActiveOrderOnce's own doc comment (field declaration, above): a freshly
      // (re)created instance -- e.g. right after returnToLocalRideHome()'s pushAndRemoveUntil on
      // ride completion -- has an in-memory wasBusy of false that never actually observed "busy",
      // so the check below must also self-heal on this instance's first-ever poll, not only on an
      // in-memory-detected transition.
      final isFirstPollForThisInstance = !_hasPolledActiveOrderOnce;
      _hasPolledActiveOrderOnce = true;
      setState(() {
        if (active.isNotEmpty) {
          hasActiveOrder = true;
          activeOrder = active.first;
        } else {
          hasActiveOrder = false;
          activeOrder = null;
        }
      });
      // Mirrors listenRiderStatus()'s wasOffline->online forced refetch: the moment this rider is
      // confirmed to have left the busy state, proactively re-check for a newly-eligible pending
      // order instead of only waiting on the next realtime assignment INSERT / 10s poll tick.
      //
      // Issue 1 follow-up: the backend rematch (async trigger + redispatch_freed_riders cron) can
      // still take up to ~20-40s to actually create the rider_assignments row this fetch depends
      // on, so a bare fetchSearchingOrders() right at the busy->free instant can find nothing yet
      // even when a genuinely eligible order is already searching. rider_self_rematch() runs the
      // exact same, unmodified matching function synchronously for this rider only (auth.uid()
      // scoped -- it can never touch another rider), giving a same-request guarantee instead of
      // waiting on the async/cron paths, which remain as the fallback if this call itself fails.
      //
      // ROOT CAUSE FIX (see _hasPolledActiveOrderOnce's doc comment): also self-heal on this
      // instance's first-ever poll whenever the rider is found free, not only on an in-memory-
      // observed wasBusy->free transition -- returnToLocalRideHome()'s pushAndRemoveUntil recreates
      // this screen's State on every local-ride completion exit, so wasBusy alone can never detect
      // the transition on the resulting fresh instance. rider_self_rematch() is a cheap,
      // idempotent, auth.uid()-scoped no-op when the rider genuinely has nothing new to match (e.g.
      // a first-ever app launch with no prior ride), so this costs nothing extra in that case and
      // closes the gap in the completion case.
      if ((wasBusy || isFirstPollForThisInstance) && !hasActiveOrder) {
        debugPrint('[INSTR] ${DateTime.now().toIso8601String()} _pollActiveOrderFallback() BUSY->FREE transition detected (wasBusy=$wasBusy, isFirstPoll=$isFirstPollForThisInstance) -- calling rider_self_rematch() then fetchSearchingOrders()');
        try {
          await supabase.rpc('rider_self_rematch');
        } catch (e, stackTrace) {
          debugPrint('[INSTR] ${DateTime.now().toIso8601String()} rider_self_rematch() failed (non-fatal, async trigger/cron backstop remain): $e');
          // Phase 5 F2: non-fatal Crashlytics report so a real production failure rate of this
          // dispatch-trigger call is visible (debugPrint alone is silenced in release builds) --
          // purely additive, does not rethrow or change the existing non-fatal fallback behavior;
          // fetchSearchingOrders() below still always runs regardless.
          FirebaseCrashlytics.instance.recordError(
            e,
            stackTrace,
            reason: 'rider_self_rematch (dispatch trigger) failed',
            information: ['riderId: $riderId'],
            fatal: false,
          );
        }
        fetchSearchingOrders();
      }
    } catch (_) {
      _activeOrderPollBackoff.recordFailure();
    } finally {
      // P8 FIX #6.4-B: reset before the recursive call below, mirroring fetchSearchingOrders()'s
      // own _fetchInFlight/_refetchQueued finally block -- this reset-then-recurse sequence is
      // fully synchronous (no `await` in between), so no third trigger can interleave and
      // observe a stale "not in flight" state before the follow-up poll claims the flag again.
      _pollInFlight = false;
      if (_pollQueued) {
        _pollQueued = false;
        _pollActiveOrderFallback();
      }
    }
  }

  // Perf fix (WayDrop Phase J): RiderActiveOrderScreen is only ever pushed for an order whose
  // status is already in _pollActiveOrderFallback()'s own busy-status list above -- so while it's
  // open, this screen already knows hasActiveOrder must be true without spending a DB round trip
  // to re-confirm it every 30s / on every order realtime event, exactly the class of duplicate
  // work already fixed for RiderHomeTab (see active_order_screen_state.dart). The moment the
  // covering screen closes, poll once immediately -- this is what actually detects the busy->free
  // transition and fires rider_self_rematch() above, so that dispatch-critical behavior is
  // preserved exactly, just deferred from "every tick/event while covered" to "once when covered
  // ends" (the earliest point such a transition could genuinely have happened anyway, since the
  // rider cannot free up while RiderActiveOrderScreen -- their own active-order screen -- is still
  // open for it).
  void _onActiveOrderScreenVisibilityChanged() {
    if (!mounted) return;
    if (ActiveOrderScreenState.isOpen.value) {
      if (!hasActiveOrder) {
        setState(() => hasActiveOrder = true);
      }
      return;
    }
    _pollActiveOrderFallback();
  }

  void startActiveOrderPollTimer() {
    _activeOrderPollTimer?.cancel();
    _activeOrderPollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      // Perf fix (WayDrop Phase J): skip the redundant DB round trip while RiderActiveOrderScreen
      // is open and covering this tab -- see _onActiveOrderScreenVisibilityChanged() above for why
      // this is safe. The timer itself is left running (not cancelled/restarted), so it resumes
      // normal polling the moment isOpen goes back to false, same pattern as the analogous
      // silent-refresh-timer gate in rider_home_tab.dart.
      if (ActiveOrderScreenState.isOpen.value) return;
      // Phase 5 F8: skip this tick if the poll has been failing recently -- only ever engages
      // after real failures (recordFailure() inside _pollActiveOrderFallback()'s own catch
      // block); a healthy poll always returns true here and this line changes nothing for it.
      if (!_activeOrderPollBackoff.shouldAttempt()) return;
      _pollActiveOrderFallback();
    });
  }

  // P1 fix (RiderOrdersScreen realtime duplication): now goes through RealtimeManager instead of
  // its own raw supabase.stream() connection. The realtime-triggered path below reuses the exact
  // same _pollActiveOrderFallback() query the 30s safety-net timer already uses (unchanged), so
  // the two paths can never disagree about what "active order" means -- only how soon a change
  // is observed. INSERT/DELETE on `orders` are intentionally not subscribed to here: an order is
  // always created with rider_id still null (never matches this filter at insert time) and rows
  // are never deleted, so UPDATE is the only event type that can ever apply, exactly matching
  // what the previous .stream() delivered in practice for this filter.
  Future<void> listenActiveOrder() async {
    if (riderId == null) return;
    // Initial snapshot, mirroring what .stream() previously gave immediately on subscribe.
    await _pollActiveOrderFallback();
    if (_activeOrderSubId != null && _activeOrderSubChannel != null) {
      RealtimeManager.instance.unsubscribe(_activeOrderSubChannel!, _activeOrderSubId!);
      _activeOrderSubId = null;
      _activeOrderSubChannel = null;
    }
    // Egress fix (Fix #3): was its own channel name ('rider-orders-updates-$riderId') filtered
    // identically to RiderHomeTab's 'rider-active-order-$riderId' channel (same table/filter,
    // both screens mounted simultaneously via IndexedStack) -- RealtimeManager only pools on an
    // EXACT channelName match, so two independent sockets were delivering every orders event for
    // this rider. Reusing that name (and its event=all, which RealtimeManager requires callers to
    // match exactly to pool) merges them into one. Event breadth is widened from UPDATE to ALL,
    // but per the comment above this method, INSERT/DELETE can never actually match this
    // rider_id filter in practice (orders are created with rider_id null, never deleted), so the
    // set of events this callback actually receives is unchanged.
    _activeOrderSubChannel = 'rider-active-order-$riderId';
    _activeOrderSubId = RealtimeManager.instance.subscribe(
      channelName: _activeOrderSubChannel!,
      table: 'orders',
      owner: 'RiderOrdersScreen_ActiveOrder',
      event: PostgresChangeEvent.all,
      schema: 'public',
      filterColumn: 'rider_id',
      filterValue: riderId!,
      callback: (payload) {
        // [TRACE_ACTIVEORDER] TEMPORARY diagnostic instrumentation -- investigating "Active Ride
        // In Progress" staying stuck after a rider cancels an accepted order. Delete after
        // root-cause capture.
        debugPrint(
          '[TRACE_ACTIVEORDER] RiderOrdersScreen.listenActiveOrder() REALTIME EVENT riderId=$riderId '
          'orderId=${payload.newRecord['id']} newStatus=${payload.newRecord['order_status']} '
          'epoch=${DateTime.now().millisecondsSinceEpoch}',
        );
        if (!mounted) return;
        // Perf fix (WayDrop Phase J): skip the redundant re-query while RiderActiveOrderScreen is
        // open -- it's already handling this exact event via its own realtime subscription. See
        // _onActiveOrderScreenVisibilityChanged() for the reconciliation that runs once it closes.
        if (ActiveOrderScreenState.isOpen.value) return;
        _pollActiveOrderFallback();
      },
    );
  }

  // =========================================================
  // REALTIME STREAMING OF SEARCHING ORDERS
  // =========================================================
  Future<void> fetchSearchingOrders() async {
    debugPrint('[INSTR] ${DateTime.now().toIso8601String()} fetchSearchingOrders() CALLED (riderId=$riderId, fetchInFlight=$_fetchInFlight)');
    if (riderId == null) return;
    // [PERF] Phase 8A: re-entrancy guard -- never run two fetches concurrently.
    // A trigger arriving while one is in flight (timer tick + realtime event) is
    // coalesced into a single follow-up fetch so no update is ever dropped.
    if (_fetchInFlight) {
      _refetchQueued = true;
      debugPrint('[INSTR] ${DateTime.now().toIso8601String()} fetchSearchingOrders() SKIPPED (already in flight) -- queued a follow-up refetch instead');
      return;
    }
    _fetchInFlight = true;
    try {
      // Fetch active dispatch configuration to get maxSearchDurationSec. Cached (Performance
      // Roadmap P0 #2) -- this call previously ran fresh on every single invocation of
      // fetchSearchingOrders (every 10s timer tick, plus every rider_assignments/orders realtime
      // event), against a table that only ever has one active row and changes only on an admin
      // edit. DispatchConfigCache returns the same row shape, just not a fresh query every time.
      final config = await DispatchConfigCache.get(
        () => supabase.from('dispatch_config').select('*').eq('is_active', true).maybeSingle(),
      );
      final int maxSearchDurationSec = int.tryParse(config?['max_search_duration_sec']?.toString() ?? '900') ?? 900;

      // 1. Fetch only real assignments with status 'sent'
      // P8 FIX #6.3 (RiderOrdersScreen query projection optimization): narrowed from
      // `*, orders(*, users(full_name, phone, user_code))` to exactly the fields this screen
      // reads, verified field-by-field against every `assignment[...]`/`order[...]`/`item[...]`
      // access in this file (see fetchSearchingOrders, _processAndFilterAssignments,
      // _filterExpiredAssignmentsFromState, buildOrderCard, _showNearbyOrderDetailsSheet -- none
      // of them are passed this object whole to another screen/widget). The `users(...)` embed had
      // zero consumers anywhere in this file and is dropped entirely. `distance_away` (read
      // optimistically at _showNearbyOrderDetailsSheet's `item['distance_away']`) is deliberately
      // omitted -- confirmed directly against the linked production database's
      // information_schema.columns that no `orders.distance_away` column exists (nor on any other
      // public table, nor referenced in any public function body), so that read was already always
      // null and stays that way; listing a non-existent column explicitly here would instead make
      // PostgREST error out and break the whole fetch.
      //
      // BUG FIX (sound-fires-but-card-missing, live-device-confirmed on two separate order_ids):
      // this same P8 FIX #6.3 pass introduced exactly the mistake its own comment above warns
      // against -- `rider_distance_km` AND `estimated_pickup_time_min` are both columns on
      // `order_assignment_logs`, not `rider_assignments` (confirmed against
      // 20260529000000_baseline_foundational_schema.sql's CREATE TABLE for each), so selecting
      // either one here made PostgREST reject this entire query (42703) on every single call.
      // That silently threw inside the try/catch below before `_processAndFilterAssignments()`
      // ever ran, so `rideOrders`/`parcelOrders` could never be populated -- for any order, not
      // just after a busy->free transition. Both values this screen actually needs are derived
      // below without them: `distance_km` (what start-dispatch writes to `rider_assignments`) for
      // rider distance, and `_processAndFilterAssignments()`'s own distance-based estimate
      // (`(distKm * 3).ceil().clamp(2, 20)`) for pickup time -- both already-existing fallbacks in
      // `assignment['distance_km'] ?? assignment['rider_distance_km']` and the
      // `assignment['estimated_pickup_time_min'] != null ? ... : ...` ternary gracefully handle
      // these keys now always being absent, so no other line needs to change.
      final assignmentsData = await supabase
          .from('rider_assignments')
          .select('''
            id,
            order_id,
            expires_at,
            distance_km,
            sent_at,
            created_at,
            orders(
              id,
              user_id,
              order_status,
              order_type,
              distance_meters,
              distance_km,
              pickup_lat,
              pickup_lng,
              created_at,
              final_fare,
              current_fare,
              boost_amount,
              boost_percentage,
              parcel_images,
              pickup_address,
              destination_address,
              parcel_type,
              weight_category,
              special_instructions,
              vehicle_type,
              fare_payment_method,
              payment_mode
            )
          ''')
          .eq('rider_id', riderId!)
          .eq('assignment_status', 'sent');
      final assignmentsList = List<Map<String, dynamic>>.from(assignmentsData);
      debugPrint('[INSTR] ${DateTime.now().toIso8601String()} fetchSearchingOrders() SQL returned ${assignmentsList.length} row(s) with assignment_status=sent for riderId=$riderId');

      final Map<String, Map<String, dynamic>> mergedMap = {};
      final now = DateTime.now();

      for (final a in assignmentsList) {
        final orderIdStr = a['order_id']?.toString();
        if (orderIdStr == null) continue;

        final order = a['orders'] as Map<String, dynamic>?;
        if (order != null && (order['order_status'] == 'searching' || order['order_status'] == 'created')) {
          // Skip if the order itself is older than maxSearchDurationSec
          final createdAtStr = order['created_at']?.toString();
          if (createdAtStr != null) {
            final createdAt = DateTime.tryParse(createdAtStr);
            if (createdAt != null && now.toUtc().difference(createdAt.toUtc()).inSeconds > maxSearchDurationSec) {
              continue;
            }
          }
          mergedMap[orderIdStr] = a;
        }
      }

      final list = mergedMap.values.toList();
      debugPrint('[INSTR] ${DateTime.now().toIso8601String()} fetchSearchingOrders() after status/age filtering: ${list.length} eligible order(s) -- calling _processAndFilterAssignments()');
      _processAndFilterAssignments(list);
      // Phase 5 F8: only resets the 10s timer's own backoff state -- does not affect this
      // function's return value/control flow for any other caller (e.g. a realtime event).
      _searchingOrdersPollBackoff.recordSuccess();
    } catch (e) {
      debugPrint('FETCH SEARCHING ORDERS DIRECT ERROR => $e');
      debugPrint('[INSTR] ${DateTime.now().toIso8601String()} fetchSearchingOrders() EXCEPTION: $e');
      _searchingOrdersPollBackoff.recordFailure();
      if (mounted && loading) {
        setState(() {
          loading = false;
        });
      }
    } finally {
      _fetchInFlight = false;
      if (_refetchQueued) {
        _refetchQueued = false;
        fetchSearchingOrders();
      }
    }
  }

  void listenSearchingOrders() {
    debugPrint('[INSTR] ${DateTime.now().toIso8601String()} listenSearchingOrders() STARTED for riderId=$riderId');
    if (_ordersSubId != null && _ordersSubChannel != null) {
      RealtimeManager.instance.unsubscribe(_ordersSubChannel!, _ordersSubId!);
      _ordersSubId = null;
      _ordersSubChannel = null;
    }
    _ordersSubChannel = 'rider-assignments-$riderId';
    debugPrint('[INSTR] ${DateTime.now().toIso8601String()} calling RealtimeManager.subscribe() channel=$_ordersSubChannel table=rider_assignments owner=RiderOrdersScreen_Assignments filterColumn=rider_id filterValue=$riderId');
    _ordersSubId = RealtimeManager.instance.subscribe(
      channelName: _ordersSubChannel!,
      table: 'rider_assignments',
      owner: 'RiderOrdersScreen_Assignments',
      event: PostgresChangeEvent.all,
      schema: 'public',
      filterColumn: 'rider_id',
      filterValue: riderId!,
      callback: (payload) {
        debugPrint('[INSTR] ${DateTime.now().toIso8601String()} rider_assignments REALTIME EVENT RECEIVED (RiderOrdersScreen) => type=${payload.eventType}, orderId=${payload.newRecord['order_id']}, status=${payload.newRecord['assignment_status']}');
        debugPrint('REALTIME ASSIGNMENT EVENT => ${payload.eventType}');
        if (payload.eventType == PostgresChangeEvent.insert) {
          final sentAtStr = payload.newRecord['sent_at']?.toString() ?? payload.newRecord['created_at']?.toString();
          if (sentAtStr != null) {
            final sentAt = DateTime.tryParse(sentAtStr);
            if (sentAt != null) {
              LocationCacheService.serverClockSkew = DateTime.now().difference(sentAt);
            }
          }
          // [PERF] Phase 8A: mark the fallback timer as redundant only on a *confirmed new
          // assignment INSERT* -- the actual event the poll exists to catch when realtime drops
          // it. Scoped to INSERT only (not UPDATE/DELETE from this rider's own accept/reject/expiry
          // churn) so a genuinely missed INSERT is never masked by unrelated traffic on this same
          // channel: nothing arms the gate for it, so the next 10s tick runs unconditionally.
          _lastRealtimeEventAt = DateTime.now();
          debugPrint('[INSTR] ${DateTime.now().toIso8601String()} _lastRealtimeEventAt updated to ${_lastRealtimeEventAt!.toIso8601String()} (RiderOrdersScreen assignments channel, INSERT)');
        } else if (payload.eventType == PostgresChangeEvent.update) {
          final status = payload.newRecord['assignment_status']?.toString();
          final orderId = payload.newRecord['order_id']?.toString();
          if (orderId != null && ['accepted', 'rejected', 'expired', 'completed', 'cancelled'].contains(status)) {
            _announcedOrders.remove(orderId);
          }
        }
        // Perf fix (WayDrop Phase J): same "a busy rider can never be assigned new dispatch work"
        // invariant startLocationTimer() already relies on above to skip its own fetch -- applied
        // here too, since this channel's fetchSearchingOrders() call was missing that guard even
        // though every event it can fire on (a 'sent'/'accepted'/'expired' assignment-status churn
        // for this rider) is exactly as unable to add anything new to the searching list while busy.
        if (mounted && !hasActiveOrder) {
          fetchSearchingOrders();
        }
      },
    );

    if (_ordersUpdateSubId != null && _ordersUpdateSubChannel != null) {
      RealtimeManager.instance.unsubscribe(_ordersUpdateSubChannel!, _ordersUpdateSubId!);
      _ordersUpdateSubId = null;
      _ordersUpdateSubChannel = null;
    }
    // Egress fix (Fix #3): same merge as listenActiveOrder() above -- reuse the canonical
    // 'rider-active-order-$riderId' channel (event=all, see comment there) instead of a second
    // 'rider-orders-updates-$riderId' name, so RealtimeManager pools this listener too.
    _ordersUpdateSubChannel = 'rider-active-order-$riderId';
    debugPrint('[INSTR] ${DateTime.now().toIso8601String()} calling RealtimeManager.subscribe() channel=$_ordersUpdateSubChannel table=orders owner=RiderOrdersScreen_Updates filterColumn=rider_id filterValue=$riderId');
    _ordersUpdateSubId = RealtimeManager.instance.subscribe(
      channelName: _ordersUpdateSubChannel!,
      table: 'orders',
      owner: 'RiderOrdersScreen_Updates',
      event: PostgresChangeEvent.all,
      schema: 'public',
      filterColumn: 'rider_id',
      filterValue: riderId!,
      callback: (payload) {
        debugPrint('REALTIME ORDER UPDATE EVENT => ${payload.newRecord['id']}');
        final record = payload.newRecord;
        final orderId = record['id']?.toString();
        final orderStatus = record['order_status']?.toString();
        if (orderId != null && ['accepted', 'rejected', 'expired', 'completed', 'cancelled'].contains(orderStatus)) {
          _announcedOrders.remove(orderId);
        }
        // Deliberately does NOT touch _lastRealtimeEventAt: this channel only ever fires on
        // order_status UPDATEs (accepted/picked_up/completed/...), which say nothing about
        // whether the rider_assignments channel is delivering new-ride INSERTs. Stamping it here
        // was the other half of the 66b78a1 regression -- normal order-lifecycle churn on an
        // active ride kept the assignments poll gated shut long after that ride finished.
        //
        // Perf fix (WayDrop Phase J): this channel fires on every single status transition of the
        // rider's own active order (accepted -> rider_arrived -> ... -> completed) -- previously
        // calling fetchSearchingOrders() on every one of them, even though a busy rider can never
        // be assigned new dispatch work (the same invariant startLocationTimer() already relies on
        // above). Guarded the same way -- hasActiveOrder is otherwise unaffected by this change.
        if (mounted && !hasActiveOrder) {
          fetchSearchingOrders();
        }
      },
    );
  }

  // =========================================================
  // FILTERING BY RADIUS & VEHICLE TYPE
  // =========================================================
  void _processAndFilterAssignments(List<Map<String, dynamic>> assignments) {
    final List<Map<String, dynamic>> rides = [];
    final List<Map<String, dynamic>> parcels = [];
    final now = DateTime.now();

    final currentUser = supabase.auth.currentUser;

    // Prune stale order IDs from the announced set to limit memory growth
    final visibleOrderIds = assignments
        .map((a) => (a['orders'] as Map?)?['id']?.toString())
        .whereType<String>()
        .toSet();
    _announcedOrders.removeWhere((id) => !visibleOrderIds.contains(id));

    for (final assignment in assignments) {
      final order = assignment['orders'] as Map<String, dynamic>?;
      if (order == null) continue;

      // STRICT self-matching check: Rider cannot accept or view their own orders!
      if (currentUser != null && order['user_id'] == currentUser.id) {
        continue;
      }

      // Only show orders that are currently in searching status
      final orderStatus = order['order_status'];
      if (orderStatus != 'searching' && orderStatus != 'created') continue;


      // Client-side expiry check
      final expiresAtStr = assignment['expires_at'];
      if (expiresAtStr != null) {
        final expiresAt = DateTime.tryParse(expiresAtStr.toString());
        if (expiresAt != null && now.isAfter(expiresAt)) {
          continue; // Skip expired assignments!
        }
      }

      // Filter out intercity parcels and intercity rides (distance > 25km)
      final String orderType = order['order_type'] ?? '';
      if (orderType == 'intercity_parcel' || orderType == 'intercity_ride') {
        continue;
      }
      final double tripMeters = double.tryParse(order['distance_meters']?.toString() ?? '0') ?? 0;
      final double tripKm = double.tryParse(order['distance_km']?.toString() ?? '0') ?? 0;
      if (orderType == 'ride' && (tripMeters > 20000 || tripKm > 20)) {
        continue;
      }

      // Parse distance safely from assignment['distance_km'] or assignment['rider_distance_km']
      final distVal = assignment['distance_km'] ?? assignment['rider_distance_km'];
      double? distKm = distVal != null ? double.tryParse(distVal.toString()) : null;

      // Fallback distance calculation if database values are null
      if (distKm == null && LocationCacheService.currentLat != null && LocationCacheService.currentLng != null) {
        final double pickupLat = double.tryParse(order['pickup_lat']?.toString() ?? '') ?? 0.0;
        final double pickupLng = double.tryParse(order['pickup_lng']?.toString() ?? '') ?? 0.0;
        if (pickupLat != 0.0 && pickupLng != 0.0) {
          final double meters = Geolocator.distanceBetween(
            LocationCacheService.currentLat!,
            LocationCacheService.currentLng!,
            pickupLat,
            pickupLng,
          );
          distKm = meters / 1000.0;
        }
      }

      // Calculate estimated pickup time matching trigger logic (CEIL(dist_km * 3))
      final int pickupTime = assignment['estimated_pickup_time_min'] != null
          ? (int.tryParse(assignment['estimated_pickup_time_min'].toString()) ?? 5)
          : (distKm != null ? (distKm * 3).ceil().clamp(2, 20) : 5);

      // Combine assignment details with order details
      final orderWithAssignment = {
        ...order,
        'assignment_id': assignment['id'],
        'rider_distance_km': distKm,
        'estimated_pickup_time_min': pickupTime,
        'assignment_status': assignment['assignment_status'],
        'expires_at': expiresAtStr,
        'sent_at': assignment['sent_at']?.toString() ?? assignment['created_at']?.toString(),
      };

      // Sound notification logic for new orders
      final orderId = order['id']?.toString();
      if (orderId != null && !_announcedOrders.contains(orderId)) {
        if (isRiderOnline) {
          _playOrderNearbySoundThrottled();
        }
        _announcedOrders.add(orderId);
      }

      if (order['order_type'] == 'ride') {
        rides.add(orderWithAssignment);
      } else {
        parcels.add(orderWithAssignment);
      }
    }

    // Update badge count provider with the count of active assignments
    try {
      providerContainer.read(activeAssignmentsCountProvider.notifier).state = rides.length + parcels.length;
    } catch (e) {
      debugPrint('Error updating active assignments badge count provider: $e');
    }

    debugPrint('[INSTR] ${DateTime.now().toIso8601String()} _processAndFilterAssignments() DONE -- rides=${rides.length}, parcels=${parcels.length}, mounted=$mounted, setState will run: $mounted');
    if (mounted) {
      setState(() {
        rideOrders = rides;
        parcelOrders = parcels;
        loading = false;
      });
    }
  }

  void _playOrderNearbySoundThrottled() {
    final now = DateTime.now();
    if (_lastSoundPlayed == null || now.difference(_lastSoundPlayed!) > const Duration(seconds: 3)) {
      _lastSoundPlayed = now;
      _playOrderNearbySound();
    }
  }

  Future<void> _playOrderNearbySound() async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(AssetSource('audio/order_nearby_sound.aac'));
    } catch (e) {
      debugPrint('Error playing in-app sound: $e');
    }
  }

  // =========================================================
  // ACCEPT & REJECT ACTIONS
  // =========================================================
  Future<void> acceptOrder(String orderId) async {
    if (codPendingAmount >= codLimit) {
      showAppSnackBar(context, 'COD Limit exceeded. Settle dues to accept orders.', type: SnackBarType.error);
      return;
    }
    if (hasActiveOrder) {
      showAppSnackBar(context, 'Complete current order first', type: SnackBarType.info);
      return;
    }
    if (processing) return;

    try {
      setState(() => processing = true);

      final response = await supabase.functions.invoke(
        'accept-order',
        body: {
          'order_id': orderId,
          'rider_id': riderId!,
        },
      );

      if (response.data == null || response.data['success'] != true) {
        throw Exception(response.data?['message'] ?? 'Failed to accept order');
      }

      if (!mounted) return;
      // Amplification-reduction pass: accept-order's response already carries the full, fresh
      // order row (post-acceptance) -- hand it to RiderActiveOrderScreen instead of letting it
      // re-fetch the identical row a moment later. Falls back to the screen's own full fetch
      // automatically if the response shape ever changes (initialOrder stays null).
      final acceptedOrder = response.data['order'];
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RiderActiveOrderScreen(
            orderId: orderId,
            initialOrder: acceptedOrder is Map
                ? Map<String, dynamic>.from(acceptedOrder)
                : null,
          ),
        ),
      );
    } catch (e, stackTrace) {
      final errorMsg = _getExceptionMessage(e);
      if (errorMsg.contains('no longer available') ||
          errorMsg.contains('already accepted') ||
          errorMsg.contains('already handled') ||
          errorMsg.contains('Assignment not found') ||
          errorMsg.contains('Assignment already handled')) {
        // Add to session rejected map permanently for this session so it gets removed immediately
        setState(() {
          rejectedOrderIds[orderId] = DateTime.now().add(const Duration(hours: 24));
        });
        await fetchSearchingOrders();
        if (mounted) {
          showAppSnackBar(context, 'This order has already been accepted by another rider!', type: SnackBarType.error);
        }
      } else {
        // Phase 5 F2: non-fatal Crashlytics report for a genuinely unexpected acceptance failure
        // (the routine "another rider already took it" race above is expected business behavior,
        // not reported here to avoid noise) -- purely additive, does not affect the existing
        // SnackBar behavior below.
        FirebaseCrashlytics.instance.recordError(
          e,
          stackTrace,
          reason: 'accept-order failed',
          information: ['orderId: $orderId', 'riderId: $riderId'],
        );
        if (mounted) {
          showAppSnackBar(context, errorMsg, type: SnackBarType.error);
        }
      }
    } finally {
      if (mounted) {
        setState(() => processing = false);
      }
    }
  }

  Future<void> rejectOrder(String orderId) async {
    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Order rejected',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
      }
      
      try {
        await supabase.functions.invoke(
          'reject-order',
          body: {
            'order_id': orderId,
            'rider_id': riderId!,
            'rejection_reason': 'Declined by rider from available list',
          },
        );
      } catch (e) {
        debugPrint('REJECT ORDER EDGE FUNCTION ERROR => $e');
      }
      
      await fetchSearchingOrders();
    } catch (e) {
      debugPrint('REJECT ORDER ERROR => $e');
    }
  }

  String _getExceptionMessage(Object e) {
    if (e is FunctionException) {
      final details = e.details;
      if (details != null) {
        if (details is Map && details.containsKey('message')) {
          return details['message'].toString();
        } else if (details is String) {
          try {
            final Map<String, dynamic> decoded = jsonDecode(details);
            if (decoded.containsKey('message')) {
              return decoded['message'].toString();
            }
          } catch (_) {
            return details;
          }
        }
      }
    }
    return e.toString().replaceAll('Exception:', '').trim();
  }

  // =========================================================
  // UI BUILD
  // =========================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        backgroundColor: darkBg,
        elevation: 0,
        title: const Text(
          'Orders Nearby',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Container(
            height: 48,
            margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            decoration: BoxDecoration(
              color: darkCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 1.5),
            ),
            child: TabBar(
              controller: tabController,
              indicator: BoxDecoration(
                color: primaryLime,
                borderRadius: BorderRadius.circular(12),
              ),
              labelColor: Colors.black,
              unselectedLabelColor: textGray,
              labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              unselectedLabelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              indicatorSize: TabBarIndicatorSize.tab,
              tabs: [
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Rides'),
                      if (rideOrders.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Colors.redAccent,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.redAccent,
                                blurRadius: 4,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Parcels'),
                      if (parcelOrders.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Colors.redAccent,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.redAccent,
                                blurRadius: 4,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: loading
          ? const SkeletonLoader()
          : (!isRiderOnline)
              ? _buildOfflineView()
              : (codPendingAmount >= codLimit)
                  ? _buildCodBlockView()
                  : TabBarView(
              controller: tabController,
              children: [
                buildOrdersList(rideOrders),
               buildOrdersList(parcelOrders),
              ],
            ),
    );
  }

  Widget buildOrdersList(List<Map<String, dynamic>> orders) {
    if (hasActiveOrder) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.03),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.05), width: 1.5),
                ),
                child: Icon(
                  Icons.lock_clock_rounded,
                  color: primaryLime.withValues(alpha: 0.8),
                  size: 48,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Active Ride in Progress',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'You cannot view or accept other orders while you have an ongoing active order.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: textGray,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (orders.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.near_me_disabled_rounded, color: textGray.withValues(alpha: 0.4), size: 48),
            const SizedBox(height: 12),
            const Text(
              'No active requests nearby',
              style: TextStyle(color: textGray, fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              'We are watching for requests in real time...',
              style: TextStyle(color: Colors.white24, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 96 + Insets.bottom(context)), // bottom padding for floating navigation bar
      itemCount: orders.length,
      itemBuilder: (context, index) {
        return buildOrderCard(orders[index]);
      },
    );
  }

  Widget buildOrderCard(Map<String, dynamic> item) {
    final fare = double.tryParse(item['final_fare']?.toString() ?? item['current_fare']?.toString() ?? '0') ?? 0.0;
    final boost = double.tryParse(item['boost_amount']?.toString() ?? '0') ?? 0.0;

    final rawImages = item['parcel_images'];
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

    return GestureDetector(
      onTap: () => _showNearbyOrderDetailsSheet(context, item),
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: darkCard,
          borderRadius: BorderRadius.circular(32),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header Row: Pulsing green dot + Title
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: primaryLime,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: primaryLime,
                        blurRadius: 6,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item['order_type'] == 'ride' ? 'Received a new ride request' : 'Received a new parcel request',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                // Visual Countdown Timer
                ValueListenableBuilder<int>(
                  valueListenable: _expiryNotifier,
                  builder: (context, tick, _) {
                    final expiresAtStr = item['expires_at'];
                  final sentAtStr = item['sent_at'];
                  if (expiresAtStr != null && sentAtStr != null) {
                    final expiresAt = DateTime.tryParse(expiresAtStr.toString());
                    final sentAt = DateTime.tryParse(sentAtStr.toString());
                    if (expiresAt != null && sentAt != null) {
                      final totalSeconds = expiresAt.difference(sentAt).inSeconds;
                      final adjustedNow = DateTime.now().subtract(LocationCacheService.serverClockSkew);
                      final elapsed = adjustedNow.difference(sentAt).inSeconds;
                      final remaining = (totalSeconds - elapsed).clamp(0, 120);
                      if (remaining > 0) {
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: remaining > 30
                                ? primaryLime.withValues(alpha: 0.1)
                                : Colors.redAccent.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: remaining > 30
                                  ? primaryLime.withValues(alpha: 0.25)
                                  : Colors.redAccent.withValues(alpha: 0.25),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.timer_outlined,
                                size: 13,
                                color: remaining > 30 ? primaryLime : Colors.redAccent,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${remaining}s',
                                style: TextStyle(
                                  color: remaining > 30 ? primaryLime : Colors.redAccent,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        );
                      }
                    }
                  }
                  return const SizedBox.shrink();
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Ride Estimation Time & Surge
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    '${item['estimated_pickup_time_min'] ?? 5} mins estimated pickup time',
                    style: const TextStyle(
                      color: primaryLime,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (boost > 0)
                  (() {
                    final boostPercent = double.tryParse(item['boost_percentage']?.toString() ?? '0') ?? 0.0;
                    return FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFFFF7E40), Color(0xFFFF5252)],
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.local_fire_department_rounded, color: Colors.white, size: 14),
                            const SizedBox(width: 4),
                            Text(
                              'SURGE +₹${boost.toStringAsFixed(0)} (+${boostPercent.toStringAsFixed(0)}%)',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  })(),
              ],
            ),
            const SizedBox(height: 18),

            // Neon Yellow Route Card (Matches Dribbble mock)
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: primaryLime,
                borderRadius: BorderRadius.circular(28),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Pickup dark capsule
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: darkBg,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.05),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.my_location_rounded, color: primaryLime, size: 16),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'PICKUP LOCATION',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white.withValues(alpha: 0.4),
                                  letterSpacing: 0.5,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                item['pickup_address'] ?? 'Pickup Address',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Drop-off dark capsule
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: darkBg,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.05),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.location_on_rounded, color: Colors.redAccent, size: 16),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'DROP-OFF LOCATION',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white.withValues(alpha: 0.4),
                                  letterSpacing: 0.5,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                item['destination_address'] ?? 'Destination Address',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
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
            const SizedBox(height: 14),

            // Parcel Specific Panel (Receiver, type, weight, instructions)
            if (item['order_type'] == 'local_parcel' || item['order_type'] == 'intercity_parcel') ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.blue.withValues(alpha: 0.08), width: 1.2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.inventory_2_rounded, color: Colors.blueAccent, size: 14),
                        const SizedBox(width: 8),
                        const Text(
                          'Parcel details',
                          style: TextStyle(color: Colors.blueAccent, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (item['parcel_type'] != null)
                      _buildParcelDetailRow('Category', item['parcel_type'].toString()),
                    if (item['weight_category'] != null)
                      _buildParcelDetailRow('Weight Class', item['weight_category'].toString()),
                    // Receiver details hidden before acceptance
                    if (parcelImages.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      const Text(
                        'Attached Images:',
                        style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      SizedBox(
                        height: 60,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: parcelImages.length,
                          itemBuilder: (context, idx) {
                            return Container(
                              margin: const EdgeInsets.only(right: 8),
                              width: 60,
                              height: 60,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.white10),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                // 60x60 display size: downsample the decoded image in
                                // memory instead of holding a full-res decode.
                                child: CachedNetworkImage(
                                  imageUrl: parcelImages[idx],
                                  fit: BoxFit.cover,
                                  memCacheWidth: (60 * MediaQuery.of(context).devicePixelRatio).round(),
                                  memCacheHeight: (60 * MediaQuery.of(context).devicePixelRatio).round(),
                                  errorWidget: (ctx, url, err) => const Icon(
                                    Icons.broken_image_rounded,
                                    color: Colors.white24,
                                    size: 20,
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

            if (item['special_instructions'] != null && item['special_instructions'].toString().trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.05), width: 1),
                ),
                child: Text(
                  'Note: ${item['special_instructions']}',
                  style: const TextStyle(color: textGray, fontSize: 12, fontStyle: FontStyle.italic),
                ),
              ),
            ],

            const SizedBox(height: 18),

            // Actions: Circular close/reject button + custom SlideToAccept swipe button
            Row(
              children: [
                // Reject Button (circular)
                GestureDetector(
                  onTap: processing ? null : () => rejectOrder(item['id']),
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 1.5),
                    ),
                    child: const Center(
                      child: Icon(Icons.close_rounded, color: Colors.white70, size: 24),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Swipe to Accept Slider
                Expanded(
                  child: SlideToAcceptButton(
                    fare: fare,
                    onAccept: () => acceptOrder(item['id']),
                    processing: processing,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showNearbyOrderDetailsSheet(BuildContext context, Map<String, dynamic> item) {
    // Format fare and distance values
    final fare = double.tryParse(item['final_fare']?.toString() ?? item['current_fare']?.toString() ?? '0') ?? 0.0;
    final boost = double.tryParse(item['boost_amount']?.toString() ?? '0') ?? 0.0;
    final boostPercent = (double.tryParse(item['boost_percentage']?.toString() ?? '0') ?? 0.0).toStringAsFixed(0);
    
    final distanceAway = item['distance_away'] as double? ?? -1;
    var riderDistanceKm = item['rider_distance_km'] != null ? double.tryParse(item['rider_distance_km'].toString()) : null;
    if (riderDistanceKm == null && LocationCacheService.currentLat != null && LocationCacheService.currentLng != null) {
      final double pickupLat = double.tryParse(item['pickup_lat']?.toString() ?? '') ?? 0.0;
      final double pickupLng = double.tryParse(item['pickup_lng']?.toString() ?? '') ?? 0.0;
      if (pickupLat != 0.0 && pickupLng != 0.0) {
        final double meters = Geolocator.distanceBetween(
          LocationCacheService.currentLat!,
          LocationCacheService.currentLng!,
          pickupLat,
          pickupLng,
        );
        riderDistanceKm = meters / 1000.0;
      }
    }
    final distStr = riderDistanceKm != null
        ? '${riderDistanceKm.toStringAsFixed(2)} km away'
        : (distanceAway >= 0
            ? '${(distanceAway / 1000).toStringAsFixed(1)} km away'
            : 'Calculating location...');

    final distKm = item['distance_km'] ?? (item['distance_meters'] != null ? (double.tryParse(item['distance_meters'].toString()) ?? 0.0) / 1000.0 : null);
    final rideDistStr = distKm != null ? '${double.tryParse(distKm.toString())?.toStringAsFixed(1)} km' : 'N/A';
    
    final vehicle = item['vehicle_type']?.toString().toUpperCase() ?? 'BIKE';
    // orders has no `payment_method` column -- this always read null. fare_payment_method is the
    // passenger's real settlement choice (only set once the order reaches payment_pending), so a
    // not-yet-accepted order here typically only has the booking-time payment_mode; fall back to
    // that instead of silently mislabeling every order "CASH".
    final fareMethod = item['fare_payment_method']?.toString();
    final paymentMode = item['payment_mode']?.toString().toLowerCase();
    final payment = fareMethod == 'personal_upi'
        ? 'PERSONAL UPI / QR'
        : fareMethod == 'cash'
            ? 'CASH'
            : fareMethod == 'cashfree'
                ? 'ONLINE PAYMENT'
                : paymentMode == 'cash'
                    ? 'CASH'
                    : paymentMode == 'upi'
                        ? 'PERSONAL UPI / QR'
                        : 'ONLINE PAYMENT';

    final rawImages = item['parcel_images'];
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

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: darkCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => Container(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            const SizedBox.shrink(),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Order Details',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: primaryLime.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$vehicle REQUEST',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: primaryLime,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _buildDetailField(Icons.my_location_rounded, 'Pickup Address', item['pickup_address'] ?? 'N/A', Colors.greenAccent),
            const SizedBox(height: 16),
            _buildDetailField(Icons.location_on_rounded, 'Destination Address', item['destination_address'] ?? 'N/A', Colors.redAccent),
            const SizedBox(height: 16),
            const Divider(color: Colors.white10),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildStatColumn('Pickup Distance', distStr),
                _buildStatColumn('Total Ride Distance', rideDistStr),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                (() {
                  final boostPercentVal = double.tryParse(item['boost_percentage']?.toString() ?? '0') ?? 0.0;
                  return _buildStatColumn(
                    'Est. Fare',
                    // Phase 11 (Issue 1): whole-rupee format -- current_fare/final_fare are
                    // already whole-rupee (create-order rounds the booking-time estimate).
                    '₹${fare.toStringAsFixed(0)}',
                  );
                })(),
                _buildStatColumn('Payment Method', payment),
              ],
            ),
            if (item['order_type'] == 'local_parcel' || item['order_type'] == 'intercity_parcel') ...[
              const SizedBox(height: 18),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.blue.withValues(alpha: 0.08), width: 1.2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.inventory_2_rounded, color: Colors.blueAccent, size: 14),
                        const SizedBox(width: 8),
                        const Text(
                          'Parcel details',
                          style: TextStyle(color: Colors.blueAccent, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (item['parcel_type'] != null)
                      _buildParcelDetailRow('Category', item['parcel_type'].toString()),
                    if (item['weight_category'] != null)
                      _buildParcelDetailRow('Weight Class', item['weight_category'].toString()),
                    // Receiver details hidden before acceptance
                    if (item['special_instructions'] != null && item['special_instructions'].toString().trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Divider(color: Colors.white10),
                      const SizedBox(height: 4),
                      Text(
                        'Note: ${item['special_instructions']}',
                        style: const TextStyle(color: textGray, fontSize: 12, fontStyle: FontStyle.italic),
                      ),
                    ],
                  ],
                ),
              ),
                         if (boost > 0) ...[
              const SizedBox(height: 18),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFFF7E40), Color(0xFFFF5252)],
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.bolt_rounded, color: Colors.white, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'Boosted: ₹${boost.toStringAsFixed(2)} (+$boostPercent%) included',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],    ],
            if (parcelImages.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                'ATTACHED PARCEL IMAGES',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: textGray,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 120,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: parcelImages.length,
                  itemBuilder: (context, idx) {
                    return GestureDetector(
                      onTap: () {
                        showDialog(
                          context: context,
                          builder: (ctx) => Dialog(
                            backgroundColor: Colors.transparent,
                            insetPadding: const EdgeInsets.all(10),
                            child: Stack(
                              alignment: Alignment.topRight,
                              children: [
                                InteractiveViewer(
                                  panEnabled: true,
                                  minScale: 0.5,
                                  maxScale: 4.0,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(16),
                                    // Full-screen view: no mem-cache downsampling (largest
                                    // display size here), but still routed through
                                    // CachedNetworkImage so it reads the same disk cache
                                    // entry the 120x120 thumbnail below already populated
                                    // instead of re-downloading the same URL.
                                    child: CachedNetworkImage(
                                      imageUrl: parcelImages[idx],
                                      fit: BoxFit.contain,
                                      placeholder: (context, url) =>
                                          const Center(child: CircularProgressIndicator(color: primaryLime)),
                                      errorWidget: (ctx, url, err) => const Icon(
                                        Icons.broken_image_rounded,
                                        color: Colors.white30,
                                        size: 48,
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: 10,
                                  right: 10,
                                  child: GestureDetector(
                                    onTap: () => Navigator.pop(ctx),
                                    child: Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: const BoxDecoration(
                                        color: Colors.black54,
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(Icons.close, color: Colors.white, size: 20),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                      child: Container(
                        margin: const EdgeInsets.only(right: 12),
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          // 120x120 display size: downsample the decoded image in memory
                          // instead of holding a full-res decode. Shares the same disk
                          // cache entry as the full-screen viewer above, so tapping to
                          // view full-screen does not re-download the image.
                          child: CachedNetworkImage(
                            imageUrl: parcelImages[idx],
                            fit: BoxFit.cover,
                            memCacheWidth: (120 * MediaQuery.of(context).devicePixelRatio).round(),
                            memCacheHeight: (120 * MediaQuery.of(context).devicePixelRatio).round(),
                            errorWidget: (ctx, url, err) => const Icon(
                              Icons.broken_image_rounded,
                              color: Colors.white24,
                              size: 28,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
            const SizedBox(height: 12),
          ],
        ),
      ),
    ),
  );
}

  Widget _buildDetailField(IconData icon, String label, String value, Color iconColor) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: iconColor, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: textGray,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStatColumn(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: textGray,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ],
    );
  }



  Widget _buildParcelDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label: ',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 11, fontWeight: FontWeight.bold),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCodBlockView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFFEF4444).withValues(alpha: 0.05),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.1), width: 1.5),
              ),
              child: const Icon(
                Icons.gpp_maybe_rounded,
                color: Color(0xFFEF4444),
                size: 64,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'COD Limit Exceeded',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Your cash pending amount has exceeded the allowed limit of ₹${codLimit.toStringAsFixed(2)}. Please settle the amount to resume receiving orders.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: textGray,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 28),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: darkCard,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Cash to Paid',
                        style: TextStyle(color: textGray, fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                      Text(
                        '₹${codPendingAmount.toStringAsFixed(2)}',
                        style: const TextStyle(color: Color(0xFFEF4444), fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(color: Colors.white10),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'COD Limit',
                        style: TextStyle(color: textGray, fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                      Text(
                        '₹${codLimit.toStringAsFixed(2)}',
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOfflineView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.03),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: 0.05), width: 1.5),
              ),
              child: Icon(
                Icons.sensors_off_rounded,
                color: textGray.withValues(alpha: 0.6),
                size: 64,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'You are Offline',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Go online from the Home screen to see available orders near you.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: textGray,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @visibleForTesting
  Set<String> get announcedOrders => _announcedOrders;

  @visibleForTesting
  DateTime? get lastSoundPlayed => _lastSoundPlayed;

  @visibleForTesting
  void setLastSoundPlayed(DateTime? val) {
    _lastSoundPlayed = val;
  }

  @visibleForTesting
  void processAndFilterAssignments(List<Map<String, dynamic>> assignments) {
    _processAndFilterAssignments(assignments);
  }
}


// =========================================================
// CUSTOM SLIDING ACCEPT BUTTON (Match Dribbble screenshot)
// =========================================================
class SlideToAcceptButton extends StatefulWidget {
  final double fare;
  final VoidCallback onAccept;
  final bool processing;

  const SlideToAcceptButton({
    super.key,
    required this.fare,
    required this.onAccept,
    this.processing = false,
  });

  @override
  State<SlideToAcceptButton> createState() => _SlideToAcceptButtonState();
}

class _SlideToAcceptButtonState extends State<SlideToAcceptButton> {
  double _dragPosition = 0;
  bool _isAccepted = false;

  @override
  void didUpdateWidget(covariant SlideToAcceptButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.processing && oldWidget.processing) {
      setState(() {
        _dragPosition = 0;
        _isAccepted = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const handleWidth = 120.0;
        final maxDrag = constraints.maxWidth - handleWidth - 6.0;

        return Container(
          height: 52,
          width: double.infinity,
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 1.5),
          ),
          child: Stack(
            children: [
              // Price on the far right
              Positioned.fill(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 20),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            // Phase 11 (Issue 1): whole-rupee format, matching the identical
                            // SlideToAcceptButton in incoming_order_card.dart (already fixed).
                            '₹${widget.fare.toStringAsFixed(0)}',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Slide Handle Button
              Positioned(
                left: 3 + _dragPosition,
                top: 3,
                bottom: 3,
                child: GestureDetector(
                  onHorizontalDragUpdate: (details) {
                    if (_isAccepted || widget.processing) return;
                    setState(() {
                      _dragPosition = (_dragPosition + details.delta.dx).clamp(0.0, maxDrag);
                    });
                  },
                  onHorizontalDragEnd: (details) {
                    if (_isAccepted || widget.processing) return;
                    if (_dragPosition >= maxDrag * 0.8) {
                      setState(() {
                        _dragPosition = maxDrag;
                        _isAccepted = true;
                      });
                      widget.onAccept();
                    } else {
                      setState(() {
                        _dragPosition = 0;
                      });
                    }
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    width: handleWidth,
                    height: 46,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(23),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 4,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Center(
                      child: widget.processing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF0B0F19),
                              ),
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Text(
                                  'Accept',
                                  style: TextStyle(
                                    color: Color(0xFF0B0F19),
                                    fontSize: 14,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  width: 20,
                                  height: 20,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFFC5FF30),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Center(
                                    child: Icon(
                                      Icons.chevron_right_rounded,
                                      color: Color(0xFF0B0F19),
                                      size: 14,
                                    ),
                                  ),
                                ),
                              ],
                            ),
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
