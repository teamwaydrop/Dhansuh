// Regression guard for Phase 2 audit finding H2 -- push-notification SECURITY DEFINER functions
// left PUBLIC-executable (anon + authenticated could call them directly via PostgREST RPC).
//
// Migration 20260906000003:
//   * send_push_notification_fnc(uuid,text,text,jsonb)          -- REVOKE FROM PUBLIC + GRANT service_role
//   * deliver_push_notification_http_fnc(uuid,text,text,jsonb)  -- REVOKE FROM PUBLIC + GRANT service_role
//   * check_dormant_riders()                                    -- REVOKE FROM PUBLIC + GRANT service_role
//   * send_admin_push_notification(text,text,text,text,jsonb)   -- REVOKE FROM PUBLIC, GRANT authenticated
//     + service_role, CREATE OR REPLACE with a prepended admin / service-role guard, fan-out
//     body reproduced verbatim.
//
// Source-as-text structural guard (this repo's convention). Asserts the migration is present,
// uses the exact live signatures, REVOKEs each from PUBLIC, only re-grants to backend roles,
// the admin function keeps its verbatim fan-out body plus an is_admin()/auth.uid() guard, no
// later migration re-opens any of them, and no application code calls them directly.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

const _migPath =
    'supabase/migrations/20260906000003_relockdown_push_notification_functions.sql';

const _internalSigs = <String, String>{
  'send_push_notification_fnc': 'public.send_push_notification_fnc(uuid, text, text, jsonb)',
  'deliver_push_notification_http_fnc':
      'public.deliver_push_notification_http_fnc(uuid, text, text, jsonb)',
  'check_dormant_riders': 'public.check_dormant_riders()',
};

const _adminSig = 'public.send_admin_push_notification(text, text, text, text, jsonb)';

