// Regression guard for the send-push-notification Google OAuth token cache (performance pass).
//
// CONTEXT: getAccessToken() previously performed a fresh Google OAuth JWT-bearer token exchange on
// every single invocation, even though the resulting access token is valid for a full hour. It now
// caches the token (with expiry) in a module-level variable so warm Edge Function instances can
// reuse it, refreshing with a safety margin before real expiry. Cold starts (module-level variable
// still null) fall through to the exact same OAuth flow as before -- this cache must be pure upside,
// never able to hand out a stale/expired token, and never log/persist/expose the token anywhere.
//
// Structural guard (reads the real source), matching the pattern used throughout this suite for
// Deno edge functions that can't run against a live Supabase/Google OAuth endpoint in a plain unit
// test.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('send-push-notification -- getAccessToken() caches the Google OAuth token', () {
    final source = _read('supabase/functions/send-push-notification/index.ts');

    test('a module-level cache variable holds the token together with its expiry', () {
      expect(source.contains('let _cachedAccessToken'), isTrue);
      expect(source.contains('expiresAtMs'), isTrue);
    });

    test('getAccessToken() checks the cache before doing any network/crypto work, with a safety '
        'margin before real expiry', () {
      final start = source.indexOf(
          'async function getAccessToken(clientEmail: string, privateKey: string)');
      final end = source.indexOf('serve(async (req)');
      final body = source.substring(start, end);

      final cacheCheckIdx = body.indexOf('if (_cachedAccessToken');
      final cleanKeyIdx = body.indexOf('const cleanKey');
      expect(cacheCheckIdx, greaterThanOrEqualTo(0));
      expect(cleanKeyIdx, greaterThan(cacheCheckIdx),
          reason: 'the cache check must happen before the PEM/JWT/network work, not after');
      expect(body.contains('TOKEN_REFRESH_MARGIN_MS'), isTrue,
          reason: 'must refresh before real expiry, never hand out a token that could expire '
              'mid-flight');
    });

    test('a fresh token exchange always updates the cache before returning', () {
      final start = source.indexOf('const resData = await response.json();');
      final end = source.indexOf('return resData.access_token;');
      final body = source.substring(start, end);
      expect(body.contains('_cachedAccessToken = {'), isTrue);
      expect(body.contains('token: resData.access_token'), isTrue);
    });

    test('the token is never logged, persisted to the DB, or included in a response body', () {
      expect(source.contains('console.log(accessToken)'), isFalse);
      expect(source.contains('console.error(accessToken)'), isFalse);
      expect(source.contains('access_token: accessToken'), isFalse);
      // Only ever used to build the Authorization header for the FCM request.
      expect(source.contains('"Authorization": `Bearer \${accessToken}`'), isTrue);
    });

    test('FCM payload construction and notification DB flow are unchanged', () {
      expect(source.contains('fcm.googleapis.com/v1/projects'), isTrue);
      expect(source.contains("await updateStatus(\"sent\", true);"), isTrue);
      expect(source.contains("await updateStatus(\"failed\", false,"), isTrue);
    });
  });
}
