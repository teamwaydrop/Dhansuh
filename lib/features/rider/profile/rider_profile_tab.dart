import 'dart:async';
import 'package:waydrop/core/services/cache/identity_scoped_future.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:waydrop/modules/notifications/services/notification_service.dart';
import 'package:waydrop/core/services/cache/cache_cleanup_helper.dart';
import 'package:waydrop/core/services/session/user_session_service.dart';
import 'package:waydrop/main_navigation_screen.dart';
import 'package:waydrop/shared/helpers/auth_session.dart';
import 'package:waydrop/features/rider/orders/screens/rider_order_history_screen.dart';
import 'package:waydrop/features/rider/payouts/rider_payouts_screen.dart';
import 'package:waydrop/features/rider/settings/rider_settings_screen.dart';
import 'package:waydrop/modules/support/screens/admin_support_chats_screen.dart';
import 'package:waydrop/modules/chat/screens/order_chat_screen.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_payout_details_screen.dart';
import 'package:waydrop/features/rider/vehicles/screens/my_vehicles_screen.dart';
import 'package:waydrop/modules/support/screens/customer_support_screen.dart';
import 'package:waydrop/modules/rewards/services/reward_service.dart';
import 'package:waydrop/modules/rewards/screens/rewards_screen.dart';
import 'package:waydrop/modules/rewards/widgets/reward_profile_tile.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:waydrop/core/providers/app_mode_provider.dart';
import 'package:waydrop/core/providers/initial_data_provider.dart';
import 'package:waydrop/shared/widgets/skeleton_loader.dart';
import 'package:waydrop/shared/helpers/insets.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/main.dart';

class RiderProfileTab extends ConsumerStatefulWidget {
  // [PERF] whether this tab is the currently visible/selected tab inside
  // RiderMainNavigationScreen's IndexedStack. Defaults to true so any call site that doesn't pass
  // it keeps running exactly as before. Mirrors RiderOrdersScreen.isActive: only pauses the
  // riders-row realtime subscription (a pure display refresh with no dispatch side effects) while
  // this tab is off-screen; everything else is untouched.
  final bool isActive;

  const RiderProfileTab({super.key, this.isActive = true});

  @override
  ConsumerState<RiderProfileTab> createState() => _RiderProfileTabState();
}

class _RiderProfileTabState extends ConsumerState<RiderProfileTab> {
  final supabase = Supabase.instance.client;
  Map<String, dynamic>? rider;
  Map<String, dynamic>? kyc;
  String userCode = '';
  bool loading = true;
  String? _riderSubChannel;
  String? _riderSubId;
  int _loadRevision = 0;
  int _subscriptionRevision = 0;
  String? _profileUserId;
  bool _disposed = false;

  bool _loadIsCurrent(String userId, int revision) => mounted && !_disposed &&
      supabase.auth.currentUser?.id == userId && _loadRevision == revision;

  void _releaseRiderSubscription() {
    _subscriptionRevision++;
    final channel = _riderSubChannel;
    final id = _riderSubId;
    _riderSubChannel = null;
    _riderSubId = null;
    _subscribedRiderId = null;
    if (channel != null && id != null) {
      RealtimeManager.instance.unsubscribe(channel, id);
    }
  }

  // R1 FIX #6: distinguishes a true cold-start mount (initialRiderDataProvider's snapshot is
  // guaranteed fresh -- fetched by AppStartScreen moments earlier in the same navigation
  // transition) from a mid-session recreation (returnToLocalRideHome()'s pushAndRemoveUntil
  // rebuilds RiderMainNavigationScreen and, with it, a brand-new _RiderProfileTabState -- the
  // same never-refreshed snapshot would otherwise be stale there). `static` survives individual
  // State disposal but not a process restart, so this is false exactly once per app launch and
  // true for every subsequent _RiderProfileTabState construction within that same process.
  // Scoped to this class only -- intentionally independent of RiderMainNavigationScreen's,
  // RiderHomeTab's, RiderOrdersScreen's, and RiderEarningsTab's own identically-shaped flags.
  static bool _hasConsumedColdStartSeed = false;

