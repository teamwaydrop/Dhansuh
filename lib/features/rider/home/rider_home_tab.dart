import 'package:waydrop/core/services/diagnostics/ride_diagnostics.dart';
import 'package:waydrop/core/services/diagnostics/ride_diagnostics_owner.dart';
import 'dart:async';
import 'dart:convert';
import 'package:waydrop/features/rider/home/active_order_refresh_coordinator.dart';
import 'package:waydrop/features/rider/home/offline_tracking_rollback.dart';
import 'package:waydrop/features/rider/home/pending_assignment_read.dart';
import 'package:waydrop/features/rider/home/travel_plan_refresh.dart';
import 'package:waydrop/features/rider/home/rider_profile_read.dart';
import 'package:waydrop/features/rider/home/today_earnings_refresh.dart';
import 'package:waydrop/features/rider/home/incoming_order_type_read.dart';
import 'package:waydrop/core/models/today_earnings_seed.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:geolocator/geolocator.dart';
import 'package:waydrop/core/services/location/location_cache_service.dart';
import 'package:waydrop/modules/notifications/screens/notifications_inbox_screen.dart';
import 'package:waydrop/modules/notifications/widgets/notification_bell_badge.dart';
import 'package:waydrop/modules/notifications/services/notification_badge_service.dart';
import 'package:waydrop/core/services/maps/ola_map_service.dart';
import 'package:waydrop/features/rider/orders/screens/rider_active_order_screen.dart';
import 'package:waydrop/core/services/session/active_order_screen_state.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:waydrop/core/services/network/poll_backoff.dart';

import 'package:waydrop/modules/payments/services/payment_service.dart';
import 'package:waydrop/modules/payments/services/payment_debug_trace.dart';
import 'package:waydrop/models/payment_for.dart';
import 'package:waydrop/shared/widgets/skeleton_loader.dart';
import 'package:waydrop/shared/helpers/location_display_service.dart';
import 'package:waydrop/shared/helpers/time_format_helper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:waydrop/core/providers/initial_data_provider.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:waydrop/features/rider/models/partner_service_mode.dart';
import 'package:waydrop/features/rider/onboarding/screens/service_mode_selection_screen.dart';
import 'package:waydrop/features/rider/intercity/intercity_bookings_screen.dart';
import 'package:waydrop/features/rider/travel_plans/screens/post_travel_plan_screen.dart';
import 'package:waydrop/features/rider/travel_plans/screens/travel_plan_details_screen.dart';
import 'package:waydrop/features/intercity/shared/services/intercity_matching_service.dart';
import 'package:waydrop/shared/helpers/insets.dart';



class RiderHomeTab extends ConsumerStatefulWidget {
  // P2-A (WayDrop P1/P2 performance pass): whether this tab is the currently visible/selected tab
  // inside RiderMainNavigationScreen's IndexedStack. Defaults to true so any call site that doesn't
  // pass it keeps running exactly as before. Only ever pauses the 30s silent refresh timer below --
  // realtime subscriptions and GPS/location tracking are untouched by this flag (both must keep
  // working even while another tab is in front, e.g. an incoming-order sound/haptic or a live
  // location ping while the rider is looking at the Orders tab).
  final bool isActive;

  const RiderHomeTab({super.key, this.isActive = true});

  @override
  ConsumerState<RiderHomeTab> createState() => _RiderHomeTabState();
}

class _RiderHomeTabState extends ConsumerState<RiderHomeTab> with WidgetsBindingObserver {
  final supabase = Supabase.instance.client;
  Map<String, dynamic>? rider;
  double todayEarnings = 0.0;
  EarningsScope? _grossEarningsScope;
  TodayEarningsSeed? _initialEarningsSeed;
  // Item 4: a traveller can have several concurrently active intercity passengers under one
  // travel plan (each their own `orders` row, same rider_id) -- this must be a list, not a single
  // nullable order, or every entry past the first silently disappears from Rider Home.
  List<Map<String, dynamic>> activeOrders = [];
  late final ActiveOrderRefreshCoordinator<ActiveOrderReconciliation>
      _activeOrderRefresh;
  final RiderActiveOrderVerification _activeOrderVerification = RiderActiveOrderVerification();
  RiderOfflineContext? _trackingRecoveryFailure;
  final OfflineStatusEvidence _offlineStatusEvidence = OfflineStatusEvidence();
  String? _offlineStatusUserId;
  final PendingAssignmentRead _pendingAssignmentRead = PendingAssignmentRead();
  late final TravelPlanRefresh _travelPlanRefresh;
  final RiderProfileRead _riderProfileRead = RiderProfileRead();
  String? _riderProfileOwnerUserId;
  late final TodayEarningsRefresh _todayEarningsRefresh;
  final IncomingOrderTypeRead _incomingOrderTypeRead = IncomingOrderTypeRead();
  bool get _trackingRecoveryUnavailable {
    final failure = _trackingRecoveryFailure;
    return failure != null && _activeOrderVerification.sameOfflineIdentity(
        failure, rider?['id']?.toString(), supabase.auth.currentUser?.id) &&
        !LocationCacheService.isRiderLiveTrackingActive;
  }
  bool get _activeOrderEvidenceUnresolved =>
      _offlineStatusEvidence.unknown ||
      _activeOrderVerification.unresolvedFor(rider?['id']?.toString(),
          orderRevision: _activeOrderRefresh.invalidationRevision);
  final ActiveOrderEventMetadata _activeOrderEvents = ActiveOrderEventMetadata();
  bool isOnline = false;
  bool statusUpdating = false;
  bool loading = true;
  Timer? _riderSilentRefreshTimer;
  // Egress fix: loadRider() swallows its own errors internally (existing
  // try/catch/debugPrint, never rethrows), so recorded directly from inside its own
  // success/catch paths. Consulted by the 30s silent-refresh timer only -- initState,
  // resume, and realtime callbacks all call loadRider() unconditionally.
  final PollBackoff _refreshBackoff = PollBackoff();
  String? riderSubId;
  String? riderSubChannel;
  String? assignmentSubId;
  String? assignmentSubChannel;
  String? activeOrderSubId;
  String? activeOrderSubChannel;
  String? travelPlansSubId;
  String? travelPlansSubChannel;
  String? _subscribedAssignmentsRiderId;
  String? _subscribedActiveOrderRiderId;
  String? _subscribedTravelPlansRiderId;

  List<Map<String, dynamic>> travelPlans = [];
  bool loadingPlans = false;
  // Accepted/pending Travel Together counts per plan (keyed by rider_travel_plans.id), so the
  // Travel Plan card can show "N Accepted / M Pending" instead of the plan silently disappearing
  // from this list -- see loadTravelPlans() below for why 'fully_booked' plans must stay listed.
  Map<String, int> _planAcceptedCounts = {};
  Map<String, int> _planPendingCounts = {};

  PartnerServiceMode? get serviceMode => PartnerServiceMode.fromDb(rider?['service_mode']);

  final AudioPlayer _audioPlayer = AudioPlayer();
  final Set<String> _announcedOrders = {};
  DateTime? _lastSoundPlayed;



  static const Color primaryLime = Color(0xFFC5FF30);
  static const Color darkBg = Color(0xFF0B0F19);
  static const Color darkCard = Color(0xFF131926);
  static const Color textGray = Color(0xFF94A3B8);

  // PERF FIX (rider-location-realtime-fanout, Phase 1): the exact column set
  // LocationCacheService.updateRiderLocation() writes on every GPS heartbeat/movement update
  // (lib/core/services/location/location_cache_service.dart) — nothing in this tab's UI derives
  // from any of these, so a `riders` UPDATE whose changed columns are a subset of this set can
  // never affect what this tab renders and is safe to skip the earnings requery/rebuild for. Kept
  // as an explicit allowlist (not a blocklist) so any *new* column this tab starts depending on in
  // the future safely falls through to the full refresh by default instead of silently being
  // ignored.
  static const Set<String> _locationHeartbeatFields = {
    'current_lat',
    'current_lng',
    'current_heading',
    'last_location_updated_at',
    'last_active_at',
    'updated_at',
  };

  // PERF FIX (P1, WayDrop duplicate-realtime audit): the exact `riders` columns
  // credit_rider_for_completed_order() writes, atomically, whenever an order genuinely completes
  // (confirmed by reading its current definition, 20260820000000_fix_intercity_parcel_delivery_
  // rider_credit_guard.sql -- called both directly and via complete_order_and_settle(), so this is
  // the single, authoritative write path for every completion, ride or parcel, cash or online). No
  // other `riders` column -- account_status, service_mode, subscription_*, rating, kyc_id, etc. --
  // is ever touched by that write. Kept as an explicit allowlist (not a blocklist) for the same
  // reason as _locationHeartbeatFields above: any *new* column this tab starts deriving earnings
  // from in the future safely falls through to a refresh by default instead of silently being
  // ignored.
  static const Set<String> _earningsRelevantFields = {
    'total_orders',
    'total_completed_orders',
    'total_earnings',
    'today_earnings',
    'wallet_balance',
    'cod_pending_amount',
  };

  // The coordinator scopes its existing 3s recency window to identity/day and
  // invalidation revision. Distinct events are not assumed to be one transaction.
  EarningsScope? get _currentEarningsScope {
    final userId = supabase.auth.currentUser?.id;
    final riderId = rider?['id']?.toString();
    return userId == null || riderId == null ? null : EarningsScope(userId, riderId, DateTime.now());
  }
  Future<EarningsSnapshot?> _readTodayEarnings(String riderId) {
    final userId = supabase.auth.currentUser?.id;
    return userId == null ? Future.value() :
        _todayEarningsRefresh.read(EarningsScope(userId, riderId, DateTime.now()));
  }
  Future<void> _refreshEarningsOnly(String riderId) async {
    try {
      final snapshot = await _readTodayEarnings(riderId);
      if (mounted && snapshot != null &&
          _todayEarningsRefresh.markApplied(snapshot, _currentEarningsScope)) {
        setState(() {
          todayEarnings = snapshot.total;
          _grossEarningsScope = snapshot.scope;
        });
      }
    } catch (_) {
      debugPrint('Error calculating today earnings: request_failed');
    }
  }

  // "Today's Gross Earnings" (Phase 2 reconciliation): must use the SAME authoritative
  // gross-fare definition as rider_earnings_tab.dart's todayE -- final_fare ?? current_fare,
  // completed/delivered orders, current LOCAL calendar day -- so the Home card and the Earnings
  // tab always show the identical figure for the same rider/day. Previously summed
  // orders.rider_earning (a NET figure), which is why Home and Earnings could disagree even
  // though both already correctly date-filter by completed_at's local day. Payment method is
  // deliberately not filtered on -- Cashfree/Personal QR/Cash all contribute their full gross fare.
  Future<double> _fetchTodayEarnings(String riderId, DateTime nowLocal) async {
    final startOfToday = DateTime(nowLocal.year, nowLocal.month, nowLocal.day).toUtc();
    final response = await supabase
        .from('orders')
        .select('final_fare, current_fare')
        .eq('rider_id', riderId)
        .inFilter('order_status', ['completed', 'delivered'])
        .gte('completed_at', startOfToday.toIso8601String())
        .count(CountOption.exact);
    final ordersData = response.data;

    double total = 0.0;
    TodayEarningsRefresh.validateCompleteRows(ordersData, response.count);
    for (var o in ordersData) {
      total += double.tryParse((o['final_fare'] ?? o['current_fare'])?.toString() ?? '0') ?? 0.0;
    }
    return total;
  }

  // R1 FIX #3 (consistency pass): initialRiderDataProvider is a StateProvider written exactly
  // once, at true app cold start, and never cleared -- so `initialData != null` alone stays true
  // forever, including on every mid-session RiderHomeTab recreation (returnToLocalRideHome()'s
  // pushAndRemoveUntil rebuilds RiderMainNavigationScreen and, with it, a brand-new
  // _RiderHomeTabState). Without this flag, every recreation would keep reusing the original
  // cold-start snapshot indefinitely instead of re-fetching. `static` survives individual State
  // disposal but not a process restart, so this is false exactly once per app launch and true for
  // every subsequent _RiderHomeTabState construction within that same process. Scoped to this
  // class only -- intentionally independent of RiderMainNavigationScreen's, RiderOrdersScreen's,
  // RiderEarningsTab's, and RiderProfileTab's own identically-shaped flags.
  static bool _hasConsumedColdStartSeed = false;

  late final RideDiagnosticOwner _rideDiagnosticOwner;

  @override
  void initState() {
    super.initState();
    _rideDiagnosticOwner = RideDiagnosticOwner.widget(() => mounted, surface: RideSurface.riderHome);
    _todayEarningsRefresh = TodayEarningsRefresh(
        fetch: (scope) => _fetchTodayEarnings(scope.riderId, scope.localNow));
    _travelPlanRefresh = TravelPlanRefresh(
      currentRiderId: () => mounted && _riderProfileOwnerUserId != null &&
          _riderProfileOwnerUserId == supabase.auth.currentUser?.id &&
          serviceMode == PartnerServiceMode.intercity
          ? (rider?['id'])?.toString() : null,
      fetchPlans: (riderId) async => List<Map<String, dynamic>>.from(await supabase
          .from('rider_travel_plans').select().eq('rider_id', riderId)
          .inFilter('status', ['active', 'fully_booked']).order('travel_date', ascending: true)),
      fetchRequests: (ids) async => List<Map<String, dynamic>>.from(await supabase
          .from('intercity_requests').select('route_id, status').inFilter('route_id', ids)),
      apply: (snapshot) => setState(() {
        travelPlans = snapshot.plans;
        _planAcceptedCounts = snapshot.acceptedCounts;
        _planPendingCounts = snapshot.pendingCounts;
      }),
      onFailure: () => debugPrint('Error loading travel plans: request_failed'),
    );
    _activeOrderRefresh = ActiveOrderRefreshCoordinator(
      currentRiderId: () => mounted ? (rider?['id'])?.toString() : null,
      fetch: _fetchActiveOrders,
      apply: (result) {
        if (mounted && _activeOrderVerification.apply(rider?['id']?.toString(), result,
            orderRevision: _activeOrderRefresh.invalidationRevision)) {
          setState(() {
            activeOrders = result.orders;
          });
        }
      },
    );
    // Feature 1: start the realtime-driven unread notification badge (safe to call repeatedly).
    NotificationBadgeService.instance.startListening();
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
    final initialData = ref.read(initialRiderDataProvider);
    // R1 FIX #3 (consistency pass): the seed is only trusted on a true cold start -- present AND
    // not yet consumed this process. A mid-session recreation finds _hasConsumedColdStartSeed
    // already true and falls through to the unconditional live fetch below, exactly like every
    // other loadRider() caller.
    final seedUsable = initialData != null && initialData.belongsTo(supabase.auth.currentUser?.id) &&
        !_hasConsumedColdStartSeed;
    if (seedUsable) {
      _hasConsumedColdStartSeed = true;
      rider = initialData.rider;
      _riderProfileOwnerUserId = supabase.auth.currentUser?.id;
      if (_riderProfileOwnerUserId != null && rider?['id'] != null) {
        _todayEarningsRefresh.bindIdentity(_riderProfileOwnerUserId!, rider!['id'].toString());
      }
      _activeOrderVerification.beginIdentity(rider?['id']?.toString());
      isOnline = rider?['account_status'] == 'online';
      _initialEarningsSeed = initialData.earningsSeed;
      final scope = _currentEarningsScope;
      final grossSeed = _initialEarningsSeed != null && scope != null
          ? _todayEarningsRefresh.seedGross(_initialEarningsSeed!, scope) : null;
      if (grossSeed != null && _todayEarningsRefresh.markApplied(grossSeed, scope)) {
        todayEarnings = grossSeed.total;
        _grossEarningsScope = grossSeed.scope;
      } else if (rider?['id'] != null) {
        unawaited(_refreshEarningsOnly(rider!['id'].toString()));
      }
      loading = false;
    }
    // R1 FIX #3 (rider cold-start duplicate riders query): initialData was just applied above
    // (rider/isOnline/todayEarnings/loading), synchronously, with nothing in between that could
    // have changed it server-side -- skip re-fetching the exact same row here. Scoped to this
    // call site ONLY: every other loadRider() caller (30s silent-refresh timer, app-resume,
    // tab-visibility change, go-online, subscription purchase, etc.) is untouched and keeps
    // doing a full live fetch exactly as before.
    loadRider(skipQuery: seedUsable);
    WidgetsBinding.instance.addObserver(this);
    _startSilentRefreshTimer();
    // Perf fix (WayDrop Phase H): see _onActiveOrderScreenVisibilityChanged() below.
    ActiveOrderScreenState.isOpen.addListener(_onActiveOrderScreenVisibilityChanged);
  }

