// Regression guard for Phase 1 audit findings C1 + H1 -- privileged SECURITY DEFINER functions
// that were left PUBLIC-executable.
//
// Migration 20260906000001 REVOKEs EXECUTE FROM PUBLIC on:
//   * credit_rider_for_completed_order   (C1 -- arbitrary wallet credit -> real-money withdrawal)
//   * apply_government_tax_payment        (H1 -- rider zeroes own tax-due balance)
//   * apply_order_government_tax          (H1 -- forge government_tax_ledger rows)
//   * assign_nearby_searching_orders_core (H1 -- unauthorized dispatch injection)
//
// This test (source-as-text, this repo's structural-regression-guard convention) asserts the
// migration is present, uses the exact live function signatures, only REVOKEs FROM PUBLIC (never
// touches a service_role grant or a function body), and that no LATER migration re-grants any of
// these to PUBLIC / authenticated / anon. It also asserts no application code calls these
// functions directly (the whole basis for the REVOKE being non-breaking).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

const _migPath =
    'supabase/migrations/20260906000001_revoke_public_execute_privileged_settlement_functions.sql';

const _sigs = <String, String>{
  'credit_rider_for_completed_order':
      'public.credit_rider_for_completed_order(uuid, numeric, boolean, numeric)',
  'apply_government_tax_payment': 'public.apply_government_tax_payment(uuid, uuid, numeric)',
  'apply_order_government_tax':
      'public.apply_order_government_tax(uuid, uuid, text, numeric, boolean)',
  'assign_nearby_searching_orders_core':
      'public.assign_nearby_searching_orders_core(uuid, uuid, double precision, double precision, public.partner_service_mode_enum)',
};

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

  group('C1 + H1: migration 20260906000001 locks down all four functions', () {
    for (final e in _sigs.entries) {
      test('REVOKEs EXECUTE FROM PUBLIC on ${e.key} with the exact signature', () {
        expect(
          exec.contains('REVOKE ALL ON FUNCTION ${e.value} FROM PUBLIC;'),
          isTrue,
          reason: 'missing/incorrect REVOKE for ${e.key}',
        );
      });

      test('re-asserts (does not drop) the service_role EXECUTE grant on ${e.key}', () {
        expect(
          exec.contains('GRANT EXECUTE ON FUNCTION ${e.value} TO service_role;'),
          isTrue,
        );
      });
    }

    test('the migration is REVOKE/GRANT only -- no function body, DDL, or business logic', () {
      for (final forbidden in [
        'CREATE OR REPLACE FUNCTION',
        'CREATE FUNCTION',
        'DROP FUNCTION',
        'ALTER TABLE',
        'CREATE TABLE',
        'DROP TABLE',
        'CREATE TRIGGER',
        'CREATE POLICY',
        'DROP POLICY',
        'UPDATE public.',
        'DELETE FROM',
        'INSERT INTO',
        'wallet_balance',
        'commission',
        'gst_amount',
        'pricing_config',
      ]) {
        expect(exec.contains(forbidden), isFalse,
            reason: 'migration must be permission-only, found "$forbidden"');
      }
    });

    test('the REVOKE targets are exactly the four in-scope functions (no scope creep)', () {
      final revokes = RegExp(r'REVOKE ALL ON FUNCTION (public\.[a-z_]+)\(')
          .allMatches(exec)
          .map((m) => m.group(1))
          .toSet();
      expect(revokes, {
        'public.credit_rider_for_completed_order',
        'public.apply_government_tax_payment',
        'public.apply_order_government_tax',
        'public.assign_nearby_searching_orders_core',
      });
    });
  });

  group('no later migration re-opens these functions', () {
    final laterMigs = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .where((f) =>
            f.path.contains('20260906000001') == false &&
            f.uri.pathSegments.last.compareTo(
                    '20260906000001_revoke_public_execute_privileged_settlement_functions.sql') >
                0)
        .toList();

    test('no migration after 20260906000001 GRANTs any of the four to PUBLIC/authenticated/anon', () {
      for (final f in laterMigs) {
        final s = f.readAsStringSync();
        for (final fn in _sigs.keys) {
          final bad = RegExp('GRANT[^;]*$fn[^;]*TO[^;]*(PUBLIC|authenticated|anon)',
              caseSensitive: false);
          expect(bad.hasMatch(s), isFalse,
              reason: '${f.uri.pathSegments.last} re-grants $fn to a client role');
        }
      }
    });
  });

  group('the REVOKE is non-breaking: no application code calls these functions directly', () {
    List<String> dartFiles() => Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => f.readAsStringSync())
        .toList();
    List<String> edgeFiles() => Directory('supabase/functions')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.ts') && !f.path.endsWith('.test.ts'))
        .map((f) => f.readAsStringSync())
        .toList();

    test('no Flutter client invokes credit_rider_for_completed_order / apply_order_government_tax / assign_nearby_searching_orders_core via .rpc() (comments are fine)', () {
      // Strip Dart // and /// comments first -- these function names appear only in explanatory
      // comments across the earnings/home/activity screens, never as a call.
      final code = dartFiles()
          .map((s) => s
              .split('\n')
              .map((l) {
                final i = l.indexOf('//');
                return i >= 0 ? l.substring(0, i) : l;
              })
              .join('\n'))
          .join('\n');
      for (final fn in [
        'credit_rider_for_completed_order',
        'apply_government_tax_payment',
        'apply_order_government_tax',
        'assign_nearby_searching_orders_core',
      ]) {
        expect(RegExp('''\\.rpc\\(\\s*['"]$fn['"]''').hasMatch(code), isFalse,
            reason: 'Flutter calls $fn via .rpc()');
        expect(code.contains(fn), isFalse,
            reason: 'executable Dart references $fn (not a comment)');
      }
    });

    test('no edge function invokes credit_rider_for_completed_order / apply_order_government_tax / assign_nearby_searching_orders_core via .rpc()', () {
      final all = edgeFiles().join('\n');
      for (final fn in [
        'credit_rider_for_completed_order',
        'apply_order_government_tax',
        'assign_nearby_searching_orders_core',
      ]) {
        expect(RegExp('\\.rpc\\(\\s*["\']$fn["\']').hasMatch(all), isFalse,
            reason: 'an edge function calls $fn via .rpc()');
      }
    });

    test('the ONLY edge-function callers of apply_government_tax_payment use the service-role admin client', () {
      final webhook = _read('supabase/functions/cashfree-webhook/index.ts');
      final verify = _read('supabase/functions/verify-payment/index.ts');
      for (final src in [webhook, verify]) {
        expect(src.contains('apply_government_tax_payment'), isTrue);
        // called on `supabaseAdmin` (the service-role client), not the user-scoped client.
        expect(
          RegExp(r'supabaseAdmin\.rpc\(\s*"apply_government_tax_payment"').hasMatch(src),
          isTrue,
          reason: 'apply_government_tax_payment must be called via the service-role admin client',
        );
      }
    });

    test('every settlement PERFORM of credit_rider_for_completed_order / apply_order_government_tax lives inside a SECURITY DEFINER function', () {
      // The two live settlement functions that call them.
      for (final path in [
        'supabase/migrations/20260901000019_gate_free_trial_waiver_to_local_orders.sql',
        'supabase/migrations/20260906000000_fix_parcel_completion_travel_plan_status_sync.sql',
      ]) {
        final s = _read(path);
        if (s.contains('credit_rider_for_completed_order') ||
            s.contains('apply_order_government_tax')) {
          expect(s.contains('SECURITY DEFINER'), isTrue,
              reason: '$path calls a locked fn but is not SECURITY DEFINER');
        }
      }
    });
  });
}