  static const Color primaryLime = Color(0xFFC5FF30);
  static const Color darkBg = Color(0xFF0B0F19);
  static const Color darkCard = Color(0xFF131926);
  static const Color textGray = Color(0xFF94A3B8);

  // PERF FIX (P7, rider location write-volume audit): the exact riders columns this tab's own
  // `build()`/business logic reads off `rider` (verified by grep across this file -- `full_name`/
  // `rider_image` fallbacks read from `rider` are dead: those columns don't exist on `riders`,
  // they only ever resolve via the separate `kyc` fetch below). `kyc_id` is included because
  // loadProfileData()'s own rider_kyc fetch is keyed off it (`riders.kyc_id` changing means the
  // cached `kyc` state is for the wrong record until refetched). `account_status` is included
  // because switchToUser()'s error-fallback path reads it off this same cached `rider` map. A
  // realtime `riders` UPDATE whose changed columns are a subset of LocationCacheService's GPS
  // heartbeat fields (current_lat/current_lng/current_heading/last_location_updated_at/
  // last_active_at/updated_at) can never affect any of this and is safe to skip the 3-query
  // loadProfileData() reload for. Kept as an explicit allowlist (not a blocklist) so any *new*
  // field this tab starts depending on in the future safely falls through to a refresh by default
  // instead of silently being ignored -- same reasoning as RiderHomeTab's own
  // _earningsRelevantFields/_locationHeartbeatFields (rider_home_tab.dart).
  static const Set<String> _profileRelevantFields = {
    'rating',
    'kyc_id',
    'account_status',
  };

  String? _subscribedRiderId;
  // [PERF] Issue #2: cached admin-role query — created once, not per rebuild.
  late Future<Map<String, dynamic>?> _adminRoleFuture;
  late Future<Map<String, dynamic>?> _rewardStatusFuture;
  late final IdentityScopedFuture<Map<String, dynamic>> _roleCache;
  late final IdentityScopedFuture<Map<String, dynamic>> _rewardCache;
  StreamSubscription<AuthState>? _cacheAuthSubscription;
  String? _cacheUserId;

  void _bindIdentityFutures() {
    _cacheUserId = supabase.auth.currentUser?.id;
    _adminRoleFuture = _roleCache.read('users:role', _loadAdminRole);
    _rewardStatusFuture = _rewardCache.read('rewards:rider', () => RewardService.fetchStatus('rider'));
  }

  @override
  void initState() {
    super.initState();
    _roleCache = IdentityScopedFuture(() => supabase.auth.currentUser?.id);
    _rewardCache = IdentityScopedFuture(() => supabase.auth.currentUser?.id);
    _bindIdentityFutures();
    _cacheAuthSubscription = supabase.auth.onAuthStateChange.listen((_) {
      if (!mounted || _disposed || _cacheUserId == supabase.auth.currentUser?.id) return;
      setState(_bindIdentityFutures);
      // Retire the old subscription immediately, even when the new identity is null.
      _loadRevision++;
      _releaseRiderSubscription();
      loadProfileData();
    });
    loadProfileData();
  }

  Future<Map<String, dynamic>?> _loadAdminRole() {
    return supabase
        .from('users')
        .select('role')
        .eq('id', supabase.auth.currentUser?.id ?? '')
        .maybeSingle();
  }

