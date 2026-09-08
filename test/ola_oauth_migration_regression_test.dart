// Structural regression guard for the Ola Maps OAuth migration (OLA_CLIENT_ID/OLA_CLIENT_SECRET
// client-credentials flow replacing the plain OLA_MAPS_API_KEY query-param scheme in
// get-live-order-status). Confirms: the OAuth credentials are read only via Deno.env.get() and
// never hardcoded/logged/returned to the client; the token endpoint and grant type match what was
// verified against Ola Krutrim's documented OAuth flow; the pre-OAuth OLA_MAPS_API_KEY path is
// still present and selectable (not deleted) so it remains an instant, no-redeploy rollback until
// OAuth is confirmed stable in production; and the client secret can never leak into a response
// body or error message surfaced to Flutter.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final olaClient = _read('supabase/functions/_shared/ola_client.ts');
  final getLiveOrderStatus = _read('supabase/functions/get-live-order-status/index.ts');

  group('ola_client.ts: credentials are never hardcoded, logged, or returned to the client', () {
    test('OLA_CLIENT_ID and OLA_CLIENT_SECRET are read only via Deno.env.get()', () {
      expect(olaClient.contains('Deno.env.get("OLA_CLIENT_ID")'), isTrue);
      expect(olaClient.contains('Deno.env.get("OLA_CLIENT_SECRET")'), isTrue);
    });

    test('no console.log/console.error call includes the client secret or the access token variable', () {
      // Every log call in the file is grepped for the two sensitive identifiers -- none should
      // ever appear inside a console.log/console.error argument list.
      final logCalls = RegExp(r'console\.(log|error)\([^;]*\);', dotAll: true)
          .allMatches(olaClient)
          .map((m) => m.group(0)!)
          .toList();
      expect(logCalls, isNotEmpty);
      for (final call in logCalls) {
        expect(call.contains('clientSecret'), isFalse);
        expect(call.contains('accessToken'), isFalse);
      }
    });

    test('no error message construction embeds clientSecret/clientId/accessToken', () {
      // Every HttpError(...) call site is a fixed, hand-written string literal -- never a
      // template interpolation of the credential/token variables.
      final httpErrorCalls = RegExp(r'new HttpError\([^)]*\)', dotAll: true)
          .allMatches(olaClient)
          .map((m) => m.group(0)!)
          .toList();
      expect(httpErrorCalls.length, greaterThanOrEqualTo(5));
      for (final call in httpErrorCalls) {
        expect(call.contains(r'${clientSecret}'), isFalse);
        expect(call.contains(r'${accessToken}'), isFalse);
      }
    });

    test('the access token is never assigned into a Response/JSON body', () {
      // Distinct from the CachedToken type's `accessToken: string` field declaration (an
      // in-memory type annotation, not a value ever serialized out) -- what must never exist is
      // the token being placed into a JSON.stringify()'d response payload.
      final jsonStringifyCalls = RegExp(r'JSON\.stringify\([^;]*\)', dotAll: true)
          .allMatches(olaClient)
          .map((m) => m.group(0)!)
          .toList();
      for (final call in jsonStringifyCalls) {
        expect(call.contains('accessToken'), isFalse);
        expect(call.contains('access_token'), isFalse);
      }
    });
  });

  group('ola_client.ts: OAuth flow matches the verified Ola Krutrim client-credentials contract', () {
    test('token endpoint is the documented Ola Krutrim Keycloak-backed URL', () {
      expect(
        olaClient.contains(
          'https://account.olamaps.io/realms/olamaps/protocol/openid-connect/token',
        ),
        isTrue,
      );
    });

    test('grant_type is client_credentials, submitted as form-urlencoded', () {
      expect(olaClient.contains('grant_type: "client_credentials"'), isTrue);
      expect(
        olaClient.contains('"Content-Type": "application/x-www-form-urlencoded"'),
        isTrue,
      );
    });

    test('subsequent Ola Maps API calls use a Bearer Authorization header, not an api_key param', () {
      expect(olaClient.contains(r'"Authorization": `Bearer ${accessToken}`'), isTrue);
    });

    test('an expired/rejected cached token is retried exactly once with a forced-fresh token', () {
      expect(olaClient.contains('response.status === 401 || response.status === 403'), isTrue);
      expect(olaClient.contains('cachedToken = null;'), isTrue);
    });

    test('missing client credentials produce a safe, explicit configuration error', () {
      expect(olaClient.contains('OLA_OAUTH_NOT_CONFIGURED'), isTrue);
      expect(olaClient.contains('is not configured on the server'), isTrue);
    });
  });

  group('get-live-order-status: OAuth is the default path, and the API-key path is preserved for rollback', () {
    test('imports the shared OAuth-based olaRequest helper', () {
      expect(
        getLiveOrderStatus.contains(
          'import { olaRequest } from "../_shared/ola_client.ts";',
        ),
        isTrue,
      );
    });

    test('OLA_AUTH_MODE selects between "oauth" (default) and the legacy "api_key" path', () {
      expect(getLiveOrderStatus.contains('Deno.env.get("OLA_AUTH_MODE") ?? "oauth"'), isTrue);
      expect(getLiveOrderStatus.contains('olaAuthMode === "api_key"'), isTrue);
    });

    test('OLA_MAPS_API_KEY is not deleted -- the legacy query-param call still exists as the fallback branch', () {
      expect(getLiveOrderStatus.contains('Deno.env.get("OLA_MAPS_API_KEY")'), isTrue);
      expect(
        getLiveOrderStatus.contains(
          r'https://api.olamaps.io/routing/v1/distanceMatrix/basic?origins=${riderLat},${riderLng}&destinations=${pickupLat},${pickupLng}&api_key=${olaApiKey}',
        ),
        isTrue,
      );
    });

    test('the OAuth branch calls the same distanceMatrix endpoint with the same origin/destination params', () {
      expect(getLiveOrderStatus.contains('olaRequest("/routing/v1/distanceMatrix/basic"'), isTrue);
      expect(getLiveOrderStatus.contains(r'origins: `${riderLat},${riderLng}`'), isTrue);
      expect(
        getLiveOrderStatus.contains(r'destinations: `${pickupLat},${pickupLng}`'),
        isTrue,
      );
    });

    test('the existing defensive rows/elements ETA parsing/validation is untouched by the migration', () {
      // Same guard as the original OLA ETA parsing crash fix -- must still run identically
      // regardless of which auth branch produced etaData.
      expect(getLiveOrderStatus.contains('OLA ETA response has no rows'), isTrue);
      expect(getLiveOrderStatus.contains('OLA ETA response row has no elements'), isTrue);
      expect(
        getLiveOrderStatus.contains('OLA ETA element missing distance/duration'),
        isTrue,
      );
    });

    test('an ETA/OAuth failure still degrades gracefully instead of failing the whole live-status response', () {
      // getEtaWithBudget's contract (fetchFresh throws, caller falls back to cache/zero) is
      // unchanged by the migration -- the catch block still re-throws into it rather than
      // returning an error response directly.
      expect(getLiveOrderStatus.contains('catch (etaError)'), isTrue);
      expect(getLiveOrderStatus.contains('throw etaError;'), isTrue);
    });

    test('this function never itself reads OLA_CLIENT_SECRET and never includes an access token in its output', () {
      // Only ola_client.ts should ever call Deno.env.get("OLA_CLIENT_SECRET") -- mentioning the
      // variable *name* in an explanatory comment here is fine (it names, never holds, the
      // secret); what must not exist is this file reading the value itself.
      expect(getLiveOrderStatus.contains('Deno.env.get("OLA_CLIENT_SECRET")'), isFalse);
      expect(getLiveOrderStatus.contains('access_token'), isFalse);
    });
  });
}
