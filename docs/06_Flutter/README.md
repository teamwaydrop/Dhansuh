# WayDrop Flutter Codebase — Directory & File Flow Architecture

**Version:** 1.0  
**Last Updated:** July 5, 2026  
**Maintainer:** Lead Mobile Platform Engineer  
**Applies To Commit:** 241d836  

---

## 1. Directory Tree & Codebase Organization

The client application code is located in the `lib/` directory and is organized into features, models, services, and shared widgets. Below is the file directory tree:

```text
lib/
├── core/                              # Core system utilities namespaced by domain
│   ├── services/                      # Low-level platform & network services
│   │   ├── analytics/                 # AnalyticsService
│   │   ├── cache/                     # CacheService, CacheCleanupHelper
│   │   ├── database/                  # SupabaseService
│   │   ├── location/                  # LocationCacheService, ServiceabilityService, LocationPermissionHelper
│   │   ├── maps/                      # OlaMapService
│   │   ├── realtime/                  # RealtimeManager, RealtimeOrderController, RealtimeObservability
│   │   └── session/                   # FeatureFlagService, UserSessionService, PipService
│   ├── navigation/                    # Central routing configurations
│   │   └── flow_modules.dart
│   └── theme/                         # App colors & resolution layout scaling
│       ├── app_colors.dart
│       └── responsive_layout.dart
├── design_system/                     # Premium design system tokens
│   └── waydrop_design_system.dart
├── features/                          # Vertical business features (loosely coupled)
│   ├── auth/                          # Authentication flow screens
│   ├── local_rides/                   # Local passenger rides flow
│   ├── local_parcels/                 # Local parcel delivery flow
│   ├── intercity/                     # Intercity vertical (rides and parcels)
│   ├── rider/                         # Rider dashboard, KYC onboarding, travel plans, earnings
│   └── user/                          # User home tab, activity ledger, settings
├── modules/                           # Cross-cutting platform modules
│   ├── admin/                         # Admin panel dashboard
│   ├── chat/                          # In-app passenger-rider chat messages
│   ├── support/                       # Support ticketing & admin chat
│   ├── payments/                      # Cashfree payments integration & pricing engine
│   └── notifications/                 # FCM client services
├── shared/                            # Generic shared UI resources
│   ├── helpers/                       # ConnectivityWrapper, DeviceInfoHelper
│   ├── widgets/                       # SkeletonLoader, ModeSwitchOverlay, CustomNavigationBar
│   ├── screens/                       # ConnectionErrorScreen, NotServiceableScreen
│   └── animations/                    # WayDropBikeAnimation
├── models/                            # Shared domain data models
├── app_start_screen.dart              # Startup guard screen
├── main.dart                          # Application entry point
└── main_navigation_screen.dart        # Customer flow main navigation
```

---

## 3. Data Flow & Connection Pipeline

The client architecture uses a unidirectional data flow. User inputs trigger backend requests, while realtime streams handle UI updates:

```text
[1. User Gesture]
       │ (Taps "Pay & Book" in FarePreviewSheet)
       ▼
[2. Riverpod Provider]
       │ (Invokes calculate-order-pricing Edge Function)
       ▼
[3. Services Layer]
       │ (OlaMapService routes path -> Supabase API creates order)
       ▼
[4. Database Event]
       │ (orders table inserts row -> triggers start-dispatch)
       ▼
[5. Realtime Stream]
       │ (RealtimeManager listens to order channel changes)
       ▼
[6. State Update]
       │ (currentOrderProvider updates TransportOrder model)
       ▼
[7. Screen Rerender]
       │ (SearchingRiderScreen switches to ActiveOrderTrackingScreen)
       ▼
[8. Live Tracking]
       │ (Maps markers follow rider coordinates in real-time)
```

### 3.1. Detailed Connections Specification

1. **Auth Flow:**
   - [LoginScreen](file:///c:/Users/munee/Desktop/waydrop/lib/features/auth/screens/login_screen.dart) $\to$ [SupabaseService.sendOtp](file:///c:/Users/munee/Desktop/waydrop/lib/core/services/database/supabase_service.dart#L6) $\to$ Supabase Auth.
   - [OtpScreen](file:///c:/Users/munee/Desktop/waydrop/lib/features/auth/screens/otp_screen.dart) $\to$ [SupabaseService.verifyOtp](file:///c:/Users/munee/Desktop/waydrop/lib/core/services/database/supabase_service.dart#L14) $\to$ creates profile $\to$ [AppStartScreen](file:///c:/Users/munee/Desktop/waydrop/lib/app_start_screen.dart).

2. **Booking Flow:**
   - [HomeTab](file:///c:/Users/munee/Desktop/waydrop/lib/features/user/home/home_tab.dart) $\to$ [AddressSelectionScreen](file:///c:/Users/munee/Desktop/waydrop/lib/transport/address_selection_screen.dart) $\to$ calls [OlaMapService.autocomplete](file:///c:/Users/munee/Desktop/waydrop/lib/core/services/maps/ola_map_service.dart#L171).
   - [AddressSelectionScreen](file:///c:/Users/munee/Desktop/waydrop/lib/transport/address_selection_screen.dart) $\to$ calls [OlaMapService.fetchRoute](file:///c:/Users/munee/Desktop/waydrop/lib/core/services/maps/ola_map_service.dart) $\to$ passes details to [FarePreviewSheet](file:///c:/Users/munee/Desktop/waydrop/lib/transport/fare_preview_sheet.dart).
   - [FarePreviewSheet](file:///c:/Users/munee/Desktop/waydrop/lib/transport/fare_preview_sheet.dart) $\to$ calls `create-order` Edge Function $\to$ redirects to [SearchingRiderScreen](file:///c:/Users/munee/Desktop/waydrop/lib/transport/searching_rider_screen.dart).

3. **Tracking & Realtime Flow:**
   - [SearchingRiderScreen](file:///c:/Users/munee/Desktop/waydrop/lib/transport/searching_rider_screen.dart) $\to$ registers order listener via [RealtimeOrderController.watchOrder](file:///c:/Users/munee/Desktop/waydrop/lib/core/services/realtime/realtime_order_controller.dart) $\to$ updates `currentOrderProvider`.
   - On rider acceptance, switches view to [ActiveOrderTrackingScreen](file:///c:/Users/munee/Desktop/waydrop/lib/transport/active_order_tracking_screen.dart).
   - [ActiveOrderTrackingScreen](file:///c:/Users/munee/Desktop/waydrop/lib/transport/active_order_tracking_screen.dart) listens to the rider's live coordinates stream via [RiderStatusService](file:///c:/Users/munee/Desktop/waydrop/lib/features/rider/services/rider_status_service.dart) $\to$ updates position markers on the map dynamically.

---

## 4. Sub-Module Documentation References

For detailed reference documentation on each architectural layer, refer to the following sub-documents:

- [Core Lifecycle Configurations](Core.md): Detailed specifications for `main.dart`, app initialization, and mode routing.
- [Services Layer API References](Services.md): Complete specifications for all 19 system integrations and API helpers.
- [State Providers Reference](Providers.md): Details on state notifiers, data flows, and Riverpod updates.
- [Domain Models Specification](Models.md): Complete reference for JSON serialization models, parameters, and type mappings.
- [Design System & Widgets Guide](Widgets.md): Specifications for custom components, 3D tilt containers, and layouts.
- [Screens Catalog Reference](Screens.md): Catalog of application views, controllers, and navigation transitions.
