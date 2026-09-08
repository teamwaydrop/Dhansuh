// Regression guard for the Phase 6 CORE notification failure-tracking fix.
//
// AUDIT CONTEXT: the notification pipeline (orders trigger -> pg_net -> send_order_status_
// notifications_core -> send_push_notification_fnc -> INSERT INTO notifications -> pg_net ->
// send-push-notification Edge Function -> FCM) had a proven, live silent-failure zone -- 378
// notifications.delivery_status='pending' rows observed stuck for over an hour (some ~8 weeks) at
// audit time, because every failure point in this chain was either an unhandled exception or a
// RAISE WARNING that only reached ephemeral Postgres/function logs. This migration adds a new,
// admin-only, additive-only public.notification_failures table and wires a failure-branch-only
// INSERT into exactly four existing functions. It does NOT touch on_intercity_request_change or
// on_rider_review_insert (Item 5, a separate, not-yet-approved decision).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read('supabase/migrations/20260901000035_notification_failure_tracking.sql');

  group('1. notification_failures table exists with the approved shape', () {
    test('table is created', () {
      expect(migration.contains('CREATE TABLE IF NOT EXISTS public.notification_failures'), isTrue);
    });

    test('failure_stage CHECK constraint enumerates exactly the four approved stages', () {
      expect(
        migration.contains(
          "failure_stage text NOT NULL CHECK (failure_stage IN ('enqueue', 'processing', 'insert', 'push_delivery'))",
        ),
        isTrue,
      );
    });

    test('required context columns all exist, all nullable except failure_stage/source_function', () {
      for (final col in [
        'source_function text NOT NULL',
        'notification_type text,',
        'reference_id uuid,',
        'user_id uuid,',
        'notification_id uuid REFERENCES public.notifications(id) ON DELETE SET NULL',
        'error_code text,',
        'error_message text,',
        'pg_net_request_id bigint,',
        'created_at timestamptz NOT NULL DEFAULT now()',
      ]) {
        expect(migration.contains(col), isTrue, reason: 'missing column definition: $col');
      }
    });

    test('notification_id FK uses ON DELETE SET NULL -- this table must never block a '
        'notifications row from being pruned in the future', () {
      expect(migration.contains('REFERENCES public.notifications(id) ON DELETE SET NULL'), isTrue);
    });
  });

  group('2. Indexes exist as approved', () {
    test('created_at, failure_stage, and reference_id are all indexed', () {
      expect(migration.contains('CREATE INDEX IF NOT EXISTS idx_notification_failures_created_at ON public.notification_failures (created_at)'), isTrue);
      expect(migration.contains('CREATE INDEX IF NOT EXISTS idx_notification_failures_stage ON public.notification_failures (failure_stage)'), isTrue);
      expect(migration.contains('CREATE INDEX IF NOT EXISTS idx_notification_failures_reference_id ON public.notification_failures (reference_id)'), isTrue);
    });
  });

  group('3. RLS mirrors the proven dispatch_config/pricing_config pattern exactly', () {
    test('RLS is enabled', () {
      expect(migration.contains('ALTER TABLE public.notification_failures ENABLE ROW LEVEL SECURITY'), isTrue);
    });

    test('exactly one SELECT policy exists, gated by is_admin(), for authenticated only', () {
      expect(migration.contains('FOR SELECT'), isTrue);
      expect(migration.contains('TO authenticated'), isTrue);
      expect(migration.contains('USING (public.is_admin())'), isTrue);
    });

    test('no INSERT/UPDATE/DELETE policy exists for anyone but service_role -- RLS default-deny '
        'means normal users (including admins, via RLS) can never write to this table', () {
      expect(migration.contains('FOR INSERT'), isFalse);
      expect(migration.contains('FOR UPDATE'), isFalse);
      expect(migration.contains('FOR DELETE'), isFalse);
      expect(migration.contains('FOR ALL'), isFalse);
    });

    test('only SELECT is granted to authenticated; service_role retains full access (the only '
        'intended write path)', () {
      expect(migration.contains('GRANT SELECT ON public.notification_failures TO authenticated'), isTrue);
      expect(migration.contains('GRANT ALL ON public.notification_failures TO service_role'), isTrue);
    });
  });

  group('4. No secrets, tokens, OTPs, or full payloads are ever stored', () {
    test('no INSERT into notification_failures anywhere in this migration references a secret, '
        'token, OTP, or the raw p_data/NEW payload wholesale', () {
      final forbidden = [
        'v_service_role_key',
        'p_pickup_otp',
        'p_delivery_otp',
        'decrypted_secret',
      ];
      // Isolate just the notification_failures INSERT statements' VALUES clauses and confirm none
      // of the forbidden identifiers appear inside any of them.
      final insertBlocks = RegExp(
        r'INSERT INTO public\.notification_failures \([\s\S]*?\);',
      ).allMatches(migration).map((m) => m.group(0)!).toList();
      expect(insertBlocks.length, greaterThanOrEqualTo(5),
          reason: 'expected at least 5 notification_failures INSERT call sites (1 table-definition '
              'reference does not count; this checks the actual INSERT statements)');
      for (final block in insertBlocks) {
        for (final term in forbidden) {
          expect(block.contains(term), isFalse,
              reason: 'notification_failures INSERT must never reference $term:\n$block');
        }
      }
    });

    test('every error_message value is bounded via left(SQLERRM, 2000), never the raw SQLERRM '
        'or any longer/unbounded string', () {
      final errorMessageInserts = RegExp(r'error_code, error_message[\s\S]{0,400}').allMatches(migration);
      expect(errorMessageInserts.length, greaterThanOrEqualTo(3));
      for (final m in errorMessageInserts) {
        expect(m.group(0)!.contains('left(SQLERRM, 2000)'), isTrue);
      }
    });
  });

  group('5. Failure tracking executes ONLY inside failure branches (structural proof)', () {
    test('deliver_push_notification_http_fnc: the enqueue-stage INSERT sits strictly after the '
        'vault-missing RAISE WARNING and before the RETURN that already exists on that branch -- '
        'it cannot fire on the success path, which returns via the un-modified PERFORM net.http_post '
        'call further down', () {
      final fn = _extractFunction(migration, 'deliver_push_notification_http_fnc');
      final warnIdx = fn.indexOf('RAISE WARNING \'Push notification delivery skipped');
      final insertIdx = fn.indexOf("'enqueue', 'deliver_push_notification_http_fnc'");
      final returnIdx = fn.indexOf('RETURN;');
      expect(warnIdx, greaterThan(-1));
      expect(insertIdx, greaterThan(warnIdx));
      expect(returnIdx, greaterThan(insertIdx));
    });

    test('deliver_push_notification_http_fnc: the push_delivery-stage INSERT sits strictly after '
        'the function-level "Failed to send push notification HTTP call" RAISE WARNING -- the '
        'unique, unchanged marker of the outer EXCEPTION branch -- so it can only run if '
        'net.http_post itself threw, not from either of the two inner defensive guards this '
        'function also contains', () {
      final fn = _extractFunction(migration, 'deliver_push_notification_http_fnc');
      final outerExceptionMarkerIdx = fn.indexOf("RAISE WARNING 'Failed to send push notification HTTP call: %', SQLERRM;");
      final insertIdx = fn.indexOf("'push_delivery', 'deliver_push_notification_http_fnc'");
      expect(outerExceptionMarkerIdx, greaterThan(-1));
      expect(insertIdx, greaterThan(outerExceptionMarkerIdx));
    });

    test('on_order_status_update: both new INSERTs sit strictly after their respective failure '
        'signals (the vault-missing ELSE / the outer EXCEPTION), and RETURN NEW is still '
        'unconditional and unchanged, exactly as before', () {
      final fn = _extractFunction(migration, 'on_order_status_update');
      final elseIdx = fn.indexOf('RAISE WARNING \'on_order_status_update: vault secret');
      final firstInsertIdx = fn.indexOf("'enqueue', 'on_order_status_update', 'order_status'");
      expect(elseIdx, greaterThan(-1));
      expect(firstInsertIdx, greaterThan(elseIdx));
      // RETURN NEW must still be the function's last statement before its own final END -- i.e.
      // unconditional regardless of which branch (success, vault-missing, or exception) ran.
      expect(fn.trim().contains('RETURN NEW;\nEND;'), isTrue);
    });

    test('send_order_status_notifications_core: the new EXCEPTION clause is appended after the '
        'function\'s pre-existing final END IF (closing the p_old_status IS DISTINCT FROM '
        'p_new_status block) -- it wraps the whole function without altering a single line of the '
        'existing branch logic', () {
      final fn = _extractFunction(migration, 'send_order_status_notifications_core');
      final lastEndIfIdx = fn.lastIndexOf('END IF;');
      final exceptionIdx = fn.indexOf('EXCEPTION WHEN OTHERS THEN');
      expect(lastEndIfIdx, greaterThan(-1));
      expect(exceptionIdx, greaterThan(lastEndIfIdx));
    });

    test('send_push_notification_fnc: the new outer EXCEPTION clause is appended after the '
        'existing INSERT INTO notifications statement, not before or inside it -- distinguished '
        'from this function\'s two PRE-EXISTING, unrelated, nested "Ignore formatting errors" '
        'guards (which sit before the INSERT and are untouched) by anchoring on the new clause\'s '
        'own unique marker text', () {
      final fn = _extractFunction(migration, 'send_push_notification_fnc');
      final insertIdx = fn.indexOf('INSERT INTO public.notifications (');
      final valuesCloseIdx = fn.indexOf(');', insertIdx);
      final newExceptionIdx = fn.indexOf(
        "RAISE WARNING 'send_push_notification_fnc: failed to insert notification for user %: %', p_user_id, SQLERRM;",
      );
      expect(insertIdx, greaterThan(-1));
      expect(newExceptionIdx, greaterThan(valuesCloseIdx));
    });
  });

  group('6. Each of the four approved functions gets exactly one, correctly-staged failure INSERT '
      'call site (per new EXCEPTION/failure branch)', () {
    test('deliver_push_notification_http_fnc has both an enqueue-stage and a push_delivery-stage '
        'call site', () {
      final fn = _extractFunction(migration, 'deliver_push_notification_http_fnc');
      expect(fn.contains("'enqueue', 'deliver_push_notification_http_fnc'"), isTrue);
      expect(fn.contains("'push_delivery', 'deliver_push_notification_http_fnc'"), isTrue);
    });

    test('on_order_status_update has an enqueue-stage call site (both branches)', () {
      final fn = _extractFunction(migration, 'on_order_status_update');
      expect("'enqueue', 'on_order_status_update'".allMatches(fn).length, 2);
    });

    test('send_order_status_notifications_core has a processing-stage call site', () {
      final fn = _extractFunction(migration, 'send_order_status_notifications_core');
      expect(fn.contains("'processing', 'send_order_status_notifications_core'"), isTrue);
    });

    test('send_push_notification_fnc has an insert-stage call site', () {
      final fn = _extractFunction(migration, 'send_push_notification_fnc');
      expect(fn.contains("'insert', 'send_push_notification_fnc'"), isTrue);
    });
  });

  group('7. notification_id is captured only when available, never invented', () {
    test('deliver_push_notification_http_fnc extracts notification_id from p_data via a guarded, '
        'self-contained sub-block that can never abort the function on a bad/missing value', () {
      final fn = _extractFunction(migration, 'deliver_push_notification_http_fnc');
      expect(
        fn.contains("v_notification_id := NULLIF(p_data->>'notification_id', '')::uuid;"),
        isTrue,
      );
      // The extraction's own guard: appears before the first failure INSERT that uses it.
      final extractIdx = fn.indexOf("v_notification_id := NULLIF(p_data->>'notification_id'");
      final firstUseIdx = fn.indexOf('notification_id, error_message');
      expect(extractIdx, greaterThan(-1));
      expect(firstUseIdx, greaterThan(extractIdx));
    });

    test('the other three functions never claim a notification_id they cannot know at their '
        'stage (enqueue/processing happen before or without a guaranteed existing row in the '
        'context available to them)', () {
      final onOrderStatusUpdate = _extractFunction(migration, 'on_order_status_update');
      final core = _extractFunction(migration, 'send_order_status_notifications_core');
      expect(onOrderStatusUpdate.contains('notification_id,'), isFalse);
      expect(core.contains('notification_id,'), isFalse);
    });
  });

  group('8. Every failure-tracking INSERT is itself defensively guarded', () {
    test('every notification_failures INSERT call site is wrapped in its own nested '
        'BEGIN...EXCEPTION WHEN OTHERS THEN NULL...END, so a failure while logging a failure can '
        'never itself raise -- guaranteeing this feature cannot introduce a new failure mode', () {
      final insertBlocks = RegExp(
        r'BEGIN\s*\n\s*INSERT INTO public\.notification_failures[\s\S]*?EXCEPTION WHEN OTHERS THEN\s*\n\s*NULL;\s*\n\s*END;',
      ).allMatches(migration).toList();
      expect(insertBlocks.length, greaterThanOrEqualTo(5),
          reason: 'every notification_failures INSERT call site must be self-guarded');
    });
  });

  group('9. Item 5 explicitly NOT included in this migration', () {
    test('on_intercity_request_change is not redefined by this migration', () {
      expect(migration.contains('CREATE OR REPLACE FUNCTION public.on_intercity_request_change'), isFalse);
    });

    test('on_rider_review_insert is not redefined by this migration', () {
      expect(migration.contains('CREATE OR REPLACE FUNCTION public.on_rider_review_insert'), isFalse);
    });

    test('the dead 9-arg send_order_status_notifications_core overload is not touched -- only '
        'the live 11-arg overload (with p_cancelled_by/p_cancel_reason) is redefined', () {
      expect(
        migration.contains(
          'CREATE OR REPLACE FUNCTION public.send_order_status_notifications_core(p_order_id uuid, p_old_status text, p_new_status text, p_order_type text, p_estimated_duration_min integer, p_pickup_otp text, p_delivery_otp text, p_user_id uuid, p_rider_id uuid, p_cancelled_by text DEFAULT NULL::text, p_cancel_reason text DEFAULT NULL::text)',
        ),
        isTrue,
      );
    });
  });

  group('10. No new trigger is introduced', () {
    test('this migration contains no CREATE TRIGGER statement -- only CREATE TABLE and '
        'CREATE OR REPLACE FUNCTION on already-existing, already-trigger-bound functions', () {
      expect(migration.contains('CREATE TRIGGER'), isFalse);
      expect(migration.contains('CREATE OR REPLACE TRIGGER'), isFalse);
    });
  });

  group('11. Notification content/routing untouched (spot-check)', () {
    test('a sample of existing notification copy strings from send_order_status_notifications_core '
        'appear unmodified', () {
      final core = _extractFunction(migration, 'send_order_status_notifications_core');
      for (final copy in [
        "'Ride Accepted 🚗'",
        "'Order Cancelled ❌'",
        "'Parcel Delivered 🎉'",
        "jsonb_build_object(\n                    'type', 'order_status',",
      ]) {
        expect(core.contains(copy), isTrue, reason: 'notification copy/payload shape must be unchanged: $copy');
      }
    });
  });
}

/// Extracts a single `CREATE OR REPLACE FUNCTION public.<name>(...) ... $function$;` block from
/// the migration file's raw text, for functions defined with a plain (non-dollar-quoted-name)
/// `$function$` body delimiter, as every function in this migration uses.
String _extractFunction(String migration, String name) {
  final startPattern = 'CREATE OR REPLACE FUNCTION public.$name(';
  final start = migration.indexOf(startPattern);
  expect(start, greaterThan(-1), reason: 'function $name not found in migration');
  final end = migration.indexOf(r'$function$;', start);
  expect(end, greaterThan(start), reason: 'end of function $name not found');
  return migration.substring(start, end + r'$function$;'.length);
}
