import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_payout_details_screen.dart';
import 'package:waydrop/shared/widgets/app_snackbar.dart';
import 'package:waydrop/shared/widgets/skeleton_loader.dart';
import 'package:waydrop/shared/helpers/insets.dart';
import 'package:waydrop/models/payment_for.dart';
import 'package:waydrop/modules/payments/services/payment_service.dart';
import 'package:waydrop/modules/payments/services/payment_debug_trace.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/core/providers/initial_data_provider.dart';
import 'package:waydrop/core/services/database/government_tax_ledger_cache.dart';
import 'package:waydrop/core/services/database/rider_payout_account_cache.dart';
import 'package:waydrop/main.dart';
import 'package:waydrop/shared/helpers/fare_presentation_helper.dart';

class RiderEarningsTab extends StatefulWidget {
  // [PERF] whether this tab is the currently visible/selected tab inside
  // RiderMainNavigationScreen's IndexedStack. Defaults to true so any call site that doesn't pass
  // it keeps running exactly as before. Mirrors RiderOrdersScreen.isActive: only pauses the
  // riders-row realtime subscription (a pure display refresh with no dispatch side effects) while
  // this tab is off-screen; everything else is untouched.
  final bool isActive;

  const RiderEarningsTab({super.key, this.isActive = true});

  @override
  State<RiderEarningsTab> createState() => _RiderEarningsTabState();
}

class _RiderEarningsTabState extends State<RiderEarningsTab> {
  final supabase = Supabase.instance.client;
  Map<String, dynamic>? rider;
  double todayEarnings = 0.0;
  // Distinguishes "today's gross earnings is genuinely ₹0 (no completed rides today)" from "the
  // orders query that computes it failed and was silently swallowed" -- previously indistinguishable
  // from the UI's point of view, both rendering as a confident-looking "₹0.00" with no indication
  // anything went wrong. riders.today_earnings (shown on the Home tab) is a separate, server-side
  // running total that is never reset by any trigger/cron in this codebase (confirmed: only ever
  // incremented, in credit_rider_for_completed_order) -- it is NOT scoped to the calendar day
  // despite its name, so it must never be treated as ground truth for "today" reconciliation; this
  // orders-query-derived value (filtered by completed_at's actual local calendar date) is the
  // authoritative one. This flag exists purely so a genuine fetch failure is visibly distinct from
  // a real zero, never to change what counts as gross earnings.
  bool _todayEarningsUnavailable = false;
  List<Map<String, dynamic>> recentOrders = [];
  // Latest 3 completed rides EVER (no 30-day restriction) -- distinct from `recentOrders` above,
  // which is deliberately windowed to the last 30 days for the analytics chart/averages below and
  // must stay exactly as-is (see the egress-fix comments on that query). Using the SAME windowed
  // list to also decide "No Completed Trips Yet" was the actual bug: a partner whose only completed
  // ride fell outside that 30-day window (while Order History, which has no such window, still
  // showed it) saw the empty state despite having a real completed ride. This list exists purely to
  // answer "has this partner ever completed a ride, and what are the latest 3" -- server-limited to
  // 3 rows, same status/ordering filter Order History already uses.
  List<Map<String, dynamic>> recentCompletedRides = [];
  Map<String, dynamic>? payoutAccount;
  List<Map<String, dynamic>> recentWithdrawals = [];
  String? _withdrawalsSubChannel;
  String? _withdrawalsSubId;
  String? _riderSubChannel;
  String? _riderSubId;
  bool isPayoutActive = false;
  bool loading = true;
  Map<String, dynamic>? activeOrder;

  // R1 FIX #5: distinguishes a true cold-start mount (initialRiderDataProvider's snapshot is
  // guaranteed fresh -- fetched by AppStartScreen moments earlier in the same navigation
  // transition) from a mid-session recreation (returnToLocalRideHome()'s pushAndRemoveUntil
  // rebuilds RiderMainNavigationScreen and, with it, a brand-new _RiderEarningsTabState -- the
  // same never-refreshed snapshot would otherwise be stale there). `static` survives individual
  // State disposal but not a process restart, so this is false exactly once per app launch and
  // true for every subsequent _RiderEarningsTabState construction within that same process.
  // Scoped to this class only -- intentionally independent of RiderMainNavigationScreen's,
  // RiderHomeTab's, and RiderOrdersScreen's own identically-shaped flags.
  static bool _hasConsumedColdStartSeed = false;

  // Government Tax Due -- server-authoritative balance (riders.government_tax_due_balance) and
  // the server-configured blocking threshold (government_tax_config), fetched fresh each load so
  // a rate/threshold change never needs a client rebuild. Entirely independent of the ₹40/₹280
  // subscription shown above/below it.
  double taxDueThreshold = 100.0;
  bool _payingTaxDue = false;

  // COD Settlement ("Cash to be Paid") -- server-authoritative balance
  // (riders.cod_pending_amount) and blocking threshold (riders.cod_limit), same
  // read-only/server-derived pattern as Government Tax Due above.
  bool _payingCodSettlement = false;

  // New Analytics state
  List<DailyMetrics> dailyMetricsList = [];
  DateTime? selectedDay;
  String selectedMetric = 'Earnings'; // 'Earnings', 'Active Time', 'Orders'
  int selectedRange = 7; // 7 or 30
  double thisWeekEarnings = 0.0;
  double thisMonthEarnings = 0.0;
  double avgEarningsPerDay = 0.0;
  double avgOrdersPerDay = 0.0;
  double avgEarningsPerOrder = 0.0;

  static const primaryLime = Color(0xFFC5FF30);
  static const darkBg = Color(0xFF0B0F19);
  static const darkCard = Color(0xFF131926);
  static const textGray = Color(0xFF94A3B8);

  // PERF FIX (P7, rider location write-volume audit): the exact riders columns this tab's `build()`
  // and settlement flows read off `rider` (verified by grep across this file -- `today_earnings`
  // is NOT among them; todayEarnings/thisWeekEarnings/thisMonthEarnings are always computed from
  // the real date-scoped `orders` query in fetchData(), never from rider['today_earnings'], and
  // that calculation is unchanged by this gate). A realtime `riders` UPDATE whose changed columns
  // are a subset of LocationCacheService's GPS heartbeat fields (current_lat/current_lng/
  // current_heading/last_location_updated_at/last_active_at/updated_at) can never affect any of
  // this and is safe to skip the 7+-query fetchData() reload for. Kept as an explicit allowlist
  // (not a blocklist), same reasoning as RiderHomeTab's own _earningsRelevantFields -- any *new*
  // field this tab starts depending on in the future safely falls through to a refresh by default.
  static const Set<String> _earningsUiRelevantFields = {
    'total_earnings',
    'wallet_balance',
    'cod_pending_amount',
    'cod_limit',
    'government_tax_due_balance',
    'subscription_active',
  };



  @override
  void initState() {
    super.initState();
    fetchData();
    syncWithdrawals();
    _subscribeWithdrawals();
  }

