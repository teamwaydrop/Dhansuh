import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/auth/screens/login_screen.dart';
import 'package:waydrop/main.dart'; // import navigatorKey
import 'package:waydrop/shared/helpers/auth_session.dart';
import 'package:waydrop/shared/widgets/app_snackbar.dart';
import 'package:waydrop/core/services/cache/cache_cleanup_helper.dart';
import 'package:waydrop/core/services/developer/developer_mode_service.dart';
import 'package:waydrop/core/navigation/nav_trace.dart';

class UserSessionService {
  static final UserSessionService _instance = UserSessionService._internal();
  factory UserSessionService() => _instance;
  UserSessionService._internal();

  final _supabase = Supabase.instance.client;
  RealtimeChannel? _suspensionChannel;

  /// Starts listening to real-time changes to the current user's profile
  /// to log them out immediately if their account is suspended or deleted.
  void listenUserSuspension() {
    final user = _supabase.auth.currentUser;
    if (user == null) return;

    // Unsubscribe from any previous channel first
    stopListening();

    debugPrint('[TRACE_SESSION] Starting real-time user suspension listener for: ${user.id} epoch=${DateTime.now().millisecondsSinceEpoch}');

    _suspensionChannel = _supabase
        .channel('user-suspension-${user.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'users',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: user.id,
          ),
          callback: (payload) async {
            final isSuspended = payload.newRecord['is_suspended'] ?? false;
            final isDeleted = payload.newRecord['deleted_at'] != null;
            if (isSuspended || isDeleted) {
              debugPrint(
                isDeleted
                    ? 'Account deletion detected real-time! Logging out.'
                    : 'User suspension detected real-time! Logging out.',
              );

              // A network hiccup on signOut() must never leave a suspended user logged in --
              // clearing local state and navigating away (best-effort local logout) still has to
              // happen even if the remote sign-out call itself throws. Previously this whole
              // callback had no try/catch, so a signOut() failure silently defeated real-time
              // suspension enforcement entirely: cache/session were never cleared and the user was
              // never routed to LoginScreen.
              try {
                await _supabase.auth.signOut();
              } catch (e, st) {
                debugPrint('User suspension: remote signOut() failed, continuing with local logout anyway: $e');
                debugPrintStack(stackTrace: st);
              }

              try {
                await CacheCleanupHelper.clearAllCaches();
                AuthSession.clear();
                DeveloperModeService.instance.clear();
                stopListening();

                // Route back to WelcomeScreen
                NavTrace.begin('UserSessionService', 'pushAndRemoveUntil LoginScreen (suspension/deletion)');
                navigatorKey.currentState?.pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (route) => false,
                );
                NavTrace.end('UserSessionService', 'pushAndRemoveUntil LoginScreen (suspension/deletion)');

                // Display suspended/deleted alert SnackBar
                final context = navigatorKey.currentContext;
                if (context != null) {
                  showAppSnackBar(
                    context,
                    isDeleted
                        ? 'Your account has been deleted.'
                        : 'Your account has been suspended. Please contact support.',
                    type: SnackBarType.error,
                  );
                }
              } catch (e, st) {
                debugPrint('User suspension: local logout cleanup/navigation failed: $e');
                debugPrintStack(stackTrace: st);
              }
            }
          },
        )
        .subscribe();
  }

  /// Cancels the real-time subscription.
  void stopListening() {
    if (_suspensionChannel != null) {
      debugPrint('Stopping user suspension listener.');
      _supabase.removeChannel(_suspensionChannel!);
      _suspensionChannel = null;
    }
  }
}
