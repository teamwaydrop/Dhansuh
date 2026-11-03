import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/session/rider_access_service.dart';

void main() {
  test('transient Auth failures cannot masquerade as an invalid session', () {
    for (final failure in [
      AuthRetryableFetchException(statusCode: '503'),
      const AuthException('gateway unavailable', statusCode: '504'),
      const AuthException('transport failed'),
      TimeoutException('synthetic timeout'),
      const PostgrestException(message: 'statement timeout', code: '57014'),
      const PostgrestException(message: 'pool timeout', code: 'PGRST003'),
      const PostgrestException(message: 'permission denied', code: '42501'),
    ]) {
      expect(
        RiderAccessService.requiresLogin(failure),
        isFalse,
        reason:
            '${failure.runtimeType} must remain an error, never ready or Login',
      );
    }
  });
  test('definitive missing or rejected credentials still require login', () {
    for (final failure in [
      AuthSessionMissingException(),
      const AuthException('unauthorized', statusCode: '401'),
      const AuthException('malformed token', code: 'invalid_jwt'),
      const PostgrestException(message: 'invalid JWT', code: 'PGRST301'),
      const PostgrestException(message: 'expired JWT', code: 'PGRST303'),
    ]) {
      expect(RiderAccessService.requiresLogin(failure), isTrue);
    }
  });
}
