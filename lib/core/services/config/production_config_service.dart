import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/cache/cache_service.dart';

/// Phase 1 production control system -- app version control, maintenance mode, and remote feature
/// flags. Single source of truth for `public.production_config`
/// (20260901000034_production_config.sql).
///
/// AUDIT NOTE: a previous `feature_flags` table + FeatureFlagService existed and was deliberately
/// dropped/disabled (see the migration's own comment header and
/// lib/core/services/session/feature_flag_service.dart, which is now dead code -- init() never
/// fetches, isEnabled() is called from nowhere in lib/). This service replaces that concept; it does
/// not extend or resurrect the old table.
///
/// FETCH POLICY (documented per Phase 1 requirement to decide staleness risk explicitly):
/// - Exactly one network fetch per app cold start, awaited by AppStartScreen before it decides which
///   screen to show (maintenance_mode/force_update must be known before login is even offered).
/// - A single in-flight fetch is shared by any concurrent callers (`_inFlight`) -- no duplicate
///   requests, no request storms.
/// - On success, the row is cached in memory AND persisted via CacheService (Hive, encrypted,
///   already used for other last-known-good data in this app) so a later cold start that has no
///   network can still use the last real value instead of only hardcoded defaults.
/// - On failure (timeout/offline/error) with no usable cache: fails OPEN -- maintenance_mode=false,
///   force_update=false, every feature flag=true. Bricking a brand-new install's very first launch
///   because of one network hiccup is a worse outcome than rarely missing a maintenance window; the
///   server-side enforcement in create-order/create-payment/send-push-notification is the actual
///   safety net for the operations that truly must not proceed, independent of what the client
///   believes.
/// - On failure WITH a usable cache (a previous successful fetch this install), the cached value is
///   used as-is, including if it says maintenance_mode=true -- a stale "still in maintenance" is the
///   safe stale direction (it self-corrects the moment the next successful fetch happens); a stale
///   "not in maintenance" would be the risky direction, but is bounded by fetching fresh on every
///   single cold start (never skipped, unlike a mid-session TTL cache) so staleness is capped at one
///   app restart.
/// - Never refetched again during the same session automatically -- `refresh(force: true)` exists
///   for a future explicit pull-to-refresh but nothing calls it yet, matching "avoid fetch loops" and
///   "no request on every widget rebuild".
class ProductionConfigService {
  static final ProductionConfigService instance = ProductionConfigService._internal();
  ProductionConfigService._internal();

  static const String _cacheKey = 'production_config_v1';
  static const Duration _fetchTimeout = Duration(seconds: 5);

  // Safe, non-disruptive defaults -- used only when there is no fetched value AND no cache at all
  // (e.g. brand-new install, first launch, offline). Every flag defaults to enabled; nothing is
  // blocked.
  static final Map<String, dynamic> _hardcodedDefaults = {
    'minimum_android_version': '0.0.0',
    'latest_android_version': '0.0.0',
    'force_update': false,
    'update_message': 'A new version of WayDrop is available. Please update to continue.',
    'maintenance_mode': false,
    'maintenance_message': 'WayDrop is currently undergoing scheduled maintenance. Please check back shortly.',
    'local_rides_enabled': true,
    'ride_booking_enabled': true,
    'intercity_enabled': true,
    'parcel_enabled': true,
    'payments_enabled': true,
    'subscriptions_enabled': true,
    'notifications_enabled': true,
  };

  Map<String, dynamic> _config = Map<String, dynamic>.from(_hardcodedDefaults);
  bool _hasFetchedThisSession = false;
  Future<void>? _inFlight;
  String? _appVersion;

  /// Single initialization/fetch path. Safe to call more than once (e.g. defensive callers) --
  /// concurrent calls share one in-flight fetch, and a call after the first successful fetch this
  /// session is a no-op unless `force: true`.
  Future<void> init({bool force = false}) async {
    if (_inFlight != null) {
      return _inFlight;
    }
    if (_hasFetchedThisSession && !force) {
      return;
    }
    _inFlight = _fetch();
    try {
      await _inFlight;
    } finally {
      _inFlight = null;
    }
  }

  /// Explicit alias for a future manual refresh (e.g. pull-to-refresh) -- not wired into anything
  /// automatic in Phase 1.
  Future<void> refresh({bool force = true}) => init(force: force);

