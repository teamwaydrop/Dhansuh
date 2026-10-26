import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Widget-owned operation revisions; account changes retire even A -> B -> A.
/// Token refresh for the same account does not retire a valid operation.
class IdentityOperationScope {
  IdentityOperationScope({required this.currentUserId, required this.isAlive,
      required Stream<String?> identities, void Function()? onIdentityChanged}) {
    _identity = currentUserId();
    _subscription = identities.listen((identity) {
      if (identity != _identity) {
        _identity = identity; _revision++;
        if (!_disposed && isAlive()) onIdentityChanged?.call();
      }
    });
  }
  factory IdentityOperationScope.forWidget(bool Function() isAlive, {void Function()? onIdentityChanged}) {
    final auth = Supabase.instance.client.auth;
    return IdentityOperationScope(currentUserId: () => auth.currentUser?.id,
        isAlive: isAlive, identities: auth.onAuthStateChange.map((event) => event.session?.user.id),
        onIdentityChanged: onIdentityChanged);
  }
  final String? Function() currentUserId;
  final bool Function() isAlive;
  late final StreamSubscription<String?> _subscription;
  String? _identity;
  int _revision = 0;
  bool _disposed = false;
  IdentityOperation begin() => IdentityOperation._(this, ++_revision, currentUserId());
  void dispose() { _disposed = true; _revision++; _subscription.cancel(); }
}

class IdentityOperation {
  IdentityOperation._(this._scope, this._revision, this.userId);
  final IdentityOperationScope _scope;
  final int _revision;
  final String? userId;
  bool get isCurrent => userId != null && !_scope._disposed && _scope.isAlive() &&
      _scope._revision == _revision && _scope.currentUserId() == userId;
  void requireCurrent() {
    if (!isCurrent) throw StateError('Mode switch operation no longer current');
  }
}
