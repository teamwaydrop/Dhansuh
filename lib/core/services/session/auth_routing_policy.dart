import 'package:supabase_flutter/supabase_flutter.dart';

/// Routine refreshes keep the current route, but a restored/switched identity
/// must be resolved even when the SDK reports it as tokenRefreshed.
class AuthRoutingPolicy {
  String? _userId;
  AuthRoutingPolicy(this._userId);

  bool shouldRecheck(AuthState state) {
    final next = state.session?.user.id;
    final changed = next != _userId;
    _userId = next;
    if (state.event == AuthChangeEvent.initialSession ||
        state.event == AuthChangeEvent.signedIn ||
        state.event == AuthChangeEvent.tokenRefreshed ||
        state.event == AuthChangeEvent.signedOut) {
      return changed;
    }
    return true;
  }
}