  @override
  void didUpdateWidget(covariant RiderProfileTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive != oldWidget.isActive) {
      if (widget.isActive) {
        // Tab became visible again -- refresh immediately (the realtime subscription was paused,
        // so the displayed data may be stale) then let _subscribeRider() re-attach as normal.
        loadProfileData();
      } else if (_riderSubChannel != null && _riderSubId != null) {
        _releaseRiderSubscription();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cacheAuthSubscription?.cancel();
    _roleCache.dispose();
    _rewardCache.dispose();
    _loadRevision++;
    _releaseRiderSubscription();
    super.dispose();
  }

  Future<void> loadProfileData() async {
    if (!mounted || _disposed) return;
    final user = supabase.auth.currentUser;
    if (user == null) return;
    final revision = ++_loadRevision;
    if (_profileUserId != user.id) {
      _releaseRiderSubscription();
      _profileUserId = user.id;
    }
    try {

      // 1. Fetch user_code
      final userData = await supabase
          .from('users')
          .select('user_code')
          .eq('id', user.id)
          .maybeSingle();
      if (!_loadIsCurrent(user.id, revision)) return;
      final fetchedUserCode = userData?['user_code']?.toString() ?? '...';

      // 2. Fetch Rider details
      // R1 FIX #6: a true cold start reuses AppStartScreen's already-fetched riders row instead
      // of re-querying an identical row a moment later -- safe because nothing can have changed
      // server-side between that fetch and this mount. The seed is a `select('*', ...)` fetch of
      // the same table/row, so it covers every field this tab reads. The rider_kyc fetch below is
      // untouched -- the seed's own rider_kyc embed doesn't carry vehicle_number/vehicle_type,
      // so it can never replace this screen's own kyc query.
      final initialData = providerContainer.read(initialRiderDataProvider);
      final seedRider = initialData?.belongsTo(user.id) == true ? initialData?.rider : null;
      final Map<String, dynamic>? riderData;
      if (seedRider != null && seedRider['id'] != null && !_hasConsumedColdStartSeed) {
        _hasConsumedColdStartSeed = true;
        riderData = seedRider;
      } else {
        // Egress fix: narrowed to the fields read off `rider` in this file (grepped exhaustively --
        // full_name/rider_image are NOT real columns on `riders`, they're already dead fallbacks
        // here since only rider_kyc carries them).
        riderData = await supabase
            .from('riders')
            .select('id, kyc_id, account_status, rating')
            .eq('user_id', user.id)
            .maybeSingle();
      }
      if (!_loadIsCurrent(user.id, revision)) return;

      if (riderData != null) {
        // 3. Fetch KYC details (contains profile picture and vehicle number)
        // Egress fix: narrowed to the fields read off `kyc` in this file.
        final kycData = await supabase
            .from('rider_kyc')
            .select('full_name, vehicle_number, vehicle_type, rider_image')
            .eq('id', riderData['kyc_id'])
            .maybeSingle();
        if (!_loadIsCurrent(user.id, revision)) return;

        if (mounted) {
          setState(() {
            rider = riderData;
            kyc = kycData;
            userCode = fetchedUserCode;
            loading = false;
          });
        }
        _subscribeRider(riderData['id'], user.id);
      } else {
        if (mounted) {
          setState(() {
            userCode = fetchedUserCode;
            loading = false;
          });
        }
      }
    } catch (e) {
      debugPrint('LOAD PROFILE DATA ERROR => $e');
      if (_loadIsCurrent(user.id, revision)) setState(() => loading = false);
    }
  }

  void _subscribeRider(String riderId, String userId) {
    if (!mounted || _disposed || !widget.isActive ||
        supabase.auth.currentUser?.id != userId || _profileUserId != userId) {
      return;
    }
    if (_subscribedRiderId == riderId) return;
    _releaseRiderSubscription();
    _subscribedRiderId = riderId;
    final subscriptionRevision = _subscriptionRevision;
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
      owner: 'RiderProfileTab',
      event: PostgresChangeEvent.update,
      schema: 'public',
      filterColumn: 'id',
      filterValue: riderId,
      callback: (payload) {
        if (!mounted || _disposed || !widget.isActive ||
            supabase.auth.currentUser?.id != userId ||
            _profileUserId != userId || _subscribedRiderId != riderId ||
            _subscriptionRevision != subscriptionRevision) {
          return;
        }
        final oldData = payload.oldRecord;
        final newData = payload.newRecord;
        // Conservative fallback (matches RiderHomeTab's own gating): if oldRecord is empty (no
        // diff available), treat every key as changed rather than silently skipping.
        final isProfileRelevantUpdate = oldData.isEmpty ||
            newData.keys
                .where((key) => !oldData.containsKey(key) || oldData[key] != newData[key])
                .any(_profileRelevantFields.contains);
        if (isProfileRelevantUpdate) {
          loadProfileData();
        }
      },
    );
  }

