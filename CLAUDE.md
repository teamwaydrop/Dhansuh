# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

WayDrop is a mobility/logistics app (local rides, local parcels, intercity rides, intercity parcels) built with Flutter (Dart, Riverpod) on top of Supabase (Postgres, RLS, Realtime, Edge Functions in Deno/TypeScript). Payments go through Cashfree. Maps/routing use Ola Maps. Push notifications use FCM.

There is an extensive hand-maintained doc set in `docs/` — read the relevant page before making non-trivial changes in that area:

- `docs/01_Architecture.md` — system topology, client-server data flow
- `docs/02_Database.md`, `03_RLS.md`, `04_Triggers.md` — schema, RLS policies, PL/pgSQL triggers
- `docs/06_Flutter/*` — per-layer Flutter reference (Core, Services, Providers, Screens, Widgets, Models)
- `docs/07_Payments.md` — Cashfree checkout/webhook/rollback flow
- `docs/08_Realtime.md` — WebSocket manager, reconnects, subscription lifecycle
- `docs/09_Notifications.md`, `10_Admin.md`
- `docs/11_Deployment.md` — env vars, migration/edge-function deploy steps, release build commands
- `docs/12_Troubleshooting.md` — coding standards + common failure modes
- `docs/13_Business_Logic.md`, `14_API_Contracts.md` — pricing/dispatch rules, the 16 edge function contracts
- `docs/15_Testing.md` — QA bypass credentials, mock locations, E2E checklists
- `docs/16_Runbook.md` — operational procedures

Note: `docs/06_Flutter/README.md` contains some example file paths from an older `lib/transport/...` layout that no longer exists — the codebase has since moved to the feature-first layout described in `ARCHITECTURE.md` and below. Trust `ARCHITECTURE.md` and the actual `lib/` tree over path examples in that doc.

`ARCHITECTURE.md` (repo root) is the authoritative, binding rulebook for folder layout, dependency direction, and import conventions — read it before adding/moving files.

## Commands

### Run / build (Flutter)
The client reads `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `OLA_MAPS_API_KEY` from `.env` at build time via `--dart-define-from-file`. Copy `.env.example` to `.env` and fill in real values first.

```bash
flutter run --dart-define-from-file=.env

flutter build appbundle --release --obfuscate --split-debug-info=build/app/outputs/symbols
flutter build ipa --release --obfuscate --split-debug-info=build/ios/outputs/symbols
```

Cashfree secrets (`CASHFREE_APP_ID`, `CASHFREE_SECRET_KEY`) are never in `.env` — they exist only as Supabase Edge Function secrets and are read server-side.

### Lint / analyze
```bash
flutter analyze
```

### Tests
```bash
flutter test                              # full suite
flutter test test/chat_regression_test.dart   # single file
```
Almost all tests under `test/` are **structural regression guards**, not widget/unit tests in the usual sense: they read source files as text (`File(path).readAsStringSync()`) and assert that a previously-fixed bug pattern (e.g. a raw `upi://pay` URI literal, an unvalidated client-supplied payment amount) has not been reintroduced. When fixing a production bug, check whether an existing regression test documents the root cause, and add a new structural guard test for genuinely new fixes rather than only relying on manual QA. A couple of files (`load_test_websocket.dart`, `network_chaos_verifier.dart`) are real network/websocket tests against a live Supabase instance, not structural guards.

`docs/15_Testing.md` has QA bypass credentials for manual testing: phone numbers prefixed `99999999` (e.g. `+919999999901`) bypass SMS with OTP `123456`; Cashfree sandbox UPI handles `success@gocashfree` / `fail@gocashfree` simulate payment outcomes.

### Supabase (backend)
```bash
supabase migration new <name>             # create a new migration
supabase db reset                         # apply all migrations locally (requires Docker)
supabase db push                          # deploy migrations to the linked project
supabase functions deploy <name>          # deploy a single edge function
supabase functions deploy                 # deploy all edge functions
supabase secrets set KEY="value"          # set an edge function secret
```
Migrations live in `supabase/migrations` (136+ files, strictly additive/forward-only — don't edit past migrations). Edge functions live under `supabase/functions/<name>/index.ts` (Deno/TypeScript, no Node tooling/package.json).

## Architecture

### High-level flow
Flutter client → Supabase Edge Functions (Deno, `service_role`, bypasses RLS) for anything transactional (order creation, pricing, payments, KYC) → Postgres. Postgres triggers/`pg_cron` react to state changes and can call edge functions (e.g. `send-push-notification`) via `pg_net`. The client also holds a single multiplexed Realtime WebSocket subscribed to filtered Postgres changes (orders, rider assignments, chat messages) for live UI updates, and receives FCM push for background/killed-app events. Auth is Supabase Phone OTP; RLS policies key off `auth.uid()` from the JWT.

### `lib/` layout (feature-first + platform modules)
```
lib/
├── core/            # app-wide infra: services (analytics, cache, database, location, maps, realtime, session), navigation, theme, providers
├── design_system/   # typography/spacing/color tokens
├── models/           # entities / dto / enums
├── shared/           # generic reusable screens, widgets, helpers, animations
├── features/         # business verticals: auth, user, rider, local_rides, local_parcels, intercity
└── modules/           # cross-cutting engines: chat, support, admin, payments, notifications
```

Dependency direction is one-way and enforced by convention, not tooling — **check it manually**:
```
features/*  →  modules/*  →  shared/*  →  core/*
```
- No feature may import another feature (e.g. `local_rides` must never import from `local_parcels`) — shared code belongs in `shared/` or `core/`.
- `modules/*` must stay feature-agnostic — never import from `features/`.
- No barrel files (`export 'x.dart'` re-export files) — import concrete paths directly.
- Prefer `package:waydrop/...` imports over deep relative (`../../../..`) imports.
- Screens are presentation-only; business logic and API calls live in controllers; reactive state lives in Riverpod providers.
- Guard `async` gaps in widgets with `if (!mounted) return;` before navigating/setting state after an `await`.
- Map Postgres `snake_case` to Dart `camelCase` in model classes during (de)serialization — never pass raw JSON maps into UI code.

### Business model context
Local rides/parcels take a per-order platform commission; WayDrop MAX is a subscription tier giving riders 0% commission for a periodic fee; passengers can add a voluntary "boost fare" on top of a ride, of which the platform takes a smaller cut. Intercity rides/parcels match against rider-published travel-plan corridors rather than ad-hoc dispatch. These rules and their edge cases are in `docs/13_Business_Logic.md` — check it before touching pricing, dispatch, or subscription logic, since incorrect changes here are revenue-affecting.