  @override
  void didUpdateWidget(covariant RiderEarningsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive != oldWidget.isActive) {
      if (widget.isActive) {
        // Tab became visible again -- refresh immediately (the realtime subscription was paused,
        // so the displayed data may be stale) then let _subscribeRider() re-attach as normal.
        fetchData();
      } else if (_riderSubChannel != null && _riderSubId != null) {
        RealtimeManager.instance.unsubscribe(_riderSubChannel!, _riderSubId!);
        _riderSubChannel = null;
        _riderSubId = null;
        _subscribedRiderId = null;
      }
    }
  }

  @override
  void dispose() {
    if (_withdrawalsSubChannel != null && _withdrawalsSubId != null) {
      RealtimeManager.instance.unsubscribe(_withdrawalsSubChannel!, _withdrawalsSubId!);
      _withdrawalsSubChannel = null;
      _withdrawalsSubId = null;
    }
    if (_riderSubChannel != null && _riderSubId != null) {
      RealtimeManager.instance.unsubscribe(_riderSubChannel!, _riderSubId!);
      _riderSubChannel = null;
      _riderSubId = null;
    }
    super.dispose();
  }

  // Egress fix (Fix #9): routed through the app's shared RealtimeManager instead of a raw
  // supabase.channel() call, matching every other subscription in this file (and app) --
  // reconnect/backoff and disposal now go through the same pooled lifecycle as the rest of the
  // app instead of a separate, manually-managed socket. Channel name scoped per-user (the raw
  // channel this replaces used a single fixed name for every rider, which only avoided colliding
  // with itself because raw supabase.channel() calls never pooled by name in the first place).
  // Same table/event/filter/callback behavior as before -- any withdrawal event for this user
  // still unconditionally triggers fetchData().
  void _subscribeWithdrawals() {
    final user = supabase.auth.currentUser;
    if (user == null) return;

    if (_withdrawalsSubChannel != null && _withdrawalsSubId != null) {
      RealtimeManager.instance.unsubscribe(_withdrawalsSubChannel!, _withdrawalsSubId!);
      _withdrawalsSubChannel = null;
      _withdrawalsSubId = null;
    }
    _withdrawalsSubChannel = 'rider-withdrawals-${user.id}';
    _withdrawalsSubId = RealtimeManager.instance.subscribe(
      channelName: _withdrawalsSubChannel!,
      table: 'rider_withdrawals',
      owner: 'RiderEarningsTab_Withdrawals',
      event: PostgresChangeEvent.all,
      schema: 'public',
      filterColumn: 'user_id',
      filterValue: user.id,
      callback: (payload) {
        fetchData();
      },
    );
  }

  String? _subscribedRiderId;

  void _subscribeRider(String riderId) {
    if (_subscribedRiderId == riderId) return;
    _subscribedRiderId = riderId;
    if (_riderSubChannel != null && _riderSubId != null) {
      RealtimeManager.instance.unsubscribe(_riderSubChannel!, _riderSubId!);
      _riderSubChannel = null;
      _riderSubId = null;
    }
    // PERF FIX (P0/P7): join the same pooled channel RiderHomeTab/RiderOrdersScreen already use
    // for this exact rider row (table='riders', event=update, filterColumn='id', filterValue=
    // riderId all identical -- confirmed against RiderHomeTab.subscribeRider() and
    // RiderOrdersScreen.listenRiderStatus() before making this change) instead of opening a
    // second, separate realtime socket subscription via a raw supabase.channel() call for data
    // this tab was already receiving redundantly. RealtimeManager fans this callback out
    // independently of every other listener on the same channel, so this is purely additive --
    // it changes nothing about what RiderHomeTab/RiderOrdersScreen receive or do.
    _riderSubChannel = 'rider-home-$riderId';
    _riderSubId = RealtimeManager.instance.subscribe(
      channelName: _riderSubChannel!,
      table: 'riders',
      owner: 'RiderEarningsTab',
      event: PostgresChangeEvent.update,
      schema: 'public',
      filterColumn: 'id',
      filterValue: riderId,
      callback: (payload) {
        if (!mounted) return;
        final oldData = payload.oldRecord;
        final newData = payload.newRecord;
        // Conservative fallback (matches RiderHomeTab's own gating): if oldRecord is empty (no
        // diff available), treat every key as changed rather than silently skipping.
        final isEarningsUiRelevantUpdate = oldData.isEmpty ||
            newData.keys
                .where((key) => !oldData.containsKey(key) || oldData[key] != newData[key])
                .any(_earningsUiRelevantFields.contains);
        if (isEarningsUiRelevantUpdate) {
          fetchData();
        }
      },
    );
  }

  Future<void> syncWithdrawals() async {
    try {
      await supabase.functions.invoke(
        'create-rider-withdrawal',
        method: HttpMethod.get,
      );
    } catch (syncErr) {
      debugPrint('Withdrawal sync background error => $syncErr');
    }
  }

  Future<void> fetchData() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;

      // Finding A (WayDrop Performance Roadmap Phase 5): government_tax_config has no dependency
      // on riderData, so it's started here -- concurrently with the riders fetch below -- instead
      // of after every other query has already finished. Same query, same try/catch, same fallback
      // value; only when it starts changes.
      double fetchedTaxDueThreshold = 100.0;
      final taxDueFuture = () async {
        try {
          final thresholdRow = await supabase
              .from('government_tax_config')
              .select('threshold_amount')
              .eq('is_active', true)
              .order('updated_at', ascending: false)
              .limit(1)
              .maybeSingle();
          if (thresholdRow != null) {
            fetchedTaxDueThreshold = double.tryParse('${thresholdRow['threshold_amount']}') ?? 100.0;
          }
        } catch (err) {
          debugPrint('Error fetching government tax due threshold: $err');
        }
      }();

      // R1 FIX #5: a true cold start reuses AppStartScreen's already-fetched riders row instead
      // of re-querying an identical row a moment later -- safe because nothing can have changed
      // server-side between that fetch and this mount. The seed is a `select('*', ...)` fetch of
      // the same table/row, so it covers every field this tab reads.
      final seedRider = providerContainer.read(initialRiderDataProvider)?.rider;
      final Map<String, dynamic> riderData;
      if (seedRider != null && seedRider['id'] != null && !_hasConsumedColdStartSeed) {
        _hasConsumedColdStartSeed = true;
        riderData = seedRider;
      } else {
        // Egress fix: narrowed from `*` to the exact columns this tab reads (grepped
        // exhaustively across every `rider?['...']`/`rider!['...']` access in this file --
        // matches the existing _earningsUiRelevantFields allowlist above plus `id`, needed
        // for _subscribeRider() and the per-order queries below).
        riderData = await supabase
            .from('riders')
            .select('id, total_earnings, wallet_balance, cod_pending_amount, cod_limit, government_tax_due_balance, subscription_active')
            .eq('user_id', user.id)
            .single();
      }

      _subscribeRider(riderData['id']);

      final thirtyDaysAgo = DateTime.now().subtract(const Duration(days: 30)).toUtc();

      // Finding A: the five queries below only depend on riderData['id']/user.id (already resolved
      // above), not on each other -- previously each was awaited one at a time. Each keeps its
      // exact original try/catch body and fallback value; they now just run concurrently via
      // Future.wait below instead of sequentially.
      List<Map<String, dynamic>> ordersData = [];
      final ordersFuture = () async {
        try {
          // Egress fix: narrowed from `*` to the exact columns read from this result
          // (grepped exhaustively across processOrdersData(), day.orders, and
          // _ExpandableOrderCard -- the only 3 places these rows are ever consumed).
          final res = await supabase
              .from('orders')
              .select('id, order_code, order_type, completed_at, created_at, picked_up_at, accepted_at, rider_earning, boost_amount, distance_km, time_taken_seconds, vehicle_type, final_fare, current_fare, gst_amount, gst_percentage, pg_charge_amount, commission_amount, commission_percentage, subscription_commission_waived, fare_payment_method, payment_mode, payment_status')
              .eq('rider_id', riderData['id'])
              .inFilter('order_status', ['completed', 'delivered'])
              .gte('completed_at', thirtyDaysAgo.toIso8601String())
              .order('completed_at', ascending: false);
          ordersData = List<Map<String, dynamic>>.from(res);
          _todayEarningsUnavailable = false;
        } catch (err) {
          debugPrint('Error fetching orders: $err');
          // Previously this failure was invisible: ordersData stayed [], and every downstream
          // figure (Today's Gross Earnings included) silently rendered as a confident "₹0.00"
          // indistinguishable from a real zero. Flagging it lets the UI show the difference.
          _todayEarningsUnavailable = true;
        }
      }();

      // Latest 3 completed rides ever, server-limited (no 30-day window, no over-fetch of full
      // history) -- same status filter/ordering Order History already uses for the identical
      // "has this rider ever completed a ride" question, just capped to 3 rows here instead of 50.
      List<Map<String, dynamic>> recentCompletedRidesData = [];
      final recentCompletedRidesFuture = () async {
        try {
          final res = await supabase
              .from('orders')
              .select('id, order_code, order_type, completed_at, created_at, picked_up_at, accepted_at, rider_earning, boost_amount, distance_km, time_taken_seconds, vehicle_type, final_fare, current_fare, gst_amount, gst_percentage, pg_charge_amount, commission_amount, commission_percentage, subscription_commission_waived, fare_payment_method, payment_mode, payment_status')
              .eq('rider_id', riderData['id'])
              .inFilter('order_status', ['completed', 'delivered'])
              .order('completed_at', ascending: false)
              .limit(3);
          recentCompletedRidesData = List<Map<String, dynamic>>.from(res);
        } catch (err) {
          debugPrint('Error fetching recent completed rides: $err');
        }
      }();

      List<Map<String, dynamic>> activityData = [];
      final activityFuture = () async {
        try {
          final thirtyDaysAgoLocal = DateTime.now().subtract(const Duration(days: 30));
          final thirtyDaysAgoStr = "${thirtyDaysAgoLocal.year}-${thirtyDaysAgoLocal.month.toString().padLeft(2, '0')}-${thirtyDaysAgoLocal.day.toString().padLeft(2, '0')}";
          // Egress fix: narrowed from `*` to the exact columns read (grepped
          // exhaustively -- only date/online_seconds/last_online_toggle_at are ever
          // read off `act` in the day-grouping loop above).
          final res = await supabase
              .from('rider_daily_activity')
              .select('date, online_seconds, last_online_toggle_at')
              .eq('rider_id', riderData['id'])
              .gte('date', thirtyDaysAgoStr)
              .order('date', ascending: true);
          activityData = List<Map<String, dynamic>>.from(res);
        } catch (err) {
          debugPrint('Error fetching daily activity (table might not exist yet): $err');
        }
      }();

      Map<String, dynamic>? activeOrderData;
      final activeOrderFuture = () async {
        try {
          // Egress fix: narrowed from `*` to the exact columns read (grepped
          // exhaustively -- activeOrder is only ever used for a null-check plus
          // picked_up_at/accepted_at/created_at, to compute activeOrderStart above).
          final res = await supabase
              .from('orders')
              .select('picked_up_at, accepted_at, created_at')
              .eq('rider_id', riderData['id'])
              .inFilter('order_status', ['accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing'])
              .maybeSingle();
          activeOrderData = res;
        } catch (err) {
          debugPrint('Error fetching active order on earnings tab: $err');
        }
      }();

      List<Map<String, dynamic>> withdrawalsData = [];
      final withdrawalsFuture = () async {
        try {
          // Egress fix: narrowed from `*` to the exact columns read (grepped
          // exhaustively across _WithdrawalRow -- the only consumer of these rows).
          final res = await supabase
              .from('rider_withdrawals')
              .select('amount, status, created_at, cashfree_response, transfer_id, cashfree_reference_id')
              .eq('rider_id', riderData['id'])
              .order('created_at', ascending: false)
              .limit(10);
          withdrawalsData = List<Map<String, dynamic>>.from(res);
        } catch (err) {
          debugPrint('Error fetching withdrawals: $err');
        }
      }();

      Map<String, dynamic>? payoutData;
      final payoutFuture = () async {
        try {
          // Egress fix (Fix #6 completion): shared with rider_payout_details_screen.dart,
          // rider_active_order_screen.dart, and rider_payment_settings_screen.dart's own reads of
          // this same row via RiderPayoutAccountCache -- see that class's doc comment for why this
          // is safe (display/edit data only, invalidated on every write, never the
          // active-status-gating reads elsewhere in the app).
          payoutData = await RiderPayoutAccountCache.get(
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
        } catch (err) {
          debugPrint('Error fetching payout account: $err');
        }
      }();

      await Future.wait([
        ordersFuture,
        recentCompletedRidesFuture,
        activityFuture,
        activeOrderFuture,
        withdrawalsFuture,
        payoutFuture,
        taxDueFuture,
      ]);

      if (!mounted) return;
      setState(() {
        rider = riderData;
        recentOrders = ordersData;
        recentCompletedRides = recentCompletedRidesData;
        recentWithdrawals = withdrawalsData;
        payoutAccount = payoutData;
        isPayoutActive = payoutData != null && payoutData!['cashfree_beneficiary_status'] == 'active';
        activeOrder = activeOrderData;
        taxDueThreshold = fetchedTaxDueThreshold;
      });

      processOrdersData(ordersData, activityData);
    } catch (e) {
      debugPrint('Critical error in fetchData: $e');
      if (mounted) setState(() => loading = false);
    }
  }

  void processOrdersData(List<Map<String, dynamic>> orders, List<Map<String, dynamic>> activity) {
    final nowLocal = DateTime.now();
    final todayStart = DateTime(nowLocal.year, nowLocal.month, nowLocal.day);

    // 1. Calculate Summary Metrics
    double todayE = 0.0;
    double weekE = 0.0;
    double monthE = 0.0;

    final startOfWeek = todayStart.subtract(Duration(days: nowLocal.weekday - 1));
    final startOfMonth = DateTime(nowLocal.year, nowLocal.month, 1);

    // Group orders by local date
    final Map<DateTime, List<Map<String, dynamic>>> ordersByDay = {};

    for (var o in orders) {
      final dateStr = o['completed_at'] ?? o['created_at'];
      if (dateStr == null) continue;
      final completedAt = DateTime.tryParse(dateStr.toString())?.toLocal();
      if (completedAt == null) continue;
      
      final orderDate = DateTime(completedAt.year, completedAt.month, completedAt.day);
      final fare = double.tryParse(o['rider_earning']?.toString() ?? '0') ?? 0.0;
      // "Today's Gross Earnings" (hero figure, top of this screen) must be the total GROSS fare
      // of today's completed rides -- independent of payment method/commission/tax, which are
      // shown separately (Wallet, Cash to Paid, Government Tax Due). orders.rider_earning is a
      // NET figure (fare minus commission, historically also minus Platform GST) -- summing it
      // here silently produced a net total instead of gross (real-device report: two ₹21 rides
      // showed ₹36.95, not ₹42). final_fare ?? current_fare is the same authoritative
      // customer-payable-fare column every other settlement reader in this codebase uses (e.g.
      // create-payment/index.ts). Scoped to `todayE` only -- weekE/monthE and the Earnings
      // Analytics chart/day-breakdown below are unchanged, unaudited net figures.
      final grossFare = double.tryParse((o['final_fare'] ?? o['current_fare'])?.toString() ?? '0') ?? 0.0;

      // Sum summary metrics
      if (orderDate.isAtSameMomentAs(todayStart)) {
        todayE += grossFare;
      }
      if (orderDate.isAfter(startOfWeek.subtract(const Duration(seconds: 1)))) {
        weekE += fare;
      }
      if (orderDate.isAfter(startOfMonth.subtract(const Duration(seconds: 1)))) {
        monthE += fare;
      }

      // Grouping
      if (!ordersByDay.containsKey(orderDate)) {
        ordersByDay[orderDate] = [];
      }
      ordersByDay[orderDate]!.add(o);
    }

    // 2. Generate last 30 calendar days
    final List<DailyMetrics> metrics = [];
    double total30DayEarnings = 0.0;
    int total30DayOrders = 0;

    for (int i = 0; i < 30; i++) {
      final dayDate = todayStart.subtract(Duration(days: 29 - i));
      final dayOrders = ordersByDay[dayDate] ?? [];

      double earnings = 0.0;
      int timeSec = 0;
      double boost = 0.0;
      double surge = 0.0;
      double rain = 0.0;

      for (var o in dayOrders) {
        earnings += double.tryParse(o['rider_earning']?.toString() ?? '0') ?? 0.0;
        timeSec += int.tryParse(o['time_taken_seconds']?.toString() ?? '0') ?? 0;
        boost += double.tryParse(o['boost_amount']?.toString() ?? '0') ?? 0.0;
        surge += double.tryParse(o['surge_fee']?.toString() ?? '0') ?? 0.0;
        rain += double.tryParse(o['rain_fee']?.toString() ?? '0') ?? 0.0;
      }

      // Find online seconds for this day from activity
      int onlineSec = 0;
      DateTime? toggleAt;
      for (var act in activity) {
        final actDateStr = act['date'];
        if (actDateStr != null) {
          final parts = actDateStr.toString().split('-');
          if (parts.length == 3) {
            final y = int.tryParse(parts[0]);
            final m = int.tryParse(parts[1]);
            final d = int.tryParse(parts[2]);
            if (y == dayDate.year && m == dayDate.month && d == dayDate.day) {
              onlineSec = int.tryParse(act['online_seconds']?.toString() ?? '0') ?? 0;
              final toggleAtStr = act['last_online_toggle_at'];
              if (toggleAtStr != null) {
                toggleAt = DateTime.tryParse(toggleAtStr.toString());
              }
              break;
            }
          }
        }
      }

      DateTime? activeOrderStart;
      if (dayDate.year == todayStart.year &&
          dayDate.month == todayStart.month &&
          dayDate.day == todayStart.day &&
          activeOrder != null) {
        final startStr = activeOrder!['picked_up_at'] ?? activeOrder!['accepted_at'] ?? activeOrder!['created_at'];
        if (startStr != null) {
          activeOrderStart = DateTime.tryParse(startStr.toString());
        }
      }

      total30DayEarnings += earnings;
      total30DayOrders += dayOrders.length;

      metrics.add(DailyMetrics(
        date: dayDate,
        earnings: earnings,
        activeTimeSec: timeSec,
        onlineTimeSec: onlineSec,
        boostFare: boost,
        surgeFee: surge,
        rainFee: rain,
        extraFee: surge + rain,
        totalOrders: dayOrders.length,
        orders: dayOrders,
        lastOnlineToggleAt: toggleAt,
        activeOrderStart: activeOrderStart,
      ));
    }

    // 3. Compute Averages (rolling last 30 days)
    final avgEPerDay = total30DayEarnings / 30.0;
    final avgOPerDay = total30DayOrders / 30.0;
    final avgEPerOrder = total30DayOrders > 0 ? total30DayEarnings / total30DayOrders : 0.0;

    setState(() {
      todayEarnings = todayE;
      thisWeekEarnings = weekE;
      thisMonthEarnings = monthE;
      dailyMetricsList = metrics;
      avgEarningsPerDay = avgEPerDay;
      avgOrdersPerDay = avgOPerDay;
      avgEarningsPerOrder = avgEPerOrder;
      
      // Default selected day is today start
      selectedDay ??= todayStart;
      loading = false;
    });
  }



  String _fmt(dynamic v) => (double.tryParse('$v') ?? 0.0).toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    // Calculate dynamic averages based on currently selectedRange and only active days
    double dynamicAvgEarningsPerDay = 0.0;
    double dynamicAvgOrdersPerDay = 0.0;
    double dynamicAvgEarningsPerOrder = 0.0;

    if (dailyMetricsList.isNotEmpty) {
      final visibleDaysForAverages = dailyMetricsList.sublist(
        (dailyMetricsList.length - selectedRange).clamp(0, dailyMetricsList.length),
        dailyMetricsList.length,
      );
      double rangeEarnings = 0.0;
      int rangeOrders = 0;
      int activeDays = 0;
      for (var day in visibleDaysForAverages) {
        if (day.totalOrders > 0 || day.onlineTimeSec > 0) {
          rangeEarnings += day.earnings;
          rangeOrders += day.totalOrders;
          activeDays++;
        }
      }
      dynamicAvgEarningsPerDay = activeDays > 0 ? rangeEarnings / activeDays : 0.0;
      dynamicAvgOrdersPerDay = activeDays > 0 ? rangeOrders.toDouble() / activeDays : 0.0;
      dynamicAvgEarningsPerOrder = rangeOrders > 0 ? rangeEarnings / rangeOrders : 0.0;
    }

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
                  const Text('Earnings', 
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -0.5)),
                  const SizedBox(height: 20),

                  // Today's earnings overview card
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                    decoration: BoxDecoration(
                      color: primaryLime,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("Today's Gross Earnings",
                          style: TextStyle(fontSize: 12, color: Colors.black87, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        // A genuine fetch failure must never present as an indistinguishable
                        // "₹0.00" -- that previously hid the real problem entirely.
                        _todayEarningsUnavailable
                            ? const Text('Unable to load',
                                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Colors.black54, letterSpacing: -0.5))
                            : Text('₹${_fmt(todayEarnings)}',
                                style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: Colors.black, letterSpacing: -1)),
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: _MiniStat(label: 'Total Earned', value: '₹${_fmt(rider?['total_earnings'])}', darkText: true),
                              ),
                              Container(width: 1, height: 32, color: Colors.black12, margin: const EdgeInsets.symmetric(horizontal: 6)),
                              Expanded(
                                child: _MiniStat(label: 'Wallet', value: '₹${_fmt(rider?['wallet_balance'])}', darkText: true),
                              ),
                              Container(width: 1, height: 32, color: Colors.black12, margin: const EdgeInsets.symmetric(horizontal: 6)),
                              Expanded(
                                child: _MiniStat(label: 'Cash to Paid', value: '₹${_fmt(rider?['cod_pending_amount'])}', darkText: true),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),



                  // Payout bank card
                  if (payoutAccount == null) ...[
                    Container(
                      margin: const EdgeInsets.only(top: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: darkCard,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.warning_amber_rounded, color: primaryLime, size: 18),
                              SizedBox(width: 8),
                              Text('No Payout Account Linked',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white)),
                            ],
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Setup your payout bank details to withdraw earnings and activate Drop Partner Mode.',
                            style: TextStyle(fontSize: 11, color: textGray, fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            height: 40,
                            child: ElevatedButton(
                              onPressed: () async {
                                final res = await Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => const RiderPayoutDetailsScreen()),
                                );
                                if (res == true) fetchData();
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: primaryLime,
                                foregroundColor: Colors.black,
                                elevation: 0,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: const Text('Setup Payout Account', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    Container(
                      margin: const EdgeInsets.only(top: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: darkCard,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.account_balance_rounded, color: primaryLime, size: 16),
                                  SizedBox(width: 8),
                                  Text('Payout Method',
                                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white)),
                                ],
                              ),
                              IconButton(
                                icon: const Icon(Icons.edit_outlined, color: primaryLime, size: 16),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () async {
                                  final res = await Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => const RiderPayoutDetailsScreen()),
                                  );
                                  if (res == true) fetchData();
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.04),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              children: [
                                _buildPayoutInfoRow('Account Holder', payoutAccount?['beneficiary_name'] ?? '-'),
                                const SizedBox(height: 6),
                                if (payoutAccount?['account_number'] != null) ...[
                                  _buildPayoutInfoRow(
                                    'Bank Account',
                                    payoutAccount!['account_number'].toString().length > 4
                                        ? '******${payoutAccount!['account_number'].toString().substring(payoutAccount!['account_number'].toString().length - 4)}'
                                        : payoutAccount?['account_number'] ?? '-',
                                  ),
                                  const SizedBox(height: 6),
                                  _buildPayoutInfoRow('IFSC Code', payoutAccount?['ifsc_code'] ?? '-'),
                                  const SizedBox(height: 6),
                                ],
                                if (payoutAccount?['upi_vpa'] != null) ...[
                                  _buildPayoutInfoRow('UPI ID (VPA)', payoutAccount?['upi_vpa'] ?? '-'),
                                  const SizedBox(height: 6),
                                ],
                                _buildPayoutInfoRow(
                                  'Status',
                                  isPayoutActive ? 'Verified' : 'Pending Verification',
                                  valueColor: isPayoutActive ? primaryLime : const Color(0xFFF59E0B),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: 12),
                  
                  // Withdraw Button
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: ElevatedButton(
                      onPressed: (payoutAccount != null &&
                              payoutAccount!['beneficiary_id'] != null &&
                              payoutAccount!['beneficiary_id'].toString().trim().isNotEmpty &&
                              (double.tryParse('${rider?['wallet_balance']}') ?? 0.0) >= 1.0)
                          ? () => _showWithdrawBottomSheet()
                          : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryLime,
                        foregroundColor: Colors.black,
                        disabledBackgroundColor: Colors.white10,
                        disabledForegroundColor: Colors.white24,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.call_made_rounded, size: 16),
                          SizedBox(width: 8),
                          Text('Withdraw Funds', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900)),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Subscription banner
                  if (rider?['subscription_active'] == true) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: primaryLime.withOpacity(0.3)),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.star_rounded, color: primaryLime, size: 18),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text('Commission waiver active — keep earning more!',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Government Tax Due -- a separate liability from the subscription/wallet
                  // above; never deducted from or offset by subscription revenue.
                  _buildGovernmentTaxDueCard(),
                  const SizedBox(height: 12),

                  // Cash to be Paid (COD Settlement) -- an independent liability from Government
                  // Tax Due above; the two are never combined or offset against each other.
                  _buildCodSettlementCard(),
                  const SizedBox(height: 12),

                  // Recent Withdrawals
                  if (recentWithdrawals.isNotEmpty) ...[
                    const Text('Recent Withdrawals', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Colors.white)),
                    const SizedBox(height: 12),
                    ...recentWithdrawals.map((w) => _WithdrawalRow(withdrawal: w)),
                    const SizedBox(height: 20),
                  ],

                  // No empty-state card at all when there are no completed rides yet -- this
                  // section simply doesn't render (was previously an "No Completed Trips Yet" card
                  // shown even when it genuinely wasn't needed). recentCompletedRides is the
                  // all-time, limit-3 list (never the 30-day-windowed `recentOrders` used for the
                  // analytics section below).
                  if (recentCompletedRides.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const Text('Recent Completed Rides', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -0.3)),
                    const SizedBox(height: 12),
                    ...recentCompletedRides.map(
                      (o) => _ExpandableOrderCard(key: ValueKey('recent-${o['id'] ?? o['order_code']}'), order: o),
                    ),
                    const SizedBox(height: 20),
                  ],

                  // Analytics Dashboard -- only meaningful once there's at least one ride within the
                  // last 30 days to chart; unrelated to whether the rider has ever completed a ride
                  // at all (that's the section immediately above).
                  if (recentOrders.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    const Text('Earnings Analytics', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -0.3)),
                    const SizedBox(height: 12),

                    // Summary Header
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildSummaryHeaderCard("Today", todayEarnings),
                        _buildSummaryHeaderCard("This Week", thisWeekEarnings),
                        _buildSummaryHeaderCard("This Month", thisMonthEarnings),
                      ],
                    ),
                    const SizedBox(height: 12),
                    
                    // Averages Row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildAverageCard("Avg Earnings / Day", "₹${_fmt(dynamicAvgEarningsPerDay)}"),
                        _buildAverageCard("Avg Orders / Day", dynamicAvgOrdersPerDay.toStringAsFixed(1)),
                        _buildAverageCard("Avg / Order", "₹${_fmt(dynamicAvgEarningsPerOrder)}"),
                      ],
                    ),
                    const SizedBox(height: 20),
                    
                    // Graph type & range selectors
                    Wrap(
                      spacing: 8,
                      runSpacing: 10,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        // Type Toggles
                        Wrap(
                          spacing: 6,
                          children: ['Earnings', 'Active Time', 'Orders'].map((m) {
                            final isSel = selectedMetric == m;
                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => setState(() => selectedMetric = m),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                decoration: BoxDecoration(
                                  color: isSel ? primaryLime : Colors.white.withValues(alpha: 0.04),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: isSel ? primaryLime : Colors.white10),
                                ),
                                child: Text(
                                  m,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: isSel ? Colors.black : textGray,
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                        
                        // Range Toggles
                        Wrap(
                          spacing: 6,
                          children: [7, 30].map((r) {
                            final isSel = selectedRange == r;
                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => setState(() => selectedRange = r),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: isSel ? Colors.white10 : Colors.transparent,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: isSel ? primaryLime.withValues(alpha: 0.5) : Colors.transparent),
                                ),
                                child: Text(
                                  '${r}D',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: isSel ? primaryLime : textGray,
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    
                    // Chart
                    if (dailyMetricsList.isNotEmpty)
                      _buildChart(
                        dailyMetricsList.sublist(
                          (dailyMetricsList.length - selectedRange).clamp(0, dailyMetricsList.length),
                          dailyMetricsList.length,
                        ),
                      ),
                    const SizedBox(height: 20),
                    // Selected Day Breakdown
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      transitionBuilder: (Widget child, Animation<double> animation) {
                        return FadeTransition(
                          opacity: animation,
                          child: SizeTransition(
                            sizeFactor: animation,
                            axisAlignment: -1.0,
                            child: child,
                          ),
                        );
                      },
                      child: Builder(
                        key: ValueKey(selectedDay),
                        builder: (context) {
                          DailyMetrics? selDayMetrics;
                          if (selectedDay != null && dailyMetricsList.isNotEmpty) {
                            try {
                              selDayMetrics = dailyMetricsList.firstWhere(
                                (d) => d.date.year == selectedDay!.year &&
                                       d.date.month == selectedDay!.month &&
                                       d.date.day == selectedDay!.day,
                              );
                            } catch (_) {}
                          }
                          if (selDayMetrics != null) {
                            return _buildSelectedDayBreakdown(selDayMetrics);
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                  ],
                  SizedBox(height: 96 + Insets.bottom(context)),
                ],
              ),
      ),
    );
  }

  Widget _buildPayoutInfoRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: textGray, fontWeight: FontWeight.w500)),
        Text(value, style: TextStyle(fontSize: 12, color: valueColor ?? Colors.white, fontWeight: FontWeight.bold)),
      ],
    );
  }

  void _showWithdrawBottomSheet() {
    final maxBalance = double.tryParse('${rider?['wallet_balance']}') ?? 0.0;
    final upiAvailable = payoutAccount?['upi_vpa'] != null && payoutAccount!['upi_vpa'].toString().trim().isNotEmpty;
    
    final amountController = TextEditingController(text: maxBalance.toStringAsFixed(2));
    String selectedMode = 'banktransfer';
    bool sheetLoading = false;
    final formKey = GlobalKey<FormState>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: darkCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 24,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 24,
              ),
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Withdraw Funds',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -0.5)),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, color: textGray),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text('Available Balance: ₹${maxBalance.toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 13, color: textGray, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: amountController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Colors.white),
                      decoration: const InputDecoration(
                        prefixText: '₹ ',
                        prefixStyle: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Colors.white),
                        labelText: 'Withdrawal Amount',
                        labelStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: textGray),
                        hintText: '0.00',
                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white12, width: 2)),
                        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryLime, width: 2)),
                        errorBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.red, width: 2)),
                        focusedErrorBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.red, width: 2)),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) return 'Enter withdrawal amount';
                        final val = double.tryParse(value);
                        if (val == null || val <= 0) return 'Enter a valid amount';
                        if (val > maxBalance) return 'Insufficient wallet balance';
                        if (val < 1.0) return 'Minimum withdrawal is ₹1.00';
                        return null;
                      },
                    ),
                    const SizedBox(height: 24),

                    const Text('Select Transfer Destination',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: textGray)),
                    const SizedBox(height: 8),

                    _buildModeTile(
                      title: 'Bank Account',
                      subtitle: payoutAccount?['account_number'] != null
                          ? '******${payoutAccount!['account_number'].toString().substring(payoutAccount!['account_number'].toString().length - 4)} (${payoutAccount?['ifsc_code']})'
                          : 'Linked Bank Account',
                      icon: Icons.account_balance_rounded,
                      value: 'banktransfer',
                      groupValue: selectedMode,
                      onChanged: (val) => setSheetState(() => selectedMode = val!),
                    ),
                    const SizedBox(height: 8),

                    _buildModeTile(
                      title: 'UPI ID (VPA)',
                      subtitle: upiAvailable ? payoutAccount!['upi_vpa'] : 'No UPI VPA ID registered',
                      icon: Icons.qr_code_rounded,
                      value: 'upi',
                      groupValue: selectedMode,
                      enabled: upiAvailable,
                      onChanged: (val) => setSheetState(() => selectedMode = val!),
                    ),
                    const SizedBox(height: 24),

                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: sheetLoading
                            ? null
                            : () async {
                                if (!formKey.currentState!.validate()) return;
                                final withdrawAmount = double.parse(amountController.text.trim());

                                setSheetState(() => sheetLoading = true);
                                try {
                                  final response = await supabase.functions.invoke(
                                    'create-rider-withdrawal',
                                    body: {
                                      'amount': withdrawAmount,
                                      'transfer_mode': selectedMode,
                                    },
                                  );

                                  if (!mounted) return;

                                  if (response.status == 200 && response.data?['success'] == true) {
                                    Navigator.pop(ctx);
                                    showAppSnackBar(
                                      context,
                                      response.data?['message'] ?? 'Withdrawal processed successfully',
                                      type: SnackBarType.success,
                                    );
                                    fetchData();
                                  } else {
                                    setSheetState(() => sheetLoading = false);
                                    showAppSnackBar(
                                      context,
                                      response.data?['message'] ?? 'Failed to process withdrawal',
                                      type: SnackBarType.error,
                                    );
                                  }
                                } catch (e) {
                                  setSheetState(() => sheetLoading = false);
                                  showAppSnackBar(context, 'Withdrawal request failed: $e', type: SnackBarType.error);
                                }
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primaryLime,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          elevation: 0,
                        ),
                        child: sheetLoading
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2),
                              )
                            : const Text('Confirm & Withdraw', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).then((_) => amountController.dispose());
  }

  Widget _buildModeTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required String value,
    required String groupValue,
    required void Function(String?) onChanged,
    bool enabled = true,
  }) {
    final isSelected = value == groupValue;
    return InkWell(
      onTap: enabled ? () => onChanged(value) : null,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white.withOpacity(0.04) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected
                ? primaryLime
                : enabled
                    ? Colors.white10
                    : Colors.white.withOpacity(0.02),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: enabled ? (isSelected ? primaryLime : textGray) : Colors.white24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: enabled ? Colors.white : Colors.white24)),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: enabled ? textGray : Colors.white10)),
                ],
              ),
            ),
            Radio<String>(
              value: value,
              groupValue: groupValue,
              onChanged: enabled ? onChanged : null,
              activeColor: primaryLime,
            ),
          ],
        ),
      ),
    );
  }

  // Government Tax Due card -- a separate, WayDrop-business-configured liability the Drop Partner
  // owes for completed services (pending CA/accounting confirmation, not a legally verified GST
  // determination). Balance/threshold are both server-derived (riders.government_tax_due_balance,
  // government_tax_config) -- this widget only ever displays/reads them, never sets them.
  Widget _buildGovernmentTaxDueCard() {
    final dueBalance = double.tryParse('${rider?['government_tax_due_balance']}') ?? 0.0;
    final isBlocked = dueBalance >= taxDueThreshold;
    final isApproaching = !isBlocked && taxDueThreshold > 0 && dueBalance >= taxDueThreshold * 0.8;

    final Color accentColor = isBlocked
        ? const Color(0xFFEF4444)
        : isApproaching
            ? const Color(0xFFF59E0B)
            : primaryLime;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: darkCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accentColor.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.receipt_long_rounded, color: accentColor, size: 18),
              const SizedBox(width: 8),
              const Text('Government Tax Due', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white)),
            ],
          ),
          const SizedBox(height: 8),
          Text('₹${dueBalance.toStringAsFixed(2)}', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: accentColor)),
          const SizedBox(height: 6),
          const Text(
            'Tax amount collected on completed services and payable through WayDrop.',
            style: TextStyle(fontSize: 11, color: textGray, height: 1.4),
          ),
          if (isBlocked) ...[
            const SizedBox(height: 10),
            Text(
              'New orders are paused because your Government Tax Due has reached the ₹${taxDueThreshold.toStringAsFixed(0)} limit. Pay the due amount to continue receiving orders.',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFEF4444), height: 1.4),
            ),
          ] else if (isApproaching) ...[
            const SizedBox(height: 10),
            Text(
              'Approaching the ₹${taxDueThreshold.toStringAsFixed(0)} limit — pay soon to keep receiving new orders without interruption.',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFF59E0B), height: 1.4),
            ),
          ],
          if (dueBalance > 0) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton(
                onPressed: _payingTaxDue ? null : _payGovernmentTaxDue,
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentColor,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _payingTaxDue
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                    : const Text('Pay Government Tax Due', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // "Cash to be Paid" card -- WayDrop's commission share owed by the Drop Partner for services
  // already settled by collecting cash/personal-UPI directly from the passenger. Balance/limit
  // are both server-derived (riders.cod_pending_amount, riders.cod_limit) -- this widget only
  // ever displays/reads them, never sets them. Same structure as the Government Tax Due card
  // above; the two are independent liabilities.
  Widget _buildCodSettlementCard() {
    final dueBalance = double.tryParse('${rider?['cod_pending_amount']}') ?? 0.0;
    final codLimit = double.tryParse('${rider?['cod_limit']}') ?? 500.0;
    final isBlocked = codLimit > 0 && dueBalance >= codLimit;
    final isApproaching = !isBlocked && codLimit > 0 && dueBalance >= codLimit * 0.8;

    final Color accentColor = isBlocked
        ? const Color(0xFFEF4444)
        : isApproaching
            ? const Color(0xFFF59E0B)
            : primaryLime;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: darkCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accentColor.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.currency_rupee_rounded, color: accentColor, size: 18),
              const SizedBox(width: 8),
              const Text('Cash to be Paid', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white)),
            ],
          ),
          const SizedBox(height: 8),
          Text('₹${dueBalance.toStringAsFixed(2)}', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: accentColor)),
          const SizedBox(height: 6),
          const Text(
            'WayDrop\'s commission and dues on cash rides you\'ve collected, payable through WayDrop.',
            style: TextStyle(fontSize: 11, color: textGray, height: 1.4),
          ),
          if (isBlocked) ...[
            const SizedBox(height: 10),
            Text(
              'New orders are paused because your Cash to be Paid has reached the ₹${codLimit.toStringAsFixed(0)} limit. Pay the due amount to continue receiving orders.',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFEF4444), height: 1.4),
            ),
          ] else if (isApproaching) ...[
            const SizedBox(height: 10),
            Text(
              'Approaching the ₹${codLimit.toStringAsFixed(0)} limit — pay soon to keep receiving new orders without interruption.',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFF59E0B), height: 1.4),
            ),
          ],
          if (dueBalance > 0) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton(
                onPressed: _payingCodSettlement ? null : _payCodSettlement,
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentColor,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _payingCodSettlement
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                    : const Text('Pay Cash Dues', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Server reads the real, authoritative balance and charges exactly that -- this client only
  // ever asks to "pay my cash dues"; it never supplies or influences the amount (see
  // create-payment/index.ts's cod_settlement branch). `amount` passed to startPayment below is
  // local display only on the processing screen, same non-authoritative role it already plays
  // for subscription/order-fare/tax-due payments.
  Future<void> _payCodSettlement() async {
    if (_payingCodSettlement) return;
    final riderId = rider?['id'];
    final dueBalance = double.tryParse('${rider?['cod_pending_amount']}') ?? 0.0;
    if (riderId == null || dueBalance <= 0) return;

    PaymentTrace.start('cod_settlement');
    PaymentTrace.step('BUTTON_CLICKED', 'cod_settlement', 'Pay Cash Dues button');
    PaymentTrace.step('PAYMENT_TYPE', 'cod_settlement', 'cod_settlement');
    PaymentTrace.step('AMOUNT', 'cod_settlement', dueBalance);

    setState(() => _payingCodSettlement = true);
    try {
      final result = await PaymentService.startPayment(
        context: context,
        paymentFor: PaymentFor.codSettlement,
        amount: dueBalance,
        paymentMethod: 'cashfree',
        riderId: riderId,
        paymentForLabel: 'Cash to be Paid',
      );

      PaymentTrace.step('PaymentService.startPayment() RETURNED', 'cod_settlement', result);

      if (!mounted) {
        PaymentTrace.abnormalExit('_payCodSettlement', 'cod_settlement', 'widget unmounted after startPayment');
        return;
      }

      if (result['success'] == true) {
        showAppSnackBar(context, 'Cash dues payment successful.', type: SnackBarType.success);
        await fetchData();
        PaymentTrace.end('cod_settlement');
      } else {
        final message = result['message']?.toString() ?? 'Payment was not completed';
        showAppSnackBar(context, message, type: SnackBarType.error);
        PaymentTrace.abnormalExit('_payCodSettlement', 'cod_settlement', message);
      }
    } catch (e, st) {
      PaymentTrace.exceptionAt('_payCodSettlement', 'cod_settlement', e, st);
      rethrow;
    } finally {
      if (mounted) setState(() => _payingCodSettlement = false);
    }
  }

  // Server reads the real, authoritative balance and charges exactly that -- this client only
  // ever asks to "pay my tax due"; it never supplies or influences the amount (see
  // create-payment/index.ts's tax_due branch). `amount` passed to startPayment below is local
  // display only on the processing screen, same non-authoritative role it already plays for
  // subscription/order-fare payments.
  Future<void> _payGovernmentTaxDue() async {
    if (_payingTaxDue) return;
    final riderId = rider?['id'];
    final dueBalance = double.tryParse('${rider?['government_tax_due_balance']}') ?? 0.0;
    if (riderId == null || dueBalance <= 0) return;

    // TEMP DEBUG INSTRUMENTATION -- see payment_debug_trace.dart.
    PaymentTrace.start('tax_due');
    PaymentTrace.step('BUTTON_CLICKED', 'tax_due', 'Pay Government Tax Due button');
    PaymentTrace.step('PAYMENT_TYPE', 'tax_due', 'tax_due');
    PaymentTrace.step('AMOUNT', 'tax_due', dueBalance);

    setState(() => _payingTaxDue = true);
    try {
      final result = await PaymentService.startPayment(
        context: context,
        paymentFor: PaymentFor.taxDue,
        amount: dueBalance,
        paymentMethod: 'cashfree',
        riderId: riderId,
        paymentForLabel: 'Government Tax Due',
      );

      PaymentTrace.step('PaymentService.startPayment() RETURNED', 'tax_due', result);

      if (!mounted) {
        PaymentTrace.abnormalExit('_payGovernmentTaxDue', 'tax_due', 'widget unmounted after startPayment');
        return;
      }

      if (result['success'] == true) {
        showAppSnackBar(context, 'Government Tax Due payment successful.', type: SnackBarType.success);
        await fetchData();
        PaymentTrace.end('tax_due');
      } else {
        final message = result['message']?.toString() ?? 'Payment was not completed';
        showAppSnackBar(context, message, type: SnackBarType.error);
        PaymentTrace.abnormalExit('_payGovernmentTaxDue', 'tax_due', message);
      }
    } catch (e, st) {
      PaymentTrace.exceptionAt('_payGovernmentTaxDue', 'tax_due', e, st);
      rethrow;
    } finally {
      if (mounted) setState(() => _payingTaxDue = false);
    }
  }

  Widget _buildSummaryHeaderCard(String title, double amount) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: darkCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(0.05)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 10, color: textGray, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '₹${_fmt(amount)}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAverageCard(String title, String value) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.02),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withOpacity(0.03)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(title, style: const TextStyle(fontSize: 8, color: textGray, fontWeight: FontWeight.w500)),
            const SizedBox(height: 2),
            Text(
              value,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChart(List<DailyMetrics> visibleDays) {
    double maxVal = 0.0;
    for (var day in visibleDays) {
      double val = _getMetricValue(day);
      if (val > maxVal) maxVal = val;
    }
    if (maxVal == 0.0) maxVal = 1.0;

    return Container(
      height: 240,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: darkCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: visibleDays.map((day) {
          final double val = _getMetricValue(day);
          final double heightFactor = (val / maxVal).clamp(0.0, 1.0);
          final bool isSelected = selectedDay != null &&
              day.date.year == selectedDay!.year &&
              day.date.month == selectedDay!.month &&
              day.date.day == selectedDay!.day;

          final barWidth = selectedRange == 7 ? 20.0 : 5.0;
          
          return Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() {
                  selectedDay = day.date;
                });
              },
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (selectedRange == 7 && isSelected)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          _formatMetricValueShort(val),
                          style: const TextStyle(
                            fontSize: 9,
                            color: primaryLime,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  Expanded(
                    child: Center(
                      child: TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: 0.0, end: heightFactor),
                        duration: const Duration(milliseconds: 500),
                        builder: (context, animatedFactor, child) {
                          return Container(
                            width: barWidth,
                            height: double.infinity,
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              heightFactor: animatedFactor.clamp(0.02, 1.0),
                              child: Container(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: isSelected
                                        ? [primaryLime, primaryLime.withOpacity(0.4)]
                                        : [primaryLime.withOpacity(0.25), primaryLime.withOpacity(0.05)],
                                  ),
                                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                                  boxShadow: isSelected
                                      ? [
                                          BoxShadow(
                                            color: primaryLime.withOpacity(0.3),
                                            blurRadius: 6,
                                            offset: const Offset(0, -1),
                                          )
                                        ]
                                      : null,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _formatDateLabel(day.date),
                    style: TextStyle(
                      fontSize: 8,
                      color: isSelected ? primaryLime : textGray,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSelectedDayBreakdown(DailyMetrics day) {
    final total = day.earnings;
    final double extra = day.extraFee;
    final double boost = day.boostFare;
    final double base = (total - boost - extra).clamp(0.0, double.infinity);
    final avgPerOrder = day.totalOrders > 0 ? total / day.totalOrders : 0.0;


    int rideCount = 0;
    double rideEarnings = 0.0;
    int parcelCount = 0;
    double parcelEarnings = 0.0;

    for (var o in day.orders) {
      final t = o['order_type']?.toString() ?? 'ride';
      final isP = t == 'local_parcel' || t == 'intercity_parcel' || t.contains('parcel');
      final fare = double.tryParse(o['rider_earning']?.toString() ?? '0') ?? 0.0;
      if (isP) {
        parcelCount++;
        parcelEarnings += fare;
      } else {
        rideCount++;
        rideEarnings += fare;
      }
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: darkCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Text(
                    _formatSelectedDate(day.date),
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    icon: const Icon(Icons.calendar_month_rounded, color: primaryLime, size: 18),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () async {
                      final nowVal = DateTime.now();
                      final initialVal = day.date.isAfter(nowVal) 
                          ? nowVal 
                          : (day.date.isBefore(nowVal.subtract(const Duration(days: 29))) 
                              ? nowVal.subtract(const Duration(days: 29)) 
                              : day.date);
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: initialVal,
                        firstDate: nowVal.subtract(const Duration(days: 29)),
                        lastDate: nowVal,
                        builder: (context, child) {
                          return Theme(
                            data: Theme.of(context).copyWith(
                              colorScheme: const ColorScheme.dark(
                                primary: primaryLime,
                                onPrimary: Colors.black,
                                surface: darkCard,
                                onSurface: Colors.white,
                              ),
                              dialogBackgroundColor: darkBg,
                            ),
                            child: child!,
                          );
                        },
                      );
                      if (picked != null) {
                        setState(() {
                          selectedDay = DateTime(picked.year, picked.month, picked.day);
                        });
                      }
                    },
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: primaryLime.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${day.totalOrders} order${day.totalOrders == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: primaryLime),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          
          // Metrics Grid
          Row(
            children: [
              Expanded(child: _buildDayMetricTile('Earnings', '₹${_fmt(total)}')),
              Expanded(child: _buildDayMetricTile('Completed Orders', '${day.totalOrders}')),
            ],
          ),
          const SizedBox(height: 12),
          RealtimeDurationGrid(
            activeTimeSec: day.activeTimeSec,
            activeOrderStart: day.activeOrderStart,
            onlineTimeSec: day.onlineTimeSec,
            lastOnlineToggleAt: day.lastOnlineToggleAt,
            formatDuration: _formatDuration,
            buildMetricTile: _buildDayMetricTile,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _buildDayMetricTile('Average Per Order', '₹${_fmt(avgPerOrder)}')),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 16),

          // Order Type Breakdown Section
          const Divider(color: Colors.white10, height: 1),
          const SizedBox(height: 14),
          const Text(
            'ORDER TYPE BREAKDOWN',
            style: TextStyle(fontSize: 9, color: textGray, fontWeight: FontWeight.bold, letterSpacing: 0.5),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.02),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.03)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Rides', style: TextStyle(fontSize: 10, color: textGray, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text('$rideCount completed', style: const TextStyle(fontSize: 11, color: Colors.white70, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 2),
                      Text('₹${_fmt(rideEarnings)}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: primaryLime)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.02),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.03)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Parcels', style: TextStyle(fontSize: 10, color: textGray, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text('$parcelCount completed', style: const TextStyle(fontSize: 11, color: Colors.white70, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 2),
                      Text('₹${_fmt(parcelEarnings)}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: primaryLime)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          
          const Divider(color: Colors.white10, height: 1),
          const SizedBox(height: 16),
          
          // Proportion Bar Legended visual
          const Text(
            'EARNINGS BREAKDOWN',
            style: TextStyle(fontSize: 9, color: textGray, fontWeight: FontWeight.bold, letterSpacing: 0.5),
          ),
          const SizedBox(height: 8),
          _buildProportionBar(base, boost, extra, total),
          const SizedBox(height: 12),
          
          _buildBreakdownLegendTile('Base Earnings', '₹${_fmt(base)}', primaryLime),
          _buildBreakdownLegendTile('Boost Earnings', '₹${_fmt(boost)}', Colors.blueAccent),
          _buildBreakdownLegendTile('Weather / Demand Earnings', '₹${_fmt(extra)}', const Color(0xFFF59E0B)),
          if (extra > 0) ...[
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2),
              child: Text(
                '↳ Surge: ₹${_fmt(day.surgeFee)}  |  Rain: ₹${_fmt(day.rainFee)}',
                style: const TextStyle(fontSize: 10, color: textGray, fontWeight: FontWeight.w500),
              ),
            ),
          ],
          
          // Day's completed orders list
          if (day.orders.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Text(
              'TRIP HISTORY',
              style: TextStyle(fontSize: 9, color: textGray, fontWeight: FontWeight.bold, letterSpacing: 0.5),
            ),
            const SizedBox(height: 8),
            ...day.orders.map((o) => _ExpandableOrderCard(key: ValueKey(o['id'] ?? o['order_code']), order: o)),
          ],
        ],
      ),
    );
  }

  Widget _buildDayMetricTile(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 10, color: textGray, fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Colors.white),
        ),
      ],
    );
  }

  Widget _buildBreakdownLegendTile(String label, String value, Color dotColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 11, color: textGray, fontWeight: FontWeight.w500)),
          const Spacer(),
          Text(value, style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildProportionBar(double base, double boost, double extra, double total) {
    if (total <= 0) return const SizedBox();
    
    final basePct = base / total;
    final boostPct = boost / total;
    final extraPct = extra / total;

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: Row(
          children: [
            if (basePct > 0)
              Expanded(
                flex: (basePct * 100).round().clamp(1, 100),
                child: Container(color: primaryLime),
              ),
            if (boostPct > 0)
              Expanded(
                flex: (boostPct * 100).round().clamp(1, 100),
                child: Container(color: Colors.blueAccent),
              ),
            if (extraPct > 0)
              Expanded(
                flex: (extraPct * 100).round().clamp(1, 100),
                child: Container(color: const Color(0xFFF59E0B)),
              ),
          ],
        ),
      ),
    );
  }

  String _formatSelectedDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    if (date.year == today.year && date.month == today.month && date.day == today.day) {
      return 'Today, ${_getMonthName(date.month)} ${date.day}';
    } else if (date.year == yesterday.year && date.month == yesterday.month && date.day == yesterday.day) {
      return 'Yesterday, ${_getMonthName(date.month)} ${date.day}';
    } else {
      final weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
      return '${weekdays[date.weekday - 1]}, ${_getMonthName(date.month)} ${date.day}';
    }
  }

  String _getMonthName(int month) {
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return months[month - 1];
  }

  String _formatDuration(int seconds) {
    if (seconds <= 0) return '0m';
    final mins = seconds ~/ 60;
    final hours = mins ~/ 60;
    final remainingMins = mins % 60;
    if (hours > 0) {
      return '${hours}h ${remainingMins}m';
    } else {
      return '${remainingMins}m';
    }
  }

  double _getMetricValue(DailyMetrics day) {
    switch (selectedMetric) {
      case 'Earnings':
        return day.earnings;
      case 'Active Time':
        return day.activeTimeSec / 3600.0;
      case 'Orders':
        return day.totalOrders.toDouble();
      default:
        return 0.0;
    }
  }

  String _formatMetricValueShort(double val) {
    switch (selectedMetric) {
      case 'Earnings':
        return '₹${val.toStringAsFixed(0)}';
      case 'Active Time':
        if (val == 0) return '0h';
        return '${val.toStringAsFixed(1)}h';
      case 'Orders':
        return val.toStringAsFixed(0);
      default:
        return '';
    }
  }

  String _formatDateLabel(DateTime date) {
    if (selectedRange == 7) {
      final weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return weekdays[date.weekday - 1];
    } else {
      if (date.day % 5 == 0) {
        return date.day.toString();
      }
      return '';
    }
  }
}

