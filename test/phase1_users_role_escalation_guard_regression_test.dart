// Regression guard for Phase 1 audit finding H4 -- users.role / users.is_developer
// self-escalation.
//
// Migration 20260906000002:
//   Layer A -- REVOKE UPDATE (role, is_developer) ON public.users FROM authenticated, anon
//   Layer B -- (re)attach trigger_prevent_role_self_escalation BEFORE UPDATE ON public.users
//              with a hardened session check (blocks only a real end-user PostgREST session).
//
// Source-as-text structural guard. Asserts both layers are present, the guard blocks the right
// sessions, only the two privileged columns are locked (rating/profile columns untouched), and
// `is_suspended` -- a column that does not exist on public.users -- is never referenced.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

const _migPath =
    'supabase/migrations/20260906000002_restore_users_role_self_escalation_guard.sql';

void main() {
  final mig = _read(_migPath);
  final exec = mig
      .split('\n')
      .map((l) {
        final i = l.indexOf('--');
        return i >= 0 ? l.substring(0, i) : l;
      })
      .join('\n');

  group('H4 Layer A -- column-level UPDATE privilege', () {
    test('REVOKEs UPDATE (role, is_developer) on public.users from authenticated AND anon', () {
      expect(exec.contains('REVOKE UPDATE (role, is_developer) ON TABLE public.users FROM authenticated;'), isTrue);
      expect(exec.contains('REVOKE UPDATE (role, is_developer) ON TABLE public.users FROM anon;'), isTrue);
    });

    test('does NOT revoke UPDATE on any other column (rating / rating_sum / total_ratings / profile fields stay writable)', () {
      // The SECURITY INVOKER rating trigger writes rating/rating_sum/total_ratings as the
      // authenticated user -- those must NOT be revoked.
      for (final col in [
        'rating', 'rating_sum', 'total_ratings', 'full_name', 'email',
        'profile_completed', 'onboarding_completed', 'preferred_mode',
        'profile_photo_url', 'gender', 'pref_order_notifications',
      ]) {
        expect(exec.contains('REVOKE UPDATE ($col)'), isFalse,
            reason: 'must not revoke UPDATE on $col');
      }
      // Exactly one REVOKE-UPDATE column list, and it is (role, is_developer).
      final lists = RegExp(r'REVOKE UPDATE \(([^)]+)\)').allMatches(exec).map((m) => m.group(1)!.trim()).toSet();
      expect(lists, {'role, is_developer'});
    });

    test('does not touch service_role privileges or any GRANT', () {
      expect(exec.contains('FROM service_role'), isFalse);
      expect(RegExp(r'\bGRANT\b').hasMatch(exec), isFalse);
    });
  });

  group('H4 Layer B -- trigger guard', () {
    test('(re)creates the function and the trigger on public.users', () {
      expect(mig.contains('CREATE OR REPLACE FUNCTION public.prevent_role_self_escalation()'), isTrue);
      expect(mig.contains('DROP TRIGGER IF EXISTS trigger_prevent_role_self_escalation ON public.users;'), isTrue);
      expect(
        mig.contains('CREATE TRIGGER trigger_prevent_role_self_escalation\nBEFORE UPDATE ON public.users\nFOR EACH ROW\nEXECUTE FUNCTION public.prevent_role_self_escalation();'),
        isTrue,
      );
    });

    test('the function is SECURITY DEFINER with a pinned search_path', () {
      final fn = mig.substring(
        mig.indexOf('CREATE OR REPLACE FUNCTION public.prevent_role_self_escalation()'),
        mig.indexOf('DROP TRIGGER IF EXISTS'),
      );
      expect(fn.contains('SECURITY DEFINER'), isTrue);
      expect(fn.contains('SET search_path = public'), isTrue);
    });

    test('the guard fires on a change to role OR is_developer', () {
      expect(
        mig.contains('NEW.role IS DISTINCT FROM OLD.role') &&
            mig.contains('NEW.is_developer IS DISTINCT FROM OLD.is_developer'),
        isTrue,
      );
    });

    test('the guard blocks ONLY a real end-user session (auth.uid() present AND not service_role)', () {
      // auth.uid() IS NOT NULL => a user access token with a `sub` claim.
      // service_role key / dashboard SQL console / pg_cron => no `sub` => not blocked.
      expect(mig.contains('auth.uid() IS NOT NULL'), isTrue);
      expect(mig.contains("coalesce(auth.role(), 'authenticated') <> 'service_role'"), isTrue);
      expect(mig.contains('RAISE EXCEPTION'), isTrue);
      expect(mig.contains("ERRCODE = 'insufficient_privilege'"), isTrue);
    });

    test('is_suspended (a non-existent users column) is never referenced', () {
      expect(mig.toLowerCase().contains('is_suspended'), isTrue,
          reason: 'header explains why is_suspended is excluded -- that mention is expected');
      // ...but never in executable SQL.
      expect(exec.contains('is_suspended'), isFalse,
          reason: 'is_suspended must not appear in any executable statement');
    });
  });

  group('non-breaking: nothing legitimate writes users.role / users.is_developer', () {
    test('no Flutter file and no edge function updates users.role or users.is_developer', () {
      final srcs = <String>[
        ...Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .map((f) => f.readAsStringSync()),
        ...Directory('supabase/functions')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.ts') && !f.path.endsWith('.test.ts'))
            .map((f) => f.readAsStringSync()),
      ];
      final all = srcs.join('\n');
      // Locate every `from('users')` / `from("users")` and scan the following 400 chars for a
      // write to the two privileged columns.
      final singleQuote = "from('users')";
      final doubleQuote = 'from("users")';
      for (final marker in [singleQuote, doubleQuote]) {
        var idx = all.indexOf(marker);
        while (idx != -1) {
          final window = all.substring(idx, (idx + 400).clamp(0, all.length));
          final isWrite = window.contains('.update(') || window.contains('.upsert(');
          if (isWrite) {
            expect(window.contains("'role'") || window.contains('"role":'), isFalse,
                reason: 'a users write near offset $idx includes role');
            expect(window.contains('is_developer'), isFalse,
                reason: 'a users write near offset $idx includes is_developer');
          }
          idx = all.indexOf(marker, idx + 1);
        }
      }
    });

    test('update-order-status reads users but never writes it', () {
      final s = _read('supabase/functions/update-order-status/index.ts');
      for (final m in RegExp(r'\.from\(\s*"users"\s*\)\s*\.\s*(\w+)').allMatches(s)) {
        expect(m.group(1), 'select');
      }
    });
  });
}