  Future<void> logout() async {
    final logoutUserId = supabase.auth.currentUser?.id;
    final confirm = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: darkBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
             const SizedBox.shrink(),
            const SizedBox(height: 28),
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFFEF4444).withValues(alpha: 0.2),
                  width: 1.5,
                ),
              ),
              child: const Center(
                child: Icon(Icons.logout_rounded, color: Color(0xFFEF4444), size: 34),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Sign Out?',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
                color: Colors.white,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Are you sure you want to sign out of your account on this device?',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: textGray,
                height: 1.45,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 32),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(
                        color: Colors.white24,
                        width: 1.5,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                      minimumSize: const Size.fromHeight(54),
                    ),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFEF4444),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                      minimumSize: const Size.fromHeight(54),
                    ),
                    child: const Text(
                      'Sign Out',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    if (confirm != true) return;
    if (!mounted || logoutUserId == null || supabase.auth.currentUser?.id != logoutUserId) return;

    try {
      await NotificationService().removeToken();
    } catch (_) {}
    if (!mounted || supabase.auth.currentUser?.id != logoutUserId) return;
    await supabase.auth.signOut();
    await CacheCleanupHelper.clearAllCaches();
    AuthSession.clear();
    UserSessionService().stopListening();
    // BUG FIX (logout -> login -> OTP gets stuck until app restart): this used to
    // Navigator.pushAndRemoveUntil(...LoginScreen(), (_) => false) here, which -- with a
    // predicate that always returns false -- removes every route including the app's own
    // `home:` route (AppStartScreen itself), disposing its State and, with it, the
    // onAuthStateChange listener that OTP verification depends on to navigate (see
    // otp_screen.dart's comment: "AppStartScreen's listener is the sole source of truth for
    // post-login routing"). AppStartScreen was still alive and still subscribed at the moment
    // signOut() above resolved, so its own listener already reacts to the `signedOut` event
    // and swaps currentScreen to LoginScreen itself -- no manual navigation is needed here at
    // all, and doing it manually was actively harmful: it destroyed the one listener the next
    // login's post-OTP navigation relies on, so a second login-in-the-same-process would
    // verify the OTP successfully but never navigate anywhere (fixed only by a full app
    // restart, which recreates AppStartScreen fresh).
  }

  Future<void> switchToUser() async {
    final user = supabase.auth.currentUser;
    if (user == null) return;

    try {
      final dbRider = await supabase
          .from('riders')
          .select('account_status')
          .eq('user_id', user.id)
          .maybeSingle();
      if (!mounted || supabase.auth.currentUser?.id != user.id) return;
      if (dbRider != null && dbRider['account_status'] == 'online') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please go offline in Drop Partner Mode before switching to User Mode.'),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }
    } catch (e) {
      debugPrint('Direct status check failed: $e');
      if (!mounted || supabase.auth.currentUser?.id != user.id) return;
      if (rider != null && rider?['account_status'] == 'online') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please go offline in Drop Partner Mode before switching to User Mode.'),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }
    }

    final confirm = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: darkCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 20),
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(color: const Color(0xFF1E293B), borderRadius: BorderRadius.circular(20)),
              child: const Icon(Icons.swap_horiz_rounded, color: primaryLime, size: 30),
            ),
            const SizedBox(height: 16),
            const Text('Switch to User Mode?', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.white)),
            const SizedBox(height: 6),
            const Text('You will switch to client/user view to order rides and deliveries.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: textGray)),
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
                    child: const Text('Switch', style: TextStyle(fontWeight: FontWeight.w800, color: Colors.black)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    if (confirm != true) return;
    if (!mounted || supabase.auth.currentUser?.id != user.id) return;

    await supabase.from('users').update({'preferred_mode': 'user'}).eq('id', user.id);
    if (!mounted || supabase.auth.currentUser?.id != user.id) return;
    ref.read(appModeProvider.notifier).switchToUser();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const MainNavigationScreen()),
      (_) => false,
    );
  }

  String _capitalize(String text) {
    if (text.isEmpty) return '';
    return text[0].toUpperCase() + text.substring(1);
  }

  Widget _buildGroupedCard({required List<Widget> children}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: darkCard,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: children,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = kyc?['full_name'] ?? rider?['full_name'] ?? 'Edward';
    final vehicleNumber = kyc?['vehicle_number'] ?? '';
    final vehicleType = kyc?['vehicle_type'] ?? 'bike';
    final rating = double.tryParse(rider?['rating']?.toString() ?? '') ?? 4.96;
    final displayVehicle = vehicleNumber.isNotEmpty
        ? '${_capitalize(vehicleType)} • $vehicleNumber'
        : 'Hyundai Solaris • S10364';

    final imageUrl = kyc?['rider_image'] ?? rider?['rider_image'];
    final riderId = rider?['id']?.toString() ?? '';

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
                  // Header Row: Profile Title and Settings settings icon
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Profile',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1.0,
                        ),
                      ),
                      GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => RiderSettingsScreen(
                                kycData: kyc,
                                riderData: rider,
                              ),
                            ),
                          );
                        },
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: darkCard,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.15),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.more_horiz_rounded,
                            color: Colors.white70,
                            size: 22,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Rider User Info Card (No edit rename options on the Rider side)
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: darkCard,
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        // Rider avatar circle
                        Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: primaryLime, width: 2),
                            boxShadow: [
                              BoxShadow(
                                color: primaryLime.withValues(alpha: 0.15),
                                blurRadius: 16,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: ClipOval(
                            child: (imageUrl != null && imageUrl.toString().startsWith('http'))
                                ? CachedNetworkImage(
                                    imageUrl: imageUrl.toString(),
                                    fit: BoxFit.cover,
                                    fadeInDuration: Duration.zero,
                                    fadeOutDuration: Duration.zero,
                                    placeholder: (ctx, url) => const ImageSkeleton(shape: BoxShape.circle),
                                    errorWidget: (ctx, url, err) => const Icon(Icons.person_rounded, color: Colors.white, size: 30),
                                  )
                                : const Icon(Icons.person_rounded, color: Colors.white, size: 30),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: -0.3,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: primaryLime.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          rating.toStringAsFixed(1),
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: primaryLime,
                                          ),
                                        ),
                                        const SizedBox(width: 2),
                                        const Icon(Icons.star_rounded, color: primaryLime, size: 12),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                displayVehicle,
                                style: const TextStyle(
                                  color: textGray,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Group 1 Card: Rider operations
                  _buildGroupedCard(
                    children: [
                      _MenuTile(
                        icon: Icons.history_rounded,
                        label: 'Completed Orders',
                        subtitle: 'View history of rides and parcels',
                        color: primaryLime,
                        onTap: () {
                          if (riderId.isNotEmpty) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => RiderOrderHistoryScreen(riderId: riderId),
                              ),
                            );
                          }
                        },
                      ),
                      FutureBuilder<Map<String, dynamic>?>(
                        key: ValueKey('rider-rewards:$_cacheUserId'),
                        future: _rewardStatusFuture,
                        builder: (context, snapshot) {
                          final status = snapshot.data;
                          final show = status != null && RewardService.isFeatureEnabled(status);
                          return Column(
                            children: [
                              const Divider(height: 1, indent: 64, color: Colors.white10),
                              if (show) ...[
                                RewardProfileTile(
                                  status: status,
                                  icon: Icons.confirmation_number_rounded,
                                  iconColor: primaryLime,
                                  iconBgColor: primaryLime.withValues(alpha: 0.1),
                                  titleColor: Colors.white,
                                  subtitleColor: textGray,
                                  chevronColor: const Color(0xFF475569),
                                  progressTrackColor: Colors.white.withValues(alpha: 0.08),
                                  onTap: () {
                                    if (RewardService.isUnlocked(status)) {
                                      Navigator.push(context, MaterialPageRoute(builder: (_) => const RewardsScreen(ownerType: 'rider')));
                                    } else {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text(RewardService.subtitleFor(status))),
                                      );
                                    }
                                  },
                                ),
                                const Divider(height: 1, indent: 64, color: Colors.white10),
                              ],
                            ],
                          );
                        },
                      ),
                      _MenuTile(
                        icon: Icons.directions_car_filled_rounded,
                        label: 'My Vehicles',
                        subtitle: 'View and add verified vehicles',
                        color: primaryLime,
                        onTap: () {
                          if (riderId.isNotEmpty) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => MyVehiclesScreen(riderId: riderId, kyc: kyc, accountId: _profileUserId, kycId: rider?['kyc_id']?.toString()),
                              ),
                            );
                          }
                        },
                      ),
                      const Divider(height: 1, indent: 64, color: Colors.white10),
                      _MenuTile(
                        icon: Icons.account_balance_wallet_rounded,
                        label: 'Payout Transactions',
                        subtitle: 'Withdrawal payouts and status log',
                        color: primaryLime,
                        onTap: () {
                          if (riderId.isNotEmpty) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => RiderPayoutsScreen(riderId: riderId),
                              ),
                            );
                          }
                        },
                      ),
                      const Divider(height: 1, indent: 64, color: Colors.white10),
                      _MenuTile(
                        icon: Icons.credit_card_rounded,
                        label: 'Payment Settings',
                        subtitle: 'Configure payout accounts',
                        color: primaryLime,
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const RiderPayoutDetailsScreen(),
                            ),
                          );
                        },
                      ),
                      const Divider(height: 1, indent: 64, color: Colors.white10),
                      _MenuTile(
                        icon: Icons.swap_horiz_rounded,
                        label: 'Switch to User Mode',
                        subtitle: 'Order rides and deliveries',
                        color: const Color(0xFF2563EB),
                        onTap: switchToUser,
                      ),
                      // Conditional Admin support panel tile
                      FutureBuilder<Map<String, dynamic>?>(
                        key: ValueKey('rider-role:$_cacheUserId'),
                        future: _adminRoleFuture,
                        builder: (context, snapshot) {
                          if (snapshot.hasData && (snapshot.data?['role'] == 'admin' || snapshot.data?['role'] == 'support')) {
                            return Column(
                              children: [
                                const Divider(height: 1, indent: 64, color: Colors.white10),
                                _MenuTile(
                                  icon: Icons.admin_panel_settings_rounded,
                                  label: 'Admin Support Panel',
                                  subtitle: 'View and reply to client help requests',
                                  color: const Color(0xFFEF4444),
                                  onTap: () {
                                    Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminSupportChatsScreen()));
                                  },
                                ),
                              ],
                            );
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Group 2 Card: Customer support & details
                  _buildGroupedCard(
                    children: [
                      _MenuTile(
                        icon: Icons.help_outline_rounded,
                        label: 'Help & Legal Policies',
                        subtitle: 'Get help with orders, payouts and compliance',
                        color: const Color(0xFF7C3AED),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const CustomerSupportScreen(),
                            ),
                          );
                        },
                      ),
                      const Divider(height: 1, indent: 64, color: Colors.white10),
                      _MenuTile(
                        icon: Icons.logout_rounded,
                        label: 'Sign Out',
                        subtitle: 'Logout from this device',
                        color: const Color(0xFFEF4444),
                        onTap: logout,
                      ),
                    ],
                  ),
                  SizedBox(height: 96 + Insets.bottom(context)),
                ],
              ),
      ),
    );
  }
}

// Grouped card tile helper widget for Rider
class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final Color color;
  final VoidCallback onTap;
  final Widget? trailing;

  const _MenuTile({
    required this.icon,
    required this.label,
    this.subtitle,
    required this.color,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFF94A3B8),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing ?? Icon(
              Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.3),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}
