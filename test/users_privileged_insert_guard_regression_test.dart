import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Structural safeguards only: these never connect to a database and do not
// establish runtime RLS, trigger order, JWT behavior or PostgREST upsert results.
void main() {
  final migration = File(
    'supabase/migrations/20261012000000_guard_users_privileged_insert.sql',
  ).readAsStringSync();
  final sql = migration
      .split('\n')
      .map((line) => line.split('--').first)
      .join('\n');

  test('attaches a separate row-level INSERT guard with no OLD dependency', () {
    expect(sql, contains('BEFORE INSERT ON public.users'));
    expect(sql, contains('FOR EACH ROW'));
    expect(sql, contains('public.prevent_privileged_users_insert()'));
    expect(sql, isNot(contains('OLD.')));
    expect(sql.trim(), startsWith('BEGIN;'));
    expect(sql.trim(), endsWith('COMMIT;'));
  });

  test('rejects both elevated initial fields and explicit nulls', () {
    expect(sql, contains("NEW.role IS DISTINCT FROM 'user'"));
    expect(sql, contains('NEW.is_developer IS DISTINCT FROM false'));
    expect(sql, contains('RAISE EXCEPTION'));
    expect(sql, contains("ERRCODE = 'insufficient_privilege'"));
    expect(RegExp(r'NEW\.\w+\s*:?=').hasMatch(sql), isFalse,
        reason: 'The guard must reject input rather than normalize it.');
  });

  test('preserves provisioning without trusting all missing-subject sessions', () {
    expect(sql, contains("auth.role() = 'service_role'"));
    expect(sql,
        contains("CURRENT_USER = 'postgres' AND auth.uid() IS NULL"));
    expect(sql, contains('SECURITY INVOKER'));
    expect(sql, contains("SET search_path = ''"));
    expect(sql, isNot(contains('SECURITY DEFINER')));
  });

  test('does not replace UPDATE protection, grants, RLS or profile defaults', () {
    expect(sql, isNot(contains('public.prevent_role_self_escalation')));
    expect(sql, isNot(contains('trigger_prevent_role_self_escalation')));
    expect(RegExp(r'\b(GRANT|REVOKE|ALTER TABLE|UPDATE|DELETE)\b')
        .hasMatch(sql), isFalse);
    expect(sql, isNot(contains('public.admins')));
  });

  test('ordinary auth and reviewer upserts omit privileged fields', () {
    for (final path in [
      'lib/core/services/database/supabase_service.dart',
      'lib/features/auth/screens/otp_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      final payloads = RegExp(r'\.upsert\(\{([\s\S]*?)\}\)')
          .allMatches(source)
          .map((match) => match.group(1)!);
      expect(payloads, isNotEmpty, reason: path);
      for (final payload in payloads) {
        expect(payload, contains("'id': user.id"));
        expect(payload, isNot(contains("'role':")));
        expect(payload, isNot(contains("'is_developer':")));
      }
    }
  });

  test('existing profile and token ownership policies remain in source', () {
    final baseline = File(
      'supabase/migrations/20260529000000_baseline_foundational_schema.sql',
    ).readAsStringSync();
    expect(baseline, contains('Users can insert own profile'));
    expect(baseline, contains('WITH CHECK (("auth"."uid"() = "id"))'));
    final tokens = File(
      'supabase/migrations/20260602000001_create_user_device_tokens.sql',
    ).readAsStringSync();
    expect(tokens, contains('with check ( (select auth.uid()) = user_id )'));
  });
}
