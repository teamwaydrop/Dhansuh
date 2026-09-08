// Regression guard for the Phase 1 production control system: app version control, maintenance
// mode, remote feature flags, server-side enforcement, and cached remote config.
//
// AUDIT CONTEXT (read-only audit performed before any implementation -- see conversation report):
// a `public.feature_flags` table + Flutter FeatureFlagService existed once and was deliberately
// dropped/disabled (20260616000005_feature_flags.sql created it, 20260702000000_drop_feature_flags.sql
// dropped it, "remote feature flags are no longer used"; feature_flag_service.dart's init()/fetchFlags()
// are literal no-ops today and isEnabled() is called from nowhere in lib/). This migration/service set
// is a new, minimal Phase 1 design -- it does not resurrect or duplicate that old table, and it does
// not duplicate subscription_plans (pricing stays there; see migration 33).
//
// ProductionConfigService.isVersionLower is public specifically so this file can exercise the real
// comparison logic directly (no mirroring needed, unlike private/library-scoped logic elsewhere in
// this test suite). Everything that requires a live Supabase/network connection at runtime (the
// actual fetch, RLS enforcement) is instead verified structurally against the migration/service
// source, matching this repo's established regression-test convention.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/core/services/config/production_config_service.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read('supabase/migrations/20260901000034_production_config.sql');
  final configService = _read('lib/core/services/config/production_config_service.dart');
  final featureFlags = _read('lib/core/services/config/feature_flags.dart');
  final appStart = _read('lib/app_start_screen.dart');
  final homeTab = _read('lib/features/user/home/home_tab.dart');
  final maintenanceScreen = _read('lib/shared/screens/maintenance_screen.dart');
  final updateRequiredScreen = _read('lib/shared/screens/update_required_screen.dart');
  final sharedCache = _read('supabase/functions/_shared/production_config_cache.ts');
  final createOrder = _read('supabase/functions/create-order/index.ts');
  final createPayment = _read('supabase/functions/create-payment/index.ts');
  final sendPush = _read('supabase/functions/send-push-notification/index.ts');
  final acceptOrder = _read('supabase/functions/accept-order/index.ts');
  final acceptIntercityRequest = _read('supabase/functions/accept-intercity-request/index.ts');
  final oldFeatureFlagsDrop = _read('supabase/migrations/20260702000000_drop_feature_flags.sql');
  final oldFeatureFlagService = _read('lib/core/services/session/feature_flag_service.dart');
  final pubspec = _read('pubspec.yaml');

  group('0. Audit: no duplicate/competing config system was created', () {
    test('the old feature_flags table was already dropped, and this migration does not '
        'resurrect it', () {
      expect(oldFeatureFlagsDrop.contains('DROP TABLE IF EXISTS public.feature_flags'), isTrue);
      expect(migration.contains('CREATE TABLE IF NOT EXISTS public.feature_flags'), isFalse);
      expect(migration.contains('INSERT INTO public.feature_flags'), isFalse);
    });

    test('the old FeatureFlagService remains dead code (no remote fetch), untouched by this '
        'task -- confirmed still a no-op, not deleted (out of scope) but also not extended', () {
      expect(oldFeatureFlagService.contains('Disabled remote fetching, using hardcoded defaults'), isTrue);
      expect(oldFeatureFlagService.contains('No-op - remote feature flags are disabled'), isTrue);
    });

    test('subscription pricing (subscription_plans) is not touched or duplicated by this '
        'migration -- pricing stays exclusively in subscription_plans (migration 33)', () {
      expect(migration.contains('ALTER TABLE public.subscription_plans'), isFalse);
      expect(migration.contains('INSERT INTO public.subscription_plans'), isFalse);
      expect(migration.contains('ALTER TABLE public.dispatch_config'), isFalse);
      expect(migration.contains('ALTER TABLE public.pricing_config'), isFalse);
    });

    test('package_info_plus was added as a real dependency (no existing app-version-reading '
        'mechanism was found in the audit -- device_info_helper.dart hardcoded "1.0.0")', () {
      expect(pubspec.contains('package_info_plus:'), isTrue);
    });
  });

  group('1. Migration: table shape, safe defaults, idempotency', () {
    test('all required app-version-control columns exist with safe (non-disruptive) defaults', () {
      expect(migration.contains("minimum_android_version text NOT NULL DEFAULT '1.0.0'"), isTrue);
      expect(migration.contains("latest_android_version text NOT NULL DEFAULT '1.0.0'"), isTrue);
      expect(migration.contains('force_update boolean NOT NULL DEFAULT false'), isTrue);
      expect(migration.contains('update_message text NOT NULL DEFAULT'), isTrue);
    });

    test('maintenance mode columns exist, defaulting OFF', () {
      expect(migration.contains('maintenance_mode boolean NOT NULL DEFAULT false'), isTrue);
      expect(migration.contains('maintenance_message text NOT NULL DEFAULT'), isTrue);
    });

    test('all 7 Phase 1 feature flags exist, defaulting to true (enabled) -- deploying this '
        'migration must not disable anything currently working', () {
      for (final flag in [
        'local_rides_enabled',
        'ride_booking_enabled',
        'intercity_enabled',
        'parcel_enabled',
        'payments_enabled',
        'subscriptions_enabled',
        'notifications_enabled',
      ]) {
        expect(migration.contains('$flag boolean NOT NULL DEFAULT true'), isTrue, reason: '$flag must default true');
      }
    });

    test('an extra_flags jsonb escape hatch exists for future ad-hoc values without a new '
        'migration', () {
      expect(migration.contains("extra_flags jsonb NOT NULL DEFAULT '{}'::jsonb"), isTrue);
    });

    test('at most one active row is enforced via a partial unique index (mirrors migration '
        "33's uq_subscription_plans_active_vehicle_type pattern)", () {
      expect(
        migration.contains('CREATE UNIQUE INDEX IF NOT EXISTS uq_production_config_active'),
        isTrue,
      );
      expect(migration.contains('WHERE (is_active)'), isTrue);
    });

    test('the seed row uses ON CONFLICT DO NOTHING -- safe to re-run, never overwrites an '
        'admin-edited row', () {
      expect(migration.contains("ON CONFLICT (config_code) DO NOTHING"), isTrue);
    });

    test('reuses the existing generic updated_at trigger function instead of writing a new '
        'one', () {
      expect(migration.contains('EXECUTE FUNCTION public.update_updated_at_column();'), isTrue);
      expect(migration.contains('CREATE OR REPLACE FUNCTION public.update_updated_at_column'), isFalse);
    });

    test('no Cashfree/service-role/secret credential COLUMN is defined on this table (the '
        "migration's own comments legitimately discuss why secrets don't belong here -- this "
        'checks the actual schema, not the prose)', () {
      expect(migration.contains('cashfree_secret'), isFalse);
      expect(migration.contains('service_role_key text'), isFalse);
      expect(migration.contains('secret_key text'), isFalse);
      expect(migration.contains('CASHFREE_SECRET_KEY'), isFalse);
    });
  });

  group('2. Security / RLS: read-only for normal users, no client write path', () {
    test('RLS is enabled', () {
      expect(migration.contains('ALTER TABLE public.production_config ENABLE ROW LEVEL SECURITY'), isTrue);
    });

    test('exactly one SELECT policy exists, scoped to is_active rows, for anon AND '
        'authenticated (maintenance/version must be checkable before login)', () {
      expect(migration.contains('FOR SELECT'), isTrue);
      expect(migration.contains('TO anon, authenticated'), isTrue);
      expect(migration.contains('USING (is_active = true)'), isTrue);
    });

    test('no INSERT/UPDATE/DELETE policy exists for anon/authenticated -- RLS default-deny '
        'means normal users can never modify this table via the client', () {
      expect(migration.contains('FOR INSERT'), isFalse);
      expect(migration.contains('FOR UPDATE'), isFalse);
      expect(migration.contains('FOR DELETE'), isFalse);
      expect(migration.contains('FOR ALL'), isFalse);
    });

    test('only SELECT is granted to anon/authenticated; service_role retains full access '
        '(the only intended write path)', () {
      expect(migration.contains('GRANT SELECT ON public.production_config TO anon, authenticated'), isTrue);
      expect(migration.contains('GRANT ALL ON public.production_config TO service_role'), isTrue);
    });
  });

  group('3. App version control: isVersionLower comparison (real logic, not mirrored)', () {
    test('current < minimum -> blocked (CASE A)', () {
      expect(ProductionConfigService.isVersionLower('1.0.0', '1.1.0'), isTrue);
    });

    test('current == minimum -> NOT blocked (>= minimum satisfies the floor)', () {
      expect(ProductionConfigService.isVersionLower('1.1.0', '1.1.0'), isFalse);
    });

    test('current < latest but >= minimum -> not "lower than minimum" (CASE B path), while '
        'still lower than latest (recommendation path)', () {
      expect(ProductionConfigService.isVersionLower('1.1.0', '1.0.0'), isFalse); // >= minimum 1.0.0
      expect(ProductionConfigService.isVersionLower('1.1.0', '1.2.0'), isTrue); // < latest 1.2.0
    });

    test('current >= latest -> no update message at all (CASE C)', () {
      expect(ProductionConfigService.isVersionLower('1.2.0', '1.2.0'), isFalse);
      expect(ProductionConfigService.isVersionLower('1.3.0', '1.2.0'), isFalse);
    });

    test('build-number suffix ("+51") is ignored -- comparison is on the version string only', () {
      expect(ProductionConfigService.isVersionLower('1.0.0+51', '1.0.0+999'), isFalse);
    });

    test('missing version config on either side fails OPEN (never blocks)', () {
      expect(ProductionConfigService.isVersionLower(null, '1.1.0'), isFalse);
      expect(ProductionConfigService.isVersionLower('1.0.0', null), isFalse);
      expect(ProductionConfigService.isVersionLower('', '1.1.0'), isFalse);
    });

    test('malformed version strings fail OPEN (never blocks, never throws)', () {
      expect(() => ProductionConfigService.isVersionLower('not-a-version', '1.1.0'), returnsNormally);
      expect(ProductionConfigService.isVersionLower('not-a-version', '1.1.0'), isFalse);
      expect(ProductionConfigService.isVersionLower('1.0.0', 'also-bad'), isFalse);
    });

    test('differing segment counts are compared correctly (e.g. "1.2" vs "1.2.1")', () {
      expect(ProductionConfigService.isVersionLower('1.2', '1.2.1'), isTrue);
      expect(ProductionConfigService.isVersionLower('1.2.0', '1.2'), isFalse);
    });
  });

  group('4. Maintenance mode: wired into AppStartScreen before the login gate', () {
    test('the maintenance_mode check runs before the `user == null` -> LoginScreen branch, so '
        'it blocks even a logged-out user', () {
      final maintenanceIdx = appStart.indexOf('if (config.maintenanceMode) {');
      final loginIdx = appStart.indexOf('await changeScreen(const LoginScreen(), startTime);');
      expect(maintenanceIdx, greaterThan(-1));
      expect(loginIdx, greaterThan(-1));
      expect(maintenanceIdx, lessThan(loginIdx));
    });

    test('MaintenanceScreen is shown with the config-provided message, and offers a retry that '
        're-runs checkUserFlow (so maintenance ending is picked up without reinstalling)', () {
      expect(appStart.contains('MaintenanceScreen(message: config.maintenanceMessage, onRetry: () => checkUserFlow())'), isTrue);
    });

    test('MaintenanceScreen renders the message with no truncation and a "Check Again" retry '
        'action', () {
      expect(maintenanceScreen.contains('required this.message'), isTrue);
      expect(maintenanceScreen.contains('required this.onRetry'), isTrue);
      expect(maintenanceScreen.contains('Check Again'), isTrue);
      expect(maintenanceScreen.contains('Text(\n                message,'), isTrue);
    });

    test('does not crash or infinite-spin -- MaintenanceScreen is a real terminal Scaffold, '
        'not a loading state', () {
      expect(maintenanceScreen.contains('CircularProgressIndicator'), isFalse);
    });
  });

  group('5. App version gate: CASE A/B/C/D behavior wired into AppStartScreen', () {
    test('CASE A/D: force_update OR current < minimum blocks with UpdateRequiredScreen, before '
        'the profile/rider data fetch', () {
      expect(
        appStart.contains(
          'final blockedByVersion = config.forceUpdate ||\n'
          '          ProductionConfigService.isVersionLower(installedVersion, config.minimumAndroidVersion);',
        ),
        isTrue,
      );
      final blockIdx = appStart.indexOf('if (blockedByVersion) {');
      final profileQueryIdx = appStart.indexOf("from('users')");
      expect(blockIdx, greaterThan(-1));
      expect(profileQueryIdx, greaterThan(-1));
      expect(blockIdx, lessThan(profileQueryIdx));
    });

    test('UpdateRequiredScreen has no retry/continue action -- CASE A/D must stay blocked '
        'until the app is actually updated and relaunched', () {
      expect(updateRequiredScreen.contains('onRetry'), isFalse);
      expect(updateRequiredScreen.contains('ElevatedButton'), isFalse);
    });

    test('UpdateRequiredScreen does not fabricate a Play Store link or fake download '
        'mechanism', () {
      expect(updateRequiredScreen.contains('url_launcher'), isFalse);
      expect(updateRequiredScreen.contains('launchUrl'), isFalse);
      expect(updateRequiredScreen.contains('play.google.com'), isFalse);
    });

    test('CASE B: a non-blocking recommendation is shown at most once per session, only after '
        'reaching a real app screen (not during onboarding/login)', () {
      expect(appStart.contains('bool _updateRecommendationShown = false;'), isTrue);
      expect(appStart.contains('if (_updateRecommendationShown) return;'), isTrue);
      expect(appStart.contains('_updateRecommendationShown = true;'), isTrue);
      // Called after both real destinations, not after LoginScreen/ProfileSetupScreen/PermissionsScreen.
      expect(
        appStart.contains(
          'await changeScreen(const RiderMainNavigationScreen(), startTime);\n'
          '        unawaited(NotificationService().processPendingNotificationQueue());\n'
          '        _maybeShowUpdateRecommendation(config, installedVersion);',
        ),
        isTrue,
      );
      expect(
        appStart.contains(
          'await changeScreen(const MainNavigationScreen(), startTime);\n'
          '        unawaited(NotificationService().processPendingNotificationQueue());\n'
          '        _maybeShowUpdateRecommendation(config, installedVersion);',
        ),
        isTrue,
      );
    });

    test('CASE B uses the existing showAppSnackBar mechanism (SnackBarType.info), not a new '
        'banner widget', () {
      expect(appStart.contains('showAppSnackBar(context, config.updateMessage, type: SnackBarType.info);'), isTrue);
    });

    test('CASE C (current >= latest) shows nothing: _maybeShowUpdateRecommendation returns '
        'early when isVersionLower(current, latest) is false', () {
      expect(
        appStart.contains(
          'if (!ProductionConfigService.isVersionLower(installedVersion, config.latestAndroidVersion)) return;',
        ),
        isTrue,
      );
    });
  });

  group('6. Feature flags: central typed access layer', () {
    test('every Phase 1 flag has a typed getter mapping to its exact production_config column', () {
      final expected = {
        'localRidesEnabled': 'local_rides_enabled',
        'rideBookingEnabled': 'ride_booking_enabled',
        'intercityEnabled': 'intercity_enabled',
        'parcelEnabled': 'parcel_enabled',
        'paymentsEnabled': 'payments_enabled',
        'subscriptionsEnabled': 'subscriptions_enabled',
        'notificationsEnabled': 'notifications_enabled',
      };
      expected.forEach((getter, column) {
        expect(featureFlags.contains("static bool get $getter => _config.getFlag('$column')"), isTrue, reason: '$getter -> $column');
      });
    });

    test('FeatureFlags never triggers a network request itself -- it only reads through '
        'ProductionConfigService\'s already-fetched config', () {
      expect(featureFlags.contains('Supabase'), isFalse);
      expect(featureFlags.contains('.select('), isFalse);
    });
  });

  group('7. ProductionConfigService: single fetch path, no duplicate requests, safe fallback', () {
    test('concurrent init() calls share one in-flight fetch (no duplicate requests)', () {
      expect(configService.contains('if (_inFlight != null) {\n      return _inFlight;\n    }'), isTrue);
    });

    test('init() is a no-op after the first successful fetch this session unless forced -- no '
        're-fetch on every checkUserFlow() re-run / widget rebuild', () {
      expect(configService.contains('if (_hasFetchedThisSession && !force) {\n      return;\n    }'), isTrue);
    });

    test('the fetch is bounded by an explicit timeout (never hangs the splash screen forever)', () {
      expect(configService.contains('.timeout(_fetchTimeout)'), isTrue);
      expect(configService.contains('static const Duration _fetchTimeout = Duration(seconds: 5)'), isTrue);
    });

    test('a fetch failure falls back to the persisted last-known-good cache via CacheService, '
        'never crashes', () {
      expect(configService.contains('CacheService.instance.get(_cacheKey)'), isTrue);
      expect(configService.contains('CacheService.instance.put(_cacheKey, _config)'), isTrue);
      expect(configService.contains('} catch (e) {\n      debugPrint(\'ProductionConfigService: fetch failed, using cache/defaults: \$e\');'), isTrue);
    });

    test('with no cache at all (brand-new install, offline), every flag defaults to enabled '
        'and maintenance/force_update default to off -- fails open, never bricks first launch', () {
      expect(configService.contains("'maintenance_mode': false"), isTrue);
      expect(configService.contains("'force_update': false"), isTrue);
      for (final flag in [
        'local_rides_enabled',
        'ride_booking_enabled',
        'intercity_enabled',
        'parcel_enabled',
        'payments_enabled',
        'subscriptions_enabled',
        'notifications_enabled',
      ]) {
        expect(configService.contains("'$flag': true"), isTrue, reason: '$flag must default true');
      }
    });

    test('a missing/malformed column value falls back to the hardcoded default rather than '
        'throwing (typed getters guard every read)', () {
      expect(configService.contains('bool _boolValue(String key, {bool? defaultValue}) {'), isTrue);
      expect(configService.contains('if (value is bool) return value;'), isTrue);
      expect(configService.contains('String _stringValue(String key) {'), isTrue);
      expect(configService.contains('if (value is String && value.isNotEmpty) return value;'), isTrue);
    });
  });

  group('8. Home screen UI-level feature-flag enforcement (critical entry points only)', () {
    test('Ride tile is gated by rideBookingEnabled AND localRidesEnabled', () {
      expect(
        homeTab.contains('isDisabled: !FeatureFlags.rideBookingEnabled || !FeatureFlags.localRidesEnabled,'),
        isTrue,
      );
    });

    test('Parcel tile is gated by parcelEnabled', () {
      expect(homeTab.contains('isDisabled: !FeatureFlags.parcelEnabled,'), isTrue);
    });

    test('Intercity tile is gated by intercityEnabled', () {
      expect(homeTab.contains('isDisabled: !FeatureFlags.intercityEnabled,'), isTrue);
    });

    test('the existing location-serviceability disabled behavior (separate reason, separate '
        'wording) is unchanged for tiles that are not feature-flag-disabled', () {
      expect(homeTab.contains('if (!_isLocationServiceable) {\n                                      return;'), isTrue);
    });

    test('a disabled tile still uses the existing greyed-out isDisabled visual treatment -- no '
        'new disabled-state UI was invented', () {
      final anchor = homeTab.indexOf('Widget _buildServiceBubble({');
      final end = homeTab.indexOf('\n  Widget _buildRecentRideCard(', anchor);
      expect(anchor, greaterThan(-1));
      expect(end, greaterThan(anchor));
      final block = homeTab.substring(anchor, end);
      expect(block.contains('ColorFilter.mode('), isTrue);
      expect(block.contains('Colors.grey'), isTrue);
    });
  });

  group('9. Server-side enforcement (the critical gap a Flutter-only flag cannot close)', () {
    test('create-order enforces ride_booking_enabled/local_rides_enabled for order_type=ride, '
        'parcel_enabled for local_parcel, and intercity_enabled for both intercity types -- the '
        'single central order-creation entry point for every order type', () {
      expect(createOrder.contains('import { getProductionConfig, isFeatureEnabled } from "../_shared/production_config_cache.ts";'), isTrue);
      expect(createOrder.contains('if (order_type === "ride") {'), isTrue);
      expect(createOrder.contains('isFeatureEnabled(productionConfig, "local_rides_enabled")'), isTrue);
      expect(createOrder.contains('isFeatureEnabled(productionConfig, "ride_booking_enabled")'), isTrue);
      expect(createOrder.contains('} else if (order_type === "local_parcel") {'), isTrue);
      expect(createOrder.contains('isFeatureEnabled(productionConfig, "parcel_enabled")'), isTrue);
      expect(createOrder.contains('} else if (order_type === "intercity_ride" || order_type === "intercity_parcel") {'), isTrue);
      expect(createOrder.contains('isFeatureEnabled(productionConfig, "intercity_enabled")'), isTrue);
    });

    test('create-order returns a 503 HttpError (not a silent failure or a generic 500) when a '
        'flag blocks order creation', () {
      expect(createOrder.contains('throw new HttpError(503,'), isTrue);
      expect(createOrder.contains('"FEATURE_DISABLED"'), isTrue);
    });

    test('create-payment enforces payments_enabled for every payment type, and '
        'subscriptions_enabled additionally for payment_for === "subscription" only', () {
      expect(createPayment.contains('import { getProductionConfig, isFeatureEnabled } from "../_shared/production_config_cache.ts";'), isTrue);
      expect(createPayment.contains('isFeatureEnabled(productionConfig, "payments_enabled")'), isTrue);
      expect(
        createPayment.contains(
          'if (payment_for === "subscription" && !isFeatureEnabled(productionConfig, "subscriptions_enabled")) {',
        ),
        isTrue,
      );
    });

    test('send-push-notification enforces notifications_enabled at the single, central '
        'outbound-push delivery point', () {
      expect(sendPush.contains('import { getProductionConfig, isFeatureEnabled } from "../_shared/production_config_cache.ts";'), isTrue);
      expect(sendPush.contains('isFeatureEnabled(productionConfig, "notifications_enabled")'), isTrue);
    });

    test('send-push-notification returns 200 (not an error status) when skipped -- the caller '
        '(deliver_push_notification_http_fnc) is fire-and-forget pg_net and never inspects the '
        'body, so a skip must not be logged as a delivery failure', () {
      final anchor = sendPush.indexOf('if (!isFeatureEnabled(productionConfig, "notifications_enabled")) {');
      final end = sendPush.indexOf('\n    }', anchor);
      expect(anchor, greaterThan(-1));
      expect(end, greaterThan(anchor));
      final block = sendPush.substring(anchor, end);
      expect(block.contains('{ status: 200, headers: corsHeaders }'), isTrue);
      expect(block.contains('skipped: true'), isTrue);
    });

    test('notifications_enabled=false does NOT stop the notifications row insert/in-app inbox '
        '-- documented as push-delivery-only, since the row is written before this Edge '
        'Function is ever called', () {
      expect(
        sendPush.contains('It does NOT, and cannot,\n    // retroactively stop the public.notifications row itself'),
        isTrue,
      );
    });

    test('the flag check runs AFTER the AUTH block completes, not before -- consistent with '
        'every other business-logic check in this function; an unauthenticated caller must '
        'never get a substantive response before being authorized', () {
      final authIdx = sendPush.indexOf('const isTrustedServerCaller');
      final flagCheckIdx = sendPush.indexOf('if (!isFeatureEnabled(productionConfig, "notifications_enabled")) {');
      expect(authIdx, greaterThan(-1));
      expect(flagCheckIdx, greaterThan(authIdx));
    });
  });

  group('10. Cache/egress: shared server-side cache prevents a query-per-request pattern', () {
    test('production_config_cache.ts uses the identical 30s TTL + in-flight-dedupe pattern as '
        'the existing dispatch_config_cache.ts (a proven precedent in this codebase)', () {
      expect(sharedCache.contains('const TTL_MS = 30_000;'), isTrue);
      expect(sharedCache.contains('if (inFlight) {\n    return inFlight;\n  }'), isTrue);
    });

    test('a config fetch failure fails OPEN server-side too -- isFeatureEnabled defaults to '
        'true so a production_config outage can never itself block bookings/payments/'
        'notifications', () {
      expect(sharedCache.contains('defaultValue = true'), isTrue);
      expect(sharedCache.contains('if (!config) return defaultValue;'), isTrue);
    });

    test('no realtime subscription is used for this config -- one lightweight cached fetch per '
        'cold start (client) / per 30s TTL window (server), matching the "prefer one lightweight '
        'fetch with caching" requirement', () {
      expect(configService.contains('.channel('), isFalse);
      expect(configService.contains('.stream('), isFalse);
      expect(sharedCache.contains('.channel('), isFalse);
    });
  });

  group('11. Phase 4: accept-order and accept-intercity-request finalize NEW matches only, '
      'never an already-accepted/in-progress order', () {
    test('accept-order enforces the same order-type -> flag mapping as create-order for the '
        'acceptance moment', () {
      expect(
        acceptOrder.contains(
          'import { getProductionConfig, isFeatureEnabled } from "../_shared/production_config_cache.ts";',
        ),
        isTrue,
      );
      expect(acceptOrder.contains('if (order.order_type === "ride") {'), isTrue);
      expect(acceptOrder.contains('isFeatureEnabled(productionConfig, "local_rides_enabled")'), isTrue);
      expect(acceptOrder.contains('isFeatureEnabled(productionConfig, "ride_booking_enabled")'), isTrue);
      expect(acceptOrder.contains('} else if (order.order_type === "local_parcel") {'), isTrue);
      expect(acceptOrder.contains('isFeatureEnabled(productionConfig, "parcel_enabled")'), isTrue);
      expect(
        acceptOrder.contains(
          '} else if (order.order_type === "intercity_ride" || order.order_type === "intercity_parcel") {',
        ),
        isTrue,
      );
      expect(acceptOrder.contains('isFeatureEnabled(productionConfig, "intercity_enabled")'), isTrue);
    });

    test('accept-order returns 503 (not silent/500) when blocked, and never touches an order '
        'that is not still "searching" -- the gate sits strictly between the idempotency check '
        'and ORDER STATUS VALIDATION', () {
      final idempotencyIdx = acceptOrder.indexOf('idempotent: true,');
      final flagCheckIdx = acceptOrder.indexOf('PHASE 3 PRODUCTION CONTROL');
      final statusValidationIdx = acceptOrder.indexOf('ORDER STATUS VALIDATION');
      expect(idempotencyIdx, greaterThan(-1));
      expect(flagCheckIdx, greaterThan(idempotencyIdx));
      expect(statusValidationIdx, greaterThan(flagCheckIdx));
    });

    test('accept-intercity-request enforces intercity_enabled -- the sole edge function that '
        'finalizes a NEW intercity Travel Together match', () {
      expect(
        acceptIntercityRequest.contains(
          'import { getProductionConfig, isFeatureEnabled } from "../_shared/production_config_cache.ts";',
        ),
        isTrue,
      );
      expect(
        acceptIntercityRequest.contains('isFeatureEnabled(productionConfig, "intercity_enabled")'),
        isTrue,
      );
      expect(acceptIntercityRequest.contains('"FEATURE_DISABLED"'), isTrue);
    });

    test('accept-intercity-request checks the flag AFTER request_id validation and BEFORE '
        'invoking the accept_intercity_request RPC -- the RPC call is the only statement that '
        'can write order_status="accepted", so this can only ever block a genuinely new '
        'acceptance', () {
      final requestIdCheckIdx = acceptIntercityRequest.indexOf('"request_id is required."');
      final flagCheckIdx = acceptIntercityRequest.indexOf('PHASE 4 PRODUCTION CONTROL');
      final rpcCallIdx = acceptIntercityRequest.indexOf('supabase.rpc("accept_intercity_request"');
      expect(requestIdCheckIdx, greaterThan(-1));
      expect(flagCheckIdx, greaterThan(requestIdCheckIdx));
      expect(rpcCallIdx, greaterThan(flagCheckIdx));
    });

    test('a config-fetch failure fails open for both functions, matching every other '
        'production_config enforcement point', () {
      expect(acceptOrder.contains('getProductionConfig(supabase)'), isTrue);
      expect(acceptIntercityRequest.contains('getProductionConfig(supabase)'), isTrue);
    });
  });
}
