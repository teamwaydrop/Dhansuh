import 'package:flutter/material.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_entry_handler.dart';
import 'package:flutter/services.dart';
import 'package:waydrop/shared/widgets/lazy_indexed_stack.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/providers/initial_data_provider.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/features/rider/models/partner_service_mode.dart';

import 'package:waydrop/features/rider/home/rider_home_tab.dart';
import 'package:waydrop/features/rider/orders/rider_orders_screen.dart';
import 'package:waydrop/features/rider/earnings/rider_earnings_tab.dart';
import 'package:waydrop/features/rider/profile/rider_profile_tab.dart';
import 'package:waydrop/shared/widgets/custom_curved_navigation_bar.dart';

// Every caller, including direct post-payment/order navigation, uses the same guard.
class RiderMainNavigationScreen extends StatelessWidget {
  final int initialIndex;
  const RiderMainNavigationScreen({super.key, this.initialIndex = 0});
  @override
  Widget build(BuildContext context) => RiderEntryHandler(
    readyScreen: _RiderDashboard(initialIndex: initialIndex));
}

class _RiderDashboard extends ConsumerStatefulWidget {
  final int initialIndex;
  const _RiderDashboard({this.initialIndex = 0});

  @override
  ConsumerState<_RiderDashboard> createState() => _RiderDashboardState();
}

class _RiderDashboardState extends ConsumerState<_RiderDashboard> {
  final supabase = Supabase.instance.client;
  late int _index;

