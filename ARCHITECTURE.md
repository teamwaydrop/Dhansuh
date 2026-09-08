# WayDrop Mobile Application Architecture

This document defines the architectural patterns, folder layout, state management, and coding standards for the WayDrop Flutter application. All developers and subagents must adhere strictly to these guidelines.

---

## 1. Folder Structure & Responsibilities

The codebase follows a refined **Feature-First + Platform Module** architecture.

```
lib/
├── main.dart
├── app_start_screen.dart
├── main_navigation_screen.dart
│
├── core/                           # App-wide infrastructure (generic)
│   ├── constants/                  # Static constants (API, maps, configurations)
│   ├── extensions/                 # Dart extensions on Context, String, DateTime, etc.
│   ├── location/                   # Location resolvers and serviceability models
│   ├── providers/                  # App-wide Riverpod providers (mode state, session)
│   ├── theme/                      # Responsive layout grids and app color theme schemes
│   ├── navigation/                 # Centralized flow modules & routes
│   └── services/                   # App-wide services divided by domain
│
├── design_system/                  # Typography, spacing, colors, and common raw tokens
│
├── models/                         # Domain models grouped by business type
│   ├── entities/                   # Database entities and domain representations
│   ├── dto/                        # Request/Response Data Transfer Objects (DTOs)
│   └── enums/                      # Standard domain enums
│
├── shared/                         # Completely generic, reusable code
│   ├── animations/
│   ├── screens/                    # e.g., ConnectionErrorScreen, PoliciesScreen
│   ├── helpers/                    # Shared utility helper classes
│   └── widgets/                    # Sub-categorized generic widgets
│
├── features/                       # Business vertical modules (loosely coupled)
│   ├── auth/                       # login, otp verification, profile setup, permissions
│   ├── user/                       # Customer home, services menu, activity tab, profile, settings
│   ├── rider/                      # Rider onboarding (KYC), home, travel plans, earnings, payouts, settings
│   ├── local_rides/                # Local ride-hailing flow (booking, searching, tracking, rating)
│   ├── local_parcels/              # Local parcel flow (booking, searching, tracking)
│   └── intercity/                  # Intercity ride/parcel vertical
│
└── modules/                        # Cross-cutting platform modules (reusable across features)
    ├── chat/                       # General order chat module
    ├── support/                    # Support ticket/chat flows
    ├── admin/                      # Admin panel dashboard views
    ├── payments/                   # Fare calculation pricing and payment gateways
    └── notifications/              # Local/push notifications service manager
```

---

## 2. Dependency & Coupling Rules

To prevent code drift and maintain loose coupling, dependencies are strictly directional.

```
Feature Modules (local_rides, local_parcels, intercity, rider, user, auth)
    ↓
Cross-Cutting Platform Modules (chat, support, payments, notifications)
    ↓
Shared Components & Helper Layer (shared/)
    ↓
Core Infrastructure Layer (core/)
```

### Directives:
*   **No Inter-Feature Imports**: A file inside `features/local_rides/` must **never** import a file from `features/local_parcels/`. If they require common widgets, utilities, or services, those files must be moved to the `shared/` or `core/` layers.
*   **Modules are Feature-Agnostic**: A module in `modules/` (like `payments`) must not import features from `features/`. Modules act as generic, cross-cutting engines.
*   **Feature Sub-Folders**: When a business feature grows, it must be structured by sub-features (e.g. `booking/`, `searching/`, `tracking/`, `rating/`). Each active sub-feature will use:
    *   `screens/` - UI view screens.
    *   `widgets/` - Sub-feature specific UI components.
    *   `controllers/` - Controllers handling business logic.
    *   `providers/` - Riverpod state providers.
    *   `services/` - Sub-feature specific API calls.

---

## 3. State Management & Logic Separation

WayDrop separates visual layout (UI) from state modification and logic:
1.  **Screens (Views)**: Focus solely on presentation and UI layout. They should contain minimal logic. Large screens must be decomposed into smaller widgets.
2.  **Controllers**: Houses business logic, interacts with API services, and updates states. Screens delegate user actions to controllers.
3.  **Riverpod Providers**: Holds and exposes reactive state variables.

Avoid putting heavy logic or direct DB connections in screen files.

---

## 4. Coding & Import Conventions

*   **Preferred Package Imports**: Always prefer package imports `import 'package:waydrop/...'` over deep relative imports (`import '../../../../...'`). This simplifies file refactoring.
*   **Comments Pattern**: Inline comments should answer **why** a block of code does what it does (its design intent), rather than **what** it mechanically executes (which should be clear from the code).
*   **No Barrel Exports**: Avoid creating barrel files (`export 'xyz.dart';`) for entire folders or features. Import direct paths instead.
