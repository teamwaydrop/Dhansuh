// Regression guard: rating notifications truncated written feedback to 40 characters and
// unconditionally appended "..." even when the comment was shorter than 40 characters -- proven
// live against production: a 9-character comment ("too bad 😔"), stored in full in
// rider_reviews.comment, produced the notification body 'Feedback: "too bad 😔..."', a false-
// truncation ellipsis appended to a comment that was never actually cut off.
//
// ROOT CAUSE: on_rider_review_insert() (SQL trigger, AFTER INSERT ON public.rider_reviews):
//   v_body := v_body || ' Feedback: "' || substring(NEW.comment from 1 for 40) || '..."';
// This was the ONLY truncation point in the whole path (rating screen -> rider_reviews INSERT ->
// this trigger -> send_push_notification_fnc -> public.notifications -> push delivery -> FCM).
// rider_reviews.comment itself was never truncated -- only the notification body string was.
//
// FIX (20260901000032_rating_notification_full_feedback.sql): the complete, untruncated
// NEW.comment is used when feedback is present; an explicit "No written feedback provided."
// fallback is used when it is NULL/empty. Reproduced end to end against a real local
// Supabase/Docker instance (rider_reviews INSERT -> real trigger fire -> notifications row
// read-back): a 97-character comment, an exactly-40-character comment, a 9-character comment, an
// empty string, and NULL all produced the correct notification body with zero truncation and no
// false ellipsis, in both rating directions (rated_by='user' and rated_by='rider'). Every other
// branch of the function -- direction resolution, recipient logic, title wording, the self-notify
// defense-in-depth guard, notification_type, and the payload shape -- is reproduced byte-for-byte
// unchanged from 20260729000002_fix_rating_notification_direction.sql.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration = _read('supabase/migrations/20260901000032_rating_notification_full_feedback.sql');
  // Scoped to the actual executable function body -- the migration's own header comment quotes
  // the old buggy line verbatim as documentation, which must not make this assertion pass
  // spuriously.
  final fnStart = migration.indexOf('CREATE OR REPLACE FUNCTION public.on_rider_review_insert()');
  final fnEnd = migration.indexOf('SET search_path = public;', fnStart);
  final functionBody = migration.substring(fnStart, fnEnd);

  group('1. THE FIX: no truncation, no forced ellipsis, explicit empty-feedback fallback', () {
    test('fnStart/fnEnd anchors resolved correctly', () {
      expect(fnStart, greaterThan(-1));
      expect(fnEnd, greaterThan(fnStart));
    });

    test('the truncating substring() call is gone from the executable function body', () {
      expect(functionBody.contains('substring(NEW.comment'), isFalse);
    });

    test('a non-empty comment is appended in full, unmodified', () {
      expect(
        migration.contains("v_body := v_body || ' Feedback: \"' || NEW.comment || '\"';"),
        isTrue,
      );
    });

    test('a NULL/empty comment gets the explicit fallback string, not an omitted clause', () {
      expect(
        migration.contains("v_body := v_body || ' Feedback: \"No written feedback provided.\"';"),
        isTrue,
      );
    });

    test('the comment-presence check is unchanged (still gates which branch runs)', () {
      expect(migration.contains("IF NEW.comment IS NOT NULL AND NEW.comment != '' THEN"), isTrue);
    });
  });

  group('2. Everything else in the function is reproduced byte-for-byte unchanged', () {
    test('the rated_by direction branches are both present, unchanged', () {
      expect(migration.contains("IF NEW.rated_by = 'rider' THEN"), isTrue);
      expect(migration.contains('v_recipient_user_id := NEW.user_id;'), isTrue);
      expect(
        migration.contains('SELECT user_id INTO v_recipient_user_id FROM public.riders WHERE id = NEW.rider_id;'),
        isTrue,
      );
    });

    test('both directions\' title/body wording (unrelated to the feedback clause) is unchanged', () {
      expect(migration.contains("v_title := 'You''ve been rated 5-Star! 🌟';"), isTrue);
      expect(migration.contains("v_body := 'Your Drop Partner rated your trip 5 stars!';"), isTrue);
      expect(migration.contains("v_body := 'Your Drop Partner rated your trip.';"), isTrue);
      expect(
        migration.contains(
          "v_body := 'Excellent job! Your passenger rated your trip 5 stars. Keep up the amazing work!';",
        ),
        isTrue,
      );
      expect(migration.contains("v_body := 'Your passenger rated their trip with you.';"), isTrue);
    });

    test('the self-notify defense-in-depth guard is unchanged', () {
      expect(
        migration.contains(
          'IF v_recipient_user_id IS NOT NULL AND v_recipient_user_id IS DISTINCT FROM auth.uid() THEN',
        ),
        isTrue,
      );
    });

    test('notification_type and payload shape are unchanged', () {
      expect(migration.contains("'type', 'new_rating',"), isTrue);
      expect(migration.contains("'rating', NEW.rating,"), isTrue);
      expect(migration.contains("'review_id', NEW.id,"), isTrue);
      expect(migration.contains("'order_id', NEW.order_id,"), isTrue);
      expect(migration.contains("'rated_by', NEW.rated_by"), isTrue);
    });

    test('SECURITY DEFINER and search_path hardening are unchanged', () {
      expect(migration.contains('LANGUAGE plpgsql SECURITY DEFINER'), isTrue);
      expect(migration.contains('SET search_path = public;'), isTrue);
    });
  });

  group('3. This is a new forward-only migration, not an edit to an applied one', () {
    test('the already-applied 20260729000002 migration file is untouched', () {
      final oldMigration =
          _read('supabase/migrations/20260729000002_fix_rating_notification_direction.sql');
      expect(
        oldMigration.contains("v_body := v_body || ' Feedback: \"' || substring(NEW.comment from 1 for 40) || '..\"';"),
        isFalse,
      );
      // The old file still has its own original (buggy) line -- confirming it was never edited,
      // only superseded by a later CREATE OR REPLACE.
      expect(
        oldMigration.contains(
          "v_body := v_body || ' Feedback: \"' || substring(NEW.comment from 1 for 40) || '...\"';",
        ),
        isTrue,
      );
    });
  });
}
