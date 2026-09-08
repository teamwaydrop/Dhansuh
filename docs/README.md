# WayDrop Technical Documentation Reference Guide

**Version:** 1.0  
**Last Updated:** July 5, 2026  
**Maintainer:** Lead System Architect  
**Applies To Commit:** 241d836  

---

## 1. Project Overview

### What is WayDrop?
WayDrop is a modern logistics and mobility ecosystem designed for rapid, on-demand transport and shipping. It bridges the gap between passengers/senders and independent rider partners, allowing users to request local rides, courier deliveries, or arrange corridor-based intercity travel plans and parcel shipments.

### Business Model
WayDrop operates a dual-transaction model:
- **On-Demand (Local) Commission:** Takes a platform commission (e.g., 10-20%) on individual local rides and parcel deliveries.
- **Subscription-Based (WayDrop MAX):** Offers riders a zero-commission subscription tier where they pay a fixed periodic fee (e.g., weekly/monthly) to retain 100% of their base fares and distance-based earnings.
- **Ride Boosting:** Allows passengers to add a voluntary "boost fare" to incentivize riders. The platform takes a smaller percentage of this boost (e.g., 20%), passing 80% directly to the rider.

### Supported Services
1. **Local Ride:** Short-distance point-to-point passenger transport within a city tier (e.g. bike, auto, cab).
2. **Local Parcel:** On-demand local courier service for packages up to 10kg (via bike) and larger shipments (via auto).
3. **Intercity Ride:** Long-distance ride sharing connecting different cities, utilizing travel plan corridor matching.
4. **Intercity Parcel:** Direct delivery of packages between cities by matching shipments with travellers going along the same route.

### User Roles
- **User (Passenger/Sender):** Books rides, sends packages, manages payments, tracks rides, rates riders, and chats.
- **Rider (Traveller/Courier):** Completes KYC, registers payout details, manages online/offline status, views nearby orders, accepts/rejects assignments, publishes travel plans, handles package verification, and requests withdrawals.
- **Admin:** Monitors system activity, reviews KYC submissions, moderates support chats, and broadcasts push notifications.

### Technology Stack
- **Client Client:** Flutter (Dart), utilizing Riverpod for state management and Ola Maps SDK for map tiles and routing.
- **Backend / DB:** Supabase (PostgreSQL), utilizing Row Level Security (RLS), PL/pgSQL database functions, triggers, and real-time socket channels.
- **APIs & Workers:** Supabase Edge Functions (Deno / TypeScript).
- **Notifications:** Firebase Cloud Messaging (FCM) via Deno.
- **Payment Processor:** Cashfree Payment Gateway SDK (client) & API (backend webhooks).

---

## 2. Table of Contents

Navigate the documentation modules using the relative links below:

### System & Architecture
- **[01 Architecture](01_Architecture.md)** — Core design pattern, client-server data flow, external API integrations, and block diagrams.
- **[13 Business Logic](13_Business_Logic.md)** — Lifecycles, pricing formulas, dispatch logic, subscription rules, and compliance gates.
- **[14 API Contracts](14_API_Contracts.md)** — Routes, payloads, responses, and errors for the 16 Edge Functions.

### Database & Security
- **[02 Database](02_Database.md)** — Table schemas, relationship ER diagrams, sequences, and enums.
- **[03 RLS](03_RLS.md)** — Row Level Security (RLS) policies, security boundaries, and tenant isolation.
- **[04 Triggers](04_Triggers.md)** — PL/pgSQL database functions, trigger logic, and automated cron checking.

### Sub-systems
- **[07 Payments](07_Payments.md)** — Cashfree checkout, webhook verification, rollback logic, and sequence diagrams.
- **[08 Realtime](08_Realtime.md)** — WebSockets manager, exponential backoff reconnects, heartbeat checking, and subscription lifecycles.
- **[09 Notifications](09_Notifications.md)** — FCM configuration, foreground suppressions, and native notification channels.
- **[10 Admin](10_Admin.md)** — Dashboard, broadcast push notifications, and support chats.

### Flutter Client (`lib/` Directory Index)
- **[Flutter README](06_Flutter/README.md)** — Overview of the Flutter app structure.
- **[Core Configuration](06_Flutter/Core.md)** — Geofence resolver, location caching, and city normalization.
- **[Services](06_Flutter/Services.md)** — Integrations (Ola Maps, Supabase, Notification, Cache, PIP).
- **[State Providers](06_Flutter/Providers.md)** — Riverpod providers, notifiers, and theme controllers.
- **[Screens Index](06_Flutter/Screens.md)** — Onboarding, booking, tracking, and settings UI files.
- **[Widgets](06_Flutter/Widgets.md)** — Design system elements, Curved Navigation, and 3D containers.
- **[Models](06_Flutter/Models.md)** — Data structures (TransportOrder, PaymentFor, Maps).

### Deployment & Operations
- **[11 Deployment](11_Deployment.md)** — Build commands, Supabase migration pipelines, secrets, and environment variable references.
- **[12 Troubleshooting](12_Troubleshooting.md)** — Coding standards, roadmap, and common failure debugging (realtime, webhooks, maps).
- **[15 Testing Guide](15_Testing.md)** — QA accounts, bypass credentials, QA test suites, and regression checks.
- **[16 Operations Runbook](16_Runbook.md)** — Step-by-step procedures for updates, recovery, secret rotation, and manuals.