  void _startSilentRefreshTimer() {
    _riderSilentRefreshTimer?.cancel();
    // P2-A: don't run the silent refresh timer while this tab isn't the visible one -- it's purely
    // a periodic UI freshness nicety (rider stats/earnings), not something anything else depends on
    // while off-screen. Realtime subscriptions and location tracking are set up elsewhere and are
    // never touched by this.
    if (!widget.isActive) return;
    _riderSilentRefreshTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      // Perf fix (WayDrop Phase H): same "purely a UI freshness nicety" reasoning as the
      // widget.isActive gate above -- also skip while RiderActiveOrderScreen is open and covering
      // this tab, since nothing here is visible in that window either. Not cancelling/restarting
      // the timer itself (kept exactly as before) -- only its body's DB call is skipped, so the
      // very next tick after the covering screen closes resumes normal refreshing on its own,
      // in addition to the immediate reconciliation _onActiveOrderScreenVisibilityChanged already
      // does the moment it closes.
      // Egress fix: skip this background refresh if recent attempts have been
      // failing (Supabase throttle/outage) -- doesn't affect initState/resume/
      // realtime-callback calls to loadRider(), only this passive timer.
      if (mounted && !ActiveOrderScreenState.isOpen.value && _refreshBackoff.shouldAttempt()) {
        loadRider();
      }
    });
  }

  // Perf fix (WayDrop Phase H): RiderActiveOrderScreen has its own realtime subscription to this
  // exact order and already refreshes itself while open -- subscribeActiveOrder()'s callback below
  // skips its loadActiveOrder()/loadRider() calls while that screen is covering this tab, to avoid
  // duplicating work for a screen the rider isn't looking at. This is the reconciliation half: the
  // moment that screen closes (ActiveOrderScreenState.isOpen flips back to false), refresh once so
  // activeOrders/rider aren't left stale from having been skipped while it was open.
  void _onActiveOrderScreenVisibilityChanged() {
    if (!mounted) return;
    if (ActiveOrderScreenState.isOpen.value) return;
    final riderId = rider?['id']?.toString();
    if (riderId == null) return;
    loadActiveOrder(riderId);
    loadRider(skipActiveOrderReload: true);
  }

  @override
  void didUpdateWidget(covariant RiderHomeTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive != oldWidget.isActive) {
      if (widget.isActive) {
        // Tab became visible again -- refresh immediately (data may be stale from the paused
        // window) and resume the timer, mirroring the existing app-resume behavior below.
        loadRider();
        _startSilentRefreshTimer();
      } else {
        _riderSilentRefreshTimer?.cancel();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      loadRider();
    }
  }

  @override
  void dispose() {
    _rideDiagnosticOwner.dispose();
    _incomingOrderTypeRead.dispose();
    _todayEarningsRefresh.dispose();
    _riderProfileRead.dispose();
    _travelPlanRefresh.dispose();
    _pendingAssignmentRead.dispose();
    _activeOrderRefresh.dispose();
    _activeOrderVerification.dispose();
    _activeOrderEvents.clear();
    ActiveOrderScreenState.isOpen.removeListener(_onActiveOrderScreenVisibilityChanged);
    _riderSilentRefreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (riderSubId != null && riderSubChannel != null) {
      RealtimeManager.instance.unsubscribe(riderSubChannel!, riderSubId!);
    }
    if (assignmentSubId != null && assignmentSubChannel != null) {
      RealtimeManager.instance.unsubscribe(assignmentSubChannel!, assignmentSubId!);
    }
    if (activeOrderSubId != null && activeOrderSubChannel != null) {
      RealtimeManager.instance.unsubscribe(activeOrderSubChannel!, activeOrderSubId!);
    }
    if (travelPlansSubId != null && travelPlansSubChannel != null) {
      RealtimeManager.instance.unsubscribe(travelPlansSubChannel!, travelPlansSubId!);
    }
    _audioPlayer.dispose();
    super.dispose();
  }

  // PERF FIX (P4, orders-realtime full-loadRider cascade): `skipActiveOrderReload` lets a caller
  // that has *just* run loadActiveOrder() itself (subscribeActiveOrder's callback, below) opt out
  // of the exact-duplicate loadActiveOrder() call this function would otherwise make a few lines
  // below. Defaults to false so every existing call site (initState, the 30s timer, app-resume,
  // tab-visibility, subscription purchase, go-online, etc.) keeps running exactly as before --
  // this is additive only, not a behavior change for any caller that doesn't pass it.
  //
  // R1 FIX #3: `skipQuery` mirrors HomeTab (passenger)'s already-shipped `skipQuery` gate in
  // shape -- used ONLY by initState()'s own call, when initialRiderDataProvider's seed was just
  // applied synchronously with nothing in between that could have changed it server-side.
  // Defaults to false so every other caller is completely unaffected. Subscriptions,
  // loadActiveOrder(), travel-plan handling, assignment reconciliation, and live-tracking startup
  // all still run unconditionally below -- only the `riders`/`orders` fetch and its `setState` are
  // skipped, since the seed already populated `rider`/isOnline/todayEarnings/loading.
  Future<void> loadRider({bool skipActiveOrderReload = false, bool skipQuery = false}) async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;

      if (_offlineStatusUserId != user.id) {
        final changedIdentity = _offlineStatusUserId != null;
        if (changedIdentity) _travelPlanRefresh.invalidate();
        if (changedIdentity) _todayEarningsRefresh.retireIdentity();
        _offlineStatusUserId = user.id;
        _offlineStatusEvidence.resetIdentity();
        if (changedIdentity) _offlineStatusEvidence.markUnknown();
      }

      final statusReadRevision = _offlineStatusEvidence.readRevision;

      if (!skipQuery) {
        final profileRevision = _riderProfileRead.prepare(user.id, statusReadRevision);
        // Egress fix: narrowed from `*` to the exact columns this screen reads
        // (grepped exhaustively across every `rider?['...']`/`rider!['...']`
        // access in this file) -- `riders` also carries current_lat/lng,
        // heading, cod_pending_amount, government_tax_due_balance, timestamps
        // etc. that this tab never touches, and this query runs on initState,
        // the 30s silent-refresh timer, app resume, and every realtime callback.
        final data = await _riderProfileRead.read(user.id, () async => await supabase
            .from('riders')
            .select('''
              id,
              account_status,
              service_mode,
              subscription_active,
              subscription_expires_at,
              free_trial_started_at,
              free_trial_expires_at,
              free_trial_used,
              wallet_balance,
              rider_kyc!riders_kyc_id_fkey(
                full_name,
                rider_image
              )
            ''')
            .eq('user_id', user.id)
            .maybeSingle());
        if (!mounted || supabase.auth.currentUser?.id != user.id ||
            !_offlineStatusEvidence.acceptsRead(statusReadRevision) ||
            !_riderProfileRead.isCurrent(user.id, profileRevision)) {
          return;
        }

        EarningsSnapshot? earningsSnapshot;
        if (data != null) {
          final kyc = data['rider_kyc!riders_kyc_id_fkey'] ?? data['rider_kyc'];
          if (kyc is Map) {
            data['full_name'] = kyc['full_name'];
            data['rider_image'] = kyc['rider_image'];
          }

          _todayEarningsRefresh.bindIdentity(user.id, data['id'].toString());
          try {
            earningsSnapshot = await _readTodayEarnings(data['id'].toString());
          } catch (_) {
            debugPrint('Error calculating today earnings: request_failed');
          }
        } else {
          _todayEarningsRefresh.retireIdentity();
        }

        if (!mounted || supabase.auth.currentUser?.id != user.id ||
            !_offlineStatusEvidence.acceptsRead(statusReadRevision) ||
            !_riderProfileRead.isCurrent(user.id, profileRevision)) {
          return;
        }
        // A fresh existing read can resolve a lost acknowledgement. If it
        // confirms offline, retire restored tracking before publishing that state.
        if (_offlineStatusEvidence.unknown && data?['account_status'] == 'offline') {
          await LocationCacheService.stopRiderLiveTracking();
          if (!mounted || supabase.auth.currentUser?.id != user.id ||
              !_offlineStatusEvidence.acceptsRead(statusReadRevision) ||
              !_riderProfileRead.isCurrent(user.id, profileRevision)) {
            return;
          }
        }
        setState(() {
          _riderProfileRead.applied();
          if (rider?['id'] != data?['id']) {
            _activeOrderRefresh.invalidate();
            _travelPlanRefresh.invalidate();
            travelPlans = [];
            _planAcceptedCounts = {};
            _planPendingCounts = {};
            loadingPlans = false;
            _activeOrderEvents.clear();
            _activeOrderVerification.beginIdentity(data?['id']?.toString());
            _trackingRecoveryFailure = null;
            todayEarnings = 0.0;
            _grossEarningsScope = null;
            _initialEarningsSeed = null;
            _offlineStatusEvidence.resetIdentity();
            activeOrders = [];
          }
          rider = data;
          _riderProfileOwnerUserId = user.id;
          _offlineStatusEvidence.confirmRead(
              _offlineStatusEvidence.readRevision, rider?['account_status']);
          isOnline = !_offlineStatusEvidence.unknown && rider?['account_status'] == 'online';
          if (data == null) todayEarnings = 0.0;
          if (earningsSnapshot != null &&
              _todayEarningsRefresh.markApplied(earningsSnapshot, _currentEarningsScope)) {
            todayEarnings = earningsSnapshot.total;
            _grossEarningsScope = earningsSnapshot.scope;
          }
          loading = false;
        });
      }
      if (rider != null) {
        subscribeRider(rider!['id']);
        subscribeAssignments(rider!['id']);
        subscribeActiveOrder(rider!['id']);
        if (!skipActiveOrderReload) {
          loadActiveOrder(rider!['id']);
        }
        // Travel Plans are an Intercity Traveller-mode concept only — a
        // Local City Partner never subscribes to or loads them, so the
        // "Intercity Travel Plans" section never renders/updates for them.
        // Toggled on every load so a Service Mode switch (see
        // _refreshAfterServiceModeChange) immediately subscribes/unsubscribes
        // this channel instead of leaving a stale one running.
        if (serviceMode == PartnerServiceMode.intercity) {
          subscribeTravelPlans(rider!['id']);
          loadTravelPlans(rider!['id']);
        } else {
          _unsubscribeTravelPlans();
        }
        // Realtime sockets are commonly suspended while the app is backgrounded and Postgres
        // Changes has no replay/backlog for whatever was missed during that gap, so every path
        // that reaches here (init, foreground resume, the 30s silent refresh) also reconciles any
        // already-"sent" assignment that never got its own INSERT event shown -- instead of the
        // driver only finding out a request was waiting once it's already expired.
        // _reconcilePendingAssignments() below also updates the active-assignments badge from the
        // same fetched rows (Performance Roadmap Task 2) -- it and _updateActiveAssignmentsBadge()
        // used to each run their own independent query against the identical rider_assignments
        // rows (rider_id=X, assignment_status='sent') on every loadRider() call; merged into one
        // fetch since _reconcilePendingAssignments' select is already a superset of what the badge
        // count needs. subscribeAssignments' realtime callback still calls
        // _updateActiveAssignmentsBadge() on its own, unchanged -- no fetched rows are available to
        // reuse there without also running the reconcile/announce logic on every realtime tick,
        // which would change when incoming-order sheets can appear.
        _reconcilePendingAssignments(rider!['id']);
        if (isOnline) {
          LocationCacheService.startRiderLiveTracking();
        }
      }
      _refreshBackoff.recordSuccess();
    } catch (e) {
      debugPrint('Error in loadRider: $e');
      _refreshBackoff.recordFailure();
      if (mounted) setState(() => loading = false);
    }
  }

  // See loadRider() -- surfaces a "sent" assignment this device hasn't already shown/announced,
  // e.g. one delivered by start-dispatch while the realtime channel was disconnected/backgrounded.
  // Never shows an order the passenger cancelled or another rider already accepted (order_status
  // filter), and never re-shows one already popped up or already responded to (_announcedOrders /
  // assignment_status filter) -- so this can never double-notify alongside the live realtime path.
  // Shared by _reconcilePendingAssignments() and _updateActiveAssignmentsBadge() (Performance
  // Roadmap Task 2) -- both need every 'sent' rider_assignments row for this rider joined with its
  // order's status; they used to each fetch it independently.
  // Egress fix: narrowed from `*, orders(order_status)` to the exact fields both callers (and
  // _showIncomingOrder, which receives a row from this result) read -- order_id, expires_at, and
  // the joined order_status. order_type added alongside it so _showIncomingOrder can tell a local
  // ride/parcel apart from an intercity match and gate the local incoming-ride sound accordingly
  // (rider_assignments itself has no order_type column -- it's a shared offer ledger for both
  // local dispatch and intercity manual offers -- so this join is the only source for it here).
  Future<List<Map<String, dynamic>>> _fetchPendingSentAssignments(String riderId) async {
    return _pendingAssignmentRead.read(riderId, () async {
    final rows = await supabase
        .from('rider_assignments')
        .select('order_id, expires_at, orders(order_status, order_type)')
        .eq('rider_id', riderId)
        .eq('assignment_status', 'sent');
    return (rows as List).cast<Map<String, dynamic>>();
    });
  }

  void _updateActiveAssignmentsBadgeFromRows(List<Map<String, dynamic>> rows) {
    final now = DateTime.now();
    int activeCount = 0;
    for (final assignment in rows) {
      final expiresAtStr = assignment['expires_at']?.toString();
      final order = assignment['orders'] as Map<String, dynamic>?;

      final orderStatus = order?['order_status'];
      if (order != null && (orderStatus == 'searching' || orderStatus == 'created')) {
        if (expiresAtStr != null) {
          final expiresAt = DateTime.tryParse(expiresAtStr);
          if (expiresAt != null && now.isAfter(expiresAt)) {
            continue; // expired
          }
        }
        activeCount++;
      }
    }

    if (mounted) {
      ref.read(activeAssignmentsCountProvider.notifier).state = activeCount;
    }
  }

  Future<void> _reconcilePendingAssignments(String riderId) async {
    if (!mounted || rider?['id']?.toString() != riderId) return;
    final revision = _pendingAssignmentRead.revisionFor(riderId);
    debugPrint('[INSTR-HOME] ${DateTime.now().toIso8601String()} _reconcilePendingAssignments() CALLED for riderId=$riderId');
    try {
      final rows = await _fetchPendingSentAssignments(riderId);
      if (!mounted || rider?['id']?.toString() != riderId ||
          revision != _pendingAssignmentRead.revisionFor(riderId)) {
        return;
      }
      debugPrint('[INSTR-HOME] ${DateTime.now().toIso8601String()} _reconcilePendingAssignments() SQL returned ${rows.length} row(s) with assignment_status=sent');
      _updateActiveAssignmentsBadgeFromRows(rows);

      final now = DateTime.now();
      for (final row in rows) {
        final orderId = row['order_id']?.toString();
        if (orderId == null || _announcedOrders.contains(orderId)) continue;

        final expiresAtStr = row['expires_at']?.toString();
        if (expiresAtStr != null) {
          final expiresAt = DateTime.tryParse(expiresAtStr);
          if (expiresAt != null && now.isAfter(expiresAt)) continue;
        }

        final order = row['orders'] as Map<String, dynamic>?;
        final orderStatus = order?['order_status']?.toString();
        if (orderStatus != 'searching' && orderStatus != 'created') continue;

        if (!mounted) return;
        // No `break` here: _showIncomingOrder is now sound/haptic + badge only (no modal), so every
        // pending unannounced assignment can be announced in the same pass -- multiple simultaneous
        // incoming rides are expected and already rendered as separate cards in the Orders tab.
        _showIncomingOrder(row);
      }
    } catch (e) {
      debugPrint('Error reconciling pending assignments: $e');
    }
  }

  Future<void> loadActiveOrder(String riderId) =>
      _activeOrderRefresh.request(riderId);

  Future<ActiveOrderReconciliation> _fetchActiveOrders(String riderId) async {
      // Egress fix audit: deliberately left broad, not narrowed. The result (`activeOrders`) is
      // passed wholesale into TravelPlanDetailsScreen as `activeOrder:` (see _showTravelPlanDetails
      // below) -- the same ~2500-line, 30+-field screen already flagged unsafe to narrow for in
      // realtime_order_controller.dart's fetchOrder(). Narrowing this select safely would require
      // a dedicated full audit of that screen's field usage first.
      final rows = await supabase
          .from('orders')
          .select('*, users(full_name, gender, profile_photo_url)')
          .eq('rider_id', riderId)
          .inFilter('order_status', ['accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing', 'payment_pending']);
      final orderRows = (rows as List).cast<Map<String, dynamic>>();
      final reconciliation = _activeOrderEvents.reconcile(orderRows, activeOrders, _isOrderActivelyBusy);
      final busyRows = reconciliation.orders;
      // [TRACE_ACTIVEORDER] TEMPORARY diagnostic instrumentation -- investigating "Active Ride In
      // Progress" staying stuck after a rider cancels an accepted order. Delete after root-cause
      // capture.
      debugPrint(
        '[TRACE_ACTIVEORDER] RiderHomeTab.loadActiveOrder() riderId=$riderId fetched ${busyRows.length} '
        'active row(s): ${busyRows.map((e) => '${e['id']}:${e['order_status']}').toList()} '
        'epoch=${DateTime.now().millisecondsSinceEpoch}',
      );
      return reconciliation;
  }

  // Mirrors public.rider_is_on_active_trip(): a local job is busy the instant it's accepted, but
  // an intercity/long-distance job accepted-but-"Waiting for Travel Day" (trip_started_at still
  // null) is only a future reservation, not an active job — it must not surface here as "your
  // current order" or block going offline / accepting a different job.
  bool _isOrderActivelyBusy(Map<String, dynamic> order) => isRiderOrderActivelyBusy(order);

  String? _subscribedRiderId;

  void subscribeRider(String riderId) {
    final subscribedUserId = supabase.auth.currentUser?.id;
    if (_subscribedRiderId == riderId) return;
    _subscribedRiderId = riderId;
    if (riderSubId != null && riderSubChannel != null) {
      RealtimeManager.instance.unsubscribe(riderSubChannel!, riderSubId!);
      riderSubId = null;
      riderSubChannel = null;
    }
    riderSubChannel = 'rider-home-$riderId';
    riderSubId = RealtimeManager.instance.subscribe(
      channelName: riderSubChannel!,
      table: 'riders',
      owner: 'RiderHomeTab_Rider',
      event: PostgresChangeEvent.update,
      schema: 'public',
      filterColumn: 'id',
      filterValue: riderId,
      callback: (payload) async {
        if (!mounted || supabase.auth.currentUser?.id != subscribedUserId ||
            rider?['id']?.toString() != riderId) {
          return;
        }
        final data = payload.newRecord;

        // PERF FIX (rider-location-realtime-fanout, Phase 1): during an active ride, GPS pushes a
        // `riders` UPDATE roughly every 10-30s (LocationCacheService.updateRiderLocation()'s
        // 10m-movement-OR-30s-heartbeat gate) that only ever touches _locationHeartbeatFields.
        // Re-running the full "sum today's completed orders" query and rebuilding this whole tab
        // on every one of those writes was pure waste -- nothing here (isOnline, todayEarnings,
        // subscription badges, profile info) can change as a result of a pure location write.
        // `oldRecord` is populated because `riders` has REPLICA IDENTITY FULL (confirmed live), so
        // the actual changed columns are diffed directly instead of guessed. Any column outside
        // the known-safe set -- account_status, total_earnings, subscription_*, cod_*, etc. --
        // falls through to the exact original behavior below, unchanged.
        final oldData = payload.oldRecord;
        final isLocationOnlyUpdate = oldData.isNotEmpty &&
            data.keys.every((key) =>
                !oldData.containsKey(key) ||
                oldData[key] == data[key] ||
                _locationHeartbeatFields.contains(key));

        if (isLocationOnlyUpdate) {
          // Keep the cached rider map's fields current for anything that reads them later, without
          // triggering a rebuild for a change nothing on this tab visibly depends on.
          if (rider != null) {
            rider = {...rider!, ...data};
          }
          return;
        }
        final profileUserId = supabase.auth.currentUser?.id;
        if (profileUserId == null || rider?['id']?.toString() != riderId) return;
        final profileRevision = _riderProfileRead.invalidate(profileUserId);
        final applicationRevision = _riderProfileRead.applicationRevision;
        if (oldData.isEmpty || oldData['service_mode'] != data['service_mode']) {
          _travelPlanRefresh.invalidate();
        }

        // PERF FIX (P1, WayDrop duplicate-realtime audit): a non-location `riders` change (e.g. a
        // plain Go Online/Offline toggle, which only ever writes account_status) previously still
        // ran the full today's-earnings requery unconditionally below, even though nothing about
        // account_status (or service_mode, subscription_*, rating, kyc_id, etc.) can affect what
        // was earned today. Only re-run it when at least one of the columns
        // credit_rider_for_completed_order() actually writes on a real completion
        // (_earningsRelevantFields, see its declaration above) is among the changed keys. Same
        // conservative fallback as isLocationOnlyUpdate above: if oldData is empty (no diff
        // available), every key in `data` counts as "changed", so this still refreshes rather than
        // silently skipping when the true diff can't be determined.
        final changedKeys = data.keys
            .where((key) => !oldData.containsKey(key) || oldData[key] != data[key]);
        final isEarningsRelevantUpdate = changedKeys.any(_earningsRelevantFields.contains);

        EarningsSnapshot? earningsSnapshot;
        if (isEarningsRelevantUpdate) {
          _initialEarningsSeed = null;
          _todayEarningsRefresh.invalidate();
          try {
            earningsSnapshot = await _readTodayEarnings(data['id'].toString());
          } catch (_) {
            debugPrint('Error calculating today earnings: request_failed');
          }
        }

        if (!mounted || supabase.auth.currentUser?.id != profileUserId ||
            rider?['id']?.toString() != riderId ||
            !_riderProfileRead.isCurrent(profileUserId, profileRevision) ||
            _riderProfileRead.applicationRevision != applicationRevision) {
          return;
        }
        setState(() {
          _riderProfileRead.applied();
          if (rider != null) {
            rider = {
              ...rider!,
              ...data,
            };
          } else {
            rider = data;
          }
          // Realtime callbacks may have been queued before the failed write;
          // they cannot resolve its outcome without a fresh profile read.
          isOnline = !statusUpdating && !_offlineStatusEvidence.unknown &&
              rider?['account_status'] == 'online';
          if (earningsSnapshot != null &&
              _todayEarningsRefresh.markApplied(earningsSnapshot, _currentEarningsScope)) {
            todayEarnings = earningsSnapshot.total;
            _grossEarningsScope = earningsSnapshot.scope;
          }
        });
      },
    );
  }

  // Standalone entry point for subscribeAssignments()'s realtime callback, which has no
  // already-fetched rows to reuse -- kept on its own original, narrower query (unchanged). Only
  // the counting logic below is shared with _reconcilePendingAssignments() (Performance Roadmap
  // Task 2), which fetches the superset select it already needs and reuses that same logic instead
  // of this function's query.
  Future<void> _updateActiveAssignmentsBadge(String rId) async {
    if (!mounted || rider?['id']?.toString() != rId) return;
    final revision = _pendingAssignmentRead.revisionFor(rId);
    try {
      final data = await _fetchPendingSentAssignments(rId);
      if (!mounted || rider?['id']?.toString() != rId ||
          revision != _pendingAssignmentRead.revisionFor(rId)) {
        return;
      }
      _updateActiveAssignmentsBadgeFromRows(data);
    } catch (e) {
      debugPrint('Error updating active assignments badge: $e');
    }
  }

  void subscribeAssignments(String riderId) {
    if (_subscribedAssignmentsRiderId == riderId) return;
    _subscribedAssignmentsRiderId = riderId;
    if (assignmentSubId != null && assignmentSubChannel != null) {
      RealtimeManager.instance.unsubscribe(assignmentSubChannel!, assignmentSubId!);
      assignmentSubId = null;
      assignmentSubChannel = null;
    }
    assignmentSubChannel = 'rider-assignments-$riderId';
    debugPrint('[INSTR-HOME] ${DateTime.now().toIso8601String()} calling RealtimeManager.subscribe() channel=$assignmentSubChannel table=rider_assignments owner=RiderHomeTab_Assignments filterColumn=rider_id filterValue=$riderId');
    assignmentSubId = RealtimeManager.instance.subscribe(
      channelName: assignmentSubChannel!,
      table: 'rider_assignments',
      owner: 'RiderHomeTab_Assignments',
      event: PostgresChangeEvent.all,
      schema: 'public',
      filterColumn: 'rider_id',
      filterValue: riderId,
      callback: (payload) {
        _rideDiagnosticOwner.receipt(payload.newRecord['order_id'] ?? payload.oldRecord['order_id'],
          endpoint: RideEndpoint.assignmentFeed);
        debugPrint('[INSTR-HOME] ${DateTime.now().toIso8601String()} rider_assignments REALTIME EVENT RECEIVED (RiderHomeTab) => type=${payload.eventType}, orderId=${payload.newRecord['order_id']}, status=${payload.newRecord['assignment_status']}, mounted=$mounted');
        if (!mounted || rider?['id']?.toString() != riderId) return;
        _pendingAssignmentRead.invalidate(riderId);

        // Compute and update server clock skew to eliminate client-side skew
        if (payload.eventType == PostgresChangeEvent.insert) {
          final sentAtStr = payload.newRecord['sent_at']?.toString() ?? payload.newRecord['created_at']?.toString();
          if (sentAtStr != null) {
            final sentAt = DateTime.tryParse(sentAtStr);
            if (sentAt != null) {
              LocationCacheService.serverClockSkew = DateTime.now().difference(sentAt);
            }
          }
        }
        
        _updateActiveAssignmentsBadge(riderId);

        if (payload.eventType == PostgresChangeEvent.insert) {
          final assignment = payload.newRecord;
          final orderId = assignment['order_id']?.toString();
          // Guard against a duplicate INSERT delivery (e.g. a realtime reconnect replay racing
          // the foreground-resume reconciliation in loadRider()) showing a second incoming-order
          // sheet for the same order.
          final alreadyAnnounced = orderId != null && _announcedOrders.contains(orderId);
          if (assignment['assignment_status'] == 'sent' && !alreadyAnnounced) {
            // The realtime INSERT payload is the raw rider_assignments row -- Postgres realtime
            // never joins across tables, and this table has no order_type column of its own (it's
            // a shared offer ledger for local dispatch AND intercity manual offers). Resolve the
            // matched order's order_type here so _showIncomingOrder can gate the local
            // incoming-ride sound to local orders only, instead of playing it for every match.
            _resolveOrderTypeAndShowIncomingOrder(assignment);
          }
        } else if (payload.eventType == PostgresChangeEvent.update) {
          final assignment = payload.newRecord;
          final status = assignment['assignment_status']?.toString();
          if (status == 'accepted_by_user') {
            HapticFeedback.heavyImpact();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('User accepted your offer! Confirm to start delivery.'),
                backgroundColor: Colors.green,
              ),
            );
          }
          if (['accepted', 'rejected', 'expired', 'completed', 'cancelled'].contains(status)) {
            final orderId = assignment['order_id']?.toString();
            if (orderId != null) {
              _announcedOrders.remove(orderId);
            }
          }
          // Trigger reload
          setState(() {});
        }
      },
    );
  }

  void subscribeActiveOrder(String riderId) {
    if (_subscribedActiveOrderRiderId == riderId) return;
    _subscribedActiveOrderRiderId = riderId;
    if (activeOrderSubId != null && activeOrderSubChannel != null) {
      RealtimeManager.instance.unsubscribe(activeOrderSubChannel!, activeOrderSubId!);
      activeOrderSubId = null;
      activeOrderSubChannel = null;
    }
    activeOrderSubChannel = 'rider-active-order-$riderId';
    activeOrderSubId = RealtimeManager.instance.subscribe(
      channelName: activeOrderSubChannel!,
      table: 'orders',
      owner: 'RiderHomeTab_ActiveOrder',
      event: PostgresChangeEvent.all,
      schema: 'public',
      filterColumn: 'rider_id',
      filterValue: riderId,
      callback: (payload) async {
        if (!mounted) return;
        _rideDiagnosticOwner.receipt(payload.newRecord['id'] ?? payload.oldRecord['id'],
          status: payload.newRecord['order_status'], version: payload.newRecord['updated_at']);
        final record = payload.newRecord;
        final oldRecord = payload.oldRecord;
        if (rider?['id']?.toString() != riderId) return;
        final earningsChanged = TodayEarningsRefresh.orderEventAffectsEarnings(record, oldRecord);
        if (earningsChanged) {
          _initialEarningsSeed = null;
          _todayEarningsRefresh.invalidate();
        }
        _activeOrderRefresh.invalidate();
        _pendingAssignmentRead.invalidate(riderId);
        _activeOrderEvents.record(record, oldRecord,
            deleted: payload.eventType == PostgresChangeEvent.delete);
        final orderId = record['id']?.toString();
        final orderStatus = record['order_status']?.toString();
        // [TRACE_ACTIVEORDER] TEMPORARY diagnostic instrumentation -- investigating "Active Ride
        // In Progress" staying stuck after a rider cancels an accepted order. Delete after
        // root-cause capture.
        debugPrint(
          '[TRACE_ACTIVEORDER] RiderHomeTab.subscribeActiveOrder() CALLBACK FIRED orderId=$orderId '
          'newStatus=$orderStatus newRiderId=${record['rider_id']} epoch=${DateTime.now().millisecondsSinceEpoch}',
        );
        if (orderId != null && ['completed', 'delivered', 'cancelled'].contains(orderStatus)) {
          _announcedOrders.remove(orderId);
        }
        // Perf fix (WayDrop Phase H): RiderActiveOrderScreen already has its own realtime
        // subscription to this exact order (filtered by id instead of rider_id) and refreshes
        // itself on every one of these same events -- while it's open and covering this tab,
        // re-running the identical loadActiveOrder()/loadRider() queries here (plus rebuilding this
        // off-screen tab) is pure duplicated work. Skipped here; reconciled once via
        // _onActiveOrderScreenVisibilityChanged() the moment that screen closes, so nothing here
        // stays stale. The subscription itself stays live either way -- only these two calls are
        // gated.
        if (!ActiveOrderScreenState.isOpen.value) {
          if (earningsChanged) unawaited(_refreshEarningsOnly(riderId));
          // loadActiveOrder() is unconditional -- it's the only thing that keeps `activeOrders`
          // (rider-visible active-order UI) correct, and it must run on every event regardless of
          // which column changed, exactly as before.
          //
          // ROOT CAUSE FIX (new pending order silently never announced after the current ride
          // completes): this used to fire loadActiveOrder() without awaiting it, then immediately
          // (same synchronous tick) trigger loadRider()/_reconcilePendingAssignments() below --
          // which calls _showIncomingOrder() for any already-pending 'sent' assignment (e.g. one
          // matched to this rider while they were busy, or one whose realtime INSERT the client
          // missed). _showIncomingOrder() gates on `activeOrders.isNotEmpty` to never announce while
          // busy -- but activeOrders was still the STALE value from before this exact completion
          // event, since loadActiveOrder()'s own setState() hadn't landed yet. On a completion
          // event, that race made _showIncomingOrder() see a non-empty (stale) activeOrders, skip
          // the announcement, and -- critically -- return BEFORE marking the order as announced, so
          // nothing else was guaranteed to ever re-surface it. Awaiting loadActiveOrder() here
          // guarantees `activeOrders` reflects the just-completed ride (now free) before any
          // pending-assignment reconciliation below evaluates that guard.
          await loadActiveOrder(riderId);
          if (!mounted) return;

          // PERF FIX (P4, orders-realtime full-loadRider cascade): loadRider() additionally
          // re-fetches rider profile/KYC (unrelated to this order), recomputes today's earnings
          // (only actually changes when a completion just wrote it), and refreshes intercity
          // travel plans (unrelated to this order) -- none of which depend on most `orders`
          // columns (fare edits, distance_meters recompute, OTP writes, address edits, chat/typing
          // fields, etc.). `order_status` is the one column whose change genuinely drives all of
          // that: it's what flips an order busy/free (activeOrders composition, already covered by
          // loadActiveOrder() above) and what credit_rider_for_completed_order() gates on for a
          // completion (earnings). `orders` has REPLICA IDENTITY FULL (confirmed in the baseline
          // schema migration, same precondition subscribeRider's own diffing already relies on),
          // so oldRecord is populated in practice; if it's ever empty (diff unavailable), this
          // falls through to the original unconditional-reload behavior instead of silently
          // skipping -- same conservative-default pattern as subscribeRider's gating above.
          final orderStatusChanged =
              oldRecord.isEmpty || oldRecord['order_status'] != record['order_status'];

          if (orderStatusChanged) {
            // loadActiveOrder() was already just run above -- skip loadRider()'s own internal
            // duplicate of that exact same query. loadRider() still runs
            // _reconcilePendingAssignments() internally, so it's not duplicated below.
            loadRider(skipActiveOrderReload: true);
          } else {
            // Not escalating to the full cascade, but loadRider() was previously reachable from
            // ANY orders event and is the only thing that invoked assignment reconciliation here
            // -- preserve that specific side effect explicitly instead of losing it. This is the
            // same narrow, single-table query _reconcilePendingAssignments() always was; it is not
            // part of the cascade being gated out.
            _reconcilePendingAssignments(riderId);
          }
        }
      },
    );
  }

  void subscribeTravelPlans(String riderId) {
    if (_subscribedTravelPlansRiderId == riderId) return;
    _subscribedTravelPlansRiderId = riderId;
    if (travelPlansSubId != null && travelPlansSubChannel != null) {
      RealtimeManager.instance.unsubscribe(travelPlansSubChannel!, travelPlansSubId!);
      travelPlansSubId = null;
      travelPlansSubChannel = null;
    }
    travelPlansSubChannel = 'rider-travel-plans-$riderId';
    travelPlansSubId = RealtimeManager.instance.subscribe(
      channelName: travelPlansSubChannel!,
      table: 'rider_travel_plans',
      owner: 'RiderHomeTab_TravelPlans',
      event: PostgresChangeEvent.all,
      schema: 'public',
      filterColumn: 'rider_id',
      filterValue: riderId,
      callback: (payload) {
        if (!mounted || rider?['id']?.toString() != riderId) return;
        _travelPlanRefresh.invalidate();
        loadTravelPlans(riderId);
      },
    );
  }

  void _unsubscribeTravelPlans() {
    _travelPlanRefresh.invalidate();
    if (travelPlansSubId != null && travelPlansSubChannel != null) {
      RealtimeManager.instance.unsubscribe(travelPlansSubChannel!, travelPlansSubId!);
      travelPlansSubId = null;
      travelPlansSubChannel = null;
    }
    _subscribedTravelPlansRiderId = null;
  }

  // Production-grade incoming ride experience (replaces the old blocking full-screen popup):
  // announce a new assignment with sound + haptic only, never a modal. The assignment already
  // lives in rider_assignments with assignment_status='sent', which the Orders tab
  // (rider_orders_screen.dart) lists directly -- countdown, Accept/Reject and all -- and the Orders
  // tab's bottom-nav badge (activeAssignmentsCountProvider, updated independently by
  // _updateActiveAssignmentsBadge) already reflects the count. This mirrors how Uber/Rapido/Blinkit
  // Partner surface new requests: a sound + a badge on the requests list, never a takeover dialog
  // that blocks map/navigation use, and it naturally supports any number of simultaneous incoming
  // rides since the Orders tab already renders one card per pending assignment.
  // Resolves the matched order's order_type (not present on the raw rider_assignments realtime
  // payload -- see subscribeAssignments()) before announcing, so the local incoming-ride
  // haptic+sound never fires for an intercity match. A single narrow lookup, fired only for a
  // genuinely new unannounced 'sent' assignment, so it doesn't add meaningful egress.
  Future<void> _resolveOrderTypeAndShowIncomingOrder(Map<String, dynamic> assignment) async {
    final userId = supabase.auth.currentUser?.id;
    final riderId = rider?['id']?.toString();
    if (!mounted || userId == null || riderId == null ||
        _riderProfileOwnerUserId != userId) {
      return;
    }
    final orderId = assignment['order_id']?.toString();
    String? orderType;
    if (orderId != null) {
      try {
        orderType = await _incomingOrderTypeRead.read(
          userId: userId, riderId: riderId, orderId: orderId,
          fetch: () async => await supabase.from('orders').select('order_type').eq('id', orderId).maybeSingle(),
        );
      } catch (_) {
        debugPrint('Error resolving incoming order type: request_failed');
      }
    }
    if (!mounted || supabase.auth.currentUser?.id != userId ||
        rider?['id']?.toString() != riderId || _riderProfileOwnerUserId != userId) {
      return;
    }
    _showIncomingOrder(assignment, orderType: orderType);
  }

  void _showIncomingOrder(Map<String, dynamic> assignment, {String? orderType}) {
    // Partial evidence cannot prove that the rider is free.
    if (_activeOrderEvidenceUnresolved) return;
    debugPrint('[INSTR-HOME] ${DateTime.now().toIso8601String()} _showIncomingOrder() ENTERED for orderId=${assignment['order_id']}, activeOrders.length=${activeOrders.length}');
    // A busy rider (already has an active order) must never be announced a new incoming order.
    // start-dispatch/find_nearby_riders already excludes busy riders from new assignments, but
    // this guards the client paths that can surface an older 'sent' assignment (app-resume
    // reconciliation, realtime reconnect replay) after the rider became busy in the meantime.
    if (activeOrders.isNotEmpty) {
      debugPrint('[INSTR-HOME] ${DateTime.now().toIso8601String()} _showIncomingOrder() SKIPPED -- rider has ${activeOrders.length} active order(s)');
      return;
    }

    final orderId = assignment['order_id']?.toString();
    if (orderId != null) {
      if (_announcedOrders.contains(orderId)) {
        debugPrint('[INSTR-HOME] ${DateTime.now().toIso8601String()} _showIncomingOrder() SKIPPED -- orderId=$orderId already in _announcedOrders');
        return;
      }
      _announcedOrders.add(orderId);
    }

    // _fetchPendingSentAssignments()'s reconciliation path joins order_type directly onto the row
    // (assignment['orders']['order_type']); the realtime INSERT path passes it explicitly via the
    // `orderType` param instead, since that payload has no join. An unresolved/unknown type (e.g.
    // the lookup failed) defaults to treating it as local, so a lookup failure can never silently
    // suppress the existing local-ride sound -- it can only ever suppress a *confirmed* intercity
    // match.
    final resolvedOrderType =
        orderType ?? (assignment['orders'] as Map<String, dynamic>?)?['order_type']?.toString();
    final isKnownIntercity = resolvedOrderType == 'intercity_ride' || resolvedOrderType == 'intercity_parcel';
    if (isKnownIntercity) {
      debugPrint(
        '[INSTR-HOME] ${DateTime.now().toIso8601String()} _showIncomingOrder() orderId=$orderId is '
        'order_type=$resolvedOrderType -- SKIPPING local incoming-ride haptic+sound',
      );
      return;
    }

    debugPrint('[INSTR-HOME] ${DateTime.now().toIso8601String()} _showIncomingOrder() FIRING haptic+sound for orderId=$orderId');
    HapticFeedback.heavyImpact();
    _playOrderNearbySoundThrottled();
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
      debugPrint('Error playing in-app sound on home tab: $e');
    }
  }

  Future<void> toggleOnlineStatus() async {
    if (statusUpdating || _offlineStatusEvidence.unknown) return;
    
    final newStatus = isOnline ? 'offline' : 'online';

    // 1. If going offline, block if there's any active order
    if (newStatus == 'offline') {
      if (_activeOrderEvidenceUnresolved || activeOrders.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot go offline while you have an active order.'),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }

      // Show confirmation sheet
      final offlineOperation = _activeOrderVerification.captureOfflineContext(
        riderId: rider?['id']?.toString(),
        userId: supabase.auth.currentUser?.id,
        hasActiveOrders: activeOrders.isNotEmpty,
        orderRevision: _activeOrderRefresh.invalidationRevision,
      );
      if (offlineOperation == null) return;
      bool stillPermitted() => mounted && _activeOrderVerification.permitsOffline(
        offlineOperation,
        riderId: rider?['id']?.toString(),
        userId: supabase.auth.currentUser?.id,
        hasActiveOrders: activeOrders.isNotEmpty,
        orderRevision: _activeOrderRefresh.invalidationRevision,
      );
      final confirm = await showModalBottomSheet<bool>(
        context: context,
        backgroundColor: darkCard,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
        builder: (_) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.shrink(),
              const SizedBox(height: 20),
              Container(
                width: 64, height: 64,
                decoration: BoxDecoration(color: const Color(0xFF3B1E1E), borderRadius: BorderRadius.circular(20)),
                child: const Icon(Icons.power_settings_new_rounded, color: Color(0xFFEF4444), size: 30),
              ),
              const SizedBox(height: 16),
              const Text('Go Offline?', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.white)),
              const SizedBox(height: 6),
              const Text('You will stop receiving orders', style: TextStyle(fontSize: 13, color: textGray)),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, false),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white24),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        minimumSize: const Size.fromHeight(52),
                      ),
                      child: const Text('Cancel', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryLime,
                        foregroundColor: Colors.black,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        minimumSize: const Size.fromHeight(52),
                      ),
                      child: const Text('Go Offline', style: TextStyle(fontWeight: FontWeight.w800, color: Colors.black)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      if (confirm != true || statusUpdating || !isOnline || !stillPermitted()) return;
      var offlineWriteAttempted = false;
      try {
        HapticFeedback.mediumImpact();
        statusUpdating = true;
        _offlineStatusEvidence.beginWrite();
        setState(() {
          isOnline = false;
          if (rider != null) {
            rider!['account_status'] = 'offline';
          }
        });

        await LocationCacheService.stopRiderLiveTracking();

        // Never target a different session or act on an expired order context.
        if (!stillPermitted()) throw StateError('Offline operation context changed');

        offlineWriteAttempted = true;
        await supabase.from('riders').update({
          'account_status': 'offline',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('user_id', offlineOperation.userId);
      } catch (_) {
        bool ownsRollback() => mounted && _activeOrderVerification.sameOfflineIdentity(
            offlineOperation, rider?['id']?.toString(), supabase.auth.currentUser?.id);
        if (ownsRollback() && offlineWriteAttempted) {
          setState(() {
            _offlineStatusEvidence.markUnknown();
            isOnline = false;
          });
        }
        final recovery = await restoreOfflineTracking(
          isCurrentIdentity: ownsRollback,
          isTrackingActive: () => LocationCacheService.isRiderLiveTrackingActive,
          restartTracking: () => LocationCacheService.startRiderLiveTracking(canStart: ownsRollback),
          stopIncompleteTracking: () => LocationCacheService.stopRiderLiveTracking(),
        );
        if (mounted && ownsRollback()) {
          final restored = recovery == OfflineTrackingRollback.restored &&
              LocationCacheService.isRiderLiveTrackingActive;
          setState(() {
            isOnline = _offlineStatusEvidence.permitsOnline(restored);
            _trackingRecoveryFailure = restored ? null : offlineOperation;
            if (rider != null && !_offlineStatusEvidence.unknown) {
              rider!['account_status'] = restored ? 'online' : 'offline';
            }
          });
          if (_offlineStatusEvidence.unknown) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Account status is awaiting confirmation. Online actions are paused until the next refresh.'),
              backgroundColor: Colors.orange,
            ));
          } else if (!restored) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Location tracking could not restart. Check GPS and location permission before trying again.'),
              backgroundColor: Colors.orange,
            ));
          }
        }
      } finally {
        if (mounted && _activeOrderVerification.sameOfflineIdentity(
            offlineOperation, rider?['id']?.toString(), supabase.auth.currentUser?.id)) {
          _offlineStatusEvidence.finishWrite();
        }
        statusUpdating = false;
      }
      return;
    }

    // 2. If going online, check subscription first!
    final isSubscribed = _isSubscriptionActive(rider);

    if (!isSubscribed) {
      // Launch offer: a partner who has never had the free trial gets the
      // "30 Days Free" screen instead of the paid MAX sheet -- no payment order,
      // no Cashfree checkout. Once free_trial_used flips true server-side
      // (permanently, regardless of expiry), this always falls through to the
      // existing paid-subscription sheet below, unchanged.
      if (_isFreeTrialEligible(rider)) {
        _showFreeTrialBottomSheet();
      } else {
        _showSubscriptionBottomSheet(goingOnline: true);
      }
      return;
    }

    // A passenger paying via UPI intent needs somewhere to send the money —
    // every rider already has a rider_payout_accounts row (mandatory before
    // reaching Rider Home, see rider_entry_handler.dart), but upi_vpa on it
    // is optional there (onboarding's Payout Details screen labels it
    // "Personal UPI (Optional)" -- bank account + IFSC alone is a complete,
    // successfully-saved payout setup). Require it here before allowing them
    // online -- UNLESS an active free trial is running: a partner who
    // finished onboarding with bank-only payout must never be re-prompted for
    // UPI just to go online during their free 30 days (that's a Payment
    // Settings decision, not a go-online gate). Paid-subscriber behavior is
    // intentionally unchanged -- this skip is scoped to _isFreeTrialActive
    // only, never to isSubscribed in general.
    final riderId = rider?['id'];
    if (riderId != null && !_isFreeTrialActive(rider)) {
      final payoutAccount = await supabase
          .from('rider_payout_accounts')
          .select('upi_vpa')
          .eq('rider_id', riderId)
          .maybeSingle();

      final hasUpiVpa = (payoutAccount?['upi_vpa'] as String?)?.trim().isNotEmpty == true;
      if (!hasUpiVpa) {
        if (!mounted) return;
        _showAddUpiVpaSheet();
        return;
      }
    }

    await _bringRiderOnline();
  }

  /// Single, production-safe entry point for bringing a rider online. Checks GPS/location
  /// permission, requests notification permission, obtains and validates a FRESH GPS fix, then
  /// writes account_status='online' together with current_lat/current_lng/last_location_updated_at
  /// in one atomic UPDATE. A rider is never marked online without a validated location.
  ///
  /// ROOT CAUSE FIX ("0 active partners nearby" despite the Drop Partner being online and
  /// co-located): account_status used to be flipped to 'online' in its own UPDATE, fully decoupled
  /// from the rider's current_lat/current_lng/last_location_updated_at write (which happened later,
  /// via startRiderLiveTracking()'s fire-and-forget first heartbeat) -- a real window where a rider
  /// was 'online' with null or stale location, invisible to both the passenger's nearby count and
  /// (until the first heartbeat lands) dispatch itself, since find_nearby_riders() requires
  /// current_lat/current_lng IS NOT NULL. That was fixed once, here -- but two other "Go Online"
  /// buttons inside _showSubscriptionBottomSheet() reimplemented the old, unsafe write directly
  /// instead of calling this method, reintroducing the exact race for every non-subscribed rider
  /// (the default, non-MAX-plan population). This is now the only place in the app that ever writes
  /// riders.account_status='online'; every "go online" action calls it.
  ///
  /// Returns true only once account_status/current_lat/current_lng/last_location_updated_at have
  /// been committed together. Returns false (after showing the user a clear, specific error) if GPS
  /// is disabled, permission is denied, or a fresh fix could not be obtained within 8 seconds --
  /// never silently reports misleading availability.
  Future<bool> _bringRiderOnline() async {
    if (_offlineStatusEvidence.unknown) return false;
    final onlineUserId = supabase.auth.currentUser?.id;
    final onlineRiderId = rider?['id']?.toString();
    final onlineRevision = _offlineStatusEvidence.readRevision;
    bool ownsOnlineOperation() => _offlineStatusEvidence.permitsOnlineOperation(
        onlineRevision, mounted: mounted, userId: onlineUserId, riderId: onlineRiderId,
        currentUserId: supabase.auth.currentUser?.id,
        currentRiderId: rider?['id']?.toString());
    if (!ownsOnlineOperation()) return false;
    // Check location service
    final gpsEnabled = await Geolocator.isLocationServiceEnabled();
    if (!gpsEnabled) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enable location/GPS services on your device to go online.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return false;
    }

    // Check/Request permission
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Location permission is required to go online.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return false;
    }

    // Request Notification Permission on Android (API 33+)
    if (mounted && Theme.of(context).platform == TargetPlatform.android) {
      final notifStatus = await Permission.notification.status;
      if (notifStatus.isDenied) {
        final res = await Permission.notification.request();
        if (res.isDenied) {
          if (!mounted) return false;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Notification permission is recommended for location tracking in the background.'),
              backgroundColor: Colors.orangeAccent,
            ),
          );
          // Not fatal -- only GPS/location itself blocks going online.
        }
      }
    }

    // A fresh position is obtained and validated FIRST, then written in the SAME update statement
    // as account_status='online' -- atomic, no race window. If a fresh location genuinely can't be
    // obtained, going online is aborted with an honest error instead of silently reporting
    // misleading availability.
    double? freshLat;
    double? freshLng;
    try {
      await LocationCacheService.initializeLocation().timeout(const Duration(seconds: 8));
    } catch (_) {
      // Fall through to the null-check below, which surfaces the honest failure state.
    }
    freshLat = LocationCacheService.currentLat;
    freshLng = LocationCacheService.currentLng;
    if (freshLat == null || freshLng == null) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to get a fresh location fix. Please check GPS and try again.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return false;
    }

    if (!ownsOnlineOperation()) return false;
    try {
      HapticFeedback.mediumImpact();
      statusUpdating = true;
      setState(() {
        isOnline = true;
        if (rider != null) {
          rider!['account_status'] = 'online';
        }
      });

      await LocationCacheService.startRiderLiveTracking(canStart: ownsOnlineOperation);
      if (!ownsOnlineOperation()) return false;

      final nowIso = DateTime.now().toUtc().toIso8601String();
      await supabase.from('riders').update({
        'account_status': 'online',
        'updated_at': nowIso,
        'current_lat': freshLat,
        'current_lng': freshLng,
        'last_location_updated_at': nowIso,
      }).eq('user_id', onlineUserId!);
      if (!ownsOnlineOperation()) return false;

      // subscribeAssignments()'s realtime channel is established once, early, independent of
      // online status, so it should already be live by the time this runs -- but a rider tapping
      // Go Online immediately after opening the app can still race the socket's own auth/join
      // handshake, and a request created inside that window's INSERT event is then simply missed
      // (Postgres Changes has no replay/backlog for it). This one-time reconciliation pass catches
      // anything already pending at go-online time; ongoing delivery relies on the realtime
      // subscription (already live) and the 30s general refresh timer thereafter.
      if (rider != null) {
        final riderId = rider!['id']?.toString();
        if (riderId != null) {
          unawaited(_reconcilePendingAssignments(riderId));
        }
      }

      return true;
    } catch (_) {
      if (!ownsOnlineOperation()) return false;
      setState(() {
        isOnline = false;
        if (rider != null) {
          rider!['account_status'] = 'offline';
        }
      });
      return false;
    } finally {
      statusUpdating = false;
    }
  }

  /// Single source of truth for "does this rider currently have an active,
  /// unexpired subscription" — used for the go-online gate, the home banner,
  /// and anywhere else that needs to know whether commission is waived.
  static bool _isSubscriptionActive(Map<String, dynamic>? rider) {
    return rider?['subscription_active'] == true &&
        rider?['subscription_expires_at'] != null &&
        DateTime.tryParse(rider!['subscription_expires_at'].toString())?.isAfter(DateTime.now()) == true;
  }

  /// Whether this partner has never had the one-time launch free trial granted
  /// (server-authoritative field, riders.free_trial_used -- set exactly once by
  /// activate_rider_free_trial() and never reset). Used purely to decide which
  /// bottom sheet to show; the RPC itself independently re-checks this same
  /// condition server-side before granting anything, so a stale/tampered client
  /// value here can never re-grant an already-used trial.
  static bool _isFreeTrialEligible(Map<String, dynamic>? rider) {
    return rider?['free_trial_used'] != true;
  }

  /// Whether the partner's 30-day free trial window is currently running.
  ///
  /// free_trial_expires_at is a PERMANENT historical bookkeeping field (set once by
  /// activate_rider_free_trial(), never reset -- see 20260901000016_rider_free_trial.sql's own
  /// doc comment) -- it records that a trial WAS granted and when it was originally due to end,
  /// but it is not by itself proof the entitlement is still live: an admin can end a rider's
  /// active entitlement early (subscription_active=false, subscription_expires_at=NULL) while
  /// intentionally leaving this historical timestamp untouched. Checking free_trial_expires_at in
  /// isolation previously caused an already-ended trial to still show as "30 Days Free" until the
  /// original 30-day window would have naturally elapsed. _isSubscriptionActive is the actual live
  /// entitlement and is required here too, matching _buildSubscriptionBanner's own documented
  /// assumption that "during the trial window, subscription_active ... IS the trial window".
  static bool _isFreeTrialActive(Map<String, dynamic>? rider) {
    if (!_isSubscriptionActive(rider)) return false;
    final expiresAtStr = rider?['free_trial_expires_at'];
    if (expiresAtStr == null) return false;
    final expiresAt = DateTime.tryParse(expiresAtStr.toString());
    return expiresAt != null && expiresAt.isAfter(DateTime.now());
  }

  /// Whether the rider's CURRENTLY active entitlement (per _isSubscriptionActive) is a PAID
  /// subscription rather than the free trial -- used to hide the "Extend"/Subscribe action while
  /// a paid plan is running (Phase 14 no-stacking rule: a second purchase is only allowed after
  /// the current one expires; buying while only the free trial is active remains allowed).
  ///
  /// subscription_expires_at is reset to activation_time+24h on every paid purchase now that
  /// create-payment/cashfree-webhook/verify-payment never stack it onto an existing expiry --
  /// free_trial_expires_at is a separate, permanent bookkeeping column set once by
  /// activate_rider_free_trial() and never touched by a paid purchase. So while subscription is
  /// active, the two timestamps being EQUAL means the trial is what's currently active; any other
  /// value means a paid subscription is currently active.
  static bool _isPaidSubscriptionActive(Map<String, dynamic>? rider) {
    if (!_isSubscriptionActive(rider)) return false;
    final subExpires = rider?['subscription_expires_at']?.toString();
    final trialExpires = rider?['free_trial_expires_at']?.toString();
    return !(trialExpires != null && subExpires == trialExpires);
  }

  /// Days remaining in the active free trial, derived live from
  /// free_trial_expires_at -- ceil()'d so "23 hours left" still reads as "1 day
  /// remaining" rather than rounding down to 0 the day it's due to expire.
  static int _freeTrialDaysRemaining(Map<String, dynamic>? rider) {
    final expiresAtStr = rider?['free_trial_expires_at'];
    if (expiresAtStr == null) return 0;
    final expiresAt = DateTime.tryParse(expiresAtStr.toString());
    if (expiresAt == null) return 0;
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.isNegative) return 0;
    return (remaining.inSeconds / const Duration(days: 1).inSeconds).ceil();
  }

  void _showAddUpiVpaSheet() {
    final upiController = TextEditingController();
    bool saving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: darkCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
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
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: primaryLime.withValues(alpha: 0.08),
                      shape: BoxShape.circle,
                      border: Border.all(color: primaryLime.withValues(alpha: 0.15), width: 1.5),
                    ),
                    child: const Icon(Icons.qr_code_rounded, color: primaryLime, size: 40),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Add Your UPI ID',
                    style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Passengers pay you directly via UPI at trip completion. Add your UPI ID (VPA) so they know where to send the payment.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: textGray, fontSize: 13, fontWeight: FontWeight.w500, height: 1.4),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: upiController,
                    autofocus: true,
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                    decoration: InputDecoration(
                      hintText: 'e.g. yourname@upi',
                      hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
                      filled: true,
                      fillColor: Colors.black.withValues(alpha: 0.2),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: saving
                          ? null
                          : () async {
                              final vpa = upiController.text.trim();
                              if (!vpa.contains('@') || vpa.length < 3) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(
                                    content: Text('Enter a valid UPI ID (e.g. name@upi)'),
                                    backgroundColor: Colors.redAccent,
                                  ),
                                );
                                return;
                              }
                              setSheetState(() => saving = true);
                              try {
                                await supabase
                                    .from('rider_payout_accounts')
                                    .update({'upi_vpa': vpa})
                                    .eq('rider_id', rider?['id']);
                                if (ctx.mounted) Navigator.pop(ctx);
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('UPI ID saved. You can go online now.'),
                                      backgroundColor: Colors.green,
                                    ),
                                  );
                                }
                              } catch (e) {
                                setSheetState(() => saving = false);
                                if (ctx.mounted) {
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    SnackBar(content: Text('Failed to save UPI ID: $e'), backgroundColor: Colors.redAccent),
                                  );
                                }
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryLime,
                        foregroundColor: Colors.black,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: saving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2.0),
                            )
                          : const Text('Save UPI ID', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Launch offer for a partner who has never had the free trial (see
  /// _isFreeTrialEligible). Replaces the paid MAX sheet entirely for this
  /// partner -- no plan selection, no billing breakdown, no Cashfree checkout.
  /// The primary button calls activate_rider_free_trial() (server-authoritative
  /// one-time grant, see migration 20260901000016_rider_free_trial.sql) and
  /// then brings the rider online exactly the same way every other "go online"
  /// path does (_bringRiderOnline).
  void _showFreeTrialBottomSheet() {
    bool sheetProcessing = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: darkCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 36),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox.shrink(),
                  const SizedBox(height: 20),
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFC5FF30), Color(0xFF00FFCC)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: primaryLime.withValues(alpha: 0.25),
                            blurRadius: 24,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: const Icon(Icons.celebration_rounded, color: Colors.black, size: 40),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Center(
                    child: Text(
                      '🎉 30 Days Free',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: primaryLime.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: primaryLime.withValues(alpha: 0.3)),
                      ),
                      child: const Text(
                        '0% Company Commission',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: primaryLime),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'You pay ₹0 company commission during your free 30-day period.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.white70, fontWeight: FontWeight.w600, height: 1.4),
                  ),
                  const SizedBox(height: 16),
                  // Tax/commission transparency (required): 0% COMPANY COMMISSION is not the same
                  // thing as 0% government tax -- this box is the partner-facing disclosure of that
                  // distinction, deliberately worded to never claim a tax amount/liability this
                  // client can't determine (that stays entirely in the existing, unmodified
                  // apply_order_government_tax()/settlement mechanism -- see the earnings breakdown
                  // for the actual per-order figures).
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.03),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                    ),
                    child: const Text(
                      'Government taxes/GST are separate from company commission and will be handled '
                      'according to applicable GST rules. See your earnings breakdown for applicable '
                      'deductions/settlement.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11.5, color: textGray, fontWeight: FontWeight.w500, height: 1.4),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Your 30-day free period starts when you activate it.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: textGray, fontWeight: FontWeight.w500, height: 1.4),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      onPressed: sheetProcessing
                          ? null
                          : () async {
                              setSheetState(() => sheetProcessing = true);
                              try {
                                final rpcResult = await supabase.rpc('activate_rider_free_trial');
                                Map<String, dynamic>? row;
                                if (rpcResult is List && rpcResult.isNotEmpty) {
                                  row = Map<String, dynamic>.from(rpcResult.first as Map);
                                } else if (rpcResult is Map) {
                                  row = Map<String, dynamic>.from(rpcResult);
                                }
                                final trialActivated = row?['trial_activated'] == true;
                                final reason = row?['reason']?.toString();

                                if (!mounted) return;

                                if (trialActivated) {
                                  Navigator.pop(sheetCtx);
                                  // Trial is already granted server-side at this point (irreversible --
                                  // free_trial_used is permanent), so a GPS/location failure here must
                                  // never be reported as success: _bringRiderOnline()'s result is the
                                  // single source of truth for whether the rider is actually online, not
                                  // merely whether the trial RPC succeeded.
                                  final wentOnline = await _bringRiderOnline();
                                  await loadRider();
                                  if (mounted) {
                                    final expiresAtStr = row?['free_trial_expires_at']?.toString();
                                    if (wentOnline) {
                                      _showFreeTrialActivatedDialog(expiresAtStr);
                                    } else {
                                      // _bringRiderOnline() already surfaced the specific reason (GPS
                                      // disabled / permission denied / no fix) via its own SnackBar.
                                      // Trial is safely banked -- free_trial_used=true persists, so the
                                      // rider's next "Go Online" tap goes straight to _bringRiderOnline()
                                      // (isSubscribed is now true) without re-showing this sheet.
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Your 30-day free trial is activated. Tap Go Online again once location is available.',
                                          ),
                                          backgroundColor: Colors.orangeAccent,
                                        ),
                                      );
                                    }
                                  }
                                  return;
                                }

                                // Server rejected the grant -- re-sync from the authoritative
                                // source instead of trusting anything computed client-side, then
                                // route to whichever flow now actually applies.
                                await loadRider();
                                if (!mounted) return;
                                Navigator.pop(sheetCtx);

                                if (reason == 'already_subscribed') {
                                  // Rider already has an active paid subscription (e.g. bought
                                  // MAX before ever going online) -- just go online normally,
                                  // the existing subscription already grants 0% commission.
                                  await _bringRiderOnline();
                                } else {
                                  // 'trial_already_used' (or any other reason) -- the one-time
                                  // trial is gone, fall back to the normal paid MAX sheet.
                                  _showSubscriptionBottomSheet(goingOnline: true);
                                }
                              } catch (e) {
                                // Never surface raw PostgREST/exception text to the rider -- the
                                // sheet stays open (trial NOT marked active, rider NOT taken
                                // online) so they can simply retry.
                                debugPrint('activate_rider_free_trial failed: $e');
                                if (mounted) {
                                  setSheetState(() => sheetProcessing = false);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text("Couldn't activate your free trial. Please check your connection and try again."),
                                      backgroundColor: Colors.redAccent,
                                    ),
                                  );
                                }
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryLime,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 0,
                      ),
                      child: sheetProcessing
                          ? const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: 20, height: 20,
                                  child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2),
                                ),
                                SizedBox(width: 12),
                                Text('Activating your free trial...', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                              ],
                            )
                          : const Text(
                              'ACTIVATE & GO ONLINE',
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 0.3),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: TextButton(
                      onPressed: sheetProcessing ? null : () => Navigator.pop(sheetCtx),
                      child: const Text(
                        'Maybe later',
                        style: TextStyle(color: textGray, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showFreeTrialActivatedDialog(String? expiresAtStr) {
    final expiresAt = expiresAtStr != null ? DateTime.tryParse(expiresAtStr)?.toLocal() : null;
    String expiresText = '30 days from now';
    if (expiresAt != null) {
      const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      expiresText = '${expiresAt.day} ${months[expiresAt.month - 1]} ${expiresAt.year}';
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: darkCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: primaryLime.withValues(alpha: 0.2), width: 1.5),
        ),
        title: Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: primaryLime.withValues(alpha: 0.1), shape: BoxShape.circle),
            child: const Icon(Icons.celebration_rounded, color: primaryLime, size: 40),
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '🎉 30 Days Free Activated!',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              "You're now ONLINE with 0% company commission.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600, height: 1.4),
            ),
            const SizedBox(height: 4),
            Text(
              'Your free period ends on $expiresText.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: textGray, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 10),
            // Same required tax/commission distinction as the activation sheet, restated here
            // since this is the moment the partner is most likely to actually read it.
            const Text(
              'Applicable government taxes/GST remain separate from company commission.',
              textAlign: TextAlign.center,
              style: TextStyle(color: textGray, fontSize: 11, fontWeight: FontWeight.w500, height: 1.4),
            ),
          ],
        ),
        actions: [
          Center(
            child: SizedBox(
              width: 140,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryLime,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
                child: const Text('START EARNING', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Vehicle-specific subscription pricing: the set of vehicle_type values ('bike'/'auto'/'cab')
  /// this rider actually has VERIFIED -- the primary KYC vehicle (only if kyc_status='approved')
  /// plus any additional approved rows in rider_vehicles. Mirrors the exact server-side
  /// verification create-payment/index.ts performs before charging for a vehicle-specific plan --
  /// this client-side copy is display/selection-only and is never trusted for the actual charge.
  Future<Set<String>> _fetchVerifiedVehicleTypes() async {
    final verified = <String>{};
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return verified;

    final kyc = await supabase
        .from('rider_kyc')
        .select('vehicle_type, kyc_status')
        .eq('user_id', userId)
        .maybeSingle();
    if (kyc != null && kyc['kyc_status'] == 'approved' && kyc['vehicle_type'] != null) {
      verified.add(kyc['vehicle_type'].toString());
    }

    final riderId = rider?['id']?.toString();
    if (riderId != null) {
      final extra = await supabase
          .from('rider_vehicles')
          .select('vehicle_type')
          .eq('rider_id', riderId)
          .eq('status', 'approved');
      for (final v in List<Map<String, dynamic>>.from(extra)) {
        if (v['vehicle_type'] != null) verified.add(v['vehicle_type'].toString());
      }
    }
    return verified;
  }

  /// Current active subscription prices, keyed by plan_id (e.g. 'daily_bike', 'weekly') --
  /// read directly from the server-authoritative subscription_plans table (migration
  /// 20260901000033_vehicle_specific_subscription_pricing.sql) for DISPLAY only. The actual charge
  /// amount is always re-derived server-side from this same table at create-payment time -- this
  /// client-side read can never influence what Cashfree actually collects.
  Future<Map<String, double>> _fetchSubscriptionPlanPrices() async {
    final rows = await supabase
        .from('subscription_plans')
        .select('plan_id, amount')
        .eq('is_active', true);
    final prices = <String, double>{};
    for (final r in List<Map<String, dynamic>>.from(rows)) {
      final planId = r['plan_id']?.toString();
      final amount = double.tryParse(r['amount'].toString());
      if (planId != null && amount != null) {
        prices[planId] = amount;
      }
    }
    return prices;
  }

  Future<void> _showSubscriptionBottomSheet({bool goingOnline = false}) async {
    // Vehicle-specific pricing requires knowing (a) which vehicle_types this rider actually has
    // verified and (b) the current active price for each -- both loaded up front, before the sheet
    // is even shown. On any failure, or if no valid vehicle/price combination is available, the
    // sheet is never opened and no hardcoded price is ever displayed or charged -- fail closed,
    // never silently fall back to the old flat ₹40.
    Set<String> verifiedVehicleTypes;
    Map<String, double> planPrices;
    try {
      final results = await Future.wait([
        _fetchVerifiedVehicleTypes(),
        _fetchSubscriptionPlanPrices(),
      ]);
      verifiedVehicleTypes = results[0] as Set<String>;
      planPrices = results[1] as Map<String, double>;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not load subscription pricing. Please try again. ($e)'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (!mounted) return;

    const vehicleTypeOrder = ['bike', 'auto', 'cab'];
    final availableVehicleTypes = vehicleTypeOrder
        .where((v) => verifiedVehicleTypes.contains(v) && planPrices.containsKey('daily_$v'))
        .toList();
    final double? weeklyPrice = planPrices['weekly'];

    if (availableVehicleTypes.isEmpty || weeklyPrice == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Subscription pricing is currently unavailable for your verified vehicle. Please try again shortly or contact support.',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    int selectedDays = 1;
    String selectedVehicleType = availableVehicleTypes.first;
    bool sheetProcessing = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: darkCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final double dailyPrice = planPrices['daily_$selectedVehicleType']!;
            final double amount = selectedDays == 1 ? dailyPrice : weeklyPrice;
            return Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 36),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.85,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                   const SizedBox.shrink(),
                  const SizedBox(height: 24),
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: primaryLime.withValues(alpha: 0.08),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: primaryLime.withValues(alpha: 0.1),
                            blurRadius: 20,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.workspace_premium_rounded,
                        color: primaryLime,
                        size: 40,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'Waydrop ',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                            letterSpacing: -0.5,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [
                                Color(0xFFC5FF30),
                                Color(0xFF00FFCC),
                                Color(0xFFC5FF30),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFFC5FF30).withValues(alpha: 0.3),
                                blurRadius: 10,
                                spreadRadius: 1,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                          child: const Text(
                            'MAX',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                              color: Colors.black,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Center(
                    child: Text(
                      'Commission-Free Plan',
                      style: TextStyle(
                        fontSize: 14,
                        color: textGray,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.02),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
                    ),
                    child: Column(
                      children: [
                        _buildBenefitRow(Icons.check_circle_rounded, "Keep 100% of the user fare"),
                        const SizedBox(height: 10),
                        _buildBenefitRow(Icons.check_circle_rounded, "Zero company commission — only GST deducted"),
                        const SizedBox(height: 10),
                        _buildBenefitRow(Icons.check_circle_rounded, "Higher payout earnings automatically locked"),
                      ],
                    ),
                  ),
                  // Vehicle selector — always shows all 3 vehicle types (Bike/Auto/Cab) so the
                  // rider can see every vehicle's price, but only vehicles this rider actually has
                  // VERIFIED (availableVehicleTypes -- KYC-approved primary vehicle or an approved
                  // rider_vehicles row) are tappable. An unverified vehicle is shown greyed out
                  // with an explicit "Not verified" label and cannot be selected -- it can never
                  // become the purchased plan. This is UI-level only: create-payment/index.ts
                  // independently re-verifies the same rider_kyc/rider_vehicles data server-side
                  // before ever charging, so this can never be the only thing standing between an
                  // unverified vehicle and a real charge.
                  const SizedBox(height: 24),
                  const Text(
                    'Select Vehicle',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: textGray,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      for (final vt in vehicleTypeOrder) ...[
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(right: vt == vehicleTypeOrder.last ? 0 : 8),
                            child: Builder(
                              builder: (context) {
                                final isVerified = availableVehicleTypes.contains(vt);
                                final priceForVt = planPrices['daily_$vt'];
                                final isSelectedVerified = isVerified && selectedVehicleType == vt;
                                return Opacity(
                                  opacity: isVerified ? 1.0 : 0.45,
                                  child: InkWell(
                                    onTap: isVerified ? () => setSheetState(() => selectedVehicleType = vt) : null,
                                    borderRadius: BorderRadius.circular(12),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(vertical: 10),
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: isSelectedVerified ? primaryLime.withValues(alpha: 0.08) : Colors.transparent,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: isSelectedVerified ? primaryLime : Colors.white10,
                                          width: isSelectedVerified ? 2 : 1,
                                        ),
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            vt[0].toUpperCase() + vt.substring(1),
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                              color: isSelectedVerified ? primaryLime : Colors.white70,
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            isVerified
                                                ? (priceForVt != null ? '₹${priceForVt.toStringAsFixed(0)}' : '—')
                                                : 'Not verified',
                                            style: TextStyle(
                                              fontSize: 9.5,
                                              fontWeight: FontWeight.w700,
                                              color: isVerified ? textGray : Colors.redAccent.withValues(alpha: 0.85),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Select Plan Duration',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: textGray,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildPlanOptionTile(
                    title: "1 Day Pass",
                    subtitle: "Valid till that day ends (inclusive GST)",
                    priceText: "₹${dailyPrice.toStringAsFixed(0)}",
                    isSelected: selectedDays == 1,
                    onTap: () => setSheetState(() => selectedDays = 1),
                  ),
                  const SizedBox(height: 8),
                  _buildPlanOptionTile(
                    title: "7 Days (1 Week)",
                    subtitle: "Extend for a full week commission-free (inclusive GST)",
                    priceText: "₹${weeklyPrice.toStringAsFixed(0)}",
                    isSelected: selectedDays == 7,
                    onTap: () => setSheetState(() => selectedDays = 7),
                  ),
                  const SizedBox(height: 20),
                  // Billing breakdown card
                  Builder(
                    builder: (context) {
                      final double total = selectedDays == 1 ? dailyPrice : weeklyPrice;
                      final double base = double.parse((total / 1.18).toStringAsFixed(2));
                      final double gst = double.parse((total - base).toStringAsFixed(2));

                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.02),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Billing Details',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Actual Plan Price',
                                  style: TextStyle(fontSize: 12, color: textGray),
                                ),
                                Text(
                                  '₹${base.toStringAsFixed(2)}',
                                  style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'GST (18%)',
                                  style: TextStyle(fontSize: 12, color: textGray),
                                ),
                                Text(
                                  '₹${gst.toStringAsFixed(2)}',
                                  style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            const Divider(color: Colors.white10, height: 1),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Total Payable Amount',
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
                                ),
                                Text(
                                  '₹${total.toStringAsFixed(2)}',
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: primaryLime),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: sheetProcessing
                          ? null
                          : () async {
                              // TEMP DEBUG INSTRUMENTATION -- see payment_debug_trace.dart.
                              PaymentTrace.start('subscription');
                              PaymentTrace.step('BUTTON_CLICKED', 'subscription', 'Subscription purchase button');
                              PaymentTrace.step('PAYMENT_TYPE', 'subscription', 'subscription');
                              PaymentTrace.step('AMOUNT', 'subscription', amount);

                              setSheetState(() => sheetProcessing = true);
                              try {
                                final user = supabase.auth.currentUser;
                                if (user == null) throw Exception("User not logged in");

                                // Egress fix: only `id` is read below (passed to PaymentService.startPayment).
                                final riderRes = await supabase.from('riders').select('id').eq('user_id', user.id).single();

                                if (!mounted) return;

                                // Server owns the subscription plan definition (real charge amount +
                                // exact-hour duration) -- this client only ever sends a plan id. The
                                // actual starts_at/expires_at are computed server-side, only once
                                // Cashfree confirms the payment (cashfree-webhook/verify-payment), never
                                // from anything computed here. See create-payment/index.ts and migrations
                                // 20260726000002_subscription_plan_allowlist.sql /
                                // 20260901000033_vehicle_specific_subscription_pricing.sql. The daily
                                // plan_id now encodes the selected, already-verified vehicle
                                // (create-payment independently re-verifies this rider actually has that
                                // vehicle before charging -- this client selection can never make the
                                // server charge for an unverified vehicle).
                                final planId = selectedDays == 1 ? 'daily_$selectedVehicleType' : 'weekly';

                                // Actually start payment via PaymentService
                                final paymentResult = await PaymentService.startPayment(
                                  context: context,
                                  paymentFor: PaymentFor.subscription,
                                  amount: amount, // local display only -- server derives the real charge from planId
                                  paymentMethod: 'cashfree',
                                  riderId: riderRes['id'],
                                  planId: planId,
                                );

                                PaymentTrace.step('PaymentService.startPayment() RETURNED', 'subscription', paymentResult);

                                if (paymentResult['success'] != true) {
                                  throw Exception(paymentResult['message'] ?? 'Payment was not completed');
                                }


                                if (goingOnline) {
                                  // Unified safe go-online flow (see _bringRiderOnline doc
                                  // comment) -- never writes account_status='online' without a
                                  // validated, atomically-written location.
                                  await _bringRiderOnline();
                                }

                                if (!mounted) {
                                  PaymentTrace.abnormalExit('subscription onPressed', 'subscription', 'widget unmounted after success');
                                  return;
                                }
                                Navigator.pop(sheetCtx);

                                _showSubscriptionSuccessDialog(selectedDays);
                                loadRider();
                                PaymentTrace.end('subscription');
                              } catch (e, st) {
                                PaymentTrace.exceptionAt('subscription purchase onPressed', 'subscription', e, st);
                                if (mounted) {
                                  setSheetState(() => sheetProcessing = false);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Purchase failed: $e')),
                                  );
                                }
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryLime,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 0,
                      ),
                      child: sheetProcessing
                          ? const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: 20, height: 20,
                                  child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2),
                                ),
                                SizedBox(width: 12),
                                Text(
                                  'Authorizing online payment...',
                                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                                ),
                              ],
                            )
                          : Text(
                              goingOnline ? 'Pay ₹${amount.toStringAsFixed(2)} & Go Online' : 'Pay ₹${amount.toStringAsFixed(2)} & Subscribe',
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (goingOnline)
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: OutlinedButton(
                        onPressed: sheetProcessing
                            ? null
                            : () async {
                                Navigator.pop(sheetCtx);
                                // Unified safe go-online flow (see _bringRiderOnline doc
                                // comment) -- never writes account_status='online' without a
                                // validated, atomically-written location. Handles its own
                                // isOnline/statusUpdating state and revert-on-failure.
                                await _bringRiderOnline();
                                loadRider();
                              },
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.white12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: const Text(
                          'No thanks, go online with commission',
                          style: TextStyle(color: textGray, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                      ),
                    )
                  else
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: TextButton(
                        onPressed: sheetProcessing ? null : () => Navigator.pop(sheetCtx),
                        child: const Text(
                          'Maybe later',
                          style: TextStyle(color: textGray, fontSize: 13, fontWeight: FontWeight.bold),
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
    );
  }

  Widget _buildBenefitRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, color: primaryLime, size: 16),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }

  Widget _buildPlanOptionTile({
    required String title,
    required String subtitle,
    required String priceText,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white.withValues(alpha: 0.04) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? primaryLime : Colors.white10,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 11, color: textGray, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              priceText,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: isSelected ? primaryLime : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSubscriptionSuccessDialog(int days) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: darkCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08), width: 1.5),
        ),
        title: Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: primaryLime.withValues(alpha: 0.1), shape: BoxShape.circle),
            child: const Icon(Icons.check_circle_rounded, color: primaryLime, size: 40),
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Upgrade Successful!',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Your Waydrop MAX subscription is now active for $days ${days == 1 ? "day" : "days"}. Keep 100% of your customer fare!',
              textAlign: TextAlign.center,
              style: const TextStyle(color: textGray, fontSize: 13, height: 1.4),
            ),
          ],
        ),
        actions: [
          Center(
            child: SizedBox(
              width: 120,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryLime,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
                child: const Text('AWESOME', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubscriptionBanner() {
    final hasSubscriptionRecord = rider?['subscription_expires_at'] != null;
    final isSubscribed = _isSubscriptionActive(rider);

    // Free-trial state takes priority over the generic "subscribed" banner below --
    // during the trial window, subscription_active/subscription_expires_at ARE the
    // trial window (see migration 20260901000016_rider_free_trial.sql), so isSubscribed
    // is also true here; free_trial_expires_at is what distinguishes "this is the
    // launch trial" from "this is a paid MAX plan" for messaging purposes only. Once
    // free_trial_expires_at passes, this falls straight through to the normal
    // isSubscribed/expired banners below, unchanged.
    if (_isFreeTrialActive(rider)) {
      final expiresAtStr = rider!['free_trial_expires_at'];
      final expiresAt = DateTime.tryParse(expiresAtStr.toString())?.toLocal();
      // "DD MMM" (no year) -- matches the requested "X days remaining • Until DD MMM" format.
      String expirationText = '';
      if (expiresAt != null) {
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        expirationText = "${expiresAt.day} ${months[expiresAt.month - 1]}";
      }
      // Computed live from the server-written free_trial_expires_at (_freeTrialDaysRemaining) --
      // never a hard-coded 30.
      final daysLeft = _freeTrialDaysRemaining(rider);

      return Container(
        margin: const EdgeInsets.only(bottom: 20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: darkCard,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: primaryLime.withValues(alpha: 0.35), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: primaryLime.withValues(alpha: 0.06),
              blurRadius: 16,
              spreadRadius: 0,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFC5FF30), Color(0xFF00FFCC)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.celebration_rounded, color: Colors.black, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '30 Days Free • 0% Commission',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Colors.white),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    daysLeft > 0
                        ? '$daysLeft ${daysLeft == 1 ? "day" : "days"} remaining • Until $expirationText'
                        : 'Ends today • Until $expirationText',
                    style: const TextStyle(fontSize: 11, color: textGray, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (isSubscribed) {
      final expiresAtStr = rider!['subscription_expires_at'];
      final expiresAt = DateTime.tryParse(expiresAtStr.toString())?.toLocal();
      String expirationText = '';
      if (expiresAt != null) {
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final tomorrow = today.add(const Duration(days: 1));
        final expireDay = DateTime(expiresAt.year, expiresAt.month, expiresAt.day);
        final timeStr = "${expiresAt.hour.toString().padLeft(2, '0')}:${expiresAt.minute.toString().padLeft(2, '0')}";
        
        if (expireDay == today) {
          expirationText = "Today at $timeStr";
        } else if (expireDay == tomorrow) {
          expirationText = "Tomorrow at $timeStr";
        } else {
          const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
          expirationText = "${expiresAt.day} ${months[expiresAt.month - 1]} at $timeStr";
        }
      }

      return Container(
        margin: const EdgeInsets.only(bottom: 20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: darkCard,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: primaryLime.withValues(alpha: 0.3), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: primaryLime.withValues(alpha: 0.04),
              blurRadius: 16,
              spreadRadius: 0,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: primaryLime.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.workspace_premium_rounded, color: primaryLime, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                   Wrap(
                     spacing: 6,
                     crossAxisAlignment: WrapCrossAlignment.center,
                     children: [
                       const Text(
                         'Waydrop ',
                         style: TextStyle(
                           fontSize: 15,
                           fontWeight: FontWeight.w900,
                           color: Colors.white,
                           letterSpacing: -0.5,
                         ),
                       ),
                       Container(
                         padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                         decoration: BoxDecoration(
                           gradient: const LinearGradient(
                             colors: [
                               Color(0xFFC5FF30),
                               Color(0xFF00FFCC),
                               Color(0xFFC5FF30),
                             ],
                             begin: Alignment.topLeft,
                             end: Alignment.bottomRight,
                           ),
                           borderRadius: BorderRadius.circular(6),
                           boxShadow: [
                             BoxShadow(
                               color: const Color(0xFFC5FF30).withValues(alpha: 0.2),
                               blurRadius: 6,
                               spreadRadius: 0.5,
                             ),
                           ],
                         ),
                         child: const Text(
                           'MAX',
                           style: TextStyle(
                             fontSize: 10,
                             fontWeight: FontWeight.w900,
                             color: Colors.black,
                             letterSpacing: 0.5,
                           ),
                         ),
                       ),
                     ],
                   ),
                  const SizedBox(height: 4),
                  Text(
                    'Commission Waived! Active until $expirationText',
                    style: const TextStyle(fontSize: 11, color: textGray, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
            // NO-STACKING (Phase 14): a PAID subscription that's currently active must not offer
            // another purchase -- "Subscribe"/"Extend" only becomes available again after it
            // expires (create-payment/index.ts enforces this server-side regardless of what the
            // client shows). Buying is still allowed while only the free trial is active, so the
            // button stays visible in that case.
            if (!_isPaidSubscriptionActive(rider)) ...[
              const SizedBox(width: 8),
              SizedBox(
                height: 36,
                child: ElevatedButton(
                  onPressed: () => _showSubscriptionBottomSheet(goingOnline: false),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white10,
                    foregroundColor: primaryLime,
                    elevation: 0,
                    side: const BorderSide(color: Colors.white12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  child: const Text('Extend', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ],
        ),
      );
    } else if (hasSubscriptionRecord) {
      final expiresAtStr = rider!['subscription_expires_at'];
      final expiresAt = DateTime.tryParse(expiresAtStr.toString())?.toLocal();
      String expirationText = '';
      if (expiresAt != null) {
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final tomorrow = today.add(const Duration(days: 1));
        final expireDay = DateTime(expiresAt.year, expiresAt.month, expiresAt.day);
        final timeStr = "${expiresAt.hour.toString().padLeft(2, '0')}:${expiresAt.minute.toString().padLeft(2, '0')}";
        
        if (expireDay == today) {
          expirationText = "Today at $timeStr";
        } else if (expireDay == tomorrow) {
          expirationText = "Tomorrow at $timeStr";
        } else {
          const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
          expirationText = "${expiresAt.day} ${months[expiresAt.month - 1]} at $timeStr";
        }
      }

      return Container(
        margin: const EdgeInsets.only(bottom: 20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: darkCard,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.3), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFEF4444).withValues(alpha: 0.04),
              blurRadius: 16,
              spreadRadius: 0,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFEF4444).withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444), size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                   Wrap(
                     spacing: 6,
                     crossAxisAlignment: WrapCrossAlignment.center,
                     children: [
                       const Text(
                         'Waydrop ',
                         style: TextStyle(
                           fontSize: 15,
                           fontWeight: FontWeight.w900,
                           color: Colors.white,
                           letterSpacing: -0.5,
                         ),
                       ),
                       Container(
                         padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                         decoration: BoxDecoration(
                           gradient: const LinearGradient(
                             colors: [
                               Color(0xFFC5FF30),
                               Color(0xFF00FFCC),
                               Color(0xFFC5FF30),
                             ],
                             begin: Alignment.topLeft,
                             end: Alignment.bottomRight,
                           ),
                           borderRadius: BorderRadius.circular(6),
                           boxShadow: [
                             BoxShadow(
                               color: const Color(0xFFC5FF30).withValues(alpha: 0.2),
                               blurRadius: 6,
                               spreadRadius: 0.5,
                             ),
                           ],
                         ),
                         child: const Text(
                           'MAX',
                           style: TextStyle(
                             fontSize: 10,
                             fontWeight: FontWeight.w900,
                             color: Colors.black,
                             letterSpacing: 0.5,
                           ),
                         ),
                       ),
                     ],
                   ),
                  const SizedBox(height: 4),
                  Text(
                    'Plan expired on $expirationText',
                    style: const TextStyle(fontSize: 11, color: textGray, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 36,
              child: ElevatedButton(
                onPressed: () => _showSubscriptionBottomSheet(goingOnline: false),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFEF4444),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: const Text('Extend', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
              ),
            ),
          ],
        ),
      );
    } else {
      return Container(
        margin: const EdgeInsets.only(bottom: 20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: darkCard,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 1.2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 8,
              offset: const Offset(0, 4),
            )
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.star_border_rounded, color: textGray, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                   Wrap(
                     spacing: 6,
                     crossAxisAlignment: WrapCrossAlignment.center,
                     children: [
                       const Text(
                         'Get Waydrop ',
                         style: TextStyle(
                           fontSize: 14,
                           fontWeight: FontWeight.bold,
                           color: Colors.white,
                         ),
                       ),
                       Container(
                         padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                         decoration: BoxDecoration(
                           gradient: const LinearGradient(
                             colors: [
                               Color(0xFFC5FF30),
                               Color(0xFF00FFCC),
                               Color(0xFFC5FF30),
                             ],
                             begin: Alignment.topLeft,
                             end: Alignment.bottomRight,
                           ),
                           borderRadius: BorderRadius.circular(6),
                           boxShadow: [
                             BoxShadow(
                               color: const Color(0xFFC5FF30).withValues(alpha: 0.2),
                               blurRadius: 6,
                               spreadRadius: 0.5,
                             ),
                           ],
                         ),
                         child: const Text(
                           'MAX',
                           style: TextStyle(
                             fontSize: 10,
                             fontWeight: FontWeight.w900,
                             color: Colors.black,
                             letterSpacing: 0.5,
                           ),
                         ),
                       ),
                     ],
                   ),
                  const SizedBox(height: 4),
                  const Text(
                    'Keep 100% of your earnings. Subscribe now!',
                    style: TextStyle(fontSize: 11, color: textGray, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 36,
              child: ElevatedButton(
                onPressed: () => _showSubscriptionBottomSheet(goingOnline: false),
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryLime,
                  foregroundColor: Colors.black,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: const Text('Subscribe', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
              ),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: darkBg,
      body: SafeArea(
        bottom: false,
        child: loading
            ? const SkeletonLoader()
            : ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  const SizedBox(height: 24),
                  _buildHeader(),
                  const SizedBox(height: 24),
                  _buildTodayEarningsCard(),
                  const SizedBox(height: 20),
                  _buildServiceModeCard(),
                  const SizedBox(height: 20),
                  // "Go Online" is the local radius-dispatch mechanism only
                  // (find_nearby_riders / assign_nearby_searching_orders_to_rider) —
                  // Intercity Traveller-mode partners are matched via their
                  // Travel Plans instead, not a live online toggle.
                  if (serviceMode == PartnerServiceMode.local) ...[
                    _buildToggle(),
                    const SizedBox(height: 20),
                  ],
                  // WayDrop MAX (0% commission subscription) only applies to the local radius-dispatch
                  // commission model -- Intercity Traveller-mode partners are matched via Travel Plans
                  // and priced differently, so the offer/banner is not relevant to them.
                  if (serviceMode == PartnerServiceMode.local) _buildSubscriptionBanner(),
                  // Item 4: render one banner per active order instead of only the first, so a
                  // traveller with several concurrently active intercity passengers can see and
                  // open every one of them from Rider Home.
                  if (activeOrders.isNotEmpty) ...[
                    for (final order in activeOrders) ...[
                      _buildActiveOrderBanner(order),
                      const SizedBox(height: 12),
                    ],
                    const SizedBox(height: 8),
                  ],
                  // Travel Plans / "Intercity Traveller" jobs are only ever
                  // relevant to Intercity Traveller-mode partners.
                  if (serviceMode == PartnerServiceMode.intercity)
                    _buildTravelPlansSection(),
                  SizedBox(height: 96 + Insets.bottom(context)), // extra padding for floating nav bar
                ],
              ),
      ),
    );
  }

  Future<void> loadTravelPlans(String riderId, {bool authoritativeChange = false}) async {
    if (!mounted || rider?['id']?.toString() != riderId ||
        serviceMode != PartnerServiceMode.intercity) {
      return;
    }
    if (authoritativeChange) _travelPlanRefresh.invalidate();
    if (travelPlans.isEmpty) {
      setState(() => loadingPlans = true);
    }
    try {
      // Keep complete plan rows and the existing status/count predicates. The
      // coordinator publishes both query results together, never partial data.
      await _travelPlanRefresh.request(riderId);
    } finally {
      if (mounted && rider?['id']?.toString() == riderId) {
        setState(() => loadingPlans = false);
      }
    }
  }

  String extractCity(String address) {
    return LocationDisplayService.resolveCity(
      city: null,
      address: address,
      fallback: 'Other',
    );
  }

  // Issue 2: routed through the single canonical cancel_travel_plan_by_traveller() RPC (via
  // IntercityMatchingService.cancelTravelPlan) instead of a direct rider_travel_plans update.
  // This is the exact call site that previously surfaced "Failed to cancel plan: Cannot cancel
  // this travel plan while a trip is already in progress" for plans that had NOT genuinely
  // started -- root cause was cascade_cancel_travel_plan_dependents() silently rolling back the
  // whole transaction on its first accepted passenger (fixed in migration 20260901000001); the
  // RPC's own trip_started_at-based check now only refuses when a trip has truly started.
  Future<void> _deleteTravelPlan(String planId, String reason) async {
    try {
      final result = await IntercityMatchingService.cancelTravelPlan(
        routeId: planId,
        cancelReason: reason,
      );
      if (!mounted) return;
      if (result['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Travel plan cancelled successfully.'), backgroundColor: Colors.green),
        );
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) loadTravelPlans(rider!['id'], authoritativeChange: true);
        });
      } else {
        final msg = (result['message'] as String?) ?? 'Could not cancel this travel plan.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to cancel plan: $msg')),
        );
      }
    } catch (e) {
      if (mounted) {
        final msg = e is PostgrestException ? e.message : e.toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to cancel plan: $msg')),
        );
      }
    }
  }


  void _showTravelPlanDetails(BuildContext context, Map<String, dynamic> plan) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TravelPlanDetailsScreen(
          plan: plan,
          rider: rider,
          isOnline: isOnline,
          activeOrder: activeOrders,
          loadActiveOrder: loadActiveOrder,
          deleteTravelPlan: _deleteTravelPlan,
          fetchMatchingOrders: _fetchMatchingOrders,
          handleOrderAction: _handleOrderAction,
        ),
      ),
    );
  }
  Future<List<Map<String, dynamic>>> _fetchMatchingOrders(Map<String, dynamic> plan) async {
    try {
      debugPrint('FETCH MATCHING ORDERS => Invoking match-intercity-riders with plan: $plan');
      final response = await supabase.functions.invoke(
        'match-intercity-riders',
        body: {
          'plan': {
            'rider_id': plan['rider_id'],
            'pickup_lat': plan['pickup_lat'],
            'pickup_lng': plan['pickup_lng'],
            'destination_lat': plan['destination_lat'],
            'destination_lng': plan['destination_lng'],
            'weight_preference': plan['weight_preference'],
            'max_weight_kg': plan['max_weight_kg'] ?? (double.tryParse(plan['weight_preference']?.toString() ?? '0') ?? 0.0),
            'travel_plan_type': plan['travel_plan_type'] ?? 'both',
            'vehicle_type': plan['vehicle_type'] ?? 'car',
            'max_bookings': plan['max_bookings'] ?? 3,
            'pickup_city': plan['pickup_city'],
            'destination_city': plan['destination_city'],
            'travel_date': plan['travel_date'],
            'route_geometry': plan['route_geometry'],
          }
        },
      );

      debugPrint('FETCH MATCHING ORDERS => Status: ${response.status}, Data: ${response.data}');

      if (response.data == null || response.data['success'] != true) {
        debugPrint('FETCH MATCHING ORDERS => Failed response or success is not true');
        return [];
      }

      final List matchesList = response.data['matches'] ?? [];
      final list = List<Map<String, dynamic>>.from(matchesList)
          .where((o) => o['user_id'] != plan['rider_id'])
          .toList();

      // Parse cached route points first
      List<dynamic> routePoints = [];
      if (plan['route_geometry'] != null) {
        try {
          final decoded = jsonDecode(plan['route_geometry'].toString());
          if (decoded is List) {
            routePoints = decoded;
          }
        } catch (e) {
          debugPrint('Error parsing cached route_geometry: $e');
        }
      }

      // If cached route is missing, dynamically fetch fallback from directions API
      if (routePoints.isEmpty) {
        final double? planOriginLat = double.tryParse(plan['pickup_lat']?.toString() ?? '');
        final double? planOriginLng = double.tryParse(plan['pickup_lng']?.toString() ?? '');
        final double? planDestLat = double.tryParse(plan['destination_lat']?.toString() ?? '');
        final double? planDestLng = double.tryParse(plan['destination_lng']?.toString() ?? '');

        if (planOriginLat != null && planOriginLng != null && planDestLat != null && planDestLng != null) {
          try {
            final planRoute = await OlaMapService.getDirections(
              originLat: planOriginLat,
              originLng: planOriginLng,
              destinationLat: planDestLat,
              destinationLng: planDestLng,
            );
            if (planRoute != null) {
              routePoints = planRoute.polylinePoints.map((pt) => [pt['lat'], pt['lng']]).toList();
            }
          } catch (e) {
            debugPrint('Error fetching directions fallback: $e');
          }
        }
      }

      // Fetch assignment statuses for this rider
      // Egress fix: narrowed to the 2 fields read below (order_id used as the join key,
      // assignment_status injected into each order).
      final assignmentsRes = await supabase
          .from('rider_assignments')
          .select('order_id, assignment_status')
          .eq('rider_id', plan['rider_id']);
      final assignments = List<Map<String, dynamic>>.from(assignmentsRes);

      // Inject assignment statuses into the order objects
      return list.map((order) {
        final ass = assignments.firstWhere(
          (a) => a['order_id'] == order['id'],
          orElse: () => {},
        );
        return {
          ...order,
          'assignment_status': ass['assignment_status'],
        };
      }).toList();

    } catch (e) {
      debugPrint('Error fetching matching orders: $e');
      return [];
    }
  }

  Future<void> _handleOrderAction(BuildContext context, Map<String, dynamic> order, StateSetter setSheetState) async {
    if (rider == null) return;
    final riderId = rider!['id'];

    if (!isOnline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please go online to accept orders.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final String? assignmentStatus = order['assignment_status']?.toString();
    final diagnosticAttempt = _rideDiagnosticOwner.begin(ride: order['id']?.toString(), endpoint: RideEndpoint.acceptance, status: 'accepted');

    if (assignmentStatus == 'accepted_by_user') {
      // Step 2: Passenger accepted rider -> Rider does final confirmation to start!
      if (_activeOrderEvidenceUnresolved || activeOrders.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You cannot accept another order while having an active order in progress.'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      try {
        final response = await _rideDiagnosticOwner.api(RideEndpoint.acceptance, order['id']?.toString(), () => supabase.functions.invoke(
          'accept-order',
          body: {
            'order_id': order['id'],
            'rider_id': riderId,
          },
        ), status: 'accepted', attempt: diagnosticAttempt);

        if (response.data == null || response.data['success'] != true) {
          throw Exception(response.data?['message'] ?? 'Failed to accept order');
        }

        if (!mounted) return;
        Navigator.pop(context); // Close details sheet

        await loadActiveOrder(riderId);

        if (!mounted) return;
        // Amplification-reduction pass (fetchRiderProfile audit): this tab already holds a fresh
        // rider/todayEarnings snapshot (kept live via subscribeRider's realtime callback) -- hand
        // it to the active-order screen instead of letting it re-fetch the same data on open.
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => RiderActiveOrderScreen(
              orderId: order['id'],
              initialRiderProfile: rider,
              initialRiderProfileUserId: _riderProfileOwnerUserId,
              initialEarningsSeed: _initialEarningsSeed,
            ),
          ),
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error accepting order: ${e.toString().replaceAll('Exception:', '').trim()}'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    } else {
      // Step 1: Rider sends delivery offer -> Inserts assignment as 'sent'
      try {
        // Egress fix: only existence + `id` (used for the update below) are read.
        final existingList = await supabase
            .from('rider_assignments')
            .select('id')
            .eq('order_id', order['id'])
            .eq('rider_id', riderId)
            .order('created_at', ascending: false)
            .limit(1);
        final existing = (existingList as List).isNotEmpty ? (existingList as List).first : null;

        if (existing == null) {
          final double fare = double.tryParse(order['proposed_fare']?.toString() ?? order['rider_earning']?.toString() ?? order['current_fare']?.toString() ?? '0') ?? 0.0;
          await supabase.from('rider_assignments').insert({
            'order_id': order['id'],
            'rider_id': riderId,
            'assignment_round': 1,
            'assignment_status': 'sent',
            'distance_km': 0.0,
            'estimated_earnings': fare,
            'sent_at': DateTime.now().toUtc().toIso8601String(),
            'expires_at': DateTime.now().add(const Duration(hours: 24)).toUtc().toIso8601String(),
          });
        } else {
          final double fare = double.tryParse(order['proposed_fare']?.toString() ?? order['rider_earning']?.toString() ?? order['current_fare']?.toString() ?? '0') ?? 0.0;
          await supabase.from('rider_assignments').update({
            'assignment_status': 'sent',
            'estimated_earnings': fare,
            'expires_at': DateTime.now().add(const Duration(hours: 24)).toUtc().toIso8601String(),
            'responded_at': null,
          }).eq('id', existing['id']);
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Delivery offer sent to user!'),
              backgroundColor: Colors.green,
            ),
          );
        }

        // Re-fetch/rebuild the sheet
        setSheetState(() {});
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error sending offer: $e'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    }
  }



  Widget _buildTravelPlansSection() {
    final activePlansCount = travelPlans.where((p) => p['status'] == 'active').length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Row(
                children: [
                  const Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'Intercity Travel Plans',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      "$activePlansCount/3 active",
                      style: const TextStyle(color: textGray, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.dashboard_rounded, color: primaryLime, size: 22),
                  tooltip: 'Bookings Dashboard',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const IntercityBookingsScreen(),
                      ),
                    ).then((_) {
                      if (rider != null) loadTravelPlans(rider!['id'], authoritativeChange: true);
                    });
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline_rounded, color: primaryLime, size: 22),
                  tooltip: 'Post Travel Plan',
                  onPressed: () {
                // Intercity Traveller mode has no "Go Online" toggle (see
                // build()'s serviceMode == local guard on _buildToggle()) —
                // match-intercity-riders only uses account_status as a
                // scoring bonus, never a hard requirement, so posting a
                // travel plan must not depend on being online.
                if (activePlansCount >= 3) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('You can only have a maximum of 3 active travel plans.'),
                      backgroundColor: Colors.orange,
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                  return;
                }
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => PostTravelPlanScreen(
                      riderId: rider!['id'],
                      onPlanPosted: (insertedPlan) {
                        if (mounted) {
                          _showTravelPlanDetails(context, Map<String, dynamic>.from(insertedPlan));
                          loadTravelPlans(rider!['id'], authoritativeChange: true);
                        }
                      },
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ],
    ),
    const SizedBox(height: 10),
        (loadingPlans && travelPlans.isEmpty)
            ? const Center(child: CircularProgressIndicator(color: primaryLime))
            : travelPlans.isEmpty
                ? Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: darkCard,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Center(
                      child: Text(
                        'No travel plans posted. Post your route to match with intercity parcel or ride orders.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: textGray, fontSize: 13),
                      ),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: travelPlans.length,
                    itemBuilder: (context, index) {
                      final plan = travelPlans[index];
                      final date = DateTime.parse(plan['travel_date']).toLocal();
                      final dateStr = "${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}";
                      final timeStr = "${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}";
                      final dateTimeStr = "$dateStr • $timeStr";
                      return GestureDetector(
                        onTap: () => _showTravelPlanDetails(context, plan),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: darkCard,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 1),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Location Details First
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              const Text(
                                                'PICKUP CITY',
                                                style: TextStyle(
                                                  fontSize: 8.5,
                                                  fontWeight: FontWeight.bold,
                                                  color: textGray,
                                                  letterSpacing: 0.5,
                                                ),
                                              ),
                                              const SizedBox(height: 3),
                                              Text(
                                                LocationDisplayService.resolveCity(
                                                  city: plan['pickup_city'],
                                                  address: plan['pickup_address'],
                                                  fallback: 'Pickup Location',
                                                ),
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.white,
                                                  fontSize: 14,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ],
                                          ),
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 10),
                                          child: Icon(
                                            Icons.swap_horiz_rounded,
                                            color: primaryLime.withValues(alpha: 0.8),
                                            size: 18,
                                          ),
                                        ),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              const Text(
                                                'DESTINATION CITY',
                                                style: TextStyle(
                                                  fontSize: 8.5,
                                                  fontWeight: FontWeight.bold,
                                                  color: textGray,
                                                  letterSpacing: 0.5,
                                                ),
                                              ),
                                              const SizedBox(height: 3),
                                              Text(
                                                LocationDisplayService.resolveCity(
                                                  city: plan['destination_city'],
                                                  address: plan['destination_address'],
                                                  fallback: 'Drop Location',
                                                ),
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.white,
                                                  fontSize: 14,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    const Divider(color: Colors.white10, height: 24, thickness: 1),
                                    // Travel Specs Row (Date, Time, Type, Vehicle)
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Row(
                                          children: [
                                            const Icon(Icons.access_time_rounded, color: primaryLime, size: 13),
                                            const SizedBox(width: 6),
                                            Text(
                                              dateTimeStr,
                                              style: const TextStyle(
                                                color: Colors.white70,
                                                fontSize: 11,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ],
                                        ),
                                        Row(
                                          children: [
                                            Icon(
                                              plan['travel_plan_type'] == 'ride'
                                                  ? Icons.directions_car_rounded
                                                  : Icons.inventory_2_rounded,
                                              color: textGray,
                                              size: 13,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              plan['travel_plan_type']?.toString().toUpperCase() ?? 'BOTH',
                                              style: const TextStyle(
                                                color: Colors.white70,
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            const Text(
                                              '•',
                                              style: TextStyle(color: Colors.white24, fontSize: 11),
                                            ),
                                            const SizedBox(width: 6),
                                            Icon(
                                              plan['vehicle_type'] == 'bike'
                                                  ? Icons.two_wheeler_rounded
                                                  : Icons.directions_car_rounded,
                                              color: textGray,
                                              size: 13,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              plan['vehicle_type']?.toString().toUpperCase() ?? 'CAR',
                                              style: const TextStyle(
                                                color: Colors.white70,
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                    Builder(builder: (context) {
                                      final planId = plan['id'].toString();
                                      final accepted = _planAcceptedCounts[planId] ?? 0;
                                      final pending = _planPendingCounts[planId] ?? 0;
                                      if (accepted == 0 && pending == 0) return const SizedBox.shrink();
                                      return Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Divider(color: Colors.white10, height: 20, thickness: 1),
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              Row(
                                                children: [
                                                  if (accepted > 0)
                                                    Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                      decoration: BoxDecoration(
                                                        color: primaryLime.withValues(alpha: 0.14),
                                                        borderRadius: BorderRadius.circular(8),
                                                      ),
                                                      child: Text(
                                                        '$accepted Accepted',
                                                        style: const TextStyle(color: primaryLime, fontSize: 11, fontWeight: FontWeight.bold),
                                                      ),
                                                    ),
                                                  if (accepted > 0 && pending > 0) const SizedBox(width: 8),
                                                  if (pending > 0)
                                                    Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                      decoration: BoxDecoration(
                                                        color: Colors.orangeAccent.withValues(alpha: 0.14),
                                                        borderRadius: BorderRadius.circular(8),
                                                      ),
                                                      child: Text(
                                                        '$pending Pending',
                                                        style: const TextStyle(color: Colors.orangeAccent, fontSize: 11, fontWeight: FontWeight.bold),
                                                      ),
                                                    ),
                                                ],
                                              ),
                                              TextButton(
                                                onPressed: () => _showTravelPlanDetails(context, plan),
                                                style: TextButton.styleFrom(
                                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                                  minimumSize: Size.zero,
                                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                ),
                                                child: const Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Text('View Trip', style: TextStyle(color: primaryLime, fontSize: 12, fontWeight: FontWeight.bold)),
                                                    SizedBox(width: 2),
                                                    Icon(Icons.arrow_forward_ios_rounded, color: primaryLime, size: 11),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      );
                                    }),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
      ],
    );
  }


  Widget _buildHeader() {
    final name = rider?['full_name'] ?? 'Rider';
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Hello',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w300,
                color: textGray,
              ),
            ),
            Text(
              name,
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                height: 1.1,
              ),
            ),
          ],
        ),
        Row(
          children: [
            GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const NotificationsInboxScreen()),
                );
              },
              child: NotificationBellBadge(
                child: Container(
                  width: 44,
                  height: 44,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    color: darkCard,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24, width: 1.5),
                  ),
                  child: const Icon(Icons.notifications_none_rounded, color: Colors.white, size: 22),
                ),
              ),
            ),
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: darkCard,
                shape: BoxShape.circle,
                border: Border.all(color: isOnline ? primaryLime : Colors.white24, width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: (isOnline ? primaryLime : Colors.transparent).withValues(alpha: 0.15),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: ClipOval(
                child: (rider?['rider_image'] != null && rider!['rider_image'].toString().startsWith('http'))
                    ? CachedNetworkImage(
                        imageUrl: rider!['rider_image'].toString(),
                        fit: BoxFit.cover,
                        fadeInDuration: Duration.zero,
                        fadeOutDuration: Duration.zero,
                        placeholder: (ctx, url) => const ImageSkeleton(shape: BoxShape.circle),
                        errorWidget: (ctx, url, err) => const Icon(Icons.person_rounded, color: Colors.white, size: 26),
                      )
                    : const Icon(Icons.person_rounded, color: Colors.white, size: 26),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTodayEarningsCard() {
    final today = todayEarnings;
    final grossAvailable = _grossEarningsScope?.key == _currentEarningsScope?.key &&
        _grossEarningsScope != null;
    final wallet = rider?['wallet_balance'] ?? 0;
    return Container(
      width: double.infinity,
      height: 200,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: primaryLime,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Stack(
        children: [
          // 3D Wallet Illustration Image
          Positioned(
            right: -10,
            bottom: -10,
            top: -10,
            child: Image.asset(
              'assets/images/3d_wallet_illustration.png',
              width: 200,
              height: 200,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  width: 140,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 24),
                  child: Icon(
                    Icons.account_balance_wallet_rounded,
                    size: 80,
                    color: darkBg.withValues(alpha: 0.2),
                  ),
                );
              },
            ),
          ),
          // Content
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Today earning section
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Today's Gross Earnings",
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.black.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        grossAvailable ? '₹${_fmt(today)}' : 'Unavailable',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: Colors.black,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                // Wallet section
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Wallet Balance',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.black.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '₹${_fmt(wallet)}',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: Colors.black,
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
    );
  }

  Future<void> _openServiceModeSheet() async {
    final mode = serviceMode;
    if (mode == null || rider == null) return;
    final changed = await showServiceModeChangeSheet(context, currentMode: mode);
    if (changed) {
      await _refreshAfterServiceModeChange();
    }
  }

  // Runs immediately after riders.service_mode is written by the bottom
  // sheet (see showServiceModeChangeSheet's _save). loadRider() re-fetches
  // the rider row (UI refresh), re-subscribes/unsubscribes the travel plans
  // realtime channel for the new mode (realtime refresh), and recomputes the
  // active-assignments badge (matching refresh). The notifications inbox and
  // Orders-tab badge both read from that same freshly-updated state, so no
  // separate notification refresh call is needed.
  Future<void> _refreshAfterServiceModeChange() async {
    await loadRider();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Service mode updated'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Widget _buildServiceModeCard() {
    final mode = serviceMode;
    return InkWell(
      onTap: _openServiceModeSheet,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: darkCard,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: primaryLime.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: primaryLime.withValues(alpha: 0.3), width: 1.5),
              ),
              child: Icon(
                mode == PartnerServiceMode.intercity ? Icons.alt_route_rounded : Icons.tune_rounded,
                color: primaryLime,
                size: 26,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'SERVICE MODE',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: textGray,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    mode?.label ?? 'Not set',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: Colors.white),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: Colors.white.withValues(alpha: 0.3), size: 22),
          ],
        ),
      ),
    );
  }

  Widget _buildToggle() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: darkCard,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 1.5),
      ),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: isOnline ? primaryLime.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(18),
              border: isOnline ? Border.all(color: primaryLime.withValues(alpha: 0.3), width: 1.5) : null,
            ),
            child: Icon(
              isOnline ? Icons.sensors_rounded : Icons.sensors_off_rounded,
              color: isOnline ? primaryLime : textGray,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _offlineStatusEvidence.unknown ? 'Account status unconfirmed' :
                  _trackingRecoveryUnavailable ? 'Location tracking unavailable' :
                      (isOnline ? 'You are Online' : 'You are Offline'),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const SizedBox(height: 2),
                Text(
                  _offlineStatusEvidence.unknown ? 'Online actions paused until refresh' :
                  _trackingRecoveryUnavailable ? 'Check GPS and location permission' :
                      (isOnline ? 'Active & receiving orders' : 'Inactive, tap to go online'),
                  style: const TextStyle(fontSize: 12, color: textGray, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
          // Custom Premium Toggle Switch
          GestureDetector(
            onTap: toggleOnlineStatus,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 58,
              height: 32,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: isOnline ? primaryLime : Colors.white12,
              ),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 250),
                alignment: isOnline ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 26,
                  height: 26,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isOnline ? Colors.black : Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
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
  }

  Widget _buildActiveOrderBanner(Map<String, dynamic> order) {
    final code = order['order_code'] ?? '';
    final status = order['order_status'] ?? '';
    final type = order['order_type'] ?? 'ride';
    final isParcel = type == 'local_parcel' || type == 'intercity_parcel';
    final isIntercity = type == 'intercity_ride' || type == 'intercity_parcel';
    // Item: Active Task card must identify the passenger by name, not just an order code --
    // with several concurrently active intercity passengers, "#code" alone made it easy to open
    // the wrong one. For intercity trips the route uses city names ("Warangal -> Bhadrachalam")
    // and shows the scheduled travel time, matching what the card looks like once opened.
    final passengerName = order['users']?['full_name']?.toString();
    final pickup = isIntercity
        ? LocationDisplayService.resolveCity(city: order['pickup_city'], address: order['pickup_address'], fallback: 'Pickup')
        : (order['pickup_address'] ?? 'Pickup');
    final dest = isIntercity
        ? LocationDisplayService.resolveCity(city: order['destination_city'], address: order['destination_address'], fallback: 'Destination')
        : (order['destination_address'] ?? 'Destination');
    final travelDate = order['travel_date'] != null ? DateTime.tryParse(order['travel_date'].toString())?.toLocal() : null;
    final vehicleType = order['vehicle_type']?.toString().toLowerCase() ?? 'bike';
    
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
    
    final String imagePath;
    if (isIntercity) {
      imagePath = 'assets/images/intercity.png';
    } else if (isParcel) {
      imagePath = 'assets/images/delivery.png';
    } else {
      imagePath = 'assets/images/$vehicleImg.jpg';
    }
    
    return GestureDetector(
      onTap: () {
        if (order['id'] != null) {
          // Amplification-reduction pass (fetchRiderProfile audit): same reasoning as the accept
          // flow above -- this tab's own rider/todayEarnings state is already fresh, so hand it in
          // instead of letting the active-order screen re-fetch it on open.
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => RiderActiveOrderScreen(
                orderId: order['id'],
                initialRiderProfile: rider,
                initialRiderProfileUserId: _riderProfileOwnerUserId,
                initialEarningsSeed: _initialEarningsSeed,
              ),
            ),
          );
        }
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: darkCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: primaryLime.withValues(alpha: 0.15), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: primaryLime.withValues(alpha: 0.05),
              blurRadius: 16,
              spreadRadius: 0,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            // Left circular vehicle or parcel asset image
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: primaryLime.withValues(alpha: 0.3), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: primaryLime.withValues(alpha: 0.1),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.asset(
                  imagePath,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return Image.asset(
                      'assets/images/delivery.png',
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return Container(
                          color: primaryLime.withValues(alpha: 0.1),
                          child: Icon(
                            isParcel ? Icons.local_shipping_rounded : Icons.directions_car_rounded,
                            color: primaryLime,
                            size: 24,
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 16),
            
            // Middle Details
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: primaryLime.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'ACTIVE TASK',
                          style: TextStyle(
                            color: primaryLime,
                            fontSize: 8.5,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          (passengerName != null && passengerName.isNotEmpty) ? passengerName : '#$code',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    status.toString().replaceAll('_', ' ').toUpperCase(),
                    style: const TextStyle(
                      color: primaryLime,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$pickup → $dest',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: textGray,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (isIntercity && travelDate != null) ...[
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(Icons.schedule_rounded, color: textGray.withValues(alpha: 0.7), size: 11),
                        const SizedBox(width: 4),
                        Text(
                          TimeFormatHelper.formatDateTime12Hour(travelDate),
                          style: TextStyle(
                            color: textGray.withValues(alpha: 0.9),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            
            // Right Chevron
            Icon(
              Icons.chevron_right_rounded,
              color: primaryLime.withValues(alpha: 0.6),
              size: 24,
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(dynamic v) => (double.tryParse('$v') ?? 0.0).toStringAsFixed(2);
}



