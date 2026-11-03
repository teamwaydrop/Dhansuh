# Files changed for the Waydrop fixes

31 October 2026. Lines refer to this working tree.

## Application source

| File | Function/anchor | Line |
|---|---|---:|
| `lib/main.dart` | `Future<void> main()` | 44 |
| `lib/app_start_screen.dart` | `Future<void> checkUserFlow()` | 98 |
| `lib/core/providers/initial_data_provider.dart` | `bool isUsableFor` | 30 |
| `lib/core/services/config/production_config_service.dart` | `Future<void> _fetch()` | 93 |
| `lib/core/services/location/location_cache_service.dart` | `static Future<void> _performHeartbeatUpdate()` | 324 |
| `lib/core/services/session/rider_access_service.dart` | `static RiderAccess decide` | 29 |
| `lib/core/services/diagnostics/api_metrics_client.dart` | `class ApiMetricsClient` | 5 |
| `lib/main_navigation_screen.dart` | `void setIndex` | 29 |
| `lib/features/rider/navigation/rider_main_navigation_screen.dart` | `class RiderMainNavigationScreen` | 18 |
| `lib/features/rider/onboarding/screens/rider_entry_handler.dart` | `Future<void> load()` | 46 |
| `lib/features/rider/services/rider_status_service.dart` | `switchToRiderMode() async` | 104 |
| `lib/features/rider/home/rider_home_tab.dart` | `Future<void> loadRider` | 348 |
| `lib/features/rider/orders/rider_orders_screen.dart` | `final seedRider =` | 247 |
| `lib/features/rider/earnings/rider_earnings_tab.dart` | `final seedRider =` | 285 |
| `lib/features/rider/profile/rider_profile_tab.dart` | `final seedRider =` | 157 |
| `lib/features/user/home/home_tab.dart` | `Future<void> _load(` | 687 |
| `lib/features/user/activity/activity_tab.dart` | `Future<void> loadOrders` | 263 |
| `lib/features/auth/screens/profile_setup_screen.dart` | `.from('users').upsert` | 101 |
| `lib/modules/admin/admin_dashboard_screen.dart` | `class AdminDashboardScreen` | 8 |
| `lib/modules/notifications/services/notification_badge_service.dart` | `Future<void> _refreshOnce` | 44 |
| `lib/shared/widgets/account_guard.dart` | `Future<bool> _check` | 40 |
| `lib/shared/widgets/lazy_indexed_stack.dart` | `class LazyIndexedStack` | 5 |

## Tests

- `test/waydrop_access_and_lazy_tabs_test.dart` — main(), line 33
- `test/waydrop_gps_and_badge_test.dart` — main(), line 54
- `test/waydrop_metrics_and_seed_test.dart` — main(), line 7
- `test/logout_login_otp_navigation_regression_test.dart` — main(), line 42
- `test/production_control_system_regression_test.dart` — main(), line 24
- `test/rider_kyc_submission_reliability_regression_test.dart` — main(), line 32
- `test/subscription_trial_banner_and_vehicle_selection_regression_test.dart` — main(), line 62
- `test/egress_fixes_3_to_10_regression_test.dart` — main(), line 11
- `test/rider_home_earnings_reconciliation_regression_test.dart` — main(), line 36

## Pre-existing changes preserved

Startup, passenger Home, location cache and notification badge already had local changes; this task extends them. Existing edits to realtime_manager.dart, user_session_service.dart, incoming_order_card.dart, order_chat_screen.dart, payment_service.dart and unrelated regression files were not changed. Existing local migrations, .env, signing/certificate files and IDE settings were left in place.

## Report/evidence artifacts

The WAYDROP_* files in this docs directory contain the report, validation summaries, catalog/advisor/permission/index/plan evidence, Edge identity-check references and a redacted client-key classification. docs/proposals contains two unexecuted SQL proposals and their staging acceptance instructions. Generated build logs are disposable and are not production artifacts.
