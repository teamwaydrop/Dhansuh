import 'dart:async';
import 'package:waydrop/core/services/session/auth_routing_policy.dart';
import 'package:waydrop/core/services/session/account_profile_service.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/auth/screens/login_screen.dart';
import 'package:waydrop/shared/screens/connection_error_screen.dart';
import 'package:waydrop/shared/helpers/global_error_controller.dart';

/// Screen protection complements RLS; roles come from the database, never metadata.
class AccountGuard extends StatefulWidget {
  final Widget child;
  final bool adminOnly;
  const AccountGuard({super.key, required this.child, this.adminOnly = false});
  @override
  State<AccountGuard> createState() => _AccountGuardState();
}

class _AccountGuardState extends State<AccountGuard> {
  StreamSubscription<AuthState>? _subscription;
  late Future<bool> _allowed;
  late final AuthRoutingPolicy _authRoutingPolicy;
  @override
  void initState() {
    super.initState();
    _authRoutingPolicy = AuthRoutingPolicy(Supabase.instance.client.auth.currentUser?.id);
    _allowed = _check();
    _subscription = Supabase.instance.client.auth.onAuthStateChange.listen(
      (event) {
        if (!mounted || !_authRoutingPolicy.shouldRecheck(event)) {
          return;
        }
        setState(() => _allowed = _check());
      },
      onError: (Object error, StackTrace stack) {
        if (mounted && Supabase.instance.client.auth.currentSession == null) {
          setState(() => _allowed = Future.value(false));
        }
      },
    );
  }

  Future<bool> _check() async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) return false;
    if (!widget.adminOnly) return true;
    final profile = await AccountProfileService.instance.load(user.id);
    return client.auth.currentUser?.id == user.id &&
        profile?['role'] == 'admin';
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: _allowed,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (snapshot.hasError) {
        return ConnectionErrorScreen(
          errorType: ErrorType.backend,
          retryEnabled: AccountProfileService.isTransient(snapshot.error!),
          errorMessage: AccountProfileService.isSchemaError(snapshot.error!)
              ? 'Please update Waydrop or contact support to verify this account.'
              : 'Unable to verify account access. Please try again when the service is available.',
          onRetry: () => setState(() => _allowed = _check()),
        );
      }
      if (snapshot.data != true) {
        if (Supabase.instance.client.auth.currentUser == null) {
          return const LoginScreen();
        }
        return const Scaffold(body: Center(child: Text('Access denied')));
      }
      return widget.child;
    },
  );
}
