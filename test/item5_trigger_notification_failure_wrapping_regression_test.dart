// Regression guard for Phase 6 ITEM 5 (approved separately from the core Phase-6 migration
// 20260901000035): on_intercity_request_change and on_rider_review_insert must never let a
// notification-processing failure roll back the underlying business transaction (an intercity
// request insert/update, or a rating/review insert).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration =
      _read('supabase/migrations/20260901000036_item5_trigger_notification_failure_wrapping.sql');

  group('1. Only the two approved functions are redefined', () {
    test('on_intercity_request_change is redefined', () {
      expect(migration.contains('CREATE OR REPLACE FUNCTION public.on_intercity_request_change()'), isTrue);
    });

    test('on_rider_review_insert is redefined', () {
      expect(migration.contains('CREATE OR REPLACE FUNCTION public.on_rider_review_insert()'), isTrue);
    });

    test('no other function is redefined -- exactly two CREATE OR REPLACE FUNCTION statements '
        'appear in this migration', () {
      final matches = RegExp(r'CREATE OR REPLACE FUNCTION public\.\w+\(').allMatches(migration);
      expect(matches.length, 2);
    });

    test('send_push_notification_fnc, send_order_status_notifications_core, and '
        'deliver_push_notification_http_fnc are not touched by this migration', () {
      for (final name in [
        'send_push_notification_fnc',
        'send_order_status_notifications_core',
        'deliver_push_notification_http_fnc',
      ]) {
        expect(migration.contains('CREATE OR REPLACE FUNCTION public.$name'), isFalse,
            reason: '$name must not be redefined by the Item 5 migration');
      }
    });
  });

  group('2. No new table, no new trigger, no new notification_failures.failure_stage value', () {
    test('this migration contains no CREATE TABLE statement -- it reuses the already-deployed '
        'public.notification_failures table', () {
      expect(migration.contains('CREATE TABLE'), isFalse);
    });

    test('this migration contains no CREATE TRIGGER statement -- only redefines the bodies of '
        'the two already-trigger-bound functions', () {
      expect(migration.contains('CREATE TRIGGER'), isFalse);
      expect(migration.contains('CREATE OR REPLACE TRIGGER'), isFalse);
    });

    test('only the existing "enqueue" failure_stage value is used -- no new enum/value is '
        'invented', () {
      expect("'enqueue', 'on_intercity_request_change'".allMatches(migration).length, 1);
      expect("'enqueue', 'on_rider_review_insert'".allMatches(migration).length, 1);
      for (final stage in ['processing', 'insert', 'push_delivery']) {
        expect(migration.contains("'$stage', 'on_intercity_request_change'"), isFalse);
        expect(migration.contains("'$stage', 'on_rider_review_insert'"), isFalse);
      }
    });
  });

  group('3. Each function\'s entire notification-construction-and-send logic is wrapped in its '
      'own guard, with an unconditional RETURN NEW after it', () {
    test('on_intercity_request_change: guard opens right after the DECLARE block and its '
        'EXCEPTION handler sits before the final, unconditional RETURN NEW', () {
      final fn = _extractFunction(migration, 'on_intercity_request_change');
      final declareEndIdx = fn.indexOf('BEGIN');
      final innerBeginIdx = fn.indexOf('BEGIN', declareEndIdx + 'BEGIN'.length);
      final exceptionIdx = fn.indexOf('EXCEPTION WHEN OTHERS THEN');
      final failureInsertIdx = fn.indexOf("'enqueue', 'on_intercity_request_change'");
      final lastReturnNewIdx = fn.lastIndexOf('RETURN NEW;');
      expect(innerBeginIdx, greaterThan(declareEndIdx));
      expect(exceptionIdx, greaterThan(innerBeginIdx));
      expect(failureInsertIdx, greaterThan(exceptionIdx));
      expect(lastReturnNewIdx, greaterThan(failureInsertIdx));
    });

    test('on_rider_review_insert: guard opens right after the DECLARE block and its EXCEPTION '
        'handler sits before the final, unconditional RETURN NEW', () {
      final fn = _extractFunction(migration, 'on_rider_review_insert');
      final declareEndIdx = fn.indexOf('BEGIN');
      final innerBeginIdx = fn.indexOf('BEGIN', declareEndIdx + 'BEGIN'.length);
      final exceptionIdx = fn.indexOf('EXCEPTION WHEN OTHERS THEN');
      final failureInsertIdx = fn.indexOf("'enqueue', 'on_rider_review_insert'");
      final lastReturnNewIdx = fn.lastIndexOf('RETURN NEW;');
      expect(innerBeginIdx, greaterThan(declareEndIdx));
      expect(exceptionIdx, greaterThan(innerBeginIdx));
      expect(failureInsertIdx, greaterThan(exceptionIdx));
      expect(lastReturnNewIdx, greaterThan(failureInsertIdx));
    });

    test('both functions still call send_push_notification_fnc the same number of times as '
        'before (4 call sites in on_intercity_request_change, 1 in on_rider_review_insert) -- '
        'the guard wraps the existing calls, it does not add or remove any', () {
      final intercity = _extractFunction(migration, 'on_intercity_request_change');
      final review = _extractFunction(migration, 'on_rider_review_insert');
      expect('PERFORM public.send_push_notification_fnc('.allMatches(intercity).length, 4);
      expect('PERFORM public.send_push_notification_fnc('.allMatches(review).length, 1);
    });
  });

  group('4. Every failure-tracking INSERT is itself defensively guarded (nested exception)', () {
    test('both new notification_failures INSERT call sites are wrapped in their own nested '
        'BEGIN...EXCEPTION WHEN OTHERS THEN NULL...END, so a failure while logging a failure can '
        'never escape and roll back the business transaction', () {
      final insertBlocks = RegExp(
        r'BEGIN\s*\n\s*INSERT INTO public\.notification_failures[\s\S]*?EXCEPTION WHEN OTHERS THEN\s*\n\s*NULL;\s*\n\s*END;',
      ).allMatches(migration).toList();
      expect(insertBlocks.length, 2);
    });
  });

  group('5. Success-path content/payload/recipient logic is reproduced unchanged', () {
    test('on_intercity_request_change: sample notification copy and jsonb payload shape survive '
        'unmodified', () {
      final fn = _extractFunction(migration, 'on_intercity_request_change');
      for (final copy in [
        "'New Parcel Match'",
        "'Discussion Opened 💬'",
        "'Payment Verified! 💳'",
        "'type', 'intercity_request',",
        "jsonb_build_object('type', 'intercity_request', 'request_id', NEW.id, 'order_id', NEW.parcel_id, 'status', NEW.status)",
      ]) {
        expect(fn.contains(copy), isTrue, reason: 'missing unchanged copy/payload: $copy');
      }
    });

    test('on_rider_review_insert: recipient-resolution and feedback-append logic, plus the '
        'self-notify defense-in-depth guard, survive unmodified', () {
      final fn = _extractFunction(migration, 'on_rider_review_insert');
      for (final snippet in [
        "v_recipient_user_id := NEW.user_id;",
        "SELECT user_id INTO v_recipient_user_id FROM public.riders WHERE id = NEW.rider_id;",
        "v_body := v_body || ' Feedback: \"' || NEW.comment || '\"';",
        "v_recipient_user_id IS DISTINCT FROM auth.uid()",
        "'type', 'new_rating',",
      ]) {
        expect(fn.contains(snippet), isTrue, reason: 'missing unchanged logic: $snippet');
      }
    });
  });

  group('6. No secrets, tokens, OTPs, or full payloads captured in the new failure-tracking '
      'INSERTs', () {
    test('the two new notification_failures INSERT VALUES clauses never reference a secret, '
        'token, OTP, or a raw payload variable', () {
      final insertBlocks = RegExp(
        r'INSERT INTO public\.notification_failures \([\s\S]*?\);',
      ).allMatches(migration).map((m) => m.group(0)!).toList();
      expect(insertBlocks.length, 2);
      for (final block in insertBlocks) {
        for (final term in ['p_pickup_otp', 'p_delivery_otp', 'decrypted_secret', 'password_hash']) {
          expect(block.contains(term), isFalse,
              reason: 'notification_failures INSERT must never reference $term:\n$block');
        }
        expect(block.contains('left(SQLERRM, 2000)'), isTrue,
            reason: 'error_message must be bounded via left(SQLERRM, 2000)');
      }
    });
  });
}

/// Extracts a single `CREATE OR REPLACE FUNCTION public.<name>(...) ... $function$;` block from
/// the migration file's raw text.
String _extractFunction(String migration, String name) {
  final startPattern = 'CREATE OR REPLACE FUNCTION public.$name(';
  final start = migration.indexOf(startPattern);
  expect(start, greaterThan(-1), reason: 'function $name not found in migration');
  final end = migration.indexOf(r'$function$;', start);
  expect(end, greaterThan(start), reason: 'end of function $name not found');
  return migration.substring(start, end + r'$function$;'.length);
}