void main() {
  final mig = _read(_migPath);
  // Strip SQL `--` comments so the header's explanatory text can't satisfy an executable check.
  final exec = mig
      .split('\n')
      .map((l) {
        final i = l.indexOf('--');
        return i >= 0 ? l.substring(0, i) : l;
      })
      .join('\n');

  group('H2: migration 20260906000003 is present and locks the three pure-internal functions', () {
    for (final e in _internalSigs.entries) {
      test('REVOKEs ALL FROM PUBLIC on ${e.key} with the exact signature', () {
        expect(
          exec.contains('REVOKE ALL ON FUNCTION ${e.value} FROM PUBLIC;'),
          isTrue,
          reason: 'missing/incorrect REVOKE for ${e.key}',
        );
      });

      test('grants EXECUTE on ${e.key} to service_role and to NO client role', () {
        expect(exec.contains('GRANT EXECUTE ON FUNCTION ${e.value} TO service_role;'), isTrue);
        expect(
          RegExp('GRANT[^;]*${RegExp.escape(e.value)}[^;]*TO[^;]*(authenticated|anon|PUBLIC)',
                  caseSensitive: false)
              .hasMatch(exec),
          isFalse,
          reason: '${e.key} must not be granted to a client role',
        );
      });
    }

    test('the three pure-internal functions get no CREATE OR REPLACE (permission-only change)', () {
      // Only send_admin_push_notification may be recreated (to add its guard).
      final creates = RegExp(r'CREATE OR REPLACE FUNCTION public\.(\w+)')
          .allMatches(mig)
          .map((m) => m.group(1))
          .toSet();
      expect(creates, {'send_admin_push_notification'});
    });
  });

  group('H2: send_admin_push_notification stays callable for admins but is guarded', () {
    test('REVOKEs ALL FROM PUBLIC with the exact signature', () {
      expect(exec.contains('REVOKE ALL ON FUNCTION $_adminSig FROM PUBLIC;'), isTrue);
    });

    test('grants EXECUTE to authenticated (admin-panel JWT) and service_role, never anon', () {
      expect(exec.contains('GRANT EXECUTE ON FUNCTION $_adminSig TO authenticated;'), isTrue);
      expect(exec.contains('GRANT EXECUTE ON FUNCTION $_adminSig TO service_role;'), isTrue);
      expect(
        RegExp('GRANT[^;]*send_admin_push_notification[^;]*TO[^;]*anon', caseSensitive: false)
            .hasMatch(exec),
        isFalse,
      );
    });

    test('is recreated SECURITY DEFINER with a pinned search_path', () {
      final fn = mig.substring(
        mig.indexOf('CREATE OR REPLACE FUNCTION public.send_admin_push_notification'),
      );
      expect(fn.contains('SECURITY DEFINER'), isTrue);
      expect(fn.contains("SET search_path TO 'public'"), isTrue);
    });

    test('prepends an admin / service-role guard: blocks a non-admin end-user session only', () {
      expect(mig.contains('auth.uid() IS NOT NULL AND NOT public.is_admin()'), isTrue);
      expect(mig.contains('RAISE EXCEPTION'), isTrue);
      expect(mig.contains("USING ERRCODE = 'insufficient_privilege'"), isTrue);
    });

    test('reproduces the live fan-out body verbatim (riders / users / ELSE branches intact)', () {
      // The three recipient branches and the exact selection shapes of the live body
      // (retrieved via pg_get_functiondef 2026-09-06). A subtle change to any of these
      // (dropped DISTINCT, altered join, altered city filter) would silently change WHO
      // receives an admin broadcast -- assert them explicitly.
      expect(mig.contains("IF p_recipient_type = 'riders' THEN"), isTrue);
      expect(mig.contains("ELSIF p_recipient_type = 'users' THEN"), isTrue);
      // riders branch: DISTINCT on r.user_id, city filter joins orders on o.rider_id = r.id.
      expect(mig.contains('SELECT DISTINCT r.user_id'), isTrue);
      expect(
        mig.contains(
            'WHERE o.rider_id = r.id AND (o.pickup_city = p_city OR o.destination_city = p_city)'),
        isTrue,
      );
      // users branch: DISTINCT on u.id, exclude anyone who is a rider.
      expect(mig.contains('SELECT DISTINCT u.id'), isTrue);
      expect(
        mig.contains('AND NOT EXISTS (SELECT 1 FROM public.riders r WHERE r.user_id = u.id)'),
        isTrue,
      );
      // users + ELSE branches: city filter joins orders on o.user_id = u.id.
      expect(
        mig.contains(
            'WHERE o.user_id = u.id AND (o.pickup_city = p_city OR o.destination_city = p_city)'),
        isTrue,
      );
      // ELSE (all-users) branch selects id with NO DISTINCT, exactly as live.
      expect(mig.contains('SELECT id FROM public.users u'), isTrue);
      // Fan-out still calls the per-user helper (unchanged), 3 times (one per branch).
      expect(
        'PERFORM public.send_push_notification_fnc(v_user_id, p_title, p_body, p_data);'
            .allMatches(mig)
            .length,
        3,
      );
      // The guard fires BEFORE the fan-out (a guard placed after the loops would still
      // send every notification before raising).
      expect(
        mig.indexOf('NOT public.is_admin()') <
            mig.indexOf("IF p_recipient_type = 'riders' THEN"),
        isTrue,
        reason: 'admin guard must precede the fan-out branches',
      );
    });

    test('the CREATE OR REPLACE targets ONLY send_admin_push_notification (no unrelated fn)', () {
      // Scope guard: every REVOKE/GRANT/CREATE in the migration names one of exactly the
      // four in-scope functions -- nothing else.
      final touched = RegExp(
              r'(?:REVOKE ALL ON FUNCTION|GRANT EXECUTE ON FUNCTION|CREATE OR REPLACE FUNCTION) (public\.\w+)')
          .allMatches(exec)
          .map((m) => m.group(1))
          .toSet();
      expect(touched, {
        'public.send_push_notification_fnc',
        'public.deliver_push_notification_http_fnc',
        'public.check_dormant_riders',
        'public.send_admin_push_notification',
      });
    });

    test('the migration does not touch FCM / token / template / notification-content logic', () {
      for (final forbidden in [
        'fcm_token',
        'device_token',
        'net.http_post',
        'notification_failures',
        'INSERT INTO public.notifications',
        'send-push-notification',
        'CREATE TRIGGER',
        'DROP TRIGGER',
        'ALTER TABLE',
        'CREATE POLICY',
      ]) {
        expect(exec.contains(forbidden), isFalse,
            reason: 'migration must be permission + verbatim-body only, found "$forbidden"');
      }
    });
  });

  group('no later migration re-opens any of the four notification functions', () {
    final laterMigs = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .where((f) =>
            f.uri.pathSegments.last.compareTo(
                '20260906000003_relockdown_push_notification_functions.sql') >
            0)
        .toList();

    test('no migration after 20260906000003 GRANTs any of the four to PUBLIC/authenticated/anon', () {
      final names = [..._internalSigs.keys, 'send_admin_push_notification'];
      for (final f in laterMigs) {
        final s = f.readAsStringSync();
        for (final fn in names) {
          // send_admin_push_notification -> authenticated is the one allowed re-grant.
          final roles = fn == 'send_admin_push_notification' ? '(PUBLIC|anon)' : '(PUBLIC|authenticated|anon)';
          final bad = RegExp('GRANT[^;]*$fn[^;]*TO[^;]*$roles', caseSensitive: false);
          expect(bad.hasMatch(s), isFalse,
              reason: '${f.uri.pathSegments.last} re-grants $fn to a client role');
        }
      }
    });
  });

  group('the REVOKE is non-breaking: no application code calls these functions directly', () {
    String stripComments(String s, String marker) => s
        .split('\n')
        .map((l) {
          final i = l.indexOf(marker);
          return i >= 0 ? l.substring(0, i) : l;
        })
        .join('\n');

    test('no Flutter client invokes any of the four via .rpc() (comments are fine)', () {
      final code = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .map((f) => stripComments(f.readAsStringSync(), '//'))
          .join('\n');
      for (final fn in [..._internalSigs.keys, 'send_admin_push_notification']) {
        expect(RegExp('''\\.rpc\\(\\s*['"]$fn['"]''').hasMatch(code), isFalse,
            reason: 'Flutter calls $fn via .rpc()');
      }
    });

    test('no edge function invokes any of the four via .rpc()', () {
      final all = Directory('supabase/functions')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.ts') && !f.path.endsWith('.test.ts'))
          .map((f) => stripComments(f.readAsStringSync(), '//'))
          .join('\n');
      for (final fn in [..._internalSigs.keys, 'send_admin_push_notification']) {
        expect(RegExp('''\\.rpc\\(\\s*["']$fn["']''').hasMatch(all), isFalse,
            reason: 'an edge function calls $fn via .rpc()');
      }
    });
  });
}
