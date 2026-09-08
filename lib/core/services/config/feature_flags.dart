import 'package:waydrop/core/services/config/production_config_service.dart';

/// Central, typed access point for the Phase 1 remote feature flags. Every flag reads through
/// ProductionConfigService's already-fetched/cached config -- calling one of these getters never
/// triggers a network request itself (see ProductionConfigService's single-fetch-path doc comment).
///
/// Each flag defaults to `true` (enabled) when the config is unavailable, missing that column, or
/// hasn't been fetched yet -- consistent with the fail-open policy documented on
/// ProductionConfigService. These are UI-visibility switches only; the operations that must not
/// proceed even if a caller bypasses the UI are additionally enforced server-side (create-order,
/// create-payment, send-push-notification -- see the conversation report for which flag is enforced
/// where).
class FeatureFlags {
  FeatureFlags._();

  static ProductionConfigService get _config => ProductionConfigService.instance;

  /// Master switch for the whole local-rides vertical (UI visibility, e.g. the Home "Ride" tile).
  static bool get localRidesEnabled => _config.getFlag('local_rides_enabled');

  /// Finer-grained switch for the ride booking action itself (e.g. "new bookings paused"), checked
  /// together with [localRidesEnabled] both client-side and server-side (create-order).
  static bool get rideBookingEnabled => _config.getFlag('ride_booking_enabled');

  /// Covers both intercity_ride and intercity_parcel -- Phase 1 does not split intercity by type.
  static bool get intercityEnabled => _config.getFlag('intercity_enabled');

  /// Covers local_parcel only (intercity_parcel is governed by [intercityEnabled]).
  static bool get parcelEnabled => _config.getFlag('parcel_enabled');

  /// Master kill switch for all payment creation (order fares, subscriptions, tax due, COD
  /// settlement) -- enforced server-side in create-payment.
  static bool get paymentsEnabled => _config.getFlag('payments_enabled');

  /// Additionally required (alongside [paymentsEnabled]) for a subscription purchase specifically.
  static bool get subscriptionsEnabled => _config.getFlag('subscriptions_enabled');

  /// Outbound push/FCM delivery kill switch -- does not affect the in-app Notifications inbox
  /// history, only future push alerts (see send-push-notification's enforcement comment).
  static bool get notificationsEnabled => _config.getFlag('notifications_enabled');
}