class _MiniStat extends StatelessWidget {
  final String label, value;
  final bool darkText;
  const _MiniStat({required this.label, required this.value, this.darkText = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              color: darkText ? Colors.black : Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10,
            color: darkText ? Colors.black54 : Colors.white70,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

class _WithdrawalRow extends StatefulWidget {
  final Map<String, dynamic> withdrawal;
  const _WithdrawalRow({required this.withdrawal});

  @override
  State<_WithdrawalRow> createState() => _WithdrawalRowState();
}

class _WithdrawalRowState extends State<_WithdrawalRow> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final withdrawal = widget.withdrawal;
    final amount = double.tryParse(withdrawal['amount']?.toString() ?? '0') ?? 0;
    final status = withdrawal['status'] ?? 'pending';
    final date = withdrawal['created_at'] ?? '';
    final dt = DateTime.tryParse(date.toString())?.toLocal();
    final dateStr = dt != null
        ? '${dt.day}/${dt.month} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}'
        : '';
    final fullDateStr = dt != null
        ? '${dt.day}/${dt.month}/${dt.year} at ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}'
        : 'N/A';

    Color statusColor;
    IconData statusIcon;
    String statusText;

    switch (status) {
      case 'success':
        statusColor = _RiderEarningsTabState.primaryLime;
        statusIcon = Icons.check_circle_rounded;
        statusText = 'Success';
        break;
      case 'failed':
        statusColor = const Color(0xFFEF4444);
        statusIcon = Icons.error_rounded;
        statusText = 'Failed';
        break;
      case 'processing':
        statusColor = const Color(0xFF3B82F6);
        statusIcon = Icons.hourglass_empty_rounded;
        statusText = 'Processing';
        break;
      case 'pending':
      default:
        statusColor = const Color(0xFFF59E0B);
        statusIcon = Icons.hourglass_top_rounded;
        statusText = 'Pending';
        break;
    }

    String? errorMessage;
    if (withdrawal['cashfree_response'] != null) {
      final resp = withdrawal['cashfree_response'];
      if (resp is Map) {
        errorMessage = resp['message']?.toString() ?? resp['error']?.toString();
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: _RiderEarningsTabState.darkCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: InkWell(
        onTap: () {
          setState(() {
            _isExpanded = !_isExpanded;
          });
        },
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(statusIcon, color: statusColor, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Withdrawal - $statusText',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          dateStr,
                          style: const TextStyle(
                            fontSize: 11,
                            color: _RiderEarningsTabState.textGray,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      Text(
                        '-₹${amount.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: statusColor,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        _isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                        color: _RiderEarningsTabState.textGray,
                        size: 16,
                      ),
                    ],
                  ),
                ],
              ),
              if (_isExpanded) ...[
                const SizedBox(height: 12),
                const Divider(color: Colors.white10, height: 1),
                const SizedBox(height: 12),
                _buildDetailRow('Transaction ID', withdrawal['transfer_id'] ?? 'N/A'),
                const SizedBox(height: 8),
                _buildDetailRow('Ref ID', withdrawal['cashfree_reference_id'] ?? 'N/A'),
                const SizedBox(height: 8),
                _buildDetailRow('Date', fullDateStr),
                if (errorMessage != null && errorMessage.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444).withOpacity(0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.2)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.info_outline, color: Color(0xFFEF4444), size: 14),
                            SizedBox(width: 6),
                            Text(
                              'Failure Reason',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFEF4444)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          errorMessage,
                          style: const TextStyle(fontSize: 11, color: Color(0xFFFDA4AF), fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: _RiderEarningsTabState.textGray, fontWeight: FontWeight.w500)),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}


class DailyMetrics {
  final DateTime date;
  final double earnings;
  final int activeTimeSec;
  final int onlineTimeSec;
  final double boostFare;
  final double surgeFee;
  final double rainFee;
  final double extraFee;
  final int totalOrders;
  final List<Map<String, dynamic>> orders;
  final DateTime? lastOnlineToggleAt;
  final DateTime? activeOrderStart;

  DailyMetrics({
    required this.date,
    required this.earnings,
    required this.activeTimeSec,
    required this.onlineTimeSec,
    required this.boostFare,
    required this.surgeFee,
    required this.rainFee,
    required this.extraFee,
    required this.totalOrders,
    required this.orders,
    this.lastOnlineToggleAt,
    this.activeOrderStart,
  });
}

class _ExpandableOrderCard extends StatefulWidget {
  final Map<String, dynamic> order;
  const _ExpandableOrderCard({super.key, required this.order});

  @override
  State<_ExpandableOrderCard> createState() => _ExpandableOrderCardState();
}

class _ExpandableOrderCardState extends State<_ExpandableOrderCard> {
  bool _expanded = false;

  // Fetched once (not per-rebuild/per-expand-toggle) so the collapsed headline figure and the
  // expanded "YOUR TRIP EARNINGS" figure are always the exact same number for this order -- never
  // two different "earnings" values on the same card. Government Tax is read live from
  // government_tax_ledger (RLS already lets a rider read their own rows); never a hard-coded
  // amount/percentage.
  double? _govTaxAmount;
  double? _govTaxRate;
  bool _taxLoading = true;

  @override
  void initState() {
    super.initState();
    _loadGovernmentTax();
  }

  Future<void> _loadGovernmentTax() async {
    final orderId = widget.order['id']?.toString();
    if (orderId == null) {
      if (mounted) setState(() => _taxLoading = false);
      return;
    }
    try {
      // Egress fix (Fix #6): a government_tax_ledger ORDER_TAX row is immutable once written, so
      // it's safe to cache per order_id -- reopening/re-expanding this same order's card within a
      // session no longer re-fetches it. GovernmentTaxLedgerCache never caches a not-found result
      // (Phase 2/Issue 5 fix) -- a fresh card instance for this same order (e.g. list rebuild)
      // always gets a real re-query rather than latching onto a stale/empty read.
      final row = await GovernmentTaxLedgerCache.get(
        orderId,
        () => Supabase.instance.client
            .from('government_tax_ledger')
            .select('amount, rate_percent')
            .eq('order_id', orderId)
            .eq('entry_type', 'ORDER_TAX')
            .maybeSingle(),
      );
      if (!mounted) return;
      setState(() {
        _govTaxAmount = double.tryParse(row?['amount']?.toString() ?? '0') ?? 0.0;
        _govTaxRate = double.tryParse(row?['rate_percent']?.toString() ?? '0') ?? 0.0;
        _taxLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _taxLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final code = order['order_code']?.toString() ?? '';
    final type = order['order_type']?.toString() ?? 'ride';
    // Canonical commission-waiver read -- same source rider_activity_tab.dart's completed-ride
    // sheet uses, so WayDrop Commission never disagrees between the two rider-facing screens that
    // show a completed ride's breakdown.
    final breakdown = FareBreakdown.fromOrder(order);
    final riderEarning = double.tryParse(order['rider_earning']?.toString() ?? '0') ?? 0.0;
    final boostAmount = double.tryParse(order['boost_amount']?.toString() ?? '0') ?? 0.0;
    final surgeFee = double.tryParse(order['surge_fee']?.toString() ?? '0') ?? 0.0;
    final rainFee = double.tryParse(order['rain_fee']?.toString() ?? '0') ?? 0.0;
    final extraFee = surgeFee + rainFee;

    // calculate_fare_breakdown() computes rider_earning = base_fare - commission_amount only --
    // it has no awareness of government tax (that's calculated separately by
    // apply_order_government_tax() into government_tax_ledger). So "Your Trip Earnings" must
    // subtract governmentTax too, never read directly off riderEarning, or it would silently equal
    // Ride Fare whenever commission is 0% (free trial/MAX) -- which is exactly the reported bug.
    //
    // riderEarning - govTax is NOT the fix, though: base_fare (what riderEarning is derived from)
    // already has "Platform GST" (orders.gst_amount, a separate, partner-facing-hidden concept)
    // netted out of it -- so riderEarning alone silently understates true earnings by that amount.
    // Rather than re-deriving commission from scratch, this reuses the already-correct riderEarning
    // and adds back the Platform GST base_fare had netted out: customerPaid - commission - govTax
    // algebraically equals riderEarning + platformGstAmount - govTax. Every term is an existing
    // authoritative column/ledger value; only addition/subtraction is performed here. While the tax
    // lookup is still in flight, this falls back to riderEarning (pre-tax) rather than a wrong number.
    final govTaxAmount = _govTaxAmount ?? 0.0;
    // Eligible Cashfree ride under the deployed 2% PG-charge rule (breakdown.isPgChargeRide,
    // migration 20260901000037): orders.rider_earning is ALREADY the final net (fare - 5% GST -
    // 2% PG charge; government tax skipped). Show it directly -- adding gstAmount back would
    // over-report by the GST amount, and there is no government tax to subtract.
    final netEarnings = breakdown.isPgChargeRide
        ? riderEarning
        : (_taxLoading ? riderEarning : (riderEarning + breakdown.gstAmount - govTaxAmount));

    final distance = double.tryParse(order['distance_km']?.toString() ?? '0') ?? 0.0;
    
    int timeTakenSec = int.tryParse(order['time_taken_seconds']?.toString() ?? '') ?? 0;
    if (timeTakenSec <= 0) {
      final pAt = DateTime.tryParse(order['picked_up_at']?.toString() ?? order['accepted_at']?.toString() ?? '');
      final cAt = DateTime.tryParse(order['completed_at']?.toString() ?? '');
      if (pAt != null && cAt != null) {
        timeTakenSec = cAt.difference(pAt).inSeconds;
        if (timeTakenSec < 0) timeTakenSec = 0;
      }
    }
    
    String timeTakenStr = 'N/A';
    if (timeTakenSec > 0) {
      final mins = timeTakenSec ~/ 60;
      final secs = timeTakenSec % 60;
      timeTakenStr = '${mins}m ${secs}s';
    }

    // Parse completion time: "Completed 4:32 PM"
    String completedTimeStr = 'N/A';
    final completedAtStr = order['completed_at'] ?? order['created_at'];
    if (completedAtStr != null) {
      final dt = DateTime.tryParse(completedAtStr.toString())?.toLocal();
      if (dt != null) {
        final hour = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
        final min = dt.minute.toString().padLeft(2, '0');
        final ampm = dt.hour >= 12 ? 'PM' : 'AM';
        completedTimeStr = 'Completed $hour:$min $ampm';
      }
    }

    final isParcel = type == 'local_parcel' || type == 'intercity_parcel' || type.toString().contains('parcel');
    final vehicleType = order['vehicle_type']?.toString().toLowerCase() ?? 'bike';
    
    String vehicleImgPath = 'assets/images/bike.jpg'; // default
    if (isParcel || vehicleType.contains('delivery') || vehicleType.contains('parcel') || vehicleType.contains('package')) {
      vehicleImgPath = 'assets/images/delivery.png';
    } else if (vehicleType.contains('auto') || vehicleType.contains('rickshaw')) {
      vehicleImgPath = 'assets/images/auto.jpg';
    } else if (vehicleType.contains('cab') || vehicleType.contains('car') || vehicleType.contains('sedan')) {
      vehicleImgPath = 'assets/images/cab.jpg';
    }

    const primaryLime = Color(0xFFC5FF30);
    const textGray = Color(0xFF94A3B8);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF131926),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: InkWell(
        onTap: () {
          setState(() {
            _expanded = !_expanded;
          });
        },
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.asset(
                      vehicleImgPath,
                      width: 36,
                      height: 36,
                      fit: BoxFit.cover,
                      cacheWidth: 108,
                      cacheHeight: 108,
                      errorBuilder: (context, error, stackTrace) => Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: primaryLime.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          isParcel ? Icons.inventory_2_outlined : Icons.two_wheeler_rounded,
                          color: primaryLime,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isParcel ? 'Parcel Delivery (#${code.toUpperCase()})' : 'Ride (#${code.toUpperCase()})',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          completedTimeStr,
                          style: const TextStyle(fontSize: 11, color: textGray),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '+₹${netEarnings.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: primaryLime),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    _expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    color: textGray,
                    size: 16,
                  ),
                ],
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                child: _expanded
                    ? Column(
                        children: [
                          const SizedBox(height: 12),
                          const Divider(color: Colors.white10, height: 1),
                          const SizedBox(height: 12),
                          
                          // RIDE FARE
                          _buildOrderBreakdownSectionHeader('RIDE FARE'),
                          // Ride Fare = breakdown.customerPaid (final_fare/current_fare) -- the
                          // total the passenger was actually charged/quoted. NEVER
                          // breakdown.fareBeforeGst, which nets "Platform GST" out of the total.
                          _buildOrderBreakdownRow('Ride Fare', '₹${breakdown.customerPaid.toStringAsFixed(2)}'),
                          if (boostAmount > 0)
                            _buildOrderBreakdownRow('Boost Earnings', '+₹${boostAmount.toStringAsFixed(2)}', valueColor: primaryLime),
                          if (extraFee > 0) ...[
                            _buildOrderBreakdownRow(
                              'Extra Fee (Weather / Demand)',
                              '+₹${extraFee.toStringAsFixed(2)}',
                              valueColor: const Color(0xFFF59E0B),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(left: 16, bottom: 6),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    '  ↳ Surge Fee',
                                    style: TextStyle(fontSize: 10, color: textGray),
                                  ),
                                  Text(
                                    '₹${surgeFee.toStringAsFixed(2)}',
                                    style: const TextStyle(fontSize: 10, color: Colors.white70),
                                  ),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(left: 16, bottom: 6),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    '  ↳ Rain Fee',
                                    style: TextStyle(fontSize: 10, color: textGray),
                                  ),
                                  Text(
                                    '₹${rainFee.toStringAsFixed(2)}',
                                    style: const TextStyle(fontSize: 10, color: Colors.white70),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 4),
                          _buildOrderBreakdownRow('Distance Traveled', '${distance.toStringAsFixed(1)} km'),
                          _buildOrderBreakdownRow('Active Trip Time', timeTakenStr),
                          const SizedBox(height: 8),
                          const Divider(color: Colors.white10, height: 1),
                          const SizedBox(height: 8),
                          // DEDUCTIONS -- WayDrop Commission and Government Tax are two separate
                          // concepts, never combined. Commission reads the same
                          // subscriptionCommissionWaived flag rider_activity_tab.dart's
                          // completed-ride sheet uses, so this card and that sheet never disagree.
                          // Government Tax was fetched once in initState() (not re-fetched on every
                          // rebuild/expand-toggle) from government_tax_ledger for this exact order
                          // (RLS already lets a rider read their own rows) -- never a hard-coded
                          // amount/percentage. "Platform GST" (orders.gst_amount, a distinct,
                          // separate concept) is deliberately NOT shown here -- partner-facing
                          // screens show only the real Government Tax liability.
                          _buildOrderBreakdownSectionHeader('DEDUCTIONS'),
                          _buildOrderBreakdownRow(
                            breakdown.subscriptionCommissionWaived
                                ? 'WayDrop Commission (0%)'
                                : 'WayDrop Commission (${breakdown.commissionPercentage.toStringAsFixed(0)}%)',
                            breakdown.subscriptionCommissionWaived ? '₹0.00' : '-₹${breakdown.commissionAmount.toStringAsFixed(2)}',
                            valueColor: breakdown.subscriptionCommissionWaived ? Colors.white : const Color(0xFFEF4444),
                          ),
                          if (breakdown.subscriptionCommissionWaived)
                            _buildOrderBreakdownRow('Subscription Benefit', 'Commission waived', valueColor: primaryLime),
                          if (breakdown.isPgChargeRide)
                            // Eligible 2% PG-charge ride -- only the PG charge is an actual wallet
                            // deduction (orders.pg_charge_amount). GST (orders.gst_amount) is shown
                            // further below as a separate, non-deducted figure -- never listed here
                            // under DEDUCTIONS, since it no longer reduces YOUR TRIP EARNINGS.
                            _buildOrderBreakdownRow('PG Charge (2%)', '₹${breakdown.pgChargeAmount.toStringAsFixed(2)}')
                          else
                            _taxLoading
                                ? const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 4),
                                    child: Text(
                                      'Checking applicable government tax...',
                                      style: TextStyle(color: textGray, fontSize: 10),
                                    ),
                                  )
                                : _buildOrderBreakdownRow(
                                    (_govTaxRate ?? 0) > 0
                                        ? 'Government Tax (${_govTaxRate!.toStringAsFixed(0)}%)'
                                        : 'Government Tax',
                                    '₹${govTaxAmount.toStringAsFixed(2)}',
                                  ),
                          const SizedBox(height: 8),
                          const Divider(color: Colors.white10, height: 1),
                          const SizedBox(height: 8),
                          _buildOrderBreakdownRow(
                            'YOUR TRIP EARNINGS',
                            '₹${netEarnings.toStringAsFixed(2)}',
                            valueColor: primaryLime,
                          ),
                          if (breakdown.isPgChargeRide) ...[
                            const SizedBox(height: 4),
                            // GST (5%) -- recorded on the order for reporting/audit, but NOT part of
                            // DEDUCTIONS: it is never subtracted from YOUR TRIP EARNINGS on an
                            // eligible Cashfree ride (Phase 12, migration 20260901000038). Shown
                            // separately, neutrally-colored, so it never reads as a wallet deduction.
                            _buildOrderBreakdownRow(
                              'GST (5%) -- recorded separately',
                              '₹${breakdown.gstAmount.toStringAsFixed(2)}',
                              valueColor: textGray,
                            ),
                          ],
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              breakdown.isPgChargeRide
                                  ? 'PG Charge (2%) is the only deduction from your wallet. GST is recorded separately and is not deducted. No government tax applies on this ride.'
                                  : 'Government tax is separate from company commission and applies '
                                      'regardless of subscription/free-trial status.',
                              style: const TextStyle(color: textGray, fontSize: 9.5, height: 1.3),
                            ),
                          ),
                        ],
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOrderBreakdownRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8), fontWeight: FontWeight.w500)),
          Text(value, style: TextStyle(fontSize: 11, color: valueColor ?? Colors.white, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildOrderBreakdownSectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 2),
      child: Text(
        label,
        style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8), fontWeight: FontWeight.bold, letterSpacing: 0.6),
      ),
    );
  }
}