  Future<void> _fetch() async {
    try {
      // Phase 2 audit finding: PackageInfo.fromPlatform() is a platform-channel call with no
      // built-in bound -- in the extremely unlikely case it never resolves, this await would
      // otherwise stall the entire fetch (and therefore the splash screen) indefinitely, since it
      // runs before the already-timeout-bounded Supabase call below. Same defense-in-depth
      // treatment as that call, not because this has ever been observed to hang in practice.
      final packageInfo = await PackageInfo.fromPlatform().timeout(const Duration(seconds: 3));
      _appVersion = packageInfo.version;
    } catch (e) {
      debugPrint('ProductionConfigService: PackageInfo.fromPlatform() failed: $e');
    }

    // Always try the persisted last-known-good first so `_config` is never worse than a previous
    // successful fetch while the network call below is in flight.
    final cached = CacheService.instance.get(_cacheKey);
    if (cached is Map) {
      _config = _mergeWithDefaults(Map<String, dynamic>.from(cached));
    }

    try {
      final row = await Supabase.instance.client
          .from('production_config')
          .select()
          .eq('is_active', true)
          .maybeSingle()
          .timeout(_fetchTimeout);

      if (row != null) {
        _config = _mergeWithDefaults(Map<String, dynamic>.from(row));
        _hasFetchedThisSession = true;
        unawaited(CacheService.instance.put(_cacheKey, _config));
        debugPrint('ProductionConfigService: fetched fresh production_config.');
      } else {
        debugPrint('ProductionConfigService: no active production_config row found -- using cache/defaults.');
      }
    } catch (e) {
      debugPrint('ProductionConfigService: fetch failed, using cache/defaults: $e');
      // _config already holds either the persisted cache (set above) or _hardcodedDefaults
      // (the initial value) -- nothing further to do; this is the documented fail-open path.
    }
  }

  Map<String, dynamic> _mergeWithDefaults(Map<String, dynamic> fetched) {
    final merged = Map<String, dynamic>.from(_hardcodedDefaults);
    fetched.forEach((key, value) {
      if (value != null) merged[key] = value;
    });
    return merged;
  }

  // ---------------------------------------------------------------
  // Typed getters -- every one handles a missing/malformed value safely by falling back to the
  // hardcoded default for that key rather than throwing.
  // ---------------------------------------------------------------

  String get minimumAndroidVersion => _stringValue('minimum_android_version');
  String get latestAndroidVersion => _stringValue('latest_android_version');
  bool get forceUpdate => _boolValue('force_update');
  String get updateMessage => _stringValue('update_message');
  bool get maintenanceMode => _boolValue('maintenance_mode');
  String get maintenanceMessage => _stringValue('maintenance_message');

  /// The installed app's version (PackageInfo `version`, e.g. "1.0.0" -- NOT the build number).
  /// Null until the first `init()` completes (or if PackageInfo itself failed) -- callers must treat
  /// null as "unknown, do not block".
  String? get appVersion => _appVersion;

  bool getFlag(String key, {bool defaultValue = true}) => _boolValue(key, defaultValue: defaultValue);

  String _stringValue(String key) {
    final value = _config[key] ?? _hardcodedDefaults[key];
    if (value is String && value.isNotEmpty) return value;
    return _hardcodedDefaults[key] as String;
  }

  bool _boolValue(String key, {bool? defaultValue}) {
    final fallback = defaultValue ?? (_hardcodedDefaults[key] as bool? ?? true);
    final value = _config[key];
    if (value is bool) return value;
    return fallback;
  }

  /// Version comparison: returns true if [current] is strictly lower than [required].
  /// Dot-separated integer segments only (e.g. "1.2.3"), ignoring any "+build" suffix. Malformed or
  /// missing input on EITHER side returns false (fail open -- never blocks on a parse failure; see
  /// class doc for the staleness/failure policy this matches).
  static bool isVersionLower(String? current, String? required) {
    if (current == null || current.isEmpty || required == null || required.isEmpty) {
      return false;
    }
    try {
      final currentParts = current.split('+').first.trim().split('.').map((e) => int.parse(e)).toList();
      final requiredParts = required.split('+').first.trim().split('.').map((e) => int.parse(e)).toList();
      final maxLength = currentParts.length > requiredParts.length ? currentParts.length : requiredParts.length;
      for (int i = 0; i < maxLength; i++) {
        final c = i < currentParts.length ? currentParts[i] : 0;
        final r = i < requiredParts.length ? requiredParts[i] : 0;
        if (c > r) return false;
        if (c < r) return true;
      }
      return false;
    } catch (e) {
      debugPrint('ProductionConfigService.isVersionLower: parse failed (current=$current, required=$required): $e');
      return false;
    }
  }
}