  // Local Orders (the "Orders" tab) is a Local City Partner-only concept —
  // an Intercity Traveller partner is matched via Travel Plans instead, so
  // that tab is dropped from the bottom nav entirely for them. Tracked here
  // (rather than trusting a one-time fetch) so switching Service Mode from
  // the Home screen's Service Mode card is reflected in the nav bar the
  // moment riders.service_mode is written, without needing a restart.
  PartnerServiceMode? _serviceMode;
  String? _riderId;
  String? _serviceModeSubId;
  String? _serviceModeSubChannel;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, 3);
    // The entry guard has just published a fresh rider response. Reuse it once
    // for this consumer; later recreations of the same seed still fetch live data.
    final initialData = ref.read(initialRiderDataProvider);
    final initialRider = ref.read(initialRiderDataProvider)?.rider;
    bool seedUsable = false;
    if (initialRider != null && initialData != null && initialData.consumeFor('RiderDashboard', supabase.auth.currentUser?.id)) {
      _serviceMode = PartnerServiceMode.fromDb(initialRider['service_mode']);
      _riderId = initialRider['id']?.toString();
      seedUsable = _riderId != null;
    }
    _loadServiceMode(skipQuery: seedUsable);
  }

  @override
  void dispose() {
    if (_serviceModeSubId != null && _serviceModeSubChannel != null) {
      RealtimeManager.instance.unsubscribe(_serviceModeSubChannel!, _serviceModeSubId!);
    }
    super.dispose();
  }

  // R1 FIX #2: `skipQuery` lets initState() reuse a just-fetched seed instead of re-querying the
  // identical row. Defaults to false so every existing behavior (the live fetch, its error
  // handling, and the subscription that follows it) is unchanged for the mid-session-recreation
  // path and for any future caller that doesn't pass it.
  Future<void> _loadServiceMode({bool skipQuery = false}) async {
    final user = supabase.auth.currentUser;
    if (user == null) return;
    if (!skipQuery) {
      try {
        final data = await supabase
            .from('riders')
            .select('id, service_mode')
            .eq('user_id', user.id)
            .maybeSingle();
        if (!mounted || data == null) return;
        setState(() {
          _riderId = data['id']?.toString();
          _serviceMode = PartnerServiceMode.fromDb(data['service_mode']);
        });
      } catch (e) {
        debugPrint('Error loading service mode for rider nav: $e');
        return;
      }
    }
    if (_riderId != null) _subscribeServiceMode(_riderId!);
  }

  void _subscribeServiceMode(String riderId) {
    // Egress fix (Fix #3): identical table/event/filter (riders, UPDATE, id=riderId) as the
    // channel RiderHomeTab/RiderOrdersScreen/RiderEarningsTab/RiderProfileTab already open under
    // 'rider-home-$riderId' -- reusing that exact name lets RealtimeManager pool this listener
    // onto their existing channel instead of opening a 5th independent socket for the same row.
    _serviceModeSubChannel = 'rider-home-$riderId';
    _serviceModeSubId = RealtimeManager.instance.subscribe(
      channelName: _serviceModeSubChannel!,
      table: 'riders',
      owner: '_RiderDashboard',
      event: PostgresChangeEvent.update,
      schema: 'public',
      filterColumn: 'id',
      filterValue: riderId,
      callback: (payload) {
        if (!mounted) return;
        final newMode = PartnerServiceMode.fromDb(payload.newRecord['service_mode']);
        if (newMode == _serviceMode) return;
        setState(() {
          _serviceMode = newMode;
          final maxIndex = _buildTabs().length - 1;
          if (_index > maxIndex) _index = 0;
        });
      },
    );
  }

  bool get _isIntercity => _serviceMode == PartnerServiceMode.intercity;

  // P2-A: _buildTabs() re-runs on every build() (including every tab switch, since IndexedStack
  // keeps all children mounted), so this always reflects the CURRENT _index -- RiderHomeTab's
  // element is preserved across rebuilds by its ValueKey, so a changing isActive value reaches its
  // State via didUpdateWidget exactly the way it's meant to.
  List<Widget> _buildTabs() {
    // Earnings/Profile follow Orders, whose own presence/position is pinned by the visibility
    // test in rider_orders_tab_visibility_regression_test.dart -- shift their indices to match.
    final earningsIndex = _isIntercity ? 1 : 2;
    final profileIndex = _isIntercity ? 2 : 3;
    return [
      RiderHomeTab(key: const ValueKey('home'), isActive: _index == 0),
      // Orders is always index 1 when present (immediately after Home, only shown for
      // !_isIntercity) -- see the visibility test in
      // rider_orders_tab_visibility_regression_test.dart for why this tab's presence/position
      // is pinned that way.
      if (!_isIntercity) RiderOrdersScreen(key: const ValueKey('orders'), isActive: _index == 1),
      RiderEarningsTab(key: const ValueKey('earnings'), isActive: _index == earningsIndex),
      RiderProfileTab(key: const ValueKey('profile'), isActive: _index == profileIndex),
    ];
  }

  List<CustomNavBarItem> _buildNavItems() => [
        const CustomNavBarItem(
          iconActive: Icons.home_rounded,
          iconInactive: Icons.home_outlined,
          label: 'Home',
        ),
        if (!_isIntercity)
          const CustomNavBarItem(
            iconActive: Icons.receipt_long_rounded,
            iconInactive: Icons.receipt_long_outlined,
            label: 'Orders',
          ),
        const CustomNavBarItem(
          iconActive: Icons.account_balance_wallet_rounded,
          iconInactive: Icons.account_balance_wallet_outlined,
          label: 'Earnings',
        ),
        const CustomNavBarItem(
          iconActive: Icons.person_rounded,
          iconInactive: Icons.person_outline_rounded,
          label: 'Profile',
        ),
      ];

  static const Color darkBg = Color(0xFF0B0F19);

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarContrastEnforced: false,
    ));

    final activeAssignmentsCount = ref.watch(activeAssignmentsCountProvider);

    final tabs = _buildTabs();
    final navItems = _buildNavItems();
    final safeIndex = _index.clamp(0, tabs.length - 1);
    final ordersIndex = _isIntercity ? -1 : 1;

    return Scaffold(
      backgroundColor: darkBg,
      body: Stack(
        children: [
          LazyIndexedStack(
            // Home owns dispatch, pending-assignment reconciliation and GPS.
            eagerIndices: const {0},
            index: safeIndex,
            children: tabs,
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: CustomCurvedNavigationBar(
              currentIndex: safeIndex,
              onTap: _onTap,
              activeIconColor: const Color(0xFF0B0F19), // Dark contrast color for active icon on white background
              backgroundColor: darkBg, // Match the screen background
              badges: ordersIndex >= 0 ? {ordersIndex: activeAssignmentsCount} : const {},
              items: navItems,
            ),
          ),
        ],
      ),
    );
  }

  void _onTap(int i) => setState(() => _index = i);
}
