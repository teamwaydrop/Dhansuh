# WayDrop Technical Documentation — System Architecture

**Version:** 1.0  
**Last Updated:** July 5, 2026  
**Maintainer:** Lead System Architect  
**Applies To Commit:** 241d836  

---

## 1. System Topology Overview

WayDrop uses a **Serverless-First Server-Client Hybrid Architecture**. The client-side application is written in Flutter and interacts directly with a serverless backend hosted on Supabase. Heavy computation, third-party integrations (Cashfree, FCM), and security-sensitive steps are performed within isolated Supabase Edge Functions.

The system communicates through three key channels:
1. **REST API (Supabase & Edge Functions):** For stateless, transactional requests like order creation, payment generation, and KYC validation.
2. **WebSocket Channels (Postgres Realtime):** For state synchronization (e.g. tracking order status updates, receiving chat messages, and tracking active rider positions).
3. **Push Notifications (Firebase Cloud Messaging):** For asynchronous event delivery (e.g. alerting riders to nearby orders, notifying users of status updates, and support messages) when the app is in the background or closed.

---

## 2. Complete Architecture Diagram

The block diagram below details how the client client, authentication layer, database, edge functions, and external services are connected:

```mermaid
graph TD
    classDef client fill:#e1f5fe,stroke:#0288d1,stroke-width:2px;
    classDef supabase fill:#efebe9,stroke:#5d4037,stroke-width:2px;
    classDef postgres fill:#e8f5e9,stroke:#2e7d32,stroke-width:2px;
    classDef external fill:#fff8e1,stroke:#f57f17,stroke-width:2px;

    %% Client App
    Flutter["Flutter Client App (Dart)"]:::client
    
    %% Supabase Core Services
    SubAuth["Supabase Authentication"]:::supabase
    SubStorage["Supabase Storage<br/>(buckets: parcel_images, kyc_docs)"]:::supabase
    SubFunctions["Supabase Edge Functions<br/>(Deno / TypeScript)"]:::supabase
    
    %% Database Services
    SubDB[(Supabase PostgreSQL Database)]:::postgres
    SubRealtime["Supabase Realtime Engine<br/>(WAL Replication)"]:::postgres
    PgCron["pg_cron Scheduler"]:::postgres
    
    %% External APIs
    Firebase["Firebase Cloud Messaging (FCM)"]:::external
    OlaMaps["Ola Maps Geocoding & Routing"]:::external
    Cashfree["Cashfree Payment Gateway"]:::external

    %% Connections
    Flutter -->|Auth token sign-in/verify| SubAuth
    Flutter -->|Upload KYC / Parcel photos| SubStorage
    Flutter -->|Invoke REST APIs / SSL HTTPS| SubFunctions
    
    SubFunctions -->|Bypass RLS / service_role| SubDB
    SubFunctions -->|Fetch OAuth2 & send notifications| Firebase
    SubFunctions -->|Create / verify checkout session| Cashfree
    SubFunctions -->|Compute distance & routes| OlaMaps
    
    SubDB -->|Database Event Triggers| SubFunctions
    SubDB -->|Cron tasks check| PgCron
    SubDB -->|WAL Log events| SubRealtime
    
    SubRealtime -.->|WebSocket stream updates| Flutter
    Cashfree -.->|Webhooks payment confirmation| SubFunctions
    Firebase -.->|Push notify background alerts| Flutter
    Flutter -->|Ola Maps Web SDK Tiles| OlaMaps
```

---

## 3. Core Architecture Sub-systems

### 3.1. Authentication Layer
- Handled via Supabase Phone OTP Auth.
- The phone number is verified, returning a JWT token.
- On successful login, the client receives the JWT token, which is attached to all subsequent REST requests (`Authorization: Bearer <JWT>`).
- Row Level Security (RLS) uses `auth.uid()` from this JWT to restrict query results.

### 3.2. Transactional API Pipeline
1. The Flutter client invokes a Supabase Edge Function via HTTPS.
2. The Edge Function verifies the JWT auth header to authenticate the caller.
3. The function performs third-party validations or calls (e.g. routing calculations on Ola Maps, payment initiation on Cashfree).
4. The function executes changes on PostgreSQL with elevated permissions (`service_role` client) to bypass RLS policies.
5. The function returns a JSON response to the client.

### 3.3. Real-time Database Synchronization
- The client establishes a single, multiplexed WebSocket connection to the Supabase Realtime service.
- The client subscribes to Postgres replication changes (`supabase_realtime` publication) on specific tables (e.g., `orders`, `rider_assignments`, `order_chat_messages`) filtered by columns (e.g., `user_id = auth.uid()` or `rider_id = <rider_id>`).
- When a database trigger or script alters a row, PostgreSQL writes the change to the Write-Ahead Log (WAL). The Realtime engine reads this log and pushes the update down the WebSocket to the client.

### 3.4. Payment Sub-system
- Coordinates between Flutter client, Supabase Edge Functions, Cashfree payment gateway, and PostgreSQL.
- State transitions are managed using the `payments` table and updated in real-time, providing immediate visual feedback in the client UI.

### 3.5. Notification Sub-system
- High-priority background alerts are dispatched via database triggers.
- Triggers invoke PostgreSQL functions that send HTTP POST requests to the `send-push-notification` edge function via the `pg_net` extension.
- The Edge function converts the payload, grabs device tokens from `user_device_tokens`, and delivers them using Google OAuth2 to the Firebase Cloud Messaging (FCM) API.
