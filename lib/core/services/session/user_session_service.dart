import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';
import 'package:waydrop/app_start_screen.dart';
import 'package:waydrop/core/services/location/location_cache_service.dart';
import 'package:waydrop/modules/notifications/services/notification_badge_service.dart';
import 'package:waydrop/main.dart'; // import navigatorKey
import 'package:waydrop/shared/helpers/auth_session.dart';
import 'package:waydrop/shared/widgets/app_snackbar.dart';
import 'package:waydrop/core/services/cache/cache_cleanup_helper.dart';
import 'package:waydrop/core/services/developer/developer_mode_service.dart';
import 'package:waydrop/core/navigation/nav_trace.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/core/services/session/account_profile_service.dart';

class UserSessionService with WidgetsBindingObserver {
  static final UserSessionService _instance = UserSessionService._internal();
  factory UserSessionService() => _instance;
  UserSessionService._internal();

  final _supabase = Supabase.instance.client;
  String? _suspensionSubscriptionId;
  String? _suspensionChannelName;
  bool _handlingRestriction = false;
  bool _validatingAuth = false;
  int _generation = 0;
  StreamSubscription<AuthState>? _authSubscription;

  /// Starts listening to real-time changes to the current user's profile
  /// to log them out immediately if their account is suspended or deleted.
  void listenUserSuspension() {
    final user = _supabase.auth.currentUser;
    if (user == null) return;

    // Unsubscribe from any previous channel first
    stopListening();
    WidgetsBinding.instance.addObserver(this);
    _authSubscription = _supabase.auth.onAuthStateChange.listen((state) {
      if (state.event == AuthChangeEvent.tokenRefreshed ||
          state.event == AuthChangeEvent.userUpdated) {
        unawaited(_verifyAuth());
      }
    }, onError: (Object error, StackTrace stack) {
      debugPrint('Account Auth listener could not verify the session.');
    });

    debugPrint('[TRACE_SESSION] Starting real-time user suspension listener for: ${user.id} epoch=${DateTime.now().millisecondsSinceEpoch}');

    _suspensionChannelName = 'user-suspension-${user.id}';
    _suspensionSubscriptionId = RealtimeManager.instance.subscribe(
      channelName: _suspensionChannelName!,
      table: 'users',
      owner: 'UserSessionService',
      event: PostgresChangeEvent.update,
      filterColumn: 'id',
      filterValue: user.id,
      callback: (payload) async {
        final isDeleted = payload.newRecord['deleted_at'] != null;
        if (isDeleted) {
          await handleAccountRestriction(isDeleted: isDeleted);
        } else {
          await _verifyAuth();
        }
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_verifyAuth());
  }

  Future<void> _verifyAuth() async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null || _validatingAuth) return;
    final generation = _generation;
    _validatingAuth = true;
    try {
      await AccountProfileService.instance.verifyAuth(userId);
    } on AccountRestrictedException {
      if (generation == _generation && _supabase.auth.currentUser?.id == userId) {
        await handleAccountRestriction(isDeleted: false);
      }
    } on AuthException catch (error) {
      if (!AccountProfileService.isTransient(error) &&
          generation == _generation && _supabase.auth.currentUser?.id == userId) {
        await handleAccountRestriction(isDeleted: false,
            message: 'Your session could not be verified. Please sign in again.');
      }
    } catch (error) {
      // An unavailable Auth service is unknown, never proof of an unbanned user.
      // Startup/privileged entry remains gated; a reconnect/resume revalidates.
      debugPrint('Account Auth verification unavailable; will recheck on resume/refresh.');
    } finally {
      _validatingAuth = false;
    }
  }

  /// Preserve the app-level auth owner even when a mode switch replaced its route.
  /// Remote logout failure must not strand the next OTP login on a bare LoginScreen.
  Future<void> handleAccountRestriction({required bool isDeleted, String? message}) async {
    final restrictedUserId = _supabase.auth.currentUser?.id;
    if (_handlingRestriction || restrictedUserId == null) return;
    _handlingRestriction = true;
    stopListening();
    NotificationBadgeService.instance.stopListening();
    try {
      try {
        // This installed SDK removes the local session before the remote request.
        await _supabase.auth.signOut().timeout(const Duration(seconds: 8));
      } catch (error) {
        debugPrint('Restricted account: remote logout failed; local session was cleared.');
      }
      // Do not let an old account's slow logout replace a newly signed-in account.
      if (_supabase.auth.currentUser != null &&
          _supabase.auth.currentUser!.id != restrictedUserId) {
        return;
      }
      try {
        await CacheCleanupHelper.clearAllCaches().timeout(const Duration(seconds: 8));
      } catch (error) {
        debugPrint('Restricted account: cache cleanup failed.');
      }
      if (_supabase.auth.currentUser != null &&
          _supabase.auth.currentUser!.id != restrictedUserId) {
        return;
      }
      AuthSession.clear();
      DeveloperModeService.instance.clear();
      unawaited(LocationCacheService.stopRiderLiveTracking());
      NavTrace.begin('UserSessionService', 'restore AppStartScreen after restriction');
      navigatorKey.currentState?.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AppStartScreen()),
        (_) => false,
      );
      NavTrace.end('UserSessionService', 'restore AppStartScreen after restriction');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final context = navigatorKey.currentContext;
        if (context != null && context.mounted) {
          showAppSnackBar(context,
            message ?? (isDeleted ? 'Your account has been deleted.' : 'Your account has been suspended. Please contact support.'),
            type: SnackBarType.error);
        }
      });
    } finally {
      _handlingRestriction = false;
    }
  }

  /// Cancels the real-time subscription.
  void stopListening() {
    ++_generation;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_authSubscription?.cancel());
    _authSubscription = null;
    final subscriptionId = _suspensionSubscriptionId;
    final channelName = _suspensionChannelName;
    _suspensionSubscriptionId = null;
    _suspensionChannelName = null;
    if (subscriptionId != null && channelName != null) {
      debugPrint('Stopping user suspension listener.');
      RealtimeManager.instance.unsubscribe(channelName, subscriptionId);
    }
  }
}
