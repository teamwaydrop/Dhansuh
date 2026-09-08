// Regression guard for Phase 10E — Phase 2C: redispatch cron self-overlap advisory lock.
//
// EVIDENCE (Phase 10B Supabase performance diagnostics): redispatch_freed_riders() observed at
// ~10.18s against a 20s pg_cron schedule; redispatch_stalled_searching_orders() on a 15s schedule;
// "potential overlap exists"; Postgres showed significant lock/contention behaviour. pg_cron does
// NOT serialize a job against its own still-running previous tick, so a slow sweep + the next
// scheduled tick = two concurrent executions of the SAME function doing the SAME work over the
// SAME candidate set — pure duplicate work + extra row-lock traffic, never an extra match.
//
// FIX (20260908000000_redispatch_cron_advisory_locks.sql): each function takes a
// TRANSACTION-SCOPED advisory lock (pg_try_advisory_xact_lock) as its first action and RETURNs
// immediately if it is already held. pg_cron runs each invocation in its own transaction, so the
// lock is always released when that transaction ends (commit / error / statement timeout) — it
// can never leak, and the two functions use different classifier ints so they never block each
// other. Both function bodies are otherwise reproduced byte-for-byte from their current live
// definitions (20260901000017 and 20260809000000).
//
// Structural (source-as-text) guard — this repo's established convention for backend correctness
// that cannot run against a live Supabase instance in a plain unit test.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read(
    'supabase/migrations/20260908000000_redispatch_cron_advisory_locks.sql',
  );

  // SQL with every `-- ...` comment line stripped, so assertions about what the migration actually
  // DOES are not confused by what its (deliberately detailed) header comment mentions.
  final sql = migration
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('--'))
      .join('\n');

  group('Phase 2C — redispatch cron self-overlap advisory lock', () {
    test('both redispatch cron functions are re-defined by this migration', () {
      expect(
        migration.contains('CREATE OR REPLACE FUNCTION public.redispatch_freed_riders()'),
        isTrue,
      );
      expect(
        migration.contains('CREATE OR REPLACE FUNCTION public.redispatch_stalled_searching_orders()'),
        isTrue,
      );
    });

    test('each function takes a TRANSACTION-SCOPED advisory lock and no-ops if it is already held', () {
      // xact-scoped -> released automatically at transaction end; can never leak a session lock.
      expect(migration.contains('pg_try_advisory_xact_lock'), isTrue);
      expect(migration.contains('pg_advisory_lock('), isFalse,
          reason: 'must be the try_ + _xact_ variant, never a blocking or session-scoped lock');
      expect(migration.contains('pg_advisory_xact_lock('), isFalse,
          reason: 'must be the non-blocking pg_TRY_advisory_xact_lock — a blocking wait would just '
              'move the contention, not remove it');

      // redispatch_freed_riders(): guard is the first statement after BEGIN, and bails with RETURN.
      expect(
        RegExp(
          r'redispatch_freed_riders\(\)[\s\S]*?BEGIN\s*'
          r'(--[^\n]*\n\s*)*'
          r'IF NOT pg_try_advisory_xact_lock\(4735021, 1\) THEN\s*'
          r'RAISE NOTICE[^\n]*\n\s*'
          r'RETURN;\s*'
          r'END IF;',
        ).hasMatch(migration),
        isTrue,
      );

      // redispatch_stalled_searching_orders(): same shape, different classifier int, and it runs
      // BEFORE the vault-secret lookup so a skipped tick does zero work.
      expect(
        RegExp(
          r'redispatch_stalled_searching_orders\(\)[\s\S]*?BEGIN\s*'
          r'(--[^\n]*\n\s*)*'
          r'IF NOT pg_try_advisory_xact_lock\(4735021, 2\) THEN\s*'
          r'RAISE NOTICE[^\n]*\n\s*'
          r'RETURN;\s*'
          r'END IF;\s*'
          r'\n\s*SELECT decrypted_secret INTO v_service_role_key',
        ).hasMatch(migration),
        isTrue,
      );
    });

    test('the two operations use DIFFERENT advisory-lock keys so they never block each other', () {
      expect(sql.contains('pg_try_advisory_xact_lock(4735021, 1)'), isTrue);
      expect(sql.contains('pg_try_advisory_xact_lock(4735021, 2)'), isTrue);
      // Exactly one guarded acquisition per function (in executable SQL, comments stripped).
      expect('IF NOT pg_try_advisory_xact_lock('.allMatches(sql).length, 2);
      expect('pg_try_advisory_xact_lock('.allMatches(sql).length, 2);
    });

    test('redispatch_freed_riders() body is otherwise unchanged from the live definition '
        '(20260901000017): rider_at_drop in the busy set + per-rider exception isolation + 5-min scan', () {
      expect(
        migration.contains(
          "AND bo.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing', 'payment_pending')",
        ),
        isTrue,
        reason: 'the busy-status blocking set must be byte-for-byte the current live set',
      );
      expect(migration.contains("o.updated_at >= NOW() - INTERVAL '5 minutes'"), isTrue);
      expect(
        RegExp(
          r'\) LOOP\s*'
          r'BEGIN\s*'
          r'PERFORM public\.assign_nearby_searching_orders_core\([\s\S]*?\);\s*'
          r'EXCEPTION WHEN OTHERS THEN\s*'
          r"[\s\S]*?RAISE WARNING 'redispatch_freed_riders: failed to rematch rider",
        ).hasMatch(migration),
        isTrue,
        reason: 'per-rider BEGIN/EXCEPTION isolation must be preserved',
      );
      // No new matching rule / no reimplementation.
      expect(migration.contains('PERFORM public.assign_nearby_searching_orders_core('), isTrue);
    });

    test('redispatch_stalled_searching_orders() body is otherwise unchanged from the live '
        'definition (20260809000000): stalled re-invoke loop + orphaned-lock cleanup', () {
      expect(migration.contains("o.order_status = 'searching'"), isTrue);
      expect(migration.contains("o.order_type NOT IN ('intercity_ride', 'intercity_parcel')"), isTrue);
      expect(
        migration.contains("url := v_supabase_url || '/functions/v1/start-dispatch'"),
        isTrue,
      );
      expect(migration.contains('timeout_milliseconds := 5000'), isTrue);
      // Orphaned dispatch_worker_running cleanup, unchanged (120s threshold).
      expect(
        RegExp(
          r'UPDATE public\.orders\s*'
          r'SET dispatch_worker_running = false\s*'
          r'WHERE dispatch_worker_running = true\s*'
          r"AND order_status != 'searching'[\s\S]*?"
          r"INTERVAL '120 seconds'",
        ).hasMatch(migration),
        isTrue,
      );
    });

    test('this migration does NOT touch cron schedules, grants, or any other object (executable SQL)', () {
      expect(sql.contains('cron.schedule'), isFalse,
          reason: 'Phase 2C must not change cron frequency');
      expect(sql.contains('cron.unschedule'), isFalse);
      expect(sql.toUpperCase().contains('DROP '), isFalse);
      expect(sql.toUpperCase().contains('ALTER TABLE'), isFalse);
      expect(sql.contains('GRANT '), isFalse);
      expect(sql.contains('REVOKE '), isFalse);
      // Only the two intended function definitions.
      expect('CREATE OR REPLACE FUNCTION'.allMatches(sql).length, 2);
    });

    test('completion / settlement path is not referenced by this migration\'s executable SQL '
        '(out of Phase 2C scope for code changes)', () {
      for (final untouched in [
        'complete_order_and_settle',
        'credit_rider_for_completed_order',
        'apply_order_government_tax',
        'calculate_fare_breakdown',
        'lock_timeout',
        'statement_timeout',
      ]) {
        expect(sql.contains(untouched), isFalse,
            reason: '"$untouched" must not appear in executable SQL — Phase 2C ships only the '
                'redispatch advisory lock');
      }
    });
  });

  group('Phase 2C — the live redispatch function definitions this migration reproduces are the '
      'ones it claims', () {
    test('20260901000017 is the current redispatch_freed_riders() (rider_at_drop busy set)', () {
      final base = _read(
        'supabase/migrations/20260901000017_redispatch_freed_riders_include_rider_at_drop.sql',
      );
      expect(
        base.contains(
          "AND bo.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing', 'payment_pending')",
        ),
        isTrue,
      );
    });

    test('20260809000000 is the current redispatch_stalled_searching_orders() (orphaned-lock cleanup)', () {
      final base = _read(
        'supabase/migrations/20260809000000_clear_orphaned_dispatch_worker_locks.sql',
      );
      expect(base.contains('CREATE OR REPLACE FUNCTION public.redispatch_stalled_searching_orders()'), isTrue);
      expect(base.contains("INTERVAL '120 seconds'"), isTrue);
    });
  });
}