class RealtimeDurationGrid extends StatefulWidget {
  final int activeTimeSec;
  final DateTime? activeOrderStart;
  final int onlineTimeSec;
  final DateTime? lastOnlineToggleAt;
  final String Function(int) formatDuration;
  final Widget Function(String, String) buildMetricTile;

  const RealtimeDurationGrid({
    super.key,
    required this.activeTimeSec,
    required this.activeOrderStart,
    required this.onlineTimeSec,
    required this.lastOnlineToggleAt,
    required this.formatDuration,
    required this.buildMetricTile,
  });

  @override
  State<RealtimeDurationGrid> createState() => _RealtimeDurationGridState();
}

class _RealtimeDurationGridState extends State<RealtimeDurationGrid> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimerIfNeeded();
  }

  @override
  void didUpdateWidget(covariant RealtimeDurationGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    _startTimerIfNeeded();
  }

  void _startTimerIfNeeded() {
    final isRunning = widget.activeOrderStart != null || widget.lastOnlineToggleAt != null;
    if (isRunning) {
      if (_timer == null) {
        _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (mounted) {
            setState(() {});
          }
        });
      }
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    int displayActiveSec = widget.activeTimeSec;
    if (widget.activeOrderStart != null) {
      final diff = DateTime.now().difference(widget.activeOrderStart!).inSeconds;
      if (diff > 0) {
        displayActiveSec += diff;
      }
    }

    int displayOnlineSec = widget.onlineTimeSec;
    if (widget.lastOnlineToggleAt != null) {
      final diff = DateTime.now().difference(widget.lastOnlineToggleAt!).inSeconds;
      if (diff > 0) {
        displayOnlineSec += diff;
      }
    }

    return Row(
      children: [
        Expanded(
          child: widget.buildMetricTile(
            'Active Working Time',
            widget.formatDuration(displayActiveSec),
          ),
        ),
        Expanded(
          child: widget.buildMetricTile(
            'Online Time',
            widget.formatDuration(displayOnlineSec),
          ),
        ),
      ],
    );
  }
}


