# WayDrop Technical Documentation — Troubleshooting & Standards

**Version:** 1.0  
**Last Updated:** July 5, 2026  
**Maintainer:** Operations Quality Lead  
**Applies To Commit:** 241d836  

---

## 1. Coding Standards & Architectural Guidelines

To maintain code quality as new developers join the project, follow these guidelines:

### 1.1. Code Style & Clean Architecture
- **State Separation:** Keep UI widgets stateless. Business logic, network requests, and database calls must be handled in Riverpod state providers.
- **CamelCase & SnakeCase:** Map PostgreSQL `snake_case` fields to Dart `camelCase` parameters during serialization in model classes. Do not use raw JSON maps in UI classes.
- **Asynchronous Safe Guards:** When calling asynchronous methods in UI widgets, check `if (!mounted)` before triggering state changes or navigation:
  ```dart
  await saveProfile();
  if (!mounted) return;
  Navigator.pushReplacement(...);
  ```

### 1.2. Database & SQL Best Practices
- **Security First:** Ensure Row Level Security (RLS) is enabled on all new tables.
- **Permissions:** Grant explicit read/write permissions to authenticated roles.
- **Triggers:** Keep trigger functions simple. Avoid making external HTTP calls inside transactional triggers. Instead, insert events into a queue table (like `notifications`) and let background workers process them asynchronously.

---

## 2. Common Runtime Issues & Resolutions

### 2.1. Real-time Sync & WebSocket Failures
- **Symptom:** Passengers don't receive order status updates, or riders don't see incoming matching offers.
- **Root Cause:** The WebSocket connection was lost due to network changes, or the channel subscription failed.
- **Resolution:**
  1. Inspect the `RealtimeManager` log output to verify the socket state.
  2. If the connection is stale, check if the heartbeat ping-pong interval is active.
  3. Ensure the table replica identity is set to `REPLICA IDENTITY FULL` to receive update details on the client:
     ```sql
     ALTER TABLE public.orders REPLICA IDENTITY FULL;
     ```

### 2.2. Webhook Signature Failures
- **Symptom:** Cashfree confirms a successful payment, but the order remains in a `pending_payment` state.
- **Root Cause:** The `CASHFREE_SECRET_KEY` does not match, or the signature payload formatting is incorrect.
- **Resolution:**
  1. Check the Edge Function logs on the Supabase dashboard to inspect the verification signature error.
  2. Verify the raw request payload matches Cashfree's signature requirements.
  3. Ensure the correct webhook keys are configured in Deno secrets.

### 2.3. Location Services & Routing Errors
- **Symptom:** Fares display as 0, or map routes fail to draw.
- **Root Cause:** The Ola Maps API key is invalid, or the daily quota has been exceeded.
- **Resolution:**
  1. Check `lib/core/services/maps/ola_map_service.dart` to verify the request payload.
  2. Inspect the HTTP status code returned by the Ola Maps API. A `403 Forbidden` indicates an invalid key or domain restriction.
