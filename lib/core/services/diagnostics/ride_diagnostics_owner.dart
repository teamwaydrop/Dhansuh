import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'ride_diagnostics.dart';

/// Local auth-event observer only; never creates a Supabase channel or request.
class RideDiagnosticOwner {
  RideDiagnosticOwner({
    required this.isAlive,
    required this.currentIdentity,
    required Stream<String?> identities,
    this.surface,
    RideDiagnostics? recorder,
  }) : recorder = recorder ?? RideDiagnostics.instance {
    _identity = currentIdentity();
    if (this.recorder.enabled) {
      _subscription = identities.listen((value) {
        if (value != _identity) {
          _identity = value;
          _generation++;
          _retired = true;
          _pendingFrames.clear();
        }
      });
    }
  }
  factory RideDiagnosticOwner.widget(
    bool Function() isAlive, {
    RideSurface? surface,
  }) {
    final auth = Supabase.instance.client.auth;
    return RideDiagnosticOwner(
      isAlive: isAlive,
      surface: surface,
      currentIdentity: () => auth.currentUser?.id,
      identities: auth.onAuthStateChange.map((e) => e.session?.user.id),
    );
  }
  final RideDiagnostics recorder;
  final RideSurface? surface;
  final bool Function() isAlive;
  final String? Function() currentIdentity;
  StreamSubscription<String?>? _subscription;
  String? _identity;
  int _generation = 0;
  bool _disposed = false;
  bool _retired = false;
  final Map<String, String> _rendered = {};
  // One callback per owner; retain only the latest observation per ride, at most 64.
  final Map<String, void Function()> _pendingFrames = {};
  bool _frameScheduled = false;

  @visibleForTesting
  int get pendingFrameObservations => _pendingFrames.length;

  @visibleForTesting
  bool get hasScheduledFrameObservation => _frameScheduled;
  RideAttempt begin({
    String? ride,
    String? correlation,
    bool plan = false,
    RideEndpoint? endpoint,
    Object? status,
    bool action = true,
  }) {
    final generation = _generation;
    final identity = currentIdentity();
    return recorder.begin(
      rawRide: ride,
      rawCorrelation: correlation,
      plan: plan,
      endpoint: endpoint,
      status: diagnosticStatus(status),
      surface: surface,
      action: action,
      isCurrent: () =>
          !_disposed &&
          !_retired &&
          isAlive() &&
          identity != null &&
          generation == _generation &&
          currentIdentity() == identity,
    );
  }

  Future<T> api<T>(
    RideEndpoint endpoint,
    String? ride,
    Future<T> Function() invoke, {
    Object? status,
    bool plan = false,
    bool action = true,
    RideAttempt? attempt,
  }) =>
      (attempt?.forEndpoint(endpoint) ??
              begin(
                ride: ride,
                endpoint: endpoint,
                status: status,
                plan: plan,
                action: action,
              ))
          .observe(
            invoke,
            evidence: (value) {
              final data = value is FunctionResponse ? value.data : value;
              return data is Map ? data : null;
            },
            httpStatus: (value) =>
                value is FunctionResponse ? value.status : null,
            errorStatus: (error) =>
                error is FunctionException ? error.status : null,
          );

  /// Existing stream receipt only; never retain the payload or raw identity.
  void receipt(
    Object? ride, {
    Object? status,
    Object? version,
    RideEndpoint? endpoint,
  }) {
    begin(
      ride: ride is String ? ride : null,
      endpoint: endpoint,
      status: status,
      action: false,
    ).event(
      RideEvent.realtimeReceipt,
      version: version is String ? version : null,
    );
  }

  /// Call only from the builder containing this status. Not proof of physical presentation.
  void frame(
    BuildContext context,
    String? ride,
    Object? status,
    bool Function() stillSameStatus,
  ) {
    if (!recorder.enabled ||
        _disposed ||
        _retired ||
        diagnosticStatus(status) == null) {
      return;
    }
    final attempt = begin(ride: ride, status: status, action: false);
    final label = attempt.ride;
    if (label == null ||
        _rendered[label] == '$_generation:${diagnosticStatus(status)}') {
      return;
    }
    if (!_pendingFrames.containsKey(label) && _pendingFrames.length >= 64) {
      _pendingFrames.remove(_pendingFrames.keys.first);
    }
    _pendingFrames[label] = () {
      try {
        if (!attempt.isCurrent() ||
            !context.mounted ||
            !stillSameStatus() ||
            ModalRoute.of(context)?.isCurrent == false) {
          return;
        }
        final key = '$_generation:${diagnosticStatus(status)}';
        if (_rendered[label] == key) return;
        if (_rendered.length >= 64) {
          _rendered.remove(_rendered.keys.first);
        }
        _rendered[label] = key;
        attempt.event(RideEvent.rendered);
      } catch (_) {
        /* Optional diagnostic callback cannot affect the UI. */
      }
    };
    if (_frameScheduled) return;
    _frameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _frameScheduled = false;
      final observations = _pendingFrames.values.toList(growable: false);
      _pendingFrames.clear();
      for (final observe in observations) {
        observe();
      }
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _subscription?.cancel().catchError((_) {});
    _rendered.clear();
    _pendingFrames.clear();
  }
}
