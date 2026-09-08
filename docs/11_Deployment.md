# WayDrop Technical Documentation — Deployment & Environment Configuration

**Version:** 1.0  
**Last Updated:** July 5, 2026  
**Maintainer:** DevOps Lead  
**Applies To Commit:** 241d836  

---

## 1. Environment Variables Reference

WayDrop uses environment files to manage configurations across local, staging, and production environments.

### 1.1. Client Configuration (`.env`)
The Flutter app reads the following variables from the `.env` file at build time:

- **`SUPABASE_URL`:** The remote Supabase project endpoint (e.g., `https://yvwpchffctiagevpqgwy.supabase.co`).
- **`SUPABASE_ANON_KEY`:** The client-safe API key used for RLS queries.
- **`OLA_MAPS_API_KEY`:** The API key used for autocomplete queries and geocoding.
- **`CASHFREE_APP_ID`:** The client identifier for Cashfree Payments.
- **`CASHFREE_ENV`:** Configures the payment SDK environment (`TEST` or `PROD`).

### 1.2. Edge Function Secrets
Secrets used by Deno Edge Functions must be configured in the Supabase remote vault using the CLI:

```bash
supabase secrets set CASHFREE_APP_ID="your-app-id"
supabase secrets set CASHFREE_SECRET_KEY="your-secret-key"
supabase secrets set OLA_MAPS_API_KEY="your-maps-key"
supabase secrets set FIREBASE_SERVICE_ACCOUNT_KEY="raw-service-account-json-string"
```

---

## 2. Supabase Migrations & Edge Functions Deployments

### 2.1. Managing Migrations
To update the database schema, developers must use the Supabase CLI migration system:

1. **Create a Migration:** Generates a new SQL migration file:
   ```bash
   supabase migration new add_payout_logs
   ```
2. **Apply Migrations Locally (with Docker):**
   ```bash
   supabase db reset
   ```
3. **Deploy Migrations to Production:**
   ```bash
   supabase db push
   ```

### 2.2. Deploying Edge Functions
Edge functions must be deployed individually using the Supabase CLI:

```bash
# Deploy a single function (e.g. create-order)
supabase functions deploy create-order --project-ref yvwpchffctiagevpqgwy

# Deploy all functions
supabase functions deploy
```

---

## 3. Flutter Client Compilation Guide

### 3.1. Android Release Build (Google Play App Bundle)
To build a release-ready Android App Bundle (AAB):

1. **Configure Signing:** Ensure `android/key.properties` contains valid keystore paths and credentials.
2. **Run Build Command:**
   ```bash
   flutter build appbundle --release --obfuscate --split-debug-info=build/app/outputs/symbols
   ```
   *Note: Obfuscation is recommended to secure database connection helpers and service keys in the binary.*

### 3.2. iOS Release Build (App Store Archive)
To build and archive the iOS app for TestFlight or the App Store:

1. **Run Build Command:**
   ```bash
   flutter build ipa --release --obfuscate --split-debug-info=build/ios/outputs/symbols
   ```
2. **Distribute:** Open the generated Xcode archive (`build/ios/archive/Runner.xcarchive`) in Xcode and upload it to App Store Connect.
